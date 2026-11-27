import { memo } from "react";
import { TaskLines } from "../conversation/TaskLine";
import { type RowProps } from "./rowProps";

/// A finished turn's started sub-sessions, one line each beside its fold (conversation/TaskLine.tsx).
export const TaskLineRow = memo(
  function TaskLineRow({ row }: RowProps) {
    return row.tasks?.length ? <TaskLines tasks={row.tasks} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
