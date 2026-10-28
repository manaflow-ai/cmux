// The `policyUnenforced` row: a permission policy the chat's harness cannot keep.
import { memo } from "react";
import { PolicyUnenforcedNote } from "../conversation/CompactionNote";
import type { RowProps } from "./rowProps";

export const PolicyUnenforcedRow = memo(
  function PolicyUnenforcedRow({ row }: RowProps) {
    return row.policyUnenforced ? <PolicyUnenforcedNote note={row.policyUnenforced} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
