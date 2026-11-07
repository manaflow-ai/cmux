// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where the live line's "⌃B to run in background" (BackgroundHint.tsx) sits, so pointing at the
/// line never moves or covers its times and tokens (Leo, 2026-11-06, on "8s · 2m5 1.4K toke" drawn
/// over itself while he hovered the line's right edge: "this flickers"). The hint used to take its
/// room only on hover, which squeezed the counts into each other and moved them under the pointer.
/// Every arm keeps the hint's room while it is offered, so hover changes its opacity alone.
/// Compare them in the gallery's `agent-pane.background-hint`.
export const backgroundHintRoom = defineExperiment({
  id: "background-hint-room",
  title: "Ctrl-B hint room",
  description: "Where the live line keeps the room of its Ctrl-B hint, so hovering the line moves nothing.",
  arms: {
    end: {
      label: "Line end, on hover",
      description: "Its room kept at the line's right end; it fades in there on hover.",
    },
    inline: {
      label: "After the counts, on hover",
      description: "Its room kept right after the tokens, a dot before it; it fades in there on hover.",
    },
    always: {
      label: "Line end, always",
      description: "Shown at the line's right end while the command runs, with or without the pointer.",
    },
  },
  defaultArm: "end",
});
