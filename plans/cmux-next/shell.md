# cmux next: app shell, build wiring, GhosttyKit, Liquid Glass

Research for [REWRITE.md](REWRITE.md). Paths are relative to the worktree root
unless they start with `SDK/` (= `xcrun --show-sdk-path`, Xcode 27.0 27A266a,
macOS SDK 27.0) or `ghostty/` (submodule pinned at `9961d09be3f`; read from
`repo/ghostty` because this worktree's submodule is not initialized).
Line numbers are as of `fde44232c35`.

## Decisions requested

1. **Deployment target macOS 26.** Required for `Observations`, glass APIs
   without `#available` forks, and an umbrella package declared `.macOS(.v26)`.
   It drops macOS 14/15 users. See section 3.4.
2. **Sibling target, repointed `cmux` scheme** (section 1.3). Old app stays
   buildable as `cmux-legacy` until cutover.
3. **Reuse of existing leaf packages** (`CmuxGhosttyKit`, the CloudTui manual-IO
   frame codec, `CmuxUpdater`) versus "do not port old Swift". This doc
   recommends reusing `CmuxGhosttyKit` only (it is a 20-line binary wrapper) and
   rewriting the rest. Flag if you want a stricter or looser line.

## 1. Build system

### 1.1 What exists

- `cmux.xcodeproj` is `objectVersion = 60`, compatibility "Xcode 14.0"
  (`cmux.xcodeproj/project.pbxproj:6`, `:12819`). No
  `PBXFileSystemSynchronizedRootGroup` (that needs objectVersion 77), so every
  Swift file in `Sources/` (1,456 entries, ~546k lines) is an explicit
  PBXBuildFile + PBXFileReference. This is the per-file pbxproj churn to escape.
- App target `cmux` is `A5001050` (`project.pbxproj:12551`). Build phases
  (`:12553-12569`): Sources, Frameworks, Resources, Compress Markdown Viewer
  Assets, Write Extension Point, Copy Dock Tile Plugin, Embed System Extensions,
  Embed Frameworks, Copy CLI, Build Diff Sidecar, Build Command Palette Nucleo
  FFI, ShellScript, Build Plain Text Paste Worker, Reject Bundled Provider
  Binaries. Dependencies: `cmux-cli`, `CmuxDockTilePlugin`,
  `cmuxTunnelExtension`.
- Identity lives in build configs: Debug `A5001082` sets
  `PRODUCT_NAME = "cmux DEV"`, `PRODUCT_BUNDLE_IDENTIFIER = com.cmuxterm.app.debug`,
  `CODE_SIGN_ENTITLEMENTS = ""`, `INFOPLIST_FILE = Resources/Info.plist`,
  `SPARKLE_PUBLIC_KEY`, `SWIFT_OBJC_BRIDGING_HEADER = cmux-Bridging-Header.h`,
  `SWIFT_VERSION = 5.0` (`:17347-17393`). Release `A5001083` sets `cmux`,
  `com.cmuxterm.app`, `Resources/cmux.entitlements` (`:17396-17437`). Nightly and
  RC entitlements are the root `cmux.{nightly,rc,release}.entitlements`.
- All 14 `MACOSX_DEPLOYMENT_TARGET` values are `14.0`.
- `Info.plist` carries `SUFeedURL` and `SUPublicEDKey = $(SPARKLE_PUBLIC_KEY)`
  (`Resources/Info.plist:302-305`). Sparkle is a remote package
  (`A5001232`, `:12850`) and product `A5001231` on the target.
- GhosttyKit is linked twice by design: the target's Frameworks phase links
  `GhosttyKit.xcframework` (`:1979`, `:6070`, `:8292`), and packages depend on
  `Packages/Shared/CmuxGhosttyKit`, a `binaryTarget(path:
  "../../../GhosttyKit.xcframework")` (`Packages/Shared/CmuxGhosttyKit/Package.swift`).
  The bridging header is just `@import GhosttyKit;` (`cmux-Bridging-Header.h`).
  SwiftPM alone cannot link the macOS archive ("binary lacks the lib prefix",
  `Packages/macOS/CmuxTerminal/Package.swift` comment), so package test targets
  link a C stub and only the Xcode app target links the real library.
- Local packages already use Swift 6 mode (`swiftLanguageMode(.v6)`,
  `ExistentialAny`, `InternalImportsByDefault`) at `.macOS(.v14)`.

### 1.2 What the tagged-build tools assume

- `scripts/reload.sh:1616-1620` hardcodes `-project cmux.xcodeproj -scheme cmux
  -configuration Debug`. It overrides `PRODUCT_BUNDLE_IDENTIFIER` on the command
  line (`:1638`) to `com.cmuxterm.app.debug.<tag>` (`:1397`) and names the app
  `cmux DEV <tag>` (`:1394`). It expects the build product `cmux DEV.app`
  (`APP_NAME`/`BASE_APP_NAME`, `:11-13`), copies it to the tag name, then patches
  `Info.plist` with PlistBuddy: `CFBundleIdentifier`, URL scheme
  `cmux-dev-<tag>`, and `LSEnvironment` keys `CMUX_TAG`, `CMUX_BUNDLE_ID`,
  `CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock`, `CMUX_DEBUG_LOG`,
  `CMUXD_UNIX_PATH`, `CMUX_SOCKET_ENABLE`, `CMUX_SOCKET_MODE=allowAll`
  (`:1935-1975`). It expects `Contents/Resources/bin/cmux` (CLI, `:361`, `:667`)
  and installs the published cmux-tui client into the bundle (`:1406-1430`).
- `scripts/reload-cloud.sh` is a shim to the hq script (`:5-22`), which runs the
  same `reload.sh` on a fleet Mac.
- `cmux-ci build cmux` sends `CMUX_FLEET_BUILD_TAG=<tag> <recipe> <repo> <ref>`
  (`~/.local/share/cmux-fleet-client/versions/8dac9dc1f1fa703b4935/ci-client.py:137-141`);
  the recipe calls `reload.sh --tag` from the checkout at that SHA. So whatever
  scheme `cmux` builds on the branch SHA is what the fleet ships. No fleet change
  is needed if the branch's `cmux` scheme builds the new app.
- `cmux.xcscheme` references `A5001050` for build, launch, profile, and macro
  expansion, and `cmuxUITests` as its only testable
  (`cmux.xcodeproj/xcshareddata/xcschemes/cmux.xcscheme:6-30`).

Therefore the invariants for the new app are: scheme named `cmux`, Debug
`PRODUCT_NAME = "cmux DEV"`, Debug bundle id `com.cmuxterm.app.debug`, the same
`Info.plist` keys that reload.sh patches, `Contents/Resources/bin/cmux`, and the
app must read `CMUX_TAG` / `CMUX_SOCKET_PATH` from its environment.

### 1.3 Recommendation: sibling target, repoint the `cmux` scheme

Add one new `PBXNativeTarget` `cmux-next` whose only compiled source is
`App/main.swift` (3 lines: `import CmuxNextApp; CmuxNextApp.main()`), and whose
only package products are `CmuxNextApp` (new local umbrella package at
`Packages/macOS/CmuxNext`) and `Sparkle`. Copy the Debug/Release configs from
`A5001082`/`A5001083` verbatim (same `PRODUCT_NAME`, bundle ids, `Info.plist`,
entitlements, `SPARKLE_PUBLIC_KEY`, `OTHER_LDFLAGS`), then change only
`MACOSX_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 6.0`, and delete
`SWIFT_OBJC_BRIDGING_HEADER`. Link `GhosttyKit.xcframework` in its Frameworks
phase (reuse file ref `A5001016`). Keep the phases the tools rely on: Copy CLI
(+ dependency on `cmux-cli`) and the Reject Bundled Provider Binaries check.
Drop Dock Tile, Tunnel Extension, Diff Sidecar, Nucleo FFI, Markdown assets,
Extension Point until a feature needs them.

On the branch, edit `cmux.xcscheme` so its BuildableReferences point at the new
target's ID and remove the `cmuxUITests` testable. Add `cmux-legacy.xcscheme`
pointing at `A5001050` for A/B runs. Both targets produce `cmux DEV.app`; they
must never be built in one invocation (they are not; each scheme builds one).

Concrete trade-off versus replacing `A5001050`'s sources in place:

| | Sibling + repointed scheme | Replace in place |
|---|---|---|
| pbxproj diff on branch | ~250 added lines (one target, two configs, 3-4 phases, one package ref), plus a 1-file scheme edit | ~6,000 deleted lines (1,456 build files + file refs + groups) plus ~45 package refs |
| Rebase onto main | Additive; main's constant pbxproj edits to the old target do not conflict | Every main PR that adds a Swift file conflicts on the deleted region; always "take ours", but every rebase needs it |
| reload.sh / reload-cloud / cmux-ci | Unchanged | Unchanged |
| A/B against old app on same SHA | `-scheme cmux-legacy` | Needs a main checkout |
| Old tests (`cmuxTests`, `cmuxUITests`, `cmux-unit`, `cmux-ci` schemes) | Keep compiling against legacy; no change | All break (they compile old sources / `TEST_HOST = cmux DEV.app`); must be deleted up front |
| Cutover cost | One later PR: delete `A5001050` + old sources, rename target to `cmux` | Already paid |
| Risk | Two targets share `Info.plist`/entitlements; a key edited for one silently affects the other | Branch cannot build the old app at all |

The sibling path moves the big deletion to the end, when the new app is
complete, and keeps every tool working on day one. Replace-in-place only wins
if the branch will never rebase, which is false for a multi-week rewrite.

Do the pbxproj edit with a script (Ruby `xcodeproj` gem or a checked-in Python
generator), not by hand, and never let Xcode re-save the project to
objectVersion 77 on the branch (it rewrites the whole file and conflicts with
main). After the target exists, adding code means adding files under
`Packages/macOS/CmuxNext/Sources/...`, with zero pbxproj edits.

### 1.4 Umbrella package layout

```
Packages/macOS/CmuxNext/Package.swift   // swift-tools-version: 6.2
  platforms: [.macOS(.v26)]
  products: .library("CmuxNextApp")
  targets:
    CmuxNextApp        AppDelegate, window controllers, menu, scene wiring
    CmuxNextModel      @Observable stores mirrored from the daemon (no AppKit)
    CmuxNextDaemon     cmux-tui client: socket, framing, AsyncSequence events
    CmuxNextTerminal   Ghostty surface NSView + manual-mirror IO (depends CmuxGhosttyKit)
    CmuxNextChrome     tab strip, sidebar, palette, glass components
  swiftSettings (all targets):
    .swiftLanguageMode(.v6)
    .defaultIsolation(MainActor.self)          // except CmuxNextDaemon
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
    .enableUpcomingFeature("InferIsolatedConformances")
    .enableUpcomingFeature("ExistentialAny")
    .enableUpcomingFeature("InternalImportsByDefault")
```

`CmuxNextModel` and `CmuxNextDaemon` have no GhosttyKit dependency, so
`swift test` works for them on any Mac without the stub trick. `CmuxNextTerminal`
tests need the same C-stub target pattern as `CmuxTerminalCore`.

Verified: a scratch package with these settings at `.macOS(.v26)` compiles on
Xcode 27 (Swift 6.4) and Xcode 26.3 (Swift 6.2.4, SDK 26.2)
(`/tmp/cmux-next-glass-probe`, section 3.3). `.defaultIsolation` needs tools 6.2,
which Xcode 26.x has.

## 2. GhosttyKit

### 2.1 How the current app does it

- Process init: `ghostty_init(argc, argv)` (`ghostty/include/ghostty.h:1302`,
  called at `Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/Interop/GhosttyRuntimeCInterop.swift:40`).
- App: fill `ghostty_runtime_config_s` (`ghostty.h:1257-1266`: `userdata`,
  `wakeup_cb`, `action_cb`, `read_clipboard_cb`, `confirm_read_clipboard_cb`,
  `write_clipboard_cb`, `close_surface_cb`, `tmux_control_cb`), then
  `ghostty_app_new(&runtime, config)` (`ghostty.h:1330`;
  `Sources/GhosttyTerminalView.swift:838-841`, `:965`). `wakeup_cb` fires on
  any thread; the app coalesces to one main-thread `ghostty_app_tick`
  (`GhosttyTerminalView.swift:376`, `:1791`; `ghostty.h:1333`).
- Surface: `ghostty_surface_config_new()`, set `platform_tag =
  GHOSTTY_PLATFORM_MACOS`, `platform.macos.nsview = Unmanaged.passUnretained(view)`,
  `userdata`, `scale_factor`, `io_mode`, `io_write_cb` (`TerminalSurface+RuntimeSurfaceCreation.swift:31-76`),
  then `ghostty_surface_new` (`:368`, `ghostty.h:1351`), then install
  `ghostty_surface_set_render_presented_callback` /
  `ghostty_surface_set_render_failed_callback` (`:333-343`, `ghostty.h:1396-1413`).
- Ghostty owns the layer. The Metal renderer creates an `IOSurfaceLayer`, assigns
  it as the NSView's layer, and sets `wantsLayer`
  (`ghostty/src/renderer/Metal.zig:103-120`). The embedder does not create a
  `CAMetalLayer` and must not replace the view's layer.
- Input: `GhosttyNSView` is an `NSTextInputClient`
  (`GhosttyTerminalView.swift:13824`) that routes `keyDown` through
  `interpretKeyEvents` and overrides `performKeyEquivalent` (`:6801-6820`), then
  calls `ghostty_surface_key` / `ghostty_surface_text` /
  `ghostty_surface_preedit` / `ghostty_surface_ime_point` (`ghostty.h:1571`,
  `:1582`, `:1586`, `:1656`).

That file is 14,536 lines. The new app needs a small fraction of it.

### 2.2 Minimal surface host for the new app

One `final class TerminalSurfaceView: NSView, NSTextInputClient` (MainActor) plus
one `GhosttyRuntime` singleton:

- `GhosttyRuntime`: `ghostty_init` once; `ghostty_app_new` with `wakeup_cb` that
  hops to the main actor and calls `ghostty_app_tick` (coalesced by an atomic
  flag); `action_cb` switch for the handful of actions the frontend owns
  (`GHOSTTY_ACTION_RENDER`, `SET_TITLE`, `PWD`, `MOUSE_SHAPE`, `RING_BELL`,
  `DESKTOP_NOTIFICATION`, `CELL_SIZE`, `ghostty.h:1143-1168`); clipboard
  callbacks via `NSPasteboard`. Call `ghostty_app_set_focus` on app
  activate/resign (`ghostty.h:1335`).
- `TerminalSurfaceView` lifecycle:
  - `viewDidMoveToWindow`: create the surface once with the view pointer.
  - `viewDidChangeBackingProperties`: `ghostty_surface_set_content_scale`
    (`ghostty.h:1440`) and `ghostty_surface_set_display_id` with the screen's
    `CGDirectDisplayID` (`ghostty.h:1821`).
  - `setFrameSize` / `layout`: `ghostty_surface_set_size` in backing pixels
    (`ghostty.h:1443`).
  - `becomeFirstResponder` / `resignFirstResponder`: `ghostty_surface_set_focus`.
  - Window occlusion notification: `ghostty_surface_set_occlusion` (`:1442`).
  - Mouse: `ghostty_surface_mouse_button`, `_mouse_pos`, `_mouse_scroll`,
    `_mouse_pressure` (`ghostty.h:1643-1655`).
  - Keys: `keyDown` → `interpretKeyEvents` → `insertText` / `setMarkedText` →
    `ghostty_surface_key` with the composed text, `ghostty_surface_preedit`
    for marked text; `firstRect(forCharacterRange:)` from
    `ghostty_surface_ime_point`.
  - Teardown: `ghostty_surface_free` (`ghostty.h:1365`) on the main actor after
    removing from superview. Callback userdata boxes must outlive the free call
    (`ghostty.h:1396-1405` comments).

### 2.3 Daemon-fed surfaces (manual IO): supported

The manaflow-ai fork adds embedder-owned IO (`ghostty.h:548-559`):

```c
typedef enum {
  GHOSTTY_SURFACE_IO_EXEC = 0,
  GHOSTTY_SURFACE_IO_MANUAL = 1,
  GHOSTTY_SURFACE_IO_MANUAL_MIRROR = 2,  // embedder owns PTY + protocol; parser replies suppressed
} ghostty_surface_io_mode_e;
typedef void (*ghostty_io_write_cb)(void*, const char*, uintptr_t);
GHOSTTY_API void ghostty_surface_process_output(ghostty_surface_t, const char*, uintptr_t);
```

Fields `io_mode`, `io_write_cb`, `io_write_userdata` are in
`ghostty_surface_config_s` (`ghostty.h:627-629`). Backend is
`ghostty/src/termio/Manual.zig`. In manual modes Ghostty spawns no process;
user input is delivered to `io_write_cb` on Ghostty's IO thread, and PTY bytes
are injected with `ghostty_surface_process_output` (`ghostty.h:1589`).

Use `GHOSTTY_SURFACE_IO_MANUAL_MIRROR` for cmux-tui PTYs. The daemon keeps its
own VT state and answers DA/DSR/OSC queries, so `MANUAL` would reply twice.
The existing cloud path already does exactly this:
`Sources/Cloud/CloudTuiManualMirrorSession.swift` (header comment: "cmux-tui
remains the PTY/session owner"), with `TerminalSurfaceIOMode.manualMirror`
(`Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurfaceIOMode.swift`)
and a C trampoline that copies bytes and hands them to a `@Sendable` closure
(`TerminalManualIOWrite.swift`). Read those as a reference for the protocol
dance (attach, replay with `ESC c ESC [3J` reset, geometry claim,
`resize-surface`), not as code to port.

Other fork APIs the new app should use:

- `ghostty_surface_set_grid_size(surface, cols, rows, &resolved)`
  (`ghostty.h:1464`): apply the daemon's authoritative grid when this view does
  not own canonical geometry. The spec's "selecting a visible terminal view
  explicitly transfers canonical geometry" rule is in
  `cmux-tui/spec/native-frontend.md` ("Persistent Swift frontend boundary").
- `ghostty_surface_restore_kitty_replay` (`ghostty.h:1620`): restore Kitty
  graphics state before replay on a fresh surface.
- `ghostty_surface_update_theme_config` (`ghostty.h:1380`): documented as
  requiring serialization with `process_output` in manual mode.
- Threading: `process_output` and `update_theme_config` must be serialized per
  surface; feed from one main-actor (or one per-surface serial) consumer of the
  daemon event stream.

Live tab hover previews: a second, small manual-mirror surface attached to the
same daemon terminal (each attachment gets its own VT mirror,
`native-frontend.md`) is simpler than snapshotting. For an offscreen preview,
`GHOSTTY_PLATFORM_METAL_EXTERNAL_LEASED` delivers each frame as an `IOSurface`
(`ghostty.h:65-72`, `:478-521`) that can be set as `CALayer.contents` in the
tab strip without an NSView. Prototype both; the NSView route is the default.

Surface config is a C ABI struct. Rebuilding GhosttyKit after a submodule bump
changes it; `ghostty.h` says fields must match the Zig side (`ghostty.h:62-64`).
Keep all `ghostty_*` calls inside `CmuxNextTerminal` so a bump touches one
target.

## 3. Liquid Glass (SDK 27.0, verified by grep and compile)

### 3.1 AppKit

| API | Availability | Source |
|---|---|---|
| `NSGlassEffectView` (`contentView`, `cornerRadius`, `tintColor`, `style: .regular/.clear`) | macOS 26.0 | `SDK/.../AppKit.framework/Headers/NSGlassEffectView.h:14-37` |
| `NSGlassEffectView.effectIsInteractive` | **macOS 27.0** | same, `:45` |
| `NSGlassEffectContainerView` (`contentView`, `spacing`; merges nearby glass, batches rendering) | macOS 26.0 | same, `:52-65` |
| `NSBackgroundExtensionView` (`contentView`, `automaticallyPlacesContentView`; extends content under titlebar/sidebar) | macOS 26.0 | `NSBackgroundExtensionView.h:22-40` |
| `NSSplitViewItem.automaticallyAdjustsSafeAreaInsets`, top/bottom aligned accessory VCs | macOS 26.0 | `NSSplitViewItem.h:140-155` |
| `NSToolbarItem.style` (`.plain/.prominent`), `backgroundTintColor`, `badge` | macOS 26.0 | `NSToolbarItem.h:20-24`, `:142`, `:152`, `:200` |
| `NSScrollEdgeEffectStyle` (`automaticStyle/softStyle/hardStyle`), `preferredScrollEdgeEffectStyle` on titlebar and split accessory VCs | **macOS 26.1** | `NSScrollEdgeEffect.h:16-30`, `NSTitlebarAccessoryViewController.h:73` |
| `NSButton.tintProminence`, `borderShape`; `NSControl.BorderShape` | macOS 26.0 | `NSButton.h:124`, `:179`; `NSControl.h:158` |
| `NSView.prefersCompactControlSizeMetrics`; `NSControlSizeExtraLarge` | macOS 26.0 | `NSView.h:630`; `NSCell.h:96` |
| `NSView.cornerConfiguration`, `effectiveCornerRadii` | **macOS 27.0** | `NSView.h:614-623` |

Sidebar glass on macOS 26 comes for free from `NSSplitViewController` with a
`NSSplitViewItem(sidebarWithViewController:)`; the sidebar floats as glass over
content. The terminal area should be a `NSBackgroundExtensionView` only if we
want the terminal background to bleed under the sidebar; per REWRITE.md visual
rules, glass never sits on terminal content.

### 3.2 SwiftUI

| API | Availability | Source |
|---|---|---|
| `View.glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape())` | macOS 26.0 | `SDK/.../SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface:3062-3064` |
| `struct Glass` (`.regular`, `.clear`, `.identity`, `.tint(_:)`, `.interactive(_:)`) | macOS 26.0 | same, `:7243-7258` |
| `GlassEffectContainer(spacing:content:)` | macOS 26.0 | same, `:11521-11524` |
| `View.glassEffectID(_:in:)` (morphing between glass shapes in a namespace) | macOS 26.0 | same, `:22409-22411` |
| `View.glassEffectUnion(id:namespace:)` | macOS 26.0 | same, `:12644` |
| `GlassEffectTransition` (`.matchedGeometry`, `.materialize`, `.identity`), `View.glassEffectTransition(_:)` | macOS 26.0 | same, `:3498-3512` |
| `View.backgroundExtensionEffect()` / `(isEnabled:)` | macOS 26.0 | `SDK/.../SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface:15830-15835` |
| `ButtonStyle.glass`, `.glassProminent` | macOS 26.0 | same, `:1471`, `:4458` |
| `ToolbarContent.sharedBackgroundVisibility(_:)`, `ToolbarSpacer` | macOS 26.0 | same, `:7320`, `:29510` |
| `View.scrollEdgeEffectStyle(_:for:)` | macOS 26.0 | same, `:15926` |
| `View.toolbarBackgroundVisibility(_:for:)` | macOS 15.0 | same, `:12820` |

SDK 27 note: builders are now `@SwiftUICore.ContentBuilder`
(`SwiftUI.swiftinterface:127` and throughout). See the `swiftui-whats-new-27`
skill for source breaks when a file also compiles on Xcode 26.

### 3.3 Compile probe

`/tmp/cmux-next-glass-probe` (Swift 6 mode, `defaultIsolation(MainActor)`,
`.macOS(.v26)`) uses `NSGlassEffectContainerView` + `NSGlassEffectView` hosting
an `NSHostingView` whose SwiftUI tab strip uses `GlassEffectContainer`,
`.glassEffect(.regular.tint(...).interactive(), in: .capsule)`,
`.glassEffectID`, `.glassEffectTransition(.matchedGeometry)`,
`.backgroundExtensionEffect()`, `.buttonStyle(.glass)`, plus `Observations`
and `NSAnimationContext.animate(.spring(...))`. Results:

- Xcode 27 / SDK 27.0: builds.
- Xcode 26.3 / SDK 26.2: fails on `effectIsInteractive` even inside
  `if #available(macOS 27.0, *)`, because the symbol is absent from the SDK.
  Builds after wrapping it in `#if compiler(>=6.4)`.

CI and the fleet use Xcode 26.x (`.xcode-version` = `26`;
`scripts/ci/xcode-pins.txt`: macOS 26 pool defaults to 26.6, macOS 15 pool at
most 26.3). Rule: any macOS 27 API (`effectIsInteractive`,
`cornerConfiguration`, `withObservationTracking(options:)`) needs
`#if compiler(>=6.4)` plus `#available(macOS 27, *)`, or wait until CI moves to
Xcode 27.

### 3.4 Deployment target: 14.0 today, raise to 26.0 for the new target

Every target is at `14.0`. The existing app gates glass behind
`#available(macOS 26...)` in 12 places and keeps a visual-effect fallback
(`Packages/macOS/CmuxAppKitSupportUI/.../WindowChrome/Glass/`).

Raising the new target to 26.0 means:

- No glass/non-glass fork in any view; `Observations` and
  `NSHostingSceneRepresentation` (macOS 26.0, `SwiftUI.swiftinterface:10390`)
  usable directly.
- Users on macOS 14/15 cannot run the new app. The appcast has no
  `sparkle:minimumSystemVersion` (no match under `scripts/` or `.github/`), so
  shipping it on the existing feed would offer those users an update that does
  not launch. Cutover must add `minimumSystemVersion` to the appcast generator
  and freeze a last 14/15-compatible release. **Decision for you.**
- The macOS 15 CI pool can still compile against SDK 26 but cannot launch the
  app; UI/e2e lanes must pin the macOS 26 pool.
- Fleet Macs that launch tagged builds must run macOS 26+.
- Packages it depends on can stay at `.v14`; a `.v26` package cannot be used by
  a `.v14` target, so only the new target and umbrella package move.

## 4. Patterns to adopt

**State ownership.** Daemon state (sessions, workspaces, screens, columns, panes,
tabs, titles, cwd, agent status) is authoritative in cmux-tui. The Swift side
holds `@Observable @MainActor final class` stores that are projections of
daemon events, plus frontend-only state that the spec assigns to the frontend
(selection, scroll, hover, drag; `cmux-tui/spec/native-frontend.md`
"Entrypoints"). Stores never mutate topology locally; they send a command and
apply the resulting event (optimistic UI only where latency shows, keyed by a
request ID and reconciled on the event).

**Concurrency.** Swift 6 language mode, `defaultIsolation(MainActor.self)` for
UI targets, `NonisolatedNonsendingByDefault` so `async` helpers run on the
caller's actor unless marked `@concurrent`. The daemon client target is not
MainActor-default: one `actor DaemonConnection` owns the socket and decoder.
Ghostty C callbacks (`wakeup_cb`, `io_write_cb`, render callbacks) arrive on
foreign threads; each trampoline copies bytes into a `Sendable` value and hops
with `Task { @MainActor in ... }` or a `MainActor.assumeIsolated` only where
the header guarantees the GUI thread (`ghostty_font_size_action_cb`,
`ghostty.h:1415`). No `DispatchQueue.asyncAfter` (repo rule); timeouts use an
injected `Clock`.

**Daemon events as AsyncSequence.** `DaemonConnection.events` returns an
`AsyncThrowingStream<DaemonEvent, any Error>` built with
`makeStream(bufferingPolicy: .unbounded)` for control events. Terminal output is
a separate per-surface stream so a busy PTY cannot delay topology events. A
MainActor `for try await` loop per window applies events to stores; per-surface
loops call `ghostty_surface_process_output`. Reconnect is a new stream plus a
snapshot resync, driven by the connection actor.

**Observation to AppKit.** `Observations { store.tabs }` (macOS 26.0,
`SDK/usr/lib/swift/Observation.swiftmodule/arm64e-apple-macos.swiftinterface:141-149`)
gives an `AsyncSequence` of changes for AppKit controllers that are not
SwiftUI. macOS 26 AppKit also re-runs `layout`/`updateLayer`/`draw` when
`@Observable` properties read there change (WWDC25 "What's new in AppKit"; not
visible in headers, so **unverified here**; confirm in the first prototype
before relying on it). `withObservationTracking(options:)` is macOS 27 only
(`:138`).

**AppKit shell, SwiftUI leaves.** Window, split view, tab strip, column scroller,
and terminal views are AppKit (precise first-responder, key routing, and
Core Animation control). Palette rows, sidebar rows, popovers, settings are
SwiftUI inside `NSHostingView` (`SwiftUI.swiftinterface:12074`). Menus can use
`NSHostingMenu` (macOS 14.4, `:5198`). Set `NSHostingView.sizingOptions` to
avoid layout feedback loops inside AppKit containers.

**Tab animation.** The strip is a layer-backed NSView with one
`CALayer` (or light NSView) per tab; widths are computed by a pure layout
function of (count, available width, pinned) so open/close animate by diffing
frames. Use `NSAnimationContext.animate(.spring(...))` (macOS 15.0,
`SwiftUI.swiftinterface:31620-31624`) to drive AppKit frame changes with
SwiftUI spring curves, or `CASpringAnimation` directly on layers. Glass
background for the strip is one `NSGlassEffectView` behind the tabs; do not put
a glass view per tab (use `NSGlassEffectContainerView` if individual tab glass
is wanted, so rendering is batched).

**Keyboard.** One ordered router: (1) palette/overlay first responder,
(2) app shortcut table (`KeyboardShortcutSettings` equivalent, user-editable,
persisted in `~/.config/cmux/cmux.json` per repo rule), checked in
`NSWindow.performKeyEquivalent` before the terminal, (3) terminal view
`keyDown` → `interpretKeyEvents` → Ghostty. Menu items carry the same
shortcuts so the menu bar reflects them. Register every action once in an
action registry that the palette, menus, shortcuts, and debug socket all call
(repo "shared entrypoints" rule, goal 6).

**Debug socket.** Honor `CMUX_TAG`, `CMUX_SOCKET_PATH`, `CMUX_SOCKET_ENABLE`,
`CMUX_SOCKET_MODE` from `LSEnvironment` exactly as reload.sh writes them, so
`cmux-dev --socket /tmp/cmux-debug-<tag>.sock` and existing agent preflight
work unchanged. The debug socket must expose `identify`, `screenshot`, and
palette actions early; handoff preflight depends on them.

## 5. First steps

1. Script the `cmux-next` target + `cmux-legacy` scheme + repointed `cmux`
   scheme; umbrella package with an empty window. Prove
   `cmux-ci build cmux --ref <sha> --tag next-shell-v1` produces a launchable
   `cmux DEV next-shell-v1.app` with the tagged socket.
2. `CmuxNextTerminal`: one `TerminalSurfaceView` in `GHOSTTY_SURFACE_IO_EXEC`
   to validate init, input, IME, resize, and scale.
3. Switch to `MANUAL_MIRROR` fed by the bundled cmux-tui daemon.
4. Glass chrome on top.
