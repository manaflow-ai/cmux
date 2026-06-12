import { RouterProvider } from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { AgentChatApp } from "../agent-chat/react/AgentChatApp";
import agentChatStyles from "../agent-chat/styles.css?inline";
import { createWebviewsRouter } from "../router";
import { installWebviewStyles } from "./installWebviewStyles";

/**
 * Boots the agent chat surface: installs its styles and renders `AgentChatApp`
 * through the shared router. Loaded as its own chunk so the other surfaces
 * never ship the chat UI (matches the agent-session/diff splitting).
 */
export function mountAgentChatSurface(rootElement: HTMLElement): void {
  installWebviewStyles("agent-chat", agentChatStyles);
  document.documentElement.dataset.cmuxWebviewKind = "agent-chat";
  document.body.dataset.cmuxWebviewKind = "agent-chat";
  const router = createWebviewsRouter(() => <AgentChatApp />);
  createRoot(rootElement).render(<RouterProvider router={router} />);
}
