import { memo } from "react";
import { type RowProps } from "./rowProps";

/// The session start row ("Claude Code · Opus 5.5", sessionStart.ts) draws nothing in the transcript
/// (Lucas, 2026-11-06: it landed inside the first turn's work and read as noise). The row stays in
/// the store: HarnessStatusCard reads Claude Code's version from it, and the model shows in the
/// composer's picker. SessionStartNote is kept for the gallery.
export const SessionStartRow = memo(
  function SessionStartRow(_props: RowProps) {
    return null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
