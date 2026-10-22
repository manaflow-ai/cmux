import { forwardRef, type ButtonHTMLAttributes } from "react";

// The one composer control (Leo 2026-10-21: "did we have a generalized solution to the weird pills?
// that you added to the bottom?"). Every control in the composer is one of two kinds:
//   - a chip: a label, maybe a leading glyph or a trailing chevron (the mode, the model button, the
//     harness);
//   - an icon: a square glyph button (+, the mic, Send, Stop, ↵, the context ring).
// Both draw from one set of tokens in composerLocation.css (`--composer-control-*`): one height, one
// chip padding on both sides, one glyph-to-text gap, one corner radius, no fill at rest and one soft
// fill on hover, as Claude Code's and Codex's controls do, and the pointing hand. The box's own
// padding is `--composer-inset`, so + sits as far from the box's left edge as from its top and
// bottom. A surface tunes a value by setting the token, never by restyling one control.
//
// A plain button is a `ComposerControl`; a trigger a menu primitive renders (the + picker, the mode
// menu's MenuButton, the model picker's button) carries the same mark through `composerControl()`.

export type ComposerControlKind = "chip" | "icon";

/** The mark the composer's metrics key on, for a trigger another component renders. */
export const composerControl = (kind: ComposerControlKind) => ({ "data-control": kind }) as const;

type ComposerControlProps = ButtonHTMLAttributes<HTMLButtonElement> & { kind: ComposerControlKind };

export const ComposerControl = forwardRef<HTMLButtonElement, ComposerControlProps>(function ComposerControl(
  { kind, type, ...props },
  ref,
) {
  return <button ref={ref} type={type === "submit" ? "submit" : "button"} {...props} data-control={kind} />;
});
