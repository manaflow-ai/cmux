import { RouterProvider } from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { AgentSessionApp } from "../agent-session/react/main";
import { applyCodexDocumentMetadata } from "../agent-session/shared/theme";
import agentSessionStyles from "../agent-session/shared/styles.css?inline";
import { createWebviewsRouter } from "../router";
import { installWebviewStyles } from "./installWebviewStyles";

/**
 * Boots the agent session surface: installs its styles and Codex document
 * metadata, then renders `AgentSessionApp` through the shared router. Loaded as
 * its own chunk so the diff viewer never ships the agent session UI.
 */
export function mountAgentSessionSurface(rootElement: HTMLElement): void {
  installWebviewStyles("agent-session", agentSessionStyles);
  applyCodexDocumentMetadata();
  document.documentElement.dataset.cmuxWebviewKind = "agent-session";
  document.body.dataset.cmuxWebviewKind = "agent-session";
  const router = createWebviewsRouter(() => <AgentSessionApp />);
  createRoot(rootElement).render(<RouterProvider router={router} />);
}
