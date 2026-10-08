import { RouterProvider } from "@tanstack/react-router";
import { createRoot } from "react-dom/client";
import { App } from "../App";
import { applyDiffViewerAppearance, resolveDiffViewerAppearance } from "../appearance";
import { installSolidBackdrop } from "../backdrop";
import { createDiffViewerLabelResolver, loadDiffViewerLabels, shouldAssertMissingLabels } from "../labels";
import { installDiffLanguageHostAPI } from "../diff-languages/host";
import { diffPageClient } from "../diff/page";
import { bootPageDiff } from "../diff/pageBoot";
import { createWebviewsRouter } from "../router";
import { applyDiffViewerStatusToDocument, initialDiffViewerStatus } from "../status";
import diffViewerStyles from "../styles.css?inline";
import type { DiffViewerConfig } from "../types";
import { installWebviewStyles } from "./installWebviewStyles";

/** The config the classic host (and the dev server) embeds in the page, or null. */
function readEmbeddedConfig(): DiffViewerConfig | null {
  const element = document.getElementById("cmux-diff-viewer-config");
  if (!element?.textContent) {
    return null;
  }
  return JSON.parse(element.textContent);
}

/**
 * Boots the diff viewer surface: reads its config, applies appearance/labels/
 * status, then renders the diff `App` through the shared router. Loaded as its
 * own chunk so the agent session surface never ships `@pierre/diffs`.
 *
 * The classic host and the dev server embed the config, and the viewer renders at once. On the
 * shared page host (no embedded config) the viewer asks `cmux.diff.config` and renders when it
 * answers; the returned promise settles then.
 */
export function mountDiffSurface(rootElement: HTMLElement): Promise<void> {
  const embedded = readEmbeddedConfig();
  if (embedded) {
    return renderDiffSurface(rootElement, embedded, embedded.payload?.languages);
  }
  const page = diffPageClient();
  if (!page) {
    throw new Error("Missing cmux diff viewer config");
  }
  return bootPageDiff(
    page,
    (config, languages) => renderDiffSurface(rootElement, config, languages),
    undefined,
    undefined,
    async (config) => {
      // The empty state paints with the viewer's look until the user opens a repository. It loads
      // on demand (with the ui wrapper and Base UI), so an open repository never evaluates it.
      installWebviewStyles("diff", diffViewerStyles);
      const empty = await import("../viewer-empty/emptySurface");
      installWebviewStyles("viewer-empty", empty.viewerEmptyStyles);
      installWebviewStyles("ui", empty.uiStyles);
      applyDiffViewerAppearance(resolveDiffViewerAppearance(config.payload?.appearance));
      installSolidBackdrop();
      return empty.pickDiffConfig(rootElement, page, { labels: config.payload?.labels });
    },
  ).then(() => undefined);
}

/** Applies the config's appearance, labels and status, then renders the viewer. */
export async function renderDiffSurface(
  rootElement: HTMLElement,
  config: DiffViewerConfig,
  languages: unknown,
): Promise<void> {
  await loadDiffViewerLabels();
  installWebviewStyles("diff", diffViewerStyles);
  installDiffLanguageHostAPI(languages);
  applyDiffViewerAppearance(resolveDiffViewerAppearance(config.payload?.appearance));
  installSolidBackdrop();
  if (typeof config.payload?.title === "string" && config.payload.title.trim() !== "") {
    document.title = config.payload.title;
  }
  const label = createDiffViewerLabelResolver(config.payload?.labels, {
    assertMissing: shouldAssertMissingLabels(),
  });
  const initialStatus = initialDiffViewerStatus(config, label);
  document.body.dataset.filesHidden = "false";
  applyDiffViewerStatusToDocument(initialStatus);
  const router = createWebviewsRouter(() => <App config={config} initialStatus={initialStatus} />);
  createRoot(rootElement).render(<RouterProvider router={router} />);
}
