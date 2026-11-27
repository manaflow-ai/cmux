# Cloud machines

Run workspaces on cloud machines.

A cloud machine is a remote computer that cmux sets up for you. Run a workspace there, or move one over and bring it back.

## Pick the level you need

- One chat: use New Cloud Chat in the app or paste the setup prompt below into Chief. cmux prepares the machine and keeps the conversation in one place.
- Repeatable setup: use the CLI commands on this page. They expose machine ids, workspace ids, and session ids so a script or another agent can continue the same work.
- Team and integration work: describe the checkout in .cmux/machine.toml, list secret names under [secrets], and store each value on your Mac with cmux cloud secret set (Secrets and the vault). Use MCP or acpmux when another client needs to drive the session.

## Paste this into your agent

Copy this into any agent chat in cmux, opened on the folder you want to work on. It signs you in, makes a machine if you have none, and starts an agent there. New to cmux? The prompt on Getting started installs it first.

```text
Get me working in cmux Cloud from this folder: run `cmux cloud diagnostics`; if it says I am signed out, run `cmux login` and tell me to finish it in the browser. Run `cmux cloud list-machines`; if I have none, run `cmux setup cloud-machine` and tell me which card to click (it costs money every hour it runs). Then run `cmux cloud start-session --target machine:<id> --agent claude --from-folder .` with that machine's id from the list (or the one you just made), and give me the chat it opens. To move a chat I already have, run `cmux cloud move` in it; to bring it back to this Mac, `cmux cloud bring-back`. If a step fails, show me its error and the command to retry; never guess.
```

```bash
cmux cloud new-machine
cmux cloud new-workspace
cmux cloud ssh
cmux cloud exec
cmux cloud move
cmux cloud bring-back
```

## Terminals

Open a terminal on a machine with ssh, or make a new workspace there. Pass --workspace with a workspace id to add a terminal tab to that workspace instead. When the terminal is open, both answer machine_id and workspace_id, plus the new terminal's surface_id when cmux knows it. A paused machine resumes first: if that takes longer than about 30 seconds the answer is pending (machine_id, resuming, pending) and the terminal still opens.

```bash
cmux cloud ssh --target machine:<id>
cmux cloud new-terminal-on-machine --target machine:<id>
cmux cloud new-terminal-on-machine --target machine:<id> --workspace <workspace-id>
```

## Start an agent on a machine

Start a Claude or Codex session on a cloud machine. Name the machine with --target, or give a name with --name to use that machine or create it. An agent that runs this asks you first in its chat.

```bash
cmux cloud start-session --target machine:<id> --agent claude
cmux cloud start-session --name dev --agent codex
```

## Check and recover a session

A Cloud machine can be running while its chat is waiting, paused, or unreachable. Check the machine and the session separately so a network problem does not look like lost work.

```bash
cmux cloud diagnostics
cmux acp machine status
cmux acp ls
cmux cloud list-machines
```

Use the machine or session id named by those commands when you retry. A paused machine resumes when you open a terminal or start a chat; pause it again when you are done to stop its hourly cost.

## Fork, snapshot, hand off

For an opted-in ordinary chat interrupted by machine loss, see
[Recover a running chat replica](../running-chat-replicas.md).

```bash
cmux cloud fork-machine
cmux cloud snapshot-machine
cmux cloud restore-machine
cmux cloud hand-off-machine
```

## Ports and browser tabs

Open a port of a machine in a cmux browser tab, or get its link. Name the machine with --target machine:<id>; cmux cloud list-machines lists the ids.

```bash
cmux cloud open-browser --target machine:<id> --port 3000
cmux cloud machine-link --target machine:<id> --port 3000
cmux cloud port-forward --target machine:<id> --port 3000
cmux cloud port-list --target machine:<id>
cmux cloud port-close --target machine:<id> --port 3000
```

> Running machines do not update themselves. New software reaches new machines first.

- [Machines](machines.md)
- [Remote machines and Tailscale](remote.md)
- [Secrets and the vault](vault.md)
- [Plans and credits](plans.md)
