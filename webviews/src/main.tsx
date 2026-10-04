// DESKTOP-FEEL (R139): the shared desktop layer loads first. The hosts of main.mjs link no
// stylesheet (only the Vite HTML entries get assets/desktop.css), so the diff viewer installs the
// layer's CSS inline, ahead of its own styles.
import "./pages/shared/desktop";
import desktopStyles from "./pages/shared/desktop.css?inline";
import { installWebviewStyles } from "./surfaces/installWebviewStyles";

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Missing cmux webview root");
}

// The diff viewer loads as its own chunk (it pulls in `@pierre/diffs`). The agent session that
// main.mjs also booted is retired: the agent pane (agent-session/acpmux) replaced it.
installWebviewStyles("desktop", desktopStyles);
void import("./surfaces/diffSurface").then((surface) => {
  void surface.mountDiffSurface(rootElement);
});
