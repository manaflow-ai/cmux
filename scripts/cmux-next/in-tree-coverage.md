# In-tree pages: coverage matrix

Every browser path of in-tree Chromium pages (`CMUX_IN_TREE_PAGES`, PR manaflow-ai/cmux#47146) and the tab, pane and
window paths next to it, each with the automated live row that checks it, or **MISSING** with the reason it cannot run
headlessly on a fleet display worker yet. Bugs found in real use and their rows are in
[in-tree-regressions.md](in-tree-regressions.md); this file is the whole surface.

Sources of rows (all run by `scripts/measure/split-spring.sh --suite=in-tree-verify --parts=...`, never on a laptop):

| Short | Script | Part(s) |
| --- | --- | --- |
| `live` | `in-tree-live-checks.py` | `live-on`, `live-off`, `regressions` |
| `cef` | `cef-layer-verify.py` (CuaDriver real input) | `cef-intree`, `cef-off` |
| `cov` | `in-tree-coverage-checks.py` (this matrix's new rows; site `in-tree-coverage-site/`) | `coverage-on`, `coverage-off` |
| `perm` | `permission-prompts-live.py` | `prompts` |
| `ovl` | `overlay-live-check.py` | `overlay-on`, `overlay-off` |
| `pkg` | Swift package suites (`run-swift-testing-suites.sh`) | light step |
| `fork` | `cmux_embedder_test` cases (`scripts/measure/cef-embedder.sh`) | fork step |

Every `cov` row also runs with the switch off (`coverage-off`), so the `CMUX_IN_TREE_PAGES=0` column is the same row
name in the other part. A row that needs a window-point mouse event (hover, right click, double click, drag, wheel)
says INFO with the switch off: `debug.mouse` window points reach the cmux window, never an OFF page's child window.

## Browser

| Path | Row(s) | OFF parity | Notes |
| --- | --- | --- | --- |
| Navigation: back/forward by action | `cov` `nav.back_action`, `nav.forward_action` | `coverage-off` same rows | |
| Navigation: back/forward by keys (Cmd-[ / Cmd-]) | `cov` `nav.back_key`, `nav.forward_key` | same | real keys (`debug.key sequence`) after a page click |
| Navigation: two-finger swipe | `cov` `nav.swipe_back` | INFO off | synthetic phased scroll; history swipe needs `trackSwipeEvent` from a real gesture, so a FAIL in both modes is the rig |
| Reload (action, Cmd-R) | `cov` `reload.action`, `reload.key` | same | sessionStorage load count |
| Stop | `cov` `stop.action` | same | `/slow` held 10 s by the server |
| Omnibar typing and commit | `cov` `omnibar.commit`; `live` `omnibar_narrow.*` (bug 15, layout) | same | `debug.omnibar_type` (field editor path, not raw keys) |
| Omnibar suggestions | `cov` `omnibar.suggestions` | same | |
| Find in page | `cov` `find.key` | same | real Cmd-F; typed text through `debug.key` to the find field |
| Page zoom Cmd-= / Cmd-- / Cmd-0 | `cov` `zoom.keys`, `zoom.actions` | same | the sweep's real-key zoom (key names) is replaced by key codes |
| Ctrl-wheel zoom | `cov` `zoom.ctrl_wheel` (the wheel reaches the page with ctrlKey) | INFO off | |
| Pinch zoom | **MISSING** | | `debug.mouse` synthesizes no magnify (gesture) events; needs a `magnify` action in `DebugMouse` |
| Text selection (double click, drag) | `cov` `select.double_click`, `select.drag` | INFO off | |
| Copy / paste with real keys | `cov` `clipboard.copy_key`, `clipboard.paste_key` | same | the worker's pasteboard (`pbcopy`/`pbpaste`) |
| Drag and drop: inside the page (HTML5, text) | `cov` `dnd.html5`; `cef` `drag` (pointer events) | INFO off | Chromium starts an AppKit drag session that follows the real pointer: dragstart without drop in both modes is the rig |
| Drag and drop: files into the page, links out | **MISSING** | | needs a WindowServer drag from or to another app (Finder) with a real pointer |
| Context menu (text, link) | `cov` `context_menu.text`, `context_menu.link`, `context_menu.devtools`; `cef` `context` | `context_menu.devtools` both modes | `debug.menu` reads the menu |
| JS dialogs alert / confirm / prompt | `cov` `dialog.alert`, `dialog.confirm_ok`, `dialog.confirm_cancel`, `dialog.prompt_text`, `dialog.prompt_cancel`; `live` `prompts.alert`/`confirm`/`prompt` (shown); `pkg` `InTreePromptKeyboardTests` (bug 5) | same | answers reach the page |
| beforeunload | `cov` `dialog.beforeunload_stay`, `dialog.beforeunload_leave` | same | |
| File chooser: open | `live` `prompts.file`, `prompts.file_after_popup.*` (bug 4); `fork` `intree157-filechooser`, `-small` (bug 3) | `live-off` | |
| File chooser: multiple, directory, save | `cov` `chooser.multiple`, `chooser.directory`, `chooser.save`, `chooser.upload_multiple` | same | |
| Downloads | `cov` `download.link`, `download.blob` (bytes checked); `live` `prompts.download` (shown) | same | `CMUX_NEXT_DOWNLOADS_DIR` in the step's folder |
| Pop-ups: open, draw, click | `cef` `popup.hosted`, `popup.pixels`, `popup.click`; `fork` `intree157-popup`, `-popup-opener` (bugs 1, 2) | `cef-off` | |
| Pop-ups: size and float | `live` `popup_float.windowed`, `.opener_fullscreen` (bugs 10, 16); `pkg` `BrowserPopupWindowTests` | | |
| Pop-ups: close (by opener, by itself), target=_blank | `cov` `popup.close_opener`, `popup.close_self`, `popup.blank_link_tab` | same | |
| DevTools: draws, first click | `cef` `devtools.pixels`, `devtools.first_click`, `devtools.click` (bugs 1, 6); `fork` `intree157-devtools*` | `cef-off` | |
| DevTools: dock bottom / right / undock / close | `cov` `devtools.dock_bottom`, `devtools.dock_right`, `devtools.undock`, `devtools.close` | same | frames from `debug.cef devtools` |
| DevTools over hide/show | `live` `reveal.hide_devtools.*` (bug 9) | | |
| Permissions: geolocation, notifications | `perm` (Chromium rows) | `perm` runs with the switch on only | |
| Permissions: camera, microphone | `cov` `permission.camera`, `permission.microphone` | same | Block only: Allow raises the host's macOS prompt |
| HTTP auth | `cov` `http_auth.cancel`, `http_auth.sign_in` | same | |
| Cursors and hover | `cov` `hover.link`, `hover.box`, `hover.text`, `hover.leave` (mouseover, `:hover`, `debug.cursor`) | INFO off | by hand: `try-layouts/site/pointer-bench.html` |
| Pointer lock | `cov` `pointer_lock.enter`, `pointer_lock.exit_escape` | same | |
| Scrolling: wheel | `live` `pane_fit.viewport` (bug 13); `cef` `scroll`; `cov` `scroll.page` | INFO off | |
| Scrolling: nested scrollers | `cov` `scroll.nested` | INFO off | |
| Scrolling: momentum | **MISSING** | | `NSEvent.syntheticScroll` sets no `momentumPhase`; needs a `momentum` field in `debug.mouse scroll` |
| Video playback | `cov` `video.stream`, `video.webm_decode` | same | a canvas stream and a MediaRecorder WebM, no network |
| Element full screen (video and div), window key | `live` `element_fullscreen.*` (bug 24) | `live-off` | |
| IME composition | `cov` `ime.renderer` (DevTools `Input.imeSetComposition`) | same | **MISSING** for the AppKit route: no debug hook calls `setMarkedText` on the page's view (`NSTextInputClient`); needs a `debug.ime` method |
| VoiceOver / accessibility tree reaches the page | `cov` `ax.page_tree` (CuaDriver tree has the page's labelled button and heading) | same | VoiceOver speech itself: **MISSING** (needs a person or VoiceOver running on the worker) |
| Renderer crash: sad tab, reload | `cov` `crash.sad_tab`, `crash.reload` | same | SIGKILL of the page's renderer pid from `renderers.list` |
| Memory: 50 tabs opened and closed | `cov` `memory50.open`, `memory50.closed` | same | footprint, family RSS, renderer helpers |
| Page layout fit, clicks land, viewport | `live` `pane_fit.*` (bug 13) | | |
| Census: no page windows, no overlay panel | `live` `census`; `ovl` | `live-off`, `overlay-off` | |
| Two pages side by side, input to each | `live` `two_pages.*` | | |
| Select popups (`<select>`) | `cef` `select` | `cef-off` | |

## Tabs, panes, windows next to the browser

| Path | Row(s) | OFF parity | Notes |
| --- | --- | --- | --- |
| Window full screen enter / exit | `live` `fullscreen.*` (bug 12), `live_resize.fullscreen.*` (bug 17) | | |
| Pane split | `live` `key_route.split` (bug 23), `cov` `shortcut.cmd+d`, `shortcut.cmd+shift+d` | | |
| Pane close with a page | `cov` `pane_close.page` | same | |
| Pane zoom | `live` `pane_zoom.*` (bug 14), `key_route.zoom`/`unzoom`; `cov` `shortcut.cmd+shift+return` | | |
| Pane resize, divider drag | `live` `divider_resize.*` (bug 11), `live_resize.divider.pixels` (bug 18) | | |
| Window edge resize | `live` `window_resize.*` (bug 11), `live_resize.window.pixels` (bug 19) | | |
| Tab create / close / spam | `live` `shortcuts.cmd_t`, `shortcuts.cmd_w`, `tab_spam` (bug 22); `cov` `shortcut.cmd+t` | | |
| Tab switch (action, Ctrl-Tab) | `cov` `tab_switch.behind`, `tab_switch.action`, `tab_switch.key` | same | |
| Tab drag between panes | `cov` `tab_move.drag_to_pane` (a `debug.mouse` drag on the strip) | same | |
| Tab to a new split / a new window | `cov` `tab_move.new_split`, `tab_move.new_window` | same | |
| Workspace switch | `live` `live_resize.switch.pixels` (bug 21); `cef` `show.again` | | |
| Window move (programmatic, Accessibility) | `cov` `window_move.programmatic`, `window_move.ax` (page view keeps its frame, `screenX` follows) | same | a title-bar drag stays **MISSING** (bug 20): `debug.mouse` cannot drag the title bar of a window that is not key |
| Window minimize / restore | `cov` `minimize.hidden`, `minimize.restore` | same | |
| App hide / show and the return flicker | `live` `reveal.hide.*`, `reveal.cover.*` (bug 9) | | |
| App switch to another app and back with activation | **MISSING** | | activating needs focus; `debug.page_reveal` and `debug.app_activation` are the no-focus stand-ins |
| Keyboard focus: click | `live` `two_pages.input`; `cov` `focus_route.click_real_key` | same | |
| Keyboard focus: Cmd-Opt-arrows | `cov` `focus_route.cmd_opt_arrow_in`, `focus_route.cmd_opt_arrow_out` | same | |
| Keyboard focus: tab switch, programmatic | `live` `key_route.*` (bug 23); `cov` `tab_switch.key` | | |
| Focus steal by the page | `live` `focus.marker` (C7) | `live-off` | |
| Every cmux shortcut with a page focused | `cov` `shortcut.*` (Cmd-T, Cmd-D, Cmd-Shift-D, Cmd-Shift-Return, Cmd-Shift-P, Cmd-L, Cmd-R, Cmd-=, Cmd-N, Cmd-Opt-I with effects; Cmd-Shift-], Ctrl-Tab, Cmd-1, Cmd-W by router dry run); `live` `shortcuts.*`, `key_route.*` | same | |
| `CMUX_IN_TREE_PAGES=0` parity | `coverage-off`, `live-off`, `cef-off`, `overlay-off` | | |

## What stays MISSING and why

- Pinch zoom and scroll momentum: `debug.mouse` makes no magnify events and no momentum phase.
- Files dragged into a page and links dragged out: a WindowServer drag between apps needs a real pointer.
- The AppKit IME route (`setMarkedText` on the page's view) and VoiceOver speech: no debug hook; the renderer's IME and the
  accessibility tree are checked.
- Window move by a title-bar drag (bug 20) and a real app switch with activation: both need the window key or the app
  active, which a no-focus run never makes.
