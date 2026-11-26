// The full-height thread minimap's model (ScrollMap.tsx): the rail spans the transcript's viewport
// and maps the whole scroll height onto it, so every message draws where it is in the chat. Pure
// functions over the transcript's layout, so nothing here measures a row.
import type { AcpmuxRow } from "../model";
import { geometryOf, type GeometrySource } from "../conversationGeometry";
import { THREAD_PADDING_TOP, type MinimapTurn } from "./model";

/// Space kept above and below the rail inside the transcript's viewport.
export const MAP_MARGIN = 12;
/// The rail shows once the chat has this many prompts and is taller than its viewport.
export const MAP_MIN_PROMPTS = 2;
/// A hover or press within this many px of a mark is on it; farther is on the track.
export const MAP_HIT = 6;
/// The bar for the view is never shorter than this, so a long chat's stays easy to grab.
export const MAP_MIN_THUMB = 18;
/// The rail's bands: of the prompts (and of the replies) in one band this tall, the first draws
/// for the rest (a long chat has thousands of rows; mapMarks).
const MERGE_PX = 3;
/// The fisheye by px from the pointer: marks within these distances grow by these shares.
const FISHEYE: ReadonlyArray<readonly [number, number]> = [
  [MAP_HIT, 1],
  [14, 0.6],
  [24, 0.3],
  [36, 0.12],
];

export type MapMark = {
  kind: "user" | "agent";
  /// The row's index in the transcript rows.
  row: number;
  /// The turn it belongs to (an index into the minimap's turns), or -1 before the first prompt.
  turn: number;
  /// Its center on the rail, px from the rail's top.
  y: number;
};

/// The first and last marks whose y lies in [top, bottom]. Marks are generated top to bottom, so
/// binary search keeps the scroll-frame update bounded by the visible map range instead of scanning
/// every row in a long transcript.
export function marksIn(
  marks: readonly MapMark[],
  top: number,
  bottom: number,
): { first: number; last: number } | undefined {
  let low = 0;
  let high = marks.length;
  while (low < high) {
    const middle = low + Math.floor((high - low) / 2);
    if (marks[middle]!.y < top) low = middle + 1;
    else high = middle;
  }
  const first = low;
  if (first >= marks.length || marks[first]!.y > bottom) return undefined;

  low = first;
  high = marks.length;
  while (low < high) {
    const middle = low + Math.floor((high - low) / 2);
    if (marks[middle]!.y <= bottom) low = middle + 1;
    else high = middle;
  }
  return { first, last: low - 1 };
}

/// Where content offset `top` (a row's layout top) draws on a rail `height` tall.
export function mapY(top: number, total: number, height: number): number {
  if (total <= 0 || height <= 0) return 0;
  return Math.max(0, Math.min(height, ((top + THREAD_PADDING_TOP) / (total + THREAD_PADDING_TOP)) * height));
}

/// The scroll offset whose view is centered on rail point `y`.
export function scrollTopAt(y: number, height: number, total: number, viewportHeight: number): number {
  const at = (Math.max(0, Math.min(height, y)) / Math.max(1, height)) * (total + THREAD_PADDING_TOP);
  return Math.max(0, Math.min(total - viewportHeight, at - viewportHeight / 2));
}

/// The bar for what is on screen: its top and height on the rail.
export function mapThumb(
  scrollTop: number,
  viewportHeight: number,
  total: number,
  height: number,
): { top: number; height: number } {
  const span = total + THREAD_PADDING_TOP;
  if (span <= 0 || height <= 0) return { top: 0, height: 0 };
  const size = Math.min(height, Math.max(MAP_MIN_THUMB, (viewportHeight / span) * height));
  const top = (Math.max(0, scrollTop) / span) * height;
  return { top: Math.max(0, Math.min(height - size, top)), height: size };
}

/// The rows that draw a mark, by kind and in row order: the prompts, and the replies with text.
/// Built once per rows snapshot from the one before it, reading only the rows from where they
/// differ (model.ts RowsChange), so a streamed token reads its own row and not the chat's.
export type MapRows = {
  readonly rows: readonly AcpmuxRow[];
  /// How many of `lists.users` and `lists.agents` (row indexes, ascending) are this snapshot's.
  readonly users: number;
  readonly agents: number;
  readonly lists: MapRowLists;
};
/// The lists a run of snapshots shares: each next snapshot writes past the entries it keeps, so only
/// the snapshot that wrote last reads or extends them (another, as a render React set aside left
/// one, builds its own again).
type MapRowLists = { users: number[]; agents: number[]; owner?: MapRows };

export function mapRows(
  rows: readonly AcpmuxRow[],
  previous?: MapRows,
  change?: { readonly base: readonly AcpmuxRow[]; readonly rows: readonly AcpmuxRow[]; readonly from: number },
): MapRows {
  if (previous?.rows === rows && previous.lists.owner === previous) return previous;
  const extend =
    previous !== undefined &&
    change !== undefined &&
    change.base === previous.rows &&
    change.rows === rows &&
    previous.lists.owner === previous;
  const lists: MapRowLists = extend ? previous.lists : { users: [], agents: [] };
  const from = extend ? Math.max(0, Math.min(change.from, rows.length, previous.rows.length)) : 0;
  let users = extend ? lowerBound(lists.users, previous.users, from) : 0;
  let agents = extend ? lowerBound(lists.agents, previous.agents, from) : 0;
  for (let index = from; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (row.kind === "user") lists.users[users++] = index;
    else if (row.kind === "assistant" && row.text) lists.agents[agents++] = index;
  }
  const next: MapRows = { rows, users, agents, lists };
  lists.owner = next;
  return next;
}

/// The first of `list`'s first `count` entries at or past `value`.
function lowerBound(list: ArrayLike<number>, count: number, value: number): number {
  let low = 0;
  let high = count;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (list[middle]! < value) low = middle + 1;
    else high = middle;
  }
  return low;
}

/// A prompt's mark and a reply's per MERGE_PX band of the rail, top to bottom: the band's first of
/// each kind draws for the rest (a long chat has thousands of rows and the rail some hundred px, so
/// the marks stay as many at any length). Each sits on a whole px, so a reply that grows moves only
/// the marks it moves a px. `keep`'s rows (the focused, previewed or keyed-to prompt) draw even in
/// a band another draws for. A prompt's mark is its turn's: `turns[i]` is the prompt of row
/// `turns[i].index`. The map jumps from band to band by binary search on the layout and on `index`,
/// so a layout change costs O(marks x log rows), not a walk of the rows.
export function mapMarks(
  rows: readonly AcpmuxRow[],
  turns: readonly MinimapTurn[],
  layout: GeometrySource & { readonly totalHeight: number },
  height: number,
  index?: MapRows,
  keep: ReadonlyArray<number | undefined> = [],
): MapMark[] {
  const rowsIndex = index && index.rows === rows && index.lists.owner === index ? index : mapRows(rows);
  const geometry = geometryOf(layout);
  const total = layout.totalHeight;
  const span = total + THREAD_PADDING_TOP;
  const placed = Math.min(geometry.count, rows.length);
  const turnOf = (row: number) => {
    let low = 0;
    let high = turns.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (turns[middle]!.index <= row) low = middle + 1;
      else high = middle;
    }
    return low - 1;
  };
  // Rows past the layout's (a layout a render behind) sit at the top, as an unplaced row did.
  const yOf = (row: number) => mapY(row < placed ? geometry.topAt(row) : 0, total, height);
  const pick = (kind: MapMark["kind"], list: readonly number[], count: number): MapMark[] => {
    const out: MapMark[] = [];
    const mark = (row: number) => out.push({ kind, row, turn: turnOf(row), y: Math.round(yOf(row)) });
    const kept = keep
      .filter((row): row is number => row !== undefined && list[lowerBound(list, count, row)] === row)
      .sort((a, b) => a - b)
      .filter((row, at, all) => row !== all[at - 1]);
    let held = 0;
    const end = lowerBound(list, count, placed);
    if (end < count) mark(list[end]!);
    let at = 0;
    while (at < end) {
      const row = list[at]!;
      const y = yOf(row);
      mark(row);
      // The next band's first row: its edge's place in the chat, then the list's next entry there,
      // set right on the entries beside it (mapY's inverse is a float).
      const edge = (Math.floor(y / MERGE_PX) + 1) * MERGE_PX;
      const next =
        height > 0 && edge <= height
          ? Math.min(placed, geometry.upperBoundTop((edge / height) * span - THREAD_PADDING_TOP))
          : placed;
      let to = Math.max(at + 1, lowerBound(list, end, next));
      while (to > at + 1 && yOf(list[to - 1]!) >= edge) to -= 1;
      while (to < end && yOf(list[to]!) < edge) to += 1;
      const stop = to < end ? list[to]! : placed;
      while (held < kept.length && kept[held]! <= row) held += 1;
      while (held < kept.length && kept[held]! < stop) mark(kept[held++]!);
      at = to;
    }
    return out;
  };
  const users = pick("user", rowsIndex.lists.users, rowsIndex.users);
  const agents = pick("agent", rowsIndex.lists.agents, rowsIndex.agents);
  // Both kinds top to bottom, in row order where they share a px.
  const marks: MapMark[] = [];
  let user = 0;
  let agent = 0;
  while (user < users.length || agent < agents.length) {
    const a = users[user];
    const b = agents[agent];
    marks.push(!b || (a && (a.y < b.y || (a.y === b.y && a.row < b.row))) ? users[user++]! : agents[agent++]!);
  }
  return marks;
}

/// The prompt nearest rail point `y` (at its own place, not its band's mark), and how far it is, or
/// undefined when there is none: a band draws one prompt for several, and a pointer on it points
/// at the one nearest it, as it did when each drew. Two binary searches, no walk of the rows.
export function promptAt(
  index: MapRows,
  turns: readonly MinimapTurn[],
  layout: GeometrySource & { readonly totalHeight: number },
  height: number,
  y: number,
): (MapMark & { distance: number }) | undefined {
  const geometry = geometryOf(layout);
  const total = layout.totalHeight;
  const placed = Math.min(geometry.count, index.rows.length);
  const list = index.lists.users;
  const end = lowerBound(list, index.users, placed);
  if (end === 0 || height <= 0) return undefined;
  const yOf = (row: number) => mapY(geometry.topAt(row), total, height);
  const at = lowerBound(
    list,
    end,
    geometry.upperBoundTop((y / height) * (total + THREAD_PADDING_TOP) - THREAD_PADDING_TOP),
  );
  let best: { row: number; y: number; distance: number } | undefined;
  // The prompts on each side of the point; the nearer wins, the upper one a tie.
  for (const near of [at - 2, at - 1, at, at + 1]) {
    if (near < 0 || near >= end) continue;
    const row = list[near]!;
    const place = yOf(row);
    const distance = Math.abs(place - y);
    if (!best || distance < best.distance) best = { row, y: place, distance };
  }
  if (!best) return undefined;
  let low = 0;
  let high = turns.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (turns[middle]!.index <= best.row) low = middle + 1;
    else high = middle;
  }
  return { kind: "user", row: best.row, turn: low - 1, y: Math.round(best.y), distance: best.distance };
}

/// The mark nearest rail point `y`, if one is within MAP_HIT px; a prompt wins a tie with a reply.
export function markAt(marks: readonly MapMark[], y: number): number | undefined {
  let best: number | undefined;
  let distance = MAP_HIT + 0.001;
  for (let index = 0; index < marks.length; index += 1) {
    const mark = marks[index]!;
    const off = Math.abs(mark.y - y);
    if (off < distance || (off === distance && mark.kind === "user")) {
      best = index;
      distance = off;
    }
    if (mark.y - y > MAP_HIT) break;
  }
  return best;
}

/// How much a mark `distance` px from the pointer grows (0 to 1); undefined is no pointer.
export function mapProgress(distance: number | undefined): number {
  if (distance === undefined) return 0;
  const off = Math.abs(distance);
  for (const [within, share] of FISHEYE) if (off <= within) return share;
  return 0;
}
