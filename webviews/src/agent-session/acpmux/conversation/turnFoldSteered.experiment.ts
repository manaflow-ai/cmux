// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a finished turn the person steered mid-turn folds. A steer keeps the reply before it in sight
/// (cmux#37245), which used to draw the work around it as run lines beside the closed "Worked for": two
/// folds for one turn (Leo, 2026-11-07: "there's two competing sort of folds in here", "this could have
/// been, like, tucked inside the worked for", "when you open the worked for, that, like, finished two,
/// whatever, that's already automatically expanded"). Compare in `agent-pane.one-fold-per-turn`.
/// The default, `in-order`, folds each stretch where it ran: the turn's Worked for ends at a message
/// that came in mid-turn (the person's steer, another agent's message) and the work after it folds
/// under its own line below it. The other arms drew one Worked for at the turn's top, which pulled the
/// work after the message up above it (Leo, 2026-11-11: "it sort of, like, steals commands that came
/// in, perhaps, like, in between something, and it just shunts them to the top, like it rewrites the
/// transcript in a way").
/// Three `trim-*` arms trim `in-order` (RFD 0085's follow-up: every seat named "one footer per turn,
/// quieter summaries for the stretches before a steer" as the subtle form of Leo's "stick the steered
/// together", 2026-11-22). They fold as `in-order` does and keep each steer where it arrived; they
/// differ in how quiet a Worked for above a steer is and in when the stretch footers go. Compare in
/// `agent-pane.steered-turn-trim`. `trimArm` reads which one, if any.
export const turnFoldSteered = defineExperiment({
  id: "turn-fold-steered",
  title: "One fold for a steered turn",
  description: "Where a steered turn's work folds: in order around the steer, inside one Worked for, or beside it.",
  arms: {
    "in-order": {
      label: "In order",
      description: "A message that came in mid-turn ends the Worked for above it; the work after it folds below it.",
    },
    "nested-open": {
      label: "Nested, open",
      description: "Every run line sits inside Worked for and is already open when Worked for opens.",
    },
    nested: {
      label: "Nested, closed",
      description: "Every run line sits inside Worked for and opens on its own click.",
    },
    header: {
      label: "On the header",
      description: "Worked for's line names the work it holds; its run lines open with it.",
    },
    "trim-muted": {
      label: "In order, trimmed",
      description:
        "As in order; a Worked for above a steer draws in the quieter color, and the turn has one footer, under its answer.",
    },
    "trim-bare": {
      label: "In order, bare",
      description:
        "As in order; a Worked for above a steer says its time alone, quieter, with no rule, and the turn has one footer.",
    },
    "trim-at-end": {
      label: "In order, footers at the end",
      description:
        "As trimmed; each steer brings its stretch's footer while the turn runs, and the turn's end keeps its one footer.",
    },
    split: {
      label: "Beside the fold",
      description: "Before: the run lines around the steer's reply draw beside the closed Worked for.",
    },
  },
  defaultArm: "in-order",
});

/// A trim of `in-order` (the `trim-*` arms): how quiet a Worked for above a steer draws, and whether
/// the stretch footers stay while the turn runs (`trim-at-end`) or never draw.
export type SteeredTrim = { quiet: "muted" | "bare"; liveFooters: boolean };
const TRIMS: Readonly<Record<string, SteeredTrim>> = {
  "trim-muted": { quiet: "muted", liveFooters: false },
  "trim-bare": { quiet: "bare", liveFooters: false },
  "trim-at-end": { quiet: "muted", liveFooters: true },
};
/// The trim `arm` names, if it is one of the `trim-*` arms.
export const trimArm = (arm: string | undefined): SteeredTrim | undefined => (arm ? TRIMS[arm] : undefined);
/// Whether `arm` folds a steered turn in order: `in-order` and its trims.
export const foldsArmInOrder = (arm: string | undefined) => arm === "in-order" || trimArm(arm) !== undefined;
