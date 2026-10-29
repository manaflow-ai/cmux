// The `sessionStart` row: where a Claude Code session started.
import { memo } from "react";
import { SessionStartNote } from "../conversation/SessionStartNote";
import type { RowProps } from "./rowProps";

export const SessionStartRow = memo(
  function SessionStartRow({ row }: RowProps) {
    return row.sessionStart ? <SessionStartNote start={row.sessionStart} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
