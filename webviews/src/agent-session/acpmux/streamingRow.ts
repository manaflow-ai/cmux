// The streaming reply's row as its own store (HOT PATH AUDIT area F, row W1,
// handoff/hot-path-audit/stream/AUDIT.md). A streamed chunk changes one thing: the text of the
// reply being written. Drawn through the pane's snapshot, each chunk re-rendered the whole pane
// (AcpmuxPane: ~20 memos over every row), the composer and Session Info, 5-11 ms of React per
// frame with 2,000 rows. Chrome's model: a change repaints what it damages.
//
// When a snapshot differs from the one the pane drew only in that row's text (`textOnly`), the
// pane keeps its snapshot and the row's newer value goes here; the transcript reads it
// (`useStreamingRow`) and draws that one row. Any other change goes through the pane as before and
// clears this store in the same turn, so the pane's own rows are the truth again. The store holds
// one value; nothing else owns it.
import { useSyncExternalStore } from "react";
import type { AcpmuxRow } from "./model";

/// The reply's raw row (the client's), how many chunks it is ahead of the row the pane drew, and
/// that drawn row's text.
export type StreamingRow = {
  readonly row: AcpmuxRow;
  readonly ahead: number;
  readonly drawnText: string;
};

let current: StreamingRow | undefined;
const listeners = new Set<() => void>();

function publish(next: StreamingRow | undefined): void {
  if (current === next) return;
  current = next;
  for (const listener of listeners) listener();
}

export const streamingRow = {
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => void listeners.delete(listener);
  },
  get: (): StreamingRow | undefined => current,
  /// The streaming row moved on without the pane: `drawn` is the raw row the pane last drew.
  set(row: AcpmuxRow, drawn: AcpmuxRow): void {
    publish({ row, ahead: row.version - drawn.version, drawnText: drawn.text ?? "" });
  },
  /// The pane draws a new snapshot: its rows are the truth again.
  clear(): void {
    publish(undefined);
  },
};

/// The text the transcript last drew for the streaming reply, by row id (`drew`): the pane's
/// transcript shapes rows (conversation/turns.ts), so the fast path is only taken while the reply's
/// drawn row is the client's row as it is (its text unchanged by the shaping).
let drawn: { id: string; text: string } | undefined;

export function drewStreamingRow(id: string | undefined, text: string | undefined): void {
  drawn = id === undefined || text === undefined ? undefined : { id, text };
}

export function drawsAsIs(row: AcpmuxRow): boolean {
  return drawn !== undefined && drawn.id === row.id && drawn.text === row.text;
}

const none = (): undefined => undefined;
const noSubscribe = (): (() => void) => () => {};

/// The streaming row the transcript draws ahead of the pane's snapshot, if any. Only the pane's
/// live transcript (`active`) subscribes; a replay, guest or other transcript never re-renders for it.
export function useStreamingRow(active: boolean): StreamingRow | undefined {
  return useSyncExternalStore(
    active ? streamingRow.subscribe : noSubscribe,
    active ? streamingRow.get : none,
    active ? streamingRow.get : none,
  );
}

/// Whether the pane may draw a streamed chunk through the row alone: false while a view that reads
/// the reply's text from the pane's snapshot is open (an artifact following an open fence, Find),
/// so that view stays exact (review of #34004).
const blockedBy = new Set<string>();

export function setStreamingRowBlocked(blocked: boolean, by: string): void {
  if (blocked) blockedBy.add(by);
  else blockedBy.delete(by);
}

export function streamingRowBlocked(): boolean {
  return blockedBy.size > 0;
}

/// Every own field of the two rows is the same, except `text` and `version`.
function sameButText(previous: AcpmuxRow, next: AcpmuxRow): boolean {
  const before = previous as unknown as Record<string, unknown>;
  const after = next as unknown as Record<string, unknown>;
  const keys = Object.keys(after);
  if (keys.length !== Object.keys(before).length) return false;
  return keys.every((key) => key === "text" || key === "version" || Object.is(before[key], after[key]));
}

/// The index of the one row `next` changes from `previous` when the change is only a streaming
/// reply's text growing, else -1. Unchanged rows keep their objects (direct.ts `OrderedRows`), so
/// the scan is one pointer compare per row.
export function textOnlyRow(previous: readonly AcpmuxRow[], next: readonly AcpmuxRow[]): number {
  if (previous === next || previous.length !== next.length) return -1;
  let changed = -1;
  for (let index = next.length - 1; index >= 0; index -= 1) {
    const before = previous[index]!;
    const after = next[index]!;
    if (before === after) continue;
    if (changed >= 0) return -1;
    if (
      after.kind !== "assistant" ||
      after.streaming !== true ||
      before.id !== after.id ||
      typeof before.text !== "string" ||
      typeof after.text !== "string" ||
      !after.text.startsWith(before.text) ||
      !sameButText(before, after)
    )
      return -1;
    changed = index;
  }
  return changed;
}
