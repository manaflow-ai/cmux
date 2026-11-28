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
import { startTransition, useLayoutEffect, useRef, useState } from "react";
import type { AcpmuxRow } from "./model";
import { keptPrefix } from "./conversation/prefixFlatMap";

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

/// The tail of the rows the transcript last told its draw from (measuring only, the bench's redraw table).
export let drewTail = "never";
let drewIds: ReadonlySet<string> = new Set();
export function noteDrewTail(tail: string, ids: ReadonlySet<string>): void {
  drewTail = tail;
  drewIds = ids;
}
/// Where the transcript's last told rows have `row` (measuring only): drawn, or absent and whether
/// it ran in a background turn.
export function drewPlace(row: AcpmuxRow): string {
  return drewIds.has(row.id) ? "in-pane" : `absent,bg=${row.inBackground === undefined ? "n" : "y"}`;
}

/// How the transcript's drawn reply stands to `row`, for the replay bench's redraw table (measuring only).
export function drawnReplyState(row: AcpmuxRow): string {
  if (!drawn) return `none@${drewPlace(row)}`;
  if (drawn.id !== row.id) return "other-id";
  const text = row.text ?? "";
  if (drawn.text === text) return "as-is";
  return text.startsWith(drawn.text) ? "behind" : drawn.text.startsWith(text) ? "ahead" : "shaped";
}

export function drawsAsIs(row: AcpmuxRow): boolean {
  return drawn !== undefined && drawn.id === row.id && drawn.text === row.text;
}

/// The streaming row the transcript draws ahead of the pane's snapshot, if any. Only the pane's
/// live transcript (`active`) subscribes; a replay, guest or other transcript never re-renders for it.
///
/// Each streamed frame's draw is a transition: React renders it in 5 ms slices and a key goes
/// between them, so a key waits for at most one slice, not for the whole transcript's render. As
/// an external store (`useSyncExternalStore`) every frame's draw was a sync render in the frame's
/// microtask that no input could cut into: the largest share of the wait before a key reached the
/// page while a reply streamed (every chat page shares one renderer, CEFSwitches
/// `processPerSitePageSchemes`, so another chat's stream held the key too). A slice the stream's
/// next frame overtakes renders the newer row; the transcript reads `live` only while its row
/// still shows `drawnText`, so a draw that lands after the pane's own redraw shows nothing stale.
export function useStreamingRow(active: boolean): StreamingRow | undefined {
  return useStreamingRowCatchUp(active).live;
}

/// `useStreamingRow`, with `catchUp`: called inside a synchronous render the transcript runs anyway
/// (a flushSync placing a row that grew), it takes the newest chunk into that render. The chunk's own
/// transition then finds the value it would set already drawn and commits nothing. A reply's row
/// grows a line while a chunk's transition still waits, about 70 times in 74 on a streamed reply
/// (test/agent-pane-stream-renders.test.ts): each was a second whole transcript pass for one chunk.
export function useStreamingRowCatchUp(active: boolean): { live: StreamingRow | undefined; catchUp: () => void } {
  const [live, setLive] = useState<StreamingRow | undefined>(() => (active ? current : undefined));
  // Written in the effect, not the render (the React Compiler skips a hook that writes a ref while it
  // renders). A catch-up in the render before this effect reads the last committed `active`, and the
  // hook's own result is gated on this render's `active` either way.
  const activeRef = useRef(active);
  useLayoutEffect(() => {
    activeRef.current = active;
    if (!active) return;
    // A frame that landed between the render and this effect.
    setLive(current);
    return streamingRow.subscribe(() => startTransition(() => setLive(current)));
  }, [active]);
  const [catchUp] = useState(() => () => {
    if (activeRef.current) setLive(current);
  });
  return { live: active ? live : undefined, catchUp };
}

/// `row` drawn with `live`: the reply's newer text and version, or the live line's `quietKey` naming
/// the reply's newer version (turns.ts `quietKey`: the line stays quiet while the reply's text moves).
export function streamedRow(row: AcpmuxRow, live: StreamingRow): AcpmuxRow {
  if (row.kind === "assistant") {
    if (row.id !== live.row.id || row.text !== live.drawnText) return row;
    return { ...row, text: live.row.text, version: row.version + live.ahead };
  }
  const key = row.quietKey;
  if (typeof key !== "string") return row;
  const at = key.lastIndexOf(":");
  if (at < 0 || key.slice(0, at) !== live.row.id) return row;
  const version = Number(key.slice(at + 1));
  if (!Number.isFinite(version)) return row;
  return { ...row, quietKey: `${live.row.id}:${version + live.ahead}`, version: row.version + live.ahead };
}

/// `rows` with the streaming reply's newer text (`streamedRow`), the same array when there is none.
/// For what reads the rows at a person's action (copy, Find as it opens), not per chunk.
export function rowsWithStreamingRow(rows: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  const live = current;
  if (!live) return rows;
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const row = rows[index]!;
    if (row.id !== live.row.id) continue;
    const next = streamedRow(row, live);
    if (next === row) return rows;
    const copy = rows.slice();
    copy[index] = next;
    return copy;
  }
  return rows;
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
/// reply's text growing, else -1. Unchanged rows keep their objects (direct.ts `OrderedRows`), and
/// the client says how many leading rows a snapshot kept (prefixFlatMap.ts `keptPrefix`), so only
/// the rows past those are compared: a token in a 35,000-row chat compares its own row, not every row.
export function textOnlyRow(previous: readonly AcpmuxRow[], next: readonly AcpmuxRow[]): number {
  if (previous === next || previous.length !== next.length) return -1;
  const kept = keptPrefix(previous, next);
  let changed = -1;
  for (let index = next.length - 1; index >= kept; index -= 1) {
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
