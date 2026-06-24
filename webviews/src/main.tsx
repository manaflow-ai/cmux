type WebviewKind = "agent-session" | "open-chat" | "diff";

function resolveWebviewKind(): WebviewKind {
  if (
    document.documentElement.dataset.cmuxWebviewKind === "open-chat" ||
    document.body.dataset.cmuxWebviewKind === "open-chat" ||
    document.getElementById("cmux-open-chat-config")
  ) {
    return "open-chat";
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
// and Open Chat pulls in its composer home screen.
const webviewKind = resolveWebviewKind();
if (webviewKind === "agent-session") {
  void import("./surfaces/agentSessionSurface").then((surface) => {
    surface.mountAgentSessionSurface(rootElement);
  });
} else if (webviewKind === "open-chat") {
  void import("./surfaces/openChatSurface").then((surface) => {
    surface.mountOpenChatSurface(rootElement);
  });
} else {
  void import("./surfaces/diffSurface").then((surface) => {
    surface.mountDiffSurface(rootElement);
  });
}
