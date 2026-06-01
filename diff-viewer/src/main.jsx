import { createRoot } from "react-dom/client";
import { App } from "./App.jsx";
import styles from "./styles.css?inline";

function readConfig() {
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
document.title = config.payload?.title ?? document.title;
document.body.dataset.filesHidden = "false";
document.body.dataset.statusOnly = config.payload?.statusMessage || config.payload?.pendingReplacement ? "true" : "false";

createRoot(document.getElementById("root")).render(<App config={config} />);
