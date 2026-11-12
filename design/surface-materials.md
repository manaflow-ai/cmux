# Surface materials: what is native glass, what is web

Leo, 2026-11-09:

> we need to be auditing all of the app, like what is supposed to be native-looking, what is
> supposed to be not as native. [...] we can just have a lot of stuff be web views, because
> evidently, I mean, things can look kind of decent [...] sometimes you want glass, sometimes you
> want, like, the simulation of glass. [...] it's just a consistency, okay?

His reference is a settings window that is entirely a web view and still looks native. This page
has two parts. The first is the rule: each kind of surface, how it renders and which material it may
show. The second is the inventory: every surface of cmux NEXT today and where it stands. The kinds
and the kind of every native file that builds glass are in
`schemas/surface-materials/surface-materials.json`. `scripts/cmux-next/check-surface-materials.py`
enforces both, and it runs in the pre-push gate.

The other specs, and what each one owns:
- leo-workspace `design/glass.md`: glass levels, host glass, the lens.
- `design/overlay-surfaces.md`: the roles and the never-opaque rule.
- `design/menus.md`: menu rows and how menus open.

This page decides only which kind a surface is.

## Materials

| Material | What it is | Where it comes from |
|---|---|---|
| real glass | the system's material: Liquid Glass on macOS 26, vibrancy before that, and the opaque popup surface under Reduce Transparency | `Glass.makeSurface(role)` / `makeOverlayPanel`, `GlassPanelView`, `WindowMaterialView` |
| host glass | real glass that the App draws under a web page's surface; the page draws only the content | `data-host-glass="menu\|popover\|chip"` (webviews `ui/glass/hostGlass.ts`) → `AgentPaneView+HostGlass.swift` |
| page glass (simulated) | a web glass level: tint plus `backdrop-filter`, from `--ds-glass-<level>-*` | `.ui-glass` (webviews `ui/glass/glass.css`) |
| card veil (simulated) | a native veil and rim over the sidebar's glass, never a second glass | `CardSurfaceView` |
| clear | nothing of its own; it shows the window's material | the window chrome, see-through pages |
| system | NSMenu's own material | `NSMenu` |

## The rule

| Kind | Renders as | Material | Surfaces |
|---|---|---|---|
| window-chrome | native | real glass (the window's), with what sits on it clear | window backdrop, titlebar, sidebar, tab strip, dock backdrop, browser omnibar |
| system-menu | native NSMenu | system | app menu bar; right-click menus a page hands to the App (rows and SF Symbols only) |
| web-floating | **web** | host glass in a see-through Chromium agent pane; elsewhere the page glass at its level | menus, pickers (This Mac / Cloud / Remote, folder, model, mode, permissions), popovers, hover cards, slash / @ / emoji lists, tooltips in pages |
| web-content | **web** | clear on the window material; docked bars at the chrome level | chat, New Tab, Settings, Home pages, markdown, diff, history, onboarding |
| web-host | native shell, web content | real glass under or around the page's content | host glass, popups past a pane's edge (`WebPopupHost`, `DeclarativePopupHost`), the dialog page, web cards, the sidebar's Updated card, Session Info's panel, icon picker, quick composer |
| sidebar-card | native | card veil | Update Ready, notices, Now Playing |
| native-overlay | native | real glass | the floating native surfaces that exist today: palette, toasts, find bars, HUDs (which-key, zoom), drag ghosts, browser bubbles and cards, Chief pet, permission request, notifications panel, Home sheets. **A closed set.** |
| material-source | native | real glass | the shared glass itself and the hosts built on it: `Glass`, `GlassPanelView`, `OverlaySurface`, tooltip, hover card, find pill, shortcut chip |
| scene-renderer | native | real glass or card veil | the Apps scene renderer, which draws the material each scene node names |
| debug | native | real glass | Debug fixtures and playgrounds, never shipped |

What the rule means in practice:

- **New floating UI is web-floating.** A menu, picker, popover, card or sheet is written in shared
  web, and in the agent pane it gets the App's own glass through host glass. That puts it on the
  same material as a native menu, with no new Swift. A new native glass surface needs a kind in the
  manifest and a reason in its PR. The check fails on one without a kind.
- **Content is web and clear.** A page never draws a glass box of its own around content. It sits
  on the window's material, as the settings reference does. Only bars docked on the window take the
  chrome level.
- **Floating web glass in the agent pane is host glass, always.** A `ui-popup ui-glass` surface there
  without `data-host-glass` reads as a flat box beside the menus that are on the App's glass: two
  materials for one kind. The check fails on one. `host-glass-allow: <reason>` exempts a single
  surface; the current offenders are a backlog list (below) that only shrinks.
- **Real glass never shows empty.** The content of a surface is on screen before its glass lands
  under it. That is the empty glass box before menus, fixed in cmux#39931.
- **Window chrome and system menus stay native.** They are the frame that web content sits in.
- Reduce Transparency is the one opaque path, for every kind (`overlay-surfaces.md`).

## One floating material (2026-11-11)

Leo, 2026-11-11, on the context card over the composer beside the model picker and the native menus:

> Like, man, it's really f***ing ugly when it mixes like this, you know?

> The whole point is to have things show through to show off the f***ing art. The point is, the
> styles mix and they don't look good. So they need to look good.

His reference is the account menu of a desktop chat app: one translucent surface, one radius, one row rhythm.

- **Every floating web surface is one material**: menus, context menus, selects, popovers, pickers
  (the model picker included), the combobox, the slash and @ lists, hover cards and the context
  ring's card are all the menu glass level (`--ds-glass-menu-tint` 78%, `--ds-glass-menu-blur`),
  one radius (`--ui-popup-radius`, the native popovers' 8 pt), one hairline and one drop. On the
  App's glass each lays the same 40% veil of the theme surface (`--host-glass-fill`). No surface
  sets a tint, blur, veil or radius of its own (`webviews/test/glass-levels.test.ts`).
- **Translucent, never opaque.** The art shows through every surface the same way; the frost and
  the veil keep text legible. A solid fill is never the fix (`design/menus.md`).
- Removed private looks: the model menu's 92% tint and 10 px corner, the + menu's and New Tab
  suggestions' 86%, the context card's popover level (70%, 24 px), and the model menus' private
  veil (now everyone's). Gallery `ui.menu-material`: before, one, host-clear, host-veil (ships),
  host-veil-light, dense.
- The popover level stays for glass in the page that is not a popup: the composer, Session Info,
  the running tray, side tabs.
- Native NSMenus stay system-drawn (Lawrence 2026-10-23: "we don't want ANYTHING custom besides the
  icons"). Host glass puts the web menus on the same App material, so the two meet; the web side
  matches the native one, never the reverse.

## Inventory (2026-11-09, feat-cmux-next efdf71a9)

`Sources/` is `Packages/macOS/CmuxNext/Sources/`; `W/` is `webviews/src/`.

### Native

| Surface | Kind | Material | Code |
|---|---|---|---|
| Window backdrop | window-chrome | real glass (regular or clear Liquid Glass, frosted, translucent tint, or opaque by setting) | `Sources/CmuxNextDesign/WindowMaterialView.swift` |
| Titlebar, toolbar band | window-chrome | clear | `CmuxNextApp/Windows/TitlebarToolbarBand.swift` |
| Sidebar | window-chrome | clear; real glass when it floats over content; the stuck project header's veil is the sidebar tone over a within-window blur | `CmuxNextSidebar/Views/SidebarContainerView.swift`, `SidebarStuckVeilView.swift` |
| Tab strip | window-chrome | clear; one real glass panel in the glass tab style | `CmuxNextTabs/TabStripView.swift` |
| Dock backdrop | window-chrome | real glass rim around the terminal's background | `CmuxNextLayout/Views/DockBackdropView.swift` |
| Browser omnibar | window-chrome | real glass | `CmuxNextBrowser/UI/OmnibarViews.swift` |
| Terminal pane | (content, native Metal) | clear on the window material | `CmuxNextTerminal` |
| Sidebar cards | sidebar-card | card veil | `SidebarNoticeCardView`, `SidebarUpdateCardView`, `SidebarNowPlayingCardView`, app health's footer chip (`AppHealthIndicatorView`) |
| Command palette | native-overlay | real glass | `CmuxNextPalette/PaletteContentView.swift` |
| Tooltips, hover cards | material-source | real glass | `CmuxNextDesign/Tooltip/TooltipPanel.swift`, `HoverCards/HoverCardPanel.swift` |
| Toasts | native-overlay | real glass (the toast role: Liquid Glass on macOS 26, the blur before it, opaque under Reduce Transparency) | `CmuxNextDesign/Toast/CmuxToastView.swift`, `CmuxToastOverlayHost.swift` |
| Find bars (terminal, browser) | native-overlay | real glass (the find pill) | `CmuxNextDesign/FindPill/FindPillView.swift` |
| Which-key HUD, pane zoom, shortcut chips | native-overlay | real glass | `WhichKeyOverlay.swift`, `PaneZoomIndicatorView.swift` |
| Tab and link drag ghosts, drop overlay | native-overlay | real glass | `TabDragGhostPanel.swift`, `LinkDragGhost.swift`, `DropOverlayGlassRenderers.swift` |
| Browser bubbles and cards (page info, extensions, bookmarks, downloads, notices, prompt bar) | native-overlay | real glass | `CmuxNextBrowser/UI/*`, `PageInfo/UI/PageInfoPanel.swift` |
| Permission request, notifications panel, restart notice, update sheet | native-overlay | real glass | `PermissionRequestPanel.swift`, `NotificationsPanelView.swift` |
| Home sheets, recipient suggestions, agent pill card | native-overlay | real glass | `CmuxNextHome/*` |
| Chief pet, quick composer | native-overlay / web-host | real glass | `CmuxNextFloating/*` |
| Right-click menus | system-menu | system | `CmuxNextDesign/Overlay/WebContextMenu.swift`, `CmuxNextPages/PageMenuPresenter.swift` |
| Debug Settings | (debug, SwiftUI) | flat | `CmuxNextSettingsWindow/SettingsPane.swift` |

### Web on the App's glass (web-host)

| Surface | Material | Code |
|---|---|---|
| Agent pane menus, popovers, comboboxes, hover cards, tooltips | host glass | `W/ui/Popover.tsx`, `Menu.tsx`, `ContextMenu.tsx`, `Combobox.tsx`, `Tooltip.tsx` → `AgentPaneView+HostGlass.swift` |
| Session Info | host glass | `W/agent-session/acpmux/session-info/SessionInfo.tsx` |
| Menu past a pane's edge | real glass panel with native rows | `CmuxNextDesign/Overlay/WebPopupHost.swift`, `DeclarativePopupHost.swift` |
| Dialogs, web cards | real glass under the page | `OverlayDialogCard.swift`, `WebCardPanel.swift` |
| Sidebar's Updated card | real glass under the page, plus the page's own blur | `SidebarUpdatedCardHost.swift`, `W/pages/changelog/updateSurfaces.css` |

### Web

| Surface | Kind | Material | Code |
|---|---|---|---|
| Agent chat, transcript | web-content | clear | `W/agent-session/acpmux/*` |
| Composer box | web-content | page glass (popover level, with its own rim) | `W/ui/glass/composerMaterial.css` |
| New Tab page | web-content | clear; its suggestions at 86% page glass | `W/agent-session/acpmux/newtab/*` |
| Settings | web-content | clear; its menus page glass (no host glass in that page) | `W/pages/settings`, `W/pages/shared/pageBase.css` |
| Markdown, diff, files | web-content | clear; headers and toolbar menus page glass | `W/pages/markdown`, `W/pages/diff`, `W/styles.css` |
| Home messages and channels | web-content | page glass headers | `W/pages/home-messages`, `W/pages/home-channels` |
| Onboarding | web-content | page glass cards | `W/pages/onboarding/styles.css` |
| In-page dialogs | web-floating | page glass | `W/ui/Dialog.tsx` |

### Inconsistent today (the backlog)

These are floating surfaces in the agent pane drawn on page glass, which reads as a flat box next to
the host-glass menus around them. They are listed in `web_floating_pending`. The check fails a new
one, and it fails an entry once its surface is fixed, so the list only shrinks:

- the feature tip (`W/ui/FeatureTip.tsx`);
- the full model picker with its harness rail (`ModelPicker.tsx` `PickerDialog`). The quick model
  menus are already on host glass with their 40% veil (`modelPicker.css`);
- the slash, @ and emoji lists (`SlashMenu.tsx`, `Composer.tsx`, `MentionMenu.tsx`, `EmojiMenu.tsx`);
- the in-pane palette menu (`PaletteMenu.tsx`);
- New Tab's omni list (`NewTabPage.tsx`);
- the steer queue (`steerQueue/SteerQueue.tsx`);
- the agents list (`subagents/AgentsPill.tsx`).

The empty glass box before menus was the worst inconsistency, and cmux#39931 fixes it. The order
for the rest:
1. The feature tip and the full model picker: one mark each, with the quick menus' 40% veil for the picker.
2. The composer's lists. They sit next to the composer, which no filter may blur, and
   `data-glass-keeps-underlay` already handles that.
3. The rest.

## Screenshots

The gallery shows the materials side by side (`bun run gallery:dev`, or the gallery advisory run on
a PR):
- `ui.host-glass`: page glass before, host glass clear, and the open order as frames
  (`open-together` is the empty box, `open-content-first` ships);
- `ui.liquid-glass`: the glass levels and the lens.

Mac captures of real glass come from `cmux-ci capture`. A lane VM cannot record a Mac, so the
real-material check for the flash fix is Leo's nightly.

## Check

`python3 -I scripts/cmux-next/check-surface-materials.py .`, with its tests in
`scripts/cmux-next/tests/check-surface-materials.test.sh`, runs in the pre-push gate. Its rules:
- `native-unlisted`: a native file builds glass and has no kind;
- `native-kind`: a native file has a web kind or an unknown kind;
- `native-material`: a material its kind does not allow, such as a sidebar card on real glass;
- `native-stale`: an entry whose file no longer builds glass;
- `web-floating`: a floating glass surface in the agent pane without host glass, or a pending entry
  that is already fixed.
