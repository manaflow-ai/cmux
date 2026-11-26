import type { ReactNode } from "react";
import "./RowSlots.css";

/// The slots a transcript row's line fills, which RowFrame (VirtualTranscript.tsx) places (doc
/// transcript-motion-model.md, "`RowFrame` slots: `lead`, `body`, `actions`, `meta`. Each row kind
/// fills slots; the frame places them."): `lead` (a glyph, a switcher), `body` (the line's words),
/// `meta` (an age, a delivery note) in that order from the start, and `actions` in a fixed slot at
/// the line's end edge. So an action never moves with the words before it: at every text length
/// Copy's right edge is the line's right edge (rule 10, invariant I10; Leo, 2026-11-17: "STOP
/// MAKING THE COPY BUTTON MOVE WITH THE TEXT WHY WAS IT NOT JUST AT THE RIGHT EDGE").
///
/// `lead`, `body` and `meta` draw as the line's own items (no box of their own), so the rules a
/// row kind's items already have still reach them; `actions` is the one box, the end slot.
export function RowSlots({
  lead,
  body,
  meta,
  actions,
  className,
}: {
  lead?: ReactNode;
  body?: ReactNode;
  meta?: ReactNode;
  actions?: ReactNode;
  className?: string;
}) {
  return (
    <span className={["cv-row-slots", className].filter(Boolean).join(" ")}>
      {lead}
      {body}
      {meta}
      {actions !== undefined && actions !== null && actions !== false && (
        <span className="cv-row-slots__actions">{actions}</span>
      )}
    </span>
  );
}
