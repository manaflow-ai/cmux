# Overlay host (R84, R126): app overlays above Chromium pages

Each Chromium page is a child window of the main window, and the CEF fork
re-adds it above every other child window each time it shows. Anything in the
main window's view tree, and any app child window shown before such a re-add,
is then below the page.

`WindowOverlayHost` (CmuxNextDesign/Overlay, landed e3a477291c8) keeps one
transparent child panel per main window above every page window and holds the
named layers, bottom to top: content (page windows) < pane chrome < `.pane`
overlays < the sidebar (an occluder) < `.window` overlays < `.modal` overlays.
`ChildWindowPolicy` records every child window of a main window that is not the
host panel, a page window or a presenter still listed for migration.

## Presenter inventory

| Presenter | Where | Today | Target |
| --- | --- | --- | --- |
| Which-key | CmuxNextApp/Focus/WhichKey/WhichKeyOverlay.swift | on the host (`.window`, toast at the bottom center) | done |
| Focus ring, inactive dim, drop zones | CmuxNextApp/Windows/WindowOverlayLayer.swift | planes on the host panel | done |
| Sidebar | CmuxNextApp/WindowRootView.swift | occluder of the host (`setOccluder`) | done |
| Hover cards (tabs, workspaces) | CmuxNextDesign/HoverCards/HoverCardPanel.swift | own child panel, reordered above pages by the host | `.window` presentation |
| Palette | CmuxNextPalette/PaletteController.swift | own key child panel | `.window` presentation that takes the keyboard |
| Omnibox suggestions | CmuxNextBrowser/UI/OmniboxSuggestionPanel.swift | on the host (`.pane`, `.attached` under the bar) | done |
| Page info | CmuxNextBrowser/PageInfo/UI/PageInfoController.swift | own key child panel | `.window` popover |
| Tab group editor | CmuxNextTabs/Groups/Editor/TabGroupEditorPanel.swift | own key child panel | `.window` popover |
| Appearance studio | removed (R82 commit 6: Customize Appearance opens Settings > Appearance) | none | none |
| Feed panel | CmuxNextApp/Feed/FeedPanelController.swift | own child panel | `.window` popover |
| Notifications panel | CmuxNextApp/Notifications/Panel/NotificationsPanelController.swift | own child panel | `.window` popover |
| Restart notice | CmuxNextApp/Crash/RestartNoticePanel.swift (plain NSPanel) | own child panel | `.window` toast |
| Browser popup panels | CmuxNextApp/Popups/BrowserPopupPanels.swift | own child panel holding a page | stays a child window (it is a page) |
| Divider catchers | CmuxNextApp/Windows/DividerMouseCatchers.swift | click-catching child panels | stay (they forward the mouse, inactive under a blocking overlay) |
| Alerts, sheets, dialogs | Quit, destructive confirmation, rename, CLI install, updater | NSAlert sheets and windows | R96 dialogs lead: CmuxDialog on the host |
| Tooltips | AppKit `toolTip` (47 sites), SwiftUI `.help` (36 sites) | system tooltip windows | a host tooltip where a tooltip can overlap a page, after a live check shows the system tooltip below a page |
| Tab drag ghosts, refusal HUD | CmuxNextApp/Drag | in the window's view tree | `.window` dragGhost (tab-dnd lead's known issue) |

## Open checks

- Live proof on cmux-lawrence-2 with a loaded CEF page: tooltip, alert,
  palette and which-key visible above the page, and a click forwarded by the
  panel completes in the page (down, drag, up through the window server).
- The system tooltip: whether its window is ever below a page window.
