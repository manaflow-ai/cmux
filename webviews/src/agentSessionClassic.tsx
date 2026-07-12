import { mountAgentSessionSurface } from "./surfaces/agentSessionSurface";

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Missing cmux webview root");
}

mountAgentSessionSurface(rootElement);
