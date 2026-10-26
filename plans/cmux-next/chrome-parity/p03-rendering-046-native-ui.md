# p03-rendering-046: Chromium native UI on the attached view

Track B (tasks 044, 045) makes the page's `RenderWidgetHostViewCocoa` a subview of the pane's `CEFHostView`,
and the page window never orders in. This task sorts every kind of Chromium native UI by where it shows then,
from the Chromium code that shows it on macOS, and gives each kind a check.

The table is code: `CEFNativeWidget` (`CmuxNextBrowser/CEF/CEFNativeWidget.swift`) has the route, the Chromium
source and the row of `scripts/cmux-next/cef-native-ui-live.py` for each kind. `CEFNativeWidgetTests` keeps the
table and the fallback state machine honest.

| Kind | Route | Chromium source | Check (row) |
| --- | --- | --- | --- |
| `<select>` popup | Chromium's view | `content/app_shim_remote_cocoa/web_menu_runner_mac.mm` | `select`: Down, Return change the value |
| Context menu | host (cmux menu) | `chrome/browser/ui/cocoa/renderer_context_menu/render_view_context_menu_mac_cocoa.mm` | `context-menu`: event + capture (manual) |
| Autofill, password, `<datalist>` | page window (fallback) | `chrome/browser/ui/views/autofill/popup/popup_view_views.cc` | `autofill`: the dropdown fills the input |
| Color picker | Chromium's view | `components/remote_cocoa/app_shim/color_panel_bridge.mm` | `color-picker`: NSColorPanel shows |
| Date and time pickers | Chromium's view | `content/app_shim_remote_cocoa/popup_window_mac.mm` | `date-picker`: a popup window shows |
| Print preview | page window (fallback) | `chrome/browser/ui/views/constrained_window_views.cc` | `print-preview`: a window or page-window widget shows |
| IME (Japanese, Korean, dead keys, emoji) | Chromium's view | `content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm` | `ime`: Option-E E gives "é" with compositionstart |
| File drop in | host (`CEFFileDragRelay`) | `content/app_shim_remote_cocoa/web_drag_dest_mac.mm` | `file-drop-in`: Finder drag (manual) |
| Link drag out | Chromium's view | `content/app_shim_remote_cocoa/web_contents_view_cocoa.mm` | `link-drag-out`: dragstart and dragend |
| Accessibility | Chromium's view | `content/browser/accessibility/browser_accessibility_cocoa.mm` | `accessibility`: `ax-tour.sh --dump` finds the page's button |
| Tooltips | Chromium's view | `render_widget_host_view_cocoa.mm` (`setToolTipAtMousePoint:`) | `tooltip`: a tooltip window shows |
| Cursor | Chromium's view | `render_widget_host_view_cocoa.mm` (`updateCursor:`) | `cursor`: capture with the cursor (manual) |

## Per-widget fallback

Chrome hangs autofill and print preview on the Browser's `views::Widget`, which is the page window in cmux. A
widget whose parent window is not on screen does not show over the page, so for those widgets the fork orders the page window in,
transparent and over the host view, while the widget is open; the page's pixels and input stay in the attached
view. The fork reports it with the tab event `CMUX_TAB_EVENT_PAGE_WINDOW_WIDGET = 14` (`CEFForkTabEvent.pageWindowWidget`):
`value = kind << 1 | shown`, where `kind` is the `CEFNativeWidget` raw value (2 autofill, 5 print preview, 12
another page-window widget). The app keeps the open widgets per host view (`CEFPageWindowWidgets`, in
`ChildWindowPageFallback.swift` with the rest of the child-window path); while one is open, the host view counts as
child-window content (pane motion moves it by frames) and the fork is told to place the window at once. Each show
is counted in `debug.cef` `tracker.page_window_widget_shows`, the one expected exception to DC8b's "page windows
ordered in = 0".

The fork side of the event (`chrome_child_window_mac.mm`: order in on `Widget::AddChild` of a widget of these
kinds, order out on its close) belongs to the fork change of task 044. The real fix, which removes the fallback,
is the fork parenting those widgets to the attached view's window, as Chrome's remote_cocoa
`NativeWidgetNSWindowBridge` parents them to the browser window.

## Status

Not run yet: the fork's attach API (044) and the app's adoption (045) are not on `perf/chrome-parity`. Run
`cef-native-ui-live.py` on the fleet build that has them; a row that fails moves its kind to `.pageWindow` in
`CEFNativeWidget.route` (with the fork reporting it) or gets a fork fix.
