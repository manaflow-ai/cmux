// The running turn's live line as its hidden calls move it, without the pane. Under the running
// turn's closed "Working for" (drawnRows.ts) a read's start or end draws no row anyone sees, but
// the live line reads it ("Reading x", then "Thinking" from its end: turns.ts `lineCall`,
// `liveClock`), so each one redrew the whole pane: the root, its header, the transcript, the
// composer (bench/transcript-replay.bench.ts `tool_call.hidden_pane_renders_per_record`, 1 a
// record). liveThought.ts did the same for a hidden thought's chunk; a call also moves the line.
//
// The transcript notes the running turn's rows as it last shaped them (turns.ts `liveTurnShapes`)
// and the line it drew of them (`drewLiveLine`). When the client's newest snapshot changes one
// hidden call of that turn and nothing else (`callOnly`), the turn is shaped again with that one
// row (the same arguments, O(the turn's rows)); if every row but the line draws the same, the pane
// keeps its snapshot and the newer line goes here. The line's row reads it (`useLiveLineRow`) and
// renders alone; the pulse hears it (liveThought.ts `lineHeardNow`).
//
// Anything else redraws the pane (`redraw`). A pass that draws the running turn from the pane's
// older snapshot while the line is ahead of it (the fold opened, a held call let go, any row the
// transcript draws again) asks the pane to draw the newest snapshot at once (`flush`), from the
// layout effect, before that pass paints.
import { useLayoutEffect, useMemo, useSyncExternalStore } from "react";
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "./model";
import { LIVE_THINKING, THINKING, liveTurnShapes, sameShape, type LiveTurnShape } from "./conversation/turns";
import { oneRowChangeFrom } from "./rowChanges";
import { settledRead, whenSettled } from "./paneSettle";
import { sameButRows } from "./liveToolOutput";
import { drewUnderClosedFold, hiddenUnderFold } from "./drawnRows";
import { isThought } from "./conversation/thoughts";

/// The line the transcript drew (`from`) and the line as the calls since have it (`to`).
type Entry = { readonly from: AcpmuxRow; readonly to: AcpmuxRow; readonly seq: number };

/// The turn as the pane's rows hold it now, with the bypassed calls in it (`shape.turn`), the
/// line the transcript drew, and the client snapshot those rows are (`basis`).
/// `moved`: another bypass changed a row of `shape.turn` since `shape.shaped` was made of it.
type Drawn = {
  readonly shape: LiveTurnShape;
  readonly line: AcpmuxRow;
  readonly basis: AcpmuxSnapshot;
  readonly moved?: boolean;
  /// The turn's work drawn open: the running turn's rows the transcript drew, by id (`drewLiveLine`).
  readonly open?: ReadonlyMap<string, AcpmuxRow>;
};

/// Under the open fold: the turn's rows a call moved without the pane, by the row the transcript drew
/// (`from`), and the ids of those rows (`useLiveOpenRow`).
const openEntries = new Map<AcpmuxRow, { readonly to: AcpmuxRow; readonly seq: number }>();
const openIds = new Set<string>();
const openListeners = new Set<() => void>();

/// The pane draws: each `redraw` moves it on, and a shape from before it is stale.
let stamp = 0;
/// The snapshot the pane last drew (`redraw`).
let basis: AcpmuxSnapshot | undefined;
let drawn: Drawn | undefined;
let entry: Entry | undefined;
/// A call went around the pane since it last drew: its rows are older than the client's.
let ahead = false;
let seq = 0;
const listeners = new Set<() => void>();
let flush: (() => void) | undefined;

/// A call kind whose start and end show only on the line under the closed fold, and that nothing
/// outside the transcript reads off the pane's rows (no shell tray, no file list, no send).
const QUIET_KINDS = new Set(["read", "search", "fetch"]);

export const liveCallLine = {
  /// The pane draws `next`: shapes made from here on carry the new stamp, the line is told again.
  redraw(next: AcpmuxSnapshot): void {
    stamp += 1;
    liveTurnShapes.stamp(stamp);
    basis = next;
    drawn = undefined;
    ahead = false;
  },
  /// What draws the client's newest snapshot at once; returns the unregister.
  onFlush(draw: () => void): () => void {
    flush = draw;
    return () => {
      if (flush === draw) flush = undefined;
    };
  },
  /// The pane took another bypass from `previous` to `next` (a reply's or a thought's chunk, a
  /// command's output, the usage numbers): the turn's rows move on with it, or the line is told again.
  follow(previous: AcpmuxSnapshot | undefined, next: AcpmuxSnapshot): void {
    if (!drawn) return;
    if (drawn.basis !== previous) return void (drawn = undefined);
    if (next.rows === previous.rows) return void (drawn = { ...drawn, basis: next });
    const index = oneRowChangeFrom(next.rows, previous.rows);
    const was = index === undefined ? undefined : previous.rows[index];
    const now = index === undefined ? undefined : next.rows[index];
    const at = was ? drawn.shape.turn.lastIndexOf(was) : -1;
    if (!was || !now) return void (drawn = undefined);
    if (at < 0) {
      // A row not in the turn's rows (an earlier turn's, a held one): the turn is as it was.
      drawn = { ...drawn, basis: next };
      return;
    }
    const turn = drawn.shape.turn.slice();
    turn[at] = now;
    // Its shaped rows are older than `turn` now: a call shapes them again first (`callOnly`), so a
    // streamed token costs no shaping.
    drawn = { ...drawn, shape: { ...drawn.shape, turn }, basis: next, moved: true };
  },
  get: (): Entry | undefined => entry,
  /// Forgets everything (tests).
  reset(): void {
    stamp = 0;
    basis = undefined;
    drawn = undefined;
    entry = undefined;
    ahead = false;
    flush = undefined;
    openEntries.clear();
    openIds.clear();
    liveTurnShapes.stamp(0);
    liveTurnShapes.reset();
  },
};

/// The running turn's live line among the last rows the transcript drew, else undefined.
function tailLine(rows: readonly AcpmuxRow[]): AcpmuxRow | undefined {
  for (let index = rows.length - 1; index >= Math.max(0, rows.length - 8); index -= 1)
    if (rows[index]!.id === LIVE_THINKING) return rows[index];
  return undefined;
}

/// Whether each of `turn`'s rows is one of `rows`' own objects, in order, after its last prompt:
/// the turn was shaped from the pane's snapshot as the client gave it, not from older rows or
/// rows a pass made of its own.
function turnOf(turn: readonly AcpmuxRow[], rows: readonly AcpmuxRow[]): boolean {
  let at = rows.length - 1;
  for (let index = turn.length - 1; index >= 0; index -= 1) {
    const row = turn[index]!;
    while (at >= 0 && rows[at] !== row) {
      if (rows[at]!.kind === "user" && row.kind !== "user") return false;
      at -= 1;
    }
    if (at < 0) return false;
    at -= 1;
  }
  return true;
}

/// What the transcript drew of the running turn (VirtualTranscript, after liveThought.ts
/// `drewThoughts` told the fold). While the line is ahead of the pane, a pass that drew another
/// line, or the turn's work open, draws the pane's older rows: the pane draws the newest at once.
export function drewLiveLine(rows: readonly AcpmuxRow[] | undefined): void {
  const line = rows ? tailLine(rows) : undefined;
  const closed = drewUnderClosedFold();
  const open = closed || !rows ? undefined : runningTurnRows(rows);
  if (ahead) {
    if (line && line === entry?.from && (closed ? !drawn?.open : drawn?.open && sameRows(drawn.open, open))) return;
    drawn = undefined;
    ahead = false;
    flush?.();
    return;
  }
  // The pass drew the pane's own rows: what went around it is in them now.
  openEntries.clear();
  openIds.clear();
  // The same line as before: the rows the bypasses followed since still hold.
  if (drawn && drawn.line === line && (closed ? !drawn.open : drawn.open && sameRows(drawn.open, open))) return;
  const shape = liveTurnShapes.last();
  if (open) {
    // The turn's work drawn open: each of its rows the transcript drew is one the pass shaped, so a
    // call's change to one of them can go to that row alone (`callOnly`, `useLiveOpenRow`).
    drawn =
      line &&
      basis &&
      shape &&
      shape.stamp === stamp &&
      drewShaped(shape.shaped, open) &&
      turnOf(shape.turn, basis.rows)
        ? { shape, line, basis, open }
        : undefined;
    return;
  }
  // The transcript draws the line `steadyRows` kept (turns.ts): an equal line drawn before stands
  // in for the one this pass shaped, so the shaped line need only hold the same values.
  drawn =
    line &&
    closed &&
    basis &&
    shape &&
    shape.stamp === stamp &&
    sameShape(shape.shaped.at(-1), line, COMPARE_DEPTH) &&
    turnOf(shape.turn, basis.rows)
      ? { shape, line, basis }
      : undefined;
}

/// The running turn's rows `rows` holds (back to its prompt), by id.
function runningTurnRows(rows: readonly AcpmuxRow[]): Map<string, AcpmuxRow> | undefined {
  const turn = new Map<string, AcpmuxRow>();
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const row = rows[index]!;
    if (row.kind === "user") return turn;
    turn.set(row.id, row);
  }
  return undefined;
}

function sameRows(a: ReadonlyMap<string, AcpmuxRow>, b: ReadonlyMap<string, AcpmuxRow> | undefined): boolean {
  if (!b || a.size !== b.size) return false;
  for (const [id, row] of a) if (b.get(id) !== row) return false;
  return true;
}

/// Whether the transcript drew each of the turn's shaped rows (past its prompt), and only those.
function drewShaped(shaped: readonly AcpmuxRow[], open: ReadonlyMap<string, AcpmuxRow>): boolean {
  let count = 0;
  for (const row of shaped) {
    if (row.kind === "user") continue;
    const drew = open.get(row.id);
    if (!drew || !sameShape(drew, row, COMPARE_DEPTH)) return false;
    count += 1;
  }
  return count === open.size;
}

/// A row of the open turn drew `row`: while calls are ahead of the pane, a row they moved that is not
/// the one they moved on from draws the pane's older state, so the pane draws the newest at once.
function drewOpenRow(row: AcpmuxRow): void {
  if (!ahead || !openIds.has(row.id) || openEntries.has(row)) return;
  drawn = undefined;
  ahead = false;
  flush?.();
}

/// The line's row drew `row`: a line drawn ahead of the pane that is not the one the entry moved
/// on from draws the pane's older state, so the pane draws the newest at once.
function drewLineRow(row: AcpmuxRow): void {
  if (!ahead || row === entry?.from) return;
  drawn = undefined;
  ahead = false;
  flush?.();
}

/// What a call moves on its activity row (direct.ts): its calls, its version, whether one is still
/// running and how many it holds. The row is shaped again with them, so the turn's other rows must
/// still draw the same.
const ROW_KEYS = new Set(["version", "items", "streaming", "toolCount"]);
/// As deep as turns.ts `steadyRows` compares: rows equal to that depth draw the same.
const COMPARE_DEPTH = 4;

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

/// Debug (replay bench RENDERS=1): the check the last `callOnly` failed on.
let lastMiss = "";
function missed(at: string): undefined {
  lastMiss = at;
  return undefined;
}
export const callOnlyMiss = (): string => lastMiss;
const closedNow = (): boolean => drewUnderClosedFold();

/// A call whose start or end draws only on the live line.
function quietCall(item: AcpmuxActivity | undefined): boolean {
  const tool = item?.tool;
  return tool !== undefined && tool.kind !== undefined && QUIET_KINDS.has(tool.kind) && tool.background === undefined;
}

/// Calls the pane reads only through readers that follow the rows store (pane/rowsStore.ts
/// `useRowsValue`: Run in background, background shells, the Summary card's content): a command or
/// a think call, never an edit (the header's Changes), a subagent or a call with diffs.
const FOLLOWED_KINDS = new Set([...QUIET_KINDS, "execute", "think"]);

/// An item whose change the transcript draws as the reshaped turn says and the pane's readers follow
/// on their own: a followed call, or a thought (it draws in the run only once it is not quiet, and the
/// reshape below tells when it would).
function followedItem(item: AcpmuxActivity | undefined): boolean {
  if (!item) return true;
  const tool = item.tool;
  if (!tool) return isThought(item);
  return tool.kind !== undefined && FOLLOWED_KINDS.has(tool.kind) && !tool.diffs?.length;
}

function sameItem(from: AcpmuxActivity | undefined, to: AcpmuxActivity): boolean {
  if (!from) return true;
  if (from.tool || to.tool) return from.tool?.id === to.tool?.id;
  return from.kind === to.kind;
}

/// The running turn's line after the client's newest snapshot `next`, when it differs from the one
/// before it (`previous`) only in one hidden activity row's quiet calls (one more, or one moved on)
/// and the turn shaped again draws every other row the same, else undefined.
///
/// `followed` (pane/rowsStore.ts `readersFollow`): every pane reader of a command's or thought's row
/// follows the rows store, so the row need not be hidden and its change may be a command, a think
/// call or a thought too; the reshape still says the transcript draws every other row the same. Before,
/// each such record redrew the whole pane: 516 of 1,124 pane renders a replay window under load (bench
/// replay-under-load RENDERS=1, `redraw:rows(+0,1:activity)`, most a thought still quiet or a running
/// command the run leaves to the live line; goal renderer-main-busy).
export function callOnly(
  previous: AcpmuxSnapshot,
  next: AcpmuxSnapshot,
  followed = false,
): { line: AcpmuxRow; rows: readonly (readonly [AcpmuxRow, AcpmuxRow])[] } | undefined {
  if (!drawn) return missed(`nodrawn(${closedNow() ? "closed" : "open"})`);
  if (drawn.open && !followed) return missed("open/unfollowed");
  if (drawn.basis !== previous) return missed("basis");
  const index = oneRowChangeFrom(next.rows, previous.rows);
  if (index === undefined || !sameButRows(previous, next)) return missed("notrows");
  const was = previous.rows[index];
  const now = next.rows[index];
  if (!was || !now || was.id !== now.id || now.kind !== "activity" || was.kind !== "activity") return missed("notact");
  if ((!followed && !hiddenUnderFold(next.rows, index)) || !sameExcept(was, now, ROW_KEYS))
    return missed("hidden/keys");
  const before = was.items ?? [];
  const after = now.items ?? [];
  if (after.length < before.length || after.length > before.length + 1) return missed("len");
  let changed = 0;
  for (let at = 0; at < after.length; at += 1) {
    const from = before[at];
    const to = after[at]!;
    if (from === to) continue;
    changed += 1;
    if (followed) {
      if (!followedItem(to) || !followedItem(from) || !sameItem(from, to)) return missed("kind");
    } else if (!quietCall(to) || (from && (!quietCall(from) || from.tool!.id !== to.tool!.id))) return missed("quiet");
  }
  if (changed === 0) return missed("none");
  const { shape } = drawn;
  const at = shape.turn.lastIndexOf(was);
  if (at < 0) return missed("notinturn");
  const turn = shape.turn.slice();
  turn[at] = now;
  const shaped = liveTurnShapes.reshape(shape, turn);
  const old = drawn.moved ? liveTurnShapes.reshape(shape, shape.turn) : shape.shaped;
  if (shaped.length !== old.length) return missed("shapedlen");
  const last = shaped.length - 1;
  // Every other row the same in each value, as `steadyRows` keeps a drawn row: a renderer may draw
  // from fields its version does not cover (transcript/RowFrame.tsx `RowContent`), so the same
  // version is not enough. Under the open fold a row may change in place: the row the transcript
  // drew of its id draws the new one (`useLiveOpenRow`).
  const rows: [AcpmuxRow, AcpmuxRow][] = [];
  for (let row = 0; row < last; row += 1) {
    if (sameShape(old[row], shaped[row], COMPARE_DEPTH)) continue;
    const drew = drawn.open && old[row]!.id === shaped[row]!.id ? drawn.open.get(old[row]!.id) : undefined;
    if (!drew) return missed(`row${row}/${last}:${shaped[row]!.kind}`);
    rows.push([drew, shaped[row]!]);
  }
  const line = shaped[last]!;
  if (line.id !== LIVE_THINKING || line.kind !== THINKING) return missed("noline");
  drawn = { ...drawn, shape: { ...shape, turn, shaped }, basis: next, moved: false };
  return { line, rows };
}

/// Debug (replay bench RENDERS=1): why a one-activity-row record is not a `callOnly` one.
export function callMiss(previous: AcpmuxSnapshot, next: AcpmuxSnapshot): string {
  const index = oneRowChangeFrom(next.rows, previous.rows);
  if (index === undefined) return "multi";
  const was = previous.rows[index];
  const now = next.rows[index];
  if (!was || !now || now.kind !== "activity") return "notact";
  const hidden = hiddenUnderFold(next.rows, index) ? "hidden" : "shown";
  const keys = Object.keys(now).filter((k) => !ROW_KEYS.has(k) && !Object.is((was as any)[k], (now as any)[k]));
  const before = was.items ?? [];
  const after = now.items ?? [];
  const items: string[] = [];
  for (let at = 0; at < after.length; at += 1) {
    const from = before[at];
    const to = after[at]!;
    if (from === to) continue;
    const t = to.tool;
    const f = from?.tool as Record<string, unknown> | undefined;
    const fields =
      t && f
        ? Object.keys(t)
            .filter((k) => !Object.is(f[k], (t as any)[k]))
            .sort()
            .join("+")
        : from
          ? "item"
          : "new";
    items.push(`${to.kind}/${t?.kind ?? "-"}${t?.background ? "/bg" : ""}:${fields}`);
  }
  return `${hidden}|keys=${keys.join("+") || "-"}|${items.slice(0, 2).join(",")}${items.length > 2 ? ",+" : ""}`;
}

/// The pane kept its snapshot for a hidden call: the line the transcript drew is `line` now.
export function setLiveLine(line: AcpmuxRow): void {
  if (!drawn) return;
  const kept = entry?.from === drawn.line ? entry : undefined;
  // A call that leaves the line's words, counts and look as they are (a read's end under one that runs
  // on, its status only) draws nothing new: the line keeps its render and reads `line` at its next one.
  // Before, every hidden call drew the line again (`content` 1 a tool_call record).
  if (drawsSame(kept?.to ?? drawn.line, line)) {
    entry = { from: drawn.line, to: line, seq: kept?.seq ?? 0 };
    ahead = true;
    return;
  }
  entry = { from: drawn.line, to: line, seq: (seq += 1) };
  ahead = true;
  whenSettled("call-line", () => {
    for (const listener of listeners) listener();
  });
}

/// Under the open fold: the turn's rows the pane kept its snapshot for draw these (`callOnly`'s
/// `rows`, from the row the transcript drew to the row the turn shapes now).
export function setOpenRows(rows: readonly (readonly [AcpmuxRow, AcpmuxRow])[]): void {
  if (rows.length === 0) return;
  for (const [from, to] of rows) {
    openEntries.set(from, { to, seq: (seq += 1) });
    openIds.add(from.id);
  }
  ahead = true;
  whenSettled("open-rows", () => {
    for (const listener of openListeners) listener();
  });
}

const subscribeOpen = (listener: () => void): (() => void) => {
  openListeners.add(listener);
  return () => void openListeners.delete(listener);
};

/// The open turn's row as the calls since the pane drew have it. Only the pane's live transcript
/// (`active`) listens; a call renders only the rows it moved.
export function useLiveOpenRow(row: AcpmuxRow, active: boolean): AcpmuxRow {
  const listens = active && row.kind !== "user" && row.id !== LIVE_THINKING;
  const read = useMemo(() => settledRead(() => openEntries.get(row)?.seq ?? 0), [row]);
  const version = useSyncExternalStore(listens ? subscribeOpen : noSubscribe, listens ? read : zero, zero);
  useLayoutEffect(() => {
    if (listens) drewOpenRow(row);
  }, [listens, row]);
  return version === 0 ? row : (openEntries.get(row)?.to ?? row);
}

/// Whether `a` and `b` draw the same line: the same in every value but the row's version.
function drawsSame(a: AcpmuxRow, b: AcpmuxRow): boolean {
  return a.id === b.id && sameShape({ ...a, version: 0 }, { ...b, version: 0 }, COMPARE_DEPTH);
}

/// Lines moved by calls without the pane, for the live line's pulse (VirtualTranscript).
export const liveCallLineHeard = {
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => void listeners.delete(listener);
  },
};

/// `row`, or the line as the calls since the pane drew have it when `row` is the line drawn then.
export function lineCalledNow(row: AcpmuxRow): AcpmuxRow {
  return entry && row === entry.from ? entry.to : row;
}

const noSubscribe = (): (() => void) => () => {};
const zero = (): number => 0;
const subscribe = (listener: () => void) => liveCallLineHeard.subscribe(listener);

/// The row as the transcript draws it now. Only the pane's live transcript (`active`) listens, and
/// only its live line, so a hidden call renders that one row.
export function useLiveLineRow(row: AcpmuxRow, active: boolean): AcpmuxRow {
  const listens = active && row.id === LIVE_THINKING;
  const read = useMemo(() => settledRead(() => (entry && entry.from === row ? entry.seq : 0)), [row]);
  const version = useSyncExternalStore(listens ? subscribe : noSubscribe, listens ? read : zero, zero);
  useLayoutEffect(() => {
    if (listens) drewLineRow(row);
  }, [listens, row]);
  return version === 0 ? row : lineCalledNow(row);
}
