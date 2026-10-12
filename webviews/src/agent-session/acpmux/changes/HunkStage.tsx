// A hunk's Stage hunk (Unstaged) or Unstage hunk (Staged), under its last changed line (cx-ncc.74).
import React from "react";
import { useT } from "../i18n";
import type { HunkAnchor } from "./hunkReview";

export function HunkStage({ anchor, unstage, onPress }: { anchor: HunkAnchor; unstage: boolean; onPress: () => void }) {
  const t = useT();
  return (
    <div className="acpmux-hunk-actions">
      <button
        type="button"
        className="acpmux-hunk-stage"
        aria-label={t(unstage ? "hunk.unstageAt" : "hunk.stageAt", { line: anchor.label })}
        onClick={onPress}
      >
        {t(unstage ? "hunk.unstage" : "hunk.stage")}
      </button>
    </div>
  );
}
