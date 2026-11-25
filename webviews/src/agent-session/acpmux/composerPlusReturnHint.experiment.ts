// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// What Return does, on the + menu's highlighted row (the design review: "show what Return does
/// before Return"; Leo chose the keycap and verb look, 2026-11-22, cmux#49930). "none" is the
/// menu before: the switch back.
export const composerPlusReturnHint = defineExperiment({
  id: "composer-plus-return-hint",
  title: "Composer + menu Return hint",
  description:
    "Whether the + menu's highlighted row ends in the Return keycap and the verb Return carries out (Attach, Run, Open...).",
  arms: {
    verb: {
      label: "Keycap and verb",
      description: "The highlighted row ends in ↩ and its verb; other rows are unchanged.",
    },
    none: {
      label: "None",
      description: "No Return hint: the menu before.",
    },
  },
  defaultArm: "verb",
});
