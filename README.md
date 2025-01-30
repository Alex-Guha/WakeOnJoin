# Wake On Join

This script piggybacks off of [Velocity](https://papermc.io/software/velocity)'s logs to turn on and off one or more minecraft server, *regardless of launcher*, as well as the computers they are running on via Wake On LAN.

#### Why? What's the use case?

I have a powerful desktop computer at home that I never make full usage of. I also have a raspberry pi acting as a low power server for a variety of applications on my home network. I didn't want to run my desktop when it's not needed to save on the electricity bill, but I also wanted to leverage the compute of my desktop.  
I went looking for solutions and, while I found some, they were launcher specific and none incorporated WakeOnLAN. Thus this was made.

I could also see this being used with a proxmox setup, so I extended it to work for any number of servers, on any number of computers.

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

## Velocity Config/Suggestions

### MOTD

We can set Velocity's `ping-passthrough = "all"` to allow players to see the Velocity MOTD when the corresponding server is off, and the MC server MOTD when it's on.

For instance, the Velocity MOTD might be: "Server offline. Connect to turn it on!", and then the MC server MOTD could be: "Server is online!". This way, players can see if the server is on without having to connect.

- [Velocity MOTD Maker](https://docs.papermc.io/misc/tools/minimessage-web-editor) (Velocity uses the MiniMessage format which is different from vanilla)
- [Vanilla MOTD Maker](https://mctools.org/motd-creator)

### Informing Players of Startup through Velocity Errors

Within `messages.properties` in the `lang/` folder of Velocity, you can change `velocity.error.connecting-server-error` to something like "Starting up server, please reconnect in a minute." to allow players to see that something is happening when they connect to an offline server.

### Port forwarding for Velocity

There are tons of resources about this online. Usually the setting is found in the Firewall section of your router.

I recommend using the default Minecraft port 25565, so that you can use forced hosts without including the port in the url if that's relevant to you (i.e. "mc.mydomain.com" instead of "mc.mydomain.com:25564")

### Multiple Minecraft Servers, One Computer

If you are allowing only one server at a time to be running (i.e. `one-server-at-a-time` is set), then all servers may run on the same port, as only one will be using it at a time. This would be set in both `velocity.toml` on Velocity and `server.properties` in the MC servers. This also makes setting firewall rules easy.

---

## Todo

- [ ] Find a way to check if the user is using the pc and do not put it to sleep if so
- [ ] Piggyback off Velocity error messages to tell players that:
	- [x] ~~Another server is already running when they try to join one, if ONE_SERVER_AT_A_TIME is set~~ See Velocity Advice section
	- [ ] Server is starting/failed to start
	- [ ] Computer is turning on/failed to turn on
