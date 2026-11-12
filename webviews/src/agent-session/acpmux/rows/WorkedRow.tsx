import { memo } from "react";
import { WorkedFor } from "../conversation/TurnRows";
import { workEnds } from "../conversation/waterfallSpans";
import { type RowProps } from "./rowProps";

/// "Worked for 15s": opens the turn's commentary and tool calls (turnView in conversation/turns.ts).
export const WorkedRow = memo(
  function WorkedRow({ row, onToggleActivity, expanded, controls }: RowProps) {
    return <WorkedFor row={row} expanded={expanded} controls={controls} onToggle={() => onToggleActivity(row.id)} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    workEnds(a.row.workedFooter?.turnWork) === workEnds(b.row.workedFooter?.turnWork) &&
    a.expanded === b.expanded &&
    a.controls === b.controls &&
    a.onToggleActivity === b.onToggleActivity,
);
