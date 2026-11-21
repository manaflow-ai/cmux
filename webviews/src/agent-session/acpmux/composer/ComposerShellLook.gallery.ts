// l10n-allow-file: gallery entry titles, not shipped UI.
// The composer's box (shellLook.experiment.ts): corner, border vs shadow vs fill, inner padding.
import { composerClimbEntry } from "./climbEntry";
import { composerShellLook } from "./shellLook.experiment";

export default composerClimbEntry({
  id: "agent-pane.composer-shell-look",
  title: "Composer box look",
  definition: composerShellLook,
});
