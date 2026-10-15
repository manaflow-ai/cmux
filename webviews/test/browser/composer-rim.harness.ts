// The chat composer's and the New Tab box's rims and focus rings, with the pane's own stylesheets in
// its entry's order (acpmux/dev.tsx) and the desktop layer's script (it sets the hairline tokens).
import "../../src/pages/shared/desktop";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";
import "../../src/agent-session/acpmux/newtab/screen.css";

document.body.style.margin = "0";
for (const box of document.querySelectorAll<HTMLElement>(".acpmux-composer-box, .nt-box")) {
  Object.assign(box.style, { width: "320px", height: "96px", margin: "16px" });
}
document.documentElement.dataset.harnessReady = "1";
