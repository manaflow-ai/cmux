import React from "react";
import { createRoot } from "react-dom/client";
import { AcpmuxApp } from "./App";

document.documentElement.dataset.cmuxWebviewKind = "acpmux-agent-session";
createRoot(document.getElementById("root")!).render(<AcpmuxApp />);
