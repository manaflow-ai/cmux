// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a cmux deeplink typed or pasted into the composer draws in the draft (Leo, 2026-11-03: "hm i
/// wonder if those should be rendered the deeplinks within the composer too..."). Every arm keeps
/// the URL as the draft's text, so send, copy and undo see exactly what was typed. Gallery
/// `agent-pane.composer-deeplinks`.
export const composerDeeplinkLook = defineExperiment({
  id: "composer-deeplink-look",
  title: "Composer deeplinks",
  description:
    "How a cmux deeplink (cmux://workspace/…, cmux://agent/…, cmux.com/deeplink/…) reads in the draft. The text stays the URL in every arm; only its look changes.",
  arms: {
    link: {
      label: "Link",
      description: "The link blue with a faint underline, as the sent prompt draws the same URL.",
    },
    chip: {
      label: "Chip",
      description: "The URL on the session chip's grey wash, rounded, as a chip in the line.",
    },
    plain: {
      label: "Plain",
      description: "Plain text, as before.",
    },
  },
  defaultArm: "link",
});
