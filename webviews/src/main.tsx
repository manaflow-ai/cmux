type WebviewKind = "agent-chat" | "agent-session" | "diff";

function resolveWebviewKind(): WebviewKind {
  if (
    document.documentElement.dataset.cmuxWebviewKind === "agent-chat" ||
    document.body.dataset.cmuxWebviewKind === "agent-chat" ||
    document.getElementById("cmux-agent-chat-config") ||
    // Vite dev / standalone fallback: the router uses hash history, so plain
    // `bun run dev` reaches the surface at `/#/agent-chat` with no host HTML.
    window.location.hash.startsWith("#/agent-chat")
  ) {
    return "agent-chat";
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
if (webviewKind === "agent-chat") {
  void import("./surfaces/agentChatSurface").then((surface) => {
    surface.mountAgentChatSurface(rootElement);
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
