// The `subagent` row: one subagent in an open batch.
import { memo } from "react";
import { SubagentListRow } from "../subagents/SubagentGroup";
import type { RowProps } from "./rowProps";

export const SubagentRow = memo(
  function SubagentRow({ row }: RowProps) {
    return <SubagentListRow row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
