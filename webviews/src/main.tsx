type WebviewKind = "agent-session" | "diff" | "gui-mode";

function resolveWebviewKind(): WebviewKind {
  if (
    document.documentElement.dataset.cmuxWebviewKind === "gui-mode" ||
    document.body.dataset.cmuxWebviewKind === "gui-mode"
  ) {
    return "gui-mode";
  }
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
const webviewKind = resolveWebviewKind();
if (webviewKind === "gui-mode") {
  void import("./surfaces/guiModeSurface").then((surface) => {
    surface.mountGuiModeSurface(rootElement);
  }).catch((error) => renderSurfaceLoadError(rootElement, error, "Could not load GUI Mode."));
} else if (webviewKind === "agent-session") {
  void import("./surfaces/agentSessionSurface").then((surface) => {
    surface.mountAgentSessionSurface(rootElement);
  }).catch((error) => renderSurfaceLoadError(rootElement, error, "Could not load the agent session."));
} else {
  void import("./surfaces/diffSurface").then((surface) => {
    surface.mountDiffSurface(rootElement);
  }).catch((error) => renderSurfaceLoadError(rootElement, error, "Could not load the webview."));
}

function renderSurfaceLoadError(root: HTMLElement, error: unknown, fallback: string): void {
  const message = error instanceof Error && error.message ? error.message : fallback;
  root.textContent = message;
  root.setAttribute("role", "alert");
  root.style.cssText = [
    "min-height:100vh",
    "display:grid",
    "place-items:center",
    "padding:24px",
    "color:#f1f0e8",
    "background:transparent",
    "font:13px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif",
  ].join(";");
}
