# The selected item is the foreground

Leo, 2026-11-10:

> in light mode, for instance. Okay, when your tab is selected, you know, just like a simple example
> is like white background, and all that stuff. It's like it should be. The selected tab should be
> white as well. Right now, the selected tab gets this highlight, and it's gray. But it's like, bro,
> that doesn't make sense because it looks like it's backgrounded against the foreground, which is
> light mode. And the same thing likewise happens in dark mode. [...] We can like morph it in as
> like, you know how folder tabs look, right? Like just integrate that. Like make it look cohesive.
> Make it look good. And the other thing is I was thinking like, wait a second, this is even better
> when you have image-based backgrounds because it's like, oh, like actually, yeah, the same kind of
> foregrounding, backgrounding thing applies. We can go under that paradigm instead of the current
> stuff that we have.

## The rule

A window has two layers:

| Layer | What it is | Token |
|---|---|---|
| content (foreground) | the pane's card: terminal, page, agent chat | `ThemeTokens.contentSurface` / `--cmux-content-surface` / `--ds-color-content-surface` |
| chrome (background) | everything around the card: sidebar, tab strip, titlebar | the content surface under `ThemeTokens.chromeSurface(shade:)`, i.e. black at `Metrics.mainPaneChromeShade` (4.5% light, 28% dark) / `--cmux-chrome-shade` / `--ds-color-chrome-shade` |

A selected tab, row, segment or nav item belongs to the foreground. It is drawn in the content's own
surface, never a gray picked per component:

- light mode: white, like the content;
- dark mode: the content's black;
- an image or see-through window: exactly what the content shows. There the content paints nothing
  of its own (`Palette.paneFill` is clear) and shows the window's one tint, and the chrome's shade
  lies on that tint, so no fill over the shade can show what the content shows: it would add the
  tint twice. The tab strip cuts the shade away under the selected tab instead (the folder tab is
  clear there). A sidebar row, which cannot cut the shade, keeps `Palette.selectionFill` in a
  see-through window (`ThemeTokens.selectedSurface(panesPaint:chromeShade:)` is nil); in an opaque window it is
  the content's surface, opaque.

The content's surface counts as the selection only where it stands out of the chrome around it:
WCAG contrast of at least 1.04 against black at the chrome's shade over it
(`ThemeTokens.minimumSelectedContrast`, `ThemeTokens.selectedOnChrome`, mirrored in the gallery's
`selectedOnChrome`). No shade (bare, panes, flat-sidebar-line), or a near-black theme whose shade
does not show (Builtin Dark's #000000), keeps `Palette.selectionFill`. The folder tab follows the
same rule (`Palette.selectedFolderReads`): where it would not read, its pill keeps the selection fill
over the folder. A folder is made hidden and fades in on its first selection, like every later one.

The folder join changes no layout's geometry: Floating Panes and Blocks (pane separation `cards`)
keep their pane padding (`Metrics.codePanePadding`), so each pane's first tab sits inside its card.
While a tab's width moves, the folder's outline is keyframed on the same samples as the pill
(`TabCell+InnerPath`), so the folder moves with the tab, and the chrome shade's hole under it
plays the same samples, with the tab's slot move folded in (`TabStripView.selectedFolderMotion`,
`ChromeShadeHoles.FolderMotion`): the hole, the outline and the fill move together, nothing jumps.

The frame around the card (trimmed under the top row, wedges, the top row's folder holes, the pills
on the traffic lights' line) needs a shown strip along the card's top. Without one (vertical tabs, a
hidden tab bar, an app workspace, Home Chief) the card keeps its whole frame and four rounded
corners, and every strip draws its own band. A strip's first tab sits on its leading (minX) edge
whichever side the sidebar is on, so that is the corner that squares. Styles with a shade of their own
(two-tone, floating, blocks) keep it. A panel with its own fill is chrome too: the rail's open
overlay and the hover-expanded vertical list draw the chrome's shade; a row on the user's sidebar
colour (`appearance.surfaces.sidebar`) takes the contrast rule against that colour
(`Palette.selectedSurface(over:)`). With no shade, `--cmux-chrome-shade` is the hover fill, so a
track or a nav keeps its background.

`selectedSurface` is the token, mapped to `contentSurface`: `ThemeTokens.selectedSurface`,
`Palette.selectedSurface` (a row over the shade), `Palette.selectedFolderSurface` (the folder tab, =
`Palette.contentSurface` = `paneFill`, what the content really paints),
`--cmux-selected-surface`, `--ds-color-selected`. Unselected items have no fill of their own: they
sit on the chrome.

## The folder tab

The selected tab and the content are one shape: the tab rises from the content's top edge, rounded
on top (the tab's corner radius, 6pt compact), and meets the edge through two concave fillets
(8pt), each tangent to the tab's side and to the edge. No seam and no border. The first tab, on the
content's leading edge, has no leading fillet: the content's side continues straight up into the
tab's. The gray pill is gone.

This is `chrome.cornerFlush` = `flush-goo`, now the default at every density
(`CornerFlush.swift`). The default window (`appearance.chromeStyle` unset, which reads as `flat`)
and every style with the card take it, with the card. A style the user picked without the card
(bare, panes, flat-sidebar-line) or a set `layout.panePadding` keeps that layout and its gray
selection (the folder tab puts each strip's first tab on the card's edge).
A Debug Settings value applies as set. `off`, `flush` and `flush-tight` stay as Debug tunables. Tabs at the bottom
of a pane get no folder.

- Top-row strips sit on the window's chrome shade (`MainPaneChromeShadeView`). The shade gets a hole
  under the selected folder (`ChromeShadeHoles`), so over an image the tab shows what the content does.
- Strips inside the card (a lower or inner split) draw their own chrome band at the same shade, with
  the same hole, so their folder reads against the card the same way.
- Under Floating Panes there is no frame shade (the main pane has no radius), so every strip draws
  that band itself.
- The card is 12pt, concentric with the window across its 4pt gap; `layout.paneCornerRadius` still
  sets it.

Gallery: `webviews/src/gallery/fixtures/FolderTabs.gallery.tsx` (`native.folder-tabs`). Variants:
`goo-r8` (ships), `goo-r8-first-tab`, `goo-r4`, `goo-r12`, `square`, `goo-r8-hairline`,
`pill-before`, each in light, dark and over an image through the gallery's axes. Pick: `goo-r8`.
r4 reads as a notch, r12 crowds a 24pt compact tab, the square join looks pasted on, and the
hairline brings back the seam the rule removes.

## Motion

A selection change is a state transition, not a redraw. The folder is one layer per tab, laid out
once per geometry change. A selection change cross-fades the old tab's folder out and the new
one's in (`Motion.tabs`, `MotionFade.crossfade`, 80 ms; instant under Reduce Motion), and the shade's
holes cross-fade with them (`ChromeShadeHoles` patches), so the shape and its colour move together.
Nothing is laid out again: no height change, no pop-in, no jump. Known gap: the tab title's colour
changes at once.

## Surfaces

Changed:

| Surface | Before | Now |
|---|---|---|
| pane tab strip (`TabCell`, `TabStripView`) | gray pill | folder tab in `selectedFolderSurface`, shade hole under it |
| workspace tabs (vertical list, `VerticalTabListView+Drawing`) | selectionFill | `selectedSurface` |
| sidebar workspace rows (`WorkspaceRowView+Rendering`) | selectionFill | `selectedSurface`; the drop target keeps selectionFill (it is a target, not a selection) |
| sidebar session/item rows (`SidebarItemRowView`, `SidebarItemListRowView`) | selectionFill | `selectedSurface`; the key-focus ring stays |
| web segmented control (`ui/controls.css`) | gray active segment on a gray track | active segment `--ds-color-selected` on a `--ds-color-chrome-shade` track |
| settings nav and segments (`pages/settings/styles.css`, `refined.css`) | tinted pill on the page | sidebar is the chrome shade, `aria-current` link and checked segment are `--ds-color-selected` |

Left alone, with the reason:

| Surface | Why |
|---|---|
| command palette rows (`PaletteRowCell`) | a cursor on floating glass, not a selection against the content |
| notifications panel rows (`NotificationRowView`) | a floating panel; there is no content layer under it |
| hover and lit controls (`ChromeHover`) | a lit control inside the content, not a selected item |
| list rows inside content pages (70 rules in `schemas/selected-surface/pending.json`) | they already sit on the content, so "the content's surface" would erase them; each needs its own decision, and the backlog only shrinks |
| iOS (`CmuxTabsKit`) | native Swift with a card overview and no selected pill; iOS web pages get the CSS fallbacks of `--ds-color-*` |
| classic | frozen |

## Check

`scripts/cmux-next/check-selected-surface.py` runs in the pre-push gate:

- `[web-selected]`: a CSS rule whose selector is a selected state (`[aria-selected]`,
  `[aria-current]`, `[data-selected]`, `[data-active]`, `[data-checked]`, `.is-selected`,
  `.is-active`, `.is-current`) and paints a background must use `--ds-color-selected` or
  `--cmux-selected-surface`.
- `[native-selected]`: a NEXT line painting `Palette.selectionFill` for a selected or active item
  must use `Palette.selectedSurface` or `Palette.selectedFolderSurface`.
- `[stale-pending]`: a fixed backlog entry must leave the list.

A surface that is not a foreground selection says why with a `selected-surface-allow: <reason>`
comment. Tests: `tests/test_cmux_next_selected_surface.py` (lane manual: no new CI tests).
