# Remote agent status in `ssh-tmux` mirrors

`ssh-tmux` mirrors have no local PTY for the remote agent and no remote cmux
socket. The status path therefore uses the tmux control stream that the mirror
already owns.

## Transport

On attach, the existing tmux control connection installs a versioned helper in
the remote user's data directory and makes it the default command for newly
created panes. The helper adds a launch wrapper for Claude and Codex. Each
wrapper captures the exact tmux socket, pane id, and a launch owner token in
every hook command, then writes a JSON value to the pane-scoped `@cmux_agent`
user option:

```text
SessionStart       {agent, state: idle}
UserPromptSubmit   {agent, state: working}
PermissionRequest   {agent, state: blocked}
Stop               {agent, state: idle}
SessionEnd         clear
```

`RemoteTmuxControlConnection` subscribes each pane with:

```text
refresh-client -B "cmux_agent_<pane>:%<pane>:#{@cmux_agent}"
```

The `%subscription-changed` value is parsed locally and forwarded through
`RemoteTmuxSessionChannel`. The channel checks pane ownership before fan-out,
so a shared/multiplexed host cannot publish one session's status into another
workspace.

The sidebar uses the existing `cmux.remote.agent:<agent>` status namespace and
per-panel lifecycle ownership already used by the SSH TUI projector. Statuses
are aggregated by mirrored tmux window and provider, so multiple panes do not
overwrite each other. Idle clears the lifecycle; working and blocked retain the
running or needs-input state.

## Codex trust and shared daemons

Codex 0.162 does not execute a session hook unless the exact normalized command
identity is trusted in its session flags. The launch wrapper supplies both the
session hook and its matching trust hash as `-c` arguments, without editing the
remote Codex configuration. A shared app-server therefore receives the same
pane-bound command context as a direct launch.

A shared app-server can execute a hook without the launching shell's
environment. The generated command contains the pane route literally, so it
does not use cwd matching and remains correct when multiple panes share a
directory. The owner token ignores late events from a previous invocation.

## Scope and limitations

- New panes use the managed default command. On attach, an existing pane is
  updated when it is an idle, recognizable shell at an empty prompt; running
  programs and panes with custom tmux `default-command` values are left alone.
  An already-running agent still needs to be restarted for launch-time hooks.
- A read-only home, missing Python 3, or a malformed install leaves no hook
  status for that launch.
- An agent already running when the mirror attaches does not emit SessionStart
  through the newly installed hook. Restarting it enables lifecycle status.
- This change covers both dedicated and multiplexed `ssh-tmux` control streams.
  The separate `cmux ssh` path is covered by the Codex launch-wrapper fix in
  PR #18792; this patch does not change that transport.

## Regression coverage

- `RemoteTmuxAgentStatusTests`: lifecycle parsing and malformed-value handling.
- `scripts/tests/test_remote_tmux_agent_helper.py`: exact pane routing, Codex
  trust arguments, pass-through commands, and stale-owner suppression.
- `RemoteTmuxControlParserTests`: quoted agent subscription.
- `RemoteTmuxSessionChannelTests`: pane-scoped fan-out on shared streams.
