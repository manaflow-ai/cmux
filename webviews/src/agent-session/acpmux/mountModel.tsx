// The pane's stylesheets (mount.tsx) load first, before any module that reads them.
import "./mount";
import { createRoot } from "react-dom/client";
import { AcpmuxApp, type InitialChat } from "./App";
import { PaneBoundary } from "./PaneBoundary";
import { AcpmuxDirectClient, nextFrame } from "./direct";
import { UiProvider } from "../../ui/UiProvider";
import { nativePopupHost } from "../../ui/popupHost";
import { installNativeMenu } from "../../ui/nativeMenu";
import { postNative } from "./native";
import { pageHostFlickerSend, startFlickerLog } from "./flickerLog";
import { pageHostClient } from "./pageHost";
import { appPopupHost } from "../../pages/shared/pagePopupHost";
import { installMessageMenuReporter } from "./conversation/messageMenu";
import { installDragOut } from "./conversation/dragOut";
import { installPageKey } from "./pageKey";
import { installRevealSettle } from "../shared/pageReveal";
import { setHarnessSymbolHost } from "../shared/harnessIcons";
import { experimentArm } from "../../experiments/experiment";
import { liveBackground } from "../../ui/liveBackground/liveBackground.experiment";
import { reportHostGlass } from "../../ui/glass/hostGlass";
import { chatUnderHoverCard, hostGlassCover } from "./chatUnderGlass";
import { installUiPointer, type UiPointerControl } from "./uiPointer/picker";
import { reportChatSnapshot } from "./chatSnapshot/live";

// The chat's snapshot drew in the document's first frame (chatSnapshot/boot.ts): the host shows the
// page now, before the handshake, instead of keeping its loading state until the rows are read.
reportChatSnapshot(postNative);

// Inspect Element's page side (uiPointer/picker.ts), driven by the native own-window picker. Its
// report goes on the normal host protocol so the shared page host and the legacy WKWebView use the
// same validation.
(globalThis as typeof globalThis & { __cmuxUiPointer?: UiPointerControl }).__cmuxUiPointer = installUiPointer(
  document,
  {
    post: (report) => void postNative("uiPointer.report", report),
    // Esc that reached the page: the native picker stops too (UIInspectorController.pageReport).
    cancel: () => void postNative("uiPointer.report", { cancelled: true }),
  },
);

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
export function mountAcpmux(initialChat?: InitialChat): void {
  const root = document.getElementById("root")!;
  // A menu with no room in the pane goes past the window's edge through the native host (cx-6k6cg):
  // the shared page host's popup ops, else the legacy bridge's.
  const popupHost =
    appPopupHost(pageHostClient()) ??
    (window.webkit?.messageHandlers?.agentSession ? nativePopupHost(postNative) : null);
  // Right-click menus are the app's native menus (ui/nativeMenu.ts): the shared page host installs
  // its call with the page client; the legacy bridge answers `contextMenu.show`.
  if (!pageHostClient() && window.webkit?.messageHandlers?.agentSession)
    installNativeMenu((request) => postNative("contextMenu.show", { ...request }));
  // Floating glass the page marks (data-host-glass: Session Info first) is the App's own glass under
  // the page, as its native menus are (ui/glass/hostGlass.ts).
  if (pageHostClient() || window.webkit?.messageHandlers?.agentSession)
    reportHostGlass(document, (surfaces) => postNative("pane.glass", { surfaces }), {
      candidates: chatUnderHoverCard,
      options: hostGlassCover,
    });
  // The always-on flicker detector (flickerLog.ts): on the shared page host its batches are the
  // `diag.flicker` op, on the old host the pane's own WebKit handler takes them.
  startFlickerLog(window, pageHostClient() ? pageHostFlickerSend() : undefined);
  createRoot(root).render(
    <UiProvider container={root} popupHost={popupHost}>
      <PaneBoundary onRetry={() => window.location.reload()}>
        <AcpmuxApp initialChat={initialChat} />
      </PaneBoundary>
    </UiProvider>,
  );
}
