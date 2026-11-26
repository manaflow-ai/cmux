// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What a command row says (Leo, 2026-11-07: "it's not just you ran a command. It's that you ran a
/// specific thing"). Every look keeps the whole line in the opened Shell block. Compare them in
/// `agent-pane.command-row-labels`.
export const commandLabelLook = defineExperiment({
  id: "command-label-look",
  title: "Command row labels",
  description:
    "Every row prefers its description, then an action inferred from its input. Choose how unnamed commands and groups read.",
  arms: {
    verbs: {
      label: "Name grouped actions",
      description: "Name repeated actions as a group and clean up unnamed commands.",
    },
    description: {
      label: "Description first",
      description: "Show the supplied description and name grouped actions.",
    },
    "verbs-command": {
      label: "Named command rows",
      description: "Show the action on the row and its command in the expanded detail.",
    },
    cleaned: {
      label: "Cleaned fallback",
      description: "Shorten plumbing on unnamed commands and use a command count for groups.",
    },
    command: {
      label: "As-typed fallback",
      description: "Keep plumbing on unnamed commands and use a command count for groups.",
    },
  },
  defaultArm: "verbs",
});

export type CommandLabelLook = keyof typeof commandLabelLook.arms;
