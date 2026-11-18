// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How Back to before this turn asks before it rewinds a chat on this machine (LocalRewind.tsx):
/// the conversation, the files, or both, the files' count from acpmux's dry run and, where they
/// can't be reset, why. Compare the arms in the gallery's `agent-pane.local-rewind` (view Compare
/// arms), or set `cmux.experiments` to `{"local-rewind-confirm":"segmented"}` in the pane's web
/// inspector and reload. Every arm opens on the conversation alone.
export const localRewindConfirm = defineExperiment({
  id: "local-rewind-confirm",
  title: "Back to before this turn: the confirm",
  description:
    "The prompt's Rewind asks what goes back before it runs. Look at whether the default (conversation only) reads at a glance, whether a blocked files choice says why, and how close the ask stays to the button.",
  arms: {
    checks: {
      label: "Popover, two checkboxes",
      description:
        "A small popover anchored to the button: Conversation (checked) and Also reset files (N files), the second disabled with its reason when the files can't be reset; Cancel and Rewind.",
    },
    segmented: {
      label: "Popover, segmented choice",
      description:
        "The same popover with one segmented control: Conversation, Files, Both. Files and Both are disabled with the reason under them when the files can't be reset.",
    },
    inline: {
      label: "Inline row under the prompt",
      description:
        "No popover: a quiet row opens under the prompt's bubble with the files checkbox, Cancel and Rewind, and the transcript makes room for it.",
    },
  },
  defaultArm: "checks",
});

export type LocalRewindLook = keyof typeof localRewindConfirm.arms;
