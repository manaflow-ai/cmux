// The `notice` and `typing` rows, and any kind no renderer claims: one muted line.
import { memo } from "react";
import type { RowProps } from "./rowProps";

export const NoticeRow = memo(
  function NoticeRow({ row }: RowProps) {
    return <div className="acpmux-muted">{row.text}</div>;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
