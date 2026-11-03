import { createContext, useLayoutEffect, useMemo } from "react";
import { flushSync } from "react-dom";

/** A geometry read returns its state update, so every sibling reads before any update applies. */
type ReadMeasurement = () => (() => void) | undefined;
type Measurement = { read: ReadMeasurement; active: boolean };

export function createCommitMeasurements(
  schedule: (run: () => void) => void = queueMicrotask,
  commit: (run: () => void) => void = flushSync,
) {
  let pending = new Set<Measurement>();
  let ticket = 0;
  let generation = 0;
  let scheduled = false;
  const flush = () => {
    ticket += 1;
    scheduled = false;
    if (!pending.size) return;
    const batchGeneration = generation;
    const batch = pending;
    pending = new Set();
    const writes: Array<{ measurement: Measurement; apply: () => void }> = [];
    for (const measurement of batch) {
      if (batchGeneration !== generation || !measurement.active) continue;
      const apply = measurement.read();
      if (apply) writes.push({ measurement, apply });
    }
    for (const { measurement, apply } of writes) if (batchGeneration === generation && measurement.active) apply();
  };
  const clear = () => {
    generation += 1;
    ticket += 1;
    scheduled = false;
    for (const measurement of pending) measurement.active = false;
    pending.clear();
  };
  const enqueue = (read: ReadMeasurement) => {
    const measurement = { read, active: true };
    pending.add(measurement);
    if (!scheduled) {
      scheduled = true;
      const queuedTicket = ++ticket;
      // A child can commit without its virtualizer rendering. Flush that work before paint,
      // outside React's effects; the parent's normal synchronous drain invalidates this ticket.
      schedule(() => {
        if (queuedTicket !== ticket) return;
        commit(flush);
      });
    }
    return () => {
      measurement.active = false;
      pending.delete(measurement);
      if (!pending.size) {
        ticket += 1;
        scheduled = false;
      }
    };
  };
  return { enqueue, flush, clear };
}

export const CommitMeasurements = createContext<ReturnType<typeof createCommitMeasurements> | null>(null);

/** Stable for a transcript's lifetime; StrictMode cleanup may be followed by another setup. */
export function useCommitMeasurements() {
  const measurements = useMemo(() => createCommitMeasurements(), []);
  useLayoutEffect(() => () => measurements.clear(), [measurements]);
  return measurements;
}
