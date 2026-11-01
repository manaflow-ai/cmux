// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// The + menu's commands group (Leo, 2026-11-01: "our + button results are still really bad"): at
/// most a few recent commands and one "Commands and skills…" row that opens the slash list. The
/// arms vary where that row stands and whether recents show; gallery `agent-pane.composer-plus`.
export const composerPlusCommands = defineExperiment({
  id: "composer-plus-commands",
  title: "Composer + menu commands",
  description:
    "Where the + menu's few recent commands and its one Commands and skills… row stand. Every arm keeps the menu short; skills stay under /.",
  arms: {
    "recents-then-row": {
      label: "Recents, then row",
      description: "Up to three recent commands, then Commands and skills… closing the group.",
    },
    "row-then-recents": {
      label: "Row, then recents",
      description: "Commands and skills… first, the recent commands under it.",
    },
    "row-only": {
      label: "Row only",
      description: "No recent commands: one Commands and skills… row.",
    },
  },
  defaultArm: "recents-then-row",
});
