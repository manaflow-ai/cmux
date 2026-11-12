// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// How the jump pair looks (VirtualTranscript.tsx `JumpToLatest` and `JumpUp`, jumpPair.css,
/// design/transcript-overlays.md "The jump pair"). Leo, 2026-11-12, on the fisheye disc: "I feel
/// like this jump to top button is a little bit strange-looking, no? Like, did we redesign that
/// [stuff] yet?" Compare the arms in the gallery's `agent-pane.jump-pair-look` (view Compare arms),
/// or set `cmux.experiments` to `{"jump-pair-look":"lens"}` in the pane's web inspector and reload.
/// Every arm keeps the glass (never opaque), the 32 px height (so Jump up stands over the Needs you
/// pill the same way), the composer's center line, the fade in place, and the behavior.
export const jumpPairLook = defineExperiment({
  id: "jump-pair-look",
  title: "Jump to latest and Jump up: the look",
  description:
    "Both buttons over a transcript parked mid-chat. Look at whether the pair reads as one quiet control over the composer, whether the words under it stay out of the way, and how it sits next to the Needs you pill.",
  arms: {
    frosted: {
      label: "Frosted disc",
      description:
        "A 32 px glass circle at the composer's glass level (the popover level: the surface at 70% under the shared blur), a soft shadow, the arrow. The words under it frost instead of bending, as the scroll-to-bottom circles of the common chat apps do.",
    },
    labeled: {
      label: "Labeled pill",
      description:
        "The same glass as a short rounded rectangle with the arrow and its words (Jump to latest, Jump up, Jump back), the Needs you pill's shape, so the three read as one family.",
    },
    stacked: {
      label: "Stacked squares",
      description:
        "Two frosted rounded squares in the Needs you pill's corner radius, Jump up a hairline gap over Jump to latest, so the pair reads as one compact column.",
    },
    lens: {
      label: "Fisheye lens (before)",
      description:
        'The disc before: a fisheye lens that magnifies and bends the words under it (Leo, 2026-10-21: "I want more fisheye!"), the arrow on a soft pool.',
    },
  },
  defaultArm: "frosted",
});

export type JumpPairLook = keyof typeof jumpPairLook.arms;
