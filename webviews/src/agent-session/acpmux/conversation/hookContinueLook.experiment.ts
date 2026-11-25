// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the chat marks a turn a Stop hook made go on, so the reply after it reads as the hook's
/// continuation and not a second answer (Leo, 2026-11-22: "if you did get hooked, i think it should
/// get displayed better"). Gallery `agent-pane.hook-continue`.
export const hookContinueLook = defineExperiment({
  id: "hook-continue-look",
  title: "Stop hook continuation",
  description: "The quiet mark between a reply and the text a blocking Stop hook made the agent write after it.",
  arms: {
    line: {
      label: "Status line",
      description:
        "A status line like a compaction's: hook icon, 'Stop hook asked to continue', and the hook's reason in muted text, cut to one line; click opens the whole reason.",
    },
    divider: {
      label: "Divider",
      description: "A hairline divider with 'Stop hook asked to continue' in its middle; the reason is its tooltip.",
    },
    chip: {
      label: "Chip",
      description: "A small muted chip, 'Stop hook', above the continued text; the reason is its tooltip.",
    },
  },
  defaultArm: "line",
});
