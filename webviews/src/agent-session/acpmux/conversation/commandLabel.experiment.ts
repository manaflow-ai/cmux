// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What a command row says (Leo, 2026-11-07: "it's not just you ran a command. It's that you ran a
/// specific thing"). Every look keeps the whole line in the opened Shell block. Compare them in
/// `agent-pane.command-row-labels`.
export const commandLabelLook = defineExperiment({
  id: "command-label-look",
  title: "Command row labels",
  description:
    "Whether a command row names what the command did (a verb table, the model's description) or shows the line.",
  arms: {
    verbs: {
      label: "Verb table first",
      description:
        "A known program reads as a past-tense verb and its argument; a description names the rest; else the cleaned line.",
    },
    description: {
      label: "Description first",
      description: "Claude's Bash description when it has one, else the verb table, else the cleaned line.",
    },
    "verbs-command": {
      label: "Verb + dimmed command",
      description: "As Verb table first, with the cleaned command line after it in the dim tone.",
    },
    cleaned: {
      label: "Command, cleaned",
      description: "Ran <line> without redirects and the head/cut/wc filters piped after it.",
    },
    command: {
      label: "Command as typed (before)",
      description: "Ran <line> as it was typed, plumbing included: the look before this change.",
    },
  },
  defaultArm: "verbs",
});

export type CommandLabelLook = keyof typeof commandLabelLook.arms;
