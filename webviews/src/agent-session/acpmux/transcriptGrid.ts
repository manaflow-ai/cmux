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

/// What a row is for the gap rules (grid.md 5.5). Kept per row in the layout, so a placement that
/// skips DOM-empty rows still picks the gap from the neighbours that draw.
export const MARK_OTHER = 0;
export const MARK_PROMPT = 1;
export const MARK_MESSAGE = 2;
export const MARK_INDICATOR = 3;

type MarkedRow = { kind: string; incoming?: unknown; received?: unknown; text?: string };
export function rowMark(row: MarkedRow): number {
  if (row.kind === "user" && !row.incoming && !row.received) return MARK_PROMPT;
  if (row.kind === "assistant" && (row.text?.length ?? 0) > 0) return MARK_MESSAGE;
  // The live line (turns.ts WORKING and THINKING, by value: this module stays import-free).
  if (row.kind === "working" || row.kind === "thinking") return MARK_INDICATOR;
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
/// gap under it for its hover action row; anything else takes the composer gap.
export function tailGap(last: number, beforeLast: number): number {
  if (last === MARK_INDICATOR && beforeLast === MARK_PROMPT) return TRANSCRIPT_BLOCK_GAP;
  if (last === MARK_PROMPT || last === MARK_MESSAGE) return TRANSCRIPT_BLOCK_GAP;
  return TRANSCRIPT_COMPOSER_GAP;
}
