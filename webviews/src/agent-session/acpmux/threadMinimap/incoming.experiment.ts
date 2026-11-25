// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the prompt rail draws messages other chats sent (Leo, 2026-11-03: "i've always been on the
/// fence about messages from other chats showing up in that prompt jump scroll rail individual
/// elements"). Every arm keeps them on the rail, in the one column every tick shares at rest (one x,
/// one width: cmux#32637, after Leo rejected #31681's set-in ticks). `as-now` gives each its own tick
/// like a prompt. `secondary` draws their ticks dimmer at rest, so the person's prompts stay the rail's
/// rhythm. `folded` gives a run of them next to each other one tick, whose card reads "Received N
/// messages" from their senders, as the transcript's row for them does (cmux#32720). `folded-secondary`
/// folds and dims (25%); `folded-faint` folds and dims a smaller step (32%). `folded`, the default,
/// folds and draws every resting tick at the person's 40%: a dimmer tick reads as a gap on a dark rail,
/// so a rail of prompts and other chats' messages read as uneven pairs (Leo, 2026-11-06: "you guys
/// didn't fix the spacing on this left side session rail thing"). The card still names the sender.
/// Dogfood switches from `cmux.experiments`: {"thread-minimap-incoming":"folded-secondary"}.
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
      description:
        "Messages next to each other share one tick, drawn as the person's, so every tick keeps the rail's even rhythm; its card reads Received N messages and their senders.",
    },
    "folded-faint": {
      label: "Folded, faint step",
      description: "Folded per run, and the folded tick a small step dimmer at rest (32% against 40%).",
    },
    "folded-secondary": {
      label: "Folded, secondary",
      description: "Folded per run, and the folded tick dimmer at rest: the person's prompts keep the rhythm.",
    },
  },
  defaultArm: "folded",
});

/// Whether an arm folds runs of other chats' messages into one tick, and the opacity their resting
/// ticks draw at when it dims them (the person's draw at 40%), or false when they draw as the person's.
export const INCOMING_LOOK: Record<keyof typeof threadMinimapIncoming.arms, { fold: boolean; dim: number | false }> = {
  "as-now": { fold: false, dim: false },
  secondary: { fold: false, dim: 0.25 },
  folded: { fold: true, dim: false },
  "folded-faint": { fold: true, dim: 0.32 },
  "folded-secondary": { fold: true, dim: 0.25 },
};
