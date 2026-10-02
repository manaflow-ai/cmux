# Browser chrome

A browser pane has a toolbar under its tab strip: back, forward, reload, the omnibar (page-info chip, URL, bookmark star), and the extensions button. Helium's geometry, the terminal theme's colors. Sources: `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/UI/` at `1824883286a`. JSON key `components["browser.toolbar"]`.

![Browser pane next to a terminal, dark](../images/window/dark-browser.png)

![Toolbar, dark, idle](../images/browser/dark-toolbar.png)
![Toolbar, light, idle](../images/browser/light-toolbar.png)

## Geometry (`OmnibarStyle.swift:15-70`)

Bar height 24 compact / 28 comfortable; toolbar height bar + 6 (padding 3). Buttons bar-height square, radius 8, symbol 13/15, no spacing. Omnibar radius 8, chip bar-4 radius 6 at 2, text at 5, trailing padding 8, icons 12/13, font system 13/14. Editing ring 1.5. Suggestion card radius 12, outset 3 top and 6 sides, rows bar height, inset 4, gap 2, radius 8. Progress line 2 pt.

## States

| element | state | token | source |
|---|---|---|---|
| toolbar | | windowBackground | OmnibarStyle.swift:79 |
| omnibar | idle | chromeBackground fill | :80, OmnibarViews.swift:50 |
| omnibar | hover | elevatedBackground | :81 |
| omnibar | editing | elevatedBackground, 1.5 pt focusRing ring, text selection textSelection | OmnibarViews.swift:46-54 |
| omnibar | popup open | elevatedBackground card, selected row selectionFill | OmniboxSuggestionPanel.swift:167 |
| URL text | idle | host textPrimary, rest textSecondary | AddressField.swift:105-112 |
| button | default | clear, tint textPrimary | ChromeButtons.swift:124-134 |
| button | hover | hoverFill | :129 |
| button | pressed | selectionFill | :127 |
| button | disabled | clear, whole button opacity 0.35 | :68 |
| chip / star | hover | hoverFill | OmnibarStyle.swift:87 |
| loading | | progress line alpha(focusRing, 0.8) | ProgressLineView.swift:61 |
| find bar, prompt bar | | overlay material, radius panelCornerRadius, padding 8, height tabStripHeight | BrowserMetrics.swift:28-35 |

![Omnibar hover, dark](../images/browser/dark-omnibar-hover.png)
![Omnibar hover, light](../images/browser/light-omnibar-hover.png)
![Reload hover](../images/browser/dark-reload-hover.png)
![Bookmark star hover](../images/browser/dark-star-hover.png)
![Omnibar editing: focus ring](../images/browser/dark-omnibar-editing.png)
![Omnibar editing with the suggestion card](../images/browser/dark-omnibar-editing-popup.png)

UNVERIFIED: pressed buttons (tracking loop, as in tabs), loading progress, find bar, load error page, extension toolbar. Tokens above are from code.

![Browser pane, light](../images/window/light-browser.png)
