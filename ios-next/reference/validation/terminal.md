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
