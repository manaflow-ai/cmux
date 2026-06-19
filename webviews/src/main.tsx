type WebviewKind = "agent-session" | "diff" | "kanban";

function resolveWebviewKind(): WebviewKind {
  if (
    document.documentElement.dataset.cmuxWebviewKind === "kanban" ||
    document.body.dataset.cmuxWebviewKind === "kanban"
  ) {
    return "kanban";
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
// the kanban board pulls in its own UI, and none pays for the others. Shared
// vendor code (React, the router) is hoisted by Rollup into chunks all reuse.
const webviewKind = resolveWebviewKind();
if (webviewKind === "kanban") {
  void import("./surfaces/kanbanSurface").then((surface) => {
    surface.mountKanbanSurface(rootElement);
  });
} else if (webviewKind === "agent-session") {
  void import("./surfaces/agentSessionSurface").then((surface) => {
    surface.mountAgentSessionSurface(rootElement);
  });
} else {
  void import("./surfaces/diffSurface").then((surface) => {
    surface.mountDiffSurface(rootElement);
  });
}
