import "../shared/styles.css";
import "../acpmux/styles.css";
import "../acpmux/changes/changes.css";
import "../acpmux/summary/summary.css";
import "../acpmux/header/header.css";
import "../acpmux/keys.css";
import "./styles.css";
import { mountPreview } from "./PreviewApp";
import paneStrings from "../acpmux/generated/strings.json";

// Strings the shipped pane loads from locales/<code>.js (acpmux/i18n.ts); this page installs them all.
globalThis.__cmuxPaneStrings ??= paneStrings;

document.documentElement.lang = "en";
document.documentElement.dataset.cmuxWebviewKind = "acpmux-agent-session-preview";
mountPreview();
