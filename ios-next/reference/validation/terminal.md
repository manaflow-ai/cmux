# CNTerminalUI validation (slot `term`)

Date: 2026-10-09. Simulator: headless iPhone 17 Pro (`nx-ios-term`, iOS 27 runtime,
402 x 874 pt @3x) on the remote build Mac. App: `Drawer` scheme, Debug,
`CMUX_NEXT_DEV_SCREEN=terminal`, backed by `CNMockHost`. Contact sheets are in
`terminal/`.

How it was built: the shell agent has not wired `ModuleRoots.terminals()` to
`TerminalsRoot` yet, so the build used a private copy of the remote tree where
only that one line was patched (and `CNConversationsUI`, mid-change by its
owner, was taken from `HEAD`). No other agent's file was edited in the
worktree. The link also needs `ARCHS=arm64` (see Gaps).

## What was built

| Area | Implementation |
| --- | --- |
| Renderer | libghostty (`GhosttyNextKit`, apple-v6 pin) via `CmuxGhosttyKit`; surface `GHOSTTY_PLATFORM_IOS`, `io_mode = MANUAL_MIRROR`; adapted from `ios/CmuxiOS/Sources/CmuxiOSTerminal/Ghostty/*` |
| Output | `termOutput` frames from `HostClient.openStream(id:)` → `ghostty_surface_process_output` on one serial output queue |
| Input | Ghostty-encoded bytes from `io_write_cb` → `HostClient.sendTerminalInput` (`termInput`) |
| Grid | attach with the grid that fits the view; `ghostty_surface_set_grid` locks it; size or text size changes send `term.resize` debounced 150 ms |
| Keyboard | `UITextInput` + hardware keys + key bar (Esc, Tab, sticky Ctrl/Alt, arrows with repeat, `~ / \| -`, Paste, Hide) copied from `CmuxiOSTerminal/Input`; bar redrawn as Liquid Glass capsules; grid never resizes for the keyboard, the view pans the cursor row above it on the keyboard's own curve |
| Theme | Ghostty "Apple System Colors" / "Apple System Colors Light" written as two configs; switched with `ghostty_surface_update_config` on trait change |
| Text size | setting `cmuxNext.terminalFontSize` (same key and 9...24 range as `CNSettingsUI.AppPreferences`), default 13; pinch, More menu Larger/Smaller/Reset |
| Scrollback | one-finger vertical pan → `ghostty_surface_mouse_scroll` (precision), momentum at UIScrollView deceleration 0.998/ms via CADisplayLink, off under Reduce Motion |
| Selection | long press = double click (word), drag extends, release shows an edit menu (Copy, Paste, Select All); tap clears |
| Reconnect | `connection.generation` change → reset surface (RIS + ED 3) → `term.attach` → host replays scrollback |
| List | `TerminalsRoot(connection:)`: title, cwd, running; + creates and pushes; swipe closes; `term.updated` / `term.exited` keep it current |

## Results

| Element | Expected | Measured | Result |
| --- | --- | --- | --- |
| Ghostty renders (not black) | text and ANSI colors drawn | `ls --color`, `git status` (red), `git log` (yellow), prompt (cyan/purple/green) all drawn; `screens-light-dark.png` | pass |
| Light theme | Apple System Colors Light, bg #FEFFFF | bg and palette match the theme file | pass |
| Dark theme, live switch | Apple System Colors, bg #1E1E1E | switched in place on `simctl ui appearance dark`; debug value `theme=dark`, font stayed 13 | pass |
| `top`-like live screen | redraws every second in place | `top-dark.png`; inverse header, colored CPU column, clock advances | pass |
| Typing `ls -la` + Return | echoed, command runs | `axe type 'ls -la'` + `axe key 40` → long listing (`term-lsla`) | pass |
| Sticky Ctrl (armed) | next key gets Ctrl, then off | Ctrl tapped → bar shows ink-filled ctrl; `c` → host printed `^C` and a new prompt; next key `y` plain, bar back to off (`keybar-sticky-ctrl.png`) | pass |
| Sticky lock (double tap within 0.4 s) | locked until tapped | not reachable: axe taps are ≥ 0.6 s apart. Logic is the unchanged `TerminalStickyModifiers` covered by `ios/CmuxiOS/Tests/CmuxiOSTerminalTests/TerminalInputRouterTests.swift` | not verified in UI |
| Grid unchanged by keyboard show/hide | same cols × rows | `grid=50x42` before, during and after hide/show (debug accessibility value) | pass |
| No grid jump (framediff of consecutive frames, 60 fps, 427 frames) | content only translates, no step | per-frame offset vs frame 0 found by row matching: only values 0…36 px, no frame-to-frame step > 5 px (1.7 pt); residual after translation ≤ 2.6 / 255 mean gray (pure translation, no reflow) | pass |
| Pan follows the key bar | same frames as the bar | hide: bar moves frames 125–144, terminal 126–142; show: bar 291–314, terminal 291–303 (the bar's long sub-pixel tail; terminal shift is only 12 pt) | pass (within 1–2 frames) |
| Cursor stays above the bar | cursor bottom + 4 pt ≤ bar top | trace: cursor bottom 838, bar top 826 → shift 12 pt, cursor visible | pass |
| Scrollback via pan | older lines appear | swipe down 400 pt → earlier `git status` output visible; typing returns to the bottom | pass |
| Long-press selection + Copy | word selected, pasteboard gets it | long press on "date" selected the word; Copy → `simctl pbpaste` = `date` | pass |
| Paste button | pastes into the terminal | nav-bar Paste → `date` typed; Return ran it | pass |
| Text size change → resize | grid follows the font | 13 → 15 pt: grid 50×42 → 43×36 and `term.resize` sent; Reset → 50×42 | pass (via menu) |
| Pinch | same path as the menu | not driven: axe has no two-finger gesture | not verified in UI |
| Reconnect | stream ends, re-attach on the new generation, no duplicated scrollback | trace: `stream 1 ended` at 68.338 s, `attach generation=2` at 68.874 s; screen identical after replay (no duplicates), new input echoed (`reconnect-before-after.png`) | pass |
| New terminal (+) | created and opened | new `zsh` pushed with its login banner and prompt | pass |
| Swipe to close | row removed, host closes it | `top` removed; list re-read shows two terminals | pass |
| macOS `swift test` | package still builds on macOS | all suites pass (UI files are `#if os(iOS)`) | pass |

## Gaps and honest notes

- **Build setting needed by the shared script**: GhosttyNextKit's simulator slice is
  arm64 only. `remote-ios.sh build` uses `generic/platform=iOS Simulator`, which
  also links x86_64, so the app fails to link (`_ghostty_*` undefined for x86_64)
  as soon as the shell references `TerminalsRoot`. Fix in the script or
  `project.yml` (owner: shell/coordinator): pass `ARCHS=arm64` or set
  `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`.
- **Shell wiring**: `ModuleRoots.terminals()` must return
  `TerminalsRoot(connection: connection)` (and `import CNTerminalUI`).
- **Software keyboard not exercised**: the headless simulator has a hardware
  keyboard attached, so only the key bar (inputAccessoryView) shows. Keyboard
  show/hide was measured with that bar; the full software keyboard (larger pan,
  IME, autocorrect-off traits) needs a device or a simulator with the hardware
  keyboard disconnected.
- **Hardware Backspace from axe** did not erase (the simulator harness drops some
  special keys; the cmux iOS keyboard plan records the same). Return, letters
  and the key bar work.
- **Mirror mode does not reflow**: after a text size change the existing lines
  are clipped or padded until the host redraws (Ghostty mirror contract). The
  mock host's `top` and canned outputs are wider than a 50-column phone grid,
  so they wrap; that is the mock's fixed-width output, not the renderer.
- **Font**: Ghostty's default embedded font (JetBrains Mono). SF Mono is not
  available to apps by name on iOS.
- **Status banner** ("Reconnecting…") shows for the ~0.5 s reconnect window; it
  was too short to capture in a screenshot.
- No reference recording exists for a terminal, so timing was checked against
  the keyboard's own motion in the same recording rather than a reference app.
- DEBUG-only hooks: accessibility value `grid=… font=… shift=… theme=…` on the
  terminal, `CMUX_NEXT_TERMINAL_TRACE=1` (layout/attach trace in the app's
  tmp), `CMUX_NEXT_TERMINAL_DEBUG=1` (More → Drop Connection).

## Round 2: device dogfood fixes and e2e findings (2026-10-09)

Measured on the same simulator with the **software keyboard** shown: the headless
simulator reports a hardware keyboard, so a DEBUG-only harness
(`CMUX_NEXT_SOFTWARE_KEYBOARD=1`, simulator builds only) switches its input modes to
the software keyboard (the `setHardwareLayout:` UI-test trick). Not a device run.

| Item | Change | Evidence | Result |
| --- | --- | --- | --- |
| Key bar overlapped the last rows (device) | The key bar (and composer) are no longer an input accessory: the controller pins them to `view.keyboardLayoutGuide` (follows undocked keyboards). The terminal pans so the last row with text (or the cursor row, whichever is lower) sits on the top of the key bar/composer, never pushing the cursor row above the top. The bar has an opaque strip in the terminal background with a hairline, so text never shows between the glass keys. | `terminal/dogfood-keybar-pinning.png`: shell prompt, a codex-like TUI (`footertest`: footer "← for agents · ? for shortcuts" under the cursor) with the keyboard, and with the composer | pass: footer sits on the bar's top edge, nothing under the bar |
| Keyboard show/hide motion | same | 60 fps recording, consecutive-frame row matching: content only translates (residual ≤ 5/255), one decaying curve over ~23 frames each way, no step back | pass |
| Scrolling did not work on device | Pan begins on the translation (a slow drag starts at zero velocity, which the old velocity test refused); other pans (drawer) wait for it; the pointer position is set before each scroll so TUIs get wheel reports at the finger. Ghostty picks the behavior from the mirrored modes. | `terminal/dogfood-scroll.png`: (1) slow 2 s drag with the keyboard up scrolls the scrollback row by row (8 rows, recording `scroll.mp4` analysed); (2) `mousetest` (alt screen + SGR mouse): wheel reports `ESC[<64;26;8M` / `ESC[<65;…M` reach the host; (3) `alttest` (alt screen, no reporting): arrow keys `ESC[A` | pass |
| Composer row | Liquid Glass capsule above the key bar: `+` (Photos, Camera, Files), field growing 1→4 lines, Send (highlight). Send = paste (bracketed when the app enabled it) + Return; long-press Send → "Send Without Return"; empty Send = bare Return. Key bar's first key toggles composer/raw; tapping the terminal returns to raw typing. In composer mode the grid ends above the resting composer (a grid change, not keyboard-driven). | `terminal/dogfood-composer.png`: 4-line wrap; a photo uploaded with `fs.upload` and its quoted path inserted; composer at rest with the keyboard hidden (grid 50×42 → 50×38) | pass |
| `fs.upload` | Host: `providers/files.ts` writes `~/.cmux-next-host/uploads/<uuid>/<name>` (0600, dir 0700), 50 MB cap checked before decoding, name sanitized to one component; capability `fs.v1`; PROTOCOL §4 files. Swift: `HostClient.uploadFile` (180 s timeout); mock answers with a path. | `host/test/files.test.ts` (sanitizing, path layout, mode, no collision, size/base64/empty rejection); host suite 57/57, `tsc` clean | pass |
| e2e #10 host restart | A `not_found` attach shows "This Terminal Ended on the Mac" with New Terminal / Back to Terminals instead of the raw error. Also fixed: a failed attach retried in a hot loop (each reset redraw re-triggered attach); now it waits for the next connection. | `terminal/dogfood-ended.png` (DEBUG "Simulate Host Restart", then New Terminal opens a fresh shell) | pass |
| e2e #13 first `top` row under the nav bar | Same root cause as the overlap: the old pan aligned the cursor plus a margin to the bar. With the software keyboard up the grid still does not resize (D8), so a full-screen app's top rows sit under the nav bar while the keyboard is up; with the keyboard down nothing covers the grid. | screenshots above | fixed for the bar-only case; keyboard-up remains the D8 trade-off |
| e2e #17 stray `%` | `+` now opens the screen first; the screen creates the terminal with the grid that fits it and attaches with the same grid, so the shell never draws its first prompt at a different size. | trace: `attach grid=50x42` for the created terminal, no resize | pass (mock; zsh PROMPT_SP needs the real host) |
| e2e #18 settings font size | `AppPreferences` follows the shared `cmuxNext.terminalFontSize` default when the terminal writes it (pinch, Larger/Smaller Text); the terminal already followed settings. | code | not run in the Settings UI |

Remaining gaps: no real-device run (the coordinator reinstalls); Camera is device-only;
the real host's zsh `%` marker and `fs.upload` over WebRTC need the deployed host.

## Round 3: review fixes and keyboard row shrink (2026-10-09)

| Item | Change | Evidence | Result |
| --- | --- | --- | --- |
| Rows shrink with the keyboard (Aziz's decision, overrides D8) | While the software keyboard is up the grid is the space between the nav bar and the key bar/composer: content slides with the keyboard, then the grid locks and one `term.resize` goes out when the animation settles; on hide the grid grows back first and Ghostty's restored scrollback slides in. | `terminal/round3-keyboard-resize.png`: `top` 50×23 with header visible, shell prompt above the bar, codex-like footer TUI on the bar with its header visible, composer 50×18; `terminal/round3-keyboard-frames.png`: hide/show frames | pass: consecutive-frame row matching over 504 frames shows only translations (residual ≤ 7/255), no unexplained jump |
| Uploads blocked control replies / could exceed the lane limit | Chunked upload on the bulk lane: `fs.upload.begin {name, mimeType?, size}` → `{uploadId}`, `fileChunk` frames (kind 4, `[u32 seq]` + bytes), `fs.upload.end` → `{path}`, `fs.upload.cancel`. 50 MB checked from the file size before reading; files are read in 64 KiB chunks on the client actor and staged off the main actor. | host `test/files.test.ts` (5 tests: path layout, in-flight chunks at end, out-of-order/overlong/stalled/oversized, kind isolation, retention); simulator photo upload → quoted path | pass |
| Upload retention | Host removes `uploads/*` older than 7 days at startup and daily. | test | pass |
| Row reads per draw | The last content row is computed once per drawn frame (cached). | code | done |
| Orphan terminals | A terminal created for a screen whose attach fails or whose screen is gone is closed on the host. | code | done |

The `top` header lines in the mock wrap at 50 columns (the mock's fixed-width output), so with 23 rows its first lines scroll away; a real `top` redraws for the new size.
