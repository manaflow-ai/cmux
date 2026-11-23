// AcpmuxPane's pane body (RFD 0046 step 2.2): the drawn tree around the chat (its New Tab page,
// header, transcript, side panels, asks, composer slot and dialogs), moved out of App.tsx as it was.
// A plain render function AcpmuxPane calls inline for its `pane`, so React sees the same element
// tree (no component boundary of its own); every hook stays in AcpmuxPane, and this holds no state.
import type React from "react";
import type { createCloudPlanSubscribe } from "../cloudPlanSubscribe";
import type { sideChatRow } from "../header/sideChatRow";
import type { useSummaryCard } from "../summary/cardState";
import type { useNeedsYou } from "../needsYou/useNeedsYou";
import type { cloudFolderGrants } from "../cloudRun";
import type { useCheckpoints } from "../checkpoints/controller";
import type { usePeerCloudMachine } from "../peerCloudMachine";
import type { useFolderTrustAsk } from "../useFolderTrustAsk";
import type { useCloudChatRecovery } from "../useCloudChatRecovery";
import type { useSessionInfo } from "../session-info/useSessionInfo";
import type { SaveDocument } from "../conversation/ArtifactPanel";
import { BrowserSidebar } from "../browser/BrowserSidebar";
import { Activity } from "react";
import { LivePresenceStack, LiveTypingLine } from "../multiplayer/LivePresence";
import { ShareDialogHost } from "../share/ShareControl";
import { holdComposerPlace } from "../composer/composerHandover";
import { hasNativeHost } from "../native";
import { CloudEnvironmentEditor } from "../CloudEnvironmentEditor";
import { knownRefusalText } from "../transportErrors";
import { NewTabPage } from "../NewTabPage";
import { FOCUS_LOCATION_EVENT, type NewTabHost, type NewTabChat } from "../newTabModel";
import { NewTabScreen, type NewTabScreenActions } from "../newtab/NewTabScreen";
import { HistoryScreen } from "../newtab/HistoryScreen";
import { NewTabAppPage } from "../newtab/NewTabAppPage";
import { historyPages } from "../queue/historyPages";
import type { AllChatsPage } from "../newtab/allChatsListModel";
import { newTabScreenActions } from "../newtab/screenActions";
import { cloudSendAgent } from "../cloudModePick";
import { jumpSide } from "../jumpPlace";
import { StyleSwitch } from "../newtab/StyleSwitch";
import { screenTemplate, shownTemplate, pageStyle, pickNewTabStyle } from "../newtab/templates";
import { newTabPageSubmit } from "../newtab/pageSubmit";
import type { ComposerAttachment, DroppedKind, KnownPaths } from "../attachments";
import { EmptyState, type EmptyStateProjects } from "../EmptyState";
import { projectName } from "../emptyStateModel";
import { TourStartContext } from "../repoTour/TourBlock";
import { ChatUnavailableState } from "../ChatUnavailableState";
import { PastChat } from "../PastChat";
import { answerFromHome } from "../homeInboxModel";
import { HomeLists } from "../HomeLists";
import { AgentDotGrid } from "../dotGrid/AgentDotGrid";
import { ComputerUsePreviewCard } from "../computerUse/ComputerUsePreviewCard";
import { translate, type Translate } from "../i18n";
import { LINK_DOWN_SAID_MS } from "../afterDelay";
import { PeerCopyBanner } from "../PeerCopyBanner";
import { Inspector, type ExportOutcome } from "../Inspector";
import { SummaryButton } from "../summary/SummaryButton";
import { chatProcessesHere } from "../processTerminal";
import { BackgroundTasksPanel } from "../backgroundTasks/BackgroundTasksPanel";
import { backgroundTasksLook } from "../backgroundTasks/backgroundTasksLook.experiment";
import { AgentTonesContext } from "../subagents/agentTones";
import { WorkflowSideTab } from "../summary/WorkflowSideTab";
import { isWaitingForWords, type Dictation, type DictationField } from "../dictation";
import { DictationMic } from "../DictationMic";
import { DictationNotice } from "../DictationNotice";
import { AgentNamesContext, AgentOpenContext } from "../conversation/agentNames";
import { BackgroundTaskOutputContext, type BackgroundTaskOutputReader } from "../conversation/backgroundTaskOutput";
import { turnView } from "../conversation/turns";
import { ArtifactPanel } from "../conversation/ArtifactPanel";
import { changeArtifactPin, type OpenedArtifact } from "../conversation/artifactPin";
import { ShortcutsContext } from "../shortcuts";
import { PaneLoadingMark } from "../PaneLoadingMark";
import { NeedsYouButton } from "../needsYou/NeedsYou";
import { ImageViewer } from "../conversation/ImageViewer";
import { ChatHeaderInlineStatus, ChatHeaderStatus } from "../header/ChatHeaderStatus";
import { ChatHeaderTools } from "../header/ChatHeaderTools";
import { HEADER_ACTIONS, type ChatMenuItem } from "../header/chatHeaderToolsModel";
import { ThreadTitle } from "../header/ThreadTitle";
import { ChatSummaryLine } from "../header/ChatSummaryLine";
import { setHeaderState } from "../header/headerState";
import { tabRowStyle, type TabRow } from "../header/tabRow";
import { cloudStartFolder, newTabProjectPick, type CloudSignInRetry } from "../cloudRun";
import { CloudStartView } from "../CloudStartView";
import { configureQuickActions, quickActions, type QuickActionMode } from "../header/quickActions";
import { ChatDisplaySettings } from "../ChatDisplaySettings";
import { afterDeleteDismiss } from "../header/deleteDismiss";
import { DeleteChatDialog } from "../header/DeleteChatDialog";
import { readChatMini } from "../header/miniRow";
import { ToastLayer } from "../ToastLayer";
import { SubagentClockContext } from "../subagents/subagentGroupModel";
import { NewProjectUnsupported } from "../newtab/NewProjectName";
import { newWorktree } from "../startFolderModel";
import { LiveChatChoice } from "../LiveChatChoice";
import { WatchBanner } from "../WatchBanner";
import { HandoffReviewMessage } from "../handoff/ReviewMessage";
import { withExtensionCommands, withToolCommands } from "../composer/extensionCommands";
import { ReplayScreen } from "../replay/ReplayScreen";
import { recordSteer, type SteerAct } from "../steerQueue/log";
import { SteerQueue, type SteerActions } from "../steerQueue/SteerQueue";
import { StatusIsland } from "../statusIsland/StatusIsland";
import { experimentArm } from "../../../experiments/experiment";
import { sandboxRetryable, type SandboxTab, type RunModeRows, type SandboxRun } from "../sandboxRun";
import { SandboxRunView } from "../SandboxRunView";
import { PaneFeatureTips } from "../featureTips";
import { callNative } from "../callNative";
import { openOfferChat } from "../rows/rowActions";
import { VirtualTranscript } from "../VirtualTranscript";
import { LiveTreePill } from "../header/LiveTreePill";
import { readFolderStatus } from "./hostBindings";
import { NewTabComposerChips } from "./ComposerChips";
import type { AcpmuxSnapshot, paneHeader } from "../model";
import type { AcpmuxDirectClient } from "../direct";
import type { SteerItem } from "../steerQueue/model";
import type { IslandState } from "../statusIsland/model";
import type { EmptyChatComposerPosition } from "../composerSettings";
import type { TrayHandleSide } from "../chatDisplay";
import type { CmuxCommand, CmuxCommandResult } from "../cmuxCommands";
import type { SendGesture } from "../heldPrompt";
import type { CloudChatHintState } from "../cloudChatHintModel";
import type { CloudStartProgress } from "../cloudStartProgress";
import type { SendToCloud } from "./useCloudSend";
import type { UploadProgressReport, UploadResult } from "../cloudUploads";
import type { SlashCommand } from "../slashCommands";
import type { CloudMachine } from "../cloudMachines";
import type { Project } from "../ProjectChooser";
import type { ExtraFolderDraft } from "../extraFolders";
import type { ShellRuns } from "../shell/shellRuns";
import type { EventRecord } from "../direct/records";
import type { Folds } from "../conversation/viewFolds";
import type { RowProps } from "../rows/rowProps";
import type { TurnFile } from "../diffTypes";
import type { PathRef } from "../diff";
import type { UnderHeaderLines } from "../header/underHeader";
import type { ChatUnavailable } from "../chatUnavailable";
import type { ComputerUsePreview } from "../computerUse/computerUsePreview";
import type { ComputerUsePlace } from "../computerUse/computerUseState";
import type { ComposerWake } from "../Composer";
import type { Handoff } from "../handoff/protocol";
import type { HandoffStrings } from "../handoff/strings";
import type { PastTurn } from "../pastChatModel";
import type { TourOfferActions } from "../repoTour/TourOffer";
import type { TourTask } from "../repoTour/tourModel";
import type { PerfSend } from "../perfReporter";
import type { NoticeQueue } from "../../../ui/NoticeStack";
import type { Artifact } from "../conversation/artifactPreview";
import type { BackgroundGroup } from "../backgroundTasks/backgroundTasks";
import type { BackgroundFocus } from "../backgroundTasks/openBackgroundTasks";
import type { WorkflowDetailRequest } from "../summary/foldWorkflows";
import type { BackgroundCommand } from "../session-info/processes";
import type { ChatImage } from "../conversation/chatImages";
import type { WorkflowSummary, WorkflowAgent } from "../summary/workflow";

/** Saves the inspector's export through the host's save panel (`pane.saveLog`): true is saved, false a cancelled panel. A host without it, or one that refuses the log, leaves the inspector to copy it. */
async function saveLogNatively(text: string, suggestedName: string): Promise<ExportOutcome> {
  try {
    return (await callNative<boolean>("pane.saveLog", { text, suggestedName })) === true ? "saved" : "cancelled";
  } catch {
    return "unavailable";
  }
}

/// The New Tab page shows only with its host (App.tsx `showNewTab` reads `newTab !== undefined`), and
/// the Cloud start view only with its progress (`cloudStartShown`): each pair passes as one, so the
/// tree reads `newTab` and `cloudStart` as set where AcpmuxPane's render did.
type NewTabShown = { showNewTab: true; newTab: NewTabHost } | { showNewTab: false; newTab: NewTabHost | undefined };
type CloudStartShown =
  | { cloudStartShown: true; cloudStart: CloudStartProgress }
  | { cloudStartShown: false; cloudStart: CloudStartProgress | undefined };

/// What AcpmuxPane's render hands its pane body: each value as the render worked it out.
export type PaneBodyDeps = NewTabShown &
  CloudStartShown & {
    knowsWhatItIs: boolean;
    shortcuts: Readonly<Record<string, string>>;
    setShell: React.Dispatch<React.SetStateAction<HTMLElement | null>>;
    inTabRow: boolean;
    header: ReturnType<typeof paneHeader>;
    soloTab: boolean;
    tabRow: TabRow;
    ownBackgroundPane: boolean;
    composerSnapshot: AcpmuxSnapshot;
    t: Translate;
    connected: boolean;
    snapshot: AcpmuxSnapshot;
    selectSession: (sessionId: string) => void;
    directClient: React.RefObject<AcpmuxDirectClient | undefined>;
    steering: boolean;
    steerQueueOn: boolean;
    steerItems: SteerItem[];
    steerNow: number;
    steerActions: SteerActions;
    setSteering: React.Dispatch<React.SetStateAction<boolean>>;
    setSteerLog: React.Dispatch<React.SetStateAction<SteerAct[]>>;
    statusIsland: IslandState | undefined;
    needsYou: ReturnType<typeof useNeedsYou>;
    freshView: boolean;
    emptyChatComposerPosition: EmptyChatComposerPosition;
    reviewing: boolean;
    inspectorOpen: boolean;
    summaryCard: ReturnType<typeof useSummaryCard>;
    previewBeside: boolean;
    jumpPlaceArm: "center" | "end" | "start" | "corner";
    trayHandle: TrayHandleSide;
    chatMinimapBeside: boolean;
    hasBottomAsk: boolean;
    setPaneMain: (element: HTMLDivElement | null) => void;
    setToastTop: React.Dispatch<React.SetStateAction<HTMLDivElement | null>>;
    harnessesOpen: boolean;
    newTabApp: string | undefined;
    setNewTab: React.Dispatch<React.SetStateAction<NewTabHost | undefined>>;
    folderAskView: React.JSX.Element | null;
    newTabGeneration: number;
    setNewTabAppGone: React.Dispatch<React.SetStateAction<number | undefined>>;
    newTabAdoptions: number;
    setupContinuation: React.RefObject<((harness: string) => void) | undefined>;
    setHarnessesOpen: React.Dispatch<React.SetStateAction<boolean>>;
    handleCmuxCommand: (
      command: CmuxCommand,
      typedArgs?: string,
      fresh?: boolean,
      attachments?: ComposerAttachment[],
      gesture?: SendGesture,
    ) => CmuxCommandResult;
    importFile: (file: File) => Promise<void>;
    importError: string | undefined;
    sandbox: SandboxTab;
    newTabStartMachine: string | undefined;
    leaveNewTabDraft: (text: string, attachments: ComposerAttachment[]) => void;
    takeNewTabDraft: () => { text: string; attachments: ComposerAttachment[] } | undefined;
    cloudPickPending: boolean;
    takeCloudPick: () => void;
    cloudHintShown: boolean;
    cloudHint: CloudChatHintState;
    newTabRunMode: RunModeRows | undefined;
    cloudWaitsForCheck: boolean;
    cloudHeld: "checking" | { refusal: string; prompt: string; cwd?: string | undefined } | undefined;
    setCloudHeld: React.Dispatch<
      React.SetStateAction<"checking" | { refusal: string; prompt: string; cwd?: string | undefined } | undefined>
    >;
    openCloudChatWith: (start: { prompt?: string | undefined; cwd?: string | undefined }) => Promise<unknown>;
    answerCloudStart: (id: string, button: string) => Promise<boolean>;
    retryCloudStart: () => void;
    cloudSignInRetry: CloudSignInRetry;
    cloudPlanStore: ReturnType<typeof createCloudPlanSubscribe>;
    runCloudHere: (expectedKey?: string) => void;
    dismissCloudFailure: () => void;
    switchTeamAndRetry: (team: { id: string }) => void;
    openNewCloudChatForStart: () => void;
    cloudTooBigActions: {
      onPickRepo: (cwd: string) => void;
      onPickFolder: () => void;
      onStartWithoutFolder: () => void;
    };
    setUpCloud: (action: "connectChatGPT" | "setUpClaude" | "addKey" | "openSettings") => void;
    dismissCloudSetUp: () => void;
    cloudSendHeld: boolean;
    cloudPageHeld: boolean;
    cloudRetryFolder: React.RefObject<{ cwd: string } | { home: true } | undefined>;
    sendToCloud: SendToCloud;
    sandboxing: boolean;
    startSandbox: (text: string, attachmentCount: number, harness: string | undefined) => string | boolean;
    sandboxNotNow: "sandbox_spent" | "unavailable_now";
    newTabSandboxSent: React.RefObject<boolean>;
    heldBack: React.RefObject<{ text: string; attachments: ComposerAttachment[] }[] | undefined>;
    setSandboxDraftMoved: React.Dispatch<React.SetStateAction<boolean>>;
    connectMachine: (
      kind: "cloud" | "ssh" | "cloudSignIn" | "cloudPage" | "addMachine" | "move" | "bringBack" | "phone",
    ) => undefined;
    dictation: Dictation;
    uploadFiles: (
      files: File[],
      cancelled?: (index: number) => boolean,
      progress?: UploadProgressReport,
    ) => Promise<UploadResult>;
    newTabDictationField: React.RefObject<DictationField | null>;
    sandboxUncheckedNotice: boolean;
    sandboxUnchecked: React.JSX.Element;
    trustQuestion: React.JSX.Element | undefined;
    quick: boolean;
    localPaths: (kind: DroppedKind, files: File[], gestureAt?: number) => Promise<KnownPaths | undefined>;
    commandSession: string | undefined;
    newTabSnapshot: AcpmuxSnapshot;
    pendingCommands: SlashCommand[] | undefined;
    extensionCommands: readonly SlashCommand[];
    /// Computer use and browser use in the `/` and `$` menus (toolMentions.ts).
    toolCommands: readonly SlashCommand[];
    /// Whether a send of `text` from `place` waits for Computer Use (App.tsx, #48541).
    holdsForComputerUseSetup: (
      text: string,
      toast?: boolean,
      place?: ComputerUsePlace,
      opensSetup?: boolean,
    ) => boolean;
    newTabFixError: string | undefined;
    newTabKnownProjects: readonly string[] | null;
    startFolder: string | undefined;
    onNewTabPromptTyped: (text: string, target?: { harness?: string; cwd?: string }) => void;
    onCloudMachinePicked: (machine: CloudMachine | undefined) => void;
    cloudOfferable: boolean;
    cloudFolderGrant: ReturnType<typeof cloudFolderGrants>;
    handshaken: boolean;
    newTabChatsPending: boolean;
    machineName: string | undefined;
    newTabProjects: Project[];
    extraFolderDraft: ExtraFolderDraft | undefined;
    setExtraFolderDraft: React.Dispatch<React.SetStateAction<ExtraFolderDraft | undefined>>;
    registryChips: React.ComponentType<{ snapshot: AcpmuxSnapshot }> | undefined;
    runNewTabPlusSearch: (id: string) => Promise<unknown>;
    withSubmitAfterHandshake: (actions: NewTabScreenActions) => NewTabScreenActions;
    requestFolder: (cwd: string, use: (folder: string) => void, cancel?: (refusal?: unknown) => void) => Promise<void>;
    newTabStartGeneration: React.RefObject<number>;
    showAllChats: () => undefined;
    setProjectDraft: React.Dispatch<React.SetStateAction<string | undefined>>;
    shellRuns: ShellRuns;
    setNewTabFixError: React.Dispatch<React.SetStateAction<string | undefined>>;
    harnessesPage: React.JSX.Element;
    contextOpen: boolean;
    contextPage: React.JSX.Element;
    whenHandshaken: (run: () => void) => void;
    chatFromNewTab: (text: string, cwd?: string, attachments?: ComposerAttachment[], chat?: NewTabChat) => void;
    newTabFieldEdited: (text: string) => void;
    replaying: string | undefined;
    loadReplay: () => Promise<EventRecord[]>;
    setReplaying: React.Dispatch<React.SetStateAction<string | undefined>>;
    folds: Folds;
    minimapVisible: boolean;
    columnEndReserve: 0 | 204;
    noDismissRegistry: {
      recap: React.NamedExoticComponent<RowProps>;
      memoryOffer: React.NamedExoticComponent<RowProps>;
      promptCoach: React.NamedExoticComponent<RowProps>;
      presetApproval: React.NamedExoticComponent<RowProps>;
    };
    toggleActivity: (id: string, covers?: readonly string[]) => void;
    showsChatView: boolean;
    premountsChatView: boolean;
    chatViewMount: React.RefObject<{ shown: boolean; key: number }>;
    parkVisible: boolean;
    soloUnder: boolean;
    parkStyle: React.CSSProperties | undefined;
    parkedVisible: boolean;
    chatName: string;
    renameFromTitle: (() => void) | undefined;
    tabRowTools: (element: HTMLElement | null) => void;
    liveTreeEnabled: boolean;
    readLiveTree: () => Promise<unknown>;
    shareOpen: boolean;
    setShareOpen: React.Dispatch<React.SetStateAction<boolean>>;
    sessionInfo: ReturnType<typeof useSessionInfo>;
    readOnlySubagent: boolean;
    /// The dock draws the composer and its quiet row (App.tsx `dockFoot`; bottomStack.css `data-foot`).
    dockFoot: boolean;
    localCwd: string | undefined;
    remoteChat: boolean;
    runSplitAction: (id: string, cwd: string | undefined, mode: QuickActionMode) => void;
    lastEditTurn: { key: string; rowId: string; files: TurnFile[]; pathsOnly: PathRef[] } | undefined;
    chatCwd: string | undefined;
    toggleChanges: (mode: QuickActionMode) => void;
    previewUrl: string | undefined;
    ignoreFailure: (result: Promise<unknown>) => undefined;
    refreshTabState: () => undefined;
    sideTabs: boolean;
    toggleSideTabs: () => undefined;
    sideChat: ReturnType<typeof sideChatRow>;
    canMove: boolean;
    newTerminal: () => void;
    newBrowser: () => void;
    chatMenu: () => ChatMenuItem[];
    readTabState: (pair?: boolean) => Promise<void>;
    continuing: boolean;
    canContinue: boolean;
    stopContinuing: () => void;
    turnWorking: boolean;
    summaryPanel: React.JSX.Element;
    underHeader: UnderHeaderLines;
    checkpoints: ReturnType<typeof useCheckpoints>;
    cloudUnavailable: ChatUnavailable | undefined;
    cloudRecovery: ReturnType<typeof useCloudChatRecovery>;
    runHeaderAction: (id: string, cwd?: string, mode?: QuickActionMode) => void;
    peerMachine: ReturnType<typeof usePeerCloudMachine>;
    reconnectPeer: (peer: string) => Promise<unknown>;
    previewShown: boolean;
    computerUsePreview: ComputerUsePreview | null;
    viewedSandbox: SandboxRun | undefined;
    pendingWake: React.RefObject<ComposerWake | undefined>;
    sandboxWake: React.RefObject<ComposerWake | undefined>;
    setSandboxViewing: React.Dispatch<React.SetStateAction<boolean>>;
    handoff: Handoff | undefined;
    reviewReload: number;
    handoffLabels: HandoffStrings;
    setReviewReload: React.Dispatch<React.SetStateAction<number>>;
    missingRows: boolean;
    pastTurns: PastTurn[] | undefined;
    pastWaitsForTrust: boolean;
    trustAsk: ReturnType<typeof useFolderTrustAsk>;
    githubRepository: string | undefined;
    sandboxView: SandboxRun | undefined;
    sandboxHoldsChat: boolean;
    heroPicker: EmptyStateProjects | undefined;
    tourOffer: TourOfferActions | undefined;
    chatTones: Map<string, number> | undefined;
    chatAgentNames: ReadonlyMap<string, string>;
    chatAgentOpen: { views: ReadonlyMap<string, string>; open: (id: string) => undefined };
    backgroundTaskOutput: BackgroundTaskOutputReader | undefined;
    tourHere: boolean;
    startTourTask: (task: TourTask) => Promise<string>;
    transcript: React.JSX.Element;
    displayAnchor: HTMLElement | null;
    setDisplayAnchor: React.Dispatch<React.SetStateAction<HTMLElement | null>>;
    closeInspector: () => void;
    sendPerf: PerfSend;
    setDock: React.Dispatch<React.SetStateAction<HTMLElement | null>>;
    paneToasts: NoticeQueue;
    toastTop: HTMLDivElement | null;
    asks: React.JSX.Element | null;
    dotGridArm: "off" | "on" | "compact";
    hostLine: React.JSX.Element;
    forkPendingLine: React.JSX.Element | undefined;
    composer: false | React.JSX.Element;
    artifact: OpenedArtifact | undefined;
    liveArtifact: Artifact | undefined;
    artifactVersionList: readonly Artifact[] | undefined;
    setArtifact: React.Dispatch<React.SetStateAction<OpenedArtifact | undefined>>;
    saveDocumentNatively: SaveDocument;
    backgroundPanel: { sessionId?: string | undefined; expanded: boolean; dismissed: ReadonlySet<string> } | undefined;
    backgroundList: BackgroundGroup[];
    clientEpoch: number;
    backgroundFocus: BackgroundFocus | undefined;
    stopSubagent: ((id: string) => Promise<unknown>) | undefined;
    backgroundWorkflowReads:
      | {
          sessionId: string | undefined;
          chat: string;
          connection: string;
          read: (
            request: WorkflowDetailRequest & { before?: number | undefined; after?: number | undefined },
          ) => Promise<unknown>;
        }
      | undefined;
    backgroundOwnLogReads: {
      chat: { session: string | undefined; harness: string | undefined };
      read: (id: string) => Promise<EventRecord[]>;
      connected: boolean;
    };
    stopProcess: (id: string) => Promise<unknown>;
    setBackgroundPanel: React.Dispatch<
      React.SetStateAction<
        { sessionId?: string | undefined; expanded: boolean; dismissed: ReadonlySet<string> } | undefined
      >
    >;
    panelCommands: BackgroundCommand[];
    openTrayCommand: (command: BackgroundCommand) => void;
    imageView: { images: ChatImage[]; index: number } | undefined;
    setImageView: React.Dispatch<React.SetStateAction<{ images: ChatImage[]; index: number } | undefined>>;
    deleteConfirmOpen: boolean;
    setDeleteConfirmOpen: React.Dispatch<React.SetStateAction<boolean>>;
    setDeleteConfirmSession: React.Dispatch<React.SetStateAction<string | undefined>>;
    deleteInFlight: React.RefObject<
      { target: string; client: AcpmuxDirectClient; harness?: string | undefined } | undefined
    >;
    deleteChat: () => Promise<void>;
    workflowSideTab: WorkflowSummary | undefined;
    closeWorkflowSideTab: () => void;
    showWorkflowAgent: (agent: WorkflowAgent) => void;
  };

/// The pane's body: clear until it knows what it is, then the New Tab page or the chat view.
export function drawPaneBody({
  knowsWhatItIs,
  shortcuts,
  setShell,
  inTabRow,
  header,
  soloTab,
  tabRow,
  ownBackgroundPane,
  composerSnapshot,
  t,
  connected,
  snapshot,
  selectSession,
  directClient,
  steering,
  steerQueueOn,
  steerItems,
  steerNow,
  steerActions,
  setSteering,
  setSteerLog,
  statusIsland,
  needsYou,
  showNewTab,
  freshView,
  emptyChatComposerPosition,
  reviewing,
  inspectorOpen,
  summaryCard,
  previewBeside,
  jumpPlaceArm,
  trayHandle,
  chatMinimapBeside,
  hasBottomAsk,
  setPaneMain,
  setToastTop,
  harnessesOpen,
  newTab,
  newTabApp,
  setNewTab,
  folderAskView,
  newTabGeneration,
  setNewTabAppGone,
  newTabAdoptions,
  setupContinuation,
  setHarnessesOpen,
  handleCmuxCommand,
  importFile,
  importError,
  sandbox,
  newTabStartMachine,
  leaveNewTabDraft,
  takeNewTabDraft,
  cloudPickPending,
  takeCloudPick,
  cloudHintShown,
  cloudHint,
  newTabRunMode,
  cloudStart,
  cloudWaitsForCheck,
  cloudHeld,
  setCloudHeld,
  openCloudChatWith,
  answerCloudStart,
  retryCloudStart,
  cloudSignInRetry,
  cloudPlanStore,
  runCloudHere,
  dismissCloudFailure,
  switchTeamAndRetry,
  openNewCloudChatForStart,
  cloudTooBigActions,
  setUpCloud,
  dismissCloudSetUp,
  cloudSendHeld,
  cloudPageHeld,
  cloudRetryFolder,
  sendToCloud,
  sandboxing,
  startSandbox,
  sandboxNotNow,
  newTabSandboxSent,
  heldBack,
  setSandboxDraftMoved,
  connectMachine,
  dictation,
  uploadFiles,
  newTabDictationField,
  sandboxUncheckedNotice,
  sandboxUnchecked,
  trustQuestion,
  quick,
  localPaths,
  commandSession,
  newTabSnapshot,
  pendingCommands,
  extensionCommands,
  toolCommands,
  holdsForComputerUseSetup,
  newTabFixError,
  newTabKnownProjects,
  startFolder,
  onNewTabPromptTyped,
  onCloudMachinePicked,
  cloudOfferable,
  cloudFolderGrant,
  handshaken,
  newTabChatsPending,
  machineName,
  newTabProjects,
  extraFolderDraft,
  setExtraFolderDraft,
  registryChips,
  runNewTabPlusSearch,
  withSubmitAfterHandshake,
  requestFolder,
  newTabStartGeneration,
  showAllChats,
  setProjectDraft,
  shellRuns,
  setNewTabFixError,
  harnessesPage,
  contextOpen,
  contextPage,
  whenHandshaken,
  chatFromNewTab,
  newTabFieldEdited,
  replaying,
  loadReplay,
  setReplaying,
  folds,
  minimapVisible,
  columnEndReserve,
  noDismissRegistry,
  toggleActivity,
  showsChatView,
  premountsChatView,
  chatViewMount,
  parkVisible,
  soloUnder,
  parkStyle,
  parkedVisible,
  chatName,
  renameFromTitle,
  tabRowTools,
  liveTreeEnabled,
  readLiveTree,
  shareOpen,
  setShareOpen,
  sessionInfo,
  readOnlySubagent,
  dockFoot,
  localCwd,
  remoteChat,
  runSplitAction,
  lastEditTurn,
  chatCwd,
  toggleChanges,
  previewUrl,
  ignoreFailure,
  refreshTabState,
  sideTabs,
  toggleSideTabs,
  sideChat,
  canMove,
  newTerminal,
  newBrowser,
  chatMenu,
  readTabState,
  continuing,
  canContinue,
  stopContinuing,
  turnWorking,
  summaryPanel,
  underHeader,
  checkpoints,
  cloudUnavailable,
  cloudRecovery,
  runHeaderAction,
  peerMachine,
  reconnectPeer,
  previewShown,
  computerUsePreview,
  viewedSandbox,
  pendingWake,
  sandboxWake,
  setSandboxViewing,
  handoff,
  reviewReload,
  handoffLabels,
  setReviewReload,
  missingRows,
  pastTurns,
  pastWaitsForTrust,
  trustAsk,
  githubRepository,
  cloudStartShown,
  sandboxView,
  sandboxHoldsChat,
  heroPicker,
  tourOffer,
  chatTones,
  chatAgentNames,
  chatAgentOpen,
  backgroundTaskOutput,
  tourHere,
  startTourTask,
  transcript,
  displayAnchor,
  setDisplayAnchor,
  closeInspector,
  sendPerf,
  setDock,
  paneToasts,
  toastTop,
  asks,
  dotGridArm,
  hostLine,
  forkPendingLine,
  composer,
  artifact,
  liveArtifact,
  artifactVersionList,
  setArtifact,
  saveDocumentNatively,
  backgroundPanel,
  backgroundList,
  clientEpoch,
  backgroundFocus,
  stopSubagent,
  backgroundWorkflowReads,
  backgroundOwnLogReads,
  stopProcess,
  setBackgroundPanel,
  panelCommands,
  openTrayCommand,
  imageView,
  setImageView,
  deleteConfirmOpen,
  setDeleteConfirmOpen,
  setDeleteConfirmSession,
  deleteInFlight,
  deleteChat,
  workflowSideTab,
  closeWorkflowSideTab,
  showWorkflowAgent,
}: PaneBodyDeps) {
  return !knowsWhatItIs ? (
    // Clear until it knows: the pane's background shows, never a chat screen a New Tab replaces.
    <ShortcutsContext.Provider value={shortcuts}>
      <section
        ref={setShell}
        className="acpmux-shell"
        data-tab-row={inTabRow ? "" : undefined}
        data-solo-tab={soloTab ? "" : undefined}
        aria-busy="true"
        style={inTabRow ? tabRowStyle(tabRow) : undefined}
      >
        {/* The host's loading state covers this until the page paints; a page it gave up on shows here
            still connecting, so it shows the same mark, never a blank pane (cmux#48605). */}
        <PaneLoadingMark label={t("transcript.loading")} />
      </section>
    </ShortcutsContext.Provider>
  ) : (
    <ShortcutsContext.Provider value={shortcuts}>
      <section
        ref={setShell}
        className="acpmux-shell"
        data-tab-row={inTabRow ? "" : undefined}
        data-solo-tab={soloTab ? "" : undefined}
        data-background-pane={ownBackgroundPane ? "" : undefined}
        aria-label={composerSnapshot.summary?.title || t("header.agentChat")}
        style={inTabRow ? tabRowStyle(tabRow) : undefined}
      >
        {document.documentElement.hasAttribute("data-cmux-browser-pane") && connected && (
          <BrowserSidebar
            sessions={snapshot.sessions}
            workspaces={snapshot.browserWorkspaces}
            selected={snapshot.sessionId}
            onSelect={selectSession}
            onRefresh={() => void directClient.current?.refreshBrowserWorkspaces()}
          />
        )}
        {steering && steerQueueOn ? (
          <SteerQueue
            items={steerItems}
            now={steerNow || Date.now()}
            actions={steerActions}
            onClose={() => setSteering(false)}
            onAct={(item, act, text) =>
              setSteerLog((log) =>
                recordSteer(log, { sessionId: item.sessionId, act, ...(text ? { text } : {}), at: Date.now() }),
              )
            }
          />
        ) : null}
        {statusIsland ? (
          <StatusIsland
            state={statusIsland}
            actions={{
              answer: needsYou.actions.answer,
              goTo: needsYou.actions.goTo,
              // The chat on screen: its failure is right here, at the foot of the transcript. Another
              // chat opens beside this one (`chat.asks.open`), which the host does only for a chat on
              // this Mac's acpmux and never from New Tab: there the card offers no Open Chat.
              openSession: (sessionId) => {
                if (sessionId === snapshot.sessionId) {
                  const failures = document.querySelectorAll(".cv-turn-error__cause");
                  failures[failures.length - 1]?.scrollIntoView({ block: "nearest" });
                  return;
                }
                void callNative("chat.asks.open", { sessionId }).catch(() => undefined);
              },
              canOpen: (sessionId) =>
                !showNewTab &&
                (sessionId === snapshot.sessionId ||
                  !snapshot.sessions.some((session) => session.sessionId === sessionId && session.peer)),
            }}
          />
        ) : null}
        <div
          className="acpmux-main"
          data-new-chat={freshView && !showNewTab ? "" : undefined}
          // Settings' `agentPane.emptyChatComposerPosition`: "center" sits a new chat's composer in the
          // middle of the pane (styles.css); absent, it docks at the bottom as always.
          data-empty-chat-composer={
            freshView && !showNewTab && emptyChatComposerPosition === "center" ? "center" : undefined
          }
          // The transcript runs the pane's height under the bottom stack (bottomStack.css) while the
          // stage shows it; a new chat's hero, a handoff review, the diff and the inspector keep it in flow.
          data-dock={!reviewing && !freshView && !inspectorOpen ? "float" : undefined}
          data-summary={summaryCard.column ? "inline" : "popover"}
          data-cu-preview={previewBeside ? "" : undefined}
          // The jump stack's place and side (jumpPlace.css): the whole stack moves together.
          data-jump-place={jumpPlaceArm}
          data-jump-side={jumpSide(jumpPlaceArm, trayHandle)}
          data-vscode-minimap={chatMinimapBeside ? "" : undefined}
          // A question or permission card in the bottom stack (conversation.css). An attribute, not a
          // `:has()` over the pane: that would be checked again for every node a streamed chunk inserts
          // into the transcript, and restyle the composer each time.
          data-asks={hasBottomAsk ? "" : undefined}
          // data-jump-latest: Jump to latest is up (hidden under the inspector), set by setJumpLatestShown.
          ref={setPaneMain}
        >
          <div ref={setToastTop} className="acpmux-toasts-top" />
          {!harnessesOpen &&
            showNewTab &&
            !newTab.history &&
            !newTabApp &&
            pageStyle(shownTemplate(newTab)) !== "minimal" && (
              <StyleSwitch
                current={pageStyle(shownTemplate(newTab))}
                onPick={(next) =>
                  pickNewTabStyle(next, {
                    callNative,
                    show: (template) => setNewTab((current) => current && { ...current, template }),
                  })
                }
                onCancel={() => window.dispatchEvent(new Event(FOCUS_LOCATION_EVENT))}
              />
            )}
          {showNewTab && folderAskView}
          {newTabApp && !harnessesOpen ? (
            <NewTabAppPage
              key={`${newTabGeneration}:${newTabApp}`}
              app={newTabApp}
              {...(newTab?.cwd ? { cwd: newTab.cwd } : {})}
              onUnavailable={() => setNewTabAppGone(newTabAdoptions)}
              inputToken={newTab?.inputToken}
              onInputReady={(token) => void callNative("newTab.inputReady", { token })}
            />
          ) : showNewTab && !newTab.history && shownTemplate(newTab) !== "classic" ? (
            <>
              {/* Setup keeps this page's draft and project, while its hidden input effects stop. */}
              <Activity mode={harnessesOpen ? "hidden" : "visible"}>
                <NewTabScreen
                  // `@computer-use` held on the send's own gesture, before the page waits or starts anything (CMUX-682).
                  // A page whose chats start on another machine (an inherited remote workspace: the client starts
                  // them on the first send) is that machine's, whatever the screen's own pick says.
                  holdsSend={(text, place, late) =>
                    holdsForComputerUseSetup(
                      text,
                      true,
                      place === "here" && (newTab.startsRemote || directClient.current?.startsOnSend)
                        ? "machine"
                        : place,
                      !late,
                    )
                  }
                  onSetup={(resume) => {
                    setupContinuation.current = resume;
                    setHarnessesOpen(true);
                  }}
                  onCmuxCommand={(command, args) => handleCmuxCommand(command, args, true)}
                  onImportFile={importFile}
                  importError={importError}
                  importSandboxed={sandbox.mode === "sandboxed"}
                  // The machine the person last picked for a new chat (cmux#46019), while acpmux lists it.
                  {...(newTabStartMachine ? { startMachine: newTabStartMachine } : {})}
                  onCommands={(harness, cwd) => {
                    void callNative("chat.new", { harness, ...(cwd ? { cwd } : {}), deferred: true }).catch(
                      () => undefined,
                    );
                  }}
                  key={newTabGeneration}
                  environments
                  onLeaveDraft={leaveNewTabDraft}
                  takeDraft={takeNewTabDraft}
                  {...(cloudPickPending ? { cloudPick: takeCloudPick } : {})}
                  {...(cloudHintShown ? { cloudHint: { onClose: cloudHint.close } } : {})}
                  {...(newTabRunMode
                    ? {
                        runMode: newTabRunMode,
                        // A page-side refusal goes to the chat view, which says why (SandboxRunView), with
                        // the prompt and attachments put back in its composer.
                        ...(!cloudStart && cloudWaitsForCheck && !sandbox.unread
                          ? {
                              cloudStatus: (
                                <output className="acpmux-switch-notice">
                                  <span>{t("cloudStart.checkingTab")}</span>
                                </output>
                              ),
                            }
                          : {}),
                        ...(!cloudStart && typeof cloudHeld === "object"
                          ? {
                              cloudStatus: (
                                <output className="acpmux-switch-notice acpmux-folder-choice">
                                  <span role="alert">{cloudHeld.refusal}</span>{" "}
                                  <button
                                    type="button"
                                    className="acpmux-folder-choice-button"
                                    onClick={() => {
                                      const { prompt, cwd } = cloudHeld;
                                      setCloudHeld(undefined);
                                      void openCloudChatWith({
                                        ...(prompt ? { prompt } : {}),
                                        ...(cwd ? { cwd } : {}),
                                      }).catch(() => undefined);
                                    }}
                                  >
                                    {t("cloudStart.openNewCloudChat")}
                                  </button>
                                </output>
                              ),
                            }
                          : {}),
                        ...(cloudStart
                          ? {
                              cloudStatus: (
                                <CloudStartView
                                  start={cloudStart}
                                  bubble={cloudStart.state === "starting"}
                                  onAnswer={answerCloudStart}
                                  onRetry={retryCloudStart}
                                  onSignIn={cloudSignInRetry}
                                  planStore={cloudPlanStore}
                                  onRunHere={runCloudHere}
                                  onDismiss={dismissCloudFailure}
                                  onSwitchTeam={switchTeamAndRetry}
                                  onOpenNewCloudChat={openNewCloudChatForStart}
                                  {...cloudTooBigActions}
                                  onSetUp={setUpCloud}
                                  onSetUpDismiss={dismissCloudSetUp}
                                />
                              ),
                            }
                          : {}),
                        // The page stays locked through a stall: its send would start a chat in this tab.
                        cloudStarting: cloudSendHeld || cloudPageHeld,
                        onCloud: (
                          harness: string,
                          text: string,
                          cwd: string | undefined,
                          model: string | undefined,
                          attachments: ComposerAttachment[],
                        ) => {
                          // A Cloud chat has no Computer Use tools: @computer holds here, with the notice (cmux#48541).
                          if (holdsForComputerUseSetup(text, true, "cloud")) return false;
                          const folder = cloudStartFolder(cwd);
                          // New Tab sends use this callback directly, so record their complete folder too.
                          // Otherwise Retry would reuse the pane's previous folder.
                          cloudRetryFolder.current = folder;
                          return sendToCloud(
                            text,
                            attachments,
                            {
                              ...folder,
                              // The agent the Mode chip names and its pick: a harness with no
                              // Cloud start mode is left out, so the machine starts Claude.
                              ...cloudSendAgent(
                                snapshot.catalog.find((entry) => entry.id === harness)?.family,
                                harness,
                                model,
                              ),
                            },
                            true,
                          );
                        },
                        onSandbox: (harness: string, text: string, attachments: ComposerAttachment[]) => {
                          // A sandbox is another machine, with no Computer Use tools (cmux#48541).
                          if (holdsForComputerUseSetup(text, true, "machine")) return false;
                          // Only a run this tab can make goes: a Sandboxed pick left over once a session opened here is refused.
                          const started = sandboxing ? startSandbox(text, attachments.length, harness) : sandboxNotNow;
                          if (started !== false) newTabSandboxSent.current = true;
                          if (typeof started !== "string") return started;
                          heldBack.current = [...(heldBack.current ?? []), { text, attachments }];
                          setSandboxDraftMoved(true);
                          sandbox.refuse(text, started);
                          return true;
                        },
                      }
                    : {})}
                  onConnect={connectMachine}
                  onRefreshMachines={() => void directClient.current?.refreshPeers()}
                  onNewProject={(name) => {
                    const client = directClient.current;
                    return client?.newProjectSupported
                      ? client.newProject(name)
                      : Promise.reject(new NewProjectUnsupported());
                  }}
                  onNewWorktree={(cwd) => {
                    let folder: string | undefined;
                    return newWorktree(callNative, cwd, (used) => {
                      folder = used;
                    }).then(() => folder);
                  }}
                  accessory={<DictationMic dictation={dictation} />}
                  upload={uploadFiles}
                  dictating={isWaitingForWords(dictation.state)}
                  dictationField={newTabDictationField}
                  dictation={dictation}
                  notice={
                    <>
                      <DictationNotice dictation={dictation} />
                      {sandboxUncheckedNotice && sandboxUnchecked}
                    </>
                  }
                  startNotice={trustQuestion}
                  // The host answers only for a page on this Mac; another machine's keeps the refusal.
                  {...(!quick ? { localPaths } : {})}
                  template={screenTemplate(shownTemplate(newTab))}
                  {...(newTab.allChats === false ? { allChats: false } : {})}
                  {...(newTab.suggestionOrder ? { suggestionOrder: newTab.suggestionOrder } : {})}
                  snapshot={
                    commandSession
                      ? {
                          ...newTabSnapshot,
                          commands: withToolCommands(
                            withExtensionCommands(pendingCommands ?? [], extensionCommands),
                            toolCommands,
                          ),
                        }
                      : newTabSnapshot
                  }
                  {...(newTabFixError ? { fixError: newTabFixError } : {})}
                  omnibar={newTab.omnibar}
                  location={newTab.location}
                  lastAgent={newTab.lastAgent}
                  home={newTab.home}
                  {...(newTab.startedProject ? { startedProject: newTab.startedProject } : {})}
                  knownProjects={newTabKnownProjects}
                  {...(newTab.openTabs ? { openTabs: newTab.openTabs } : {})}
                  // The field takes keys from its first render (the host's buffer hands them over at
                  // once); only a submit waits for acpmux (`whenHandshaken`).
                  inputToken={newTab.inputToken}
                  {...(newTab.cwd ? { cwd: newTab.cwd } : {})}
                  {...(startFolder ? { startCwd: startFolder } : {})}
                  onPromptTyped={onNewTabPromptTyped}
                  onCloudMachinePicked={quick ? undefined : onCloudMachinePicked}
                  // Leo, 2026-10-31: "JUST PASSING THE SELECTED FOLDER/'PROJECT' WHEN YOU PICK CLOUD THAT'S
                  // THE BEST WAY. IT JUST GOES IT JUST WORKS". A project picked here goes to the host on its
                  // click (workspace.useFolder, as the chat composer's chip does in chooseProject), so a Cloud
                  // send copies it: cloud.startChat copies only the pane's own folders, and a recent project
                  // this page lists was none until the person sent in it here (#29294). Not on Return: the
                  // grant spends a gesture, and the Return's is the start's. Only a folder Cloud would copy
                  // (never home or above it, cloudStartFolder), and whenever Cloud may be offered, the
                  // host's sandbox check still out included (newTabProjectPick); a home or root answer
                  // asks nothing here (the local start still asks on Return).
                  {...newTabProjectPick(callNative, cloudOfferable, cloudFolderGrant.granting)}
                  {...(!handshaken ? { startPending: true } : {})}
                  {...(newTabChatsPending ? { chatsPending: true } : {})}
                  {...((newTab.host ?? machineName) ? { machineName: (newTab.host ?? machineName)! } : {})}
                  projects={newTabProjects}
                  onBrowseProject={() => callNative<{ cwd?: string }>("project.browse").then((result) => result?.cwd)}
                  // Add folder…: folders the new chat sees beside its project (extraFolders.ts).
                  extraFolders={{
                    draft: extraFolderDraft,
                    onChange: setExtraFolderDraft,
                    onBrowse: () => callNative<{ cwd?: string }>("project.browse").then((result) => result?.cwd),
                  }}
                  chips={registryChips ?? NewTabComposerChips}
                  focusField={newTab.focusesField !== false}
                  onPlusCommand={runNewTabPlusSearch}
                  {...withSubmitAfterHandshake(
                    newTabScreenActions({
                      callNative,
                      cwd: newTab.cwd,
                      chatCwd: startFolder,
                      requestFolder,
                      startsHere: () => !directClient.current?.startsOnSend,
                      // After the screen's own early hold (NewTabScreen `holdsSend`): only holds and says why.
                      holdsSend: (text, here) => holdsForComputerUseSetup(text, true, here ? "here" : "machine", false),
                      // A start belongs to this New Tab visit. Cmd-T adoption, chat selection,
                      // or another start advances the marker and fences every late completion.
                      // Harness starts may reconnect their client while the queued prompt waits;
                      // direct starts remain tied to the client that received the click.
                      startScope: (allowReconnect) => {
                        const generation = newTabStartGeneration.current;
                        const page = newTabGeneration;
                        const client = directClient.current;
                        return () =>
                          newTabStartGeneration.current === generation &&
                          newTabGeneration === page &&
                          (allowReconnect || directClient.current === client);
                      },
                      // The chat's composer glides from where New Tab's drew (composer/composerHandover.ts).
                      leave: () => {
                        holdComposerPlace();
                        setNewTab(undefined);
                      },
                      selectSession,
                      showAllChats,
                      runShell: (command, cwd) => {
                        if (cwd) setProjectDraft(cwd);
                        shellRuns.start(command, cwd ? { cwd } : {});
                      },
                      clearError: () => setNewTabFixError(undefined),
                      showError: (error) => {
                        console.warn("agent pane: Fix in a new worktree failed", error);
                        setNewTabFixError(knownRefusalText(error) ?? translate("chat.newFailed"));
                      },
                    }),
                  )}
                  // A chat card's Compress Chat or Decompress Chat: acpmux's cold archive, on this page's
                  // connection. acpmux answers it to this Mac's own app only, never a remote one.
                  {...(snapshot.origin !== "remote" && snapshot.origin !== "peer"
                    ? {
                        onColdArchive: (sessionId: string, archived: boolean) =>
                          directClient.current?.coldArchive(sessionId, archived) ??
                          Promise.reject(new Error(translate("error.notOpen"))),
                      }
                    : {})}
                />
              </Activity>
              {harnessesOpen && harnessesPage}
            </>
          ) : harnessesOpen ? (
            harnessesPage
          ) : contextOpen && !showNewTab ? (
            contextPage
          ) : showNewTab && newTab.history ? (
            <HistoryScreen
              load={(params) => callNative<AllChatsPage | undefined>("chats.page", params)}
              onOpen={(key) => callNative("chats.open", { key })}
              onOpenInTerminal={(key) => void callNative("chats.openInTerminal", { key }).catch(() => undefined)}
              onViewOnly={(key) => void callNative("chats.watch", { key }).catch(() => undefined)}
              // Waiting on you and Costs read this Mac's acpmux, which answers them to its own app only
              // (an older acpmux that names no origin says on the tab that it keeps neither yet).
              {...(snapshot.origin !== "remote" && snapshot.origin !== "peer"
                ? historyPages({
                    client: () => directClient.current,
                    callNative,
                    selectSession,
                    asks: snapshot.asks ?? [],
                    sessions: snapshot.sessions,
                  })
                : {})}
            />
          ) : showNewTab ? (
            <NewTabPage
              holdsSend={(text) =>
                holdsForComputerUseSetup(
                  text,
                  true,
                  newTab.startsRemote || directClient.current?.startsOnSend ? "machine" : "here",
                )
              }
              onCmuxCommand={(command, args) => handleCmuxCommand(command, args, true)}
              onImportFile={importFile}
              importError={importError}
              importSandboxed={sandbox.mode === "sandboxed"}
              key={newTabGeneration}
              snapshot={newTabSnapshot}
              hotkeys={newTab.hotkeys}
              initialKind={newTab.initialKind}
              cwd={newTab.cwd}
              {...(newTab.startedProject ? { startedProject: newTab.startedProject } : {})}
              {...(newTab.home ? { home: newTab.home } : {})}
              knownProjects={newTabKnownProjects}
              host={newTab.host ?? machineName}
              location={newTab.location}
              omnibar={newTab.omnibar}
              projects={newTabProjects}
              // The same deferred chips as the other templates: a pick before the chat starts opens
              // the page's chat behind it, as on the New Tab screen, never the active chat's path.
              chips={registryChips ?? NewTabComposerChips}
              {...(newTab.lastAgent ? { lastAgent: newTab.lastAgent } : {})}
              // A terminal or browser tab opens at once; a chat waits for acpmux (cx-hnpxh).
              onSubmit={newTabPageSubmit({
                callNative,
                whenHandshaken,
                startChat: chatFromNewTab,
                // After the page's own hold on Return (NewTabPage `holdsSend`) and its wait for files: holds and says why.
                holdsSend: (text) =>
                  holdsForComputerUseSetup(
                    text,
                    true,
                    newTab.startsRemote || directClient.current?.startsOnSend ? "machine" : "here",
                    false,
                  ),
              })}
              onJump={(target, id) => void callNative("tab.jump", { target, id })}
              onOpenSession={selectSession}
              onShowAll={showAllChats}
              onBrowseProject={() => callNative<{ cwd?: string }>("project.browse").then((result) => result?.cwd)}
              onEditShortcut={(kind) => void callNative("shortcut.edit", { kind })}
              inputToken={newTab.inputToken}
              onInputReady={(token) => void callNative("newTab.inputReady", { token })}
              onLeaveDraft={leaveNewTabDraft}
              takeDraft={takeNewTabDraft}
              onFieldEdit={newTabFieldEdited}
            />
          ) : replaying && replaying === snapshot.sessionId ? (
            <ReplayScreen
              sessionId={replaying}
              title={snapshot.summary?.title || snapshot.summary?.name}
              load={loadReplay}
              onClose={() => setReplaying(undefined)}
              onContinue={
                snapshot.canFork
                  ? (throughSeq) => {
                      setReplaying(undefined);
                      void directClient.current?.fork(throughSeq);
                    }
                  : undefined
              }
              transcript={(replayed) => (
                <VirtualTranscript
                  // The replayed rows fold into turns as the live chat's do (turnViewFrom above):
                  // raw, a turn's tool calls sit in activity rows the transcript draws no line for.
                  rows={turnView(replayed.rows, folds, {
                    working: replayed.isWorking,
                    clockOffset: replayed.clockOffsetMs,
                    turnStartedAtMs: replayed.turnStartedAtMs,
                    agentFamily: replayed.summary?.family ?? snapshot.summary?.family,
                  })}
                  sessionId={`replay:${replaying}`}
                  // A replay draws under its chat's view too (conversation/viewFolds.ts), as the live transcript.
                  expanded={folds}
                  showMinimap={minimapVisible}
                  // It draws in the same .acpmux-main, so its column ends where the live one's does.
                  endReserve={columnEndReserve}
                  minimapBeside={chatMinimapBeside}
                  registry={noDismissRegistry}
                  onToggleActivity={toggleActivity}
                />
              )}
            />
          ) : null}
          {(showsChatView || premountsChatView) && (
            // Its own key space: the classic page beside it is keyed by `newTabGeneration` (0 and up),
            // and a shared key let React lose the page's fiber and mount the page again beside it.
            <Activity
              key={`chat-view-${chatViewMount.current.key}`}
              mode={showsChatView || parkVisible ? "visible" : "hidden"}
            >
              <div
                className={`acpmux-stage${inspectorOpen ? " acpmux-inspecting" : ""}`}
                data-solo-tab={soloUnder ? "" : undefined}
                style={parkStyle ?? (inTabRow ? tabRowStyle(tabRow) : undefined)}
                inert={parkedVisible || undefined}
              >
                {/* In the tab row the native tabs draw over this band, so a tooltip stays out of it
                      (ui/titleTooltips.ts `data-tooltip-covered`). */}
                <header
                  className="acpmux-header"
                  data-tab-row={inTabRow ? "" : undefined}
                  data-tooltip-covered={inTabRow ? "" : undefined}
                >
                  <ChatHeaderStatus status={header.status} detail={header.detail}>
                    {!inTabRow && !showNewTab && snapshot.sessionId && (
                      <span className="acpmux-header-status-content">
                        <ThreadTitle key={snapshot.sessionId} title={chatName} onRename={renameFromTitle} />
                        {/* Where the chat stands and its next action (header/ChatSummaryLine.tsx). */}
                        <ChatSummaryLine summary={snapshot.summary?.rollingSummary} />
                      </span>
                    )}
                  </ChatHeaderStatus>
                  <div className="acpmux-handoff-header-tools" ref={tabRowTools}>
                    {liveTreeEnabled && snapshot.sessionId && (
                      <LiveTreePill key={snapshot.sessionId} cwd={snapshot.summary?.cwd} readStatus={readLiveTree} />
                    )}
                    <LivePresenceStack
                      sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
                      fallback={snapshot.presence}
                    />
                    {/* No Share button here: Share… lives in the ••• menu (Leo, 2026-11-07: "would that
                          defeat the minimalism? ... you'd want to put it in the dot dot dot area").
                          This only hosts its dialog; the faces before it draw only when someone else
                          is here. */}
                    {snapshot.sessionId && !showNewTab && hasNativeHost() && (
                      <ShareDialogHost
                        key={snapshot.sessionId}
                        sessionId={snapshot.sessionId}
                        chat={chatName}
                        open={shareOpen}
                        onOpenChange={setShareOpen}
                      />
                    )}
                    {/* No title in the tab row: the pane's tab already names the chat (Leo, 2026-11-01). */}
                    {inTabRow && (
                      <ChatHeaderInlineStatus status={header.status} detail={header.detail}>
                        {!showNewTab && snapshot.sessionId ? (
                          <ChatSummaryLine summary={snapshot.summary?.rollingSummary} inline />
                        ) : undefined}
                      </ChatHeaderInlineStatus>
                    )}
                    <ChatHeaderTools
                      chat={snapshot.sessionId}
                      nativeRowTools={{
                        enabled: inTabRow && tabRow.nativeRowTools === true && !inspectorOpen,
                        callNative,
                        panel: sessionInfo.on
                          ? {
                              // The native row's wire id for Session Info's toggle (header/nativeRowTools.ts), kept as the host knows it.
                              id: "inspector",
                              label: t("sessionInfo.title"),
                              toggled: sessionInfo.shown === true,
                              run: sessionInfo.toggle,
                            }
                          : {
                              id: "summary",
                              label: t("summary.open"),
                              toggled: summaryCard.shown,
                              run: summaryCard.toggle,
                            },
                      }}
                      nativeNeedsYou={{ items: needsYou.items, mode: needsYou.mode, actions: needsYou.actions }}
                      tabTools={!quick}
                      pullRequestChip={!readOnlySubagent}
                      // A new chat's picked folder too: New Worktree names its branch before the first prompt.
                      folder={localCwd ?? (remoteChat ? undefined : startFolder)}
                      readStatus={readFolderStatus}
                      statusKey={snapshot.isWorking}
                      working={snapshot.isWorking === true}
                      // Apply brings a worktree chat's work to its main checkout (cx-lyqio.4); a new chat has none yet.
                      onApplyWorktree={
                        snapshot.sessionId && localCwd
                          ? (key: string) =>
                              callNative("git.worktree.apply", {
                                session_id: snapshot.sessionId,
                                idempotency_key: key,
                              })
                          : undefined
                      }
                      // Remove cleans the worktree up (cx-lyqio.5); discard only on "Remove anyway".
                      onRemoveWorktree={
                        snapshot.sessionId && localCwd
                          ? (key: string, discard: boolean) =>
                              callNative("git.worktree.remove", {
                                session_id: snapshot.sessionId,
                                idempotency_key: key,
                                ...(discard ? { discard: true } : {}),
                              })
                          : undefined
                      }
                      // A merge asks the header again, so the chip shows the pull request merged.
                      onMergePullRequest={
                        localCwd
                          ? ({ number, url }) =>
                              callNative("git.pullRequest", { action: "merge", number, url }).then((value) => {
                                const result = value as {
                                  merged?: unknown;
                                  queued?: unknown;
                                } | null;
                                if (result?.merged !== true && result?.queued !== true)
                                  throw new Error(translate("header.prMergeFailed"));
                                void callNative("pane.tabState", { refresh: true })
                                  .then(setHeaderState)
                                  .catch(() => undefined);
                                return { queued: result.queued === true };
                              })
                          : undefined
                      }
                      // The glass toolbar's search chip (Settings > Advanced > Experiments): the palette's chats page.
                      onSearch={showAllChats}
                      onTerminal={(mode) => runSplitAction(HEADER_ACTIONS.terminal, localCwd, mode)}
                      onSplitDown={(mode) => runSplitAction(HEADER_ACTIONS.splitDown, localCwd, mode)}
                      onBrowser={(mode) => runSplitAction(HEADER_ACTIONS.browser, undefined, mode)}
                      // Changes owns the diff of the chat's folder, read on the chat's machine (a Cloud chat's too).
                      hasChanges={lastEditTurn !== undefined && chatCwd !== undefined}
                      onChanges={toggleChanges}
                      onFiles={localCwd ? (mode) => runSplitAction(HEADER_ACTIONS.files, localCwd, mode) : undefined}
                      previewUrl={previewUrl}
                      onPreview={(url, mode) => {
                        ignoreFailure(
                          callNative("pane.action", {
                            id: HEADER_ACTIONS.preview,
                            ...(url ? { url } : {}),
                            mode,
                          }),
                        );
                        window.setTimeout(refreshTabState, 400);
                      }}
                      sideTabs={sideTabs}
                      onSideTabs={toggleSideTabs}
                      onPointerEnter={quick ? undefined : refreshTabState}
                      onCustomize={(list) => {
                        // Shown at once; the App saves it to layout.json, whose watch pushes it to every chat.
                        // A save the App refused (layout.json mid-edit) puts the buttons back.
                        const before = quickActions();
                        configureQuickActions({ quickActions: list });
                        callNative("pane.setQuickActions", { quickActions: list }).catch(() =>
                          configureQuickActions({ quickActions: before }),
                        );
                      }}
                      sessionInfo={sessionInfo.button}
                      inbox={<NeedsYouButton items={needsYou.items} mode={needsYou.mode} actions={needsYou.actions} />}
                      inboxRelevant={needsYou.items.length > 0}
                      newButton={
                        quick
                          ? undefined
                          : {
                              available: {
                                sideChat: sideChat !== undefined,
                                // chat.newHere needs a started chat that is not a Cloud chat (canMove, as the folder menu's
                                // New Chat) and its folder; another machine's only when absolute.
                                newTab: canMove && chatCwd !== undefined && (!remoteChat || chatCwd.startsWith("/")),
                              },
                              make: (kind) => {
                                if (kind === "terminal") newTerminal();
                                else if (kind === "browser") newBrowser();
                                else if (kind === "sideChat") sideChat?.onSelect?.();
                                // The New Tab page beside the chat, in the chat's folder: it starts a chat or opens anything else.
                                else if (chatCwd) ignoreFailure(callNative("chat.newHere", { cwd: chatCwd }));
                              },
                            }
                      }
                      summary={sessionInfo.on ? null : (native) => <SummaryButton card={summaryCard} native={native} />}
                      menu={chatMenu}
                      onMenuOpen={() => Promise.all([readTabState(true), readChatMini()])}
                      expand={continuing && canContinue ? "continue" : undefined}
                      onExpanded={stopContinuing}
                    />
                  </div>
                </header>
                {/* A feature tip under its header control (featureTips.tsx; it portals out). */}
                {!quick && !showNewTab && snapshot.sessionId && <PaneFeatureTips streaming={turnWorking} />}
                {!sessionInfo.on && !summaryCard.column && summaryPanel}
                {underHeader.checkpointReview && checkpoints.review}
                {/* The lines under the header drop in from the top (ui/popupSurface.css `data-enter`). */}
                {underHeader.liveChat && snapshot.liveChat && (
                  <LiveChatChoice
                    {...snapshot.liveChat}
                    onChoose={(choice) => void callNative("chat.adoptLive", { choice }).catch(() => undefined)}
                  />
                )}
                {underHeader.unavailable && cloudUnavailable && (
                  <ChatUnavailableState
                    line
                    unavailable={cloudUnavailable}
                    onResumeMachine={cloudRecovery.resume}
                    resuming={cloudRecovery.resuming}
                    error={cloudRecovery.error}
                    {...(machineName ? { machine: machineName } : {})}
                    onRemove={() => runHeaderAction(HEADER_ACTIONS.close)}
                    onReconnect={() => {
                      cloudRecovery.refresh();
                      void directClient.current?.recheckMissing();
                    }}
                    onResume={showAllChats}
                    onClose={() => runHeaderAction(HEADER_ACTIONS.close)}
                  />
                )}
                {underHeader.peerCopy && snapshot.peerCopy && (
                  <PeerCopyBanner
                    key={`${snapshot.sessionId ?? ""}:${snapshot.peerCopy.peer}`}
                    copy={snapshot.peerCopy}
                    machine={peerMachine.state}
                    onResume={peerMachine.resume}
                    asked={peerMachine.asked}
                    onReconnect={reconnectPeer}
                    // An ssh peer's offline copy waits out acpmux's own redial (LINK_DOWN_SAID_MS): a
                    // drop that heals on its own says nothing (Leo, 2026-11-14).
                    noteDelayMs={snapshot.peerKinds?.[snapshot.peerCopy.peer] === "ssh" ? LINK_DOWN_SAID_MS : undefined}
                  />
                )}
                {/* Computer use's live preview: the app this chat's agent drives, at the top right. Always
                      mounted: with no card it draws the last one's exit, then nothing (cardMotion.ts). */}
                <ComputerUsePreviewCard
                  preview={previewShown ? computerUsePreview : null}
                  onClose={() => ignoreFailure(callNative("chat.computerUsePreview", { action: "close" }))}
                />
                {underHeader.watching && snapshot.summary?.watching && !snapshot.liveTakeOver && (
                  <WatchBanner
                    family={snapshot.summary.watching}
                    bridged={snapshot.summary.bridged === true}
                    onTakeOver={() => void directClient.current?.takeOver().catch(() => undefined)}
                    onContinue={() => void directClient.current?.continueWatched().catch(() => undefined)}
                  />
                )}
                {underHeader.watching && snapshot.liveTakeOver && (
                  <LiveChatChoice
                    {...snapshot.liveTakeOver}
                    onChoose={(choice) => void callNative("chat.adoptLive", { choice }).catch(() => undefined)}
                  />
                )}
                {underHeader.handoffError && snapshot.handoff?.error && (
                  <p className="acpmux-handoff-error" role="alert" data-enter="top">
                    {snapshot.handoff.error}
                  </p>
                )}
                {viewedSandbox ? (
                  // The person opened the tab's Sandboxed Run: it shows whatever the chat's state
                  // (its composer is hidden while it does).
                  <SandboxRunView
                    run={viewedSandbox}
                    onCheckAgain={() => void sandbox.read()}
                    unread={sandbox.unread}
                    onBack={() => {
                      pendingWake.current = sandboxWake.current ?? pendingWake.current;
                      sandboxWake.current = undefined;
                      setSandboxViewing(false);
                    }}
                  />
                ) : reviewing && handoff && snapshot.handoff ? (
                  <HandoffReviewMessage
                    key={`${handoff.handoffId}:${reviewReload}`}
                    record={handoff}
                    state={snapshot.handoff}
                    strings={handoffLabels}
                    onSave={(review) => callNative("chat.handoff.draft", { review })}
                    onStart={(review) => callNative("chat.handoff.start", { review })}
                    onReturn={() => selectSession(handoff.source.sessionId)}
                    onDiscard={() => ignoreFailure(callNative("chat.handoff.discard"))}
                    onReload={() =>
                      ignoreFailure(callNative("chat.handoff.get").then(() => setReviewReload((value) => value + 1)))
                    }
                  />
                ) : cloudUnavailable && !missingRows ? (
                  // The tab's chat is not here: which case it is, centered where the chat would be.
                  <ChatUnavailableState
                    unavailable={cloudUnavailable}
                    onResumeMachine={cloudRecovery.resume}
                    resuming={cloudRecovery.resuming}
                    error={cloudRecovery.error}
                    {...(snapshot.missingSession ? { session: snapshot.missingSession } : {})}
                    {...(machineName ? { machine: machineName } : {})}
                    onRemove={() => runHeaderAction(HEADER_ACTIONS.close)}
                    onReconnect={() => {
                      cloudRecovery.refresh();
                      void directClient.current?.recheckMissing();
                    }}
                    onResume={showAllChats}
                    onClose={() => runHeaderAction(HEADER_ACTIONS.close)}
                  />
                ) : freshView && pastTurns && (!pastWaitsForTrust || trustAsk.ask) ? (
                  <PastChat turns={pastTurns} {...(githubRepository ? { githubRepository } : {})} />
                ) : cloudStartShown ? (
                  <CloudStartView
                    start={cloudStart}
                    onAnswer={answerCloudStart}
                    onRetry={retryCloudStart}
                    onSignIn={cloudSignInRetry}
                    planStore={cloudPlanStore}
                    onRunHere={runCloudHere}
                    onDismiss={dismissCloudFailure}
                    onSwitchTeam={switchTeamAndRetry}
                    onOpenNewCloudChat={openNewCloudChatForStart}
                    {...cloudTooBigActions}
                    onSetUp={setUpCloud}
                    onSetUpDismiss={dismissCloudSetUp}
                  />
                ) : sandboxView && !snapshot.sessionId && (sandboxHoldsChat || sandbox.mode === "sandboxed") ? (
                  <SandboxRunView
                    run={sandboxView}
                    onCheckAgain={() => void sandbox.read()}
                    unread={sandbox.unread}
                    // Sandboxed can't run here now: the person says how the message goes instead.
                    {...(sandboxRetryable(sandboxView) ? { onPersistent: () => sandbox.setMode("persistent") } : {})}
                  />
                ) : freshView && !premountsChatView ? (
                  <EmptyState
                    project={projectName(composerSnapshot.summary?.cwd)}
                    picker={heroPicker}
                    tour={tourOffer}
                  />
                ) : (
                  <AgentTonesContext.Provider value={chatTones}>
                    <AgentNamesContext.Provider value={chatAgentNames}>
                      <AgentOpenContext.Provider value={chatAgentOpen}>
                        <BackgroundTaskOutputContext.Provider value={backgroundTaskOutput}>
                          <TourStartContext.Provider value={tourHere ? startTourTask : undefined}>
                            {transcript}
                          </TourStartContext.Provider>
                        </BackgroundTaskOutputContext.Provider>
                      </AgentOpenContext.Provider>
                    </AgentNamesContext.Provider>
                  </AgentTonesContext.Provider>
                )}
                {displayAnchor && (
                  <ChatDisplaySettings
                    open
                    anchor={displayAnchor}
                    onOpenChange={(open) => !open && setDisplayAnchor(null)}
                  />
                )}
                {inspectorOpen && (
                  <Inspector
                    snapshot={snapshot}
                    sessionEvents={() => directClient.current?.sessionEvents() ?? []}
                    onClose={closeInspector}
                    onExport={saveLogNatively}
                    perf={sendPerf}
                  />
                )}
              </div>
              <div
                ref={setDock}
                className="acpmux-dock"
                style={parkStyle}
                inert={parkedVisible || undefined}
                // The stack holds the composer, whose card always draws its quiet row (ComposerFoot):
                // bottomStack.css gives the transcript up first for it, from this, not from a
                // `.acpmux-dock:has(.acpmux-composer-foot)` checked again for every inserted node.
                data-foot={dockFoot ? "" : undefined}
              >
                {/* The pane's toasts stand on the stack's top edge, over the transcript (ToastLayer.tsx). */}
                <ToastLayer queue={paneToasts} topHost={toastTop} />
                {asks}
                {/* Between the hero and the docked composer. */}
                {/* A Sandboxed send holds the new chat: no recent chat replaces it while it is out.
                      Neither does a Cloud start's chat, which shows its sent message (CloudStartView). */}
                {freshView && !premountsChatView && !sandboxHoldsChat && !viewedSandbox && !cloudStartShown && (
                  <div className="acpmux-home-area">
                    {dotGridArm !== "off" && (
                      <AgentDotGrid
                        sessions={snapshot.sessions}
                        currentId={snapshot.sessionId}
                        onSelect={selectSession}
                        size={dotGridArm === "compact" ? "compact" : "regular"}
                      />
                    )}
                    <HomeLists
                      sessions={snapshot.sessions}
                      currentId={snapshot.sessionId}
                      asks={snapshot.asks}
                      tabs={needsYou.attentionTabs}
                      onSelect={selectSession}
                      onOpen={(item) =>
                        item.kind === "tab" ? needsYou.actions.goTo(item) : selectSession(item.sessionId)
                      }
                      onAnswer={(item, choice) => answerFromHome(callNative, item, choice, selectSession)}
                      shortcuts={!hasBottomAsk}
                    />
                  </div>
                )}
                {hostLine}
                {forkPendingLine}
                <LiveTypingLine
                  sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
                  fallback={snapshot.presence}
                />
                {/* A draft a refusal put back stays in reach even once the tab's run shows. */}
                {dockFoot && composer}
              </div>
            </Activity>
          )}
        </div>
        {!harnessesOpen &&
          !showNewTab &&
          !(replaying && replaying === snapshot.sessionId) &&
          !inspectorOpen &&
          !sessionInfo.on &&
          summaryCard.column &&
          summaryPanel}
        {/* Beside the chat view only: New Tab, Harnesses and a replay have no session header. */}
        {!harnessesOpen &&
          !contextOpen &&
          !showNewTab &&
          !(replaying && replaying === snapshot.sessionId) &&
          sessionInfo.panel}
        {artifact && liveArtifact && (
          <ArtifactPanel
            key={artifact.opened}
            artifact={liveArtifact}
            versions={artifactVersionList}
            pinned={!!artifact.pinned}
            sourceTitle={artifact.sourceTitle}
            onPinChange={
              artifact.sessionId
                ? (pinned) =>
                    setArtifact((current) =>
                      changeArtifactPin(current, pinned, snapshot.sessionId, artifactVersionList),
                    )
                : undefined
            }
            onClose={() => setArtifact(undefined)}
            onSave={saveDocumentNatively}
          />
        )}
        {/* Under the side panel in its column, or the column itself (backgroundTasks.css). */}
        {backgroundPanel && !harnessesOpen && !showNewTab && (
          <SubagentClockContext.Provider value={snapshot.clockOffsetMs ?? 0}>
            {/* A command is a card there, its output read as the composer hat's tail reads it. */}
            <BackgroundTaskOutputContext.Provider value={backgroundTaskOutput}>
              <BackgroundTasksPanel
                groups={backgroundList}
                readsOutput={
                  chatProcessesHere(snapshot.summary) &&
                  clientEpoch > 0 &&
                  directClient.current !== undefined &&
                  backgroundTaskOutput !== undefined
                }
                views={snapshot.subagentViews}
                look={experimentArm(backgroundTasksLook)}
                expanded={backgroundPanel.expanded}
                focus={backgroundFocus}
                stopsAgents={stopSubagent !== undefined}
                workflow={backgroundWorkflowReads}
                ownLog={backgroundOwnLogReads}
                onStop={(target) =>
                  target.kind === "agent"
                    ? (stopSubagent?.(target.id) ?? Promise.reject(new Error()))
                    : stopProcess(target.id)
                }
                onClearFinished={(ids) =>
                  setBackgroundPanel((panel) => panel && { ...panel, dismissed: new Set([...panel.dismissed, ...ids]) })
                }
                // Its own tab has the tab's own close and the whole tab already: no Expand or Close.
                onExpand={
                  ownBackgroundPane
                    ? undefined
                    : () => setBackgroundPanel((panel) => panel && { ...panel, expanded: !panel.expanded })
                }
                onClose={ownBackgroundPane ? undefined : () => setBackgroundPanel(undefined)}
                onOpenSession={openOfferChat}
                onOpenCommand={(task) => {
                  const command = panelCommands.find((candidate) => candidate.id === task.id);
                  if (command) openTrayCommand(command);
                }}
              />
            </BackgroundTaskOutputContext.Provider>
          </SubagentClockContext.Provider>
        )}
        {imageView && (
          <ImageViewer
            images={imageView.images}
            index={imageView.index}
            onIndex={(index) => setImageView((current) => current && { ...current, index })}
            onClose={() => setImageView(undefined)}
          />
        )}
        <CloudEnvironmentEditor />
        <DeleteChatDialog
          open={deleteConfirmOpen}
          onOpenChange={(next) => {
            setDeleteConfirmOpen(next);
            if (!next) {
              setDeleteConfirmSession(undefined);
              deleteInFlight.current = afterDeleteDismiss(
                deleteInFlight.current,
                directClient.current?.purgeInFlight === true,
              );
            }
          }}
          onDismiss={() => {
            setDeleteConfirmOpen(false);
            setDeleteConfirmSession(undefined);
            deleteInFlight.current = afterDeleteDismiss(
              deleteInFlight.current,
              directClient.current?.purgeInFlight === true,
            );
          }}
          onConfirm={() => ignoreFailure(deleteChat())}
          title={t("permission.verb.delete")}
          body={t("chatMenu.deleteConfirmBody")}
          closeLabel={t("chatMenu.close")}
        />
        {workflowSideTab &&
          !harnessesOpen &&
          !showNewTab &&
          !replaying &&
          !inspectorOpen &&
          !artifact &&
          !imageView && (
            <SubagentClockContext.Provider value={snapshot.clockOffsetMs ?? 0}>
              <WorkflowSideTab
                workflow={workflowSideTab}
                onClose={closeWorkflowSideTab}
                onStop={stopSubagent}
                onOpenWorkflowAgent={showWorkflowAgent}
              />
            </SubagentClockContext.Provider>
          )}
      </section>
    </ShortcutsContext.Provider>
  );
}
