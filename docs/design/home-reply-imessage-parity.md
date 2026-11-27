# Home reply quote: macOS Messages parity

User, 2026-10-28: "this reply ui is still bad". Target: macOS 27 Messages, threaded replies.

## Reference

The user's 2x screenshot of Messages (dark), with the Home screenshot it replaced. The
screenshots show personal messages, so they are in the private hq repo, not here:
`cmuxterm-hq/docs/design/home-reply-imessage-parity/` (`reference-imessage-dark-2x.png`,
`before-home-dark-2x.png`, and the before/after renders from `HomeReplyQuoteCaptureTests`).

Not captured: cmux-lawrence-2 refused SSH (connection reset at key exchange). The cmux-lawrence
mini's Messages window returned an empty accessibility tree behind a keychain prompt. There is
no light-mode or open-thread-view reference yet.

## Measurements (2x pixels / 2 = pt; colours converted from Display P3 to sRGB)

Quote of my root (the reply's root is not right above it):

| | Messages | Home before | Home after |
|---|---|---|---|
| text | 10 pt regular (48-char line 229 pt) | 12 pt | 10 pt |
| text inset | 8 pt left, 9 pt right | 12 / 12 | 8 / 9 |
| height, 1 line | 23.5 pt, half-circle ends | 28 | 23.5 |
| height, 2 lines | 34.5 pt (11 pt pitch), half-circle ends | 46 (15 pt pitch) | 34.5 |
| first baseline | 16 pt under the top | centred | 16 |
| outline | 1 pt, sRGB 56/96/139 | 1 pt, outgoing blue 2/132/254 | 56/96/139 |
| text colour | sRGB 60/124/212 | outgoing blue | 60/124/212 |
| tail | outlined, hangs 4 pt under the right end | none | bubble tail at 0.8 (4.1 pt) |
| "N Replies" | 10 pt semibold, ink ends 11 pt in, baseline 14 pt under | 10 pt bold, 6 pt in, 13.75 | 10 pt semibold, 10.5 pt in, 14 |
| reply top under quote top | 48.5 pt (1 line), 59 (2 lines) | 52.5, no arc | 48.5 |
| arc | grey, ~2.75 pt stroke, 14.5 pt right of the reply's left edge, r ~18.5 pt, ends 42 pt right of it, level 2 pt under the quote's middle | none | the existing reply arc (x +14.25, r 19, end +43), level 2 pt under the quote's middle |

The arc in Messages is the same arc a reply right under its root gets, so Home reuses that
connector (`connectorRoot` = the preview row; `RowSpec.connectorAnchorY`).

## Not changed

- The Chief's quoted root (left side) keeps its faded gray fill (Lawrence's 2026-10-27 reference); it takes the
  new size and tail.
- "N Replies" colour stays `PreviewStyle.repliesBlue` (Messages in the screenshot: sRGB 77/163/248, its window
  background 40 against Home's 30).
- Light mode and themed accents mix the outgoing blue into the background (45 % outline, 85 % text); not
  checked against a light Messages reference.
- The open thread view.

## Tests

`Packages/Shared/CmuxMessagesLab/Tests/MessagesLabHomeTests/HomeReplyQuoteParityTests.swift` (red first,
then green); `HomeReplyQuoteCaptureTests` writes `.build/home-reply-quote.png` (dark and light).
