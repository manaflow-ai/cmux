// The `activityLine` row: the running turn's line under its todo list.
import { memo } from "react";
import { ActivityLine } from "../conversation/ActivityLine";
import type { RowProps } from "./rowProps";

/// The running turn's activity line under its todo list (agent.sessionStatus, cx-ncc.102).
export const ActivityLineRow = memo(
  function ActivityLineRow({ row }: RowProps) {
    return <ActivityLine row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.row.at === b.row.at,
);
