// The composer hat (subagents/SubagentTray.tsx) joined to the docked composer card as one glass
// (bottomStack.css), with the pane's own stylesheets in its entry's order (acpmux/dev.tsx) and the
// desktop layer's script (it sets the hairline tokens and loads the glass the card wears).
import "../../src/pages/shared/desktop";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";
import "../../src/agent-session/acpmux/subagents/subagents.css";
import "../../src/agent-session/acpmux/bottomStack.css";

document.body.style.margin = "0";
for (const dock of document.querySelectorAll<HTMLElement>(".acpmux-dock")) {
  Object.assign(dock.style, { display: "flex", flexDirection: "column", width: "380px", margin: "16px" });
}
for (const box of document.querySelectorAll<HTMLElement>(".acpmux-composer-box")) box.style.height = "72px";
document.documentElement.dataset.harnessReady = "1";
