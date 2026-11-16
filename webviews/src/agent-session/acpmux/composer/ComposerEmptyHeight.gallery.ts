// The composer's resting height and placeholder (emptyHeight.experiment.ts).
import { composerClimbEntry } from "./climbEntry";
import { composerEmptyHeight } from "./emptyHeight.experiment";

export default composerClimbEntry({
  id: "agent-pane.composer-empty-height",
  title: "Composer resting height",
  definition: composerEmptyHeight,
});
