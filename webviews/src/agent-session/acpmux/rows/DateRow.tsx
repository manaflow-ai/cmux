// The `date` row: the date line over a prompt after a gap.
import { memo } from "react";
import { DateLine } from "../conversation/DateLine";
import type { RowProps } from "./rowProps";

/// "Sun, Sep 13 at 7:55 PM" over a prompt after an hour's gap (turnView in conversation/turns.ts).
export const DateRow = memo(
  function DateRow({ row }: RowProps) {
    return <DateLine row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.at === b.row.at,
);
