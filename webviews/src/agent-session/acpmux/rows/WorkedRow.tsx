// The `worked` row: a finished turn's "Worked for" line.
import { memo } from "react";
import { WorkedFor } from "../conversation/TurnRows";
import type { RowProps } from "./rowProps";

/// "Worked for 15s": opens the turn's commentary and tool calls (turnView in conversation/turns.ts).
export const WorkedRow = memo(
  function WorkedRow({ row, onToggleActivity, expanded, controls }: RowProps) {
    return <WorkedFor row={row} expanded={expanded} controls={controls} onToggle={() => onToggleActivity(row.id)} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.expanded === b.expanded &&
    a.controls === b.controls &&
    a.onToggleActivity === b.onToggleActivity,
);
