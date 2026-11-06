import { memo } from "react";
import { RecapNote } from "../conversation/RecapNote";
import { type RowProps } from "./rowProps";
import { dismissRecap } from "./rowActions";

export const RecapRow = memo(
  function RecapRow({ row }: RowProps) {
    return row.recap ? <RecapNote recap={row.recap} onDismiss={() => dismissRecap(row.id)} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
