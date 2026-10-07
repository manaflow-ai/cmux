# cmux-next tab strip: narrow tabs, favicons, title marquee

Dogfood nxdog13 asked for narrow tabs,
favicons in browser tabs, and a hover marquee for clipped titles. Code:
`TabChromeVisibility`, `TabCell`, `CmuxNextDesign/Text/TitleFade*`,
`CmuxNextApp/Favicons/`.

## Narrow tabs (Chromium thresholds)

Sources, Chromium `main` on 2026-09-30:
[tab.cc](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/views/tabs/tab.cc)
(`Tab::UpdateIconVisibility`, `Tab::Layout`),
[tab.h](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/views/tabs/tab.h)
(`kMinimumContentsWidthForCloseButtons = 68`),
[tab_style.cc](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/tabs/tab_style.cc)
(standard width 232 + 2 x 12, minimum inactive width "appears 16 DIP
wide", minimum active width = favicon or close button + insets, pinned
content 24, separators 2 x 16 DIP),
[layout_constants.cc](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/layout_constants.cc)
(close button 14 or 16, pre-title padding 8, after-title padding 4) and
[tab_strip_layout.cc](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/views/tabs/tab_strip_layout.cc)
(inactive tabs shrink below the active one before the strip overflows).

Chromium decides from the contents width (tab width less both content
insets). cmux uses the same rules in points with its own tokens:

| Rule | Chromium | cmux |
| --- | --- | --- |
| Inactive favicon | shown while it fits, else centered and clipped | same |
| Inactive title | any width left after favicon + pre-title padding, `FADE_TAIL` | same, at least `titleMinVisibleWidth` (12 pt), alpha-mask fade |
| Inactive x | always, from 68 DIP of contents | on hover only (nxdog9), from 68 pt of contents |
| Active x | always | on hover; always once contents < 68 pt (narrow) |
| Active favicon | after the x, if it still fits | same; else the x alone, centered |
| Below minimum inactive width | nothing drawn | same (closing, growing in) |
| Pinned | favicon only | same |
| Separators | between inactive tabs, hidden next to the active or hovered tab and at the ends | same (1 device pixel, half the tab height) |

The strip keeps its own widths (compact: 200 pt max, 32 pt minimum
inactive, scrolls after that; the "+" follows the last tab).

## Favicons

`BrowserTabIconState` is Chromium's `TabIcon` rule: throbber while the live
page loads, else the favicon, else a globe. `TabFaviconStore` resolves the
live page's favicon URL, or the daemon record's for a tab without a live
page, through `BrowserFaviconLoader`: http(s) only, no cookies sent or
stored, 1 MiB body cap, fetch and decode off the main thread, redrawn at
most 64 px, cached per profile (64 per profile in the loader, 256
`TabImage`s in the store). Nothing polls: a strip snapshot that reads a
missing icon starts one fetch and re-renders when it lands.

Not done: the Chromium engine still fetches through this loader instead of
the tab's own Chromium request context (`CefBrowserHost::DownloadImage`),
which needs a new CEF shim entry point; Chromium's two throbber states
(waiting counter-clockwise, loading clockwise) are one spinner; agent
program icons on terminal tabs.

## Title marquee

A clipped tab or workspace title fades out (no ellipsis). While the pointer
rests on it, after `MotionMarquee.delay` it scrolls at 40 pt/s until its
last glyph is fully opaque, holds, and returns (motion.md). Glyphs leaving
on the left fade across the row's own padding (the icon-title gap in a
tab). One Core Animation keyframe pass on the title with the same pass
inverted on its mask; the delay is the animation's `beginTime`, so no app
timer runs. Leaving stops it at once (a mid-scroll title springs back).
Reduce Motion and `ui.animationSpeed` "off" never start it: the tab hover
card and the workspace row's tooltip show the full title instead.
