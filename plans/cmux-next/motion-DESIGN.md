# cmux-next motion gate: no-animation switch and per-area switches

Status: implemented on `feat-cmux-next` (2026-10-20). Owner of the switches; the
tokens, curves and springs stay in [motion.md](motion.md).

## Ask

Lawrence, 2026-10-20: "Make a no-animation toggle in settings that totally
disables every single animation, including reorder groups, every single
animation that you can think of. Make sure it is comprehensive. Make sure that
stuff in the future respects this properly. Coding agents in the future that add
animations need to handle having no animations at all." Then: "make it so that
people can be more precise and choose exactly which animations they want too".

## Design

One gate, one category per animation.

- `MotionCategory` (CmuxNextDesign) names ten areas: `sidebar`, `tabs`, `panes`
  (panes and windows), `overlays` (menus, popovers, palette, sheets, toasts,
  notices, find bars, cards), `hoverCards` (hover cards, tooltips), `home` (Home,
  the Chief chat, agent chat panes), `cursor` (agent cursor), `indicators`
  (spinners, pulses, progress, attention flashes), `feedback` (hover, press and
  focus highlights, theme and color changes), `web` (cmux's own web pages).
  The grouping comes from the inventory below: each area is one thing a person
  sees and can name, and no call site needed a second category.
- `MotionGate` is the only way to animate. `Motion.sidebar`, `Motion.tabs`, ...
  are gates; every timing read (`duration`, `spring`, `period`,
  `animatesMovement`, `animatesFades`, `animatesLoops`, `policy`) and every
  helper (`animate`, `animateTimed`, `animateExit`, `transaction`, `set`,
  `springAnimation`, `scheduledFade`, the loops, `flashAnimation`,
  `attentionAnimation`, `marqueeAnimation`, `animation` for SwiftUI, the launch
  mark) is a gate member. The old static `Motion.animate(...)` and friends are
  gone, so code that names no category does not compile. Category-free helpers
  (`Motion.withoutAnimation`, `canAnimate`, `presentationValue`, `scale`) stay
  static: they never animate.
- `MotionPolicy` gained `animationsEnabled`, `disabledCategories` and
  `category`. `categoryAnimates` is `animationsEnabled && speed != off &&
  category not disabled`; `animatesMovement`, `animatesFades`, `animatesLoops`,
  every duration and the tween FFI policy (speed index 2 = off) derive from it.
  So a category that is off behaves exactly as `ui.animationSpeed: "off"` for
  its own animations, and the master switch off behaves as "off" for all of
  them. Reduce Motion and live resize still apply inside an enabled category.
- Order of checks, every animation: master switch on, category on, speed not
  off, then Reduce Motion (movement instant, fades capped at a crossfade, loops
  stop).
- Spinners and other loops: off renders the static glyph (the existing
  "loops off" path, `StatusIndicatorPlan`), so they stay recognizable.
- Web: `WebTheme`'s payload carries `motion` = `off` / `reduced` / `full`
  (`Motion.web`). The bootstrap every cmux web view loads sets
  `data-cmux-motion` on `<html>`; under `off` one stylesheet sets every CSS
  transition and animation to 0 s, and a wrapper on `Element.animate`,
  `scrollTo`, `scrollBy` and `scrollIntoView` makes script animations and
  smooth scrolls instant. Agent chat panes also get their `--agent-motion-*`
  durations from `Motion.web.policy` (0 when off). Websites are not changed.
- Theme and color changes (`ColorTransition`) follow `feedback`.

## Settings, actions, CLI, MCP

| Key | Default | Settings row (Appearance > Motion) | Action (Cmd-Shift-P, CLI, MCP) |
| --- | --- | --- | --- |
| `ui.animations.enabled` | true | Play Animations | `appearance.animations.toggle`, `cmux settings toggle-all-animations` |
| `ui.animations.sidebar` | true | Animate the Sidebar | `appearance.animations.sidebar.toggle`, `toggle-sidebar-animations` |
| `ui.animations.tabs` | true | Animate Tabs | `appearance.animations.tabs.toggle`, `toggle-tab-animations` |
| `ui.animations.panes` | true | Animate Panes and Windows | `appearance.animations.panes.toggle`, `toggle-pane-and-window-animations` |
| `ui.animations.overlays` | true | Animate Menus and Cards | `appearance.animations.overlays.toggle`, `toggle-menu-and-card-animations` |
| `ui.animations.hoverCards` | true | Animate Hover Cards | `appearance.animations.hoverCards.toggle`, `toggle-hover-card-animations` |
| `ui.animations.home` | true | Animate Home and Chats | `appearance.animations.home.toggle`, `toggle-home-and-chat-animations` |
| `ui.animations.cursor` | true | Animate the Agent Cursor | `appearance.animations.cursor.toggle`, `toggle-agent-cursor-animations` |
| `ui.animations.indicators` | true | Animate Spinners and Progress | `appearance.animations.indicators.toggle`, `toggle-spinner-and-progress-animations` |
| `ui.animations.feedback` | true | Animate Highlights and Colors | `appearance.animations.feedback.toggle`, `toggle-highlight-and-color-animations` |
| `ui.animations.web` | true | Animate cmux Web Pages | `appearance.animations.web.toggle`, `toggle-web-page-animations` |

Turning a switch back on removes its key (the default). A managed key refuses.
The toggles are MCP tools (not in the MCP `systemChange` exemption), unlike the
older speed and kind toggles. Strings: English plus 20 translations in
`CmuxNextSettings/Localizable.xcstrings` and `CmuxNextActions/ActionCatalog.xcstrings`.
`ui.animationSpeed`, `ui.paneAnimations`, `ui.animations.newTab`,
`ui.animations.newWorkspace` and `ui.animations.bounce` keep working inside
their categories.

## Future-proofing

1. Compile time: a gate member without a category does not exist.
2. `scripts/cmux-next/check-motion.sh` (pre-push gate and the `cmux-next checks`
   CI job) also fails on: a `Motion.<member>` with no category (clear message), a
   SwiftUI `.animation(` whose value is not `Motion.<category>.animation(...)`,
   `.transition(`, `.contentTransition(`, `.symbolEffect(`,
   `.matchedGeometryEffect(`, `phaseAnimator`, `keyframeAnimator`,
   `TimelineView(.animation`, a window `animationBehavior` other than `.none`
   that no gate decides, a popover `animates` that no gate decides, and an
   `.animator()` change with no gate group within 40 lines. A reviewed exception
   is `// motion: allow <reason>` (the older `// motion-allow: <reason>` still
   works); the reason is required. Fixtures: `scripts/cmux-next/tests/check-motion.test.sh`.
3. AGENTS.md rule under "cmux-next checks before every push".
4. Tests: `MotionCategoryPolicyTests` (one category off stops only it; the master
   switch overrides every category; Reduce Motion and speed off still apply; web
   value), `MotionMasterSwitchSurfaceTests` (every gate helper of every category
   is still with the master switch off, a category off stills only itself, a
   popup opens and closes in one frame, a clipped title runs no marquee),
   `MotionCategoriesSettingTests` (parse, diagnostics, applier, Settings rows,
   catalog actions, toggles write the key, managed refusal).

## Inventory

255 gated call sites in 112 source files (outside
`CmuxNextDesign/Motion`), plus 15 test files moved to gates and 24 reviewed
`motion: allow` escapes in 10 files (each says how it still obeys its gate).
Rules used to assign a category: by module and file (sidebar, tabs, layout,
...), then per call: loop helpers (spinners, pulses, flashes, attention) go to
`indicators`, and `hover`, `hoverOut` and `focus` fade tokens go to `feedback`,
except in Home, the cursor and indicators.

### `sidebar`: 62 call sites in 18 files

- `CmuxNextApp/Windows/CollapsedBandReveal.swift` (3)
- `CmuxNextSidebar/Logic/SidebarLayout+Viewport.swift` (2)
- `CmuxNextSidebar/Views/ChromeDecorations.swift` (6)
- `CmuxNextSidebar/Views/DragLiftView.swift` (12)
- `CmuxNextSidebar/Views/NSView+HoverReveal.swift` (1)
- `CmuxNextSidebar/Views/NSView+TrailingFade.swift` (1)
- `CmuxNextSidebar/Views/ProfileBarView.swift` (2)
- `CmuxNextSidebar/Views/Sections/SidebarRegionView.swift` (1)
- `CmuxNextSidebar/Views/SidebarContainerView.swift` (2)
- `CmuxNextSidebar/Views/SidebarDragSpring.swift` (4)
- `CmuxNextSidebar/Views/SidebarDropOutlineView.swift` (2)
- `CmuxNextSidebar/Views/SidebarListView+Drag.swift` (2)
- `CmuxNextSidebar/Views/SidebarListView+Layout.swift` (2)
- `CmuxNextSidebar/Views/SidebarResizeHandle.swift` (1)
- `CmuxNextSidebar/Views/SidebarRowMotion.swift` (6)
- `CmuxNextSidebar/Views/SidebarSpacePaging.swift` (6)
- `CmuxNextSidebar/Views/SidebarView+Reveal.swift` (2)
- `CmuxNextSidebar/Views/WorkspaceRowView.swift` (7)

### `tabs`: 17 call sites in 8 files

- `CmuxNextApp/Drag/TabDragSession+Ghost.swift` (1)
- `CmuxNextApp/Drag/TabDragSession.swift` (3)
- `CmuxNextTabs/NewTabButtonView.swift` (2)
- `CmuxNextTabs/PaneToolbarView.swift` (2)
- `CmuxNextTabs/TabCell.swift` (5)
- `CmuxNextTabs/TabEdgeFade.swift` (2)
- `CmuxNextTabs/TabStripView+Sync.swift` (1)
- `CmuxNextTabs/TabStripView.swift` (1)

### `panes`: 38 call sites in 20 files

- `CmuxNextApp/SleepyMode/SleepySceneView.swift` (2)
- `CmuxNextDaemonRecovery/DaemonConnectingView.swift` (1)
- `CmuxNextDesign/BackdropVideoView.swift` (2)
- `CmuxNextDesign/DropOutlineRing.swift` (5)
- `CmuxNextDesign/Launch/LaunchMarkView.swift` (4)
- `CmuxNextDesign/Launch/LaunchReveal.swift` (1)
- `CmuxNextDesign/WindowMaterialView.swift` (3)
- `CmuxNextLayout/Views/DropHighlightView.swift` (2)
- `CmuxNextLayout/Views/DropOverlay/DropOverlayGlassRenderers.swift` (2)
- `CmuxNextLayout/Views/DropOverlay/DropOverlayLightRenderers.swift` (2)
- `CmuxNextLayout/Views/DropOverlay/DropOverlayLineRenderers.swift` (2)
- `CmuxNextLayout/Views/DropOverlay/DropOverlayPreviewRenderers.swift` (2)
- `CmuxNextLayout/Views/LayoutPaneContentProvider.swift` (2)
- `CmuxNextLayout/Views/LayoutRootView.swift` (1)
- `CmuxNextLayout/Views/PaneOverlayView.swift` (1)
- `CmuxNextLayout/Views/ScreenContentView+DividerDrag.swift` (1)
- `CmuxNextLayout/Views/ScreenContentView+Motion.swift` (2)
- `CmuxNextLayout/Views/StripScrollbarView.swift` (1)
- `CmuxNextOnboarding/Views/OnboardingWindowController.swift` (1)
- `CmuxNextPopups/BrowserPopupWindow.swift` (1)

### `overlays`: 52 call sites in 31 files

- `CmuxNextApp/Popups/CornerPanelMotion.swift` (1)
- `CmuxNextApp/Server/ServerMenuBarController.swift` (1)
- `CmuxNextBrowser/PageInfo/UI/PageInfoToggle.swift` (2)
- `CmuxNextBrowser/PageInfo/UI/PageInfoWindows.swift` (1)
- `CmuxNextBrowser/UI/BrowserChromeView+CookieImport.swift` (2)
- `CmuxNextBrowser/UI/BrowserChromeView+Notice.swift` (2)
- `CmuxNextBrowser/UI/BrowserChromeView+Toolbar.swift` (1)
- `CmuxNextBrowser/UI/BrowserChromeView.swift` (2)
- `CmuxNextBrowser/UI/ExtensionActionToolbar.swift` (4)
- `CmuxNextDesign/Overlay/WindowOverlayHost+Present.swift` (2)
- `CmuxNextDesign/Toast/CmuxToastMotion.swift` (5)
- `CmuxNextFloating/QuickComposer/QuickComposerPanel+Floating.swift` (1)
- `CmuxNextFloating/QuickComposer/QuickComposerPanel.swift` (1)
- `CmuxNextFocusUI/MotionShortcutHintChipFader.swift` (2)
- `CmuxNextFocusUI/WhichKey/WhichKeyOverlay.swift` (2)
- `CmuxNextOnboarding/Steps/HelperDragPanel.swift` (1)
- `CmuxNextPalette/PaletteContentView.swift` (7)
- `CmuxNextRemoteView/Pane/RemoteDesktopPaneView.swift` (1)
- `CmuxNextServer/Views/AddServerCardPanel.swift` (1)
- `CmuxNextServer/Views/ServerApproverView.swift` (1)
- `CmuxNextServer/Views/ServerHealthView.swift` (1)
- `CmuxNextServer/Views/ServerPanelView.swift` (1)
- `CmuxNextSidebar/Views/SidebarCardPresence.swift` (1)
- `CmuxNextSidebar/Views/SidebarCardSlotMotion.swift` (1)
- `CmuxNextSidebar/Views/SidebarCardTransition.swift` (1)
- `CmuxNextSidebar/Views/SidebarNoticeCardView.swift` (1)
- `CmuxNextSidebar/Views/SidebarNowPlayingCardView.swift` (1)
- `CmuxNextSidebar/Views/SidebarUpdateCardView.swift` (1)
- `CmuxNextTerminal/TerminalFindBarView.swift` (2)
- `CmuxNextTerminal/TerminalSizedForChip.swift` (1)
- `CmuxNextTerminal/TerminalStatusBanner.swift` (1)

### `hoverCards`: 11 call sites in 4 files

- `CmuxNextDesign/HoverCards/HoverCardMotion.swift` (4)
- `CmuxNextDesign/HoverCards/HoverCardPanel.swift` (2)
- `CmuxNextDesign/Tooltip/TooltipPanel.swift` (4)
- `CmuxNextTabs/TabHoverCardView.swift` (1)

### `home`: 3 call sites in 3 files

- `CmuxNextAgentPane/AgentPaneView+Loading.swift` (1)
- `CmuxNextFloating/ChiefPet/ChiefPetController.swift` (1)
- `CmuxNextHome/NativeTranscript/HomeNativeTranscriptView.swift` (1)

### `cursor`: 4 call sites in 1 files

- `CmuxNextAgentCursor/AgentCursorLayer.swift` (4)

### `indicators`: 34 call sites in 12 files

- `CmuxNextAgentPane/AgentPaneView.swift` (1)
- `CmuxNextApp/Handlers/PaneHandlers+Verbs.swift` (1)
- `CmuxNextBrowser/UI/ProgressLineView.swift` (2)
- `CmuxNextDesign/StatusIndicator/StatusIndicatorAppearance.swift` (3)
- `CmuxNextDesign/StatusIndicator/StatusIndicatorLayer+Dots.swift` (2)
- `CmuxNextDesign/StatusIndicator/StatusIndicatorLayer.swift` (5)
- `CmuxNextDesign/Windows/WebTheme.swift` (1)
- `CmuxNextLayout/Views/PaneOverlayView.swift` (1)
- `CmuxNextSidebar/Views/SidebarNowPlayingControls.swift` (1)
- `CmuxNextTabs/TabCell+HibernationRing.swift` (2)
- `CmuxNextTabs/TabCell+StatusIndicator.swift` (12)
- `CmuxNextUpdater/UpdateSheetView.swift` (3)

### `feedback`: 25 call sites in 20 files

- `CmuxNextApp/WindowRootView+TitlebarReveal.swift` (1)
- `CmuxNextApps/Render/AppSceneDecorations.swift` (1)
- `CmuxNextApps/Render/AppSceneRowView.swift` (1)
- `CmuxNextApps/Store/Views/AppGrantsView.swift` (1)
- `CmuxNextApps/Store/Views/AppInstalledView.swift` (1)
- `CmuxNextBrowser/UI/OmnibarViews.swift` (1)
- `CmuxNextDesign/ChromeHover.swift` (3)
- `CmuxNextDesign/ColorTransition/ColorTransition.swift` (1)
- `CmuxNextDesign/HoverReveal.swift` (1)
- `CmuxNextDesign/ScrollEdgeFade.swift` (2)
- `CmuxNextLayout/Views/DividerHandleView.swift` (1)
- `CmuxNextLayout/Views/PaneOverlayView.swift` (3)
- `CmuxNextSettingsWindow/Views/ScrollEdgeFadeModifier.swift` (1)
- `CmuxNextSidebar/Views/DragLiftView.swift` (1)
- `CmuxNextSidebar/Views/Sections/SidebarSectionHeaderView.swift` (1)
- `CmuxNextSidebar/Views/SidebarDragSpring.swift` (1)
- `CmuxNextSidebar/Views/SidebarListView+Drag.swift` (1)
- `CmuxNextSidebar/Views/SidebarView+Reveal.swift` (1)
- `CmuxNextTabs/Groups/TabGroupChipCell.swift` (1)
- `CmuxNextTabs/PaneToolbarView.swift` (1)

### `web`: 3 call sites in 3 files

- `CmuxNextAgentPane/AgentPaneTheme.swift` (1)
- `CmuxNextAgentPane/AgentPaneView.swift` (1)
- `CmuxNextDesign/Windows/WebTheme.swift` (1)

### `(owner's gate: TitleFade)`: 6 call sites in 1 files

- `gate)` (6)


Other changes found by the inventory:

- `WorkspaceRowView` title arrival and rename transitions checked only Reduce
  Motion; with speed off they ran a `CATransition` of 0 s, which Core Animation
  plays at its 0.25 s default. They now ask `Motion.sidebar.animatesMovement`.
- `ColorTransition.current` read `Motion.speed == .off`; it now reads
  `Motion.feedback.isEnabled`.
- `WebTheme.statusIndicators` was static only under Reduce Motion; it now
  follows `Motion.indicators.animatesLoops` (speed off, master, category).
- Windows that animated by themselves (`animationBehavior`): Page Info,
  onboarding window and helper drag panel now ask their gate.
- Sleepy Mode's 10 fps sky draws a still frame when `Motion.panes.animatesLoops`
  is false.

## Not covered / residual risk

- Implicit Core Animation actions on standalone layers that change outside any
  transaction (0.25 s default) cannot be found statically. The code base already
  disables actions on nearly every layer change (about 280 `CATransaction`
  sites); none were found animating by themselves, but this was not proven
  site by site.
- AppKit's own animations that cmux does not drive (menus opening, sheets, the
  system full-screen transition, scroller fades) follow macOS, not these
  switches.
- `Packages/macOS/CmuxUpdater` and the computer-use helper are separate
  packages and were not changed.
- Websites in browser tabs are not changed (only cmux's own pages).
- A switch change reaches windows already animating at their next animation;
  a window's `animationBehavior` is read when the window is made.
