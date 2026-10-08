// Sidebar prototype entry (prototype.html), dev server only; the shipped pane never imports it.
import "../../shared/styles.css";
import "../styles.css";
import "../conversation/conversation.css";
import "./prototype.css";
import paneStrings from "../generated/strings.json";

// Strings the shipped pane loads from locales/<code>.js (acpmux/i18n.ts); this page installs them all.
globalThis.__cmuxPaneStrings ??= paneStrings;
import { createRoot } from "react-dom/client";
import { WorkspaceShell } from "./WorkspaceShell";

createRoot(document.getElementById("root")!).render(<WorkspaceShell />);
