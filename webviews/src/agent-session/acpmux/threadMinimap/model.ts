// The thread minimap's model: one tick per user message at the transcript's left edge
// (the Codex desktop app's prompt rail). Pure functions, so geometry and previews need no DOM.
import type { AcpmuxRow } from "../model";
import { opensTurn } from "../turnStart";
import { MOTION_MS } from "../../../motion/scale.generated";

export type ReplySpan = { text: string; bold: boolean };
export type ReplyBlock = { kind: "paragraph" | "item"; spans: ReplySpan[] };
export type MinimapTurn = {
  /// The user row's index in the transcript rows (and in the layout's tops).
  index: number;
  id: string;
  /// The turn's stable key: session id, row id and a hash of the prompt, since every session
  /// numbers its rows `user-<seq>` and a row's `at` is not stable across snapshots. Bookmarks use
  /// the row id's seq instead (bookmarks.ts), which acpmux checks against its log.
  key: string;
  /// The prompt on one line.
  prompt: string;
  /// The start of the first reply after the prompt.
  reply: ReplyBlock[];
};

/// The rail's geometry and timing, measured from 60 Hz recordings of the Codex desktop app's prompt
/// rail (lane notes: minimap-ref/SPEC.md). CSS px and ms; the drawn sizes live in threadMinimap.css.
/// The rail shows from this many prompts...
export const MIN_PROMPTS = 4;
/// ...and only when the transcript column starts this far right of the scroller's left edge.
export const MIN_GUTTER = 48;
/// The rail's left edge, in from the scroller's.
export const RAIL_LEFT = 16;
/// One row per prompt: a fixed 10 px pitch (not proportional to the thread), 36 px wide to hit.
export const ROW_PITCH = 10;
export const ROW_WIDTH = 36;
/// The tick's line box; a tick draws `tickLength(progress)` of it from the left.
export const TICK_BOX = 26;
/// Rows past this many, or past 70% of the window's height, scroll inside the rail.
export const RAIL_MAX_ROWS = 64;
export const RAIL_MAX_SHARE = 0.7;
/// The fisheye by row distance from the hovered (or scrubbed) row: 26, 20, 14, 10, then 6 px.
const PROGRESS = [1, 0.7, 0.4, 0.2] as const;
/// Space kept free above and below the card inside the transcript's viewport.
export const EDGE_MARGIN = 8;
/// A jump lands the prompt's bubble this far below the top of the transcript's viewport.
export const LANDING_OFFSET = 35;
/// The transcript thread's top padding (.acpmux-thread): row tops start this far down the scroller.
export const THREAD_PADDING_TOP = 16;
/// A click's smooth scroll (Codex's Chromium smooth scroll, fitted), and a Previous or Next Turn step's.
export const JUMP_CURVE = [0.35, 0.05, 0, 1] as const;
export const STEP_CURVE = [0.3, 0.2, 0, 1] as const;
export const STEP_MS = MOTION_MS.standard;
/// The preview card opens this long after the pointer reaches the rail (Codex's `delayOpen`, 250 ms).
/// Shorter than the app's 450 ms hover delay (ui/hoverIntent.ts): the rail is a deliberate target,
/// and the card is the point of hovering it. Once one shows, the next row's follows at once.
export const CARD_DELAY = 250;
/// When older turns load above the rail's rows and move them, the rail glides back over this long.
export const SHIFT_MS = MOTION_MS.standard;
/// A jump keeps correcting its landing for up to this many frames while the rows it crossed measure.
export const SETTLE_FRAMES = 45;
/// The landing highlight on the prompt's bubble.
export const HIGHLIGHT_MS = 1400;
export const HIGHLIGHT_EASING = "cubic-bezier(0.23, 1, 0.32, 1)";
/// Blocks of a reply the preview keeps (the card clamps to three lines).
const PREVIEW_BLOCKS = 4;
const PREVIEW_CHARS = 360;

/// How magnified a row is (0 to 1) at `distance` rows from the hovered one; undefined is no hover.
export function tickProgress(distance: number | undefined): number {
  if (distance === undefined) return 0;
  return PROGRESS[Math.abs(distance)] ?? 0;
}

/// The drawn length of a tick at `progress`: 6 px at rest, 26 px hovered.
export const tickLength = (progress: number) => TICK_BOX * (0.2308 + 0.7692 * progress);

/// The rail's height for `count` rows in a window `windowHeight` tall: every row up to 64 rows or
/// 70% of the window, after which the rows scroll. It never outgrows the transcript it is centered
/// on (`viewportHeight`, less EDGE_MARGIN at each end), so a short pane's rows all scroll into view.
export function railHeight(count: number, windowHeight: number, viewportHeight = windowHeight): number {
  return Math.max(
    0,
    Math.min(
      count * ROW_PITCH,
      RAIL_MAX_ROWS * ROW_PITCH,
      Math.floor(windowHeight * RAIL_MAX_SHARE),
      // A transcript not measured yet (0) does not cap it.
      viewportHeight > 0 ? Math.floor(viewportHeight - 2 * EDGE_MARGIN) : Infinity,
    ),
  );
}

/// The card's top for a row centered at `center`: centered on it, kept inside the viewport.
export function cardOffset(center: number, cardHeight: number, viewportHeight: number): number {
  const top = center - cardHeight / 2;
  const max = viewportHeight - EDGE_MARGIN - cardHeight;
  return Math.max(EDGE_MARGIN, Math.min(top, max));
}

/// How long a click's smooth scroll takes for `distance` px: about 200 ms for 150 px up to 400 ms
/// for 650 px and more, as the recorded Chromium scrolls took.
export function jumpDuration(distance: number): number {
  const share = Math.min(1, Math.max(0, (Math.abs(distance) - 150) / 500));
  return Math.round(200 + 200 * share);
}

/// Each prompt's turn and the reply it previews, by row object: rows are immutable, so a long
/// chat's snapshot hashes and previews only the turns that changed.
const turnsByPrompt = new WeakMap<AcpmuxRow, { turn: MinimapTurn; sessionId: string; reply?: AcpmuxRow }>();

/// The turns of `rows`, and the rows they were read from.
export type MinimapTurns = { rows: readonly AcpmuxRow[]; sessionId: string; turns: MinimapTurn[] };

/// The transcript's turns. A turn that ends before the first row that differs from
/// `previous.rows` (by object) is kept, and `turns` stays `previous.turns` when every turn is.
export function minimapTurns(rows: readonly AcpmuxRow[], sessionId = "", previous?: MinimapTurns): MinimapTurns {
  const reuse = previous?.sessionId === sessionId ? previous : undefined;
  let from = 0;
  if (reuse) while (from < rows.length && from < reuse.rows.length && rows[from] === reuse.rows[from]) from += 1;
  // A kept turn's rows all come before `from`: the next turn's prompt is before it (a row
  // inserted at that prompt's index joins the turn before).
  let keep = 0;
  if (reuse) while (keep + 1 < reuse.turns.length && reuse.turns[keep + 1]!.index < from) keep += 1;
  const turns: MinimapTurn[] = reuse ? reuse.turns.slice(0, keep) : [];
  let user: AcpmuxRow | undefined;
  let userIndex = 0;
  let reply: AcpmuxRow | undefined;
  const close = () => {
    if (!user) return;
    const kept = turnsByPrompt.get(user);
    if (kept && kept.sessionId === sessionId && kept.reply === reply && kept.turn.index === userIndex)
      turns.push(kept.turn);
    else {
      const turn: MinimapTurn = {
        index: userIndex,
        id: user.id,
        key: `${sessionId}#${user.id}#${hash(user.text ?? "")}`,
        prompt: (user.text ?? "").replace(/\s+/g, " ").trim(),
        reply: reply?.text ? replyPreview(reply.text) : [],
      };
      turnsByPrompt.set(user, { turn, sessionId, reply });
      turns.push(turn);
    }
    user = undefined;
    reply = undefined;
  };
  const start = keep < (reuse?.turns.length ?? 0) ? reuse!.turns[keep]!.index : 0;
  for (let index = reuse && keep > 0 ? start : 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    // A steer goes on with its turn (turnStart.ts): it starts no minimap turn.
    if (opensTurn(row)) {
      close();
      user = row;
      userIndex = index;
    } else if (user && !reply && row.kind === "assistant" && row.text) reply = row;
  }
  close();
  const old = reuse?.turns;
  const same = old && old.length === turns.length && old.every((turn, index) => turn === turns[index]);
  return { rows, sessionId, turns: same ? old : turns };
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

/// The turns on screen, first to last, as the Codex rail's IntersectionObserver sees them. Codex
/// observes each turn's block, which starts LANDING_OFFSET (35 px) above its prompt's bubble (a jump
/// puts the block's top at the view's top and the bubble 35 px down), with a -16 px top margin. So a
/// turn stops counting once the next prompt's bubble is within 35 + 16 px of the top: a prompt just
/// jumped to is the first lit turn, not the one above it. A bubble draws THREAD_PADDING_TOP below its
/// layout top, so that is a layout top at or above `scrollTop + LANDING_OFFSET`. At the bottom a turn
/// counts once its bubble is on screen: our turns have no block above the bubble to show first.
export function visibleTurns(
  turns: readonly MinimapTurn[],
  tops: Float64Array,
  totalHeight: number,
  scrollTop: number,
  viewportHeight: number,
): { first: number; last: number } {
  const bottom = scrollTop + viewportHeight - THREAD_PADDING_TOP;
  const first = currentTurn(turns, tops, scrollTop + LANDING_OFFSET, 0);
  let last = first;
  while (last + 1 < turns.length && (tops[turns[last + 1].index] ?? totalHeight) < bottom) last += 1;
  return { first, last };
}

/// The scroll offset that lands a turn's prompt bubble LANDING_OFFSET below the viewport's top.
export function turnScrollTop(turn: MinimapTurn, tops: Float64Array): number {
  return Math.max(0, THREAD_PADDING_TOP + (tops[turn.index] ?? 0) - LANDING_OFFSET);
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
  // A streaming reply previews again on every token: stop reading once the preview is full, and
  // read line by line instead of splitting the whole reply.
  for (let start = 0; start <= markdown.length;) {
    if (blocks.length >= PREVIEW_BLOCKS || chars >= PREVIEW_CHARS) break;
    const newline = markdown.indexOf("\n", start);
    const end = newline < 0 ? markdown.length : newline;
    const line = markdown.slice(start, end).trim();
    start = end + 1;
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
