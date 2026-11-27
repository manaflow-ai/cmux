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
| Inactive x | always, from 68 DIP of contents | on hover only (nxdog9), from the favicon + x width (below) |
| Active x | always | on hover; always once contents < 68 pt (narrow) |
| Active favicon | after the x, if it still fits | same; else the x alone, centered |
| Below minimum inactive width | nothing drawn | same (closing, growing in) |
| Pinned | favicon only | same |
| Separators | between inactive tabs, hidden next to the active or hovered tab and at the ends | same (1 device pixel, half the tab height) |

The strip keeps its own widths (compact: 200 pt max, 56 pt selected (Chrome's,
Lawrence 2026-10-16), scrolls after that; the "+" follows the last tab). The
other tabs' minimum (Settings > Minimum Tab Width,
`appearance.metrics.tabMinInactiveWidth`) is the room for the favicon and the
x side by side, worked out from the parts (Lawrence 2026-10-20, replacing
Chrome's 32, where the x never fits): `TabStripMetrics.faviconCloseWidth` =
pill insets 2 x 1 + leading inset 8 + favicon 16 + gap 4 + x 16 + trailing
inset 4 = 50 comfortable; 48 compact (14 pt favicon); 46 under Compact tabs
(6 pt leading inset). The x's click target is the drawn 16 pt plus 2 pt a side,
20 pt, Apple's macOS minimum (HIG Accessibility, 20 x 20 pt); it stays inside
the pill and clear of the favicon. The 7 pt glyph centered in the 16 pt button
leaves 8.5 pt to the favicon and to the pill's edge, matching the 8 pt before
the favicon, so the pair reads centered. Tab Overflow (`tabs.overflow`, cx-kp9b4) Scroll keeps
tabs 140 pt wide and scrolls sooner; the palette's Tabs: Use Scrolling Tabs /
Tabs: Use Shrinking Tabs set it, and the first crowded Shrink strip offers it
once at its trailing end.

## Favicons

`BrowserTabIconState` is Chromium's `TabIcon` rule: throbber while the live
page loads, else the favicon, else a globe. Unlike Chromium, the waiting state
(the request is out, nothing committed yet) does not turn the other way: every
cmux spinner turns clockwise on one shared clock (`SpinnerClock`; user
2026-10-20, "synced and spinning in the same direction").

`TabFaviconStore` resolves the live page's favicon URL, or the daemon
record's for a tab without a live page. A live page's icon is fetched as
that page fetches it: a Chromium tab through its own request context
(`cmux_shim_download_favicon`, CEF's `DownloadImage` as a favicon fetch:
the tab's cookies and profile, Chromium's cache), kept in the shared
`BrowserFaviconLoader` cache. Everything else goes through
`BrowserFaviconLoader`: http(s) only, no cookies sent or stored, 1 MiB body
cap, fetch and decode off the main thread, redrawn at most 64 px, cached
per profile (64 per profile in the loader, 256 `TabImage`s in the store).
Nothing polls: a strip snapshot that reads a missing icon starts one fetch
and re-renders when it lands.

The same icons show wherever a page is named: the tab strip, the sidebar's
workspace rows and tab rows, Search Tabs, the bookmarks bar and its menus,
and the New Tab location bar's open-tab and recent-page rows (sent to the
page as inline PNGs; its CSP allows `img-src data:` only). A bookmark or a
recent page shows its site's icon: an open tab's on the same origin, else
the origin's `/favicon.ico`.

Not done: agent program icons on terminal tabs; a New Tab row whose icon
lands after the page opened keeps its glyph until the next New Tab.

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
