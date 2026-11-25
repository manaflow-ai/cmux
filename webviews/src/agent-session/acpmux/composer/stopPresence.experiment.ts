// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the composer's Stop shows that a turn started again while it lingered after the last one's
/// end (composer/turnPresence.ts; Leo, 2026-11-22: "we ought to have a better fade in/fade out and
/// maybe a pulse when you for some reason start stop quick. so that the composer isn't flickering
/// with the stop button"). Every arm keeps Stop's 28 px box, fades Stop in and out, plays once on
/// the motion scale's 180 ms step, and plays nothing under Reduce Motion. Gallery
/// `agent-pane.composer-stop-presence`.
export const stopPresence = defineExperiment({
  id: "stop-presence",
  title: "Stop presence and pulse",
  description:
    "What the composer's Stop does when a turn ends and the next starts within a moment: it stays, and pulses once in place of going and coming back.",
  arms: {
    ring: {
      label: "Ring",
      description: "A soft ring in the glyph's color grows out of Stop's box and fades.",
    },
    bump: {
      label: "Bump",
      description: "Stop's glyph swells to 115% and settles back.",
    },
    fade: {
      label: "Fade only",
      description: "No pulse: Stop dims while it lingers and comes back to full when the next turn starts.",
    },
  },
  defaultArm: "ring",
});

export type StopPresenceArm = keyof typeof stopPresence.arms;
