# Chrome desktop (macOS) Extensions menu, extension context menu, toolbar actions, audio UI: parity spec

Source: upstream Chromium `main` at `2dca33025a6310ce8846070e902f7a48f3a89de4` (2026-10-19), sparse clone at
`/Users/lawrence/fun/cmux-worktrees/chromium-src-ref`. All paths below are relative to that root. All sizes are DIP.
"cite" = `path:line`. Short prefixes used: `EXT/` = `chrome/browser/ui/views/extensions/`, `UIEXT/` = `chrome/browser/ui/extensions/`, `GRD` = `chrome/app/generated_resources.grd`.

## 0. Feature flags that decide what you are matching

| Flag | Default on desktop (source) | Effect | Cite |
|---|---|---|---|
| `extensions_features::kExtensionsMenuAccessControl` | **DISABLED** (enabled only on Android) | OFF = **legacy menu** (`ExtensionsMenuView`: "Full access / Access requested / No access needed" sections, pin button per row). ON = **new menu** (`ExtensionsMenuMainPageView` + site-permissions sub-page, site toggle, per-extension toggle, request-access chip in toolbar). | `extensions/common/extension_features.cc:165-170` |
| Field trial `ExtensionsToolbarAndMenuRedesign` | enables `ExtensionsMenuAccessControl` on mac in the *testing* config | Only proves the experiment exists; Finch decides real Stable population. | `testing/variations/fieldtrial_testing_config.json:7525-7537` |
| `features::IsRoundedIconsEnabled()` = `kDesktopGlowUp \|\| kRoundedIcons` | both OFF | OFF = use the `*ChromeRefreshOld*` / `*Old*` vector icons listed below. | `ui/base/ui_base_features.cc:535-538` |
| `kExtensionsToolbarZeroState` | DISABLED | puzzle hidden when profile has 0 extensions | `extension_features.cc:180`, `EXT/extensions_toolbar_desktop.cc:1113-1118` |
| `use_titlecase` (GRIT) | true on Mac | Mac uses the **Title Case** variants of menu strings (e.g. "Manage Extensions", "Pin to Toolbar"). | `GRD:5975`, `GRD:6068` |

Both menus are **bubbles (views::BubbleDialogDelegate), not NSMenus**. The per-extension "⋮" context menu **is** a menu, but a Views-drawn `MenuItemView` (not native NSMenu) because it is run through `MenuRunner(std::unique_ptr<MenuItemView>)` (`EXT/extension_context_menu_controller.cc:45-68`).

## 1. Shared metrics (resolved values)

| Metric | Value | Cite |
|---|---|---|
| `INSETS_DIALOG` | 20 all sides | `chrome/browser/ui/views/chrome_layout_provider.cc:52-54` |
| `INSETS_VECTOR_IMAGE_BUTTON` | 4 all sides | `chrome_layout_provider.cc:65-66` |
| `DISTANCE_EXTENSIONS_MENU_WIDTH` (new menu width) | 448 (`kMediumDialogWidth`) | `chrome_layout_provider.cc:132-133`, `ui/views/layout/layout_provider.h:261` |
| `DISTANCE_BUBBLE_PREFERRED_WIDTH` (legacy menu width) | 320 (`kSmallDialogWidth`) | `ui/views/layout/layout_provider.cc:88-89`, `layout_provider.h:260` |
| `DISTANCE_EXTENSIONS_MENU_BUTTON_ICON_SIZE` | 20 | `chrome_layout_provider.cc:134-135` |
| `DISTANCE_EXTENSIONS_MENU_BUTTON_ICON_SMALL_SIZE` | 16 | `:136-137` |
| `DISTANCE_EXTENSIONS_MENU_EXTENSION_ICON_SIZE` | 28 | `:138-139` |
| `DISTANCE_EXTENSIONS_MENU_ICON_SPACING` | (28-20)/2 = 4 | `:140-143` |
| `DISTANCE_EXTENSIONS_MENU_BUTTON_MARGIN` | 12 | `:144-145` |
| `DISTANCE_EXTENSIONS_MENU_LABEL_ICON_SPACING` | 4 | `:146-147` |
| `DISTANCE_RELATED_CONTROL_VERTICAL_SMALL` | 8 | `:150-151` |
| `DISTANCE_RELATED_LABEL_HORIZONTAL_LIST` | 8 | `:154-155` |
| `DISTANCE_UNRELATED_CONTROL_HORIZONTAL_LARGE` / `_VERTICAL_LARGE` | 16 / 16 | `:162-165` |
| `DISTANCE_RELATED_LABEL_HORIZONTAL` | 12 | `ui/views/layout/layout_provider.cc:133-134` |
| `DISTANCE_CONTROL_LIST_VERTICAL` | 12 (HoverButton vertical pad = 12/2 = 6) | `layout_provider.cc:96-97` |
| `DISTANCE_BUTTON_HORIZONTAL_PADDING` (HoverButton horiz pad) | 16 | `layout_provider.cc:90-91` |
| `kExtensionsMenuButtonRadius` | `kXSmall` = 4 | `chrome_layout_provider.cc:330`, `layout_provider.cc:249-250` |
| Dialog / bubble corner radius (`kDialogRadius`) | `kMediumSmall` = 12 | `layout_provider.cc:212`, `:251-252` |
| Menu corner radius (`kMenuRadius`) | 12 | `layout_provider.cc:213` |
| Section container corner radius (new menu) | 12 (`kContainerBackgroundRadius`) | `EXT/extensions_menu_main_page_view.cc:63` |

Typography (font size pt / weight / line height):

| Style | Size / weight | Line height | Cite |
|---|---|---|---|
| `STYLE_HEADLINE_4` | 16 / Medium | 24 | `ui/views/style/typography_provider.cc:201-203`, `:355` |
| `STYLE_BODY_2_EMPHASIS` (=BODY_2_MEDIUM) | 14 / Medium | 20 | `:230-232`, `:359` |
| `STYLE_BODY_3` | 13 / Normal | 20 | `:238-240`, `:360` |
| `STYLE_BODY_3_EMPHASIS` (=BODY_3_MEDIUM) | 13 / Medium | 20 | `:242-244`, `typography.h:145-146` |
| `STYLE_BODY_4` | 12 / Normal | 18 | `:254-256`, `:361` |
| `STYLE_BODY_5` | 11 / Normal | 16 | `:270-272`, `:363` |
| `CONTEXT_DIALOG_TITLE` (legacy bubble title, Chrome) | 15 pt, line 22 | `chrome/browser/ui/views/chrome_typography_provider.cc:65,92-93,198` |
| `CONTEXT_BADGE` (toolbar badge text) | 9 pt **Bold** | `chrome_typography_provider.cc:70,83-85` |
| Chrome default (unstyled label/LabelButton) | 12 pt | `chrome_typography_provider.cc:69,74` |
| Menu item font (context menus) | `CONTEXT_MENU` + `STYLE_BODY_3` = 13 pt | `ui/views/controls/menu/menu_config.cc:84-85` |
| Legacy bubble title label | `CONTEXT_DIALOG_TITLE` + `STYLE_HEADLINE_4` (16 Medium) | `ui/views/bubble/bubble_frame_view.cc:127,173` |

Colors (light / dark, default Google grayscale palette; `ui/color/ref_color_mixer.cc:128-160`, `ui/color/sys_color_mixer.cc:150-300`):

| Color id | Resolves to | Light | Dark | Cite |
|---|---|---|---|---|
| `kColorExtensionsMenuText` | `kColorSysOnSurface` | #1F1F1F | #E3E3E3 | `chrome/browser/ui/color/material_chrome_color_mixer.cc:161` |
| `kColorExtensionsMenuSecondaryText` | `kColorSysOnSurfaceSubtle` | #474747 | #C7C7C7 | `material_chrome_color_mixer.cc:162` |
| `kColorExtensionsMenuContainerBackground` | `kColorSysSurface3` = blend(#6991D6 over Surface, 0x1C) light; dark = blend(#D1E1FF over #1F1F1F, 0x1C) or Neutral20 #303030 with `kDarkModeSurfaceTokens` | ~#EEF3FA | ~#333438 | `chrome/browser/ui/color/chrome_color_mixer.cc:472`, `sys_color_mixer.cc:188-203` |
| `kColorExtensionMenuIcon` | `ui::kColorIcon` → `kColorSysOnSurfaceSubtle` | #474747 | #C7C7C7 | `chrome_color_mixer.cc:465`, `ui/color/material_ui_color_mixer.cc:87` |
| `kColorExtensionMenuIconDisabled` | `kColorIconDisabled` | | | `chrome_color_mixer.cc:466` |
| `kColorExtensionMenuPinButtonIcon` (legacy, pinned) | accent (`kColorAccentWithGuaranteedContrastAtopPrimaryBackground`) = Primary40 #0B57D0 / Primary80 #A8C7FA | #0B57D0 | #A8C7FA | `chrome_color_mixer.cc:467-469` |
| `kColorExtensionMenuPinButtonIconDisabled` | pin color at `kDisabledControlAlpha` | | | `:470-471` |
| `kColorHoverButtonBackgroundHovered` (row hover) | `kColorSysStateHoverOnSubtle` = Neutral10 @0x0F / Neutral99 @0x1A | #1F1F1F @6% | #FDFCFB @10% | `chrome_color_mixer.cc:557`, `sys_color_mixer.cc:275-277` |
| Bubble background | `kColorBubbleBackground` → `kColorSysSurface` | #FFFFFF | #1F1F1F | `ui/color/material_ui_color_mixer.cc:44` |
| `kColorExtensionIconBadgeBackgroundDefault` (CR2023) | `kColorSysNeutralContainer` | #F2F2F2 | #282828 | `material_chrome_color_mixer.cc:469-470` |
| Badge text default | max-contrast vs badge bg (black/white) | | | `UIEXT/icon_with_badge_image_source.cc:99-103` |
| `kColorToolbarButtonIcon` | `kColorSysOnSurfaceSecondary` | #474747 | #C7C7C7 | `material_chrome_color_mixer.cc:558-559` |
| `kColorToolbarInkDropHover` / `Ripple` | SysStateHoverOnSubtle / SysStateRippleNeutralOnSubtle (Neutral10 @0x14 light, Neutral99 @0x29 dark) | | | `material_chrome_color_mixer.cc:569-570`, `sys_color_mixer.cc:281-283` |
| Blocked-action decoration | white circle r=12 with shadows (0,1) blur 4 @0x4D and (0,2) blur 12 @0x26 | | | `chrome_color_mixer.cc:460-464`, `icon_with_badge_image_source.cc:232-266` |

## 2. Toolbar: puzzle button + action buttons (C)

### 2.1 Puzzle ("Extensions") button — `EXT/extensions_toolbar_button.cc`
| Property | Value | Cite |
|---|---|---|
| Size | toolbar button size = `kToolbarButtonHeight` 34×34 (48 touch) | `EXT/extensions_toolbar_desktop.cc:698-705`, `chrome/browser/ui/layout_constants.cc:131-132` |
| Icon | 20 (`kDefaultIconSizeChromeRefresh`), centered via layout insets | `:189-196`, `:100-124`, `chrome/browser/ui/layout_constants.h:371` |
| Icon glyph | default `kExtensionChromeRefreshOldIcon` (`components/vector_icons/extension_chrome_refresh_old.icon`); new-menu states: all blocked `kExtensionOffOldIcon`, any has access `kExtensionOnOldIcon` | `UIEXT/extensions_toolbar_view_model.cc:175-190` |
| Opens on | mouse **press** (`NotifyAction::kOnPress`); press again closes | `:44-45`, `:150-158` |
| Tooltip | "Extensions" (`IDS_TOOLTIP_EXTENSIONS_BUTTON`); new menu: also "Extensions not allowed on this site" / "Extensions allowed on this site" | `:75`, `UIEXT/extensions_toolbar_view_model.cc:212-224`, `GRD:10300-10312` |
| A11y | role button, `HasPopup::kMenu`; name "Extensions menu" (`IDS_ACC_NAME_EXTENSIONS_BUTTON`), states "Extensions not allowed on this site. Select to open menu" / "Extensions allowed on this site. Select to open menu" | `:50`, `:59-71`, `GRD:10313-10321` |
| Pressed state | held (pressed lock) while bubble open | `:160`, `:140-144` |
| Ink drop | circle (Emphasis::kMaximum radius) inset so it is `kLocationBarHeight` 34 tall; hover/ripple colors above | `chrome/browser/ui/views/toolbar/toolbar_ink_drop_util.cc:36-70` |
| Visibility | container hidden when profile has no extensions; otherwise always visible (normal mode) | `EXT/extensions_toolbar_desktop.cc:174-175`, `:1113-1123` |
| Placement | pinned action views left→right, then popped-out action(s), then request-access chip (new menu), then puzzle (rightmost); 2 DIP horizontal margin on every child | `:183-193`, `:643-660`, `:255-256` |

### 2.2 Toolbar action button — `chrome/browser/ui/views/toolbar/toolbar_action_view.cc`
| Property | Value | Cite |
|---|---|---|
| Kind | `MenuButton`, triggers on mouse **release** | `:73-94` |
| Size | `GetToolbarActionSize()` = 34×34 (fallback 28×28) | `:226-229`, `EXT/extensions_toolbar_desktop.cc:698-705` |
| Border | zero insets (badge draws to the edge) | `:116-125` |
| Icon | extension action icon rendered at `ActionIconSize()` (16, `EXTENSION_ICON_BITTY`) centered in the canvas; disabled state = desaturated default disabled icon; grayscale when action disabled (HSL shift {-1,0,0.6}) | `:203-208`, `UIEXT/icon_with_badge_image_source.cc:166-195`, `extensions/browser/extension_action.cc:74-80` |
| Badge | height 14; text font 9 pt bold; width = min(text,23)+2×2 padding, min 14, parity-matched to icon area; right-aligned in the 28×28 centered icon area, centered if width ≥20; bottom-aligned; bg rounded rect r=4 (outer 3 + 1); a 1-DIP transparent "cutout" r=3 around it clears the icon; bg = extension-specified color made opaque or `kColorExtensionIconBadgeBackgroundDefault`; text = extension color or max-contrast | `icon_with_badge_image_source.cc:39`, `:89-163`, `:197-228` |
| Blocked-action decoration | white circle r=12 behind icon with 2 shadows (when action wants to run but is withheld) | `:230-266` |
| Left click | if popup showing: hide it and swallow release; else ink drop ACTION_PENDING then `ExecuteUserAction(kToolbarButton)`; if action disabled: show the context menu instead | `:231-255`, `:344-355` |
| Right click / Down arrow | context menu (§4) anchored `kTopLeft` to button bounds | `:96-100`, `:155-159`, `EXT/extension_context_menu_controller.cc:60-68` |
| Keyboard reorder | `event_utils::GetReorderCommandForKeyboardEvent` (Cmd+Shift+Left/Right on Mac) moves pinned action by ±1 | `:137-153` |
| Drag reorder | drag only pinned + draggable (not incognito); insertion index = midpoint rule clamped to pinned count; live reorder preview; drop calls `MovePinnedAction` | `EXT/extensions_toolbar_desktop.cc:757-796`, `:976-1043` |
| Popped out | an unpinned extension whose popup/dialog opens is temporarily shown (between pinned icons and puzzle), removed when popup closes | `:491-560`, `:593-640` |
| Popup open | button stays pressed (pressed lock) while popup shows | `:327-342` |
| Tooltip | legacy: extension tooltip (`GetTooltip`); new menu: no tooltip, rich hover card instead | `:210-213`, `:166-194` |
| Hover/ink | toolbar ink drop (circle 34), shows when hot-tracked; ink kept while context menu shows | `:77-79` |
| A11y name | `view_model->GetAccessibleName(web_contents)` | `:198` |

### 2.3 Request-access chip (new menu only) — `EXT/extensions_request_access_button.cc`
Visible when ≥1 extension requests access on the current site. Text "Allow {N}?" (`IDS_EXTENSIONS_REQUEST_ACCESS_BUTTON`, `GRD:6423`), tooltip "Click to allow on {ORIGIN}:" + list (`GRD:6432`), after granting shows "Allowed" briefly (`GRD:6429`). Has a hover card, and an input-protector against accidental clicks. Cites `:62-82`, `:87-96`, `:98-111`.

## 3. Extensions menu bubble (A)

### 3.1 Common bubble frame
| Property | Legacy (`EXT/extensions_menu_view.cc`) | New (`EXT/extensions_menu_coordinator.cc`) |
|---|---|---|
| Type | `BubbleDialogDelegateView`, arrow from container (TOP_RIGHT default) | `BubbleDialogDelegate`, arrow TOP_RIGHT, `DIALOG_SHADOW`, autosize (`:86-90`) |
| Width | fixed 320 (`:126-127`) | fixed 448 (`:94-96`) |
| Margins | 0 (`:102`) | 0 (`:93`) |
| Title/close | frame title "Extensions" + frame close button (`:105-106`) | drawn inside page (header row) |
| Buttons | none (`:104`) | none (`:101`) |
| Arrow-key traversal | yes (`:119`) | yes (`:102`) |
| Anchor highlight | anchor's MenuButtonController handles it (`:121-124`) | same (`:97-100`) |
| Window a11y title | empty (to avoid "Alert Extensions") (`:108-117`, `:437-440`) | n/a |
| Corner radius | 12 (dialog radius) | 12 |
| Close when empty | n/a | if there are 0 entries the bubble closes immediately (`EXT/extensions_menu_delegate_desktop.cc:417-426`) |
| Pages | single | main page ↔ site-permissions page swap in the same bubble (`extensions_menu_delegate_desktop.cc:429-442`, `:564-571`) |

### 3.2 LEGACY menu (flag OFF; source default)
Layout top→bottom (`EXT/extensions_menu_view.cc:144-212`):
1. Frame title "Extensions" (16 Medium) + close (X) button.
2. ScrollView, max height **448**, no horizontal scroll, no overflow indicator (`:159-166`). Content inset H20 (dialog left) (`:225-226`). Three sections in this order: **Full access** (kGranted), **Access requested** (kWithheld + kActiveTab), **No access needed** (kNone) (`:269-271`, `:276-293`). Each section:
   - Header label: section short text, `CONTEXT_DIALOG_BODY_TEXT_SMALL` + `STYLE_EMPHASIZED` (semibold, 12pt), top border 12 (`:235-244`).
   - Description: multi-line, `CONTEXT_DIALOG_BODY_TEXT_SMALL` primary (`:247-253`).
   - Rows (sorted case-insensitive by name) (`:55-59`, `:295-316`).
   - Section hidden when it has no rows (`:350-361`).
3. `views::Separator` (`:168`).
4. Footer HoverButton "Manage Extensions" (Mac title case) with settings icon `kSettingsChromeRefreshOldIcon` 20, color `kColorIcon`; border V = item inset (12), H = 20+4; extra image-label spacing +4 (`:173-201`). Click → chrome://extensions.

Legacy row `ExtensionMenuItemView` (`EXT/extensions_menu_item_view.cc:107-198`), horizontal flex:
| Child | Spec | Cite |
|---|---|---|
| Primary `ExtensionsMenuButton` (HoverButton, flex) | icon = extension action icon 28×28; text = extension name (default 12pt label); tooltip = action tooltip; disabled if action disabled; border V8 H0 (12−4); bubble-menu-item config: no focus ring, ink drop with instant hover highlight, rect highlight | `EXT/extensions_menu_button.cc:34-58`, `chrome/browser/ui/views/bubble_menu_item_factory.cc:54-65` |
| Pin HoverButton (only when actions can show in toolbar) | border 12 all; icon 20: unpinned `kKeepOldIcon` color `kColorExtensionMenuIcon`; pinned `kKeepOffOldIcon` color accent (`kColorExtensionMenuPinButtonIcon`); tooltip "Pin" / "Unpin" / "Pinned by your Administrator"; a11y "Pin {name}" / "Unpin {name}" / "{name} is pinned by your Administrator"; disabled when force-pinned or incognito; click toggles pin and announces "Extension pinned"/"Extension unpinned" | `:164-193`, `:202-236`, `:269-278`, `:55-82` |
| Context "⋮" HoverButton | border 12; icon `kBrowserToolsChromeRefreshOldIcon` 20 (`kColorExtensionMenuIcon` / disabled color); tooltip "More options"; a11y name = extension name; opens §4 menu via MenuButtonController | `:137-162`, `:238-267` |
| Hover behavior | hovering a row button requests focus; leaving clears focus (keyboard + mouse share highlight) | `:84-103` |

Legacy section strings: "Full access" / "These extensions can see and change information on this site." ; "Access requested" / "To give an extension access to this site, click it." ; "No access needed" / "These extensions don't need to see and change information on this site." (`GRD:6454-6469`).

### 3.3 NEW menu main page (flag ON) — `EXT/extensions_menu_main_page_view.cc`
Root BoxLayout vertical, insets T20 L0 B(20−6)=14 R0 (`:202-218`). Children in order (`:219-237`):

| # | Block | Spec | Cite |
|---|---|---|---|
| 1 | Header | margins H20; Label "Extensions" `CONTEXT_DIALOG_TITLE`+`STYLE_HEADLINE_4` (16 Medium/24), color `kColorExtensionsMenuText`, flex; close button = `BubbleFrameView::CreateCloseButton` (icon `kCloseChromeRefreshOldIcon` 16 + 4 inset = 24×24, circular highlight, tooltip/a11y "Close") | `:483-503`, `ui/views/bubble/bubble_frame_view.cc:182-195` |
| 2 | Site settings row | margins V8 H20; cross-axis start; Label `STYLE_BODY_3_EMPHASIS`, multi-line, char-break, color text: "Allow extensions on {site}" or "Extensions are not allowed on {site}"; optional TooltipIcon (enterprise text, bubble width 320, arrow TOP_RIGHT); ToggleButton left margin 12, height forced to label line height (20); a11y name "Allow extensions", description empty; toggle tooltip "Extensions allowed on this site" / "Extensions are not allowed on this site". Toggle ON = customize per extension, OFF = block all. Hidden on restricted (chrome://) and policy-blocked sites. | `:223-226`, `:505-552`, `:240-254`, `:294-304`, `UIEXT/extensions_menu_view_model.cc:1040-1106`, `EXT/extensions_menu_delegate_desktop.cc:461-467` |
| 3 | ScrollView | max height 448, margins V8, content inset H20 | `:554-576` |
| 3a | Reload section (hidden by default) | `SectionContainer`: bg `kColorExtensionsMenuContainerBackground`, radius 12, inside insets V16 H16; centered: Label "To apply your updated settings to this site, reload this page" (`CONTEXT_DIALOG_BODY_TEXT_SMALL`+`BODY_3`, secondary color, multi-line) + MdTextButton "Reload" (tooltip "Reload page"), top margin 8. Shown when site setting changed and page needs reload. | `:157-174`, `:578-612`, `:406-423`, `UIEXT/extensions_menu_view_model.cc:1014-1038` |
| 3b | Requests section (hidden unless requests) | `SectionContainer`; header "Requests access" `BODY_2_EMPHASIS` 14 Medium; rows (top margin 8): ImageView extension icon 28, name `BODY_3_EMPHASIS` (flex, elide), MdTextButton kText "Dismiss" (tooltip "Dismiss request", a11y "Dismiss request for {name}"), MdTextButton kText "Allow" (left margin 8, tooltip "Allow extension to read and change this site", a11y "Allow {name} to read and change this site", click-protected). Allow = grant "Always on this site"; Dismiss = hide request for this tab. Rows sorted like entries. | `:306-368`, `:613-632`, `UIEXT/extensions_menu_view_model.cc:610-641`, `:1386-1448` |
| 3c | Menu entries container | `SectionContainer` (bg surface3, r12, insets V16 H16), top margin 8. Entries sorted case-insensitive by name; each entry after the first gets top interior margin 8. | `:634-636`, `:259-288`, `UIEXT/extensions_menu_view_model.cc:49-53` |
| 4 | "Discover more extensions" (Google Chrome branded only) | HoverButton, icon `kGoogleChromeWebstoreIcon`, opens Web Store with menu utm source | `:639-648` |
| 5 | "Manage Extensions" | HoverButton, icon `kSettingsChromeRefreshOldIcon`, opens chrome://extensions | `:651-670` |

HoverButton (rows 4–5): border V6 H16, icon-label spacing 12, full-width ink-drop hover fill `kColorHoverButtonBackgroundHovered`, no focus ring (focus = highlight), triggers on release, left+right mouse (`chrome/browser/ui/views/controls/hover_button.cc:35-51`, `:100-125`, `hover_button.h:104-105`).

**Entry view** `EXT/extensions_menu_entry_view.cc:171-331` (vertical, stretch):
- Main row (horizontal flex):
  - Action HoverButton (flex): icon = action icon 28×28, label `BODY_3_EMPHASIS` color `kColorExtensionsMenuText`, border 0, focus-ring radius 4, focus ALWAYS (`:211-232`). Click = run action (`UIEXT/extensions_menu_view_model.cc:771-782`). Disabled extensions keep focusable, state DISABLED, a11y description "{name} is disabled" (`:399-423`). A11y name = "{name}, {site access a11y}" when site-permissions button shown (`UIEXT/extensions_menu_view_model.cc:998-1009`).
  - Site access ToggleButton: left margin 8; a11y "Allow {name} on this site"; tooltip "Allowed on this site" / "Not allowed on this site"; visible only if user can customize this extension on this site; ON when site access ≠ on-click or currently granted; click-protected against unintended clicks; ON→ grant (restore Always on site / all sites, or one-time activeTab grant), OFF→ revoke (to on-click, or clear activeTab + reload bubble) (`:233-261`, `:345-350`, `UIEXT/extensions_menu_view_model.cc:309-344`, `:652-769`).
  - Context-menu HoverButton: left margin 8, border 4 all (20 icon → 28×28 hit), circle highlight, tooltip "More options"; icon normal = `kKeepOldIcon` (pin) when pinned else `kBrowserToolsChromeRefreshOldIcon` (⋮); hover/pressed always ⋮; a11y "See more options for {name}" / "{name} is pinned. See more options." (`:262-285`, `:425-450`, `UIEXT/extensions_menu_view_model.cc:202-210`, `:879-894`). **No separate pin button in the new menu** — pin is in the context menu.
- Secondary row:
  - Site-permissions HoverButton (enabled state): label `BODY_5` (11pt) `kColorExtensionsMenuSecondaryText`, left margin 28 (aligns under name), border H12, image-label spacing 4; non-enterprise: right-aligned arrow `kSubmenuArrowChromeRefreshOldIcon` 16; enterprise: left-aligned `kBusinessChromeRefreshOldIcon` 16; text = "Ask on every visit" / "Always on this site" / "Always on all sites" / "No access needed"; tooltip "Change site permissions" (or "Installed by your administrator"); a11y "{text}. Select to change site permissions" / "{text}. Installed by your administrator"; click → site-permissions page (`:40-88`, `:286-308`, `:352-394`, `UIEXT/extensions_menu_view_model.cc:212-307`).
  - Disabled state renders a non-focusable Label instead (same font/color, elide tail) (`:377-393`).
  - Status rules: hidden on restricted URLs; disabled on policy-blocked hosts; enterprise: hidden if user-blocked + no access, else disabled; non-enterprise: hidden if user blocked site, enabled if customizable, else disabled (`UIEXT/extensions_menu_view_model.cc:146-200`).

### 3.4 NEW menu site-permissions page — `EXT/extensions_menu_site_permissions_page_view.cc`
| Block | Spec | Cite |
|---|---|---|
| Header | interior margin T20 L20 R20; back ImageButton `kArrowBackOldIcon` 20 + 4 inset, circle highlight, tooltip/a11y "Back" → main page; extension icon 28 (left margin 8); name `STYLE_HEADLINE_4`, secondary text color, elide tail (left margin 8, flex); close button | `:232-286` |
| Separator | full width, margins V16 | `:161-174`, `:287-288` |
| "Site Permissions" label | `BODY_3_EMPHASIS`, margins H20 | `:294-303` |
| 3 radio rows | each: margins T16 L20 R20; RadioButton `BODY_3` text color, group 0, left margin 4, image-label spacing 4+8=12; description below `BODY_5` secondary, multi-line, indented 20+4+4+8 = 36. Options: "Ask on every visit" / "Runs only after you click the extension"; "Always on {site}" / "Runs automatically every time you visit this site"; "Always on all sites" / "Runs automatically on all sites you visit". Options disabled when extension cannot get that level. | `:176-225`, `:304-309`, `:388-421`, `UIEXT/extensions_menu_view_model.cc:896-956` |
| Separator | inset H20, margins V16 | `:311` |
| Show-requests row | "Allowed to show requests in the toolbar" `BODY_3_EMPHASIS` + ToggleButton (height = line height 20); a11y "Allowed to show requests" / "Not allowed to show requests" | `:312-344`, `:381-385`, `:424-429` |
| Separator | inset H20, top 16, bottom 16−6=10 | `:346-347` |
| "Manage this extension" | HoverButton, no leading icon, trailing `kSubmenuArrowChromeRefreshOldIcon` 20 in `kColorIconSecondary`, title `BODY_3_EMPHASIS`, border H20, bottom margin 14, tooltip "Manage extension settings" → chrome://extensions/?id= | `:110-117`, `:348-377` |

### 3.5 Keyboard + a11y summary
- Arrow-key traversal between focusable controls inside the bubble (`extensions_menu_view.cc:119`, `extensions_menu_coordinator.cc:102`). Esc closes (bubble default).
- Legacy rows: hover moves focus (`extensions_menu_item_view.cc:84-103`).
- New entry controls: action button, toggle, context button, site-permissions button are leaves with explicit names; descriptions cleared to avoid tooltip double-reading (`extensions_menu_entry_view.cc:313-330`).
- Toggles and "Allow" use `InputEventActivationProtector` (ignore clicks right after appear/move/navigation; key events not allowed) (`extensions_menu_entry_view.cc:98-157`, `extensions_menu_main_page_view.cc:98-147`).

### 3.6 Empty state
There is **no empty-state text**. With 0 extensions the puzzle button is hidden (§2.1); the new menu closes itself if it would have 0 entries (`extensions_menu_delegate_desktop.cc:417-426`).

## 4. Per-extension context menu (B) — `chrome/browser/extensions/extension_context_menu_model.cc`

Rendered as a Views menu (`MenuItemView`): corner radius 12, item vertical margin 6, horizontal border padding 12, font 13pt (BODY_3) → item height ≈ 32, separator height 17, submenu arrow 16, no mnemonics on Mac, accelerators hidden (`ui/views/controls/menu/menu_config.cc:84-95`, `menu_config_mac.mm:10-14`, `menu_config.h:220-222`). Anchor = button bounds, `kTopLeft` (`EXT/extension_context_menu_controller.cc:60-68`). Mac text = Title Case variants.

### 4.1 Legacy order (flag OFF) — `InitMenu` `:959-1047`
| # | Item (Mac text) | IDS | Condition / enabled | Action |
|---|---|---|---|---|
| 1 | {Extension name} (`&` escaped) | — | enabled iff homepage URL valid and not component | open homepage, new fg tab (`:454-460`, `:546-548`) |
| – | extension-contributed `chrome.contextMenus` items (with leading separator) | — | if any for `browser_action`/`action` context | custom (`:1090-1102`) |
| – | separator | | always | |
| 2 | "This Can Read and Change Site Data" ▸ submenu | `IDS_EXTENSIONS_CONTEXT_MENU_PAGE_ACCESS` | if extension can be affected or has activeTab on page; else item 2' | |
| 2a | ◉ "When You Click the Extension" | `..._PAGE_ACCESS_RUN_ON_CLICK` | radio; enabled iff selectable | set site access (`:653-677`) |
| 2b | ◉ "On {host}" (host = IDN, `www.` stripped) | `..._RUN_ON_SITE` | radio | |
| 2c | ◉ "On All Sites" | `..._RUN_ON_ALL_SITES` | radio | |
| 2d | separator + "Learn More About Site Access" | `..._PAGE_ACCESS_LEARN_MORE` | | open help URL |
| 2' | "Can't Read or Change Site's Data" (disabled) | `IDS_EXTENSIONS_CONTEXT_MENU_CANT_ACCESS_PAGE` | when not even on-click selectable | (`:1116-1121`) |
| – | separator (after page access block) | | only if block shown | |
| 3 | "Rate It..." | `IDS_EXTENSIONS_CONTEXT_MENU_RATE_IT` | `ShouldShowReviewPrompt` | CWS review URL |
| 4 | "Options" | `IDS_EXTENSIONS_OPTIONS_MENU_ITEM` | has options page | open options |
| 5 | "Remove from Chrome" | `IDS_EXTENSIONS_UNINSTALL` (`chrome/app/google_chrome_strings.grd:1083-1085`) | not component and not policy-required | uninstall confirm dialog |
| 5' | [building icon 16] "Installed by Your Administrator" (disabled) | `IDS_EXTENSIONS_INSTALLED_BY_ADMIN` | policy-required instead of 5 | — |
| 6 | "Pin" / "Unpin" / [building icon] "Pinned by your Administrator" | `IDS_EXTENSIONS_PIN_TO_TOOLBAR` / `UNPIN_FROM_TOOLBAR` / `PINNED_BY_ADMIN` | **only when opened from the toolbar icon** (`kToolbarAction`) and actions can show in toolbar; disabled in incognito or force-pinned | toggle pin (`:1016-1031`, `:555-577`) |
| – | separator + "Open Side Panel"/"Close Side Panel" | `IDS_EXTENSIONS_SUBMENU_OPEN/CLOSE_SIDE_PANEL_ITEM` | has sidePanel permission + side panel for tab | toggle panel (`:1049-1083`) |
| – | separator | | not component | |
| 7 | "Manage Extension" | `IDS_MANAGE_EXTENSION` | not component | chrome://extensions/?id= |
| 8 | "View Web Permissions" | `IDS_VIEW_WEB_PERMISSIONS` | not component | site settings for extension origin |
| – | separator + "Inspect Popup" | `IDS_EXTENSION_ACTION_INSPECT_POPUP` | developer mode on, non-synthesized action, has delegate; enabled iff popup exists and inspection allowed | DevTools on popup (`:1041-1046`, `:467-473`) |

### 4.2 New-menu order (flag ON) — `InitMenuWithFeature` `:747-957`
| # | Item (Mac text) | IDS | Condition |
|---|---|---|---|
| 1 | {Extension name} + contributed items | — | always (`:766-774`) |
| 2 | One of (only if extension requests host permissions or activeTab): "You Previously Chose To Allow All Extensions On {origin}" (disabled) / "You Previously Chose To Not Allow Any Extensions On {origin}" (disabled, not for policy-required) / "Can't Read or Change Site's Data" (disabled, site interaction none) / **"Site Permissions" ▸** {◉ "Ask on Every Visit", ◉ "Always on {origin}", ◉ "Always on All Sites", [sep + building icon "Installed by Your Administrator" if policy]} | `..._ALL_EXTENSIONS_GRANTED`, `..._ALL_EXTENSIONS_BLOCKED`, `..._CANT_ACCESS_PAGE`, `IDS_EXTENSIONS_CONTEXT_MENU_SITE_PERMISSIONS`, `..._RUN_ON_CLICK_V2`, `..._RUN_ON_SITE_V2`, `..._RUN_ON_ALL_SITES_V2` | `:781-871` |
| 3 | "Manage Site Permissions" | `IDS_EXTENSIONS_CONTEXT_MENU_PAGE_ACCESS_PERMISSIONS_PAGE` | same condition as 2; opens chrome://extensions/sitePermissions | `:873-878` |
| – | sep + [building] "Installed by Your Administrator" | | policy-required and not already in submenu | `:880-891` |
| – | separator | | if any of pin/options/uninstall present | `:893-898` |
| 4 | "Pin to Toolbar" / "Unpin from Toolbar" / [building] "Pinned by your Administrator" | `IDS_EXTENSIONS_CONTEXT_MENU_PIN_TO_TOOLBAR` / `..._UNPIN_FROM_TOOLBAR` / `IDS_EXTENSIONS_PINNED_BY_ADMIN` | any source, if actions can show in toolbar | `:900-916` |
| 5 | "Rate It..." | | review prompt eligible | `:918-922` |
| 6 | "Options" | | has options page | `:924-926` |
| 7 | "Remove from Chrome" | | not component, not policy-required | `:928-930` |
| – | side panel item (with sep) | | as legacy | `:932` |
| – | sep, "Manage Extension", "View Web Permissions" | | not component | `:934-939` |
| – | sep, "Inspect Popup" (building icon if inspection blocked by policy) | | developer mode | `:941-956` |

Other rules: radio checked = current user site access; disabled entries per `IsCommandIdEnabled` (`:409-517`); site-access commands no-op if tab navigated to another origin (`:653-662`); choosing side-panel from the menu closes the Extensions bubble (`:734-741`). Building icon = `kBusinessOldIcon` 16 `kColorIcon`.

## 5. Strings (F) — English, Mac variant where it differs

Extensions menu / toolbar (all `GRD` unless noted):
| IDS | English | Line |
|---|---|---|
| IDS_EXTENSIONS_MENU_TITLE | Extensions | 6435 |
| IDS_TOOLTIP_EXTENSIONS_BUTTON | Extensions | 10300 |
| IDS_ACC_NAME_EXTENSIONS_BUTTON | Extensions menu | 10313 |
| IDS_TOOLTIP_EXTENSIONS_BUTTON_ALL_EXTENSIONS_BLOCKED / _ANY_EXTENSION_HAS_ACCESS | Extensions not allowed on this site / Extensions allowed on this site | 10307-10312 |
| IDS_ACC_NAME_EXTENSIONS_BUTTON_ALL_EXTENSIONS_BLOCKED / _ANY_EXTENSION_HAS_ACCESS | Extensions not allowed on this site. Select to open menu / Extensions allowed on this site. Select to open menu | 10316-10321 |
| IDS_MANAGE_EXTENSIONS | Manage extensions (non-Mac) / **Manage Extensions** (Mac) | 5965 / 6042 |
| IDS_EXTENSIONS_MENU_ACCESSING_SITE_DATA_SHORT / long | Full access / These extensions can see and change information on this site. | 6454 / 6457 |
| IDS_EXTENSIONS_MENU_WANTS_TO_ACCESS_SITE_DATA_SHORT / long | Access requested / To give an extension access to this site, click it. | 6460 / 6463 |
| IDS_EXTENSIONS_MENU_CANT_ACCESS_SITE_DATA_SHORT / long | No access needed / These extensions don't need to see and change information on this site. | 6466 / 6469 |
| IDS_EXTENSIONS_MENU_CONTEXT_MENU_TOOLTIP | More options | 6438 |
| IDS_EXTENSIONS_MENU_CONTEXT_MENU_TOOLTIP_ACCESSIBLE_NAME | {EXTENSION_NAME} | 6445 |
| IDS_EXTENSIONS_PIN_TO_TOOLBAR / UNPIN_FROM_TOOLBAR | Pin / Unpin | 6030 / 6033 |
| IDS_EXTENSIONS_PINNED_BY_ADMIN | Pinned by your Administrator (Mac) / Pinned by your administrator | 6036 / 5959 |
| IDS_EXTENSIONS_PIN_TO_TOOLBAR_ACCESSIBLE_NAME / UNPIN_… / PINNED_BY_ADMIN_… | Pin {N} / Unpin {N} / {N} is pinned by your Administrator | 6081-6087 |
| IDS_EXTENSION_PINNED / UNPINNED | Extension pinned / Extension unpinned | `ui/strings/ui_strings.grd:425-430` |
| IDS_APP_CLOSE | Close | `ui/strings/ui_strings.grd:687` |
| IDS_EXTENSIONS_MENU_SITE_SETTINGS_LABEL | Allow extensions on {SITE_NAME} | 6472 |
| IDS_EXTENSIONS_MENU_SITE_SETTINGS_NOT_ALLOWED_LABEL | Extensions are not allowed on {SITE_NAME} | 6475 |
| IDS_EXTENSIONS_MENU_SITE_SETTINGS_TOGGLE_ON/OFF_TOOLTIP | Extensions allowed on this site / Extensions are not allowed on this site | 6478 / 6481 |
| IDS_EXTENSIONS_MENU_SITE_SETTINGS_TOGGLE_ACCESSIBLE_NAME | Allow extensions | 6484 |
| IDS_EXTENSIONS_MENU_MESSAGE_SECTION_ENTERPRISE_TOOLTIP_ICON_TEXT | Extensions installed by your administrator can still read and change this site | 6487 |
| IDS_EXTENSIONS_MENU_MESSAGE_SECTION_RELOAD_CONTAINER_DESCRIPTION_TEXT / BUTTON_TEXT / BUTTON_TOOLTIP | To apply your updated settings to this site, reload this page / Reload / Reload page | 6490-6496 |
| IDS_EXTENSIONS_MENU_REQUESTS_ACCESS_SECTION_TITLE | Requests access | 6499 |
| …ALLOW_BUTTON_TEXT / TOOLTIP / ACCESSIBLE_NAME | Allow / Allow extension to read and change this site / Allow {N} to read and change this site | 6502-6508 |
| …DISMISS_BUTTON_TEXT / TOOLTIP / ACCESSIBLE_NAME | Dismiss / Dismiss request / Dismiss request for {N} | 6511-6517 |
| IDS_EXTENSIONS_MENU_EXTENSION_SITE_ACCESS_TOGGLE_ON/OFF_TOOLTIP | Allowed on this site / Not allowed on this site | 6520 / 6523 |
| IDS_EXTENSIONS_MENU_EXTENSION_SITE_ACCESS_TOGGLE_ACCESSIBLE_NAME | Allow {N} on this site | 6526 |
| IDS_EXTENSIONS_MENU_EXTENSION_CONTEXT_MENU_BUTTON_TOOLTIP | More options | 6529 |
| …CONTEXT_MENU_BUTTON_ACCESSIBLE_NAME / PINNED_ACCESSIBLE_NAME | See more options for {N} / {N} is pinned. See more options. | 6532 / 6535 |
| IDS_EXTENSIONS_MENU_MAIN_PAGE_EXTENSION_SITE_ACCESS_NONE / ON_CLICK / ON_SITE / ON_ALL_SITES | No access needed / Ask on every visit / Always on this site / Always on all sites | 6538, 6567-6573 |
| IDS_EXTENSIONS_MENU_MAIN_PAGE_DISCOVER_EXTENSIONS | Discover more extensions | 6542 |
| …EXTENSION_SITE_ACCESS_TOOLTIP / ENTERPRISE_…_TOOLTIP | Change site permissions / Installed by your administrator | 6546 / 6549 |
| …EXTENSION_SITE_ACCESS_ACCESSIBLE_NAME / ENTERPRISE_… | {SITE_ACCESS}. Select to change site permissions / {SITE_ACCESS}. Installed by your administrator | 6552 / 6555 |
| IDS_EXTENSIONS_MENU_SITE_PERMISSIONS_PAGE_SETTINGS_BUTTON / _TOOLTIP | Manage this extension / Manage extension settings | 6576 / 6579 |
| …SHOW_REQUESTS_LABEL / TOGGLE_ON / TOGGLE_OFF | Allowed to show requests in the toolbar / Allowed to show requests / Not allowed to show requests | 6582-6588 |
| …SITE_ACCESS_LABEL | Site Permissions | 6591 |
| …SITE_ACCESS_ON_CLICK_TEXT / ON_SITE_TEXT / ON_ALL_SITES_TEXT | Ask on every visit / Always on {SITE_NAME} / Always on all sites | 6594-6600 |
| …ON_CLICK/ON_SITE/ON_ALL_SITES_DESCRIPTION | Runs only after you click the extension / Runs automatically every time you visit this site / Runs automatically on all sites you visit | 6603-6609 |
| IDS_EXTENSION_DISABLED_ERROR_TITLE | {EXTENSION_NAME} is disabled | 5238 |
| IDS_EXTENSIONS_REQUEST_ACCESS_BUTTON / _DISMISSED_TEXT / _TOOLTIP_MULTIPLE_EXTENSIONS | Allow {count}? / Allowed / Click to allow on {ORIGIN}: | 6423 / 6429 / 6432 |

Context menu (Mac Title Case column from `GRD:5975-6050`; sentence case `GRD:5898-5973`):
| IDS | Mac | Other |
|---|---|---|
| IDS_EXTENSIONS_CONTEXT_MENU_PAGE_ACCESS | This Can Read and Change Site Data | This can read and change site data |
| …PAGE_ACCESS_RUN_ON_CLICK / RUN_ON_SITE / RUN_ON_ALL_SITES | When You Click the Extension / On {ORIGIN} / On All Sites | When you click the extension / On {ORIGIN} / On all sites |
| …PAGE_ACCESS_LEARN_MORE | Learn More About Site Access | Learn more about site access |
| …CANT_ACCESS_PAGE | Can't Read or Change Site's Data | Can't read or change site's data |
| …SITE_PERMISSIONS | Site Permissions | Site permissions |
| …RUN_ON_CLICK_V2 / RUN_ON_SITE_V2 / RUN_ON_ALL_SITES_V2 | Ask on Every Visit / Always on {ORIGIN} / Always on All Sites | Ask on every visit / … |
| …PAGE_ACCESS_PERMISSIONS_PAGE | Manage Site Permissions | Manage site permissions |
| …ALL_EXTENSIONS_GRANTED / BLOCKED | You Previously Chose To Allow All Extensions On {ORIGIN} / You Previously Chose To Not Allow Any Extensions On {ORIGIN} | sentence case |
| …PIN_TO_TOOLBAR / UNPIN_FROM_TOOLBAR | Pin to Toolbar / Unpin from Toolbar | Pin to toolbar / Unpin from toolbar |
| …RATE_IT | Rate It... | Rate it... |
| IDS_EXTENSIONS_OPTIONS_MENU_ITEM | Options | Options |
| IDS_EXTENSIONS_UNINSTALL | Remove from Chrome (Chromium: "Remove from Chromium") | same |
| IDS_EXTENSIONS_INSTALLED_BY_ADMIN | Installed by Your Administrator | Installed by your administrator |
| IDS_MANAGE_EXTENSION | Manage Extension | Manage extension |
| IDS_VIEW_WEB_PERMISSIONS | View Web Permissions | View web permissions |
| IDS_EXTENSION_ACTION_INSPECT_POPUP | Inspect Popup | Inspect popup |
| IDS_EXTENSIONS_SUBMENU_OPEN/CLOSE_SIDE_PANEL_ITEM | Open Side Panel / Close Side Panel | Open side panel / Close side panel |

Vector icons used (defaults, rounded icons OFF): puzzle `components/vector_icons/extension_chrome_refresh_old.icon` (+ `extension_off_old`, `extension_on_old`); ⋮ `chrome/app/vector_icons/browser_tools_chrome_refresh_old.icon`; pin `chrome/app/vector_icons/keep_old.icon`, unpin `keep_off_old.icon`; settings `components/vector_icons/settings_chrome_refresh_old.icon`; submenu arrow `submenu_arrow_chrome_refresh_old.icon`; back `arrow_back_old.icon`; close `close_chrome_refresh_old.icon`; enterprise `business_chrome_refresh_old.icon` / `business_old.icon`.

---

# Part D/E: audio, media controls, app menu

The following section was produced from the same checkout (notes file `chromium-src-ref/_notes_audio.md`).

# Chrome desktop (macOS) audio/media UI spec: tab alert, tab menu, Global Media Controls, app menu

Source: Chromium `main` at 2dca33025a6 (2026-10-19). All paths are relative to the repo root. Units are DIP unless stated otherwise.
"Default" means the shipped feature-flag defaults. Flags that change visuals by default:
- `features::IsRoundedIconsEnabled()` = `kDesktopGlowUp || kRoundedIcons`. Both are DISABLED by default (ui/base/ui_base_features.cc:498, :504, :535-538). Shipped icons are therefore the `*Old*` / `*ChromeRefreshOld*` variants.
- `features::IsMenuSimplificationEnabled()` = `kDesktopGlowUp || kMenuSimplification`. Both are DISABLED (chrome/browser/ui/ui_features.cc:93, :133-136). The tab context menu therefore has NO icons on Mac.
- Mac uses `use_titlecase`, so the `[use_titlecase]` string variants apply (generated_resources.grd). `&` is a Windows mnemonic marker. Strip it.

Default color palette (baseline, no custom theme). Ref tokens: ui/color/ref_color_mixer.cc. Neutral uses the "else" branch (`kChromeDarkNeutrals26` is disabled, ui/base/ui_base_features.cc:508; ref_color_mixer.cc:92-93, :136-175).

| Ref token | Hex | cite |
|---|---|---|
| Primary10/20/30/40/80/90/95/100 | #041E49 / #062E6F / #0842A0 / #0B57D0 / #A8C7FA / #D3E3FD / #ECF3FE / #FFFFFF | ref_color_mixer.cc:31-43 |
| Secondary10/30/90 | #001D35 / #004A77 / #C2E7FF | ref_color_mixer.cc:46,51,58 |
| Error20/30/40/80/90/100 | #601410 / #8C1D18 / #B3261E / #F2B8B5 / #F9DEDC / #FFFFFF | ref_color_mixer.cc:79-89 |
| Neutral10/15/20/25/30/40 | #1F1F1F / #282828 / #303030 / #3C3C3C / #474747 / #5E5E5E | ref_color_mixer.cc:142-151 |
| Neutral80/90/95/99/100 | #C7C7C7 / #E3E3E3 / #F2F2F2 / #FDFCFB / #FFFFFF | ref_color_mixer.cc:155-164 |

Sys tokens (light / dark), ui/color/sys_color_mixer.cc:

| Sys token | Light | Dark | cite |
|---|---|---|---|
| kColorSysPrimary | #0B57D0 | #A8C7FA | :121-122 |
| kColorSysOnPrimary | #FFFFFF | #062E6F | :123-124 |
| kColorSysError | #B3261E | #F2B8B5 | :150 |
| kColorSysErrorContainer | #F9DEDC | #8C1D18 | :152-153 |
| kColorSysOnSurface | #1F1F1F | #E3E3E3 | :157-158 |
| kColorSysOnSurfaceSubtle | #474747 | #C7C7C7 | :221-222 |
| kColorSysSurface | #FFFFFF | #1F1F1F | :181-182 |
| kColorSysSurface2 | #F3F6FC (#6991D6 @0x14 over Surface) | #2D2E31 (#D1E1FF @0x14 over #1F1F1F) | :183-185, :197-198 (`kDarkModeSurfaceTokens` disabled, ui_base_features.cc:510) |
| kColorSysSurface5 | #EAF0F9 (@0x23) | #373A3E (@0x23) | :205-206 |
| kColorSysTonalContainer | #D3E3FD | #004A77 | :228-229 |
| kColorSysOnTonalContainer | #041E49 | #C2E7FF | :230-231 |
| kColorSysDivider | #D3E3FD | #5E5E5E | :242-243 |
| kColorSysStateFocusRing | #0B57D0 | #A8C7FA | :287-288 |
| kColorSysStateDisabledContainer | #1F1F1F @ alpha 0x1E (12%) | #E3E3E3 @ 0x1E | :301-303 |
| kColorSysStateHoverOnSubtle | #1F1F1F @ 0x0F | #FDFCFB @ 0x1A | :275-277 |

The Surface2/Surface5 hex values above are computed blends. The other values are copied from source.

Typography (`views::style`, ui/views/style/typography_provider.cc). Sizes are absolute pt (system font, SF on Mac). Line heights are from :355-366.

| Style | Size / weight | Line height |
|---|---|---|
| STYLE_HEADLINE_5 | 14 / Medium (:209-212) | 20 |
| STYLE_BODY_2 | 14 / Normal (:225-229) | 20 |
| STYLE_BODY_2_MEDIUM | 14 / Medium (:230-233) | 20 |
| STYLE_BODY_2_BOLD | 14 / Bold (:234-237) | 20 |
| STYLE_BODY_3_MEDIUM | 13 / Medium (:242-245) | 20 |
| STYLE_BODY_4 | 12 / Normal (:254-257) | 18 |
| STYLE_BODY_5 | 11 / Normal (:270-273) | 16 |
| STYLE_CAPTION_BOLD | 9 / Bold (:294-297) | (not in table; CAPTION = 12) |

---

## D1. Tab alert indicator

Files: chrome/browser/ui/views/tabs/tab/alert_indicator_button.cc, chrome/browser/ui/tabs/alert/tab_alert_icon.cc, chrome/browser/ui/tabs/alert/tab_alert_controller.cc, chrome/browser/ui/views/tabs/tab.cc, components/tabs/public/tab_alert.h.

### States and priority
A tab can have many alerts at the same time. The tab shows only the highest-priority one: `GetAlertToShow()` returns `*active_alerts_.begin()` in a set that is ordered by `CompareAlerts` (tab_alert_controller.cc:43-72, :313-319). Enum: components/tabs/public/tab_alert.h:12-33.

| Prio | TabAlert | Icon (shipped = Old) | Icon (rounded flag) | Color group | Tooltip line (IDS / English) |
|---|---|---|---|---|---|
| 18 | kDesktopCapturing | kRadioButtonCheckedOldIcon | kRadioButtonCheckedIcon | MediaRecording (red) | IDS_TOOLTIP_TAB_ALERT_STATE_DESKTOP_CAPTURING "This tab is sharing your screen" |
| 17 | kTabCapturing | kCaptureOldIcon | kCaptureIcon | PipPlaying (primary) | ..._TAB_CAPTURING "This tab's content is being shared" |
| 16 | kMediaRecording | kRadioButtonCheckedOldIcon | kRadioButtonCheckedIcon | MediaRecording | ..._MEDIA_RECORDING "This tab is using your camera and microphone" |
| 15 | kAudioRecording | same | same | MediaRecording | ..._AUDIO_RECORDING "This tab is using your microphone" |
| 14 | kVideoRecording | same | same | MediaRecording | ..._VIDEO_RECORDING "This tab is using your camera" |
| 13 | kBluetoothConnected | kBluetoothConnectedOldIcon | kBluetoothConnectedIcon | AudioPlaying (grey) | ..._BLUETOOTH_CONNECTED "This tab is connected to a Bluetooth device" |
| 12 | kBluetoothScanActive | kBluetoothScanningChromeRefreshOldIcon | kBluetoothSearchingIcon | AudioPlaying | ..._BLUETOOTH_SCAN_ACTIVE "This tab is actively scanning for Bluetooth devices" |
| 11 | kUsbConnected | kUsbChromeRefreshOldIcon | kUsbIcon | AudioPlaying | ..._USB_CONNECTED "This tab is connected to a USB device" |
| 10 | kHidConnected | kVideogameAssetChromeRefreshOldIcon | kVideogameAssetIcon | AudioPlaying | ..._HID_CONNECTED "This tab is connected to a HID device" |
| 9 | kSerialConnected | kSerialPortChromeRefreshOldIcon | kDeveloperBoardIcon | AudioPlaying | ..._SERIAL_CONNECTED "This tab is connected to a serial port" |
| 8 | kActorWaitingOnUser | kCursorSparkIcon | same | Pip | IDS_TOOLTIP_TAB_ALERT_STATE_ACTOR_ACCESSING "Gemini is working on your task..." |
| 7 | kActorAccessing | kCursorSparkIcon + Lottie spinner | same | Pip | same |
| 6 | kGlicAccessing | Glic IDR_GLIC_ACCESSING_ICON | same | Pip | ..._GLIC_ACCESSING "You're sharing this tab with Gemini" |
| 5 | kGlicSharing | same | same | Pip | ..._GLIC_SHARING "You're sharing this tab with Gemini" |
| 4 | kAiModeSharing | same | same | Pip | ..._AI_MODE_SHARING "You're sharing this tab with AI Mode" |
| 3 | kVrPresentingInHeadset | kCardboardOldIcon | kCardboardIcon | AudioPlaying | ..._VR_PRESENTING "This tab is presenting VR content to a headset" |
| 2 | kPipPlaying | kPictureInPictureAltOldIcon | kPictureInPictureAltIcon | Pip | ..._PIP_PLAYING "This tab is playing a video in picture-in-picture mode" |
| 1 | kAudioMuting | **kVolumeOffChromeRefreshOldIcon** | kVolumeOffIcon | AudioPlaying | ..._AUDIO_MUTING "This tab's audio is being muted" |
| 0 | kAudioPlaying | **kVolumeUpChromeRefreshOldIcon** | kVolumeUpIcon | AudioPlaying | ..._AUDIO_PLAYING "This tab is playing audio" |

Cites: priority tab_alert_controller.cc:47-68. Icons tab_alert_icon.cc:69-128. Color group tab_alert_icon.cc:19-66. Tooltip ids tab_alert_controller.cc:168-229. English text: generated_resources.grd:17225-17267, glic_strings.grdp:10-13, actor_strings.grdp:56.

Muted wins over playing (1 > 0). Both are active together when a tab is muted and recently audible.

When the audio states turn on and off:
- kAudioPlaying = `RecentlyAudibleHelper::WasRecentlyAudible()` (tab_alert_controller.cc:493-500). The flag stays true for **2 s** after the audio stops: `kRecentlyAudibleTimeout = base::Seconds(2)` (chrome/browser/ui/recently_audible_helper.h:30).
- kAudioMuting = recently audible AND `WebContents::IsAudioMuted()` (tab_alert_controller.cc:381-391, :499-500). A muted tab that never played audio shows no icon.

### Geometry
- Icon width: `kTabAlertIndicatorIconWidth` = **16** (touch 12). kTabCapturing uses `kTabAlertIndicatorCaptureIconWidth` = 16 (layout_constants.cc:106-109, tab_alert_icon.cc:134-140). The button preferred size is the image size, 16x16.
- Vector source: volume_up_chrome_refresh_old.icon has a 20-unit canvas and a 16-unit canvas variant. At 16 DIP the 16-unit rep is used (components/vector_icons/volume_up_chrome_refresh_old.icon). These are the Material Symbols "volume_up" / "volume_off" outlined shapes.
- Placement (tab.cc:578-603): the icon is vertically centered and right-aligned, before the close button.
  - Gap rule: `right = close_x - 4` (`kTabAlertIndicatorCloseButtonPaddingAdjustment` = 4, tab.cc:120), where `close_x = close visible left - kTabAfterTitlePadding (4)` (layout_constants.cc:104-105). The total gap to the visible close button is therefore 8 DIP. The extra 4 applies only when both the alert and the close button show and the tab is large enough for a close button (tab.cc:1464-1466).
  - The title ends 4 DIP before the alert (tab.cc:625-626).
  - Close button visible size = 16 (rounded flag: 14) (layout_constants.cc:110-111).
- Space priority (tab.cc:1340-1466):
  - Pinned tab: the alert replaces the favicon.
  - Active tab: close button first, then alert, then favicon.
  - Inactive tab: alert first, then favicon, then close button.
  - If nothing fits, the alert is centered and clipped.

### Colors (`tabs::GetAlertIndicatorColor(state, tab_active, frame_active)`)
Material mixer: chrome/browser/ui/color/material_chrome_color_mixer.cc:528-545. All 4 active/inactive combinations map to the same sys token:

| Group | Color id family | Resolves to | Light / Dark |
|---|---|---|---|
| AudioPlaying (audio, muted, BT, USB, HID, serial, VR) | kColorTabAlertAudioPlaying{Active,Inactive}Frame{Active,Inactive} | kColorSysOnSurfaceSubtle | #474747 / #C7C7C7 |
| MediaRecording (camera, mic, desktop capture) | kColorTabAlertMediaRecording* | kColorSysError | #B3261E / #F2B8B5 |
| PipPlaying (PiP, tab capture, Gemini/actor/AI mode) | kColorTabAlertPipPlaying* | kColorSysPrimary | #0B57D0 / #A8C7FA |

A custom theme can override these colors (chrome_color_mixer.cc:713-744). That path is out of scope for the default look.

### Animations (alert_indicator_button.cc)
| Item | Value | cite |
|---|---|---|
| Fade-in | 200 ms, EASE_IN, opacity 0 to 1 | :43, :504-506 |
| Fade-out (icon removed) | 1000 ms, EASE_IN, opacity 1 to 0 | :44, :430-432 |
| Frame interval | 50 ms (20 FPS) | :52-53 |
| Recording/capture states (Media/Audio/Video recording, Tab/Desktop capturing) | "throbber": [in 200, out 1000] x2, then a final in 200. Total 2600 ms, then the icon stays solid. | :60-80, :469-482 |
| Camera/mic minimum hold | When a camera/mic indicator goes away, the fade-out lasts `max(5 s - time shown, 1000 ms)`. | :47, :492-502 |
| Playing <-> Muted swap | Instant, no fade | :238-244 |
| Opacity method | `SaveLayerAlpha(opacity*255)` around the image paint | :426-441 |
| Actor spinner | Lottie, 0.7 scale, frames 0-180 of 2007, looped | :55-58, :152-210 |

### Click to mute
- Enabled only when **`media::kEnableTabMuting`** is on AND the state is kAudioPlaying or kAudioMuting (alert_indicator_button.cc:271-273). The flag is **DISABLED by default** (media/base/media_switches.cc:558-559, "Enables user control over muting tab audio from the tab strip"). **Shipped Chrome: clicking the speaker selects the tab and does not mute it.** The button is disabled and passes all mouse events to the Tab (:380-386).
- When the flag is on:
  - The tab must be active, or the tab's largest selectable region must be at least 250% of the button width (mouse) or 400% (gesture) (:86-87, :268-288, :405-424; tab.cc:1086-1088).
  - Only a plain left click mutes. Shift, Control, middle click, and right click go to the Tab (:302-311).
  - The click swaps the icon immediately, then calls `ToggleTabAudioMute()` (:388-403).
- Hover: the alert button never shows its own tooltip, because `GetTooltipHandlerForPoint` returns null (:297-300). The Tab tooltip is `"<title>\n<alert tooltip line>"` (tab.cc:1257-1270).
- Pressed-state image: the code intends to show the opposite glyph, but it passes the unswapped state. In effect the pressed image equals the normal image (:96-107). This is an upstream quirk.

### Accessibility
- Button name: IDS_ACCNAME_MUTE_TAB "Mute tab" (alert_indicator_button.cc:144-145; generated_resources.grd:11194).
- Tab accessible-name suffix (tab_alert_controller.cc:232-273; generated_resources.grd:17272-17317):

| State | IDS | English |
|---|---|---|
| AudioPlaying | IDS_TAB_AX_LABEL_AUDIO_PLAYING_FORMAT | "{TITLE} - Audio playing" |
| AudioMuting | IDS_TAB_AX_LABEL_AUDIO_MUTING_FORMAT | "{TITLE} - Audio muted" |
| MediaRecording | ..._MEDIA_RECORDING_FORMAT | "{TITLE} - Camera and microphone recording" |
| AudioRecording | ..._AUDIO_RECORDING_FORMAT | "{TITLE} - Microphone recording" |
| VideoRecording | ..._VIDEO_RECORDING_FORMAT | "{TITLE} - Camera recording" |
| TabCapturing | ..._TAB_CAPTURING_FORMAT | "{TITLE} - Tab content shared" |
| DesktopCapturing | ..._DESKTOP_CAPTURING_FORMAT | "{TITLE} - Desktop content shared" |
| PipPlaying | ..._PIP_PLAYING_FORMAT | "{TITLE} - Video playing in picture-in-picture mode" |
| BT / BT scan / USB / HID / Serial | ..._BLUETOOTH_CONNECTED_FORMAT etc. | "- Bluetooth device connected" / "- Bluetooth scan active" / "- USB device connected" / "- HID device connected" / "- Serial port connected" |
| VR | IDS_TAB_AX_LABEL_VR_PRESENTING | "{TITLE} - VR presenting to headset" |

---

## D2. Tab context menu (chrome/browser/ui/tabs/tab_menu_model.cc `Build`, :308-701)

Command ids are `tabs::TabContextMenuCommand` enum values (components/tabs/public/tab_context_menu_command.h:12-43). Mac uses Title Case `[use_titlecase]` strings (generated_resources.grd:12400-12523). `num_tabs` = the size of the selection if the right-clicked tab is selected, else 1 (:309-320). The menu shows no icons by default (menu simplification is off).

| # | Command id | IDS | Mac English | Condition / notes | cite |
|---|---|---|---|---|---|
| 1 | CommandNewTabToRight | IDS_TAB_CXMENU_NEWTABTORIGHT (RTL: ..._NEWTABTOLEFT; vertical tabs: ..._NEWTABBELOW) | "New Tab to the Right" / "New Tab to the Left" / "New Tab Below" | always | :327-335 |
| 2 | CommandAddToSplit | IDS_TAB_CXMENU_ADD_TAB_TO_NEW_SPLIT (if this is the active tab) or IDS_TAB_CXMENU_NEW_SPLIT_WITH_CURRENT | "Add Tab to New Split View" / "New Split View with Current Tab" | Tab not in a split AND active tab not split. Enabled only for 1-2 tabs. A submenu if horizontal direct access is on. | :337-391 |
| 2' | CommandSwapWithActiveSplit (submenu) | IDS_TAB_CXMENU_SWAP_WITH_ACTIVE_SPLIT | "Move Tab into Split View" | Tab not in a split AND active tab split. Enabled only if 1 tab. | :338-350 |
| 2'' | CommandArrangeSplit (submenu) | IDS_TAB_CXMENU_ARRANGE_SPLIT | "Arrange Split View" | Tab is in a split | :392-403 |
| 3 | CommandToggleFocusGroup | IDS_TAB_CXMENU_FOCUS_TAB_GROUP / UNFOCUS / FOCUS_TABS (plural) | "Focus on Tab Group" etc. | `kTabGroupsFocusing`, DISABLED by default (ui_features.cc:578) | :405-433 |
| 4 | CommandAddToExistingGroup (submenu) **or** CommandAddToNewGroup | IDS_TAB_CXMENU_ADD_TAB_TO_GROUP / IDS_TAB_CXMENU_ADD_TAB_TO_NEW_GROUP (plural) | "Add Tab to Group" / "Add Tabs to Group"; "Add Tab to New Group" / "Add Tabs to New Group" | Submenu if other groups exist | :435-468 |
| 5 | CommandRemoveFromGroup | IDS_TAB_CXMENU_REMOVE_TAB_FROM_GROUP | "Remove From Group" | Any selected tab is in a non-ephemeral group | :470-478 |
| 6 | CommandMoveToExistingWindow (submenu) **or** CommandMoveTabsToNewWindow | IDS_TAB_CXMENU_MOVETOANOTHERWINDOW / IDS_TAB_CXMENU_MOVE_TABS_TO_NEW_WINDOW (plural) | "Move Tab to Another Window" / "Move Tabs to Another Window"; "Move Tab to New Window" / "Move Tabs to New Window" | Submenu if other windows exist | :480-508 |
| - | separator | | | | :510 |
| 7 | CommandReload | IDS_TAB_CXMENU_RELOAD | "Reload" | | :511 |
| 8 | CommandDuplicate | IDS_TAB_CXMENU_DUPLICATE | "Duplicate" | | :513-515 |
| 9 | CommandTogglePinned | IDS_TAB_CXMENU_PIN_TAB / IDS_TAB_CXMENU_UNPIN_TAB | "Pin" / "Unpin" | "Unpin" if all target tabs are pinned (tab_strip_model.cc:3512-3520) | :517-520 |
| 10 | **CommandToggleSiteMuted** | **IDS_TAB_CXMENU_SOUND_MUTE_SITE / IDS_TAB_CXMENU_SOUND_UNMUTE_SITE** | `{NUM_TABS, plural, =1 {Mute Site} other {Mute Sites}}` / `{=1 {Unmute Site} other {Unmute Sites}}` (sentence-case non-Mac: "Mute site(s)" / "Unmute site(s)") | Always present. Label is "Mute" unless ALL target sites are muted (tab_strip_model.cc:3508-3510, tab_utils.cc:42-50). Enabled if any target has a non-empty committed URL (tab_strip_model.cc:2712-2720). For a single split it is a submenu (SplitTabMuteMenuModel), and the plural count = number of tabs in the split. | :533-558; grd:12303-12306, :12442-12445 |
| - | separator | | | Only if reading list or send-to-self shows (and no Gemini block) | :605-607 |
| 11 | CommandAddToReadLater | IDS_TAB_CXMENU_READ_LATER (plural) | "Add Tab to Reading List" / "Add Tabs to Reading List" | `SupportsReadLater()`. Disabled if no tab is supported. This item always has an icon: kMenuBookChromeRefreshOldIcon, 16. | :609-620 |
| 12 | CommandGlicShare (submenu), CommandGlicUnshare | IDS_TAB_CXMENU_GLIC_START_SHARE (plural), IDS_TAB_CXMENU_GLIC_UNSHARE | "Share Tab with Gemini" / "Share # Tabs with Gemini", "Unshare with Gemini" | Gemini enabled | :622-624, :243-275; glic_strings.grdp:480-500 |
| 13 | CommandAiModeShare (submenu) | IDS_TAB_CXMENU_AI_MODE_SHARE | "Share Tab with AI Mode" | contextual tasks feature | :625-627 |
| 14 | CommandSendTabToSelf (submenu or item) | IDS_CONTEXT_MENU_SEND_TAB_TO_SELF | "Send to Your Device" | Sync / send-tab-to-self eligibility | :629-631, :209-241; grd:14162 |
| - | separator + CommandToggleVertical | IDS_SWITCH_TO_VERTICAL_TAB_MAC / IDS_SWITCH_TO_HORIZONTAL_TAB_MAC | "Show Tabs Vertically" / "Show Tabs Horizontally" | VerticalTabStripStateController exists | :633-659; grd:10543-10546 |
| - | extension `contextMenus` items with context "tab" | (extension-provided) | | `kExtensionTabContextMenu` ENABLED by default (extension_features.cc:163) | :661-681 |
| - | separator | | | | :684 |
| 15 | CommandCloseTab | IDS_TAB_CXMENU_CLOSETAB | "Close" | | :685 |
| 16 | CommandCloseOtherTabs | IDS_TAB_CXMENU_CLOSEOTHERTABS | "Close Other Tabs" | | :686-687 |
| 17 | CommandCloseTabsToRight | IDS_TAB_CXMENU_CLOSETABSTORIGHT (RTL: ...TOLEFT; vertical: ..._CLOSETABSBELOW) | "Close Tabs to the Right" / "Close Tabs Below" | Disabled if no tabs to close | :689-700 |

What "Mute Site" does (`SetSitesMuted`, tab_strip_model.cc:5629-5674):
- For each target tab it writes the **per-origin SOUND content setting** (BLOCK or ALLOW). It is persistent and affects every tab of that site. It is not a per-tab mute.
- For `chrome://` URLs it mutes the WebContents with reason kContentSettingChrome.
- Tabs with an empty URL are skipped.

---

## D3. Global Media Controls (GMC)

### Toolbar button (chrome/browser/ui/views/global_media_controls/media_toolbar_button_view.cc)
- Created on Win/Mac/Linux unless the WebUI media button is on (`kWebUIMediaButton` DISABLED, ui_features.cc:422, :479-483) (toolbar_view.cc:419-426).
- Position: after the battery saver and performance intervention buttons, before the Gemini button and the avatar (toolbar_view.cc:548-563).
- `ToolbarButton`, height 34. Icon `kToolbarButtonIconSize` = kDefaultIconSizeChromeRefresh (20) (layout_constants.cc:131-135).
- Icon: `kMediaToolbarButtonChromeRefreshOldIcon`, a 20-unit canvas music-note-with-lines glyph (chrome/app/vector_icons/media_toolbar_button_chrome_refresh_old.icon). With the rounded flag: kQueueMusicIcon (:46-51).
- Tooltip: IDS_GLOBAL_MEDIA_CONTROLS_ICON_TOOLTIP_TEXT "Control your music, videos, and more" (:52-53; chrome/app/gmc_strings.grdp:4). Accessibility: HasPopup = dialog (:54).
- Click: fires on mouse **press** (kOnPress). It toggles the dialog: if the dialog shows, the click hides it (:43-44, :124-133).
- Right-click menu (media_toolbar_button_contextual_menu.cc:41-56):
  1. Check item "Show other cast sessions" (IDS_MEDIA_TOOLBAR_CONTEXT_SHOW_OTHER_SESSIONS, pref kMediaRouterShowCastSessionsStartedByOtherDevices; disabled if the pref is managed).
  2. "Report an issue with Google Cast" (Chrome-branded builds, when feedback is allowed; opens chrome://cast-feedback).
  Strings: gmc_strings.grdp:49-52.
- Visibility (media_toolbar_button_controller.cc:49-69):
  - Shown and enabled when the item manager has an active item or an open dialog.
  - Hidden when there are no active items and no frozen items.
  - Shown but **disabled** when there are only frozen items.
- An item is shown when the session is controllable, has a non-empty title, and is not a non-remote-playback presentation (components/global_media_controls/public/media_session_notification_item.cc:413-434).
- Freeze grace period: 2500 ms (media_session_notification_item.cc:54).
- Paused sessions auto-dismiss after 60 min (`kGlobalMediaControlsAutoDismiss` ENABLED, media_switches.cc:633; media_session_item_producer.cc:18-32).

### Dialog (media_dialog_view.cc)
- `BubbleDialogDelegateView`, no buttons, anchor arrow TOP_RIGHT under the toolbar button (:97-104, :384). Accessible title: IDS_GLOBAL_MEDIA_CONTROLS_DIALOG_NAME "Global Media Controls" (:385-386; gmc_strings.grdp:37).
- Frame corner radius: `GetCornerRadiusMetric(Emphasis::kHigh)` = **8** (:232-236; ui/views/layout/layout_provider.cc:199-200).
- Bubble background: kColorBubbleBackground = kColorSysSurface (#FFFFFF / #1F1F1F) (ui/color/material_ui_color_mixer.cc:44).
- Margins 0 (:413).
- The layout is always **MediaItemUIUpdatedView**. No flag check remains (`ShowMediaItem` -> `BuildMediaItemUIUpdatedView`, :170-191, :685-696).
- Empty size: width = DISTANCE_BUBBLE_PREFERRED_WIDTH (kSmallDialogWidth, 320), height 1 (:248-259; layout_provider.cc:88-89).
- If the last item hides, the dialog closes (:193-203).

Vertical stack (BoxLayout vertical, cross-axis center, :418-430). Live Caption is supported on Mac (`speech::IsOnDeviceSpeechRecognitionSupported`, components/live_caption/caption_util.cc:127-133). Live Translate is always on for non-CrOS (media_switches.cc:1893-1899).
1. **Item list** (`MediaItemUIListView`, components/global_media_controls/public/views/media_item_ui_list_view.cc):
   - Scroll view, max height **488** (:18, :35-36), overlay scrollbars.
   - Content insets **8** on all sides, **8** between items (:22, :43-48).
   - Dialog content width = 400 + 2x8 = **416**.
2. **Live Caption row** (:514-564):
   - Horizontal BoxLayout. Insets V10/H20 (kVerticalMarginDip / kHorizontalMarginDip, :72-74). Spacing 8 (DISTANCE_RICH_HOVER_BUTTON_ICON_HORIZONTAL, chrome_layout_provider.cc:192-193).
   - Icon kLiveCaptionOnOldIcon, 20, kColorIcon (= SysOnSurfaceSubtle).
   - Label: multiline, left-aligned, flex 1. Text "Live Caption" (IDS_GLOBAL_MEDIA_CONTROLS_LIVE_CAPTION) or "Live Caption - {LANGUAGE}" when on (:76-86).
   - Optional enterprise icon (kBusinessOldIcon, kColorIconSecondary, tooltip "This setting is managed by your administrator.").
   - `views::ToggleButton`, track 26x16 (ui/views/controls/button/toggle_button.cc:50). Toggles pref kLiveCaptionEnabled.
   - Download progress, error, and reboot strings: gmc_strings.grdp:22-28.
3. **Live Translate row**: same layout, cross-axis start (:566-625). Visible only when Live Caption is on. Icon kGTranslateIcon. Title IDS_SETTINGS_CAPTIONS_ENABLE_LIVE_TRANSLATE_TITLE "Live Translate".
4. **Target-language combobox** (:627-651): visible when both prefs are on. Bottom pad 10. Width = 416 - 2x(20+20+8) = 320 (:282-288). Accessible name "Choose the language to translate the captions to".
5. **Separator**: horizontal, length 416 - 2x20 (:426-428, :290).
6. **Caption settings** `RichHoverButton` (:654-678):
   - Container insets V10/H0. Text "Caption settings" (IDS_GLOBAL_MEDIA_CONTROLS_CAPTION_SETTINGS).
   - Leading kSettingsChromeRefreshOldIcon 20. Trailing kLaunchOldIcon 20.
   - Opens chrome://settings/accessibility in a new foreground tab (:455-462; caption_util.cc:151-152).

### Media item: `MediaItemUIUpdatedView` (components/global_media_controls/public/views/media_item_ui_updated_view.cc)
Color theme `GetMediaColorTheme()` (chrome/browser/ui/views/global_media_controls/media_item_ui_helper.cc:280-308):

| Theme slot | Sys token | Light / Dark |
|---|---|---|
| background | kColorSysSurface2 | #F3F6FC / #2D2E31 |
| primary_foreground (title, artist, default favicon) | kColorSysOnSurface | #1F1F1F / #E3E3E3 |
| secondary_foreground (source, timestamps, all small buttons) | kColorSysOnSurfaceSubtle | #474747 / #C7C7C7 |
| play_button_container / foreground (paused state, shows "Play") | kColorSysPrimary / kColorSysOnPrimary | #0B57D0 on #FFFFFF / #A8C7FA on #062E6F |
| pause_button_container / foreground (playing state, shows "Pause") | kColorSysTonalContainer / kColorSysOnTonalContainer | #D3E3FD + #041E49 / #004A77 + #C2E7FF |
| playing_progress_foreground | kColorSysPrimary | |
| playing_progress_background, paused_progress_fg/bg, disabled button fg | kColorSysStateDisabledContainer | OnSurface @ 12% |
| device_selector_border | kColorSysDivider | #D3E3FD / #5E5E5E |
| device_selector_foreground | kColorSysPrimary | |
| device_selector_background | kColorSysSurface5 | #EAF0F9 / #373A3E |
| error_foreground / error_container | kColorSysError / kColorSysErrorContainer | |
| focus_ring | kColorSysStateFocusRing | |

Layout constants (:37-62):

| Constant | Value |
|---|---|
| Fixed width | **400** (:37, :354-358) |
| Outer insets | V16 / H12 (:39) |
| Background corner radius | 8, rounded-rect fill Surface2 (:43, :85-86) |
| Vertical spacing between rows | 12 (:47) |
| Focus ring | whole-card ring, halo inset -3, radius 8 (:57, :91-96) |
| Artwork row | inset left 4 (:40). Spacing 16 between artwork and info (:48). |
| Artwork | **80x80**, corner radius **8**, aspect-fill (scale = max) and clipped. Hidden if there is no artwork, and the info column expands. (:44, :59, :104-110, :490-501; media_view_utils.cc:13-19) |
| Info column | vertical, spacing 4 (:49) |
| Source row | favicon **14x14** with radius 2 (default icon kGlobeOldIcon tinted OnSurface), gap 4, then source label, then [Save frame] [Cast] [PiP] [Casting indicator] buttons (:120-185, :503-514) |
| Metadata row | inset right 4, spacing 16, cross-align END (:41, :51, :187-194) |
| Title / artist column | spacing 4 (:52) |
| Play/Pause | **48x48** pill (circle), icon **24** (:54, :61, :229-230) |
| Other action buttons | **28x28**, icon **20**, circular highlight (radius = h/2), ink drop on (:55, :62; media_action_button.cc:34-43; ui/views/controls/button/image_button_factory.cc:109-116) |

Labels:

| Label | Style | Color | Behavior | cite |
|---|---|---|---|---|
| Source (`metadata.source_title`, for example the site host) | BODY_5 (11pt) | secondary | left-aligned, **head elision**, flex 1 | :144-152, :458 |
| Title | BODY_2_BOLD (14pt bold) | primary | left, middle | :204-209 |
| Artist | BODY_2 (14pt) | primary | left, middle | :211-217 |
| Current time / duration | BODY_5 | secondary | Fixed width 56 (2x28), multiline. **Visible only while dragging the scrubber.** They take the place of the hidden prev/replay and forward/next buttons. | :236-242, :303-309, :319-328, :702-705 |

Buttons, in order. Tooltips: components/media_message_center_strings.grdp:3-57.

| Row | Button | Icon (Old) | Tooltip / AX (IDS / English) | Visibility rule |
|---|---|---|---|---|
| source | Save video frame | kVideoFrameSaveIcon | ..._ACTION_SAVE_VIDEO_FRAME "Save video frame" | action supported and not casting (:154-158, :665-669) |
| source | Start casting | kCastOldIcon (kCastWarningOldIcon on an issue) | ..._ACTION_SHOW_DEVICE_LIST "Show device list for casting" / ..._HIDE_DEVICE_LIST "Hide device list for casting" | devices available and no footer. Ink drop is snapped "activated" while the list is open. (:161-166, :522-530, :568-575, :765-793) |
| source | Picture-in-picture | kPictureInPictureAltOldIcon / kPipExitOldIcon | ..._ENTER_PIP "Enter picture-in-picture" / ..._EXIT_PIP "Exit picture-in-picture" | action supported and not casting (:169-174, :432-451) |
| source | Casting indicator (image only) | kCastOldIcon, 20, device_selector_foreground (Primary), 28x28 | - | only while the footer (casting) is shown (:178-185, :563) |
| metadata | Play / Pause | kPlayArrowOldIcon / kPauseOldIcon (24) | ..._ACTION_PLAY "Play" / ..._ACTION_PAUSE "Pause" | always (:223-230, :406-430) |
| progress | [current time] | | | while dragging |
| progress | Previous track | kSkipPreviousOldIcon | "Previous Track" | Non-live: always visible when not dragging, **disabled** if not supported. Live: visible only if supported. (:245-249, :671-689) |
| progress | Replay 10 | kReplay10OldIcon | "Replay 10 seconds" | non-live as above; hidden for live. Seeks -10 s (`kSeekTime`, media_view_utils.h:15; :643-647) |
| progress | Progress / LIVE | see below | | `is_live = duration == max` (:484-487) |
| progress | Forward 10 | kForward10OldIcon | "Forward 10 seconds" | as Replay 10. +10 s capped at duration (:648-652) |
| progress | Next track | kSkipNextOldIcon | "Next Track" | as Previous |
| progress | [duration] | | | while dragging |

- There is **no close/dismiss button** in the updated view. IDS_GLOBAL_MEDIA_CONTROLS_DISMISS_ICON_TOOLTIP_TEXT "Dismiss" exists but is not used here.
- A click anywhere on the card background activates the source tab (:383-390).
- The card has AX role ListItem. Name = the title, or "Media Controls" when there is no title (:330-375).
- Arrow keys on the focused card go to the scrubber (:377-381).
- Prev/next glyphs flip in RTL (media_action_button.cc:36-39).

### Progress bar `MediaProgressView` (components/global_media_controls/public/views/media_progress_view.cc). The updated view uses a straight line, `use_squiggly_line=false` (:261).

| Item | Value | cite |
|---|---|---|
| Height | 28 | :36, :179-184 |
| Horizontal inset each side | 8 | :48 |
| Line thickness | 2 normal. **4** on hover or drag, animated over 150 ms. | :40, :44, :71, :349-357 |
| Thumb | 4x16 rounded rect (radius 2), color = foreground. Hidden for live media. | :60, :290-303 |
| Gap between thumb and line on each side | 4 | :63, :276-278, :306-308 |
| Played part | rounded rect, playing fg = Primary | :275-285 |
| Remaining part | rounded rect, playing bg = DisabledContainer | :306-321 |
| Paused colors | fg and bg = DisabledContainer. Color switch delayed 200 ms. | :86-87, :466-472 |
| Focus ring | 2px stroke, radius 18, focus-ring color, inset 2 | :95, :325-336 |
| Update tick | every 150 ms while playing (straight line) | :81-82, :536-543 |
| Cursor | hand | :359-361 |
| Click/drag | Press starts a 200 ms timer. On release before 200 ms: click-seek to x. After 200 ms: drag mode. Drag mode pauses playback, shows the timestamps, hides the side buttons, and resumes on release. | :92, :363-381, :584-644 |
| Keyboard / AX | Left/Right/Up/Down = ±5 s. Role slider, name "Time scrubber". Value is a spelled-out duration. | :98, :146-151, :383-412, :546-568 |

- Timestamp format: ICU MeasureFormat NUMERIC, for example "1:05" or "1:02:03" (components/global_media_controls/public/format_duration.cc).
- Live (`MediaLiveStatusView`, media_live_status_view.cc):
  - Height 28. A 2-px pill line in play_button_container (Primary).
  - A centered "LIVE" label (IDS_GLOBAL_MEDIA_CONTROLS_MEDIA_LIVE_TEXT), CAPTION_BOLD, color OnPrimary, padding 4, rounded-rect background radius 4, color Primary (:19-41).

### Cast device picker (`CastDeviceSelectorView`, non-CrOS, chrome/browser/ui/views/global_media_controls/cast_device_selector_view.cc)
- Shown under the progress row when expanded and devices exist (:346-366). Built only if the Media Router is enabled and the item is not already casting (media_item_ui_helper.cc:35-57, :186-217).
- Container: 1-px border (Divider), radius 8, background Surface5. Insets T12 L8 B16 R8. Spacing 8 (:37-49, :124-132).
- Header row (insets L8 R4): "Cast to a device" (IDS_GLOBAL_MEDIA_CONTROLS_CAST_HEADER_TEXT) in HEADLINE_5. Close button 28x28 with kCloseSmallOldIcon 20, tooltip "Close device list for casting" (:134-162; components/global_media_controls_strings.grdp:9-12).
- Device list: vertical, spacing 4. Each entry is a `HoverButton`: icon 20 (kSpeakerOldIcon / kSpeakerGroupOldIcon / kInputOldIcon / ...) plus the name in BODY_2 secondary. Insets V6/H8, icon-label gap 8, focus radius 4 (:41-46, :292-337; media_item_ui_helper.cc:310-327).
  - A connecting device shows a `views::Throbber`. Insets H8.
  - A device with an issue (kInfo icon) shows the name in BODY_2 secondary, the status text in BODY_4, and the icon in Error color (:56-104).
- Mac Local Network permission error: "To cast, give Chrome access in: System Settings > Local Network > Chrome". "System Settings" is a link to Privacy & Security. Label width 400 (:227-287; chrome/app/media_router_strings.grdp:95-98).

### Casting footer (`CastDeviceFooterView`, cast_device_footer_view.cc)
- Shown while the item is casting.
- Container: 1-px Divider border, radius 8, background Surface5, insets V13/H15, spacing 8.
- Content: cast icon 20 in Primary, then the device name in BODY_2_MEDIUM Primary (fallback "Unknown device"), then a "Stop casting" LabelButton.
- Stop casting button: icon kStopCircleOldIcon 12, text BODY_5, both in Error color, on an ErrorContainer rounded rect (radius 10). Insets T2 L6 B2 R8, gap 4 (:19-97).

### All GMC strings
| IDS | English | file:line |
|---|---|---|
| IDS_GLOBAL_MEDIA_CONTROLS_ICON_TOOLTIP_TEXT | Control your music, videos, and more | chrome/app/gmc_strings.grdp:4 |
| IDS_GLOBAL_MEDIA_CONTROLS_DIALOG_NAME | Global Media Controls | gmc_strings.grdp:37 |
| IDS_GLOBAL_MEDIA_CONTROLS_LIVE_CAPTION / _SHOW_LANGUAGE | Live Caption / Live Caption - {LANGUAGE} | gmc_strings.grdp:16-19 |
| IDS_GLOBAL_MEDIA_CONTROLS_LIVE_CAPTION_DOWNLOAD_PROGRESS | Downloading... {PERCENT}% | gmc_strings.grdp:22 |
| IDS_GLOBAL_MEDIA_CONTROLS_CAPTION_SETTINGS | Caption settings | gmc_strings.grdp:31 |
| IDS_SETTINGS_CAPTIONS_ENABLE_LIVE_TRANSLATE_TITLE | Live Translate | settings_strings.grdp:137 |
| IDS_GLOBAL_MEDIA_CONTROLS_CAST_HEADER_TEXT | Cast to a device | components/global_media_controls_strings.grdp:9 |
| IDS_GLOBAL_MEDIA_CONTROLS_CLOSE_DEVICE_LIST_TEXT | Close device list for casting | same:12 |
| IDS_GLOBAL_MEDIA_CONTROLS_UNKNOWN_DEVICE_TEXT | Unknown device | same:18 |
| IDS_GLOBAL_MEDIA_CONTROLS_MEDIA_LIVE_TEXT | LIVE | same:21 |
| IDS_MEDIA_MESSAGE_CENTER_MEDIA_NOTIFICATION_ACTION_{PLAY,PAUSE,PREVIOUS_TRACK,NEXT_TRACK,REPLAY_10,FORWARD_10,ENTER_PIP,EXIT_PIP,SAVE_VIDEO_FRAME,SHOW_DEVICE_LIST,HIDE_DEVICE_LIST,STOP_CASTING} | Play, Pause, Previous Track, Next Track, Replay 10 seconds, Forward 10 seconds, Enter picture-in-picture, Exit picture-in-picture, Save video frame, Show device list for casting, Hide device list for casting, Stop casting | components/media_message_center_strings.grdp:3-48 |
| IDS_MEDIA_MESSAGE_CENTER_MEDIA_NOTIFICATION_TIME_SCRUBBER | Time scrubber | same:51 |
| IDS_MEDIA_MESSAGE_CENTER_MEDIA_NOTIFICATION_ACCESSIBLE_NAME | Media Controls | same:54 |
| IDS_MEDIA_TOOLBAR_CONTEXT_SHOW_OTHER_SESSIONS / _REPORT_CAST_ISSUE | Show other cast sessions / Report an issue with Google Cast | gmc_strings.grdp:49-52 |

---

## E. App menu "⋮" (chrome/browser/ui/toolbar/app_menu_model.cc `AppMenuModel::Build`, :2126-2530)

All items have 16-DIP icons (`*Old*` variants by default). Strings on Mac are mostly sentence case: the Views app menu takes the `[not use_titlecase]` text where no titlecase variant exists.

| # | Item (IDC) | IDS | English | Condition | line |
|---|---|---|---|---|---|
| 0 | Update / restart / Safety Hub / global error / default-browser rows | various | | conditional, followed by a separator | 2129-2151 |
| 1 | IDC_NEW_TAB | IDS_NEW_TAB | New tab | | 2161 |
| 2 | IDC_NEW_WINDOW | IDS_NEW_WINDOW | New window | | 2165 |
| 3 | IDC_NEW_INCOGNITO_WINDOW | IDS_NEW_INCOGNITO_WINDOW | New Incognito window | not Guest | 2172 |
| - | separator | | | | 2192 |
| 4 | Profile submenu | (profile name, avatar icon) | | not ChromeOS. Followed by a spacing separator. | 2195-2208 |
| 5 | Passwords and autofill submenu | IDS_PASSWORDS_AND_AUTOFILL_MENU | Passwords and autofill | not Guest | 2211-2223 |
| 6 | History submenu | IDS_HISTORY_MENU | History | not off-the-record | 2225-2237 |
| 6b | Other device tabs submenu | IDS_OTHER_DEVICE_TABS_MENU | Other device tabs | `syncer::kCrossDeviceTabsInAppMenu` | 2239-2249 |
| 7 | IDC_SHOW_DOWNLOADS | IDS_SHOW_DOWNLOADS | Downloads | | 2251-2255 |
| 8 | Bookmarks and lists submenu | IDS_BOOKMARKS_AND_LISTS_MENU | Bookmarks and lists | not Guest | 2256-2268 |
| 9 | Tab groups submenu | IDS_SAVED_TAB_GROUPS_MENU | Tab groups | regular profile | 2270-2281 |
| 10 | **Extensions** | see below | | | 2283-2326 |
| 11 | IDC_CLEAR_BROWSING_DATA | IDS_CLEAR_BROWSING_DATA | Delete browsing data... | | 2328-2333 |
| - | separator; Zoom row ("Zoom", −, +, fullscreen) IDS_ZOOM_MENU / IDS_ZOOM_MINUS2 / IDS_ZOOM_PLUS2; separator | | | | 2335-2337, 2549-2560 |
| 12 | IDC_PRINT | IDS_PRINT | Print... | | 2339-2341 (components/components_strings.grd:463-469) |
| 13 | IDC_OPEN_GLIC (Gemini) | IDS_GLIC_THREE_DOT_MENU_ITEM | (not resolved in checkout) | Gemini enabled | 2343-2352 |
| 14 | Lens / "Ask Google about this page" / "Search with Google" submenu | lens::GetLensOverlayEntrypointLabelAltIds(), IDS_ASK_GOOGLE_ABOUT_THIS_PAGE | (Lens label not resolved), "Ask Google about this page" | Lens overlay enabled | 2369-2429 |
| 15 | IDC_SHOW_TRANSLATE | IDS_SHOW_TRANSLATE | Translate... | | 2431-2432 |
| 16 | Find and edit submenu | IDS_FIND_AND_EDIT_MENU | Find and edit | | 2434, 2541-2547 |
| 17 | Cast, save, and share submenu | IDS_CAST_SAVE_AND_SHARE_MENU (Media Router on) / IDS_SAVE_AND_SHARE_MENU | Cast, save, and share / Save and Share | | 2436-2447 |
| 18 | More tools submenu | IDS_MORE_TOOLS_MENU | More tools | | 2464-2470 |
| - | separator | | | | 2473 |
| 19 | Help submenu (Chrome-branded) or IDC_ABOUT (Chromium) | IDS_HELP_MENU / IDS_ABOUT | Help | | 2477-2493 |
| 20 | IDC_OPTIONS | IDS_SETTINGS | Settings | | 2495-2497 |
| 21 | IDC_EXIT | IDS_EXIT | Exit | `browser_defaults::kShowExitMenuItem` (false on Mac, from prior knowledge; browser_defaults.cc not in this checkout) | 2499-2503 |
| 22 | Managed-by row | dynamic | | `ShouldDisplayManagedUi` | 2508-2525 |

**Extensions entry** (:2283-2326). The first true branch wins:
1. If action `kActionSkillsAndExtensionsSubmenu` is visible: submenu "Extensions and Skills" (IDS_EXTENSIONS_AND_SKILLS_MENU, skills_strings.grdp:23). Contents (`SkillsAndExtensionsMenuModel::Build`, :1016-1041):
   - "Manage extensions" (IDC_EXTENSIONS_SUBMENU_MANAGE_EXTENSIONS, icon kExtensionChromeRefreshOldIcon)
   - "Manage skills" (IDC_MANAGE_SKILLS, kContractIcon)
   - separator
   - "Visit Chrome Web Store" (IDC_EXTENSIONS_SUBMENU_VISIT_CHROME_WEB_STORE, kGoogleChromeWebstoreIcon only on branded builds)
2. Else if promotions are enabled AND `kExtensionsCollapseMainMenu` (DISABLED by default, ui_features.cc:175) AND there are no manageable extensions: a flat item IDC_FIND_EXTENSIONS "Find Extensions" (Mac title case; non-Mac "Explore Extensions") (grd:1913, :1964).
3. **Default**: submenu IDC kExtensionsSubmenuPlaceholder "Extensions" (IDS_EXTENSIONS_SUBMENU, grd:1919/1970) with `ExtensionsMenuModel::Build` (:1182-1201):
   1. IDS_EXTENSIONS_SUBMENU_MANAGE_EXTENSIONS_ITEM = **"Manage extensions"** (grd:745, sentence case on Mac too). IDC_EXTENSIONS_SUBMENU_MANAGE_EXTENSIONS, icon kExtensionChromeRefreshOldIcon 16. Opens chrome://extensions.
   2. IDS_EXTENSIONS_SUBMENU_CHROME_WEBSTORE_ITEM **"Visit Chrome Web Store"** (grd:1922/1974). IDC_EXTENSIONS_SUBMENU_VISIT_CHROME_WEB_STORE. Icon kGoogleChromeWebstoreIcon on branded builds only.
   There is no separator between them.

Not verified in this checkout:
- the default state of the "Skills" action.
- the English text of IDS_GLIC_THREE_DOT_MENU_ITEM and of the Lens label.
- `kShowExitMenuItem` on Mac.
