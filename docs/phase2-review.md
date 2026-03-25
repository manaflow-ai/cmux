# Phase 2 tmux Integration Review

Date: 2026-03-18
Reviewer: Codex

Reviewed inputs:
- `docs/tmux-integration-plan.md`
- `.claude/plans/snoopy-moseying-tide.md`
- `ghostty/src/termio/Termio.zig`
- `ghostty/src/termio/Exec.zig`
- `ghostty/src/termio/Manual.zig`
- `ghostty/src/termio/message.zig`
- `ghostty/src/termio/stream_handler.zig`
- `ghostty/src/terminal/tmux/viewer.zig`

## Executive Summary

Phase 2's overall direction is good:
- use Ghostty's existing tmux viewer as the protocol/state layer
- surface tmux layout changes to Swift
- give each tmux pane its own native Ghostty surface
- route tmux `%output` into pane surfaces

The biggest problems are not in the output path. They are:
- input routing via `send-keys -H`
- pane surface lifetime when the host I/O thread stores raw `*Termio`
- missing initial sync contract

My recommendation:
- keep the overall architecture
- do not implement `send-keys -H <hexblob>` as designed
- add a real lifetime/teardown handshake for registered pane surfaces
- define initial sync explicitly before coding Step 3/5

## 1. processOutput Cross-Thread Safety

## Verdict

Lock-wise, this is mostly fine.

`Termio.processOutput()` already takes `renderer_state.mutex` and is explicitly used from a separate read thread in exec mode. So the narrow question "can a non-main thread call `processOutput()`?" is answered by existing code: yes.

Relevant code:
- `Termio.processOutput()` locks `renderer_state.mutex` before touching terminal state.
- `Exec` read thread already calls `Termio.processOutput()` directly.

## What is actually risky

The real risk is not the mutex. The real risk is lifetime.

Your design stores raw `*Termio` pointers in `stream_handler.tmux_pane_surfaces`, then plans to:
- register them via an async termio message
- unregister them via another async termio message
- destroy pane surfaces on tmux exit or layout change

That leaves a use-after-free window:
- main thread queues unregister
- main thread destroys pane surface
- host I/O thread has not processed unregister yet
- tmux `%output` arrives
- host I/O thread dereferences stale `*Termio`

So the statement "single producer, single consumer = no race" is too optimistic. It avoids concurrent map mutation, but it does not solve pointer lifetime.

## Recommendation

Do one of these before implementing Step 3:

1. Two-phase teardown
- `unregister` is sent to host I/O thread
- host I/O thread removes mapping
- host I/O thread acks back
- only after ack does Swift destroy pane surface

2. Host-thread-owned registration tokens
- do not store naked `*Termio`
- store a registration record with explicit validity/liveness
- destruction flips validity first, then frees after host thread confirms no more routing

3. Retained object lifetime
- if Ghostty/cmux already has a safe retain/release story for surfaces, use that
- do not rely on raw pointer discipline alone

## Bottom line

`processOutput()` itself is thread-safe enough for this design.
The architecture is not lifetime-safe yet.

That is a blocking issue for Step 3/Step 6.

## 2. send-keys -H Hex Encoding

## Verdict

As currently designed, this is not correct.

The local tmux 3.6a man page says:
- `send-keys -H` expects each key to be a hexadecimal number for an ASCII character
- `send-keys -l` sends literal UTF-8 characters
- `send-keys -K` sends to the target client so keys are looked up in the client's key table

Your current design is:
- Ghostty encodes terminal input to bytes
- hex-encode the entire byte stream
- send one command like `send-keys -t %pane -H <hex>`

There are three problems with that:

1. `-H` is not a "raw byte stream" API
- it expects key arguments, not one concatenated blob
- even if you split per byte, the man page frames it as ASCII characters

2. Ghostty key encoding is terminal-byte-oriented, not tmux-key-oriented
- tmux as a GUI client needs key semantics, not just post-encoding bytes
- prefix handling, copy mode, tmux key tables, and tmux-native bindings all sit above "bytes written to a pane"

3. It risks bypassing tmux's own key interpretation
- you may get text insertion working
- but special keys, prefix, tmux bindings, and mode-specific behavior will be wrong or incomplete

## Recommendation

Do not make `send-keys -H <hexblob>` the Phase 2 input path.

Better options:

1. Proper tmux key-event mapping
- convert Ghostty input events into tmux key names where possible
- use `send-keys` with key names / literals intentionally

2. Split text input from special-key input
- plain text: `send-keys -l`
- special keys: named tmux keys
- this is still imperfect, but much less wrong than `-H <hexblob>`

3. If you want tmux-client semantics, investigate `-K`
- this may be closer to what a real GUI client wants
- but it changes the routing model and needs a deliberate design pass

## Bottom line

This is a blocking issue for Step 4.

The current input design is not ready to implement as written.

## 3. Initial Sync

## Verdict

This is currently under-specified, and that gap matters.

Your plan correctly notes:
- viewer already has a `Terminal` per tmux pane
- pane surfaces will have their own `Terminal`
- `%output` will keep them in sync after startup

But there is no precise startup rule for how a newly created pane surface catches up with the current viewer state.

If you skip this, new pane surfaces will start blank and only become correct after future `%output`.

If you try to do this with plain text only, it will not be faithful enough.

Plain text alone loses:
- attributes/colors
- cursor position
- scrollback structure
- modes
- hyperlinks
- any non-text terminal state

## Recommendation

You need one explicit bootstrap contract before Step 5:

1. Preferred: clone/snapshot terminal state in Zig
- host already has viewer pane `Terminal`
- create a host-side API that copies or serializes enough of that state into the new pane surface
- this is the cleanest architectural direction

2. Acceptable MVP fallback: text-only bootstrap, but call it what it is
- render current viewport text only
- accept that fidelity is partial
- do not describe this as a true initial sync

3. Better than text scrape: host-side "apply current pane snapshot"
- even if not a full deep clone, do it inside Zig against real terminal structures
- avoid Swift reconstructing terminal state from strings

## Bottom line

Initial sync is a design gap, not a small implementation detail.

I would not start Step 5 before choosing one of:
- real terminal snapshot/clone
- clearly degraded MVP bootstrap with known limitations

## 4. Overall Architecture

## Verdict

The overall architecture is reasonable.

What I like:
- using viewer as protocol/state authority
- surfacing `.windows` to Swift and querying pane topology
- keeping pane rendering in real Ghostty surfaces
- routing `%output` before/alongside `viewer.next()` so viewer and pane surface each maintain their own state

The "double Terminal" tradeoff is also fine for MVP. It is not elegant, but it is understandable and cheap enough to start with.

## What needs to change before implementation

Three things:

1. Fix input design
- replace `send-keys -H <hexblob>`

2. Add pane lifetime ownership protocol
- unregister must be acknowledged before destruction
- raw `*Termio` alone is not enough

3. Define initial sync
- decide whether this is true terminal-state bootstrap or limited viewport bootstrap

## Non-blocking notes

### `%output` routed to both viewer and pane surface

This is okay.

It is redundant, but intentional redundancy is fine here:
- viewer stays protocol-authoritative
- pane surface stays render/input-authoritative

### `termio.Message` 40-byte limit

This looks manageable.

Current code has an explicit size guard test on `termio.Message == 40 bytes`.
If `tmux_register_pane` is kept to a compact payload such as:
- `pane_id`
- pointer/handle

then it should fit.

Still, this is not something to assume. The existing size test should be updated and treated as the source of truth.

## Final Recommendation

Ready to proceed:
- Step 1 (`.windows` action)
- Step 2 (`tmux_panes()` query API)

Do not proceed as currently written:
- Step 4 (`send-keys -H <hexblob>`)

Do not proceed without an explicit design update:
- Step 3 / Step 6 lifetime handling
- Step 5 initial sync semantics

## Commit Readiness

Phase 2 is not ready to implement exactly as currently written.

It is ready for one more design pass with these concrete changes:
- replace input routing design
- add unregister/destroy handshake
- define pane bootstrap strategy

After that, the architecture is solid enough to build.
