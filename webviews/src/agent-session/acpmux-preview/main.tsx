import "../shared/styles.css";
import "../acpmux/styles.css";
import "../acpmux/changes/changes.css";
import "../acpmux/keys.css";
import "./styles.css";
import { mountPreview } from "./PreviewApp";

document.documentElement.lang = "en";
document.documentElement.dataset.cmuxWebviewKind = "acpmux-agent-session-preview";
mountPreview();
