import React from "react";
import { createRoot } from "react-dom/client";
import { applyAgentDocumentMetadata } from "../shared/theme";
import { AgentSessionApp } from "./main";

const root = document.getElementById("root");
if (root) {
  applyAgentDocumentMetadata();
  createRoot(root).render(React.createElement(AgentSessionApp));
}
