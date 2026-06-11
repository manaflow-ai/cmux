import React from "react";
import { createRoot } from "react-dom/client";
import { applyCodexDocumentMetadata } from "../shared/theme";
import { AgentSessionApp } from "./main";

const root = document.getElementById("root");
if (root) {
  applyCodexDocumentMetadata();
  createRoot(root).render(React.createElement(AgentSessionApp));
}
