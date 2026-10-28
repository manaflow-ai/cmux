// The `backgroundTask` row: a background shell's end, where it ended.
import { memo } from "react";
import { BackgroundTaskNote } from "../conversation/BackgroundTaskNote";
import type { RowProps } from "./rowProps";

export const BackgroundTaskRow = memo(
  function BackgroundTaskRow({ row }: RowProps) {
    return row.backgroundTask ? <BackgroundTaskNote task={row.backgroundTask} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
