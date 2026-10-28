# Agent session hibernation

An idle agent chat (Claude Code, Codex, any ACP harness acpmux runs) hibernates: its agent
process and the MCP servers that agent started exit, and the chat stays as it is. Source:
`cmux-tui/crates/acpmux/src/hub/idle.rs`.

## When

A chat hibernates after 2 minutes idle (`hub::IDLE_CHILD`; `ACPMUX_IDLE_CHILD_SECS` overrides
it, `0` turns hibernation off). The chat may be open on screen. Idle means all of these:

- no turn running or waiting, and nothing queued;
- no permission or question pending, and no agent request (a file read, a terminal, a
  permission not shown yet) waiting on its answer;
- no automatic continuation waiting or starting;
- no background command, background subagent or sub-session at work;
- no start of the agent in progress;
- for a Claude chat, its turns are in Claude's store (a chat whose turns are not would wake as a
  new conversation);
- nothing was logged, typed or opened for the 2 minutes;
- nothing runs under the agent but its MCP servers (`hub/idle_census.rs`): a process it did not
  report, such as a dev server it left running, keeps it up, and so does a list of its
  processes that fails or is not whole.

Before it ends the agent, the idle exit handles every agent message already read, then checks
all of the above again.

## Waking

The next prompt wakes the chat. So does typing into it (`_acpmux/typing`) or opening it on
screen (`_acpmux/attach` shown, `_acpmux/view` visible). The agent resumes its conversation
(`claude --resume`, ACP `session/load`). The prompt is accepted and drawn at once, before the
agent is up. A hibernation and its wake add no row to the transcript. A wake that fails fails
its prompt the way any failed start does, with Retry. A hibernation survives a daemon restart
(`SessionMeta::hibernated_ms`).

Every hibernation logs `hibernated` (cause, how long the chat was idle, how long the exit took).
Every wake logs `woke` or `wake failed` (cause `prompt`, `typing`, `click` or `request`, how
long the start took, how long the chat slept).

## What is stopped, and what is not

Only what acpmux spawned and holds is stopped: the agent's process and its MCP sidecars, and
only once the census found nothing else under it.
Work that left the agent's process tree on purpose (a server started with `setsid`, a daemon
it detached) is out of scope by design. Nothing signals it, so it keeps running after the chat
hibernates.

Sessions waiting on a person (a permission or a question) do not hibernate yet. Keeping only
the question for them is a follow-up.

## Measuring

`scripts/measure/acpmux-overhead.sh bench=hibernate` (fleet, `--class exclusive`) runs real
Claude Code and Codex against a stand-in model. It reports each chat's agent processes and RSS
after a turn, how many of them still run after 135 s idle, and the next prompt's time to its
first answer text. It reads a chat's processes from its host record, so it counts hosted
chats only. A chat whose agent runs directly under the daemon reads as unknown.
