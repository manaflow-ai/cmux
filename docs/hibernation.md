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
- no harness-owned background command (a Claude Code `run_in_background` shell, a Codex
  background terminal), background subagent or sub-session at work. A background task the
  daemon owns (below) does not count: it keeps running while the chat hibernates;
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

Only what acpmux spawned and holds for the agent is stopped: the agent's process and its MCP
sidecars, and only once the census found nothing else under it. Work that left the agent's process tree on purpose (a server started with `setsid`, a
daemon it detached) is out of scope by design. Nothing signals it, so it keeps running after the
chat hibernates.

Background tasks are never killed by hibernation, by design. Leo, 2026-10-27: "also when it
comes to hibernation...can't you hibernate the agent but not hibernate the bg tasks?" A
harness's own background shells cannot outlive their harness. On SIGTERM, Claude Code's exit
cleanup ends its `run_in_background` shells. On SIGKILL they keep running, but a resumed
`claude --resume` lists them as stopped and cannot stop them. Codex ends its background terminals
on any exit (`terminate_all_processes`, and its process handles kill their group on drop), and it
keeps their output in memory only. So a task that must outlive the agent runs under the daemon
instead:

- It starts with `_acpmux/bg/start` (the agent's MCP tools for it are a follow-up). The daemon
  starts a runner (`acpmux __bg-run`, `src/bg_run.rs`) in a session of its own, never in the
  harness's group. The runner starts the command as the leader of a new session.
- The task outlives the agent's hibernation, the agent's exit and a daemon restart. Its state is
  only `<ACPMUX_HOME>/bg/<chat>/`: the runner's record, a lock the runner holds while the task
  runs, its stop FIFO, and the task's output.
- Its output is bounded. Each segment holds 4 MiB, and at most two are kept (`<id>.out.<start>`,
  named by where each starts in the whole output), so a task keeps its newest 8 MiB.
  `_acpmux/bg/output` reads by offset in the whole output, returns the exact bytes (base64) and
  the text, and says how much is gone. `_acpmux/bg/list` shows each task's state and its last
  1 KiB.
- A woken agent finds its tasks by id. `_acpmux/bg/stop` writes one byte to the task's FIFO,
  which opens only while its runner holds it, so no pid is signalled. The runner then sends
  SIGTERM to the task's own group, then SIGKILL to the group 5 s later, so a stop takes 5 s.
  Only the runner signals that group, and only before it reaps the leader, which it reaps only
  once the pipe ends and a stop's SIGKILL went out. So output a child writes after the leader
  exited is kept, and a child that ignores SIGTERM is killed even with its output sent
  elsewhere. Purging a chat stops its tasks and removes their folder; a runner still there after
  the wait (20 s) keeps it. Stopping a chat keeps them, and a stopped chat starts none.
- A task whose spool failed (a full disk) says so in `outputError`: its output is incomplete.
- Only the chat's own agent (its proven caller token) and the person reach a chat's tasks.
- The task runs under `bash -c` (`/bin/sh` where there is no bash).
- A daemon-owned task never keeps a chat awake. A harness-owned background shell, a Codex
  background terminal and a background subagent still do, because hibernating would end them.

Sessions waiting on a person (a permission or a question) do not hibernate yet. Keeping only
the question for them is a follow-up.

## Measuring

`scripts/measure/acpmux-overhead.sh bench=hibernate` (fleet, `--class exclusive`) runs real
Claude Code and Codex against a stand-in model. It reports each chat's agent processes and RSS
after a turn, how many of them still run after 135 s idle, and the next prompt's time to its
first answer text. It reads a chat's processes from its host record, so it counts hosted
chats only. A chat whose agent runs directly under the daemon reads as unknown.
