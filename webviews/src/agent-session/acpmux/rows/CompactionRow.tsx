// The `compaction` row: a compaction of the chat's context.
import { memo } from "react";
import { CompactionNote } from "../conversation/CompactionNote";
import type { RowProps } from "./rowProps";

export const CompactionRow = memo(
  function CompactionRow({ row }: RowProps) {
    return row.compaction ? <CompactionNote compaction={row.compaction} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
