// A hunk's Reject and Accept, or its decision with Undo, under its last changed line.
import React from "react";
import type { FocusAfter, HunkAnchor, HunkDecision } from "./hunkReview";

export function HunkActions({
  anchor,
  decision,
  onDecide,
  focusAfter,
}: {
  anchor: HunkAnchor;
  decision?: HunkDecision;
  onDecide: (decision: HunkDecision | undefined) => void;
  focusAfter: FocusAfter;
}) {
  const decide = (next: HunkDecision | undefined) => {
    focusAfter.current = anchor.key;
    onDecide(next);
  };
  // The pressed button is replaced, so the one that replaces it takes focus.
  const takeFocus = (node: HTMLButtonElement | null) => {
    if (node && focusAfter.current === anchor.key) {
      focusAfter.current = undefined;
      node.focus();
    }
  };
  if (decision === "requested")
    return (
      <div className="acpmux-hunk-actions" data-decision={decision}>
        <output>Revert requested</output>
      </div>
    );
  if (decision)
    return (
      <div className="acpmux-hunk-actions" data-decision={decision}>
        <output>{decision === "accepted" ? "Accepted" : "Rejected"}</output>
        <button
          ref={takeFocus}
          type="button"
          className="acpmux-hunk-undo"
          aria-label={`Undo, ${anchor.label}`}
          onClick={() => decide(undefined)}
        >
          Undo
        </button>
      </div>
    );
  return (
    <div className="acpmux-hunk-actions">
      <button
        ref={takeFocus}
        type="button"
        className="acpmux-hunk-reject"
        aria-label={`Reject change at ${anchor.label}`}
        onClick={() => decide("rejected")}
      >
        Reject
      </button>
      <button
        type="button"
        className="acpmux-hunk-accept"
        aria-label={`Accept change at ${anchor.label}`}
        onClick={() => decide("accepted")}
      >
        Accept
      </button>
    </div>
  );
}
