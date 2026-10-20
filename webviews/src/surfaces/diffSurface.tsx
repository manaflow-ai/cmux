import { RouterProvider } from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { App } from "../App";
import { applyDiffViewerAppearance, resolveDiffViewerAppearance } from "../appearance";
import { createDiffViewerLabelResolver, shouldAssertMissingLabels } from "../labels";
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
  const router = createWebviewsRouter(() => (
    <App config={config} initialStatus={initialStatus} />
  ));
  createRoot(rootElement).render(<RouterProvider router={router} />);
}
