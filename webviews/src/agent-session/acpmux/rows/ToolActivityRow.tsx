// The `activity` row: a turn's tool calls and thoughts.
import { memo } from "react";
import { ToolRows } from "../conversation/TurnRows";
import { onlyQuietThoughts } from "../model";
import type { RowProps } from "./rowProps";

/// Tool calls and thoughts as quiet rows (inside an open "Worked for", or live).
export const ToolActivityRow = memo(
  function ToolActivityRow({ row, sessionId }: RowProps) {
    // A finished step of only quiet thoughts draws nothing: no `.cv-tools` box either, so the row's
    // article is empty and takes no room (model.ts onlyQuietThoughts, conversation.css `:empty`).
    if (onlyQuietThoughts(row)) return null;
    return <ToolRows row={row} sessionId={sessionId} />;
  },
  (previous, next) =>
    previous.row.id === next.row.id &&
    previous.row.version === next.row.version &&
    previous.sessionId === next.sessionId,
);
