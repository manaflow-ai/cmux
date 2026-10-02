// Entry of the ported agent pane (spec/acp-ui.md, codex-atlas-clone port). Swift loads the
// page built by scripts/cmux-next/build-agent-pane-port-web.sh when Debug Settings selects
// the "Port" prototype; the host contract is the current pane's.
import { createRoot } from "react-dom/client";
// Tokens and chrome first; the theme mapping and the pane layout override last.
import "./shell/tokens.css";
import "./shell/base.css";
import "./shell/shell.css";
import { PortApp } from "./pane/PortApp";
import "./theme/theme.css";
import "./pane/pane.css";

document.documentElement.dataset.cmuxWebviewKind = "acpmux-agent-session-port";
createRoot(document.getElementById("root")!).render(<PortApp />);
