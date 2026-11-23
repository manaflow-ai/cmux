import { startDevMotionAudit } from "../devMotionAudit";
import { openFork, openInOwnTab } from "../conversation/openFork";
import React from "react";
import { restoreForkSource } from "../handoff/restoreForkSource";
import type { QueryClient } from "@tanstack/react-query";
import type { AcpmuxRow, AcpmuxSnapshot, QueueEdit } from "../model";
import {
  AcpmuxDirectClient,
  type AcpmuxHostConfig,
  type CarriedChat,
  harnessBlock,
  type HarnessBlock,
  isTrustRefusal,
} from "../direct";
import { readHostTail } from "../tailCache";
import { failedRowOf, failedRowTrustRetry } from "../failedRowTrustRetry";
import { postNative } from "../native";
import { resendToastAvoidance } from "../toastAvoidance";
import { NativeError } from "../nativeError";
import { errorMessage, isStartCancelled, knownRefusalText, startCancelled } from "../transportErrors";
import { pageHostClient, startHostEvents } from "../pageHost";
import { newTabHost, type NewTabHost } from "../newTabModel";
import { setDeviceChats } from "../newtab/deviceChats";
import { setRecentlyClosed } from "../newtab/recentlyClosed";
import { setNowPlaying } from "../newtab/nowPlaying";
import { setAttentionTabs } from "../needsYou/attentionTabs";
import { openHarnessesPage } from "../harnesses/harnessesPage";
import { type useEarlyNewTabContext, type useLostSharedPart, withHandshakeNewTab } from "../newtab/adoption";
import { markMockPage, publishSessions } from "../newtab/chatStore";
import type { CloudStartPick } from "../newtab/draftFolder";
import { configurationSessionMatches, pickEffort } from "../configurationActions";
import { rememberRecentFolders } from "../newtab/recentProject";
import { publishWarmNewTab } from "../newtab/warmSnapshot";
import { drawPaneSnapshot, type PendingPaneDraw } from "../paneSnapshotLane";
import { setBookmarkTransport } from "../threadMinimap/bookmarks";
import {
  composerDraft,
  DRAFT_SETTLE_MS,
  notifyDraftActionsChanged,
  settleDraftWithin,
  writePersistedDraft,
} from "../composerDraft";
import { paneContext } from "../paneContext";
import { followHarnessChanges, type HarnessCatalogSource, type useHarnessCatalog } from "../catalog";
import { reloadModelCatalog } from "../modelCatalogHost";
import { type HarnessSwitch, lastOfferedModel, type SwitchPort, type SwitchView } from "../harnessSwitch";
import type { NewChatPrewarm } from "../newChatPrewarm";
import type { CloudTypingPrewarm } from "../cloudTypingPrewarm";
import { harnessProfiles } from "../harnessProfiles";
import { setStartModeSource } from "../startMode";
import { setStartRecoveryPreview } from "../startRecoveryPreview";
import { setPromptSurfaces } from "../surfaces/promptSurface";
import { preparedMockTransport } from "../mockTransport";
import { BridgeSocket } from "../bridgeSocket";
import { createAcpmuxDebug } from "../debug";
import { type AutomationCompose, pageAction } from "../automation";
import { acpWire } from "../wire";
import { chatPerfCapture } from "../chatPerfCapture";
import { acpmuxPerf } from "../perf";
import { perfReporter } from "../perfReporter";
import { frameTally } from "../conversation/frameTally";
import { reconciledProject } from "../newtab/startHint";
import { streamingRow, streamingRowBlocked } from "../streamingRow";
import { liveToolOutput, toolOutputOnly } from "../liveToolOutput";
import type { ComposerHandle, ComposerWake } from "../Composer";
import { composerReadback, takeExternalInto } from "../composer/externalAttach";
import type { FolderContinuation } from "../folderContinuation";
import type { ComposerAttachment } from "../attachments";
import { PICKER_LABELS } from "../composerPickerModel";
import { openComposerControl } from "../composerControls";
import { openPicker } from "../pickerOpeners";
import type { CloudChatIdentity } from "../cloudChatRecovery";
import { type PastTurn, readPastTurns } from "../pastChatModel";
import { uploadForSend } from "../sendUploads";
import { isStartSuperseded, startFailureNotice } from "../startFailure";
import { translate } from "../i18n";
import { cloudMachineAsleep } from "../cloudMachines";
import type { TrustHeldPrompt, useTrustHeldPrompts } from "../trustHeld";
import { routeCurrentTrustRefusal, routeOwnedTrustRefusal, type TrustRefusalOwner } from "../trustRefusalRoute";
import { heldPrompts, type SendGesture } from "../heldPrompt";
import { FILE_SEARCH_LIMIT } from "../fileSearchModel";
import type { useSessionInfo } from "../session-info/useSessionInfo";
import { setRemoteControl } from "../remoteControl";
import type { BackgroundCommand } from "../session-info/processes";
import { setSessionInfoTab } from "../session-info/sessionInfoState";
import type { useSummaryCard } from "../summary/cardState";
import { shouldScrollToBottomAfterSend } from "../sendScrollSetting";
import { configureDictation, deliverDictation } from "../dictation";
import { setReadAloudState } from "../conversation/readAloud";
import { sendPromptAgain, type SendPromptAgainState } from "../conversation/sendPromptAgain";
import { interruptedResumeRunner, type InterruptedResumeState } from "../conversation/resumeInterrupted";
import { sendUntilTaken } from "../conversation/turnRetry";
import { CONTINUE_PROMPT } from "../conversation/turnActions";
import { type ChatMarks, type CloudTurnCheckpoints, handshakeMarks } from "../conversation/cloudTurnCheckpoints";
import type { ChatFind } from "../conversation/chatFind";
import {
  forkRefusal,
  forkToTarget,
  latestForkSeq,
  messageMenuSessionMatches,
  messageMenuTarget,
  openReportedImage,
  setMessageMenuSource,
  withSendPromptAgain,
} from "../conversation/messageMenu";
import { actOnReportedImage } from "../conversation/imageMenuActions";
import { callChipHost } from "../chips/host";
import { forkAnchor } from "../conversation/branches";
import { readShortcuts } from "../shortcuts";
import { FALLBACK_LINK_SCHEME, setLinkScheme } from "../links";
import { lastCodeBlock } from "../conversation/lastCodeBlock";
import { transcriptSelectionAttachment } from "../transcriptSelection";
import { setHeaderState } from "../header/headerState";
import { setTabRow } from "../header/tabRow";
import {
  draftMessage as subagentDraftMessage,
  subagentDraftUnsaved,
  takeUnsavedSubagentDrafts,
  wakeIntoSubagentDrafts,
  wakeSubagentDrafts,
} from "../subagents/subagentDrafts";
import { type CloudStartProgress, cloudStartPushed } from "../cloudStartProgress";
import { configureQuickActions } from "../header/quickActions";
import { configureNativeSidebarPreviewVariant, configureSidebarPreviewVariant } from "../sidebarPreview";
import { handoffTurns } from "../cloudHandoffTurn";
import { agentAvatarChanged } from "../agentAvatar";
import { recordedConversationMarkdown } from "../conversation/exportMarkdown";
import { type PaneFolds, readWakeFolds, wakeFolds } from "../conversation/wakeFolds";
import type { paneNotices } from "../paneToasts";
import {
  type AcpmuxRestartGate,
  hostErrorShows,
  hostIsReconnecting,
  hostRefusedTooLarge,
  jitteredDelay,
  lostRetryDelay,
  nextRetryDelay,
  offersAcpmuxRestart,
  quickRetry,
  troubleSinceAfterLoss,
} from "../hostRetry";
import { heldStartStop, sendsHeldForHost, untilHostAnswers } from "../sendWhenReady";
import type { Subagent } from "../subagents/subagentFold";
import { newChatFolder } from "../startFolderModel";
import { dismissPlanScopeDrift, keepPlanScopeArea } from "../planScopeDriftStore";
import { setPaneNotices } from "../paneNoticeStore";
import type { HandoffReviewInput } from "../handoff/review";
import { CmuxCommandRefused } from "../cmuxCommands";
import { handoffStore, receiveHandedCloudStart } from "../commandPlace";
import { askPermissionFocus } from "../permissions/focusRequest";
import type { PermissionDecision } from "../permissions/protocol";
import { planBuildTarget } from "../permissions/planBuild";
import { type PaneSurface, readSurface } from "../paneSurface";
import { designSelectionChips, designSelectionRemovals } from "../designSelection";
import { setFloatingState } from "../floatingState";
import { type FailedRun, failedSendText } from "../sendFailure";
import type { clientWaiter } from "../lostPrompt";
import { HELD_EFFORT_ID, HELD_FAST_ID, HELD_FAST_ON } from "../heldOptions";
import { setSuggestedTasks } from "../offer/offersShown";
import { offerPicks } from "../offer/offerChoice";
import { offerWorktree } from "../offer/offerWorktree";
import { setLinkPlaces, updateLinkPlaces } from "../chips/cmuxLinkPlaces";
import type { StartedSession } from "../started/startedSessions";
import { setExperimentSwitches } from "../../../experiments/switches";
import { setSessionStatus } from "../sessionStatus";
import { pageEditHold, pageReleaseHold } from "../../../pages/shared/webSwap";
import type { SandboxTab } from "../sandboxRun";
import { callNative } from "../callNative";
import { nativeUnsentPrompts } from "../unsentPrompts";
import { flushHeldModePick } from "../heldModePick";
import type { NativeRegistry, OpenDiff } from "../rows/rowProps";
import type { ScrollAnchor } from "../VirtualTranscript";
import { emptySnapshot, saveSnapshot } from "../snapshotCache";
import { applyPaneTheme, applyPaneThemeCSS } from "../paneTheme";
import { dismissFocusRing } from "../../../ui/focusModality";
import { focusRoute } from "../../../ui/focusRoute";
import { currentRegistry, NEW_TAB_CLOSE_EVENT, streamedOnly } from "../App";
import {
  failedRowIds,
  heldGoesAfterTrust,
  heldPromptParams,
  type HeldSend,
  isStartRefusal,
  refusedMachine,
  sendGestureParam,
  type SentFrom,
} from "./sendHost";
import { fetchScrollAnchor, postScrollAnchor } from "./scrollAnchorHost";
import { readWake } from "./wake";

/** What AcpmuxPane's snapshot effect reads from the pane (App.tsx): its state, setters, refs and callbacks. */
export type PaneSnapshotArgs = {
  scrollToBottomOnSendRef: React.RefObject<boolean>;
  sandbox: SandboxTab;
  setWorkflowLabsEnabled: React.Dispatch<React.SetStateAction<boolean>>;
  setLiveTreeEnabled: React.Dispatch<React.SetStateAction<boolean>>;
  setDraft: React.Dispatch<React.SetStateAction<string | undefined>>;
  setNewSession: React.Dispatch<React.SetStateAction<boolean>>;
  setHandshaken: React.Dispatch<React.SetStateAction<boolean>>;
  handshakenRef: React.RefObject<boolean>;
  reconnectingRef: React.RefObject<boolean>;
  setAwaitsChat: React.Dispatch<React.SetStateAction<boolean>>;
  pendingSubmits: React.RefObject<(() => void)[]>;
  setProjectDraft: React.Dispatch<React.SetStateAction<string | undefined>>;
  startedFromHint: React.RefObject<string | undefined>;
  setChooseFolder: React.Dispatch<React.SetStateAction<boolean>>;
  setFolderNeeded: React.Dispatch<React.SetStateAction<{ reason: string; error?: string } | undefined>>;
  setPastTurns: React.Dispatch<React.SetStateAction<PastTurn[] | undefined>>;
  setPastWaitsForTrust: React.Dispatch<React.SetStateAction<boolean>>;
  setMachineName: React.Dispatch<React.SetStateAction<string | undefined>>;
  setLocalMachineName: React.Dispatch<React.SetStateAction<string | undefined>>;
  setCloudMachineID: React.Dispatch<React.SetStateAction<string | undefined>>;
  cloudMachineIDRef: React.RefObject<string | undefined>;
  setCloudRepositoryAvailable: React.Dispatch<React.SetStateAction<boolean>>;
  setCloudChatIdentity: React.Dispatch<React.SetStateAction<CloudChatIdentity | undefined>>;
  cloudIdentityBound: React.RefObject<boolean>;
  setCloudTurnRewind: (
    update: ChatMarks | undefined | ((marks: ChatMarks | undefined) => ChatMarks | undefined),
  ) => void;
  cloudTurnRewindUnbound: React.RefObject<boolean>;
  cloudCheckpoints: React.RefObject<CloudTurnCheckpoints | undefined>;
  observeCloudTurn: (next: AcpmuxSnapshot) => void;
  setCloudTeamMachine: React.Dispatch<React.SetStateAction<boolean>>;
  setScrollAnchor: React.Dispatch<React.SetStateAction<(ScrollAnchor & { sessionId: string }) | undefined>>;
  setGithubRepository: React.Dispatch<React.SetStateAction<string | undefined>>;
  setSnapshot: React.Dispatch<React.SetStateAction<AcpmuxSnapshot>>;
  harnessSwitch: HarnessSwitch;
  switchViewRef: React.RefObject<SwitchView>;
  newChatPrewarm: NewChatPrewarm;
  cloudTypingPrewarm: CloudTypingPrewarm;
  queryClient: QueryClient;
  catalogClientId: React.RefObject<number>;
  directClient: React.RefObject<AcpmuxDirectClient | undefined>;
  notices: ReturnType<typeof paneNotices>;
  connectedClients: ReturnType<typeof clientWaiter<AcpmuxDirectClient>>;
  setCatalogSource: React.Dispatch<React.SetStateAction<{ id: number; client: HarnessCatalogSource } | undefined>>;
  setBlockedHarness: React.Dispatch<React.SetStateAction<HarnessBlock | undefined>>;
  catalogRef: React.RefObject<ReturnType<typeof useHarnessCatalog>>;
  trustRouteSnapshot: React.RefObject<AcpmuxSnapshot>;
  trustRenderedOwner: React.RefObject<
    { client?: AcpmuxDirectClient; generation?: number; sessionId?: string } | undefined
  >;
  setCheckpointVariant: React.Dispatch<React.SetStateAction<"compact" | "expanded">>;
  showCheckpoint: React.RefObject<() => void>;
  setContinuing: React.Dispatch<React.SetStateAction<boolean>>;
  transcriptInView: React.RefObject<(() => readonly string[] | null) | undefined>;
  revealRef: React.RefObject<(value: string) => undefined>;
  startFolderRef: React.RefObject<string | undefined>;
  peerTrustStarted: React.RefObject<(() => void) | undefined>;
  trustRefused: React.RefObject<((error: unknown, again?: () => void, declined?: () => void) => boolean) | undefined>;
  trustCancelEpoch: React.RefObject<number>;
  pendingTrustRefusal: React.RefObject<
    | {
        client: AcpmuxDirectClient;
        generation: number;
        sessionId?: string;
        cancelEpoch: number;
        error: unknown;
        again?: () => void;
        declined?: () => void;
      }
    | undefined
  >;
  trustRouteOwner: React.RefObject<
    { client: AcpmuxDirectClient; generation: number; sessionId?: string; cancelEpoch: number } | undefined
  >;
  holdPrompt: React.RefObject<(() => void) | undefined>;
  holdRefused: React.RefObject<
    (text: string, attachments: ComposerAttachment[], error: unknown, sentFrom: SentFrom) => void
  >;
  shownFrom: React.RefObject<() => SentFrom>;
  trustRevision: React.RefObject<number>;
  retryAfterTrust: React.RefObject<<T>(again: () => Promise<T>) => Promise<T | undefined>>;
  setSurface: React.Dispatch<React.SetStateAction<PaneSurface>>;
  setPreviewHost: React.Dispatch<React.SetStateAction<boolean>>;
  lastFailedRuns: React.RefObject<ReadonlyMap<string, FailedRun> | undefined>;
  setWokenFolds: React.Dispatch<React.SetStateAction<{ session: string; folds: PaneFolds } | undefined>>;
  foldsNow: React.RefObject<{ session?: string } & PaneFolds>;
  findRef: React.RefObject<ChatFind | undefined>;
  toggleInspector: (open?: boolean) => boolean;
  sessionIdRef: React.RefObject<string | undefined>;
  subagentDraftChatRef: React.RefObject<string>;
  openChangesTab: React.RefObject<() => void>;
  setClientEpoch: React.Dispatch<React.SetStateAction<number>>;
  folderContinuation: FolderContinuation;
  continuationProjectGeneration: React.RefObject<number>;
  setHarnessesOpen: React.Dispatch<React.SetStateAction<boolean>>;
  setRegistry: React.Dispatch<React.SetStateAction<NativeRegistry>>;
  setNewTab: React.Dispatch<React.SetStateAction<NewTabHost | undefined>>;
  newTabStartGeneration: React.RefObject<number>;
  showsNewTabRef: React.RefObject<boolean>;
  newTabNow: React.RefObject<NewTabHost | undefined>;
  newTabRetainsDraft: React.RefObject<boolean>;
  earlyNewTab: ReturnType<typeof useEarlyNewTabContext>;
  checkSharedPart: ReturnType<typeof useLostSharedPart>;
  automationView: React.RefObject<
    { snapshot: AcpmuxSnapshot; selectSession: (sessionId: string) => void; openDiff: OpenDiff } | undefined
  >;
  setShortcuts: React.Dispatch<React.SetStateAction<Readonly<Record<string, string>>>>;
  setCloudPickRequest: React.Dispatch<React.SetStateAction<number>>;
  setCloudStart: React.Dispatch<React.SetStateAction<CloudStartProgress | undefined>>;
  composerHandle: React.RefObject<ComposerHandle | null>;
  externalWaiting: React.RefObject<boolean>;
  shownCloudStartPickNow: () => CloudStartPick | undefined;
  toggleSessionInfo: React.RefObject<(() => void) | undefined>;
  paletteCommands: React.RefObject<{ sessionId: string; commands: Record<string, () => void> }>;
  counted: React.RefObject<{
    summary: AcpmuxSnapshot["summary"];
    runningAgents: readonly Subagent[];
    runningCommands: readonly BackgroundCommand[];
    runningSessions: readonly StartedSession[];
    sourceRows: AcpmuxRow[];
    childRows: AcpmuxRow[] | undefined;
    transcriptRows: AcpmuxRow[];
    summaryCard: ReturnType<typeof useSummaryCard>;
    sessionInfo: ReturnType<typeof useSessionInfo>;
    backgroundCommandList: BackgroundCommand[];
  }>;
  opensSideSessionsRef: React.RefObject<boolean>;
  promptLanded: React.RefObject<() => void>;
  rowsRef: React.RefObject<readonly AcpmuxRow[]>;
  drawnSnapshot: React.RefObject<AcpmuxSnapshot | undefined>;
  receivedSnapshot: React.RefObject<AcpmuxSnapshot | undefined>;
  toolOutputEpoch: React.RefObject<number>;
  pendingPaneDraw: PendingPaneDraw;
  snapshotRef: React.RefObject<AcpmuxSnapshot | undefined>;
  readSendAgain: () => SendPromptAgainState;
  readInterruptedResume: () => InterruptedResumeState;
  opensSideChat: React.RefObject<boolean>;
  archiveChatRef: React.RefObject<(() => void) | undefined>;
  newChatLeftover: React.RefObject<() => { leave: () => void; cancel: () => void } | undefined>;
  heldBack: React.RefObject<{ text: string; attachments: ComposerAttachment[] }[] | undefined>;
  quoteReply: (markdown: string) => void;
  giveBackTrustHeld: React.RefObject<
    (
      _entries: readonly TrustHeldPrompt[],
      _behind?: boolean,
      _closing?: boolean,
      _until?: number,
    ) => Promise<ComposerAttachment[]>
  >;
  trustHeldNow: React.RefObject<ReturnType<typeof useTrustHeldPrompts>>;
  untakenSends: React.RefObject<number>;
  pendingWake: React.RefObject<ComposerWake | undefined>;
  transcriptAnchor: React.RefObject<(() => ScrollAnchor | null | undefined) | undefined>;
  setSends: React.Dispatch<React.SetStateAction<number>>;
  followingTranscript: React.RefObject<boolean>;
  setHostError: React.Dispatch<React.SetStateAction<string | undefined>>;
  setHostFailure: React.Dispatch<unknown>;
  setHostErrorShown: React.Dispatch<React.SetStateAction<boolean>>;
  setRetryQueued: React.Dispatch<React.SetStateAction<boolean>>;
  retryHost: React.RefObject<(() => void) | undefined>;
  cancelRetry: React.RefObject<(() => void) | undefined>;
  setAcpmuxRestartOffered: React.Dispatch<React.SetStateAction<boolean>>;
  restartGate: AcpmuxRestartGate;
  setWaitingSince: React.Dispatch<React.SetStateAction<number | undefined>>;
  setRestartUnavailable: React.Dispatch<React.SetStateAction<boolean>>;
  /// When the pane's trouble began (`troubleSince` below): bounds how long a self-retrying failure
  /// stays quiet (hostRetry.ts SELF_RETRY_SAID_MS).
  setHostTroubleSince: React.Dispatch<React.SetStateAction<number | undefined>>;
  runPendingAdoption: React.RefObject<() => void>;
  freshRef: React.RefObject<boolean>;
  inheritedFolderRef: React.MutableRefObject<string | undefined>;
  setHandedFolder: React.Dispatch<React.SetStateAction<string | undefined>>;
  automationPick: React.RefObject<((cwd: string) => void) | undefined>;
  automationCompose: React.RefObject<AutomationCompose | undefined>;
  focusComposer: () => void;
};

/** The body of AcpmuxPane's snapshot effect (RFD 0046 step 2), run by that effect in App.tsx; returns its cleanup. */
export function paneSnapshotEffect({
  scrollToBottomOnSendRef,
  sandbox,
  setWorkflowLabsEnabled,
  setLiveTreeEnabled,
  setDraft,
  setNewSession,
  setHandshaken,
  handshakenRef,
  reconnectingRef,
  setAwaitsChat,
  pendingSubmits,
  setProjectDraft,
  startedFromHint,
  setChooseFolder,
  setFolderNeeded,
  setPastTurns,
  setPastWaitsForTrust,
  setMachineName,
  setLocalMachineName,
  setCloudMachineID,
  cloudMachineIDRef,
  setCloudRepositoryAvailable,
  setCloudChatIdentity,
  cloudIdentityBound,
  setCloudTurnRewind,
  cloudTurnRewindUnbound,
  cloudCheckpoints,
  observeCloudTurn,
  setCloudTeamMachine,
  setScrollAnchor,
  setGithubRepository,
  setSnapshot,
  harnessSwitch,
  switchViewRef,
  newChatPrewarm,
  cloudTypingPrewarm,
  queryClient,
  catalogClientId,
  directClient,
  notices,
  connectedClients,
  setCatalogSource,
  setBlockedHarness,
  catalogRef,
  trustRouteSnapshot,
  trustRenderedOwner,
  setCheckpointVariant,
  showCheckpoint,
  setContinuing,
  transcriptInView,
  revealRef,
  startFolderRef,
  peerTrustStarted,
  trustRefused,
  trustCancelEpoch,
  pendingTrustRefusal,
  trustRouteOwner,
  holdPrompt,
  holdRefused,
  shownFrom,
  trustRevision,
  retryAfterTrust,
  setSurface,
  setPreviewHost,
  lastFailedRuns,
  setWokenFolds,
  foldsNow,
  findRef,
  toggleInspector,
  sessionIdRef,
  subagentDraftChatRef,
  openChangesTab,
  setClientEpoch,
  folderContinuation,
  continuationProjectGeneration,
  setHarnessesOpen,
  setRegistry,
  setNewTab,
  newTabStartGeneration,
  showsNewTabRef,
  newTabNow,
  newTabRetainsDraft,
  earlyNewTab,
  checkSharedPart,
  automationView,
  setShortcuts,
  setCloudPickRequest,
  setCloudStart,
  composerHandle,
  externalWaiting,
  shownCloudStartPickNow,
  toggleSessionInfo,
  paletteCommands,
  counted,
  opensSideSessionsRef,
  promptLanded,
  rowsRef,
  drawnSnapshot,
  receivedSnapshot,
  toolOutputEpoch,
  pendingPaneDraw,
  snapshotRef,
  readSendAgain,
  readInterruptedResume,
  opensSideChat,
  archiveChatRef,
  newChatLeftover,
  heldBack,
  quoteReply,
  giveBackTrustHeld,
  trustHeldNow,
  untakenSends,
  pendingWake,
  transcriptAnchor,
  setSends,
  followingTranscript,
  setHostError,
  setHostFailure,
  setHostErrorShown,
  setRetryQueued,
  retryHost,
  cancelRetry,
  setAcpmuxRestartOffered,
  restartGate,
  setWaitingSince,
  setRestartUnavailable,
  setHostTroubleSince,
  runPendingAdoption,
  freshRef,
  inheritedFolderRef,
  setHandedFolder,
  automationPick,
  automationCompose,
  focusComposer,
}: PaneSnapshotArgs) {
  window.React = React;
  window.cmuxAcpmuxRegistry = {
    register(kind, renderer, options) {
      const registered = window.cmuxAcpmuxRegistry as unknown as Record<string, unknown>;
      if (registered[kind] === renderer && (!options?.measure || options.measure === renderer.measure)) return;
      if (options?.measure) renderer.measure = options.measure;
      registered[kind] = renderer;
      setRegistry(currentRegistry());
    },
    configure() {
      setRegistry(currentRegistry());
    },
  };
  window.cmuxAcpmuxBridge = {
    toggleInspector,
    perfCapture: (options) => chatPerfCapture.capture(options),
    lastCodeBlock: () => lastCodeBlock(snapshotRef.current?.rows ?? []) ?? null,
    composerState: () => {
      const draft = composerHandle.current?.draft();
      return draft ? composerReadback(draft) : null;
    },
    conversationMarkdown: async () => {
      const client = directClient.current;
      const sessionId = client?.selectedSession;
      if (!client || !sessionId) return null;
      const current = () =>
        directClient.current === client &&
        client.selectedSession === sessionId &&
        snapshotRef.current?.sessionId === sessionId;
      try {
        const events = await client.conversationEvents(current);
        if (!current()) return null;
        return recordedConversationMarkdown(sessionId, events) || null;
      } catch {
        return null;
      }
    },
    command(name, sessionId) {
      // FOCUS-RING: the app's key router took this command's key, which the pane never saw; any
      // focus it moves is code focus and earns no ring, even right after a Tab.
      dismissFocusRing();
      if (name === "toggleSessionInfo") {
        toggleSessionInfo.current?.();
        return;
      }
      if (name.startsWith("header:")) {
        const separator = name.indexOf("|");
        if (separator < 0) return;
        const target = name.slice(separator + 1);
        // Both the live client and rendered callbacks must still belong to the captured chat.
        if ((directClient.current?.selectedSession ?? "") !== target) return;
        const rendered = paletteCommands.current;
        if (rendered.sessionId !== target) return;
        rendered.commands[name.slice("header:".length, separator)]?.();
        return;
      }
      // Native palette rows carry the session id that was focused when the action was queued.
      // Handle them after the current render has installed its row callbacks; the listener below
      // drops a command whose page has since switched to another session.
      if (name.startsWith("menu:")) {
        window.dispatchEvent(new CustomEvent("cmux-acpmux-menu-command", { detail: name }));
        return;
      }
      if (name === "createCheckpoint") showCheckpoint.current();
      // Stop Agent Turn (the native command palette): the composer owns the guarded cancel
      // callback, so a palette invocation cannot race a session switch with a stale client.
      if (name === "stopTurn") {
        // The page may hold chat A's last snapshot while the live client has already selected B.
        // Recheck the live selection before dispatching so A's command cannot cancel B.
        if (directClient.current?.selectedSession !== sessionId) return;
        window.dispatchEvent(new CustomEvent("cmux-acpmux-stopTurn", { detail: { sessionId } }));
      }
      // Side Question (the palette): the composer, focused, with `/btw ` to type the question after.
      if (name === "sideQuestion") {
        const shown = snapshotRef.current;
        const selected = directClient.current?.selectedSession;
        const side = shown?.sessions.some((entry) => entry.sessionId === sessionId && entry.side === true);
        if (
          !opensSideSessionsRef.current ||
          !sessionId ||
          selected !== sessionId ||
          shown?.sessionId !== sessionId ||
          side
        )
          return;
        composerHandle.current?.prefill("/btw ");
      }
      // Find, Find Next, Find Previous and Hide Find on an agent pane (the app's Edit menu, Cmd-F).
      // With the keyboard in the changes view (or the view covering the transcript) they find there.
      const target = findRef.current;
      if (name === "find") target?.show();
      if (name === "findNext") target?.next();
      if (name === "findPrevious") target?.previous();
      if (name === "hideFind") target?.hide();
      // Switch Model… (Ctrl-Cmd-M): the model picker opens on the path every opener uses, which
      // ends with the keyboard in its search field.
      if (name === "openModelPicker") openPicker(translate(PICKER_LABELS.model));
      // The composer bar's other controls from their shortcuts (composerControls.ts): each opens
      // as a click on it does.
      if (name.startsWith("composer.")) openComposerControl(name.slice("composer.".length), translate);
      // Integrate a Harness… from the palette or the File menu on a New Tab page (cx-9fqw): the
      // Harnesses page in place, as the page's own button shows it.
      if (name === "showHarnesses") openHarnessesPage();
      // A chat that just opened from a fork (the app's Fork Conversation): the composer takes the
      // keyboard, so the next words go to the fork.
      if (name === "focusComposer") focusRoute(composerHandle.current, "system", "the host's focusComposer");
      // Files another app sent to this chat (Send to cmux Chat, an image opened with cmux): the
      // composer takes them as a drop's, an unsent draft, with the keyboard (composer/externalAttach.ts).
      if (name === "attachExternal")
        externalWaiting.current = !takeExternalInto(() => composerHandle.current, callNative);
      // Archive Chat (Ctrl-Cmd-A), as in the Codex app: the chat menu's row, so it does nothing where
      // the menu has none or the chat is archived.
      if (name === "archiveChat") archiveChatRef.current?.();
      // Commit and Push live in the diff tab beside the chat (its Commit form and Push button).
      if (name === "gitCommit" || name === "gitPush") openChangesTab.current();
      // A card that mounts just after the click still takes it (`permissions/focusRequest.ts`).
      if (name === "permissionFocus") askPermissionFocus();
      if (
        [
          "permissionAllowOnce",
          "permissionAllowChat",
          "permissionDeny",
          "permissionExpand",
          "permissionRetry",
          "permissionRevoke",
          "permissionRefresh",
          // A click on an ask's notification: the waiting card takes the keyboard.
          "permissionFocus",
          // Previous Turn and Next Turn (Ctrl-Opt-Up, Ctrl-Opt-Down), and Previous and Next Bookmarked
          // Prompt (the palette's): the thread minimap steps the transcript.
          "previousTurn",
          "nextTurn",
          "previousBookmarkedPrompt",
          "nextBookmarkedPrompt",
          // Search Files… (the command palette; no default key: Cmd-P is the native Go to): the composer opens its file search.
          "searchFiles",
        ].includes(name)
      ) {
        window.dispatchEvent(new CustomEvent(`cmux-acpmux-${name}`));
      }
      if (
        name === "continueIn" &&
        snapshotRef.current?.canHandoff &&
        snapshotRef.current.handoff?.ready &&
        !snapshotRef.current.isWorking &&
        !snapshotRef.current.queue.length
      )
        setContinuing(true);
    },
    receive(next) {
      if (next.protocolVersion !== 1) return;
      harnessSwitch.reconcile(next);
      rowsRef.current = next.rows;
      snapshotRef.current = next;
      trustRouteSnapshot.current = next;
      observeCloudTurn(next);
      const owner = directClient.current;
      trustRenderedOwner.current = {
        client: owner,
        generation: owner?.trustGeneration,
        sessionId: next.sessionId,
      };
      saveSnapshot(next);
      setSnapshot(next);
    },
    applyTheme(theme) {
      applyPaneTheme(theme);
    },
    applyShortcuts(labels) {
      setShortcuts(readShortcuts(labels));
    },
    cloudStartProgress(push) {
      setCloudStart((current) => cloudStartPushed(current, push));
    },
    applyPreview(on) {
      // The environment picker, Cloud (Move to Cloud, the account's Cloud machines) and Sandboxed
      // runs are not behind Labs (Leo, 2026-10-30: "i dont like putting so much stuff in labs").
      // Cloud's own checks stay: Cloud allowed by policy, a signed-in account, and an explicit
      // pick; nothing creates a paid VM without one.
      setPromptSurfaces(on === true);
      setStartRecoveryPreview(on === true);
      // Workflows no longer follow Advanced > Labs; only applyWorkflowLabs switches them.
    },
    applyLiveTree(on) {
      setLiveTreeEnabled(on === true);
    },
    applyWorkflowLabs(on) {
      setWorkflowLabsEnabled(on === true);
    },
    applySidebarPreviewVariant(variant) {
      configureNativeSidebarPreviewVariant(variant);
    },
    applySessionStatus(on) {
      setSessionStatus(on === true);
    },
    applyExperiments(value) {
      setExperimentSwitches(value);
    },
    agentAvatarChanged(sessionId) {
      if (typeof sessionId === "string") agentAvatarChanged(sessionId);
    },
    applySuggestedTasks(on) {
      if (setSuggestedTasks(on === true)) directClient.current?.suggestedTasksChanged();
    },
    applyRemoteControl(value) {
      setRemoteControl(value);
    },
    applyPaneNotices(value) {
      setPaneNotices(value);
    },
    applyHeaderState(state) {
      setHeaderState(state);
    },
    applyTabRow(row) {
      setTabRow(row);
    },
    applyFloatingState(state) {
      setFloatingState(state);
    },
    applyDeviceChats(chats) {
      setDeviceChats(chats);
    },
    applyRecentlyClosed(items) {
      setRecentlyClosed(items);
    },
    applyNowPlaying(track) {
      setNowPlaying(track);
    },
    applyReadAloud(state) {
      setReadAloudState(state);
    },
    applyAttentionTabs(tabs) {
      setAttentionTabs(tabs);
    },
    applyLinkPlaces(places) {
      setLinkPlaces(places);
    },
    applyLinkPlacesChanged(places) {
      updateLinkPlaces(places);
    },
    revealTurn(turnId) {
      revealRef.current(turnId);
    },
    applyCustomization(customization) {
      if ("themeCSS" in customization) {
        applyPaneThemeCSS(customization.themeCSS ?? "");
      }
      if (customization.registryJS) {
        try {
          (0, eval)(customization.registryJS);
          setRegistry(currentRegistry());
        } catch {
          /* a user renderer must not take down the transcript */
        }
      }
      if (customization.layout) {
        configureDictation(customization.layout);
        configureQuickActions(customization.layout);
        configureSidebarPreviewVariant(customization.layout.sidebarPreviewVariant);
        window.cmuxAcpmuxRegistry?.configure(customization.layout);
      } else configureSidebarPreviewVariant(undefined);
    },
    dictation(update) {
      deliverDictation(update);
    },
    designSelection(selection) {
      const removals = designSelectionRemovals(selection);
      if (removals.length) composerHandle.current?.detach(removals);
      for (const chip of designSelectionChips(selection)) composerHandle.current?.attach(chip);
    },
  };
  // On the shared page host the host pushes arrive as events once the bridge exists.
  const pageHost = pageHostClient();
  if (pageHost) void startHostEvents(pageHost).catch(() => undefined);
  window.cmuxAcpmuxDebug = createAcpmuxDebug({
    replaceRows(rows, fields) {
      rowsRef.current = rows;
      setSnapshot((current) => ({
        ...current,
        rows,
        connection: "debug",
        isWorking: fields?.isWorking ?? false,
        canLoadOlder: false,
        // The live chat's steers name rows the seed replaced: only the fixture's own stand.
        waitingSteers: fields?.waitingSteers,
        newestOwnSteer: fields?.newestOwnSteer,
        ...(fields && current.summary && { summary: { ...current.summary, ...fields.summary } }),
      }));
    },
    rowCount: () => rowsRef.current.length,
    rowIds: () => rowsRef.current.map((row) => row.id),
    sessionId: () => directClient.current?.selectedSession,
    toast: (text) => notices.transient(text),
    automation: {
      snapshot: () => automationView.current!.snapshot,
      // The chat's own actions only, once it connects: never the native host (automation.ts pageAction).
      call: async (method, params) => (await pageAction(() => window.cmuxAcpmuxActions, method))(params ?? {}),
      ready: async (method) => void (await pageAction(() => window.cmuxAcpmuxActions, method)),
      selectSession: (sessionId) => automationView.current?.selectSession(sessionId),
      openDiff: (rowId) => automationView.current?.openDiff(rowId),
      pickFolder: (cwd) => automationPick.current?.(cwd),
      compose: {
        send: (text) => automationCompose.current?.send(text) ?? Promise.resolve(undefined),
        runMode: () => automationCompose.current?.runMode(),
        setRunMode: (mode) => automationCompose.current?.setRunMode(mode) ?? false,
        cloudStart: () => automationCompose.current?.cloudStart() ?? null,
      },
    },
  });
  let cancelled = false;
  // The New Tab page closes (AgentPaneView.discardUnsentChat, cx-e2aa): a chat a chip pick started
  // behind it, never sent, is discarded.
  const discardUnsent = () => harnessSwitch.cancelDeferred();
  window.addEventListener(NEW_TAB_CLOSE_EVENT, discardUnsent);
  let retryTimer: number | undefined;
  let retryDelay = 250;
  /// The last handshake named a socket this page opens itself (`acpmux-websocket`), which the browser
  /// holds back after many failed opens: no quick asks (hostRetry.ts `quickRetry`).
  let browserSocket = false;
  /// When the last client connected: its loss starts the backoff over only if it stayed up
  /// (hostRetry.ts `lostRetryDelay`).
  let connectedAt = 0;
  // Once a daemon was lost, handshakes only look for one: the user may have stopped it.
  // Looking is cheap, so a daemon started again elsewhere is found within seconds.
  let reconnect = false;
  /// The chat the lost client held (direct.ts `CarriedChat`): the next client starts from it, so
  /// a reconnect keeps every row on screen instead of reading the chat again from nothing.
  let carriedChat: CarriedChat | undefined;
  /// When the handshakes began failing (cleared by a connect): a recovery is said only once it
  /// has failed for HOST_ERROR_DEADLINE_MS (hostRetry.ts).
  let failingSince: number | undefined;
  /// When the pane's trouble began: unlike `failingSince`, a connect that is lost again within
  /// CONNECTION_STABLE_MS does not end it (hostRetry.ts `troubleSinceAfterLoss`), so a chat that
  /// never stays open stops being a bare "Reconnecting…" past SELF_RETRY_SAID_MS.
  let troubleSince: number | undefined;
  let connecting = false;
  /// The user asked to retry while an attempt was in flight; run a full one when it ends.
  let retryPending = false;
  // A seeded first prompt (onboarding's first task). Swift hands it out once, so it is kept
  // here until a connect succeeds: a first connect that fails retries without it.
  let pendingPrompt: string | undefined;
  let pendingAttachments: ComposerAttachment[] | undefined;
  let pendingTicket: { promptId: string; ticket: string } | undefined;
  // The harness that seeded prompt starts on (`newTab.submit --agent`), kept with it.
  let pendingHarness: string | undefined;
  let pendingModel: string | undefined;
  let pendingEffort: string | undefined;
  /// The connected client as the harness switch sees it.
  let switchPort: SwitchPort | undefined;
  /// Who sent each prompt a harness switch held, stamped when the switch sends it into the session
  /// it opened: a trust refusal for that prompt belongs to that selection, not to the one the
  /// composer's send saw before the switch selected its chat.
  const switchSendOwners = new Map<string, TrustRefusalOwner<AcpmuxDirectClient>>();
  /// Sessions a switch started whose first summary has not arrived: it names the model a new
  /// chat on that harness starts on.
  const startedSessions = new Set<string>();
  /// Prompts a failed or cancelled switch held go back into the composer with their
  /// attachments, before what was typed since; while no composer is mounted they wait for one.
  /// The gesture of a send acpmux held for the folder trust answer (heldPrompt.ts).
  const heldPrompt = heldPrompts((intent) =>
    postNative<{ ticket?: string }>("transport.gesture", { intent }).then((reply) => reply?.ticket),
  );
  holdPrompt.current = () => void heldPrompt.hold();
  /// The tickets of prompts the folder's trust held (trustHeld.ts) that a harness switch holds now,
  /// by prompt id, for the switch's send.
  const trustTickets = new Map<string, string>();
  /// The gesture a failed prompt row kept for its Trust re-send, apart from `heldPrompt`, which
  /// the next ordinary send takes: a prompt typed before Trust never goes under the row's id.
  const heldRowPrompt = heldPrompts((intent) =>
    postNative<{ ticket?: string }>("transport.gesture", { intent }).then((reply) => reply?.ticket),
  );
  const restorePrompt = (text: string, attachments: ComposerAttachment[]) => {
    if (composerHandle.current) composerHandle.current.restore(text, attachments);
    else heldBack.current = [...(heldBack.current ?? []), { text, attachments }];
  };
  const connectHost = async () => {
    // A Restart acpmux in flight: the old daemon is still there until it stops, and the restart
    // asks again itself when it ends. A timer queued before it, or set while it runs, asks nothing.
    if (connecting || !restartGate.mayAsk()) return;
    connecting = true;
    // Keep the existing Cloud route and destination picker alive for wake-and-send recovery
    // while reconnecting. This separate gate blocks typing hints until the new handshake installs
    // its identity, without unmounting ComposerContext and losing a pending machine selection.
    reconnectingRef.current = true;
    cloudTypingPrewarm.reset();
    try {
      acpmuxPerf.markAgent("handshakeStart");
      acpmuxPerf.markLaunch("handshakeStart");
      acpWire.lifecycle("handshake", { reconnect });
      setWaitingSince(Date.now());
      setRestartUnavailable(false);
      const answered = await callNative<{
        protocolVersion: number;
        transport?: string;
        /// Only the browser dev slot (devHost.ts) sends these; the app never does.
        endpoint?: string;
        token?: string;
        sessionId?: string;
        newSession?: boolean;
        newTab?: unknown;
        cwd?: string;
        draft?: string;
        prompt?: string;
        promptAttachments?: ComposerAttachment[];
        promptTicket?: { promptId?: unknown; ticket?: unknown };
        harness?: string;
        /// A Cloud start's picked effort (AgentPaneHandshake `effort`): the seeded chat starts on it.
        effort?: unknown;
        peer?: string;
        adopt?: unknown;
        surface?: unknown;
        linkScheme?: unknown;
        sessionMustExist?: boolean;
        revealTurn?: unknown;
        wake?: unknown;
        chooseFolder?: boolean;
        folderNeeded?: { reason?: unknown };
        pastTurns?: unknown;
        machineName?: unknown;
        localMachineName?: unknown;
        cloudMachineID?: unknown;
        cloudAccount?: unknown;
        cloudTeamMachine?: unknown;
        /// The prompt row ids whose turn has a Cloud machine checkpoint to rewind to (TurnActions
        /// `rewind`, answered by `chat.rewindTurn`); absent where the host serves no rewind.
        cloudTurnRewind?: unknown;
        /// The app opens a Cloud chat's hand-off turns (`cloud.handoffTurn`, cloudHandoffTurn.ts).
        cloudHandoffs?: unknown;
        cloudRepositoryAvailable?: unknown;
        githubRepository?: unknown;
        harnesses?: unknown;
        /// New Cloud Chat opened this tab (AgentPaneHandshake `pickCloud`): it picks Cloud once offered.
        pickCloud?: unknown;
        /// Another chat's `/side --on cloud` or `/cd --on cloud` opened this tab (commandPlace.ts).
        cloudStartHandoff?: unknown;
        model?: unknown;
        sandboxState?: unknown;
        /// The tab this page is (AgentPaneHandshake `tab`); an older app sends none.
        tab?: unknown;
      }>("ready", reconnect ? { reconnect } : {})
        // The host cleared its toast box for this handshake: it hears the mounted composer's again.
        .finally(resendToastAvoidance);
      if (cancelled) return;
      // What another chat handed this new Cloud chat, by its token, read once (commandPlace.ts).
      const received = receiveHandedCloudStart(answered, reconnect, handoffStore(), Date.now());
      const host = received.host;
      if (received.folder) setHandedFolder(received.folder);
      // Before anything draws the chat: its Session Info is this tab's, not another tab's of the chat.
      if (typeof host.tab === "string" && host.tab) setSessionInfoTab(host.tab);
      acpmuxPerf.markAgent("handshakeReady");
      acpmuxPerf.markLaunch("handshakeReady");
      setCloudTeamMachine(host.cloudTeamMachine === true);
      const turnRewind =
        Array.isArray(host.cloudTurnRewind) && host.cloudTurnRewind.every((id) => typeof id === "string")
          ? new Set(host.cloudTurnRewind as string[])
          : undefined;
      const turnRewindChat =
        (typeof host.sessionId === "string" && host.sessionId) || snapshotRef.current?.sessionId || undefined;
      cloudTurnRewindUnbound.current = turnRewind !== undefined && !turnRewindChat;
      setCloudTurnRewind((marks) => handshakeMarks(marks, turnRewind, turnRewindChat));
      cloudCheckpoints.current?.setOn(turnRewind !== undefined);
      setCloudRepositoryAvailable(host.cloudRepositoryAvailable === true);
      setCloudMachineID(
        typeof host.cloudMachineID === "string" && host.cloudMachineID ? host.cloudMachineID : undefined,
      );
      cloudIdentityBound.current = true;
      setCloudChatIdentity(
        typeof host.cloudMachineID === "string" &&
          Array.isArray(host.cloudAccount) &&
          host.cloudAccount.every((part) => part === null || typeof part === "string")
          ? { id: host.cloudMachineID, account: host.cloudAccount as (string | null)[] }
          : undefined,
      );
      setNewSession(host.newSession === true && !host.sessionId);
      // The store's start folder: the same as the app's start drawn first changes nothing; another
      // replaces it, and none clears it unless the person picked a folder meanwhile.
      if (host.newSession && !host.sessionId && typeof host.cwd === "string" && host.cwd) setProjectDraft(host.cwd);
      else if (host.newSession && !host.sessionId && !reconnect && startedFromHint.current !== undefined) {
        const hinted = startedFromHint.current;
        setProjectDraft((current) => reconciledProject(current, hinted, undefined));
      }
      if (!reconnect) startedFromHint.current = undefined;
      setChooseFolder(host.chooseFolder === true);
      setFolderNeeded(
        typeof host.folderNeeded?.reason === "string" && host.folderNeeded.reason
          ? { reason: host.folderNeeded.reason }
          : undefined,
      );
      setPastTurns(host.sessionId ? undefined : readPastTurns(host.pastTurns));
      setPastWaitsForTrust(host.adopt !== undefined && host.adopt !== null);
      if (!reconnect)
        setAwaitsChat(
          Boolean(host.sessionId) &&
            (host.transport === "mock" ||
              host.transport === "acpmux-bridge" ||
              (host.transport === "acpmux-websocket" && Boolean(host.endpoint && host.token))),
        );
      setHandshaken(true);
      // After a reload (a web update that went anyway, a crash) the host still holds this tab's
      // Sandboxed send (the host holds it): read at each handshake (a reconnect too) and shown
      // whatever Labs says now, so a paid run's receipt stays reachable (sandboxRun.ts SandboxTab.read).
      // An app that doesn't answer `sandbox.state` says nothing of it: nothing is read.
      if (host.sandboxState === true) void sandbox.read();
      handshakenRef.current = true;
      reconnectingRef.current = false;
      // Submits made on the New Tab page before acpmux answered go now, in order.
      for (const run of pendingSubmits.current.splice(0)) run();
      if (
        (host.newSession && !host.sessionId) ||
        (host.sessionId && snapshotRef.current?.sessionId && host.sessionId !== snapshotRef.current.sessionId)
      )
        // The chats list and peers stay (the New Tab page, the hero's projects and Recents draw from
        // them); the client's first frame replaces them.
        setSnapshot((previous) => ({
          ...emptySnapshot(),
          sessions: previous.sessions,
          peers: previous.peers,
        }));
      if (!reconnect) setSurface(readSurface(host.surface));
      setMachineName(typeof host.machineName === "string" && host.machineName ? host.machineName : undefined);
      setLocalMachineName(
        typeof host.localMachineName === "string" && host.localMachineName ? host.localMachineName : undefined,
      );
      // Before the transcript's rows arrive: it opens where the reader left it (cx-6bgzj).
      // A woken page (its last one let go while hidden) comes back as it was left.
      const wake = !reconnect ? readWake(host.wake) : undefined;
      if (wake) {
        // Each subagent's unsent prompt comes back before its pane's composer reads it.
        wakeIntoSubagentDrafts(wake.subagentDrafts);
        if (composerHandle.current) composerHandle.current.wake(wake.composer);
        else pendingWake.current = wake.composer;
        const folds = readWakeFolds(wake.folds, host.sessionId);
        if (folds && host.sessionId) setWokenFolds({ session: host.sessionId, folds });
      }
      if (!reconnect && host.sessionId) {
        // The chat's kept tail is asked for now, beside the reading place: the client draws it
        // while its socket connects, and this read is the one it waits on (#32735, tailCache.ts).
        if (host.transport !== "mock") void readHostTail(host.sessionId).catch(() => undefined);
        // The released page's place is newer than the kept one: a scroll that settled while
        // hidden was never reported. Keep it for a relaunch too.
        const woken = wake?.scrollAnchor;
        if (woken !== undefined) postScrollAnchor(host.sessionId, woken);
        const anchor = woken
          ? { sessionId: host.sessionId, ...woken }
          : woken === null
            ? undefined
            : await fetchScrollAnchor(host.sessionId);
        if (cancelled) return;
        setScrollAnchor(anchor);
      }
      // Reconnect handshakes for an existing session do not carry its cwd. Keep the current
      // repository until the snapshot effect observes a new session/origin/cwd; a fresh ready
      // handshake has no prior context and must clear it when the host has no GitHub origin.
      if (typeof host.githubRepository === "string" && host.githubRepository) {
        setGithubRepository(host.githubRepository);
      } else if (!reconnect) {
        setGithubRepository(undefined);
      }
      // A tab opened as the new tab page shows it until it becomes something (#16620).
      // A page that drew its New Tab frame before the handshake (useEarlyNewTabContext) keeps its
      // state: a page the user already left stays a chat.
      if (!reconnect && !earlyNewTab.current) setNewTab(newTabHost(host));
      // The early context lacks the folder the handshake filled in (seed, start folder) and, on a
      // cold page, the palette's actions whose places event came before its listener: add them.
      else if (!reconnect) setNewTab((current) => withHandshakeNewTab(current, host));
      if (!reconnect) checkSharedPart(host.newTab);
      // A chat opened from another tab starts with what it inherited (#16620). Swift hands the
      // draft out once, so a retried `ready` after a failed connect has none and keeps this one.
      const seeded = composerDraft(host.draft);
      if (seeded) setDraft(seeded);
      // Integrate a Harness… from the palette or the menu opened this tab (cx-uj5g8).
      if (host.harnesses === true) setHarnessesOpen(true);
      // New Cloud Chat from the palette opened this tab: it picks Cloud, as the Where menu's Cloud row does.
      if (host.pickCloud === true) setCloudPickRequest((count) => count + 1);
      pendingPrompt = composerDraft(host.prompt) ?? pendingPrompt;
      pendingAttachments = host.promptAttachments ?? pendingAttachments;
      // A prompt a person's action seeded has a single-use host ticket bound to its promptId
      // (cx-k21v gap 4); a CLI, MCP or script seed has none and the host refuses its send.
      if (
        (host.prompt || host.promptAttachments?.length) &&
        typeof host.promptTicket?.promptId === "string" &&
        typeof host.promptTicket.ticket === "string"
      )
        pendingTicket = {
          promptId: host.promptTicket.promptId,
          ticket: host.promptTicket.ticket,
        };
      if (typeof host.harness === "string" && host.harness) pendingHarness = host.harness;
      if (typeof host.model === "string" && host.model) pendingModel = host.model;
      if (typeof host.effort === "string" && host.effort) pendingEffort = host.effort;
      // Mock mode runs this same client against an in-page daemon.
      const mock = host.transport === "mock";
      setPreviewHost(host.transport === "preview");
      // Links copy in this build's scheme; only the hostless mock page falls back to Release's.
      setLinkScheme(host.linkScheme, mock ? FALLBACK_LINK_SCHEME : undefined);
      // Dev builds judge every layout move against the layout-motion contract (devMotionAudit.ts).
      if (!mock) startDevMotionAudit(host.linkScheme);
      if (mock) markMockPage();
      if (mock)
        setCheckpointVariant(
          new URLSearchParams(window.location.search).get("checkpointVariant") === "expanded" ? "expanded" : "compact",
        );
      // The app's host owns the socket (`acpmux-bridge`); the page never gets an endpoint or token.
      const bridge = host.transport === "acpmux-bridge";
      // The page opens its own WebSocket only on the dev slot (hostRetry.ts `quickRetry`).
      browserSocket = !mock && !bridge;
      if (!mock && !bridge && !(host.transport === "acpmux-websocket" && host.endpoint && host.token)) {
        // A host with no daemon to reach has nothing left to fail.
        setHostError(undefined);
        setHostErrorShown(false);
        return;
      }
      // Native chats never load the in-page daemon or its fixture transcripts. Keep this
      // await in the mock branch so the native handshake still starts in the same turn.
      const mockModule = mock ? (preparedMockTransport() ?? (await import("../mock"))) : undefined;
      if (cancelled) return;
      // A new chat in mock mode starts without a session too, as against a real daemon. A host
      // that names a mock session (a gallery scene) opens that one.
      const config: AcpmuxHostConfig = mockModule
        ? host.newSession
          ? { ...mockModule.mockHost, sessionId: undefined, newSession: true }
          : { ...mockModule.mockHost, sessionId: host.sessionId || mockModule.mockHost.sessionId }
        : (host as AcpmuxHostConfig);
      let connectingClient: AcpmuxDirectClient | undefined;
      acpmuxPerf.markLaunch("connectStart");
      const client = await AcpmuxDirectClient.connect(
        config,
        (next) => {
          harnessSwitch.reconcile(next);
          rowsRef.current = next.rows;
          snapshotRef.current = next;
          trustRouteSnapshot.current = next;
          observeCloudTurn(next);
          if (connectingClient)
            trustRenderedOwner.current = {
              client: connectingClient,
              generation: connectingClient.trustGeneration,
              sessionId: next.sessionId,
            };
          // What each harness reports feeds the next switch's first frame (harnessProfiles.ts).
          const summary = next.summary;
          const started = summary?.model !== undefined && startedSessions.delete(summary.sessionId);
          harnessProfiles.observe(summary, started);
          // The next New Tab page names the project used last on its first frame
          // (newtab/recentProject.ts); the mock daemon's chats are not the app's.
          if (!mock) {
            rememberRecentFolders(next);
            // Every page's New Tab lists one chat store (newtab/chatStore.ts).
            publishSessions(next);
            // The next New Tab page's first frame lists these chats (newtab/warmSnapshot.ts).
            publishWarmNewTab(
              next,
              (warm) => void postNative("newTab.warm", { warm }).catch(() => undefined),
              showsNewTabRef.current,
            );
          }
          // Only the streaming reply's text grew: its row draws it (streamingRow.ts); the pane,
          // the composer and Session Info keep the snapshot they drew.
          const drawn = drawnSnapshot.current;
          const received = receivedSnapshot.current;
          receivedSnapshot.current = next;
          const at = drawn ? streamedOnly(drawn, next) : -1;
          if (drawn && at >= 0) {
            streamingRow.set(next.rows[at]!, drawn.rows[at]!);
            return;
          }
          // Only a running command's output grew: the row that draws it reads it
          // (liveToolOutput.ts); the pane, its header and Session Info keep what they drew.
          // Not while the pane's own draw is pending (paneSnapshotLane.ts `PendingPaneDraw`).
          const call =
            drawn && received && !streamingRowBlocked() && !pendingPaneDraw.pending
              ? toolOutputOnly(received, next)
              : undefined;
          if (call) {
            liveToolOutput.set(call.id, call.output, call.before);
            return;
          }
          streamingRow.clear();
          toolOutputEpoch.current = liveToolOutput.redraw();
          // A redraw of the whole pane is a transition a key can go before, unless it answers what
          // the person just did or opens another chat (paneSnapshotLane.ts).
          const drewBefore = drawnSnapshot.current;
          drawnSnapshot.current = next;
          drawPaneSnapshot(drewBefore, next, pendingPaneDraw, () =>
            setSnapshot((previous) => {
              if (
                next.canHandoff &&
                !next.handoff?.ready &&
                next.sessionId === previous.sessionId &&
                previous.handoff?.record
              )
                return { ...next, handoff: { ...next.handoff, record: previous.handoff.record } };
              return next;
            }),
          );
        },
        () => {
          // The daemon went away. Ask Swift again: a restarted daemon has a new port and token.
          if (cancelled) return;
          reconnect = true;
          carriedChat = directClient.current?.takeCarried() ?? carriedChat;
          // A switch in flight runs again on the next client.
          harnessSwitch.disconnect(switchPort);
          setStartModeSource(undefined);
          catalogClientId.current += 1;
          directClient.current = undefined;
          delete window.cmuxAcpmuxActions;
          notifyDraftActionsChanged();
          // Until a client connects again, an open handed this page would wait for that connect.
          if (!mock) void postNative("pane.clientReady", { ready: false }).catch(() => undefined);
          // Nothing is drawn while it comes back, however long (Leo, 2026-11-22: "i dont wanna see
          // reconnecting to the Mac in a toast, i want it to just connect"): the transcript stays,
          // and a send waits and goes once it is back (sendWhenReady.ts).
          failingSince = Date.now();
          troubleSince = troubleSinceAfterLoss(troubleSince, failingSince - connectedAt, failingSince);
          setHostTroubleSince(troubleSince);
          // A client lost soon after it connected keeps the backoff growing: a daemon that drops
          // the pane right after every connect is not asked again every 250 ms. Jittered so the
          // tabs that lost one daemon together do not ask it again in lockstep.
          const lost = lostRetryDelay(retryDelay, Date.now() - connectedAt);
          retryTimer = window.setTimeout(() => void connectHost(), jitteredDelay(lost.wait));
          retryDelay = lost.next;
        },
        mockModule
          ? () => new mockModule.MockAcpmuxSocket(undefined, window.cmuxAcpmuxMockScript) as unknown as WebSocket
          : bridge
            ? () => new BridgeSocket() as unknown as WebSocket
            : undefined,
        mock ? "daemon" : "native",
        undefined,
        carriedChat,
        turnRewind !== undefined ? (state) => cloudCheckpoints.current?.observeHiddenTurn(state) : undefined,
      );
      carriedChat = undefined;
      if (cancelled) {
        client.close();
        return;
      }
      acpmuxPerf.markLaunch("connected");
      connectingClient = client;
      directClient.current = client;
      // The perf watch (perfReporter.ts): one status read on the page's first connect; off, nothing runs.
      perfReporter.attach((params) => client.perf(params));
      // The always-on frame tally (conversation/frameTally.ts): the visible chat's frame gaps, to the daemon.
      frameTally.attach((params) => client.perf(params));
      client.setFollowing(followingTranscript.current);
      // A reader scrolled far up keeps the rows in view and the screens under them (direct.ts `shedNewerHeld`).
      client.readerView = () => transcriptInView.current?.();
      client.toastSink = (text, kind) => (kind === "error" ? notices.failed(text) : notices.transient(text));
      connectedClients.connected(client);
      // connect() may have delivered its first snapshot before returning. Associate that
      // already-renderable snapshot only after the client binding exists (avoids a TDZ read).
      if (snapshotRef.current)
        trustRenderedOwner.current = {
          client,
          generation: client.trustGeneration,
          sessionId: snapshotRef.current.sessionId,
        };
      // A chat on a Cloud machine names the hand-off turn the app opens for each prompt that starts
      // one, so the machine's reports reach the hand-off (cloudHandoffTurn.ts). Mock pages have none.
      if (!mock) client.handoffTurn = handoffTurns(callNative, host);
      // Attachments too large to go inline upload at the Send, under its ticket (sendUploads.ts).
      if (!mock) client.uploadForSend = (chips, prompt) => uploadForSend(chips, prompt, callNative);
      // Prompts no agent took yet outlive the page: the app keeps them and a relaunch draws them
      // again as Not sent rows (unsentPrompts.ts).
      if (!mock) client.setUnsentPromptStore(nativeUnsentPrompts(callNative));
      setClientEpoch((epoch) => epoch + 1);
      // The minimap's prompt bookmarks live in acpmux's session (threadMinimap/bookmarks.ts).
      setBookmarkTransport({
        get: (id) => client.readBookmarks(id),
        set: (id, seq, on) => client.setBookmark(id, seq, on),
      });
      // Every trust refusal (a new chat, a resumed one, a switch, a prewarm, a prompt) shows the
      // folder's one question above the composer; Trust re-runs the refused step (cx-nn3e).
      client.onPeerSessionStarted = () => {
        if (directClient.current !== client) return;
        pendingTrustRefusal.current = undefined;
        peerTrustStarted.current?.();
      };
      client.onTrustRefused = (refusal, again, declined) => {
        if (directClient.current !== client) return;
        const shownSessionId = client.shownSession()?.sessionId;
        if (
          shownSessionId !== undefined &&
          sessionIdRef.current !== undefined &&
          shownSessionId !== sessionIdRef.current
        )
          return;
        const current = {
          client,
          generation: client.trustGeneration,
          sessionId: shownSessionId ?? sessionIdRef.current,
          cancelEpoch: trustCancelEpoch.current,
        };
        routeCurrentTrustRefusal(
          current,
          trustRouteOwner.current,
          () => trustRefused.current?.(refusal, again, declined) ?? false,
          () => {
            pendingTrustRefusal.current = { ...current, error: refusal, again, declined };
          },
        );
      };
      // Only a connected client clears the error, so a stale endpoint doesn't flicker it away.
      setHostError(undefined);
      setHostErrorShown(false);
      failingSince = undefined;
      setAcpmuxRestartOffered(false);
      catalogClientId.current += 1;
      setCatalogSource({ id: catalogClientId.current, client });
      // A refreshed harness list or live model list re-reads the catalog (no polling).
      followHarnessChanges(client, queryClient, catalogClientId.current, () => {
        if (cancelled || directClient.current !== client) return;
        void reloadModelCatalog().catch(() => undefined);
      });
      connectedAt = Date.now();
      // A mock session is not one the host can reopen.
      const persistSession = (sessionId?: string) =>
        sessionId && !mock
          ? callNative("chat.persistSession", { sessionId }).catch(() => undefined)
          : Promise.resolve();
      // A chat this client adopts later (the live-chat choice, an adopt retried after Trust).
      client.onAdopted = (sessionId) => void persistSession(sessionId);
      /// Opens a chat this one made in a tab of its own (`chat.openTab`); false when the host opens none.
      /// A mode pick on the shown chat: it holds for that chat only, never a new chat's start mode
      /// (hub/start_mode.rs; Leo 2026-10-21).
      const setMode = (modeId: string, ticket?: string) => client.setMode(modeId, ticket);
      /// `placement`: where the app opens it (AgentForkDestination: right, left, up, down,
      /// columnRight, columnLeft, row, tab, workspace, window); hand-offs explicitly retain a tab after this chat.
      const openOwnTab = (sessionId: string, placement?: string) =>
        mock ? Promise.resolve(false) : openInOwnTab(client, callNative, sessionId, placement);
      /// Settles when the turn ends. `accepted` runs once acpmux took the prompt; a sender that
      /// passes it (the composer) still holds the prompt until then, so a refusal loses nothing.
      /// Without it a refused prompt goes back into the composer.
      const send = async (
        text: string,
        attachments: import("../attachments").ComposerAttachment[] = [],
        // `sessionId`: the chat acpmux took it in, once known (a held prompt binds to it).
        accepted?: (sessionId?: string) => void,
        steer = false,
        promptId?: string,
        expectedSessionId?: string,
        // Onboarding's seeded first task: no key or click of the person's sent it.
        seeded = false,
        // A prompt the folder's trust held (trustHeld.ts): its id and its own send's ticket.
        fromTrust?: HeldSend,
        // The gesture the composer bound at this send's Enter or click while it held it.
        gesture?: SendGesture,
        // Called once acpmux took the prompt (queued too), with no hold on it: a failed turn's
        // Retry settles there, not when its turn ends (conversation/turnRetry.ts `sendUntilTaken`).
        taken?: () => void,
        // The id its row was drawn under before the chat started (startingSends.ts), when no other names it.
        drawnAs?: string,
      ) => {
        if (expectedSessionId && (directClient.current !== client || client.selectedSession !== expectedSessionId))
          throw startCancelled();
        // The reader sent it: by default the transcript goes to its latest message now, even
        // scrolled up. With the preference off, only a reader already at the latest row follows;
        // an up-scroll keeps its row and offset while this prompt and its reply arrive below.
        if (shouldScrollToBottomAfterSend(scrollToBottomOnSendRef.current, followingTranscript.current)) {
          setSends((count) => count + 1);
        }
        // WEB-SWAP: until the client holds the prompt (its own `swapHold`), only this call does.
        untakenSends.current += 1;
        let counted = true;
        const handedOn = () => {
          if (counted) untakenSends.current -= 1;
          counted = false;
        };
        try {
          return await sendThrough(
            text,
            attachments,
            accepted,
            steer,
            promptId ?? fromTrust?.promptId,
            handedOn,
            expectedSessionId,
            seeded,
            fromTrust,
            gesture,
            taken,
            drawnAs,
          );
        } finally {
          handedOn();
        }
      };
      /// The chat a trust refusal belongs to: the client, its selection generation and the session.
      type TrustOwner = TrustRefusalOwner<AcpmuxDirectClient>;
      // A trust refusal belongs to the request's selection and cancellation epoch.
      const routeTrustFor = (owner: TrustOwner, error: unknown, again?: () => void, declined?: () => void): boolean => {
        if (!isTrustRefusal(error)) return false;
        return routeOwnedTrustRefusal(
          owner,
          {
            client: directClient.current,
            generation: owner.client.trustGeneration,
            sessionId: owner.client.selectedSession,
            cancelEpoch: trustCancelEpoch.current,
          },
          trustRouteOwner.current,
          pendingTrustRefusal,
          error,
          again,
          () => trustRefused.current?.(error, again, declined) ?? false,
          declined,
        );
      };
      // A failed row's Retry that acpmux refuses for the folder's trust shows the Trust question,
      // and Trust re-sends the row's run with the gesture the refused retry kept (heldPrompt.ts),
      // as a refused send's row does (failedRowTrustRetry.ts).
      const rowRetry = failedRowTrustRetry({
        retry: (rowIds, ticket, anchor) => client.retryPrompts(rowIds, ticket, anchor),
        runOf: (row) => lastFailedRuns.current?.get(row)?.rowIds ?? [row],
        hold: (row) => void heldRowPrompt.hold(client.promptDelivery(row)?.promptId),
        takeTicket: () => heldRowPrompt.take()?.ticket,
        copy: (rowIds) => client.failedPromptCopies(rowIds),
        restore: (copies) => client.restoreFailedPrompts(copies),
      });
      const sendThrough = async (
        text: string,
        attachments: import("../attachments").ComposerAttachment[],
        accepted: ((sessionId?: string) => void) | undefined,
        steer: boolean,
        promptId: string | undefined,
        handedOn: () => void,
        expectedSessionId?: string,
        seeded = false,
        fromTrust?: HeldSend,
        gesture?: SendGesture,
        taken?: () => void,
        drawnAs?: string,
      ) => {
        // The chat it is sent in; once a start made the chat's session, that session (trustHeld.ts).
        let sentFrom = shownFrom.current();
        // A New Tab send may create/select its session inside ensureSession. Route a refusal by
        // the client's current selection generation rather than a render-time hook closure:
        // ensureSession can select before React has rendered the new chat.
        let sendOwner: TrustOwner = {
          client,
          generation: client.trustGeneration,
          sessionId: client.shownSession()?.sessionId ?? sessionIdRef.current,
          cancelEpoch: trustCancelEpoch.current,
        };
        // `again` may be absent: a held prompt the hold puts back runs no step after Trust.
        const routeForSend = (error: unknown, again?: () => void, declined?: () => void): boolean =>
          routeTrustFor(sendOwner, error, again, declined);
        // acpmux holds the prompt while the folder's trust question is open (on session/new
        // or session/prompt): the question shows for the folder acpmux named, and Trust sends
        // the prompt the composer kept. `inComposer`: the composer still holds the prompt (or got it back); else it goes back.
        const refused = (error: unknown, inComposer: boolean): never => {
          // A harness switch handed it back to the composer; Trust runs that switch again with its
          // prompts (`resumeAfterTrust`, the step its start's refusal kept), so that step stays.
          const handedBack = (error as { handedBack?: unknown } | null)?.handedBack === true;
          if (isTrustRefusal(error)) {
            // A prompt kept as its own failed row: Trust sends that row again (with the gesture its
            // send kept, under its own prompt id), never what the composer holds by then.
            const row = failedRowOf(error);
            // The send's own gesture is kept for this prompt now, before the Trust click, whose
            // gesture goes to the trust answer (heldPrompt.ts).
            if (row) {
              // After Trust, the row's whole run goes again, as its card's Retry sends it.
              rowRetry.replayAfterTrust(error, routeForSend);
            } else if (fromTrust) {
              // A prompt the folder's trust held is the hold's to put back (trustHeld.ts): only the
              // question shows, and no step a refused start kept runs after Trust.
              routeForSend(error, handedBack ? undefined : heldGoesAfterTrust);
            } else if (!handedBack && !(newTabRetainsDraft.current && expectedSessionId)) {
              // It joins the hold of the chat it was sent in (trustHeld.ts) and goes, in order,
              // after Trust, with this send's gesture; the composer lets it go (`heldRefusals`).
              if (routeForSend(error, heldGoesAfterTrust)) holdRefused.current(text, attachments, error, sentFrom);
            } else {
              const retry =
                newTabRetainsDraft.current && expectedSessionId
                  ? () =>
                      void send(text, attachments, accepted, steer, promptId, expectedSessionId).catch(() => undefined)
                  : () => composerHandle.current?.send();
              if (routeForSend(error, retry)) {
                void heldPrompt.hold();
                if (!newTabRetainsDraft.current && !inComposer) restorePrompt(text, attachments);
              }
            }
          }
          throw error;
        };
        const ownsSession = () =>
          !expectedSessionId || (directClient.current === client && client.selectedSession === expectedSessionId);
        if (!ownsSession()) throw startCancelled();
        // A harness switch holds the prompt in its own row until its session is ready, and
        // hands it back to the composer when the switch fails.
        const switchPromptId = promptId ?? gesture?.promptId ?? drawnAs ?? crypto.randomUUID();
        // Only the person's own send, not one with a seeded prompt's own id (its host ticket is bound
        // to it), keeps its gesture for a prompt held behind a slow start (#23031).
        // A prompt the folder's trust held keeps its id and its send's ticket there too, and is
        // taken once the switch wrote it, in the session the switch started: the hold's other
        // prompts of that new chat follow it there (trustHeld.ts).
        if (fromTrust?.ticket) trustTickets.set(fromTrust.promptId, fromTrust.ticket);
        const held = harnessSwitch.send(
          text,
          attachments,
          fromTrust ? () => accepted?.() : undefined,
          switchPromptId,
          !seeded && promptId === undefined,
          // A send the composer held for its files goes with the ticket its Enter bound.
          gesture?.promptId === switchPromptId ? gesture.ticket : undefined,
        );
        if (!held && fromTrust) trustTickets.delete(fromTrust.promptId);
        if (held) {
          if (!fromTrust) accepted?.();
          return held.then(
            (value) => {
              switchSendOwners.delete(switchPromptId);
              return value;
            },
            (error: unknown) => {
              // The switch selected its chat before it sent this prompt: a refusal of the send
              // belongs to that selection (its Trust re-sends the prompt with this send's gesture).
              const owner = switchSendOwners.get(switchPromptId);
              switchSendOwners.delete(switchPromptId);
              if (owner) sendOwner = owner;
              return refused(error, (error as { handedBack?: unknown }).handedBack === true);
            },
          );
        }
        // A prompt acpmux held goes with the gesture its first send kept. Otherwise bind this
        // send before waiting for chat creation and persistence; rapid Enters each get its own
        // host ticket instead of sharing the one checked when the relay finally drains.
        const sendPromptId = promptId ?? switchPromptId;
        // One the folder's trust held (trustHeld.ts) goes with its own send's ticket.
        // A send the composer held for its files goes with the gesture of its own Enter or click.
        const heldForTrust = fromTrust ?? gesture ?? heldPrompt.take();
        const kept = heldForTrust ?? (client.selectedSession ? client.bindSendGesture(sendPromptId) : undefined);
        // A chat that starts while acpmux starts or reconnects waits for it (sendWhenReady.ts): the
        // composer keeps the prompt and says "Sending when ready"; only past the deadline is the
        // send refused, as before.
        // A retry belongs to the chat selected at the send: once another chat is selected, the
        // next try would send this prompt there, so it stops and fails as before.
        let unhold: (() => void) | undefined;
        const movedOn = heldStartStop(client);
        const started = client.startedSession;
        // The agent this send starts, read before another chat can be selected.
        const startHarness = client.shownSession()?.harness ?? client.startHarness;
        const sessionId = await untilHostAnswers(() => client.ensureSession(), {
          stop: () => movedOn() || !ownsSession(),
          waiting: () => {
            unhold ??= sendsHeldForHost.hold();
          },
        })
          .finally(() => unhold?.())
          .catch((error: unknown) => {
            // A folder harness that waits for Enable or Trust says so on its own card.
            const block = harnessBlock(error);
            setBlockedHarness(block);
            // A refused start (a chat on another machine, cx-k21v) says why in this page's own
            // view: the host's typed refusal, already localized, under the localized "Not sent".
            if (isStartRefusal(error)) client.notice(failedSendText(error, false));
            // Any other failed start says why too, and its cause goes to the log (#44964). Not when
            // its card says it (Enable, Trust), it was cancelled, or another chat was selected while
            // it was out (`superseded`): the notice would land in that chat.
            else if (!block && !isTrustRefusal(error) && !isStartCancelled(error) && !isStartSuperseded(error)) {
              const line = startFailureNotice(translate, startHarness, error);
              if (line) client.notice(line);
            }
            return refused(error, Boolean(accepted));
          });

        // ensureSession may intentionally create/select the New Tab's first chat. Transfer the
        // send owner only after that successful handoff; a later navigation must not rewrite it.
        sendOwner = {
          client,
          generation: client.trustGeneration,
          sessionId: sessionId ?? client.shownSession()?.sessionId,
          // Creating the first session must not renew a canceled send's intent.
          cancelEpoch: sendOwner.cancelEpoch,
        };
        if (sessionId) sentFrom = { ...sentFrom, chat: sessionId };
        if (!ownsSession()) throw startCancelled();
        // A chat this send started is the tab's before its prompt goes. A started one already is:
        // its prompt goes in this task, so a prompt behind the turn draws as its queued row in the
        // frame the composer clears, never a native round trip later (Leo, 2026-11-11: "you sending
        // a message while I have things queued up, like that sort of slow growth is just... it gives
        // me the heebie-jeebies to look at").
        if (sessionId && sessionId === started) void persistSession(sessionId);
        else await persistSession(sessionId);
        if (!ownsSession()) throw startCancelled();
        if (client.trustGeneration !== sendOwner.generation || client.selectedSession !== sendOwner.sessionId) {
          if (!accepted) restorePrompt(text, attachments);
          throw new Error("agent_session.changed_during_send");
        }

        // A New Tab's session/new consumes the gesture into the transport's start credit. Reserve
        // the prompt ticket only after that start has succeeded; an existing chat reserved above.
        const sendTicket = kept !== undefined ? kept.ticket : client.bindSendGesture(sendPromptId)?.ticket;

        // A Quick Composer handoff can close this page only after acpmux takes the prompt.
        // Releasing a local queued row happens earlier, while its gesture may still be pending.
        const turn = client
          .send(
            text,
            attachments,
            kept?.promptId ?? sendPromptId,
            accepted && (() => accepted(sessionId)),
            sendTicket,
            steer,
            () => {
              promptLanded.current();
              taken?.();
            },
          )
          .catch((error: unknown) => refused(error, Boolean(accepted)));
        // The client counts it from here (it registers the send before its first wait).
        handedOn();
        return turn;
      };
      let sendAgainPending = false;
      const runInterruptedResume = interruptedResumeRunner({
        read: () => {
          const state = readInterruptedResume();
          return { ...state, canResume: state.canResume && directClient.current === client };
        },
        bind: () => client.bindSendGesture(),
        emptyTurn: (owner, promptId, ticket, current) => client.resumeInterrupted(owner, promptId, ticket, current),
        textTurn: (owner, gesture) =>
          send(CONTINUE_PROMPT, [], undefined, false, gesture.promptId, owner, false, undefined, gesture),
      });
      window.cmuxAcpmuxActions = {
        // `accepted` (in-page only): the composer holds the prompt until acpmux takes it.
        // `fromTrust` (in-page only): a prompt the folder's trust held, with its id and ticket.
        // `gesture` (in-page only): the gesture the composer bound at the Enter of a send it held.
        // `taken` (in-page only): called once acpmux took the prompt; unlike `accepted` it holds
        // nothing, so a refusal still fails or restores the prompt as any send's does.
        // `drawnAs` (in-page only): the prompt id a new chat's first prompt was drawn under from its
        // send (startingSends.ts `withStartingPrompt`), so the chat's row for it is that same row.
        "chat.send": ({ text, attachments, accepted, steer, expectedSessionId, fromTrust, gesture, taken, drawnAs }) =>
          send(
            String(text ?? ""),
            Array.isArray(attachments) ? attachments : [],
            typeof accepted === "function" ? (accepted as (sessionId?: string) => void) : undefined,
            steer === true,
            undefined,
            typeof expectedSessionId === "string" ? expectedSessionId : undefined,
            false,
            heldPromptParams(fromTrust),
            sendGestureParam(gesture),
            typeof taken === "function" ? (taken as () => void) : undefined,
            typeof drawnAs === "string" ? drawnAs : undefined,
          ),
        "chat.resumeInterrupted": async ({ sessionId, rowId }) => {
          if (typeof sessionId !== "string" || typeof rowId !== "string") return false;
          try {
            return await runInterruptedResume({ sessionId, rowId });
          } catch (error) {
            if ((error as { taken?: unknown } | null)?.taken === true) return true;
            if (directClient.current === client && client.selectedSession === sessionId)
              client.notice(failedSendText(error, false));
            return false;
          }
        },
        "chat.cancel": () => client.cancel(),
        "chat.planScopeDrift": ({ action, sessionId, path, area }) => {
          const id = typeof sessionId === "string" ? sessionId : undefined;
          if (!id || id !== client.selectedSession) return Promise.resolve(false);
          if (action === "keepGoing") {
            keepPlanScopeArea(id, typeof area === "string" ? area : "");
            return Promise.resolve(true);
          }
          dismissPlanScopeDrift(id);
          if (action === "stop") return client.cancel().then(() => true);
          return send(
            typeof path === "string"
              ? translate("planScopeDrift.replanPrompt", { path })
              : translate("planScopeDrift.replanPromptNoPath"),
            [],
            undefined,
            true,
            undefined,
            id,
          ).then(() => true);
        },
        "chat.typing": async ({ text, sessionId }) =>
          client.typing(typeof text === "string" ? text : "", typeof sessionId === "string" ? sessionId : undefined),
        "chat.queue.remove": ({ promptId }) => client.removeQueued(String(promptId)),
        "chat.queue.approve": ({ promptId, revision }) =>
          client.answerHeld(String(promptId), true, typeof revision === "number" ? revision : 0),
        "chat.queue.decline": ({ promptId }) => client.answerHeld(String(promptId), false),
        "chat.agentPair.resume": ({ peer }) => client.resumeAgentPair(String(peer)),
        "chat.queue.edit": ({ promptId, ...edit }) => client.editQueued(String(promptId), edit as QueueEdit),
        "chat.secret": ({ secretId, value }) =>
          client.secret(String(secretId), typeof value === "string" ? value : undefined),
        "chat.permission": ({ permissionId, optionId, answers, annotations, sessionId }) =>
          client.permission(
            String(permissionId),
            optionId === undefined || optionId === null ? undefined : String(optionId),
            answers && typeof answers === "object" ? (answers as Record<string, unknown>) : undefined,
            // The Needs you list answers asks of other chats too.
            typeof sessionId === "string" && sessionId ? sessionId : undefined,
            annotations && typeof annotations === "object" ? (annotations as Record<string, unknown>) : undefined,
          ),
        "chat.plan.build": ({ permissionId, target, sessionId }) =>
          client.planBuild(
            String(permissionId),
            planBuildTarget(target),
            typeof sessionId === "string" && sessionId ? sessionId : undefined,
          ),
        "chat.plan.compare": ({ buildId, sessionId }) =>
          client.planCompare(String(buildId), typeof sessionId === "string" && sessionId ? sessionId : undefined),
        "chat.plan.keep": ({ buildId, keep, sessionId }) =>
          client.planKeep(
            String(buildId),
            String(keep),
            typeof sessionId === "string" && sessionId ? sessionId : undefined,
          ),
        "chat.permission_group.respond": ({ groupId, revision, decision }) =>
          client.permissionGroup(String(groupId), Number(revision), decision as PermissionDecision),
        "chat.permission_group.retry": () => client.permissions.retry(),
        "chat.permission_chat.revoke": () => client.permissions.revoke(),
        "chat.permission_groups.refresh": () => client.permissions.refresh(),
        // A model, mode or effort picked while a harness starts waits for its session; a model
        // picked in a live session draws at once (harnessSwitch.ts).
        "chat.model": ({ modelId, expectedSessionId }) => {
          const summary = snapshotRef.current?.summary;
          if (!configurationSessionMatches(expectedSessionId, summary?.sessionId))
            // l10n-allow: a refusal for the host action's caller, which drops a stale pick; never shown.
            throw new Error("the agent chat session changed");
          // A failed Cloud start's pick covers a chat with no session and no switch (its agent lives only in that
          // start): a model of the same agent picked there starts that agent's chat on it, as picking the agent
          // does, so the pick replaces the failed start's and goes with Retry (#46874 review).
          const failedPick = shownCloudStartPickNow();
          if (!summary?.sessionId && !snapshotRef.current?.switching && failedPick)
            return harnessSwitch.switchTo(failedPick.harness, undefined, { model: String(modelId) });
          return harnessSwitch.pickModel(
            String(modelId),
            summary?.sessionId ? { sessionId: summary.sessionId, model: summary.model } : undefined,
          );
        },
        "chat.mode": async ({ modeId, expectedSessionId }) => {
          const sessionId = snapshotRef.current?.summary?.sessionId;
          if (!configurationSessionMatches(expectedSessionId, sessionId))
            // l10n-allow: a refusal for the host action's caller, which drops a stale pick; never shown.
            throw new Error("the agent chat session changed");
          if (harnessSwitch.pickMode(String(modeId))) return;
          // A Cloud or other remote machine's chat starts with its first send: a pick before that
          // is held, with its gesture taken now, and the send's new session takes it first.
          if (!sessionId && client.startsOnSend) {
            const ticket = postNative<{ ticket?: string }>("transport.gesture", {
              intent: { method: "session/set_mode", params: { modeId: String(modeId) } },
            }).then((reply) => reply?.ticket);
            ticket.catch(() => undefined);
            client.holdStartMode(String(modeId), ticket);
            return;
          }
          await setMode(String(modeId));
        },
        "chat.effort": (params) =>
          pickEffort(params, {
            summary: snapshotRef.current?.summary,
            switch: harnessSwitch,
            setConfig: (id, value) => client.setConfig(id, value),
          }),
        // A switch that is likely next (a hover over a chat's row in the host's lists): its newest
        // page is read now, so the switch draws it from memory (direct.ts `prefetch`).
        // `hover`: the native sidebar's pointer is on that chat's row (no sessionId: on none). The
        // page decides whether it rests there long enough to read (hoverPrefetch.ts).
        "chat.prefetch": async ({ sessionId, sessionIds, hover, lowPower }) => {
          if (hover === true) {
            client.hoverPrefetch(typeof sessionId === "string" && sessionId ? sessionId : undefined, {
              lowPower: lowPower === true,
            });
            return;
          }
          const ids = Array.isArray(sessionIds) ? sessionIds : [sessionId];
          for (const id of ids) if (id) client.prefetch(String(id));
        },
        // The host's spare page taking a tab's chat (adoptSession, above): opened as a pick is.
        "chat.adopt": async ({ sessionId }) => {
          newTabStartGeneration.current += 1;
          harnessSwitch.cancel();
          const leaving = newChatLeftover.current();
          const selected = await client.adoptSession(String(sessionId)).catch((error: unknown) => {
            leaving?.cancel();
            throw error;
          });
          if (!selected || client.attachedSession() !== selected) {
            leaving?.cancel();
            return undefined;
          }
          // Posted before the pick's own, with no wait between: a later pick still persists last.
          leaving?.leave();
          await persistSession(selected);
          return selected;
        },
        "chat.select": async ({ sessionId }) => {
          newTabStartGeneration.current += 1;
          harnessSwitch.cancel();
          const leaving = newChatLeftover.current();
          const selected = await client.select(String(sessionId)).catch((error: unknown) => {
            leaving?.cancel();
            throw error;
          });
          if (!selected || client.attachedSession() !== selected) {
            leaving?.cancel();
            return undefined;
          }
          // Posted before the pick's own, with no wait between: a later pick still persists last.
          leaving?.leave();
          await persistSession(selected);
          return selected;
        },
        // A pick of another harness is a switch: drawn now, started behind it.
        // A new chat without a folder starts in the chat's start folder (startFolder.tsx);
        // a chat with no project (`noProject`) or for a peer gets no start folder.
        "chat.new": async ({
          harness,
          cwd,
          peer,
          deferred,
          noProject,
          model,
          options,
          continueWithoutFolder,
          continueReadOnly,
        }) => {
          const readOnly = continueReadOnly === true;
          if ((noProject === true && continueWithoutFolder === true) || readOnly) {
            let generation = client.trustGeneration;
            const trustGeneration = trustRevision.current;
            const projectGeneration = continuationProjectGeneration.current;
            const holder = composerHandle.current;
            const summary = snapshotRef.current?.summary;
            const intent = switchViewRef.current.intent;
            const selectedHarness = intent?.harness ?? summary?.harness;
            const selectedModel = intent?.config.model ?? summary?.model;
            // Read-only stays in the declined folder (acpmux hub/restricted.rs); else no folder.
            const readOnlyFolder = readOnly && typeof summary?.cwd === "string" ? summary.cwd : undefined;
            if (readOnly && !readOnlyFolder) return;
            // A pending harness switch may still hold prompts behind this folder's trust gate.
            // Recovery is a different start, so retire that intent before taking the draft.
            harnessSwitch.cancel();
            return folderContinuation.run({
              start: () =>
                readOnlyFolder
                  ? client.startSession(
                      selectedHarness,
                      readOnlyFolder,
                      undefined,
                      undefined,
                      false,
                      selectedModel,
                      undefined,
                      true,
                    )
                  : client.startSession(selectedHarness, undefined, undefined, undefined, true, selectedModel),
              current: () =>
                directClient.current === client &&
                client.trustGeneration === generation &&
                trustRevision.current === trustGeneration &&
                composerHandle.current === holder,
              copyText: (id) => writePersistedDraft(id, holder?.draftText() ?? ""),
              clearFolder: () => {
                if (!readOnlyFolder) setProjectDraft(undefined);
              },
              discard: (id) => client.discard(id),
              select: async (id) => {
                holder?.suppressAttachmentCarryFor(summary?.sessionId);
                try {
                  // select advances the visit synchronously. Adopt only this operation's
                  // bump before awaiting it, so any later navigation still invalidates us.
                  const selection = client.select(id);
                  generation = client.trustGeneration;
                  const selected = await selection;
                  if (
                    selected !== id ||
                    client.selectedSession !== id ||
                    directClient.current !== client ||
                    continuationProjectGeneration.current !== projectGeneration
                  ) {
                    holder?.clearAttachmentCarrySuppression();
                    return false;
                  }
                  void persistSession(selected);
                  return true;
                } catch {
                  holder?.clearAttachmentCarrySuppression();
                  return false;
                }
              },
            });
          }
          folderContinuation.invalidate();
          // One rule for every agent and every caller (startFolderModel newChatFolder): the folder the
          // caller names unless it is only the tab's inherited one, else the start folder; a new chat
          // with neither has none (`null`), never an earlier start's folder.
          const chosen =
            peer || noProject === true
              ? cwd
                ? String(cwd)
                : undefined
              : newChatFolder({
                  ...(cwd ? { cwd: String(cwd) } : {}),
                  inherited: inheritedFolderRef.current,
                  startFolder: startFolderRef.current,
                  fresh: freshRef.current,
                });
          const folder = chosen ?? undefined;
          if (harness && !peer && noProject !== true) {
            // A new chat starts on its pick, else on acpmux's saved default, else on the model last
            // picked on that harness here. acpmux sets its start model itself (start_defaults.rs):
            // that one is not sent again.
            const start = catalogRef.current.find((entry) => entry.id === String(harness))?.start;
            const asked = model
              ? String(model)
              : start?.modelSource === "saved" || start?.modelSource === "profile"
                ? undefined
                : lastOfferedModel(String(harness), catalogRef.current, folder);
            const picked = asked && asked !== start?.model ? asked : undefined;
            // A typed combo's effort and Fast (ComposerPickers `combo`), held for the new session.
            const held =
              options && typeof options === "object"
                ? Object.fromEntries(
                    Object.entries(options as Record<string, unknown>).filter(
                      (entry): entry is [string, string] => typeof entry[1] === "string",
                    ),
                  )
                : {};
            return harnessSwitch.switchTo(String(harness), chosen, {
              deferred: deferred === true,
              ...(picked ? { model: picked } : {}),
              ...(Object.keys(held).length > 0 ? { options: held } : {}),
            });
          }
          harnessSwitch.cancel();
          // Resolves to the chat it started (none: nothing started), so a caller can hold a prompt.
          const started = await client.create(
            harness ? String(harness) : undefined,
            folder,
            peer ? String(peer) : undefined,
            noProject === true,
            peer && model ? String(model) : undefined,
            newTabRetainsDraft.current,
          );
          await persistSession(started);
          return started;
        },
        "chat.fix_from_link": async ({ url, cwd, harness, model }) => {
          const sessionId = await client.fixFromLink(
            String(url ?? ""),
            typeof cwd === "string" ? cwd : undefined,
            typeof harness === "string" ? harness : undefined,
            typeof model === "string" ? model : undefined,
          );
          await persistSession(sessionId);
          return { sessionId };
        },
        "chat.harness.hint": async ({ harness }) => harnessSwitch.hint(harness ? String(harness) : undefined),
        "chat.harness.retry": async () => harnessSwitch.retry(),
        // The catalog acpmux uses, for a host that does not serve `models.catalog`
        // (modelCatalogHost.ts): a model the feed lists today shows without a page update.
        "models.catalog": async ({ refresh }) => client.modelCatalog(refresh === true),
        // The picker's Refresh models: acpmux probes every agent again, then the catalog re-reads.
        "models.refresh": async () => {
          try {
            await client.refreshModels();
          } finally {
            // A refused or failed probe still re-reads what acpmux has.
            await queryClient.invalidateQueries({ queryKey: ["acpmux", "harnesses"] });
          }
        },
        // Enables a folder profile, then starts the chat on it. The request goes out before any
        // await, inside the click or key handler that called this: the host's confirmation
        // takes that gesture. A Cancel there (`transport.harness_not_confirmed`) changes nothing;
        // acpmux refusing the prompt shows its reason (cx-cuk4); acpmux giving none (down, too
        // slow) says so (cx-nt39g).
        "chat.harness.enable": ({ folder, id }) =>
          client.harnessEnable(String(folder), String(id)).then(
            async (result) => {
              setBlockedHarness(undefined);
              await queryClient.invalidateQueries({ queryKey: ["acpmux", "harnesses"] });
              void harnessSwitch.switchTo(String(id));
              return result;
            },
            (error: unknown) => {
              const refused = error as {
                code?: unknown;
                detail?: unknown;
                reason?: unknown;
              } | null;
              // A Cancel there changes nothing. Any refusal reads as one plain line with its way
              // on (Try again); acpmux's reason (no Trust answer, an invalid file) goes to the log.
              if (refused?.code === "transport.harness_not_confirmed") return undefined;
              console.warn("agent pane: enabling the harness was refused", refused?.detail ?? error);
              notices.failed(translate("harnesses.enableUnavailable"));
              return undefined;
            },
          ),
        "chat.harness.cancelPrompt": async ({ promptId }) => harnessSwitch.cancelQueued(String(promptId)),
        // A failure card acts on its run of prompts (`rowIds`, in order; sendFailure.ts), else on `rowId`.
        // Retry sends the run again as one prompt: one click is one gesture (direct.ts `retryPrompts`).
        "chat.retryPrompt": ({ rowId, rowIds }) => {
          // The retry belongs to the chat it was clicked in: a trust refusal goes to that chat's
          // question, whose Trust sends the run again (no second manual Retry).
          const owner: TrustOwner = {
            client,
            generation: client.trustGeneration,
            sessionId: client.shownSession()?.sessionId ?? sessionIdRef.current,
            cancelEpoch: trustCancelEpoch.current,
          };
          return retryAfterTrust.current(() =>
            rowRetry.retry(failedRowIds(rowId, rowIds), (error, again) => routeTrustFor(owner, error, again)),
          );
        },
        // Edit on prompts that did not get there: their rows go and the prompts come back to the
        // composer as one, in order, ahead of what is typed there now.
        "chat.editFailedPrompt": async ({ rowId, rowIds }) => {
          const taken = failedRowIds(rowId, rowIds).flatMap((id) => client.takeFailedPrompt(id) ?? []);
          if (!taken.length) return;
          composerHandle.current?.restore(
            taken.map((failed) => failed.input).join("\n\n"),
            taken.flatMap((failed) => failed.attachments),
          );
        },
        "chat.recap.dismiss": async ({ rowId, key }) => client.dismissRecap(String(rowId), String(key)),
        // The prompt coach card's × (conversation/PromptCoachCard.tsx).
        "chat.coach.dismiss": async ({ rowId, sessionId }) =>
          client.dismissPromptCoach(String(rowId), String(sessionId)),
        // Accept or Dismiss on a memory offer's facts (conversation/MemoryOfferCard.tsx).
        "chat.memory.resolve": async ({ offerId, accept, dismiss }) =>
          client.resolveMemory(
            String(offerId),
            Array.isArray(accept) ? accept.map(String) : [],
            Array.isArray(dismiss) ? dismiss.map(String) : [],
          ),
        // Approve or Not now on a no-prompt preset's card (conversation/PresetApprovalCard.tsx).
        "chat.presetApproval.answer": async ({ rowId, approve }) =>
          client.answerPresetApproval(String(rowId), approve === true),
        "chat.removeFailedPrompt": async ({ rowId, rowIds }) => {
          for (const id of failedRowIds(rowId, rowIds)) client.removeFailedPrompt(id);
        },
        "chat.sendPromptAgain": async ({ sessionId, rowId, model }) => {
          if (
            sendAgainPending ||
            typeof sessionId !== "string" ||
            typeof rowId !== "string" ||
            (model !== undefined && typeof model !== "string")
          )
            return false;
          sendAgainPending = true;
          try {
            return await sendPromptAgain(
              { sessionId, rowId, ...(model !== undefined ? { model } : {}) },
              {
                read: () => {
                  const state = readSendAgain();
                  return { ...state, canSend: state.canSend && directClient.current === client };
                },
                pickModel: (model, sessionId, currentModel) =>
                  harnessSwitch.pickModel(model, { sessionId, model: currentModel }),
                restore: (promptId, prompt) => client.resendPrompt(promptId, prompt),
                send: (draft, owner) =>
                  sendUntilTaken((taken) =>
                    send(
                      draft.input,
                      draft.attachments,
                      undefined,
                      false,
                      undefined,
                      owner,
                      false,
                      undefined,
                      undefined,
                      taken,
                    ),
                  ),
              },
            );
          } finally {
            sendAgainPending = false;
          }
        },
        // Retry with another model (cx-ncc.62): the chat moves to the model as the picker moves it,
        // then the prompt goes again with its attachments. A refused move sends nothing (its notice
        // says why), so the retry never runs on the old model.
        "chat.retryWith": async ({ rowId, prompt, model }) => {
          const summary = snapshotRef.current?.summary;
          const next = String(model ?? "");
          if (summary?.model !== next) {
            const live = summary?.sessionId ? { sessionId: summary.sessionId, model: summary.model } : undefined;
            if (!(await harnessSwitch.pickModel(next, live))) return;
          }
          const draft = await client.resendPrompt(String(rowId ?? ""), String(prompt ?? ""));
          await send(draft.input, draft.attachments);
        },
        // Edit and Resend (the message menu): the prompt goes back into the composer, before
        // anything typed since, with the caret in it.
        "chat.editPrompt": async ({ text }) => {
          restorePrompt(String(text ?? ""), []);
          focusComposer();
        },
        // Quote in Reply (the transcript selection menu): the Markdown quote goes after the
        // draft, which stays as typed, and the caret waits in an empty paragraph below it. With no
        // composer mounted (a Sandboxed receipt shows), it waits for the composer to come back.
        "chat.quoteReply": async ({ markdown }) => {
          quoteReply(String(markdown ?? ""));
        },
        // Selected transcript text can be attached as a context chip without changing the
        // draft text. The rail/menu owns only the gesture; the composer owns chip rendering.
        "chat.attachSelection": async ({ text }) => {
          const attachment = transcriptSelectionAttachment(String(text ?? ""));
          if (!attachment) return;
          composerHandle.current?.attach(attachment);
          focusComposer();
        },
        // Pin as chapter is the native menu's named rail action. Marking true is idempotent:
        // the bookmark transport publishes the resulting tick to every rail on this session.
        "chat.pinChapter": async ({ rowId, sessionId }) => {
          const match = /^(?:user|summary)-(\d+)$/.exec(String(rowId ?? ""));
          const seq = match ? Number(match[1]) : NaN;
          const requestedSessionId = typeof sessionId === "string" ? sessionId : "";
          // The native menu can outlive the transcript that opened it. Require both the client
          // selection and the drawn snapshot to still name the target session before touching
          // the rail; a stale menu after switching chats must be a no-op.
          if (
            !messageMenuSessionMatches(requestedSessionId, client.selectedSession, snapshotRef.current?.sessionId) ||
            !Number.isSafeInteger(seq) ||
            seq <= 0
          )
            return;
          await client.setBookmark(requestedSessionId, seq, true);
        },
        "chat.history": () => client.loadOlder(),
        // Find in Chat (the app's Find commands on an agent pane).
        "chat.find": async ({ text }) => findRef.current?.show(typeof text === "string" ? text : undefined),
        "chat.findNext": async () => findRef.current?.next(),
        "chat.findPrevious": async () => findRef.current?.previous(),
        "chat.hideFind": async () => findRef.current?.hide(),
        // Composer drafts belong to the daemon session so every host can restore them.
        "chat.readDraft": ({ sessionId }) => client.readDraft(String(sessionId)),
        "chat.writeDraft": ({ sessionId, text }) => client.writeDraft(String(sessionId), String(text ?? "")),
        "acp.trust.get": ({ cwd }) => client.trustGet(String(cwd)),
        "acp.trust.set": ({ cwd, level }) => client.trustSet(String(cwd), String(level)),
        "file.search": ({ path, query, limit }) =>
          client.fileSearch(
            typeof path === "string" ? path : undefined,
            String(query ?? ""),
            typeof limit === "number" ? limit : FILE_SEARCH_LIMIT,
          ),
        // The chat the choice leads to is kept as the tab's by `onAdopted`, only while it is shown.
        "chat.adoptLive": async ({ choice }) => {
          await client.adoptLive(choice === "fork" ? "fork" : "open");
        },
        // The native context menu's Open Image: the image the page reported under the pointer.
        "chat.menu.openImage": async () => openReportedImage(),
        // Its Copy Image, Save Image As…, Quick Look and Show in Finder: the reported image to the host.
        "chat.menu.copyImage": () => actOnReportedImage("image.copy"),
        "chat.menu.saveImage": () => actOnReportedImage("image.save"),
        "chat.menu.quickLookImage": () => actOnReportedImage("image.quickLook"),
        "chat.menu.revealImage": () => actOnReportedImage("image.reveal"),
        // Its Open on a path: the path chip's open, which the host checks again (link.openPath).
        "chat.menu.openPath": ({ path }) => callChipHost("link.openPath", { path: String(path ?? "") }),
        // A fork and a started Continue In… open in a tab of their own, so the chat keeps its tab
        // and stays in the sidebar (Leo 2026-10-13). A host that opens none (an older app, the
        // floating chat) gets the new chat in this tab, as before.
        "chat.fork": async ({ throughSeq, placement }) => {
          harnessSwitch.cancel();
          const chat = client.selectedSession;
          const forked = await client.fork(Number(throughSeq), undefined, true);
          return openFork(forked, chat, placement, {
            open: openOwnTab,
            selected: () => client.selectedSession,
            select: (id) => client.select(id),
            persist: persistSession,
            focus: () => focusComposer(),
          });
        },
        // Fork Conversation from the app (the palette's step, the chat's right-click menu, its
        // shortcut): a fork through the chat's latest finished turn, or of a working chat as it is
        // now, opened where the app names (`placement`). A chat that cannot fork says why in a
        // toast (paneToasts.ts).
        "chat.forkTo": async ({ placement }) => {
          const shown = snapshotRef.current;
          const refusal = shown ? forkRefusal(shown) : "unavailable";
          const target = shown ? forkToTarget(shown) : undefined;
          if (refusal || target === undefined) {
            if (refusal === "nothingYet") notices.transient(translate("notice.forkNothingYet"));
            else notices.failed(translate("notice.forkFailed"));
            return undefined;
          }
          harnessSwitch.cancel();
          const chat = client.selectedSession;
          // A working chat forks now, as it is; its own turn goes on (acpmux `hub/fork.rs`).
          const forked = await client.fork("live" in target ? "live" : target.throughSeq, undefined, true);
          return openFork(forked, chat, placement, {
            open: openOwnTab,
            selected: () => client.selectedSession,
            select: (id) => client.select(id),
            persist: persistSession,
            focus: () => focusComposer(),
          });
        },
        // Cloud's Try another approach is native-owned: it snapshots the current machine,
        // then asks the child acpmux to fork its latest transcript before opening a sibling.
        // postNative, never callNative: callNative would pick this same page action again.
        "chat.tryAnotherApproach": async ({ throughSeq }) => {
          if (!cloudMachineIDRef.current || Number(throughSeq) !== latestForkSeq(snapshotRef.current?.rows ?? []))
            return undefined;
          return postNative("chat.tryAnotherApproach", { throughSeq: Number(throughSeq) });
        },
        // Edit and resend (cx-ncc.60): a fork through the turn before the prompt, which then gets the
        // edited text with the prompt's attachments; the original chat stays as it was.
        "chat.editResend": async ({ rowId, throughSeq, text }) => {
          harnessSwitch.cancel();
          const draft = await client.resendPrompt(String(rowId ?? ""), String(text ?? ""));
          // A fork's own edited prompt edits again from the chat it was forked from, at the same
          // turn, so every version of the prompt is a sibling (conversation/branches.ts).
          const current = snapshotRef.current;
          const anchor = current
            ? forkAnchor(current.summary?.sessionId, current.rows, current.sessions, current.forkedAtSeq)
            : undefined;
          const forked =
            anchor && anchor.row.id === rowId
              ? await client.fork(anchor.forkSeq, anchor.parentId)
              : await client.fork(Number(throughSeq));
          if (!forked) return false;
          await persistSession(forked);
          // The reader may open another chat while the fork is saved: the edit belongs to the fork.
          if (client.selectedSession !== forked) return false;
          await send(draft.input, draft.attachments);
          return true;
        },
        // `/btw <question>`: acpmux starts the side session; the composer then opens it.
        "chat.btw": ({ question }) => client.btw(String(question ?? "")),
        // New side chat and `/side [prompt]`: `live` forks a working chat as it is now, its own
        // turn going on; `prompt` goes to the side chat once the app opened it (#38042).
        // Resolves once the side chat is open, not when its prompt's turn ends; rejects when no
        // side chat opened (the composer keeps `/side <prompt>` and says why).
        // `splitRight`: `/side`'s, always a new split right of the chat (the menu's keeps the right
        // column's placement, AgentSidePanes).
        "chat.side": async ({ throughSeq, live, prompt, splitRight, attachments, gesture }) => {
          // The chat it is beside, read before the fork (the reader may open another chat meanwhile).
          const chat = client.selectedSession;
          const split = splitRight === true ? { split: "right" } : {};
          // `/side`'s staged files (in-page only; the app's own calls name none): the side chat's
          // first prompt carries them, as a send does (#40066).
          const files = Array.isArray(attachments) ? (attachments as ComposerAttachment[]) : [];
          // The Enter a held `/side` bound (Composer `onBindSideGesture`): its prompt spends it.
          const held = sendGestureParam(gesture);
          // The side chat's prompt resolves when its turn ends, so nothing waits on it here.
          // acpmux's own refusal shows in the side chat; one the host made never reached it.
          const sidePromptRefused = (error: unknown) => {
            const code = (error as { code?: unknown } | null)?.code;
            if (typeof code === "string" && code.startsWith("transport."))
              notices.failed(
                translate("prompt.notSent", { reason: knownRefusalText(error) ?? translate("transport.refused") }),
              );
          };
          // A chat on another machine that opens side chats there (Cloud, SSH): that machine forks,
          // tags and prompts it in one call, in the chat's folder there; the app opens it beside.
          if (snapshotRef.current?.sideChatOnMachine) {
            const text = typeof prompt === "string" ? prompt.trim() : "";
            const boundary = live === true ? "live" : Number(throughSeq);
            // That machine's one call takes a text prompt; one with files opens the side chat bare and
            // the prompt then goes to it as any prompt does, files and all.
            const side = await client.sideChatOnMachine(boundary, files.length ? undefined : text || undefined);
            if (!side || !chat) throw new Error("");
            await postNative("chat.sideChat", { sessionId: side.sessionId, ...split });
            if (files.length) {
              void client.promptSide(side.sessionId, text, files, held).catch(sidePromptRefused);
              return;
            }
            // The side chat is open; a prompt it did not take stays in the composer, which says why.
            if (side.notSent) throw new CmuxCommandRefused(translate("prompt.notSent", { reason: side.notSent }));
            return;
          }
          const sessionId = await client.forkAside(live === true ? "live" : Number(throughSeq));
          if (!sessionId || !chat) throw new Error("");
          try {
            // acpmux marks it the chat's side chat; the app only opens it beside the chat.
            await client.markSide(sessionId, chat);
            await postNative("chat.sideChat", { sessionId, ...split });
          } catch (error) {
            client.takeBackSide(sessionId);
            throw error;
          }
          const text = typeof prompt === "string" ? prompt.trim() : "";
          if (!text && !files.length) return;
          void client.promptSide(sessionId, text, files, held).catch(sidePromptRefused);
        },
        // An offer's Start (cx-807da): the offered chat starts beside this one, which stays shown.
        // `worktree`: the task's Options > Worktree, else the agent's ask; `harness`, `model`,
        // `effort` and `mode`: its Options' picks (offer/offerChoice.ts), else the new chat's
        // defaults, with the tickets of the Effort and Permissions picks.
        "chat.offer.start": async (params) => {
          const { offerId, worktree } = params;
          const chat = client.selectedSession;
          const offer = client.offer(String(offerId));
          if (!chat || !offer) throw new Error(translate("offer.failed"));
          const fresh = typeof worktree === "boolean" ? worktree : offer.worktree;
          const cwd = fresh ? await offerWorktree(callNative, offer) : offer.cwd;
          return client.startOffer(chat, offer, cwd, offerPicks(params));
        },
        // Do it here (cx-lo9yf): acpmux records the answer, then the task's prompt goes to this
        // chat as the person's own (queued behind a running turn, as any prompt is).
        "chat.offer.here": async ({ offerId }) => {
          const chat = client.selectedSession;
          const offer = client.offer(String(offerId));
          if (!chat || !offer) throw new Error(translate("offer.failed"));
          await client.offerHere(chat, offer.offerId);
          void send(offer.prompt).catch(() => undefined);
        },
        "chat.offer.dismiss": async ({ offerId }) => {
          const chat = client.selectedSession;
          if (!chat) throw new Error(translate("error.notOpen"));
          await client.dismissOffer(chat, String(offerId));
        },
        // Reply on another agent's message card: the answer goes to the chat that sent it, in
        // its thread (conversation/IncomingMessageCard.tsx).
        "chat.message.reply": async ({ sessionId, msgId, threadId, text }) => {
          const str = (value: unknown) => (typeof value === "string" && value ? value : undefined);
          const [to, id, thread] = [str(sessionId), str(msgId), str(threadId)];
          await client.reply({ sessionId: to, msgId: id, threadId: thread }, String(text ?? ""));
        },
        // An inbox notice's thread the person opened: its messages, read without marking them
        // read (conversation/InboxNoticeCard.tsx).
        "chat.inbox.thread": ({ threadId }) => client.inboxThread(String(threadId ?? "")),
        // The held surge's threads (SurgeHoldRow.tsx): the chat's inbox listing, read as its panel opens.
        "chat.inbox.threads": () => client.inboxThreads(),
        // An agent link or `HOST/NAME` in a reply (conversation/sessionRefs.ts): the session it names.
        "chat.session.resolve": ({ query }) => client.resolveSession(String(query ?? "")),
        // Open a started offer or a sub-session: the app shows its tab or opens it beside this
        // chat (AgentPaneOfferOpen); a host without that opens it as a side chat; else here.
        "chat.offer.open": async ({ sessionId, sender }) => {
          const id = String(sessionId);
          try {
            // `sender`: a message's sender, any listed chat (AgentPaneOfferOpen).
            await postNative("chat.offer.open", {
              sessionId: id,
              ...(sender === true && { sender: true }),
            });
          } catch (error) {
            // The app refused a session outside this chat's family: nothing opens, not even here.
            if (error instanceof NativeError && error.code === "chat.offer.refused") return;
            try {
              await postNative("chat.sideChat", { sessionId: id });
            } catch {
              await persistSession(await client.select(id));
            }
          }
        },
        // The review shows in this tab while the tab stays the chat's; Start opens the new chat in
        // its own tab and brings this one back to the chat. Only where the chat cannot fork
        // (`chat.switchModel` is the way otherwise).
        "chat.handoff.prepare": async ({ harness }) => {
          harnessSwitch.cancel();
          return client.continueIn(String(harness));
        },
        // A switch to another harness's model in a started chat (forkHold.ts, the composer's send
        // with a held pick; the chat menu's Continue In… and `/continue`). Leo 2026-11-11: "if i
        // switch to a different model in a chat, it should just be able to seamlesly within the
        // same pane do stuff and stop asking so much bullshit ... across any and all conditions of
        // workspaces/folders/models/provides/harnesses". acpmux forks the chat as it is now onto
        // that harness and model (its history shown by reference, carried to the new agent with
        // its first prompt), this pane opens the fork in place and keeps it across a reload, and
        // the typed message, attachments and all, goes to it as its first. No review, no
        // question, no tab. Resolves once acpmux took the message (or at once with none); rejects
        // when the fork or the send failed, so the composer keeps the message.
        "chat.switchModel": async ({ harness, model, effort, fast, text, attachments, gesture }) => {
          harnessSwitch.cancel();
          const forked = await client.forkTo({
            harness: String(harness),
            ...(typeof model === "string" && model ? { model } : {}),
          });
          await persistSession(forked);
          // l10n-allow: the composer's promise only; the composer keeps the text, never shows this.
          if (client.selectedSession !== forked) throw new Error("the fork is not shown");
          // The held effort and Fast, best effort, before the first message.
          if (typeof effort === "string" && effort)
            await client.setConfig(HELD_EFFORT_ID, effort).catch(() => undefined);
          if (fast === true) await client.setConfig(HELD_FAST_ID, HELD_FAST_ON).catch(() => undefined);
          const message = typeof text === "string" ? text : "";
          const files = Array.isArray(attachments) ? (attachments as ComposerAttachment[]) : [];
          if (!message.trim() && files.length === 0) return forked;
          await new Promise<void>((resolve, reject) => {
            send(
              message,
              files,
              () => resolve(),
              false,
              undefined,
              forked,
              false,
              undefined,
              gesture as SendGesture | undefined,
            ).then(() => resolve(), reject);
          });
          return forked;
        },
        "chat.handoff.get": () => client.refreshHandoff(),
        "chat.handoff.draft": ({ review }) => client.saveHandoff(review as HandoffReviewInput),
        "chat.handoff.start": async ({ review }) => {
          // Capture the source before starting: a failed target start must return to the
          // conversation that the person forked, rather than leaving the unprompted target
          // selected in this pane. The source remains a live daemon session throughout.
          const handoff = client.handoff.state.record;
          const source = handoff?.source.sessionId;
          const target = handoff?.target.sessionId;
          const handoffId = handoff?.handoffId;
          const selectionToken = client.selectionToken;
          try {
            const receipt = await client.startHandoff(review as HandoffReviewInput);
            const startedTarget = receipt?.targetSessionId;
            if (!startedTarget || !source || client.selectedSession !== startedTarget) return receipt;
            if (await openOwnTab(startedTarget)) {
              if (client.selectedSession === startedTarget) await persistSession(await client.select(source));
            } else await persistSession(startedTarget);
            return receipt;
          } catch (error) {
            await restoreForkSource({
              source,
              target,
              handoffId,
              selectionToken,
              currentSelectionToken: () => client.selectionToken,
              currentHandoffId: () => client.handoff.state.record?.handoffId,
              selectedSession: () => client.selectedSession,
              select: (id) => client.select(id),
              persist: (id) => persistSession(id),
            }).catch(() => undefined);
            throw error;
          }
        },
        "chat.handoff.discard": async () => persistSession(await client.discardHandoff()),
        "git.diff": ({ scope, paths, context_lines }) =>
          client.gitDiff(String(scope), {
            ...(Array.isArray(paths) ? { paths: paths.map(String) } : {}),
            ...(typeof context_lines === "number" ? { context_lines } : {}),
          }),
        "git.status": () => client.gitStatus(),
        "git.checkpoint.diff": ({ from, to }) => client.gitCheckpointDiff(String(from), String(to)),
        "git.commit": (params) => client.gitCommit(params),
        "git.push": (params) => client.gitPush(params),
        "git.stage": ({ paths, unstage }) =>
          client.gitStage(Array.isArray(paths) ? paths.map(String) : [], unstage === true),
        "git.stageHunk": ({ paths, hunk, unstage }) =>
          client.gitStageHunk(
            Array.isArray(paths) ? paths.map(String) : [],
            Array.isArray(hunk) ? hunk.map(String) : [],
            unstage === true,
          ),
        "git.pullRequest": ({ action, number, url }) =>
          action === "threads"
            ? client.gitPullRequest({ action })
            : action === "merge"
              ? // A merge names the pull request it means; one that does not is refused, never an Open.
                Number.isInteger(number) && typeof url === "string"
                ? client.gitPullRequest({ action, number: number as number, url })
                : Promise.reject(new Error(translate("header.prMergeFailed")))
              : client.gitPullRequest(),
        // What the agent works on, for a terminal or browser opened from this chat (#16620).
        "pane.context": async () => (snapshotRef.current ? paneContext(snapshotRef.current) : { urls: [] }),
        // What this page holds that acpmux does not, kept by the host when a hidden chat's page
        // lets go and handed back with the next page's handshake (`wake`).
        // The transcript's place: an anchor, at its latest message, or left out when unknown
        // (never in view, or a subagent's view open) so the chat's kept anchor stands.
        // A quit asks this (an update's relaunch too): the typed draft reaches the host first, waited
        // on at most DRAFT_SETTLE_MS so the host's one-second ask still gets the chips and the place.
        "pane.wakeState": async ({ quitting, closing }) => {
          const held = trustHeldNow.current;
          // One wait for everything the page writes first, within the host's ask (wake-state.json).
          const until = Date.now() + DRAFT_SETTLE_MS;
          // The tab closes (AgentPageRetirer, while the bridge still answers): held prompts go
          // into their chats' drafts and kept chips, never its composer, which goes with it.
          if (closing === true) {
            // A subagent's draft the storage refused lives only in this page: it goes into its
            // chat's draft and kept chips the same way, a pasted chip's text in its place.
            const subagents = takeUnsavedSubagentDrafts().map(({ chat, draft }) => ({
              id: crypto.randomUUID(),
              chat,
              cwd: undefined,
              text: subagentDraftMessage(draft),
              attachments: draft.attachments.filter((chip) => chip.kind !== "pasted"),
              ticket: Promise.resolve(undefined),
            }));
            const all = [...held.release(), ...subagents];
            if (all.length) await giveBackTrustHeld.current(all, false, true, until);
            return {};
          }
          // Prompts the folder's trust holds or sends keep a hidden page (AgentPageHibernation
          // `holdsPrompts`): their tickets live with it. Quitting puts them back into drafts, and
          // a new chat's that no composer took give their chips to the wake state.
          if (quitting !== true && held.holdsAny()) return { holdsPrompts: true };
          // As a closing page's, the shown chat's go into its draft with what acpmux holds of it
          // (another client's newer save kept), never through the composer's copy.
          const released = quitting === true ? held.release() : [];
          const chips = released.length ? await giveBackTrustHeld.current(released, false, true, until) : [];
          await settleDraftWithin(composerHandle.current, Math.max(0, until - Date.now()));
          // Only untouched New Tabs are capped. Keep their page-owned drafts, attachments,
          // sends, composition and popups; quit and close still hand back their state.
          if (quitting !== true && newTabNow.current && pageReleaseHold()) return { holdsPageState: true };
          // A subagent's draft the storage refused lives only in this page (subagentDrafts.ts).
          if (quitting !== true && subagentDraftUnsaved()) return { holdsPageState: true };
          const anchor = transcriptAnchor.current?.();
          const composer = composerHandle.current?.wakeState();
          const attachments = [...chips, ...(composer?.attachments ?? [])];
          // Subagents' unsent prompts have no acpmux session: the host keeps them with the tab, the
          // ones this page kept and its chat's.
          const subagentDrafts = wakeSubagentDrafts(subagentDraftChatRef.current);
          // The transcript's open folds, the newest WAKE_FOLD_LIMIT of each (conversation/wakeFolds.ts).
          const folds = wakeFolds(foldsNow.current.session, foldsNow.current);
          return {
            ...composer,
            // An edit only this page holds (a queued message being edited, a send or draft not yet
            // saved): every hidden-chat release keeps the page for it, so nothing typed is lost.
            // The composer's draft itself is settled into acpmux above and comes back on reopen.
            ...(quitting !== true && pageEditHold() ? { holdsEdits: true } : {}),
            ...(attachments.length ? { attachments } : {}),
            ...(subagentDrafts ? { subagentDrafts } : {}),
            ...(folds ? { folds } : {}),
            ...(anchor ? { scrollAnchor: anchor } : anchor === null ? { atLatest: true } : {}),
          };
        },
      };
      // The first catalog request can race the connection: useModelCatalogState subscribes before
      // this action table exists, so retry once the direct client can serve catalog.get.
      void reloadModelCatalog().catch(() => undefined);
      // An adoption that came while this page was still connecting runs on this client.
      runPendingAdoption.current();
      // The host may now hand this page (a prewarmed New Tab page) to a tab opening an existing
      // chat: its actions answer, so the switch attaches at once (NewTabSparePool.servesChat).
      if (!mock) void postNative("pane.clientReady", { ready: true }).catch(() => undefined);
      // The native context menu's Copy Message and Fork from Here act on the row under the pointer.
      setMessageMenuSource((rowId) => {
        const current = snapshotRef.current;
        if (!current) return undefined;
        const target = messageMenuTarget(current, rowId, opensSideChat.current, counted.current.childRows);
        return withSendPromptAgain(target, rowId, readSendAgain(), translate);
      });
      // The harness switch runs on this client; one waiting on a connection runs now.
      switchPort = {
        turnRunning: () => client.turnRunning(),
        shown: () => client.shownSession(),
        create: async (harness, cwd, model) => {
          // After a Trust answer the switch that waited for it runs again, with its prompts
          // (the trust route, direct.ts; harnessSwitch.resumeAfterTrust).
          const again = () => harnessSwitch.resumeAfterTrust();
          const sessionId = await client
            .startSession(harness, cwd, undefined, again, false, model)
            .catch((error: unknown) => {
              setBlockedHarness(harnessBlock(error));
              throw error;
            });
          setBlockedHarness(undefined);
          if (sessionId) startedSessions.add(sessionId);
          return sessionId;
        },
        leave: () => client.leave(),
        startsOnSend: () => client.startsOnSend,
        open: (sessionId) => client.select(sessionId),
        attached: (sessionId) => client.shownAndAttached(sessionId),
        // A prompt held behind the trust question goes with the gesture its send kept.
        send: (text, attachments, promptId, ticket) => {
          // One the folder's trust held (trustHeld.ts) goes with its own send's ticket.
          const own = trustTickets.get(promptId);
          trustTickets.delete(promptId);
          if (own) ticket = own;
          const kept = own ? undefined : heldPrompt.take();
          // session/new has completed by the time HarnessSwitch hands the prompt back. The
          // transport's start credit now pays for this prompt ticket, including remote starts.
          const switchTicket =
            (kept?.promptId === promptId ? kept.ticket : undefined) ??
            ticket ??
            client.bindSendGesture(promptId)?.ticket;
          switchSendOwners.set(promptId, {
            client,
            generation: client.trustGeneration,
            sessionId: client.selectedSession,
            cancelEpoch: trustCancelEpoch.current,
          });
          return client.send(
            text,
            attachments,
            promptId,
            undefined,
            kept?.promptId === promptId ? kept.ticket : switchTicket,
            false,
            () => promptLanded.current(),
          );
        },
        setModel: (modelId) => client.setModel(modelId),
        setMode: (modeId, ticket) => setMode(modeId, ticket),
        setConfig: (configId, value, ticket) => client.setConfig(configId, value, ticket),
        discard: (sessionId) => client.discard(sessionId),
        prewarm: (harness, cwd) => client.prewarm(harness, cwd),
        // A function, not a getter: the React Compiler skips a component with a getter.
        prewarmSupported: () => client.prewarmSupported,
        // Where a start whose folder the pane refused starts again (harnessSwitch restartFolder).
        startFolder: () => startFolderRef.current,
      };
      // WEB-SWAP: a New Tab's prompt waits in its sender while its chat starts (screenActions.ts):
      // a web update's reload waits for the start too.
      const startChat = window.cmuxAcpmuxActions["chat.new"]!;
      window.cmuxAcpmuxActions["chat.new"] = (params) => {
        // The chat it starts takes the agent its typing warmed (newChatPrewarm.ts).
        newChatPrewarm.sent();
        untakenSends.current += 1;
        return startChat(params).finally(() => (untakenSends.current -= 1));
      };
      // A new chat's first send starts its chat, which takes the warm agent: nothing is released.
      const sendPrompt = window.cmuxAcpmuxActions["chat.send"]!;
      window.cmuxAcpmuxActions["chat.send"] = (params) => {
        newChatPrewarm.sent();
        return sendPrompt(params);
      };
      notifyDraftActionsChanged();
      harnessSwitch.setHandlers({
        restore: (text, attachments) => {
          // A failed New Tab start never surrendered this draft. Restoring it into the future
          // chat composer too would duplicate the prompt and attachments after a successful retry.
          if (!newTabRetainsDraft.current) restorePrompt(text, attachments);
        },
        opened: (sessionId) => {
          void persistSession(sessionId);
          // The harness has started and probed its models: refresh the catalog behind the picker.
          void queryClient.invalidateQueries({ queryKey: ["acpmux", "harnesses"] });
        },
        notice: (text) => client.notice(text),
        // A held pick spends its gesture now (pane-native transport); the ticket goes with the
        // pick's frame when the switch applies it. A host without the op answers with a refusal.
        gesture: (intent) =>
          postNative<{ ticket?: string }>("transport.gesture", { intent }).then((reply) => reply?.ticket),
        holdPrompt: (promptId) => void heldPrompt.hold(promptId),
      });
      harnessSwitch.connect(switchPort);
      // A New Tab permission pick made before this connect runs now, whether or not its chips
      // are still mounted (heldModePick.ts). It waits for the switch's gesture handler above, so
      // its session/set_mode carries the pick's gesture ticket.
      flushHeldModePick();
      // A pending chat's access chip asks this client the mode acpmux starts it in.
      setStartModeSource((harness, cwd) => client.startMode(harness, cwd));
      acpmuxPerf.markAgent("composerReady");
      client.snapshot();
      void client.warmRecentProjects();
      // New chats stay sessionless until the folder-trust question is answered.
      // `chat.send` creates the session after Trust; no harness hooks can run first.
      // A resumed chat is the tab's session from the start, so restoring the tab reopens it.
      if (client.adopted) void persistSession(client.adopted);
      // A tab opened by a chat's name or harness session id is rebound to the chat it named.
      else if (client.rebound) void persistSession(client.rebound);
      // A `#turn-<turnId>` link that opened this tab: scroll once the turn's row renders.
      if (typeof host.revealTurn === "string") revealRef.current(host.revealTurn);
      // Onboarding's first task runs without a Send press, once. If the chat cannot start,
      // the prompt waits in the composer instead of vanishing.
      const prompt = pendingPrompt;
      const attachments = pendingAttachments ?? [];
      const hasPrompt = Boolean(prompt || attachments.length);
      const harness = pendingHarness;
      const model = pendingModel;
      // The picker's effort with its model (a Cloud start), held under its kind's id (heldOptions.ts).
      const options = pendingEffort ? { [HELD_EFFORT_ID]: pendingEffort } : undefined;
      const ticket = pendingTicket;
      pendingPrompt = undefined;
      pendingAttachments = undefined;
      pendingHarness = undefined;
      pendingModel = undefined;
      pendingEffort = undefined;
      pendingTicket = undefined;
      // The seeded prompt goes with its ticket, under the ticket's promptId.
      if (hasPrompt && ticket) heldPrompt.keep(ticket);
      // A chat seeded with an agent starts on it, the prompt queued on the switch; a switch
      // that fails hands it back to the composer.
      if (host.peer && !host.sessionId && !client.attachedSession() && !client.adopted) {
        // The Environment picker's existing action owns peer creation and persistence. An
        // explicit host chooses it too, without inventing a second session/new handler.
        await window.cmuxAcpmuxActions["chat.new"]!({ peer: host.peer, cwd: host.cwd, harness, model }).catch(
          (error: unknown) => {
            // The handshake succeeded. A rejected folder/model is a creation failure on
            // this connection, not a reason to reconnect and repeat session/new forever.
            console.warn("agent pane: the new chat on the machine did not start", error);
            if (!cancelled && directClient.current === client)
              client.notice(knownRefusalText(error) ?? translate("chat.newFailed"));
          },
        );
      } else if (harness && hasPrompt) {
        void harnessSwitch.switchTo(harness, host.cwd, { model, ...(options ? { options } : {}) });
        void send(prompt ?? "", attachments, undefined, false, ticket?.promptId, undefined, true).catch(
          () => undefined,
        );
      } else if (hasPrompt)
        void send(prompt ?? "", attachments, undefined, false, ticket?.promptId, undefined, true).catch(
          (error: unknown) => {
            if (!isTrustRefusal(error)) restorePrompt(prompt ?? "", attachments);
          },
        );
      // A new chat seeded with the harness/model starts on them with the first Send; no session opens before that.
      // A model-only seed stays sessionless until the first Send; AcpmuxDirectClient retains
      // it in its host config and ensureSession() carries it into session/new.
      else if (harness && !client.adopted && client.startsOnSend)
        void harnessSwitch.switchTo(harness, host.cwd, { model, ...(options ? { options } : {}) });
    } catch (error) {
      if (!cancelled) {
        acpWire.lifecycle("handshake failed", { message: String(error) });
        setSnapshot((current) => ({ ...current, connection: `connecting: ${String(error)}` }));
        // A chat too large to open says so in plain words; the reply's byte count stays in the log.
        const tooLarge = hostRefusedTooLarge(error);
        // hostLine.ts words the line: only the pane's own text stands on it, the rest is Details.
        setHostError(tooLarge ? translate("host.tooLarge") : errorMessage(error) || String(error));
        setHostFailure(error);
        failingSince ??= Date.now();
        troubleSince ??= failingSince;
        setHostTroubleSince(troubleSince);
        const recovering = hostIsReconnecting(error);
        // A sleeping Cloud machine is never "Can't reach"; an SSH peer of the same name still is.
        const asleep = (peer: string | undefined) =>
          peer !== undefined && snapshotRef.current?.peerKinds?.[peer] !== "ssh" && cloudMachineAsleep(peer);
        setHostErrorShown(hostErrorShows(error, Date.now() - failingSince, asleep));
        // A refused chat of another machine still names that machine on its chip (cx-k21v).
        setMachineName((current) => refusedMachine(error) ?? current);
        // Another binary's daemon on this app's socket: the card offers Restart acpmux.
        setAcpmuxRestartOffered(offersAcpmuxRestart(error));
        // Back off so a host without a daemon is not asked four times a second. A Restart acpmux
        // in flight asks again itself when it ends.
        // A reply too large to send is the same at every ask: only the line's Retry asks again.
        if (!tooLarge && restartGate.mayAsk()) {
          retryTimer = window.setTimeout(() => void connectHost(), jitteredDelay(retryDelay));
          retryDelay = nextRetryDelay(
            retryDelay,
            reconnect || recovering,
            quickRetry({
              shown: document.visibilityState === "visible",
              failingForMs: Date.now() - failingSince,
              browserSocket,
            }),
          );
        }
      }
    } finally {
      connecting = false;
      setWaitingSince(undefined);
      // The Retry this attempt ran for (`retryNow`) has its answer.
      setRetryQueued(false);
      if (retryPending) {
        retryPending = false;
        // The attempt in flight may have connected; then there is nothing left to retry.
        // A Restart acpmux in flight asks again itself when it ends.
        if (!cancelled && !directClient.current && restartGate.mayAsk()) retryNow();
      }
    }
  };
  // The user asked: try now, and let the host start a daemon even after one was lost. Keep
  // automatic retries on `reconnect` (which deliberately preserves crash-only restart), while
  // this explicit action sends `ready` so a cleanly stopped app-owned daemon is started.
  const retryNow = () => {
    if (retryTimer !== undefined) window.clearTimeout(retryTimer);
    retryTimer = undefined;
    reconnect = false;
    retryDelay = 250;
    // The line's Retry waits on this attempt; the line itself stays until a connect clears it.
    setRetryQueued(true);
    void connectHost();
  };
  cancelRetry.current = () => {
    if (retryTimer !== undefined) window.clearTimeout(retryTimer);
    retryTimer = undefined;
    retryPending = false;
    setRetryQueued(false);
  };
  retryHost.current = () => {
    if (cancelled || !restartGate.mayAsk()) return;
    if (!connecting) return retryNow();
    // An attempt is in flight (perhaps a reconnect that may not start the daemon): run the
    // user's full attempt once it ends.
    retryPending = true;
    setRetryQueued(true);
  };
  void connectHost();
  return () => {
    cancelled = true;
    window.removeEventListener(NEW_TAB_CLOSE_EVENT, discardUnsent);
    harnessSwitch.disconnect();
    setStartModeSource(undefined);
    retryHost.current = undefined;
    cancelRetry.current = undefined;
    setHostErrorShown(false);
    if (retryTimer !== undefined) window.clearTimeout(retryTimer);
    directClient.current?.close();
    directClient.current = undefined;
    setBookmarkTransport(undefined);
    delete window.cmuxAcpmuxActions;
    notifyDraftActionsChanged();
  };
}
