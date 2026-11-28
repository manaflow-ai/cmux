// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the Background tasks panel (BackgroundTasksPanel.tsx) tells an agent's row from a command's
/// (Leo, 2026-11-24: "there is no delineation between subagents and tool calls"). Compare the arms in
/// the gallery's `agent-pane.background-tasks-rows`. Every arm leads an agent's row with the agent glyph
/// and its title at normal weight, and a command's or tool call's row with the terminal glyph in the
/// muted tone, as the chat's tool rows lead with theirs; the arms differ in how the blocks sit.
export const backgroundTasksRows = defineExperiment({
  id: "background-tasks-rows",
  title: "Background tasks rows",
  description:
    "Agents and commands told apart by a leading glyph: on the tinted agent blocks, on bare blocks parted by a rule, or in a small tile.",
  arms: {
    glyphs: {
      label: "Glyphs on blocks",
      description: "The agent glyph or the terminal glyph leads each row; each agent keeps its tinted block.",
    },
    rule: {
      label: "Glyphs, parted by a rule",
      description: "As Glyphs, with no tinted block: agents are parted by a hairline and their tasks stand in a rail.",
    },
    tile: {
      label: "Glyphs in tiles",
      description: "Each row's glyph sits in a small tinted tile, the agents' in the accent, the commands' neutral.",
    },
  },
  defaultArm: "glyphs",
});
