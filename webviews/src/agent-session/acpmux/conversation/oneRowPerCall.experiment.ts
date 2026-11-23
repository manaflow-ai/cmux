// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where a running turn draws one tool call from the moment its harness names it to its end (Leo,
/// 2026-11-07, on a pending "Writing a file" row over a "Write 12s" line for the same call:
/// "sometimes you can just combine the, like, whatever command or action you're doing sooner than
/// you do"). Every arm draws the call once; they differ in which row and how its words change.
/// Compare them in the gallery's `agent-pane.one-row-per-call`, each with a play from pending to done.
export const oneRowPerCall = defineExperiment({
  id: "one-row-per-call",
  title: "One row per call",
  description:
    "A call from pending to done: watch that it is one row the whole way, that nothing above or below it moves, and how its words change from Writing a file to Writing gen.py to Wrote gen.py.",
  arms: {
    morph: {
      label: "Line, words change in place",
      description:
        "The call is the live line from pending to done; its own words change in place with no roll, and only the next call rolls in. It folds into its run when the next step starts.",
    },
    roll: {
      label: "Line, each state rolls",
      description:
        "The call is the live line from pending to done, and each change of its words rolls the old words out above, as a new step does.",
    },
    row: {
      label: "Own row in its run",
      description:
        "A file change keeps its own row in the run from pending to done, its label changing in place; the live line never names it and reads Thinking meanwhile.",
    },
  },
  defaultArm: "morph",
});

export type OneRowPerCallArm = keyof typeof oneRowPerCall.arms;
