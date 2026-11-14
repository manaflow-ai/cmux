// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Where a Claude Code /loop's "Checking back in 7 min." sits (LoopQuiet.tsx, TaskGoalStrip.tsx
/// `LoopStrip`). Leo, 2026-11-12, of that line standing on its own over the composer: "WE PROb need
/// to start unwinding a lot of these things at the bottom... what have we introduced? a lot of stuff
/// is pretty wack around there". Compare them in the gallery's `agent-pane.composer-loop`.
export const loopPlace = defineExperiment({
  id: "composer-loop-place",
  title: "Composer: where a /loop's next run sits",
  description:
    "A Claude Code /loop between its runs: in the composer's quiet row (the stack over the composer stays as it was), the same with only the time, or its own row over the composer.",
  arms: {
    quiet: {
      label: "Quiet row",
      description:
        "The clock and \"Checking back in 7 min.\" after the mode in the quiet row under the composer; the loop adds no row over the composer.",
    },
    short: {
      label: "Quiet row, time only",
      description: "The clock and \"in 7 min.\" in the quiet row; the whole sentence and the loop's prompt in the tooltip.",
    },
    stack: {
      label: "Own row (before)",
      description: "Its own line over the composer in the bottom stack, opened by a click (cmux#38051).",
    },
  },
  defaultArm: "quiet",
});
