// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the machine list draws the account's Cloud machines while they are the list kept from the last
/// launch (cloudMachines.ts `lastSeenAt`: the app's cold start, before its first fresh read lands).
/// EnvironmentPicker `lastSeenLook`; compare the arms in the gallery's
/// `agent-pane.new-tab-machine-menu-last-seen`. Leo picks one (taste call).
export const cloudLastSeenLook = defineExperiment({
  id: "cloud-last-seen-look",
  title: "Cloud machines last seen",
  description: "How Cloud machine rows read while they are the list kept from the last launch.",
  arms: {
    "dimmed-header": {
      label: "Dimmed with caption",
      description: "Cloud rows in the secondary text color under one caption: Last seen 4 min ago.",
    },
    "row-note": {
      label: "Row note",
      description: "Rows at normal weight; each row's stage text reads last seen 4 min ago.",
    },
    banner: {
      label: "Banner",
      description: "Rows unchanged; a one-line notice over the list with a Retry button.",
    },
  },
  defaultArm: "dimmed-header",
});
