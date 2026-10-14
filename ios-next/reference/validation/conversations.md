# CNConversationsUI validation (Messages parity)

Module: `Packages/CmuxNextMobile/Sources/CNConversationsUI` (UIKit inside, public SwiftUI
root `ConversationsRoot(connection:)`). Reference: [`../imessage.md`](../imessage.md).
Device: iPhone 17 Pro simulator (iOS 27, 402 x 874 pt) on the remote build Mac, slot `conv`,
`CMUX_NEXT_DEV_SCREEN=conversations` (MockHost data). Captured 2026-10-09.

Evidence in this folder:

| File | What |
| --- | --- |
| `conversations/list-light-overlay.png`, `list-dark-overlay.png` | ref, impl, 50% blend, abs diff (list) |
| `conversations/row-light-overlay.png` | row-aligned overlay: ref row 1 (y 168) vs impl row 1 (y 306, below the pinned grid) |
| `conversations/thread-light-overlay.png`, `thread-dark-overlay.png` | ref, impl, blend, diff (thread) |
| `conversations/anim-*.png` | per-animation strips: reference recording (top) vs implementation (bottom), same step from each onset |
| `conversations/trace-*.txt` | DEBUG display-link trace of every spring the module drives (`CMUX_CONV_TRACE=1`): label, frame timestamp, t, value |
| `conversations/tools/` | `rec.sh` (record while driving AXe), `edge.py` (edge tracker), `springfit.py`, `tracefit.py`, `collapse.py`, `sheet.py`, `onset.py` |

Implementation recordings: `~/nxios-ref/impl/conversations/*.mp4` (not in git).

## Method, and why there are two timing columns

1. **In-app trace** (exact). Every animation the module drives itself runs on `SpringDriver`
   (analytic SwiftUI spring on `CADisplayLink`). The DEBUG trace logs the value at each
   frame's `targetTimestamp`; `tracefit.py` fits `spring(response, damping)` to it. This is what
   the app renders, frame by frame, with 0 dropped frames after the first.
2. **Recording vs recording** (same pipeline). Reference and implementation recordings were
   both made with `simctl io recordVideo` and measured with the same tracker (`edge.py`) and
   fitter (`springfit.py`). The remote host ran at load average 100-540 during capture (the
   reference was captured at 400-900), so recordings drop and bunch frames; both pipelines also
   compress the clock similarly (Apple's push, specified as 0.28 s, measures 0.19 s in its own
   recording; ours, traced at exactly 0.28 s, measures 0.195 s). Compare the two recording
   columns with each other, not with the spec.

`framediff.py` was run on every pair (`fd/*/report.txt`, kept out of git); with whole-frame
crops its onset/progress metrics are dominated by unrelated changes (highlight, keyboard,
different content), so its durations are not meaningful here. The `anim-*.png` strips and
the trackers above replace it.

## Animations

| Animation | Reference spec | In-app trace (fit) | Ref recording (fit) | Impl recording (fit) | Result |
| --- | --- | --- | --- | --- | --- |
| Push list -> thread | spring 0.28 / 1.0, 99% 295 ms (18 fr) | 0.280 / 1.00, 99% 300 ms (18 fr) | 0.190 / 1.00, 201 ms (12 fr) | 0.195 / 1.00, 207 ms (12 fr) | pass (≤1 fr) |
| Pop (back button) | 0.27 / 1.0, 285 ms (17 fr) | 0.270 / 1.00, 300 ms (18 fr) | not measurable: pop1 has 37 ms frames and a 200 ms gap | 0.215 / 1.00, 228 ms (14 fr) | pass vs spec; ref recording unusable |
| List parallax / dim | x = -0.30 W (1-p), black 0.10 (1-p) | implemented exactly (`ConvTransition.apply`) | | visible in `anim-push.png`, `anim-pop.png` | pass |
| Header hold + crossfade | hold ~100 ms, fade ~60 ms, no translation | `TimedDriver` 160 ms, counter-translated | | header fixed in strips | pass, no blur (see mismatches) |
| Interactive edge back | 1:1 tracking, velocity-projected completion | release at p 0.27, 0.73 -> 0 on 0.27 s spring with release velocity, 99% 283 ms | p .40 -> .70 in 65 ms | p .27 -> .84 in 117 ms (in-app) ≈ 82 ms recording clock | close; see mismatches |
| Swipe actions snap | critically damped ~450 ms | close: 0.430 / 1.00, 467 ms (28 fr) | open snap -134.6 -> -130 | card edge 247.7 -> 270 in ~300 ms (recording) | pass |
| Swipe geometry | 50 pt circles, 10 gaps, open -130 / +70 | -130 trailing; +130 leading (2 actions) | card rests at x 270.7 | card rests at x 270.0 | pass (leading has 2 actions by task) |
| Timestamp reveal | 0.30 x finger, saturates 60-70; return 0.43 / 1.0, 450 ms (27 fr) | return 0.430 / 1.00, 467 ms (28 fr) | max 52.7 pt for 180 pt finger; return 0.290 / 1.00, 307 ms | max 51.0 pt for 180 pt; return 0.275 / 1.00, 291 ms | pass (1 fr, 1.7 pt) |
| Send: bubble flight | 0.45 / 0.84, ~19 fr | 0.450 / 0.84, 99% 317 ms (19 fr), overshoot 0.8% | squash, lift, land with tail (send3) | same sequence: fill over the field, squash, lift, land; slot bubble hidden until landing (`anim-send.png`, re-recorded) | pass (shape/sequence); recorder bunches the first ~150 ms |
| Send: transcript shift | 0.30 / 1.0 | `UIView.animate(springDuration: 0.30, bounce: 0)` around the batch update | | | pass by construction |
| Delivered move | 0.33 / 0.94 | `springDuration 0.33, bounce 0.06`; receipt stays on the previous message until delivered | | visible in recording | pass |
| Tapback | scale ~1.08 linear while held, menu at ~1.0 s, dim to white x 0.8 in 150 ms | 0.12 s press -> linear scale to 1.08 by 0.5 s; menu at 1.0 s (gesture min duration); panels spring 0.250 / 0.80, 16 fr | menu at ~+900 ms after first visible change | menu at ~+1000 ms after first visible change (scale start) | pass (±1 strip step) |
| Context menu | spring ~0.25 / 0.80, preview r30, menu w250 | system `UIContextMenuInteraction` (same system animation) | | `anim-ctx.png` | pass (system) |
| Large title collapse | title 1:1, cap top 128; inline title at offset ~54 | cap top 128.0, inline fades in 67 ms at offset 54, large out 40 ms | cap top 128.0 -> 73.7 | cap top 128.0 -> 74.3 (gone at 54) | pass |
| Typing indicator | [K] 3 x 9 pt dots, 1.2 s period, 0.3 s phase | as specified (CAKeyframe), enters with 0.6 scale pop | n/a | `typing` screenshot in `anim-send.png` run | implemented per [K] |

## Static geometry (light; dark uses the same layout)

| Element | Reference | Measured | Pass |
| --- | --- | --- | --- |
| Large title | 34 bold, x16, AX y 119.7, h 40.7, cap top 128 | (16, 119.7, 370 x 40.7), cap top 128.0 | yes |
| Title separator / first row | y 168 / 176 | divider 8 pt above row 1 (rows start below the pinned grid) | yes |
| Row height | 86.7 | 86.7 | yes |
| Avatar | 45, x26, row+20 | 45 at (26, row+20) | yes |
| Title | 17 semibold, x83, cap top row+16.0 | x83, cap top row+16.0 | yes |
| Preview | 15, 2 lines, w303, cap top title+21.7 | w303, cap top title+21.7 | yes |
| Date | 15, right edge 365.7 | right edge 365.7 | yes |
| Chevron | 10.3 x 14, right edge 386 | x 375.7..386 | yes |
| Separator | x83-386, 1 pt | x83-386, 1/3 pt hairline | no: hairline is thinner (cmux style) |
| Search capsule | x28-374, y798, h48, r24 | x28-316 + 48 pt compose circle (x326-374), y798, h48 | changed by task (compose) |
| Bubble 1 line | h 40, capsule | 39.7 + AA | yes |
| Line pitch | 20 | 3-line bubble 80.0 | yes |
| Sent right edge / received left edge | 386 / 16 | 386.0 / 16 | yes |
| Max width / min width | 280 / ~48 | 280 / 48 ("Ok") | yes |
| Tail (sent), inner edge at B+0.3..6.3 | R-20.3, -18.7, -17.3, -16.0, -14.3, -12.7, -10.3 | R-19.7, -18.3, -17.0, -15.7, -14.7, -13.0, -11.0 | yes (≤0.7) |
| Tail outer edge B..B+6 | R-10.3 .. R-8.7 | R-10.3 .. R-8.7 | yes |
| Back button | 44 glass at (16, 62) | (16, 62, 44, 44) | yes |
| Header avatar / pill | 60 at x171 y62 / pill y117 h32.3 | 60 centered at y62 / y117 h32.3 | yes |
| "+" button | 40 at (28, 806) | (28, 806, 40, 40) | yes |
| Field | x80-374, y805.7, h40.3, r20 | x80-374, h 40.3 | yes |
| Send capsule | 38 x 28, inset 6.3 | 38 x 28, inset 6.3 (ink fill, not blue) | yes |
| Receipt | 11 semibold, right edge R-21, ink ~8 under body | same rule | yes |

Colors follow `CNDesign` by design: outgoing bubble = `outgoingBubble` (ink), incoming =
`incomingBubble`, unread dot = ink, avatars on `groupHue` / `chiefAvatar`, swipe actions on
`highlight` / `attention` / group hue / `danger`. The overlays therefore differ in color, not geometry.

## Re-recording at lower host load (14:34, load ~15)

Send, pop and interactive back were re-recorded (`~/nxios-ref/impl/conversations/rerecord/`,
trace `conversations/trace-rerecord.txt`). The in-app trace is unchanged (push 0.280/1.00,
pop 0.270/1.00, send 0.450/0.84 with 0.8% overshoot, edge completion 0.245/1.00 from p 0.73).
Even at load ~15 the simulator recorder still bunches the first frames of each transition
(3-8 ms PTS spacing, then a catch-up), so pop measures 0.150/1.00 in the recording versus 0.215
earlier; recording fits for pop and edge back stay inconclusive. The re-recorded send exposed a
real bug, now fixed: the landing slot's bubble was visible during the flight because
`configure` reset the alpha that the layout attributes had set (dequeue applies attributes
first). Body visibility now goes through one path for both. `anim-send.png`, `anim-pop.png`
and `anim-edge.png` are from the re-recording.

## E2E fixes (2026-10-09, from `e2e.md`)

| Bug | Fix | Verified |
| --- | --- | --- |
| 1 Tabs: tab bar stays hidden after the accessory opens Agents | Root applies `.toolbarVisibility(.hidden, for: .tabBar)` only while a thread is on screen (nav `willShow`/`didShow`); SwiftUI scopes it to the Home tab, so switching tabs or popping restores the bar | Tabs: Chief thread (bar hidden) -> accessory -> Agents with bar -> Home (thread, hidden) -> back (bar back) |
| 11 Raw Markdown | `ConvMarkdown`: inline Markdown (bold, italic, code, strike, links underlined in ink) in bubbles; previews and Copy use plain text | Chief thread shows `dist/` in monospace, no backticks |
| 12 No indicator while an agent runs | Store tracks `agent.list` / `agent.session` status; `agent:<sessionId>` conversations show the typing bubble while the session is `running` | code path (MockHost agent conversations do not use the `agent:` id) |
| 21 Header overlap | Intro is one line (subtitle or kind), never the header name, in the lower slot | dark Chief thread |
| Shell chrome | Search/compose bar and composer stay above the tab bar and bottom accessory (safe area) | `conversations/shells-drawer-tabs.png` |

## Remaining mismatches (honest list)

- **Recording quality.** Under the remote host's load the recorder drops or bunches frames
  (the reference pop1 has 37 ms frames and a 200 ms gap; our re-recordings at load ~15 still
  bunch transition starts).
  Timing claims rest on the in-app trace plus same-pipeline comparisons where both recordings
  were trackable (push, timestamp return, swipe snap, collapse). Re-record on an idle host for
  frame-exact video evidence of send, pop and edge back.
- **Interactive back.** The tracked fraction at release was 0.27 for a 160 pt AXe swipe: AXe's
  final move arrives with the `.ended` touch under load. The page now lands on the release
  fraction before springing, and tracks the finger 1:1 by construction, but 1:1 tracking was
  not re-verified in video. Completion is ~20-30% slower than the reference's 65 ms (recording
  clock).
- **Header crossfade has no blur.** The reference blurs the outgoing header (~10 pt Gaussian)
  while fading; we only fade (no public per-view blur filter).
- **No pinned-grid, delete, pin or typing reference** ([K] in the spec). Pin/unpin flies the
  avatar on spring 0.45 / 0.85 between row and grid; delete uses the collection view's
  removal inside a 0.3 s critically damped spring. Untested against a recording.
- **Tapback reactions are local only** (the protocol has no reaction method): choosing one
  dismisses the menu. The action menu has Copy and Share (no Translate/Select).
- **Row separator** is a 1/3 pt hairline instead of the reference's 1 pt line.
- **Swipe start flake.** One right swipe from x=30 under load did not open (card moved 16 pt
  then closed); repeating from x=40 worked. The cell's pan begins only for horizontal
  velocity and the burst AXe events can read as a short drag.
- **Context menu preview height** is the system's (about 395 pt here) rather than the
  reference's 528 pt; `preferredContentSize` asks for 528.
