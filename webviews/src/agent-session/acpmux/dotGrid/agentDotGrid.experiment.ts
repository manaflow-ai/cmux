// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment, experimentArm } from "../../../experiments/experiment";

/// The agent dot grid (AgentDotGrid.tsx) on the new chat's home: off by default. To dogfood in the
/// app, set `cmux.experiments` to `{"agent-dot-grid":"on"}` (or `"compact"`) in the pane's web
/// inspector and reload the pane.
export const agentDotGrid = defineExperiment({
  id: "agent-dot-grid",
  title: "Agent dot grid",
  description:
    "Every agent chat, across workspaces, as one dot above the home lists: fill and outline say running, needs approval, done, error or idle; running dots pulse. Hover names the chat, a click opens it.",
  arms: {
    off: { label: "Off", description: "No dot grid; the home shows its lists only." },
    on: { label: "On", description: "A dot grid of 10px dots above the home lists." },
    compact: { label: "Compact", description: "The same grid with dense 6px dots." },
  },
  defaultArm: "off",
});

export type AgentDotGridArm = keyof typeof agentDotGrid.arms;

export const agentDotGridArm = (): AgentDotGridArm => experimentArm(agentDotGrid);
