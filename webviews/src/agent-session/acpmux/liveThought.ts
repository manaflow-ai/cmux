// A streaming thought's newer text as its own store, by row id: what streamingRow.ts is for a reply's
// text and liveToolOutput.ts for a running command's output, for the thought an activity row ends
// with (Leo, 2026-11-16: "the dream is infinite chats of infinite length with flat or no growth in
// cpu/memory/even disk"). Drawn through the pane's snapshot, each thought chunk rendered the pane
// root, its header, the composer and Session Info (bench/delta-renders.bench.ts `thought`), though
// none of them draws a thought.
//
// When the client's newest snapshot differs from the one before it only in one activity row's last
// thought growing (`thoughtOnly`), and the transcript draws that thought as the client holds it
// (`drewThoughts`), the pane keeps its snapshot and the newer thought goes here. The row that draws
// it reads it (`useLiveThoughtRow`) and renders alone. Any other change goes through the pane
// (`redraw`), and once that commits the entries made before it go (`settle`).
import { useCallback, useMemo, useSyncExternalStore } from "react";
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "./model";
import { isThought } from "./conversation/thoughts";
import { oneRowChangeFrom } from "./rowChanges";
import { rowsWithLiveOutput, sameButRows } from "./liveToolOutput";
import { rowsWithStreamingRow } from "./streamingRow";

/// A row's thought now (`to`), and the thought item the pane's rows drew (`from`): a drawn row whose
/// last item is still `from` draws `to`. `ahead`: the chunks since `from`, which the row's version
/// moves on by, so a renderer that memoizes on the version draws each one.
type Entry = {
  readonly from: AcpmuxActivity;
  readonly to: AcpmuxActivity;
  readonly ahead: number;
  readonly seq: number;
  readonly epoch: number;
};

const entries = new Map<string, Entry>();
const listeners = new Map<string, Set<() => void>>();
let seq = 0;
let epoch = 0;
/// Thought chunks drawn without the pane since it last drew, and who hears them: the live line,
/// whose "Waiting" clock counts from the turn's last event (`liveThoughtHeard`).
let heard = 0;
const lineListeners = new Set<() => void>();

export const liveThought = {
  /// Row `id`'s last thought moved on from `before` to `after` without the pane. Notifies the row
  /// that draws it, and the live line, which hears the turn go on.
  set(id: string, before: AcpmuxActivity, after: AcpmuxActivity): void {
    const kept = entries.get(id);
    const same = kept !== undefined && kept.epoch === epoch && kept.to === before;
    entries.set(id, {
      from: same ? kept.from : before,
      to: after,
      ahead: same ? kept.ahead + 1 : 1,
      seq: (seq += 1),
      epoch,
    });
    const set = listeners.get(id);
    if (set) for (const listener of set) listener();
    heard += 1;
    for (const listener of lineListeners) listener();
  },
  get: (id: string): Entry | undefined => entries.get(id),
  /// The pane is drawing a newer snapshot: a later chunk is told from that snapshot's rows.
  redraw(): number {
    heard = 0;
    return (epoch += 1);
  },
  /// The pane committed the snapshot of draw `drawnEpoch`: the entries made before it go. Silent:
  /// the rows it drew hold those thoughts.
  settle(drawnEpoch: number): void {
    for (const [id, entry] of entries) if (entry.epoch < drawnEpoch) entries.delete(id);
  },
  /// How many rows hold an entry (tests).
  get size(): number {
    return entries.size;
  },
};

/// The thought item each live-turn row of the transcript drew last, by row id (`drewThoughts`).
let drawn = new Map<string, AcpmuxActivity>();
/// The running turn's work folded out of sight under its closed "Working for" (turns.ts
/// `shapeLiveTurn`, liveTurnWork `folded`): the prompt that opened it and every row id the
/// transcript drew after it. A row of that turn the transcript did not draw is hidden in the fold,
/// and a thought growing in it stays hidden: only the person opening the fold shows it, and that
/// draws the pane again.
let folded: { readonly prompt: string; readonly shown: ReadonlySet<string> } | undefined;
/// What the transcript drew of the running turn: each row's last item when it is a thought, and
/// whether its work is folded away. Read from the end back to the turn's prompt, so O(the running
/// turn's rows), not the chat's.
export function drewThoughts(rows: readonly AcpmuxRow[] | undefined): void {
  const next = new Map<string, AcpmuxActivity>();
  const shown = new Set<string>();
  let closed = false;
  let prompt: string | undefined;
  if (rows)
    for (let index = rows.length - 1; index >= 0; index -= 1) {
      const row = rows[index]!;
      if (row.kind === "user") {
        prompt = row.id;
        break;
      }
      shown.add(row.id);
      if (row.kind === "worked" && row.turnPhase === "running" && row.foldOpen === false) closed = true;
      const last = row.kind === "activity" ? row.items?.at(-1) : undefined;
      if (last && isThought(last)) next.set(row.id, last);
    }
  drawn = next;
  folded = closed && prompt !== undefined ? { prompt, shown } : undefined;
}

/// The thought the pane's drawn rows (`paneRows`) hold for row `id` at `index` when that row is
/// hidden in the running turn's closed fold (`folded`), else undefined. The row must come after the
/// fold's prompt with no turn summary between (an ended stretch's runs draw), and draw no row.
function hiddenThought(
  rows: readonly AcpmuxRow[],
  index: number,
  id: string,
  paneRows: readonly AcpmuxRow[] | undefined,
): AcpmuxActivity | undefined {
  if (!folded || !paneRows || folded.shown.has(id)) return undefined;
  const held = paneRows[index];
  if (!held || held.id !== id) return undefined;
  for (let at = index - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (row.kind === "turnSummary") return undefined;
    if (row.kind === "user") return row.id === folded.prompt ? held.items?.at(-1) : undefined;
  }
  return undefined;
}

const ROW_KEYS = new Set(["version", "items"]);
const ITEM_KEYS = new Set(["text", "endedAt"]);

function sameThought(previous: AcpmuxActivity | undefined, next: AcpmuxActivity | undefined): boolean {
  return (
    previous !== undefined &&
    next !== undefined &&
    previous.text === next.text &&
    previous.endedAt === next.endedAt &&
    sameExcept(previous, next, ITEM_KEYS)
  );
}

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

/// The row whose last thought alone grew from `previous` to `next`, with that thought before and
/// now, else undefined. The client tells which row changed (rowChanges.ts), so this reads that row
/// alone: O(its items). Only a thought the transcript draws as the client holds it (`drewThoughts`)
/// and that already draws (not quiet: a thought's text and time only grow, so it stays drawn), or
/// one the running turn's closed "Working for" hides, as the pane's drawn rows (`paneRows`) hold it.
/// That one drew the whole pane for each chunk of a thought nobody sees (Leo, 2026-11-26: "Why
/// should non visible thing even affect the renderer thread anyways?").
export function thoughtOnly(
  previous: AcpmuxSnapshot,
  next: AcpmuxSnapshot,
  paneRows?: readonly AcpmuxRow[],
): { id: string; before: AcpmuxActivity; after: AcpmuxActivity } | undefined {
  const index = oneRowChangeFrom(next.rows, previous.rows);
  if (index === undefined || !sameButRows(previous, next)) return undefined;
  const row = previous.rows[index];
  const now = next.rows[index];
  if (!row || !now || row.id !== now.id || now.kind !== "activity" || now.streaming !== true) return undefined;
  if (!sameExcept(row, now, ROW_KEYS)) return undefined;
  const was = row.items;
  const items = now.items;
  if (!was || !items || was.length !== items.length || !items.length) return undefined;
  const last = items.length - 1;
  for (let at = 0; at < last; at += 1) if (was[at] !== items[at]) return undefined;
  const before = was[last]!;
  const after = items[last]!;
  if (!isThought(before) || !isThought(after) || before.tool || after.tool) return undefined;
  if (!sameExcept(before, after, ITEM_KEYS) || !after.text.startsWith(before.text)) return undefined;
  // A short thought is quiet once it is finished, but the live transcript deliberately keeps
  // the current thought visible while it streams. `drewThoughts` proves that this row is the one
  // currently drawing it, so its chunks can stay on the row without redrawing the pane.
  // A thought the closed fold hides stays hidden as it grows: no row draws it, so it draws nothing.
  const drawnNow = drawnThought(now.id, drawn.get(now.id) ?? hiddenThought(next.rows, index, now.id, paneRows));
  if (!sameThought(drawnNow, before)) return undefined;
  return { id: now.id, before, after };
}

/// The thought the transcript drew for row `id` (`shown`: the one in its rows, or the one the pane
/// holds for a row its fold hides), or the newer one this store gave that row since (a chunk after
/// a chunk).
function drawnThought(id: string, shown: AcpmuxActivity | undefined): AcpmuxActivity | undefined {
  const entry = entries.get(id);
  return entry && entry.epoch === epoch && sameThought(entry.from, shown) ? entry.to : shown;
}

function subscribe(id: string, listener: () => void): () => void {
  let set = listeners.get(id);
  if (!set) listeners.set(id, (set = new Set()));
  set.add(listener);
  return () => {
    set.delete(listener);
    if (set.size === 0) listeners.delete(id);
  };
}

const noSubscribe = (): (() => void) => () => {};
const zero = (): number => 0;

/// `row` with its last thought as it is now: the store's newer thought while the row's last item is
/// the one the entry moved on from.
function withLiveThought(row: AcpmuxRow): AcpmuxRow {
  const entry = entries.get(row.id);
  const items = row.items;
  if (!entry || !items?.length || items[items.length - 1] !== entry.from) return row;
  return { ...row, items: [...items.slice(0, -1), entry.to], version: row.version + entry.ahead };
}

/// The row as the transcript draws it now. Only the pane's live transcript (`active`) subscribes,
/// and only a row that ends with a thought, so a chunk renders the one row that draws it.
export function useLiveThoughtRow(row: AcpmuxRow, active: boolean): AcpmuxRow {
  const last = row.kind === "activity" ? row.items?.at(-1) : undefined;
  const listens = active && last !== undefined && isThought(last);
  const id = row.id;
  const listen = useCallback(
    (listener: () => void) => (listens ? subscribe(id, listener) : noSubscribe()),
    [listens, id],
  );
  const read = useCallback(() => {
    const entry = listens ? entries.get(id) : undefined;
    return entry && entry.from === last ? entry.seq : 0;
  }, [listens, id, last]);
  const version = useSyncExternalStore(listens ? listen : noSubscribe, listens ? read : zero, zero);
  return useMemo(() => (version === 0 ? row : withLiveThought(row)), [row, version]);
}

/// `rows` with each row's newer thought (`withLiveThought`), the same array when none has one. For
/// what reads the rows at a person's action (copy), not per chunk.
export function rowsWithLiveThoughts(rows: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  if (entries.size === 0) return rows;
  let next: AcpmuxRow[] | undefined;
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (!entries.has(row.id)) continue;
    const live = withLiveThought(row);
    if (live === row) continue;
    next ??= rows.slice();
    next[index] = live;
  }
  return next ?? rows;
}

/// `rows` as the live transcript draws them now: the streaming reply's newer text (streamingRow.ts),
/// running commands' newer output (liveToolOutput.ts) and thoughts' newer text (above). For what
/// reads the rows at a person's action: copy, Find as it opens.
export function rowsDrawnNow(rows: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  return rowsWithLiveThoughts(rowsWithLiveOutput(rowsWithStreamingRow(rows)));
}

/// Thought chunks drawn without the pane since it last drew, for the live line (turns.ts `THINKING`):
/// each is an event the turn heard. The transcript's live line pulse (conversation/liveLinePulse.ts)
/// listens here, so the line never reads "Waiting" while a thought streams and draws for none of them.
export const liveThoughtHeard = {
  subscribe(listener: () => void): () => void {
    lineListeners.add(listener);
    return () => void lineListeners.delete(listener);
  },
  get: (): number => heard,
};

/// The live line as it is now: a thought chunk drawn without the pane moves its `heardKey` on
/// (Thinking.tsx reads a new key as an event heard). The same row while none was.
export function lineHeardNow(row: AcpmuxRow): AcpmuxRow {
  if (heard === 0 || row.kind !== "thinking" || typeof row.heardKey !== "string") return row;
  return { ...row, heardKey: `${row.heardKey}~${heard}`, version: row.version + heard };
}
