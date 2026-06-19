import { RouterProvider } from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { KanbanApp } from "../kanban/react/main";
import { applyCodexDocumentMetadata } from "../agent-session/shared/theme";
import kanbanStyles from "../kanban/shared/styles.css?inline";
import { createWebviewsRouter } from "../router";
import { installWebviewStyles } from "./installWebviewStyles";

/**
 * Boots the Kanban board surface: installs its styles and the shared Codex
 * document metadata, then renders `KanbanApp` through the shared router. Loaded
 * as its own chunk so the agent-session and diff surfaces never ship the board.
 */
export function mountKanbanSurface(rootElement: HTMLElement): void {
  installWebviewStyles("kanban", kanbanStyles);
  applyCodexDocumentMetadata();
  document.documentElement.dataset.cmuxWebviewKind = "kanban";
  document.body.dataset.cmuxWebviewKind = "kanban";
  const router = createWebviewsRouter(() => <KanbanApp />);
  createRoot(rootElement).render(<RouterProvider router={router} />);
}
