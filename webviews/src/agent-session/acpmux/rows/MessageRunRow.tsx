import { memo } from "react";
import { MessageRunLine } from "../conversation/MessageRunLine";
import { type RowProps } from "./rowProps";

/// A run of one-line rows that carries messages between agents, folded to one line
/// (conversation/messageRuns.ts); opening it lists its rows below.
export const MessageRunRow = memo(
  function MessageRunRow({ row, onToggleActivity, expanded }: RowProps) {
    return <MessageRunLine row={row} expanded={expanded} onToggle={() => onToggleActivity(row.id)} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.expanded === b.expanded &&
    a.onToggleActivity === b.onToggleActivity,
);
