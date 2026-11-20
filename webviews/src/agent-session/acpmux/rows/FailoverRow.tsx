import { memo } from "react";
import { FailoverNote } from "../conversation/CompactionNote";
import { type RowProps } from "./rowProps";

export const FailoverRow = memo(
  function FailoverRow({ row }: RowProps) {
    return row.failover ? <FailoverNote failover={row.failover} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
