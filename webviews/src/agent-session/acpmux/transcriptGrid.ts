// The virtual stack reads the same declarative lengths as the generated CSS grid tokens.
import grid from "../../../../schemas/layout-grid/layout-grid.json";

export const gridLength = (name: string): number => {
  const metric = grid.metrics.find((value) => value.name === name);
  if (!metric) throw new Error(`Missing layout grid metric: ${name}`);
  return metric.pt;
};
export const TRANSCRIPT_BLOCK_GAP = gridLength("gap-block");
export const TRANSCRIPT_INNER_GAP = gridLength("gap-inner");
export const TRANSCRIPT_TURN_GAP = gridLength("gap-turn");
export const TRANSCRIPT_COMPOSER_GAP = gridLength("gap-composer");

/// The interface scale the CSS grid tokens multiply by (desktop.css: `calc(24px *
/// var(--cmux-interface-scale, 1))`). The virtual stack places its gaps with the same factor, so
/// placed gaps match the drawn ones and the overlays laid in them at any Interface Size. Read once
/// per layout pass.
export function gridScale(): number {
  if (typeof document === "undefined" || typeof getComputedStyle !== "function") return 1;
  const raw = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--cmux-interface-scale"));
  return Number.isFinite(raw) && raw > 0 ? raw : 1;
}

/// What a row is for the gap rules (grid.md 5.5). Kept per row in the layout, so a placement that
/// skips DOM-empty rows still picks the gap from the neighbours that draw.
export const MARK_OTHER = 0;
export const MARK_PROMPT = 1;
export const MARK_MESSAGE = 2;
export const MARK_INDICATOR = 3;
/// A settled turn's footer: no height of its own, its action row laid in the gap under the reply.
export const MARK_FOOTER = 4;

type MarkedRow = { kind: string; incoming?: unknown; received?: unknown; text?: string };
export function rowMark(row: MarkedRow): number {
  if (row.kind === "user" && !row.incoming && !row.received) return MARK_PROMPT;
  if (row.kind === "assistant" && (row.text?.length ?? 0) > 0) return MARK_MESSAGE;
  // The live line (turns.ts WORKING and THINKING, by value: this module stays import-free).
  if (row.kind === "working" || row.kind === "thinking") return MARK_INDICATOR;
  if (row.kind === "turnSummary") return MARK_FOOTER;
  return MARK_OTHER;
}

/// One gap per adjacent pair, the most specific first: the waiting rule, then turn, then block.
/// (The composer gap is the stack's, tailGap below.) Gaps never add.
export function transcriptGap(previous: number, next: number): number {
  // Waiting for the first output: the indicator right under its prompt takes the block gap.
  if (next === MARK_INDICATOR && previous === MARK_PROMPT) return TRANSCRIPT_BLOCK_GAP;
  if (previous === MARK_PROMPT || next === MARK_PROMPT) return TRANSCRIPT_TURN_GAP;
  return TRANSCRIPT_BLOCK_GAP;
}

/// The gap between the last drawn row and the top of the bottom stack. The waiting indicator sits
/// centred between its prompt and the stack (block gap on both sides); a message keeps the block
/// gap under it for its hover action row, as does any element whose turn footer (no height, its
/// action row in the gap) follows it; anything else takes the composer gap.
export function tailGap(last: number, beforeLast: number, footerAfter = false): number {
  if (footerAfter) return TRANSCRIPT_BLOCK_GAP;
  if (last === MARK_INDICATOR && beforeLast === MARK_PROMPT) return TRANSCRIPT_BLOCK_GAP;
  if (last === MARK_PROMPT || last === MARK_MESSAGE) return TRANSCRIPT_BLOCK_GAP;
  return TRANSCRIPT_COMPOSER_GAP;
}

/// Over a floating stack (model.ts `REST_GAP`), the band under the last drawn row that comes before
/// the rest gap: a trailing turn footer's action row is laid centred in the block gap under its reply
/// (conversation.css `.cv-turn-actions`), so the rest gap starts at that row's bottom edge; with no
/// footer the rest gap starts at the row itself (a live line, a streaming reply).
export function restBand(footerAfter: boolean): number {
  return footerAfter ? (TRANSCRIPT_BLOCK_GAP + gridLength("transcript-action-control")) / 2 : 0;
}

/// Whether a turn footer follows the last drawn row: only the trailing rows that draw nothing.
export function footerAfter(marks: Uint8Array | undefined, heights: Float64Array): boolean {
  if (!marks) return false;
  for (let index = heights.length - 1; index >= 0 && heights[index] === 0; index -= 1)
    if (marks[index] === MARK_FOOTER) return true;
  return false;
}
