# Animation verification (cmux mobile vs references)

Method: UI test drives the app on simulator `cnm-app-1` while `simctl io recordVideo` records
(variable frame rate, ~60 fps during motion); `tools/anim/track_marker.py` template-matches a
marker that rides on the moving layer and reports x per frame (pt). References come from
`docs/ANIMATION-REFERENCE.md` (online video) and `docs/IMESSAGE-SPEC.md` (simulator capture).

## Drawer (reference: ChatGPT)

| Measure | ChatGPT | cmux run r6 (before) | cmux run r9 (now) |
| --- | --- | --- | --- |
| Width | screen − 64 pt (0.835) | 330 pt (0.82, capped 360) | 338 pt (screen − 64) |
| Drawer motion | moves with content, no parallax | 22% parallax | moves with content |
| Dim | ~11% black | 22% | 11% (30% dark mode) |
| Open, first-frame speed | ~7.5 widths/s | ~2.3 widths/s | ~7.5 widths/s (50 pt/frame) |
| Close to 95% / settled | ~300 ms settled | 230 / 330 ms | 167 / 367 ms |
| Overshoot | none | none | none |
| Drag | (not captured) | follows finger 1:1 | follows finger 1:1, spring on release |

Settings: `.spring(response: 0.25, dampingFraction: 1.0)`; release response 0.18–0.30 scaled by
remaining distance and release velocity.

## Agent chat send (reference: ChatGPT, T3)

ChatGPT moves the sent prompt from the composer to the top of the screen
(`.spring(response: 0.34–0.35, dampingFraction: 1.08–1.1)`, ~430 ms) and the reply grows below.
cmux: the prompt shows immediately (before the Mac echoes it), the latest turn is given the
viewport's height, and the prompt scrolls to the top with `.spring(response: 0.35, dampingFraction: 1.0)`.
Run r11 (`testAgentPermission` follow-up, screenshots 54–56): prompt pinned at top, reply streaming
under it, send ↔ stop swap. No auto-scroll while the reply streams (T3's fix).

## Messages send (reference: iMessage capture, docs/IMESSAGE-SPEC.md §3.5)

Tracked with `tools/anim/track_bubble.py` (lowest blue bubble bbox per frame, pt).

| Phase | iMessage | cmux r15 (before) | cmux r16 |
| --- | --- | --- | --- |
| Starts as the field rect under the composer glass | yes | yes | yes |
| Width phase before rising | ~130 ms | rose immediately | ~75 ms (now 150 ms delay) |
| Leading edge slides, slight scale overshoot | 0.79 → 1.0 | x0 76 → 108 | x0 80 → 108 → 102 |
| Rise overshoot above slot | ~2.7 pt | ~8 pt (scroll + offset springs stacked) | ~2 pt |
| Tap → rest | ~680 ms | ~610 ms | ~500 ms (+ delay tuning) |

Fixes: one rise spring shared by the scroll and the row; rows keyed by client id so the
pending → confirmed swap doesn't replay the send (the "ghost bubble" in r14).

## Push / pop / edge swipe (reference: iMessage §3.1–3.3)

cmux uses the system `NavigationStack` push, which is the same UIKit navigation transition Messages
uses (measured there: push spring 0.30/0.98, 30% parallax, ~9% dim). Marker tracking on run r27 loses
the outgoing row under the incoming card, as expected for that transition; no custom animation to tune.
