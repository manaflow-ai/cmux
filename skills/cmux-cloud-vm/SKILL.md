---
name: cmux-cloud-vm
description: "Operate cmux Cloud machines through the app's cloud actions, and drive a machine's own cmux-tui session from inside it. Use for cmux vm/cloud tasks; backend implementation belongs to cmux-backend."
---

# cmux Cloud machines

Use this skill when a task involves a cmux Cloud machine. Machine terminals persist
when panes close or the Mac disconnects.

The Mac-side `cmux vm …` command family (route, run, exec, agent, dev, push, pull,
tree, open, ssh, snapshot, fork, domains and the rest) was removed with the Swift
CLI. The Rust `cmux` has no `vm` scope. What remains:

| Where | What works |
| --- | --- |
| Mac, app running | `cmux cloud <verb>` app actions: create, open, fork, snapshot, restore, resize, rename and kill machines, sign in, diagnostics |
| Inside a machine | the machine's `cmux`, a guest adapter over its cmux-tui daemon: the resource grammar (`cmux workspace list`, `cmux terminal current screen read`) plus guest verbs (`cmux self`, `cmux coderouter`, `cmux env`, `cmux layout`, `cmux notify`, `cmux open-url`) |

## Start with discovery

```sh
cmux action list --category cloud
cmux action describe "cloud resize-machine"
cmux app capabilities
```

`action describe` prints the action's targets and arguments. Actions drive the app
the same way its palette and sidebar do. Run from the CLI or MCP, read actions answer
in the action result (`--json` prints it): `cloud exec` returns `exit_code`, `stdout`
and `stderr`, `cloud new-machine` the new `machine_id`, `machine-status` and the file
and listing actions their facts. They need the app, sign-in and its private tunnel.

## Machine lifecycle from the Mac

```sh
cmux cloud list-machines --json                           # machines (machine_id, target, status, owner)
cmux cloud new-machine                                    # answers machine_id (or pending)
cmux cloud new-workspace                                  # a new cloud workspace
cmux cloud new-terminal-on-machine --target machine:vm-…  # a new workspace with a terminal there
cmux cloud ssh --target machine:vm-…                      # a terminal tab in its first workspace
cmux cloud machine-status --target machine:vm-…
cmux cloud resize-machine --target machine:vm-… --size large --wait
cmux cloud snapshot-machine --target machine:vm-…
cmux cloud restore-machine --target machine:vm-… --snapshot <snapshot-id>
cmux workspace new-on-machine --machine machine:vm-…
```

From the CLI or MCP, every machine action needs `--target machine:vm-…`; without it
the app refuses the run (only a person's own click acts on the machine in front of
them). The full set is in [the command reference](references/commands.md).

Before creating a machine, check whether it already exists: `cmux cloud list-machines`
answers the app's own machine list (the sidebar's Cloud machines), each with the
`target` the other verbs take and its `status` (`paused` for a paused machine). Act on
it only when it says `loaded: true`: `loaded: false` means the list is not known yet.
`cmux machine list` also shows them (rows with `kind: "cloud"`), but it cannot tell an
unloaded list from an empty one.

## Work inside a machine

Open a terminal on the machine (`cmux cloud new-terminal-on-machine --target machine:vm-…`, or
`cmux cloud ssh --target machine:vm-…`, or the sidebar), then use
the machine's own `cmux` from that terminal. `current` selectors address the
session's active terminal, pane and workspace; use `$CMUX_TUI_TERMINAL_ID` for the
caller's own terminal:

```sh
cmux self --json
cmux workspace list
cmux pane current split --right
cmux terminal term_… write --text $'bun test\n'
cmux terminal term_… screen wait --pattern 'pass|fail' --timeout-ms 600000
cmux terminal term_… screen read
cmux notify --title "Tests done" --body "see the tests tab"
```

Read [guest operations](references/guest.md) for guest auth, CodeRouter, layouts and
browser authentication. The machine's `cmux --help` is authoritative.

## Constraints that apply throughout

- Provisioning, forking, restoring, resizing and killing machines need the user's
  authorization for the target and effect; retain authorization already given. Do not
  kill machines to make capacity.
- Keep account and upstream tokens on the host. Do not copy the user's credentials
  into a machine unless requested. Secret values do not belong in layout JSON, logs or
  command arguments.
- App actions can change focus. Prefer working inside the machine's session, which
  does not move the Mac's focus.

## Old `vm` verbs

The Swift `cmux vm …` family is gone. Its replacements are app actions:
`cmux cloud exec --command …` (returns the exit code and output), `cmux cloud ssh`
(opens a terminal), `cmux cloud file-write`, `cmux cloud file-read|files-list|prepare-scp`
(these return their result to the CLI),
`cmux cloud pause-machine|resume-machine`, `cmux cloud list-machines` (for `vm ls`),
and `cmux cloud domain-list` (listing only). These have no CLI path:
`vm route|tree|wait|restart|stats|prompt`, `vm open <m>:port/<n>`, `vm terminal …`
against a machine from the Mac, `vm layout|env` from the Mac, and domain publishing. Copy a port
link from the machine's menu (Copy Machine Link): the copy actions are menu-only. The
[command reference](references/commands.md#old-vm-verbs-and-their-replacements)
maps every old verb.

## Read only the relevant detail

- [Workflow recipes](references/agent-workflows.md): the supported paths for common tasks.
- [Command reference](references/commands.md): every cloud action and its arguments.
- [Guest operations](references/guest.md): inside-machine grammar, CodeRouter, notifications.
- [Sidebar parity](references/sidebar-parity.md): sidebar items and their actions.
- [Local workspace rules](../cmux-workspace/SKILL.md): presenting work without disrupting the caller.
