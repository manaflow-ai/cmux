// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Opening another chat in the pane (chatSwitch.ts): whether the transcript, its title and Session
/// Info move as one short performance or simply appear. Leo, 2026-11-01: "honestly i just want to
/// be able to be able to eventually play full-on animations like this", and 2026-11-03: "i wanted to
/// have more... nice stuff? around the app". Stagger is the default: the new chat is in the DOM on
/// the frame the switch lands (rule 14's "instant"), and the motion plays over it and adds no
/// dropped frame or long task (motion-and-polish.md, Choreography). To try another, set
/// `cmux.experiments` to `{"chat-switch-motion":"off"}` (or another arm) in the pane's web
/// inspector and reload.
export const chatSwitchMotion = defineExperiment({
  id: "chat-switch-motion",
  title: "Chat switch motion",
  description:
    "Opening another chat: the transcript's visible rows, the chat title and the Session Info body. Watch whether the switch reads as one movement and whether the reading position (the bottom rows) settles first.",
  arms: {
    off: { label: "Off", description: "The new chat is drawn in one frame, with no motion." },
    fade: { label: "Fade", description: "Transcript, title and Session Info fade in together over 120 ms, no travel." },
    stagger: {
      label: "Stagger",
      description:
        "The title, then the visible rows from the bottom up, each rising 6 px on one spring, 16 ms apart; Session Info's body follows from the right. All settled within 240 ms.",
    },
    depth: {
      label: "Depth",
      description:
        "The transcript comes forward from 98.5% as one sheet while Session Info slides 8 px in from its edge, on the same spring, in 180 ms.",
    },
  },
  defaultArm: "stagger",
});

export type ChatSwitchArm = keyof typeof chatSwitchMotion.arms;
