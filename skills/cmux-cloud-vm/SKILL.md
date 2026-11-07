---
name: cmux-cloud-vm
description: "Start a Cloud chat and read its reply in one command (`cmux cloud start-chat --prompt TEXT --wait --json`), and operate cmux Cloud machines through the app's cloud actions (or the cmux VM API with no app: provision, exec, pause, delete), and drive a machine's own cmux-tui session from inside it. Use for cmux machine/vm/cloud tasks; backend implementation belongs to cmux-backend."
---

# cmux Cloud machines

Use this skill when a task involves a cmux Cloud machine. Machine terminals persist
when panes close or the Mac disconnects.

The Swift CLI's `cmux vm …` family (route, run, agent, dev, push, pull, tree, open
and the rest) was removed. What works now:

| Where | What works |
| --- | --- |
| Mac, app running | `cmux cloud start-chat --prompt TEXT --wait --json` (a Cloud chat and its reply, below), and the `cmux cloud <verb>` app actions: create, open, fork, snapshot, restore, resize, rename and kill machines, sign in, diagnostics |
| No app (CI, a headless agent) | `cmux machine` (`new`, `show`, `exec`, `pause`, `resume`, `rm` and more; `cmux vm` is its old name) against the cmux VM API with an API key: [provision, run, pause, delete](references/headless.md) |
| Inside a machine | the machine's `cmux`, a guest adapter over its cmux-tui daemon: the resource grammar (`cmux workspace list`, `cmux terminal current screen read`) plus guest verbs (`cmux self`, `cmux coderouter`, `cmux env`, `cmux layout`, `cmux notify`, `cmux open-url`) |

## Start a Cloud chat and read its reply: one command

```sh
cmux cloud start-chat --prompt 'Summarize README.md' --wait --json
```

It starts an agent chat (`--agent claude` by default, or `codex`, ...) on a Cloud
machine, sends the prompt and, with `--wait`, waits for the turn to end and answers
`reply` with `machine_id`, `machine_name`, `session_id`, `workspace_id` and
`tab_id`. The chat opens as a tab in the machine's workspace in the app, so
the person can read it. Without `--wait` it answers once the prompt is sent.

- Which machine: `--name NAME` takes the machine with that name, or creates it;
  `--target machine:vm-…` takes that machine. With neither it creates a new small
  machine with a new name (`chat-…`), one workspace per machine, so a chat never
  lands on a machine someone else uses.
- No folder is needed: without `--cwd` the chat starts in a new folder of its own under
  `~/chats` on the machine; `--cwd FOLDER` starts it in that existing folder instead;
  `--timeout SECONDS` bounds `--wait` (default 900).
- Follow-ups on the same chat, with `MACHINE_ID` and `SESSION_ID` from the answer (the
  answer's `follow_up` has them filled in):

  ```sh
  cmux cloud exec --target machine:MACHINE_ID --command 'cmux-tui acp send --no-wait SESSION_ID "next prompt"'
  cmux cloud exec --target machine:MACHINE_ID --command 'cmux-tui acp wait SESSION_ID --timeout 20'
  cmux cloud exec --target machine:MACHINE_ID --command 'cmux-tui acp last SESSION_ID'
  ```

  Each `cloud exec` stops after 25 s, so wait in 20-second slices until `wait` exits 0
  (2: the agent asks for a permission, answered in the chat's tab).
- Errors say what to do next: `cloud.signed_out` (run `cmux cloud sign-in`),
  `cloud.start_pending` (the machine is still coming up: run the same command again,
  its `details.again`, to keep waiting), `chat.permission_waiting`, `chat.wait_timeout`.
  Run from an agent chat, it starts at once, as from a terminal: nothing asks the
  person. Only when they turned off `cloud.agentsStartWithoutAsking` does the app
  ask first with a card in that chat (Start, Not now); `cmux agents dialog list` lists it.

`cmux cloud start-chat --help` has every flag.

## Start with discovery

```sh
cmux action list --category cloud
cmux action describe "cloud resize-machine"
cmux app capabilities
```

`action describe` prints the action's targets and arguments. Actions drive the app
the same way its palette and sidebar do. Run from the CLI or MCP, read actions answer
in the action result (`--json` prints it): `cloud exec` returns `exit_code`, `stdout`
and `stderr`, `cmux machine new` (the `cloud new-machine` action) the new `machine_id`, `machine-status` and the file
and listing actions their facts. They need the app, sign-in and its private tunnel.

## Machine lifecycle from the Mac

```sh
cmux cloud list-machines --json                           # machines (machine_id, target, status, owner)
cmux machine new                                          # prints its target and next steps (--json: machine_id, or pending)
cmux cloud new-workspace --json                           # a new cloud workspace on a new small machine of its own (machine_id, target; or pending)
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

Read [guest operations](references/guest.md) for guest auth, CodeRouter, layouts,
computer use on the machine's desktop (`agent-desktop`, baked into every desktop
image) and browser authentication. The machine's `cmux --help` is authoritative.

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

The Swift `cmux vm …` family is gone; today's `cmux machine` (old name `cmux vm`) is
the API client in [headless.md](references/headless.md). The old verbs' replacements are app actions:
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

- [Without the app](references/headless.md): `cmux machine` with an API key, from provision to delete.
- [Workflow recipes](references/agent-workflows.md): the supported paths for common tasks.
- [Command reference](references/commands.md): every cloud action and its arguments.
- [Guest operations](references/guest.md): inside-machine grammar, CodeRouter, desktop computer use (`agent-desktop`), notifications.
- [Sidebar parity](references/sidebar-parity.md): sidebar items and their actions.
- [Local workspace rules](../cmux-workspace/SKILL.md): presenting work without disrupting the caller.
