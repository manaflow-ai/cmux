# Ghostty render worker architecture

The macOS app runs every active Ghostty Metal renderer in one supervised child
process. The app process still owns each terminal session and its authoritative
Ghostty terminal state. This boundary isolates Metal rendering and presentation
work. It does not move the complete terminal engine out of the app process.

## Process ownership

| Owner | Responsibilities |
| --- | --- |
| App process | AppKit and SwiftUI, shell child and PTY, authoritative Ghostty parser and terminal model, input and IME, accessibility and terminal queries, worker supervision, and final IOSurface assignment to a `CALayer` |
| Render worker | One Ghostty app, one manual-IO visual mirror per live terminal surface, active Ghostty renderer threads, Metal resources, and IOSurface production |

The app bundles a dedicated `cmux-ghostty-render-worker` command-line
executable under `Contents/Resources/bin`. The helper links only the render
worker package, Ghostty, and its graphics and transport dependencies. It does
not import or link AppKit, SwiftUI, or the app target. The app launches this
helper directly and supervises its lifetime.

The app creates the authoritative surface with Ghostty's external Metal
platform and a no-op present callback. It immediately marks that surface
occluded and its renderer unrealized. The authority keeps its PTY, parser,
terminal model, synchronous input behavior, and query APIs, but has no AppKit
presentation object or active Metal swap chain. The worker creates the mirror
with `GHOSTTY_SURFACE_IO_MANUAL` and
`GHOSTTY_PLATFORM_METAL_EXTERNAL`, then keeps its renderer realized only while
the corresponding pane needs renderer resources.

## Configuration and control

The app serializes its finalized effective Ghostty configuration with
`ghostty_config_serialize`. A monotonic configuration revision lets the worker
ignore stale replacements. The worker loads the serialized text into its own
Ghostty config before creating mirror surfaces.

Commands and acknowledgements use a versioned, binary-property-list protocol
over the child's standard input and output. Each payload has a four-byte length
prefix and a 16 MiB limit. The app's pipe writes are nonblocking, and AppKit or
PTY callbacks only enqueue work onto one ordered command lane. The main thread
never waits for the worker.

Each surface command carries a stable surface UUID and a monotonic surface
generation. Commands cover ordered PTY output, size and scale, focus,
visibility, color scheme, renderer realization, refreshes, preedit, pointer
state, selection clearing, and visual Ghostty binding actions. The worker
serializes libghostty calls on its engine queue. Surface and worker generations
make late commands, events, and frames harmless after replacement or restart.

## Terminal output mirroring

The authority installs its PTY tee in `ghostty_surface_config_s` before
`ghostty_surface_new` starts the IO thread. The callback copies every raw output
slice before the authority parser consumes it, assigns its modulo-`UInt64`
stream position, and enqueues it for the matching worker mirror.

The worker applies those bytes with `ghostty_surface_process_output`. It tracks
the next contiguous stream position, ignores already-applied overlap, and
reports a gap instead of silently applying out-of-order bytes. The mirror has
no shell child or PTY. Its manual-IO write callback discards terminal replies
because only the authority may write to the real session.

The output stream is parsed twice, once by the authority and once by the visual
mirror. This preserves synchronous terminal behavior and session survival, at
the cost of duplicate parser and terminal-model work.

## Frame transport and presentation

Ghostty renders into its normal Metal IOSurface targets in the worker. After
the GPU completes a frame, the external presenter callback transfers an
IOSurface Mach port to the app. The frame path does not copy pixel buffers and
does not use the control pipe.

The app creates a random bootstrap service name and a random 128-bit token for
the frame channel. Every Mach message carries the token, surface UUID, worker
generation, surface generation, frame sequence, and pixel dimensions. The
worker uses a zero-timeout Mach send. If the receive queue is full, it drops
that obsolete frame instead of blocking a Metal completion thread.

`GhosttyRemoteIOSurfaceLayer` accepts only a frame whose identity, generations,
strictly increasing sequence, declared dimensions, actual IOSurface dimensions,
and current expected pane size all match. Assigning the accepted IOSurface to
the layer is the remaining main-actor presentation step. The layer retains the
last accepted IOSurface and disables implicit content animations.

## Crash recovery

A worker exit invalidates that worker generation, but the layer keeps its last
frame visible. The authority surface, PTY, shell process, input path, and full
terminal state remain alive in the app process.

The next configuration or surface mutation starts a new worker generation. The
supervisor then asks every live authority for a recovery snapshot. Ghostty
atomically captures a bounded VT reconstruction of the newest terminal rows and
the exact next processed-output position. The new mirror applies the snapshot,
adopts that position, and then consumes queued output from the first
unrepresented byte. Overlapping queued output is trimmed, and other mutations
remain queued until resynchronization completes.

Initialization has a timeout and one automatic retry. A full or failed
nonblocking control write is treated as worker loss so the app can recover from
the authority instead of stalling a caller.

## Residual limitations

- The app process still owns the Ghostty PTY, parser, terminal model, input,
  accessibility, clipboard-related queries, and an unrealized local renderer
  control path. Parser CPU and terminal-model memory have not left the app.
- Each terminal is represented twice. The worker adds another parser, terminal
  model, font state, and active renderer, so total CPU and memory can increase
  even when app-process and main-thread contention decrease.
- All mirrors share one worker process. One worker failure temporarily freezes
  visual updates for every terminal, although their sessions continue and the
  last frames remain visible.
- Recovery reconstructs at most 4,000 physical rows and 8 MiB of VT data for a
  mirror. Older history remains authoritative in the app but is not included in
  the restarted mirror's visual reconstruction.
- The host main actor still handles input integration, pane geometry, and the
  final constant-time IOSurface-to-layer swap. This design removes active
  Ghostty Metal rendering from that process boundary, not all terminal-related
  work from the main thread.

## Code map

- `Packages/macOS/CmuxTerminalRenderTransport` defines the versioned control
  protocol, framed pipe channel, and authenticated Mach IOSurface transfer.
- `Packages/macOS/CmuxGhosttyRenderService` contains the supervisor client and
  AppKit-free worker runtime.
- `RenderWorker/GhosttyRenderWorkerMain.swift` is the dedicated worker
  executable entry point.
- `Packages/macOS/CmuxTerminal` owns the authority-to-mirror routing, atomic
  recovery snapshots, generation fencing, and remote presentation layer.
- `Sources/TerminalSurfaceRuntimeWiring.swift` installs the process-wide worker,
  configuration updates, event handling, and frame delivery.
- `ghostty/` contains the external Metal presenter, initial PTY tee, effective
  configuration serialization, and atomic VT-tail plus output-sequence APIs.
