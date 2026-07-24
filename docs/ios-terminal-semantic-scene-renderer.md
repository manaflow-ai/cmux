# iOS terminal semantic-scene renderer

## Goal

The iOS terminal must render the canonical Mac terminal with Ghostty's layout,
shaping, colors, cursor, links, selection, search highlights, IME, and image
semantics. It must not reconstruct terminal state by parsing a second VT byte
stream. A frame shown on iOS must identify one canonical terminal lifetime and
one iOS presentation lifetime, and stale work from an older lifetime must be
rejected before presentation.

## Root cause

The current remote rendering path has two terminal authorities:

1. The Mac Ghostty terminal exports an authoritative render grid.
2. `MobileTerminalRenderGridReplay` converts that grid back into synthesized VT.
3. iOS feeds the synthesized VT through a second Ghostty parser.
4. `GhosttySurfaceView` independently schedules parser work, grid export,
   Metal rendering, and Core Animation presentation.

The render-grid DTO cannot carry every terminal semantic. The VT reconstruction
also loses producer intent and makes iOS infer state that the Mac already knows.
Independent replay, viewport, geometry, recovery, and presentation state owners
can accept different generations of work. These are the shared causes of
spacing drift, misplaced cells, duplicated text, stale frames, and late
rerenders. Fixes confined to individual timing paths preserve that ownership
error.

The persistent terminal backend already removes the first half of the problem.
`cmuxd` owns one Ghostty terminal and emits bounded full or delta semantic
scenes. Ghostty's terminal-independent scene renderer consumes those scenes and
produces IOSurfaces with Ghostty's real font metrics, shaping, atlas, image, and
shader implementation.

## Ruled-out designs

### UIKit cell renderer

A UIKit renderer is transport-simple, but it would approximate Ghostty font
metrics and shaping. It would also require separate implementations for
ligatures, wide glyphs, image placement, decoration geometry, cursor behavior,
and custom shaders. It cannot meet renderer parity and would create another
permanent renderer authority.

### Mac pixel streaming

Streaming Mac-rendered pixels can preserve one sampled frame, but it ties visual
quality and latency to network bandwidth and Mac display scale. It cannot
provide local text selection, accessibility geometry, link hit testing, crisp
rotation or zoom, or low-latency cursor and IME behavior without a second
semantic channel. It is unsuitable as the primary terminal renderer.

## Selected architecture

The canonical backend emits Ghostty semantic scenes. iOS applies them to
Ghostty's terminal-independent Metal scene renderer and presents its retained
IOSurface directly.

```text
PTY
  -> cmuxd GhosttyTerminal
  -> per-iOS-presentation RenderScene encoder
  -> authenticated Iroh terminal-scene lane
  -> bounded scene decoder
  -> iOS Ghostty scene renderer
  -> retained IOSurface
  -> one Core Animation presentation owner
```

The byte lane remains a separately negotiated compatibility path for older
clients. A presentation uses either semantic scenes or VT compatibility for its
entire lifetime. It never feeds both into one view.

## State ownership

`cmuxd` owns:

- PTY reads and writes.
- The only mutable terminal parser and screen state.
- Terminal ID, runtime epoch, and content sequence.
- Per-presentation full/delta scene encoder caches.
- Terminal mode validation for key and mouse input.

The Mac mobile host owns:

- Same-account admission and terminal-scene capability advertisement.
- One bounded Iroh lane per mounted iOS presentation.
- Binary scene framing and input forwarding.
- The current resolved Ghostty renderer configuration generation.

One iOS scene-lane actor owns:

- Presentation ID and monotonically increasing generation.
- Lane reconnection and exact full-scene bootstrap.
- Terminal, content, presentation, and scene sequence fences.
- Resnapshot by closing and reopening after a gap, rejected delta, overflow, or
  terminal epoch change.

One iOS scene-render actor owns:

- The `ghostty_scene_renderer_t` handle.
- Serialized apply, configure, render, frame lease, and release operations.
- The active renderer epoch and matching identity fence.
- Animation renders only while Ghostty reports visible animation work.

One main-actor terminal view owns:

- Current pixel size and content scale.
- Exactly one installed IOSurface and its presentation transaction.
- Focus, keyboard, touch, selection, accessibility, and viewport requests.
- Release of the previous retained IOSurface after the replacement transaction
  commits.

No process-wide scene registry, parser, replay baseline dictionary, display
generation map, or recovery timer may become a second owner.

## Wire contract

The Iroh stream header adds a `terminalScene` lane. Its resource identifies the
canonical terminal. The lane declaration also carries the client-created
presentation ID and nonzero generation.

The Mac sends:

1. One bounded configuration envelope.
2. One full semantic-scene frame.
3. Contiguous delta frames for that exact terminal and presentation lifetime.

Every scene envelope carries:

- Protocol version and envelope kind.
- Terminal UUID and nonzero runtime epoch.
- Nonzero content sequence.
- Presentation UUID, generation, and nonzero presentation sequence.
- Canonical full or delta kind.
- Payload length and payload bytes.

The outer decoder limits configuration bytes, scene bytes, buffered bytes, and
envelope count before allocation. Ghostty validates the inner scene format and
its resource limits again.

The lane is intentionally full-first. iOS does not resume from a delta cursor
after a disconnect because a renderer cache is presentation-local and cheap to
recreate. A scene or identity rejection closes the lane, destroys the renderer,
advances the presentation generation, and reopens for a fresh full scene.

Input travels on the same bidirectional lane. Text, keys, mouse events,
selection, search, viewport, focus, and IME are typed operations. The backend
validates stateful encodings against its canonical terminal. Raw text framing
remains only for the old compatibility lane.

## Geometry and presentation

iOS sends physical width, physical height, and content scale when a presentation
opens or its drawable geometry changes. The Ghostty scene renderer calculates
columns, rows, padding, and cell metrics from the same resolved configuration
used by Mac rendering. The backend resizes the PTY only from an active
presentation geometry lease.

Geometry changes advance the presentation generation. Work from the prior
generation can finish, but identity checks discard it before it reaches the
layer. The first frame for a new generation must be full and sized for the new
pixel geometry. The existing frame stays visible until that replacement is
ready, preventing blank or mixed-size intermediate states.

Core Animation receives retained IOSurfaces. The scene-render actor releases the
Ghostty frame lease after retaining the IOSurface. The view releases the
previous retained IOSurface only after the replacement transaction commits.
This prevents Ghostty from mutating storage still visible on screen.

## Failure behavior

| Failure | Required behavior |
| --- | --- |
| Missing or rejected scene capability | Use the isolated compatibility renderer for that presentation lifetime. |
| Missing initial full scene | Show reconnecting state, close the lane, and reopen with a new generation. |
| Sequence gap or wrong identity | Never apply the frame; recreate the lane and renderer from a full scene. |
| Decoder or Ghostty resource limit | Close only the affected presentation and report a bounded error. |
| Lane backpressure | Drop the attachment, never an interior scene; the next lane starts with a full scene. |
| Renderer or GPU failure | Keep the last committed frame, destroy the renderer, and bootstrap a new generation. |
| App backgrounding | Stop animation work and preserve the last committed frame; reconnect if iOS invalidates transport or GPU state. |
| Terminal runtime epoch change | Reject all prior frames and start a new presentation generation. |

## Implementation stages

1. Add the bounded terminal-scene wire codec, lane declaration, identity checks,
   and full-first recovery tests.
2. Expose backend semantic-scene attachments through the Mac mobile host and
   advertise `terminal.semantic_scene.v1`.
3. Add the iOS Ghostty scene-render actor and IOSurface presentation view with
   deterministic lease and generation tests.
4. Route scene-capable mounts to the new view. Keep the existing Ghostty surface
   only behind the explicit compatibility capability.
5. Move key, mouse, focus, viewport, selection, search, link, accessibility, and
   IME operations onto typed backend commands.
6. Delete render-grid-to-VT reconstruction and the duplicated verified replay
   state for semantic-scene clients after compatibility coverage proves older
   hosts remain isolated.

## Acceptance

- ASCII, ligatures, emoji, combining marks, CJK, wide cells, ANSI styles, OSC
  colors, links, cursor forms, selection, search, IME, Kitty images, and custom
  shaders match Ghostty's Mac renderer for the same semantic scene.
- Resize, rotation, zoom, reconnect, background and foreground, full-screen TUI
  swaps, alternate screen transitions, and rapid output never show content from
  the wrong identity or generation.
- A deliberately dropped delta causes a full bootstrap without duplicated or
  stale text.
- One hundred rapid scene updates remain bounded and converge to the newest
  complete scene.
- Dormant terminals create no iOS renderer work.
- Runtime inspection finds one canonical terminal parser and one presentation
  owner for each scene-backed iOS terminal.
- Focused transport, decoder, renderer, and UI lifecycle tests pass, followed by
  isolated Simulator dogfood with screenshots and a recovery stress run.
