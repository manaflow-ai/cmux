// AcpmuxPane's composer tree (RFD 0046 step 2.2): the bottom stack's notices, the hat and the
// composer, or a subagent pane's own composer, moved out of App.tsx as it was. A plain render
// function AcpmuxPane calls inline for its `composer`, so React sees the same element tree (no
// component boundary of its own); every hook stays in AcpmuxPane, and this holds no state.
import type React from "react";
import type { HarnessCatalog } from "../catalog";
import type { useTrustHeldPrompts } from "../trustHeld";
import type { useCloudChatRecovery } from "../useCloudChatRecovery";
import type { useSessionInfo } from "../session-info/useSessionInfo";
import type { useBackgroundNotice } from "../conversation/backgroundNotice";
import type { useStopThroughReconnect } from "../stopThroughReconnect";
import type { clientWaiter } from "../lostPrompt";
import type { DefaultComposerChips } from "./ComposerChips";
import { ShareNudge } from "../share/ShareNudge";
import { chatOnThisMac, chatPlace } from "../chatMachine";
import { thisMacName, type ConnectKind, type OffloadKind } from "../environments";
import { sayActionRefusal } from "../actionRefusal";
import { isTrustRefusal, type AcpmuxDirectClient } from "../direct";
import { postNative } from "../native";
import { knownRefusalText } from "../transportErrors";
import { INSTALL_COMMANDS } from "../harnesses/harnessRows";
import { heldPick } from "../newtab/draftFolder";
import { startThenSend } from "./firstSend";
import { cloudSendAgent, cloudStartModePick } from "../cloudModePick";
import { rememberCloudPick, rememberStartedProject } from "../newtab/startedProject";
import { writePersistedDraft } from "../composerDraft";
import { Composer, type ComposerHandle, type ComposerWake, type ComposerRelay } from "../Composer";
import type { BrowseRequest } from "../browseProject";
import { restoreComposerDraft } from "../composerRestore";
import { openPicker } from "../pickerOpeners";
import { startRefusalRoute } from "../startRefusal";
import { paneKnowsNewChat } from "../locationRow";
import { translate, type Translate } from "../i18n";
import { inThisVisit, type useFolderTrustAsk, composerTrustBlock } from "../useFolderTrustAsk";
import { bindsHeldSendNow } from "../heldSendBinding";
import { TrayPullTab } from "../subagents/TrayPullTab";
import { pullTabCounts } from "../subagents/trayPullTabModel";
import { isWaitingForWords, type Dictation } from "../dictation";
import { SIDE_COMMAND } from "../composer/sendMenuModel";
import { DictationNotice } from "../DictationNotice";
import { DATE, THINKING, WORKING } from "../conversation/turns";
import { switchForks } from "../conversation/messageMenu";
import { DEFAULT_PICK_MODEL, lastPick } from "../lastPick";
import { cloudAgentPick } from "../cloudAgentPick";
import { ImageViewerContext } from "../conversation/imageViewerContext";
import { HarnessStatusCard } from "../HarnessStatusCard";
import { cloudStartFolder, cloudPickExtras } from "../cloudRun";
import { cloneRepository } from "../startFolderModel";
import { repickCloudChat, type RepickMachine } from "../cloudRepick";
import { rememberNewChatPlace } from "../lastNewChatPlace";
import { HarnessHealthNotice } from "../HarnessHealthNotice";
import { Notice } from "../NoticeSlot";
import { AutoResumeNotice } from "../AutoResumeNotice";
import { MoveDock } from "../place/PlaceMounts";
import { OverloadNotice } from "../OverloadNotice";
import type { HostOverload } from "../overloadNoticeModel";
import { liveAutoResume, type TurnPhase } from "../turnPhase";
import { RulesNotice } from "../RulesNotice";
import { composerShell, shellContextAttachments, type ShellRuns } from "../shell/shellRuns";
import { SwitchNotice } from "../SwitchNotice";
import { BACKGROUND_NOTICE_TEXT } from "../conversation/backgroundNotice";
import { InstructionsNotice, type InstructionsFailure } from "../header/InstructionsNotice";
import { FolderChoice } from "../FolderChoice";
import { WorktreeFailure } from "../startFolder";
import { WorktreeSetupNotice } from "../worktreeSetup";
import { MissingFolder } from "../missingFolder";
import { chooseChatFolder } from "../missingFolderModel";
import { ManagedBanner } from "../ManagedBanner";
import { PaneNotices } from "../PaneNotices";
import { PlanScopeDriftNotice } from "../PlanScopeDriftNotice";
import { ComputerUseSetupNotice } from "../computerUse/ComputerUseSetupNotice";
import type { ComputerUseHold, ComputerUsePlace } from "../computerUse/computerUseState";
import { bridgeGone } from "../watchBannerModel";
import { cmuxCommandRefusal, type CmuxCommand, type CmuxCommandResult } from "../cmuxCommands";
import { heldSendNotice } from "../sendFailure";
import { lostPrompt, resentAfterLoss, keepLostPrompt } from "../lostPrompt";
import { guestMention } from "../mentionItems";
import { clearHeldFork, sendHeldFork, heldFork } from "../forkHold";
import { CloudChatHint } from "../CloudChatHint";
import { AutoArrival, AutoAddingMachineLine } from "../AutoWhere";
import { AUTO_LOOK, type AutoLanding } from "../autoWhereModel";
import type { StringKey } from "../i18n";
import { callNative } from "../callNative";
import { editQueued, openSenderChat } from "../rows/rowActions";
import { HatQuestions, type HatQuestionActions } from "../question/HatQuestions";
import { hatShows, type HatQuestion } from "../question/hatModel";
import { keptInChat, removeQueued, sendWhenTaken, heldRefusal, heldGoesAfterTrust, type SentFrom } from "./sendHost";
import { keptAttachments } from "./draftHost";
import { withdrawForTypedReply } from "./hatHost";
import type { AcpmuxSnapshot, AcpmuxRow, AcpmuxPermission } from "../model";
import type { RunMode, SandboxRun, SandboxTab, AutoRow } from "../sandboxRun";
import type { CloudEnvironmentPick } from "../cloudEnvironmentChoice";
import type { CloudChatHintState } from "../cloudChatHintModel";
import type { MachineHarnessCheck } from "../machineHarnesses";
import { type CloudSignIn, refusedStartSignIn } from "../cloudAgentLogin";
import type { HarnessHealth, UpdateOffer } from "../harnessHealthNoticeModel";
import type { ForumRule } from "../rulesNoticeModel";
import type { ShareNudgeState } from "../share/shareNudgeModel";
import type { PaneNotices as PaneToasts } from "../paneToasts";
import type { ManagedBy } from "../managedBy";
import type { SubagentTrayPlacement } from "../subagents/subagentTrayPlacement";
import type { TrayItem } from "../subagents/runningTray";
import type { TrayHandleSide } from "../chatDisplay";
import { hatPillInMiddle, hatPillQuiet, type HatPillPlace } from "../hatPillPlace.experiment";
import type { SwitchView, HarnessSwitch } from "../harnessSwitch";
import type { CloudMachine } from "../cloudMachines";
import type { ComposerAttachment, DroppedKind, KnownPaths } from "../attachments";
import type { SendGesture } from "../heldPrompt";
import type { LocalCommand } from "../localCommands";
import type { SendToCloud } from "./useCloudSend";
import type { TurnFile } from "../diffTypes";
import type { PathRef } from "../diff";
import type { BtwNotes } from "../aside/btwNotes";
import type { PaneSurface } from "../paneSurface";
import type { StartingSends } from "../startingSends";
import type { HeaderMoveTarget } from "../header/headerState";
import type { Project } from "../ProjectChooser";
import type { ExtraFolderDraft } from "../extraFolders";
import type { FileSearchSource } from "../fileSearchModel";
import type { ComposerPlusExtension, CaptureMode } from "../composerPlusRegistry";
import type { UploadProgressReport, UploadResult } from "../cloudUploads";
import type { MarkdownFieldHandle } from "../MarkdownField";
import { commandPlace } from "../commandPlace";

/// A worktree start that failed, and where (App.tsx `worktreeError`).
type WorktreeError = {
  cwd: string;
  sessionId?: string;
  visit?: string;
  github?: { repo: string; candidates: string[] };
  message?: string;
};

/// What AcpmuxPane's render hands its composer tree: each value as the render worked it out.
export type PaneComposerDeps = {
  /// The dock's focus edge (App.tsx `markDockEdge`): the composer reports focus-visible in its card.
  markDockEdge: (lit: boolean) => void;
  /// acpmux's overload verdict for this Mac (App.tsx `useHostOverload`); the notice shows only when over.
  hostOverload: HostOverload | undefined;
  readOnlySubagent: boolean;
  /// The Composer relayed to the subagent a subagent pane shows (Composer.tsx `relay`).
  subagentRelay: ComposerRelay | undefined;
  subagentDraftKey: string;
  /// A message to the subagent did not reach the chat: its note shows over the box.
  subagentFailed: boolean;
  /// acpmux's queue for the composer's queued cards, the same list while it holds the same prompts.
  composerTurnQueue: AcpmuxSnapshot["queue"];
  t: Translate;
  reviewing: boolean;
  snapshot: AcpmuxSnapshot;
  dictation: Dictation;
  cloudHintShown: boolean;
  showNewTab: boolean;
  composerModeRows: {
    onMode: (mode: RunMode) => void;
    sandbox?: false | undefined;
    mode: RunMode;
    environment: CloudEnvironmentPick;
    auto?: AutoRow;
  };
  /// Where Auto put this page's chat (AutoArrival), or `deciding` while the daemon answers.
  autoArrival: AutoLanding | "deciding" | undefined;
  autoAddingMachine: StringKey | undefined;
  /// The arrival line's move is offered now (the chat's own move menu offers it).
  autoArrivalMove: boolean;
  onAutoArrivalDismiss: () => void;
  /// Auto picked: the daemon decides where the Send goes first (App.tsx `autoSendGate`).
  autoSendGate: {
    picked: boolean;
    holds: () => boolean;
    cloudStart: () => { autoLanding?: AutoLanding };
    once: <A extends unknown[], R>(send: (...args: A) => R) => (...args: A) => R;
  };
  cloudHint: CloudChatHintState;
  machineCheck: MachineHarnessCheck;
  machinePeer: string | undefined;
  catalog: HarnessCatalog;
  machineSelected: string | undefined;
  importError: string | undefined;
  instructionsFailure: { cwd: string; failure: InstructionsFailure } | undefined;
  openInstructions: (cwd: string, name: string) => void;
  setInstructionsFailure: React.Dispatch<
    React.SetStateAction<{ cwd: string; failure: InstructionsFailure } | undefined>
  >;
  harnessCard: React.JSX.Element | undefined;
  startsElsewhere: boolean;
  chatSignIns: {
    cloudSignIn: CloudSignIn | undefined;
    apiKeySignIn: CloudSignIn | undefined;
    refusedSignIn: CloudSignIn | undefined;
    localRefusedSignIn: CloudSignIn | undefined;
    healthSignIn: CloudSignIn | undefined;
  };
  switchLoginCommand: string | undefined;
  composerHandle: React.RefObject<ComposerHandle | null>;
  healthStale: React.RefObject<boolean>;
  connectMachine: (kind: ConnectKind) => undefined;
  chooseWorkspaceFolder: (request?: BrowseRequest) => Promise<string | undefined>;
  machineName: string | undefined;
  targetSignInHealth: HarnessHealth | undefined;
  harnessHealth: HarnessHealth | undefined;
  healthHarness: string | undefined;
  recheckHealth: () => void;
  setUpdateOffer: React.Dispatch<React.SetStateAction<UpdateOffer | undefined>>;
  setSignInNoticeVisible: React.Dispatch<React.SetStateAction<boolean>>;
  rulesLocal: boolean;
  rules: ForumRule[];
  folderNeeded: { reason: string; error?: string | undefined } | undefined;
  directClient: React.RefObject<AcpmuxDirectClient | undefined>;
  setFolderNeeded: React.Dispatch<React.SetStateAction<{ reason: string; error?: string | undefined } | undefined>>;
  folderAskView: React.JSX.Element | null;
  folderChoiceOffered: boolean;
  folderError: string | undefined;
  background: ReturnType<typeof useBackgroundNotice>;
  liveTurnPhase: TurnPhase;
  shareNudge: ShareNudgeState;
  setShareOpen: React.Dispatch<React.SetStateAction<boolean>>;
  notices: PaneToasts;
  /// A started chat's Local, Cloud, Auto chips (undefined in the floating chat or before a session): one element per
  /// chat and toast sink, so a pane render that changes neither hands the composer the same one.
  placeControl: React.ReactNode | undefined;
  worktreeCreatingHere: boolean;
  worktreeSetupHere: boolean;
  worktreeSetupFolder: string | undefined;
  worktreeCreating: false | { sessionId?: string | undefined; visit?: string | undefined; repo?: string | undefined };
  worktreeError: WorktreeError | undefined;
  visitNow: string | symbol | undefined;
  freshChat: boolean;
  startInWorktree: (cwd: string, github?: { repo: string; candidates: string[] }) => void;
  setWorktreeError: React.Dispatch<React.SetStateAction<WorktreeError | undefined>>;
  btwFailure: { sessionId: string; reason: string } | undefined;
  setBtwFailure: React.Dispatch<React.SetStateAction<{ sessionId: string; reason: string } | undefined>>;
  sandboxUncheckedNotice: boolean;
  sandboxUnchecked: React.JSX.Element;
  sandboxElsewhere: SandboxRun | undefined;
  sandboxHoldsChat: boolean;
  sandboxWake: React.RefObject<ComposerWake | undefined>;
  setSandboxViewing: React.Dispatch<React.SetStateAction<boolean>>;
  quick: boolean;
  manager: ManagedBy | undefined;
  shownSessionId: string | undefined;
  hideManaged: (sessionId: string) => void;
  goalAtFoot: boolean;
  goalNode: React.JSX.Element | null;
  /** The approved plan's band (ApprovedPlanBand.tsx), drawn under the goal; null with none. */
  approvedPlanNode?: React.JSX.Element | null;
  /** The approved plan sits at the hat's foot, over the composer (approvedPlan.experiment.ts). */
  approvedPlanAtFoot?: boolean;
  /** A live customization's bar (customizeBar/CustomizeBar.tsx), right over the composer; null with none. */
  customizeBarNode?: React.JSX.Element | null;
  hatQuestionList: readonly HatQuestion[];
  NO_HAT_QUESTIONS: readonly HatQuestion[];
  hatQuestionActions: HatQuestionActions;
  trayPlacement: SubagentTrayPlacement;
  trayTucked: boolean;
  trayNode: React.JSX.Element | null;
  trayList: TrayItem[];
  waitingAgents: Set<string>;
  trayHandle: TrayHandleSide;
  /// Where the tucked hat's pill stands: trayHandle, or aside when the jump stack takes the center
  /// line (hatSide, hatPillPlace.experiment.ts).
  hatHandle: TrayHandleSide;
  hatPillArm: HatPillPlace;
  statusCardOpen: boolean;
  /// The changes pill over the composer (session-info/EnvironmentCard.tsx ChangesPill), null when off.
  changesPillNode: React.JSX.Element | null;
  setStatusCardOpen: React.Dispatch<React.SetStateAction<boolean>>;
  openImage: (src: string, alt: string, path?: string) => void;
  cloudStarting: boolean;
  /// Return during a Cloud start queues the message for the started chat ("just go"); false: it waits.
  onCloudStartQueue?: (text: string) => boolean;
  composerDrawn: AcpmuxSnapshot;
  guestsHere: boolean;
  composerSnapshot: AcpmuxSnapshot;
  isSideSession: boolean;
  switchView: SwitchView;
  handshaken: boolean;
  newSession: boolean;
  ComposerChips: React.ComponentType<{ snapshot: AcpmuxSnapshot }> | typeof DefaultComposerChips;
  reconnectPeer: (peer: string) => Promise<unknown>;
  sessionInfo: ReturnType<typeof useSessionInfo>;
  /// The agent's /compact for this chat (App.tsx `compactChat`): the context card's Compact conversation row.
  compactChat: (() => void) | undefined;
  draft: string | undefined;
  setDraftSettled: React.Dispatch<React.SetStateAction<string | undefined>>;
  onNewChatDraft: (text: string) => Promise<unknown>;
  onCloudTyping: (text: string, sessionId?: string) => void;
  onCloudMachinePicked: (machine: CloudMachine | undefined) => void;
  wakeOnTyping: () => void;
  handleCmuxCommand: (
    command: CmuxCommand,
    typedArgs?: string,
    fresh?: boolean,
    attachments?: ComposerAttachment[],
    gesture?: SendGesture,
  ) => CmuxCommandResult;
  handleLocalCommand: (command: LocalCommand) => boolean;
  commandState: (fresh: boolean) => Parameters<typeof cmuxCommandRefusal>[2];
  harnessSwitch: HarnessSwitch;
  projectDraft: string | undefined;
  cloudSourceWaiting: boolean;
  setCloudSourceWaiting(waiting: boolean): void;
  cloudSourcePick(cwd: string | undefined): string | undefined;
  checkedOutGitHub: { cwd: string; name: string } | undefined;
  cloningGitHub: string | undefined;
  clearProject(): void;
  /// A GitHub repository picked with This Mac picked: the chip's choice only, checked out when Return sends.
  deferGitHub(repo: string, candidates: string[]): void;
  /// Drops that pick (another machine picked).
  dropDeferredGitHub(): void;
  /// The repository the chip names while it waits for Return.
  pendingGitHub: string | undefined;
  /// Return on a GitHub repository chosen with This Mac picked: starts its checkout and holds the prompt, which
  /// goes once the checkout is the folder. False when the chip names no such repository.
  checkOutGitHubOnSend(): boolean;
  openEmptyProject: (() => void) | undefined;
  pickSourceProject(cwd: string, peer?: string): Promise<void>;
  cloudPicked: boolean;
  cloudWakeChat: string | undefined;
  cloudRecovery: ReturnType<typeof useCloudChatRecovery>;
  sandboxing: boolean;
  sandboxPickedNotOffered: boolean;
  sandboxDraftMoved: boolean;
  transcriptFollowing: () => boolean;
  authBlock: string | undefined;
  cloudFolderOnce: React.RefObject<{ cwd: string } | { home: true } | undefined>;
  cloudRetryFolder: React.RefObject<{ cwd: string } | { home: true } | undefined>;
  sendToCloud: SendToCloud;
  shellRuns: ShellRuns;
  sandbox: SandboxTab;
  sandboxNotNow: "sandbox_spent" | "unavailable_now";
  startSandbox: (text: string, attachmentCount: number, harness: string | undefined) => string | boolean;
  setCloudWaking: React.Dispatch<React.SetStateAction<boolean>>;
  trustHeld: ReturnType<typeof useTrustHeldPrompts>;
  trustHeldCwd: string | undefined;
  cardEdit: {
    turn: { key: string; rowId: string; files: TurnFile[]; pathsOnly: PathRef[] } | undefined;
    changes:
      | { files: readonly TurnFile[]; root: string | undefined; additions: number; deletions: number; outside: boolean }
      | undefined;
  };
  turnRowsShown: AcpmuxRow[];
  btwNotes: BtwNotes;
  surfaceRef: React.RefObject<PaneSurface>;
  trustHolds: boolean;
  claimShellRuns: React.RefObject<boolean>;
  pickedProject: React.RefObject<string | undefined>;
  remoteChat: boolean;
  startingSends: StartingSends;
  individualPermission: AcpmuxPermission | undefined;
  promptLanded: React.RefObject<() => void>;
  cancelOpenInWindow: () => void;
  connectedClients: ReturnType<typeof clientWaiter<AcpmuxDirectClient>>;
  trustAsk: ReturnType<typeof useFolderTrustAsk>;
  holdPrompt: React.RefObject<(() => void) | undefined>;
  holdRefused: React.RefObject<
    (text: string, attachments: ComposerAttachment[], error: unknown, sentFrom: SentFrom) => void
  >;
  sessionIdRef: React.RefObject<string | undefined>;
  startInBackground: (text: string, taken: Promise<unknown>) => void;
  heldBack: React.RefObject<{ text: string; attachments: ComposerAttachment[] }[] | undefined>;
  interruptedResumeOwner: { sessionId: string; rowId: string; family: string | undefined } | undefined;
  stopThroughReconnect: ReturnType<typeof useStopThroughReconnect>;
  queueSideChatRef: React.RefObject<((promptId: string, prompt: string) => Promise<boolean>) | undefined>;
  opensSideSessions: boolean;
  readQueuedImage: (id: string) => Promise<string | undefined>;
  chooseProject: (
    cwd: string,
    peer?: string,
    refused?: () => void,
    accepted?: (folder: string) => void,
  ) => Promise<void>;
  cloudDraftMachineID: React.RefObject<string | null | undefined>;
  offloadChat: (kind: OffloadKind, session?: string) => void;
  offloads: ("move" | "bringBack")[];
  offloadReasons: Readonly<Partial<Record<OffloadKind, string>>>;
  moveTargets: readonly HeaderMoveTarget[];
  moveChatToMachine: (machine: string, session: string | undefined) => void;
  refreshTabState: () => undefined;
  canMove: boolean;
  newTabProjects: Project[];
  machineFolders: Project[] | undefined;
  extraFolderDraft: ExtraFolderDraft | undefined;
  setExtraFolderDraft: React.Dispatch<React.SetStateAction<ExtraFolderDraft | undefined>>;
  localMachineName: string | undefined;
  cloudOfferable: boolean;
  onOtherMachine: boolean;
  cloudPickedNotOffered: boolean;
  ignoreFailure: (result: Promise<unknown>) => undefined;
  fileRoot: string | undefined;
  searchFiles: FileSearchSource;
  plusSearchExtensions: ComposerPlusExtension[];
  runPlusSearch: (id: string) => void;
  captureScreen: (mode: CaptureMode) => Promise<File | undefined>;
  localCwd: string | undefined;
  uploadFiles: (
    files: File[],
    cancelled?: (index: number) => boolean,
    progress?: UploadProgressReport,
  ) => Promise<UploadResult>;
  localPaths: (kind: DroppedKind, files: File[], gestureAt?: number) => Promise<KnownPaths | undefined>;
  openInWindow: (sent: boolean) => void;
  hasBottomAsk: boolean;
  nextStepFire: { fire: () => void } | undefined;
  prompt: React.RefObject<MarkdownFieldHandle | null>;
  composerRef: (handle: ComposerHandle | null) => void;
  composerUnplacedQuotes: (quotes: string[]) => void;
  trustSendOff: boolean;
  blockSend: boolean;
  cloudSendHeld: boolean;
  signInNoticeVisible: boolean;
  authPreflightPending: boolean;
  composerMic: React.JSX.Element;
  importFile: (file: File) => Promise<void>;
  /// The Computer Use setup notice a held `@computer-use` send raised (undefined while none shows).
  computerUseAsk: ComputerUseHold | undefined;
  /// Where the held send that raised it was going: the notice shows (and its Set Up opens setup) only
  /// while this composer still sends there, never after a switch to Cloud or another machine.
  computerUseAsked: ComputerUsePlace | undefined;
  setUpComputerUse: () => void;
  setComputerUseAsked: React.Dispatch<React.SetStateAction<ComputerUsePlace | undefined>>;
  /// Whether a send of `text` from `place` waits for Computer Use (App.tsx, #48541).
  holdsForComputerUseSetup: (text: string, toast?: boolean, place?: ComputerUsePlace, opensSetup?: boolean) => boolean;
};

/// The pane's composer tree: a subagent pane's relayed Composer, or (unless reviewing) the bottom
/// stack of notices, the hat and the Composer.
export function drawPaneComposer({
  hostOverload,
  markDockEdge,
  composerTurnQueue,
  readOnlySubagent,
  subagentRelay,
  subagentDraftKey,
  subagentFailed,
  t,
  reviewing,
  snapshot,
  dictation,
  cloudHintShown,
  showNewTab,
  composerModeRows,
  autoArrival,
  autoAddingMachine,
  autoArrivalMove,
  onAutoArrivalDismiss,
  autoSendGate,
  cloudHint,
  machineCheck,
  machinePeer,
  catalog,
  machineSelected,
  importError,
  instructionsFailure,
  openInstructions,
  setInstructionsFailure,
  harnessCard,
  startsElsewhere,
  chatSignIns,
  switchLoginCommand,
  composerHandle,
  placeControl,
  healthStale,
  connectMachine,
  chooseWorkspaceFolder,
  machineName,
  targetSignInHealth,
  harnessHealth,
  healthHarness,
  recheckHealth,
  setUpdateOffer,
  setSignInNoticeVisible,
  rulesLocal,
  rules,
  folderNeeded,
  directClient,
  setFolderNeeded,
  folderAskView,
  folderChoiceOffered,
  folderError,
  background,
  liveTurnPhase,
  shareNudge,
  setShareOpen,
  notices,
  worktreeCreatingHere,
  worktreeSetupHere,
  worktreeSetupFolder,
  worktreeCreating,
  worktreeError,
  visitNow,
  freshChat,
  startInWorktree,
  setWorktreeError,
  btwFailure,
  setBtwFailure,
  sandboxUncheckedNotice,
  sandboxUnchecked,
  sandboxElsewhere,
  sandboxHoldsChat,
  sandboxWake,
  setSandboxViewing,
  quick,
  manager,
  shownSessionId,
  hideManaged,
  goalAtFoot,
  goalNode,
  approvedPlanNode = null,
  approvedPlanAtFoot = false,
  customizeBarNode = null,
  hatQuestionList,
  NO_HAT_QUESTIONS,
  hatQuestionActions,
  trayPlacement,
  trayTucked,
  trayNode,
  trayList,
  waitingAgents,
  trayHandle,
  hatHandle,
  hatPillArm,
  statusCardOpen,
  setStatusCardOpen,
  changesPillNode,
  openImage,
  cloudStarting,
  onCloudStartQueue,
  composerDrawn,
  guestsHere,
  composerSnapshot,
  isSideSession,
  switchView,
  handshaken,
  newSession,
  ComposerChips,
  reconnectPeer,
  sessionInfo,
  compactChat,
  draft,
  setDraftSettled,
  onNewChatDraft,
  onCloudTyping,
  onCloudMachinePicked,
  wakeOnTyping,
  handleCmuxCommand,
  handleLocalCommand,
  commandState,
  harnessSwitch,
  projectDraft,
  cloudSourceWaiting,
  setCloudSourceWaiting,
  cloudSourcePick,
  checkedOutGitHub,
  cloningGitHub,
  clearProject,
  deferGitHub,
  dropDeferredGitHub,
  pendingGitHub,
  checkOutGitHubOnSend,
  openEmptyProject,
  pickSourceProject,
  cloudPicked,
  cloudWakeChat,
  cloudRecovery,
  sandboxing,
  sandboxPickedNotOffered,
  sandboxDraftMoved,
  transcriptFollowing,
  authBlock,
  cloudFolderOnce,
  cloudRetryFolder,
  sendToCloud,
  shellRuns,
  sandbox,
  sandboxNotNow,
  startSandbox,
  setCloudWaking,
  trustHeld,
  trustHeldCwd,
  cardEdit,
  turnRowsShown,
  btwNotes,
  surfaceRef,
  trustHolds,
  claimShellRuns,
  pickedProject,
  remoteChat,
  startingSends,
  individualPermission,
  promptLanded,
  cancelOpenInWindow,
  connectedClients,
  trustAsk,
  holdPrompt,
  holdRefused,
  sessionIdRef,
  startInBackground,
  heldBack,
  interruptedResumeOwner,
  stopThroughReconnect,
  queueSideChatRef,
  opensSideSessions,
  readQueuedImage,
  chooseProject,
  cloudDraftMachineID,
  offloadChat,
  offloads,
  offloadReasons,
  moveTargets,
  moveChatToMachine,
  refreshTabState,
  canMove,
  newTabProjects,
  machineFolders,
  extraFolderDraft,
  setExtraFolderDraft,
  localMachineName,
  cloudOfferable,
  onOtherMachine,
  cloudPickedNotOffered,
  ignoreFailure,
  fileRoot,
  searchFiles,
  plusSearchExtensions,
  runPlusSearch,
  captureScreen,
  localCwd,
  uploadFiles,
  localPaths,
  openInWindow,
  hasBottomAsk,
  nextStepFire,
  prompt,
  composerRef,
  composerUnplacedQuotes,
  trustSendOff,
  blockSend,
  cloudSendHeld,
  signInNoticeVisible,
  authPreflightPending,
  composerMic,
  importFile,
  computerUseAsk,
  computerUseAsked,
  setUpComputerUse,
  setComputerUseAsked,
  holdsForComputerUseSetup,
}: PaneComposerDeps) {
  // Where the composer's send runs, for `@computer-use` (CMUX-682): a chat off this Mac (a Cloud VM, a
  // Sandboxed run, a peer, an SSH host) has no Computer Use tools (acpmux gives a remote session no cmux
  // tools, #48541), so its send is held too, and the chat says so.
  // A fresh chat on another machine has no summary yet: `startsElsewhere` (its connection's origin) says so.
  const computerUsePlace: ComputerUsePlace =
    cloudPicked || sandboxing || snapshot.summary?.hostKind === "cloud" || snapshot.startsOnCloud
      ? "cloud"
      : snapshot.summary?.host || machinePeer || snapshot.summary?.peer || startsElsewhere
        ? "machine"
        : "here";
  // `/side --on cloud …` goes to a Cloud chat whatever this chat is: held as a Cloud send, with the
  // Cloud notice, never this Mac's setup (commandPlace.ts reads the `--on` the command handler reads).
  const sendPlace = (text: string): ComputerUsePlace => {
    // Read without the attachments placed in the text (U+FFFC tokens), as the command's dispatch reads it.
    const words = text.replace(/\uFFFC[^\uFFFC]*\uFFFC/g, "").trim();
    const side = /^\/side(?:\s+([\s\S]*))?$/i.exec(words);
    const placed = side ? commandPlace(side[1]) : undefined;
    return placed && "place" in placed && placed.place === "cloud" ? "cloud" : computerUsePlace;
  };
  // A started chat can use native file links before its cwd arrives. On a fresh pane, the
  // native host still verifies the destination before handing back a gesture's paths.
  const localFileLinks =
    !quick &&
    !readOnlySubagent &&
    (snapshot.summary ? chatOnThisMac(snapshot.summary, snapshot.peerKinds, chatPlace(snapshot)) : !onOtherMachine);
  const shownComputerUseAsk = computerUseAsked === computerUsePlace ? computerUseAsk : undefined;
  return (
    (readOnlySubagent || !reviewing) && (
      <>
        <PaneNotices onAction={(id) => void callNative("pane.noticeAction", { id }).catch(() => undefined)} />
        <Notice id="dictation" tier="error" when={dictation.notice?.message}>
          <DictationNotice dictation={dictation} />
        </Notice>
        <Notice id="subagent-failed" tier="error" when={readOnlySubagent && subagentFailed}>
          <p className="acpmux-composer-remote-note" role="alert">
            {t("subagents.messageFailed")}
          </p>
        </Notice>
        {!readOnlySubagent && (
          <>
            <PlanScopeDriftNotice sessionId={snapshot.sessionId} />
            <Notice id="auto-arrival" tier="hint" when={autoArrival !== undefined}>
              {autoArrival !== undefined && (
                <AutoArrival
                  landing={autoArrival}
                  look={AUTO_LOOK}
                  {...(autoArrivalMove ? { onMove: (kind) => offloadChat(kind, snapshot.sessionId) } : {})}
                  onDismiss={onAutoArrivalDismiss}
                />
              )}
            </Notice>
            <Notice id="auto-adding-machine" tier="hint" when={autoAddingMachine !== undefined}>
              {autoAddingMachine !== undefined && <AutoAddingMachineLine text={autoAddingMachine} look={AUTO_LOOK} />}
            </Notice>
            <Notice id="computer-use-setup" tier="error" when={shownComputerUseAsk}>
              {shownComputerUseAsk && (
                <ComputerUseSetupNotice
                  hold={shownComputerUseAsk}
                  onSetUp={setUpComputerUse}
                  onDismiss={() => setComputerUseAsked(undefined)}
                />
              )}
            </Notice>
            <Notice id="cloud-hint" tier="hint" when={cloudHintShown && !showNewTab}>
              <CloudChatHint onUse={() => composerModeRows.onMode("cloud")} onClose={cloudHint.close} />
            </Notice>
            <Notice id="machine-harness" tier="error" when={machineCheck.notice && machinePeer !== undefined}>
              <p className="acpmux-composer-remote-note" role="alert">
                {t("composer.peerHarnessMissing", {
                  agent: catalog.find((entry) => entry.id === machineSelected)?.name ?? machineSelected ?? "",
                  machine: machinePeer ?? "",
                })}
              </p>
            </Notice>
            <Notice id="import-error" tier="error" when={!showNewTab && importError}>
              <p className="acpmux-composer-remote-note" role="alert">
                {importError}
              </p>
            </Notice>
            <Notice id="instructions" tier="error" when={instructionsFailure}>
              <InstructionsNotice
                failure={instructionsFailure?.failure}
                onRetry={() =>
                  instructionsFailure && openInstructions(instructionsFailure.cwd, instructionsFailure.failure.file)
                }
                onDismiss={() => setInstructionsFailure(undefined)}
              />
            </Notice>
            {harnessCard ? (
              <Notice id="harness-block" tier="error" when>
                {harnessCard}
              </Notice>
            ) : (
              <Notice id="switch" tier="error" when={snapshot.switching?.phase === "failed"}>
                <SwitchNotice
                  switching={snapshot.switching}
                  // Install runs the installer in a terminal tab of this Mac: never for a chat elsewhere.
                  installs={!startsElsewhere}
                  // An agent not signed in: on another machine its sign-in runs there, in the card; on
                  // this Mac in the in-place card where acpmux has one, else its login in a terminal
                  // tab; then Retry starts it (hq#11225; refusedStartSignIn).
                  {...refusedStartSignIn({
                    startsElsewhere,
                    elsewhereCard: chatSignIns.refusedSignIn,
                    localCard: chatSignIns.localRefusedSignIn,
                    loginCommand: switchLoginCommand,
                  })}
                  onRetry={() => void callNative("chat.harness.retry")}
                  // The refused prompt is back in the composer; a chat on another machine starts only
                  // with a send, so the share's retry sends it again (as Trust's answer does).
                  onShared={() => void callNative("chat.harness.retry").then(() => composerHandle.current?.send())}
                  onAction={(action) => {
                    // Install runs the agent's installer where its output shows, then Retry starts it.
                    if (action === "install") {
                      const command = snapshot.switching ? INSTALL_COMMANDS[snapshot.switching.harness] : undefined;
                      if (command)
                        void callNative("tab.open", {
                          kind: "terminal",
                          text: command,
                          ...(snapshot.summary?.cwd ? { cwd: snapshot.summary.cwd } : {}),
                          run: true,
                        }).catch(() => undefined);
                      return;
                    }
                    // The refused agent's login, where its sign-in page or code shows; Retry then starts it.
                    if (action === "signIn") {
                      if (switchLoginCommand && !startsElsewhere) {
                        healthStale.current = true;
                        void callNative("tab.open", {
                          kind: "terminal",
                          text: switchLoginCommand,
                          ...(snapshot.summary?.cwd ? { cwd: snapshot.summary.cwd } : {}),
                          run: true,
                          keep: true,
                        }).catch(() => undefined);
                      }
                      return;
                    }
                    const route = startRefusalRoute(action, startsElsewhere);
                    if (route === "newCloudMachine") connectMachine("cloud");
                    // That machine's folder menu; a menu that is not mounted falls back to the panel's answer.
                    else if (route === "machineFolderMenu") {
                      if (!openPicker("Location")) void chooseWorkspaceFolder();
                    } else void chooseWorkspaceFolder();
                  }}
                  share={{ ...(machineName && { machine: machineName }), call: () => callNative("machine.share.self") }}
                />
              </Notice>
            )}
            {!harnessCard && (
              <HarnessHealthNotice
                health={targetSignInHealth ?? harnessHealth}
                harness={healthHarness}
                name={catalog.find((entry) => entry.id === healthHarness)?.name ?? healthHarness ?? ""}
                {...(snapshot.summary?.cwd ? { cwd: snapshot.summary.cwd } : {})}
                open={(params) => {
                  healthStale.current = true;
                  void callNative("tab.open", params).catch(() => undefined);
                }}
                native={callNative}
                {...(chatSignIns.healthSignIn && { signIn: chatSignIns.healthSignIn })}
                turnRunning={snapshot.isWorking}
                onUpdated={recheckHealth}
                onOffer={setUpdateOffer}
                onSignInVisible={setSignInNoticeVisible}
              />
            )}
            {snapshot.sessionId && rulesLocal && <RulesNotice rules={rules} />}
            <Notice id="missing-folder" tier="error" when={folderNeeded && !snapshot.sessionId}>
              <MissingFolder
                reason={folderNeeded?.reason ?? ""}
                error={folderNeeded?.error}
                onChoose={() => {
                  void chooseChatFolder(
                    () => callNative("chat.folder.choose"),
                    async (adopt) => {
                      const client = directClient.current;
                      if (!client) throw new Error(t("error.nativeUnavailable"));
                      const sessionId = await client.resume(adopt);
                      if (sessionId) await callNative("chat.persistSession", { sessionId });
                    },
                  ).then(
                    (result) => {
                      if (result.done) setFolderNeeded(undefined);
                      else if (result.reason) setFolderNeeded({ reason: result.reason });
                    },
                    (error: unknown) => {
                      console.warn("agent pane: choosing the chat's folder failed", error);
                      setFolderNeeded(
                        (current) =>
                          current && { ...current, error: knownRefusalText(error) ?? translate("startFolder.failed") },
                      );
                    },
                  );
                }}
              />
            </Notice>
            {!showNewTab && folderAskView}
            {/* Only the host's refusal of the folder chip's Choose folder… stands over the composer,
              with the line to retry. */}
            <Notice id="folder-choice" tier="error" when={folderChoiceOffered && folderError}>
              <FolderChoice error={folderError} onChoose={chooseWorkspaceFolder} />
            </Notice>
            <Notice id="background" tier="status" when={background.notice}>
              <output className="acpmux-switch-notice acpmux-background-notice">
                {background.notice && t(BACKGROUND_NOTICE_TEXT[background.notice])}
              </output>
            </Notice>
            <OverloadNotice state={hostOverload} />
            {!showNewTab && <AutoResumeNotice state={liveAutoResume(liveTurnPhase, snapshot.autoResume)} />}
            {!showNewTab && !quick && (
              <MoveDock
                session={snapshot.sessionId}
                say={notices.transient}
                claims={() => ({
                  queued: snapshot.queue.length,
                  hasDraft: (composerHandle.current?.draftText() ?? "").trim() !== "",
                })}
              />
            )}
            {!showNewTab && (
              <ShareNudge
                open={shareNudge.shown}
                onShare={() => {
                  shareNudge.close();
                  setShareOpen(true);
                }}
                onInvite={() => {
                  shareNudge.close();
                  void callNative("action.run", { id: "agent.share.invite" }).catch(
                    sayActionRefusal(notices.transient),
                  );
                }}
                onDismiss={shareNudge.close}
              />
            )}
            {/* New Worktree: Creating worktree…, then the worktree recipe's setup in the same line
              (worktreeSetup.tsx), for the chat in that worktree, until it is dismissed. */}
            <Notice id="worktree-creating" tier="status" when={worktreeCreatingHere || worktreeSetupHere}>
              <WorktreeSetupNotice
                callNative={callNative}
                folder={worktreeSetupFolder}
                creating={worktreeCreatingHere}
                {...(worktreeCreating && worktreeCreating.repo ? { cloning: worktreeCreating.repo } : {})}
              />
            </Notice>
            <Notice
              id="worktree-error"
              tier="error"
              when={inThisVisit(worktreeError, snapshot.sessionId, visitNow) && freshChat && !snapshot.sessionId}
            >
              <WorktreeFailure
                {...(worktreeError?.message ? { message: worktreeError.message } : {})}
                onRetry={() => worktreeError && startInWorktree(worktreeError.cwd, worktreeError.github)}
                onDismiss={() => setWorktreeError(undefined)}
              />
            </Notice>
            <Notice id="btw-failure" tier="error" when={btwFailure}>
              <output className="acpmux-switch-notice acpmux-folder-choice">
                <span role="alert">
                  {btwFailure?.reason
                    ? t("sideSession.failedBecause", { reason: btwFailure.reason })
                    : t("sideSession.failed")}
                </span>{" "}
                <button type="button" className="acpmux-folder-choice-button" onClick={() => setBtwFailure(undefined)}>
                  {t("sideQuestion.dismiss")}
                </button>
              </output>
            </Notice>
            {/* The tab's Sandboxed run while a chat shows here: it has no session to go back to, so it is
              offered here. */}
            {/* The newest read of the host's sandbox state didn't answer: say so, with Check again. The
              run the tab last knew stays in view. With nothing known, Labs only (without it there is no
              Sandboxed send to lose); a card in the chat view has its own Check again. */}
            <Notice id="sandbox-unchecked" tier="status" when={sandboxUncheckedNotice}>
              {sandboxUnchecked}
            </Notice>
            <Notice id="sandbox-elsewhere" tier="status" when={sandboxElsewhere && !sandboxHoldsChat}>
              <output className="acpmux-switch-notice acpmux-folder-choice">
                <span>
                  {t(sandboxElsewhere?.state === "running" ? "sandbox.elsewhereRunning" : "sandbox.elsewhereDone")}
                </span>{" "}
                <button
                  type="button"
                  className="acpmux-folder-choice-button"
                  onClick={() => {
                    // The receipt takes the composer's place: what only the composer holds (shell
                    // mode, its line, attachments) comes back with it on Back.
                    sandboxWake.current = composerHandle.current?.wakeState();
                    setSandboxViewing(true);
                  }}
                >
                  {t("sandbox.show")}
                </button>
              </output>
            </Notice>
            {/* A chat the Chief or another chat's agent is driving now: who, and Hide (ManagedBanner.tsx). */}
            <Notice id="managed-by" tier="status" when={!quick && manager}>
              {manager && shownSessionId && (
                <ManagedBanner
                  manager={manager}
                  onOpenManager={openSenderChat}
                  onHide={() => hideManaged(shownSessionId)}
                />
              )}
            </Notice>
          </>
        )}
        {/* The tray (subagents/SubagentTray.tsx): in the bottom stack, right above the composer, every
            running or recently ended subagent, background command and started chat, one card each. */}
        {/* Tucked away (chatDisplay.ts TRAY_TUCKED_KEY), the hat leaves only its pull tab at the
              composer's top middle (subagents/TrayPullTab.tsx). */}
        {/* The agent's questions waiting on the person, over the hat (question/HatQuestions.tsx). */}
        {/* The card under it keeps answering the question it shows; the hat shows only with more to
              step to than that one (hatShows), and stays mounted so it arrives and leaves as a move. */}
        {/* No held-messages row: the count of inbox messages held without a turn is not the person's to
            read (Leo, 2026-11-24: "it's also not useful to show this to the user"). */}
        {!goalAtFoot && goalNode}
        {!approvedPlanAtFoot && approvedPlanNode}
        <HatQuestions
          key={shownSessionId}
          questions={hatShows(hatQuestionList) ? hatQuestionList : NO_HAT_QUESTIONS}
          actions={hatQuestionActions}
        />
        {trayPlacement === "tray" &&
          (trayTucked && trayNode ? (
            <TrayPullTab
              chat={shownSessionId}
              {...pullTabCounts(trayList, waitingAgents)}
              side={hatHandle}
              quiet={hatPillQuiet(hatPillArm) && (hatHandle !== trayHandle || hatPillInMiddle(hatPillArm))}
            />
          ) : (
            trayNode
          ))}
        {goalAtFoot && goalNode}
        {approvedPlanAtFoot && approvedPlanNode}
        {customizeBarNode}
        {statusCardOpen && <HarnessStatusCard summary={snapshot.summary} onDismiss={() => setStatusCardOpen(false)} />}
        {/* "1 file changed +2 -2" (session-info/EnvironmentCard.tsx), off by default: a look turns it on. */}
        {changesPillNode}
        {/* An attached image opens in the chat's image viewer, as a transcript image does. */}
        <ImageViewerContext.Provider value={openImage}>
          <Composer
            // A subagent's composer starts from its own draft: another subagent's pane is another composer.
            key={subagentRelay ? subagentDraftKey : undefined}
            relay={subagentRelay}
            onFocusEdge={markDockEdge}
            cloudStarting={cloudStarting}
            {...(onCloudStartQueue ? { onCloudStartQueue } : {})}
            snapshot={composerDrawn}
            guestHarnesses={guestsHere ? composerSnapshot.catalog : undefined}
            headerCwd={snapshot.summary?.cwd ?? ""}
            turnQueue={composerTurnQueue}
            sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
            placeholder={isSideSession ? t("sideSession.placeholder") : undefined}
            switching={Boolean(switchView.intent)}
            // An existing chat being restored or opened (no handshake yet, or its session not
            // attached) draws no new chat's folder and environment strip.
            chatKnown={paneKnowsNewChat({ handshaken, newSession }, composerSnapshot)}
            stackAbove={
              (trayPlacement === "tray" && trayNode !== null) ||
              goalNode !== null ||
              approvedPlanNode !== null ||
              customizeBarNode !== null ||
              statusCardOpen ||
              hatShows(hatQuestionList)
            }
            chips={ComposerChips}
            // The quiet row's Reconnect asks acpmux to reconnect the chat's peer.
            onReconnectMachine={(link) => reconnectPeer(link.machine)}
            // The context card's Details opens Session Info on Context, unfolded and lit (main's).
            onOpenContext={sessionInfo.reveal ? () => sessionInfo.reveal?.("context") : undefined}
            // The card's Compact conversation row sends the agent's /compact, as Session Info's Compact does.
            onCompact={compactChat}
            draft={draft}
            onDraftSettled={setDraftSettled}
            onUnsentDraft={quick ? undefined : onNewChatDraft}
            onTyping={quick ? undefined : onCloudTyping}
            onCloudMachinePicked={quick ? undefined : onCloudMachinePicked}
            onPromptEdit={quick ? undefined : wakeOnTyping}
            onSuggestionTaken={() => directClient.current?.takeSuggestion()}
            keptAttachments={quick ? undefined : keptAttachments}
            onCmuxCommand={(command, args, attachments, gesture) =>
              handleCmuxCommand(command, args, false, attachments, gesture)
            }
            onLocalCommand={handleLocalCommand}
            onBindSideGesture={() => directClient.current?.bindSideGesture()}
            // Send's menu offers Send in side chat where `/side <prompt>` would fork this chat now.
            sendsToSide={SIDE_COMMAND !== undefined && !cmuxCommandRefusal(SIDE_COMMAND, "prompt", commandState(false))}
            // A send the composer holds for its files (a pasted screenshot still being read) binds
            // its Enter or click now only when it goes straight to the chat open now: a chat start,
            // a harness switch (deferred included), a Cloud start or wake and a sandbox run spend
            // that gesture themselves first (heldSendBinding.ts).
            onBindSendGesture={() => {
              const client = directClient.current;
              const route = {
                openChat: client?.selectedSession,
                switchPending: harnessSwitch.view().intent !== undefined,
                startsChat: Boolean(projectDraft && !snapshot.sessionId),
                cloudStart: cloudPicked,
                cloudWake: Boolean(cloudWakeChat && cloudRecovery.state !== "deleted"),
                sandbox: sandboxing || sandboxPickedNotOffered || (sandboxHoldsChat && !sandboxDraftMoved),
              };
              return client && bindsHeldSendNow(route) ? client.bindSendGesture() : undefined;
            }}
            // A send made while a dropped file still attaches goes now, ahead of it, and shows as
            // sent (composer/sendBehind.ts): only where onSend below takes it straight to the client
            // of the chat open now (its plain path), which sends it once the file is its chip.
            onBindSendAhead={() => {
              const client = directClient.current;
              const plainPath =
                client !== undefined &&
                Boolean(snapshot.sessionId) &&
                client.selectedSession === snapshot.sessionId &&
                surfaceRef.current !== "quick" &&
                !projectDraft &&
                !snapshot.summary?.watching &&
                !authBlock &&
                !cloningGitHub &&
                !autoSendGate.picked &&
                !(sandboxHoldsChat && !sandboxDraftMoved) &&
                !sandboxPickedNotOffered &&
                !trustHolds &&
                !trustHeld.pending() &&
                !heldFork(snapshot.sessionId) &&
                Boolean(window.cmuxAcpmuxActions?.["chat.send"]);
              const route = {
                openChat: client?.selectedSession,
                switchPending: harnessSwitch.view().intent !== undefined,
                startsChat: Boolean(projectDraft && !snapshot.sessionId),
                cloudStart: cloudPicked,
                cloudWake: Boolean(cloudWakeChat && cloudRecovery.state !== "deleted"),
                sandbox: sandboxing || sandboxPickedNotOffered || (sandboxHoldsChat && !sandboxDraftMoved),
              };
              return client && plainPath && bindsHeldSendNow(route) ? client.bindSendGesture() : undefined;
            }}
            transcriptFollowing={transcriptFollowing}
            // `@computer-use` held before the send binds its key press or click (CMUX-682), so that
            // gesture opens the setup page; onSend checks again for a send that waited for its files.
            holdsSend={(text, late) => holdsForComputerUseSetup(text, false, sendPlace(text), !late)}
            onSend={autoSendGate.once((text, chips, steer, gesture) => {
              // A Sandboxed new chat: the message runs once on a throwaway VM, through the
              // host, and the chat shows its receipt; no acpmux chat starts.
              // While the tab's run holds the chat nothing else sends as Sandboxed (the composer keeps
              // the prompt); a composer kept for a refused draft sends as Persistent once picked.
              // The Trust continuation uses ComposerHandle.send(force), but never bypasses auth.
              if (authBlock || cloningGitHub) return false;
              if (sandboxHoldsChat && !sandboxDraftMoved) return false;
              // Auto picked: the daemon says where first; the prompt stays until it has, then sends there.
              if (autoSendGate.holds()) return false;
              // `@computer-use` not ready, or a chat off this Mac (`computerUsePlace`): the composer keeps
              // the message (CMUX-682). Asked first in `holdsSend`; again here for a send that waited.
              if (holdsForComputerUseSetup(text, false, computerUsePlace, false)) return false;
              setComputerUseAsked(undefined);
              // A GitHub repository on the chip with This Mac picked: Return checks it out here first (cmux#53226).
              if (!sandboxing && checkOutGitHubOnSend()) return false;
              if (cloudPicked) {
                if (cloudSourceWaiting) return false;
                const once = cloudFolderOnce.current;
                cloudFolderOnce.current = undefined;
                const folder = once ?? cloudStartFolder(cloudSourcePick(projectDraft ?? composerSnapshot.summary?.cwd));
                // Each send records its complete folder, so a Retry repeats this send's folder, never an older one's.
                cloudRetryFolder.current = folder;
                // The agent picked for the machine (cloudAgentPick.ts) goes first: the chips show it.
                const machinePick = cloudAgentPick();
                const held = heldPick(composerSnapshot);
                const shownModel = composerSnapshot.summary?.model;
                // Before the picker has a harness (the catalog still listing), the person's last local pick
                // goes, so a Cloud send never falls back to Claude over the agent they use here (cmux#51731).
                const remembered = lastPick(composerSnapshot.summary?.cwd);
                const shownHarness = held.harness || composerSnapshot.summary?.harness || healthHarness;
                const cloudShownAgent = machinePick ?? {
                  harness: shownHarness || remembered?.harness,
                  model:
                    held.model ??
                    (shownModel && shownModel !== "default"
                      ? shownModel
                      : !shownHarness && remembered?.model !== DEFAULT_PICK_MODEL
                        ? remembered?.model
                        : undefined),
                };
                const started = sendToCloud(
                  text,
                  shellContextAttachments(chips ?? [], (id) => shellRuns.get(id)),
                  {
                    ...folder,
                    ...autoSendGate.cloudStart(),
                    // The agent and model the composer shows, as the New Tab page's Cloud send names them
                    // (cloudSendAgent): a pick held by a switch, else the chat's, else the picker's face. Before,
                    // only a switch's pick went, so a page showing GPT-6.1 Sol started Claude on the machine.
                    ...cloudSendAgent(
                      composerSnapshot.catalog.find((entry) => entry.id === cloudShownAgent.harness)?.family,
                      cloudShownAgent.harness ?? "",
                      cloudShownAgent.model,
                      machinePick !== undefined,
                    ),
                    // The Mode chip holds its pick under the chat's own harness (none on a blank page): the send
                    // reads it there too, so a pick the chip shows is never dropped for the picker face's harness.
                    ...cloudStartModePick(composerSnapshot.summary?.harness),
                    // The picker's effort and account go with its model (cmux-tui/docs/model-connections.md).
                    ...cloudPickExtras(composerSnapshot.summary),
                  },
                );
                if (typeof started === "string") {
                  directClient.current?.notice(started);
                  return false;
                }
                // The folder the person picked (here or by an earlier Cloud start) is Cloud's next default, kept
                // apart from This Mac's (newtab/startedProject.ts, cmux#53226); the tab folder's GitHub origin no
                // one picked never is.
                if (started === true && "cwd" in folder && folder.cwd === pickedProject.current)
                  rememberCloudPick(folder.cwd, callNative);
                return started;
              }
              if (sandboxPickedNotOffered) {
                sandbox.refuse(text, sandboxNotNow);
                return false;
              }
              if (sandboxing) {
                const started = startSandbox(text, chips?.length ?? 0, composerSnapshot.summary?.harness);
                if (typeof started !== "string") return started;
                // Refused here: the chat view says why and the composer keeps the prompt.
                sandbox.refuse(text, started);
                return false;
              }
              // A Cloud chat whose machine is paused or out of reach: the send wakes the machine and
              // waits in the pane under "Waking the machine…", then goes once the chat is back
              // (cloudWake.ts). Enter's gesture resumes the machine; the prompt keeps the send's.
              if (cloudWakeChat && cloudRecovery.state !== "deleted" && !quick && !snapshot.summary?.watching) {
                setCloudWaking(true);
                trustHeld.hold(
                  text,
                  shellContextAttachments(chips ?? [], (id) => shellRuns.get(id)),
                  { chat: cloudWakeChat, cwd: trustHeldCwd },
                  true,
                );
                cloudRecovery.resume();
                return true;
              }
              // Until acpmux connects nothing takes a prompt; the composer keeps it.
              if (!window.cmuxAcpmuxActions?.["chat.send"]) return false;
              // An installed harness mention is a read-only guest request. Keep the normal send
              // path untouched for ordinary @text, code, attachments, or unknown profiles; the first
              // known mention outside code gets one inline guest note at the transcript tail.
              if (guestsHere && !chips?.length && snapshot.sessionId && directClient.current) {
                const guest = guestMention(text, composerSnapshot.catalog);
                if (guest) {
                  const changedFiles =
                    cardEdit.changes?.files
                      .map((file) => file.path)
                      .filter(Boolean)
                      .slice(0, 40) ?? [];
                  const question = [
                    guest.question || "Review this chat and its current working changes.",
                    changedFiles.length > 0 ? `Current changed files: ${changedFiles.join(", ")}` : undefined,
                  ]
                    .filter(Boolean)
                    .join("\n\n");
                  const anchor = [...turnRowsShown]
                    .reverse()
                    .find((row) => ![WORKING, THINKING, DATE].includes(row.kind));
                  const client = directClient.current;
                  btwNotes.ask(
                    snapshot.sessionId,
                    question,
                    anchor,
                    (guestQuestion, guestSession, harness) =>
                      client
                        .btwInline(guestQuestion, harness ?? guest.harnessId, guestSession)
                        .catch((error: unknown) => {
                          // A trust refusal opens Trust, as /btw's does (btwCapability.ts); the note keeps its Retry.
                          client.routeTrustRefusal(error);
                          throw error;
                        }),
                    guest.harnessId,
                  );
                  return true;
                }
              }
              // A held pick of another harness's model (forkHold.ts; Leo 2026-11-06: "it should only
              // need to necessarily fork when you enter a message on that new model"; Leo 2026-11-11:
              // "it should just be able to seamlesly within the same pane do stuff and stop asking so
              // much bullshit"): this message forks the chat onto that harness and model in this same
              // pane and goes to the fork, attachments and all (`chat.switchModel`). The composer keeps the
              // message, and the pick, when the fork or its send fails.
              if (snapshot.sessionId && surfaceRef.current !== "quick") {
                // A chat that can no longer fork (its host lost the support) drops the pick, so the
                // message goes to the chat as it is rather than failing each send.
                if (!switchForks(snapshot)) clearHeldFork(snapshot.sessionId);
                const forked = sendHeldFork(snapshot.sessionId, {
                  fork: (params) =>
                    callNative<string>("chat.switchModel", {
                      ...params,
                      text,
                      attachments: shellContextAttachments(chips ?? [], (id) => shellRuns.get(id)),
                      ...(gesture ? { gesture } : {}),
                    }),
                  // The composer leaves with the chat: its prompt is not the source chat's draft now.
                  sent: (source) => writePersistedDraft(source, ""),
                });
                if (forked !== undefined) return forked;
              }
              // Shell mode's chips carry their commands' output as it is now.
              const attachments = shellContextAttachments(chips ?? [], (id) => shellRuns.get(id));
              // The folder's trust holds prompts: this one waits in the pane and goes after Trust
              // (trustHeld.ts). One sent while earlier held prompts still go waits behind them, so
              // none overtakes another.
              if (trustHolds || trustHeld.pending()) {
                // A send the composer held for its files keeps the ticket its Enter bound.
                trustHeld.hold(text, attachments, undefined, false, gesture);
                return true;
              }
              if (!snapshot.sessionId) claimShellRuns.current = true;
              // A send in the project the person picked here starts their chat there: once that chat
              // has started (or the send to it landed), the next New Tab defaults to it (Leo
              // 2026-10-21, newtab/startedProject.ts). A refused or failed start leaves the default.
              const sentIn = !snapshot.sessionId ? projectDraft : snapshot.summary?.cwd;
              const startedHere =
                pickedProject.current && sentIn === pickedProject.current && !remoteChat ? sentIn : undefined;
              const rememberStart = () => {
                if (!startedHere) return;
                rememberStartedProject(startedHere, callNative);
                if (pickedProject.current === startedHere) pickedProject.current = undefined;
              };
              // A started chat never holds the prompt (plans/cmux-next/composer-delivery-DESIGN.md):
              // it leaves the composer at once and shows as its own row, which says how far it got,
              // and a refusal stays on that row with Retry, Edit and Remove. One refused before any
              // row showed (the chat could not take prompts) comes back to the composer. A View Only
              // chat is taken over first (below), so the composer holds its prompt meanwhile.
              if (
                snapshot.sessionId &&
                surfaceRef.current !== "quick" &&
                !projectDraft &&
                !snapshot.summary?.watching
              ) {
                // Prompts sent while the chat started still wait to go: this one goes after them.
                if (startingSends.busy) {
                  startingSends.add(text, attachments, sendWhenTaken(steer === true), gesture);
                  return true;
                }
                const holder = composerHandle.current;
                const sentOn = directClient.current;
                // A typed reply while the chat's own question waits answers it in the chat: the
                // question is declined first, so the agent reads the reply instead of waiting on it
                // (question/hatModel.ts, relevance fade). Its record then says "Answered in chat".
                withdrawForTypedReply(individualPermission, sentOn, () =>
                  callNative("chat.send", { text, attachments, steer, ...(gesture ? { gesture } : {}) }),
                ).then(
                  () => {
                    rememberStart();
                    promptLanded.current();
                  },
                  (error: unknown) => {
                    cancelOpenInWindow();
                    if (keptInChat(error) || isTrustRefusal(error)) return;
                    // A prompt a harness switch handed back (harnessSwitch.ts) is in the composer already.
                    if ((error as { handedBack?: unknown } | null)?.handedBack === true) return;
                    const giveBack = () => (composerHandle.current ?? holder)?.restore(text, attachments);
                    if (!lostPrompt(error)) return giveBack();
                    // The connection went before the pane heard acpmux take it (a reset, an acpmux
                    // restart, the pane's own stall recovery): acpmux may have it, and the host's
                    // journal sends it again if not. It stays in the chat as its own row on its way,
                    // which acpmux's record turns into the sent row, or which fails with Retry if
                    // that never comes (lostPrompt.ts keepLostPrompt). Only when no connection could
                    // hold it does it come back to the composer, saying why.
                    void keepLostPrompt(error, connectedClients, sentOn, { input: text, attachments }).then(
                      (outcome) => {
                        // A failed row keeps the host's copy (unsentPrompts.ts) for a relaunch;
                        // a shown prompt is acpmux's, and one given back is the composer's.
                        if (outcome === "failed") return;
                        sentOn?.forgetUnsentPrompt(lostPrompt(error)!.promptId);
                        if (outcome === "shown") return promptLanded.current();
                        giveBack();
                        const line = heldSendNotice(error, attachments);
                        if (line) directClient.current?.notice(line);
                      },
                    );
                  },
                );
                return true;
              }
              // A new chat's prompt leaves the composer at once as a queued row, and what is sent
              // while the chat starts waits behind it (startingSends.ts): a refusal (folder trust,
              // the remote guard, the sandbox) puts each back in the composer to send again. The
              // Quick Composer and a View Only chat still keep the prompt until acpmux takes it.
              const queues = surfaceRef.current !== "quick" && !snapshot.summary?.watching;
              if (queues && startingSends.busy) {
                startingSends.add(text, attachments, sendWhenTaken(steer === true), gesture);
                return true;
              }
              let accept: (taken: true) => void = () => undefined;
              const taken = new Promise<true>((resolve) => (accept = resolve));
              // The id its row is drawn under from the send (`withStartingPrompt`) and the chat's
              // client draws it under once it goes, so it is one row throughout: the one its Enter's
              // gesture is bound to, if any (`sendThrough` sends it under that).
              const promptId = gesture?.promptId ?? crypto.randomUUID();
              const send = async () => {
                // Replying to a View Only chat takes it over first (`takeOver`); while the app that
                // runs it still does, the pane asks how, and the composer keeps the message.
                // A Claude or Codex desktop session acpmux delivers into takes the reply where it runs (`bridgedWatch`).
                if (
                  snapshot.summary?.watching &&
                  !snapshot.summary.bridged &&
                  !(await directClient.current?.takeOver())
                ) {
                  throw new Error("watch.notTakenOver");
                }
                const pick = heldPick(snapshot);
                // The chat's start is part of this send: a trust refusal there asks the folder's
                // question, keeps this prompt (with its send's gesture) and sends it after Trust
                // (cx-nn3e P0b; the prompt was lost when only the start ran again). A held pick's
                // start waits for this prompt, so the prompt goes with it (firstSend.ts).
                const start = () =>
                  callNative("chat.new", {
                    cwd: projectDraft,
                    peer: directClient.current?.newChatPeer(),
                    ...pick,
                  }).then(
                    (started) => {
                      if (started) rememberStart();
                    },
                    (error: unknown) => {
                      // A queued row joins the hold of the new chat it was sent in (trustHeld.ts),
                      // which sends it after Trust; Start Agent and a View Only chat keep it in the
                      // composer, and Trust sends it from there.
                      if (isTrustRefusal(error) && !queues) {
                        if (trustAsk.refused(error, () => composerHandle.current?.send())) holdPrompt.current?.();
                      } else if (isTrustRefusal(error) && trustAsk.refused(error, heldGoesAfterTrust)) {
                        holdRefused.current(text, attachments, error, { chat: undefined, cwd: projectDraft });
                      }
                      throw error;
                    },
                  );
                // A View Only chat, taken over above, answers its waiting question in the chat too.
                const deliver = () =>
                  withdrawForTypedReply(
                    snapshot.sessionId ? individualPermission : undefined,
                    directClient.current,
                    () =>
                      callNative("chat.send", {
                        text,
                        attachments,
                        accepted: () => accept(true),
                        drawnAs: promptId,
                        steer,
                        ...(gesture ? { gesture } : {}),
                      }),
                  );
                // A new chat has no bridged session to take over: its start, then (or with) the prompt.
                if (projectDraft && !snapshot.sessionId) return startThenSend(start, deliver, Boolean(pick.harness));
                if (!snapshot.summary?.bridged) return deliver();
                // The app that ran the bridged session is gone: the chat is taken over and the message
                // stays in the composer. It is not sent again here, since its send gesture is spent;
                // the next Return sends it to the taken-over chat.
                // Taken over only while the chat it was sent to is still the one shown.
                const sender = directClient.current;
                const sentTo = snapshot.sessionId;
                const stillShown = () => directClient.current === sender && sessionIdRef.current === sentTo;
                return deliver().catch(async (error: unknown) => {
                  if (bridgeGone(error) && stillShown() && (await sender?.takeOver())) {
                    throw new Error("watch.notTakenOver");
                  }
                  throw error;
                });
              };
              // The composer that holds the prompt: a refusal that comes once it is gone (the pane
              // swaps it when the chat's session starts) puts the prompt in the one shown now.
              const holder = composerHandle.current;
              const sentOn = directClient.current;
              // Start Agent's Return; ⌘Return (onOpenInWindow, right after this) opens a window instead.
              if (surfaceRef.current === "quick") startInBackground(text, taken);
              const turn = send();
              turn.then(() => promptLanded.current(), cancelOpenInWindow);
              // Taken, or refused before acpmux took it (the turn's later failure is the transcript's).
              // A prompt acpmux refused for the folder's trust that joined the hold (`holdRefused`)
              // counts as taken: it waits in the queue now. One a dropped connection lost before acpmux
              // took it is held until the host's resend shows on the next connection; only one that
              // never shows says "Not sent" and comes back (lostPrompt.ts).
              const held = Promise.race([taken, turn.then(() => true as const)]).catch(async (error: unknown) => {
                if (heldRefusal(error)) return true as const;
                if (lostPrompt(error)) {
                  if (await resentAfterLoss(error, connectedClients, sentOn)) return true as const;
                  const line = heldSendNotice(error, attachments);
                  if (line) directClient.current?.notice(line);
                }
                throw error;
              });
              if (queues) {
                startingSends.add(text, attachments, () => held, undefined, promptId);
                return true;
              }
              held.catch(() => {
                if (composerHandle.current === holder) return;
                if (composerHandle.current) composerHandle.current.restore(text, attachments);
                else heldBack.current = [...(heldBack.current ?? []), { text, attachments }];
              });
              return held;
            })}
            // A prompt held while the agent starts goes back to the composer; else Stop stops the turn.
            onResume={
              interruptedResumeOwner
                ? () =>
                    callNative<boolean>("chat.resumeInterrupted", {
                      sessionId: interruptedResumeOwner.sessionId,
                      rowId: interruptedResumeOwner.rowId,
                    })
                : undefined
            }
            onStop={() => {
              if (!harnessSwitch.cancelQueuedAll()) stopThroughReconnect.stop();
            }}
            onQueueRemove={(promptId) => {
              // A prompt the folder's trust holds is the pane's (trustHeld.ts).
              if (trustHeld.has(promptId)) {
                trustHeld.remove(promptId);
                return Promise.resolve(true);
              }
              return startingSends.owns(promptId)
                ? Promise.resolve(startingSends.remove(promptId))
                : removeQueued(promptId);
            }}
            onQueueCancelEdit={async (promptId, text, attachments) => {
              const own = trustHeld.get(promptId);
              if (own) {
                trustHeld.remove(promptId);
                restoreComposerDraft(composerHandle, heldBack, own.text, own.attachments);
                return true;
              }
              const removed = startingSends.owns(promptId)
                ? startingSends.remove(promptId)
                : await removeQueued(promptId);
              if (removed) restoreComposerDraft(composerHandle, heldBack, text, attachments);
              return removed;
            }}
            onQueueChange={(promptId, edit) => {
              // An edit that adds `@computer-use` while Computer Use is not ready is refused as a send is: the
              // queued prompt keeps its old text and the editor keeps the edit (CMUX-682).
              // A typed refusal (not "refused by acpmux"): the queue editor opens again with the edit.
              if (edit.op === "update" && holdsForComputerUseSetup(edit.text, false, computerUsePlace))
                return Promise.reject(Object.assign(new Error("held"), { code: "computer_use_held" }));
              // Send Now runs the queued text at once: held as a send is, the row stays queued.
              if (edit.op === "send_now") {
                const queued = snapshot.queue.find((entry) => entry.id === promptId)?.prompt;
                if (queued && holdsForComputerUseSetup(queued, false, computerUsePlace)) return Promise.resolve(false);
              }
              // A held prompt's text and images change in the pane; nothing else applies to it.
              if (trustHeld.has(promptId)) {
                trustHeld.edit(promptId, edit);
                return Promise.resolve(edit.op === "update");
              }
              return startingSends.owns(promptId)
                ? Promise.resolve(edit.op === "update" && startingSends.edit(promptId, edit.text))
                : editQueued(promptId, edit);
            }}
            // A prompt that started while it was edited comes back to the prompt, so the edit is kept.
            // A row still waiting for a new chat gives its edit back only once it went: a refusal gave
            // the prompt back as it was sent, so the edit ends as Esc ends one (startingSends.ts `lost`).
            onQueueLost={(text, promptId) => startingSends.lost(promptId, text)}
            // A queued row's Open in side chat: `/btw`'s path, behind its gate. The prompt leaves the
            // queue first, so it never also runs here; one that already started stays with the turn.
            // A side chat that could not start gives its text back to the prompt.
            // The waiting agent messages' cards offer it too (queueSideChatRef).
            onQueueSideChat={
              (queueSideChatRef.current =
                opensSideSessions && !isSideSession && snapshot.sessionId
                  ? async (promptId, prompt) => {
                      const sessionId = snapshot.sessionId!;
                      // A side chat on this Mac runs the text as a send: held before the row leaves the queue.
                      if (holdsForComputerUseSetup(prompt, false, computerUsePlace)) return false;
                      // A row still waiting for the chat to take it leaves here; one with images stays,
                      // as a side chat asks the text alone.
                      const local = startingSends.rows.find((row) => row.id === promptId);
                      if (
                        local
                          ? local.attachments.length > 0 || !startingSends.remove(promptId)
                          : !(await removeQueued(promptId))
                      )
                        return false;
                      setBtwFailure(undefined);
                      // The side session's notice says it plainly (the prompt is back in the composer
                      // to send again); a reason only when the pane words it, the rest in the log.
                      const fail = (error: unknown) => {
                        console.warn("agent pane: the side session did not start", error);
                        setBtwFailure({ sessionId, reason: knownRefusalText(error) ?? "" });
                      };
                      // Asked again once the row left the queue (the removal awaited): it holds and says
                      // why, and the text comes back to the composer.
                      if (holdsForComputerUseSetup(prompt, false, computerUsePlace, false)) {
                        composerHandle.current?.restore(prompt, []);
                        return false;
                      }
                      callNative<string>("chat.btw", { question: prompt }).then(
                        (side) => postNative("chat.sideChat", { sessionId: side }).catch(fail),
                        (error: unknown) => {
                          fail(error);
                          composerHandle.current?.restore(prompt, []);
                        },
                      );
                      return true;
                    }
                  : undefined)
            }
            queueImage={readQueuedImage}
            onProject={pickSourceProject}
            // A machine with no folder known here: the new chat starts there, in its default folder.
            onComputer={(computer) => {
              // Switching away from an explicitly selected Cloud machine must not leave a stale
              // draft target that a later keystroke could wake.
              cloudDraftMachineID.current = null;
              dropDeferredGitHub();
              rememberNewChatPlace(computer === "local" ? { kind: "local" } : { kind: "machine", peer: computer });
              void callNative("chat.new", computer === "local" ? {} : { peer: computer }).catch(() => undefined);
            }}
            // A chat on a Cloud machine whose first send has not run: another Cloud machine picked moves it
            // there and sends its first prompt again (cloudRepick.ts), instead of a new empty chat.
            {...(snapshot.summary?.hostKind === "cloud" && !quick
              ? { onRepick: (machine: RepickMachine) => repickCloudChat(callNative, machine) }
              : {})}
            // A Cloud or SSH chat's worktree is made on its machine, beside its repository there
            // (cmuxterm-hq#7856: whatever works on a local chat works on a Cloud chat).
            onNewWorktree={freshChat && !quick ? startInWorktree : undefined}
            onCloneRepository={
              freshChat && !quick && !remoteChat ? (url) => cloneRepository(callNative, url) : undefined
            }
            onNewProject={openEmptyProject}
            noProject={projectDraft === ""}
            sourceRepository={checkedOutGitHub}
            onCloudFolderWaiting={setCloudSourceWaiting}
            cloningRepository={cloningGitHub}
            pendingRepository={cloningGitHub ? undefined : pendingGitHub}
            onNoProject={freshChat ? clearProject : undefined}
            // A GitHub repository picked for a new chat on this Mac: its checkout here (cloned first when
            // there is none), then the chat's worktree of it.
            {...(freshChat && !quick
              ? {
                  onGitHubHere: deferGitHub,
                }
              : {})}
            onConnect={connectMachine}
            // A started chat's Local, Cloud, Auto (beside the picker's own move row); the floating chat has none.
            // Built once per chat by the pane (App.tsx `placeControl`): an inline element here was a new prop on
            // every pane render, so each streamed chunk drew the composer and its box again while keys waited.
            {...(placeControl ? { placeControl } : {})}
            // The floating chat has no tab to move.
            {...(quick
              ? {}
              : {
                  onOffload: offloadChat,
                  offloads,
                  offloadReasons,
                  moveTargets,
                  onMoveTo: (id: string) => moveChatToMachine(id, snapshot.sessionId),
                })}
            // The list opened: the machines' status and the chat's moves are read again.
            onRefreshMachines={() => {
              void directClient.current?.refreshPeers();
              refreshTabState();
            }}
            // A started local chat lists the same folders to move to (dogfood 09); Start Agent's
            // panel lists them before its first prompt (cx-hkat).
            projectChoices={freshChat || (!quick && canMove) ? newTabProjects : undefined}
            {...(machineFolders ? { machineFolders } : {})}
            // An unsent chat's Add folder…: folders it sees beside its project, or beside its private
            // folder with none (Leo, 2026-11-03: "and you can also just start with nothing").
            {...(freshChat && !quick && !snapshot.sessionId
              ? {
                  extraFolders: {
                    draft: extraFolderDraft,
                    onChange: setExtraFolderDraft,
                  },
                }
              : {})}
            onBrowseProject={
              folderChoiceOffered
                ? chooseWorkspaceFolder
                : freshChat && !quick
                  ? (request?: BrowseRequest) =>
                      callNative<{ cwd?: string }>("project.browse").then((result) => {
                        if (result?.cwd && !request?.deferPick) void chooseProject(result.cwd);
                        return result?.cwd;
                      })
                  : undefined
            }
            // A Cloud or SSH chat's command runs on its machine, in its folder there (the host's routing).
            onShell={composerShell(shellRuns, {
              ...(composerSnapshot.summary?.cwd ? { cwd: composerSnapshot.summary.cwd } : {}),
              ...(snapshot.sessionId ? { sessionId: snapshot.sessionId } : {}),
            })}
            localName={thisMacName(localMachineName, machineName, composerSnapshot.summary)}
            environments
            // Where the new chat runs is settable as soon as Cloud may be offered here, not only once the
            // host's check answered: before, the Where menu's Cloud row ran New Cloud Machine meanwhile
            // and made a workspace on the click (cmux#47677). A send before the check waits for it
            // (cloud_checking, cloudSendAfterCheck). A page on another machine starts no Cloud chat. Cloud
            // still picked while it is briefly not offered (a pending selection, a switch) stays shown, so
            // the menu never reads This Mac while Return goes to Cloud (cmux#47679).
            {...((cloudOfferable && !onOtherMachine) || cloudPickedNotOffered ? { runMode: composerModeRows } : {})}
            onBrowseFolder={
              canMove ? () => callNative<{ cwd?: string }>("project.browse").then((result) => result?.cwd) : undefined
            }
            // A started local chat's folder is fixed (Leo 2026-10-13): its folder menu starts a new chat
            // in a tab of its own; a Cloud chat's folder is a label.
            // The floating chat has no tabs to open one in. Another machine's `~` is not this Mac's: a
            // remote chat starts one only in an absolute folder.
            onNewChat={
              canMove && !quick
                ? (cwd) => {
                    if (!remoteChat || cwd.startsWith("/")) ignoreFailure(callNative("chat.newHere", { cwd }));
                  }
                : undefined
            }
            onShellInterrupt={() => {
              const running = shellRuns.running(snapshot.sessionId);
              if (running) shellRuns.stop(running.id);
              return running !== undefined;
            }}
            onMode={(modeId) => callNative("chat.mode", { modeId })}
            // Without a folder there is nothing to search; the + menu leaves the item out.
            searchFiles={fileRoot ? searchFiles : undefined}
            plusExtensions={plusSearchExtensions}
            onPlusCommand={runPlusSearch}
            capture={captureScreen}
            // A recording goes by its path on this Mac: only a chat here can read it (as Sources' + below).
            canRecord={localCwd !== undefined && localFileLinks}
            upload={uploadFiles}
            localPaths={localFileLinks ? localPaths : undefined}
            onOpenInWindow={quick ? openInWindow : undefined}
            // ⌘↩ on an empty prompt answers a waiting tagged ask's first answer (NextStepCard.tsx),
            // never while a question or permission card waits.
            onEmptyCommandReturn={hasBottomAsk ? undefined : nextStepFire?.fire}
            prompt={prompt}
            handle={composerRef}
            onUnplacedQuotes={composerUnplacedQuotes}
            // No prompt goes while a picked folder waits for the user's answer, or while the chat only
            // shows a session another app runs (WatchBanner).
            // The folder's trust question holds Send only for a remote chat and Start Agent
            // (trustSendOff): a prompt sent under it waits in the pane (trustHeld.ts), or goes now to
            // a chat whose agent already runs (trustPasses). A read in flight (`{}`) holds nothing.
            blocked={composerTrustBlock(trustSendOff, trustAsk.blocked)}
            // A new chat on another machine holds Send while its agent is not set up there.
            blockSend={
              blockSend ||
              cloudSendHeld ||
              Boolean(cloningGitHub) ||
              (cloudPicked && cloudSourceWaiting) ||
              machineCheck.blocked
            }
            closeOnTrustAsk={Boolean(
              trustAsk.ask && (trustAsk.ask.state !== "decided" || trustAsk.ask.level === "untrusted"),
            )}
            // A preflight still disables sending, but must not insert then remove a checking row
            // above the already-painted composer. Settled authentication failures keep their notice.
            authBlock={signInNoticeVisible ? undefined : authBlock}
            authChecking={authPreflightPending}
            authBlocked={Boolean(authBlock)}
            // The composer draws the session's strip before its Send, and Send ends the session.
            accessory={composerMic}
            dictating={isWaitingForWords(dictation.state)}
            dictation={dictation}
            onImportFile={importFile}
            importSandboxed={sandbox.mode === "sandboxed"}
            onEdit={(command) => ignoreFailure(callNative("pane.edit", { command }))}
          />
        </ImageViewerContext.Provider>
      </>
    )
  );
}
