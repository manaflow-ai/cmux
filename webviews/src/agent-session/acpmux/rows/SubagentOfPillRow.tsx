// The `subagentOf` row: the child view's "Subagent of" pill.
import { memo } from "react";
import { SubagentOfRow } from "../subagents/SubagentGroup";
import type { RowProps } from "./rowProps";

/// The child view's "Subagent of" pill; a click goes back to the parent's view.
export const SubagentOfPillRow = memo(
  function SubagentOfPillRow({ row }: RowProps) {
    return <SubagentOfRow row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.row.text === b.row.text,
);
