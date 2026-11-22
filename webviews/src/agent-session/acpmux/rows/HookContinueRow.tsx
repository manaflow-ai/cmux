import { memo } from "react";
import { HookContinueNote } from "../conversation/HookContinueNote";
import { type RowProps } from "./rowProps";

export const HookContinueRow = memo(
  function HookContinueRow({ row }: RowProps) {
    return row.hookContinue ? <HookContinueNote note={row.hookContinue} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
