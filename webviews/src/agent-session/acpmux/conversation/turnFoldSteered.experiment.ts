// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a finished turn the person steered mid-turn folds. A steer keeps the reply before it in sight
/// (cmux#37245), which used to draw the work around it as run lines beside the closed "Worked for": two
/// folds for one turn (Leo, 2026-11-07: "there's two competing sort of folds in here", "this could have
/// been, like, tucked inside the worked for", "when you open the worked for, that, like, finished two,
/// whatever, that's already automatically expanded"). Compare in `agent-pane.one-fold-per-turn`.
export const turnFoldSteered = defineExperiment({
  id: "turn-fold-steered",
  title: "One fold for a steered turn",
  description: "Where a steered turn's run lines go: inside its Worked for, or beside it as before.",
  arms: {
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
    split: {
      label: "Beside the fold",
      description: "Before: the run lines around the steer's reply draw beside the closed Worked for.",
    },
  },
  defaultArm: "nested-open",
});
