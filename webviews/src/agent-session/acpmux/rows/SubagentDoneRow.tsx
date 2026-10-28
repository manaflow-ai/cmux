// The `subagentDone` row: where a subagent ended.
import { memo } from "react";
import { SubagentDoneLine } from "../subagents/SubagentDoneLine";
import type { RowProps } from "./rowProps";

/// Where a subagent ended, while running ones sit in the tray (subagents/SubagentDoneLine.tsx).
export const SubagentDoneRow = memo(
  function SubagentDoneRow({ row }: RowProps) {
    return <SubagentDoneLine row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
