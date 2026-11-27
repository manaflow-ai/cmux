// The agent pane on the shared page host (`cmux-page://cmux.agent/`, CmuxNextAgentPane
// AgentPageProvider): the old `agentSession` methods become `cmux.agent.*` pane-protocol calls, and
// the scripts the old host evaluated become events of the stream `cmux.agent.host.events`.
import { setVoiceState } from "./voice";
import { deliverHandoffFailure } from "./dictation";
import type { PageClient } from "../../pages/shared/pageClient";
import { receiveTransportEvent, type TransportEvent } from "./bridgeSocket";
import { receiveModelCatalog } from "./modelCatalogHost";
import { setEditedFilesSettings } from "./turnChanges/settings";
import { setComposerSettings } from "./composerSettings";
import { setAgentDiffColors } from "./diffColors";
import { setChatDisplay } from "./chatDisplay";
import { setDeviceChats } from "./newtab/deviceChats";
import { setToolCards } from "./toolCards/toolCardStore";
import { setPlanScopeDrift } from "./planScopeDriftStore";
import { setRecentlyClosed } from "./newtab/recentlyClosed";
import { setNowPlaying } from "./newtab/nowPlaying";
import { setReadAloudState } from "./conversation/readAloud";
import { setAttentionTabs } from "./needsYou/attentionTabs";
import { setLinkPlaces, updateLinkPlaces } from "./chips/cmuxLinkPlaces";
import { setHeaderState } from "./header/headerState";
import { setTabRow } from "./header/tabRow";
import { receiveNativeRowToolInvocation } from "./header/nativeRowTools";
import { setFloatingState } from "./floatingState";
import { configureNativeSidebarPreviewVariant } from "./sidebarPreview";
import { setExperimentSwitches } from "../../experiments/switches";
import { receivePromptUploadState } from "./promptUploadState";
import { setComputerUsePreview } from "./computerUse/computerUsePreview";
import { setComputerUseState } from "./computerUse/computerUseState";
import { setMachineLink } from "./machineLink";
import { setRemoteControl } from "./remoteControl";
import { setPaneNotices } from "./paneNoticeStore";
import { runNativeSessionInfoAction, setNativeSessionInfoHost } from "./session-info/native/host";
import { addCloudPreviewPort, seedCloudPreviewPorts } from "./cloudPreviewPorts";
import { noteChatTheme, SNAPSHOT_WRITE_EVENT } from "./chatSnapshot/live";

import { scopedPageClient } from "./paneView";
import { bridgeFor } from "./pane/viewBridges";

export { agentPageOp, callPageHost, pageHostClient, resetPageHostClientForTests } from "./pageHostClient";

export const HOST_EVENTS = "cmux.agent.host.events";
/// NewTabPage's FOCUS_LOCATION_EVENT, kept here so the transport does not load the new tab page.
export const FOCUS_LOCATION = "acpmux-focus-location";

export type HostEvent = { kind: string; value?: unknown };

/// The host events that belong to one chat, not the document (goal memory-per-chat, paneView.ts):
/// in a shared pane document each view subscribes with its `view` filter and these land in that
/// view's store (paneViewStore.ts), so two chats never draw each other's header, row or cards. Every
/// other kind is the app's (theme, settings, catalogs) and applies to the whole document. Not yet
/// per view, so still the document's: transport, uploads, Session Info and the Cloud preview ports.
/// The chat's bridge commands go to its view's bridge (viewBridges.ts).
export const VIEW_EVENT_KINDS: ReadonlySet<string> = new Set([
  "command",
  "stopTurn",
  "sideQuestion",
  "revealTurn",
  "dictation",
  "designSelection",
  "cloudStartProgress",
  "headerState",
  "tabRow",
  "floatingState",
  "paneNotices",
  "toolCards",
  "computerUsePreview",
]);

/// Runs one host event in the page: the same `cmuxAcpmuxBridge` function the old host's script ran.
/// The user's registry.js is not an event: the host evaluates it, since the page's CSP
/// (script-src 'self') refuses a script element the page makes. `view` is the pane view whose
/// subscription brought it (null: the page's own); only VIEW_EVENT_KINDS read it.
export function applyHostEvent(event: HostEvent, view: string | null = null): void {
  const bridge = window.cmuxAcpmuxBridge;
  // The chat's own bridge: its view's in a shared document, the document's on a page of its own.
  const chat = bridgeFor(view);
  const value = event.value as never;
  switch (event.kind) {
    case "imessage.changed":
      window.dispatchEvent(new Event("cmux-imessage-changed"));
      return;
    case "projectPalette":
      window.dispatchEvent(new CustomEvent("cmux-project-palette", { detail: event.value }));
      return;
    case "github.changed":
      window.dispatchEvent(new Event("cmux-github-changed"));
      return;
    case "sessionInfoHost":
      return setNativeSessionInfoHost(event.value);
    case "sessionInfoAction":
      return runNativeSessionInfoAction(event.value);
    case "uploads.state":
      return receivePromptUploadState(event.value);
    case "theme": {
      const theme = event.value as { web?: unknown; agent?: Record<string, unknown>; key?: unknown };
      noteChatTheme(theme.key);
      (window as { cmuxTheme?: { apply(payload: unknown): void } }).cmuxTheme?.apply(theme.web);
      if (theme.agent) bridge?.applyTheme(theme.agent);
      return;
    }
    case "shortcuts":
      return bridge?.applyShortcuts?.(value);
    case "preview":
      return bridge?.applyPreview?.(event.value === true);
    case "liveTree":
      return bridge?.applyLiveTree?.(event.value === true);
    case "workflowLabs":
      // Separate from the existing preview environment toggle. The host can opt the
      // experimental workflow summary in without changing preview semantics.
      return bridge?.applyWorkflowLabs?.(event.value === true);
    case "sidebarPreviewVariant":
      return configureNativeSidebarPreviewVariant(event.value);
    case "experiments":
      // Direct: a push before a component mounts is kept.
      return setExperimentSwitches(event.value);
    case "machineLink":
      return setMachineLink(event.value);
    case "paneNotices":
      // Direct, like remoteControl: a push before the composer mounts is kept.
      return setPaneNotices(event.value, view);
    case "remoteControl":
      // Direct, like machineLink: a push before Session Info mounts is kept.
      return setRemoteControl(event.value);
    case "editedFiles":
      // Direct, not through window.cmuxAcpmuxEditedFiles: an event that arrives before the card
      // module loads still sets the value the card then reads.
      return setEditedFilesSettings(event.value);
    case "composer":
      return setComposerSettings(event.value);
    case "diffColors":
      return setAgentDiffColors(event.value);
    case "display":
      // Direct, like composer: a push before the chat mounts is kept (chatDisplay.ts).
      return setChatDisplay(event.value);
    case "deviceChats":
      // Direct, like editedFiles: a push before the New Tab screen mounts is kept.
      return setDeviceChats(event.value);
    case "recentlyClosed":
      return setRecentlyClosed(event.value);
    case "nowPlaying":
      // Direct, like recentlyClosed: a push before the New Tab screen mounts is kept.
      return setNowPlaying(event.value);
    case "voice":
      return setVoiceState(event.value);
    case "readAloud":
      // The app's voice (conversation/readAloud.ts): which message it reads, on every change.
      return setReadAloudState(event.value);
    case "attentionTabs":
      // Keep a push that arrives before the Needs you header mounts.
      return setAttentionTabs(event.value);
    case "linkPlaces":
      // The workspaces and tabs a pasted cmux link can name (chips/cmuxLinkPlaces.ts), kept before
      // the transcript mounts.
      return setLinkPlaces(event.value);
    case "linkPlacesChanged":
      // Only the places renamed since the last push (an agent's title spinner), applied in place.
      return updateLinkPlaces(event.value);
    case "toolCards":
      // Direct, like deviceChats: a push before the chat mounts is kept.
      return setToolCards(event.value, view);
    case "planScopeDrift":
      // Direct, like toolCards: a push before the composer mounts is kept.
      return setPlanScopeDrift(event.value);
    case "computerUsePreview":
      // Direct, like toolCards: a push before the chat mounts is kept.
      return setComputerUsePreview(event.value, view);
    case "computerUseState":
      // Computer Use on this Mac, for a send that names `@computer-use` (computerUse/computerUseState.ts).
      return setComputerUseState(event.value);
    case "customization":
      return bridge?.applyCustomization(value);
    case "headerState":
      return setHeaderState(event.value, view);
    case "tabRowToolInvoked":
      return receiveNativeRowToolInvocation(event.value);
    case "tabRow":
      return setTabRow(event.value, view);
    case "floatingState":
      return setFloatingState(event.value, view);
    case "dictation":
      return chat?.dictation?.(value);
    case "dictationHandoff":
      return deliverHandoffFailure(event.value);
    case "designSelection":
      return chat?.designSelection?.(value);
    case "cloudStartProgress":
      // How a Cloud start goes (cloudStartProgress.ts): the page checks every field.
      return chat?.cloudStartProgress?.(event.value);
    case "revealTurn":
      return chat?.revealTurn?.(String(event.value));
    case "command":
      return chat?.command?.(String(event.value));
    case "stopTurn":
      return chat?.command?.("stopTurn", String(event.value));
    case "sideQuestion":
      return chat?.command?.("sideQuestion", String(event.value));
    case "focusLocation":
      window.dispatchEvent(new Event(FOCUS_LOCATION));
      return;
    case "chatSnapshot.write":
      // The tab hides: the chat's drawn copy is written now, before a hidden page freezes.
      window.dispatchEvent(new Event(SNAPSHOT_WRITE_EVENT));
      return;
    case "transport":
      return receiveTransportEvent(event.value as TransportEvent);
    case "models.catalog":
      return receiveModelCatalog(event.value);
    case "cloudPreviewPort":
      return void addCloudPreviewPort(event.value);
    case "cloudPreviewPortsKnown": {
      const value = event.value;
      const ports =
        value && typeof value === "object" && Array.isArray((value as { ports?: unknown }).ports)
          ? (value as { ports: unknown[] }).ports
          : Array.isArray(value)
            ? value
            : [];
      return seedCloudPreviewPorts(ports);
    }
  }
}

const subscribed = new WeakMap<PageClient, Map<string | null, Promise<void>>>();

/// Subscribes to host events once per client and view, after the page installed `cmuxAcpmuxBridge`.
/// A view's subscription carries its `view` filter (scopedPageClient), so the host sends it that
/// chat's events; the page's own (null view) is today's one subscription a page.
export async function startHostEvents(page: PageClient, view: string | null = null): Promise<void> {
  let byView = subscribed.get(page);
  if (!byView) {
    byView = new Map();
    subscribed.set(page, byView);
  }
  let ready = byView.get(view);
  if (!ready) {
    const views = byView;
    ready = scopedPageClient(page, view)
      .subscribe<HostEvent>(HOST_EVENTS, (event) => applyHostEvent(event, view))
      .then(
        () => undefined,
        (error) => {
          views.delete(view);
          throw error;
        },
      );
    byView.set(view, ready);
  }
  await ready;
}
