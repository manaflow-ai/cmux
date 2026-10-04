# CEF fork cmux.18 candidates

The single list of fork changes for the release after cmux.17 of
manaflow-ai/cef. cmux.17 carries ONLY the build without DCHECKs (fork PR 8:
web content could abort the embedder through a failed DCHECK); everything
below moved to cmux.18 (coordinator, 2026-10-04). The browser lead keeps it; each
entry names the export, why the app needs it, and the app fallback until it
ships. Nothing here is built yet.

| # | Export (fork API) | Why | App fallback until it ships |
| --- | --- | --- | --- |
| 1 | `cmux_window_set_overlay_anchor(void* window)` (18) | The fork's parent tracker re-adds each page window with `addChildWindow:ordered:NSWindowAbove` on every show or re-parent, so a page can cover the app's overlay panel for one frame. With an anchor, the fork orders the page directly below the anchor window instead of above everything. | `WindowOverlayHost` re-asserts the overlay panel's order on every child add (`ShellWindow.addChildWindow`) and on every window update while it shows (R84). |
| 2 | skip-beforeunload close (18) | Closing a tab or window whose page has a `beforeunload` handler must be able to skip the prompt when the person already confirmed in cmux (quit, close workspace). | The app shows its own confirmation and then closes normally; the page may still prompt. |
| 3 | P6 `int cmux_tab_set_extension_access(int browser_id, int allowed)` (18) | Block extension content scripts, programmatic injection, messaging, extension subframes, `debugger.attach` and `captureVisibleTab` for agent-driven tabs. Design: passwords.md section 3.4.1. | Interim refusal: the app and the browser host refuse agent calls on a tab whose profile has an enabled extension with access to the page, unless the person allowed agents in that tab (`tab.access`, reason `extension_host_access`). |

| 4 | Debug symbols (`symbol_level=1`, dsymutil in packaging) | Symbolicated CEF frames in crash reports (cmux.17 still builds with `symbol_level=0`). | Symbol names from exports only. |
| 5 | Linux and Windows builds without DCHECKs | The same abort risk as macOS cmux.16 if those builds ship. | Not shipped yet. |

Not needed in the fork:

- Hard reload (reload ignoring the cache): the shim calls `CefBrowser::ReloadIgnoreCache()` directly, the same way `cmux_shim_reload` calls `Reload()`.
