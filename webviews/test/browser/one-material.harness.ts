// The floating primitives' stylesheets in the pane's order (acpmux/dev.tsx), and the desktop layer's
// script, which loads the glass every surface wears (one-material-browser.test.ts).
import "../../src/pages/shared/desktop";
import "../../src/ui/ui.css";
import "../../src/ui/controls.css";
import "../../src/ui/popupSurface.css";
import "../../src/ui/notice.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "../../src/agent-session/acpmux/threadMinimap/threadMinimap.css";
import "../../src/agent-session/acpmux/chips/linkCard.css";

document.body.style.margin = "0";
document.documentElement.dataset.harnessReady = "1";
