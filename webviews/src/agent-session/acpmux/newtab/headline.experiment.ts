// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How New Tab's optional headline reads (NewTabHeadline.tsx). Hero ships: the same size and colour
/// as a new chat's "What should we build in <project>?", so the two questions read as one product,
/// and as Codex's New Tab draws its question. Compare the arms in the gallery
/// (agent-pane.new-tab-headline); dogfood another with {"new-tab-headline":"quiet"} in `cmux.experiments`.
export const newTabHeadline = defineExperiment({
  id: "new-tab-headline",
  title: "New Tab headline",
  description: "The question over New Tab's composer, with the project as a picker inside it.",
  arms: {
    hero: {
      label: "Hero",
      description:
        "The new chat's hero: its question's size (20px) in the text colour, the project underlined with a chevron.",
    },
    quiet: {
      label: "Quiet",
      description: "Where the old greeting sat: heading size, dimmed, the project underlined with a chevron.",
    },
    chip: {
      label: "Chip",
      description:
        "The hero's size, the project as the composer's folder chip (icon, name, chevron) inside the question.",
    },
  },
  defaultArm: "hero",
});
