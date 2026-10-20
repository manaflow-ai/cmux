// Replays a sync motion stream (schemas/sync-motion/streams.json) as one synced client sees it.
import type { SyncRow } from "./syncMotion";

export type SyncStreamOp =
  | { op: "rename"; id: string; title: string }
  | { op: "move"; id: string; before: string | null }
  | { op: "insert"; id: string; title: string; before: string | null }
  | { op: "remove"; id: string }
  | { op: "snapshot"; rows: SyncRow[] };

export type SyncStreamEvent = SyncStreamOp & { at: number; client: string; origin: "local" | "remote" };

export type SyncStream = { name: string; note: string; events: SyncStreamEvent[] };

export type SyncClient = { id: string; device_kind: string; device_name: string };

export type SyncStreamFile = {
  version: number;
  clients: SyncClient[];
  initial: SyncRow[];
  streams: SyncStream[];
};

function place(rows: SyncRow[], row: SyncRow, before: string | null): SyncRow[] {
  const rest = rows.filter((other) => other.id !== row.id);
  const index = before === null ? -1 : rest.findIndex((other) => other.id === before);
  if (index < 0) return [...rest, row];
  return [...rest.slice(0, index), row, ...rest.slice(index)];
}

/** The rows after `op`. Ops on an unknown id change nothing (the owner already refused them). */
export function applySyncOp(rows: readonly SyncRow[], op: SyncStreamOp): SyncRow[] {
  switch (op.op) {
    case "snapshot":
      return op.rows.map((row) => ({ ...row }));
    case "rename":
      return rows.map((row) => (row.id === op.id ? { ...row, title: op.title } : row));
    case "move": {
      const row = rows.find((other) => other.id === op.id);
      return row ? place([...rows], row, op.before) : [...rows];
    }
    case "insert":
      return place([...rows], { id: op.id, title: op.title }, op.before);
    case "remove":
      return rows.filter((row) => row.id !== op.id);
  }
}

/**
 * One applied batch for one client: the events that arrived in the same frame, folded. `snapshot`
 * when any event in it replaced the state; `direct` when every event in it was this client's own.
 */
export type SyncBatch = { rows: SyncRow[]; snapshot: boolean; direct: boolean };

export function foldBatch(rows: readonly SyncRow[], events: readonly SyncStreamEvent[], client: string): SyncBatch {
  let next = [...rows];
  for (const event of events) next = applySyncOp(next, event);
  return {
    rows: next,
    snapshot: events.some((event) => event.op === "snapshot"),
    direct: events.length > 0 && events.every((event) => event.client === client),
  };
}
