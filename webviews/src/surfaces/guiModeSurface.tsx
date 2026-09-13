import { RouterProvider } from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { applyCodexDocumentMetadata } from "../agent-session/shared/theme";
import agentSessionStyles from "../agent-session/shared/styles.css?inline";
import { GuiModeApp } from "../gui-mode/GuiModeApp";
import guiModeStyles from "../gui-mode/styles.css?inline";
import { createWebviewsRouter } from "../router";
import { installWebviewStyles } from "./installWebviewStyles";

export function mountGuiModeSurface(rootElement: HTMLElement): void {
  installWebviewStyles("agent-session", agentSessionStyles);
  installWebviewStyles("gui-mode", guiModeStyles);
  applyCodexDocumentMetadata();
  document.documentElement.dataset.cmuxWebviewKind = "gui-mode";
  document.body.dataset.cmuxWebviewKind = "gui-mode";
  const router = createWebviewsRouter(() => <GuiModeApp />);
  createRoot(rootElement).render(<RouterProvider router={router} />);
}
