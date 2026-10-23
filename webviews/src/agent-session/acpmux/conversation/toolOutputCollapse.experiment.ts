// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import type { CSSProperties } from "react";
import { defineExperiment, experimentArm } from "../../../experiments/experiment";

/// How a long tool output collapses (Leo 2026-10-22: "also the tool calling i think there should be
/// more of like a "show more" type thing for long outputs or whatnot..."): a call's output and a
/// command's Shell block show their first rows, then a control that opens them in place and closes
/// them again. The arms vary the rows shown, the cut (a bottom fade or a hard edge) and where the
/// control sits; compare them in the gallery's `agent-pane.tool-output-collapse`. An edit's diff
/// keeps the eight lines and fade of the shipped arm whatever the arm.
export const toolOutputCollapse = defineExperiment({
  id: "tool-output-collapse",
  title: "Tool output collapse",
  description:
    "A long tool output's first rows and its Show more control: how many rows, a fade or a hard cut, and a text link, a quiet bar or a corner chip.",
  arms: {
    "fade-link": {
      label: "8 rows, fade, link",
      description:
        "Eight rows under a bottom fade, with a quiet text link under the block (Claude Code, the Codex app).",
    },
    "six-bar": {
      label: "6 rows, fade, bar",
      description: "Six rows under a bottom fade, with a full-width quiet bar along the block's foot.",
    },
    "ten-chip": {
      label: "10 rows, hard cut, chip",
      description: "Ten rows cut with a hard edge, with a small glass chip in the block's bottom-right corner.",
    },
    "fifteen-link": {
      label: "15 rows, fade, link",
      description: "Fifteen rows under a bottom fade, with the text link under the block.",
    },
  },
  defaultArm: "fade-link",
});

export type ToolOutputCollapse = keyof typeof toolOutputCollapse.arms;

/// The rows each arm shows before it cuts.
export const COLLAPSE_ROWS: Readonly<Record<ToolOutputCollapse, number>> = {
  "fade-link": 8,
  "six-bar": 6,
  "ten-chip": 10,
  "fifteen-link": 15,
};

/// The running arm's rows, and the attributes a block's card carries for its look (conversation.css
/// `[data-collapse]`): its rows as `--cv-preview-rows`, so the CSS cut and the count agree.
export function collapseLook() {
  const arm = experimentArm(toolOutputCollapse);
  const rows = COLLAPSE_ROWS[arm];
  return { rows, card: { "data-collapse": arm, style: { "--cv-preview-rows": rows } as CSSProperties } };
}
