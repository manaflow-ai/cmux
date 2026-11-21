// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How an opened run of calls draws when it is long (RunScroll.tsx). The Codex app keeps it to about
/// ten lines that scroll on their own, faded at the top and bottom where more is hidden; cmux gives it
/// 14 before it scrolls (Lucas, 2026-11-11: "a few more lines"). Before, every line drew in the transcript's one scroll (Leo, 2026-10-30, #26696).
export const runScroll = defineExperiment({
  id: "run-scroll",
  title: "Opened run scroll",
  description: "A long opened run: its own scroll box of 14 lines, or every line in the transcript.",
  arms: {
    box: {
      label: "Scroll box",
      description: "14 lines, scrolled on their own, faded where more is hidden, as the Codex app does.",
    },
    inline: {
      label: "Every line",
      description: "Every line in the transcript's one scroll; the run is as tall as its calls.",
    },
  },
  defaultArm: "box",
});
