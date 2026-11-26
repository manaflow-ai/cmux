// The chat's usage numbers as their own store: what streamingRow.ts is for a reply's text, for the
// context count, usage and time breakdown a status update moves (Leo, 2026-11-16: "you know it's
// slow. you know how to solve it"). Drawn through the pane's snapshot, each usage update rendered the
// pane root, the transcript, the header and the composer (bench/delta-renders.bench.ts `status`),
// though only the context ring, its card and Session Info's usage draw those numbers.
//
// When the client's newest snapshot differs from the one the pane drew only in the summary's usage
// fields (`usageOnly`), the pane keeps its snapshot and the newer summary goes here. The parts that
// draw usage read the summary through `useLiveSummary` and render alone. Any other change goes
// through the pane, whose summary is then the truth again (an entry names the summary it moved on
// from, so a newer drawn summary simply no longer matches it).
import { useSyncExternalStore } from "react";
import { sameConnection, type AcpmuxSnapshot } from "./model";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

let entry: { readonly drawn: Summary; readonly now: Summary } | undefined;
const listeners = new Set<() => void>();

function publish(next: typeof entry): void {
  if (entry === next) return;
  entry = next;
  for (const listener of listeners) listener();
}

export const liveSummary = {
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => void listeners.delete(listener);
  },
  /// The summary moved on from `drawn` (the pane's) to `now` without the pane.
  set(drawn: Summary, now: Summary): void {
    publish({ drawn, now });
  },
  /// The pane draws a new snapshot: its summary is the truth again. Silent: the readers render
  /// with that snapshot's summary as it commits; notifying them now would draw them a frame early,
  /// with the pane's older summary (a store's update outruns the pane's `setSnapshot`).
  clear(): void {
    entry = undefined;
  },
  get: () => entry,
};

/// The summary fields only usage readers draw: a change to these alone is not the pane's.
const USAGE_KEYS = new Set(["usage", "usageStats", "contextBreakdown", "timeBreakdown"]);

/// Whether `next` differs from `drawn` only in its summary's usage fields: the same rows, every
/// other field the same object, and the summary's other fields the same. O(fields).
export function usageOnly(drawn: AcpmuxSnapshot, next: AcpmuxSnapshot): boolean {
  if (drawn.rows !== next.rows || !drawn.summary || !next.summary || drawn.summary === next.summary) return false;
  const before = drawn as unknown as Record<string, unknown>;
  const after = next as unknown as Record<string, unknown>;
  const keys = Object.keys(after);
  if (keys.length !== Object.keys(before).length) return false;
  for (const key of keys)
    if (
      key !== "summary" &&
      !Object.is(before[key], after[key]) &&
      !(key === "connection" && sameConnection(before[key], after[key]))
    )
      return false;
  return sameButUsage(drawn.summary, next.summary);
}

/// Whether two summaries hold the same objects in every field but the usage ones. O(fields).
function sameButUsage(previous: Summary, next: Summary): boolean {
  const was = previous as unknown as Record<string, unknown>;
  const now = next as unknown as Record<string, unknown>;
  let count = 0;
  for (const key in now) {
    if (USAGE_KEYS.has(key)) continue;
    count += 1;
    if (!Object.is(was[key], now[key])) return false;
  }
  for (const key in was) if (!USAGE_KEYS.has(key)) count -= 1;
  return count === 0;
}

const none = (): undefined => undefined;

/// `summary` as it is now: the store's newer one while `summary` is the one it moved on from, or one
/// that holds the same in every other field (a reader that kept an equal older object,
/// useSessionInfo.tsx `useSameValue`). A summary the pane scoped to a subagent differs in more than
/// usage, so it keeps its own numbers.
export function useLiveSummary<T extends Summary | undefined>(summary: T): T {
  return liveOf(useSyncExternalStore(liveSummary.subscribe, liveSummary.get, none), summary);
}

function liveOf<T extends Summary | undefined>(live: typeof entry, summary: T): T {
  if (!live || summary === undefined) return summary;
  return live.drawn === summary || sameButUsage(live.drawn, summary) ? (live.now as T) : summary;
}

/// One plain value read from `summary` as it is now (useLiveSummary): its reader renders only when
/// that value changes, not on every usage update (the model chip's context percent).
export function useLiveSummaryValue<V extends string | number | boolean | undefined>(
  summary: Summary | undefined,
  select: (summary: Summary | undefined) => V,
): V {
  return useSyncExternalStore(
    liveSummary.subscribe,
    () => select(liveOf(entry, summary)),
    () => select(summary),
  );
}
