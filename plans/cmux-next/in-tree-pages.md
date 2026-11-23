# In-tree Chromium pages

Status: behind a switch, off by default. Needs the cmux CEF fork's in-tree API (`cmux_cef_api_version() >= 36`,
manaflow-ai/cef `cmux/in-tree-pages`, `include/cef_cmux.h` "In-tree pages").

## What it is

Today a Chromium page is a child `NSWindow` of the cmux window (CmuxParentViewTracker), optionally drawn into the
window's layers by layer hosting (API 26), with resize sync (API 27), detached hosting (API 30) and the resize fence
(API 32/34). Overlays then need their own window above the pages (`OverlayHostPanel`), dividers need catcher panels
above the pages (`DividerMouseCatchers`), and focus moves between the cmux window and each page window.

In the in-tree mode the page's own view (`WebContentsViewCocoa` with Chromium's `RenderWidgetHostViewCocoa` inside) is
a subview of its pane (`CEFHostView` -> `CEFInTreePageView`) in the cmux window. The Chrome widget window stays
headless and its compositor is stopped. So:

1. **Pages.** `CEFInTreeHosting` calls `cmux_browser_set_in_tree_hosting(browser, container)` at the end of the
   run-loop turn after the page window exists, retries once at the next show, and after a second refusal hands the page
   back to layer hosting (`fellBack`; that tab's presentation is `.childWindow` again). The current content view is
   re-read each time with `cmux_browser_in_tree_content_view` (it changes with the renderer).
2. **Overlays.** `WindowOverlayHost` keeps every presenter's API. With the mode on its root
   (`OverlayHostPanel.root`, an `OverlayRootView`: planes, pane, window and modal containers) moves onto the top of the
   main window's content view (`WindowOverlayHost+InWindow.swift`). The mouse goes by AppKit's own hit test: the root
   answers only where an overlay takes the mouse (`acceptsMouse`). No mouse monitor, no `ignoresMouseEvents` switching,
   no `takeEventFromBelow`. A modal overlay takes the window's first responder through the window's gate; Tab cycles in
   it (`ShellWindow.selectNextKeyView`), its key equivalents go only to it (`ShellWindow.performKeyEquivalent`), Escape
   goes to it (`routeInWindowModalEscape`).
3. **Dividers.** `WindowOverlayLayer`'s placement follows the real windows: with no page child window on screen it is
   `.inWindow` and the catchers stay inactive. A page window that still shows (a page the fork refused twice) is
   served as with the mode off: the planes and the presented overlays go to the panel above it
   (`WindowOverlayHost.servesPageWindows` turns `usesWindowBackend` off for that window), the catchers turn on, and
   the window is counted once (`in_tree_guards.divider_catchers`) and named in `debug.layers`
   `retired_page_windows`. A scroll on a divider's grab strip goes to the pane on the pointer's side of the line
   (`DividerHandleView+Scroll.swift`).
4. **Focus.** The cmux window is always key. `ShellWindow.makeFirstResponder` adds one rule
   (`ShellWindow+InTreePages.swift`, `InTreePageFocus`). A view that is, or is inside, an `InTreePageContainer` may
   become first responder only:
   - while the window dispatches the person's input event aimed at that page (a press whose hit view is in the page,
     or a key while the page already holds the keys);
   - while the focus model applies a move to the page's pane (`focus.isApplying`);
   - in a routed move (`FocusRoute`, `routeInFlight`) naming that view;
   - inside cmux's own grant (`CEFInTreeHosting.grantFocus`, the browser's `SetFocus` call).

   Anything else (Chromium restoring focus, `window.focus()`, a tab activation) is refused and logged in the focus log
   like every refused move. Page views are found by container ancestry, never by class name.
5. **Frames.** A resized in-tree page joins the window's resize fence (`CEFResizeFences`, `cmux_browser_resize_fence`)
   with a deadline of about one display frame (`max(8 ms, refresh)`). On a miss the container shows the last frame
   pinned top-left and clipped (`contentsGravity = .topLeft`, `masksToBounds`).
6. **Keys.** Reserved shortcuts are decided in the window's `sendEvent` before the page sees them, as today. Chromium
   does not hand back an unhandled key equivalent in this mode, so `CEFRuntime.routeUnhandledKey` gives it to the main
   menu after the held-shortcut path; never through the window's `performKeyEquivalent` (that would loop to the page).
7. **Prompts.** Permission prompts, file choosers, downloads, passwords, extension prompts and JS dialogs anchor to
   the tab's `contentView` (in the cmux window in both modes), and cmux's CEF handlers take every one, so the fork's
   "page is invisible, cancel unless a handler takes it" rule does not drop them.

## The switch

`browser.inTreePages` (Debug Settings, section "Chromium In-Tree Pages"), `InTreePages`. Decided once at launch,
before the first window:

1. `CMUX_IN_TREE_PAGES=1|0` in the environment (benches and harnesses);
2. else `browser.inTreePages` in the build's `debug-tunables.json`;
3. else on for a dev build whose tag starts with `in-tree-pages`;
4. else off.

Release and RC builds read no file: only the environment variable can turn it on. At CEF ready the engine is checked
(`CEFInTreeCalls.support`): without the three shim symbols or with a fork API below 36 the mode turns off
(`unsupported_fork: ...` in `debug.cef in_tree`), pages stay child windows and overlays go back to the panel
(`InTreePages.activeDidChange`).

With the switch off every changed path takes today's branch: no in-tree call is made, overlays use the panel, the
divider catchers and cross-window guards run as before.

## Defaults chosen (Aziz asleep, 2026-11-18)

- Off everywhere except dev builds tagged `in-tree-pages...`, where it is on unless the file says false. The tag
  default makes the dogfood build show the mode without a settings step; OFF vs IN on that build is one file value or
  `CMUX_IN_TREE_PAGES=0` plus a relaunch.
- Applies at the next launch only: one process never mixes child-window and in-tree pages.
- The fence deadline is `max(8 ms, one refresh interval)`, overridable with the existing resize-fence timeout override.
- Two refusals by the fork fall back to layer hosting for that page only.

## What the mode deletes or bypasses

| Path | With the mode on |
| --- | --- |
| Page child window (CmuxParentViewTracker frame sync) | headless, never on screen; the page view is in the pane |
| Layer hosting (API 26), detached hosting (API 30), resize sync (API 27) | not started for in-tree pages (`layerHosting` gets no fork) |
| `OverlayHostPanel` ordering, `reassertOrder`, `overlayWindow` placement | not used; overlays are views on the window |
| `takeEventFromBelow`, the overlay mouse monitor, `ignoresMouseEvents` routing | bypassed (counted if reached) |
| Modal `makeKey` of the panel, escape monitor | the window keeps key; first responder moves through the gate |
| `DividerMouseCatchers` panels | inactive while no page window shows; a page window that shows is served and counted |
| `ChildPageFocus` (page window key switching) | not called for `.inTree` pages (counted if reached) |
| `CrossWindowInputGuard` | bypassed; would-drop counted |
| `UnseenKeyboardGuard` page-window branch | never expected; counted if it fires for a view in a child window |

The code of every row is kept for the switch off.

## Census

- `debug.cef`: `in_tree` (`off`, `pending`, `on`, `unsupported_fork: <why>`), `tracker.in_tree_attaches`,
  `tracker.in_tree_refused`.
- `debug.layers` per window: `in_tree`, `page_views` (pane, `parked`, `parking`, frame, `rwhv_in_window`,
  `widget_drawing`; a view in no shown pane is parked by design and `parking` says where: `offscreen_parking` (the New
  Tab spare and other prewarmed or retiring pages, 100 000 pt off the content), `reserved_workspace` (the next Cmd-N's
  workspace, prewarmed off the content), `parked_workspace` (a recent workspace kept mounted, hidden), `hidden` (a
  background tab); `unplaced` is a defect), `retired_page_windows` (page child windows that showed; must stay empty),
  `widget_drawing` (pages whose headless widget still draws; must be 0); per browser `presentation: "in_tree"`,
  `rwhv_in_window`, `widget_drawing`. With the mode on `reorders` and `divider_catcher_updates` stay flat and
  `child_window_violations` stays empty.
- `debug.focus.in_tree`: `status`, `gate_allowed`, `gate_refused`, `gate_last_refusal`, `in_tree_guards`
  (`child_page_focus`, `cross_window_input`, `unseen_keyboard_page_window`, `take_event_from_below`,
  `divider_catchers`; each must stay 0).

## Harnesses

`cef-layer-verify.py --mode intree`, `cef-layer-ab.py --modes off,intree`, `cef-resize-sync-bench.py --modes
off,intree`, `overlay-live-check.py --in-tree on|off`, `split-resize-bench.py --in-tree on|off`. Each sets the switch
through `CMUX_IN_TREE_PAGES` (and the tunables file where it writes one), reads `debug.cef in_tree` back, refuses a
run whose app reports another mode, and records both in its JSON (`scripts/cmux-next/in_tree_mode.py`).

## Tests

- `CmuxNextDesignTests/InTreeOverlayTests`: dialogs and toasts on the window with no panel, the window's own hit test
  reaching every card control, a dimming dialog taking every click, the pane taking clicks beside a toast, nothing
  taken from below, the modal taking the window's first responder, the mode off keeping the panel.
- `CmuxNextDesignTests/InTreePageFocusTests`: the focus rule with a fake page (refuse self-focus, allow click, route,
  focus-model and grant), container ancestry, the switch's precedence, an engine without the calls.
- `CmuxNextAppTests/DividerHandleScrollTests`: a scroll on the strip reaches the pane on the pointer's side; mode off
  unchanged.
