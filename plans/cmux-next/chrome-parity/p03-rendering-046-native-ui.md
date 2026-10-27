# p03-rendering-046: Chromium native UI on the attached view

Track B (tasks 044, 045) makes the page's `RenderWidgetHostViewCocoa` a subview of the pane's `CEFHostView`,
and the page window never orders in. This task sorts every kind of Chromium native UI by where it shows then,
from the Chromium code that shows it on macOS, and gives each kind a check.

The table is code: `CEFNativeWidget` (`CmuxNextBrowser/CEF/CEFNativeWidget.swift`) has the route, the Chromium
source and the row of `scripts/cmux-next/cef-native-ui-live.py` for each kind. `CEFNativeWidgetTests` keeps the
table and the fallback state machine honest.

| Kind | Expected route (from source, not yet observed) | Chromium source | Check (row) |
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
## Per-widget fallback (app side only; the fork side is not written)

Chrome hangs autofill and print preview on the Browser's `views::Widget`, which is the page window in cmux. A
widget whose parent window is not on screen does not show over the page. The planned fallback: while such a widget
is open, the fork orders the page window in over the host view and reports it. The app side is on this branch; no
fork sends the event yet, so **the fallback is not implemented**, and autofill and print preview are expected to
fail on a Track B build until the fork side lands.

App side (`CEFPageWindowWidgets`, in `ChildWindowPageFallback.swift` with the rest of the child-window path):

- The tab event `CMUX_TAB_EVENT_PAGE_WINDOW_WIDGET = 14` (`CEFForkTabEvent.pageWindowWidget`), `a` = the Chromium
  window id, `value = kind << 1 | shown`, where `kind` is the `CEFNativeWidget` raw value (2 autofill, 5 print
  preview, 12 another page-window widget; a newer fork's kind is kept raw, so two unknown kinds stay two widgets).
- The state is per Chromium window, as the fork orders in a window, not a tab: a show goes to the host that owns
  the reported window (`CEFPaneHost.owns(window:)`, as `sidePanelChanged` does). A popup tab adopted by its own
  host stays in its opener's window while `awaitsWindowMove` is true, and a widget it opens then orders in the
  opener's page window over the opener's host view. A close goes to every host; only the holder changes.
- While one is open, that host counts as child-window content (pane motion moves it by frames, not by render-server
  transforms a child window cannot follow), and the fork is told at once to place the window over the host.
- Each show is counted in `debug.cef` `tracker.page_window_widget_shows` and `page_window_widget_shows_by_kind`,
  the one expected exception to DC8b's "page windows ordered in = 0".

Fork side (a follow-up fork change at the next free API, max + 1 of the fork lines then, above 044's 36;
044's spec says the page window never orders in and does not cover it):

- `libcef/browser/chrome/views/chrome_child_window_mac.mm`: when a widget of these kinds becomes a child of the
  Browser's widget (`Widget::AddChild` / `NativeWidgetMac::ReparentNativeView`), order the page window in,
  transparent, at the host view's frame, and send event 14 with `shown`; when the last one closes
  (`WidgetObserver::OnWidgetDestroying`), order it out and send event 14 without `shown`.
- The ordered-in page window sets `ignoresMouseEvents = YES`. Its child widget window (the dropdown, the dialog)
  is its own `NSWindow` and still takes its clicks. Without this, a click on the page while an autofill
  dropdown is open (another field, or a click that dismisses the dropdown) goes to the page window, not to the
  attached `RenderWidgetHostViewCocoa`.
- `cef_cmux.h` declares `CMUX_TAB_EVENT_PAGE_WINDOW_WIDGET` behind its fork API version; the app gates nothing on
  it, because an older fork never sends it.

The real fix, which removes the fallback, is the fork parenting those widgets to the attached view's window, as
Chrome's remote_cocoa `NativeWidgetNSWindowBridge` (`components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm`)
parents a child widget to its parent's `NSWindow`.

## Status

**Open. Task 046 is not done.** No row has run. The routes in `CEFNativeWidget.route` come from reading the
Chromium source; no fleet run has checked them. The acceptance needs, on a fleet build that has 044 and 045:

1. `cef-native-ui-live.py --app ... --tag ... --out OUT` with a person at the host for `file-drop-in` (it waits
   for the drop and fails on timeout).
2. A person looks at `OUT/native-ui-context-menu.png` and `OUT/native-ui-cursor.png`, then runs
   `cef-native-ui-live.py --confirm OUT/native-ui.json --rows context-menu,cursor`. A capture row stays
   `pending-review` (and the run fails) until that confirm.
3. Attach `native-ui.json` and the PNGs here. Set `CEFNativeWidget.route` (and its test) from the observed
   `observed_route` of each row; a failed row gets a fork fix or a per-widget fallback, which needs the fork side
   above.
