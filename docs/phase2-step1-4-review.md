# Phase 2 Step 1-4 Review

Date: 2026-03-18
Reviewer: Codex

Scope reviewed:
- `ghostty/src/apprt/action.zig`
- `ghostty/src/apprt/surface.zig`
- `ghostty/src/Surface.zig`
- `ghostty/src/termio/stream_handler.zig`
- `ghostty/src/termio/message.zig`
- `ghostty/src/termio/Thread.zig`
- `ghostty/src/apprt/embedded.zig`
- `ghostty.h`
- `Sources/GhosttyTerminalView.swift`

## Executive Summary

Step 1-4 has a good core shape:
- new tmux actions/messages are mostly clean
- `.windows` wiring is in the right place
- `%output` routing before `viewer.next()` is the right default
- the `termio.Message` size guard is still in place

The main problems are:
- initial sync uses `dumpString` and then feeds plain text into `processOutput()`
- unregister ack is keyed only by `pane_id`, but pane IDs can be reused
- `send-keys` improved compared to the old `-H` idea, but the current literal/key-name split is still not robust enough for a real tmux GUI client

## Findings

### 1. High: initial sync via `dumpString` -> `processOutput()` is semantically wrong

Current implementation:
- `tmuxRegisterPane()` looks up the viewer pane terminal
- calls `screen.dumpString(...)`
- feeds the resulting plain text into `pane_termio.processOutput(dump)`

Relevant code:
- `stream_handler.zig` `tmuxRegisterPane()` initial sync path
- `Screen.dumpString()` emits plain formatted screen text, not a replayable terminal state stream

Why this is a problem:
- `dumpString` is a rendered text dump
- `processOutput()` expects terminal output bytes
- feeding plain text back into a terminal does not reconstruct:
  - attributes/colors
  - cursor position
  - modes
  - hyperlinks
  - scrollback structure
  - alternate-screen state
  - wrapped-line semantics beyond visible text

So this is not just "lower fidelity". It is the wrong data model.

What will happen in practice:
- panes may look roughly right for simple shell prompts
- but anything richer than plain text will drift immediately
- initial cursor/mode state will be wrong

Recommendation:
- do not merge this initial sync as the long-term path
- replace it with one of:
  1. a true host-side terminal snapshot/clone into the pane surface
  2. a clearly-degraded MVP bootstrap that is explicitly documented as text-only and temporary

Blocking status:
- blocking for the "native Ghostty surface per pane" goal

### 2. High: unregister ack keyed only by `pane_id` is not safe

Current implementation:
- unregister removes `pane_id` from `tmux_pane_surfaces`
- then sends `tmux_pane_unregistered(pane_id)` as the destroy ack

Relevant code:
- `stream_handler.zig` `tmuxUnregisterPane()`
- `action.zig` / `surface.zig` / `Surface.zig` action/message plumbing

Why this is a problem:
- `pane_id` is not guaranteed to be a globally unique lifetime token
- Ghostty's own tmux viewer tests explicitly mention reused pane IDs:
  - "Uses same pane IDs 0,1 - they should be re-created since old panes were cleared"

That means this race is possible:
1. old pane `1` unregisters
2. tmux session/layout changes
3. new pane `1` appears and gets registered
4. delayed ack for old pane `1` arrives
5. Swift destroys the new pane `1` by mistake

Recommendation:
- ack must carry more than `pane_id`
- use at least one of:
  1. generation / registration token
  2. surface identity
  3. host-assigned opaque registration ID

Blocking status:
- blocking for two-phase teardown correctness

### 3. Medium: `send-keys` split is better than `-H`, but still not robust enough

Current implementation:
- `key_type == 0` => `send-keys -l -t %pane "<text>"`
- `key_type != 0` => `send-keys -t %pane <key_name>`

What is better now:
- this is better than the earlier `-H <hexblob>` design
- it acknowledges tmux has separate notions of literal text vs key names

What is still wrong or incomplete:

#### Literal path

The current quoting only escapes:
- `"`
- `\`

That is not a general serialization for arbitrary user input.

Examples that are still problematic:
- embedded newline
- carriage return
- control bytes
- strings that should not be routed as `-l` text at all

If the pane surface ever sends anything beyond plain text, this path becomes fragile.

#### Key-name path

This path is only correct if the caller is already producing valid tmux key names.

That means:
- no terminal-encoded escape sequences here
- no "already-encoded by Ghostty terminal" bytes
- actual tmux key names only

So the architecture still needs a real input-mapping layer.

The remaining design question is:
- where do we convert Ghostty input events into tmux key names vs literal text?

Right now that layer is not defined in this patch.

Recommendation:
- keep the `literal vs key name` split
- but do not treat this Step 4 implementation as finished
- add an explicit mapping contract in Swift/Zig before wiring real input

Blocking status:
- medium for Step 4 itself
- becomes high once real interactive typing is wired

## Point-by-Point Review

## 1. ABI: action / message / surface message additions

Overall this looks okay.

What looks good:
- new action tags are append-only
- `action.zig` still uses enum/header sync checks
- `tmux_pane_unregistered` payload is a simple extern struct
- `tmux_windows_changed` is void, so no extra union payload complexity
- `termio.Message` still has an explicit `@sizeOf(Message) == 40` test

No major ABI concern from Step 1 itself.

The real issue is not ABI shape, it is the teardown token (`pane_id`) being too weak semantically.

## 2. `%output` routing position

This is in the right place.

Current position:
- intercept `%output`
- route to registered pane surface
- then pass the same notification into `viewer.next()`

I agree with that ordering.

Why it is right:
- pane surface sees the raw pane output immediately
- viewer still maintains its own protocol/state model
- the duplication is intentional and understandable in this MVP

I do not see a reason to move `%output` routing after `viewer.next()`.

## 3. Initial sync (`dumpString`)

This is the weakest part of the current implementation.

`dumpString` is fine for:
- debug output
- text extraction
- screen inspection

It is not fine for:
- reconstructing a live terminal surface

So if this merges, it should be merged as a temporary bootstrap hack, not as the architecture we plan to keep.

## 4. send-keys literal vs key name split

Directionally correct, not complete.

The split itself is good:
- plain text and special keys should not be encoded the same way

But the actual boundary is still missing:
- who decides literal vs key name?
- what input types are allowed on each path?
- what happens to Enter, arrows, modifiers, paste, bracketed paste, IME commit text?

That needs to be specified before Step 4 can be called done.

## 5. Two-phase teardown ack flow

The existence of an ack is good.

That was the right architectural move.

But the ack payload is not strong enough.

Two-phase teardown should identify:
- which registration is being removed
- not just which pane ID happened to be involved

So the flow is now structurally correct, but still logically unsafe.

## Non-blocking Notes

### `tmux_windows_changed` as a void action

This is fine for now.

Querying pane topology through `ghostty_surface_tmux_panes()` is a reasonable design.

### `termio.Message` payload size

This looks fine.

`tmux_register_pane` is compact:
- `usize pane_id`
- `*Termio pane_termio`

That should fit comfortably under the existing 40-byte union cap, and the size test remains present.

### Swift debug handler

No issue.

The current `TMUX_WINDOWS_CHANGED` debug handler is minimal and appropriate for this step.

## Final Recommendation

Step 1 is basically fine.
Step 2 is basically fine.
Step 3 is not safe to ship until:
- initial sync is redesigned
- unregister ack is strengthened

Step 4 is improved, but not complete:
- keep the split
- redesign the real input mapping before calling it done

## Commit Readiness

Not ready to commit as-is.

I would block on:
- initial sync using `dumpString` as replay input
- `tmux_pane_unregistered(pane_id)` as the only teardown ack identity

I would mark as follow-up but not immediate blocker:
- input mapping contract behind `ghostty_surface_tmux_send_keys()`
