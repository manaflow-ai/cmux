// DESKTOP-FEEL (R139): the shared desktop layer loads first. The hosts of main.mjs link no
// stylesheet (only the Vite HTML entries get assets/desktop.css), so the diff viewer installs the
// layer's CSS inline, ahead of its own styles. The legacy agent session (ACP UI lead) keeps the
// behavior half only until its content opts in with `.selectable`.
import "./pages/shared/desktop";
import desktopStyles from "./pages/shared/desktop.css?inline";
import { installWebviewStyles } from "./surfaces/installWebviewStyles";

type WebviewKind = "agent-session" | "diff";

function resolveWebviewKind(): WebviewKind {
  if (
    document.documentElement.dataset.cmuxWebviewKind === "agent-session" ||
    document.body.dataset.cmuxWebviewKind === "agent-session" ||
    document.getElementById("cmux-agent-session-config")
  ) {
    return "agent-session";
  }
  return "diff";
}

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Missing cmux webview root");
}

// Load only the active surface so each one ships as its own chunk: the diff
// viewer pulls in `@pierre/diffs`, the agent session pulls in its editor UI,
// and neither pays for the other. Shared vendor code (React, the router) is
// hoisted by Rollup into chunks both surfaces reuse.
if (resolveWebviewKind() === "agent-session") {
  void import("./surfaces/agentSessionSurface").then((surface) => {
    surface.mountAgentSessionSurface(rootElement);
  });
} else {
  installWebviewStyles("desktop", desktopStyles);
  void import("./surfaces/diffSurface").then((surface) => {
    void surface.mountDiffSurface(rootElement);
  });
}
