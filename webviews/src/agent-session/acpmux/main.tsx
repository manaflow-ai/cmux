// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../../pages/shared/desktop";
// The shared icon+label button (cx-s6zvc); the pane does not load the rest of ui.css.
import "../../ui/ghost.css";
import "./composerFooterShared.css";
import "./diffTokens.css";
import "./styles.css";
import React from "react";
import { createRoot } from "react-dom/client";
import { AcpmuxApp } from "./App";
import { PaneBoundary } from "./PaneBoundary";
import { AcpmuxDirectClient, nextFrame } from "./direct";
import { UiProvider } from "../../ui/UiProvider";
import { nativePopupHost } from "../../ui/popupHost";
import { installNativeMenu } from "../../ui/nativeMenu";
import { postNative } from "./native";
import { pageHostClient } from "./pageHost";
import { appPopupHost } from "../../pages/shared/pagePopupHost";
import { installMessageMenuReporter } from "./conversation/messageMenu";
import { installDragOut } from "./conversation/dragOut";
import { installPageKey } from "./pageKey";
import { installRevealSettle } from "../shared/pageReveal";
import { setHarnessSymbolHost } from "../shared/harnessIcons";
import { experimentArm } from "../../experiments/experiment";
import { liveBackground } from "../../ui/liveBackground/liveBackground.experiment";

// The native own-window picker runs in the page's inspector runtime. Keep its report on the
// normal host protocol so the shared page host and the legacy WKWebView use the same validation.
(
  globalThis as typeof globalThis & { __cmuxUiPointerPost?: (params: Record<string, unknown>) => void }
).__cmuxUiPointerPost = (params) => {
  void postNative("uiPointer.report", params);
};

// One transcript snapshot per display frame, however many deltas land in it.
AcpmuxDirectClient.scheduleFrame = nextFrame;
document.documentElement.dataset.cmuxWebviewKind = "acpmux-agent-session";
// The native context menu learns which message is under the pointer (conversation/messageMenu.ts).
installMessageMenuReporter(document);
// Images and file chips drag out as real files, through the host (conversation/dragOut.ts).
installDragOut(document);
// LIVE BACKGROUND (experiment live-background, off by default): a slow shader behind the pane.
{
  const arm = experimentArm(liveBackground);
  if (arm !== "off")
    void import("../../ui/liveBackground/liveBackground").then(({ installLiveBackground }) =>
      installLiveBackground(document, arm),
    );
}
// The composer shows its caret only while the page is the key one (pageKey.ts).
installPageKey(document);
// A switch away and back is a reattach: nothing started while hidden plays on return, and a change
// that lands before the first frame back starts no entrance (shared/pageReveal.ts).
installRevealSettle(document);
// A custom harness's SF Symbol icon: the host draws it (`harness.symbol`, AgentPaneModel).
setHarnessSymbolHost((name) =>
  postNative<{ src?: unknown }>("harness.symbol", { name }).then((reply) =>
    typeof reply?.src === "string" ? reply.src : null,
  ),
);
const root = document.getElementById("root")!;
// A menu with no room in the pane goes past the window's edge through the native host (cx-6k6cg):
// the shared page host's popup ops, else the legacy bridge's.
const popupHost =
  appPopupHost(pageHostClient()) ?? (window.webkit?.messageHandlers?.agentSession ? nativePopupHost(postNative) : null);
// Right-click menus are the app's native menus (ui/nativeMenu.ts): the shared page host installs
// its call with the page client; the legacy bridge answers `contextMenu.show`.
if (!pageHostClient() && window.webkit?.messageHandlers?.agentSession)
  installNativeMenu((request) => postNative("contextMenu.show", { ...request }));
createRoot(root).render(
  <UiProvider container={root} popupHost={popupHost}>
    <PaneBoundary onRetry={() => window.location.reload()}>
      <AcpmuxApp />
    </PaneBoundary>
  </UiProvider>,
);
