import { memo } from "react";
import { BackgroundTurnLine } from "../conversation/BackgroundTurnLine";
import { type RowProps } from "./rowProps";

/// A turn the agent ran on its own, folded to one line (conversation/backgroundTurns.ts); opening it
/// lists its rows below.
export const BackgroundTurnRow = memo(
  function BackgroundTurnRow({ row, onToggleActivity, expanded }: RowProps) {
    return <BackgroundTurnLine row={row} expanded={expanded} onToggle={() => onToggleActivity(row.id)} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.expanded === b.expanded &&
    a.onToggleActivity === b.onToggleActivity,
);
