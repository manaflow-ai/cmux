// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where another agent's message the agent has not read yet draws while the turn runs (hq RFD draft
/// transcript-ordering, sweep row 3). acpmux already gave it its place: it went into the turn as a
/// steer, at its record's `seq`, like the person's own steer. The `group` arm pulls it out of the turn
/// into the one group of waiting messages at the end (pendingMessages.ts), so a notice that came in
/// before the person's steer drew under it (Leo, 2026-11-25, relayed with a screenshot of his steer
/// over a notice: "we need to respect the ordering of things coming in when we render it.").
/// The `arrival` arm leaves it at its `seq`; a run of them folds in place (laneNoticeBatches.ts), and
/// only what acpmux has not delivered yet (queue entries, with no `seq`) waits in the end group.
export const waitingMessagesOrder = defineExperiment({
  id: "waiting-messages-order",
  title: "Unread messages in arrival order",
  description: "Where another agent's message the agent has not read yet draws: at its arrival, or in the end group.",
  arms: {
    group: {
      label: "End group",
      description: "Before: an unread message leaves its turn for the one group of waiting messages at the end.",
    },
    arrival: {
      label: "Arrival order",
      description: "An unread message stays where it came in; only queued ones wait in the end group.",
    },
  },
  defaultArm: "arrival",
});
