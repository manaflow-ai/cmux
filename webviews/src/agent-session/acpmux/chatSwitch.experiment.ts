// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Opening another chat in the pane (chatSwitch.ts): whether the transcript, its title and Session
/// Info move as one short performance or simply appear. Leo, 2026-11-01: "honestly i just want to
/// be able to be able to eventually play full-on animations like this". Today's switch is instant,
/// which is what motion-and-polish.md rule 14 asks of a cached view ("instant if cached"), so Off
/// stays the default; to try another, set `cmux.experiments` to `{"chat-switch-motion":"stagger"}`
/// in the pane's web inspector and reload.
export const chatSwitchMotion = defineExperiment({
  id: "chat-switch-motion",
  title: "Chat switch motion",
  description:
    "Opening another chat: the transcript's visible rows, the chat title and the Session Info body. Watch whether the switch reads as one movement and whether the reading position (the bottom rows) settles first.",
  arms: {
    off: { label: "Off", description: "Today: the new chat is drawn in one frame." },
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
  defaultArm: "off",
});

export type ChatSwitchArm = keyof typeof chatSwitchMotion.arms;
