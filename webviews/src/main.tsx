import { bootSurface, type WebviewKind } from "./surfaceBoot";

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
//
// `bootSurface` guarantees a failed import/mount never leaves a blank pane: it
// auto-reloads once (self-healing a restored page whose scheme token lapsed)
// and otherwise renders a visible retry instead of nothing. See surfaceBoot.ts.
const webviewKind = resolveWebviewKind();
const load =
  webviewKind === "agent-session"
    ? () => import("./surfaces/agentSessionSurface").then((s) => s.mountAgentSessionSurface)
    : webviewKind === "editor"
      ? () => import("./surfaces/editorSurface").then((s) => s.mountEditorSurface)
      : () => import("./surfaces/diffSurface").then((s) => s.mountDiffSurface);

void bootSurface({
  root: rootElement,
  kind: webviewKind,
  load,
  reload: () => window.location.reload(),
  storage: window.sessionStorage,
  onError: (message, error) => {
    // Serialize the error into the message: an Error/DOMException logged as a
    // second console arg serializes to `{}` through the native console bridge,
    // which hides the actual cause (e.g. a CSP-blocked CSS preload that rejects
    // the surface's dynamic import).
    const detail =
      error instanceof Error
        ? `${error.name}: ${error.message}${error.stack ? `\n${error.stack}` : ""}`
        : typeof error === "string"
          ? error
          : (() => {
              try {
                return JSON.stringify(error);
              } catch {
                return String(error);
              }
            })();
    console.error(`${message} :: ${detail}`);
  },
});
