// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the prompt rail draws messages other chats sent (Leo, 2026-11-03: "i've always been on the
/// fence about messages from other chats showing up in that prompt jump scroll rail individual
/// elements"). Every arm keeps them on the rail, in the one column every tick shares at rest (one x,
/// one width: cmux#32637, after Leo rejected #31681's set-in ticks). `as-now` gives each its own tick
/// like a prompt. `secondary` draws their ticks dimmer at rest, so the person's prompts stay the rail's
/// rhythm. `folded` gives a run of them next to each other one tick, whose card reads "Received N
/// messages" from their senders, as the transcript's row for them does (cmux#32720). `folded-secondary`,
/// the default, folds and dims. Dogfood switches from `cmux.experiments`:
/// {"thread-minimap-incoming":"as-now"}.
export const threadMinimapIncoming = defineExperiment({
  id: "thread-minimap-incoming",
  title: "Prompt rail: other chats' messages",
  description: "How the prompt rail draws messages from other chats: a tick each, dimmer, folded per run, or both.",
  arms: {
    "as-now": { label: "A tick each", description: "Every message from another chat is its own tick, like a prompt." },
    secondary: {
      label: "Secondary",
      description: "A tick each, dimmer at rest (25% against 40%) in the same column; the card names the sender.",
    },
    folded: {
      label: "Folded",
      description: "Messages next to each other share one tick; its card reads Received N messages and their senders.",
    },
    "folded-secondary": {
      label: "Folded, secondary",
      description: "Folded per run, and the folded tick dimmer at rest: the person's prompts keep the rhythm.",
    },
  },
  defaultArm: "folded-secondary",
});

/// Whether an arm folds runs of other chats' messages into one tick, and whether it dims their ticks.
export const INCOMING_LOOK: Record<keyof typeof threadMinimapIncoming.arms, { fold: boolean; dim: boolean }> = {
  "as-now": { fold: false, dim: false },
  secondary: { fold: false, dim: true },
  folded: { fold: true, dim: false },
  "folded-secondary": { fold: true, dim: true },
};
