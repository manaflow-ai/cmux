// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How a chat starting in Cloud shows its progress under the person's message (CloudStartView):
/// metadata in the chat, never a modal. The arms differ only in the layout; compare them in the
/// gallery's `agent-pane.cloud-start`.
export const cloudStartLook = defineExperiment({
  id: "cloud-start-look",
  title: "Cloud start progress",
  description: "How a chat starting in Cloud draws its step, folder, machine, secrets and network.",
  arms: {
    chips: {
      label: "Chips",
      description: "A spinner line with the step, then one row of small chips: folder, machine, secrets, network.",
    },
    rows: {
      label: "Fact rows",
      description: "A spinner line, then label and value rows like the Sandboxed receipt's facts.",
    },
    steps: {
      label: "Step list",
      description:
        "The three steps as a checklist (done, current with a spinner, next), the facts on one line under it.",
    },
  },
  defaultArm: "chips",
});

/// How the quiet start view (a start on its way, before any failure) says what the chat waits on:
/// one line under the person's message, never the step list. Gallery `agent-pane.cloud-start`, the
/// `quiet-*` variants.
export const cloudStartQuietLook = defineExperiment({
  id: "cloud-start-quiet-look",
  title: "Cloud start wait line",
  description: "What the quiet Cloud start line says while the machine, copy, setup and agent start.",
  arms: {
    inline: {
      label: "Stage and ETA inline",
      description: "The live line's look with the stage's words, then its time and the usual wait after a dot.",
    },
    stacked: {
      label: "ETA under the stage",
      description: "The stage's words on the live line, the usual wait as one secondary line under it.",
    },
    hint: {
      label: "Stage with a progress hint",
      description: "The inline line over a thin row of segments, one per stage this start runs.",
    },
    thinking: {
      label: "Thinking only",
      description: "The line before this change: Thinking, with no stage and no ETA.",
    },
  },
  defaultArm: "inline",
});
