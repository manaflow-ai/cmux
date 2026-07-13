import { RouterProvider } from "@tanstack/react-router";
import { Component, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "../App";
import { applyDiffViewerAppearance, resolveDiffViewerAppearance } from "../appearance";
import { createDiffViewerLabelResolver, shouldAssertMissingLabels } from "../labels";
import { mobileDiffErrorMessage, postMobileDiffMessage } from "../mobile-diff";
import { createWebviewsRouter } from "../router";
import { applyDiffViewerStatusToDocument, initialDiffViewerStatus } from "../status";
import diffViewerStyles from "../styles.css?inline";
import type { DiffViewerConfig } from "../types";
import { installWebviewStyles } from "./installWebviewStyles";

function readConfig(): DiffViewerConfig {
  const element = document.getElementById("cmux-diff-viewer-config");
  if (!element?.textContent) {
    throw new Error("Missing cmux diff viewer config");
  }
  return JSON.parse(element.textContent);
}

/**
 * Boots the diff viewer surface: reads its config, applies appearance/labels/
 * status, then renders the diff `App` through the shared router. Loaded as its
 * own chunk so the agent session surface never ships `@pierre/diffs`.
 */
export function mountDiffSurface(rootElement: HTMLElement): void {
  const config = readConfig();
  if (config.payload?.mobileHost === true) {
    document.body.dataset.mobileHost = "true";
  } else {
    delete document.body.dataset.mobileHost;
  }
  installWebviewStyles("diff", diffViewerStyles);
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
  const app = <App config={config} initialStatus={initialStatus} />;
  const router = createWebviewsRouter(() => config.payload?.mobileHost === true ? (
    <MobileDiffRenderErrorBoundary fallbackMessage={label("renderFailed")}>
      {app}
    </MobileDiffRenderErrorBoundary>
  ) : app);
  createRoot(rootElement).render(<RouterProvider router={router} />);
}

class MobileDiffRenderErrorBoundary extends Component<{
  children: ReactNode;
  fallbackMessage: string;
}, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError(): { failed: boolean } {
    return { failed: true };
  }

  componentDidCatch(error: unknown): void {
    postMobileDiffMessage({
      type: "error",
      message: mobileDiffErrorMessage(error, this.props.fallbackMessage),
    });
  }

  render(): ReactNode {
    return this.state.failed ? null : this.props.children;
  }
}
