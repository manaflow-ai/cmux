# cmux NEXT: motion from first principles (container clock, content size, the frames between)

Status: design, 2026-11-10. No app code changes with this document. Curves and durations are Lawrence's pick in
Motion Lab; this document gives candidates and a recommendation, never a pick.

Lawrence, 2026-11-10: "we need to make all animations better, more fluid, more sensical, thinking about how the web
contents in chrome/webkit + how terminals TUI resizes timings vs expansion/movement of the container panes. think
from first principles and make it better, current one is not good enough."

His binding rules, which every section below obeys: match Chrome's smoothness in the whole app; no bounce in any
motion; terminals have zero lag on a resize; a page may lag but never shows outside its pane; 120 Hz; a pane close
gives the survivors their final grid once; no perf or motion switch (a motion lands on and the old path is
deleted); removals and defect fixes do not wait for a pick.

## The problem

A pane holds content that cmux does not draw: a program behind a PTY, a Chromium page, a WebKit page. Each of them
needs time to draw at a new size, and a program can only draw the size it was told last. Today the app animates the
pane's size on the main thread, lays the pane out again on every frame, and gives each content type its size by a
different rule in each motion. The result is the set of defects people see: frames that miss a refresh, a page that
moves or lags behind its pane, a TUI picture cut at a size it did not draw, a change that shows only at the landing.

The answer in one paragraph: a pane motion is not a resize animation. It is a transition between two pictures, the
one the content drew at the old size and the one it draws at the new size. The app tells the content its final size
once, in the turn of the input, and then moves only a position and a clip, on the display's clock, with no layout
per frame. The motion's length is the time the content has to draw; nothing changes at the landing.

## How to read the evidence

Nothing in this document was measured for it. No build or test can run where it was written.

- **[read]**: read in the code at `feat-cmux-next` `b7dfd714d4e1` by the author. `S/` means
  `Packages/macOS/CmuxNext/Sources/`.
- **[read, 2nd]**: read by a read-only helper agent at the same commit; the author checked the lines that the
  design depends on, not every line.
- **[measured by ...]**: a number another owner measured; the source is named. It was not measured again.
- **[source]**: fetched from the named upstream file. **[recalled]**: from memory, not checked against a source.

## 1. What the code does today

### 1.1 Clocks [read; the per-window list is read, 2nd]

- Each window has one `CADisplayLink` (`S/CmuxNextWakeups/FrameScheduler.swift:298-318`, range 80 to 120 Hz,
  120 preferred). `MotionClock` (`S/CmuxNextDesign/Motion/MotionClock.swift`) is one client of it; pane springs, the
  sidebar's width slide and the sidebar card slot step on it, on the main thread. The tab drag ghost has its own
  frame client on the ghost panel's scheduler (`S/CmuxNextApp/Drag/TabDragSession.swift:109`), also on main.
- The render server runs the tab strip's moves (additive `CABasicAnimation`, `S/CmuxNextTabs/TabMotion.swift`), the
  sidebar's row moves (additive `CASpringAnimation`, `S/CmuxNextSidebar/Views/SidebarDragSpring.swift`), the space
  page slide, and the fades of rings, dims, flashes, hover and overlays. No main-thread work per frame.
- AppKit's own timing runs a window live resize, the full screen transition and a window's open motion. A main
  window that a person opens uses AppKit's document-window zoom when movement animates; a restored one shows in
  place (`S/CmuxNextDesign/Motion/MotionGate+WindowOpen.swift`, `S/CmuxNextApp/Windows/WindowManager.swift:400`).
  Eight other windows and panels set their behaviour through the gate [read, 2nd]; 18 panels set `.none`.

### 1.2 Pane motion [read]

- A split, close, zoom, equalize, key resize and a divider release step `AnimatedFrame` springs per pane and per
  divider in `ScreenContentView.step` (`S/CmuxNextLayout/Views/ScreenContentView+Motion.swift`).
  `applyPresentation` sets each pane host's real frame on the device-pixel grid and calls
  `layoutSubtreeIfNeeded()` on every frame in which a size changed. There is no snapshot and no transform.
- Tokens (`S/CmuxNextDesignTokens/Motion/MotionTunables.swift`, response in seconds / damping): split 0.085 / 0.95,
  move 0.15 / 1, zoom 0.2 / 1, scroll 0.2 / 0.9, screen 0.2 / 0.9, settle 0.22 / 0.85, track 0.12 / 0.9,
  selection 0.15 / 0.9, panel 0.165 / 0.85, popover 0.24 / 0.86, pinDrag 0.215 / 0.8385, fallback 0.2 / 0.9.
  `MotionPolicy.spring` lifts only the structural tokens (move, appear, disappear, tabOpen) to damping 1 or more;
  `ui.animations.bounce` = `subtle` gives them a bounce of 0.15.
- A split, close or equalize of a terminal reports the final grid at the spring's start, which is the key's turn
  (a zoom's spring starts later, see below), and holds the surface at its final size,
  anchored top or bottom (`S/CmuxNextTerminal/TerminalSurfaceView+PaneMotion.swift`, `restAt`, `reportFinalGrid`,
  `holdSurface(size:anchor:)`).
- A zoom changes nothing in the key's turn: the handler only sends `zoom-pane`
  (`S/CmuxNextApp/Handlers/PaneHandlers.swift:268-272`) and the motion starts when the daemon's layout comes back.
  A swap is the same (`PaneHandlers+Verbs.swift:17-27`) and has no motion.
- A key resize is different from a split: the terminal host follows its pane on every frame, the surface takes the
  area it shows in on every frame, Ghostty's reflow preview is on, and the PTY gets a grid per refresh at most
  (`S/CmuxNextTerminal/TerminalHostView+PaneMotion.swift`, `PaneMotionHoldFollowing`).
- The program hold (keep the last frame until the program redraws, at most 3 refreshes) is on only for a key resize
  or a drag of a terminal on the alternate screen
  (`S/CmuxNextTerminal/TerminalSurfaceView+FrameOwner.swift:116-137`). A split, close or zoom has no program hold.
- Movement snaps in every window while any window is in a live resize or a full screen transition: `Motion`'s base
  policy reads the app-wide `LiveResizeWindows.shared.isActive` (`S/CmuxNextDesign/Motion/Motion.swift:58`).

### 1.3 Content hand-off today, per motion

| Motion | Terminal grid goes to the PTY | Terminal surface size | Chromium (CEF) page | WebKit page |
| --- | --- | --- | --- | --- |
| Split, close, equalize | once, at the spring's start, in the key's turn [read] | final size at the start, held [read] | laid out every frame; a page that holds the keys: once at its rest size [read] | every frame [read] |
| Zoom, unzoom | once, at the spring's start, which is after the daemon's answer [read] | final size at the spring's start, held [read] | as a split [read] | every frame [read] |
| Key resize | one per refresh at most [read] | every frame, reflow preview [read] | every frame [read] | every frame [read] |
| Divider drag | one per refresh at most; the newest at the release [read] | every frame [read] | page window detached unless it holds focus, attached again at the landing [read, 2nd] | every frame [read] |
| Sidebar show or hide | once, at the END of the slide [read] | every frame [read] | every frame [read] | every frame [read] |
| Window live resize | after each committed size [inferred by the helper, not confirmed] | every size AppKit gives | page window detached unless it holds focus [read, 2nd]; the commit waits `liveResizeDeadlineMs` for the page, default 0 [read] | every size |
| Full screen | once, at the end (`S/CmuxNextBridge/ResizeCoordinator.swift`) [read, 2nd] | final size at the start; AppKit animates a snapshot | final size | final size |
| Hidden pane, tab or screen | none; one size when it shows [read, 2nd] | none | parked and frozen | one size when it shows |

What shows between the old and the new picture today:

- Terminal: the old bounds and frame stay until a frame at the new size is ready; the host paints the terminal's
  background in a gap; the terminal host, the pane's content area and the pane host clip (`masksToBounds`). No
  stretch was found. [read, 2nd]
- CEF page: its last frame, unscaled, inside its pane; the gap shows the page's own background, else the pane fill
  (`S/CmuxNextBrowser/CEF/CEFHostView.swift:111-127`). The main thread never waits for a page (deadlines default
  to 0). [read]
- WebKit page: the web view takes the page area each frame through autoresizing; the gap shows the web view's
  background in the page colour. [read]

### 1.4 Chrome of the app [read, 2nd; the lines marked * were checked by the author]

| Motion | Clock and curve today |
| --- | --- |
| Sidebar show or hide * | `TimedProgress` on `MotionClock`, main thread, ease-out; two Auto Layout constraints change per frame, so the window lays out per frame (`S/CmuxNextSidebar/Views/SidebarContainerView+WidthMotion.swift`) |
| Sidebar width drag | no clock; one layout per pointer event |
| Sidebar rows (move, insert, fold) | render server, additive spring, `move`; insert fades on `tabOpen` |
| Sidebar bottom card slot | hand-stepped spring on main with `needsLayout` per frame |
| Tab strip add, close, reorder * | render server, 200 ms `1-(1-t)^2`; a new target restarts from the value on screen with no velocity (`S/CmuxNextDesign/Motion/MotionTween.swift`) |
| Tab strip overflow reveal | spring `scroll` (damping 0.9) |
| Tab drag ghost | hand-stepped `track` (0.9), release on `settle` (0.85) (`S/CmuxNextApp/Drag/TabDragSession+Ghost.swift:138`) |
| Dialogs, palette | fade 0.12 s and scale from 0.97 on `appear`; scrim 0.18 s |
| Popups | open with no animation; close with a fade and a shrink |
| Hover cards * | `panel` (0.85); `grow()` uses `settle` on purpose: "stretches a hair past rest and pulls back" (`S/CmuxNextDesign/HoverCards/HoverCardPanel+Morph.swift:130-144`) |
| Space change * | the old sidebar page and the live list move one sidebar width on `screen` (0.9), render server; a swipe's release uses `settle` (`S/CmuxNextSidebar/Views/SidebarSpacePaging.swift`) |
| Screen change | the new screen comes from an 18 % offset with a fade, the old one fades out, on `screen` (`S/CmuxNextLayout/Views/LayoutRootView+Screens.swift`) |
| Column reveal (strip camera) | spring `scroll` (0.9) on main |
| Home (MessagesLab) * | raw `CASpringAnimation`: pin drag stiffness 320 / damping 30, send button 520 / 30; outside `check-motion.sh` |
| Web pages * | CSS tokens; three curves pass 1: `--cmux-ease-spring` (peak 1.006), `--acpmux-minimap-spring` (1.008), `--cu-preview-ease-pop` (`cubic-bezier(0.34, 1.4, 0.64, 1)`) |

### 1.5 Numbers other owners measured

These are in the performance lead's hand-off notes, not in this repository, and were not measured again.

- A pane spring frame costs 6 to 9 ms of main thread with 17 to 19 view layouts (RESIZE owners). The refresh is
  8.3 ms.
- A close key cycle is about 19 to 22 ms p50; its films miss 1 to 4 refreshes (CLOSE PERF owner).
- A hosted Chromium page moved as a whole for 2 to 4 frames per split, by up to 660 device pixels (PR #39993, a
  120 Hz Mac mini).
- Zoom's first change comes 50 to 60 ms after the key; a zoom out wraps the text again in one step at rest, about
  250 ms after the key (Motion Lab build v13).
- From the resize send to the first presented program frame: p99 11.7 ms and 17.4 ms in two runs (comment in
  `S/CmuxNextTerminal/TerminalFramePresenter.swift`).

## 2. What the content can and cannot do

### 2.1 A program behind a PTY

- The size goes to the program as `TIOCSWINSZ`; the kernel sends `SIGWINCH` to the foreground process group. There
  is no acknowledgement: the terminal cannot know that the program has drawn at the new size. [source: the
  `TIOCSWINSZ` manual page]
- Synchronized output (DEC mode 2026) is the one in-band signal that a picture is complete, and only programs that
  use it send it. [source: the mode 2026 specification]
- So a program on the alternate screen has exactly two correct pictures in a motion: the old one at the old size
  and the new one at the new size, and the new one comes one to three refreshes after the send (1.5). No size in
  between is ever correct for it. A size sent per frame of a 100 ms motion is 12 signals; each redraw is late for
  the frame it was meant for.
- On the primary screen the terminal's own reflow is the correct picture at any grid. The shell still gets the
  signal and many shells print the prompt again on each one.

### 2.2 A page

A page lays itself out at any size, in another process, and its frame comes some refreshes later. A page with
heavy layout or script comes later still. Each new size is one more layout and one more `resize` event for the
page's script.

### 2.3 How other systems do it

Terminals [source unless marked]:

- Ghostty (`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`, `sizeDidChange`) sets the size at once,
  with no debounce, and its comment says to use the final size and not the view's frame during an animation ("The
  size represents our final size we're going for"). It does not animate splits
  (`macos/Sources/Features/Splits/`). Its IO thread coalesces resizes to one per 25 ms (`src/termio/Thread.zig`).
  The renderer pads with the background and never stretches (`src/renderer/generic.zig`).
- kitty debounces a resize (`resize_debounce_time 0.1 0.5`). VS Code debounces columns by 100 ms
  (`terminalResizeDebouncer.ts`). WezTerm does not debounce (`wezterm-gui/src/termwindow/resize.rs`).
- tmux resizes its own screen at once but sends the size to the pane's program at most once per 250 ms
  (`server-client.c`, `server_client_check_pane_resize`).
- A synchronized update ends by a timeout: Alacritty 150 ms (`vte` `src/ansi.rs`), tmux 1 s, kitty 2 s and a
  resize cancels it (`kitty/screen.c`).
- Compositors that animate a window's size send ONE size, the target, and show the old buffer until the new one
  comes (Hyprland issue 8371: the maintainer refuses a resize per frame). They stretch the old buffer; cmux must
  not.

No terminal that was read animates a pane's size with a size per frame. Not checked: iTerm2, Terminal.app.

Chromium [source; each file is under `chromium/chromium` `main` and was read through a fetch tool that returns
excerpts, so a quote is an excerpt and "not found" means not in the excerpt]:

- **Animation runs off the UI thread.** The compositor thread animates transform, opacity and filter, so that
  "input and animations [are] responsively handled on one thread while the other thread is busy"
  (`docs/how_cc_works.md`). The browser's own UI layers use the same path: `ui/compositor/layer_animator.h` adds
  "threaded animations" and `StartTogether` gives a group "the same effective start time even when some of them
  start on the compositor thread".
- **A page that changed size never holds the browser's frame.** On macOS a new view size makes a new surface id
  with a deadline of 0 frames (`content/browser/renderer_host/browser_compositor_view_mac.mm`,
  `UpdateSurfaceFromNSView`: `cc::DeadlinePolicy::UseSpecifiedDeadline(0u)`). The reason is in
  `content/browser/renderer_host/delegated_frame_host.cc`: "we would like to produce new content as soon as
  possible or the OS will create an additional black gutter. Until we can block resize on surface synchronization
  on these platforms, we will not block UI on the top-level renderer."
- **Until the page's frame at the new size comes, the old frame shows unscaled with a gutter.** The page's layer is
  shown with `stretch_content_to_fill_bounds` false (`delegated_frame_host.cc`, `EmbedSurface`). The display
  compositor draws the fallback surface at its own size, cut to the quad, and fills the rest with the page's root
  background colour (`components/viz/service/display/surface_aggregator.cc`, `HandleSurfaceQuad`,
  `EmitGutterQuadsIfNecessary`; its comment: "the surface content may be stretched or have gutter"). The gutter
  colour is the last frame's root background (`render_widget_host_view_mac.mm`,
  `BrowserCompositorMacGetGutterColor`).
- **A window live resize is the one case where the UI thread waits.** It waits in the Core Animation pre-commit
  for a frame "of same size as the NSView", so that window and content "are resized in lock-step"
  (`ui/accelerated_widget_mac/window_resize_helper_mac.h`), for at most 500 ms
  (`components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm`, `kUIPaintTimeout`). The same file turns
  the wait off in a full screen transition: "there is no need for updates during such transition. Re-layout and
  re-paint will be done after the transition." Resize messages to the page are throttled in a window resize
  (`render_widget_host_view_mac.mm`, `kThrottleResizeIpc`).
- **A hidden page that was resized shows blank, not its old size**, when it shows again (`delegated_frame_host.cc`:
  "This is preferred to showing contents of old size").
- **The tab strip** animates bounds for 200 ms (`chrome/browser/ui/views/tabs/tab_container.cc`,
  `AnimateViewTo`). A slot that already goes to the same target is not started again, because that "changes the
  timing of how the slot animates, leading to hitches". Tabs keep their width while the pointer is in the strip
  after a close, "so that as the user closes tabs with the mouse a tab continues to fall under the mouse". The
  first tab and a closing browser do not animate.
- **Interrupt.** `LayerAnimator`'s default is `IMMEDIATELY_SET_NEW_TARGET`: the running animation goes to its end
  and the new one starts. cmux differs on purpose: a new target starts from the value on screen (Lawrence's
  2026-10-28 rule).

No Chrome surface that was read animates the SIZE of a page: the tab strip and the UI layers animate bounds of
views that hold no page, and a page's size changes only with the window. Not read: Chrome's side panel.

WebKit [source, same limits; `WebKit/WebKit` `main`]:

- A new frame size goes to the drawing area at once and the UI process does not wait:
  `Source/WebKit/UIProcess/mac/WKViewLayoutStrategy.mm`, `didChangeFrameSize` calls `setDrawingAreaSize` with the
  view's frame size; its `willStartLiveResize` and `didEndLiveResize` are empty.
- The UI process keeps what it shows until the web process catches up: the display link fires off the main thread
  and scrolling has its own thread
  (`Source/WebKit/UIProcess/RemoteLayerTree/mac/RemoteLayerTreeDrawingAreaProxyMac.mm`; for a zoom: "Hold this
  scale until the web process catches up").
- [recalled] The older macOS drawing area waited up to 500 ms for the web process in a live resize
  (`TiledCoreAnimationDrawingAreaProxy`); that file is not at its old path now.

What cmux takes from this:

- The picture between two sizes is settled by Chrome itself: the old frame, unscaled, cut by its container, with
  the page's own background in the rest, and the UI never waits. cmux's CEF path already does this
  (section 1.3), and #39993 fixes the corner it holds.
- Chrome avoids the problem this document has to solve: it does not animate a page's size. So there is no Chrome
  model for "a pane that changes size over 100 ms". The nearest ones are the compositors of section 2.3's last
  item: one size, the target, at the start.
- cmux does not copy the 500 ms wait of the window live resize. The repository's rule is that the main thread
  never blocks; cmux's deadlines for a page default to 0 (`CEFLayerHosting`). The cost is a gutter at the window's
  edge in a fast live resize, in the page's background colour.
- Chrome's full screen rule is the class K rule: no update during the transition, one layout for the final size.

## 3. First principles

1. **One clock: the display's refresh.** A motion whose end is known when it starts is sampled by the render
   server, with no main-thread work per frame. Only motion that follows a pointer steps on the main thread, once
   per refresh, because each frame needs a new input sample.
2. **The content gets its final size once, in the turn of the input.** Never a size in between, never a size at
   the landing. This holds for the PTY grid, the terminal surface, a Chromium page and a WebKit page, in every
   motion with a known end. Motion that follows a pointer has no known end: it sends at most one size per refresh
   and always sends the last one.
3. **A motion is a transition between two pictures.** In every frame a pane shows the newest picture its content
   has drawn: unscaled, with its top-left corner on the pane's top-left corner (a terminal on the primary screen
   may keep its bottom rows instead, as `motionAnchor` does today), clipped by the pane. Where the picture does
   not cover the pane, the pane's own ground shows (the terminal's background, the page's background). Never a
   stretched picture, never a still copy in place of live content, never the window's background, never a pixel
   outside the pane.
4. **The motion is the time the content has to draw.** A terminal needs at most 3 refreshes (25 ms at 120 Hz) and
   a page some frames. A motion of about 100 ms covers both, so the frame at the landing already shows the final
   picture and nothing changes at rest. A motion of one frame cannot hide this time: the old picture then shows at
   the final geometry until the new one comes. A longer motion buys nothing more.
5. **Position never passes its target.** Critical damping or a curve that only rises. A new target starts from the
   value on screen; velocity carries over only when it points at the new target and cannot pass it. This is "no
   bounce" as a testable rule: overshoot is 0 pixels.
6. **Only a person's action animates.** A change from a script, the CLI, MCP or an agent, and any change to a
   hidden workspace, applies to the model at once and shows in one frame (the repository's automation rule).
7. **One intent, one animation, the same from every entrypoint; the inverse action is the exact inverse; no
   animation waits for another** (Lawrence 2026-10-28). The local model changes in the input's turn; the daemon
   reconciles later.

Principle 2 and 4 together say why "send the final size at the start" is right for every content type, not only
for terminals. With a size per frame the content is late in every frame of the motion and its final picture
arrives after the landing. With one size at the start the content is late once, at the start, when the container
has moved least.

The visible cost is for a pane that shrinks: its final picture is smaller than the pane until the landing, so a
strip of the pane's ground shows beside it. For a terminal this is what a split does today. For a page it is new:
today a page gets a size per frame and its last frame is cut by the pane, which hides the lag while the pane
shrinks and shows it while the pane grows. The first owner films both arms on a heavy page before the per-frame
path is deleted; if the strip is worse than the lag, a page that shrinks keeps its old picture, cut, until the
frame at the final size comes, and nothing else in this design changes.

### 3.1 Why the render server, and what stays on the main thread

Chrome's rule is that the main thread never has to run for an animation frame. In cmux the render server is the
thread that plays that part. A motion that obeys principle 2 changes nothing but a position and a clip after its
first frame, and Core Animation can run both without the app. The tab strip and the sidebar rows already work this
way. Pane motion does not: it sets view frames and lays out on the main thread per frame, and one long main-thread
task stops the motion.

The design moves pane motion in two stages, and the first is useful alone:

- **Stage 1, no layout per frame.** Every content type takes its final size at the start (principle 2). The pane's
  own chrome (its tab strip, a browser toolbar) is laid out for the final size at the start too. The frame clock
  then writes only a position and a clip per pane. Budget: the motion's main-thread step is at most 1 ms p99.
- **Stage 2, no main thread per frame.** The same position and clip run as one render server animation group per
  motion, added in the input's turn in one transaction. A new target reads the presentation value and starts from
  it.

Where cmux differs from Chrome, and why:

- Pointer-driven motion (a divider drag, a sidebar width drag, a window live resize) stays on the main thread:
  the pointer is the clock. Chrome does the same for a window resize.
- A pane edge on the render server is not put on the device-pixel grid in each frame, as `pixelEdges` does today.
  Text that moves can be soft for the length of the motion. The picture at rest is on the grid. The stage 2 owner
  films this before the old path goes.

Not verified for stage 2: that a Chromium page's `CALayerHost`, a `WKWebView` and Ghostty's IOSurface layer each
keep presenting under an explicit bounds animation of an ancestor layer, and that the overlay panel above the page
windows (`WindowOverlayLayer`) can run the same animation in the same transaction. The stage 2 owner proves both
on split before it ports another motion.

## 4. The contract, per motion

Classes: **K** = known end (principle 2: final size once, at the start). **P** = follows a pointer (one size per
refresh at most). **N** = no content size changes.

For every class K motion the same content rule holds, so the table does not repeat it:

- Terminal: one grid to the PTY and one surface size, both final, in the input's turn. Alternate screen: Ghostty
  keeps the last program frame until the program's redraw or 3 refreshes (the rule of #40174, section 4.1 of the
  #40040 design); primary screen: the reflow frame at once.
- Page (CEF and WebKit): one layout at the final size, in the input's turn. The last frame stays, unscaled, top-left,
  clipped, with the page's background in the gap, until the page's frame at the final size comes.
- In between: principle 3. Interrupt: principle 5.

| Motion | Class | Clock (design) | What differs from the common rule | Today's gap |
| --- | --- | --- | --- | --- |
| Split open | K | render server (stage 2) | the new pane paints its ground from its first frame (#40052) | pages get a size per frame; no program hold; layout per frame |
| Pane close | K | render server | survivors get their final grid once (already so); the closing pane shows its ground or fades | key cycle over budget; under the close motion hold |
| Zoom, unzoom | K | render server | the model changes in the key's turn; unzoom is the exact inverse | waits for the daemon (50 to 60 ms); text wraps again at rest |
| Move, swap | K | render server | the model changes in the key's turn; panes move as whole pictures at their final sizes | waits for the daemon; no motion |
| Equalize | K | render server | none | pages get a size per frame (terminals already get one grid) |
| Key resize | K | render server, or one frame per press | each press is one intent: one grid per press | size and grid per frame of the spring (see section 8) |
| Sidebar show or hide | K | render server | every pane of the screen takes its final size at the start; the sidebar and the content area move as layers | grid at the END; window layout per frame |
| Full screen | K | AppKit's transition | final size at the start for surfaces AND grids | grids wait for the end |
| Column reveal | N | render server | a translation of the strip; no size changes | hand-stepped spring, damping 0.9 |
| Pin, unpin (sidebar, tab) | N | render server | the row or tab moves from where it shows to its slot | draft #38267 waits for the pick |
| Sidebar rows | N | render server (already) | none | card slot lays out per frame on main |
| Tab strip add, close, reorder | N | render server (already) | none | overflow reveal and drag ghost use damping below 1 |
| Overlays, popups, hover cards | N | render server (already) | never delay input: the surface takes keys in the turn it opens | three tokens and `grow()` pass their target |
| Divider drag | P | pointer, one sample per refresh | terminal: surface and grid per refresh, hold rule of #40174; page: one size per refresh at most; the release adds no travel | release carries velocity; page window detaches |
| Sidebar width drag | P | pointer, one sample per refresh | as a divider drag | one layout per event, not per refresh |
| Window live resize | P | AppKit | as a divider drag; only THIS window's motion snaps | movement snaps in every window |
| Space change, screen change | none | one frame | no motion (ordered); a finger swipe follows the finger and lands with no bounce | slide and fade |

### 4.1 Acceptance, the same for every motion

Each is a distribution (p50, p95, p99, max) over at least 20 runs, light and under STRESS, at 120 Hz, at 1x and 2x.

| Metric | Definition | Budget |
| --- | --- | --- |
| First frame | input event time to the first presented frame that shows the change | under 10 ms p95 to the commit; shown at the next refresh |
| Missed refreshes | refreshes during the motion in which the container did not advance | 0 |
| Wrong-size frames | frames in which a terminal shows a program picture drawn for a grid that is not the grid sent last | alternate screen: at most 3 per size change; primary screen: 0 |
| Protrusion | page or terminal pixels outside the pane's clip | 0 |
| Holes | frames in which a pane's area shows the window's background | 0 |
| Settle lag | refreshes after the landing until every pane shows its final picture | 0 for a motion of 100 ms or more with terminals; reported for pages |
| Overshoot | the farthest any edge goes past its target | 0 px |
| Sizes sent | sizes each content got in one class K motion | exactly 1 |
| Main-thread step | main-thread time per motion frame | stage 1: 1 ms p99; stage 2: 0 |

After #40169 the present callback (reason `reflow`, `program`, `bound`) gives the wrong-size and settle counts with
no film. "Sizes sent" is a counter at the three hand-off seams (`TerminalGridReporter`, `beginPageSync`, the
WebKit container's layout).

### 4.2 The film judge

A film fails when any frame in it is:

- **frozen**: a pane's pixels stand still for 2 or more refreshes while its container moves and its content had
  output, or a still copy stands in for live content;
- **stretched**: content pixels scaled on any axis;
- **anchored**: an old picture held at a corner of a pane with another size for longer than the content's bound
  (alternate screen 3 refreshes; primary screen 1);
- **protruding**: content pixels outside its pane;
- **a hole**: window background inside a pane;
- **past its target**: any edge beyond its rest position;
- **late**: any change of content after the landing frame.

A strip of the pane's own ground between a final-size picture and a moving pane edge is not a failure during the
motion. It is the visible cost of principle 2 for a pane that shrinks, and it is why the motion is short.

## 5. Candidates for Motion Lab (no pick here)

Names K2 to K12 are the Motion Lab curve set of build v13: K2 ease-out 100 ms, K3 ease-out 120 ms, K4 ease-out
quint 100 ms, K5 ease-in-out 120 ms, K6 critically damped with response 0.15 s, K10 linear 100 ms, K11 critically
damped 0.12 s, K12 critically damped 0.2 s. No candidate passes its target. "One frame" is in every list.

How the principles rank curves, before any film: an ease-out moves most in its first frames, so the action feels
tied to the key, but the old picture is cut or padded most in the frames before the program's redraw. An
ease-in-out (K5) hides that time and feels late. A critically damped spring starts from zero velocity, so its
first frame moves least of all. Linear (K10) stops hard. The recommendation is therefore the shortest ease-out
that still covers the content's time, and films decide.

| Motion | Candidates | Recommendation and reason |
| --- | --- | --- |
| Split open | one frame; K2; K3; K11 | K2: 12 refreshes cover the terminal bound and a page's first frames; the ground strip shows for the shortest time |
| Pane close | V1 one frame; V0 slide (today); V3 slide out; V6 fade and grow, each on K2 or K3 | V6 on K2: a survivor grows, so its final picture is only uncovered (no strip); the fade hides the closing pane's bare ground |
| Zoom, unzoom | one frame; Z0 cover (today); Z4 grow and fade, on K2 or K3 | Z4 on K3 (Lawrence's stated target); the travel is the longest of the pane motions |
| Move, swap | one frame (today); whole panes translate on K2; cross-fade 100 ms | translate on K2: it shows which pane went where; one frame when a script did it |
| Equalize | one frame; K2; K6 (today's `move`) | K2, as split: the same kind of change |
| Key resize | one frame per press; K2 with the final grid at the start; today (follow every frame, K6) | one frame per press: a held key repeats, and the repeats are the motion; Ghostty and tmux do this |
| Column reveal | one frame; K2; K3; K11 | K3: a translation only, and the travel can be a whole column |
| Sidebar show or hide | one frame; K2; K3; today (ease-out on the `appear` and `disappear` lengths) | K3, sidebar and content as layers; one frame if films show the strip too wide |
| Sidebar rows | one frame; K6 (today's `move`); tab strip tween 200 ms | K6: already critically damped on the render server |
| Sidebar or tab pin | one frame (P0); translate (P1) on K6; translate on the tab tween | P1 on the curve its surface already uses (rows K6, tabs the tween) |
| Tab strip | one frame; today (200 ms `1-(1-t)^2`); K3 | today's: it is Chrome's tab strip tween |
| Overlays (dialog, palette) | one frame; fade 100 ms; fade and scale from 0.97 on K2 | palette: one frame to open (typing must not wait), fade to close; dialogs: fade 100 ms |
| Hover cards | one frame; fade 80 ms; fade and grow on K11 | fade and grow on K11: the stretch past rest goes |
| Divider or tab drag release | no release motion; K2 to a snapped target; K11 | no motion unless a snap or a limit moved the target; then K2 |
| Space swipe release | K2; K11; one frame | K2 from the finger's position |
| Space change, screen change | one frame (ordered by Lawrence) | no candidate |
| Window live resize, full screen | AppKit's | no candidate |

## 6. Removals

Ordered by Lawrence already:

1. The screen change slide and fade (`LayoutRootView+Screens.swift`). Owner SCREEN SWITCH INSTANT.
2. The space slide on a click (`SidebarSpacePaging.slide`), and the switch on mouse up. Owner SPACE SWITCH.

Found by the inventory. None needs a curve pick unless it says so:

3. Every spring that can pass its target: tokens with damping below 1 (`settle`, `scroll`, `screen`, `track`,
   `selection`, `panel`, `popover`, `pinDrag`, `split`, the fallback), the setting `ui.animations.bounce` with
   its `subtle` value and its two actions, and the debug variant `PaneMotionVariant.softLanding`. From rest,
   damping 0.85 passes the target by 0.6 % of the travel and 0.9 by 0.15 %; `split` at 0.95 by less than 0.01 %,
   so it is in the list for the rule, not for a visible defect.
4. The hover card's stretch past rest (`HoverCardPanel.grow`, asked for by Leo on 2026-11-07). Lawrence's rule is
   newer and covers every motion.
5. The MessagesLab springs with damping ratio below 1 (pin drag 0.84, send button 0.66 by the formula; its comment
   says 2 to 3 %), and the three CSS curves that pass 1.
6. Velocity that can carry an edge past its target: the divider release seed (`SplitMotion.seed`), a retarget with
   velocity, the swipe release on `settle`.
7. The sidebar slide's "grid at the landing" hold (`WindowRootView+ContentAreaMotion.swift`) and its window layout
   per frame.
8. A page size per frame in a class K motion (the CEF page's layout in each frame after `beginPageSync(.paneSpring)`,
   which is called once per spring start; the WebKit container's
   autoresizing per frame). The rule a focused CEF page already has (`holdPageAtRest`) becomes the only rule.
9. The daemon round trip before a zoom or a swap shows.
10. The app-wide live resize snap; it becomes per window.
11. With #40174: `TerminalFramePresenter`, the frame owner, the spring draw-ahead and the Reduce Motion snap wait.
12. After the key resize pick: the per-frame follow of a key resize (`PaneMotionHoldFollowing`, the reflow preview
    in a spring).
13. After each pick: the debug variants `crisp` and the losing Motion Lab variants (no motion switch stays).
14. Dead or stale: `ScreenContentView.holdsGrids` (never set true), the `screen` token once 1 and 2 land, and the
    comments that say pane animation is off by default (`Motion.swift:102-105`; rule 9 of
    [motion.md](motion.md)), that every pane's terminal is laid out live per frame (`SplitMotion.swift`), and the
    ones the helper found stale (`RestingPlacement.swift:64-76`, `CEFHostView.swift:545-551`) or the author did
    (`TerminalSurfaceView+FrameOwner.swift:116-124`: "a split's, close's or zoom's grid goes at its landing";
    `TerminalSurfaceView.swift:523-535` says the same, as the reviewer found).

## 7. Work plan: one owner per motion

Ordered by what a person sees most. "Now" means the owner can start on the AWS minis today; no fleet Mac runs
macOS 14 or 15. Each owner writes its red test first and runs it itself on the fleet, before and after.

| # | Owner | Red test (fails today) | Main files (`S/`) | Needs | Start |
| --- | --- | --- | --- | --- | --- |
| 1 | SPLIT OPEN (also proves stage 1 and stage 2) | a Chromium page and a WebKit page each get more than 1 size in one split; a 50 ms main-thread stall in the motion stops the pane edge | `CmuxNextLayout/Views/ScreenContentView+Motion.swift`, `SplitMotion.swift`, `PaneArrival.swift`, `CmuxNextBrowser/CEF/CEFTabContentView+PaneMotion.swift`, `CmuxNextBrowser/WebKit/WebKitPageContainer+PaneMotion.swift` | #40052, #39993 first; the terminal hold on a split comes with #40174; curve from Motion Lab | now (pages, stage 1); stage 2 after stage 1 |
| 2 | PANE CLOSE | the key cycle is over one refresh; a film misses refreshes | `ClosingPanes.swift`, `ScreenContentView+Motion.swift` | the close pick (close motion hold); #40174 for the Reduce Motion snap | after the pick; owner CLOSE PERF holds the key cycle now |
| 3 | SIDEBAR SHOW OR HIDE | an alternate-screen fixture gets its grid at the end of the slide, not in the key's turn; the window lays out on every frame | `CmuxNextSidebar/Views/SidebarContainerView+WidthMotion.swift`, `CmuxNextApp/WindowRootView+ContentAreaMotion.swift`, `CmuxNextApp/Windows/ShellWindow+ContentAreaMotion.swift` | nothing; tell the sidebar owner ([OWNERS.md](OWNERS.md)); curve from Motion Lab | now |
| 4 | ZOOM | the first changed frame comes after the daemon's answer, not in the key's turn; a zoom out changes text after the landing | `CmuxNextApp/Handlers/PaneHandlers.swift`, `PaneZoomMotion.swift` | the zoom pick for the motion; none for the key's turn | now (model in the key's turn); motion after the pick |
| 5 | NO BOUNCE (removals 3 to 6) | a spring trace from rest and from a retarget passes its target | `CmuxNextDesignTokens/Motion/`, `CmuxNextDesign/HoverCards/`, `Packages/Shared/CmuxMessagesLab`, `webviews/src` | nothing | now |
| 6 | KEY RESIZE | an alternate-screen fixture gets more than 1 grid per press | `CmuxNextLayout/Views/LayoutRootView+KeyResize.swift`, `CmuxNextTerminal/TerminalHostView+PaneMotion.swift` | #40174 (it deletes the paths this uses); the key resize pick | after #40174 |
| 7 | DIVIDER DRAG and its release | the divider travels after the pointer lets go; a page gets more than 1 size per refresh | `DividerDrag.swift`, `SplitMotion.swift`, `CmuxNextBrowser/CEF/CEFLayerHosting.swift` | #40174 | after #40174 |
| 8 | TAB STRIP | the overflow reveal and the drag ghost pass their target | `CmuxNextTabs/`, `CmuxNextApp/Drag/` | nothing; tell the tab strip owner | now |
| 9 | SIDEBAR ROWS and PIN | the card slot lays out on main per frame; pin has no motion | `CmuxNextSidebar/Views/` | the pin pick (draft #38267); tell the sidebar owner | card slot now; pin after the pick |
| 10 | OVERLAYS and HOVER CARDS | an overlay's first frame comes later than the next refresh after the key | `CmuxNextDesign/Motion/Motion+Popup.swift`, `CmuxNextDesign/HoverCards/` | the overlay pick for curves | now for the first-frame test |
| 11 | WINDOW RESIZE and FULL SCREEN | a live resize in window A snaps a motion in window B; in full screen the grid goes at the end | `CmuxNextDesign/Motion/Motion+LiveResize.swift`, `CmuxNextBridge/ResizeCoordinator.swift`, `CmuxNextApp/Windows/WindowController+FullScreen.swift` | #40174 for the terminal part | now for the per-window snap |
| 12 | COLUMN REVEAL | the camera passes its target; it steps on main | `CmuxNextLayout/Views/ScreenContentView+Scrolling.swift` | curve from Motion Lab | now |
| 13 | MOVE and SWAP | the first changed frame comes after the daemon's answer | `CmuxNextApp/Handlers/PaneHandlers+Verbs.swift` | the move pick for the motion | now (model in the key's turn) |
| 14 | SPACE and SCREEN CHANGE | owned: SPACE SWITCH and SCREEN SWITCH INSTANT | | | running |

Stage 2 (render server) is owner 1's second part. When split passes on it, each pane motion owner ports its own
motion; no second clock path stays behind.

## 8. Other designs and open pull requests

- **#40040 (Ghostty integration design)** agrees: section 4.3 says the app calls `set_size` with the final size
  at the start of the motion and animates only the clip and the position. This document extends that rule to the
  key resize and the sidebar slide, which that section does not name, and to pages. One difference in words:
  #40040 keeps a "draw-ahead" for a drag; a drag has no final size, so here it gets one size per refresh.
- **#40174 (Ghostty times resize frames)** is the terminal half of the in-between rule and this design depends on
  it. Three points to settle there: it changes when a Reduce Motion close, zoom and key snap show, which touches
  the close motion hold; it leaves the key resize on a size per frame, which this document proposes to end
  (below); the m55 decision asked for the bound as time and not as ticks, and its description says "3 refreshes".
- **#40169 (present callback)** gives the wrong-size and settle metrics of section 4.1 their data.
- **#40091 (main thread scheduling)** agrees in direction: no main task over 4 ms; today's spring frame (6 to 9 ms)
  breaks that. It conflicts in one line: its frame order treats springs as an unbudgeted class that runs first.
  Here a class K motion leaves the main thread (stage 2), and until then its step has a 1 ms budget.
- **#39993 (hosted page top-left anchor)** is the page half of principle 3 for one host. `ChromiumHostPageView`
  has the same bottom-left pattern and is not fixed there; owner 1 takes it.
- **#40052 (new pane ground)** is the "no hole" rule for a split.
- **#34884** moves tab strip moves onto the frame clock during pane motion. That is the opposite direction to
  principle 1; with stage 2 both are on the render server and the reason for #34884 goes.
- **Key resize conflicts with an earlier decision.** The code follows a key resize on every frame with no hold
  (cmux-ad m18, m19). Principle 2 makes each press one intent with one grid. This is a visible change, so it is in
  the Motion Lab list (section 5) and nothing is removed before that pick.
- **"Content must move while it animates"** (Lawrence 2026-10-18, quoted in `SplitMotion.swift`) stays true in
  the sense that the code already took on 2026-10-23: content is live and rides its pane; it is not laid out again
  at each size.

## 9. Not verified

- Every number in 1.5: measured by other owners, not again.
- Ghostty's Zig sources: the submodules were not checked out; facts come from `docs/ghostty-fork.md`, the #40040
  design and the upstream files named in 2.3.
- The terminal grid order in a window live resize (inferred).
- Stage 2's two open points (section 3.1).
- Sidebar and tab pin code, `CollapsedBandReveal`, six vendor springs in MessagesLab: not read.
- iTerm2 and Terminal.app: no source was read. Chrome's side panel and the old WebKit drawing area: not read.
- The Chromium and WebKit quotes came through a fetch tool that returns excerpts; the files were not read whole.
- How long a Chromium or WebKit page needs for its first frame at a new size in cmux: no distribution exists.
  Owner 1 measures it; the 100 ms reasoning in principle 4 rests on #39993's 2 to 4 frames for one page.
