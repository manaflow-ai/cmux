# Home group replies to other people: macOS Messages parity

User, 2026-10-29 (NIGHTLY): "for imessage ui make sure we handle other people responding to other
people". Target: the user's 2x dark screenshot of a macOS Messages group chat (two teammates, a
text root, a link card root and a 3-line root, each answered further down by the other person).
The screenshot shows personal messages, so it is not in this repo.

## Measurements (2x pixels / 2 = pt, dark, transcript background sRGB 30)

| | Messages | Home before | Home after |
|---|---|---|---|
| quote left edge | the bubble column (45 pt; bubbles 45 pt) | the 1:1 edge, under the avatar column | bubble column (`leftEdge + bubbleInset`) |
| quote look | 1 pt outline sRGB 80, text 129 (incoming text at 1/2) | grey fill at 0.55 | outline `mix(incomingText, background, 0.5)`, all at 0.5 |
| quote tail | outlined tail under the bottom left, text and card | text only | text and card |
| quoted person's avatar | 18 pt disc, half opacity, bottom 4 to 4.5 pt under the quote, centred on the avatar column | none | 18 pt, 0.5, 4.25 pt under, avatar column centre |
| line | 2.5 pt, sRGB 66 (`Fixture.connector`), from 6 to 6.5 pt under that avatar to the reply bubble's top | 2.5 pt stub at x 32.5, 12.5 pt long | avatar column, 6.25 pt under the avatar to the bubble top |
| reply | name (11 pt) and avatar kept; bubble top 35 pt under the quote's bottom (text and card) | name and avatar; 38 pt | 35 pt |
| root with one reply further down | "1 Reply" 16 pt in from the bubble's left | no label (2 or more only) | "1 Reply" at `labelLeft + bubbleInset` |
| long root | 3 lines whole (45.5 pt, 11 pt pitch) | 2 lines, cut with "…" | 3 lines |

Not measured: a light-mode reference (light colours use the same mixes, UNVERIFIED), a reply
with a tapback badge (the line stops at the row bitmap's 24 pt margin), and my own reply to
another person's message (Home draws the quote and avatar without the line).

## Tests

`HomeGroupReplyQuoteTests` (geometry and pixels through `RowBuilder` and `RowDraw`) and
`HomeGroupReplyCaptureTests` (the user's scene dark and light, `.build/home-group-reply.png`).
