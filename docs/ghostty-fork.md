# Ghostty Fork Changes (manaflow-ai/ghostty)

This repo uses a fork of Ghostty for local patches that aren't upstream yet.
When we change the fork, update this document and the parent submodule SHA.

## Fork update checklist

1) Make changes in `ghostty/`.
2) Commit and push to `manaflow-ai/ghostty`.
3) Update this file with the new change summary + conflict notes.
4) In the parent repo: `git add ghostty` and commit the submodule SHA.

## Current fork changes

The submodule pinned by this branch is `3da10da73`, the head of
https://github.com/manaflow-ai/ghostty/pull/200. It reports a terminal outcome
for every accepted tokened iOS render, rejects renderer-thread requests that
iOS external-drain mode cannot consume, and exposes a nonblocking prompt reveal
operation. The pin includes the prior fork changes below, including VT
formatter cursor restoration at `f76c132e5`, VT stream-boundary visibility at
`9513174f2`, and Hangul canonical font resolution at `3fbdd078d`.

### iOS tokened render disposition and nonblocking prompt reveal

- Pull request:
  - https://github.com/manaflow-ai/ghostty/pull/200
- Commits:
  - `6b221bd26` (ios: report tokened render dispositions)
  - `e96f2fa1a` (refactor: simplify render failure callback)
  - `531e49bd6` (ios: make prompt scroll nonblocking)
  - `d13061b27` (test: cover terminal render delivery gaps)
  - `3da10da73` (fix: guarantee tokened render disposition)
- Files:
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/renderer.zig`
  - `src/renderer/Thread.zig`
  - `src/renderer/generic.zig`
  - `src/renderer/metal/Frame.zig`
  - `src/renderer/metal/IOSurfaceLayer.zig`
  - `src/renderer/opengl/Frame.zig`
  - `src/termio/Termio.zig`
- Summary:
  - Pairs the existing exact-frame presentation callback with discarded and
    backend-failed outcomes, including layer-size and surface-generation
    rejection after GPU completion.
  - Rejects asynchronous tokened requests on iOS, where external-drain mode
    does not service the renderer-thread request slot, and terminally fails a
    request accepted across another platform's drain-mode transition.
  - Releases delivery gates even when a host omits the optional failure
    callback, while preserving explicitly null callback userdata.
  - Adds a try-only scroll-to-bottom operation so iOS prompt reveal retries on
    its display driver instead of blocking the output queue on Ghostty state.
- Conflict note:
  - Preserve one terminal disposition for every accepted token. If upstream
    changes Metal layer assignment or external-drain ownership, keep iOS
    submissions on the external driver and retain the post-GPU discard signal.
- Artifact:
  - https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-3da10da73ae848c0310e3e0f0cb29e509c2f6963-crashsubdir-cmux-crash-sentry-off-v1
  - SHA-256 `6a02a2ec3794de79a02af993083292a89517d2533eb20c746deca377f23456bd`
    is pinned in `scripts/ghosttykit-checksums.txt`.

### VT formatter cursor restoration after margins

- Pull request:
  - https://github.com/manaflow-ai/ghostty/pull/191
- Commit: `533c27ae1` (Preserve saved cursors during formatter replay)
- File: `src/terminal/formatter.zig`
- Summary:
  - Restores the active cursor after terminal-wide state during VT formatter
    replay and derives CUP coordinates from the emitted margins and origin mode.
  - Preserves application-owned saved cursors instead of using DECSC/DECRC as
    replay scratch state.
  - Fixes the formatter replay mismatch reported by the cmux Valgrind tests.
- Artifact:
  - https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-f76c132e526f124fe4aaebd39f516751656844bc-crashsubdir-cmux-crash-sentry-off-v1
  - The hosted build published the 129,284,050-byte archive and verified SHA-256
    `af9f8f12e6f41ffe00b5b65f150bb887b19dc752e47d20d3c351696c803509af`,
    which is pinned in `scripts/ghosttykit-checksums.txt`.

### Hangul NFC/NFD canonical font resolution

- Pull request:
  - https://github.com/manaflow-ai/ghostty/pull/185
- Commits:
  - `0316a8de8` (test: NFC and NFD Hangul must resolve the same font face)
  - `3fbdd078d` (font: resolve NFD Hangul clusters via canonical composition)
- Files:
  - `src/font/hangul.zig` (new)
  - `src/font/main.zig`
  - `src/font/shaper/run.zig`
  - `src/font/shaper/coretext.zig` (test)
- Summary:
  - Font selection keyed on the raw stored codepoints of a grapheme cluster,
    so a decomposed Hangul cluster queried the resolver with its leading jamo
    while the equivalent precomposed syllable queried with the syllable
    codepoint, selecting different fallback faces (and bypassing
    `font-codepoint-map` entries for U+AC00-U+D7A3) for canonically
    equivalent text.
  - `src/font/hangul.zig` implements the algorithmic Hangul canonical
    composition from The Unicode Standard ch. 3.12 (L+V, L+V+T, and LV+T
    clusters over the modern jamo ranges). `RunIterator.indexForCell`
    resolves the face through the composed codepoint first, so both
    encodings produce the identical resolver query.
  - Terminal cell contents and shaper input are unchanged: copy/paste of NFD
    text still returns the original NFD codepoints, and CoreText/HarfBuzz
    compose the cluster during shaping when the face carries the precomposed
    glyph.
- Conflict note:
  - Upstream tracks the same defect in
    https://github.com/ghostty-org/ghostty/discussions/4163. If upstream
    lands its own cluster-level or normalization-based resolution, prefer
    the upstream mechanism and drop `src/font/hangul.zig` plus the
    `indexForCell` hook, keeping the `coretext.zig` regression test to prove
    the behavior survives the merge.
- Fixes:
  - https://github.com/manaflow-ai/cmux/issues/9583
- Artifact:
  - https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-3fbdd078dfc499134710d3cf9ce2c5e06fa101aa-crashsubdir-cmux-crash-sentry-off-v1
  - SHA-256 `e8ce9217b32486f8070600b673d9a25e7270dcca9f5565781684f92ffb2f7eb5`
    is pinned in `scripts/ghosttykit-checksums.txt`.

### VT stream-boundary visibility

- Commit: `11aa609d7` (Expose safe VT stream snapshot boundary), reapplied
  on fork main as `9513174f2`
- Files: `include/ghostty/vt/terminal.h`, `src/terminal/c/terminal.zig`,
  `src/lib_vt.zig`
- Summary:
  - Exposes a read-only libghostty query that reports whether the VT stream
    parser has no incomplete escape sequence buffered.
  - Lets cmux cut a distributed terminal snapshot only at a replay-safe byte
    boundary, while retaining later raw PTY bytes for each smart client.
- Artifact:
  - https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-11aa609d75dec882ef2f83171e2cbe887aeddbc5-crashsubdir-cmux-crash-sentry-off-v1
  - SHA-256 `1a4acbcc9e0e5b20c0b4dad6660d0c08546a5d36192053834df960144fa8fdb9`
    is pinned in `scripts/ghosttykit-checksums.txt`.

The renderer line was reviewed in
https://github.com/manaflow-ai/ghostty/pull/168, following the merged
https://github.com/manaflow-ai/ghostty/pull/153,
https://github.com/manaflow-ai/ghostty/pull/165, and
https://github.com/manaflow-ai/ghostty/pull/166,
https://github.com/manaflow-ai/ghostty/pull/167, then integrated by
https://github.com/manaflow-ai/ghostty/pull/169. The combined head adds
lossless hidden-tab renderer reclamation, forced renderer rebuild
transactions, shared custom Metal pipelines, compile-attempt-owned failure
backoff, one observation owner per native tab group, and bounded app-mailbox
turns. Retry timers validate lifecycle generations immediately before xev
reset, so a stale cross-thread handoff cannot replace a fresh 250 ms deadline.
The seven PRs landed in merge commits `1e86b46e2`, `4dab6fd6c`,
`2fc66ed15`, `3c1b75d25`, `c467d389c`, `64d7fca66`, and `4d6f0014f`.
The final font integration landed in merge commits `23003282d` and
`36a46414a`.

### Cached macOS unified loggers

- Pull request:
  - https://github.com/manaflow-ai/ghostty/pull/177
- Commits:
  - `a019bcab2` (test: skip formatting for disabled macOS logs)
  - `ee691e86b` (fix: cache and gate macOS loggers)
- Files:
  - `pkg/macos/os.zig`
  - `pkg/macos/os/log.zig`
  - `src/main_ghostty.zig`
- Summary:
  - Gives each compile-time Ghostty log scope one lazily initialized,
    process-lifetime `os_log_t` through `dispatch_once_f`, replacing per-event
    `os_log_create` and `os_release` calls.
  - Checks `os_log_type_enabled` before allocating or formatting at the shared
    `Log.log` boundary, so disabled types cannot pay the enabled-path setup
    cost.
  - Adds an always-disabled-log formatting probe and a counter-backed cache
    initialization test. The first commit intentionally fails the probe before
    the production fix.
  - In a ReleaseFast workload targeting 25 million disabled events over five
    seconds, median normalized CPU fell from 0.904 core to 0.123 core; median
    CPU seconds per million events fell from 0.2072 to 0.0248.
  - Conflict note: keep logger identity scoped by compile-time subsystem and
    category, keep initialization thread-safe and process-lifetime, and keep
    the type-enablement check before every message allocation or formatter.

The cached-logger integration at `754c95d4f` has a universal ReleaseFast
GhosttyKit archive built with Zig 0.16.0 by
https://github.com/manaflow-ai/cmux/actions/runs/31135442829. It is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-754c95d4f286ff7a0cebbc5d5b198818ebf80cf1-crashsubdir-cmux-crash-sentry-off-v1
and its SHA-256 is pinned in `scripts/ghosttykit-checksums.txt`. The published
asset was downloaded again, passed `scripts/validate-xcframework-archive.py`,
and matched SHA-256
`cd86cb5fbb7087021383999fe4ca920b0af616ba7d71b05aa7f41a58a9f7a54b`.

### iOS startup locale before crash reporting

- Commit: `f0f8273b7` (Initialize locale before crash reporting)
- File: `src/global.zig`
- Summary:
  - Moves `ensureLocale()` and `syncEnviron()` before Ghostty's crash reporting
    init so Darwin `setlocale` completes before Sentry starts its background
    initialization thread.
  - Fixes the cmux INTERNAL TestFlight crash from August 2, 2026, where build
    `20260801151612` crashed in `ghostty_init + 1388` while the main thread was
    in `setlocale` from `GhosttyRuntime.init`.
- Conflict note:
  - Preserve this ordering during future `global.init` merges: process-wide
    locale mutation must stay before any Ghostty-owned background thread starts.

### Empty opener stderr diagnostics

- Commits:
  - `45aec50de` (test: cover spawned open stderr reader log bound)
  - `19d03fa4d` (os/open: skip empty stderr diagnostics)
- File: `src/os/open.zig`
- Summary:
  - Runs the stderr drain against a real spawned process that writes 40 blank
    lines and exits, with a one-second timeout proving the reader thread reaches
    EOF instead of spinning.
  - Requires fewer than 10 repeated blank-line diagnostics in that capture
    window.
  - Continues consuming blank stderr lines so the opener can exit, but does not
    send content-free `open stderr=` records to macOS unified logging.
- Conflict note:
  - Preserve delimiter consumption, the EOF timeout coverage, and draining
    after the reporting cap. Suppressing a log must never suppress the read
    that advances the pipe.
- Artifact:
  - https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-19d03fa4d0161e60e02de2e42601992be0c001c3-crashsubdir-cmux-crash-sentry-off-v1
  - SHA-256 `d2842bb7778a4e8d5a5a5f57ce6a85508630e3184ba46c1ca1ae5cbe1655472f`
    is pinned in `scripts/ghosttykit-checksums.txt`.

### Atomic bracketed paste delivery

- Pull request:
  - https://github.com/manaflow-ai/ghostty/pull/194
- Patch commits:
  - `7ad529298` (test: cover atomic bracketed paste encoding)
  - `f27772d10` (fix: enqueue bracketed paste atomically)
- Current cmux Ghostty submodule pin and artifact commit:
  - `f76c132e5` (descends from the atomic-paste patch and retains the
    `11aa609d7` VT stream-boundary API required by current cmux TUI code)
- Files:
  - `src/input/paste.zig`
  - `src/Surface.zig`
- Summary:
  - Encodes the opening fence, sanitized payload, and closing fence into one
    owned buffer.
  - Sends that buffer through the termio mailbox as one write request, so
    parser-generated mode, device, and focus replies cannot be inserted inside
    a bracketed paste and desynchronize the foreground application's input
    parser.
- Conflict note:
  - Preserve the single-message boundary when paste encoding or termio write
    ownership changes. Splitting the three segments back into independent
    mailbox messages reintroduces the ordering race.
- Artifact:
  - https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-f76c132e526f124fe4aaebd39f516751656844bc-crashsubdir-cmux-crash-sentry-off-v1
  - SHA-256 `af9f8f12e6f41ffe00b5b65f150bb887b19dc752e47d20d3c351696c803509af`
    is pinned in `scripts/ghosttykit-checksums.txt`.

### Initial cmux theme-picker render

- Commit: `5068b3a37` (fix: render cmux theme picker before input)
- File: `src/cli/list_themes.zig`
- Summary:
  - Initializes the terminal dimensions, renders the theme picker, and flushes
    the first frame before waiting for input, so the picker does not open blank.
  - Merges cleanly with the `abcf5697d` Sentry initialization fix; no conflict
    resolution was required.
- Artifact:
  - https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-59f2b5d2ec67a5f9dfe9138f6e5a4353b75d238e-crashsubdir-cmux-crash-v1
  - SHA-256 `3767b7bba0931f9cab359d0c8147885e14a2b6ce420044e5946b4b823fc093da`
    is pinned in `scripts/ghosttykit-checksums.txt`.

### Semantic prompt row lifecycle

- Pull request:
  - https://github.com/manaflow-ai/ghostty/pull/176
- Commits:
  - `afcda52a2` (terminal: test prompt mark cleared by output overwrite)
  - `2d6e944e3` (terminal: clear stale prompt marks on output overwrite)
- Files:
  - `src/terminal/Terminal.zig`
- Summary:
  - Clears a row's OSC 133 prompt or prompt-continuation mark when printable
    output actually overwrites that row.
  - Applies the same invariant to scalar printing and the batched narrow/wide
    print path, including a wide-character spacer written before wrapping.
  - Preserves historical prompt metadata unless output replaces content on
    that row, so prompt navigation remains intact while prompt-aware clear
    logic cannot mistake repainted TUI output for a live shell prompt.
  - Conflict note: every printable-output path that writes cells directly must
    clear stale row-level prompt metadata for each row it mutates. Do not move
    this responsibility into CSI erase handling or a specific shell protocol
    transition.

### Hidden macOS renderer reclamation

- Pull request:
  - https://github.com/manaflow-ai/ghostty/pull/153
  - https://github.com/manaflow-ai/ghostty/pull/165
  - https://github.com/manaflow-ai/ghostty/pull/166
  - https://github.com/manaflow-ai/ghostty/pull/167
  - https://github.com/manaflow-ai/ghostty/pull/168
  - Integration: https://github.com/manaflow-ai/ghostty/pull/169
  - Retry deadline hardening: https://github.com/manaflow-ai/ghostty/pull/170
- Commits:
  - `1de584d1e` (test: require lossless renderer realization requests)
  - `517a4c75a` (renderer: reclaim hidden macOS tab GPU memory)
  - `cc4ac8141` (test: require shared standard Metal pipelines)
  - `921d4efaa` (renderer: share standard Metal pipelines)
  - `f9d7262e1` (test: prevent concurrent Metal pipeline compilation)
  - `1e8aecd93` (renderer: serialize standard Metal pipeline creation)
  - `267541adf` (test: preserve Metal pipelines across renderer handoffs)
  - `b2c78d61a` (renderer: retain standard Metal pipelines across handoffs)
  - `e5702c1ab` (test: keep selected key tabs renderer-visible)
  - `19555c20f` (macos: keep selected key tab renderer visible)
  - `9ee855755` (test: recycle Metal command queues on renderer release)
  - `88fe92c27` (renderer: release hidden Metal command queues)
  - `532bbb0a5` (test: reclaim deselected tab renderers synchronously)
  - `7d0009af6` (macos: reclaim deselected tab renderers immediately)
  - `68ffad656` (test: prevent main-queue renderer teardown deadlock)
  - `7b24d1c5d` (renderer: avoid main-queue teardown deadlock)
  - `0f2b10bad` (test: require renderer-owned Metal resource lifetimes)
  - `232b24bf2` (renderer: release duplicate Metal resource retention)
  - `99439d40e` (test: cover deferred IOSurface clear ordering)
  - `24cf22453` (renderer: harden hidden-tab recovery)
  - `5faee251a` (renderer: close recovery lifetime edges)
  - `941791f5b` (test: cover renderer recovery failure edges)
  - `2c48281d4` (renderer: close recovery allocation gaps)
  - `1d7602ab3` (test: cover renderer restore lifecycle gaps)
  - `978e08759` (renderer: complete restore transaction semantics)
  - `970dbe093` (test: preserve forced renderer rebuild requests)
  - `13a8b53d3` (renderer: preserve forced rebuild transactions)
  - `735157526` (test: stop retrying missing renderer surfaces)
  - `1968317a3` (macos: stop retrying missing renderer surfaces)
  - `2907a1959` (test: preserve compositor-owned targets during clear)
  - `5495e912d` (renderer: preserve compositor-owned targets through clear)
  - `ce4d4842b` (test: require nonpurging target release)
  - `288fa8cac` (renderer: release presented targets without purge)
  - `bef29c98f` (test: hand external renderer retries to loop owner)
  - `facfef23a` (renderer: hand external retries to loop owner)
  - `bcc7fc4bd` (test: reject stale renderer retry delivery)
  - `2013a9c3d` (renderer: reject stale realization retry delivery)
  - `41aeef311` (test: invalidate retry while claiming request)
  - `8b1781336` (renderer: invalidate retry while claiming request)
  - `a255f34f2` (test: cover custom shader and tab observer reuse)
  - `f010d69af` (renderer: share custom pipelines and tab observers)
  - `7e783145b` (renderer: harden shared shader cache diagnostics)
  - `357f582b3` (test: cover stale tab callbacks and shader retries)
  - `074c0f7b7` (fix renderer cache and tab callback races)
  - `b88d39586` (test: classify custom shader failures as recoverable)
  - `ed67f2b59` (merge current fork main and preserve the Zig 0.16 port)
  - `67e76e130` (test: cover failed shader restore backoff)
  - `9fff00fc4` (fix: back off failed custom shader restores)
  - `a1e727ad2` (fix: tolerate matching retained shader entries)
  - `173623b9d` (test: cover live shader failure backoff)
  - `78621f8ce` (fix: key shader retries to compile attempts)
  - `29cbadf15` (test: reset resolved renderer retry deadlines)
  - `f9b38609a` (test: replace obsolete renderer retry handoffs)
  - `45abb8a2d` (fix: reset resolved renderer retry deadlines)
  - `e7d06af34` (fix: generation-tag renderer retry timers)
  - `cd1f8e012` (test: update renderer retry request assertion)
- Files:
  - `include/ghostty.h`
  - `macos/Sources/Features/Terminal/BaseTerminalController.swift`
  - `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
  - `macos/Tests/Ghostty/RendererTabSelectionTests.swift`
  - `src/apprt/embedded.zig`
  - `src/renderer.zig`
  - `src/renderer/Metal.zig`
  - `src/renderer/Thread.zig`
  - `src/renderer/generic.zig`
  - `src/renderer/message.zig`
  - `src/renderer/metal/IOSurfaceLayer.zig`
  - `src/renderer/metal/Frame.zig`
  - `src/renderer/metal/Target.zig`
  - `src/renderer/metal/Texture.zig`
  - `src/renderer/metal/api.zig`
  - `src/renderer/metal/buffer.zig`
  - `src/renderer/metal/shaders.zig`
- Summary:
  - Reclaims a deselected native tab's renderer while retaining its PTY,
    terminal state, scrollback, and surface.
  - Publishes renderer lifecycle state losslessly outside the bounded mailbox
    and retries fallible GPU restoration with bounded backoff.
  - Exposes one forced renderer rebuild transaction so an unrealize/realize
    transition cannot be coalesced away when a hidden surface becomes ready.
  - Drains outstanding frame leases and detaches the compositor layer before
    releasing teardown-only Metal resources.
  - Stops retrying reclamation when a native macOS surface no longer exists,
    instead of waking the renderer indefinitely for a surface that cannot
    return.
  - Keeps compositor-owned IOSurfaces alive until the queued layer clear has
    finished, and releases presented targets without making shared IOSurfaces
    purgeable.
  - Hands external-render retry scheduling back to the xev loop owner instead
    of mutating loop timers from the iOS external render queue.
  - Tags retries with publication generations and invalidates them atomically
    while claiming newer requests, so stale retries cannot override the latest
    external-render state.
  - Validates generation-tagged timer requests immediately before xev reset,
    rejects stale expirations, and resets the retry backoff after successful
    resolution so delayed handoffs cannot inherit or overwrite fresh deadlines.
  - Shares immutable standard shader pipelines by Metal device and pixel
    format while preserving renderer-owned resources and transactional cleanup.
  - Shares custom shader pipelines by device, pixel format, and source across
    renderer handoffs, retains one idle custom configuration, evicts older
    configurations, and retains one identical compiler-failure fallback for a
    source-keyed, non-sliding 30-second retry window starting when compilation
    fails, independent of renderer reference lifetime.
  - Elects one native-tab observation owner per tab group and binds queued
    callbacks to the group that emitted them, avoiding quadratic callbacks and
    stale callbacks that could orphan observation ownership.
  - Observes native tab selection conservatively and avoids synchronous
    renderer-to-main waits during teardown.
  - Conflict note: future renderer lifecycle work must preserve lossless
    realization publication, forced rebuild transactions, bounded recovery,
    compositor-owned IOSurface lifetimes, loop-owned retry timers,
    generation-checked retry delivery, atomic request claiming, bounded shared
    custom-pipeline retention, compile-attempt-owned compiler-failure backoff,
    single-owner tab observation, conservative tab selection, and off-main
    teardown without synchronous main-queue waits.

### Resolved font-binding action callbacks

- Commits:
  - Original branch:
    - `e6aa4fddb` (test: cover native font action callbacks)
    - `80d7fb35a` (feat: emit resolved font binding actions)
  - Reapplied on current fork main:
    - `9242f2cec` (test: cover native font action callbacks)
    - `bc1d15f1b` (feat: emit resolved font binding actions)
    - `2803ccfe1` (docs: clarify font action callback reentrancy)
- Files:
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
- Summary:
  - Adds a one-shot per-surface C callback for successfully performed increase,
    decrease, reset, and absolute font-size binding actions.
  - Reports the resolved action plus previous and current point sizes and
    adjusted-state flags after Ghostty applies the native mutation.
  - Keeps callback ownership on the exact embedded surface, with synchronous
    GUI-thread delivery and userdata valid through surface teardown.
  - Conflict note: future font-action routing must emit only after a successful
    native mutation, preserve chained and custom binding semantics, keep
    callback userdata alive until `ghostty_surface_free` returns, and never
    destroy or otherwise reenter the surface from the synchronous callback.

The previously pinned `88357634c4` universal ReleaseFast GhosttyKit archive
combines the initial theme-picker render and semantic prompt lifecycle fixes.
It was built
with Zig 0.16.0 and is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-88357634c4dbadc87981e2ebb64eb599c53aa012-crashsubdir-cmux-crash-v1
with its SHA-256 pinned in `scripts/ghosttykit-checksums.txt`. The published
asset was downloaded again, passed `scripts/validate-xcframework-archive.py`,
and matched SHA-256
`0448351c3f8b07fd2698c905260a97d064e4e186d0544766965effb41aedfbd5`.

The earlier `da1ddcf41` universal ReleaseFast GhosttyKit archive was built with
Zig 0.16.0. It is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-da1ddcf41f6fd763c39bde4c69d1ac7323cb9bd0-crashsubdir-cmux-crash-v1
and its SHA-256 is pinned in `scripts/ghosttykit-checksums.txt`. The published
asset was downloaded again, passed `scripts/validate-xcframework-archive.py`,
and matched SHA-256
`51bb73625dd8e53a98675fb75dc573931ab3b65646e02e5f0ef6bf7db89308da`.

### Ordered writes survive transient backpressure

- Commits:
  - `99335171e` (test: retain queued writes through backpressure)
  - `2f6ee7b3d` (fix: preserve queued writes through backpressure)
  - `d74e17608` (test: compile queued writes without WouldBlock)
  - `982a723ff` (fix: accept backend-specific write errors)
- Files:
  - `vendor/libxev/src/watcher/stream.zig`
  - `vendor/libxev/VENDORED.md`
- Summary:
  - Keeps the current ordered write request at the queue head when the backend
    reports transient `error.WouldBlock`, resubmitting the same buffer without
    notifying the client or advancing later requests.
  - Preserves the existing partial-write behavior while making libxev's
    ordered queue the single owner of both partial progress and transient
    backpressure.
  - Adds a deterministic fake-backend regression test with two queued writes.
    It injects `WouldBlock` into the head request and verifies that neither a
    client completion nor scheduling of the later request can occur.
  - Instantiates the ordered-write path with a backend whose write error set
    does not contain `WouldBlock`, preserving compilation and terminal-error
    behavior for non-kqueue backends.
  - Conflict note: future ordered-stream changes must retain the head request
    across both short successful writes and transient `WouldBlock` results.
    Only a complete write or terminal error may pop it and schedule its
    successor. Keep the error discriminator widened to `anyerror` so the
    `WouldBlock` branch remains valid for backend-specific error sets that
    cannot produce that error.

### `os/open` stderr drain spin and zombie leak

`openThread` drained a spawned child's stderr with
`std.Io.Reader.takeDelimiterExclusive`, which advances only *up to* the
delimiter. Once the seek position sits on a `\n` it returns a zero-length slice
forever, without progressing and without erroring, so the loop spun at 100% CPU
after the very first stderr line, emitting empty `open stderr=` records until
macOS throttled the process-wide logging firehose
(`__FIREHOSE_CLIENT_THROTTLED_DUE_TO_HEAVY_LOGGING__`, which makes *every*
`os_log` call in the process expensive). `exe.wait()` was only reachable by
exiting that loop, so the child was never reaped either.

Measured live on cmux 0.64.20 after ~1 day uptime: 11 zombie children matched
one-for-one by 11 threads burning ~12.4% CPU each, ~95% of the process total
(500-600% observed), each with 94-97% of its stack inside
`zig_os_log_with_type`.

The fix switches to `takeDelimiter` (consumes the delimiter, reports
end-of-stream as `null`), reaps via `defer` so `wait()` is unconditional, and
caps reporting at 32 lines while still draining so a child blocked writing into
a full pipe can finish and exit. The drain loop is extracted as `drainStderr`
with tests covering termination, blank-line input, and the reporting cap.

- Commits:
  - `8f31fb57c` (os/open: stop the stderr drain from spinning and leaking zombies)
- Files:
  - `src/os/open.zig`

The intermediate `8f31fb57c` universal ReleaseFast GhosttyKit archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-8f31fb57cde291e7b8fecb46203bc398c44459f4-crashsubdir-cmux-crash-v1
and its SHA-256 is pinned in `scripts/ghosttykit-checksums.txt`.

### Inherited from `af4dfb43f`

The common base for both merged lines is `af4dfb43f`, the reviewed head of
https://github.com/manaflow-ai/ghostty/pull/152. It adds teardown-safe action
lease release on top of transactional menu-owned key binding consumption and
modifier-independent paired-release tracking from
https://github.com/manaflow-ai/ghostty/pull/151, based on the current
`manaflow-ai/ghostty` `main`, including the synchronous embedder teardown from
https://github.com/manaflow-ai/ghostty/pull/146 and the render-grid work from
https://github.com/manaflow-ai/ghostty/pull/147.

`4cc0933cf` adds the screen-anchored render-grid export for the iOS
local-scrollback scroll work: `buildRenderGridJson` gains an active-area
anchor mode, every export carries `history_rows` + `row_space_revision`
(scrollbar semantics; revision bumps on trim/eviction/reflow/erase), and the
new C export `ghostty_surface_render_grid_json_v2` takes the anchor flag.
Existing exports keep viewport anchoring byte-for-byte unchanged. Files:
`src/apprt/embedded.zig`, `include/ghostty.h`. The line's earlier swap-chain
rotation commit (`d2fc392de`, the iOS frozen-presents root-cause fix) was
independently landed on `main` as the byte-identical serial frame-lease
rotation (https://github.com/manaflow-ai/ghostty/pull/145); the merge keeps
`main`'s version.

On the `main` side: the complete renderer scheduling hardening landed
through https://github.com/manaflow-ai/ghostty/pull/136 after the initial
bounded-turn fix in https://github.com/manaflow-ai/ghostty/pull/135. Reliable
external redraw delivery and surface lifetime retention landed through
https://github.com/manaflow-ai/ghostty/pull/139. The owned-userdata experiment
from https://github.com/manaflow-ai/ghostty/pull/140 was superseded by the
synchronous teardown contract in
https://github.com/manaflow-ai/ghostty/pull/146. Serial frame-lease rotation
landed through https://github.com/manaflow-ai/ghostty/pull/145. Dead PTY reader
and child cleanup landed through
https://github.com/manaflow-ai/ghostty/pull/143. The cumulative external
frontend integration landed through
https://github.com/manaflow-ai/ghostty/pull/128, and the earlier stacked PRs
https://github.com/manaflow-ai/ghostty/pull/127,
https://github.com/manaflow-ai/ghostty/pull/123, and
https://github.com/manaflow-ai/ghostty/pull/122 are now merged or superseded.
The nonblocking renderer lifecycle fix landed through
https://github.com/manaflow-ai/ghostty/pull/132 before that cumulative merge.
The resulting main line supplies the external-frontend renderer contract used
by cmux Browser, exact cursor state for process-separated terminal mirrors,
mutable-default color reset semantics, nonblocking embedded lifecycle updates,
and the product-main renderer/link fixes described below. It also bounds each
renderer mailbox drain turn so continuous producers cannot starve lifecycle
processing or rendering.

The mailbox line is integrated into the pinned `cd1f8e012` universal
ReleaseFast GhosttyKit archive published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-cd1f8e0120f534cabc7d89257baccc42c166d369-crashsubdir-cmux-crash-v1
and its SHA-256 is pinned in `scripts/ghosttykit-checksums.txt`.

The ordered-write integration archive `dfe719016` and its component
`982a723ff` and `2258bea96` universal ReleaseFast GhosttyKit archives remain
published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-dfe719016d70140f2f6ffad54021b254b120d13e-crashsubdir-cmux-crash-v1,
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-982a723ffe5c239dd2d64e409366397135e3dab1-crashsubdir-cmux-crash-v1
and
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-2258bea96ddc005156beceb741b7dabb283ec615-crashsubdir-cmux-crash-v1,
with their SHA-256 values retained in `scripts/ghosttykit-checksums.txt`.

The previous `0b1734f1e` universal ReleaseFast GhosttyKit archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-0b1734f1eeca32ff6e0c17af2c95641639e682ba-crashsubdir-cmux-crash-v1.

### Bounded app mailbox turns

- Commits:
  - `6a8cdbc7a` (test: reproduce app mailbox drain starvation)
  - `2258bea96` (fix: bound app mailbox drain turns)
- File:
  - `src/App.zig`
- Summary:
  - Limits one app-thread mailbox turn to the queue depth observed when the
    turn begins, so concurrent renderer and terminal producers cannot keep a
    runtime's main thread inside `App.drainMailbox` indefinitely.
  - Preserves FIFO ordering and the existing bounded-queue backpressure while
    explicitly waking another app tick when messages remain, including after
    an early quit or message-handler failure.
  - Covers the exact producer-refill mechanism with a deterministic test that
    injects more app messages while the starting batch is being handled.
  - Conflict note: future app-loop changes must preserve the finite
    start-of-turn snapshot and an explicit continuation for messages left
    behind. Do not restore a producer-refillable drain-until-empty loop.

The issue-branch `2258bea96` universal ReleaseFast GhosttyKit archive is
published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-2258bea96ddc005156beceb741b7dabb283ec615-crashsubdir-cmux-crash-v1
and its SHA-256 is pinned in `scripts/ghosttykit-checksums.txt`.

The integrated `cd1f8e012` universal ReleaseFast GhosttyKit archive is
published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-cd1f8e0120f534cabc7d89257baccc42c166d369-crashsubdir-cmux-crash-v1
and its SHA-256 is pinned in `scripts/ghosttykit-checksums.txt`. Verification
covered the archive layout and plist, absence of AppleDouble entries, every
declared architecture, and `_ghostty_surface_rebuild_renderer` plus
`_ghostty_init` in all three static-library slices.

### PTY reader and child lifecycle teardown

- Commits:
  - `8bf503f98` (test: cover dead PTY and child cleanup)
  - `5ef5cba63` (fix: terminate dead PTY readers and reap children)
- File:
  - `src/termio/Exec.zig`
- Summary:
  - Treats a zero-byte PTY read as authoritative EOF instead of returning to
    `poll()`, preventing an `io-gather` thread from spinning when a dead
    descriptor remains permanently readable without `POLLHUP`.
  - Handles `POLLHUP`, `POLLERR`, and `POLLNVAL` as terminal conditions while
    draining any readable tail bytes before the gather pipeline exits.
  - Gives surface teardown a nonblocking `waitpid` fallback when Darwin no
    longer exposes an already-exited child through `getpgid`, while accepting
    `ECHILD` when the normal process watcher won the reaping race.
  - Conflict note: future PTY read-pipeline changes must keep EOF independent
    of platform-specific poll flags, and process teardown must leave exactly
    one owner consuming every direct child's wait status.

### Bounded renderer mailbox turns and continuation recovery

- Commits:
  - `188d31a97` (fix: bound renderer mailbox drain turns)
  - `18c3fd311` (renderer: preserve progress across wake errors)
  - `727a7dc02` (fix: drain external renderer continuations)
  - `994fee1b0` (merge the complete bounded-drain follow-up)
- Files:
  - `src/datastruct/blocking_queue.zig`
  - `src/renderer/Thread.zig`
- Summary:
  - Limits one renderer turn to the mailbox depth observed when the turn
    begins. Messages added by concurrent producers remain FIFO-ordered for the
    next turn.
  - Applies latest-value lifecycle state and performs the pending render after
    every bounded batch, even when terminal output keeps refilling the mailbox.
  - Rechecks after rendering and explicitly re-wakes the normal renderer when
    work arrived during either the drain or render, because producer
    notifications may have coalesced with the wake being handled.
  - External iOS rendering, which permanently disables the xev callback, drains
    each finite continuation batch until quiescent on its serial render queue.
  - Restores failed focus/display lifecycle requests only when their atomic
    slots are still empty, preserving newer concurrent publications and making
    focus application transactional for a later retry.
  - Conflict note: future renderer-loop changes must preserve bounded progress
    for lifecycle state and rendering, normal-path post-render re-wakes, and
    external-path continuation consumption. Do not replace the snapshot drain
    with an unbounded producer-refillable drain-until-empty loop.

### External redraw delivery and surface lifetime

- Commits:
  - `d1efafd78` (fix: retain rejected external redraw requests)
  - `62e1de720` (fix: ticket external redraw deliveries)
  - `741b11662` (fix: bind redraw tickets to surface lifetimes)
  - `cf1dee45d` (fix: retain surfaces through app action dispatch)
  - `d3265f4c5` (merge the reviewed redraw-delivery follow-up)
- Files:
  - `src/App.zig`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/apprt/gtk/Surface.zig`
  - `src/renderer/Thread.zig`
- Summary:
  - Assigns one generation-scoped redraw ticket to each external surface so a
    rejected app-mailbox enqueue has one retained retry owner.
  - Distinguishes queued work from enqueue failure, retries only after mailbox
    capacity returns, and rejects stale acknowledgments or allocator-address
    reuse from an older surface lifetime.
  - Retains the surface allocation while the host render action is dispatched,
    allowing reentrant teardown to unregister immediately while deferring final
    destruction until the callback returns.
  - Conflict note: external redraw changes must preserve per-surface ticket
    ownership, generation checks, enqueue-failure retry ownership, and the app
    action lifetime lease. A raw surface pointer is not a sufficient delivery
    identity across asynchronous dispatch.

### Synchronous embedder teardown and host-owned userdata

- Pull request:
  - https://github.com/manaflow-ai/ghostty/pull/152
- Commits:
  - `7541eb3db` (revert the owned-userdata lease layer)
  - `b47e5cac2` (fix: complete surface teardown before free returns)
  - `ff36ae8ac` (fix: serialize teardown with cross-thread actions)
  - `28c0f9bf5` (test: order cross-thread teardown assertions)
  - `518ac28d5` (merge the synchronous teardown fix)
  - `b8efe0f45` (test: cover action release teardown ordering)
  - `af4dfb43f` (fix: release action lease before teardown wake)
- Files:
  - `include/ghostty.h`
  - `src/App.zig`
  - `src/apprt/embedded.zig`
- Summary:
  - Removes `ghostty_surface_new_with_owned_userdata`; embedded surfaces again
    borrow callback userdata supplied through `ghostty_surface_config_s`.
  - Makes `ghostty_surface_free` synchronously stop renderer and IO callbacks
    before returning, including serialization with cross-thread app actions.
  - Retains only the outer surface allocation when teardown is reentrant from
    an app action. The live core is still destroyed synchronously.
  - Requires the embedder to retain callback userdata until
    `ghostty_surface_free` returns, then release it exactly once.
  - Drops the action's allocation reference before publishing a drained action
    count and waking teardown, so the embedder cannot free the app while the
    action still needs its allocator.
  - Conflict note: future teardown changes must preserve synchronous callback
    quiescence and release action references before advertising that the final
    action has drained. Embedders may not release borrowed userdata before
    `ghostty_surface_free` returns.

### Transactional menu-owned key bindings and paired releases

- Pull requests:
  - https://github.com/manaflow-ai/ghostty/pull/150
  - https://github.com/manaflow-ai/ghostty/pull/151
- Commits:
  - `1509cc596` (test: cover menu-owned binding eligibility)
  - `22d6c589f` (fix: preserve menu binding key lifecycle)
  - `985dd1e96` (test: cover modifier-first binding release)
  - `d9311bb99` (fix: pair binding release without modifiers)
- Files:
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/input/Binding.zig`
  - `src/input/key.zig`
- Summary:
  - Adds `ghostty_surface_key_consume_if_menu_action` for a native menu miss to
    atomically resolve and consume only the requested focused-surface action.
  - Accepts only an exact root, single-action, consumed, performable binding
    while no key sequence or key table is active.
  - Records the trigger in Ghostty so a reported paired key release is consumed
    without encoding terminal input.
  - Pairs the release by physical key and unshifted codepoint instead of live
    modifiers, so releasing Command before C does not leak C's key-up event.
  - Clears prior release ownership when a later press or repeat starts a new
    same-key transaction, then records it again only if Ghostty consumes that
    event. Duplicate releases remain consumed without swallowing a later
    forwarded key lifecycle.
  - Leaves unconsumed, app-wide, all-surface, chained, sequence, key-table, and
    custom action bindings to normal Ghostty key processing.
  - Conflict note: menu routing must use this transaction instead of querying
    binding identity in one call and submitting the key in another. The
    eligibility decision and paired release state must remain atomic. Release
    ownership must stay modifier-independent and expire before a new same-key
    press or repeat is resolved.

### Nonblocking renderer lifecycle state

- Commits:
  - `2d99010ff` (test: cover nonblocking renderer lifecycle state)
  - `ca21db1bb` (fix: publish renderer lifecycle state without blocking)
  - `ade1de1f4` (merge the then-current fork `main`)
  - `98c95ac88` (merge the lifecycle fix through fork PR #132)
- Files:
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/renderer/Thread.zig`
- Summary:
  - Publishes surface visibility, focus, and macOS display ID into independent
    atomic latest-value slots instead of waiting for capacity in the bounded
    renderer mailbox.
  - Applies those coalesced values on the renderer thread after ordered mailbox
    work, so an older compatibility message cannot overwrite a newer lifecycle
    request.
  - Keeps embedder UI executors nonblocking even when the renderer thread is
    wedged or its mailbox is full. The renderer wakeup remains the signal that
    drives the next drain.
  - Conflict note: future surface lifecycle or renderer-mailbox changes must
    preserve the invariant that UI-thread visibility, focus, and display-ID
    calls never wait for renderer progress. New idempotent lifecycle fields
    should use the same latest-value publication path rather than a `.forever`
    mailbox push.

### External frontend rendering and recovery

- Commits:
  - `581dbf264` (embedded: add manual mirror IO mode)
  - `9a391205c` (feat: add external Metal presenter ABI)
  - `0f400d0f5` (feat: serialize worker recovery state)
  - `ad5d0124c` (merge the external presenter and manual-renderer lines)
  - `d0dc34b2a` (embedded: pin combined cmux surface ABI)
  - `8c645641a` (embedded: add leased external Metal frames)
- Files:
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/renderer/external_frame.zig`
  - `src/renderer/frame_lease.zig`
  - `src/renderer/Metal.zig`
  - `src/renderer/OpenGL.zig`
  - `src/termio/Manual.zig`
- Summary:
  - Adds windowless Metal presentation for an external frontend. Completed
    IOSurface frames carry explicit frame and host-context tokens; the host
    either drops the frame or acquires a lease and releases that exact lease
    when it is finished presenting.
  - Keeps manual-mirror terminal I/O under the embedder's authority, including
    startup PTY teeing, parser-response suppression, serialized configuration,
    and an atomic VT-tail/output-sequence snapshot for worker recovery.
  - Retains the embedder-owned OpenGL path while assigning stable, distinct
    platform ABI values to OpenGL, ordinary external Metal, and leased external
    Metal surfaces.
  - Conflict note: renderer refactors must preserve exact frame ownership,
    one-release-per-acquired-lease semantics, and the atomic recovery snapshot.
    Platform enum values and the combined surface ABI are externally consumed
    and must not be renumbered implicitly.

### Serial frame-lease rotation

- Commits:
  - `3a43d5edc` (test: require serial frame slot rotation)
  - `fcafac572` (fix: rotate serial frame leases)
  - `50ad1963d` (merge the frame-lease rotation fix)
- File:
  - `src/renderer/frame_lease.zig`
- Summary:
  - Rotates the free-slot search after every successful acquisition. A serial
    producer therefore presents distinct IOSurface objects even when each Metal
    frame completes before the next input event.
  - Preserves exact-slot ownership, generation tokens, out-of-order release
    safety, and semaphore backpressure; only the choice among currently free
    slots changes.
  - Prevents Core Animation from deduplicating repeated assignments of one
    IOSurface while its pixels change underneath it, which otherwise batches
    low-rate terminal echo until unrelated layer activity triggers recomposition.
  - Conflict note: future lease-pool refactors must retain round-robin selection
    among free slots. A fixed first-free scan reintroduces serial-render stalls
    even when every GPU completion and renderer wake is timely.

### Cursor visual and replay continuity state

- Commits:
  - `9a614e570` (terminal: expose effective cursor visual state)
  - `fa8e3b18b` (terminal: expose screen activity token)
  - `71ed4f8f6` (terminal: expose cursor semantic activity)
- Files:
  - `include/ghostty/vt/terminal.h`
  - `src/terminal/c/terminal.zig`
  - `src/terminal/stream_terminal.zig`
- Summary:
  - Exposes the active screen's resolved cursor shape and terminal-wide DEC
    mode 12 blink state separately from the SGR cell cursor-style getter.
  - Exposes opaque wrapping screen-activity and cursor-activity tokens. A
    process-separated frontend compares them only for inequality so it can
    replay resets, alternate-screen round trips, and same-value semantic
    changes that the final visible shape/blink pair alone cannot reveal.
  - Conflict note: DECSCUSR, DEC mode 12, alternate-screen transitions, full
    reset, and embedder-default changes must continue advancing the appropriate
    activity token even when the resolved visual pair is unchanged.

### Dynamic colors follow mutable defaults

- Commit: `d6f611a30` (terminal: let color resets follow mutable defaults)
- Files:
  - `src/terminal/color.zig`
  - `src/terminal/c/render.zig`
- Summary:
  - OSC 110, 111, and 112 clear their foreground, background, and cursor
    overrides instead of copying the current default into the override slot.
    A later C API default-color update therefore becomes visible in an already
    attached render state.
  - Covers override, reset, and subsequent mutable-default updates while
    reusing one C render state, matching long-lived external frontends.
  - Conflict note: reset must continue to mean "no override"; snapshotting the
    current default recreates stale colors after a later frontend theme update.

### Unindented hard-newline link continuations

- Pull request: https://github.com/manaflow-ai/ghostty/pull/134
- Commits:
  - `823641e234c3c6bf4bc5badb72261d8a6fc37232` (fix: join unindented wrapped links)
  - `f6b47c8371991a4555f907737e808f161c368661` (merge the link continuation fix)
- Files:
  - `src/Surface.zig`
  - `src/link.zig`
  - `src/link_wrap.zig`
- Summary:
  - Uses one shared continuation classifier for terminal-grid candidate
    expansion and newline normalization, so hover, copy, preview, and open all
    resolve the same complete link.
  - Recognizes unindented hard-newline continuations after link punctuation
    while preserving the existing indented continuation behavior.
  - Keeps conservative boundaries for explicit schemes and roots, semantic
    prompt transitions, unrelated indentation, and trailing sentence
    punctuation.
  - Conflict note: link-grid expansion and newline normalization must continue
    to share the classifier; duplicating the continuation decision can make
    hover and activation disagree.

### Bounded Kitty graphics state

- Pull request: https://github.com/manaflow-ai/ghostty/pull/137
- Commit:
  - `b7feeea5c0ee041f8cb79aace2129efad31df19d` (merge bounded Kitty graphics state)
- Files:
  - `include/ghostty/vt/{kitty_graphics.h,terminal.h,types.h}`
  - `src/lib_vt.zig`
  - `src/terminal/{Screen.zig,Terminal.zig}`
  - `src/terminal/c/{kitty_graphics.zig,main.zig,terminal.zig}`
  - `src/terminal/kitty/{graphics.zig,graphics_exec.zig,graphics_image.zig,graphics_storage.zig,graphics_unicode.zig}`
- Summary:
  - Bounds per-screen Kitty image and placement storage, in-progress image
    loads, allocation sizes, and eviction scans.
  - Exposes the lib-vt C ABI for image and placement enumeration, restores
    image-number aliases, and reports anonymous placement identity.
  - Adds renderer-owned graphics dirty/damage state for incremental external
    snapshots.
  - Applies limit changes atomically and preserves replacements while cleaning
    placement pins during replacement and eviction.
  - Conflict note: future Kitty storage changes must preserve bounded resource
    use, atomic limit updates, alias/enumeration ABI behavior, and placement-pin
    cleanup.

## Reconciled product-main line

The product-main line had advanced independently to `b211341be` while the
external-frontend line advanced to `d6f611a30`. Integration commit
`7c3ddd6f3cd4935f1b6bd10530b1e8e8ec4c9ef9` reconciled both histories, and
merge commit `c55514dd52d806e9aa661ee20381aa19c91c1c09` landed that cumulative
result on `manaflow-ai/ghostty` `main` through
https://github.com/manaflow-ai/ghostty/pull/128. The current submodule pin
therefore includes the indented hard-newline link continuations, tokened
presentation lifetime fixes, leased external frames, recovery snapshots,
cursor continuity state, mutable-default color resets, and nonblocking embedded
lifecycle publication together.

The older `b211341be` universal ReleaseFast archive remains published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-b211341be1ba902e772f57fc67c3e65d35205676-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt` for reproducibility of older
cmux revisions.

### Indented hard-newline link continuations

- Commits:
  - `a1d8997f8` (test: cover indented hard-newline path links)
  - `11dd30a9b` (fix: join indented hard-wrapped links)
  - `6596607d1` (test: cover overlapping wrapped URL matchers)
  - `b5c39a8f7` (fix: align hover matcher priority with clicks)
  - `0a714f958` (test: reject non-link cells in wrapped URLs)
  - `eb9004aa8` (fix: resolve wrapped links from exact terminal cells)
  - `4267fc865` (test: preserve copy-link space trimming)
  - `0768b05d2` (fix: honor copy-link whitespace trimming)
  - `ae379642e` (merge the presentation-token runtime)
  - `828bb0b73` (test: preserve wrapped-path trailing spaces)
  - `8eb1857c4` (fix: retain wrapped-path trailing spaces)
  - `3288abc24` (test: cover inherited presentation callbacks)
  - `fedd33703` (fix: inherit render presentation callbacks)
  - `f1602d2e8` (test: cover reviewed link and render regressions)
  - `5038188f1` (fix: close reviewed render and link gaps)
  - `e4851d3d7` (test: cover presentation teardown and deferral)
  - `da0372405` (fix: harden tokened render completion)
  - `cc1574d2d` (test: cover callback registration lifetime)
  - `91de70f2d` (test: cover OpenGL presentation completion)
  - `56e3fcfd5` (fix: make presentation registration one-shot)
  - `56f0479de` (test: cover stalled Metal teardown lifetime)
  - `ecc2479dd` (test: cover out-of-order frame completion)
  - `34627914a` (test: reject stale frame generations)
  - `d5d3dec57` (fix: make stalled frame teardown lifetime-safe)
  - `79c8c3643` (test: preserve tokened Metal targets through assignment)
  - `f22ef7896` (fix: freeze tokened Metal presentations)
  - `3fa2305e1` (test: cover presentation ownership and GL ordering)
  - `fb97d47a0` (fix: preserve presentation ownership and GL ordering)
  - `fa6e8eae2` (test: cover synchronous presentation reentrancy)
  - `fe44a2ef4` (fix: deliver synchronous presentations after thread cleanup)
  - `79ebe478e` (test: preserve OpenGL presentation errors)
  - `b211341be` (fix: preserve OpenGL presentation errors)
- Files:
  - `build.zig`
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt.zig`
  - `src/apprt/embedded.zig`
  - `src/config/Config.zig`
  - `src/config/url.zig`
  - `src/input/Link.zig`
  - `src/link.zig`
  - `src/link_wrap.zig`
  - `src/renderer.zig`
  - `src/renderer/Metal.zig`
  - `src/renderer/OpenGL.zig`
  - `src/renderer/Thread.zig`
  - `src/renderer/generic.zig`
  - `src/renderer/link.zig`
  - `src/renderer/metal/CompletionLifetime.zig`
  - `src/renderer/metal/Frame.zig`
  - `src/renderer/metal/IOSurfaceLayer.zig`
  - `src/renderer/metal/Target.zig`
  - `src/renderer/opengl/Frame.zig`
- Summary:
  - Resolves each link to one exact value and exact terminal-cell set shared
    by hit testing, open/copy actions, previews, always highlighting, and
    Cmd-hover. Bounding selections are retained only for selection UI.
  - Recognizes conservative hard-newline continuations after URL/path break
    punctuation with 1-16 cells of indentation inside one semantic region.
    Period-ending rows, new rooted or scheme links, and ambiguous bare paths
    after `/` fail closed instead of merging unrelated rows.
  - Excludes indentation and trailing sentence punctuation from both actions
    and highlights. The built-in path matcher uses an unmapped match delimiter
    after joined candidates; custom end-of-input matchers retain literal
    behavior. Copy-link actions still honor the configured trailing-space
    trimming without changing the canonical target used for opening.
  - Applies matcher priority across overlapping candidate scopes, keeps OSC 8
    ownership authoritative, and maps both cells of wide UTF-8 glyphs.
  - Bounds cell, byte, candidate, and regex work; compressed pages stay cold.
    Regex work runs outside the terminal lock and stale snapshots are
    revalidated before results are applied.
  - Keeps the public surface config at 120 bytes and registers each surface's
    callback through a one-shot post-construction setter. Callback state is
    never inherited, and its userdata remains valid until surface destruction.
  - Carries presentation tokens through every backend. Metal uses exact
    in-flight slot ownership plus ref-counted renderer generations, so stalled,
    late, reordered, and post-teardown command-buffer completions cannot touch
    freed renderer or callback state.
  - Freezes each tokened Metal frame onto its rendered IOSurface while a
    replacement target re-enters the swap chain. The queued main-layer update
    retains those exact pixels, applies the size and teardown gates, and only
    then acknowledges the token; ordinary frames keep the allocation-free path.
  - OpenGL blits before its finish fence, preserves blit and cleanup failures,
    and acknowledges only after GPU validation, renderer cleanup, draw-lock
    release, and thread instrumentation. A reentrant callback may free its
    surface because delivery is the thread path's final operation.
  - Conflict note: future link matching changes must keep actions and highlights
    on the shared exact resolver. Renderer changes must preserve one-shot
    registration, exact-frame presentation, teardown cancellation, and final
    callback delivery together.

The presentation-token-only predecessor `24284c3ba` is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-24284c3ba4ebe79860d2b4e8d5d710fde2e1ebd3-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`.

### Tokened renderer presentation callbacks

- Commits:
  - `d303f9c89` (add tokened render presentation callbacks)
  - `a9d462403` (preserve presentation tokens across render backends)
  - `24284c3ba` (merge fork `main` at `bb30526cd`)
- Files:
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/renderer.zig`
  - `src/renderer/Metal.zig`
  - `src/renderer/OpenGL.zig`
  - `src/renderer/Thread.zig`
  - `src/renderer/generic.zig`
  - `src/renderer/metal/Frame.zig`
  - `src/renderer/metal/IOSurfaceLayer.zig`
  - `src/renderer/opengl/Frame.zig`
- Summary:
  - Adds an explicit render token to the embedded render request and returns
    that token only after the selected target is assigned to the host layer.
  - Preserves the token through Metal, OpenGL, and the generic renderer path so
    a stale command-buffer completion cannot acknowledge a newer iOS replay.
  - Keeps the existing layer-size guard authoritative. A target discarded after
    geometry changes emits no false presentation callback.
  - Conflict note: future renderer refactors must carry the token through every
    backend and invoke the callback only after the exact target assignment.

The previous `bb30526cd` pin contains the merged theme, render-grid,
wrap-aware URL, and authoritative sprite-font shaping changes.

### Authoritative sprite-font shaping runs

- Commits:
  - `a6ca2cca0` (test: preserve sprite runs inside text)
  - `20d11e519` (font/shaper: preserve authoritative sprite runs)
  - `bb30526cd` (merge Ghostty PR #120 into fork `main`)
- Files:
  - `src/font/shaper/coretext.zig`
  - `src/font/shaper/run.zig`
- Summary:
  - Keeps special sprite-font resolutions in their own shaping runs even when
    a surrounding text font also contains the bidi-neutral codepoint.
  - Uses one coalescing predicate for both visual run-boundary discovery and
    logical run construction, so the two phases cannot disagree about whether
    a special glyph belongs to the surrounding text font.
  - Covers a box-drawing sprite between ordinary text runs. The test-only
    commit absorbs the trailing border into the text run; the fix restores
    separate sprite/text/sprite runs.
  - Conflict note: future bidi or shaper changes must preserve special-font
    resolver results as authoritative. Special fonts bypass CoreText and
    HarfBuzz shaping and render their own glyphs.

The previous documented pin `366c801e0` added wrap-aware URL matching across
semantic soft wraps and is reachable from fork `main` through the merged
https://github.com/manaflow-ai/ghostty/pull/118.
The corresponding universal ReleaseFast GhosttyKit archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-366c801e066c37695c2d9be4a6567662bd763ad0-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`.

The previous `b4b6d69c8` pin introduced an exact Ghostty CLI executable-path
contract for embedded hosts. That commit is reachable from fork `main` through
`67b388b73` and was published via
https://github.com/manaflow-ai/ghostty/pull/115. Its universal ReleaseFast
GhosttyKit archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-b4b6d69c82033e16137266a04b364dc53d16c350-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`.

### URL matching across semantic soft wraps

- Commits:
  - `e0ab6113a` (test: cover URL links across semantic soft wraps)
  - `eee34d0f9` (fix: match URLs across semantic soft wraps)
  - `cbf65567a` (fix: scope wrapped link candidates by matcher)
  - `ee1e56791` (test: cover idempotent URL link finalization)
  - `30bd02565` (fix: preserve custom matchers across finalization)
  - `366c801e0` (merge Ghostty PR #118 into fork `main`)
- Files:
  - `src/Surface.zig`
  - `src/config/Config.zig`
  - `src/config/url.zig`
  - `src/input/Link.zig`
  - `src/terminal/StringMap.zig`
- Summary:
  - Keeps semantic prompt boundaries for path and custom-link matching, while
    letting explicit-scheme URLs use the complete soft-wrapped logical line
    when a semantic marker divides the line at a visual row boundary.
  - Assigns candidate bounds to each matcher so URL matching can use the wider
    logical line without weakening the narrower scopes for paths or custom
    matchers.
  - Keeps link hover, click, preview, and copy on one selection path; clicking
    any wrapped row yields the same complete URL.
  - Preserves custom matchers when configuration finalization or cloning calls
    `Config.finalize()` repeatedly, with focused regression coverage for that
    idempotence contract.
  - Conflict note: future upstream syncs must preserve the explicit-scheme
    wider scope, matcher-owned candidate bounds, and idempotent custom-matcher
    finalization together.

### Embedded Ghostty CLI path ownership

- `src/termio/Exec.zig` exports `GHOSTTY_BIN` as the exact CLI executable.
  Native Ghostty resolves to its running binary; an embedded host can supply a
  separate helper without assuming the host GUI executable is named `ghostty`.
- The zsh, bash, fish, nushell, and elvish SSH integrations invoke
  `GHOSTTY_BIN` directly. They install no SSH wrapper when an embedded host has
  not supplied a helper, so missing optional CLI support cannot break ordinary
  `ssh`.
- `GHOSTTY_BIN_DIR` remains the directory contract for the independent `path`
  shell-integration feature; it is no longer used to reconstruct a CLI filename.
- Conflict note: future upstream merges must preserve the distinction between
  the exact CLI path (`GHOSTTY_BIN`) and its PATH directory
  (`GHOSTTY_BIN_DIR`) across `src/termio/Exec.zig` and every shell integration.

The earlier fork history below includes terminal-owned scrollbar snapshots,
absolute row-space identity, OSC-boundary geometry, and compare-and-set
absolute-row restoration for notification scrollback replay.

The underlying compression, selection, and full-scrollback changes were
published via
https://github.com/manaflow-ai/ghostty/pull/96 and
https://github.com/manaflow-ai/ghostty/pull/99 and
https://github.com/manaflow-ai/ghostty/pull/104 and
https://github.com/manaflow-ai/ghostty/pull/105 and
https://github.com/manaflow-ai/ghostty/pull/106.

### Notification replay viewport authority

- OSC PWD actions carry the terminal scrollbar snapshot and row-space revision
  from the exact byte position where the replay boundary was parsed.
- `ghostty_surface_scrollbar` reads live terminal geometry without waiting for
  renderer publication.
- `ghostty_surface_scroll_to_row_if_revision` validates the row-space identity,
  scrolls, and returns the resulting geometry under one terminal lock. A reset,
  reflow, screen replacement, surface replacement, or scrollback eviction makes
  a stale request fail closed instead of scrolling the wrong rows.
- Conflict note: keep the PWD snapshot fields ABI-stable in
  `src/apprt/action.zig` / `include/ghostty.h`, preserve the PageList revision
  increments around row renumbering, and keep the embedded compare-and-set API
  adjacent to `ghostty_surface_scrollbar` during future fork merges.

### Upstream TLDR (`d560c645..7e02af879`)

- Terminal memory: idle renderer work now compresses cold scrollback pages,
  typically cutting their resident memory by 70% to 90%; unused page-pool
  backing is returned to the OS; the default logical scrollback limit rises
  from 10 MB to 50 MB.
- Terminal performance: pipelined PTY reads improve measured IO throughput by
  25% to 55%, parser/VT processing is substantially faster, and renderer-state
  lock hold time is reduced.
- libghostty-vt: adds compression scheduling APIs, color query/report APIs,
  Unicode width helpers, absolute-row viewport scrolling, and tracked grid
  references.
- Protocols and correctness: adds Kitty drag-and-drop parsing and fixes PageList
  capacity, ownership, bitmap allocator, cursor-height, and link-allocation
  edge cases.
- macOS: fixes IME preedit commits, quick-terminal sizing after display
  reconnects, and pasteboard handling for file URLs and multiple items.

### Fork integration and conflict notes

1. `src/Surface.zig`: kept the fork's latched Ctrl/Cmd-click semantics while
   adopting upstream's cached release position, drag guard, and renderer-lock
   ownership. The obsolete selection tests were dropped; the fork link-click
   regression test remains.
2. `src/renderer/Thread.zig`: kept cmux's iOS external-drain ownership and
   combined it with upstream's visibility refresh and idle compression
   scheduler. Desktop embedded surfaces therefore get automatic compression
   without a cmux-side timer.
3. `src/terminal/stream_terminal.zig`: used upstream's color-query response
   implementation because it supersedes the fork-only `a78fe53ef` patch while
   retaining terminal-stream APC handling.
4. `src/apprt/embedded.zig`: render-grid JSON snapshots now decode compressed
   nodes through `pagePreservingState`, reuse one temporary decode per page,
   and leave the original scrollback compressed. This prevents iOS snapshot
   streaming from undoing desktop memory savings. Replacement pages are
   acquired before the current page is released, so OOM leaves one valid owner
   for the scope defer instead of double-freeing the prior decode.
5. Fork CI keeps the `ubuntu-latest` aggregate-test fallback and skips
   upstream-only Vouch jobs outside `ghostty-org/ghostty`.
6. Selection changes and screen lifecycle transitions advance a terminal-wide
   atomic activity epoch. Renderer wakes compare the epoch without acquiring
   the terminal mutex, including for hidden surfaces, then invoke
   `selection_changed`. Accessibility callbacks can therefore read the
   selection synchronously without deadlocking or adding lock contention to
   output-heavy surfaces.
7. `selection_changed` is appended after every previously released C action
   tag. The old tail remains numeric value 64 and the new callback is 65, so
   existing binary embedders do not reinterpret later action payloads.
8. `PageListFormatter` decodes compressed history into temporary owned pages
   and frees them after formatting, so full `read-screen` and clipboard reads
   no longer make cold history resident. Temporary decode allocation failures
   propagate as `OutOfMemory` through Zig and C formatter APIs.
9. `ghostty_surface_read_screen_tail_vt` lets cmux preserve terminal history
   while replacing a completed remote-command surface. Ghostty derives the
   newest physical-row suffix from `PageList` pins and formats VT into a fixed
   byte buffer, halving the suffix on overflow so output is never cut inside a
   control sequence or UTF-8 codepoint. The formatter preserves SGR conceal,
   wide/grapheme cells, and compressed-page ownership. Upstream conflicts should
   keep this beside the existing embedded read-text APIs and retain
   `PageListFormatter.pagePreservingState` rather than restoring cold pages.

Verified with Zig 0.15.2: compression, formatter, selection activity, and
libghostty-vt compression tests,
the cmux link-click regression test, the `wasm32-freestanding` libghostty-vt
build, a clean universal GhosttyKit build, tagged cmux reloads `gcmp` and
`gsel2`, and live accessibility reads across select-all, endpoint adjustment,
and clearing.
Prebuilt archive:
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-eb500e9f45c8b6ffa6043350ec1488a42d195406-crashsubdir-cmux-crash-v1

### Previous pin

The previous cmux pin was `5ae712a89`, which added the bounded VT screen-tail
export on top of `e215e78bf`. Before that, `1ae98c991` was superseded by
`e215e78bf` after
full scrollback formatting was changed to preserve compressed storage and
selection notifications moved to a lock-free terminal-wide epoch. The initial
compression merge for this update was `870ed36f9`; it was superseded by
`4117298e4` after the preserved-page OOM ownership fix, by `bdf4baa80` after
the selection notification callback fix, then by `1ae98c991` after preserving
public action tag values. The fork's prior `main` head was
`cc31d54ee`, which merged upstream through `d560c645`; both histories are
ancestors of `e215e78bf`.

### Earlier pin

Previous cmux pinned fork head: `541e5e89d`, which merges the render-grid span
preservation head `1b454eb99` from manaflow-ai/ghostty#89 with the
Arabic/Hebrew RTL shaping head `7a5179843` from manaflow-ai/ghostty#88.

The render-grid change keeps wide or grapheme-backed cells in their own
`cmux.render-grid.v1` spans so mobile replay receives the producer's exact
start column and `cell_width` instead of inferring per-grapheme columns from an
aggregate same-style span.

The RTL series is based on ghostty-org/ghostty#11079 and adds the `itijah` bidi
resolver, extends the shared `uucode` tables with bidi fields, resolves visual
shaping runs per row, sets RTL shaping direction for CoreText/HarfBuzz, and
anchors Arabic combining marks/tashkeel to the correct base cluster. The
cmux-only follow-up commit adapts the new shaper tests to this pinned fork's
`vtStream().nextSlice` void-returning API. The RTL series was validated locally
with:

```bash
cd ghostty
zig build test -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=arabic
zig build test -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=hebrew
zig build test -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=bidi
zig build test -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=RTL
zig build test -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=mixed
zig build test -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=Bengali
```

The corresponding prebuilt archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-541e5e89db0448d5cd85a7b348d8f6a64618c900-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`.

### 0a) lib-vt OSC color query replies

- Files:
  - `src/terminal/stream_terminal.zig`
- Summary:
  - Adds OSC 4/10/11/12 query replies to the non-termio `TerminalStream` path used by libghostty-vt consumers.
  - Reports known palette/default/override colors through the existing `write_pty` effect in 16-bit `rgb:xxxx/xxxx/xxxx` form, preserving the query's BEL or ST terminator.
  - Leaves unknown dynamic colors unanswered so embedders that have not supplied host defaults preserve the previous silent behavior.
  - Upstreamability: mirrors the existing termio stream handler behavior, but scoped to lib-vt's callback-based reply mechanism.

The previous cmux pinned fork head was `1b454eb99`, which retained the
Darwin-only `ghostty_surface_set_renderer_realized` C API (a
`display_realized` renderer-thread mailbox message that drives
`displayUnrealized()`/`displayRealized()`) on top of `5697db81`. cmux uses it to
release an occluded terminal's GPU renderer resources (Metal swap chain /
IOSurface) while keeping its PTY alive, then rebuild them on re-show. The API
returns whether the message was enqueued so the embedder only advances its
realize/unrealize mirror state on success. The push is `.instant`
(non-blocking) so it never stalls the embedder's main thread waiting on the
renderer. See manaflow-ai/ghostty branch `feat-renderer-realized-offscreen`,
the copy-mode read branches `issue-6170-surface-read-screen-text-main` and
`issue-6170-screen-clipboard-text`, and
https://github.com/manaflow-ai/cmux/issues/4607. The corresponding prebuilt
archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-49cb510f759aa109a5b1d30329583195155e58a4-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`. The `1b454eb99` render-grid
head's corresponding prebuilt archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-1b454eb999d6f4aea28a18ca0e1500c0477383ef-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`. The `7a5179843` RTL shaping
head's corresponding prebuilt archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-7a51798436fa2cfcfcc9a2ed1e109ba69bdb68f9-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`.

The prior head was refreshed from upstream `main` on May 1, 2026.
Earlier cmux pinned fork head: `34cbf180d`, merging the surface registry
serialization for https://github.com/manaflow-ai/cmux/issues/5458 (`e5c962a72`,
landed on cmux `main`) into the iOS render bounded-acquire line (`f78189ac1`)
combined with the cmd-click link refresh under mouse reporting (`df789cd4b`,
manaflow-ai/ghostty#71 and PRs #74 through #79) for
https://github.com/manaflow-ai/cmux/issues/5128. This keeps the previous head's
manual embedded IO patch in https://github.com/manaflow-ai/ghostty/pull/53,
the Metal renderer row rebuild guard for https://github.com/manaflow-ai/cmux/issues/3369,
the URL/path regex bound for spaced file paths followed by prose, and the iOS
render serial-queue bounded acquire fix from manaflow-ai/ghostty#80. This head
keeps the cmux theme picker hooks, exposes the manual surface IO needed by
libghostty iOS clients, bounds shaped glyph iteration during IME/preedit row
rebuilds, prevents Cmd-hover from highlighting normal sentence text after a file
path, and lets Cmd-click open links even while a mouse-reporting alt-screen TUI
(Claude Code, Codex) has grabbed the mouse.
It also supports Ctrl-N and Ctrl-P in the cmux theme picker.
The corresponding prebuilt archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-34cbf180d8917b802d61d9929cfb493594f2ab52-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`.

### 0) Render-grid span column preservation for mobile replay

- Commit: `79b5bb6ee` (render-grid: split nontrivial cells into own spans)
- PR: https://github.com/manaflow-ai/ghostty/pull/89
- Files:
  - `src/apprt/embedded.zig`
- Summary:
  - Forces wide cells and cells with attached grapheme data to close the active
    render-grid span before and after emission.
  - Preserves exact producer columns for mixed-width same-style text, so iOS
    replay no longer has to reconstruct per-grapheme widths from one aggregate
    `cell_width`.
  - Conflict note: this sits in the render-grid JSON encoder's row/cell loop,
    near the span coalescing logic and `appendRenderGridCellText`.

### 1) macOS display link restart on display changes

- Commit: `05cf31b38` (macos: restart display link after display ID change)
- Files:
  - `src/renderer/generic.zig`
- Summary:
  - Restarts the CVDisplayLink when `setMacOSDisplayID` updates the current CGDisplay.
  - Prevents a rare state where vsync is "running" but no callbacks arrive, which can look like a frozen surface until focus/occlusion changes.

### 2) macOS resize stale-frame mitigation

The resize commits are grouped by feature because they touch the same stale-frame replay path and
tend to conflict together during rebases.

- Commits:
  - `a3588ac53` (macos: reduce transient blank/scaled frames during resize)
  - `9ba54a68c` (macos: keep top-left gravity for stale-frame replay)
- Files:
  - `pkg/macos/animation.zig`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/renderer/Metal.zig`
  - `src/renderer/generic.zig`
  - `src/renderer/metal/IOSurfaceLayer.zig`
- Summary:
  - Replays the last rendered frame during resize and keeps its geometry anchored correctly.
  - Reduces transient blank or scaled frames while a macOS window is being resized.

### 3) OSC 99 (kitty) notification parser

- Commits:
  - `2033ffebc` (Add OSC 99 notification parser)
  - `a75615992` (Fix OSC 99 parser for upstream API changes)
- Files:
  - `src/terminal/osc.zig`
  - `src/terminal/osc/parsers.zig`
  - `src/terminal/osc/parsers/kitty_notification.zig`
- Summary:
  - Adds a parser for kitty OSC 99 notifications and wires it into the OSC dispatcher.
  - Adapts the parser to upstream's newer capture API so the cmux OSC 99 hook survives the March 30 upstream sync.

### 4) cmux theme picker helper hooks

- Commits:
  - `66ff6ec4d` (Add cmux theme picker helper hooks)
  - `aa650937d` (Fix cmux theme picker preview writes)
  - `89d3612c9` (Improve cmux theme picker footer contrast)
  - `0dc979889` (Respect system theme in cmux picker)
  - `d9e0ab512` (Skip theme detection in cmux picker)
  - `042cbaaab` (Match Ghostty theme picker startup)
  - `eb34bcdd6` (Harden cmux theme override writes)
  - `04ec69173` (Apply highlighted cmux theme on Enter)
  - `4265d3428` (Apply cmux theme from picker search)
  - `176bd550f` (Add ctrl navigation to cmux theme picker)
- Files:
  - `build.zig`
  - `src/cli/list_themes.zig`
  - `src/main_ghostty.zig`
- Summary:
  - Adds a `zig build cli-helper` step so cmux can bundle Ghostty's CLI helper binary on macOS.
  - Lets `+list-themes` switch into a cmux-managed mode via env vars, writing the cmux theme override file and posting the existing cmux reload notification for live app-wide preview.
  - Keeps the preview UI readable in light mode, matches upstream picker startup behavior, and hardens writes to the cmux-managed theme override file.
  - Restores Enter as the cmux apply action by writing the currently highlighted theme before the picker exits.
  - Applies the highlighted search result when Enter is pressed from search mode in cmux-managed picker sessions.
  - Supports Ctrl-N and Ctrl-P as one-row down/up navigation in cmux-managed picker sessions.

### 5) Color scheme mode 2031 reporting

- Commits:
  - `2be58ee0e` (Fix DECRPM mode 2031 reporting wrong color scheme)
  - `74709c29b` (Send initial color scheme report when mode 2031 is enabled)
- Files:
  - `src/Surface.zig`
  - `src/termio/stream_handler.zig`
- Summary:
  - Keeps Ghostty's mode 2031 color-scheme response aligned with the surface's actual conditional state after config reloads.
  - Sends the initial DSR 997 report as soon as mode 2031 is enabled, which cmux relies on for immediate color-scheme awareness.

### 6) Keyboard copy mode selection C API

- Commits:
  - `0b231db94` (Re-export cmux selection APIs removed from upstream)
  - `46bd03a7` (surface: add absolute screen row text read)
  - `edad0cfec` (surface: format screen row clipboard text)
  - `e81fb65f` (surface: bound screen clipboard text formatting)
  - `aeed68c44` (Expose native keyboard selection geometry)
  - `65505e8c3` (Make keyboard copy navigation atomic)
  - `acefff5de` (Bound copy work and expose runtime cursor style)
  - `7a5d08b7c` (Preserve rich bounded keyboard copies)
  - `4a6c443c3` (Preserve plain bounded clipboard copies)
- PRs:
  - https://github.com/manaflow-ai/ghostty/pull/154
  - https://github.com/manaflow-ai/ghostty/pull/156
  - https://github.com/manaflow-ai/ghostty/pull/157
  - https://github.com/manaflow-ai/ghostty/pull/159
  - https://github.com/manaflow-ai/ghostty/pull/160
- Files:
  - `include/ghostty.h`
  - `src/apprt/embedded.zig`
  - `src/Surface.zig`
  - `src/termio/Termio.zig`
  - `src/terminal/Screen.zig`
  - `src/terminal/Selection.zig`
  - `src/terminal/render.zig`
- Summary:
  - Restores `ghostty_surface_select_cursor_cell` and `ghostty_surface_clear_selection`.
  - Keeps cmux keyboard copy mode working against the refreshed Ghostty base after upstream removed those exports.
  - Exposes exact grid dimensions, asymmetric padding, cursor position, and cursor cell width through `ghostty_surface_grid_metrics`.
  - Resolves viewport cells to canonical glyph coordinates so wide and wrapped glyphs use their actual leading cell and width.
  - Adds tracked character and linewise viewport selection APIs. Ghostty owns selection rendering, reflow, scrolling, and clipboard formatting while cmux moves logical endpoints.
  - Preserves selection mode and direction through snapshots, screen clones, reflow, and renderer caching.
  - Stores the keyboard copy cursor as a tracked screen pin, preserving logical
    cell identity across PTY output, reset, reflow, scrolling, and alternate
    screen transitions.
  - Applies counted glyph movement and scrolling under one terminal lock, then
    returns the authoritative viewport cell and glyph width to the host.
  - Ties keyboard selection ownership to Ghostty's selection activity identity
    so mouse or other foreign selection replacement cannot be mistaken for
    copy-mode state.
  - Bounds clipboard formatting to 2 MiB and preflights selected physical cells
    before decompression, keeping both input work and output size bounded.
  - Returns cursor geometry and effective runtime color in one terminal-state
    snapshot, including OSC overrides, semantic cell colors, inverse video,
    palette colors, and live manual-IO theme changes.
  - Publishes bounded keyboard-copy selections as mixed plain text and styled
    HTML, preserving rich paste targets without returning formatter buffers to
    the Swift host. If HTML exceeds its formatter byte budget, it publishes the
    already-bounded plain text instead of failing the copy.
- Conflict notes:
  - Reconcile the exported C declarations with `src/apprt/embedded.zig` whenever the embedded surface API changes.
  - Keep character-cell canonicalization aligned with wide-cell and wrapped-spacer behavior in `src/terminal/Selection.zig`.
  - Linewise endpoints remain logical row pins. Full-row bounds are derived for rendering and copying, rather than stored in the selection.
  - Keep tracked cursor cleanup generation-safe when alternate screens are
    destroyed, and preserve selection activity checks whenever selection
    ownership changes.

### 7) macos-background-from-layer config flag

- Commits:
  - `ae3cc5d29` (Restore macOS layer background hook)
  - `aa28e1bcb` (Add macos-background-from-layer config flag)
  - `1a01b36d9` (Skip fullscreen bg draw call in layer-background mode)
  - `82e20630b` (Preserve bg images in layer background mode)
  - `465a9a621` (Restore bg-image alpha in layer background mode)
- Files:
  - `src/config/Config.zig`
  - `src/renderer/generic.zig`
- Summary:
  - Adds a `macos-background-from-layer` bool config (default false).
  - When true, sets `bg_color[3] = 0` in the per-frame uniform update so the Metal renderer skips the full-screen background fill.
  - Allows the host app to provide the terminal background via `CALayer.backgroundColor` for instant coverage during view resizes, avoiding alpha double-stacking.
  - Replays the layer-background restore on top of the refreshed Ghostty base so cmux keeps the resize-coverage fix after the upstream sync.

### 8) TerminalStream kitty graphics APC handling

- Commit: `a8e92c9c5` (terminal: add APC handler to stream_terminal)
- Files:
  - `src/terminal/stream_terminal.zig`
- Summary:
  - Wires `.apc_start`, `.apc_put`, and `.apc_end` through the shared APC parser in `TerminalStream`.
  - Restores kitty graphics execution and APC OK/error replies for the non-termio stream path used by cmux/libghostty integrations.

### 9) Config load string C API

- Commit: `f7880c473` (Add config load string C API)
- Files:
  - `include/ghostty.h`
  - `src/config/CApi.zig`
  - `src/config/Config.zig`
- Summary:
  - Adds a C API for loading Ghostty config from an in-memory string.
  - Lets cmux parse generated or override config without materializing a separate config file first.

### 10) Manual embedded IO for libghostty iOS

- Commit: `22fa801f8` (Expose manual embedded IO for iOS)
- PR: https://github.com/manaflow-ai/ghostty/pull/53
- Files:
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/input.zig`
  - `src/input/text.zig`
  - `src/renderer/Thread.zig`
  - `src/termio.zig`
  - `src/termio/Manual.zig`
  - `src/termio/Termio.zig`
  - `src/termio/backend.zig`
- Summary:
  - Exposes `GHOSTTY_SURFACE_IO_MANUAL`, `io_write_cb`, `ghostty_surface_process_output`,
    `ghostty_surface_text_input`, and `ghostty_surface_render_now` through the embedded C API.
  - Wires the existing manual termio backend into embedded surfaces without taking stale
    xcframework or build-system changes from the old iOS branch.
  - Keeps manual surface writes inline so iOS typing does not wait on the termio thread wakeup path.
  - Comments each fork-only API/runtime hook with its upstream-removal condition.
  - Checked upstream `ghostty-org/ghostty` `4dcb09ada` on May 1, 2026. It does not expose
    equivalent libghostty surface IO selection, write callback, text-input callback,
    render-now C API, or output C API. Upstream already has internal
    `Termio.processOutput`, so prefer an upstream C bridge if one lands.

### 11) Metal renderer preedit row rebuild guard

- Commits:
  - `70b95dada` (Expose unsafe preedit catch-up in renderer rows)
  - `fe972c095` (Bound renderer preedit catch-up to shaped glyphs)
- Files:
  - `src/renderer/generic.zig`
- Summary:
  - Adds a regression test for the row-rebuild path where IME/preedit covers the
    only shaped glyph in a row and the remaining terminal cells are empty.
  - Bounds the shaped glyph cursor before reading from the shaped-cell slice, so
    `GenericRenderer(Metal).rebuildRow` no longer assumes terminal cells and
    shaped glyph cells have one-to-one cardinality.
  - The first commit intentionally preserves the panic so cmux can keep the
    required failing-test-then-fix history for https://github.com/manaflow-ai/cmux/issues/3369.

### 12) URL/path regex bounds for spaced file paths

- Commits:
  - `6e10706a7` (test: cover spaced file path link bounds)
  - `6eed7af92` (fix: bound spaced file path links)
  - `ff6e1260d` (fix: handle dotted spaced path prefixes)
- Files:
  - `src/config/url.zig`
- Summary:
  - Adds coverage for a path with spaces ending in `.mp4` followed by a normal sentence.
  - Routes dotted paths with spaced directory names through the stricter dotted-path branch.
  - Keeps single-space path components such as `Recovered Screen Recordings` while preserving
    the existing double-space stop case.
  - Trims trailing sentence punctuation when more text follows, without breaking dotted paths
    that end at end-of-line.
  - Preserves versioned or dotted path components before the first space, such as
    `/tmp/v1.2 captures/video.mp4`.

### 13) Cmd-click opens links under mouse reporting (alt-screen TUIs)

- Commits (manaflow-ai/ghostty#71, by @doronpr):
  - `1c7613c95` (fix: open terminal links on cmd-click even when mouse reporting is active)
  - `55d154a97` (fix: gate link refresh on effective mouse-reporting state)
- Follow-up commits (manaflow-ai/ghostty#74):
  - `354e3626b` (fix: suppress mouse reporting for the full cmd-clicked link click)
  - `d1dbbec9b` (fix: key cmd-click link suppression on the modifier, not over_link)
- Follow-up commit (manaflow-ai/ghostty#75):
  - `76ead3eae` (fix: also suppress motion reports during a cmd-clicked link drag)
- Follow-up commit (manaflow-ai/ghostty#76):
  - `f24195271` (fix: scope cmd-click link suppression to left button; clear stale hover)
- Follow-up commits (manaflow-ai/ghostty#77):
  - `5998abddd` (fix: latch cmd-click link suppression for the click lifecycle)
  - `59fb750c0` (fix: clear link-click latch unconditionally on left release)
- Follow-up commit (manaflow-ai/ghostty#78):
  - `9f014e98b` (fix: open latched link on release with press-time chord; defer-clear latch)
- Follow-up commit (manaflow-ai/ghostty#79):
  - `df789cd4b` (fix: only open a latched link click that started on a link)
- Files:
  - `src/Surface.zig`
- Summary:
  - Link hover/highlight state was refreshed in `keyCallback`/`cursorPosCallback`
    only when mouse reporting was off, or shift was releasing the mouse from
    capture. Holding the ctrl/super link-activation modifier was not considered,
    so under a mouse-grabbing alt-screen TUI (Claude Code, Codex) `over_link`
    stayed `false`, the link-click branch in `mouseButtonCallback` was skipped,
    and the Cmd-click was reported to the program — which made cmux fall back to
    the OS default browser instead of honoring the configured link-open target.
  - Adds a shared `mouseLinkRefreshAllowed` gate (pure logic in
    `mouseLinkRefreshAllowedState`) that also allows local link handling when the
    ctrl/super modifier is held, using the effective mouse-reporting state
    (`isMouseReporting()`), matching iTerm2 and macOS Terminal. Fixes
    https://github.com/manaflow-ai/cmux/issues/5128.
  - Follow-up (#74): `mouseButtonCallback` ran the link-open path only on
    release, while the mouse-report path ran for both press and release and only
    broke out for the shift-release case — so a Cmd-click over a link still
    reported the *press* to the program and leaked a half-click to mouse-grabbing
    TUIs. The follow-up breaks out of the report path whenever the ctrl/super
    link chord is held (keyed on the modifier, like the shift-release path, so
    cursor jitter can't leak a press or a release), suppressing the whole click.
  - Follow-up (#75): `cursorPosCallback` still emitted `.motion` reports while a
    button was held during the chord, so a drag during link activation leaked
    button-motion. Mirrors the shift "grab override" for the ctrl/super chord in
    the motion path. Net: the link chord suppresses the whole left click+drag —
    press, release, and motion — consistently.
  - Follow-up (#76): scopes that suppression to the left button (ctrl/super
    right/middle clicks still reach the program, since link activation is
    left-only), and clears a stale link highlight/cursor when the chord is
    released through `cursorPosCallback`'s mods (refresh when `over_link` is set,
    mirroring `keyCallback`'s existing reset branch).
  - Follow-up (#77): latches the suppression decision at left-button press
    (`mouse.link_click_active`) and applies it through the release, instead of
    re-checking the live modifier each event — so releasing ctrl/super before the
    mouse button can't leak the release as a half-click. Ties suppression to the
    click lifecycle (press/drag/release), fully closing the half-click class. The
    latch is cleared unconditionally on left release (independent of
    mouse-reporting state) so it can't go stale.
  - Follow-up (#78): unifies the open and suppression decisions. `linkAtPos`
    uses the latched chord while a click is active and the release attempts
    `processLinks` whenever latched, so releasing the modifier before the button
    still opens the link (instead of swallowing the click); the latch is cleared
    via a function-level `defer` so the early-return link-open path resets it.
  - Follow-up (#79): only opens the latched click when it started on a link
    (`link_press_over_link`), so a chord drag that began off a link and released
    over one is swallowed rather than opening a link the press never targeted.
  - Known limitation (noted by review): the bypass matches the default
    `ctrlOrSuper` chord, which is exactly what both link kinds already require to
    activate (OSC 8 `linkAtPos` and the default url `hover_mods = ctrlOrSuper`); a
    user who reconfigures `link.highlight.hover_mods` to a non-default chord would
    not get the under-mouse-reporting bypass. Out of scope for #5128.

### 14) Embedded surface registry serialization

- Commits:
  - `c9b61a8af` (Add surface registry mutation serialization test)
  - `e5c962a72` (Serialize Ghostty surface registry mutations)
- Files:
  - `src/App.zig`
- Summary:
  - Adds a deterministic regression test for concurrent embedded runtime
    surface registry mutation.
  - Protects the native `App.surfaces` list and `focused_surface` pointer with
    one mutex so an off-main `ghostty_surface_free` cannot overlap the main
    actor `ghostty_surface_new` insertion path.
  - Keeps callbacks such as the quit timer outside the registry mutex to avoid
    re-entrancy through the embedder.
- Conflict notes:
  - Any upstream change to `App.addSurface`, `App.deleteSurface`,
    `App.focusedSurface`, or the embedded surface close path should preserve
    serialization of registry/focus mutation across create and free.

The current cmux pin is the merged head `34cbf180d`, which merges the surface
registry serialization (`e5c962a72`, section 14, landed on cmux `main` via
branch `issue-5458-surface-registry-lock`) into the Cmd-click link fix line
(`df789cd4b`, section 13) on top of the iOS render bounded-acquire pin
(`f78189ac1`). It is reachable from `manaflow-ai/ghostty` through branch
`issue-5128-alt-screen-link-open`. Published
`xcframework-34cbf180d8917b802d61d9929cfb493594f2ab52-crashsubdir-cmux-crash-v1`
and pinned its archive checksum in `scripts/ghosttykit-checksums.txt`. The
release and checksum pin must be regenerated whenever this commit changes, even
for comment-only amends, because the release tag is keyed by the Ghostty commit
SHA.

## Upstreamed fork changes

### cursor-click-to-move respects OSC 133 click-to-move

- Was local in the fork as `10a585754`.
- Landed upstream as `bb646926f`, so it is no longer carried as a fork-only patch.

### zsh prompt redraw follow-ups

- Were local in the fork as `8ade43ce5`, `0cf559581`, `312c7b23a`, and `404a3f175`.
- Dropped during the March 30, 2026 rebase because newer Ghostty prompt-marking changes on the refreshed base superseded these fork-only zsh redraw patches, so cmux no longer carries them separately.

### initial focus seeding and DECSET 1004 startup behavior

- Was local in the fork as `c19c82bfd`.
- Dropped from the current pinned fork head when cmux removed the corresponding
  app-side initial focus seed and went back to post-create focus sync.

## Merge conflict notes

These files change frequently upstream; be careful when rebasing the fork:

- April 28, 2026, upstream merge:
  - Merged upstream `659019666` into `465a9a621` without textual conflicts.
  - Verified with `CMUX_GHOSTTYKIT_NO_PREBUILT=1 ./scripts/ensure-ghosttykit.sh`.
  - Verified cmux with `./scripts/reload.sh --tag gtyup`.
  - Published `xcframework-d3117e03ea19665bc83a28f7e0428c63937e6140` and pinned
    its archive checksum in `scripts/ghosttykit-checksums.txt`.
  - Merged `d3117e03e` into fork `main` with https://github.com/manaflow-ai/ghostty/pull/48.
  - Package GhosttyKit archives with `COPYFILE_DISABLE=1`; the archive validator rejects
    macOS AppleDouble entries such as `._GhosttyKit.xcframework`.

- April 28, 2026, theme picker restore:
  - Reapplied the section 4 cmux picker hooks on top of `d3117e03e`.
  - Enter in cmux mode must call the same selection-apply path used by keyboard/mouse navigation
    before setting the picker outcome to apply.
  - Verified with `zig build cli-helper -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Doptimize=ReleaseFast`.
  - Verified Enter writes `theme = light:0x96f,dark:0x96f` in a PTY temp-config run.
  - Published `xcframework-04ec69173f8f5ac5a2568afca0faf8e4a74b2dc2` and pinned
    its archive checksum in `scripts/ghosttykit-checksums.txt`.

- April 30, 2026, theme picker search Enter:
  - Search-mode Enter in cmux mode must apply the current filtered selection and exit with
    outcome `apply`.
  - Escape still leaves search mode, and stock Ghostty search Enter still returns to normal mode.
  - Verified with `./scripts/reload.sh --tag thmenter`.
  - Published `xcframework-4265d34282ce2023c27da851c454dabe6cdc76ce` and pinned
    its archive checksum in `scripts/ghosttykit-checksums.txt`.

- May 1, 2026, manual embedded IO for libghostty iOS:
  - Added only the manual embedded IO API/runtime pieces on top of fork `main` `495316732`.
  - Avoided old iOS branch `.gitignore`, package, and xcframework build-system changes.
  - Checked upstream `ghostty-org/ghostty` `4dcb09ada`; no equivalent public libghostty
    surface IO API exists yet.
  - Added comments to the fork-only hunks stating that they should be deleted in favor of
    an upstream implementation when one exists.
  - Verified with `zig build test`.
  - Verified the universal macOS plus iOS xcframework path with
    `CMUX_GHOSTTYKIT_NO_PREBUILT=1 ./scripts/ensure-ghosttykit.sh`.
  - Published `xcframework-22fa801f88f96fa842e54ecce6c34a5d36003d19` and pinned
    its archive checksum in `scripts/ghosttykit-checksums.txt`.
  - Merged https://github.com/manaflow-ai/ghostty/pull/53 so the submodule SHA is
    reachable from fork `main`.

- `src/terminal/osc.zig`
  - OSC dispatch logic moves often. Re-check the integration points for the OSC 99 parser and keep
    the newer `capture`/`captureTrailing()` API usage intact.

- `src/terminal/osc/parsers.zig`
  - Ensure `kitty_notification` stays imported after upstream parser reorganizations.

- `src/cli/list_themes.zig`
  - cmux now relies on the upstream picker UI plus local env-driven hooks for live preview and restore.
    If upstream reorganizes the preview loop or key handling, re-check the cmux mode path and keep the
    stock Ghostty behavior unchanged when the cmux env vars are absent.
  - The April 28, 2026 restore requires Enter in cmux mode to call the same selection-apply path
    used by keyboard/mouse navigation before setting the picker outcome to apply.
  - The April 30, 2026 follow-up requires the same behavior from search mode, while preserving Escape
    as the search cancel path.

- `build.zig`
  - Upstream's new wasm/libghostty work touched the same build graph. Keep the cmux-only `cli-helper`
    step wired in without regressing the upstream `lib-vt` or wasm build paths.

- `src/main_ghostty.zig`
  - The April 28, 2026 restore only conflicted on stdout writer API usage. Keep the current
    `std.fs.File.stdout().writer(&buf)` API plus explicit flush.

- `include/ghostty.h`, `src/Surface.zig`, `src/apprt/embedded.zig`
  - Upstream removed cmux-used selection exports. Preserve the re-exported
    `ghostty_surface_select_cursor_cell` and `ghostty_surface_clear_selection` functions.

- `src/renderer/generic.zig`
  - The `macos-background-from-layer` check sits next to the glass-style check in `updateFrame`.
    If upstream refactors the bg_color uniform update or the glass conditional, re-check that both
    paths still zero out `bg_color[3]` correctly.

- `src/Surface.zig`, `src/apprt/embedded.zig`, `macos/Sources/Ghostty/Surface View/SurfaceView.swift`
  - The initial `focused` plumbing has to stay aligned across the C config, embedded runtime surface,
    and macOS wrapper. If upstream refactors surface creation or post-create focus sync, re-check that
    background panes can start unfocused without synthesizing a focus-loss transition during creation.

- `src/Surface.zig` (modifier tracking)
  - `modsChanged` and the key callback's link-highlight gate must compare binding mods against
    binding mods (stored mouse mods are binding-only). cmux sends sided modifier bits on key
    events for `macos-option-as-alt = left|right`; comparing raw mods re-dirties the screen and
    re-runs the link refresh on every event while a sided or lock modifier is held. If upstream
    refactors modifier tracking, keep the binding-normalized comparison.

- `src/termio/stream_handler.zig`
  - Keep DECSET 1004 enablement side-effect free. xterm-compatible focus reporting should only emit
    `CSI I` / `CSI O` on actual focus transitions, not immediately when the mode is enabled.

- `src/terminal/stream_terminal.zig`
  - Keep the APC handler wired into `.apc_start`, `.apc_put`, `.apc_end`, and preserve the
    `apcEnd()` response path so kitty graphics still reach `Terminal.kittyGraphics()` and reply via
    `write_pty`.

If you resolve a conflict, update this doc with what changed.
