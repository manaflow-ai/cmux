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
