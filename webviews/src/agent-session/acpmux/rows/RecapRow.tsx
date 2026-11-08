import { memo } from "react";
import { RecapNote } from "../conversation/RecapNote";
import { type RowProps } from "./rowProps";
import { dismissRecap } from "./rowActions";

export const RecapRow = memo(
  function RecapRow({ row }: RowProps) {
    const recap = row.recap;
    return recap ? <RecapNote recap={recap} onDismiss={() => dismissRecap(row.id, recap.key)} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// A recap in a read-only, replayed or read-only subagent transcript: no ×, which would do nothing
/// for a guest and act on the live chat from the others.
export const ReadOnlyRecapRow = memo(
  function ReadOnlyRecapRow({ row }: RowProps) {
    return row.recap ? <RecapNote recap={row.recap} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
