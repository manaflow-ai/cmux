// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";
import { MOTION_MS } from "../../../motion/scale.generated";

/// How a finished turn's big fold plays (turnEndFold.ts `TurnEndLook`). Leo, 2026-11-22: "the big fold we
/// do for claude is not good looking enough. it looks like a gash collapsing. you need to figure out more
/// and more variations to deal with things." Then: "you can decide on whatever you want". The fold matrix
/// (scripts/fold-matrix.ts, median of 3 runs, 18 cells) recommends `wipe`: on the base turn its largest step is
/// 0 to 5 px against fade's 88 (350 at 120 calls), it opens no band (fade's gap: up to 462 px, the gash),
/// and it draws no doubled text (snapshot's dissolve does for ~100 ms). The shipped `fade` stays the default
/// until Leo tries `wipe` in his build (the chat-hold rule: a new default look is his call). A `data-turn-end-fold` attribute
/// over the transcript (the gallery's variants) wins over this.
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
    anchored: {
      label: "Anchored",
      description: "Fade, with the view scrolled so the row under its center stays where the reader saw it.",
    },
    snapshot: {
      label: "Snapshot dissolve",
      description:
        "Nothing slides: the old frame, held as a picture, cross-dissolves into the new, which comes in faster than the old goes.",
    },
    wipe: {
      label: "Wipe (recommended)",
      description: `Nothing slides or fades: an edge runs down from the Worked for line over ${MOTION_MS.large} ms, the new frame above it, the old below.`,
    },
    sprout: {
      label: "Sprout",
      description:
        "Nothing slides: each row crossfades from the old frame to the new as an edge passes it, from the Worked for line down.",
    },
    defer: {
      label: "Defer, then wipe",
      description: `The old frame stays until you scroll, type or click (at most ${MOTION_MS.large * 4} ms), then wipes.`,
    },
  },
  defaultArm: "fade",
});

/// How the turn's closing recap card comes in as the turn folds (turnEndFold.ts `TurnEndRecap`). Leo,
/// 2026-11-22: "that's the recap. you can decide on whatever you want, or r&d more animations." and "i think
/// the fade in from the bottom is pretty awkward sometimes when you finish chats". Recommended: `place`, the card
/// drawn whole where it lands (the fold matrix: full ink on its first frame, against the fade's 148 ms
/// while the view follows it up, which read as a fade up from below). Shipped: `place`.
export const turnEndRecapLook = defineExperiment({
  id: "turn-end-recap-entrance",
  title: "Finished turn recap entrance",
  description: "How the wrap-up recap card comes in under the answer as a finished turn folds.",
  arms: {
    hold: { label: "Fade", description: "Waits until nothing crosses it, then fades in." },
    rise: { label: "Rise", description: "Fades in as it rises half a line into its place." },
    unfurl: { label: "Unfurl", description: "Opens down from its top edge as it fades in." },
    bead: { label: "Bead", description: "Fades in as it grows from 96% from its top edge." },
    place: {
      label: "In place (shipped)",
      description: "Drawn at full ink in its place at once, with no entrance.",
    },
    open: {
      label: "Open",
      description: "Full ink, its room opening down from its top as the rows above rise into it at a line a frame.",
    },
  },
  defaultArm: "place",
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

/// How a finished turn's fold plays when it crosses the person's message (turnEndFold.ts
/// `TurnEndCross`): the work drawn above a steer folds into the one Worked for over it, and an answer
/// that was drawn over a steer it came in under (turns.ts `lateSteersLast`) lands under it. Leo,
/// 2026-11-25: "well, i think we want this tho. specifically. cuz the final ultra fold simply... takes it
/// all away. we simply need to make sure it looks good while doing so. aka fast fades and comfy (maybe
/// eased) and fast and snappy and satisfying transition animations". Before, such a swap drew in one
/// frame (`snap`). Shipped: `quick`, the snappiest whose fade still reads.
export const turnEndCrossLook = defineExperiment({
  id: "turn-end-fold-cross",
  title: "Finished turn fold across your message",
  description: "How the fold at a turn's end plays when it pulls work across a message you sent.",
  arms: {
    snap: { label: "Snap (before)", description: "No motion: the folded turn is drawn in the frame it ends." },
    quick: {
      label: "Quick (shipped)",
      // motion-allow: prose naming the shipped arm's timing for the reviewer, not a duration anything plays
      description: "The work fades out over 120 ms on an ease-out, then the rows under it move up as one over 180 ms.",
    },
    even: {
      label: "Even",
      description: "The work fades out over 140 ms on an ease-out, then the rows under it move up as one over 200 ms.",
    },
    eased: {
      label: "Eased",
      description:
        "The work fades out over 160 ms, then the rows under it move up as one over 220 ms, eased in and out.",
    },
  },
  defaultArm: "quick",
});
