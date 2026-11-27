// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Where a paused Cloud machine's chat puts Resume (PeerCopyBanner.tsx; cmuxterm-hq#4755: "a paused
/// machine's chat reads offline. There is no Resume in the pane"). Compare the arms in the
/// gallery's `agent-pane.peer-copy-paused`.
export const pausedMachineResume = defineExperiment({
  id: "paused-machine-resume",
  title: "Paused machine: Resume",
  description: "Where the banner over a paused Cloud machine's chat puts its Resume.",
  arms: {
    actions: {
      label: "Actions row",
      description: "Resume under the banner's text, as the watch and open-elsewhere banners put their choices.",
    },
    inline: {
      label: "In the sentence",
      description: "Resume as a link at the end of the banner's first line.",
    },
    button: {
      label: "Filled button",
      description: "A small filled Resume button at the trailing edge of the banner's first line.",
    },
  },
  defaultArm: "actions",
});
