// A hunk's Reject and Accept, or its decision with Undo, under its last changed line.
import React from "react";
import { useT } from "../i18n";
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
  const t = useT();
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
        <output>{t("hunk.revertRequested")}</output>
      </div>
    );
  if (decision)
    return (
      <div className="acpmux-hunk-actions" data-decision={decision}>
        <output>{t(decision === "accepted" ? "hunk.accepted" : "hunk.rejected")}</output>
        <button
          ref={takeFocus}
          type="button"
          className="acpmux-hunk-undo"
          aria-label={t("hunk.undoAt", { line: anchor.label })}
          onClick={() => decide(undefined)}
        >
          {t("hunk.undo")}
        </button>
      </div>
    );
  return (
    <div className="acpmux-hunk-actions">
      <button
        ref={takeFocus}
        type="button"
        className="acpmux-hunk-reject"
        aria-label={t("hunk.rejectAt", { line: anchor.label })}
        onClick={() => decide("rejected")}
      >
        {t("hunk.reject")}
      </button>
      <button
        type="button"
        className="acpmux-hunk-accept"
        aria-label={t("hunk.acceptAt", { line: anchor.label })}
        onClick={() => decide("accepted")}
      >
        {t("hunk.accept")}
      </button>
    </div>
  );
}
