// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Whether a chat on another machine names its machine in the composer footer at rest, beside the
/// status dot (RFD 0130: all three positions conceded "a chat on another machine earns its machine
/// name in view, because that changes what a command does"). acpmux marks the fact that earns it
/// (`composerStatus.facts[].atRest`, the machine of a peer's session); the switch only chooses whether
/// the pane draws it. Off by default: showing it always changes a shipped look, which is Leo's call.
/// Gallery `agent-pane.composer-status-dot` (`machine-at-rest-*`), design/composer-status-dot.md.
export const composerMachineAtRest = defineExperiment({
  id: "composer-machine-at-rest",
  title: "Composer machine name at rest",
  description: "A chat on another machine shows the machine's name beside the status dot, with nothing to say.",
  arms: {
    off: {
      label: "Off",
      description: "The footer names the machine only while its link is down, as before.",
    },
    on: {
      label: "On",
      description: "The machine's name stays beside the dot; a click on it pins the dot's card.",
    },
  },
  defaultArm: "off",
});
