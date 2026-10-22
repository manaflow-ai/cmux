// The chat's Summary popover (acpmux/summary/SummaryCard.tsx) with the pane's own stylesheets in its
// entry's order (acpmux/dev.tsx) and the desktop layer's script (it loads the liquid glass).
import "../../src/pages/shared/desktop";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/summary/summary.css";

document.body.style.margin = "0";
document.documentElement.dataset.harnessReady = "1";
