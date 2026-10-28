// The `turnSummary` row: a turn's footer.
import { memo } from "react";
import { TurnFooter } from "../conversation/TurnRows";
import type { RowProps } from "./rowProps";

export const SummaryRow = memo(
  function SummaryRow({ row }: RowProps) {
    return <TurnFooter row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
