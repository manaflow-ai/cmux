# Priority by interactivity

Leo, 2026-11-24: "i want all our resizing at any cpu to be able to happen in lockstep. the agent pane, chromium,
terminal, the relevant ui elements like the top right buttons. hm. isn't there a thing where we can dynamically
adjust priorities of things based off of how interactive they are? huh. maybe we need to absolutely do that far
better far more often and examine other places where we could actually put certain things higher, certain things a
bit lower."

One policy, in Rust: `cmux-tui/crates/cmux-interactivity`.

- `InteractionState`: `note(kind, now)` for Drag, Typing, Scroll, Focus; `is_interacting(now)`. A kind is active for its
  decay after its last note (Drag 400 ms, Typing 500 ms, Scroll 300 ms, Focus 300 ms). The decay is the only way back:
  no timer, no loop, nothing to stop, nothing can stay lowered.
- `policy(class, state, now) -> Qos`, a pure table:

| WorkClass | idle | interacting |
|---|---|---|
| Input, Frame | user-interactive | user-interactive |
| FocusedPane | user-initiated | user-interactive |
| VisiblePane | default | user-initiated |
| BackgroundPane | utility | background |
| AgentOutputParse | default | utility |
| Index, Sync | utility | background |
| Maintenance | background | background |

- `apply_current_thread` / `Scoped`: macOS `pthread_set_qos_class_self_np`; Linux the thread's nice (lowered only when
  the thread can be put back: root or RLIMIT_NICE), restored on drop. `lower_current_thread_for_life` (output cleanup,
  premigration) is one way: nice 19 even unprivileged, never put back.
- A terminal view's `resize-attached-view` (window live resize, divider drag) notes a drag without marking the
  connection, so lower classes yield while the pointer moves.
- C ABI (`cmux-app-ffi`, `include/cmux_interactivity.h`): `cmux_interactivity_note(kind)`,
  `cmux_interactivity_is_interacting()`, `cmux_interactivity_qos(class) -> int` (macOS `qos_class_t` raw value, -1 for
  an unknown class). The daemon and the app are separate processes with separate states: the daemon learns of a drag
  from the resize commands of the drag's transaction, the app notes what it sees itself.

## Audit

"Unmeasured" rows were not run: no fleet Mac measurement was taken for this PR (qos-load-bench needs
`cmux-ci run --class exclusive --measurement`).

### Rust, wired in this PR

| Place | Before | After | Number |
|---|---|---|---|
| `server/cmd_panes.rs` `set-split-ratio` / `set-viewport-pane-width` in a drag transaction, `set-layout-sizes` (always a transaction), via `server/input_qos.rs::note_drag` | connection threads stayed default QoS; resize did not mark person input | marks the connection like a key (3 threads to user-interactive), notes Drag (400 ms) | unmeasured |
| `mux/journal_maintenance.rs` maintenance tick (journal compaction, retention, ledgers) | default QoS | kept at default: the tick holds the workspace registry lock (a full VACUUM in the auto-vacuum migration) that layout commits take, and a demoted holder delays the resize reply under load (priority inversion). Demote only off-lock work once it is split out | not changed |
| `mux/journal_maintenance.rs` index backfill slice | default QoS (rate limited to a fifth of a core) | kept at default, as the tick: a slice holds the same registry lock | not changed |
| `mux/output_cleanup.rs`, `workspace_registry/premigrate.rs` | each had its own copy of "background + idle IO" | one shared `lower_current_thread_for_life` (`Maintenance`) | none (same behaviour) |

### Rust, set today and left as is

| Place | Class today | Proposed |
|---|---|---|
| `server/input_qos.rs` connection threads, keys | user-interactive, sticky once marked | `Input`; stays sticky (resize now marks it too) |
| `acpmux/src/qos.rs` `Tier::Background` / `OnScreen` / `background_thread` (event journal checkpointer) | background / user-initiated (scoped) | route `background()` through `Scoped` + `Maintenance`; `OnScreen` is `VisiblePane` |
| `acpmux/src/cpu_class.rs` agent harness (nice +11, PRIO_DARWIN_BG toggle) | utility-ish clamp for the whole process | `AgentOutputParse` is the daemon's parsing only; the harness is a process, not a thread, so it stays on `cpu_class.rs`; consult the daemon's state for the toggle only when the daemon is told (not wired: acpmux is a separate process with no connection to the app's note) |
| `acpmux/src/daemon_priority.rs` | daemon at default | unchanged: replies wait on it |
| `cmux-git/src/run.rs:254` child git at DARWIN_BG | background always | `Maintenance` for background refreshes; a git the focused pane waits for should be `FocusedPane` (not changed) |
| `terminal_host_runtime` terminal-host-parser, pty readers | default | per-terminal: `FocusedPane` for the focused terminal, `VisiblePane` / `BackgroundPane` otherwise. Not wired: needs the focused pane id on the parser thread; the largest remaining win for lockstep resize |
| `journal_ingress.rs`, `journal_hooks.rs` threads | default | `AgentOutputParse` / `Sync`. Not wired |
| `terminal_host_runtime` `terminal-host-parser` and `terminal-host-pty` threads (wired, second commit) | default | per-host `Follower`: `FocusedPane` (user-interactive) while this host process was typed into or resized within the decay, `VisiblePane` (default) otherwise. A terminal host is its own process with its own interaction state, so the daemon does not lower the other panes' hosts; a drag resizes every affected host, so all of them rise together. Automation's writes also note Typing (the host cannot tell the person's keys apart) |

### Swift (the lane owner wires; no Swift changed here)

| Place | Before | Proposed |
|---|---|---|
| `WorkPriority` table (`CmuxNextWakeups/WorkPriority.swift`) | static: input/frame -> userBlocking (.userInitiated GCD) | static levels stay for ordinary work; ask `cmux_interactivity_qos(class)` for the dynamic classes |
| Divider / window / sidebar drag handlers | no note | `cmux_interactivity_note(0)` per drag event |
| Key handling, scroll | no note | `cmux_interactivity_note(1)` / `(2)` |
| Pane focus change | no note | `cmux_interactivity_note(3)` |
| `TerminalSession.swift:210` writer task `.userInitiated` | fixed | `Input` (user-interactive) |
| `TerminalSession.swift:431,436` `.utility` | fixed | `BackgroundPane` |
| `AgentPaneModel+Attach.swift:51,79,109` | utility / userInitiated | `AgentOutputParse` for the parses; `Frame` for first page |
| `CEFRuntime.swift:276,300,414,452` | userInitiated / utility | launch prep stays; no per-frame work here (Chromium resize is in the compositor) |
| `DaemonBridgeStream.swift:22,52` | userInitiated | `Input` (the line a frame waits for) |

## How to verify

`scripts/measure/qos-load-bench.sh` on a fleet Mac with a resize in flight (`cmux-ci run --class exclusive
--measurement --script scripts/measure/qos-load-bench.sh --ref SHA`). Compare resize frame-time p95 with and without
the daemon's drag note under N busy threads.
