// The transcript's rows as an external store: stage 1 of the pane split (goal long-chat-frame-p95).
// The pane's `rowsRef` is this store: every place that sets the newest rows (the live client's
// `receive`, the connect callback, the restored tail, the debug seed) already writes
// `rowsRef.current`, so assigning `current` publishes, with the same array, in the same order, before
// the pane's `setSnapshot`. Nothing reads it to draw yet, so the pane behaves as before. Later stages
// move the row derivations under it (find, marks, cards, minimap, header counts) and then let a
// record that changes only the rows skip the pane's own render.
import { createContext, useContext, useSyncExternalStore } from "react";
import type { AcpmuxRow } from "../model";

export type RowsStore = {
  /// The newest rows the client published; assigning publishes (a `RefObject` for existing callers).
  current: readonly AcpmuxRow[];
  subscribe(listener: () => void): () => void;
  snapshot(): readonly AcpmuxRow[];
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
