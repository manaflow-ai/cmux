# Derived sizing

Lawrence, 2026-11-03 (msg 19857): "need to make sure everything's size is proportional the
compactness of ui etc, design it to be cohesive, and derived, and customizable from first
principles". The screenshot showed the update card's What's New popover ("What's new in nightly
4160614") with type and spacing about a quarter larger than the Compact sidebar rows and the
Update Ready card beside it.

## The model

Every chrome size is a function of a few inputs. Nothing a surface draws is a number of its own.

| Input | Setting | What it sets |
|---|---|---|
| Density | `appearance.density` (`DensityTokens`: `level`, `spacing`, `fontSize`, `tokens`) | The base row height, the 2 pt spacing grid (`Metrics.space1…6`), the item corner and the body/caption text (`Typography.body`, `.caption`). |
| Interface Size | `appearance.interfaceScale` (opt-in) | One multiplier over every token above (`Metrics.scale`, `Typography.userScale`). |
| Sidebar density | `sidebar.density` (compact, comfortable, expanded) | A row step (`space2`) and the inset step (`space3` → `space4`) on top of the base. |
| Sidebar text size | `sidebar.textSize` (default, large, larger) | +0/1/2 pt text and +0/3/5 pt rows. |
| Content scale | `app.uiScale` | The zoom of web pages. **Not a chrome input.** A chrome surface drawn by a page divides it out. |

Derivation (`SidebarRowTokens`, CmuxNextDesign, pure and tested):

```
rowHeight     = base.rowHeight + (comfortable ? space2 : 0) + textSize.rowStep
inset         = comfortable ? space4 : space3
title, detail = base.body, base.caption  + textSize.textStep
card          = inset, space2|space3 padding, row-tall button less 2×space1, corner = item corner + padding
popover       = title/detail text, line = round(text × 11/8), padding 2×inset × (card.paddingY + space2),
                a row's vertical room per change, width = 26 × title (on the 2 pt grid)
```

The customizable knobs are the existing ones: a custom density (`level`, `spacing`, `fontSize`,
exact `tokens`), `appearance.metrics.*` overrides, `sidebar.density` and `sidebar.textSize`. Each
derived surface follows them without a knob of its own.

Web surfaces get the derived values as CSS variables in page px. These are the points divided by
the page zoom, so a page draws the same points as the native rows at any `app.uiScale`:

- `--cmux-sidebar-card-*`: the Updated / Update Ready card (`SidebarCardMetrics`).
- `--cmux-sidebar-pop-*`: the What's New highlights popover (`SidebarPopoverMetrics`).

`WebTheme` carries both. `PageWebView` pushes the theme again when they change.

## The What's New popover (fixed first)

Before: `.wn-pop` used the pages' type ramp (13 px body on 18 px lines, 12 px details, 340 px wide).
The page is zoomed by `app.uiScale`, so at Lawrence's 1.15 the changes drew at 15 pt on 20.7 pt
lines beside 12 pt Compact rows. That is 25% larger than the rows and the card it opens from. The
page's 340 CSS px also overflowed the 340 pt host.

After: at Compact and default text, the body is 12 pt on 17 pt lines, details are 10.5 pt on 14 pt
lines, the padding is 12/8 pt, the width is 312 pt, and the native host takes the same width.
Larger text gives 14 pt on 19 pt lines at 364 pt. Comfortable keeps the text and adds room.

## Audit (2026-11-03, feat-cmux-next f093ac3)

Literal font sizes and literal lengths (`constant:/width:/height:/padding:/cornerRadius:/spacing:
<number>`) per module:

| Module | literal fonts | literal lengths |
|---|---|---|
| CmuxNextFeed | 35 | 84 |
| CmuxNextHome | 6 | 34 |
| CmuxNextTabs | 0 | 28 |
| CmuxNextSidebar | 0 | 17 |
| CmuxNextUpdater | 0 | 3 |
| CmuxNextPopups | 0 | 2 |

Known leaks, in the order to fix them:

1. **Pages shown as chrome.** Hover cards, the onboarding pages and the Home chat chrome use the
   pages' ramp (`desktop.css` 11/12/13 px, Comfortable's) under the content zoom. Each one should
   read derived variables, as the card and the popover now do.
2. **Tab strip vs sidebar text size.** Tabs follow `appearance.density` only. At `sidebar.textSize`
   larger, rows are 14 pt and tab titles stay 12 pt. The playground shows this side by side.
3. **Sidebar status block.** `SidebarLayoutMetrics.statusLineHeight` (14), `progressBarHeight` (8)
   and `statusBottomPadding` (4) are fixed. They should derive from the caption line.
4. **Feed cards.** CmuxNextFeed has the most literals. It should move onto `Metrics`/`Typography`.

## Playground

Debug menu > **Sizing Playground** (`debug.sizingPlayground`, DEV and NIGHTLY). It has one
specimen per sidebar density × text size. Each specimen shows a tab strip, four rows (one selected,
one with an unread dot), the Update Ready card and the What's New popover, all from
`SidebarRowTokens`. The bar switches Light/Dark. It also switches the popover between **Derived**
(shipped) and **Before**, which draws the page type under the current `app.uiScale`. The specimens
redraw live when the density, Interface Size or text tokens change.
