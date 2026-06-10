type WebviewKind = "agent-session" | "diff" | "editor";

function resolveWebviewKind(): WebviewKind {
  if (
    document.documentElement.dataset.cmuxWebviewKind === "agent-session" ||
    document.body.dataset.cmuxWebviewKind === "agent-session" ||
    document.getElementById("cmux-agent-session-config")
  ) {
    return "agent-session";
  }
  if (
    document.documentElement.dataset.cmuxWebviewKind === "editor" ||
    document.body.dataset.cmuxWebviewKind === "editor" ||
    document.getElementById("cmux-editor-config")
  ) {
    return "editor";
  }
  return "diff";
}

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Missing cmux webview root");
}

// Load only the active surface so each one ships as its own chunk: the diff
// viewer pulls in `@pierre/diffs`, the agent session pulls in its editor UI,
// the editor pulls in Monaco, and none pays for the others. Shared vendor code
// (React, the router) is hoisted by Rollup into chunks all surfaces reuse.
const webviewKind = resolveWebviewKind();
if (webviewKind === "agent-session") {
  void import("./surfaces/agentSessionSurface").then((surface) => {
    surface.mountAgentSessionSurface(rootElement);
  });
} else if (webviewKind === "editor") {
  void import("./surfaces/editorSurface").then((surface) => surface.mountEditorSurface(rootElement));
} else {
  void import("./surfaces/diffSurface").then((surface) => {
    surface.mountDiffSurface(rootElement);
  });
}
