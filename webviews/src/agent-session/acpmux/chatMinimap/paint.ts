// The chat minimap's picture (ChatMinimap.tsx): the whole transcript drawn small into one canvas, as
// VS Code's minimap draws a file. Pure: rows and the transcript's layout in, rectangles out, so
// nothing here measures a row or touches the DOM. A prompt is a bar at the right (where its bubble
// sits), a reply a block of text-like lines at the left, a tool group a narrower muted block; the
// rest (dates, notices, the working line) draws nothing. Each kind is one path and one fill, and
// rows that land on the same device pixel line merge, so a draw is bounded by the canvas's height,
// not by the number of rows, after one pass over them.
import type { AcpmuxRow, ConversationLayout } from "../model";
import { THREAD_PADDING_TOP } from "../threadMinimap/model";

/// The minimap's width in CSS px, and the room it keeps from the pane's right edge.
export const MINIMAP_WIDTH = 56;
export const MINIMAP_EDGE = 10;
/// Space above and below the minimap inside the view: clear of the transcript's 18px soft edges.
export const MINIMAP_TOP = 20;
export const MINIMAP_BOTTOM = 20;
/// The largest scale: a short chat draws at an eighth of its size from the top, as VS Code's
/// minimap draws a short file, instead of stretching to the full height.
export const MAX_SCALE = 1 / 8;
/// The view box is never shorter than this, so a long chat's stays easy to grab.
export const MIN_VIEW = 14;
/// A reply's or tool group's text lines on the map: one line every LINE_PITCH CSS px, LINE_HEIGHT tall.
const LINE_PITCH = 2;
const LINE_HEIGHT = 1;

export type MinimapKind = "prompt" | "reply" | "tool";
export type MinimapColors = Record<MinimapKind, string>;

const TOOL_KINDS = new Set(["activity", "worked", "editedFiles", "plan", "backgroundTask", "render", "preview"]);

/// A row's kind on the map, or none. A streaming reply is never painted: its height changes with every
/// token, and the minimap shows its place as a placeholder instead (ChatMinimap.tsx).
export function minimapKind(row: AcpmuxRow): MinimapKind | undefined {
  if (row.kind === "user") return "prompt";
  if (row.kind === "assistant") return row.text && !row.streaming ? "reply" : undefined;
  return TOOL_KINDS.has(row.kind) ? "tool" : undefined;
}

/// CSS px of map per px of transcript: the whole chat fits the track, never larger than MAX_SCALE.
export function minimapScale(totalHeight: number, track: number): number {
  const span = totalHeight + THREAD_PADDING_TOP;
  if (span <= 0 || track <= 0) return 0;
  return Math.min(MAX_SCALE, track / span);
}

/// The view box: its top and height on the map for a scroll offset.
export function minimapView(
  scrollTop: number,
  viewportHeight: number,
  scale: number,
  track: number,
): { top: number; height: number } {
  const height = Math.min(track, Math.max(MIN_VIEW, viewportHeight * scale));
  const top = Math.max(0, Math.min(track - height, scrollTop * scale));
  return { top, height };
}

/// What a draw needs of a 2D context, so tests can record one.
export type MinimapContext = Pick<
  CanvasRenderingContext2D,
  "setTransform" | "clearRect" | "beginPath" | "rect" | "fill" | "fillStyle" | "globalAlpha"
>;

/// The first row whose place, height, identity or kind on the map differs between two drawn states:
/// a draw whose rows all match the last one's is skipped. A new object for the same row (a token)
/// is no change.
export function firstChangedRow(
  rows: readonly AcpmuxRow[],
  layout: ConversationLayout,
  before: { rows: readonly AcpmuxRow[]; layout: ConversationLayout },
): number {
  const count = Math.min(rows.length, layout.tops.length);
  const kept = Math.min(count, before.rows.length, before.layout.tops.length);
  for (let index = 0; index < kept; index += 1) {
    if (layout.tops[index] !== before.layout.tops[index] || layout.heights[index] !== before.layout.heights[index])
      return index;
    const row = rows[index]!;
    const was = before.rows[index]!;
    if (row !== was && (row.id !== was.id || minimapKind(row) !== minimapKind(was))) return index;
  }
  return kept;
}

/// Each kind's share of the width and where it starts (fractions of the map's width), and its ink.
const SHAPES: Record<MinimapKind, { left: number; width: number; alpha: number }> = {
  prompt: { left: 0.42, width: 0.58, alpha: 0.7 },
  reply: { left: 0, width: 0.92, alpha: 0.42 },
  tool: { left: 0.06, width: 0.55, alpha: 0.5 },
};
const KINDS: readonly MinimapKind[] = ["tool", "reply", "prompt"];

/// A row's seed for its lines' lengths, from its id: rows inserted or removed before it leave it alone.
function seedOf(id: string): number {
  let hash = 2166136261;
  for (let index = 0; index < id.length; index += 1) hash = Math.imul(hash ^ id.charCodeAt(index), 16777619);
  return (hash >>> 0) % 41;
}
/// A line's length as a share of its block's width: a fixed jitter by row and line, so the map reads
/// as text and never shimmers between draws.
const jitter = (seed: number, line: number) => 0.55 + (((seed + line * 17) % 41) / 41) * 0.45;

/// Draws the map at `scale` into a `width` x `height` CSS px canvas with `dpr` device px per CSS px.
/// Returns the number of rectangles drawn (tests, perf).
export function paintMinimap(
  ctx: MinimapContext,
  rows: readonly AcpmuxRow[],
  layout: ConversationLayout,
  {
    width,
    height,
    dpr,
    scale,
    colors,
  }: {
    width: number;
    height: number;
    dpr: number;
    scale: number;
    colors: MinimapColors;
  },
): number {
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, width, height);
  if (scale <= 0) return 0;
  const count = Math.min(rows.length, layout.tops.length);
  const kinds = Array.from({ length: count }, (_, index) => minimapKind(rows[index]!));
  const pixel = 1 / dpr;
  let drawn = 0;
  for (const kind of KINDS) {
    const shape = SHAPES[kind];
    const left = shape.left * width;
    const full = shape.width * width;
    ctx.beginPath();
    // The last device pixel line this kind drew on: a row starting on it merges into what is there.
    let lastLine = -1;
    for (let index = 0; index < count; index += 1) {
      if (kinds[index] !== kind) continue;
      const rowHeight = layout.heights[index]! * scale;
      if (rowHeight <= 0) continue;
      const top = (layout.tops[index]! + THREAD_PADDING_TOP) * scale;
      if (top >= height) break;
      const line = Math.floor(top * dpr);
      // Under a device pixel: one pixel line, unless this kind already drew on it.
      if (rowHeight < pixel) {
        if (line <= lastLine) continue;
        ctx.rect(left, line / dpr, full, pixel);
        lastLine = line;
        drawn += 1;
        continue;
      }
      if (rowHeight < LINE_PITCH || kind === "prompt") {
        // A prompt keeps half a px of gap below it, so two in a row read as two.
        ctx.rect(left, top, full, Math.max(pixel, Math.min(rowHeight, height - top) - (kind === "prompt" ? 0.5 : 0)));
        lastLine = Math.ceil((top + rowHeight) * dpr) - 1;
        drawn += 1;
        continue;
      }
      const lines = Math.floor(rowHeight / LINE_PITCH);
      const seed = seedOf(rows[index]!.id);
      for (let at = 0; at < lines; at += 1) {
        const y = top + at * LINE_PITCH;
        if (y >= height) break;
        ctx.rect(left, y, full * jitter(seed, at), LINE_HEIGHT);
        drawn += 1;
      }
      lastLine = Math.ceil((top + rowHeight) * dpr) - 1;
    }
    ctx.globalAlpha = shape.alpha;
    ctx.fillStyle = colors[kind];
    ctx.fill();
  }
  ctx.globalAlpha = 1;
  return drawn;
}

/// The streaming reply's row, or -1, kept from render to render: the rows before `change.from` are the
/// last render's objects, so the reply found then is still there and still streaming unless its own
/// object changed; only the changed rows are read for a new one. With no change to go on (a first
/// render, another chat), every row is read once.
export function streamingRow(
  rows: readonly AcpmuxRow[],
  last: { rows: readonly AcpmuxRow[]; index: number } | undefined,
  change: { base: readonly AcpmuxRow[]; rows: readonly AcpmuxRow[]; from: number } | undefined,
): number {
  // The same rows (a scroll frame's render): the same answer.
  if (last?.rows === rows) return last.index;
  const from = change && last && change.base === last.rows && change.rows === rows ? change.from : 0;
  if (last && last.index >= 0 && last.index < from) return last.index;
  for (let index = from; index < rows.length; index += 1)
    if (rows[index]!.streaming && rows[index]!.kind === "assistant") return index;
  return -1;
}
