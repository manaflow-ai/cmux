// The composer's controls (footerControls.experiment.ts): +, the model picker, the mic and Send.
import { composerClimbEntry } from "./climbEntry";
import { composerFooterControls } from "./footerControls.experiment";

export default composerClimbEntry(
  "agent-pane.composer-footer-controls",
  "Composer controls look",
  composerFooterControls,
);
