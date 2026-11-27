# Pressed state: the fill changes, nothing else

Lawrence, 2026-11-15: "for all buttons, we should also not have boldness on active (mousedown) state. in
terms of design, we only want to have different bg color on mousedown."

While a button is held (mousedown, a touch, a web `:active` or a held frame), it looks like its hover with a
different background fill. Nothing else moves:

- The label keeps its weight, font, size and letter spacing. No bold on press.
- The button keeps its size, padding and place. No scale, shrink, sink, offset or rotation.
- The label and the icon keep their opacity, and the icon keeps its symbol. No dimming, no other glyph.
- A toggle that is on (`aria-pressed="true"`, Base UI `data-pressed`) may take a selected fill and ink, never
  another weight or size, so its label does not grow when it turns on.

## The shared looks

Use the shared look of the layer you are in; do not draw a pressed state by hand.

| Layer | Use | Pressed fill |
| --- | --- | --- |
| AppKit chrome (macOS) | `ChromeHover` (`CmuxNextDesign/ChromeHover.swift`), `ChromeHover.State(pressed:)` | `Palette.pressedFill` |
| SwiftUI on macOS | `.buttonStyle(.cmuxPressFill)`, `CmuxPressFillButtonStyle`, or `View.cmuxPressFill(_:rest:pressed:cornerRadius:)` in a style that sets its own font and padding (`CmuxNextDesign/GlassButtonStyle.swift`) | `Palette.pressedFill` |
| SwiftUI on iOS | `.buttonStyle(.cmuxPressFill)` (`.cmuxPressFillTinted` where `.borderless` drew the tint), `CmuxMobilePressFillStyle`, or `View.cmuxMobilePressFill(_:rest:pressed:in:)` (`CmuxMobileDesign/PressFillStyle.swift`) | `Color.cmuxMobileFillPressed`, laid over the rest fill |
| Web views | `ui/Button` (`.ui-btn`, `webviews/src/ui/controls.css`); a page's own control sets `background` only on `:active` | `var(--ds-color-pressed)` |

SwiftUI's own `.plain`, `.borderless` and `.link` styles dim the label while it is held, so cmux code uses the
styles above instead.

## Enforcement

- `scripts/cmux-next/check-pressed-state.py` (run by the pre-push gate and by cmux-next.yml's "Buttons change
  only their fill when pressed") refuses: a CSS `:active` or `[data-press-active]` rule that sets anything but
  the background (ink, a ring or a shadow pass only when the same rule also styles `:hover`); a weight, size or
  transform on an on toggle; a Tailwind `active:` class other than `active:bg-*`; Swift that reads `isPressed`,
  `pressed` or `isHighlighted` and changes a font, weight, scale, frame, padding, offset, transform, image or
  the label's opacity; and `.buttonStyle(.plain | .borderless | .link)`.
- A deliberate exception (a drag handle that follows the pointer, a key cap that travels) carries
  `pressed-state: allow <reason>` on the line or the line above it. The reason must say why the press is not a
  button press; "looks nicer" is not one.
- CodeRabbit and Greptile apply `.github/review-bot-rules/pressed-state.md` to the cases the lint cannot see
  (a pressed look set from a helper function, a JavaScript handler that adds a class on `pointerdown`).
