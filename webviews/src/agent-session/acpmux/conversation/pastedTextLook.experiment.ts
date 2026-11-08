// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a block the person pasted reads in their sent message (Leo, 2026-11-08: "It also seems like
/// this pasted text bit wasn't fixed yet"). Every arm draws the paste as the message's own text,
/// under the message's own Show more; no arm draws a card, clips or fades it on its own. Gallery
/// `agent-pane.user-bubble` `pasted-*`.
export const pastedTextLook = defineExperiment({
  id: "pasted-text-look",
  title: "Pasted text in a sent message",
  description: "How a pasted block reads among the person's typed words in their sent message.",
  arms: {
    plain: {
      label: "Plain",
      description: "The paste is ordinary message text, in its place among the typed words, with no marker.",
    },
    marker: {
      label: "Marker",
      description: "The paste is ordinary message text, set off by a quiet rule down its left edge.",
    },
  },
  defaultArm: "plain",
});
