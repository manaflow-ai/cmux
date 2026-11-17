// The one metric every one-line activity row of the transcript draws on: a tool run, a thinking
// line, a background task's end, a subagent's line, another agent's received line, "Sent to", the
// inbox's "Received 3 messages" and the "Worked for" fold header. One height, one text size, one
// chip and one glyph, so no row kind can drift taller than the others (Leo, 2026-11-17, on a
// coordinator chat whose rows had grown apart: "these are too big").
//
// conversation.css holds the same four values as `--cv-tool-row-height`, `--cv-row-font-size`,
// `--cv-row-chip-height` and `--cv-row-glyph`; model.ts estimates every one-line row from
// ROW_METRIC.height; test/transcript-row-metric-tokens.test.ts fails when the stylesheet and this
// file disagree, and test/transcript-activity-row-density.test.ts measures every row kind of
// gallery entry agent-pane.activity-row-density against it.

export type RowMetric = {
  /** A one-line row's height, top to top: the rows sit flush. CSS px. */
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
/// before, prose-sized; `compact` is the pick; `dense` is the tightest that still holds a chip.
export const ROW_METRIC_VARIANTS = {
  roomy: {
    height: 22,
    font: 14,
    chip: 18,
    glyph: 16,
    ruleAbove: 4,
    ruleBelow: 8,
    note: "Before: the rows at the prose's size.",
  },
  compact: {
    height: 20,
    font: 13,
    chip: 16,
    glyph: 16,
    ruleAbove: 2,
    ruleBelow: 6,
    note: "The pick: one point under the prose, a desktop chat agent's activity list.",
  },
  dense: {
    height: 18,
    font: 12,
    chip: 15,
    glyph: 14,
    ruleAbove: 2,
    ruleBelow: 4,
    note: "The tightest: a chip nearly fills its line and the words read as captions.",
  },
} as const satisfies Record<string, RowMetric>;

export const ROW_METRIC: RowMetric = ROW_METRIC_VARIANTS.compact;
