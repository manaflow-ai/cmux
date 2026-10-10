# CNBrowserUI validation (Mobile Safari reference)

Module: `Packages/CmuxNextMobile/Sources/CNBrowserUI`, root `BrowserRoot(connection:)`.
Reference: `ios-next/reference/safari.md`, crops in `reference/safari/` and the
raw captures in `~/nxios-ref/safari/` (iPhone 17 Pro, iOS 27).

The implementation was checked on the remote headless iPhone 17 Pro simulator
(`remote-ios.sh`, slot `browser`), running the Drawer scheme with
`CMUX_NEXT_DEV_SCREEN=browser` on `CNMockHost`. The mock host streams generated
JPEG pages at 8 fps, so the page content differs from the Safari captures. Only
the chrome and motion are comparable.

The shell's `ModuleRoots.browser()` still returned a placeholder when this was
written. The slot build patched that one line in its remote copy only, so the
browser root could be reached. The shell agent needs to make the same change:
`func browser() -> some View { BrowserRoot(connection: connection) }`.

## Method

- **Geometry:** frames come from the AXe accessibility tree (`describe-ui`, in
  points). Glyph ink was measured with a dark-pixel bounding box on 3x
  screenshots, using the same script on the reference `plain_top.png` and
  `collapsed_plain.png`.
- **Motion:** each animation was recorded with `remote-ios.sh video` while AXe
  drove the app.
  - Toolbar springs: the URL label's center y was tracked frame by frame at
    60 fps (dark-ink centroid inside the capsule) in both the reference and
    implementation recordings. A SwiftUI `spring(response:dampingFraction:)`
    was then fitted to each track. This gave cleaner fits than
    `framediff.py --track`, which lost the template over the busy mock page.
  - Larger transitions: `framediff.py` was run for onset and duration. The
    sequences were then aligned on the first changed frame in the relevant
    screen band, and side-by-side contact sheets (reference on top,
    implementation below) were checked frame by frame.
- **Noise:** the simulator recorder drops frames under load. Repeating the same
  collapse gave fitted responses between 0.40 and 0.44 s, so treat ±0.04 s and
  ±1–2 frames as noise.

## Static geometry (light; dark verified in the contact sheet)

| Element | Reference | Measured | Result |
|---|---|---|---|
| Back circle | 34, 792, 48 × 48 | 34, 792, 48 × 48 | pass |
| Address capsule | 90, 792, 222 × 48 | 90, 792, 222 × 48 | pass |
| Page-menu slot | 90, 792, 48 × 48 | 90, 792, 48 × 48 | pass |
| Page-menu glyph ink | 106.7, 810, 16 × 11.7 (3 lines, last ≈ 2/3) | 106.7, 810.0, 16.3 × 12.0 (custom 3-line shape) | pass |
| URL text cap height (17 pt medium) | 12.7 | 12.7 | pass |
| URL text center | x 201, y 816 | x 201, y 816.0 | pass |
| Reload glyph ink | 282.7, 806.3, 14.7 × 18 | 282.7, 806.3, 14.7 × 18.0 | pass |
| Tabs glyph ink | 332.3, 805, 23 × 22.3 | 332.3, 804.8, 23.0 × 22.7 | pass (0.4 pt) |
| Tabs circle | 320, 792, 48 × 48 | 320, 792, 48 × 48 | pass |
| Collapsed label center y | 843.8 | 844.0 | pass |
| Collapsed label scale | 0.74 (69 → 51 pt) | 0.74 (74.7 → 55 pt for "cmux.dev") | pass |
| Collapsed pill | text + 38, h 32, bottom inset 14 | same formula (layout code) | pass |
| Edit field (software keyboard) | 8, kbTop − 56, 330 × 48 | 8, 510, 330 × 48 (kbTop 566) | pass |
| Edit close circle | 346, y, 48 × 48 | 346, 510, 48 × 48 | pass |
| Edit field (hardware keyboard) | 34, 792, 278 × 48 | 34, 792, 278 × 48 | pass |
| Page menu panel | x 90–340, bottom ≈ 839, r ≈ 32 | x 90, w 250, bottom 839 | pass |
| Menu rows / text inset | 42 pt (62 for 2 lines), text at x 155 | 42 pt (≈ 61 for 2 lines), text at x 155 | pass |
| Overview cards | x 16 / 209, 177 × 249.3, r 18 | x 16 / 209, y 114, 177 × 249.3, r 18 | pass |
| Card close | 22 pt at (+151, +4), hidden on the selected card | 22 pt at (+151, +4), hidden on the active card | pass |
| Overview More | 346, 66, 36 × 36 | 346, 66, 36 × 36 | pass |
| Overview + / Done | 38, 788 and 316, 788 (48 pt) | 38, 788 and 316, 788 | pass |
| Favorites tiles | 72 × 72, x 16 / 115.3 / 214.7 / 314 | 72 × 72, x 16 / 115.3 / 214.0 | pass (0.7 pt) |
| Top strip | page color, rows 0–62 | page top-row average color, rows 0–62 | pass |

`toolbar-ref-vs-impl.png` shows four rows: reference expanded, implementation
expanded, reference collapsed, implementation collapsed. `states-light-dark.png`
shows the expanded, collapsed, menu, editing, overview, and new-tab states in
light (top row) and dark (bottom row).

## Motion

| Transition | Reference | Implementation | Result |
|---|---|---|---|
| Collapse (label y 816 → 844) | fit 0.38 / 0.87, settles in 16 frames | fit 0.40 / 0.87 (repeat run 0.44 / 0.84), settles in 17–18 frames | pass (≤ 2 frames, within recorder noise) |
| Expand by tapping the pill | fit 0.44 / 0.85, settles in 17 frames | fit 0.41 / 0.86, settles in 19 frames | pass (2 frames) |
| Expand by scrolling up | spec 0.41 / 0.87 (the reference clip fits poorly, rmse 0.085) | spring 0.41 / 0.87; the label track was too noisy over page content to fit | not measured |
| Side circles on collapse | fade out by ~80–150 ms while sliding inward | 140 ms linear fade, slide with the pill edges, scale 0.8 | pass (visual) |
| Address focus (software keyboard) | field rides the keyboard, rests at ~+13–16 frames, page crossfades at 30–130 ms | field follows the keyboard's own animation through the keyboard safe area, rests at +13–16; crossfade 30–130 ms | pass (`anim-edit.png`) |
| Page menu open | droplet stays capsule-round, blurred lensed rows, rest ~+14 frames | DropletShape stays a capsule until 60% progress; rows scale with the droplet; content opacity 80–200 ms, blur 8 → 0; rest at +14–16 | pass within ~2 frames (`anim-menu.png`) |
| Tab overview open | 402 → 177 wide, 64% at 77 ms, rest ~250 ms | spring 0.22 / 1.0, grid unblurs and scales from 1.06, rest ~+15–20 frames | marginal: the first frames lag 2–3 frames (`anim-open.png`) |
| Tab overview close | 177 → 402, 0.45 / 0.81, about 27 frames | spring 0.45 / 0.81; the card moves on the first frame, while the reference's grid fades for 3–4 frames before its card moves | pass for shape and duration (`anim-close.png`) |
| Close tab in overview | counter changes at once, card fades out, reflow ≈ 0.38 / 0.85 with a diagonal arc | same behavior; settles in ~16 frames | pass (`anim-tabclose.png`) |
| Toolbar swipe | page follows the finger; neighbor at 0.93 scale and blurred; snap 0.4 / 0.9 | same; the label slides with the page | pass (visual, `anim-swipe.png`) |

Changes made from these comparisons:

- The toolbar now uses separate glass shapes. Inside a `GlassEffectContainer`,
  per-shape opacity was ignored, so the side circles never faded.
- The pill label no longer dims on press. The old plain-button highlight made
  it blink during the expand.
- The tab overview and page menu stay mounted so their first frame is not
  delayed. Before this change, the page menu started 4 frames late.
- The address field follows the keyboard safe area instead of keyboard
  notifications, which removed a 4–5 frame lag.

## Interaction checks (mock host)

| Check | Result |
|---|---|
| Frames render edge to edge under the status bar; the strip color follows the page header (purple, blue, green) and becomes white after scrolling | pass |
| Every frame is acked after it is drawn; viewport = view size in points × screen scale, `mobile: true`; resent when the size, page keyboard, or desktop mode changes | pass (code path; mock streams continuously) |
| One-finger drag scrolls the remote page (`browser.touch`) and drives collapse and expand | pass |
| Tap on page content navigates (touch tap) | pass |
| Hardware keys reach the page (Backspace deleted a character); text through the hidden proxy field ("hello" typed into the page search box); Enter submits | pass |
| Address editing: full URL selected, completions ("Switch to Tab" for open tabs plus a search row), Go navigates, the label shows "🔍 query" for searches | pass |
| Page menu: Reload, Show Keyboard, Share (UIActivityViewController), Copy URL, Back/Forward, Request Desktop Website (re-attaches at 980 CSS px), Open on Mac (`browser.activate`), Close Tab | layout pass; Share, Desktop, and Open on Mac were exercised only through the code path |
| Overview: select a card, Done, +, close tab, Close All | pass |
| Toolbar swipe switches to the neighbor tab; swiping past the last tab opens a new start-page tab | pass for the neighbor tab; the past-the-end path is in code only |
| `browser.tab` and `browser.closed` events update the chrome; reload on `connection.generation` | in code; the mock host emits these on navigation, which was observed |

## Gaps and known differences

- **Status bar style:** Safari switches the status-bar glyphs between white and
  black based on page luminance. The module cannot set `preferredStatusBarStyle`
  because the shell owns the hosting controller. In dark mode over a white page,
  the clock is white on white (`states-light-dark.png`, dark collapsed). This
  needs a shell hook, such as a `CNShellChrome` status-bar preference.
- **Editable focus:** the protocol has no editable-focus signal. The soft
  keyboard opens from the page menu's "Show Keyboard". Hardware keys always go
  to the page.
- **Accent color:** the progress bar and the Done button use the cmux
  `highlight` token (#0869CB) instead of Safari's #0088FF, following the
  brief's one-hue rule.
- **Long-press:** the press is acknowledged with haptics, and the held touch
  lets the remote page open its own context menu. There is no local
  link-preview card because the protocol carries no link information.
- **Not built:** the edge-swipe back/forward gesture, the tab overview's search
  and filter controls, the "Private" segment, the mic/voice search, and a
  scroll-to-top expand (the phone does not know the remote scroll offset).
- **Progress bar:** implemented with a 3% minimum, ease-out, and a fill-and-fade
  finish. The mock loads in under a second, so it was not captured on video.
- **Address field selection:** the selected URL shows selection handles. Safari
  shows only the highlight.
- **Scroll-up expand:** the timing was not measured because the label track was
  too noisy. The spring uses the spec values.

## Displaced stream (`browser.detached`)

The host sends `browser.detached {streamId, tabId, reason:"displaced"}` when
another phone takes over a tab's screencast. `BrowserModel.handleDetached`
then does the following:

- Ignores the event unless it names the current stream.
- Cancels the frame task and calls `closeStream` locally. It does not send a
  `browser.detach` RPC, because the host has already ended the stream.
- Stops sending input to the stream.
- Keeps the last frame on screen, dimmed (black at 35%), under a glass banner
  that reads "Viewing on another device" with a "View here" button. The button
  calls `attach` again.

Every other detach path sends the `browser.detach` RPC first and calls
`closeStream` afterwards, as introduced in d345f6003e9.

The mock host now enforces one screencast per tab. A new attachment displaces
the old one and sends `browser.detached` to the displaced link only.

For testing, launching with `CMUX_NEXT_BROWSER_DISPLACE=1` (DEBUG builds only)
makes the app open a second link through the same connector once the first
frame arrives. That link attaches to the active tab, as a second phone would.

`displaced.png` shows two screenshots. On the left is the banner over the
dimmed last frame. On the right is the page after "View here": the stream is
live again, and scrolling collapses the toolbar.

## Tab zoom, card close and the new-tab origin (device recording)

The reference is a real iPhone 17 Pro Max recording,
`~/nxios-ref/safari/user/tab-zoom-device.mp4` (440 × 956 pt, 60 fps, dark
mode). I extracted its frames at 440 px wide, so 1 px = 1 pt. The
implementation was recorded on the 402 pt iPhone 17 Pro simulator in dark
mode. Widths are normalized as progress from card width to screen width
(196 → 440 on the device, 177 → 402 on the simulator). In both recordings, the
zooming rect is the bounding box of bright page pixels on the dark overview.

**What Safari does:** the zooming rect is the tab's window. The page,
including its status strip, is laid out at full screen size, scaled to the
rect's width, top-aligned and clipped by the rect. The rect's corner radius
interpolates between the screen radius and the card radius. Content never
cross-fades.

`ScaledPage` now draws the card, the zooming tab and the swipe cards the same
way, for both live frames and the start page. The zooming tab starts from the
image that the card shows.

| Item | Device | Implementation | Result |
|---|---|---|---|
| Card | 196 × 276 at x 16 / 228, y 122 (safe top 62) | (W − 48) / 2 wide, aspect 1.408, top = safe top + 60, radius 18 × width / 177 | pass |
| Card close | 22 pt circle, 4 pt from the top and right edges, 9.5 pt light cross, fill #F2F2F7 (light) / white 8 % (dark) | Same (`card-close-ref-vs-impl.png`: reference on the left, implementation on the right, 8 px/pt) | pass |
| Open: page to card | Spring fit 0.330 / 0.91, settles in 16 frames, no overshoot | Spring 0.33 / 0.91. Measured fits 0.315 / 0.95 (run 1) and an identical curve in run 2; every frame within ±1 frame except recorder duplicates; settles in 17 frames | pass |
| Close: card to page | Fit 0.335 / 1.00, settles in 23 frames, no overshoot | Spring 0.335 / 1.0. Run 2 fit 0.335 / 1.00, settles in 21 frames. Frames 1–3 trail by about 0.5 frame. Run 1 had one dropped frame at onset (fit 0.44 / 0.89). The last 5 pt no longer jump at the end: the overlay now waits for `completionCriteria: .removed` | pass |
| Card title and close button | Fade out at the start of a close; fade in late on open (by about 16 frames) | Fade out over 0.1 s; fade in over 0.15 s after a 0.22 s delay | pass (visual) |

`zoom-device-vs-sim.png` shows these rows, top to bottom:

1. Device close
2. Implementation close
3. Device open
4. Implementation open
5. Implementation (+) new tab

**New tab (+):** the recording contains no (+) taps. Both tabs (Gmail and
Start Page) exist from its first frame. Every transition in it is a page ↔
card zoom: open at frames 192, 640 and 882; close at 432, 733 and 1101.

The implementation follows the rule from the request. The new start page
grows from the grid slot its card will take (index = tab count; column =
index % 2, row = index / 2). If that slot is off-screen, the grid first
scrolls so it is visible, using the same reveal rule as the active card. The
zoom uses the close spring. Row 5 of the sheet shows tab 4 (right column,
second row) growing from its slot.

I did not validate this rule against Safari. It needs a recording with (+)
taps at different tab counts.

## Round 4: freeze, reversible zoom, pinch, overview bar, no scroll prediction

### Grid freeze (fixed)

**Root cause.** The grid's hit testing required two flags to be clear:

- `creatingTab`, which is cleared only after the host's `browser.create`
  returns. On the real host that takes up to 3 s, and longer when Chrome is
  slow.
- The zoom overlay being nil, which is cleared only in a `withAnimation`
  completion.

Returning to the grid before either happened left the grid unresponsive. This
happens after (+) followed by a quick tabs-button tap, or when completions race
each other.

**Fix.**

- **One state machine.** The zoom is now one state machine, `TabZoomState`: a
  progress value from 0 (page) to 1 (card) on a retargetable spring. Grid,
  bottom-bar and toolbar interactivity are derived from its phase:
  - the grid takes input only when settled on the overview;
  - the page takes input only when settled on the page;
  - while a zoom heads one way, the control that sends it back stays tappable.
- **No completion callbacks gate input.** No animation completion or host
  call gates input any more.
- **Tests.** `CNBrowserUITests/TabZoomStateTests` repeats 20 cycles of (+),
  sometimes interrupted early, then tabs button. It also covers 30 rapid
  toggles, pinch completion and cancel, and pinch handoff. 6 tests pass.
- **Simulator check.** I ran 4 rapid "(+) then tabs" cycles, then a close, an
  open and a reversal. The grid stayed responsive.

### Reversible transitions

The tabs button and Done now retarget the running spring from its current
position. Fit to `~/nxios-ref/safari/user/tab-reverse-device.mp4`, card width
per frame:

- **Spring after a reversal:** response 0.39, damping 0.88 (RMSE 0.5 pt and
  2.2 pt on the two reversals).
- **Velocity after a reversal:** Safari keeps only a small part of the old
  velocity, about 0.2. With full velocity, the spring keeps shrinking for 2
  more frames, which does not match the recording: 7.5 pt RMSE against
  0.5–2.4 pt.

The comparison used a DEBUG trigger, `CMUX_NEXT_BROWSER_REVERSE_MS=140`,
because AXe taps arrive about 11 frames apart and cannot land a second tap 140
ms in.

| | Safari (progress, card = 1) | Implementation |
|---|---|---|
| Return after the reversal (frames +12…+28) | 0.527 → 0.014 | 0.542 → 0.004, within 2.4 pt every frame |
| Before the reversal | 1-tab layout, slower opening (fit 0.39 / 0.84) | 0.33 / 0.91 (the 2-tab recording's fit); runs about 8 pt ahead |

The two Safari recordings disagree on the opening spring: 0.33 / 0.91 with 2
tabs, 0.39 / 0.84 with 1 tab. Safari also shows a single tab as a larger,
centered card (292 pt wide). The implementation does not have that 1-tab
layout yet.

### Pinch

- **Pinch-in on the page.** Once the pinch scale drops below 0.94 and the
  remote page is at its minimum zoom (`pageScale` ≤ 1.02 from the frame
  metadata), the pinch is taken over:
  - the page's touches are cancelled on the host;
  - the page rect follows the fingers (width = screen × scale);
  - on release it completes to the grid past half way or with inward velocity
    over 1.2 progress/s, and springs back otherwise.
- **Pinch-out on a card.** Opens the card the same way.
- **Verification.** AXe has no multi-touch, so the recordings use a scripted
  pinch (`CMUX_NEXT_BROWSER_PINCH=page|card|page-cancel`) that feeds the same
  handlers. The `UIPinchGestureRecognizer` and `MagnifyGesture` themselves need
  a device check. The page pinch followed the fingers to 221 pt, then sprang
  into the card. The card pinch-out grew to 371 pt, then opened. The cancelled
  pinch went to 341 pt and back to 402 pt.

`reverse-and-pinch.png` shows these rows, top to bottom:

1. Safari reversal
2. Implementation reversal
3. Page pinch
4. Card pinch-out

### Overview bar

The tab-count capsule was two nested glass capsules. It is now one 48 pt glass
capsule. The (+) and Done circles were already single glass shapes.

### Local scroll prediction removed; real responsiveness

Frames are now drawn exactly as streamed. `ScrollPrediction` is gone.

A host trace (`CMUX_NEXT_BROWSER_TRACE=1`) on cmux15 showed where the time
goes:

- Touch input reaches Chrome within 1–25 ms of arriving at the host. Chrome
  acknowledges a touch move in about 33 ms.
- Chrome paints frames every 17 ms right after the input.
- With 4 frames of about 55 KB in flight, the phone's acks came back about
  500 ms later. The link is the bottleneck, not Chrome.

Changes, all with environment overrides:

- JPEG quality 65 → 50: about half the bytes in a probe, 44–53 KB per frame on
  Wikipedia in practice.
- Unacked window 4 → 3, so one frame fewer is queued ahead of each new scroll
  frame.
- The phone logs each drag (`dev.cmux.next` / `browser.perf`): frames shown,
  frame rate, largest gap, time from the first touch move to the first frame
  showing the page scrolled, and KB per frame.

Measured on cmux15 with the simulator (6 drags per configuration). "Direct"
went through Tailscale DERP, so both rows are relayed paths.

| Path | Frames/s during a drag | First scrolled frame | KB/frame |
|---|---|---|---|
| Direct (q65, window 4) | 1–14, median about 2 | 0.22–0.98 s | 57–63 |
| Direct (q50, window 3) | 0–14, median about 4 | 0.31–0.89 s, often after release | 44–53 |
| Relay (q50, window 3) | 0–8, median about 4 | 0.25–0.89 s | 48–53 |

These numbers are poor and noisy:

- The simulator Mac's load average was 16–22.
- Another agent restarted the cmux15 host several times during the runs. Some
  runs were discarded because the host process changed mid-run.
- 3–5 other iOS clients were connected to the same host.

The remaining fix is throughput: video encoding (H.264) or smaller and
differential frames instead of full JPEGs. That is beyond this round.

## Round 5: zoom rect, scroll into view (Pro Max)

### Why the rect was wrong (`ours-wrong-rect-device.mp4`)

Frame-stepping the recording shows two failures:

- **(+) zoom started from the wrong place.** In frames 371–390, the page grew
  out of a right-column card two rows up. The new tab's real slot is the
  next left-column slot, below the screen.
- **Unfocus landed off its card.** In frames 305–323, the shrinking page
  landed slightly off the card it should have reached.

The cause was that the endpoint was computed from a *requested* scroll offset,
not from where the grid actually was:

- `prepareOverview` and (+) set a `ScrollPosition` and then used that number.
  The scroll view clamped it, because the new row did not exist yet when (+)
  set it.
- Card frames measured after `.offset` reported the content origin, not the
  card. This was a first attempt at measuring frames, caught on the Pro Max
  simulator.

**Fix.** The endpoint is now `OverviewLayout.card(index)` (the card's frame
in the grid content) offset by the grid content's origin in the screen's
coordinate space. The grid reports that origin with `onGeometryChange`, so it
reflects the real scroll position. It is read every frame, so it stays right
if the grid scrolls or relays out mid-flight.

**New tabs.** (+) inserts a start-page placeholder card at index
`tabs.count` immediately. The zoom grows from that card's frame. The created
tab replaces the placeholder in the same slot.

**Tests.** `CNBrowserUITests/OverviewLayoutTests` (7 cases) asserts:

- the endpoint equals the card's converted frame at offsets 0, 120, 315, 400
  and 508, including cards above or below the screen;
- the endpoint follows the reported origin and not a requested offset;
- Pro Max metrics;
- the reveal rule.

### Safari's scroll-into-view rule (`safari-scroll-into-view-device.mp4`)

**Grid metrics.** On a Pro Max with 7 tabs, card tops in content coordinates
are 122, 437, 752 and 1067 (pitch 315). The maximum offset is 508. Ours is
identical: 196 × 276 cards, the same tops, and `maxOffset` 506.8.

**Measured cases.**

- Unfocus of tab 5 (right column, row 2) from offset 0, frames 414–445: the
  grid jumps to offset 508 before the zoom starts. The card ends with its top
  at 244.
- Unfocus of tab 6 from offset 0, frames 152–184: also 508.
- A card that is already fully visible (frames 612–630): the offset is
  unchanged.

**What the cases rule out.**

- The minimal change ("card plus title just above the bar") would give 193.
- Centering would give about 412.

Neither matches.

**Rule implemented** (`OverviewLayout.offset(revealing:from:)`):

- If the card is already fully visible, keep the offset.
- Otherwise move the card to the first-row position, clamped to the content.

This reproduces all three cases. The recording has no case that separates "to
the first row" from "to the end of the content", because both measured
targets clamp to the maximum. The jump is applied without animation before
the zoom starts, for unfocus and for pinch-in.

Focusing from the grid keeps the grid's offset. Reopening the overview
recomputes it.

### Pro Max simulator check

On the iPhone 17 Pro Max simulator (440 × 956 pt) with 7 tabs and the grid
at the top:

1. Tap tab 5, whose bottom is cut off by the bar. The page grows from that
   card's real partial frame.
2. Unfocus. The grid jumps to 508, and the page shrinks into right column,
   row 2.
3. The card's final top is at 244 pt, the same as Safari (measured on the
   settled frame: the card's dark body spans 243–520).

`scroll-into-view.png` shows three rows, top to bottom: Safari frames
413–437, ours at the matching frames (brightened), and the old wrong rect
from Aziz's recording.

The zoom timing is unchanged from rounds 3–4 (same springs).

## Round 6: controllable pinch, pill tap, back/forward morph

### Pinch to and from the overview

**Detection.** One UIKit `UIPinchGestureRecognizer` covers the whole browser
screen. It never cancels or delays touches. The decision is local:

- **Pinch-in on the page.** It drives the zoom when the scale reaches 0.96,
  if either is true:
  - the last frame shows the page at its minimum zoom (start pages, blank
    tabs and unloaded tabs count), or
  - it happens within 40 ms of the fingers starting to move.

  Otherwise, and for any pinch-out, the gesture goes to the remote page as
  touches.
- **Pinch-out on a grid card.** Passing 1.04 opens that card.
- **Pinch during a running zoom.** It grabs the zoom where it is.

**Tracking.** `PinchTracker` takes the zoom rect as presented when the fingers
came down:

- **Width:** start width × pinch scale.
- **Position:** the page point under the start centroid stays under the
  centroid.
- **Rubber band:** with diminishing returns past the card (up to 0.35 progress)
  and past the full page (up to 0.12).

`TabZoomState` gained a free translation with its own velocity. On release,
progress and translation spring from the tracked values with the tracked
velocities (no discontinuity). The decision uses the projected width: below
75 % goes to the grid, otherwise back; strong inward velocity also decides.

**Unit tests (`PinchTrackerTests`).**

- 1:1 tracking within 0.01 pt at 5 scales.
- Rubber banding.
- Release continuity: same values and velocities, motion continues in the
  same direction.
- Grabbing a running zoom with no jump.
- The release rule.

**Synthetic pinch on the Pro Max simulator.** `CMUX_NEXT_BROWSER_PINCH=page`
replays a scale and centroid path on the display clock through the same
handler. It draws magenta finger dots and outlines the zoom rect in green; a
script compares them per frame.

| Run | Width vs fingers | Page point under the centroid | Release |
|---|---|---|---|
| page | ≤ 2.5 pt (dot-detection noise; most frames ≤ 1.3) | ≤ 1.6 pt | Velocity continuous (dY +4.0 → −1.3 → −9.3 pt/frame under the spring) |
| card (pinch-out) | ≤ 1.1 pt while tracking | ≤ 1.0 pt | Opened |
| grab (pinch during the tap zoom) | Continuous: no jump at the grab | | |

The rect clips at the screen edge past the full-page size, so those frames
are not measured. The feel on ProMotion is for Aziz to judge.
`pinch-tracking.png` shows the page run.

### Collapsed pill tap

**Possible causes** (none was isolated). The collapsed pill was the address
`Button`, beside an `.onTapGesture` and a swipe `DragGesture` on the same
capsule, under interactive glass. The button fires only after SwiftUI settles
which gesture wins.

**Fix.** When collapsed, the pill is now one high-priority zero-distance drag
target that calls `expand` on touch-up. SwiftUI springs start from the
presented value, so the expand also interrupts a collapse in flight.

**Trace (`browser.trace`).** On the simulator, the first frame carrying the
expand is on screen 32 ms (two 16.7 ms frames) after the handler, in 4 of 4
taps. That is the render pipeline's floor: the change is committed in the
next frame and presented on the one after. No frame waits on another gesture.

### Back / forward

The back control is now one glass capsule:

- Its width animates between the 48 pt circle and the back | forward capsule
  with the toolbar spring (0.37 / 0.9). The address capsule slides with it.
- The forward chevron slides in from inside the circle (offset, scale 0.6 → 1
  and fade) instead of popping.
- The disabled tint crossfades over 0.2 s.

There is no Safari capture of this morph, so it is not frame-matched.
`back-forward-morph.png` (frames 163–182 appear, 373–395 disappear) shows it
settling in about 17 frames with no pop.

## Round 6b: spring constants from `browser-springs-verify.md`

Applied in 63854ab308b. `ZoomSpring` is now the only source for the tab zoom;
the dead `overviewOpen`, `overviewClose` and `newTab` tokens are removed.

| Constant | Before | Now (verifier) |
|---|---|---|
| toOverview (open) | 0.33 / 0.91 | **0.37 / 0.875** |
| toPage (close, Done, card, new tab) | 0.335 / 1.0 from rest | **0.39 / 0.99**, launched at **8.5 progress/s** toward the page |
| Reversal | 0.39 / 0.88, keeps 1/5 of the velocity | **One-frame jump** toward the new target (20 pt of card width toward the page, 10 pt toward the grid), then the destination's spring from rest: **0.32 / 1.03** toward the page, **0.36 / 0.86** toward the grid |
| reflow | 0.38 / 0.85 | **0.43 / 0.89** |
| expandScroll / expandTap | 0.41 / 0.87, 0.37 / 0.90 | **0.385 / 0.88**, **0.39 / 0.88** |
| sideOut / sideIn | linear 0.14 / linear 0.18 after 0.12 | **linear 0.10** / **easeOut 0.23 after 0.09** |

**Pinch velocity bug (item 8).** The bug was in the old `PageSurface.pinch`,
which divided the scale by 0.94 but not the velocity. That code was replaced
by the round-6 pinch, which uses the raw `UIPinchGestureRecognizer` scale and
velocity windows from the tracked rect, so it no longer applies.

**Our app re-measured.** I logged the zoom progress per display frame from the
app (`CMUX_NEXT_BROWSER_ZOOM_TRACE=1`, Pro Max simulator, real display
timestamps). I could not reuse the verifier's video pipeline on our
recordings: the simulator recorder's variable frame stamps gave 4–6 pt RMS on
any spring fit, as the verifier also found for simulator footage.

| Transition | Safari (verifier) | Ours | |
|---|---|---|---|
| Open, settle to 0.5 pt | 440–470 ms | 433 ms (29 frames; one 67 ms simulator stall) | Within 1 frame |
| Close, settle to 0.5 pt | 480–500 ms | 467 ms (34 frames) | Within 1–2 frames |
| Close, first frame | Covers 1850–2700 pt/s | 0.139 progress (34 pt) in the first 16.7 ms frame = 2040 pt/s | Matches |

The reversal is covered by unit tests:
`reversalJumpsTowardTheNewTargetThenStartsFromRest` and `closeStartsFast`.
The DEBUG timed reversal did not fire in this trace run, so it has no
on-device frame comparison yet.

**Open y lead (item 9, not changed).** The verifier saw the content's y run
ahead of the width on open and overshoot by about 4 pt, but could not separate
the card frame from the content offset inside it. Our rect drives x, y, width
and height from one progress value. A separate y spring would only be
justified by a device recording of the frame edges. I have left it open until
such a capture exists.

## Round 7: the Tabs screen as the Mac's panes

The Tabs screen (`TabsRoot`, wired into both shells) is now a canvas of the
Mac's panes from `layout.v1`. `BrowserRoot` keeps the tab grid.

**Canvas.** Each workspace is a region under its title, stacked vertically.
Its panes are placed by their normalized rects, scaled to the phone's width
with 6 pt gaps. If a pane would be narrower than 150 pt or shorter than
190 pt, the workspace grows past the screen, so the canvas scrolls both ways.
`PaneCanvasLayoutTests` covers cmux15's split: a 0.4-wide pane on the left
widens the workspace to 390 pt. Each pane card shows its focused tab: a
browser screenshot, a live terminal thumbnail, an agent's latest message, or
a placeholder for a Mac-only tab. A count badge shows how many tabs the pane
has. Tapping a pane zooms into its tab. The zoom lands on the pane's frame,
read through the canvas's reported content origin. Before zooming out, the
canvas jumps so the pane is fully on screen.

**Press and hold** is a UIKit long press (0.35 s, 12 pt) with a medium haptic.
A SwiftUI long-press-then-drag sequence stopped the canvas from scrolling when
a drag started on a pane. The canvas blurs and dims, and the pane's tabs grow
out of the pane's rect as a paged list. The animation uses the overview spring
(0.37/0.875). Sliding scrubs at 72 pt per tab, with a selection haptic on each
tab and a rubber band at the ends. Lifting after a slide calls
`layout.focusTab` and zooms into that tab from its card. Lifting without a
slide leaves the list open: swipe it (1:1, snapping at most one tab per
flick) and tap a card to open it. Tapping outside folds the list back into
the pane.

![Canvas, hold, swipe, after picking](browser/pane-canvas-mock.png)

Mock host recordings use the DEBUG driver
(`CMUX_NEXT_BROWSER_HOLD=pane_a_left:-150`, drawn finger). They show: hold,
the list grows from the pane, scrub to the third tab, release, zoom into the
live agent session.

![Hold, scrub, release (mock)](browser/hold-scrub-release-mock.png)

Live on cmux15 (host with layout.v1, relayed over TURN, Tabs shell): three
panes, with p3 0.4 wide on the left and two terminals stacked on the right.
The canvas extends past the right edge. Holding p3 and scrubbing to its
second tab opened it.

![Hold, scrub, release (cmux15)](browser/hold-scrub-release-live.png)
![Tabs shell, light and dark, and cmux15](browser/pane-canvas-shell-live.png)

**Mac browser tabs.** A Mac-only tab opens a page with its title, address, a
letter tile, and a Liquid Glass card. With `browser.macStatus` off, the card
says "Turn on browser access on your Mac" and gives the exact setting path. It
adds "Then restart cmux on <host>" when a restart is required, and shows a
live "Waiting for <host>" line. When the host reports `on`, the tab becomes
streamable and the page switches to the live view. The pane card shows a
compact "Browser access off" pill. A Mac tab with `visibleOnMac:false`
renders nothing on the Mac. Its card gets a glass "Show on Mac" button, and
the opened tab dims its last frame under a card that explains the Mac's pane
will switch to it. Settings › Browser "Bring tabs forward on Mac
automatically" skips that tap, and `browser.attach` carries
`bringForward:true`. Screenshots are in dark mode, light mode at Accessibility
Medium text, and the opened hidden tab:

![Access banner, pill, large text, Show on Mac](browser/mac-access-banners.png)

**Tab shell.** In the tab shell the safe area ends at the status accessory.
The floating toolbar, the collapsed pill and the overview bar keep a 10 pt gap
above it. Hiding the tab bar on a page was tried and dropped: the accessory
stays visible and covers the toolbar.

**Open:** cmux15's Mac browser pane (p3) reports `kind:"other"` with no
`reason`. The phone therefore shows the generic "Open on your Mac" card
instead of the browser access banner. The host team needs to classify cmux-next
browser panes as `browser` and fill in `reason`. Terminal card images keep
the light or dark style from when they were requested until the next
`show(_:)` call.
