import { memo } from "react";
import { TurnFooter } from "../conversation/TurnRows";
import { workEnds } from "../conversation/waterfallSpans";
import { type RowProps } from "./rowProps";

export const SummaryRow = memo(
  function SummaryRow({ row }: RowProps) {
    return row.footerInWorked ? null : <TurnFooter row={row} />;
  },
  // A background shell's late end changes the footer's Timeline but not its version (workEnds).
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.row.footerInWorked === b.row.footerInWorked &&
    workEnds(a.row.turnWork) === workEnds(b.row.turnWork),
);
