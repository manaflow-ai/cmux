// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a pasted or dropped attachment's tile looks while the composer still reads it (composer/
/// pasteLoading.tsx), in the text at the caret and in the strip (Leo, 2026-11-07: "do we necessarily
/// need a spinner for it? Or should it just sort of, like, be dimmed to start and then, like, gradually
/// become more there as it actually loads in? ... Or actually, could we do both? ... why do we have a
/// solid color thing anyway? Shouldn't it also be glass?"). Every arm is the composer's own glass, dim
/// at first and coming up as it loads; they differ in what shows once a read takes longer than 400 ms.
/// Compare them in the gallery's `agent-pane.composer-paste-loading`.
export const pastePlaceholderLook = defineExperiment({
  id: "composer-paste-loading",
  title: "Pasted attachment loading",
  description:
    "A pasted attachment's tile while it loads: glass, dim at first and coming up as it loads; then a small ring, a thin bar along its foot, or nothing once the read passes 400 ms.",
  arms: {
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
  defaultArm: "glass-ring",
});
