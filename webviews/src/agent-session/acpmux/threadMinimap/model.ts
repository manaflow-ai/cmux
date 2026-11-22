// The thread minimap's model: one tick per user message at the transcript's left edge
// (the Codex app's thread minimap). Pure functions, so geometry and previews test without a DOM.
// Measurements are in the lane notes (.cmux-scratch/pane-protocol/thread-minimap/minimap-spec.md).
import type { AcpmuxRow } from "../model";

export type ReplySpan = { text: string; bold: boolean };
export type ReplyBlock = { kind: "paragraph" | "item"; spans: ReplySpan[] };
export type MinimapTurn = {
  /// The user row's index in the transcript rows (and in the layout's tops).
  index: number;
  id: string;
  /// The bookmark key: session id, row id and a hash of the prompt, since every session numbers
  /// its rows `user-<seq>` and a row's `at` is not stable across snapshots.
  key: string;
  /// The prompt on one line.
  prompt: string;
  /// The start of the first reply after the prompt.
  reply: ReplyBlock[];
};

/// Tick geometry (CSS px); the drawn sizes live in threadMinimap.css. The offsets are transforms.
export const TICK_PITCH = 10;
export const TICK_LEFT = 15.5;
/// Where the popover's left edge sits: 35 px right of the ticks.
export const POPOVER_LEFT = TICK_LEFT + 35;
/// Fisheye widths by index distance from the hovered tick; farther ticks rest at the last.
const TICK_WIDTHS = [26, 20, 14, 10, 6] as const;
export const TICK_MAX_WIDTH = TICK_WIDTHS[0];
export const TICK_REST_WIDTH = TICK_WIDTHS[TICK_WIDTHS.length - 1];
/// Space kept free above and below the column and the popover.
export const EDGE_MARGIN = 8;
/// The pause before the first popover shows; moving between ticks shows the next at once.
export const POPOVER_DELAY_MS = 110;
/// Blocks of a reply the preview keeps (the popover clamps to three lines).
const PREVIEW_BLOCKS = 4;
const PREVIEW_CHARS = 360;

export function tickWidth(distance: number | undefined): number {
  if (distance === undefined) return TICK_REST_WIDTH;
  return TICK_WIDTHS[Math.min(Math.abs(distance), TICK_WIDTHS.length - 1)];
}

/// The first tick's center and the pitch, for `count` ticks centered in a viewport `height` tall.
export function tickLayout(count: number, height: number): { first: number; pitch: number } {
  if (count <= 1) return { first: height / 2, pitch: TICK_PITCH };
  const room = Math.max(0, height - 2 * EDGE_MARGIN);
  // Many turns share the column: the pitch tightens until the column fits the viewport.
  const pitch = Math.min(TICK_PITCH, room / (count - 1));
  return { first: (height - pitch * (count - 1)) / 2, pitch };
}

/// The popover's top for a tick centered at `center`: centered on it, kept inside the viewport.
export function popoverOffset(center: number, popoverHeight: number, viewportHeight: number): number {
  const top = center - popoverHeight / 2;
  const max = viewportHeight - EDGE_MARGIN - popoverHeight;
  return Math.max(EDGE_MARGIN, Math.min(top, max));
}

export function minimapTurns(rows: readonly AcpmuxRow[], sessionId = ""): MinimapTurn[] {
  const turns: MinimapTurn[] = [];
  let open: MinimapTurn | undefined;
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index];
    if (row.kind === "user") {
      open = {
        index,
        id: row.id,
        key: `${sessionId}#${row.id}#${hash(row.text ?? "")}`,
        prompt: (row.text ?? "").replace(/\s+/g, " ").trim(),
        reply: [],
      };
      turns.push(open);
    } else if (open && row.kind === "assistant" && row.text) {
      open.reply = replyPreview(row.text);
      open = undefined;
    }
  }
  return turns;
}

/// FNV-1a of `text`, as base 36.
function hash(text: string): string {
  let value = 0x811c9dc5;
  for (let index = 0; index < text.length; index += 1) {
    value ^= text.charCodeAt(index);
    value = Math.imul(value, 0x01000193);
  }
  return (value >>> 0).toString(36);
}

/// The turn the reader is in: the last prompt above a third of the way down the viewport.
export function currentTurn(
  turns: readonly MinimapTurn[],
  tops: Float64Array,
  scrollTop: number,
  viewportHeight: number,
): number {
  const anchor = scrollTop + viewportHeight / 3;
  let low = 0;
  let high = turns.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if ((tops[turns[middle].index] ?? 0) <= anchor) low = middle + 1;
    else high = middle;
  }
  return Math.max(0, low - 1);
}

/// The turns on screen, first to last: a turn runs from its prompt to the next prompt (or the end).
export function visibleTurns(
  turns: readonly MinimapTurn[],
  tops: Float64Array,
  totalHeight: number,
  scrollTop: number,
  viewportHeight: number,
): { first: number; last: number } {
  const bottom = scrollTop + viewportHeight;
  const first = currentTurn(turns, tops, scrollTop, 0);
  let last = first;
  while (last + 1 < turns.length && (tops[turns[last + 1].index] ?? totalHeight) < bottom) last += 1;
  return { first, last };
}

/// The scroll offset that puts a turn's prompt at the top of the viewport (the thread's padding stays above it).
export function turnScrollTop(turn: MinimapTurn, tops: Float64Array): number {
  return Math.max(0, tops[turn.index] ?? 0);
}

/// The start of a reply as plain blocks with bold spans; code, headings' marks and link targets drop.
export function replyPreview(markdown: string): ReplyBlock[] {
  const blocks: ReplyBlock[] = [];
  let chars = 0;
  let fenced = false;
  let paragraph: string[] = [];
  const push = (kind: ReplyBlock["kind"], text: string) => {
    if (blocks.length >= PREVIEW_BLOCKS || chars >= PREVIEW_CHARS) return;
    const spans = inlineSpans(text.slice(0, PREVIEW_CHARS - chars));
    if (!spans.length) return;
    chars += spans.reduce((sum, span) => sum + span.text.length, 0);
    blocks.push({ kind, spans });
  };
  const flush = () => {
    if (paragraph.length) push("paragraph", paragraph.join(" "));
    paragraph = [];
  };
  for (const raw of markdown.split("\n")) {
    const line = raw.trim();
    if (/^(```|~~~)/.test(line)) {
      flush();
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    if (!line || /^([-*_])\1{2,}$/.test(line) || line.startsWith("|")) {
      flush();
      continue;
    }
    const item = /^(?:[-*+]|\d+[.)])\s+(.*)$/.exec(line);
    if (item) {
      flush();
      push("item", item[1]);
      continue;
    }
    const heading = /^#{1,6}\s+(.*)$/.exec(line);
    if (heading) {
      flush();
      push("paragraph", heading[1]);
      continue;
    }
    paragraph.push(line.replace(/^>\s?/, ""));
  }
  flush();
  return blocks;
}

function inlineSpans(text: string): ReplySpan[] {
  const plain = (value: string) =>
    value
      .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/`([^`]*)`/g, "$1")
      .replace(/(^|[^\w*])[*_]([^*_\s][^*_]*?)[*_](?=[^\w*]|$)/g, "$1$2");
  const spans: ReplySpan[] = [];
  const add = (value: string, bold: boolean) => {
    const clean = plain(value);
    if (!clean) return;
    const last = spans.at(-1);
    if (last && last.bold === bold) last.text += clean;
    else spans.push({ text: clean, bold });
  };
  const strong = /(\*\*|__)(.+?)\1/g;
  let at = 0;
  for (let match = strong.exec(text); match; match = strong.exec(text)) {
    add(text.slice(at, match.index), false);
    add(match[2], true);
    at = match.index + match[0].length;
  }
  add(text.slice(at), false);
  return spans;
}
