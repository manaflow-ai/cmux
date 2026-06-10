# tmux control mode (native tmux in cmux)

cmux can render a local tmux session inside a **real Ghostty terminal** using
tmux's control mode (`tmux -CC`). Because the pane is a genuine local emulator
fed the tmux pane's byte stream, you get cmux-native text selection, ⌘F find,
and a real scrollbar over full local scrollback — none of which work with a
plain `tmux attach` inside a terminal (where tmux owns the screen).

## Usage

```
cmux tmux attach [session]
```

- Run it inside any cmux terminal. That terminal is **replaced in place** (same
  pane, same tab — no new tab) with a native view of the tmux session.
- `session` is optional. With a name, cmux attaches it or creates it
  (`new-session -A`). Without a name, it attaches the most recent session.
- tmux-style abbreviations work: `cmux tmux a`, `cmux tmux at`, … all mean
  `attach`.
- You never type `tmux -CC` — cmux runs it for you as a hidden gateway.

Options: `--workspace`, `--surface`, `--window`, `--focus`. By default the target
is the calling surface (`$CMUX_SURFACE_ID`).

### Detaching

- **Ctrl-b d** detaches (cmux intercepts the tmux prefix and sends
  `detach-client`). The tmux session keeps running; the pane reverts to a shell.
- Exiting the tmux session (or the pane's program exiting) also reverts.
- The tmux prefix is hardcoded to the default **Ctrl-b**. Any other prefixed key
  is passed through to the pane literally (so Ctrl-b still works for unmapped
  chords).

### What about other tmux chords?

Window/pane chords (`Ctrl-b c`, `Ctrl-b %`, `Ctrl-b "`, etc.) are intentionally
**not** mapped: in cmux you use cmux's own splits and tabs for layout, and tmux
is just the persistent session. Only `Ctrl-b d` (detach) is special-cased.
Copy/scroll chords are unnecessary because scrollback, selection, and find are
all native.

## How it works

```
cmux tmux attach           (CLI verb)
  -> tmux.attach RPC        (Sources/TerminalController.swift)
  -> Workspace.attachLocalTmuxControlMode -> respawnTerminalSurface(controlModeSession:)
       (in-place takeover: same pane+tab id)
  -> TerminalSurface manual-IO Ghostty surface (io_mode = GHOSTTY_SURFACE_IO_MANUAL)
       feed: session bytes -> ghostty_surface_process_output
       input: io_write_cb  -> session.sendInput
  -> TmuxControlModeGateway (Packages/CmuxTmuxControlMode)
       runs `tmux -CC <target>` on a PTY (tmux requires a tty)
       parses the control protocol, resolves the active pane,
       capture-pane snapshot + live %output, send-keys for input,
       refresh-client for sizing, Ctrl-b d -> detach-client
```

Key points:

- **Manual-IO Ghostty surface.** The first non-iOS use of cmux's manual IO
  backend. Native selection / find / scrollbar / scrollback are PTY-independent
  surface features, so they work as soon as bytes flow into the surface.
- **PTY gateway.** `tmux -CC` calls `tcgetattr` on its streams and exits on
  plain pipes, so the gateway runs tmux on a pseudo-terminal and reads/writes
  the master end.
- **Content/phase response matching.** tmux emits a spontaneous `%begin/%end`
  block on entry, so the gateway resolves the pane by recognizing the
  `list-panes` output rather than by positional command order.
- **Snapshot.** On attach, `capture-pane -p -e -J -S - -E -` provides the full
  history (iTerm2's model); trailing blank rows and the trailing newline are
  trimmed so content anchors at the top, and pre-snapshot live output is dropped
  (it is already in the snapshot) to avoid a duplicate prompt.

### Code map

- `Packages/CmuxTmuxControlMode/` — the protocol core (parser, encoder, session
  orchestration, PTY gateway, `ControlModeSessionSource`). Pure + unit-tested.
- `Sources/GhosttyTerminalView.swift` — manual-IO surface + control-mode glue.
- `Sources/Workspace.swift` — `attachLocalTmuxControlMode` /
  `respawnTerminalSurface(controlModeSession:)` (in-place takeover + revert).
- `Sources/TerminalController.swift` — `tmux.attach` V2 RPC.
- `CLI/cmux.swift` — `cmux tmux attach` verb.

## Revert behavior: exact original shell preserved

On attach, the original terminal surface is **stashed alive (hidden), not
killed** — its shell, scrollback, history, and cwd keep running. A new
control-mode panel is bound to the **same bonsplit tab** (no new tab; only the
cmux panel behind the tab changes, via `surfaceIdToPanelId`). On detach the
control-mode panel is torn down and the original is restored into the same tab,
intact — it feels like tmux was a foreground program. This is a cmux-only
in-place panel swap (`attachControlModeBySwap` / `restoreOriginalAfterControlMode`
in `Sources/Workspace.swift`); it needs no bonsplit changes because the tab is
reused and SwiftUI re-renders the new panel after the mapping is re-pointed.

If the tab is closed while a control-mode session is active, the stashed
original is torn down too (`discardControlModeStashIfNeeded`) so it is not
leaked. The stash lives only in memory, so it does not survive an app restart
(see Session restore below).

## Session restore (planned)

tmux sessions survive a cmux restart because the tmux server is a separate
process. cmux should restore a control-mode surface by re-attaching:

1. Persist the control-mode target with the surface in `SessionPersistence`
   (a `tmuxControlModeTarget` field alongside the existing terminal surface
   state), set when `attachLocalTmuxControlMode` runs.
2. On restore, if a surface carries a control-mode target, re-run
   `attachLocalTmuxControlMode` for it instead of spawning a shell — but only if
   that tmux session still exists (otherwise fall back to a shell so a dead
   session does not leave a blank surface).
3. Pair this with the exact-original-shell preserve work so the restored layout
   matches: the surface comes back as the tmux view, revertible to a shell.

Until this lands, a restored cmux window brings back a normal shell in the
pane; the tmux session is still alive and can be reattached with
`cmux tmux attach <session>`.

## Limitations (P1)

- Multi-pane tmux *windows* render the active pane only; switching panes inside
  one tmux window is a follow-up.
- Prefix is the default Ctrl-b only (not read from `~/.tmux.conf`).
- Remote (SSH) and iOS use the same renderer but different session sources;
  those are later phases (see `plans/feat-control-mode-terminals/DESIGN.md` in
  the cmuxterm-hq control repo).
