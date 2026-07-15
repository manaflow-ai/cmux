type WebviewKind = "agent-session" | "diff" | "feed";

function resolveWebviewKind(): WebviewKind {
  if (
    document.documentElement.dataset.cmuxWebviewKind === "agent-session" ||
    document.body.dataset.cmuxWebviewKind === "agent-session" ||
    document.getElementById("cmux-agent-session-config")
  ) {
    return "agent-session";
  }
  if (
    document.documentElement.dataset.cmuxWebviewKind === "feed" ||
    document.body.dataset.cmuxWebviewKind === "feed" ||
    document.getElementById("cmux-feed-config")
  ) {
    return "feed";
  }
  return "diff";
}

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Missing cmux webview root");
}

// Load only the active surface so each one ships as its own chunk: the diff
// viewer pulls in `@pierre/diffs`, the agent session pulls in its editor UI,
// without paying for the others. Shared vendor code (React, the router) is
// hoisted by Rollup into chunks all surfaces reuse.
if (resolveWebviewKind() === "agent-session") {
  void import("./surfaces/agentSessionSurface").then((surface) => {
    surface.mountAgentSessionSurface(rootElement);
  });
} else if (resolveWebviewKind() === "feed") {
  void import("./surfaces/feedSurface").then((surface) => {
    surface.mountFeedSurface(rootElement);
  });
} else {
  void import("./surfaces/diffSurface").then((surface) => {
    surface.mountDiffSurface(rootElement);
  });
}
