# cmux server

Keep cmux sessions running on a Linux box or Mac, and install it there with one command.

cmux server keeps one cmux session running on a machine as a service: your terminals and agents there keep running when you log out, when the network drops, and after a reboot. Your cmux reaches it over SSH, with your own keys and SSH config. Nothing listens on the network but sshd.

## Install on another machine

From cmux on your Mac, give the machine as an ssh:// address. cmux prints each step before it runs it and asks first, unless you pass --yes:

```bash
cmux server install ssh://alice@build.example.com
cmux server install ssh://alice@build.example.com:2222 --yes
```

- it installs cmux on the machine, in ~/.local/bin, with no sudo. The download is the same build as your cmux, checked against its SHA-256;
- it runs cmux server install there, which starts the session as a service;
- it checks that the session answers, then adds the machine to your sidebar (Connect to Machine).

The machine must accept your SSH key, and its host key must already be in your known_hosts. A new host key or a password prompt goes to your terminal, as ssh always does. cmux never accepts a host key for you, and it turns off agent, X11 and port forwarding for these commands. Without a terminal (with --yes in a script), ssh never prompts: an unknown host key stops the install.

## Install on this machine

On the Linux box or Mac itself, one line installs cmux and starts the service:

```bash
curl -fsSL https://cmux.com/tui/install.sh | sh -s -- --server
```

To see what it would do first, add --dry-run. To install one exact build, add --commit SHA; --channel stable or --channel nightly picks the latest build of that channel. With cmux already installed, run cmux server install.

The installer checks the download against the SHA-256 in the build's manifest, over HTTPS only. The script is one block that the shell reads to its end before it runs, so a download cut short runs nothing.

## What the service is

- Linux: the systemd user unit cmux-server.service. cmux server install turns on lingering for your account (loginctl enable-linger), so the session starts at boot and keeps running while you are logged out. If lingering is not allowed, it says which one command an administrator runs.
- macOS: the LaunchAgent com.cmux.server. It runs while you are logged in.
- The service runs ~/.local/bin/cmux-tui daemon start --session main. That is the path cmux uses over SSH, so when cmux upgrades the machine's binary, the service runs the new one at its next start.
- A restart stops only the session daemon. Terminals keep running and the new daemon takes them back.

## Manage it

```bash
cmux server status
cmux server logs --follow
cmux server down
cmux server up
cmux server uninstall
cmux server uninstall ssh://alice@build.example.com
```

logs shows the service's log (the last 100 lines; --lines N or -n N for more, --follow or -f to keep reading). down stops the service and keeps it stopped across reboots; up starts it again. uninstall removes the service and keeps cmux and your settings, and says how to remove the rest: the cmux binary, and lingering, which stays on. cmux daemon stop --if-idle stops the running server only when nothing uses it (no terminal is starting, being reattached or running, and no other client is connected); otherwise it keeps running, says what uses it and exits 1. Every command takes --json.

cmux server install prints each file it writes and each command it runs. It does not touch a cmux-server.service or com.cmux.server plist that cmux did not write, or that was changed after cmux wrote it, or that systemd loads from another place (a package, /etc, a transient unit): install stops with an error and uninstall leaves it as it is. When it cannot ask systemd where the unit comes from, it changes nothing. On macOS the service log folder and file are readable only by you. It also stops when ~/.local/bin or the service folder can be written by other accounts.

## Options

- --session-name NAME: run another session than main.
- --user: start the service when you log in and stop it when you log out. Lingering stays as it is.
- --channel stable or --channel nightly (with ssh://): install the latest build of that channel there instead of your own build. --nightly is the same as --channel nightly.
- --label NAME (with ssh://): the machine's name in the cmux sidebar here, instead of its host name.
- --yes: run every step without asking. It is required when there is no terminal to ask on.
- --json: one JSON result on stdout, with each step and its exit status.

## For agents

Inside the machine, cmux is on PATH in every terminal the session starts, so an agent there can run cmux identify, cmux tab list or cmux skill show to drive the session.

## When it does not work

- Make sure ssh HOST works in a terminal without a password.
- Run cmux server status on the machine: it shows the service state and the session.
- Read the log with cmux server logs.
- If the service stops at logout, lingering is off: run sudo loginctl enable-linger $USER once.

- [Remote machines and Tailscale](remote.md)
- [CLI and MCP reference](cli.md)
