// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What the live line's Ctrl-B hint (BackgroundHint.tsx) says, and so how much of the line it keeps.
/// Its room is kept while it is offered (backgroundHintRoom.experiment.ts), so its words cost the
/// command's words that room even before it fades in: "⌃B to run in background" held about 160 px,
/// and in a 280 px pane the command shrank to one letter (Leo, 2026-11-20: "the ctrl b to run in
/// background is just too much too long and to obtrusive at default because it reserves so much
/// shit"). Every arm leaves the line first when it is tight, so the command keeps its room; the
/// button, its tooltip and Ctrl-B itself stay. Compare them in the gallery's
/// `agent-pane.background-hint`.
export const backgroundHintLabel = defineExperiment({
  id: "background-hint-label",
  title: "Ctrl-B hint words",
  description: "How much the live line's Ctrl-B hint says, and so how much of the line it keeps.",
  arms: {
    key: {
      label: "Key cap",
      description: "A small ⌃B key cap; its tooltip says what it does. Leaves a tight line first.",
    },
    fit: {
      label: "Words when wide",
      description: "The full words on a wide line, the ⌃B key cap on a narrower one, nothing on a tight one.",
    },
    words: {
      label: "Full words",
      description: "The old “⌃B to run in background”, leaving only a tight line.",
    },
  },
  defaultArm: "key",
});
