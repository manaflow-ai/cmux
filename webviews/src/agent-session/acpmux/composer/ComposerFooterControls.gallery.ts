// l10n-allow-file: gallery entry titles, not shipped UI.
// The composer's controls (footerControls.experiment.ts): +, the model picker, the mic and Send.
import { composerClimbEntry } from "./climbEntry";
import { composerFooterControls } from "./footerControls.experiment";

export default composerClimbEntry({
  id: "agent-pane.composer-footer-controls",
  title: "Composer controls look",
  definition: composerFooterControls,
});
