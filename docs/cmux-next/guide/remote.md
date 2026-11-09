# Remote machines and Tailscale

Run workspaces and agents on your own machines over SSH or Tailscale.

A remote machine is a computer you own: a Mac mini, a Linux box, or a server. cmux installs cmux-tui on it, starts its agent daemon, and shows its workspaces in your sidebar under the machine's name. Agents on it keep running when your laptop sleeps.

## Add a machine

Open the command palette and run Add Machine…, or click + in the Machines part of the sidebar. Type a host name, or pick a device from your Tailscale network. cmux then:

- checks that it can reach the host with SSH keys (no passwords);
- installs cmux-tui on the host;
- copies your agent profiles across and starts the agent daemon;
- shows a checklist. Run it again at any time with Check Machine.

```bash
cmux machine add
cmux machine doctor
cmux remote connect
```

## Tailscale

When Tailscale runs on this Mac, Add Machine lists the online devices of your tailnet, and marks the ones that are already added. Only your own devices are probed. A teammate's machine shows only when they share it with you.

Connections go over SSH on your tailnet. cmux opens no public port.

## Work on a machine

```bash
cmux remote new-workspace
cmux remote open-terminal-here
cmux remote reconnect
cmux remote disconnect
cmux remote forget
```

Browser tabs in a remote workspace can open the machine's localhost ports (browser.remoteLocalhost).

## When it does not connect

- Run Check Machine. Each failed step says what to fix.
- Make sure ssh HOST works in a terminal without a password.
- Run Copy SSH Error from the command palette to get the full message.

- [Cloud machines](cloud.md)
