import {
  RouterProvider,
} from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { AgentSessionApp } from "./agent-session/react/main";
import agentSessionStyles from "./agent-session/shared/styles.css?inline";
import { applyCodexDocumentMetadata } from "./agent-session/shared/theme";
import { App } from "./App";
import { applyDiffViewerAppearance, resolveDiffViewerAppearance } from "./appearance";
import { createDiffViewerLabelResolver, shouldAssertMissingLabels } from "./labels";
import { applyDiffViewerStatusToDocument, initialDiffViewerStatus } from "./status";
import diffViewerStyles from "./styles.css?inline";
import { createWebviewsRouter } from "./router";
import type { DiffViewerConfig } from "./types";

type WebviewKind = "agent-session" | "diff";

type DiffViewerRuntime = {
  config: DiffViewerConfig;
  initialStatus: ReturnType<typeof initialDiffViewerStatus>;
};

function readConfig(): DiffViewerConfig {
  const element = document.getElementById("cmux-diff-viewer-config");
  if (!element?.textContent) {
    throw new Error("Missing cmux diff viewer config");
  }
  return JSON.parse(element.textContent);
}

function installStyles(id: string, styles: string) {
  const style = document.createElement("style");
  style.dataset.cmuxWebviewStyle = id;
  style.textContent = styles;
  document.head.append(style);
}

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

const webviewKind = resolveWebviewKind();
const diffRuntime = webviewKind === "diff" ? setupDiffViewer() : null;
if (webviewKind === "agent-session") {
  setupAgentSession();
}

function setupDiffViewer(): DiffViewerRuntime {
  const config = readConfig();
  installStyles("diff", diffViewerStyles);
  applyDiffViewerAppearance(resolveDiffViewerAppearance(config.payload?.appearance));
  if (typeof config.payload?.title === "string" && config.payload.title.trim() !== "") {
    document.title = config.payload.title;
  }
  const label = createDiffViewerLabelResolver(config.payload?.labels, {
    assertMissing: shouldAssertMissingLabels(),
  });
  const initialStatus = initialDiffViewerStatus(config, label);
  document.body.dataset.filesHidden = "false";
  applyDiffViewerStatusToDocument(initialStatus);
  return { config, initialStatus };
}

function setupAgentSession() {
  installStyles("agent-session", agentSessionStyles);
  applyCodexDocumentMetadata();
  document.documentElement.dataset.cmuxWebviewKind = "agent-session";
  document.body.dataset.cmuxWebviewKind = "agent-session";
}

function RoutedWebview() {
  if (webviewKind === "agent-session") {
    return <AgentSessionApp />;
  }
  if (!diffRuntime) {
    throw new Error("Missing cmux diff viewer runtime");
  }
  return <App config={diffRuntime.config} initialStatus={diffRuntime.initialStatus} />;
}

const router = createWebviewsRouter(RoutedWebview);

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

createRoot(rootElement).render(<RouterProvider router={router} />);
