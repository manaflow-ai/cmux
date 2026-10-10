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
