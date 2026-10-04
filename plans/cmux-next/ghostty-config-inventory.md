# Ghostty config inventory (R92)

Every key in ghostty-next `src/config/Config.zig` at 59a70ffc6 (the linked GhosttyNextKit; the
session host builds libghostty-vt from 31627e4b9, whose config keys are the same), with how
cmux-next handles it on 2026-10-04 (feat-cmux-next fd408fd11c4). Design: [ghostty-config.md](ghostty-config.md).

Columns. **Ghostty consumer**: where libghostty reads the key (renderer and core-surface keys work
inside an embedded surface; termio keys run in the viewer mirror too, but in MANUAL_MIRROR the
viewer drops every reply, so reply keys belong to the session host; `apprt-macos(Swift)` keys are
implemented only by Ghostty.app's Swift frontend, which cmux does not use, so cmux must implement
them). **Mac app**: respected, overridden (a cmux.json value replaces it), partial, ignored,
n/a-mirror (the session host owns it), n/a-embedder. **Session host**: the cmux-tui daemon that owns
the PTY and the canonical libghostty-vt terminal. **Plan**: ok, fix (applies to an embedder and is
not honored), precedence (cmux.json overlaps; the design moves it into the `ghostty` layer),
decide (cmux has its own concept; Lawrence picks apply or supersede), n/a (GTK, Linux desktop,
Ghostty.app identity or updater).

Totals: 210 keys. ok 89, fix 56 (+4 Linux cgroup keys on a Linux host), precedence 5, decide 22, n/a 34.

Paths in notes are relative to `Packages/macOS/CmuxNext/Sources/` unless they start with
`cmux-tui/` or name a Ghostty file.

| key | type, default | Ghostty consumer | Mac app | session host | plan | notes |
| --- | --- | --- | --- | --- | --- | --- |
| `language` | ?[:0]const u8 = null, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a | Ghostty.app GUI locale. cmux localizes with its own string catalogs. (no consumer in ghostty-next(@59a70ffc6)/src outside config) |
| `font-family` | RepeatableString = .{}, | renderer | overridden | n/a-viewer | precedence | User value respected unless cmux.json terminal.fontFamily is set. That override loads after the user files and first writes font-family="", so the user's whole fallback list is dropped (bold/italic families stay). (CmuxNextTerminal/GhosttyRuntime.swift:179-181; CmuxNextTerminal/GhosttyRuntime+Font.swift:23-28) |
| `font-family-bold` | RepeatableString = .{}, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `font-family-italic` | RepeatableString = .{}, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `font-family-bold-italic` | RepeatableString = .{}, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `font-style` | FontStyle = .{ .default = {} }, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `font-style-bold` | FontStyle = .{ .default = {} }, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `font-style-italic` | FontStyle = .{ .default = {} }, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `font-style-bold-italic` | FontStyle = .{ .default = {} }, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `font-synthetic-style` | FontSyntheticStyle = .{}, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `font-feature` | RepeatableString = .{}, | renderer | respected | n/a-viewer | ok | Renderer key.  |
| `font-size` | f32 = switch (builtin.os.tag) { | core-surface | overridden | n/a-viewer | precedence | User value respected unless cmux.json terminal.fontSize is set (loaded after user files, wins). Override rounds to an integer (13.5 -> 14). Per-tab zoom is stored as a scale of the resolved size. (CmuxNextTerminal/GhosttyRuntime.swift:179-181; CmuxNextTerminal/GhosttyRuntime+Font.swift:29-31; CmuxNextTerminal/TerminalFontScale.swift:11-16,45-50) |
| `font-variation` | RepeatableFontVariation = .{}, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `font-variation-bold` | RepeatableFontVariation = .{}, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `font-variation-italic` | RepeatableFontVariation = .{}, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `font-variation-bold-italic` | RepeatableFontVariation = .{}, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `font-codepoint-map` | RepeatableCodepointMap = .{}, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `clipboard-codepoint-map` | RepeatableClipboardCodepointMap = .{}, | core-surface | respected | n/a-viewer | ok | Applied on copy inside the core.  |
| `font-thicken` | bool = false, | renderer | respected | n/a-viewer | ok | Renderer key.  |
| `font-thicken-strength` | u8 = 255, | renderer | respected | n/a-viewer | ok | Renderer key.  |
| `font-shaping-break` | FontShapingBreak = .{}, | renderer | respected | n/a-viewer | ok | Renderer key.  |
| `alpha-blending` | AlphaBlending = | renderer | respected | n/a-viewer | ok | Renderer key.  |
| `adjust-cell-width` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `adjust-cell-height` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `adjust-font-baseline` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `adjust-underline-position` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `adjust-underline-thickness` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `adjust-strikethrough-position` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `adjust-strikethrough-thickness` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `adjust-overline-position` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `adjust-overline-thickness` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `adjust-cursor-thickness` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `adjust-cursor-height` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `adjust-box-thickness` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `adjust-icon-height` | ?MetricModifier = null, | renderer | respected | n/a-viewer | ok | Font grid is built inside libghostty per surface; cmux does not touch it.  |
| `grapheme-width-method` | GraphemeWidthMethod = .unicode, | termio | partial | ignored | fix | Mac mirror honors it, but the daemon VT core owns the authoritative grid and does not read this key; a non-default value can make mirror and owner disagree on cell widths. HOST: Host VT keeps the libghostty-vt default; viewer honors the key, so a non-default value desyncs cell widths (noted as the next hostsnap item). (ghostty-next(@59a70ffc6)/src/termio/Termio.zig; loaded CmuxNextTerminal/GhosttyRuntime.swift:170-175) |
| `freetype-load-flags` | FreetypeLoadFlags = .{}, | renderer | n/a-embedder | n/a-viewer | n/a | FreeType backend only; macOS uses CoreText. (ghostty-next(@59a70ffc6)/src/font/SharedGridSet.zig; loaded CmuxNextTerminal/GhosttyRuntime.swift:170-175) |
| `theme` | ?Theme = null, | cli/app-level | overridden | partial | fix | cmux default 'light:Apple System Colors Light,dark:Apple System Colors' loads BEFORE user files (user theme wins). cmux.json appearance.theme loads AFTER user files and replaces the user's theme; explicit background/foreground/palette lines still win. Per room/workspace/terminal themes rebuild the config with another theme (Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/GhosttyThemeConfig.swift:32-42). HOST: Host resolves `theme` with its own parser (light/dark from the host's appearance guess); cmux.json/workspace themes not pushed. (CmuxNextTerminal/GhosttyRuntime+DefaultTheme.swift:22-26; CmuxNextTerminal/GhosttyRuntime.swift:168,176-178) |
| `background` | Color = .{ .r = 0x28, .g = 0x2C, .b = 0x34 }, | renderer+termio | partial | partial | fix | Respected by renderer and read for chrome. When cmux.json appearance.surfaces.terminal.color is set the surfaces get background-opacity=0 and the host paints the cmux color instead (cmux wins). Daemon also parses it for its own defaults (cmux-tui/crates/cmux-tui/src/config.rs:4557). HOST: Host replies OSC 11 from its own parse; cmux theme overrides not pushed, so light/dark detection by apps can disagree with what the viewer shows. (CmuxNextTerminal/GhosttyRuntime+Theme.swift:35-56; CmuxNextTerminal/GhosttyRuntime.swift:219-226,195-202) S2B: restore keeps the owner bg for one frame (S2b fixes). |
| `foreground` | Color = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, | renderer+termio | respected | partial | fix | Renderer + chrome theme input. Not replaced by appearance.theme when set explicitly. HOST: Host replies OSC 10 from its own parse; cmux theme overrides not pushed. S2B: restore keeps the owner fg for one frame (S2b fixes). |
| `background-image` | ?Path = null, | renderer | respected | n/a-viewer | ok | Renderer. Interaction with cmux translucency (surfaces forced to background-opacity=0) not verified.  |
| `background-image-opacity` | f32 = 1.0, | renderer | respected | n/a-viewer | ok | Renderer. Interaction with cmux translucency (surfaces forced to background-opacity=0) not verified.  |
| `background-image-position` | BackgroundImagePosition = .center, | renderer | respected | n/a-viewer | ok | Renderer. Interaction with cmux translucency (surfaces forced to background-opacity=0) not verified.  |
| `background-image-fit` | BackgroundImageFit = .contain, | renderer | respected | n/a-viewer | ok | Renderer. Interaction with cmux translucency (surfaces forced to background-opacity=0) not verified.  |
| `background-image-repeat` | bool = false, | renderer | respected | n/a-viewer | ok | Renderer. Interaction with cmux translucency (surfaces forced to background-opacity=0) not verified.  |
| `selection-foreground` | ?TerminalColor = null, | renderer | respected | respected | ok | Renderer, also read for chrome theme. HOST: cmux-tui TUI client only.  |
| `selection-background` | ?TerminalColor = null, | renderer | respected | respected | ok | Renderer, also read for chrome theme. HOST: cmux-tui TUI client only (its own selection painting).  |
| `selection-clear-on-typing` | bool = true, | core-surface | respected | n/a-viewer | ok | Core selection logic.  |
| `selection-clear-on-copy` | bool = false, | core-surface | respected | n/a-viewer | ok | Core selection logic.  |
| `selection-word-chars` | SelectionWordChars = .{}, | core-surface | respected | n/a-viewer | ok | Core selection logic.  |
| `minimum-contrast` | f64 = 1, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `palette` | Palette = .{}, | termio | respected | partial | fix | Renderer + chrome theme input. Not replaced by appearance.theme when set explicitly. HOST: Host replies OSC 4 from its own Rust parse of the Ghostty files; cmux.json/workspace themes are not pushed (set-default-colors exists, Mac never calls it). S2B: a restored snapshot keeps the snapshot owner palette for one frame (S2b fixes). |
| `palette-generate` | bool = false, | termio | respected | n/a-viewer | ok | Mirror termio. Daemon answers OSC 4 queries with its own palette.  |
| `palette-harmonious` | bool = false, | termio | respected | n/a-viewer | ok | Mirror termio. Daemon answers OSC 4 queries with its own palette.  |
| `cursor-color` | ?TerminalColor = null, | renderer+termio | respected | partial | fix | Renderer; cmux also uses it for the copy-mode cursor box. HOST: Host replies OSC 12 from its own parse; cmux theme overrides not pushed.  |
| `cursor-opacity` | f64 = 1.0, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `cursor-style` | terminal.CursorStyle = .block, | termio | respected | respected | ok | Also forwarded as the stream's cursor default on replay (TerminalCursorDefault.user). HOST: Host DECSCUSR default from its own parse (config.rs:3380). S2B: a restored snapshot sets the host cursor style from the snapshot owner; Ghostty config must win (S2b lead fixes the restore path). |
| `cursor-style-blink` | ?bool = null, | core-surface+termio | respected | respected | ok | Also forwarded to the daemon spawn env for shell-integration cursor. HOST: Host default blink from its own parse.  |
| `cursor-text` | ?TerminalColor = null, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `cursor-click-to-move` | bool = true, | core-surface | respected | n/a-viewer | ok | Raw mouse events forwarded; MANUAL_MIRROR sends mouse reports to io_write_cb.  |
| `mouse-hide-while-typing` | bool = false, | core-surface | respected | n/a-viewer | ok | MOUSE_VISIBILITY handled with NSCursor.setHiddenUntilMouseMoves.  |
| `scroll-to-bottom` | ScrollToBottom = .default, | renderer+core-surface | respected | n/a-viewer | ok | Core.  |
| `mouse-shift-capture` | MouseShiftCapture = .false, | core-surface | respected | n/a-viewer | ok | Raw mouse events forwarded; MANUAL_MIRROR sends mouse reports to io_write_cb.  |
| `mouse-reporting` | bool = true, | core-surface | respected | n/a-viewer | ok | Raw mouse events forwarded; MANUAL_MIRROR sends mouse reports to io_write_cb.  |
| `mouse-scroll-multiplier` | MouseScrollMultiplier = .default, | core-surface | respected | n/a-viewer | ok | cmux applies the same 2x trackpad gain as Ghostty.app before the core multiplier.  |
| `background-opacity` | f64 = 1.0, | renderer+core-surface | overridden | n/a-viewer | precedence | Respected (drives the window sheet) unless cmux.json appearance.backgroundOpacity is set (loaded after user files, wins). When <1 the surfaces get background-opacity=0 and the window root paints the one sheet. (CmuxNextTerminal/GhosttyRuntime.swift:184-202; CmuxNextTerminal/GhosttyRuntime+Background.swift:29-44) |
| `background-opacity-cells` | bool = false, | renderer | respected | n/a-viewer | ok | Read: with it set cmux does not force background-opacity=0 on surfaces.  |
| `background-blur` | BackgroundBlur = .false, | renderer+core-surface | overridden | n/a-viewer | precedence | Respected through cmux's WindowBackdrop unless cmux.json appearance.backgroundBlur is set (loaded after user files, wins). (CmuxNextTerminal/GhosttyRuntime.swift:186-190; CmuxNextTerminal/GhosttyRuntime+Theme.swift:45-54) |
| `unfocused-split-opacity` | f64 = 0.7, | apprt-macos(Swift) | ignored | n/a-viewer | fix | Apprt dimming overlay not implemented. cmux has focus.inactiveTabStyle and appearance.focusIndicator instead. (no reader in ; Ghostty.app overlay (ghostty-next(@59a70ffc6)/macos/Sources/Ghostty/Ghostty.Config.swift)) R93: today a 0.14 Debug tunable; design makes the Ghostty key the owner. |
| `unfocused-split-fill` | ?Color = null, | apprt-macos(Swift) | ignored | n/a-viewer | fix | Apprt dimming overlay not implemented. cmux has focus.inactiveTabStyle and appearance.focusIndicator instead. (no reader in ; Ghostty.app overlay (ghostty-next(@59a70ffc6)/macos/Sources/Ghostty/Ghostty.Config.swift)) R93: design makes the Ghostty key the owner. |
| `split-divider-color` | ?Color = null, | apprt-macos(Swift) | ignored | n/a-viewer | fix | cmux pane chrome draws dividers (appearance.borders). (no reader in ) R93: design makes the Ghostty key the owner of the color; splitDivider.opacity stays cmux-only. |
| `split-preserve-zoom` | SplitPreserveZoom = .{}, | apprt-macos(Swift) | ignored | n/a-viewer | decide | Zoom state lives in the daemon layout. (no reader in ) |
| `search-foreground` | TerminalColor = .{ .color = .{ .r = 0, .g = 0, .b = 0 } }, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `search-background` | TerminalColor = .{ .color = .{ .r = 0xFF, .g = 0xE0, .b = 0x82 } }, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `search-selected-foreground` | TerminalColor = .{ .color = .{ .r = 0, .g = 0, .b = 0 } }, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `search-selected-background` | TerminalColor = .{ .color = .{ .r = 0xF2, .g = 0xA5, .b = 0x7E } }, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `command` | ?Command = null, | core-surface | n/a-mirror | ignored | fix | Daemon (cmux-tui) spawns the process; cmux does not forward these keys. HOST: Host runs SurfaceOptions.command or the platform shell (surface.rs:2333); the Mac never sends Ghostty `command`. (ghostty-next(@59a70ffc6)/include/ghostty.h:513-544 (MANUAL/MANUAL_MIRROR spawn nothing, drop replies)) |
| `initial-command` | ?Command = null, | core-surface | n/a-mirror | ignored | fix | Daemon (cmux-tui) spawns the process; cmux does not forward these keys. HOST: No first-surface command; host spawns the default shell. (ghostty-next(@59a70ffc6)/include/ghostty.h:513-544 (MANUAL/MANUAL_MIRROR spawn nothing, drop replies)) |
| `notify-on-command-finish` | NotifyOnCommandFinish = .never, | core-surface | ignored | ignored | fix | COMMAND_FINISHED only sets model.lastCommand, which nothing reads. Overlaps cmux.json status.runNotifyMinimumSeconds / status.runNotifyWhenVisible (daemon-driven). HOST: Host has OSC 133 command lifecycle but no Ghostty-keyed policy. (CmuxNextTerminal/TerminalSurfaceView+Actions.swift:48-49) |
| `notify-on-command-finish-action` | NotifyOnCommandFinishAction = .{ | core-surface | ignored | n/a-viewer | fix | COMMAND_FINISHED only sets model.lastCommand, which nothing reads. Overlaps cmux.json status.runNotifyMinimumSeconds / status.runNotifyWhenVisible (daemon-driven). (CmuxNextTerminal/TerminalSurfaceView+Actions.swift:48-49) |
| `notify-on-command-finish-after` | Duration = .{ .duration = 5 * std.time.ns_per_s }, | core-surface | ignored | n/a-viewer | fix | COMMAND_FINISHED only sets model.lastCommand, which nothing reads. Overlaps cmux.json status.runNotifyMinimumSeconds / status.runNotifyWhenVisible (daemon-driven). (CmuxNextTerminal/TerminalSurfaceView+Actions.swift:48-49) |
| `env` | RepeatableStringMap = .{}, | core-surface | n/a-mirror | ignored | fix | Daemon (cmux-tui) spawns the process; cmux does not forward these keys. HOST: Mac sends login env + TerminalEnvironment (TERM, COLORTERM, TERM_PROGRAM); Ghostty `env` entries are not merged (CmuxNextDaemon/Launch/TerminalEnvironment.swift:103). (ghostty-next(@59a70ffc6)/include/ghostty.h:513-544 (MANUAL/MANUAL_MIRROR spawn nothing, drop replies)) |
| `input` | RepeatableReadableIO = .{}, | core-surface+termio | n/a-mirror | ignored | fix | MANUAL_MIRROR does not send the global input config. HOST: No initial input is written to new terminals. (ghostty-next(@59a70ffc6)/include/ghostty.h:513-544 (MANUAL/MANUAL_MIRROR spawn nothing, drop replies)) |
| `wait-after-command` | bool = false, | core-surface | n/a-mirror | ignored | fix | Process lifetime is owned by the daemon. HOST: Host lifecycle policy ignores it. (ghostty-next(@59a70ffc6)/include/ghostty.h:513-544 (MANUAL/MANUAL_MIRROR spawn nothing, drop replies)) |
| `abnormal-command-exit-runtime` | u32 = 250, | core-surface | n/a-mirror | ignored | fix | Process lifetime is owned by the daemon. HOST: Host lifecycle policy ignores it. (ghostty-next(@59a70ffc6)/include/ghostty.h:513-544 (MANUAL/MANUAL_MIRROR spawn nothing, drop replies)) |
| `scrollback-limit-bytes` | Limit(usize, 50_000_000) = .default, | termio | respected | respected | ok | Mirror honors it and the daemon parses it from the same files with its own parser. HOST: Own Rust parser of the Ghostty files (cmux-tui/src/config.rs:4606-4690), incl. legacy `scrollback-limit`.  |
| `scrollback-limit-lines` | Limit(usize, std.math.maxInt(usize)) = .default, | termio | partial | ignored | fix | Mirror honors it; the daemon parser reads only scrollback-limit/scrollback-limit-bytes, so the authoritative scrollback ignores it. HOST: GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES not set; authoritative scrollback ignores it while the Mac mirror honors it. (ghostty-next(@59a70ffc6)/src/termio/Termio.zig; loaded CmuxNextTerminal/GhosttyRuntime.swift:170-175; cmux-tui/crates/cmux-tui/src/config.rs:4673) |
| `scrollback-compression` | bool = true, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `scrollbar` | Scrollbar = .system, | apprt-macos(Swift) | ignored | n/a-viewer | fix | SCROLLBAR action only stored in model.scrollbar; no terminal scroller is drawn. (CmuxNextTerminal/TerminalSurfaceView+Actions.swift:60-63) |
| `link` | RepeatableLink = .{}, | renderer+core-surface | respected | n/a-viewer | ok | Core detects links; OPEN_URL opens web links in a cmux browser tab.  |
| `link-url` | bool = true, | cli/app-level | respected | n/a-viewer | ok | Core detects links; OPEN_URL opens web links in a cmux browser tab.  |
| `link-osc8` | bool = true, | core-surface | respected | n/a-viewer | ok | Core detects links; OPEN_URL opens web links in a cmux browser tab.  |
| `link-previews` | LinkPreviews = .true, | core-surface | ignored | n/a-viewer | fix | MOUSE_OVER_LINK stored in model.hoveredLink, used only by the context menu; no hover URL preview. (CmuxNextTerminal/TerminalSurfaceView+Actions.swift:38-39; CmuxNextApp/TerminalHostDelegate.swift:31) |
| `maximize` | bool = false, | apprt-macos(Swift) | ignored | n/a-viewer | fix | Initial window state; cmux restores its own windows. (no reader in ) |
| `fullscreen` | Fullscreen = .false, | core-surface | ignored | n/a-viewer | fix | Initial window state; cmux restores its own windows. (no reader in ) |
| `title` | ?[:0]const u8 = null, | core-surface | partial | n/a-viewer | fix | Core forces the title into SET_TITLE and blocks OSC titles; cmux puts it in model.title (remote/control topology) but sidebar tab names come from the daemon. (ghostty-next(@59a70ffc6)/src/Surface.zig:876,1985; CmuxNextTerminal/TerminalSurfaceView+Actions.swift:17-18) |
| `class` | ?[:0]const u8 = null, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (GTK/X11 only) |
| `x11-instance-name` | ?[:0]const u8 = null, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (GTK/X11 only) |
| `working-directory` | ?WorkingDirectory = null, | core-surface | n/a-mirror | ignored | fix | Daemon (cmux-tui) spawns the process; cmux does not forward these keys. HOST: cwd comes from cmux new-tab/split rules; Ghostty `working-directory` (home/inherit/path) is not read. (ghostty-next(@59a70ffc6)/include/ghostty.h:513-544 (MANUAL/MANUAL_MIRROR spawn nothing, drop replies)) |
| `keybind` | Keybinds = .{}, | core-surface | partial | n/a-viewer | fix | In a terminal Ghostty keybinds run, but the cmux binding table and main menu run first for any chord cmux binds (all tiers). cmux pre-loads super+j=unbind (Cmd-J leader). Split/tab/window actions are mapped to registry actions; quit/close_all_windows/toggle_maximize/inspector/undo/redo/check_for_updates route to nil; many actions are undecoded (quick terminal, toggle_visibility, goto_window, ...). global: binds need an event tap: none. Outside a terminal only a fixed routable list is matched, one chord per action. (CmuxNextTerminal/GhosttyRuntime.swift:169; CmuxNextTerminal/GhosttyRuntime+Keybinds.swift:12-19; CmuxNextApp/Focus/KeyRouter.swift:118-129,360-372; CmuxNextTerminal/TerminalSurfaceView+Keyboard.swift:97-112) |
| `key-remap` | KeyRemapSet = .empty, | core-surface | respected | n/a-viewer | ok | Inside Ghostty only. cmux's key router matches cmux shortcuts on the raw NSEvent before the remap.  |
| `window-padding-x` | WindowPadding = .{ .top_left = 2, .bottom_right = 2 }, | core-surface | respected | n/a-viewer | ok | cmux default (PaneChromeMetrics.terminalTextInset, balance false) loads BEFORE user files, so user values win; read back for host geometry.  |
| `window-padding-y` | WindowPadding = .{ .top_left = 2, .bottom_right = 2 }, | core-surface | respected | n/a-viewer | ok | cmux default (PaneChromeMetrics.terminalTextInset, balance false) loads BEFORE user files, so user values win; read back for host geometry.  |
| `window-padding-balance` | WindowPaddingBalance = .false, | core-surface | respected | n/a-viewer | ok | cmux default (PaneChromeMetrics.terminalTextInset, balance false) loads BEFORE user files, so user values win; read back for host geometry.  |
| `window-padding-color` | WindowPaddingColor = .background, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `window-vsync` | bool = true, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `window-inherit-working-directory` | bool = true, | core-surface | n/a-mirror | ignored | fix | New terminals are spawned by the daemon with cmux's own cwd rules. HOST: cmux cwd rules; Ghostty key not read. (ghostty-next(@59a70ffc6)/src/apprt/surface.zig) |
| `tab-inherit-working-directory` | bool = true, | core-surface | n/a-mirror | ignored | fix | New terminals are spawned by the daemon with cmux's own cwd rules. HOST: cmux cwd rules; Ghostty key not read. (ghostty-next(@59a70ffc6)/src/apprt/surface.zig) |
| `split-inherit-working-directory` | bool = true, | core-surface | n/a-mirror | ignored | fix | New terminals are spawned by the daemon with cmux's own cwd rules. HOST: cmux cwd rules; Ghostty key not read. (ghostty-next(@59a70ffc6)/src/apprt/surface.zig) |
| `window-inherit-font-size` | bool = true, | core-surface | ignored | n/a-viewer | fix | Surfaces are created without an inherited font_size; zoom is a per-tab scale (TerminalFontScale). (ghostty-next(@59a70ffc6)/src/apprt/embedded.zig:1251; CmuxNextTerminal/TerminalSurfaceView.swift:113) |
| `window-decoration` | WindowDecoration = .auto, | apprt-macos(Swift) | ignored | n/a-viewer | decide | Window apprt key. cmux owns window chrome (cmux.json window.titlebar) and tab placement. (no reader in ) |
| `window-title-font-family` | ?[:0]const u8 = null, | apprt-macos(Swift) | ignored | n/a-viewer | decide | Window apprt key. cmux owns window chrome (cmux.json window.titlebar) and tab placement. (no reader in ) |
| `window-subtitle` | WindowSubtitle = .false, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (GTK only per Config.zig docs) |
| `window-theme` | WindowTheme = .auto, | apprt-macos(Swift) | ignored | n/a-viewer | decide | Window apprt key. cmux owns window chrome (cmux.json window.titlebar) and tab placement. (no reader in ) |
| `window-colorspace` | WindowColorspace = .srgb, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `window-height` | u32 = 0, | core-surface | ignored | n/a-viewer | fix | Window apprt key. cmux owns window chrome (cmux.json window.titlebar) and tab placement. (no reader in ) |
| `window-width` | u32 = 0, | core-surface | ignored | n/a-viewer | fix | Window apprt key. cmux owns window chrome (cmux.json window.titlebar) and tab placement. (no reader in ) |
| `window-position-x` | ?i16 = null, | apprt-macos(Swift) | ignored | n/a-viewer | fix | Window apprt key. cmux owns window chrome (cmux.json window.titlebar) and tab placement. (no reader in ) |
| `window-position-y` | ?i16 = null, | apprt-macos(Swift) | ignored | n/a-viewer | fix | Window apprt key. cmux owns window chrome (cmux.json window.titlebar) and tab placement. (no reader in ) |
| `window-save-state` | WindowSaveState = .default, | apprt-macos(Swift) | ignored | n/a-viewer | fix | cmux restores windows from its own state and daemon sessions. (no reader in ) |
| `window-step-resize` | bool = false, | apprt-macos(Swift) | ignored | n/a-viewer | decide | Window apprt key. cmux owns window chrome (cmux.json window.titlebar) and tab placement. (no reader in ) |
| `window-new-tab-position` | WindowNewTabPosition = .current, | apprt-macos(Swift) | ignored | n/a-viewer | decide | Window apprt key. cmux owns window chrome (cmux.json window.titlebar) and tab placement. (no reader in ) |
| `window-show-tab-bar` | WindowShowTabBar = .auto, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a | cmux draws its own pane tab strips. (GTK/macOS native tab bar) |
| `window-titlebar-background` | ?Color = null, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (GTK only per Config.zig docs) |
| `window-titlebar-foreground` | ?Color = null, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (GTK only per Config.zig docs) |
| `drag-handle` | DragHandle = .auto, | apprt-macos(Swift) | n/a-embedder | n/a-viewer | n/a | cmux has its own tab drag. (Ghostty.app surface drag handle) |
| `resize-overlay` | ResizeOverlay = .@"after-first", | apprt-macos(Swift) | ignored | n/a-viewer | fix | Apprt grid-size overlay not implemented. (no reader in ) |
| `resize-overlay-position` | ResizeOverlayPosition = .center, | apprt-macos(Swift) | ignored | n/a-viewer | fix | Apprt grid-size overlay not implemented. (no reader in ) |
| `resize-overlay-duration` | Duration = .{ .duration = 750 * std.time.ns_per_ms }, | apprt-macos(Swift) | ignored | n/a-viewer | fix | Apprt grid-size overlay not implemented. (no reader in ) |
| `focus-follows-mouse` | bool = false, | apprt-macos(Swift) | ignored | n/a-viewer | fix | Not implemented. (no reader in ) |
| `clipboard-read` | ClipboardAccess = .ask, | core-surface | n/a-mirror | ignored | fix | MANUAL_MIRROR drops OSC 52/5522 reads on the Mac; the daemon answers and does not read this key, so the user's allow/deny/ask has no effect. HOST: GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ not wired: OSC 52 reads are silently denied; Ghostty default `ask` never prompts. (ghostty-next(@59a70ffc6)/include/ghostty.h:513-544 (MANUAL/MANUAL_MIRROR spawn nothing, drop replies)) |
| `clipboard-write` | ClipboardAccess = .allow, | core-surface+termio | respected | respected | ok | Core decides allow/deny/ask; cmux shows a sheet when confirm=true. HOST: Each Mac viewer performs OSC 52 writes per its own config (writes are not reply requests). Two attached Macs both write.  |
| `clipboard-write-limit-bytes` | Limit(usize, 64 * 1024 * 1024) = .default, | termio | respected | respected | ok | Mirror termio. image-storage-limit in the daemon is not read from this key. HOST: Viewer-side (Kitty OSC 5522).  |
| `clipboard-trim-trailing-spaces` | bool = true, | core-surface | respected | n/a-viewer | ok | Core.  |
| `clipboard-paste-protection` | bool = true, | core-surface | respected | n/a-viewer | ok | Unsafe paste confirmation sheet.  |
| `clipboard-paste-bracketed-safe` | bool = true, | core-surface | respected | n/a-viewer | ok | Core.  |
| `title-report` | bool = false, | core-surface | n/a-mirror | ignored | fix | Replies are dropped on the Mac; the daemon VT core answers with its defaults and does not read this key. HOST: GHOSTTY_TERMINAL_OPT_TITLE_REPORT not wired; default false matches Ghostty default only. (ghostty-next(@59a70ffc6)/include/ghostty.h:513-544 (MANUAL/MANUAL_MIRROR spawn nothing, drop replies)) |
| `image-storage-limit` | u32 = 320 * 1000 * 1000, | termio | respected | overridden | precedence | Mirror termio. image-storage-limit in the daemon is not read from this key. HOST: Host uses its own global kitty budget (mux.rs:402 kitty_image_limits_for_capacity).  |
| `copy-on-select` | CopyOnSelect = switch (builtin.os.tag) { | core-surface | respected | n/a-viewer | ok | supports_selection_clipboard=true; selection goes to private pasteboard com.cmuxterm.next.selection (not Ghostty.app's).  |
| `right-click-action` | RightClickAction = .@"context-menu", | core-surface | respected | n/a-viewer | ok | Core consumes non-menu actions; context-menu falls through to the cmux registry menu.  |
| `middle-click-action` | MiddleClickAction = .@"primary-paste", | core-surface | respected | n/a-viewer | ok | Middle button forwarded; core pastes from the selection pasteboard.  |
| `click-repeat-interval` | u32 = 0, | core-surface | respected | n/a-viewer | ok | Raw mouse events forwarded; MANUAL_MIRROR sends mouse reports to io_write_cb.  |
| `config-file` | RepeatablePath = .{}, | cli/app-level | respected | partial | fix | ghostty_config_load_recursive_files. HOST: Host parser follows includes but not `?optional` semantics/conditional sections exactly like libghostty (separate implementation).  |
| `config-default-files` | bool = true, | cli/app-level | n/a-embedder | n/a-viewer | n/a | CLI-only flag; cmux never loads CLI args and always loads default files (or CMUX_NEXT_GHOSTTY_CONFIG). (CmuxNextTerminal/GhosttyRuntime.swift:170-175) |
| `confirm-close-surface` | ConfirmCloseSurface = .true, | core-surface | ignored | n/a-viewer | fix | processAlive is discarded and TerminalHostDelegate does not implement terminalSessionDidRequestClose (default no-op). cmux closes tabs via the daemon without this check; app.quitBehavior only covers quit. (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:145-150; CmuxNextTerminal/TerminalSurfaceModel.swift:70) |
| `quit-after-last-window-closed` | bool = builtin.os.tag == .linux, | apprt-macos(Swift) | ignored | n/a-viewer | fix | Hard-coded false; sessions live in the daemon. QUIT_TIMER not decoded. (CmuxNextApp/AppDelegate.swift:260-262) |
| `quit-after-last-window-closed-delay` | ?Duration = null, | apprt-gtk | ignored | n/a-viewer | fix | Hard-coded false; sessions live in the daemon. QUIT_TIMER not decoded. (CmuxNextApp/AppDelegate.swift:260-262) |
| `initial-window` | bool = true, | apprt-macos(Swift) | ignored | n/a-viewer | decide | Initial window state; cmux restores its own windows. (no reader in ) |
| `undo-timeout` | Duration = .{ .duration = 5 * std.time.ns_per_s }, | apprt-macos(Swift) | ignored | n/a-viewer | decide | UNDO/REDO route to nil. (CmuxNextApp/TerminalHostActionRoute.swift:50-51) |
| `quick-terminal-position` | QuickTerminalPosition = .top, | apprt-macos(Swift) | ignored | n/a-viewer | decide | TOGGLE_QUICK_TERMINAL is not decoded; no quick terminal. (CmuxNextTerminal/GhosttyActionDecoder.swift:129-130) |
| `quick-terminal-size` | QuickTerminalSize = .{}, | apprt-macos(Swift) | ignored | n/a-viewer | decide | TOGGLE_QUICK_TERMINAL is not decoded; no quick terminal. (CmuxNextTerminal/GhosttyActionDecoder.swift:129-130) |
| `gtk-quick-terminal-layer` | QuickTerminalLayer = .top, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Wayland/GTK only) |
| `gtk-quick-terminal-namespace` | [:0]const u8 = "ghostty-quick-terminal", | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Wayland/GTK only) |
| `quick-terminal-screen` | QuickTerminalScreen = .main, | apprt-macos(Swift) | ignored | n/a-viewer | decide | TOGGLE_QUICK_TERMINAL is not decoded; no quick terminal. (CmuxNextTerminal/GhosttyActionDecoder.swift:129-130) |
| `quick-terminal-animation-duration` | f64 = 0.2, | apprt-macos(Swift) | ignored | n/a-viewer | decide | TOGGLE_QUICK_TERMINAL is not decoded; no quick terminal. (CmuxNextTerminal/GhosttyActionDecoder.swift:129-130) |
| `quick-terminal-autohide` | bool = switch (builtin.os.tag) { | apprt-macos(Swift) | ignored | n/a-viewer | decide | TOGGLE_QUICK_TERMINAL is not decoded; no quick terminal. (CmuxNextTerminal/GhosttyActionDecoder.swift:129-130) |
| `quick-terminal-space-behavior` | QuickTerminalSpaceBehavior = .move, | apprt-macos(Swift) | ignored | n/a-viewer | decide | TOGGLE_QUICK_TERMINAL is not decoded; no quick terminal. (CmuxNextTerminal/GhosttyActionDecoder.swift:129-130) |
| `quick-terminal-keyboard-interactivity` | QuickTerminalKeyboardInteractivity = .@"on-demand", | apprt-gtk | n/a-embedder | n/a-viewer | n/a |  (Wayland/GTK only) |
| `shell-integration` | ShellIntegration = .detect, | core-surface | respected | partial | fix | Read at each spawn and forwarded to the daemon's GhosttyShellIntegration env (spawn key implemented by cmux). Shown in Settings > Terminal. HOST: Mac applies mode/features as env, but the host ALSO injects its own copy (shell_integration.rs:77, scripts from the old ghostty/ submodule) for zsh/fish/bash spawned without shell_args: `shell-integration = none` is not honored for zsh/fish, and a user ZDOTDIR can be lost (host overwrites GHOSTTY_ZSH_ZDOTDIR). Needs a red test.  |
| `shell-integration-features` | ShellIntegrationFeatures = .{}, | core-surface | respected | respected | ok | Read at each spawn and forwarded to the daemon's GhosttyShellIntegration env (spawn key implemented by cmux). Shown in Settings > Terminal. HOST: GHOSTTY_SHELL_FEATURES from the Mac env reaches the shell.  |
| `command-palette-entry` | RepeatableCommand = .{}, | apprt-macos(Swift) | ignored | n/a-viewer | decide | cmux palette uses its own action catalog. (no reader in ) |
| `osc-color-report-format` | OSCColorReportFormat = .@"16-bit", | termio | n/a-mirror | ignored | fix | Replies are dropped on the Mac; the daemon VT core answers with its defaults and does not read this key. HOST: Host is the only replier in MANUAL_MIRROR (stream_handler.zig:240-258); host never reads the key. (ghostty-next(@59a70ffc6)/include/ghostty.h:513-544 (MANUAL/MANUAL_MIRROR spawn nothing, drop replies)) |
| `vt-kam-allowed` | bool = false, | core-surface | respected | n/a | ok | Mirror parses output, so KAM locks Mac input when allowed. HOST: Input encoding happens in the viewer.  |
| `vt-window-resize-allowed` | bool = false, | core-surface | n/a-mirror | ignored | fix | Grid is owned by the daemon; RESIZE_WINDOW / size actions are not decoded. HOST: CSI 8 t resize requests are not handled by the host; canonical grid size is smallest-viewer. (ghostty-next(@59a70ffc6)/src/Surface.zig:534; CmuxNextTerminal/GhosttyActionDecoder.swift:129-130) |
| `custom-shader` | RepeatablePath = .{}, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `custom-shader-animation` | CustomShaderAnimation = .true, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `bell-features` | BellFeatures = .{}, | apprt-macos(Swift) | ignored | n/a-viewer | fix | Every BEL calls NSSound.beep() (delegate default), even though Ghostty's default is attention,title without system. No attention/title/border. bellCount is not observed. (CmuxNextTerminal/TerminalSurfaceView+Actions.swift:21-27; CmuxNextTerminal/TerminalSurfaceModel.swift:67-69) |
| `bell-audio-path` | ?Path = null, | apprt-macos(Swift) | ignored | n/a-viewer | fix |  (no reader in ) |
| `bell-audio-volume` | f64 = 0.5, | apprt-macos(Swift) | ignored | n/a-viewer | fix |  (no reader in ) |
| `app-notifications` | AppNotifications = .{}, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (GTK toasts) |
| `macos-non-native-fullscreen` | NonNativeFullscreen = .false, | core-surface | ignored | n/a-viewer | decide | toggle_fullscreen maps to cmux toggleFullScreen; mode ignored. (CmuxNextApp/TerminalHostActionRoute.swift:42-43) |
| `macos-window-buttons` | MacWindowButtons = .visible, | apprt-macos(Swift) | ignored | n/a-viewer | decide | Window/Dock apprt key; cmux owns window chrome (window.titlebar). (no reader in ) |
| `macos-titlebar-style` | MacTitlebarStyle = .transparent, | apprt-macos(Swift) | ignored | n/a-viewer | decide | Window/Dock apprt key; cmux owns window chrome (window.titlebar). (no reader in ) |
| `macos-titlebar-proxy-icon` | MacTitlebarProxyIcon = .visible, | apprt-macos(Swift) | ignored | n/a-viewer | decide | Window/Dock apprt key; cmux owns window chrome (window.titlebar). (no reader in ) |
| `macos-dock-drop-behavior` | MacOSDockDropBehavior = .@"new-tab", | apprt-macos(Swift) | ignored | n/a-viewer | decide | Window/Dock apprt key; cmux owns window chrome (window.titlebar). (no reader in ) |
| `macos-option-as-alt` | ?inputpkg.OptionAsAlt = null, | core-surface | respected | n/a-viewer | ok | ghostty_surface_key_translation_mods decides translation.  |
| `macos-window-shadow` | bool = true, | apprt-macos(Swift) | ignored | n/a-viewer | decide | Window/Dock apprt key; cmux owns window chrome (window.titlebar). (no reader in ) |
| `macos-hidden` | MacHidden = .never, | apprt-macos(Swift) | ignored | n/a-viewer | decide | Window/Dock apprt key; cmux owns window chrome (window.titlebar). (no reader in ) |
| `macos-auto-secure-input` | bool = true, | apprt-macos(Swift) | ignored | n/a-viewer | fix | Password detection needs a pty termios; MANUAL_MIRROR has none, so it never fires. The toggle keybind path does not check this key. (ghostty-next(@59a70ffc6)/src/Surface.zig:1548; CmuxNextTerminal/TerminalSecureInput.swift:10-22) |
| `macos-secure-input-indication` | bool = true, | apprt-macos(Swift) | ignored | n/a-viewer | fix | No lock indicator. (no reader in ) |
| `macos-applescript` | bool = true, | apprt-macos(Swift) | n/a-embedder | n/a-viewer | n/a | cmux has its own CLI and socket. (Ghostty.app scripting/intents) |
| `macos-icon` | MacAppIcon = .official, | apprt-macos(Swift) | n/a-embedder | n/a-viewer | n/a |  (Ghostty.app icon) |
| `macos-custom-icon` | ?[:0]const u8 = null, | apprt-macos(Swift) | n/a-embedder | n/a-viewer | n/a |  (Ghostty.app icon) |
| `macos-icon-frame` | MacAppIconFrame = .aluminum, | apprt-macos(Swift) | n/a-embedder | n/a-viewer | n/a |  (Ghostty.app icon) |
| `macos-icon-ghost-color` | ?Color = null, | apprt-macos(Swift) | n/a-embedder | n/a-viewer | n/a |  (Ghostty.app icon) |
| `macos-icon-screen-color` | ?ColorList = null, | apprt-macos(Swift) | n/a-embedder | n/a-viewer | n/a |  (Ghostty.app icon) |
| `macos-shortcuts` | MacShortcuts = .ask, | apprt-macos(Swift) | n/a-embedder | n/a-viewer | n/a | cmux has its own CLI and socket. (Ghostty.app scripting/intents) |
| `linux-cgroup` | LinuxCgroup = if (builtin.os.tag == .linux) | apprt-gtk | n/a-embedder | ignored | fix (Linux host) |  HOST: Host on Linux (Cloud VM) does not use per-terminal cgroups. (Linux/GTK only) |
| `linux-cgroup-memory-limit` | ?u64 = null, | gtk/linux-only | n/a-embedder | ignored | fix (Linux host) |  HOST: As linux-cgroup. (Linux/GTK only) |
| `linux-cgroup-processes-limit` | ?u64 = null, | gtk/linux-only | n/a-embedder | ignored | fix (Linux host) |  HOST: As linux-cgroup. (Linux/GTK only) |
| `linux-cgroup-hard-fail` | bool = false, | gtk/linux-only | n/a-embedder | ignored | fix (Linux host) |  HOST: As linux-cgroup. (Linux/GTK only) |
| `gtk-opengl-debug` | bool = builtin.mode == .Debug, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Linux/GTK only) |
| `gtk-single-instance` | GtkSingleInstance = .default, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Linux/GTK only) |
| `gtk-titlebar` | bool = true, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Linux/GTK only) |
| `gtk-tabs-location` | GtkTabsLocation = .top, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Linux/GTK only) |
| `gtk-titlebar-hide-when-maximized` | bool = false, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Linux/GTK only) |
| `gtk-toolbar-style` | GtkToolbarStyle = .raised, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Linux/GTK only) |
| `gtk-titlebar-style` | GtkTitlebarStyle = .native, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Linux/GTK only) |
| `gtk-wide-tabs` | bool = true, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Linux/GTK only) |
| `gtk-horizontal-tab-scroll` | bool = true, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Linux/GTK only) |
| `gtk-custom-css` | RepeatablePath = .{}, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Linux/GTK only) |
| `desktop-notifications` | bool = true, | core-surface | respected | n/a | ok | DESKTOP_NOTIFICATION is undecoded on purpose; the daemon parses OSC 9/777/99 and cmux reads this key per arrival. HOST: Host classifies OSC 9/777/99 for cmux notifications (terminal_metadata.rs); the gate is applied by the Mac (NotificationCenterService.swift:39-44).  |
| `progress-style` | bool = true, | gtk/linux-only | ignored | n/a-viewer | fix | Mac PROGRESS_REPORT only sets model.progress (unread); tab progress comes from the daemon and ignores this key. (CmuxNextTerminal/TerminalSurfaceView+Actions.swift:46-47) |
| `bold-color` | ?BoldColor = null, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `faint-opacity` | f64 = 0.5, | renderer | respected | n/a-viewer | ok | Renderer key (custom shaders, colorspace and vsync are applied by the Metal renderer itself).  |
| `term` | []const u8 = "xterm-ghostty", | core-surface | n/a-mirror | overridden | fix | Daemon (cmux-tui) spawns the process; cmux does not forward these keys. HOST: Mac sets TERM=xterm-ghostty only when bundled terminfo exists, else xterm-256color (TerminalEnvironment.swift:103-110); host sets TERM from SurfaceOptions.term (surface.rs:2345). Ghostty `term` value is not read. XTGETTCAP TN unset (GHOSTTY_TERMINAL_OPT_TERMINFO_NAME not wired). (ghostty-next(@59a70ffc6)/include/ghostty.h:513-544 (MANUAL/MANUAL_MIRROR spawn nothing, drop replies)) |
| `enquiry-response` | []const u8 = "", | termio | n/a-mirror | ignored | fix | Replies are dropped on the Mac; the daemon VT core answers with its defaults and does not read this key. HOST: GHOSTTY_TERMINAL_OPT_ENQUIRY not wired; reply is empty (same as Ghostty default, wrong for a non-default value). (ghostty-next(@59a70ffc6)/include/ghostty.h:513-544 (MANUAL/MANUAL_MIRROR spawn nothing, drop replies)) |
| `async-backend` | AsyncBackend = .auto, | gtk/linux-only | n/a-embedder | n/a-viewer | n/a |  (Linux/GTK only) |
| `auto-update` | ?AutoUpdate = null, | apprt-macos(Swift) | n/a-embedder | n/a-viewer | n/a | cmux has its own updater. (Ghostty.app Sparkle) |
| `auto-update-channel` | ?build_config.ReleaseChannel = null, | apprt-macos(Swift) | n/a-embedder | n/a-viewer | n/a | cmux has its own updater. (Ghostty.app Sparkle) |

## Bugs found during the inventory

1. Every BEL plays `NSSound.beep()` (delegate default, `CmuxNextTerminal/TerminalSurfaceModel.swift:67-69`). Ghostty's default `bell-features = attention,title` makes no system sound. Every attached viewer beeps.
2. `terminal.fontFamily` writes `font-family = ""` first and drops the user's whole fallback list (`GhosttyRuntime+Font.swift:27`).
3. `terminal.fontSize` rounds to an integer (`GhosttyRuntime+Font.swift:30`); Ghostty accepts 13.5.
4. `appearance.theme` replaces `theme`, but explicit user colors still win: a mixed theme with no warning.
5. Session host shell integration: the host injects its own copy (scripts from the old `ghostty/` submodule, `cmux-tui/crates/cmux-tui-core/src/shell_integration.rs:77`) on top of the Mac's Ghostty integration for zsh/fish (spawned without `shell_args`). `shell-integration = none` is not honored for those shells, and a user `ZDOTDIR` can be lost because the host overwrites `GHOSTTY_ZSH_ZDOTDIR` with the Mac's integration dir. Needs a red test before the fix.
6. The host is the only replier in MANUAL_MIRROR (`ghostty-next src/termio/stream_handler.zig:240-258`) but wires none of ENQUIRY, TITLE_REPORT, CLIPBOARD_READ, COLOR_SCHEME, SIZE, TERMINFO_NAME, SCROLLBACK_MAX_LINES; OSC 52 reads are silently denied, CSI 14/16/18 t and CSI ? 996 n get no reply, XTVERSION says `libghostty`.
7. The host replies OSC 4/10/11/12 from its own parse of the Ghostty files. cmux.json and workspace themes never reach it (`set-default-colors` exists, the Mac never calls it), so apps detect light/dark against colors the viewer does not show.
8. Three Ghostty parsers exist: libghostty (Mac), `cmux-tui/crates/cmux-tui/src/config.rs` (colors, theme, cursor, scrollback) and `cmux-tui/crates/cmux-theme-tokens/src/config.rs` (chrome colors). The two Rust ones re-implement Ghostty syntax and diverge from it.
9. "Open Ghostty Settings" and the Settings Terminal card always use `~/.config/ghostty/config` and create it when missing, even when the user's file is `config.ghostty` or in Application Support (`CmuxNextApp/Handlers/SettingsHandlers.swift:58-63`, `CmuxNextApp/Settings/SettingsWindowService.swift:144-147`).
10. With no user Ghostty config, libghostty writes a template file into Ghostty.app's Application Support folder at the first cmux launch (`Config.zig:4283`).
11. `close_surface` from a Ghostty keybind does nothing (`close_surface_cb` delegate is a no-op), and quit, close_all_windows, toggle_maximize, inspector, undo, redo, check_for_updates route to nil; 22 action tags are not decoded (toggle_quick_terminal, toggle_visibility, toggle_background_opacity, goto_window, reset_window_size, initial_size, size_limit, quit_timer, float_window, key_table, move_tab_to_new_window, resize_window, set_window_title, present_terminal, export_terminal_io, selection_changed, toggle_tab_overview, toggle_window_decorations, and inspector/GTK ones). `global:` keybinds never fire.
12. `configDiagnostics` reaches only the log. There is no file watcher on the Ghostty config.

## GHOSTTY_ACTION coverage (Mac app)

28 handled, 20 partial, 22 not handled. Full table with evidence: see the scratch source
`mac-actions.tsv` (copied below).

| action | handled | notes |
| --- | --- | --- |
| GHOSTTY_ACTION_QUIT | partial | Decoded but routes to nil; appActionHandler is never assigned, so app-target quit is unhandled too. cmux Quit is its own action. |
| GHOSTTY_ACTION_NEW_WINDOW | yes | -> registry newWindow (surface target only; app-target falls to unset appActionHandler). |
| GHOSTTY_ACTION_NEW_TAB | yes | -> newSurface. |
| GHOSTTY_ACTION_CLOSE_TAB | yes | this/others/right mapped. |
| GHOSTTY_ACTION_NEW_SPLIT | yes | -> splitRight/Down/Left/Up. |
| GHOSTTY_ACTION_CLOSE_ALL_WINDOWS | partial | Decoded, routes to nil. |
| GHOSTTY_ACTION_TOGGLE_MAXIMIZE | partial | Decoded, routes to nil. |
| GHOSTTY_ACTION_TOGGLE_FULLSCREEN | yes | -> toggleFullScreen; fullscreen mode (macos-non-native-fullscreen) ignored. |
| GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. No quick terminal; quick-terminal-* keys inert. |
| GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE | yes | -> cmux command palette. |
| GHOSTTY_ACTION_TOGGLE_VISIBILITY | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_MOVE_TAB | yes | -> moveSurfaceLeft/Right (amount sign only). |
| GHOSTTY_ACTION_GOTO_TAB | yes | last_tab maps to selectSurfaceByNumber 9. |
| GHOSTTY_ACTION_GOTO_SPLIT | yes |  |
| GHOSTTY_ACTION_GOTO_WINDOW | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_RESIZE_SPLIT | partial | Direction mapped; Ghostty amount ignored (registry step). |
| GHOSTTY_ACTION_EQUALIZE_SPLITS | yes |  |
| GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM | yes |  |
| GHOSTTY_ACTION_PRESENT_TERMINAL | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_SIZE_LIMIT | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_RESET_WINDOW_SIZE | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_INITIAL_SIZE | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. window-width/height inert. |
| GHOSTTY_ACTION_CELL_SIZE | yes | Re-applies surface size. |
| GHOSTTY_ACTION_SCROLLBAR | partial | Stored in model.scrollbar and syncs copy mode; no scroller drawn (scrollbar key inert). |
| GHOSTTY_ACTION_RENDER | yes | No-op; Metal display link draws. |
| GHOSTTY_ACTION_INSPECTOR | partial | Decoded, routes to nil (no terminal inspector). |
| GHOSTTY_ACTION_SHOW_GTK_INSPECTOR | no | GTK only. |
| GHOSTTY_ACTION_RENDER_INSPECTOR | no | No inspector. |
| GHOSTTY_ACTION_EXPORT_TERMINAL_IO | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_DESKTOP_NOTIFICATION | no | Intentional: daemon parses OSC 9/777/99; desktop-notifications still read by the app. |
| GHOSTTY_ACTION_SET_TITLE | partial | Sets model.title (remote/control); sidebar tab names come from the daemon. |
| GHOSTTY_ACTION_SET_TAB_TITLE | partial | Same as SET_TITLE. |
| GHOSTTY_ACTION_SET_WINDOW_TITLE | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_PROMPT_TITLE | yes | -> renameTab. |
| GHOSTTY_ACTION_PWD | yes | Forwarded to the daemon store. |
| GHOSTTY_ACTION_MOUSE_SHAPE | yes |  |
| GHOSTTY_ACTION_MOUSE_VISIBILITY | yes | mouse-hide-while-typing works. |
| GHOSTTY_ACTION_MOUSE_OVER_LINK | partial | Stored in model.hoveredLink for the context menu; no hover preview (link-previews inert). |
| GHOSTTY_ACTION_RENDERER_HEALTH | partial | Stored in model.isRendererHealthy; nothing reads it. |
| GHOSTTY_ACTION_OPEN_CONFIG | yes | Opens ghostty_config_open_path (correct file). Usually shadowed by cmux Cmd-, (Settings). |
| GHOSTTY_ACTION_QUIT_TIMER | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. quit-after-last-window-closed-delay inert. |
| GHOSTTY_ACTION_FLOAT_WINDOW | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_SECURE_INPUT | yes | Applies EnableSecureEventInput; ignores macos-auto-secure-input; in MANUAL_MIRROR only the toggle keybind can trigger it. |
| GHOSTTY_ACTION_KEY_SEQUENCE | partial | Stored in model.isKeySequencePending; no UI. |
| GHOSTTY_ACTION_KEY_TABLE | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. Key-table mode indicator absent. |
| GHOSTTY_ACTION_COLOR_CHANGE | partial | Only the background kind; stored in model.backgroundOverride, which nothing reads (renderer already applied it). |
| GHOSTTY_ACTION_RELOAD_CONFIG | yes | Soft: re-apply current config; hard: GhosttyRuntime.reloadConfig(). |
| GHOSTTY_ACTION_CONFIG_CHANGE | yes | App-level config adopted; surface-level clones freed. |
| GHOSTTY_ACTION_CLOSE_WINDOW | yes | -> closeWindow. |
| GHOSTTY_ACTION_RING_BELL | partial | Always NSSound.beep() via the delegate default; bell-features/audio ignored; bellCount unobserved. |
| GHOSTTY_ACTION_SELECTION_CHANGED | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_UNDO | partial | Decoded, routes to nil. |
| GHOSTTY_ACTION_REDO | partial | Decoded, routes to nil. |
| GHOSTTY_ACTION_CHECK_FOR_UPDATES | partial | Decoded, routes to nil. |
| GHOSTTY_ACTION_OPEN_URL | yes | Web URLs open in a cmux browser tab; Cmd-Opt-click picks a profile. |
| GHOSTTY_ACTION_SHOW_CHILD_EXITED | partial | Sets model.hasExited; the daemon decides tab death. |
| GHOSTTY_ACTION_PROGRESS_REPORT | partial | Stored in model.progress (unread); tab progress comes from the daemon. |
| GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD | no | Not applicable on macOS. |
| GHOSTTY_ACTION_COMMAND_FINISHED | partial | Stored in model.lastCommand (unread); notify-on-command-finish inert. |
| GHOSTTY_ACTION_START_SEARCH | yes | Drives cmux find bar. |
| GHOSTTY_ACTION_END_SEARCH | yes |  |
| GHOSTTY_ACTION_SEARCH_TOTAL | yes |  |
| GHOSTTY_ACTION_SEARCH_SELECTED | yes |  |
| GHOSTTY_ACTION_READONLY | partial | Stored in model.isReadOnly; no indicator. |
| GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD | yes |  |
| GHOSTTY_ACTION_MOVE_TAB_TO_NEW_WINDOW | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
| GHOSTTY_ACTION_RESIZE_WINDOW | no | Undecoded: action_cb returns false (CmuxNextTerminal/GhosttyRuntimeCallbacks.swift:29), so Ghostty treats the binding as not performed. |
