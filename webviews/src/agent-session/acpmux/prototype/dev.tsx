// Sidebar prototype entry (prototype.html), dev server only; the shipped pane never imports it.
import "../../shared/styles.css";
import "../styles.css";
import "../conversation/conversation.css";
import "./prototype.css";
import { createRoot } from "react-dom/client";
import { WorkspaceShell } from "./WorkspaceShell";

createRoot(document.getElementById("root")!).render(<WorkspaceShell />);
