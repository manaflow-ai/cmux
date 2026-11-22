// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../../pages/shared/desktop";
// The shared icon+label button (cx-s6zvc); the pane does not load the rest of ui.css.
import "../../ui/ghost.css";
import "../../ui/controls.css";
import "./composerFooterShared.css";
import "./diffTokens.css";
import "./styles.css";
// The UI inspector's outline, label and hint (uiPointer/overlay.ts).
import "./uiPointer/uiPointer.css";
