# Browser chrome: Helium parity

Lawrence, 2026-10-20: "You made the browser UI match Chrome perfectly but I actually wanted to
match Helium not Chrome. [...] match them in terms of size, spacing, and the hover effects (not
the background colors, but what happens when you hover on it)."

Source: [imputnet/helium](https://github.com/imputnet/helium) at `3423b1671a7` (Oct 19 2026,
Chromium 155.0.8059.84), `patches/helium/ui/`. Helium's macOS repo
([imputnet/helium-macos](https://github.com/imputnet/helium-macos)) has no toolbar or tab metric
patches; all metrics come from the shared patches. A base value a patch does not change was read
from Chromium 155.0.8059.84 (marked "Chromium").

Colors are not ported: cmux keeps its theme tokens (`Palette.hoverFill`, `selectionFill`,
`pressedFill`). Only geometry and hover behavior change.

## Ported (landed with this doc)

| Item | Helium source (file:line) | Helium | cmux before (Chrome) | cmux after | cmux symbol |
|---|---|---|---|---|---|
| Toolbar button size | layout-constants.patch:95 `kToolbarButtonHeight` | 28 | 34 | 28 | `OmnibarStyle.buttonSize` |
| Toolbar button hover shape | toolbar.patch:8, :30 `Emphasis::kHigh` (Chromium layout_provider.cc:199, 8) | rounded square, r 8 | circle (r 17) | rounded square, r 8 | `OmnibarStyle.buttonCornerRadius` |
| Toolbar icon | layout-constants.patch:144 `TOOLBAR_BUTTON` insets 4 (28 - 2x4) | 20 | 20 | 20 (no change) | `OmnibarStyle.toolbarIconSize` |
| Gap between toolbar buttons | layout-constants.patch:113 `kToolbarIconDefaultMargin` = base 3 (FlexLayout collapses margins) | 3 | 0 (nav), 2 (extensions, trailing) | 3 everywhere | `OmnibarStyle.buttonSpacing` |
| Omnibar trailing icon (star) | layout-constants.patch:60 `kLocationBarTrailingIconSize` | 18 | 20 | 18 | `OmnibarStyle.trailingIconSize` |
| Tab x threshold (contents width) | tabs.patch:370 `kMinimumContentsWidthForCloseButtons` | 56 | 68 | 56 | `TabTunables.closeMinContentsWidth` |
| Tab x hover shape | tabs.patch:419-420 `RoundRectHighlightPathGenerator(VH(1,0), 4)` | rounded rect, r 4 | r 5 (comfortable), r 4 (compact) | r 4 | `TabStripMetrics.closeCornerRadius` |

## Already Helium's (no change)

| Item | Helium source | Helium | cmux |
|---|---|---|---|
| Base padding | layout-constants.patch:7 `kHeliumBasePadding` | 3 | `OmnibarStyle.basePadding` 3 |
| Omnibar height | layout-constants.patch:51 `kLocationBarHeight` | 28 | `OmnibarStyle.barHeight` 28 |
| Omnibar corner | location-bar.patch:20 (bar 8, padding 2, children 6) | 8 | `barCornerRadius` 8 |
| Omnibar child (chip, star) corner | layout-constants.patch:28 `kLocationBarChildCornerRadius` | 6 | `chipCornerRadius` 6 |
| Omnibar side margin | layout-constants.patch:116 `kLocationBarMargin` (2 x base) | 6 | `barMargin` 6 |
| Page-info chip (28 - 2 x 2) | layout-constants.patch `kLocationBarPageInfoIconVerticalPadding` 2 | 24 | `chipSize` 24 |
| Chip leading | `kLocationBarElementPadding` | 2 | `chipLeading` 2 |
| Suggestion row height | omnibox.patch:275 `OmniboxMatchCellView::kRowHeight` | 28 | `rowHeight` 28 |
| Favicon to title | layout-constants.patch:83 `kTabPreTitlePadding` | 6 | `iconTitleSpacing` 6 (comfortable) |
| Press ripple | disable-ink-ripple-effect.patch:8 `kUseRipples = false` | none, highlight only | none: press shows a flat pressed fill at once |
| Tab hover | tabs.patch (PaintBackgroundHover removed; hovered fill is the tab background color) | flat fill, no radial glow | flat `hoverFill` pill |
| Close x on inactive tabs | tabs.patch:300 `mouse_hovered_ &&` | only while hovered | only while hovered |

## Not ported (default picked, can change)

| Item | Helium | cmux now | Why kept |
|---|---|---|---|
| Hover fade timing | Chromium ink_drop_impl.cc:25-26: 250 ms in, 250 ms out | fast ease in, instant out (`MotionFade.hover` / `.hoverOut`) | Shared motion tokens used by the sidebar and every chrome control; Lawrence chose instant clears (Edge, "a fast sweep leaves no trail"); a274 owns the motion gate. |
| Close x on the selected tab | shown at all times (declutter off, enable-glow-up-features.patch) | shown on hover only (nxdog9) | Lawrence's own rule for cmux tabs. |
| Tab close button size | 14 (rounded icons on, enable-glow-up-features.patch; `kTabCloseButtonSize`) | 16 | The x's 20 x 20 pt click target (Apple's minimum, Lawrence 2026-10-20) needs the 16 pt button. |
| Tab height / strip | 31 in a 34 strip (layout-constants.patch:72, :78) | 24 in 28 (compact, default), 30 in 36 (comfortable) | The strip is every pane's (terminal, Markdown, browser) and follows the density tokens and the even-gap rule (`PaneChromeMetrics`). |
| Tab width | 190 + 2 x 8 (tabs.patch:17) | 200 compact, 240 comfortable (`tabs.maxWidth` setting) | Same shared-strip reason; a user setting. |
| Tab corner | 8 top and bottom (tabs.patch:49, :54) | `itemCornerRadius` 6 compact / 7 comfortable | Shared item radius; 8 on a 24 pt compact tab is too round. |
| New-tab + corner | 8 (tab-strip-controls.patch:8) | `itemCornerRadius` (6 / 7) | Already a rounded square, as Helium's; same shared radius. |
| Omnibox popup corner | 12 (omnibox.patch:20) | the bar's 8, bar and popup one shape | Lawrence's earlier rule: the open bar and the card are one shape. |
| Toolbar side inset | `TOOLBAR_INTERIOR_MARGIN` VH(3, 6) | `Metrics.paneChromeInset` | cmux lines the first button up with the tab pills above it. |

## Tests

`Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/HeliumChromeParityTests.swift` (red first, then
the fix) and `PaneChromeEvenGapTests.theToolbarButtonsAreHeliumsSizeAndKeepTheRowsEvenGap`.
