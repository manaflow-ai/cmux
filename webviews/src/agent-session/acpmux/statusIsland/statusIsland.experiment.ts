// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The agent status island (StatusIsland.tsx): a small floating pill over the chat that counts the
/// running agents and morphs in place into a card for the agent that needs the person (its pending
/// approval with Approve and Deny, or its failure), then back. It adds a surface and replaces none:
/// Needs you, the permission cards and the sidebar dots stay as they are. Off by default while it is
/// a prototype; dogfood opts in from `cmux.experiments`: {"agent-status-island":"on"}.
export const statusIslandExperiment = defineExperiment({
  id: "agent-status-island",
  title: "Agent status island",
  description:
    "A floating pill counts running agents and morphs into a card for the agent that needs you (Approve and Deny, or its error), then back.",
  arms: {
    off: { label: "Off", description: "No island: asks show in their chat, Needs you and the sidebar as today." },
    on: {
      label: "On",
      description: "The pill floats at the top of the chat and expands in place when an agent needs you.",
    },
  },
  defaultArm: "off",
});
