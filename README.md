# Wake On Join

This script piggybacks off of [Velocity](https://papermc.io/software/velocity)'s logs to turn on and off one or more minecraft server, *regardless of launcher*, as well as the computers they are running on via Wake On LAN.

This has been tested for Velocity 3.4.0

---

## Prerequisites

- Linux
- [Velocity](https://papermc.io/software/velocity) set up.
- `etherwake` or equivalent wake-on-lan service, and verify it works as expected
- `ssh` set up to allow the computer running the Velocity server to ssh into the computers running the servers (with keys and not passwords).
- Install `yq` (a YAML parser): `sudo snap install yq`
- If the Minecraft server computers are not running Linux, you may need to install `tmux`
- Verify `tmux` commands work properly over ssh (sent from the Velocity computer to the server computers):
	1) `ssh user@ip "tmux new-session -d -s test [server start command]"`
	2) `ssh user@ip "tmux has-session -t test"`
	3) `ssh user@ip "tmux send-keys -t test 'list' Enter; sleep 0.5; tmux capture-pane -p -t test"`
	4) `ssh user@ip "tmux send-keys -t test 'stop' C-m"`
- Ensure all commands you put in the yaml file work as expected, particularly the start-command (test over ssh)

---

## Running

### Configure `WakeOnJoin.yaml`

This should be fairly self explanatory, take a look through the yaml file for more info.

The script and yaml need not be put anywhere special or particular, jsut make sure the file paths set in the yaml are all correct.

### To start the script:

`nohup ./WakeOnJoin.sh > WakeOnJoin.log 2>&1 &`

### To kill the script:

`pkill -TERM -g $(pgrep -o -f WakeOnJoin.sh)`

---

## Autostartup

1) `crontab -e`
2) Add entry: `@reboot cd /path/to/script/ && nohup ./WakeOnJoin.sh > WakeOnJoin.log 2>&1 &`
3) You may also want to add autostart for Velocity: `@reboot cd /path/to/velocity/ && tmux new-session -d -s Velocity './start.sh'`

---

## Todo

- [ ] Find a way to check if the user is using the pc and do not put it to sleep if so
- [ ] Piggyback off Velocity error messages to tell players that:
	- [ ] Another server is already running when they try to join one, if ONE_SERVER_AT_A_TIME is set
	- [ ] Server is starting/failed to start
	- [ ] Computer is turning on/failed ot turn on
