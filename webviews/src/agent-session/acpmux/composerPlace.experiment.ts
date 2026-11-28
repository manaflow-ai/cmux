// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Where the bottom stack (the composer and the parts over it) sits against the transcript's
/// scroller. cmuxterm-hq docs/design/agent-transcript-clean-slate.md: "The composer is outside the
/// scroller. Its growth shrinks the viewport. When pinned, the bottom edge holds. When not pinned,
/// the top anchor holds." Today's stack lies over the transcript's foot (bottomStack.css, Leo
/// 2026-10-19: the transcript runs the pane's height under it, as the Claude and Codex apps lay
/// their composer), and that stays the default: this arm flips nothing. `outside` puts the stack in
/// the pane's flow under the scroller, as a new chat's hero and the diff already do, so a composer
/// that grows a line takes that line from the viewport. VirtualTranscript keeps the last row on the
/// viewport's bottom edge while the chat follows the latest, and the reader's top row in place
/// while it does not (test/composer-outside-scroller.test.ts measures both).
/// Compare the arms in the gallery's `agent-pane.composer-outside-scroller`, or set
/// `cmux.experiments` to `{"composer-place":"outside"}` in the pane's web inspector and reload.
export const composerPlace = defineExperiment({
  id: "composer-place",
  title: "Composer: over the transcript's foot, or outside the scroller",
  description:
    "A long chat with a draft that grows from one line to five. Look at whether the last message stays on the composer while the chat follows the latest, and whether a reader scrolled up keeps their place.",
  arms: {
    over: {
      label: "Over the foot (today)",
      description:
        "The stack lies over the transcript's foot; the transcript runs the pane's height and keeps the stack's height as room under its last row.",
    },
    outside: {
      label: "Outside the scroller",
      description:
        "The stack sits under the scroller in the pane's flow; its growth shrinks the viewport, the bottom edge holds while pinned and the top row holds while scrolled up.",
    },
  },
  defaultArm: "over",
});

export type ComposerPlace = keyof typeof composerPlace.arms;
