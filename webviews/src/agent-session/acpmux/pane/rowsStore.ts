// The transcript's rows as an external store: stage 1 of the pane split (goal long-chat-frame-p95).
// The pane's `rowsRef` is this store: every place that sets the newest rows (the live client's
// `receive`, the connect callback, the restored tail, the debug seed) already writes
// `rowsRef.current`, so assigning `current` publishes, with the same array, in the same order, before
// the pane's `setSnapshot`. Nothing reads it to draw yet, so the pane behaves as before. Later stages
// move the row derivations under it (find, marks, cards, minimap, header counts) and then let a
// record that changes only the rows skip the pane's own render.
import { createContext, useCallback, useContext, useRef, useSyncExternalStore } from "react";
import type { AcpmuxRow } from "../model";
import { acpmuxPerf } from "../perf";

export type RowsStore = {
  /// The newest rows the client published; assigning publishes (a `RefObject` for existing callers).
  current: readonly AcpmuxRow[];
  subscribe(listener: () => void): () => void;
  snapshot(): readonly AcpmuxRow[];
  /// Whether every pane reader of an activity row's calls follows the store on its own (`useRowsValue`):
  /// the pane draws the client's rows as they are (no row of its own drawn over them) and Session Info,
  /// which reads every call while it is open, is closed. Set after each pane render; while it holds, a
  /// record that changes only such a row may skip the pane's render (liveCallLine.ts `callOnly`).
  readersFollow: boolean;
};

export function createRowsStore(initial: readonly AcpmuxRow[] = []): RowsStore {
  let rows = initial;
  const listeners = new Set<() => void>();
  const snapshot = () => rows;
  return {
    get current() {
      return rows;
    },
    set current(next) {
      // The same array is no news: a subscriber renders only when the rows did change.
      if (next === rows) return;
      rows = next;
      for (const listener of [...listeners]) listener();
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    snapshot,
    readersFollow: false,
  };
}

const empty = createRowsStore();

/// The pane's rows store, for the transcript below it; outside a pane, an empty store.
export const TranscriptRowsContext = createContext<RowsStore>(empty);

/// The newest rows the client published, subscribed: a component reading them renders when they
/// change, whether or not the pane above it did.
export function useTranscriptRows(): readonly AcpmuxRow[] {
  const store = useContext(TranscriptRowsContext);
  return useSyncExternalStore(store.subscribe, store.snapshot, store.snapshot);
}

/// What `select` reads off the rows, subscribed to `store`: the component renders only when that value
/// changes (`same`), not on every rows change. Stage 2 of the pane split: the pane's own readers of the
/// rows (the Summary card's rows, Run in background, started sessions, background shells, render cards,
/// the edits list) read this way, so a record that changes only an activity row reaches the readers whose
/// value it moved and lets the pane's root keep its render (paneSnapshot.ts `rowsOnly`).
///
/// `shown` is the rows the pane drew (its snapshot's, with what it draws over the client's) and `client`
/// the client's rows that draw came from. While the store holds `client`, `select` reads `shown`, so a
/// pane render reads what it read before; once a record moved the store on without the pane, `select`
/// reads the store's newer rows.
export function useRowsValue<T>(
  store: RowsStore,
  select: (rows: readonly AcpmuxRow[]) => T,
  same: (a: T, b: T) => boolean,
  shown: readonly AcpmuxRow[],
  client: readonly AcpmuxRow[],
  label = "",
): T {
  const kept = useRef<{ rows: readonly AcpmuxRow[]; select: typeof select; value: T } | undefined>(undefined);
  const read = useCallback(() => {
    const newest = store.snapshot();
    const rows = newest === client ? shown : newest;
    const last = kept.current;
    if (last && last.rows === rows && last.select === select) return last.value;
    const value = select(rows);
    if (acpmuxPerf.enabled && last && !same(last.value, value)) acpmuxPerf.render(`rows-value:${label}`);
    // The same value as before keeps its object: React sees no change and does not render.
    kept.current = { rows, select, value: last && same(last.value, value) ? last.value : value };
    return kept.current.value;
  }, [store, select, same, shown, client, label]);
  return useSyncExternalStore(store.subscribe, read, read);
}

/// Two lists with the same entries in the same order.
export function sameList<T>(a: readonly T[], b: readonly T[]): boolean {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) if (!Object.is(a[i], b[i])) return false;
  return true;
}

/// Two lists of objects with the same values (each key `Object.is`) in the same order: a reader
/// that makes new objects per pass (summary/sessionSummary.ts `transcriptBackground`) reads the same.
export function sameShallowList<T extends object>(a: readonly T[], b: readonly T[]): boolean {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    const x = a[i] as Record<string, unknown>;
    const y = b[i] as Record<string, unknown>;
    if (x === y) continue;
    const keys = Object.keys(x);
    if (keys.length !== Object.keys(y).length) return false;
    for (const key of keys) if (!Object.is(x[key], y[key])) return false;
  }
  return true;
}
