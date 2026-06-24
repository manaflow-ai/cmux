# Manual test plan — remote agent status (ssh-tmux, Option C + fallbacks)

Branch `feat-remote-tmux-agent-status`. The tagged dev build logs every Option C
checkpoint to `/tmp/cmux-debug-remote-agent-status.log` (DEBUG only).

## What each debug line means

Tail the log while testing:

```bash
tail -f /tmp/cmux-debug-remote-agent-status.log | grep -E 'remote\.agent|remote\.reflow'
```

| Log line | Means |
|---|---|
| `remote.agent.hookinstall host=… agent=claude exit=0` | cmux wrote the hook into the remote `~/.claude/settings.json` (codex line follows). `exit=0` = success; non-zero/`nil` = install failed (see stderr). |
| `remote.agent.sub pane=N value="{…}"` | tmux delivered a `@cmux_agent` change over the control stream — the hook fired on the remote and cmux received it. |
| `remote.agent.hook pane=N agent=claude state=working model=…` | cmux parsed the value into a status. `cleared` = empty value (chip removed). |
| `remote.agent.sidebar write value="Claude Code working · …"` | cmux wrote the sidebar row. This is what you should see in the UI. |
| `remote.reflow.classify … cmd="claude"` | (Fallback / Attempt 1) the foreground command was classified — drives the coarse "running" chip when no hook is reporting. |

## Pre-req

- Settings → Beta Features → **Remote tmux** enabled in the tagged app.
- A remote host with `claude` (and/or `codex`) and `tmux` + `python3`.

---

## Test A — Option C end-to-end (the real path), Claude

1. In the dev app: `cmux ssh-tmux <host>`.
2. **Expect in log:** `remote.agent.hookinstall host=<host> agent=claude exit=0`
   (and an `agent=codex` line). → hooks installed.
3. In a mirrored pane, **start a fresh `claude`** (must be launched *after* step 1
   — hooks load at agent startup).
   - **Expect log:** `remote.agent.sub pane=N value="{"agent":"claude","state":"running"…}"`
     then `remote.agent.hook … state=running` then `remote.agent.sidebar write`.
   - **Expect UI:** the workspace's sidebar row shows **“Claude Code running”**.
4. Submit a prompt.
   - **Expect:** `state=working` lines; sidebar → **“Claude Code working · <model>”**
     with a sparkles icon.
5. Let the turn finish (Claude returns to the prompt).
   - **Expect:** `state=idle`; sidebar → **“Claude Code idle · <model>”**, moon icon.

**Pass:** UI tracks running → working → idle, with the model shown.

## Test B — Option C, Codex

Same as Test A, but run `codex` instead. Expect `agent=codex` in the logs and
**“Codex …”** in the sidebar. (Codex hooks live in `~/.codex/hooks.json`.)

## Test C — fallback for an already-running agent (no hook)

1. Have a `claude` **already running** on the remote *before* you attach.
2. `cmux ssh-tmux <host>`.
   - That claude has no hook loaded → **no** `remote.agent.sub` lines for it.
   - **Expect:** the Attempt 1/2 fallback — `remote.reflow.classify … cmd="claude"`
     and a sidebar chip **“Claude Code running”**, upgrading to
     **“… working/idle · <model>”** from the transcript poll within a few seconds.

**Pass:** an already-running agent still shows a (coarser) chip.

## Test E — git branch + PR row (the “which PR is open” ask)

The same hook also publishes `@cmux_git` (branch + dirty + PR), which the mirror
maps onto the workspace's per-panel branch/PR sidebar rows — the rows a local
workspace shows but the local git/PR pollers skip for a remote mirror.

1. Attach + start a fresh agent in a repo dir with a GitHub remote (Test A).
2. Submit a prompt (fires the hook → backgrounded `git`/`gh` probe).
   - **Expect log:** `remote.git.sub pane=N value="{"branch":…,"pr":{…}}"` then
     `remote.git pane=N branch=… pr=#NNNN <state>`.
   - **Expect UI:** a **branch row** (`arrow.triangle.branch` + branch name) and a
     **clickable PR row** linking to the GitHub PR — same as a local workspace.
3. The PR row only renders when its branch matches the panel's branch (cmux
   invariant); the hook stamps both from the same payload, so they match.

**Pass:** branch + clickable PR link appear for the remote mirror.

**Notes / current limits:**
- `gh` must be installed + authed on the remote, and the cwd must be a git repo
  with a GitHub remote. No PR (or no `gh`) → branch row only, no PR row.
- The probe runs on hook events (prompt submit / stop / session start), not on a
  timer — so the branch/PR refresh when the agent acts, not on a `git checkout`
  done idly in the pane.

## Test D — clean teardown

1. Exit the agent (so its pane returns to a shell), or close the mirror window.
   - **Expect:** `remote.agent.hook … cleared` (Stop hook sets idle, then the chip
     clears when the agent is gone) and the sidebar row disappears.

**Pass:** no stale "running" chip left behind.

---

## Quick manual probe (no app) — sanity-check the remote half directly

Confirms the hook + tmux channel independent of cmux. Run from your Mac:

```bash
HOST=<host>
PANE=$(ssh "$HOST" 'tmux list-panes -t <session> -F "#{pane_id}"' | head -1)

# 1. control client subscribes (leave running in one terminal):
ssh "$HOST" "tmux -C attach -t <session>" <<< 'refresh-client -B "t:'"$PANE"':#{@cmux_agent}"'

# 2. in another terminal, simulate the hook:
ssh "$HOST" "tmux set -t $PANE @cmux_agent '{\"agent\":\"claude\",\"state\":\"working\",\"model\":\"opus\"}'"
# → the control client prints: %subscription-changed t … : {"agent":"claude",...}
```

If step 2 makes step 1 print `%subscription-changed`, the tmux channel works; any
failure in the app is then on the cmux side (check the debug log).

## Troubleshooting

- **No `hookinstall` line:** attach didn't reach a live master (auth prompt?), or
  the controller didn't run the install. Check earlier `remote-tmux:` log lines.
- **`hookinstall exit≠0`:** the remote lacks `python3`, or `~/.claude` isn't
  writable. The stderr is in the log line.
- **Install OK but no `remote.agent.sub`:** the agent was started *before* attach
  (no hook loaded — Test C), or it isn't running inside tmux (`$TMUX_PANE` unset →
  hook self-disables), or the agent build ignores `settings.json` hooks.
- **`sub` arrives but no `sidebar write`:** the JSON didn't parse — inspect the
  `value="…"` in the `remote.agent.sub` line against the `{agent,state}` contract.
