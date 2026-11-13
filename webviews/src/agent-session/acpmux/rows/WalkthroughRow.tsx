import { memo } from "react";
import { Walkthrough } from "../conversation/Walkthrough";
import { type RowProps } from "./rowProps";

/// The browser walkthrough a turn ran, under its answer (conversation/Walkthrough.tsx).
export const WalkthroughRow = memo(
  function WalkthroughRow({ row }: RowProps) {
    return row.walkthrough ? <Walkthrough id={row.id} walkthrough={row.walkthrough} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
