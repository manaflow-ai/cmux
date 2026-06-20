import { RouterProvider } from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { applyDiffViewerAppearance, resolveDiffViewerAppearance } from "../appearance";
import { OpenChatApp, type OpenChatConfig } from "../open-chat/OpenChatApp";
import openChatStyles from "../open-chat/styles.css?inline";
import { applyCodexDocumentMetadata } from "../agent-session/shared/theme";
import agentSessionStyles from "../agent-session/shared/styles.css?inline";
import { createWebviewsRouter } from "../router";
import { installWebviewStyles } from "./installWebviewStyles";

function readConfig(): OpenChatConfig {
  const element = document.getElementById("cmux-open-chat-config");
  if (!element?.textContent) {
    throw new Error("Missing cmux open chat config");
  }
  return JSON.parse(element.textContent) as OpenChatConfig;
}

/**
 * Boots the Open Chat composer surface: reads its generated config, applies the
 * cmux/diff-viewer appearance tokens used by internal browser surfaces, then
 * renders the Codex-style composer through the shared webview router.
 */
export function mountOpenChatSurface(rootElement: HTMLElement): void {
  const config = readConfig();
  installWebviewStyles("agent-session", agentSessionStyles);
  installWebviewStyles("open-chat", openChatStyles);
  applyCodexDocumentMetadata();
  applyDiffViewerAppearance(resolveDiffViewerAppearance(config.payload.appearance));
  document.documentElement.dataset.cmuxWebviewKind = "open-chat";
  document.body.dataset.cmuxWebviewKind = "open-chat";
  const router = createWebviewsRouter(() => <OpenChatApp config={config} />);
  createRoot(rootElement).render(<RouterProvider router={router} />);
}
