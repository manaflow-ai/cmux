// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a pasted or dropped attachment's tile looks while the composer still reads it (composer/
/// pasteLoading.tsx), in the text at the caret and in the strip (Leo, 2026-11-07: "do we necessarily
/// need a spinner for it? Or should it just sort of, like, be dimmed to start and then, like, gradually
/// become more there as it actually loads in? ... Or actually, could we do both? ... why do we have a
/// solid color thing anyway? Shouldn't it also be glass?"). Every arm is the composer's own glass, dim
/// at first and coming up as it loads; they differ in what shows once a read takes longer than 400 ms.
/// Compare them in the gallery's `agent-pane.composer-paste-loading`.
///
/// The `chip` arms answer Leo, 2026-11-10: "the preview placeholder boxes are incongruent between the
/// initial load, then the second load, and the chat attachment itself", and 2026-11-11: "this 3 stage
/// attachment thing is still there". There is no loading tile at all: the file is the chip it becomes
/// from its first frame, in its final box (an image's picture or its glyph, a video's play tile, a
/// file's name and size), and only its picture fills in. They differ in how a read still running shows.
/// The `glass` arms are the loading tile before: a box of its own, then the chip.
export const pastePlaceholderLook = defineExperiment({
  id: "composer-paste-loading",
  title: "Pasted attachment loading",
  description:
    "A pasted attachment's tile while it loads: glass, dim at first and coming up as it loads; then a small ring, a thin bar along its foot, or nothing once the read passes 400 ms.",
  arms: {
    chip: {
      label: "The chip at once",
      description:
        "No loading tile: the chip it becomes, in its final box from the first frame (picture or kind glyph, a file's name), its picture filling in when read. No indicator.",
    },
    "chip-blur": {
      label: "The chip at once, soft picture",
      description:
        "The chip in its final box from the first frame; its picture is soft until the read ends, then sharpens in place.",
    },
    "chip-bar": {
      label: "The chip at once, late bar",
      description:
        "The chip in its final box from the first frame; a thin bar along its foot only once the read passes 400 ms.",
    },
    "glass-ring": {
      label: "Glass, late ring",
      description:
        "Glass that starts dim and comes up; a small spinner ring fades in only once the read passes 400 ms.",
    },
    "glass-bar": {
      label: "Glass, late bar",
      description:
        "Glass that starts dim and comes up; a thin bar along the tile's foot fills once the read passes 400 ms.",
    },
    "glass-dim": {
      label: "Glass, dim only",
      description: "Glass that starts dim and comes up; no indicator at all, only an upload's own progress ring.",
    },
  },
  defaultArm: "chip",
});
