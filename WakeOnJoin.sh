#!/bin/bash

# Used to ensure yaml imported data is in the desired type
to_boolean() {
  case "$1" in
    true) return 1 ;;
    ture) return 1 ;;
    rtue) return 1 ;;
    false) return 0 ;;
    flase) return 0 ;;
    fasle) return 0 ;;
    0) return 0 ;;
    1) return 1 ;;
    *) return 0 ;;
  esac
}

# Load the YAML file
YAML_FILE="WakeOnJoin.yaml"

# User set variables
declare -A server_ips
declare -A server_users
declare -A server_sleep_commands
declare -A server_start_commands
declare -A server_wake_commands

# Overridable variables
declare -A server_lockout
declare -A server_shutdown_time
declare -A server_boot_time
declare -A initial_awake

# Script variables and flags
declare -A players_online
declare -A server_active
declare -A timer_active
declare -A timer_pid
declare -A sleep_pid
declare -A initial_awake

LOG=$(yq eval '.log' "$YAML_FILE")

ONE_SERVER_AT_A_TIME=$(to_boolean $(yq eval '.one-server-at-a-time' "$YAML_FILE"))

LOCKOUT=$(yq eval '.lockout' "$YAML_FILE")
SHUTDOWN_TIME=$(yq eval '.shutdown-time' "$YAML_FILE")
BOOT_TIME=$(yq eval '.boot-time' "$YAML_FILE")
INITIAL_AWAKE=$(to_boolean $(yq eval '.initial-awake' "$YAML_FILE"))

# Parse the YAML file using yq and populate the arrays
while IFS= read -r SERVER; do
  [[ "$SERVER" == "log" || "$SERVER" == "one-server-at-a-time" || "$SERVER" == "lockout" || "$SERVER" == "initial-awake" || "$SERVER" == "shutdown-time" || "$SERVER" == "boot-time" ]] && continue

  # Populate associative arrays
  server_ips["$SERVER"]=$(yq eval ".\"$SERVER\".ip" "$YAML_FILE")
  server_users["$SERVER"]=$(yq eval ".\"$SERVER\".user" "$YAML_FILE")
  server_sleep_commands["$SERVER"]=$(yq eval ".\"$SERVER\".\"sleep-command\" // \"echo\"" "$YAML_FILE")
  server_start_commands["$SERVER"]=$(yq eval ".\"$SERVER\".\"start-command\"" "$YAML_FILE")
  server_wake_commands["$SERVER"]=$(yq eval ".\"$SERVER\".\"wake-command\"" "$YAML_FILE")

  server_lockout["$SERVER"]=$(yq eval ".\"$SERVER\".lockout // \"$LOCKOUT\"" "$YAML_FILE")
  server_shutdown_time["$SERVER"]=$(yq eval ".\"$SERVER\".\"shutdown-time\" // \"$SHUTDOWN_TIME\"" "$YAML_FILE")
  server_boot_time["$SERVER"]=$(yq eval ".\"$SERVER\".\"boot-time\" // \"$BOOT_TIME\"" "$YAML_FILE")
  initial_awake["$SERVER"]=$(to_boolean $(yq eval ".\"$SERVER\".\"initial-awake\" // \"$INITIAL_AWAKE\"" "$YAML_FILE"))

  players_online["$SERVER"]=0
  server_active["$SERVER"]=0 # False
  timer_active["$SERVER"]=0 # False
  timer_pid["$SERVER"]=0
  sleep_pid["$SERVER"]=0
done < <(yq eval '. | keys | .[]' "$YAML_FILE")



start_timer() {
  (
    sleep ${server_shutdown_time[$1]} &
    echo $! > /tmp/{$1}_sleep_pid
    wait

    if [[ $1 != "" ]]; then
      # Stop the server and kill the tmux instance
      echo "[+] No players have logged on in ${server_shutdown_time[$1]} seconds, turning server $1 off"
      if ssh "${server_users[$1]}@${server_ips[$1]}" "tmux has-session -t $1" > /dev/null 2>&1; then
        ssh ${server_users[$1]}@${server_ips[$1]} "tmux send-keys -t $1 'stop' C-m"
        echo $(date +%s) > /tmp/{$1}_lockout

        # Ensure the server shuts down (gracefully)
        for i in {1..6}; do
          sleep $(( server_lockout[$1] / 6 ))
          if ! ssh ${server_users[$1]}@${server_ips[$1]} "tmux has-session -t $1" > /dev/null 2>&1; then

            # Piggyback off Velocity's logs to send info to tell the main script that the server was shutdown
            echo "Shutdown PC server $1" >> $LOG
            break
          fi
        done

        # Assume the server hanged after $LOCKOUT seconds if it's still running, and kill it
        if ssh ${server_users[$1]}@${server_ips[$1]} "tmux has-session -t $1" > /dev/null 2>&1; then
          echo "[-] $1 hung during shutdown."

          ssh ${server_users[$1]}@${server_ips[$1]} "tmux kill-session -t $1"
          echo "[-] Killed $1."

          # Piggyback off Velocity's logs to send info to tell the main script that the server was shutdown
          echo "Shutdown PC server $1" >> $LOG
        fi
      else
        echo "[-] $1 is already off. Either it was manually shutdown or it crashed."
        # Piggyback off Velocity's logs to send info to tell the main script that the server was shutdown
        echo "Shutdown PC server $1" >> $LOG
      fi
    fi

    # Only put the PC to sleep if it wasn't already awake
    if (( initial_awake[$1] )); then
      # TODO check if the user is using the pc
      if [[ "${server_sleep_commands[$1]}" != "" ]]; then
        echo "[+] Putting PC to sleep"
        if ! ssh ${server_users[$1]}@${server_ips[$1]} "${server_sleep_commands[$1]}" > /dev/null 2>&1; then
          echo "[-] PC unreachable, may already be asleep."
        fi

      else
        echo "[+] No sleep command, skipping."
      fi
    else
        echo "[ ] PC was already awake. Skipping sleep command."
    fi
  ) &

  timer_pid[$1]=$!  # Save the PID of the background process
  sleep_pid[$1]=$(cat /tmp/{$1}_sleep_pid)
  rm -f /tmp/{$1}_sleep_pid
  timer_active[$1]=1
  echo "[+] Started timer ${timer_pid[$1]}"
}

check_lockout() {
    if [ ! -f /tmp/$1_lockout ]; then
        return 0
    fi

    local START_TIME=$(cat /tmp/$1_lockout)
    local CURRENT_TIME=$(date +%s)
    local ELAPSED_TIME=$((CURRENT_TIME - START_TIME))

    if (( ELAPSED_TIME >= server_lockout[$1] )); then
        rm -f /tmp/$1_lockout
        return 0
    else
        return 1
    fi
}


while true; do
  tail -n 0 -F "$LOG" | while read -r line; do

    if echo "$line" | grep -q "unable to connect to server"; then
      SERVER_NAME=$(echo "$line" | sed -E 's/.*: unable to connect to server (.*)$/\1/')

      # If the server is active, but either starting or shutting down, then prevent players from starting the server
      if (( server_active[$SERVER_NAME] )); then
        # Checks if the server is starting/stopping
        # May also act as a buffer against players spam connecting
        #  - Once the server starts, the loop will rapidly go through the backlog of "unable to connect"s
        #  - Until the backlog is cleared, we continue to attempt trying to turn on the computer and start the server
        #  - The only concern is if there are so many players spamming that the backlog becomes bigger than can be cleared during the lockout time
        if check_lockout "$SERVER_NAME"; then
          continue

        # Verifies if the server is running and didn't hang on startup or crash
        else
          if ssh ${server_users[$SERVER_NAME]}@${server_ips[$SERVER_NAME]} "tmux has-session -t $SERVER_NAME" > /dev/null 2>&1; then
            PANE=$(ssh ${server_users[$SERVER_NAME]}@${server_ips[$SERVER_NAME]} "tmux send-keys -t $SERVER_NAME 'list' Enter; sleep 0.5; tmux capture-pane -p -t $SERVER_NAME")
            if echo "$PANE" | tac | grep -m 1 -qP 'There are \K[0-9]+(?= of a max of [0-9]+ players online:)'; then
              continue
            else
              # Kill the tmux session if it exists
              ssh ${server_users[$SERVER_NAME]}@${server_ips[$SERVER_NAME]} "tmux kill-session -t $SERVER_NAME"
              echo "[-] Killed $SERVER_NAME."
            fi
          else
            echo "[-] $SERVER_NAME not available."
            server_active[$SERVER_NAME]=0 # false
          fi
        fi

      # No active server means the computer might be asleep, send the wake command
      else

        # Prevents players from starting multiple servers at the same time
        # TODO Add feedback to the player so they know there's a server up
        if (( ONE_SERVER_AT_A_TIME )); then
          for SERVER_ACTIVE in "${server_active[@]}"; do
            if (( SERVER_ACTIVE )); then
              continue 2
            fi
          done
        fi

        # Check if the computer is already awake
        if nc -z -w 5 "${server_ips[$SERVER_NAME]}" "22" > /dev/null 2>&1; then
          echo "[+] Computer already awake."
          initial_awake[$SERVER_NAME]=1 # true
        else
          echo "[+] Turning computer on."
          eval ${server_wake_commands[$SERVER_NAME]}
          initial_awake[$SERVER_NAME]=0 # false
        fi
      fi
      

      # Allow some time for the computer to wake up
      for i in {1..6}; do
        if nc -z -w 5 "${server_ips[$SERVER_NAME]}" "22" > /dev/null 2>&1; then
          echo "[+] Computer is online."
          break
        elif [[ $i -eq 6 ]]; then
          echo "[-] Computer failed to turn on in the allotted time."
          continue 2
        fi
        echo "[ ] Waiting for computer to come online..."
        sleep $(( server_boot_time[$SERVER_NAME] / 6 ))
      done

      echo "[+] Starting server."
      result=$(ssh ${server_users[$SERVER_NAME]}@${server_ips[$SERVER_NAME]} "tmux new-session -d -s $SERVER_NAME '${server_start_commands[$SERVER_NAME]}'")

      if $result; then
        echo "[+] $SERVER_NAME started."
        server_active[$SERVER_NAME]=1 # true
        echo $(date +%s) > /tmp/{$SERVER_NAME}_lockout

        # Just in case no one actually joins the server
        start_timer $SERVER_NAME
      else
        echo "[-] $SERVER_NAME startup failed!"
      fi

    # Track player count and log joiners
    elif echo "$line" | grep -qE "\[server connection\] .* has connected$"; then
      SERVER_NAME=$(echo "$line" | sed -E 's/.*\[(.*)\] (\S+) -> (\S+) has connected/\3/')

      (( players_online[$SERVER_NAME]++ ))

      PLAYER_NAME=$(echo "$line" | sed -E 's/.*\[(.*)\] (\S+) -> (\S+) has connected/\2/')

      echo "[>] $PLAYER_NAME joined $SERVER_NAME"

      # Handles the case where the server was running before the script was started
      if (( ! server_active[$SERVER_NAME] )); then
        server_active[$SERVER_NAME]=1 # true

        # Accounts for there being players online already
        PANE=$(ssh ${server_users[$SERVER_NAME]}@${server_ips[$SERVER_NAME]} "tmux send-keys -t $SERVER_NAME 'list' Enter; sleep 0.5; tmux capture-pane -p -t $SERVER_NAME")
        players_online[$SERVER_NAME]=$(echo "$PANE" | tac | grep -m 1 -oP 'There are \K[0-9]+(?= of a max of [0-9]+ players online:)')
      fi

      # Stop the shutdown timer if it's running
      if (( timer_active[$SERVER_NAME] )); then
        kill "${timer_pid[$SERVER_NAME]}"
        kill "${sleep_pid[$SERVER_NAME]}"
        timer_active[$SERVER_NAME]=0 # false
        echo "[+] Killed timer ${timer_pid[$SERVER_NAME]}"
      fi

    # Track player count, log leavers, and begin timer if no players left
    elif echo "$line" | grep -qE "\[server connection\] .* has disconnected$"; then
      SERVER_NAME=$(echo "$line" | sed -E 's/.*\[(.*)\] (\S+) -> (\S+) has disconnected/\3/')

      (( players_online[$SERVER_NAME]-- ))

      PLAYER_NAME=$(echo "$line" | sed -E 's/.*\[(.*)\] (\S+) -> (\S+) has disconnected/\2/')

      echo "[<] $PLAYER_NAME left $SERVER_NAME"

      # Handles the case where the server was running before the script was started
      if (( ! server_active[$SERVER_NAME] )); then
        server_active[$SERVER_NAME]=1 # true

        # Accounts for there being players online already
        PANE=$(ssh ${server_users[$SERVER_NAME]}@${server_ips[$SERVER_NAME]} "tmux send-keys -t $SERVER_NAME 'list' Enter; sleep 0.5; tmux capture-pane -p -t $SERVER_NAME")
        players_online[$SERVER_NAME]=$(echo "$PANE" | tac | grep -m 1 -oP 'There are \K[0-9]+(?= of a max of [0-9]+ players online:)')
      fi

      echo "[+] ${players_online[$SERVER_NAME]} players online"

      if (( ! players_online[$SERVER_NAME] )); then
        start_timer $SERVER_NAME
      fi

    # Reset the server tracking variable when the server is shutdown
    elif echo "$line" | grep -q "Shutdown PC server"; then
      SERVER_NAME=$(echo "$line" | sed -E 's/Shutdown PC server (.*)/\1/')

      server_active[$SERVER_NAME]=0 # false
    fi
  done

  if [ $? -ne 0 ]; then
    echo "[-] Error reading Velocity log. Retrying."
    sleep 1
  fi
done