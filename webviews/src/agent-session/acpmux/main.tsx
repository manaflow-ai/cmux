// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../../pages/shared/desktop";
import React from "react";
import { createRoot } from "react-dom/client";
import { AcpmuxApp } from "./App";
import { AcpmuxDirectClient, nextFrame } from "./direct";

// One transcript snapshot per display frame, however many deltas land in it.
AcpmuxDirectClient.scheduleFrame = nextFrame;
document.documentElement.dataset.cmuxWebviewKind = "acpmux-agent-session";
createRoot(document.getElementById("root")!).render(<AcpmuxApp />);
