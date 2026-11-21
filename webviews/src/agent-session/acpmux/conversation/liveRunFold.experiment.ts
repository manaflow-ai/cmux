// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// When a running turn's finished run closes to its summary line (turns.ts `codexRuns`). Before, the
/// latest run closed as its calls finished: two commands and the thoughts between them, three lines,
/// became one closed "Ran 2 commands" line the moment the second call ended, mid-turn, with nothing new
/// under it (Leo, 2026-11-21: "the messages and whatever collapsing and stuff, sometimes it does so too
/// soon in the midst of a turn. thats not great"). The default, `paragraph`, keeps the run the agent
/// works in drawn open until the agent's next paragraph ends it, the same rule a message run follows
/// (messageRuns.ts); earlier runs close as before. `turn-end` keeps every run of the turn open until
/// the turn ends. `now` is the old look. Compare in `agent-pane.live-run-fold`.
export const liveRunFold = defineExperiment({
  id: "live-run-fold",
  title: "When a running turn's run closes",
  description:
    "When the run of calls a running turn works in closes to its summary line: at the agent's next paragraph, at the turn's end, or as its calls finish.",
  arms: {
    paragraph: {
      label: "At the next paragraph",
      description: "The run the agent works in stays open until the agent's next paragraph; earlier runs are closed.",
    },
    "turn-end": {
      label: "At the turn's end",
      description: "Every run of the running turn stays open until the turn ends.",
    },
    now: {
      label: "As its calls finish (before)",
      description: "The latest run closes to its summary line as soon as a second call in it finishes.",
    },
  },
  defaultArm: "paragraph",
});
