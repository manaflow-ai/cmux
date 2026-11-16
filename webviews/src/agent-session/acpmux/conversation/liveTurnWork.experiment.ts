// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What a running turn draws above its one live status line. The default is `runs`, as the Codex app
/// draws a running turn: each finished run stays in sight as its folded summary line, which a click
/// opens, and the turn's thinking shows as it goes (Lucas, 2026-11-12: under `line` "no thinking at
/// all, until after the turn finished"). `line` draws it as chatgpt.com does: one line that says what the agent does now and replaces itself at each
/// step, with no finished run stacked over it (the user, 2026-11-10: "it says 'worked for 36s' but
/// if i hide it, it still shows a bunch of tool calls ... we need to match and be the same"). Replies
/// to the person always stay in sight (Leo, 2026-11-06), and so does a file change waiting for the
/// person's permission (Lawrence, 2026-11-10, 8a37e5fcf650). Before, each run's calls stayed in
/// sight until the turn ended (Leo, 2026-11-08, cmux#38339). Compare in `agent-pane.live-turn-work`.
export const liveTurnWork = defineExperiment({
  id: "live-turn-work",
  title: "Work in a running turn",
  description: "What a running turn draws above its live status line: nothing but the replies, or every finished run.",
  arms: {
    line: {
      label: "One live line",
      description: "The replies stay in sight; the work is the one live line, which replaces itself.",
    },
    runs: {
      label: "Finished runs in sight",
      description:
        "Each finished run stays in sight above the live line as its folded summary line, as the Codex app draws it.",
    },
  },
  defaultArm: "runs",
});
