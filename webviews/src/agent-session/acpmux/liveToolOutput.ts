// A running command's newer output as its own store, by call id: what streamingRow.ts is for a
// streamed reply's text, for a shell call's output (Leo, 2026-11-04: "It should just never, ever
// ... be [freaking] acceptable for there to be some sort of linear time growth degradation").
// Drawn through the pane's snapshot, each output update rendered the pane, its header and Session
// Info once (bench/delta-renders.bench.ts: 1.02, 1.02 and 1.05 renders per update at 50 to 5,000
// rows), though none of them draws a call's output while it runs.
//
// When the client's newest snapshot differs from the one before it only in one shell call's output
// growing (`toolOutputOnly`), and the new text names nothing the pane reads out of a call's output
// (a link, a `#N`, a repository: the header's Preview, Session Info's pull requests, bare `#N`
// scopes), the pane keeps its snapshot and the call's newer output goes here. The transcript's row
// that draws the call reads it (`useLiveToolRow`) and renders alone. Any other change goes through
// the pane as before (`redraw`), and once that commits the entries made before it go (`settle`):
// its rows are the truth again. The store holds one entry per call updated since the pane drew.
import { useMemo, useSyncExternalStore } from "react";
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "./model";
import { acpmuxSendCall } from "./conversation/acpmuxSends";
import { oneRowChangeFrom } from "./rowChanges";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// A call's output now (`output`), and its output in the rows the pane drew (`drawn`): a row whose
/// call still has that output takes the newer one; any other row is newer than this entry.
/// `epoch`: the pane's draws asked for before it (`redraw`). `ahead`: the updates it holds since
/// `drawn`, which the row's version moves on by, so a renderer that memoizes on the version (every
/// row renderer) draws each one, as the client's own version does (direct.ts: +1 per update).
type Entry = {
  readonly output: string;
  readonly drawn: string | undefined;
  readonly ahead: number;
  readonly seq: number;
  readonly epoch: number;
};

const entries = new Map<string, Entry>();
const listeners = new Map<string, Set<() => void>>();
let seq = 0;
let epoch = 0;

function notify(id: string): void {
  const set = listeners.get(id);
  if (set) for (const listener of set) listener();
}

export const liveToolOutput = {
  /// Call `id`'s output moved on to `output` without the pane; `before` is its output in the
  /// snapshot this one follows. Notifies only the rows that draw that call.
  set(id: string, output: string, before: string | undefined): void {
    const kept = entries.get(id);
    const same = kept !== undefined && kept.epoch === epoch;
    const drawn = same ? kept.drawn : before;
    entries.set(id, { output, drawn, ahead: same ? kept.ahead + 1 : 1, seq: (seq += 1), epoch });
    notify(id);
  },
  get: (id: string): Entry | undefined => entries.get(id),
  /// The pane is drawing a newer snapshot: an update after this one is told from that snapshot's
  /// rows. Entries from before stay until it commits, for rows drawn from the older rows meanwhile.
  redraw(): number {
    return (epoch += 1);
  },
  /// The pane committed the snapshot of draw `drawnEpoch`: every row it drew holds each call's
  /// output as of then, so the entries made before it go. Silent: such an entry's row drew its
  /// new row in that commit, which no longer has the entry's `drawn` output (`useLiveToolRow`).
  settle(drawnEpoch: number): void {
    for (const [id, entry] of entries) if (entry.epoch < drawnEpoch) entries.delete(id);
  },
  /// How many calls hold an entry (tests).
  get size(): number {
    return entries.size;
  },
};

function subscribe(ids: readonly string[], listener: () => void): () => void {
  for (const id of ids) {
    let set = listeners.get(id);
    if (!set) listeners.set(id, (set = new Set()));
    set.add(listener);
  }
  return () => {
    for (const id of ids) {
      const set = listeners.get(id);
      if (!set) continue;
      set.delete(listener);
      if (set.size === 0) listeners.delete(id);
    }
  };
}

/// The calls a row draws (its activity items' tools), one list while the row is the same object.
const callIds = new WeakMap<AcpmuxRow, readonly string[]>();
const NO_IDS: readonly string[] = [];

function idsOf(row: AcpmuxRow): readonly string[] {
  if (!row.items?.length) return NO_IDS;
  let ids = callIds.get(row);
  if (!ids) {
    const found: string[] = [];
    for (const item of row.items) if (item.tool?.id && item.tool.status === "in_progress") found.push(item.tool.id);
    ids = found.length ? found : NO_IDS;
    callIds.set(row, ids);
  }
  return ids;
}

const noSubscribe = (): (() => void) => () => {};
const zero = (): number => 0;

/// The row as the transcript draws it now: `row`, with each running call whose output moved on
/// without the pane (the store above) holding its newer output. Only the pane's live transcript
/// (`active`) subscribes, and each row only to its own running calls, so an update renders the one
/// row that draws that call: O(1) in the transcript's length.
export function useLiveToolRow(row: AcpmuxRow, active: boolean): AcpmuxRow {
  const ids = active ? idsOf(row) : NO_IDS;
  const items = row.items;
  const listen = useMemo(() => (ids.length ? (listener: () => void) => subscribe(ids, listener) : noSubscribe), [ids]);
  // The newest entry's number among the row's calls: it changes with each of their updates.
  const read = useMemo(
    () =>
      ids.length
        ? () => {
            // An entry counts only while the row holds the output it moved on from.
            let newest = 0;
            for (const item of items!) {
              const entry = item.tool ? entries.get(item.tool.id) : undefined;
              if (entry && entry.drawn === item.tool!.output) newest = Math.max(newest, entry.seq);
            }
            return newest;
          }
        : zero,
    [ids, items],
  );
  const version = useSyncExternalStore(listen, read, zero);
  return useMemo(() => (version === 0 ? row : withLiveOutput(row)), [row, version]);
}

function withLiveOutput(row: AcpmuxRow): AcpmuxRow {
  let ahead = 0;
  const items = row.items!.map((item) => {
    const tool = item.tool;
    const entry = tool ? entries.get(tool.id) : undefined;
    if (!tool || !entry || entry.drawn !== tool.output) return item;
    ahead += entry.ahead;
    return { ...item, tool: { ...tool, output: entry.output } };
  });
  return ahead ? { ...row, items, version: row.version + ahead } : row;
}

/// What a running command's new output may name that the pane reads out of a call's output: a
/// link (the header's Preview, Session Info's pull requests: `://`), a `#N`, a GitHub address or a
/// `-R`/`--repo` flag (bare `#N` scopes, conversation/bareReferences.ts). New text with any of these
/// goes through the pane.
const NAMES_SOMETHING = /:\/\/|#|github\.com|-R|--repo/;
/// The earlier output's end read with the new text, so a name split across two updates is seen.
const OVERLAP = 16;

/// The call whose output alone moved on from `previous` to `next`, with its output before and now,
/// else undefined. The client tells which row changed (`markOneRowChange`), so this reads that row
/// alone: O(1) in the transcript's length, and O(its items) plus the new text.
export function toolOutputOnly(
  previous: AcpmuxSnapshot,
  next: AcpmuxSnapshot,
): { id: string; output: string; before: string | undefined } | undefined {
  const index = oneRowChangeFrom(next.rows, previous.rows);
  if (index === undefined || !sameButRows(previous, next)) return undefined;
  const before = previous.rows[index];
  const after = next.rows[index];
  if (!before || !after || before.id !== after.id || after.kind !== "activity") return undefined;
  if (!sameExcept(before, after, ROW_KEYS)) return undefined;
  const was = before.items;
  const now = after.items;
  if (!was || !now || was.length !== now.length) return undefined;
  let changed: { from: Tool; to: Tool } | undefined;
  for (let index = 0; index < now.length; index += 1) {
    const a = was[index]!;
    const b = now[index]!;
    if (a === b) continue;
    if (changed || !a.tool || !b.tool || !sameExcept(a, b, ITEM_KEYS)) return undefined;
    changed = { from: a.tool, to: b.tool };
  }
  if (!changed) return undefined;
  const { from, to } = changed;
  if (to.kind !== "execute" || to.status !== "in_progress" || from.id !== to.id) return undefined;
  if (!sameExcept(from, to, TOOL_KEYS)) return undefined;
  // A call's first output makes it more than a draft (toolGroups.ts `isDraftCall`), and a send's
  // output says whether it went (acpmuxSends.ts): both shape the transcript's rows in the pane.
  if (!from.output || (to.command?.includes("acpmux") && acpmuxSendCall(to))) return undefined;
  const old = from.output;
  const output = to.output;
  if (typeof output !== "string" || output.length <= old.length || !output.startsWith(old)) return undefined;
  if (NAMES_SOMETHING.test(output.slice(Math.max(0, old.length - OVERLAP)))) return undefined;
  return { id: to.id, output, before: from.output };
}

const ROW_KEYS = new Set(["version", "items"]);
const ITEM_KEYS = new Set(["tool"]);
const TOOL_KEYS = new Set(["output"]);

/// Every own field of the two objects is the same, except those in `except` (which may be absent
/// on one side).
function sameExcept(previous: object, next: object, except: ReadonlySet<string>): boolean {
  const before = previous as Record<string, unknown>;
  const after = next as Record<string, unknown>;
  let count = 0;
  for (const key in after) {
    if (except.has(key)) continue;
    count += 1;
    if (!Object.is(before[key], after[key])) return false;
  }
  for (const key in before) if (!except.has(key)) count -= 1;
  return count === 0;
}

/// Every field of the two snapshots is the same object, except `rows`.
export function sameButRows(drawn: AcpmuxSnapshot, next: AcpmuxSnapshot): boolean {
  const before = drawn as unknown as Record<string, unknown>;
  const after = next as unknown as Record<string, unknown>;
  const keys = Object.keys(after);
  if (keys.length !== Object.keys(before).length) return false;
  for (const key of keys) if (key !== "rows" && !Object.is(before[key], after[key])) return false;
  return true;
}
