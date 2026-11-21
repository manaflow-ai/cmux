// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// History's Team tab: the team's agent spend from the turns teammates share (cmux-platform
/// `GET /v1/usage/audit` through acpmux's `_acpmux/team_audit`). Off until the platform's audit is
/// on beyond development (Leo, 2026-11-09: "for an engineering leader, it's easy to see like, oh
/// wow, a cost auditing type tracking tool baked into the thing"). Gallery `agent-pane.team-audit`.
export const teamAudit = defineExperiment({
  id: "team-audit",
  title: "Team spend audit",
  description:
    "A Team tab beside History's Costs: the team's shared agent turns summed per person, repository, model, harness, machine or day, with a CSV download.",
  arms: {
    off: { label: "Off", description: "Shipped: History shows no Team tab." },
    on: { label: "On", description: "History shows the Team tab." },
  },
  defaultArm: "off",
});
