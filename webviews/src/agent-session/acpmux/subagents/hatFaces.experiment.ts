// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The composer hat's folded header draws one icon per subagent, each naming its own subagent as the
/// pointer passes over it (HatFaces.tsx). Leo, 2026-11-22, on a header of "7 subagents · 4 done · 1
/// stopped" that drew one mark and one tooltip: "i wanted the redesign to show a lot of icons (of
/// subagents) and be able to thumb through them when my cursor is hovering over them to be able to
/// parse who's who". Compare them in the gallery's `agent-pane.composer-hat-faces`.
export const hatFacesLook = defineExperiment({
  id: "composer-hat-faces",
  title: "Composer hat: one icon per subagent",
  description:
    "The folded header's subagent icons: one per subagent spread side by side and overlapping only past a cap; a tight stack that fans out over its neighbours on hover; or the single lead mark it drew before.",
  arms: {
    spread: {
      label: "Spread, overlap past a cap",
      description:
        "Each subagent's icon side by side; past the cap they overlap evenly so all fit, past the smallest step a +N follows. Each names its subagent and state at once as the pointer crosses it; a click opens it.",
    },
    fan: {
      label: "Stack, fans out on hover",
      description:
        "A tight overlapping stack at rest; hovering it spreads the icons over the header (drawn over it, so nothing beside it moves), each naming its subagent; a click opens it.",
    },
    lead: {
      label: "One lead mark",
      description: "As before: the subagents kind draws its first subagent's mark, and one tooltip lists the names.",
    },
  },
  // Leo asked for this header in the words above.
  defaultArm: "spread",
});
