import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "../agent-chat/App";
import agentChatStyles from "../agent-chat/app.css?inline";
import { GalleryApp } from "../agent-chat/gallery";
import { installWebviewStyles } from "./installWebviewStyles";

export function mountAgentChatSurface(rootElement: HTMLElement): void {
  installWebviewStyles("agent-chat", agentChatStyles);
  const content = location.pathname.endsWith("/gallery") ? <GalleryApp /> : <App />;
  createRoot(rootElement).render(<StrictMode>{content}</StrictMode>);
}
