import "./diagStart";
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../../pages/shared/desktop";
import React from "react";
import { createRoot } from "react-dom/client";
import { AcpmuxApp } from "./App";
import { PaneBoundary } from "./PaneBoundary";
import { AcpmuxDirectClient, nextFrame } from "./direct";
import { UiProvider } from "../../ui/UiProvider";
import { installMessageMenuReporter } from "./conversation/messageMenu";
import { useLayoutEffect } from "react";
((globalThis as any).__cmuxT ??= {}).mainBody = performance.now(); // diag (to drop)
function FirstCommit() {
  useLayoutEffect(() => { ((globalThis as any).__cmuxT ??= {}).commit1 ??= performance.now(); }, []);
  return null;
}

// One transcript snapshot per display frame, however many deltas land in it.
AcpmuxDirectClient.scheduleFrame = nextFrame;
document.documentElement.dataset.cmuxWebviewKind = "acpmux-agent-session";
// The native context menu learns which message is under the pointer (conversation/messageMenu.ts).
installMessageMenuReporter(document);
const root = document.getElementById("root")!;
createRoot(root).render(
  <UiProvider container={root}>
    <FirstCommit />
    <PaneBoundary>
      <AcpmuxApp />
    </PaneBoundary>
  </UiProvider>,
);
((globalThis as any).__cmuxT ??= {}).mainEnd = performance.now(); // diag (to drop)
