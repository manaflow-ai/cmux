# Design tokens

Every visual value of the cmux-next macOS app, with its source. Machine-readable twin: [design-tokens.json](design-tokens.json) (the GPUI and browser ports import it). Images are from feat-cmux-next `1824883286a` (the screenshot build); they predate the sidebar tonal step and the pressed fills, so those regions need new images (see pixel-parity.md). Source refs are `path:line (Type.member)` at feat-cmux-next `d445a445556`; when lines drift, the symbol is the anchor. Hex values round each 8-bit channel half away from zero, as Swift's `.rounded()` does (`0.30 × 255 = 76.5` gives `4D`).

![Default window, dark: Apple System Colors theme, two panes, focused pane on the right](images/window/dark-default.png)

![Default window, light: Apple System Colors Light](images/window/light-default.png)

## 1. Color model

Chrome has no fixed palette, except group colors (below). Every color derives from the terminal theme (Ghostty config: `background`, `foreground`, `palette`, `selection-*`, `background-opacity`, `background-blur`) in `ThemeTokens.derive` (`Packages/Shared/CmuxTheme/Sources/CmuxTheme/ThemeTokens.swift:109-167 (ThemeTokens.derive)`). Surfaces next to the terminal are the terminal background, so there is no seam. Fills are the foreground at low alpha. Text is the foreground, muted toward the background only as far as WCAG contrast allows (4.5:1 for primary and secondary, 3:1 for tertiary and status marks). There is no accent hue. The one hue chrome uses is `highlight` (the theme's ANSI 4, usually blue), and only in agent pane composer controls: the Send fill, the pressed plan toggle (`highlight` at 16% with `highlight` text) and a switch's on state (`webviews/src/agent-session/acpmux/composerControls.css`: `.acpmux-send`, `.acpmux-plan[aria-pressed=true]`, `.acpmux-on .acpmux-switch`). `textSelection` is the theme's `selection-background`, so it is blue when the theme's is.

The default theme is `light:Apple System Colors Light,dark:Apple System Colors` (`Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/GhosttyRuntime+DefaultTheme.swift:11-16 (GhosttyRuntime.defaultThemeSpec)`), following the macOS appearance. Before the config is read the app uses Ghostty's built-in default: background `#282C34`, foreground `#FFFFFF` (`ThemeInput.swift:52-59 (ThemeInput.ghosttyDefault)`).

Ports must implement `derive` exactly, not copy the table below: the table is only the result for five reference themes. [tools/derive_theme_tokens.py](tools/derive_theme_tokens.py) is a line-for-line port; use it as the oracle in unit tests.

### Formulas

Every source line below is in `ThemeTokens.derive` (`ThemeTokens.swift`) unless named.

| token | formula (dark / light) | source |
|---|---|---|
| windowBackground, sidebarBackground, contentBackground | bg with alpha = background-opacity | ThemeTokens.swift:126,138-140 |
| chromeBackground | mix(bg, fg, 0.05 / 0.035) | :141 |
| elevatedBackground | mix(bg, fg, 0.07 / 0.02) | :142 |
| stripBackground | mix(bg, black, 0.22 / 0.05), alpha = opacity | :143 |
| textPrimary | fg pushed toward white or black in 0.02 steps until 4.5:1 over pressedFill-on-bg | :119, :173-183 (`readable`) |
| textSecondary | textPrimary mixed toward bg, up to 0.38, keeping 4.5:1 | :120, :187-195 (`muted`) |
| textTertiary | textPrimary mixed toward bg, up to 0.55, keeping 3:1 | :121 |
| hoverFill | fg @ 0.06 / 0.05 | :114 |
| selectionFill | fg @ 0.10 / 0.08 | :115 |
| secondarySelectionFill | fg @ 0.07 / 0.055 | :151 |
| pressedFill | fg @ 0.14 / 0.11 | :116 |
| badgeFill | fg @ 0.14 / 0.10 | :153 |
| separator | fg @ 0.08 / 0.07; clear under borders none | :154; Palette.swift:66 (`Palette.separator`) |
| paneBorder | fg @ 0.07 / 0.09; clear under borders none | :155; Palette.swift:68 (`Palette.paneBorder`) |
| focusRing | fg @ 0.40 (pane ring replaces alpha, see focusRing.contrast) | :156 |
| glassTint | bg @ 0.40 / 0.30 | :157 |
| shadow | mix(bg, black, 0.85), opaque; layers set opacity | :158 |
| textSelection | selection-background, else mix(bg, fg, 0.22) | :159 |
| attention / danger / success | ANSI 3 / 1 / 2 pushed to 3:1 on bg | :160-162 |
| highlight | ANSI 4 pushed to 3:1 | :127, :163 |
| highlightText | bg or textPrimary, whichever contrasts more, if 4.5:1; else black or white | :128-135 |
| sidebarStep | fg @ 0.04: the sidebar's tonal step, laid over the window backdrop | :144 |
| stripStep | black @ 0.22 / 0.05: the darker tab strip's step over the backdrop; over the opaque background it composites to stripBackground | :145 |
| textOnPrimary | opaque contentBackground (text and glyphs on a textPrimary fill: drag count badge, colored section chips) | Palette.swift:88 (`Palette.textOnPrimary`) |
| accent | = focusRing (AppKit's accent stays in the theme's grays) | Palette.swift:85 (`Palette.accent`) |

`mix(a, b, t)` is per-channel sRGB linear interpolation that keeps a's alpha (`ThemeRGB.swift:104 (ThemeRGB.mixed)`). Contrast is WCAG relative luminance (`ThemeRGB.swift:84-96 (ThemeRGB.relativeLuminance, contrast)`). "dark" means luminance(bg) < luminance(fg).

### Resolved values

Value, then the color composited on the window background, both rounded half away from zero. A screenshot can differ from a composited value by one 8-bit level, because the window server blends in 8 bits: Apple System dark selectionFill composites to `#353535` by `ThemeRGB.composited`, and the screenshot shows `#343434`; hover shows `#2B2B2B` against `#2C2C2C`. The token values themselves are exact. Sidebar fills sit on the sidebar step (`sidebarStep`), not on the bare window background.

| token | appleSystemDark | appleSystemLight | ghosttyDefault | monokaiClassic | githubLight |
|---|---|---|---|---|---|
| windowBackground | `#1E1E1E` | `#FEFFFF` | `#282C34` | `#272822` | `#FFFFFF` |
| sidebarBackground | `#1E1E1E` | `#FEFFFF` | `#282C34` | `#272822` | `#FFFFFF` |
| contentBackground | `#1E1E1E` | `#FEFFFF` | `#282C34` | `#272822` | `#FFFFFF` |
| chromeBackground | `#292929` | `#F5F6F6` | `#33373E` | `#32332C` | `#F7F7F7` |
| elevatedBackground | `#2E2E2E` | `#F9FAFA` | `#373B42` | `#363730` | `#FBFBFB` |
| stripBackground | `#171717` | `#F1F2F2` | `#1F2229` | `#1E1F1B` | `#F2F2F2` |
| sidebarStep | `#FFFFFF0A` → `#272727` | `#0000000A` → `#F4F5F5` | `#FFFFFF0A` → `#31343C` | `#FDFFF10A` → `#30312A` | `#1F23280A` → `#F6F6F6` |
| stripStep | `#00000038` → `#171717` | `#0000000D` → `#F1F2F2` | `#00000038` → `#1F2229` | `#00000038` → `#1E1F1B` | `#0000000D` → `#F2F2F2` |
| textPrimary | `#FFFFFF` | `#000000` | `#FFFFFF` | `#FDFFF1` | `#1F2328` |
| textSecondary | `#AAAAAA` | `#616161` | `#B8B9BC` | `#B2B4A9` | `#64676B` |
| textTertiary | `#888888` | `#7F8080` | `#93969A` | `#92938A` | `#828487` |
| hoverFill | `#FFFFFF0F` → `#2C2C2C` | `#0000000D` → `#F1F2F2` | `#FFFFFF0F` → `#353940` | `#FDFFF10F` → `#34352E` | `#1F23280D` → `#F4F4F4` |
| selectionFill | `#FFFFFF1A` → `#353535` | `#00000014` → `#EAEBEB` | `#FFFFFF1A` → `#3E4148` | `#FDFFF11A` → `#3C3E37` | `#1F232814` → `#EDEDEE` |
| secondarySelectionFill | `#FFFFFF12` → `#2E2E2E` | `#0000000E` → `#F0F1F1` | `#FFFFFF12` → `#373B42` | `#FDFFF112` → `#363730` | `#1F23280E` → `#F3F3F3` |
| pressedFill | `#FFFFFF24` → `#3E3E3E` | `#0000001C` → `#E2E3E3` | `#FFFFFF24` → `#464A50` | `#FDFFF124` → `#45463F` | `#1F23281C` → `#E6E7E7` |
| badgeFill | `#FFFFFF24` → `#3E3E3E` | `#0000001A` → `#E5E6E6` | `#FFFFFF24` → `#464A50` | `#FDFFF124` → `#45463F` | `#1F23281A` → `#E9E9EA` |
| separator | `#FFFFFF14` → `#303030` | `#00000012` → `#ECEDED` | `#FFFFFF14` → `#393D44` | `#FDFFF114` → `#383933` | `#1F232812` → `#EFF0F0` |
| paneBorder | `#FFFFFF12` → `#2E2E2E` | `#00000017` → `#E7E8E8` | `#FFFFFF12` → `#373B42` | `#FDFFF112` → `#363730` | `#1F232817` → `#EBEBEC` |
| focusRing | `#FFFFFF66` → `#787878` | `#00000066` → `#989999` | `#FFFFFF66` → `#7E8085` | `#FDFFF166` → `#7D7E75` | `#1F232866` → `#A5A7A9` |
| glassTint | `#1E1E1E66` → `#1E1E1E` | `#FEFFFF4D` → `#FEFFFF` | `#282C3466` → `#282C34` | `#27282266` → `#272822` | `#FFFFFF4D` → `#FFFFFF` |
| shadow | `#050505` | `#262626` | `#060708` | `#060605` | `#262626` |
| textSelection | `#3F638B` | `#ABD8FF` | `#575A61` | `#57584F` | `#CECFD0` |
| attention | `#CDAC08` | `#AC9007` | `#F0C674` | `#E6DB74` | `#4D2D00` |
| danger | `#CC372E` | `#CC372E` | `#CC6666` | `#F92672` | `#CF222E` |
| success | `#26A439` | `#26A439` | `#B5BD68` | `#A6E22E` | `#116329` |
| highlight | `#0869CB` | `#0869CB` | `#81A2BE` | `#FD971F` | `#0969DA` |
| highlightText | `#FFFFFF` | `#FEFFFF` | `#282C34` | `#272822` | `#FFFFFF` |

Pane focus ring colors (fg with the contrast alpha): subtle `fg@0.20`, standard `fg@0.55`, strong `fg@0.85`. Apple dark: `#FFFFFF33` / `#FFFFFF8C` / `#FFFFFFD9`; Apple light: `#00000033` / `#0000008C` / `#000000D9`.

### Group colors (user-content exception)

Tab groups and workspace groups take one of nine fixed colors (`CmuxNextDesign/GroupColor.swift:10-55 (GroupColor)`). They are user content, so they are the one fixed palette in chrome and the one place blue may appear outside the theme. Each is a single hue at low saturation, so groups stay calm next to the gray chrome. New groups never get blue automatically (`CmuxNextTabs/Groups/TabGroupOrdering.swift:86-88 (nextColor)`). Light or dark values follow the view's appearance, not the terminal theme.

| color | hue | chroma |
|---|---|---|
| grey | 0 | 0 |
| blue | 214 | 1 |
| red | 4 | 1 |
| yellow | 46 | 1 |
| green | 136 | 0.9 |
| pink | 330 | 0.95 |
| purple | 272 | 0.9 |
| cyan | 186 | 0.9 |
| orange | 24 | 1 |

| role | formula (light / dark) | used by |
|---|---|---|
| swatch | HSB(hue, 0.42 / 0.40 × chroma, 0.64 / 0.68) | swatches, group underline, sidebar group dot, tab icon tint, profile dot |
| fill | HSB(hue, 0.30 / 0.34 × chroma, 0.86 / 0.40) | tab group chip (hover blends 8% textPrimary, pressed 16%) |
| wash | swatch at alpha 0.09 | band behind a group's tabs |
| sidebar group header, drop target | swatch at alpha 0.16; grey uses selectionFill | `GroupHeaderRowView.swift:81-103 (GroupHeaderRowView.updateLayer)` |

### Theme scopes and translucency

A view resolves tokens inside its `ThemeScope` (app, room, workspace, terminal; `CmuxNextDesign/ThemeScope.swift (ThemeScope)`). A pane's chrome uses the theme of the terminal it shows, so two panes can have different strip colors. The window has one backdrop (`CmuxNextDesign/WindowBackdrop.swift (WindowBackdrop)`, `WindowMaterialView.swift (WindowMaterialView)`): opaque at `background-opacity` 1; otherwise `translucent` (tint only, no blur), `frosted` (NSVisualEffectView `.underWindowBackground`, behind window, when `background-blur` is a radius), or Liquid Glass regular or clear (`background-blur` -1 or -2). `appearance.backgroundBlur` (`frosted`, `glass`, `glass-clear`, `none`) overrides the material. The theme background lies over the material at `background-opacity`. Reduce Transparency makes the window opaque. Panes paint no background over a material; the sidebar and the darker tab strip add their tonal steps (`sidebarStep`, `stripStep`) through `ChromeStepView`, never a second blur. Theme switches crossfade over `fade.theme` (0.16 s).

## 2. Typography

System font (SF Pro) everywhere in native chrome; keycaps and count badges use SF Mono. No custom line height: AppKit's default line height for the font. Sizes scale with `appearance.metrics.chromeFontSize / (compact ? 12 : 13)`. Fractional sizes are exact: render 10.5 pt at 10.5 pt (Skia takes fractional sizes); never round to 10 or 11.

| style | compact | comfortable | weight | used by | source |
|---|---|---|---|---|---|
| body | 12 | 13 | regular | sidebar row title, tab title, palette row, browser body | Metrics.swift:166 (`Typography.body`) |
| bodyEmphasized | 12 | 13 | medium | unread row title, matched palette chars, hover card title | :168 |
| caption | 10.5 | 11 | regular | row subtitle, palette subtitle and accessory, tab location chip | :170 |
| header | 11 | 12 | semibold | sidebar section headers, palette section headers | :172 |
| search | 16 | 18 | regular | palette search field | :174 |
| shortcut (mono) | 10.5 | 11 | medium | keycaps, count badges | :176 |
| title | 20 | 22 | semibold | onboarding, empty states | :178 |
| subtitle | 13 | 14 | regular | onboarding | :180 |
| omnibar | 13 | 14 | regular | browser address field | OmnibarStyle.swift:47 (`OmnibarStyle.font`) |

Agent pane (web): shell 13px system; conversation 14px / 22.75px system-ui; composer 15px / 22px; inline code 13px ui-monospace (`.cv-code`, `conversation.css:130-132`); shell output 12px / 18px ui-monospace (`.cv-shell__body`, `conversation.css:615-622`).

## 3. Metrics

Default density is **compact** (`DesignSettings.swift:25 (DesignSettings.density)`). Spacing is a 2 pt grid: space1 2, space2 4, space3 6, space4 8, space5 12, space6 16 (`Tunables/ChromeTunables.swift:15-20 (ChromeTunables.space1...space6)`). Each density metric below is the `MetricTunables` static of the same name.

| metric | compact | comfortable | source |
|---|---|---|---|
| sidebarWidth (range 120-480; resize 160-360) | 208 | 240 | MetricTunables.swift:36 (`MetricTunables.sidebarWidth`) |
| titlebarHeight | 32 | 40 | :38 |
| trafficLightInset | 76 | 76 | ChromeTunables.swift:24 (`ChromeTunables.trafficLightInset`) |
| sidebarRowHeight | 24 | 32 | :40 |
| sidebarRowHeightWithSubtitle | 36 | 46 | :42 |
| sidebarHeaderHeight | 22 | 26 | :45 |
| tabStripHeight | 28 | 36 | :54 |
| tabHeight | 24 | 30 | :56 |
| tabMaxWidth / tabMinWidth | 200 / 32 | 240 / 40 | :58-61 |
| paletteWidth / searchHeight / rowHeight | 640 / 44 / 32 | 720 / 52 / 40 | :65-70 |
| panelInset | 6 | 8 | :71 |
| columnGap | 6 | 8 | :76 |
| densityPaneCornerRadius | 6 | 8 | :78 |
| panelCornerRadius | 10 | 12 | :84 |
| itemCornerRadius | 6 | 7 | :86 |
| iconSize / smallIconSize | 14 / 12 | 16 / 14 | :88-90 |
| scrollEdgeFade | 18 | 22 | :91 |
| panePadding | 2 | 4 | Metrics.swift:91-95 (`Metrics.panePadding`) |
| divider thickness / hit width | 1 / 7 | 1 / 7 | ChromeTunables.swift:32-33 (`ChromeTunables.dividerThickness`, `dividerHitWidth`) |
| tab background inset / content inset | 1 / 8 | 1 / 8 | ChromeTunables.swift:28-31 (`tabBackgroundInset`, `tabContentLeadingInset`) |
| terminal text inset | 4 | 4 | PaneChromeMetrics.swift:46 (`PaneChromeMetrics.terminalTextInset`) |

Corners come in two shapes, and ports draw each surface with the shape the Swift code uses, pixel for pixel.

**Continuous** (`cornerCurve = .continuous`): tab pills, tab close, new-tab and trailing buttons, sidebar rows, the selection pill, section items, icon buttons (ChromeHover fills), the unread count pill and dot, tab group chips and bands, the omnibar, its chip and suggestion card, hover card thumbnails, drag lift cards, and every Liquid Glass panel. CoreAnimation does not publish this curve, so the spec gives a fitted path. Each corner of radius `r` is a straight edge that ends `1.547302 r` from the corner, then three cubic Béziers. For the top-left corner, with points as (inset from the left edge, inset from the top edge) in units of `r`:

```
move/line to (1.547302, 0)
cubic  c1 (1.084498, 0)         c2 (0.882045, 0)         to (0.644148, 0.070748)
cubic  c1 (0.376057, 0.163004)  c2 (0.163004, 0.376057)  to (0.070748, 0.644148)
cubic  c1 (0, 0.882045)         c2 (0, 1.084498)         to (0, 1.547302)
```

The other corners mirror it. Do not clamp `r` or the extents when `1.547302 r` is more than half a side (a 24 pt omnibar with r 8, a capsule): the overlapping corner curves fill the same shape CoreAnimation draws. Measured against `CALayer` renders at 2x (`tools/continuous_corner_check.swift`, run on macOS 26): at most 3 of 255 levels on any pixel for r 4 to 12 on every chrome size above, including capsules. The one larger gap is a square whose `r` is half its side (the 6 pt unread dot): at most 9 levels, so it stays within the antialiasing budget. The widely quoted iOS 7 constants (1.52866483, 1.08849323, 0.86840689, 0.66993427, 0.06549600, 0.37754822, 0.16550930) miss by up to 44 levels; do not use them. In Skia, build the path with `SkPath::cubicTo` from these points and fill it antialiased.

**Circular arcs** (CALayer default, `NSBezierPath(roundedRect:)`, `CGPath(roundedRect:)`): on purpose, pane clips, pane borders, the focus, glow and attention rings and the inactive dim, so the browser page mask, a circular-arc path built from the same radius, matches them (`CmuxNextLayout/Views/PaneHostView.swift:128-131 (PaneClipView)`). Also circular, by default rather than by decision: palette rows, keycaps and actions-menu rows (`CmuxNextPalette/PaletteRowCell.swift:41,67 (PaletteKeycapsView.draw, PaletteTableRowView.drawBackground)`), tab status dots and the drop overlay hairlines. Ports draw these with circular arcs too.

Hairlines are one device pixel (1/scale pt). Strip offsets snap to device pixels (`PaneChromeMetrics.swift:69-77 (PaneChromeMetrics.snap, snapDown)`).

![Comfortable density, dark](images/window/dark-density-comfortable.png) ![Comfortable density, light](images/window/light-density-comfortable.png)

## 4. Materials

| surface | macOS 26+ | older macOS | Reduce Transparency | source |
|---|---|---|---|---|
| Floating overlays: palette, palette actions menu and shortcut recorder, hover cards, browser find bar, prompt bar, notices and page info, tab group editor, restart notice, drop overlay, drop highlight, sticky column backdrop, refusal HUD | NSGlassEffectView .regular, tint glassTint, radius panelCornerRadius | NSVisualEffectView .popover, withinWindow, glassTint layer, 1/scale separator border | opaque: mix(window, textPrimary, 0.14), 1/scale opaque separator border | OverlayMaterial.swift (OverlayMaterial.select, ReduceTransparency, ThemeTokens.opaqueOverlayFill); OverlaySurface.swift (OverlaySurfaceView.applyTheme); Glass.swift (Glass.makeOverlayPanel) |
| Sidebar | `ChromeStepView` with sidebarStep over the window backdrop | same | same (the backdrop is opaque) | SidebarContainerView.swift (SidebarContainerView.backdropStep); ChromeStepView.swift (ChromeStepView) |
| Tab strip (darker) | `ChromeStepView` with stripStep over the window backdrop; none for tabBarBackground window | same | same | PaneContentView.swift:15,56-58 (PaneContentView.stripBackdrop, stripStep) |
| Window | one backdrop: opaque, translucent, frosted or Liquid Glass (see Theme scopes and translucency) | frosted instead of glass | opaque | WindowBackdrop.swift (WindowBackdrop); WindowMaterialView.swift (WindowMaterialView) |

Every listed surface draws through `OverlaySurfaceView`: the drop overlay, drop highlight, sticky column backdrop and refusal HUD directly, the palette, its actions menu and shortcut recorder, hover cards, the browser find bar, prompt bar, notices and page info, the tab group editor and the restart notice through `Glass.makeOverlayPanel`. One observer (`ReduceTransparency`) switches every live surface when the setting changes; a theme scope repaint recolors the fallback.

The "older macOS" column cannot run in the macOS app today: `Packages/macOS/CmuxNext/Package.swift` requires macOS 26. Ports on a platform without Liquid Glass use the vibrancy row where the platform has a blur, else the opaque fallback.

The overlay tint strength Debug tunable (default 1, `ChromeTunables.swift:43-45 (ChromeTunables.glassOverlayTintStrength)`) scales the tint of `OverlaySurface` only. `Glass.makePanel` panels use `glassTint` unscaled.

## 5. Motion

Speed `fast` (default) scales times by 1, `normal` by 1.5, `off` disables (`Motion/MotionTokens.swift:4-19 (MotionSpeed)`). Fades use `easeOut` (`cubic-bezier(0,0,0.58,1)`, `Motion/Motion.swift:51 (Motion.fadeCurve)`). Springs use response/dampingFraction (SwiftUI semantics; `omega = 2π/response`, stiffness `omega²`, damping `2ζω`, `Motion/SpringParameters.swift (SpringParameters)`).

| spring | response | damping | use |
|---|---|---|---|
| move | 0.20 | 0.90 | tab reflow, row moves, pane frames |
| appear | 0.18 | 0.90 | palette scale-in, tab grow-in, row insert |
| disappear | 0.15 | 0.90 | tab close, collapse, row removal |
| settle | 0.22 | 0.85 | drop after drag |
| scroll | 0.22 | 0.90 | strip reveal, column reveal, fling snap |
| screen | 0.22 | 0.90 | screen switch |
| track | 0.12 | 0.90 | drop overlay, drag ghost |
| selection | 0.15 | 0.90 | sidebar selection pill |
| panel | 0.18 | 0.85 | hover card slide |

| fade | s | use |
|---|---|---|
| hover | 0.08 | hover fills, revealed buttons |
| focus | 0.10 | focus ring, inactive dim |
| fadeIn / fadeOut | 0.12 / 0.08 | palette, find bar, notices, hover card |
| crossfade | 0.10 | thumbnail swap; Reduce Motion ceiling |
| lift | 0.12 | drag lift shadow |
| theme | 0.16 | theme switch |
| highlight | 1.20 | Settings row highlight after a search jump or deep link |

Loops: spinner 0.9 s/turn (the braille style steps its 10 frames over the same period), status pulse 1.8 s (easeInEaseOut, low opacity 0.35), attention flash 0.6 s (two blinks of 0.3 s). The pane attention ring's pulse style uses the 1.8 s period with low opacity 0.3 and runs for `notifications.attention.duration` (`Motion/Motion+Attention.swift:14-50 (Motion.attentionAnimation)`). Marquee: delay 0.6 s, 40 pt/s, minimum 0.4 s, hold 1.2 s, ignore under 2 pt. Palette open scale 0.97, close 0.98. Source: `Motion/MotionTunables.swift:10-80 (MotionTunables.springDefaults, fadeDefaults, loopDefaults, marquee*, panel*Scale)`.

Reduce Motion: no movement springs and no loops; fades capped at 0.1 s; the attention ring fades in once (`Motion/MotionPolicy.swift (MotionPolicy)`).

## 6. Visual settings

| setting | values (default first) | effect |
|---|---|---|
| appearance.density | compact, comfortable | every metric |
| appearance.borders | default, none | none clears all borders, hairlines, separators, the focus ring, the attention width and the omnibar editing ring; the agent pane clears its composer, menu, code block and card edges (`data-borders="none"`). [Borders none](images/window/dark-borders-none.png) |
| appearance.focusIndicator | both, border, tabs, none | border = focus ring; tabs = inactive pane tabs subtler |
| appearance.tabBarBackground | window, darker | darker paints stripBackground |
| focusRing.contrast | subtle 0.20, standard 0.55, strong 0.85 | ring alpha |
| focusRing.{enabled,style,color,width,cornerRadius,showWhenSinglePane} | true, ring, nil, 1, nil, false | |
| focus.inactiveTabStyle (the Debug tunable of the same name overrides it) | fade, tonal, quiet; strength 0.35 (Debug tunable) | see tabs page (`CmuxNextSettings/PaneFocusSettings.swift (PaneFocusSettings.inactiveTabStylePath)`) |
| sidebar.sectionLook (Debug tunable `sidebar.sections.look` overrides it) | quiet, card, tray, lines, linesIcons | see sidebar page |
| sidebar.topBandMaxShare / bottomBandMaxShare / stickyBandsScroll | 1/3, 0.25 (range 0.1-0.9), true | share of the sidebar height a sticky band takes before it scrolls inside; false: bands never scroll and the list shrinks (three rows minimum) |
| notifications.attention.* | style blink, width 2, blinkCount 2, duration 3 s, persist true | pane attention ring. Blink: blinkCount blinks over 0.3 s each (0.6 s for 2), then holds. duration applies to the pulse style only |
| appearance.backgroundBlur | unset (Ghostty's background-blur), frosted, glass, glass-clear, none | the window material |
| appearance.statusIndicator.* | style arc (arc, native, dot, braille, none), size 1 (0.5-1.5), thickness 1.5, color textSecondary, honorStatusStyle true | status glyphs on sidebar rows, section headers and tabs. The cmux.json key is `size` (`StatusIndicatorConfigParser.swift:13`); the model field is `StatusIndicatorSettings.scale` |
| layout.panePadding / paneCornerRadius / paneBorder / paneBorderColor / paneBorderWidth | density values | pane chrome |
