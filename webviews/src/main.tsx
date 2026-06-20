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

// A surface chunk that rejects — failing to load, or throwing while its module
// graph evaluates (e.g. a vendor module that touches a missing browser API at
// import time) — would otherwise be swallowed by `void import(...)`, leaving a
// blank surface over the native (background-less) host with no diagnostic.
// Surface the failure visibly and to the console instead.
function reportSurfaceFailure(target: HTMLElement, kind: WebviewKind, error: unknown): void {
  console.error(`cmux ${kind} surface failed to mount`, error);
  const detail = error instanceof Error ? (error.stack ?? error.message) : String(error);
  const pre = document.createElement("pre");
  pre.style.cssText =
    "margin:0;padding:16px;height:100%;overflow:auto;white-space:pre-wrap;word-break:break-word;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;color:#ff6b6b;background:#1c1c1e";
  pre.textContent = `cmux ${kind} surface failed to mount:\n\n${detail}`;
  target.replaceChildren(pre);
}

// Load only the active surface so each one ships as its own chunk: the diff
// viewer pulls in `@pierre/diffs`, the agent session pulls in its editor UI,
// the kanban board pulls in its own UI, and none pays for the others. Shared
// vendor code (React, the router) is hoisted by Rollup into chunks all reuse.
const webviewKind = resolveWebviewKind();

// React 19 forwards uncaught render errors to `window.onerror` by default, and a
// rejected dynamic import arrives as an `unhandledrejection`. Until a surface
// has rendered anything, treat either as a fatal mount failure and show it —
// otherwise the surface fails to a blank screen over the background-less host.
const handleGlobalFailure = (error: unknown): void => {
  if (rootElement.childElementCount === 0) {
    reportSurfaceFailure(rootElement, webviewKind, error);
  }
};
window.addEventListener("error", (event) => handleGlobalFailure(event.error ?? event.message));
window.addEventListener("unhandledrejection", (event) => handleGlobalFailure(event.reason));
if (webviewKind === "kanban") {
  import("./surfaces/kanbanSurface")
    .then((surface) => surface.mountKanbanSurface(rootElement))
    .catch((error: unknown) => reportSurfaceFailure(rootElement, webviewKind, error));
} else if (webviewKind === "agent-session") {
  import("./surfaces/agentSessionSurface")
    .then((surface) => surface.mountAgentSessionSurface(rootElement))
    .catch((error: unknown) => reportSurfaceFailure(rootElement, webviewKind, error));
} else {
  import("./surfaces/diffSurface")
    .then((surface) => surface.mountDiffSurface(rootElement))
    .catch((error: unknown) => reportSurfaceFailure(rootElement, webviewKind, error));
}

// Catch the silent-blank case: the surface mounted without throwing but never
// produced DOM (a stuck Suspense, a component short-circuiting to null). Without
// this, that failure mode is indistinguishable from a thrown error — both show
// an empty surface.
setTimeout(() => {
  if (rootElement.childElementCount === 0) {
    reportSurfaceFailure(
      rootElement,
      webviewKind,
      new Error("Surface produced no DOM within 5s and threw no error (stuck Suspense or a component returning null)."),
    );
  }
}, 5000);
