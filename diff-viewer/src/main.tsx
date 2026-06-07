import { createRoot } from "react-dom/client";
import { App } from "./App";
import { applyDiffViewerAppearance, resolveDiffViewerAppearance } from "./appearance";
import { createDiffViewerLabelResolver, shouldAssertMissingLabels } from "./labels";
import { applyDiffViewerStatusToDocument, initialDiffViewerStatus } from "./status";
import styles from "./styles.css?inline";
import type { DiffViewerConfig } from "./types";

function readConfig(): DiffViewerConfig {
  const element = document.getElementById("cmux-diff-viewer-config");
  if (!element?.textContent) {
    throw new Error("Missing cmux diff viewer config");
  }
  return JSON.parse(element.textContent);
}

function installStyles() {
  const style = document.createElement("style");
  style.dataset.cmuxDiffViewerStyle = "true";
  style.textContent = styles;
  document.head.append(style);
}

const config = readConfig();
installStyles();
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

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Missing cmux diff viewer root");
}

createRoot(rootElement).render(<App config={config} initialStatus={initialStatus} />);
