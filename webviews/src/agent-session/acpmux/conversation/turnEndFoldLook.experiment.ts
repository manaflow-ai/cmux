// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";
import { MOTION_MS } from "../../../motion/scale.generated";

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
    snapshot: {
      label: "Snapshot dissolve",
      description:
        "Nothing slides: the old frame, held as a picture, cross-dissolves into the new, which comes in faster than the old goes.",
    },
    wipe: {
      label: "Wipe",
      description: `Nothing slides or fades: an edge runs down from the Worked for line over ${MOTION_MS.large} ms, the new frame above it, the old below.`,
    },
    sprout: {
      label: "Sprout",
      description: "Nothing slides: each row crossfades from the old frame to the new as an edge passes it, from the Worked for line down.",
    },
    defer: {
      label: "Defer, then wipe",
      description: `The old frame stays until you scroll, type or click (at most ${MOTION_MS.large * 4} ms), then wipes.`,
    },
  },
  defaultArm: "fade",
});

/// How the turn's closing recap card comes in as the turn folds (turnEndFold.ts `TurnEndRecap`). Leo,
/// 2026-11-22: "that's the recap. you can decide on whatever you want, or r&d more animations."
export const turnEndRecapLook = defineExperiment({
  id: "turn-end-recap-entrance",
  title: "Finished turn recap entrance",
  description: "How the wrap-up recap card comes in under the answer as a finished turn folds.",
  arms: {
    hold: { label: "Fade (shipped)", description: "Waits until nothing crosses it, then fades in." },
    rise: { label: "Rise", description: "Fades in as it rises half a line into its place." },
    unfurl: { label: "Unfurl", description: "Opens down from its top edge as it fades in." },
    bead: { label: "Bead", description: "Fades in as it grows from 96% from its top edge." },
  },
  defaultArm: "hold",
});

/// How a subagent block gets to its place as a finished turn folds (turnEndFold.ts `TurnEndSubagent`).
/// Leo, 2026-11-22: "the other one, you can decide as well".
export const turnEndSubagentLook = defineExperiment({
  id: "turn-end-subagent-fold",
  title: "Finished turn subagent fold",
  description: "How a subagent block moves to its place under the Worked for line as a finished turn folds.",
  arms: {
    slide: { label: "Slide (shipped)", description: "Slides with the rows around it." },
    swap: { label: "Swap in place", description: "Fades out where it was as it fades in where it lands." },
    dip: { label: "Dip", description: "Fades out where it was, then in where it lands." },
  },
  defaultArm: "slide",
});
