// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The Steer queue (SteerQueue.tsx): every live chat in one keyboard list ranked by which needs the
/// person now, with one key to steer, redirect, stop or fork it. Off by default while it is a
/// prototype; dogfood opts in from `cmux.experiments`: {"steer-queue":"on"}. On, the chat menu
/// lists Steer queue and ⌘⇧J opens it.
export const steerQueueExperiment = defineExperiment({
  id: "steer-queue",
  title: "Steer queue",
  description: "One keyboard list of every live chat, ranked by which needs you, with one key to steer, stop or fork.",
  arms: {
    off: { label: "Off", description: "No Steer queue: chats are steered from their own composer." },
    on: { label: "On", description: "The chat menu's Steer queue and ⌘⇧J open the ranked list." },
  },
  defaultArm: "off",
});
