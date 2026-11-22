// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a finished turn's big fold plays (turnEndFold.ts `TurnEndLook`). Leo, 2026-11-22: "the big fold we
/// do for claude is not good looking enough. it looks like a gash collapsing. you need to figure out more
/// and more variations to deal with things." The shipped `fade` stays the default until he picks one by
/// feel. A `data-turn-end-fold` attribute over the transcript (the gallery's variants) wins over this.
/// Compare in `agent-pane.turn-end-fold` and `agent-pane.big-claude-fold`.
export const turnEndFoldLook = defineExperiment({
  id: "turn-end-fold-look",
  title: "Finished turn fold look",
  description: "How the rows a finished turn folds away go, and how the rest closes over them.",
  arms: {
    fade: {
      label: "Fade, then close (shipped)",
      description: "The folded rows fade in 40 ms, then the rows around them close on the house settle.",
    },
    tuck: { label: "Tuck", description: "The folded rows slide up under the Worked for line as they fade." },
    stagger: { label: "Stagger", description: "The folded rows fade from the last up, one after another." },
    crossfade: {
      label: "Crossfade",
      description: "No lead: the folded rows fade over the whole move, cropped by the rows closing over them.",
    },
    morph: {
      label: "Card morph",
      description: "A tinted card takes the folded rows' place and shrinks into the Worked for line.",
    },
    cascade: {
      label: "Cascade",
      description: "The folded rows fold up into the Worked for line one after another, top first.",
    },
    glide: {
      label: "Glide",
      description: "A soft-start ease-in-out over the large motion step in place of the settle's ease-out.",
    },
    spring: { label: "Spring", description: "A critically damped spring (no overshoot) over 360 ms." },
    wait: {
      label: "Hold, then fold",
      description: "The ended turn's work stays in sight 320 ms after the answer lands, then folds.",
    },
    dissolve: {
      label: "Dissolve",
      description: "Nothing slides: every row that moves fades out where it was and in where it lands.",
    },
    sheet: {
      label: "Sheet",
      description:
        "The folded work rides up with the answer under the Worked for line as one surface, cropped as it goes.",
    },
    capped: {
      label: "Capped speed",
      description:
        "A speed limit at half the house bound: one steady speed, then a soft landing; a long move takes longer.",
    },
    viscous: {
      label: "Viscous",
      description:
        "Each moving row starts a frame after the one nearer the fold, so the rows are drawn in like a liquid.",
    },
    water: {
      label: "Water",
      description:
        "Sheet on the house spring: the work flows in under the line, starting still and landing without overshoot.",
    },
    edge: {
      label: "Edge start",
      description:
        "Rows that start out of sight start just past the view's edge, so nothing travels farther than it is seen.",
    },
  },
  defaultArm: "fade",
});
