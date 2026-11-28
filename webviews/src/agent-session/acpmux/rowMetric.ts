// The one metric every one-line activity row of the transcript draws on: a tool run, a thinking
// line, a background task's end, a subagent's line, another agent's received line, "Sent to", the
// inbox's "Received 3 messages" and the "Worked for" fold header. One height, one text size, one
// chip and one glyph, so no row kind can drift taller than the others (Leo, 2026-11-17, on a
// coordinator chat whose rows had grown apart: "these are too big").
//
// The row's height starts from its historical 22px pitch and adds row air (transcriptGrid.ts
// ROW_AIR_LOOKS; Leo, 2026-11-22: "our is too much of a dense eyesore right now"), so the metric
// shrinks the words, the chips, the glyphs and "Worked for"'s rule, and keeps the air between rows.
//
// conversation.css mirrors the row metric as `--cv-tool-row-height`, `--cv-row-font-size`,
// `--cv-row-chip-height` and `--cv-row-glyph`; transcriptGrid.ts derives the shipped pitch from
// the historical 22px pitch plus 10px of air. Tool text uses a 20px line inside that box.
// model.ts uses ROW_METRIC for the Worked-for rule gaps.
// test/transcript-row-metric-tokens.test.ts fails when the stylesheet, grid and metric disagree,
// and test/transcript-activity-row-density.test.ts measures every row kind of gallery entry
// agent-pane.activity-row-density against them.

import { ROW_AIR_LOOKS, TRANSCRIPT_LINE_WORDS } from "./transcriptGrid";

/** The shipped row: its words' line and the row air. */
const ROW = TRANSCRIPT_LINE_WORDS + ROW_AIR_LOOKS.shipped;

export type RowMetric = {
  /** A one-line row's height, top to top (its words' line and the row air): the rows sit flush. CSS px. */
  height: number;
  /** The row's words, CSS px at the default reading size (the prose is 14). */
  font: number;
  /** A session chip's box (a sender, "Sent to"'s recipient): no taller than the row's words. */
  chip: number;
  /** A row's leading glyph box in its 16 icon column (a tool glyph's ink is 3/4 of it). */
  glyph: number;
  /** "Worked for"'s rule: the room under its words, and the room under the rule to the next row. */
  ruleAbove: number;
  ruleBelow: number;
  note: string;
};

/// The candidates the gallery compares (agent-pane.activity-row-density): `roomy` is what shipped
/// before, prose-sized; `compact` is the pick; `dense` is the tightest that still holds a chip. All
/// three keep the row air, so they differ in the words, chips and glyphs, and `dense` in a 20 line.
export const ROW_METRIC_VARIANTS = {
  roomy: {
    height: ROW,
    font: 14,
    chip: 18,
    glyph: 16,
    ruleAbove: 4,
    ruleBelow: 8,
    note: "Before: the rows at the prose's size.",
  },
  compact: {
    height: ROW,
    font: 13,
    chip: 16,
    glyph: 16,
    ruleAbove: 2,
    ruleBelow: 6,
    note: "The pick: one point under the prose, a desktop chat agent's activity list.",
  },
  dense: {
    height: ROW - 2,
    font: 12,
    chip: 15,
    glyph: 14,
    ruleAbove: 2,
    ruleBelow: 4,
    note: "The tightest: a chip nearly fills its line and the words read as captions.",
  },
} as const satisfies Record<string, RowMetric>;

export const ROW_METRIC: RowMetric = ROW_METRIC_VARIANTS.compact;
