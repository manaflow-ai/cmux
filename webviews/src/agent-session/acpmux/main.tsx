// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../../pages/shared/desktop";
import React from "react";
import { createRoot } from "react-dom/client";
import { AcpmuxApp } from "./App";
import { PaneBoundary } from "./PaneBoundary";
import { AcpmuxDirectClient, nextFrame } from "./direct";
import { UiProvider } from "../../ui/UiProvider";

// One transcript snapshot per display frame, however many deltas land in it.
AcpmuxDirectClient.scheduleFrame = nextFrame;
document.documentElement.dataset.cmuxWebviewKind = "acpmux-agent-session";
const root = document.getElementById("root")!;
createRoot(root).render(
  <UiProvider container={root}>
    <PaneBoundary>
      <AcpmuxApp />
    </PaneBoundary>
  </UiProvider>,
);
