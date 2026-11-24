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
import { outputShapesRows } from "./conversation/toolGroups";
import { stripAnsi } from "./conversation/toolOutputModel";
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

/// `rows` as the transcript draws them now: each row with a running call whose output moved on
/// without the pane holding that newer output (`withLiveOutput`), the same array when none does.
/// For what reads the pane's rows at a person's action, not on each update: keyboard copy of a row
/// or range, and Find when it opens (review of #37907). O(rows) per call, only while an entry is
/// held; rows without one stay the same objects, so Find's per-row caches still hold.
export function rowsWithLiveOutput(rows: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  if (entries.size === 0) return rows;
  let next: AcpmuxRow[] | undefined;
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (!row.items?.length) continue;
    const live = withLiveOutput(row);
    if (live === row) continue;
    next ??= rows.slice();
    next[index] = live;
  }
  return next ?? rows;
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

/// A running call's output's end, as its next update reads it (`namesSomething`): the raw length
/// and last characters it was read to (`end`, `raw`), an escape sequence it stops inside
/// (`carry`), its last OVERLAP characters without escape sequences (`text`), and whether its last
/// word names something (`open`): a link or `#N` still being printed, which any more text without
/// a space before it changes (`http://localhost:\x1b[1m` then `5173`, `/ad` then `min`; review of
/// #37907), however long ago it started.
type Tail = {
  readonly end: number;
  readonly raw: string;
  readonly carry: string;
  readonly text: string;
  readonly open: boolean;
};
/// By call id, newest last; a call's entry goes when it stops running, and past the cap the oldest.
const tails = new Map<string, Tail>();
const TAILS_CAP = 64;
/// How far back from an output's end its last word is looked for, the first time a call is read.
const LAST_WORD_SCAN = 4096;
/// An escape sequence that has not ended yet, at the end of the text; longer than CARRY_CAP, text.
// eslint-disable-next-line no-control-regex
const UNFINISHED_ESCAPE = /\x1b(?:\[[0-?]*[ -/]*|\][^\x07\x1b]*|[()*+])?$/;
const CARRY_CAP = 256;

const isSpace = (code: number): boolean =>
  code === 32 || (code >= 9 && code <= 13) || code === 0xa0 || code === 0x2028 || code === 0x2029 || code === 0xfeff;

function lastSpace(text: string, from = text.length, stop = 0): number {
  for (let at = from - 1; at >= stop; at -= 1) if (isSpace(text.charCodeAt(at))) return at;
  return -1;
}

/// `tail` read on with `chunk`: whether the new text may name something the pane reads, with the
/// end before it, and the end after it. O(chunk).
function readOn(tail: Tail, chunk: string): { names: boolean; next: Tail } {
  const rawText = tail.carry + chunk;
  const unfinished = UNFINISHED_ESCAPE.exec(rawText);
  const cut = unfinished && rawText.length - unfinished.index <= CARRY_CAP ? unfinished.index : rawText.length;
  const plain = stripAnsi(rawText.slice(0, cut));
  const scanned = tail.text + plain;
  // A space first ends the open word as it was; any other text (or none yet) may change it.
  const continues = !(plain.length > 0 && isSpace(plain.charCodeAt(0)));
  const names = (tail.open && continues) || NAMES_SOMETHING.test(scanned);
  const space = lastSpace(plain);
  const open =
    space >= 0
      ? NAMES_SOMETHING.test(plain.slice(space + 1))
      : tail.open || NAMES_SOMETHING.test(tail.text.slice(lastSpace(tail.text) + 1) + plain);
  const end = tail.end + chunk.length;
  const raw = (tail.raw + chunk).slice(-OVERLAP);
  return { names, next: { end, raw, carry: rawText.slice(cut), text: scanned.slice(-OVERLAP), open } };
}

/// Call `id`'s output's end as of `old`: the one kept when it was read to there, else read again
/// from its last word (O(that word), up to LAST_WORD_SCAN; a longer one counts as open).
function tailOf(id: string, old: string): Tail {
  const kept = tails.get(id);
  if (kept && kept.end === old.length && old.endsWith(kept.raw)) return kept;
  const stop = Math.max(0, old.length - LAST_WORD_SCAN);
  const space = lastSpace(old, old.length, stop);
  const from = space >= 0 ? Math.max(0, space - OVERLAP) : stop;
  const start: Tail = { end: from, raw: "", carry: "", text: "", open: space < 0 && from > 0 };
  return readOn(start, old.slice(from)).next;
}

/// Whether `output`, grown from `old`, may name something new the pane reads; keeps call `id`'s
/// end for its next update.
function namesSomething(id: string, old: string, output: string): boolean {
  // The raw text too: a hyperlink's address is inside its escape sequence.
  const rawNames = NAMES_SOMETHING.test(output.slice(Math.max(0, old.length - OVERLAP)));
  const { names, next } = readOn(tailOf(id, old), output.slice(old.length));
  tails.delete(id);
  tails.set(id, next);
  if (tails.size > TAILS_CAP) tails.delete(tails.keys().next().value!);
  return rawNames || names;
}

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
  let changed: { from: Tool; to: Tool; item: AcpmuxActivity } | undefined;
  for (let index = 0; index < now.length; index += 1) {
    const a = was[index]!;
    const b = now[index]!;
    if (a === b) continue;
    if (changed || !a.tool || !b.tool || !sameExcept(a, b, ITEM_KEYS)) return undefined;
    changed = { from: a.tool, to: b.tool, item: b };
  }
  if (!changed) return undefined;
  const { from, to, item } = changed;
  if (to.status !== "in_progress") tails.delete(to.id);
  if (to.kind !== "execute" || to.status !== "in_progress" || from.id !== to.id) return undefined;
  if (!sameExcept(from, to, TOOL_KEYS)) return undefined;
  // A call's first output makes it more than a draft (toolGroups.ts `isDraftCall`), and the output
  // of a send (single or batch: each recipient's queued, delivered or failed), a who-else question
  // or a dispatch is read into rows of their own (toolGroups.ts `outputShapesRows`): both shape the
  // transcript's rows in the pane.
  if (!from.output) return undefined;
  if (shapesRows(item, to)) return undefined;
  const old = from.output;
  const output = to.output;
  if (typeof output !== "string" || output.length <= old.length || !output.startsWith(old)) return undefined;
  if (namesSomething(to.id, old, output)) return undefined;
  return { id: to.id, output, before: from.output };
}

const JSON_START = /^\s*[[{]/;

/// Whether the row readers (toolGroups.ts `outputShapesRows`) make rows of their own from this
/// running shell call. They decide that from the call's command, title and input alone, which an
/// output update leaves as they were (`TOOL_KEYS`), save one: a dispatch card also takes its kind
/// from an output that is JSON (`{"event":{"kind":…}}`). So the readers run once per call on its
/// unchanging fields, without its output (`staticShapes`), and again on each update only when its
/// output is JSON. Ordinary output costs a lookup and one regular expression per update.
function shapesRows(item: AcpmuxActivity, tool: Tool): boolean {
  if (staticShapes(item, tool)) return true;
  return JSON_START.test(tool.output ?? "") && outputShapesRows(item);
}

type ShapesMemo = {
  readonly command: string | undefined;
  readonly title: string;
  readonly inputSummary: string | undefined;
  readonly shapes: boolean;
};
/// The running calls' readings, by call id, newest last. Few calls run at once; past the cap the
/// oldest goes, and a call read again costs one more run of the readers.
const shapesMemo = new Map<string, ShapesMemo>();
const SHAPES_MEMO_CAP = 64;

function staticShapes(item: AcpmuxActivity, tool: Tool): boolean {
  const kept = shapesMemo.get(tool.id);
  if (kept && kept.command === tool.command && kept.title === tool.title && kept.inputSummary === tool.inputSummary)
    return kept.shapes;
  // Without its output: what the readers make of the call whatever it prints.
  const shapes = outputShapesRows({ ...item, tool: { ...tool, output: undefined } });
  shapesMemo.delete(tool.id);
  shapesMemo.set(tool.id, { command: tool.command, title: tool.title, inputSummary: tool.inputSummary, shapes });
  if (shapesMemo.size > SHAPES_MEMO_CAP) shapesMemo.delete(shapesMemo.keys().next().value!);
  return shapes;
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
