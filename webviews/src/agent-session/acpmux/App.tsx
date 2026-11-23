import { composerHealthHarness } from "./composerPickerEntries";
import { useFold } from "./conversation/fold";
import { setSessionRefResolver } from "./conversation/sessionRefs";
import { useHeightsSettledFor } from "./conversation/unsettledHeights";
import { PANE_PAINTED_MARK } from "./firstLoadWatch";
import { useStopThroughReconnect } from "./stopThroughReconnect";
import React, {
  useCallback,
  useEffect,
  useEffectEvent,
  useLayoutEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { useShareNudge } from "./share/shareNudgeModel";
import { paneTipHost } from "./featureTipsModel";
import { type CaptureMode, composerPlusSearchExtensions, PLUS_SEARCH_ACTIONS } from "./composerPlusRegistry";
import { takeCapture } from "./composer/screenCapture";
import { chatOnThisMac, chatPlace, chatMachine as chatMachineOf } from "./chatMachine";
import {
  CONNECT_ACTIONS,
  type ConnectKind,
  type OffloadKind,
  offloadReasonsOf,
  environmentReady,
} from "./environments";
import { machineHarnessVerdict, useMachineHarnessCheck, withMachineHarnesses } from "./machineHarnesses";
import { sayActionRefusal } from "./actionRefusal";
import { QueryClientProvider, useIsFetching, useQueryClient } from "@tanstack/react-query";
import {
  paneHeader,
  type AcpmuxPermission,
  type AcpmuxSecretAsk,
  type AcpmuxRow,
  type AcpmuxSnapshot,
  linkUp,
  SINCE_DIVIDER,
  type AcpmuxPlanEntry,
} from "./model";
import {
  lacksImageBytes,
  ownQueue,
  queuedAttachments,
  queuedMessageRows,
  useShownQueue,
} from "./conversation/queuedMessages";
import { pendingMessagesRow, searchablePendingRows, withWaitingRows } from "./conversation/pendingMessages";
import { type QueuedMessageActionsValue } from "./conversation/QueuedMessageCard";
import { AcpmuxDirectClient, type HarnessBlock, isTrustRefusal } from "./direct";
import { watchRestoredTail } from "./restoredTail";
import {
  authBlocksSend,
  authText,
  isAuthPreflightPending,
  sessionLogin,
  useRouteAuthSwitch,
  useSessionAuth,
  UNKNOWN_AUTH,
} from "./sessionAuth";
import { hasNativeHost, postNative } from "./native";
import { reportToastAvoidance } from "./toastAvoidance";
import { OpenAppCard, afterLatestFooter } from "./OpenAppCard";
import { setCloudPreviewContext, useCloudPreviewPorts } from "./cloudPreviewPorts";
import { useChatCloudEnvironment } from "./CloudEnvironmentChip";
import { NativeError } from "./nativeError";
import { errorMessage, isStartCancelled, knownRefusalText } from "./transportErrors";
import { pageHostClient } from "./pageHost";
import { type NewTabChat, type NewTabHost, pickedNewTabApp } from "./newTabModel";
import { type NewTabScreenActions } from "./newtab/NewTabScreen";
import { HarnessesScreen } from "./harnesses/HarnessesScreen";
import { ContextScreen } from "./context/ContextScreen";
import { contextAccess, contextSave } from "./context/contextAccess";
import { registerHarnessesPage } from "./harnesses/harnessesPage";
import {
  injectedNewTabContext,
  useEarlyNewTabContext,
  useLostSharedPart,
  useNewTabAdoption,
  useNewTabPlaces,
  adoptionPlan,
  carriedAnchor,
  keepAdoptedTail,
  useSessionAdoption,
  type SessionAdoption,
} from "./newtab/adoption";
import { sharesChatList, useSharedSessions } from "./newtab/chatStore";
import {
  heldPick,
  shownCloudStartPick,
  withDraftFolder,
  withCloudStartFolder,
  withCloudStartPick,
} from "./newtab/draftFolder";
import { cloudModePickFor as cloudModeFor, useCloudModePick } from "./cloudModePick";
import { rememberStartedProject } from "./newtab/startedProject";
import { shownNewTabSessions, useWarmNewTabSessions } from "./newtab/warmSnapshot";
import { TaskGoalStrip } from "./TaskGoalStrip";
import { hatPlanOf } from "./chatTaskList";
import { goalHatPlace } from "./goalHat.experiment";
import { jumpLatestPlace } from "./jumpPlace.experiment";
import { githubFolderRepo } from "./githubRepos";
import { useSessionCommands } from "./newtab/useSessionCommands";
import { shownTemplate } from "./newtab/templates";
import { holdNewTabAttachments } from "./newtab/remoteAttachmentDraft";
import { startNewTabTransition } from "./newtab/startTransition";
import { PendingPaneDraw } from "./paneSnapshotLane";
import {
  FolderRecency,
  folderFields,
  isAgentHome,
  placeFields,
  projectLabel,
  SessionsBy,
  sessionTitle,
  type AcpmuxSessionEntry,
} from "./sessionList";
import { findSession } from "./sessionIndex";
import {
  DRAFT_SETTLE_MS,
  hasPendingDraftWrite,
  readDurableDraftState,
  readPersistedDraft,
  settlePendingDraftWrites,
  writePersistedDraft,
} from "./composerDraft";
import {
  createPaneQueryClient,
  harnessCatalogKey,
  useHarnessCatalog,
  useHarnessesListed,
  type HarnessCatalogSource,
  useMachineHarnesses,
} from "./catalog";
import { usePickerCatalog } from "./modelCatalogHost";
import { isDefaultChoice } from "./defaultChoice";
import { applySwitch, browserSwitchClock, HarnessSwitch } from "./harnessSwitch";
import { liveAsk } from "./liveAsk";
import { NewChatPrewarm, type PrewarmTarget } from "./newChatPrewarm";
import { harnessModeName, highestMode } from "./harnessModes";
import {
  CloudTypingPrewarm,
  cloudIdentityKept,
  cloudTypingMachineID,
  type CloudIdentityView,
  sameNewChat,
} from "./cloudTypingPrewarm";
import { CloudComposeReservation, reservedCloudCall } from "./cloudComposeReservation";
import { useComposerKeyboard } from "./composerFocus";
import { type AutomationCompose } from "./automation";
import { acpmuxPerf } from "./perf";
import { type PerfSend } from "./perfReporter";
import { startFromContext } from "./newtab/startHint";
import { useSameValue } from "./session-info/sameValue";
import { drawsAsIs, setStreamingRowBlocked, streamingRowBlocked, textOnlyRow } from "./streamingRow";
import { liveToolOutput } from "./liveToolOutput";
import { remoteComposer } from "./remoteEditing";
import { type ComposerHandle, type ComposerRelay, type ComposerWake } from "./Composer";
import { takeExternalInto } from "./composer/externalAttach";
import {
  FolderContinuation,
  folderContinuationRequest,
  readOnlyContinuationRequest,
  readOnlyHarness,
} from "./folderContinuation";
import type { BrowseRequest } from "./AddProjectPanel";
import { handBackQuotes, quoteIntoComposer, replayHeldForComposer, restoreComposerDraft } from "./composerRestore";
import {
  linkAttachment,
  linkItems,
  type ComposerAttachment,
  type DroppedKind,
  recordingAttachment,
  recordingLeftOutNotice,
  remoteRecordingAttachment,
} from "./attachments";
import { keptChips } from "./composer/keptAttachments";
import { chatAccessGrants } from "./header/grantsMenu";
import { SIGN_IN_REQUIRED } from "./startRefusal";
import { type EmptyStateProjects } from "./EmptyState";
import { isNewChat, projectName } from "./emptyStateModel";
import type { TourOfferActions } from "./repoTour/TourOffer";
import { dismissTour, isTourDismissed, offersTour, TOUR_PROMPT, type TourTask } from "./repoTour/tourModel";
import { useCloudChatRecovery } from "./useCloudChatRecovery";
import { cloudChatRecoveryActive, cloudChatUnavailable, type CloudChatIdentity } from "./cloudChatRecovery";
import { cloudSendWakes, cloudTypingWakes, type CloudWakeState } from "./cloudWake";
import { type PastTurn } from "./pastChatModel";
import type { Project } from "./ProjectChooser";
import { byRecentUse, parseProjectRepos } from "./projectRepos";
import { agentDotGridArm } from "./dotGrid/agentDotGrid.experiment";
import { lastChange, turnFiles, turnPathsOnly, turnRows, type PathRef, type TurnFile } from "./diff";
import { opensTurn } from "./turnStart";
import { TrustAsk } from "./TrustAsk";
import { trustedLabel } from "./trustAskModel";
import { ElevationCard } from "./ElevationCard";
import { SecretCard } from "./SecretCard";
import { ToolCards } from "./toolCards/ToolCards";
import { type UploadProgressReport, uploadToMachine } from "./cloudUploads";
import { droppedPaths } from "./composer/intakeFiles";
import { useToolCards } from "./toolCards/toolCardStore";
import {
  COMPUTER_USE_PREVIEW_RESERVE,
  useComputerUsePreview,
  useComputerUsePreviewRoom,
} from "./computerUse/computerUsePreview";
import { askOnSingleCard, cardTakesShortcuts, heldOnCard } from "./permissionKeys";
import { agentName } from "./agents";
import { translate, usePaneLanguage, useT } from "./i18n";
import { chatCloudMachine, createStopWaiter } from "./cloudMachineMenu";
import { refreshCloudMachines, useCloudMachines, type CloudMachine } from "./cloudMachines";
import { usePeerCloudMachine } from "./peerCloudMachine";
import { inThisVisit, useFolderTrustAsk, visitOf } from "./useFolderTrustAsk";
import { movedOn, sentIn as sentInHeld, useTrustHeldPrompts, whereHeldGoes, type TrustHeldPrompt } from "./trustHeld";
import { type SendGesture } from "./heldPrompt";
import {
  StartingSends,
  type StartingSend,
  startingQueueEntry,
  queuedStartingSends,
  withStartingPrompt,
  startingIn,
} from "./startingSends";
import { FILE_SEARCH_LIMIT, type FileSearchSource } from "./fileSearchModel";
import { SummaryCard } from "./summary/SummaryCard";
import { transcriptBackground } from "./summary/sessionSummary";
import { openSourceFile } from "./session-info/sourcesSectionModel";
import { useSessionInfo } from "./session-info/useSessionInfo";
import { toggleRemoteControl, useRemoteControl } from "./remoteControl";
import {
  type BackgroundCommand,
  backgroundCommands,
  backgroundSection,
  type ProcessSource,
  useProcessRegistry,
  backgroundRowCount,
} from "./session-info/processes";
import {
  setSessionInfoOpen as setSessionInfoPanelOpen,
  setSessionInfoSection,
  useSessionInfoOpen,
  sessionInfoPaneKey,
} from "./session-info/sessionInfoState";
import { chatProcessesHere, openCommand, opensProcessTerminal } from "./processTerminal";
import {
  descendants,
  subagentChangesFolder,
  subagentProcesses,
  subagentSummary,
  withChatEnds,
  type SubagentScope,
  callIds,
} from "./session-info/subagentScope";
import { pendingToolCalls, waitingSubagents } from "./summary/subagentStatusListModel";
import { SubagentTray } from "./subagents/SubagentTray";
import { tuckTray } from "./subagents/trayPullTabModel";
import { agentProgressSource } from "./subagents/agentProgressSource";
import { AgentProgressContext, AgentProgressStore } from "./subagents/agentProgressStore";
import {
  type BackgroundPanel,
  backgroundPanelFor,
  isBackgroundPane,
  openBackgroundPane,
} from "./backgroundTasks/backgroundPane";
import { OpenBackgroundTasks, requestBackgroundFocus, useBackgroundFocus } from "./backgroundTasks/openBackgroundTasks";
import { backgroundGroups, type TaskCache } from "./backgroundTasks/backgroundTasks";
import { settleTrayExit } from "./subagents/trayMotionModel";
import { configureWorkflowCardOpen, configureWorkflowCardSideTab } from "./summary/workflowCardModel";
import {
  type DoneLineCache,
  finishedTrayItems,
  type TrayItem,
  trayItemKey,
  trayItems,
  useSubagentTray,
  withSubagentLines,
  endedInFailure,
} from "./subagents/runningTray";
import { lingeringTrayItems, trayItemEnd, useTrayLinger, TRAY_LINGER_MS } from "./subagents/trayLinger";
import { useSubagentTrayPlacement } from "./subagents/subagentTrayPlacement";
import { SelectionReplyChip } from "./conversation/SelectionReply";
import { setQuoteReplySink } from "./conversation/selectionReplyModel";
import { agentTone, agentTones } from "./subagents/agentTones";
import { useSummaryCard, useSummaryColumn } from "./summary/cardState";
import { chatHasSummaryContent } from "./summary/summaryContent";
import { createWorkflowAdapter, workflowDetailRequest, type WorkflowDetailRequest } from "./summary/foldWorkflows";
import { workflowPaneId, workflowPaneRequest } from "./summary/workflowTranscript";
import { useWorkflowTranscript } from "./summary/useWorkflowTranscript";
import { releaseReaderScroll, useHeldWhileScrolling } from "./summary/heldWhileScrolling";
import type { WorkflowAgent, WorkflowSummary } from "./summary/workflow";
import {
  backToOpeningChat,
  showSubagent as showSubagentIn,
  revealedSubagent,
  subagentTabTitle,
  useAutoOpenSubagents,
  useOpenNewSubagents,
  subagentRowMark,
} from "./subagents/subagentPanes";
import { shownSubagentFacts, useShownSubagent } from "./subagents/subagentShown";
import { turnCounts } from "./changes/turnCheckpoint";
import { TurnCountsContext, type TurnCountsFor } from "./changes/TurnCountsContext";
import { shotTurnId, TurnShotCache, type TurnShotsReader } from "./turnChanges/turnShots";
import { SessionEditsAndShots } from "./turnChanges/TurnShotsPair";
import { useTurnCheckpoints } from "./changes/useTurnCheckpoints";
import { latestTurnCheckpointPair, readTurnFromRows } from "./changes/turnCheckpointSource";
import { useComposerSettings } from "./composerSettings";
import { restoredDecisions, type HunkDecision, type HunkReview } from "./changes/hunkReview";
import { useDictation, type DictationField } from "./dictation";
import { DictationMic } from "./DictationMic";
import { useComposerView } from "./composer/composerView";
import type { MarkdownFieldHandle } from "./MarkdownField";
import { agentNames, agentViews } from "./conversation/agentNames";
import { loadEditDiffHunks } from "./conversation/editDiffModel";
import { loadHighlightedCode } from "./conversation/codeBlockModel";
import { BackgroundTaskOutputContext, type BackgroundTaskOutputReader } from "./conversation/backgroundTaskOutput";
import { SessionCwdContext, sessionEdits, type SessionEdits } from "./turnChanges/sessionRows";
import { startedNames, SubsessionNamesProvider, type StartedNames } from "./conversation/startedNames";
import {
  headerChangesInPlace,
  repositoryRoot,
  viewChangesBeside,
  viewChangesFiles,
  viewChangesPatch,
  viewChangesTurn,
} from "./turnChanges/viewChanges";
import { type SendPromptAgainState } from "./conversation/sendPromptAgain";
import { interruptedResumeTarget, type InterruptedResumeState } from "./conversation/resumeInterrupted";
import {
  TurnActionsContext,
  chatLoginCommand,
  compactThrough,
  offersCompact,
  answerThrough,
  type TurnActions,
} from "./conversation/turnActions";
import {
  RunInBackgroundContext,
  backgroundsWork,
  foregroundCalls,
  useBackgroundKey,
} from "./conversation/runInBackground";
import { SkillWordsContext, useSkillWords } from "./conversation/skillWords";
import { TranscriptChief } from "./conversation/sentFrom";
import { trackEditableTurns, trackPromptTurns, type EditableTurns, type PromptTurns } from "./conversation/editPrompt";
import {
  CloudTurnCheckpoints,
  readyPromptKey,
  readyPromptMap,
  readyPromptRows,
  bindMarks,
  chatWithCheckpoint,
  marksFor,
  type ChatMarks,
} from "./conversation/cloudTurnCheckpoints";
import { isFindRow, type ChatFind } from "./conversation/chatFind";
import { revealedSaid, saidRows, type SaidReveal } from "./conversation/saidReveal";
import { ChatFindScope } from "./conversation/ChatFindScope";
import {
  messageRevealTarget,
  openViewTurnFold,
  toggleTurnFold,
  toggleViewTurnFold,
  hiddenRowFolds,
  type TurnView,
  liveTurnPlan,
  earlierTurnPlan,
  EARLIER_PLAN,
  withEarlierPlan,
  samePlanEntries as sameEntries,
  waitingAsks,
  closeTurnRuns,
  turnInsideIds,
} from "./conversation/turns";
import { PendingAsks } from "./conversation/PendingAsks";
import { forgetInsideTurn } from "./conversation/transcriptDisclosureModel";
import {
  answerState,
  answeredAsks,
  bottomAsks,
  claimAnswer,
  dismissAsk,
  dismissedAsks,
  givenAnswer,
  setAnswerState,
  subscribeAnswers,
  withAnswered,
  shownAsks,
} from "./conversation/waitingAskStore";
import { turnPreviewUrl, turnServedUrl } from "./conversation/previewUrl";
import { canFork, forksAnyTurn, latestForkSeq, canForkTurn } from "./conversation/messageMenu";
import { callChipHost } from "./chips/host";
import { type SaveDocument } from "./conversation/ArtifactPanel";
import { useArtifactCoversPane } from "./conversation/artifactPanelModel";
import { pullRequestRef } from "./chips/pullRequestCardModel";
import { branchesFromKey, branchesKey, messageBranches } from "./conversation/branches";
import { ArtifactContext, type Artifact } from "./conversation/artifactPreview";
import { artifactVersionsForSession, visibleArtifact, type OpenedArtifact } from "./conversation/artifactPin";
import { uniqueArtifacts } from "./conversation/artifactDedupe";
import { writtenArtifacts } from "./conversation/writtenArtifactsModel";
import { artifactVersions, finishedReplyDocuments } from "./conversation/artifactVersions";
import { artifactLiveSource, mergeArtifactVersions } from "./conversation/artifactLive";
import { RenderPages, renderPages, renderVersions } from "./conversation/renderCall";
import { ShortcutsContext, type ShortcutLabels } from "./shortcuts";
import { notifyRevealRowsChanged, revealedMessage, revealMessageWhenShown, revealTurnWhenShown } from "./links";
import { useNeedsYou } from "./needsYou/useNeedsYou";
import type { ChatImage } from "./conversation/chatImages";
import { viewerImages } from "./summary/chatGallery";
import { ImageViewer } from "./conversation/ImageViewer";
import { ImageViewerContext } from "./conversation/imageViewerContext";
import { useStreamAppendDeclaration } from "./devMotionAudit";
import { HEADER_ACTIONS, type ChatMenuItem } from "./header/chatHeaderToolsModel";
import { setHeaderState, useHeaderState } from "./header/headerState";
import { useTabRow, useTabRowRoot, useTabRowTools } from "./header/tabRow";
import {
  draftMessage as subagentDraftMessage,
  keepSubagentDraft,
  restoreSubagentDraft,
  sendingSubagentDraft,
  subagentDraft,
  subscribeSubagentDraft,
} from "./subagents/subagentDrafts";
import { afterFailedSend } from "./subagents/subagentComposerModel";
import {
  subagentRelayPrompt,
  subagentRelaySteers,
  subagentTarget,
  workflowAgentTarget,
} from "./subagents/subagentMessage";
import { runsUnderTabRow, type UnderHeaderLines } from "./header/underHeader";
import type { LocalCommand } from "./localCommands";
import {
  composerAgentLocal,
  cloudFolderGrants,
  cloudStartFolder,
  cloudStartTeam,
  makeCloudSignInRetry,
  grantedCloudStart,
  cloudStartKeys as makeCloudStartKeys,
  type CloudStart,
  type CloudStartAnswer,
  cloudSendAfterCheck,
  composerCloudStartFolder,
  pageOnOtherMachine,
} from "./cloudRun";
import { promptBeforeTyped, type CloudStartDraft } from "./cloudStartCarry";
import { folderRunLocation, newChatRunLocation, defaultFolderFor } from "./runLocationDefault";
import {
  lastNewChatPlace,
  pickedRunLocation,
  pickedStartMachine,
  placeOfRunMode,
  rememberNewChatPlace,
} from "./lastNewChatPlace";
import { cloudStartStalled, watchCloudStartStall, type CloudStartProgress } from "./cloudStartProgress";
import { createCloudPlanSubscribe } from "./cloudPlanSubscribe";
import { type CloudSignInWait } from "./cloudSignIn";
import { retryWithSetUpPick, type CloudSetupAction, type CloudSetupNeed } from "./cloudSetup";
import { ClaudeConnectContext, setupConnect } from "./claudeConnect";
import { type QuickActionMode } from "./header/quickActions";
import {
  useChatDisplay,
  useChatMinimap,
  useChatPinnedPlan,
  useFeatureTipsOn,
  useTrayHandle,
  useTrayTucked,
} from "./chatDisplay";
import { usePresentation } from "./conversation/presentation";
import { PresentationContext } from "./conversation/presentationContextModel";
import { thinkingVerbsFor, ThinkingVerbsContext } from "./conversation/thinkingVerbs";
import { useStatusVerbConfig } from "./statusVerbs";
import { mergeInboxNotices } from "./conversation/inboxNotice";
import {
  cloudAgentLogin,
  type CloudSignIn,
  localAgentLogin,
  localApiKeyLogin,
  SIGN_IN_ON_MACHINE,
} from "./cloudAgentLogin";
import { archiveRow, markUnreadRow } from "./header/archiveRow";
import { archiveClosesTab, deleteClosesTab } from "./header/archiveClose";
import { avatarRows } from "./header/avatarRow";
import { useChatMini } from "./header/miniRow";
import { removeAgentAvatar, setAgentAvatar, useAgentAvatar } from "./agentAvatar";
import { instructionsRow, projectFilesRow } from "./header/instructionsRow";
import { sideChatPlace, sideChatRefusal, sideChatRow } from "./header/sideChatRow";
import { isCurrentMenuCommand, parseMenuCommand } from "./header/menuCommands";
import { errorRecovery, lastFailedTurn } from "./conversation/errorRecovery";
import { type WorkingCounts, WorkingCountsContext } from "./conversation/workingForModel";
import { type PreviewChips, PreviewChipsContext, previewsOf } from "./conversation/previewChipModel";
import {
  type RunElsewhere,
  RunElsewhereContext,
  type RunOutput,
  type RunPlan,
  RunElsewhereStore,
} from "./conversation/runElsewhereModel";
import { NewestSteerContext, SteerChatContext } from "./conversation/pendingSteerModel";
import { chatWaitsOn, WaitingOnContext } from "./conversation/waitingOn";
import { useTranscriptView, type TranscriptView } from "./conversation/transcriptView";
import { isWorkedFold, NO_FOLD_TOGGLES, viewFolds, type Folds } from "./conversation/viewFolds";
import { type PaneFolds } from "./conversation/wakeFolds";
import { lastTurnWorkedKeys } from "./conversation/turnEndHold";
import { type HarnessHealth, type UpdateOffer, UpdateOfferContext } from "./harnessHealthNoticeModel";
import { HarnessUpdatesContext, useHarnessUpdateList } from "./harnessUpdateList";
import { Notice, NoticeSlot } from "./NoticeSlot";
import { createPaneToasts, paneNotices, postNativePaneToast } from "./paneToasts";
import { turnPhase } from "./turnPhase";
import { type ForumRule, forumRules } from "./rulesNoticeModel";
import { type SignIn, SignInContext, signedOutHarnesses } from "./signIn";
import { ACCESS_ACTIONS, type AccessOffer } from "./accessOffer";
import { type ChatAccounts, ChatAccountsContext, readChatAccounts } from "./chatAccounts";
import { ForkPendingLine } from "./ForkPendingLine";
import { HostError, HostLineSlot, HostRecoveringLine, HostUnavailableLine, HostWaitingLine } from "./HostError";
import { hostLineText } from "./hostLine";
import { AcpmuxRestartGate, type HostRestoring, readHostRestoring, hostSelfRetrying } from "./hostRetry";
import { pageShowsWhatItIs } from "./firstPaint";
import { ShellRuns } from "./shell/shellRuns";
import { type Subagent } from "./subagents/subagentFold";
import { restartOwner, restartReaches } from "./subagents/restart";
import { type SubagentRows, runningGroups, subagentsIn } from "./subagents/subagentRows";
import { foldOwnLog, subagentPaneView, useOwnLog, needsOwnLog } from "./subagents/subagentOwnLog";
import { lastReply as lastSubagentReply, SubagentReplyContext } from "./subagents/wholeReport";
import { knownMark } from "../shared/AgentMark";
import { useSenderIconLook } from "./subagents/senderIconLook";
import {
  SubagentHarnessContext,
  SubagentNavContext,
  SubagentPaneContext,
  SubagentClockContext,
  SubagentStopContext,
  SubagentViewsContext,
  running,
} from "./subagents/subagentGroupModel";
import { useEscapeClosesSubagent } from "./subagents/subagentEscape";
import { endedEditRow, markRows, type RowMarks } from "./rowMarks";
import { ShellActionsContext, type ShellActions } from "./shell/shellRowModel";
import { useBackgroundNotice } from "./conversation/backgroundNotice";
import { type InstructionsFailure } from "./header/InstructionsNotice";
import { showsFolderChoice } from "./folderChoiceModel";
import { ownMachineFolders, type ExtraFolderDraft } from "./extraFolders";
import { type FolderAsk, confirmFolder, newChatInWorktree, newWorktree, pickFolder } from "./startFolderModel";
import { useSyncedRef } from "../../diff-viewer/useSyncedRef";
import { useWorktreeSetupStart } from "./worktreeSetup";
import { NewTabFolderAsk } from "./NewTabFolderAsk";
import { chiefOf, isTakenOver, managedBy, managerDrivingUntil, takeOverManaged } from "./managedBy";
import { handoffStrings } from "./handoff/strings";
import { useExtensionCommands, withExtensionCommands } from "./composer/extensionCommands";
import { continueTargets, mergedCommands, type CmuxCommand, type CmuxCommandResult } from "./cmuxCommands";
import { handleCmuxCommand as runCmuxCommand } from "./pane/cmuxCommands";
import { chatMenuItems } from "./pane/chatMenu";
import { newChatRunsElsewhere } from "./customizeCommand";
import { dropHandedCloudStart, handCloudStart, handoffStore } from "./commandPlace";
import { canContinueIn, reviewingHandoff } from "./handoff/continueIn";
import { importedPrompt, parseImportedSession } from "./importSession";
import { useCheckpoints } from "./checkpoints/controller";
import { PermissionPanel } from "./permissions/Panel";
import { groupAskedCalls } from "./permissions/askRows";
import { withoutQuietThoughts } from "./conversation/thoughts";
import { checkpointStrings } from "./checkpoints/strings";
import { QUICK_MESSAGES, useEscapeToDismiss, type PaneSurface } from "./paneSurface";
import { QuickSurface } from "./QuickSurface";
import { chiefDock } from "./chiefDock.experiment";
import { contextAttachment, floatingStatus, type QuickFloating } from "./floatingChatModel";
import { setFloatingState, useFloatingState } from "./floatingState";
import { FailedSendsContext, type FailedSends } from "./conversation/promptDeliveryModel";
import { failedRuns, type FailedRun } from "./sendFailure";
import { clientWaiter } from "./lostPrompt";
import { sessionReplay } from "./replay/replay.experiment";
import { readSteerLog, type SteerAct } from "./steerQueue/log";
import { steerQueue } from "./steerQueue/model";
import { type SteerActions } from "./steerQueue/SteerQueue";
import { steerQueueExperiment } from "./steerQueue/steerQueue.experiment";
import { statusIslandExperiment } from "./statusIsland/statusIsland.experiment";
import { useStatusIsland } from "./statusIsland/useStatusIsland";
import { BtwNotes } from "./aside/btwNotes";
import { supportsBtwGuest } from "./btwCapability";
import { OfferDefaultsContext, offerDefaults } from "./offer/offerChoice";
import { queueingOn, setQueueing } from "./queueing";
import { NO_MENTIONS, StartedMentionsContext, type StartedMentions } from "./started/startedSessionCardModel";
import { type SessionHover, SessionHoverContext } from "./started/sessionHoverCardModel";
import { SessionHoverStore, withSessionIds } from "./started/sessionHover";
import { pageChatStore, setPageChats } from "./chips/cmuxLinkResolve";
import { SubsessionStore, type Subsessions, subsessionRows } from "./subagents/subsessions";
import {
  type StartedCache,
  type StartedSession,
  offerChildren,
  spawnedSessions,
  sessionMentions,
  startedCardsShown,
  startedSessions,
} from "./started/startedSessions";
import { experimentArm } from "../../experiments/experiment";
import { useSessionStatus } from "./sessionStatus";
import { holdWebSwap } from "../../pages/shared/webSwap";
import { useWebSwapHold } from "../../pages/shared/useWebSwapHold";
import {
  SandboxTab,
  newTabRunModeRows,
  sandboxAgent,
  sandboxPageRefusal,
  sandboxRetryable,
  type RunMode,
} from "./sandboxRun";
import { cloudChatHintDue, cloudChatHintShown, useCloudChatHint, useCloudChatHintClaim } from "./cloudChatHintModel";
import { withCloudMachineSummary } from "./cloudSummary";
import { callNative } from "./callNative";
import { awaitsProjectPreview, takeProjectPreview } from "./newtab/newProject";
import { copyShowsRunningTurn, showsChatSnapshot, swapChatSnapshot, watchChatSnapshot } from "./chatSnapshot/live";
import { snapshotDraft } from "./chatSnapshot/restoredDraft";
import { watchLaunchSettle } from "./launchSettle";
import { type NativeRegistry, type OpenDiff } from "./rows/rowProps";
import { editQueued, openOfferChat, openSenderChat } from "./rows/rowActions";
import { PermissionAsk } from "./rows/PermissionAsk";
import { ChildAsk } from "./subagents/ChildAsk";
import { childAsks } from "./subagents/childAsks";
import { hatQuestions, sameHatQuestions, type HatQuestion } from "./question/hatModel";
import { hatSeenKey, hatQuestionsShown, stackCardKeys } from "./question/hatSeen";

import { defaultRegistry } from "./rows/registry";
import { ReadOnlyRecapRow } from "./rows/RecapRow";
import { oneRecap } from "./conversation/oneRecap";
import { ReadOnlyMemoryOfferRow } from "./rows/MemoryOfferRow";
import { ReadOnlyPresetApprovalRow } from "./rows/PresetApprovalRow";
import { MEMORY_OFFER } from "./conversation/memoryInbox";
import { ReadOnlyPromptCoachRow } from "./rows/PromptCoachRow";
import { PROMPT_COACH } from "./conversation/promptCoach";
import { PRESET_APPROVAL } from "./conversation/presetApproval";
import { type ScrollAnchor, VirtualTranscript } from "./VirtualTranscript";
import { NO_ROWS, rowKind } from "./virtualTranscriptModel";
import { turnEndedBetween, cachedSnapshot } from "./snapshotCache";
import { newestTurnSummary, useFinishMoments } from "./finish/useFinishMoments";
import { useDraftWaitOver } from "./draftSettleHold";
import { focusRoute } from "../../ui/focusRoute";
import { paneSnapshotEffect } from "./pane/paneSnapshot";
export { VirtualTranscript } from "./VirtualTranscript";
export type { ScrollAnchor } from "./VirtualTranscript";
import "./pane/bridgeGlobals";
import {
  keptInChat,
  cancelTurn,
  removeQueued,
  reserveHeldPrompt,
  heldRefusals,
  heldRefusal,
  heldGoesAfterTrust,
  type SentFrom,
  type HeldSend,
  isPersonQueuedRow,
  answerHeld,
} from "./pane/sendHost";
import { postTyping, newChatDraft, postNewChatDraft, keptAttachments } from "./pane/draftHost";
import { postScrollAnchor, fetchScrollAnchor } from "./pane/scrollAnchorHost";
import {
  beginCloudSendWith,
  sendHeldForPlanWith,
  sendToCloudWith,
  type BeginCloudSend,
  type CloudPlanHeld,
  type CloudSendDeps,
  type SendToCloud,
} from "./pane/useCloudSend";
import { postOpenInWindow, quickChatName, postStartInBackground } from "./pane/quickHost";
import { knownHarnessHealth, knownGithubRepositories, trustSource } from "./pane/trustHost";
import { readFolderStatus, checkpointDiff } from "./pane/hostBindings";
import { turnActionsFrom, turnRowsShownFrom } from "./pane/useTurnActions";
import { replyElsewhere } from "./homeInboxModel";
import { quoteInReply } from "./conversation/selectionReplyModel";
import { answerPrompt, askQuote } from "./conversation/nextStepAsk";
import { type HatQuestionActions } from "./question/HatQuestions";
import { reply as questionReply, replyParams, selection } from "./question/model";
export { NewTabComposerChips, ChatComposerChips } from "./pane/ComposerChips";
import { DefaultComposerChips } from "./pane/ComposerChips";
import { drawPaneComposer } from "./pane/PaneComposer";
import { drawPaneBody } from "./pane/PaneBody";

/// The changes view comes in its own chunk (bd cx-z9kz0): it carries the diff and file-tree
/// packages, which a New Tab page never shows, so the page's first script parses without them.
/// It starts loading once the page has painted, with the transcript's highlighted code and edit
/// cards (conversation/CodeBlock.tsx, conversation/EditDiff.tsx), so opening it waits on nothing.

/// A page action: the connected client's (chat actions run against acpmux), else the native host.

/** Saves a side panel document through the host's save panel (`pane.saveFile`); a host without one, or a failed write, is unavailable (the panel copies the document instead). */
const saveDocumentNatively: SaveDocument = async (text, suggestedName, kind) => {
  try {
    return (await callNative<boolean>("pane.saveFile", { text, suggestedName, kind })) === true ? "saved" : "cancelled";
  } catch {
    return "unavailable";
  }
};

/// `promise`'s value, or undefined once `until` (a Date.now() time) passes first.
const settledBy = <T,>(promise: Promise<T>, until: number): Promise<T | undefined> =>
  Promise.race([promise, new Promise<undefined>((settled) => setTimeout(settled, Math.max(0, until - Date.now())))]);

/// The width the header's tools take in the pane's tab row, so the App narrows the tabs (header/tabRow.ts).
const reportTabRowTools = (width: number) => void callNative("pane.tabRowTools", { width }).catch(() => undefined);
/// The longest a chat the handshake named keeps the host's loading state up for acpmux's attach. A
/// last resort only: the page reports its first paint once the chat's rows are in (`chatRead`) or
/// its open failed. A shorter hold showed a busy daemon's chat as an empty page with only its
/// composer (Leo 2026-10-21: "I LOAD IN AND IT'S A BLACK SCREEN").
const CHAT_DRAW_HOLD_MS = 10_000;

/// How many turns back the header's Preview looks for a page.
const PREVIEW_TURNS = 8;
/// How long a running line count's reveal holds a run open while its row draws (WorkingFor.tsx).
const REVEAL_HOLD_MS = 2_000;
/// An inbox notice's thread the person opened (`chat.inbox.thread`): its messages, oldest first.
// Agent links and `HOST/NAME` refs in replies resolve through the page's acpmux client.
setSessionRefResolver((query) => callNative<unknown>("chat.session.resolve", { query }));
const NO_STARTED: readonly StartedSession[] = [];
const NO_SESSION_IDS: ReadonlySet<string> = new Set();
const NO_EXPANDED: ReadonlySet<string> = new Set();
const NO_SPAWNED: readonly AcpmuxSessionEntry[] = [];
const NO_COMMANDS: readonly BackgroundCommand[] = [];
const NO_AGENTS: readonly Subagent[] = [];
const NO_HAT_QUESTIONS: readonly HatQuestion[] = [];

const sameItems = <T,>(a: readonly T[], b: readonly T[]) =>
  a.length === b.length && a.every((item, index) => item === b[index]);

export const currentRegistry = (): NativeRegistry => ({
  ...defaultRegistry,
  ...(window.cmuxAcpmuxRegistry as unknown as NativeRegistry | undefined),
});

/// The index of the streaming reply's row when `next` differs from `drawn` only in that row's
/// text (HOT PATH AUDIT area F, row W1), else -1. Every other field compares by identity: the client
/// keeps the same objects while they do not change (direct.ts `publishedSummary`, `NO_CATALOG`,
/// subagentFold.ts `views`), so this is O(fields + rows), with no serialization. Drawn only while
/// the transcript draws that row as the client holds it (`drawsAsIs`) and no view that reads the
/// pane's rows is open (`streamingRowBlocked`).
export function streamedOnly(drawn: AcpmuxSnapshot, next: AcpmuxSnapshot): number {
  const before = drawn as unknown as Record<string, unknown>;
  const after = next as unknown as Record<string, unknown>;
  const keys = Object.keys(after);
  if (keys.length !== Object.keys(before).length) return -1;
  for (const key of keys) if (key !== "rows" && !Object.is(before[key], after[key])) return -1;
  if (streamingRowBlocked()) return -1;
  const at = textOnlyRow(drawn.rows, next.rows);
  return at >= 0 && drawsAsIs(drawn.rows[at]!) ? at : -1;
}

/// Answers a secret card in the page (`chat.secret`): the value goes to acpmux only.
/// A provided value's failure reaches the card (it keeps the typed secret); a decline stays quiet.
const answerSecret = (ask: AcpmuxSecretAsk) => (value?: string) => {
  const sent = callNative("chat.secret", { secretId: ask.secretId, ...(value ? { value } : {}) });
  return value ? sent : sent.catch(() => undefined);
};

/// A peer's chat, reached over this Mac's own acpmux (server/peer_forward.rs), as ComposerPickers'
/// `onThisMac` reads it: its summary or its listed row names the peer. The peer takes only a signed
/// one-time Allow and a Deny from this Mac (mac_approvers.rs).
function chatOnPeer(snapshot: AcpmuxSnapshot): boolean {
  const summary = snapshot.summary;
  const listedPeer = summary?.sessionId ? findSession(snapshot.sessions, summary.sessionId)?.peer : undefined;
  return snapshot.origin === "peer" || !!summary?.peer || !!listedPeer;
}

/// The native label of the mode the chat runs now when it is its family's highest (Claude Code's
/// Bypass permissions, Codex's Full access), else nothing.
function fullAccessModeName(summary: AcpmuxSnapshot["summary"]): string | undefined {
  const current = summary?.modes?.currentModeId;
  if (!current || highestMode(summary?.family, summary?.harness)?.id !== current) return undefined;
  return harnessModeName(summary?.family, summary?.harness, current);
}

/// The host closes a New Tab page (`AgentPaneView.discardUnsentChat`).
export const NEW_TAB_CLOSE_EVENT = "acpmux-newtab-close";

/** Static preview boot state, not a production host handshake. The gallery still delivers the
 * snapshot through receive() after ready to initialize trust, harness and persistence state. */
/// A tagged ask's answer from the hat, as its transcript card sends one (NextStepCard.tsx): it claims
/// the answer and shares the card's state under the card's key, so the card and the hat never send it
/// twice, and one already on its way from the card is not sent again.
/// It goes as the card's does: a reply quoting the ask under `asker`'s name (nextStepAsk.ts `answerPrompt`).
function answerNextStep(question: HatQuestion, label: string, asker: string | undefined): Promise<unknown> {
  const key = question.answerKey;
  const text = answerPrompt(question.prompt, label, asker);
  if (!key) return answerThrough(callNative)(text);
  if (givenAnswer(answerState(key)) !== undefined) return Promise.resolve();
  claimAnswer(key, label);
  setAnswerState(key, { sending: label });
  return answerThrough(callNative)(text).then(
    () => setAnswerState(key, { sent: label }),
    (error: unknown) => {
      setAnswerState(key, { failed: true });
      throw error;
    },
  );
}

/// What the hat's buttons do (question/HatQuestions.tsx). The chat's own question is answered as its
/// card answers it; a tagged ask as the person's reply, with its card's reach; a started chat's
/// opens that chat, the only place it can be answered.
const hatActions = (
  focusComposer: () => void,
  reaches: (owner: string) => boolean,
  asker: () => string | undefined,
  dismiss: (question: HatQuestion) => void,
): HatQuestionActions => ({
  dismiss,
  answer: (question, answer) => {
    // A tagged ask's answer goes as its card's does (`restartReaches`): only to the chat it was read
    // for, never the next during a switch's hold, and as its card sends it (`answerThrough`): a send
    // refused rejects, so the band takes input again; one acpmux already took counts as sent.
    if (question.source === "nextStep")
      return question.sessionId && reaches(question.sessionId)
        ? answerNextStep(question, answer.label, asker())
        : Promise.reject(new Error("unreachable"));
    const asked = question.question;
    const item = asked?.items[0];
    if (!asked || !item) return Promise.reject(new Error("unanswerable"));
    const sent = questionReply(asked, { selections: { [item.id]: selection([answer.id]) } });
    // A started chat's question is answered as its own card would answer it, sent by the host for
    // the chat this pane does not show; a host that can't opens that chat (`replyElsewhere`).
    if (question.source === "child") return replyElsewhere(callNative, sent, () => openAsker(question));
    return callNative("chat.permission", replyParams(sent));
  },
  // A started chat's question in the person's own words: its Other, sent the same way.
  reply: (question, text) => {
    const asked = question.question;
    const item = asked?.items[0];
    if (question.source !== "child" || !asked || !item) return Promise.reject(new Error("unanswerable"));
    return replyElsewhere(callNative, questionReply(asked, { selections: { [item.id]: selection([], text) } }), () =>
      openAsker(question),
    );
  },
  // A tagged ask's typed answer is a reply to it too: the draft takes the ask's quote first, as
  // Quote in Reply puts one there, so what the person types under it goes quoting the ask.
  type: (question) => {
    if (question.source === "nextStep") quoteInReply(askQuote(question.prompt, asker()));
    focusComposer();
  },
  showCard: () => {
    const card = document.querySelector<HTMLElement>(".acpmux-asks-stack .acpmux-question");
    card?.scrollIntoView({ block: "nearest" });
    card?.querySelector<HTMLElement>("input, button")?.focus({ preventScroll: true });
  },
  open: openAsker,
});
/// Opens a started chat's question in its chat, beside this one (`chat.asks.open`).
function openAsker(question: HatQuestion) {
  if (question.sessionId) void callNative("chat.asks.open", { sessionId: question.sessionId }).catch(() => undefined);
}

export type InitialChat = {
  snapshot: AcpmuxSnapshot;
  machineName?: string;
  workflowLabs?: boolean;
  liveTree?: boolean;
};

/// The newest turn end of a settled view's fork points, if it named any.
function newestSettledForkSeq(settled: AcpmuxSnapshot["settled"]): number | undefined {
  if (!settled || settled.forkSeqs.length === 0) return undefined;
  return Math.max(...settled.forkSeqs);
}

export function AcpmuxApp({ initialChat }: { initialChat?: InitialChat } = {}) {
  const [queryClient] = useState(createPaneQueryClient);
  return (
    <QueryClientProvider client={queryClient}>
      <AcpmuxPane initialChat={initialChat} />
    </QueryClientProvider>
  );
}

/// No projects known (a stable value, so memos keyed on it hold).
const NO_PROJECTS: Project[] = [];

/// Experiment switch for the spare's parked chat view (App `parkedVisible`), set by the bench before load.
const spareParkVisible = () =>
  typeof window !== "undefined" && (window as { __cmuxSparePark?: unknown }).__cmuxSparePark === "visible";
const PARKED_STYLE = {
  visibility: "hidden",
  position: "absolute",
  inset: 0,
  pointerEvents: "none",
} as const satisfies React.CSSProperties;

function AcpmuxPane({ initialChat }: { initialChat?: InitialChat }) {
  // Debug measurement (acpmuxPerf): the pane's own render, before its children.
  const paneRenderStart = acpmuxPerf.enabled ? performance.now() : 0;
  acpmuxPerf.render("pane");
  const t = useT();
  const { scrollToBottomOnSend, newChatsIn, emptyChatComposerPosition } = useComposerSettings();
  const scrollToBottomOnSendRef = useRef(scrollToBottomOnSend);
  scrollToBottomOnSendRef.current = scrollToBottomOnSend;
  /// A new chat's Run as (hq#3367): Persistent is the chat as before; Sandboxed runs the
  /// first message once on a throwaway Cloud VM and shows its receipt instead. The host holds this
  /// tab's one Sandboxed send and the page renders what it says (sandboxRun.ts SandboxTab). A refused
  /// send's prompt goes back to the composer, or waits for it (`heldBack`).
  /// A Sandboxed refusal moved a draft into the chat composer: the chat view stays (with that
  /// composer, not the New Tab page that would remount without it) until a chat starts here or the
  /// host hands the page another new chat.
  const [sandboxDraftMoved, setSandboxDraftMoved] = useState(false);
  /// The Share dialog, opened by the chat menu's Share… (share/ShareControl.tsx).
  const [shareOpen, setShareOpen] = useState(false);
  const [sandbox] = useState(
    () =>
      new SandboxTab(callNative, (text) => {
        setSandboxDraftMoved(true);
        if (composerHandle.current) composerHandle.current.restore(text, []);
        else heldBack.current = [...(heldBack.current ?? []), { text, attachments: [] }];
      }),
  );
  useSyncExternalStore(sandbox.subscribe, sandbox.snapshot);
  /// Claude workflows (the transcript card, Session Info's workflows, the side tab) are on by
  /// default, not behind Labs: Leo asked for them (2026-10-24, "leo dynamic workflows ... idk how we
  /// wanna display but here"). A host `workflowLabs` push of false still turns them off.
  const [workflowLabsEnabled, setWorkflowLabsEnabled] = useState(initialChat?.workflowLabs !== false);
  /// The first live-tree slice is opt-in from Settings > Advanced > Labs; the default pane stays unchanged.
  const [liveTreeEnabled, setLiveTreeEnabled] = useState(initialChat?.liveTree === true);
  /// What a chat opened from another tab inherited (#16620); the composer starts with it.
  const [draft, setDraft] = useState<string | undefined>();
  /// Where this New Tab page's new chat starts, as the app knew it when the page loaded
  /// (AgentPaneNewTabStart): the first frame draws its project or no project, with no acpmux round trip.
  const [injectedStart] = useState(() => startFromContext(injectedNewTabContext()?.start));
  const [newSession, setNewSession] = useState(injectedStart?.newSession === true);
  /// The chat whose recorded history plays back read-only in place of it (chat menu Replay, cx-osmw).
  const [replaying, setReplaying] = useState<string | undefined>();
  // Steer queue (steerQueue/, an experiment): open or not, the clock its ages read, and the
  // person's record of where they stepped in.
  const [steering, setSteering] = useState(false);
  const [steerNow, setSteerNow] = useState(0);
  const [steerLog, setSteerLog] = useState<SteerAct[]>([]);
  /// The focused pane's rail visibility. The experiment still chooses compact/full when visible;
  /// this local switch is only the command-palette toggle and does not write shared experiment state.
  const [minimapVisible, setMinimapVisible] = useState(true);
  // Why the last `/btw` did not start its side session, for the chat it was asked in; "" when
  // acpmux gave no reason.
  const [btwFailure, setBtwFailure] = useState<{ sessionId: string; reason: string }>();
  const [statusCardOpen, setStatusCardOpen] = useState(false);
  // The host answered the handshake: the page shows what it is (a new chat's hero, a session).
  const [handshaken, setHandshaken] = useState(false);
  const handshakenRef = useRef(false);
  const reconnectingRef = useRef(false);
  /// The handshake named a chat acpmux still has to attach: the page draws it once the client's
  /// first frame (its rows, title and modes) is in, or the open's hold has passed.
  const [awaitsChat, setAwaitsChat] = useState(false);
  /// New Tab submits made before acpmux answered, run in order once it has (never dropped).
  const pendingSubmits = useRef<Array<() => void>>([]);
  const whenHandshaken = (run: () => void) => {
    if (handshakenRef.current) run();
    else pendingSubmits.current.push(run);
  };
  /// The New Tab screen's actions with its submits (a prompt, a recent session) held until the
  /// handshake: the field types from its first render, a chat needs acpmux.
  const withSubmitAfterHandshake = (actions: NewTabScreenActions): NewTabScreenActions => ({
    ...actions,
    onAsk: (...args) => {
      setNewTabStartPage(newTabGeneration);
      newTabRetainsDraft.current = true;
      return new Promise<void>((resolve, reject) => {
        whenHandshaken(() => {
          try {
            Promise.resolve(actions.onAsk(...args)).then(() => resolve(), reject);
          } catch (error) {
            reject(error);
          }
        });
      });
    },
    onOpenSession: (...args) => whenHandshaken(() => actions.onOpenSession(...args)),
  });
  // An unsent chat can choose its folder even before an agent is available.
  const [projectDraft, setProjectDraft] = useState<string | undefined>(injectedStart?.projectDraft);
  /// The folder the app's start named (`NewTabHost.start`), until the handshake's answer: a
  /// handshake that names none clears it only while the person has not picked another.
  const startedFromHint = useRef(injectedStart?.projectDraft);
  /// The folders an unsent chat sees beside its own (the folder menu's Add folder…, extraFolders.ts),
  /// on the machine they were added for; its `session/new` carries them (direct.ts `setNewChatFolders`).
  const [extraFolderDraft, setExtraFolderDraft] = useState<ExtraFolderDraft>();
  /// The host offers Choose Folder… (a new chat in a workspace without a folder).
  const [chooseFolder, setChooseFolder] = useState(injectedStart?.chooseFolder === true);
  /// A chat that opened without its folder (cx-nn3e.1): acpmux's reason, until a pick works.
  const [folderNeeded, setFolderNeeded] = useState<{ reason: string; error?: string }>();
  const [pastTurns, setPastTurns] = useState<PastTurn[]>();
  /// The past turns are an adopted chat's own, replayed once its folder's trust question is
  /// answered: they show only while that question is up, so a trusted folder never flashes them.
  const [pastWaitsForTrust, setPastWaitsForTrust] = useState(false);
  /// The host's localized refusal of the last Choose Folder… click.
  const [folderError, setFolderError] = useState<string | undefined>();
  /// A folder the user picked that waits for their answer (startFolder.tsx): the question shows
  /// above the composer, and `use` runs with the folder once they answer Use Home Folder.
  /// `sessionId` is the chat the pick was for: a chat that started or changed meanwhile drops it.
  const [folderAsk, setFolderAsk] = useState<{
    ask: FolderAsk;
    use(cwd: string): void;
    cancel?(): void;
    sessionId?: string;
    /// The client's visit it was asked in (`trustVisit`): another fresh chat has the same no-id.
    visit?: string;
    error?: string;
  }>();
  const folderConfirmGeneration = useRef(0);
  const folderConfirmInFlight = useRef(false);
  /// The chat whose folder answer is saving (Use was clicked), or false: only that chat waits on it.
  /// `visit` is the client's selection identity then (`trustVisit`): a fresh chat has no session id,
  /// so another fresh chat shown later is told apart by it.
  const [folderConfirming, setFolderConfirming] = useState<false | { sessionId?: string; visit?: string }>(false);
  const [importError, setImportError] = useState<string | undefined>();
  // Edit CLAUDE.md the app refused (a link out of the folder, not a file): the notice above the
  // composer says why, with Retry; opening it clears the notice.
  const [instructionsFailure, setInstructionsFailure] = useState<
    { cwd: string; failure: InstructionsFailure } | undefined
  >();
  // The shown chat's folder: an answer for a folder the pane has left changes nothing.
  const instructionsFolder = useRef<string | undefined>(undefined);
  const openInstructions = useCallback((cwd: string, name: string) => {
    void callNative("project.instructions", { cwd, name }).then(
      () => {
        if (instructionsFolder.current === cwd) setInstructionsFailure(undefined);
      },
      (error: unknown) => {
        if (instructionsFolder.current !== cwd) return;
        setInstructionsFailure({
          cwd,
          failure: { file: name, code: error instanceof NativeError ? error.code : undefined },
        });
      },
    );
  }, []);
  /// Shell mode's commands (shell/shellRuns.ts), across the chats this page showed.
  const [shellRuns] = useState(() => new ShellRuns(callNative));
  const allShellRuns = useSyncExternalStore(shellRuns.subscribe, shellRuns.snapshot, shellRuns.snapshot);
  /// This Mac's name, from the handshake.
  const [machineName, setMachineName] = useState<string | undefined>(initialChat?.machineName);
  // This Mac's own name (`localMachineName`): `machineName` names a seeded chat's machine instead.
  const [localMachineName, setLocalMachineName] = useState<string | undefined>();
  const [cloudMachineID, setCloudMachineID] = useState<string | undefined>();
  // The host bridge reads the current machine without re-registering every native handler.
  const cloudMachineIDRef = useRef(cloudMachineID);
  cloudMachineIDRef.current = cloudMachineID;
  const [cloudRepositoryAvailable, setCloudRepositoryAvailable] = useState(false);
  const [cloudChatIdentity, setCloudChatIdentity] = useState<CloudChatIdentity>();
  // A fresh composer can select a paused Cloud machine before it has a session. Keep only that
  // explicit picker choice; never guess a machine from the account inventory. Null records a
  // non-Cloud destination and suppresses the previous identity while its handshake catches up.
  const cloudDraftMachineID = useRef<string | null | undefined>(undefined);
  // Whether `cloudChatIdentity` still names the chat shown (cloudIdentityKept): set by the
  // handshake that gave it, cleared when the pane moves to another chat or New Tab page.
  const cloudIdentityBound = useRef(false);
  // Back to before this turn (TurnActions `rewind`): per chat, the checkpoint marks of its turns
  // (`user-<n>`), first as the handshake's `cloudTurnRewind` names them for its chat. Undefined where
  // the host serves no rewind, so no prompt draws the button. Kept per chat:
  // `chat.select` switches chats with no new handshake (cloudTurnCheckpoints.ts `ChatMarks`).
  const [cloudTurnRewind, publishCloudTurnRewind] = useState<ChatMarks>();
  const cloudTurnRewindRef = useRef<ChatMarks | undefined>(undefined);
  const setCloudTurnRewind = (
    update: ChatMarks | undefined | ((marks: ChatMarks | undefined) => ChatMarks | undefined),
  ) => {
    const next = typeof update === "function" ? update(cloudTurnRewindRef.current) : update;
    cloudTurnRewindRef.current = next;
    if (document.visibilityState !== "hidden") publishCloudTurnRewind(next);
  };
  // A handshake that named no chat: its list joins the first chat a snapshot shows.
  const cloudTurnRewindUnbound = useRef(false);
  // With `cloudTurnRewind` present, each completed turn asks the app for the checkpoint before the
  // next one (`chat.turnCheckpoint {afterSeq}`, conversation/cloudTurnCheckpoints.ts), fed by the
  // snapshot handlers below; its answer's row joins that chat's ready set.
  const cloudCheckpoints = useRef<CloudTurnCheckpoints | undefined>(undefined);
  cloudCheckpoints.current ??= new CloudTurnCheckpoints(
    // Straight to native, as the rewind: callNative would select a page action of the same name.
    (afterSeq) => postNative("chat.turnCheckpoint", { afterSeq }),
    (answer, session) => setCloudTurnRewind((marks) => chatWithCheckpoint(marks, answer, session)),
  );
  const observeCloudTurn = (next: AcpmuxSnapshot) => {
    if (document.visibilityState !== "hidden") publishCloudTurnRewind(cloudTurnRewindRef.current);
    cloudCheckpoints.current?.observe(next);
    const session = next.sessionId;
    if (!cloudTurnRewindUnbound.current || !session) return;
    cloudTurnRewindUnbound.current = false;
    setCloudTurnRewind((marks) => bindMarks(marks, session));
  };
  // A team Cloud machine its start passed no personal login to (handshake `cloudTeamMachine`): a
  // sign-in failure says so (failureCopy.ts isTeamMachineSignIn).
  const [cloudTeamMachine, setCloudTeamMachine] = useState(false);
  const [scrollAnchor, setScrollAnchor] = useState<(ScrollAnchor & { sessionId: string }) | undefined>();
  const [githubRepository, setGithubRepository] = useState<string | undefined>();
  /// What the direct client (or the host) last reported; `snapshot` draws a pending harness or
  /// model switch over it (harnessSwitch.ts).
  const [clientSnapshot, setSnapshot] = useState<AcpmuxSnapshot>(() => initialChat?.snapshot ?? cachedSnapshot());
  const [harnessSwitch] = useState(() => new HarnessSwitch());
  const switchView = useSyncExternalStore(harnessSwitch.subscribe, harnessSwitch.view, harnessSwitch.view);
  const switchViewRef = useRef(switchView);
  switchViewRef.current = switchView;
  // Typing in a new chat (this pane's fresh composer or its New Tab page) warms the agent its Enter
  // starts (newChatPrewarm.ts, acpmux hub/pool). Silent: a folder without a Trust answer asks at Enter.
  const [newChatPrewarm] = useState(
    () =>
      new NewChatPrewarm(
        {
          supported: () => directClient.current?.prewarmSupported === true,
          prewarm: (target) => directClient.current?.typingPrewarm(target.harness, target.cwd),
          release: (target) => directClient.current?.releasePrewarm(target.harness, target.cwd),
        },
        browserSwitchClock,
      ),
  );
  // A Cloud chat's first keystroke is a best-effort wake hint for its machine. The native route
  // may be unavailable in an older host; Cloud typing and send must continue either way.
  const [cloudTypingPrewarm] = useState(
    () =>
      new CloudTypingPrewarm({
        prewarm: (machineID) =>
          callNative<unknown>("cloudMachine.prewarm", { id: machineID }).then(
            () => true,
            () => false,
          ),
      }),
  );
  const [cloudReservation] = useState(() => new CloudComposeReservation(callNative, browserSwitchClock));
  /// Whether this compose reserves a machine ahead, and then the empty local chat its reserve names as the one
  /// its Send would replace (`emptyLocalChat`); `replaces` undefined: a compose with no chat.
  const cloudComposeEligible = useRef<false | { replaces: string | undefined }>(false);
  // The page going away (its tab closed) with an unsent prompt gives the warm agent back now.
  useEffect(() => {
    const gone = () => {
      newChatPrewarm.abandon();
      cloudReservation.abandon();
    };
    window.addEventListener("pagehide", gone);
    return () => {
      window.removeEventListener("pagehide", gone);
      gone();
    };
  }, [newChatPrewarm, cloudReservation]);
  const queryClient = useQueryClient();
  // Each Cmd-T adoption of this page (kept mounted or not, newtab/adoption.ts): the folder's trust and
  // harnesses are read again with the tab's roots (a parked spare's reads had none, SHORTCUT FRAMES F2).
  const [newTabAdoptions, setNewTabAdoptions] = useState(0);
  // The pane keeps the last client's catalog until the next client's arrives;
  // ids only grow, so a new client never reads an older client's cache entry.
  const catalogClientId = useRef(0);

  const directClient = useRef<AcpmuxDirectClient | undefined>(undefined);
  /// `_acpmux/perf` through the client connected now (the Inspector's Perf tab, perfReporter.ts).
  const sendPerf = useCallback<PerfSend>(
    (params) =>
      directClient.current ? directClient.current.perf(params) : Promise.reject(new Error(translate("error.notOpen"))),
    [],
  );
  /// The pane's toasts (paneToasts.ts): feedback on a click goes there, never into the transcript.
  const [paneToasts] = useState(createPaneToasts);
  /// Where the toasts' top anchors are drawn (ToastLayer.tsx).
  const [toastTop, setToastTop] = useState<HTMLDivElement | null>(null);
  const notices = useMemo(
    () => paneNotices({ transcript: () => directClient.current, toasts: paneToasts, native: postNativePaneToast }),
    [paneToasts],
  );
  /// The pane's connected clients, one after another: a prompt a connection lost waits on the next
  /// one for the host's journal to send it again there (lostPrompt.ts).
  const [connectedClients] = useState(() => clientWaiter<AcpmuxDirectClient>());
  const [catalogSource, setCatalogSource] = useState<{ id: number; client: HarnessCatalogSource }>();

  /// A chat acpmux would not start because its folder harness needs the user's Enable or the
  /// folder's Trust answer first (`harness.needs_enable` / `harness.needs_trust`).
  const [blockedHarness, setBlockedHarness] = useState<HarnessBlock | undefined>();
  // The chat's folder on this Mac, whose own harness profiles the catalog then lists too; while a
  // folder harness waits for Enable or Trust (a new chat without a session), that harness's folder.
  // A GitHub repository picked for a Cloud chat (githubRepos.ts) is no folder of this Mac's.
  const catalogFolder =
    clientSnapshot.summary?.hostKind !== "cloud" && !clientSnapshot.summary?.host
      ? (clientSnapshot.summary?.cwd ?? projectDraft ?? blockedHarness?.folder) || undefined
      : undefined;
  const catalogCwd = githubFolderRepo(catalogFolder) ? undefined : catalogFolder;
  const catalog = useHarnessCatalog(catalogSource, clientSnapshot.catalog, undefined, catalogCwd);
  // A Cmd-T adoption reads the folder's harnesses again (the parked spare's read had no tab's roots); the
  // catalog keeps drawing until the new answer lands.
  const adoptedCatalog = useRef(newTabAdoptions);
  useEffect(() => {
    if (adoptedCatalog.current === newTabAdoptions || !catalogSource) return;
    adoptedCatalog.current = newTabAdoptions;
    void queryClient.invalidateQueries({ queryKey: harnessCatalogKey(catalogSource.id, catalogCwd), exact: true });
  }, [newTabAdoptions, catalogSource, catalogCwd, queryClient]);
  // For the host actions, which read it when they run (`chat.new`'s remembered model).
  const catalogRef = useRef(catalog);
  catalogRef.current = catalog;
  /// Prompts sent while a new chat starts, until acpmux takes each, in order (startingSends.ts): the
  /// first is the chat's first row from the send, those after it queued rows. One refused comes back
  /// to the composer with those behind it.
  const [startingRows, setStartingRows] = useState<readonly StartingSend[]>([]);
  // Only the chat they were sent in draws them (startingSends.ts `startingIn`). The client's visit
  // moves with its snapshot's chat, so the snapshot names when to read it again.
  const shownStarting = useMemo(
    () =>
      startingIn(
        startingRows,
        { chat: clientSnapshot.sessionId || undefined, visit: directClient.current?.selectionToken ?? 0 },
        directClient.current?.startedChat,
      ),
    [startingRows, clientSnapshot],
  );
  // The client's own snapshot never carries the catalog: every view of the pane (the Harnesses
  // page, the picker catalog, the composer) reads the fetched one from here.
  const snapshot = useMemo(
    () =>
      liveAsk(
        withStartingPrompt(
          applySwitch(
            catalog === clientSnapshot.catalog ? clientSnapshot : { ...clientSnapshot, catalog },
            switchView,
            catalog,
          ),
          shownStarting,
        ),
      ),
    [clientSnapshot, switchView, catalog, shownStarting],
  );
  // The dialog belongs to the chat it opened on: switching chats closes it.
  const [shareChat, setShareChat] = useState(snapshot.sessionId);
  if (shareChat !== snapshot.sessionId) {
    setShareChat(snapshot.sessionId);
    setShareOpen(false);
  }
  // Updated by the client before React renders, so a late Trust save cannot replay into a new
  // route during that interval. The catalog generation changes only when the client changes.
  const trustRouteSnapshot = useRef(snapshot);
  // The snapshot's owner is captured when the client publishes that snapshot. During a selection
  // hold the direct client may already point at B while the pane still paints A; never label that
  // rendered A with B's generation or let its Trust action target B.
  const trustRenderedOwner = useRef<
    { client?: AcpmuxDirectClient; generation?: number; sessionId?: string } | undefined
  >(undefined);
  const trustAuthority = useCallback(() => {
    const current = trustRouteSnapshot.current;
    return JSON.stringify([
      catalogClientId.current,
      current.origin,
      current.answersTrust,
      directClient.current?.trustPeer ?? current.summary?.peer,
      current.summary?.hostKind,
      current.summary?.host,
    ]);
  }, []);
  const trustVisit = useCallback(() => {
    const client = directClient.current;
    const rendered = trustRenderedOwner.current;
    // A held snapshot is actionable only while its owner is still the client's live selection.
    // Return a fresh sentinel for a stale render so useFolderTrustAsk's sameVisit fence rejects
    // Trust/save/refusal callbacks even when React has not painted the replacement snapshot yet.
    // Native/gallery preview frames intentionally have no direct client; retain the unbound
    // visit semantics there so their host-backed Trust card remains interactive.
    if (!client) return undefined;
    if (
      !rendered ||
      rendered.client !== client ||
      rendered.generation !== client.trustGeneration ||
      rendered.sessionId !== client.selectedSession
    )
      return Symbol("stale-trust-visit");
    return JSON.stringify([rendered.generation, rendered.sessionId]);
  }, []);
  // The chat's Cloud machine while it does not answer: paused offers Resume, starting spins.
  // An ssh peer is never an account's Cloud machine, whatever its name.
  const offlinePeer = snapshot.peerCopy?.offline ? snapshot.peerCopy.peer : undefined;
  const peerMachine = usePeerCloudMachine(
    offlinePeer && snapshot.peerKinds?.[offlinePeer] !== "ssh" ? offlinePeer : undefined,
  );
  useEffect(() => setMinimapVisible(true), [snapshot.sessionId]);
  // The queue as the pane draws it (queuedMessages.ts `useShownQueue`): an entry that comes and goes
  // within TRANSIENT_SHOW_MS never paints, in the composer's queue or as the transcript's waiting
  // card (Leo, 2026-11-17: "i also dont like seeing the flicker flash of the Queued blah blah blah
  // something"). Both read this one list, so they show in the same frame.
  const shownQueue = useShownQueue(snapshot.queue, snapshot.sessionId ?? snapshot.summary?.sessionId);
  // The person's own queued prompts: another agent's message never draws in the composer's queue.
  const queueIds = useMemo(() => ownQueue(shownQueue).map((entry) => entry.id), [shownQueue]);
  // Another chat ends the replay: coming back to this one opens it live.
  if (replaying && snapshot.sessionId !== replaying) setReplaying(undefined);
  // A /btw failure belongs to its chat: another chat drops it.
  if (btwFailure && snapshot.sessionId !== btwFailure.sessionId) setBtwFailure(undefined);
  // A preview follows its source chat. A deliberate Pin keeps an immutable snapshot visible when
  // browsing other chats, while the original chat remains its only source of new versions.
  // Each Open is a fresh panel (`opened`), which starts on its preview.
  const [artifact, setArtifact] = useState<OpenedArtifact>();
  if (artifact && !visibleArtifact(artifact, snapshot.sessionId)) setArtifact(undefined);
  // The Background tasks panel (backgroundTasks/BackgroundTasksPanel.tsx), opened from the chat's ⋯
  // menu: the chat's right column, docked under the side panel when that is open. It is the open
  // chat's, as the side panel is; another chat closes it. `dismissed` holds the ended groups Clear
  // finished cleared. Closed, it reads nothing: its groups are derived only while it is open.
  const [backgroundPanel, setBackgroundPanel] = useState<BackgroundPanel>();
  /// This page is the chat's Background tasks tab in the right column (a `subagent:` reveal of the
  /// reserved pane id, backgroundTasks/backgroundPane.ts): it shows the panel alone, filling the tab.
  const [ownBackgroundPane, setOwnBackgroundPane] = useState(false);
  // One idempotent step, not two guarded sets that undo each other (a during-render pair made the
  // pane fail to draw once Background tasks opened in its split; Leo, 2026-11-22).
  const reconciledBackgroundPanel = backgroundPanelFor(backgroundPanel, snapshot.sessionId, ownBackgroundPane);
  if (reconciledBackgroundPanel !== backgroundPanel) setBackgroundPanel(reconciledBackgroundPanel);
  const backgroundOpen = backgroundPanel !== undefined;
  const backgroundCache = useRef<TaskCache>(new WeakMap());
  const artifactSession = snapshot.sessionId;
  // Its versions (cx-ncc.64): the chat's finished replies' documents of its kind and title.
  const artifactRows = artifact ? snapshot.rows : undefined;
  const artifactRowsRef = useRef(snapshot.rows);
  artifactRowsRef.current = snapshot.rows;
  const artifactLive = useRef<ReturnType<typeof artifactLiveSource>>(undefined);
  if (!artifact) {
    artifactLive.current?.dispose();
    artifactLive.current = undefined;
  }
  useEffect(() => () => artifactLive.current?.dispose(), []);
  // A pinned preview from another chat does not follow this chat's rows.
  const liveDocument = useMemo(
    () =>
      (artifact?.identity || artifact?.path) && artifactRows && artifact.sessionId === snapshot.sessionId
        ? artifactLive.current?.read(artifactRows)
        : undefined,
    [artifact, artifactRows, snapshot.sessionId],
  );
  // An open artifact follows its fence in the pane's rows: chunks draw through the pane meanwhile.
  useLayoutEffect(() => {
    setStreamingRowBlocked(artifact !== undefined, "artifact");
    return () => setStreamingRowBlocked(false, "artifact");
  }, [artifact]);
  const liveArtifact = liveDocument?.artifact ?? artifact;
  // Render cards by id (cx-ncc.94): a render that names an earlier one's id shows in that card.
  const pages = useMemo(() => renderPages(snapshot.rows), [snapshot.rows]);
  const artifactVersionList = useMemo(() => {
    if (!artifact) return undefined;
    // A pinned preview from another chat must not use this chat's rows: two unrelated documents
    // can have the same <title>. Preserve the source's versions captured at Pin instead.
    if (artifact.sessionId !== snapshot.sessionId) return artifactVersionsForSession(artifact, snapshot.sessionId);
    const current = liveArtifact ?? artifact;
    const scanned = artifactRows
      ? current.path
        ? uniqueArtifacts(writtenArtifacts(artifactRows).filter((item) => item.path === current.path))
        : (renderVersions(pages, current) ?? artifactVersions(finishedReplyDocuments(artifactRows), current))
      : undefined;
    // The live source holds the opened fence's streamed slot; versions finished after opening (a
    // later reply's rewrite, a newly paged reply) still join it.
    const versions = liveDocument ? mergeArtifactVersions(liveDocument.versions, scanned) : scanned;
    return artifactVersionsForSession(artifact, snapshot.sessionId, versions);
  }, [artifact, liveArtifact, artifactRows, pages, snapshot.sessionId, liveDocument]);
  const openArtifact = useCallback(
    (next: Artifact) => {
      artifactLive.current?.dispose();
      artifactLive.current = artifactLiveSource(next, artifactRowsRef.current);
      setArtifact((current) => ({
        ...next,
        sessionId: artifactSession,
        sourceTitle: snapshot.summary?.title || snapshot.summary?.name,
        opened: (current?.opened ?? 0) + 1,
      }));
    },
    [artifactSession, snapshot.summary?.title, snapshot.summary?.name],
  );
  // Repository context follows the selected session, connection origin and cwd. A reconnect
  // handshake for an existing session deliberately omits cwd, so key this lookup from the live
  // snapshot instead of clearing a valid repository while the daemon is being replaced.
  const githubRepositoryContext =
    snapshot.origin === "local" && snapshot.summary?.cwd
      ? `${snapshot.sessionId ?? snapshot.summary.sessionId}:local:${snapshot.summary.cwd}`
      : undefined;
  useEffect(() => {
    const cwd = snapshot.summary?.cwd;
    if (!githubRepositoryContext || !cwd) {
      setGithubRepository(undefined);
      return;
    }
    // The folder's repository from its last read draws now (no links to the chat before's repo, no
    // links popping in late); unknown, the transcript links nothing until the read answers.
    setGithubRepository(knownGithubRepositories.get(cwd));
    let current = true;
    void callNative<{ repository?: unknown }>("git.githubRepository", { cwd })
      .then((value) => {
        const repository = typeof value?.repository === "string" && value.repository ? value.repository : undefined;
        knownGithubRepositories.set(cwd, repository);
        if (current) setGithubRepository(repository);
      })
      .catch(() => {});
    return () => {
      current = false;
    };
  }, [githubRepositoryContext, snapshot.summary?.cwd]);
  const handoffLabels = useMemo(() => handoffStrings(t), [t]);
  const checkpointLabels = useMemo(() => checkpointStrings(t), [t]);
  const [checkpointVariant, setCheckpointVariant] = useState<"compact" | "expanded">("compact");
  // Footer actions and checkpoints show only while acpmux is reachable. The client reports failures
  // in the transcript; a bridge that cannot route an action has nothing to add.
  const connected = linkUp(snapshot.connection);
  const checkpoints = useCheckpoints({
    request: callNative,
    target: snapshot.summary?.cwd
      ? {
          cwd: snapshot.summary.cwd,
          sessionId: snapshot.sessionId,
          hostKind: snapshot.summary.hostKind,
        }
      : undefined,
    online: connected,
    strings: checkpointLabels,
    variant: checkpointVariant,
  });
  const showCheckpoint = useRef(checkpoints.show);
  showCheckpoint.current = checkpoints.show;
  useEffect(() => {
    void callNative("pane.checkpointAvailability", { available: checkpoints.supported }).catch(() => undefined);
  }, [checkpoints.supported, snapshot.sessionId]);
  const [continuing, setContinuing] = useState(false);
  const [reviewReload, setReviewReload] = useState(0);
  useEffect(() => setContinuing(false), [snapshot.sessionId]);
  // Each time the pane says a tab's chat isn't available, the app's log records the chat and why
  // (`chat.missing`, os_log category agentPane), so the views can be counted (Lawrence 2026-10-21).
  useEffect(() => {
    if (!snapshot.missingSession) return;
    void callNative("chat.missing", {
      session: snapshot.missingSession,
      reason: snapshot.missingReason ?? "unknown",
    }).catch(() => undefined);
  }, [snapshot.missingSession, snapshot.missingReason]);
  const stopContinuing = useCallback(() => setContinuing(false), []);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  /// The rows in the shown transcript's view (VirtualTranscript `inViewNow`), and the folds a turn's
  /// end holds open over them until `expanded` has them (conversation/turnEndHold.ts).
  const transcriptInView = useRef<(() => readonly string[] | null) | undefined>(undefined);
  const heldFolds = useRef<{ session?: string; keys: ReadonlySet<string> }>({ keys: new Set() });
  const foldsSeen = useRef<{ session?: string; folds?: Folds }>({});
  /// The commands the live line let go of while the reader was scrolled up, kept out of their runs
  /// until the view follows again (conversation/turnEndHold.ts `withoutHeldCalls`, cmux#33200), and
  /// the call the line named out of its run when the rows were last shaped.
  const heldCalls = useRef<{ session?: string; keys: ReadonlySet<string>; lined?: string }>({ keys: new Set() });
  /// The finished runs that came back between rows a reader scrolled up had in view, kept out of the
  /// rows until the view follows again (conversation/turnEndHold.ts `rowsToHold`).
  const heldRuns = useRef<{ session?: string; keys: ReadonlySet<string>; asked?: true }>({ keys: new Set() });
  /// The ended turn's "Worked for" over rows a reader scrolled up had in view: open until the view
  /// follows again, then closed (conversation/turnEndHold.ts `foldsToHold`; cmux#24569's turn_end rows).
  const heldWorked = useRef<{ session?: string; keys: ReadonlySet<string> }>({ keys: new Set() });
  /// Set when the rows next shaped close that Worked for, the view back at the latest row: the
  /// transcript folds it in the turn's end motion (VirtualTranscript `heldWorkedClosing`).
  const heldWorkedClosing = useRef(false);
  // Let go once the render that hands those rows over has committed: the transcript read it there.
  useLayoutEffect(() => {
    heldWorkedClosing.current = false;
  });
  /// Moves when the view follows again with commands or runs held out, so they go back in.
  const [callRelease, releaseCalls] = useReducer((count: number) => count + 1, 0);
  /// A held run the reader asks for (Find's match, a link to a call or to a message) goes back in,
  /// with every run held with it: a row that is not drawn cannot be shown.
  const showHeldRuns = useCallback((rowId: string) => {
    if (!heldRuns.current.keys.has(rowId)) return;
    heldRuns.current = { ...heldRuns.current, asked: true };
    releaseCalls();
  }, []);
  /// The "Worked for" folds the reader toggled in Thinking or Verbose, per view: those views open
  /// every finished turn's fold (conversation/viewFolds.ts), so a toggle there closes one.
  const [viewToggles, setViewToggles] = useState<ReadonlyMap<TranscriptView, ReadonlySet<string>>>(() => new Map());
  /// The subagent whose own view the transcript shows (its line in a group opens it), or none.
  const [subagentView, setSubagentView] = useState<string>();
  /// The subagent this pane was opened on (a `subagent:` reveal, subagents/subagentPanes.ts), shown
  /// once its chat is; such a pane shows the chat's other subagents in place, never in more panes.
  const [requestedSubagent, setRequestedSubagent] = useState<string>();
  const subagentPane = useRef(false);
  /// This pane was opened on a subagent (a `subagent:` reveal): while it shows a subagent, it shows
  /// the subagent's composer in place of the chat's (`readOnlySubagent`).
  const [ownSubagentPane, setOwnSubagentPane] = useState(false);
  /// Brings one message's row into the transcript, the way a running line's count does, and says
  /// which row it asked for; undefined while this chat has no row for that message. Set below,
  /// where the chat's rows are.
  const showMessage = useRef<(messageId: string) => string | undefined>(() => undefined);
  const showTimelineTurn = useRef<(turnId: string) => void>(() => undefined);
  /// ``showMessage`` for a message the chats page found by its words (a `said:` reveal).
  const showSaid = useRef<(said: SaidReveal) => string | undefined>(() => undefined);
  const reveal = (value: string) => {
    // The command palette's chats page opens a chat at the message it found by what was said:
    // the newest row of that kind holding the words, brought in as a `message=<id>` link's is.
    const said = revealedSaid(value);
    if (said !== undefined) {
      return void revealMessageWhenShown(value, () => showSaid.current(said), document, {
        chat: () => shownView.current,
      });
    }
    // A `message=<id>` link (schemas/deeplinks/agent-link.json): bring that message's row in
    // once the transcript has it, and leave the view alone when this session never saw it.
    const message = revealedMessage(value);
    if (message !== undefined) {
      // The view it belongs to goes along: row ids start over with each session and a subagent's
      // rows carry ids of the same shape, so a row still waiting to be drawn when the reader moves
      // to another chat or into a subagent is dropped, never scrolled in.
      return void revealMessageWhenShown(message, (id) => showMessage.current(id), document, {
        chat: () => shownView.current,
      });
    }
    const agent = revealedSubagent(value);
    if (agent === undefined) return void revealTurnWhenShown(value);
    if (isBackgroundPane(agent)) {
      setOwnBackgroundPane(true);
      return;
    }
    subagentPane.current = true;
    setOwnSubagentPane(true);
    setRequestedSubagent(agent);
  };
  const revealRef = useRef(reveal);
  revealRef.current = reveal;
  const forkable = canFork(snapshot);
  const turnForkable = canForkTurn(snapshot);
  // A turn end of the settled view acpmux opened the chat from stands in until the rows hold one
  // (cmuxterm-hq#9655): the fork is offered from the chat's first settled frame.
  const forkSeq = latestForkSeq(snapshot.rows) ?? newestSettledForkSeq(snapshot.settled);
  const forkAny = forksAnyTurn(snapshot);
  const tryAnotherApproachInFlight = useRef<Promise<void> | undefined>(undefined);
  // One machine rewind at a time: a second while one runs is refused, so its button says so.
  const rewindInFlight = useRef(false);
  // The prompts drawn with Back to before this turn, each with the checkpoint row it rewinds to
  // (cloudTurnCheckpoints.ts `readyPromptRows`): a sent prompt keeps its own row id, and the
  // checkpoint names the turn number after the one before it. Rebuilt only when they change.
  const rewindRowsKey = readyPromptKey(readyPromptRows(snapshot.rows, marksFor(cloudTurnRewind, snapshot.sessionId)));
  const rewindRows = useMemo(() => readyPromptMap(rewindRowsKey), [rewindRowsKey]);
  const rewindReady = useMemo<ReadonlySet<string>>(() => new Set(rewindRows.keys()), [rewindRows]);
  // Edit and resend (cx-ncc.60): rebuilt when the editable prompts change, not on every streamed row.
  // A running chat still permits editing an earlier completed prompt: editResend forks through that
  // prompt's preceding turn, leaving this branch running while the edited sibling starts its own turn.
  // Keep the same served/connected gate as ordinary forks, but do not use `forkable`, which excludes
  // a working chat (Leo, 2026-10-24).
  const editsServed = snapshot.canFork && connected;
  const lastEditTurns = useRef<EditableTurns | undefined>(undefined);
  const rowsForEdits = editsServed ? snapshot.rows : NO_ROWS;
  // acpmux's answer for the chat (a Claude Code profile under any family name edits every turn).
  const editFamily = forkAny;
  const stableEditSeqs = useMemo(
    () => (lastEditTurns.current = trackEditableTurns(rowsForEdits, editFamily, lastEditTurns.current)).seqs,
    [rowsForEdits, editFamily],
  );
  // Each prompt's own turn, for the Fork under its bubble; rebuilt only when the turns change.
  // Tracked across snapshots: a streamed row reads the rows after it, not the whole chat (cmux#48711).
  // A cache the memo below carries forward. A render React replays or drops only re-derives it
  // from the same rows, so it lives in a state-held box, not a ref written during render.
  const [promptTurnsCache] = useState<{ last?: PromptTurns }>(() => ({}));
  const rowsForPromptTurns = turnForkable ? snapshot.rows : NO_ROWS;
  const stablePromptSeqs = useMemo(
    () => (promptTurnsCache.last = trackPromptTurns(rowsForPromptTurns, promptTurnsCache.last)).seqs,
    [rowsForPromptTurns, promptTurnsCache],
  );
  // Retry with another model (cx-ncc.62): the models the composer's picker lists for the chat's
  // harness (user-hidden ones left out, aliases folded, the session's own choices added) that it can
  // run now, kept the same array while they stay the same.
  const pickerSession = useMemo(
    () => ({
      harness: snapshot.summary?.harness,
      model: snapshot.summary?.model,
      configOptions: snapshot.summary?.configOptions,
    }),
    [snapshot.summary?.harness, snapshot.summary?.model, snapshot.summary?.configOptions],
  );
  const pickerState = usePickerCatalog(snapshot.catalog, pickerSession, snapshot.sessions);
  const pickerCatalog = pickerState.catalog;
  // The chat's agent CLI health (cx-ny85), from this Mac's acpmux on the pane's own connection
  // (cx-jlzsf); a chat on another machine or in the cloud gets none (its CLI is not this Mac's).
  const [readHealth, setHarnessHealth] = useState<HarnessHealth>();
  const [signInNoticeVisible, setSignInNoticeVisible] = useState(false);
  /// An agent CLI update on offer (hq#2569 #12): the model chip's dot and picker row, not a banner.
  const [updateOffer, setUpdateOffer] = useState<UpdateOffer>();
  // A fresh chat has no summary yet, but its composer already names a harness. Read that
  // same harness's health so its existing Log In action is available before the first send.
  // Before acpmux lists its harnesses the chip draws the catalog's first one; its health is read too.
  const harnessesListed = useHarnessesListed();
  const healthHarness = composerHealthHarness(snapshot, pickerCatalog, harnessesListed);
  const healthLocal =
    !snapshot.summary?.peer &&
    snapshot.summary?.hostKind !== "cloud" &&
    (snapshot.sessionId !== undefined || !directClient.current?.newChatPeer());
  /// The composer's agent runs on this Mac (composerAgentLocal): not with Cloud picked for a new chat.
  /// Its health and sign-in are read only then; the folder's trust, rules and accounts stay `healthLocal`'s.
  /// An empty chat whose local session opened first still starts on Cloud when picked (`emptyLocalChat`).
  const agentLocal = composerAgentLocal(
    healthLocal,
    sandbox.mode,
    isNewChat(snapshot, newSession) ? undefined : snapshot.sessionId,
  );
  // A new chat that will start on another of the person's machines: whether the agent the composer
  // shows is set up there (machineHarnesses.ts; Austin, 2026-11-12: "ideally we should check if the
  // model that is selected is supported on that machine as well but this should just work").
  const machinePeer = snapshot.sessionId
    ? undefined
    : snapshot.summary?.peer || directClient.current?.newChatPeer() || undefined;
  const machineReady =
    machinePeer !== undefined &&
    environmentReady({
      id: machinePeer,
      label: machinePeer,
      kind: "ssh",
      ...(snapshot.peerConnected?.[machinePeer] !== undefined
        ? { connected: snapshot.peerConnected[machinePeer] }
        : {}),
      ...(snapshot.peerStates?.[machinePeer] !== undefined ? { state: snapshot.peerStates[machinePeer] } : {}),
    });
  const machineAgents = useMachineHarnesses(catalogSource, machinePeer, machineReady);
  const machineSelected = switchView.intent?.harness ?? healthHarness;
  const machineCheck = useMachineHarnessCheck({
    peer: machinePeer,
    selected: machineSelected,
    verdict: machineHarnessVerdict(machineSelected, machineAgents),
    switching: switchView.intent !== undefined,
    // The model picker's own pick of that agent (DefaultComposerChips `onHarness`).
    switchTo: (harness) => void callNative("chat.new", { harness }).catch(() => undefined),
  });
  /// `harness.health {id, refresh?, rescan?}` answered by this Mac's acpmux (the Harnesses page asks
  /// it by that name); `{}` for a chat on another machine, whose CLIs are not this Mac's, and while
  /// the pane has no acpmux connection. Stable per chat: the Harnesses page re-reads when it changes.
  const readHarnessHealth = useCallback(
    async (params: Record<string, unknown>): Promise<{ health?: HarnessHealth | null }> => {
      const client = directClient.current;
      // This Mac's CLIs, for the Harnesses page too; the composer's own read below also needs `agentLocal`.
      if (!client || !healthLocal) return {};
      const row = await client.harnessHealth(String(params.id ?? ""), {
        refresh: params.refresh === true,
        rescan: params.rescan === true,
      });
      return { health: (row as HarnessHealth | undefined) ?? null };
    },
    [healthLocal],
  );
  /// The Harnesses page's host calls, with `harness.health` answered by acpmux (above).
  const harnessesNative = useCallback(
    (method: string, params: Record<string, unknown> = {}) =>
      method === "harness.health" ? readHarnessHealth(params) : callNative(method, params),
    [readHarnessHealth],
  );
  // After its Log In ran in a terminal tab, coming back to the chat checks again; an update the
  // host ran (`harness.update`) checks again once the chat restarts on it.
  const healthStale = useRef(false);
  const [healthRecheck, setHealthRecheck] = useState(0);
  const recheckHealth = useCallback(() => setHealthRecheck((count) => count + 1), []);
  const healthRechecked = useRef(0);
  useEffect(() => {
    const recheck = () => {
      if (!healthStale.current || document.visibilityState === "hidden") return;
      healthStale.current = false;
      setHealthRecheck((count) => count + 1);
    };
    window.addEventListener("focus", recheck);
    document.addEventListener("visibilitychange", recheck);
    return () => {
      window.removeEventListener("focus", recheck);
      document.removeEventListener("visibilitychange", recheck);
    };
  }, []);
  useEffect(() => {
    if (!healthHarness || !agentLocal) {
      setHarnessHealth(undefined);
      return;
    }
    // Reconnecting keeps the last answer on screen; the read follows the connect.
    if (!connected) return;
    let live = true;
    // Only the fetch a recheck started asks acpmux to check again.
    const refresh = healthRecheck !== healthRechecked.current;
    healthRechecked.current = healthRecheck;
    void readHarnessHealth({ id: healthHarness, ...(refresh ? { refresh: true } : {}) })
      .then((reply) => {
        // A reply a newer read replaced changes nothing, the remembered answer included.
        if (!live) return;
        knownHarnessHealth.set(healthHarness, reply.health ?? undefined);
        setHarnessHealth(reply.health ?? undefined);
      })
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [connected, healthHarness, agentLocal, healthRecheck, readHarnessHealth]);
  // Another chat's harness draws its last known health in this render (no notice popping in late).
  const harnessHealth =
    healthHarness && agentLocal
      ? readHealth?.id === healthHarness
        ? readHealth
        : knownHarnessHealth.has(healthHarness)
          ? knownHarnessHealth.get(healthHarness)
          : readHealth
      : undefined;
  // Every harness this Mac's acpmux last found signed out, for the model picker's rail (cx-ae9eb):
  // read once the pane's direct client connects (a restored pane connects after its first render),
  // and again when a Log In comes back.
  const [signedOut, setSignedOut] = useState<Record<string, string>>({});
  // The same rows, for Harness updates available (harnessUpdateList.ts): every outdated agent CLI.
  const [healthRows, setHealthRows] = useState<readonly unknown[]>([]);
  const signedOutRechecked = useRef(0);
  useEffect(() => {
    const client = directClient.current;
    if (!connected || !client || !agentLocal) {
      setSignedOut({});
      setHealthRows([]);
      return;
    }
    let live = true;
    // After a Log In, acpmux checks again: its last rows would still say signed out.
    const refresh = healthRecheck !== signedOutRechecked.current;
    signedOutRechecked.current = healthRecheck;
    void Promise.resolve()
      .then(() => client.harnessHealthRows(refresh ? { refresh: true } : {}))
      .then((rows) => {
        if (!live) return;
        setSignedOut(signedOutHarnesses(rows));
        setHealthRows(rows);
      })
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [connected, agentLocal, healthRecheck, catalogSource]);
  // Every outdated agent CLI on this Mac for the model menus (Leo 2026-11-12, ask-3fdf0982ec), the
  // chat's own through its offer (Restart Chat follows it), any other updated in place.
  const harnessName = useCallback(
    (id: string) => agentName(id, catalog.find((entry) => entry.id === id)?.name),
    [catalog],
  );
  // The menus list the harnesses they offer: not a hidden one (the `cmux` router fallback runs
  // Claude Code's own `claude`, which its Claude Code row updates), a terminal or a model router.
  const harnessOffered = useCallback(
    (id: string) => catalog.find((entry) => entry.id === id)?.pickable !== false,
    [catalog],
  );
  const harnessUpdates = useHarnessUpdateList({
    rows: healthRows,
    offer: updateOffer,
    own: healthHarness,
    nameFor: harnessName,
    native: callNative,
    onUpdated: recheckHealth,
    offered: harnessOffered,
  });
  // The forum's current rules on this Mac (hq#2570), pinned above the composer: read when the pane
  // connects or opens a chat, and at each turn's start and end, when the chat's agent is told the
  // rules it has not read yet. A chat on another machine or in the cloud gets none.
  const [rules, setRules] = useState<ForumRule[]>([]);
  const turnWorking = snapshot.isWorking;
  // A streaming reply grows the transcript at its end: a declared layout move.
  useStreamAppendDeclaration(turnWorking);
  // Only once the chat's summary says where it runs: a remote chat never shows this Mac's rules.
  const rulesLocal = snapshot.summary !== undefined && healthLocal;
  useEffect(() => {
    const client = directClient.current;
    if (!connected || !client || !rulesLocal) {
      setRules([]);
      return;
    }
    let live = true;
    void Promise.resolve()
      .then(() => client.forumRules())
      .then((reply) => live && setRules(forumRules(reply)))
      // An older acpmux without the forum, or a failed read: no rules rather than stale ones.
      .catch(() => live && setRules([]));
    return () => {
      live = false;
    };
  }, [connected, rulesLocal, snapshot.sessionId, turnWorking]);
  // Add Credits… (accessOffer.ts): the app's own paid-plan path, run on the person's click. One the app did
  // not run (an older app) says so rather than nothing happening.
  const access = useMemo<AccessOffer>(
    () => ({
      addCredits: () =>
        void callNative("action.run", { id: ACCESS_ACTIONS.addCredits }).catch(
          sayActionRefusal(notices.transient, () =>
            translate("composer.offloadNotRun", { action: translate("access.addCredits") }),
          ),
        ),
    }),
    [notices],
  );
  // A page without a session checks its own selected target (NewTabScreen); never a guessed one here.
  const [authRouteVersion, setAuthRouteVersion] = useState(0);
  const setChatRoute = useCallback(async (sessionId: string, routeId: string) => {
    const client = directClient.current;
    if (!client) throw new Error("acpmux.notConnected");
    await client.setChatRoute(sessionId, routeId);
  }, []);
  const { routeChanging, routeAuthPending, settleRoute, switchRoute } = useRouteAuthSwitch(
    setChatRoute,
    useCallback(() => setAuthRouteVersion((version) => version + 1), []),
  );
  const readAuth = useCallback<NonNullable<SignIn["readSessionAuth"]>>(
    (query, refresh) =>
      connected && directClient.current
        ? directClient.current.sessionAuth(query, refresh)
        : Promise.resolve(UNKNOWN_AUTH),
    [connected],
  );
  const authEpoch = authRouteVersion;
  const authObservation = snapshot.isWorking ? 1 : 0;
  // Before the first prompt there is no session id, so ask acpmux about the exact harness the
  // composer displays. An unknown target answer stays unknown; it must never become a sign-in card.
  const authQuery = snapshot.sessionId
    ? { sessionId: snapshot.sessionId }
    : healthHarness && agentLocal
      ? {
          target: {
            harness: healthHarness,
            ...(snapshot.summary?.cwd?.startsWith("/") ? { cwd: snapshot.summary.cwd } : {}),
          },
        }
      : undefined;
  const {
    auth: sessionAuth,
    pending: authPending,
    recheck: recheckSession,
  } = useSessionAuth(authQuery, readAuth, authEpoch, healthRecheck, authObservation);
  const targetSignInHealth: HarnessHealth | undefined =
    !snapshot.sessionId &&
    !!healthHarness &&
    sessionAuth.state === "signedOut" &&
    sessionAuth.harness === healthHarness &&
    sessionAuth.login?.kind === "terminal" &&
    !!sessionAuth.login.command
      ? {
          id: healthHarness,
          auth: "signedOut",
          login: sessionAuth.login.command,
        }
      : undefined;
  useEffect(() => {
    settleRoute(snapshot.sessionId, authPending);
  }, [authPending, settleRoute, snapshot.sessionId]);
  const authPreflightPending = isAuthPreflightPending(routeChanging, routeAuthPending, snapshot.sessionId, authPending);
  const authBlock = authPreflightPending
    ? t("harnesses.checking")
    : authBlocksSend(sessionAuth)
      ? authText(sessionAuth, t)
      : undefined;
  const signIn = useMemo<SignIn>(
    () => ({
      signedOut,
      sessionAuth,
      recheckSession,
      readSessionAuth: readAuth,
      authEpoch,
      authRefresh: healthRecheck,
      authObservation,
      loginSession: (auth = sessionAuth) => {
        healthStale.current = true;
        void sessionLogin(
          auth,
          (params) => callNative("tab.open", params),
          snapshot.summary?.cwd,
          () => callNative("action.run", { id: CONNECT_ACTIONS.cloudSignIn }),
        ).catch(() => undefined);
      },
      logIn: (_harness, login) => {
        healthStale.current = true;
        void callNative("tab.open", {
          kind: "terminal",
          text: login,
          ...(snapshot.summary?.cwd ? { cwd: snapshot.summary.cwd } : {}),
          run: true,
        }).catch(() => undefined);
      },
      openLogIn: (_harness, login) => {
        healthStale.current = true;
        return callNative("tab.open", {
          kind: "terminal",
          text: login,
          ...(snapshot.summary?.cwd ? { cwd: snapshot.summary.cwd } : {}),
          run: true,
        }).then(
          () => true,
          () => false,
        );
      },
    }),
    [
      signedOut,
      sessionAuth,
      recheckSession,
      readAuth,
      authEpoch,
      healthRecheck,
      authObservation,
      snapshot.summary?.cwd,
    ],
  );
  // The composer's Account menu: this Mac's acpmux routes for the chat (acpmux refuses them to Web
  // and peer connections), read when the menu opens.
  const chatAccounts = useMemo<ChatAccounts | undefined>(
    () =>
      connected && healthLocal
        ? {
            list: async (sessionId) => {
              const client = directClient.current;
              if (!client) throw new Error("acpmux.notConnected");
              return readChatAccounts(await client.routes(sessionId));
            },
            set: switchRoute,
            add: async (account) => {
              await postNative("account.add", account);
            },
          }
        : undefined,
    [connected, healthLocal, switchRoute],
  );
  const loginCommand = chatLoginCommand(catalog, snapshot.summary?.harness, harnessHealth);
  // A new chat centers its composer under the hero.
  const handoff = snapshot.handoff?.record;
  const reviewing = reviewingHandoff(snapshot);
  // Until the chat's handoff is read the pane draws no review (reviews are rare): the composer and
  // a new chat's hero stay, and a review that arrives takes their place (Leo 2026-10-19: the
  // composer left for the read on every open, switch and reconnect).
  const freshChat = !reviewing && isNewChat(snapshot, newSession);
  /// The chat's start folder (startFolder.tsx): the host's folder for a new chat or the user's
  /// pick, for every start of this new chat (the agent row, a harness pick, the first Send).
  /// Undefined: the host fills the chat's folder (the workspace's agent-home folder).
  const startFolder = freshChat && !snapshot.sessionId ? projectDraft : undefined;
  const startFolderRef = useRef(startFolder);
  startFolderRef.current = startFolder;
  /// The folder question, while the chat it was asked for is still the one shown.
  const visitNow = trustVisit();
  const pendingFolder = inThisVisit(folderAsk, snapshot.sessionId, visitNow) ? folderAsk : undefined;
  // One hard stop for direct composer sends and every callback released by Trust. Confirmation
  // hides the question before the host answers, so it remains blocked while that answer saves.
  // Another chat shown meanwhile has no folder question of its own: it is not held.
  const confirmingHere = inThisVisit(folderConfirming, snapshot.sessionId, visitNow);
  const blockSend = Boolean(pendingFolder) || confirmingHere || Boolean(authBlock);
  // `snapshot.catalog` is `catalog` (the snapshot above carries the fetched one).
  const continueAvailable = canContinueIn(snapshot);
  /// Takes acpmux's trust refusal of a prompt (useFolderTrustAsk.ts): the question shows for the
  /// folder it named, and `again` sends the held prompt after Trust.
  const peerTrustStarted = useRef<(() => void) | undefined>(undefined);
  const trustRefused = useRef<((error: unknown, again?: () => void, declined?: () => void) => boolean) | undefined>(
    undefined,
  );
  const trustCancelEpoch = useRef(0);
  const pendingTrustRefusal = useRef<
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
  >(undefined);
  const trustRouteOwner = useRef<
    { client: AcpmuxDirectClient; generation: number; sessionId?: string; cancelEpoch: number } | undefined
  >(undefined);

  /// Keeps a send's gesture for the prompt acpmux held behind the trust question (heldPrompt.ts).
  const holdPrompt = useRef<(() => void) | undefined>(undefined);
  /// Puts a prompt acpmux refused for the folder's trust into the pane's hold (trustHeld.ts), with
  /// this send's gesture, in the chat it was sent in: it shows in that chat's queue and goes, in
  /// order, after Trust.
  const holdRefused = useRef<
    (text: string, attachments: ComposerAttachment[], error: unknown, sentFrom: SentFrom) => void
  >(() => undefined);
  /// The chat and folder shown, read when a prompt goes (a refusal may come after the person moved on).
  const shownFrom = useRef<() => SentFrom>(() => ({ chat: undefined, cwd: undefined }));
  // A folder without a trust answer is asked about beside the chat's other permission asks as
  // soon as the chat's folder is known (a new chat's chosen one before its first prompt). No
  // prompt goes until the answer is Trust; acpmux refuses one that does (`trust_gate.rs`).
  const lastMarks = useRef<RowMarks | undefined>(undefined);
  const marks = useMemo(() => (lastMarks.current = markRows(snapshot.rows, lastMarks.current)), [snapshot.rows]);
  const promptCount = marks.prompts.length;
  const answersTrust = snapshot.origin !== "remote" || snapshot.answersTrust === true;
  const trustAsk = useFolderTrustAsk(
    trustSource,
    {
      sessionId: snapshot.sessionId,
      cwd: snapshot.summary?.cwd ?? (snapshot.sessionId ? undefined : projectDraft),
      family: snapshot.summary?.family || snapshot.summary?.harness,
      prompts: promptCount,
      authority: trustAuthority,
      visit: trustVisit,
      reread: newTabAdoptions,
    },
    answersTrust,
    !directClient.current?.trustPeer && healthLocal && snapshot.origin !== "remote" && snapshot.origin !== "peer",
    blockSend,
  );
  // A no-folder recovery must not win over a trust answer made while its session switch is in
  // flight. The revision is advanced by Trust/Undo and by trust refusals, and read through a ref
  // because the host action handler outlives the render that installed it.
  const trustRevision = useRef(trustAsk.revision);
  trustRevision.current = trustAsk.revision;
  const trustRoute = trustAsk.refused;
  trustRefused.current = trustRoute;
  peerTrustStarted.current = trustAsk.started;
  // The connection's action table outlives renders; Retry must read the current folder/auth gate.
  const retryAfterTrust = useRef(trustAsk.retry);
  retryAfterTrust.current = trustAsk.retry;
  const cancelTrustResend = useCallback(() => {
    const client = directClient.current;
    client?.cancelTrustRefusals();
    trustCancelEpoch.current += 1;
    pendingTrustRefusal.current = undefined;
    trustAsk.cancelResend();
  }, [trustAsk]);
  const routeClient = trustRenderedOwner.current?.client;
  trustRouteOwner.current = routeClient
    ? {
        client: routeClient,
        generation: trustRenderedOwner.current?.generation ?? routeClient.trustGeneration,
        sessionId: trustRenderedOwner.current?.sessionId ?? snapshot.sessionId,
        cancelEpoch: trustCancelEpoch.current,
      }
    : undefined;
  useEffect(() => {
    const pending = pendingTrustRefusal.current;
    const client = directClient.current;
    const owner = trustRouteOwner.current;
    if (
      !pending ||
      !client ||
      pending.client !== client ||
      pending.generation !== client.trustGeneration ||
      pending.cancelEpoch !== trustCancelEpoch.current ||
      !owner ||
      owner.client !== client ||
      owner.generation !== pending.generation ||
      (pending.sessionId !== undefined && client.shownSession()?.sessionId !== pending.sessionId)
    )
      return;
    if (trustRoute(pending.error, pending.again, pending.declined)) pendingTrustRefusal.current = undefined;
  }, [trustRoute]);
  /// The ask whose card has a deny's instructions open: it stays the single card (`heldOnCard`).
  const [draftAsk, setDraftAsk] = useState<AcpmuxPermission>();
  const individualPermission =
    heldOnCard(draftAsk, snapshot.permission, snapshot.permissionGroups) ??
    (askOnSingleCard(snapshot.permission, snapshot.permissionGroups) ? snapshot.permission : undefined);
  // The asks of the sub-sessions below this chat (subagents/childAsks.ts): the oldest shows here,
  // answered through this chat, while the chat has no ask of its own.
  const belowAsks = useMemo(
    () => childAsks([...(snapshot.asks ?? []), ...(snapshot.groupedAsks ?? [])], snapshot.sessions, snapshot.sessionId),
    [snapshot.asks, snapshot.groupedAsks, snapshot.sessions, snapshot.sessionId],
  );
  const childAsk = individualPermission ? undefined : belowAsks[0];
  // Search files reads the session's folder through whoever runs the session: the acpmux
  // client (or the mock daemon), else the native host.
  const fileRoot = snapshot.summary?.cwd;
  // The + menu's Attach Screenshot…, Attach Window… and Record Screen… (composer/screenCapture.ts):
  // a still goes back to the composer as an image; a recording goes in here as a video link chip.
  // Either goes only to the chat the capture started in.
  const captureChat = useRef(snapshot.sessionId);
  useLayoutEffect(() => {
    captureChat.current = snapshot.sessionId;
  }, [snapshot.sessionId]);
  const captureScreen = useCallback(async (mode: CaptureMode) => {
    const taken = await takeCapture(mode, callNative, () => captureChat.current);
    if (taken?.kind === "recording") composerHandle.current?.attach(taken.attachment);
    return taken?.kind === "still" ? taken.file : undefined;
  }, []);
  const uploadFiles = useCallback(
    (files: File[], cancelled?: (index: number) => boolean, progress?: UploadProgressReport) =>
      uploadToMachine(files, callNative, cancelled, progress),
    [],
  );
  // A chat on this Mac links a dropped or pasted folder, or a file no block takes, where it is.
  const localPaths = useCallback(
    (kind: DroppedKind, files: File[], gestureAt?: number) => droppedPaths(kind, files, callNative, gestureAt),
    [],
  );
  const searchFiles = useCallback<FileSearchSource>(
    (query) =>
      callNative("file.search", {
        ...(fileRoot ? { path: fileRoot } : {}),
        query,
        limit: FILE_SEARCH_LIMIT,
      }),
    [fileRoot],
  );
  const chatShellRuns = useMemo(
    () => allShellRuns.filter((run) => run.sessionId === snapshot.sessionId),
    [allShellRuns, snapshot.sessionId],
  );
  // Shell output changes do not move its block. Keep the message-fold boundaries stable until
  // a command starts or leaves this chat, so output chunks cannot invalidate historical folds.
  const lastMessageBreaks = useRef<readonly number[]>([]);
  const messageBreaks = useMemo(() => {
    const next = chatShellRuns.map((run) => run.startedAt).sort((a, b) => a - b);
    const previous = lastMessageBreaks.current;
    if (next.length === previous.length && next.every((at, index) => at === previous[index])) return previous;
    return (lastMessageBreaks.current = next);
  }, [chatShellRuns]);
  // Inline `/btw` asides (aside/btwNotes.ts): rows of their chat's transcript, not of acpmux's.
  const [btwNotes] = useState(() => new BtwNotes());
  const btwSnapshot = useSyncExternalStore(btwNotes.subscribe, btwNotes.snapshot, btwNotes.snapshot);
  const hasBtwNotes = btwSnapshot.some((note) => note.sessionId === snapshot.sessionId);
  /// A fresh chat shows its empty state until something is in it: a prompt, a command it ran, or
  /// a side question asked in it (its aside is a transcript row).
  const freshView = freshChat && chatShellRuns.length === 0 && !hasBtwNotes;
  // Turn shape: work folds under "Worked for" until opened; shell mode's blocks sit where they ran.
  // A subagent's "Subagent of" pill names the chat as the chat list does: never acpmux's generated
  // name (`claude-2`), and "New chat" before it has a title, never nothing.
  const chatName = snapshot.summary ? sessionTitle(snapshot.summary, t) : t("sidebar.newChat");
  // Running subagents sit in the tray above the composer, and one that ended leaves a line where it
  // ended (subagents/runningTray.ts); Debug Settings agentPane.debug.subagentTray off keeps the
  // transcript's group cards and the agents pill.
  const subagentTray = useSubagentTray();
  const trayPlacement = useSubagentTrayPlacement();
  const [goalHatPlaceArm] = useState(() => experimentArm(goalHatPlace));
  // The agent dot grid on the home (dotGrid/agentDotGrid.experiment.ts): off unless opted in.
  const [dotGridArm] = useState(agentDotGridArm);
  const doneLines = useRef<DoneLineCache>(new Map());
  const childDoneLines = useRef<DoneLineCache>(new Map());
  const shownSessionId = snapshot.sessionId ?? snapshot.summary?.sessionId;
  // The open folds as the shown chat's transcript view draws them: Normal is `expanded` itself;
  // Thinking and Verbose also open each finished turn's "Worked for" (conversation/viewFolds.ts).
  // One object per view, set or toggle change, so the turns are not reshaped per event.
  const chatPresentation = usePresentation(shownSessionId);
  // Leo's alternate -ing verbs stay behind the explicit Rotate setting. The normal path leaves
  // this context empty so the live line remains the bare translated Thinking label.
  const statusVerbConfig = useStatusVerbConfig();
  const language = usePaneLanguage();
  const thinkingVerbs = statusVerbConfig.mode === "rotate" ? thinkingVerbsFor(language) : undefined;
  const chatView = useTranscriptView(shownSessionId);
  const chatViewRef = useRef(chatView);
  chatViewRef.current = chatView;
  const viewToggled = viewToggles.get(chatView) ?? NO_FOLD_TOGGLES;
  const folds = useMemo(() => viewFolds(chatView, expanded, viewToggled), [chatView, expanded, viewToggled]);
  // Who runs this chat when it is not the person (managedBy.ts): the line over the composer, shown
  // only while that manager drives the chat (`managerDrivingUntil`), never on a chat it only
  // dispatched or that went quiet (Leo, 2026-11-03: "i feel like it's put out there too often").
  const [takenOverAt, setTakenOverAt] = useState(0);
  const chatManager = useMemo(
    () => (isTakenOver(shownSessionId) ? undefined : managedBy(shownSessionId, snapshot.sessions)),
    // takenOverAt: the person's Hide, read back from the store.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [shownSessionId, snapshot.sessions, takenOverAt],
  );
  const drivingUntil = useMemo(() => {
    const now = Date.now();
    // Rows carry a peer's clock (SSH, Cloud): this computer's is the peer's plus the offset.
    const peerUntil = managerDrivingUntil(
      chatManager,
      snapshot.rows,
      snapshot.queue.map((entry) => entry.message),
    );
    const until = peerUntil === undefined ? undefined : peerUntil + (snapshot.clockOffsetMs ?? 0);
    return until !== undefined && until > now ? until : undefined;
  }, [chatManager, snapshot.rows, snapshot.queue, snapshot.clockOffsetMs]);
  // The line goes when the window ends: one timer to that moment, cleared when the chat, its rows
  // or the window change and on unmount (its stop condition).
  const [drivingExpired, setDrivingExpired] = useState<number | undefined>(undefined);
  useEffect(() => {
    // A queued manager message keeps it (Infinity) until the queue changes: no timer.
    if (drivingUntil === undefined || !Number.isFinite(drivingUntil)) return;
    const timer = setTimeout(() => setDrivingExpired(drivingUntil), Math.max(0, drivingUntil - Date.now()));
    return () => clearTimeout(timer);
  }, [drivingUntil]);
  const manager = drivingUntil !== undefined && drivingExpired !== drivingUntil ? chatManager : undefined;
  // The Chief whose prompts this chat draws "Sent from" (conversation/sentFrom.ts).
  const chatChief = useMemo(() => chiefOf(shownSessionId, snapshot.sessions), [shownSessionId, snapshot.sessions]);
  const freshAgents = useMemo(
    () => [...subagentsIn(snapshot.rows, snapshot.subagentViews).values()],
    [snapshot.rows, snapshot.subagentViews],
  );
  /// The name a subagent's pane tab shows (subagentPanes.ts subagentTabTitle): its own, else "Subagent of" the chat.
  const subagentTitle = (id: string) =>
    subagentTabTitle(
      freshAgents.find((agent) => agent.id === id),
      `${t("subagents.of")} ${chatName}`,
    );
  // The mark its row draws, which its pane's tab draws too (subagentPanes.ts `subagentRowMark`).
  const senderBadge = useSenderIconLook().badge;
  const chatMark = knownMark(snapshot.summary?.harness, snapshot.summary?.family);
  const subagentMark = (id: string) =>
    subagentRowMark(
      freshAgents.find((agent) => agent.id === id),
      chatMark,
      senderBadge,
    );
  // For callbacks that keep one identity (showSubagent names a pane's tab and its icon with them).
  const subagentTitleRef = useRef({ title: subagentTitle, mark: subagentMark });
  subagentTitleRef.current = { title: subagentTitle, mark: subagentMark };
  const workflowAdapter = useMemo(createWorkflowAdapter, []);
  const workflows = useMemo(
    () => (workflowLabsEnabled && shownSessionId ? workflowAdapter(freshAgents, shownSessionId) : []),
    [workflowLabsEnabled, workflowAdapter, freshAgents, shownSessionId],
  );
  const workflowRequest = useMemo(() => workflowPaneRequest(subagentView), [subagentView]);
  const selectedWorkflowAgent = useMemo(
    () =>
      [...workflows]
        .reverse()
        .find((workflow) => workflow.runId === workflowRequest?.runId)
        ?.agents.find((agent) => agent.agentId === workflowRequest?.agentId),
    [workflows, workflowRequest],
  );
  const readWorkflowAgent = useCallback(
    (request: WorkflowDetailRequest & { before?: number; after?: number }) =>
      // l10n-allow: internal transport error; the transcript surface renders its own localized state.
      directClient.current?.readWorkflowAgent(request) ?? Promise.reject(new Error("Not connected")),
    [],
  );
  const workflowTranscript = useWorkflowTranscript(
    subagentView,
    shownSessionId,
    workflowLabsEnabled,
    selectedWorkflowAgent,
    chatName,
    readWorkflowAgent,
    snapshot.connection,
  );
  // A subagent's own transcript for a line that needs its whole reply (SubagentReportLine.tsx), read
  // through one stable getter so a streaming subagent wakes no transcript row.
  const subagentViewsRef = useRef(snapshot.subagentViews);
  subagentViewsRef.current = snapshot.subagentViews;
  const readSubagentView = useCallback((id: string) => subagentViewsRef.current?.[id], []);
  // A subagent the chat's loaded rows do not hold whole (an old one, finished pages ago, or one whose
  // stop the page kept but not its work): its pane reads that subagent's own records
  // (subagents/subagentOwnLog.ts `needsOwnLog`) and draws them, loading until they come and empty if
  // there are none, never the chat's rows (Leo, 2026-11-07: "is this your sub-agent, or is this
  // literally just a duplicate of you?"; 2026-11-12: "NO MESSAGES DISPLAYED?").
  const subagentReadsOwnLog = useMemo(
    () => !!subagentView && needsOwnLog(subagentView, { rows: snapshot.rows, views: snapshot.subagentViews }),
    [subagentView, snapshot.rows, snapshot.subagentViews],
  );
  const readSubagentLog = useCallback(
    // l10n-allow: internal transport error; the subagent pane renders its own localized state.
    (id: string) => directClient.current?.readSubagentLog(id) ?? Promise.reject(new Error("Not connected")),
    [],
  );
  // A finished subagent's whole last reply, from its own records, for a report card whose Show more
  // asks for it when the chat's loaded rows no longer hold the subagent (subagents/wholeReport.ts).
  const subagentHarness = snapshot.summary?.harness;
  const readSubagentReply = useCallback(
    async (id: string) =>
      lastSubagentReply(
        foldOwnLog(id, await readSubagentLog(id), { session: shownSessionId, harness: subagentHarness }).views[id],
      ),
    [readSubagentLog, shownSessionId, subagentHarness],
  );
  // The background tasks panel's drill-in reads a subagent's own records by the same rule.
  const backgroundOwnLogReads = useMemo(
    () => ({ chat: { session: shownSessionId, harness: subagentHarness }, read: readSubagentLog, connected }),
    [shownSessionId, subagentHarness, readSubagentLog, connected],
  );
  const { log: ownLogged, loading: ownLoading } = useOwnLog(
    subagentView && !workflowRequest && subagentReadsOwnLog ? subagentView : undefined,
    { session: shownSessionId, harness: snapshot.summary?.harness },
    readSubagentLog,
    connected,
  );
  const childRows = useMemo(() => {
    if (workflowTranscript.rows) return workflowTranscript.rows;
    if (!subagentView) return undefined;
    const chat = { rows: snapshot.rows, views: snapshot.subagentViews };
    const own = { log: ownLogged, loading: ownLoading };
    if (!subagentTray) return subagentPaneView(subagentView, chat, own, folds, chatName);
    const view = subagentPaneView(subagentView, chat, own, NO_EXPANDED, chatName);
    return withSubagentLines(view, childDoneLines.current, workflowLabsEnabled) as AcpmuxRow[];
  }, [
    subagentView,
    snapshot.rows,
    snapshot.subagentViews,
    ownLogged,
    ownLoading,
    folds,
    chatName,
    subagentTray,
    workflowLabsEnabled,
    workflowTranscript.rows,
  ]);
  // The session's edit rows for the edited-files card, the same array while they are the same rows.
  const lastEditRows = useRef<SessionEdits | undefined>(undefined);
  const editRows = useMemo(() => {
    const edits = sessionEdits(snapshot.rows, lastEditRows.current);
    lastEditRows.current = edits;
    return edits.edits;
  }, [snapshot.rows]);
  // The names this chat's start calls gave its sub-sessions, for a "Sent to" row whose chat left
  // the session list (conversation/startedNames.ts); the same map while no start was added.
  const lastStartedNames = useRef<StartedNames | undefined>(undefined);
  const subsessionNames = useMemo(() => {
    const started = startedNames(snapshot.rows, lastStartedNames.current);
    lastStartedNames.current = started;
    return started.names;
  }, [snapshot.rows]);
  // The same set while it holds the same calls: it is read by memoized parts (Session Info, the
  // summary card), and the rows it is read from are new on every snapshot the pane draws.
  const askedToolCalls = useSameValue(
    useMemo(
      () => pendingToolCalls(snapshot),
      // oxlint-disable-next-line react-hooks/exhaustive-deps -- the asks' inputs, not the whole snapshot
      [snapshot.rows, snapshot.permission, snapshot.permissionGroups],
    ),
  );
  // The chat's rows before turns fold their work, which Find searches (a closed fold included).
  const sourceRows = useMemo(() => {
    const groups = snapshot.permissionGroups;
    const groupedIds = new Set(groups?.groups.flatMap((group) => group.items.map((item) => item.permissionId)));
    const rows = groups?.supported
      ? snapshot.rows.filter(
          (row) =>
            row.kind !== "permission" ||
            (!row.permission?.groupId &&
              !groupedIds.has(row.permission?.permissionId ?? "") &&
              row.permission?.permissionId !== individualPermission?.permissionId),
        )
      : individualPermission
        ? snapshot.rows.filter((row) => row.permission?.permissionId !== individualPermission.permissionId)
        : snapshot.rows;
    // Each step's consecutive thoughts as one, and none that says nothing (conversation/thoughts.ts);
    // one "While you were away" card, the newest (conversation/oneRecap.ts).
    return withoutQuietThoughts(oneRecap(rows), snapshot.isWorking);
  }, [snapshot.rows, snapshot.permissionGroups, individualPermission, snapshot.isWorking]);
  // A call the permission panel asks about is drawn by the panel's row while it waits
  // (withoutAskedCalls).
  const panelAsks = useMemo(() => groupAskedCalls(snapshot.permissionGroups), [snapshot.permissionGroups]);
  // The chats this chat's agent started, as cards in its transcript and chips in its replies
  // (started/startedSessions.ts), with the started-session-cards experiment on. An offer's
  // started task stays on its suggested tasks card.
  // Snapshots rebuild rows each time: the list keeps its object while what it says is the same,
  // so the transcript and every reply's chips (a context) do not redraw.
  const startedOn = startedCardsShown();
  // The chats it started, kept while each entry is the same object (direct.ts keeps an unchanged
  // session's entry), so a streamed snapshot does not search the transcript or rebuild the list.
  // Always read: the summary card lists them and the running line counts them, experiment or not.
  const spawnedFresh = snapshot.sessionId ? spawnedSessions(snapshot.sessions, snapshot.sessionId) : NO_SPAWNED;
  const spawnedKept = useRef<readonly AcpmuxSessionEntry[]>(NO_SPAWNED);
  if (!sameItems(spawnedKept.current, spawnedFresh)) spawnedKept.current = spawnedFresh;
  const spawned = spawnedKept.current;
  // Every chat it started, offers' included, with its live state: the rows under Session Info's
  // Subagents (the summary card's with it off), the tray and the running line's counts.
  // A chat on a Cloud VM or another machine lists the children its daemon reports with its own
  // session (RemoteAcpmuxWire `_acpmux/watch`). A new list only when an entry changes.
  const childSessions = useMemo(
    () => (spawned.length ? startedSessions(spawned, snapshot.sessionId, { doing: true }) : NO_STARTED),
    [spawned, snapshot.sessionId],
  );
  // Only a chat it started can be an offer's started task: the rows are read only when there is one.
  const offered =
    startedOn && spawned.length
      ? [...offerChildren(snapshot.rows)].filter((id) => spawned.some((entry) => entry.sessionId === id)).join("\n")
      : "";
  const startedFresh = useMemo(
    () =>
      startedOn && spawned.length
        ? startedSessions(spawned, snapshot.sessionId, { exclude: new Set(offered.split("\n")) })
        : NO_STARTED,
    [startedOn, spawned, offered, snapshot.sessionId],
  );
  const startedKept = useRef<{
    fresh: readonly StartedSession[];
    key: string;
    started: readonly StartedSession[];
  }>({
    fresh: NO_STARTED,
    key: "[]",
    started: NO_STARTED,
  });
  if (startedKept.current.fresh !== startedFresh) {
    const key = startedFresh.length ? JSON.stringify(startedFresh) : "[]";
    startedKept.current =
      startedKept.current.key === key
        ? { ...startedKept.current, fresh: startedFresh }
        : { fresh: startedFresh, key, started: startedFresh.length ? startedFresh : NO_STARTED };
  }
  const started = startedKept.current.started;
  const startedCache = useRef<StartedCache>(new Map());
  // Every listed session's full id in a reply is a chip too (started/sessionHover.ts).
  const otherIds = useMemo(
    () => (startedOn ? withSessionIds([], snapshot.sessions, snapshot.sessionId) : []),
    [startedOn, snapshot.sessions, snapshot.sessionId],
  );
  const mentionsKey = JSON.stringify([
    startedOn,
    started.map((child) => [child.sessionId, child.title, child.named, child.state]),
    // Ids only: another session's state reaches its card through the hover store, never a redraw.
    otherIds.map((mention) => mention.sessionId),
  ]);
  const startedMentions = useMemo<StartedMentions>(
    () => {
      const mentions = startedOn ? withSessionIds(sessionMentions(started), snapshot.sessions, snapshot.sessionId) : [];
      return mentions.length ? { mentions, open: openOfferChat } : NO_MENTIONS;
    },
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- what the chips name, not each status change
    [mentionsKey],
  );
  // Each session reference's hover card reads the session from one store (started/SessionHoverCard.tsx).
  // Every reference to one of the reader's chats has it (an agent link, a session name, a sender's
  // name; Leo, 2026-11-05), with started session cards on or off: the experiment draws the cards and
  // the name chips of started chats, not the hover.
  const hoverStore = useRef<SessionHoverStore | null>(null);
  hoverStore.current ??= new SessionHoverStore();
  useLayoutEffect(() => {
    hoverStore.current!.set(snapshot.sessions);
  }, [snapshot.sessions]);
  // The draft's pasted chat links name their chats from the same list (composer/deeplinkTitles.ts).
  useLayoutEffect(() => {
    const store = hoverStore.current!;
    setPageChats(store);
    return () => {
      if (pageChatStore() === store) setPageChats(undefined);
    };
  }, []);
  const sessionHover = useMemo<SessionHover>(() => ({ store: hoverStore.current!, open: openOfferChat }), []);
  // The transcript's sub-session cards read each sub-session's state from one store, so a session
  // changing never redraws a turn (subagents/subsessions.ts); a name opens its chat beside this one.
  const subsessionStore = useRef<SubsessionStore | null>(null);
  subsessionStore.current ??= new SubsessionStore();
  useLayoutEffect(() => {
    subsessionStore.current!.set(snapshot.sessions);
  }, [snapshot.sessions]);
  const subsessions = useMemo<Subsessions>(
    () => ({
      store: subsessionStore.current!,
      open: openOfferChat,
      openSender: openSenderChat,
      // A sender chip whose name acpmux resolves to no chat says so, in a toast.
      senderMissing: notices.senderMissing,
    }),
    [notices],
  );
  /// The Quick Composer panel (`"surface": "quick"` in the host's ready reply) or a tab's pane.
  const [surface, setSurface] = useState<PaneSurface>("pane");
  const [previewHost, setPreviewHost] = useState(false);
  const quick = surface === "quick";
  // The last snapshot's turns and subagent rows: the next builds on them (turnViewFrom).
  const lastTurns = useRef<{ sessionId: string | undefined; turns: TurnView; subagents: SubagentRows } | undefined>(
    undefined,
  );
  const supersededReplyIds = useMemo(
    () => (snapshot.supersededRows?.length ? new Set(snapshot.supersededRows) : undefined),
    [snapshot.supersededRows],
  );
  /// Debug Settings `agent.sessionStatus`: a running turn's activity line under its todo list.
  const sessionStatus = useSessionStatus();
  const turnRowsShown = useMemo(
    () =>
      turnRowsShownFrom({
        chatPresentation,
        childRows,
        sourceRows,
        panelAsks,
        started,
        startedCache,
        subagentTray,
        doneLines,
        workflowLabsEnabled,
        lastTurns,
        shownSessionId,
        heldCalls,
        callRelease,
        transcriptInView,
        heldRuns,
        heldWorked,
        heldWorkedClosing,
        snapshot: {
          isWorking: snapshot.isWorking,
          canLoadNewer: snapshot.canLoadNewer,
          clockOffsetMs: snapshot.clockOffsetMs,
          turnStartedAtMs: snapshot.turnStartedAtMs,
          summary: { family: snapshot.summary?.family },
          waitingSteers: snapshot.waitingSteers,
        },
        sessionStatus,
        messageBreaks,
        supersededReplyIds,
        foldsSeen,
        folds,
        heldFolds,
        chatShellRuns,
      }),
    [
      chatPresentation,
      childRows,
      sourceRows,
      started,
      folds,
      snapshot.isWorking,
      snapshot.canLoadNewer,
      snapshot.clockOffsetMs,
      snapshot.turnStartedAtMs,
      sessionStatus,
      snapshot.summary?.family,
      snapshot.waitingSteers,
      supersededReplyIds,
      messageBreaks,
      chatShellRuns,
      panelAsks,
      subagentTray,
      workflowLabsEnabled,
      shownSessionId,
      callRelease,
    ],
  );
  // The questions the agent asked the person that still wait on them once another turn came after
  // (turns.ts `waitingAsks`): pinned in the asks stack above the composer (PendingAsks.tsx) until
  // answered, said anything after, or dismissed. Leo, 2026-11-06, on a question another agent's
  // message pushed out of reach: "perhaps persistent at the bottom".
  const waitingAskRows = useMemo(
    () => {
      const last = lastTurns.current;
      if (childRows || chatPresentation === "messages" || !last || last.sessionId !== shownSessionId) return NO_ROWS;
      return waitingAsks(last.turns);
    },
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the view turnRowsShown shaped, read from its ref
    [turnRowsShown, childRows, chatPresentation, shownSessionId],
  );
  const [askDismissals, setAskDismissals] = useState(() => ({
    sessionId: shownSessionId,
    keys: dismissedAsks(shownSessionId),
  }));
  if (askDismissals.sessionId !== shownSessionId)
    setAskDismissals({ sessionId: shownSessionId, keys: dismissedAsks(shownSessionId) });
  // A card answered from this page leaves in the click's frame, before its prompt settles it
  // (waitingAskStore.ts `givenAnswer`): its answer may wait in the queue behind a running turn.
  const answered = useSyncExternalStore(subscribeAnswers, answeredAsks, answeredAsks);
  const askedAway = useMemo(() => withAnswered(askDismissals.keys, answered), [askDismissals, answered]);
  const pinnedAsks = useMemo(() => shownAsks(waitingAskRows, askedAway), [waitingAskRows, askedAway]);
  const dismissPinnedAsk = useCallback(
    (key: string) => setAskDismissals({ sessionId: shownSessionId, keys: dismissAsk(shownSessionId, key) }),
    [shownSessionId],
  );
  // Every message other sessions sent that the agent has not read yet, the steers its running turn
  // has not taken and the messages queued behind it, is in one group at the end
  // (conversation/pendingMessages.ts), never a loose list of rows and never composer-queue rows. A
  // chat with none keeps its rows as they are; one with some copies the row list once per change.
  const lastQueuedRows = useRef<readonly AcpmuxRow[] | undefined>(undefined);
  const queuedRows = useMemo(() => {
    if (childRows) return NO_ROWS;
    return (lastQueuedRows.current = queuedMessageRows(shownQueue, lastQueuedRows.current));
  }, [childRows, shownQueue]);
  // Find searches the queued messages too: each is its own row, drawn in the group of waiting
  // messages (its `joined` names them, chatFind.ts findRowIndex).
  const findRows = useMemo(() => searchablePendingRows(sourceRows, queuedRows), [sourceRows, queuedRows]);
  const lastPending = useRef<AcpmuxRow | undefined>(undefined);
  // acpmux's inbox notices next to each other draw as one (conversation/inboxNotice.ts): rows with
  // none in a run come back as they are.
  // The running turn's todo list shows in the hat over the composer (subagents/SubagentTray.tsx
  // `plan`), not pinned in the transcript (Leo, 2026-11-03: "we said earlier the composer hat is kinda
  // ok?"), unless Settings > Agent Chat > Pin Task List in Chat is on, or there is no hat (the tray off
  // in Debug Settings, the Quick Composer, a subagent's own view). Once the turn ends its list folds
  // in the transcript, as before.
  const pinnedPlan = useChatPinnedPlan();
  // The hat tucked away to its pull tab (chatDisplay.ts TRAY_TUCKED_KEY; Leo, 2026-11-04).
  const trayTucked = useTrayTucked();
  // Where its tuck chevron and pull tab sit along the composer's top edge (chatDisplay.ts TRAY_HANDLE_KEY).
  const trayHandle = useTrayHandle();
  // Where the jump stack stands over the composer (jumpPlace.experiment.ts; Leo, 2026-11-21: "didn't
  // we say we wanted to move these to the side or smth?"): beside the hat's handle, never on it.
  const [jumpPlaceArm] = useState(() => experimentArm(jumpLatestPlace));
  // Debug Settings agent.sessionStatus draws its activity line under the pinned list, so it pins it.
  const planInHat = subagentTray && !pinnedPlan && !sessionStatus && !quick && !childRows && snapshot.isWorking;
  const hatPlanRow = useMemo(() => (planInHat ? liveTurnPlan(turnRowsShown) : undefined), [planInHat, turnRowsShown]);
  // A running turn with no list of its own yet keeps the agent's earlier list with steps left in
  // sight, marked as from before the person's last message (turns.ts earlierTurnPlan). It stays folded in its own turn too; the copy goes once the agent writes a list.
  const earlierPlanRow = useMemo(
    () =>
      snapshot.isWorking && !quick && !childRows && !liveTurnPlan(turnRowsShown)
        ? earlierTurnPlan(turnRowsShown)
        : undefined,
    [snapshot.isWorking, quick, childRows, turnRowsShown],
  );
  // The chat's task list across its turns (acpmux `taskList`, chatTaskList.ts): between turns the hat
  // shows it while steps are left, and a running turn without a list of its own shows it when the
  // transcript no longer holds the earlier list (a long chat paged it out), or when the Chief keeps it.
  const tasksInHat = subagentTray && !pinnedPlan && !sessionStatus && !quick && !childRows;
  const hatTasks = tasksInHat
    ? hatPlanOf({
        working: snapshot.isWorking,
        live: hatPlanRow?.plan,
        earlier: earlierPlanRow?.plan,
        list: snapshot.summary?.taskList,
      })
    : undefined;
  const hatEarlier = hatTasks?.earlier ?? false;
  const hatKept = hatTasks?.kept ?? false;
  const hatPlanSource = hatTasks?.plan;
  // The list's entries hold while a step's state does not change, so streamed text never redraws the hat.
  const hatPlanKept = useRef<readonly AcpmuxPlanEntry[] | undefined>(undefined);
  const hatPlan = sameEntries(hatPlanKept.current, hatPlanSource)
    ? hatPlanKept.current
    : (hatPlanKept.current = hatPlanSource);
  // Without the hat, the earlier list's copy pins under the running turn, over its live line.
  const pinnedEarlier = useMemo<AcpmuxRow | undefined>(
    () =>
      !planInHat && earlierPlanRow
        ? { ...earlierPlanRow, id: `${earlierPlanRow.id}${EARLIER_PLAN}`, turnEnded: false, planEarlier: true }
        : undefined,
    [planInHat, earlierPlanRow],
  );
  const transcriptRows = useMemo(() => {
    const last = lastTurns.current;
    let steers: readonly AcpmuxRow[] = NO_ROWS;
    if (!childRows && chatPresentation !== "messages" && last && last.sessionId === shownSessionId)
      steers = last.turns.pending ?? NO_ROWS;
    // A guest's prompt is a person's, never another session's message: it draws on its own, held
    // with its Approve and Decline in view (conversation/QueuedMessageCard.tsx), never folded into
    // the group.
    const people = queuedRows.filter(isPersonQueuedRow);
    const agents = people.length ? queuedRows.filter((row) => !isPersonQueuedRow(row)) : queuedRows;
    const group = pendingMessagesRow(steers, agents, lastPending.current);
    lastPending.current = group;
    const merged = mergeInboxNotices(
      withEarlierPlan(hatPlanRow ? turnRowsShown.filter((row) => row !== hatPlanRow) : turnRowsShown, pinnedEarlier),
    );
    // The waiting messages follow the chat's latest row, not a window's last (direct.ts `newerLeft`).
    const rows = snapshot.canLoadNewer ? merged : withWaitingRows(merged, group ? [...people, group] : people);
    return childRows ? rows : btwNotes.rows(rows, snapshot.sessionId, btwSnapshot);
  }, [
    chatPresentation,
    childRows,
    turnRowsShown,
    hatPlanRow,
    pinnedEarlier,
    queuedRows,
    btwNotes,
    btwSnapshot,
    snapshot.sessionId,
    snapshot.canLoadNewer,
    shownSessionId,
  ]);
  // Failed prompts in a row with one cause share one card (sendFailure.ts); a trust failure's card
  // offers Trust folder while the folder is not trusted, and its Retry waits while the folder's
  // question is open, which acpmux would refuse again.
  const lastFailedRuns = useRef<ReadonlyMap<string, FailedRun> | undefined>(undefined);
  const runs = useMemo(
    () => (lastFailedRuns.current = failedRuns(transcriptRows, lastFailedRuns.current)),
    [transcriptRows],
  );
  // The cards' context changes only when what they show does: Trust is a new function each render.
  const trustNow = useRef(trustAsk.trust);
  trustNow.current = trustAsk.trust;
  const canTrustFolder = answersTrust && !trustAsk.trusted && trustAsk.ask?.state !== "remote";
  const trustBlock = trustAsk.blocked?.reason;
  const failedSends = useMemo<FailedSends>(
    () => ({
      runs,
      ...(trustBlock ? { trustBlock } : {}),
      ...(canTrustFolder ? { trustFolder: () => trustNow.current() } : {}),
    }),
    [runs, trustBlock, canTrustFolder],
  );
  // A wide pane reserves a right-side summary column; a narrow pane keeps the summary as a
  // popover under the header button so it never covers the composer controls.
  // Leo, 2026-10-21: "no layout shift then a fast fade in, instant if cached". A switch in place
  // (chat.select: the page's list, a branch, a fork) to a chat read cold fades its transcript in;
  // one drawn from a kept tail (direct.ts drawKeptTail) shows on the frame it lands. The first chat
  // the page shows has no chat before it: the host reveals that one (pane.painted).
  const [opened, setOpened] = useState<{ shown?: string; open: number; cold: boolean }>({
    shown: shownSessionId,
    open: 0,
    cold: false,
  });
  if (opened.shown !== shownSessionId)
    setOpened({
      shown: shownSessionId,
      open: opened.open + 1,
      cold: opened.shown !== undefined && shownSessionId !== undefined && snapshot.drewKeptTail !== true,
    });
  // A chat read with nothing in it (a new chat: its first prompt enters as a live row) has nothing
  // to fade in, and a chat whose kept tail drew after the switch's hold gave up (a slow host read
  // under load, a reconnect) is cached all the same: it shows at once. Rows that show before the
  // chat is read (a live event, or a prompt sent, while a slow attach is out) are on screen
  // already: the fade never takes them back to nothing, and what the read adds under them shows
  // as it lands.
  else if (
    opened.cold &&
    ((snapshot.chatRead === true && (freshView || transcriptRows.length === 0)) ||
      snapshot.drewKeptTail === true ||
      (snapshot.chatRead !== true && transcriptRows.length > 0))
  )
    setOpened({ ...opened, cold: false });
  const coldOpenShown = useCallback(
    (open: number) => setOpened((current) => (current.open === open ? { ...current, cold: false } : current)),
    [],
  );
  /// The chat shown now, for a permission card's deny with instructions (PermissionAsk), which
  /// reads it after the deny goes, never a render's stale copy.
  const shownChat = useRef(shownSessionId);
  useLayoutEffect(() => {
    shownChat.current = shownSessionId;
  }, [shownSessionId]);
  /// What the transcript shows now, for a `?message=` link's row still waiting to be drawn
  /// (`reveal`): the chat, and the subagent whose rows the pane shows in place of the chat's own.
  /// A row the reader leaves within the wait is dropped rather than scrolled in, because ids start
  /// over with each session and a subagent's rows carry ids of the shape the chat's own have.
  const shownSubagent = childRows ? subagentView : undefined;
  const shownView = useRef<string | undefined>(undefined);
  useLayoutEffect(() => {
    shownView.current = shownSubagent === undefined ? shownSessionId : `${shownSessionId}:subagent:${shownSubagent}`;
  }, [shownSessionId, shownSubagent]);
  // The sub-sessions this chat's agent started, and theirs, for the summary card's Subagents list.
  const chatSubsessions = useMemo(
    () => ({ rows: subsessionRows(snapshot.sessions, shownSessionId), onOpen: openOfferChat }),
    [snapshot.sessions, shownSessionId],
  );
  const [workflowSideTabId, setWorkflowSideTabId] = useState<string>();
  const workflowSideTabOpener = useRef<HTMLElement | undefined>(undefined);
  const workflowSideTabFocusOnClose = useRef(false);
  const workflowSideTab = useMemo(
    () => (workflowLabsEnabled ? workflows.find((workflow) => workflow.id === workflowSideTabId) : undefined),
    [workflowLabsEnabled, workflows, workflowSideTabId],
  );
  const clearWorkflowSideTab = useCallback(() => {
    workflowSideTabFocusOnClose.current = false;
    workflowSideTabOpener.current = undefined;
    setWorkflowSideTabId(undefined);
  }, []);
  // The Background tasks panel opens from the chat's ⋯ menu and from the running tray's header
  // (SubagentTray.tsx `onOpenPanel`). A workflow's side tab would cover it (a full-height overlay):
  // it closes. Already open, it stays as it is (expanded, cleared and drilled in alike).
  // It opens as a tab in the chat's right column (Leo, 2026-11-03: "it should be opening up on the
  // right pane as a tab instead of this"), or focuses the one open there; a host that opens no tab
  // (the gallery, Quick Chat's panel, an older app) keeps it in this pane's right column.
  const panelSession = snapshot.sessionId;
  const backgroundTabTitle = t("backgroundTasks.title");
  const openBackgroundHere = useCallback(() => {
    clearWorkflowSideTab();
    setBackgroundPanel((panel) => panel ?? { sessionId: panelSession, expanded: false, dismissed: new Set<string>() });
  }, [clearWorkflowSideTab, panelSession]);
  const openBackgroundPanel = useCallback(() => {
    if (ownBackgroundPane) return openBackgroundHere();
    void openBackgroundPane(callNative, backgroundTabTitle).then((opened) => {
      if (!opened) openBackgroundHere();
    });
  }, [ownBackgroundPane, openBackgroundHere, backgroundTabTitle]);
  // Session Info's Background tasks row: the panel, on that command's card (openBackgroundTasks.ts).
  // The request reaches the panel wherever it draws, this page or the chat's Background tasks tab.
  const openBackgroundTask = useCallback(
    (toolCallId: string) => {
      if (panelSession) requestBackgroundFocus(panelSession, toolCallId);
      openBackgroundPanel();
    },
    [panelSession, openBackgroundPanel],
  );
  const backgroundFocus = useBackgroundFocus(backgroundPanel ? panelSession : undefined);
  const closeWorkflowSideTab = useCallback(() => {
    workflowSideTabFocusOnClose.current = true;
    setWorkflowSideTabId(undefined);
  }, []);
  useLayoutEffect(() => {
    if (workflowSideTabId !== undefined) return;
    if (!workflowSideTabFocusOnClose.current) return;
    workflowSideTabFocusOnClose.current = false;
    const opener = workflowSideTabOpener.current;
    workflowSideTabOpener.current = undefined;
    if (opener && document.contains(opener)) focusRoute(opener, "system", "focus the opener back after a dialog");
  }, [workflowSideTabId]);
  useEffect(() => {
    clearWorkflowSideTab();
  }, [shownSessionId, workflowLabsEnabled, clearWorkflowSideTab]);
  // The rows the right-hand card reads (the Summary card and Session Info): the chat's rows as they
  // stood when the reader started scrolling, until the scroll settles (summary/heldWhileScrolling.ts;
  // Leo, 2026-10-25: "session summary on top right flickers when im scrolling thru the chat").
  const cardRows = useHeldWhileScrolling(snapshot.rows, shownSessionId);
  // Another chat, or the pane going, lets go of a scroll that has not settled yet.
  useEffect(() => releaseReaderScroll, [shownSessionId]);
  const cardSnapshot = useMemo(
    () => (cardRows === snapshot.rows ? snapshot : { ...snapshot, rows: cardRows }),
    [snapshot, cardRows],
  );
  const sessionInfoSnapshot = useMemo(() => {
    const summary = withCloudMachineSummary(cardSnapshot.summary, cloudMachineID);
    return summary === cardSnapshot.summary ? cardSnapshot : { ...cardSnapshot, summary };
  }, [cardSnapshot, cloudMachineID]);
  const cloudRouteHostKind = cloudMachineID ? "cloud" : snapshot.summary?.hostKind;
  const summaryHasContent = useMemo(
    () => chatHasSummaryContent(cardRows) || chatSubsessions.rows.length > 0 || workflows.length > 0,
    [cardRows, chatSubsessions, workflows],
  );
  const [shell, setShell] = useState<HTMLElement | null>(null);
  /// The chat's bottom stack (bottomStack.css): the transcript runs under it and keeps its end above it.
  const [dock, setDock] = useState<HTMLElement | null>(null);
  // The app's toasts lift above this stack; they never move it (toastAvoidance.ts).
  useEffect(() => (dock ? reportToastAvoidance(dock) : undefined), [dock]);
  // A focused composer lifts the edge of every part of the stack (composerStates.css): the dock's
  // `data-focused`, written as the composer reports focus-visible in its card while its prompt is not
  // the shell's (Composer.tsx `onFocusEdge`), never a `.acpmux-dock:has(... :focus-visible)` checked
  // again for every node a keystroke or a streamed chunk inserts (transcript-motion-model step 7).
  const dockLit = useRef(false);
  const dockNow = useRef<HTMLElement | null>(null);
  const markDockEdge = useCallback((lit: boolean) => {
    dockLit.current = lit;
    dockNow.current?.toggleAttribute("data-focused", lit);
  }, []);
  useLayoutEffect(() => {
    dockNow.current = dock;
    dock?.toggleAttribute("data-focused", dockLit.current);
  }, [dock]);
  // A chat whose agent started others has something to show too: their rows under Subagents.
  const summaryCard = useSummaryCard(
    // The side panel and Background tasks take the right column: the Summary stays a popover then.
    useSummaryColumn(shell, artifact !== undefined || backgroundPanel !== undefined || freshView),
    summaryHasContent || childSessions.length > 0,
  );
  // Another chat closes the subagent view in the render that shows it, not an effect later (which
  // drew one frame of the old subagent id against the new chat's rows: an empty child view).
  const [subagentChat, setSubagentChat] = useState(shownSessionId);
  // The groups opened on their own, each once: a group the person closes stays closed.
  const [openedGroups, setOpenedGroups] = useState<ReadonlySet<string>>(() => new Set());
  // The open folds are each chat's own (row ids such as `subagents-<seq>` repeat across chats):
  // the chats shown before keep theirs here for a switch back.
  const [chatFolds, setChatFolds] = useState<
    ReadonlyMap<
      string,
      {
        expanded: Set<string>;
        opened: ReadonlySet<string>;
        viewToggles: ReadonlyMap<TranscriptView, ReadonlySet<string>>;
      }
    >
  >(() => new Map());
  if (subagentChat !== shownSessionId) {
    setSubagentChat(shownSessionId);
    setSubagentView(undefined);
    const kept = shownSessionId === undefined ? undefined : chatFolds.get(shownSessionId);
    if (subagentChat !== undefined)
      setChatFolds(new Map(chatFolds).set(subagentChat, { expanded, opened: openedGroups, viewToggles }));
    setExpanded(kept?.expanded ?? new Set());
    setViewToggles(kept?.viewToggles ?? new Map());
    setOpenedGroups(kept?.opened ?? new Set());
  }
  // A page built again after a hidden release opens its chat's folds as they were left (wake `folds`).
  const [wokenFolds, setWokenFolds] = useState<{ session: string; folds: PaneFolds } | undefined>(undefined);
  if (wokenFolds && shownSessionId !== undefined && subagentChat === shownSessionId) {
    setWokenFolds(undefined);
    if (wokenFolds.session === shownSessionId) {
      setExpanded(new Set([...wokenFolds.folds.expanded, ...expanded]));
      setOpenedGroups(new Set([...wokenFolds.folds.opened, ...openedGroups]));
      if (viewToggles.size === 0) setViewToggles(wokenFolds.folds.viewToggles);
    }
  }
  const foldsNow = useRef<{ session?: string } & PaneFolds>({ expanded, opened: openedGroups, viewToggles });
  foldsNow.current = { session: shownSessionId, expanded, opened: openedGroups, viewToggles };
  // A group of subagents starts open while its agents run in the working turn, in the render that
  // first draws it (an agent a cancel or a reconnect left "running" in an earlier turn opens none).
  const liveGroups = useMemo(
    () => (snapshot.isWorking ? runningGroups(snapshot.rows, snapshot.subagentViews) : []),
    [snapshot.isWorking, snapshot.rows, snapshot.subagentViews],
  );
  const newGroups = subagentChat === shownSessionId ? liveGroups.filter((id) => !openedGroups.has(id)) : [];
  if (newGroups.length > 0) {
    setOpenedGroups(new Set([...openedGroups, ...newGroups]));
    setExpanded((current) => new Set([...current, ...newGroups]));
  }
  // After the reset above: a pane opened on a subagent shows it once its chat is shown, in the render
  // that first shows the chat (not an effect after it), so no frame draws the chat's rows first.
  if (requestedSubagent && shownSessionId && subagentChat === shownSessionId) {
    setSubagentView(requestedSubagent);
    setRequestedSubagent(undefined);
  }
  // A subagent's pane shows the subagent with the composer relayed to it (Composer.tsx `relay`),
  // never the chat's queue, pull request or turn controls: they are the chat's. Once it shows a chat ("Subagent of", a branch pill, another
  // harness), that chat's composer is back: a prompt there goes to the chat it shows.
  const readOnlySubagent =
    workflowRequest !== undefined ||
    (ownSubagentPane && (subagentView !== undefined || requestedSubagent !== undefined));
  // Find in Chat over the transcript (ChatFindScope, below the pane); the page actions read it
  // through `findRef`.
  const findRef = useRef<ChatFind | undefined>(undefined);
  const openFold = useCallback((fold: string) => {
    const view = chatViewRef.current;
    // Thinking and Verbose open a turn's fold unless the reader closed it there: forget that close.
    if (view !== "normal" && isWorkedFold(fold))
      setViewToggles((current) => {
        const toggled = current.get(view);
        if (!toggled) return current;
        const next = openViewTurnFold(turnRowsRef.current, toggled, fold);
        return next === toggled ? current : new Map(current).set(view, next);
      });
    else setExpanded((current) => (current.has(fold) ? current : new Set(current).add(fold)));
  }, []);
  // The folds a turn's end held open (turnRowsShown) become the reader's own open folds before the
  // frame paints, so they close only when the reader closes them.
  useLayoutEffect(() => {
    const { keys } = heldFolds.current;
    if (keys.size === 0) return;
    heldFolds.current = { session: heldFolds.current.session, keys: new Set() };
    for (const key of keys) openFold(key);
  });
  // A turn's "Worked for" is always closed when the turn ends, whatever opened it (Lucas, 2026-11-11:
  // "the Worked for should ALWAYS collapse when the turn has ended"): on the shown chat's step from
  // working to idle, its last turn's keys leave the open folds. The reader can open it again after.
  // Adjusted in render, as a chat switch is above: no extra frame. The lines the reader opened in it
  // are forgotten in a layout effect, before the frame paints (`closedTurn`).
  const [closedTurn, setClosedTurn] = useState<{ session?: string; key: string; rows: readonly AcpmuxRow[] }>();
  useLayoutEffect(() => {
    if (!closedTurn) return;
    // Every key names the same turn (its prompt's and each steer's): resolved once, by its last key.
    const edits = new Set<string>();
    forgetInsideTurn(closedTurn.session, turnInsideIds(closedTurn.rows, closedTurn.key, edits), edits);
  }, [closedTurn]);
  const [workingSeen, setWorkingSeen] = useState<{ session?: string; working: boolean }>({ working: false });
  if (workingSeen.session !== shownSessionId || workingSeen.working !== snapshot.isWorking) {
    const ended = workingSeen.session === shownSessionId && workingSeen.working && !snapshot.isWorking;
    setWorkingSeen({ session: shownSessionId, working: snapshot.isWorking });
    const keys = ended ? lastTurnWorkedKeys(snapshot.rows) : [];
    // What the reader opened while it ran closes with it, once this render is done (the store tells
    // the rows, which may not update while the pane draws).
    if (keys.length) setClosedTurn({ session: shownSessionId, key: keys.at(-1)!, rows: snapshot.rows });
    if (keys.some((key) => expanded.has(key))) {
      const next = new Set(expanded);
      for (const key of keys) next.delete(key);
      setExpanded(next);
    }
  }
  const [inspectorOpen, setInspectorOpen] = useState(false);
  // Jump to latest shows over the stage's foot (VirtualTranscript): the bottom toast deck stands above
  // it while it does (toastLayer.css), so a toast never covers the button or takes its clicks. Written
  // straight onto the pane's main element, never pane state: the button comes and goes as the reader
  // scrolls, and a pane render per scroll would draw Session Info and the rest again.
  const paneMain = useRef<HTMLDivElement | null>(null);
  const jumpLatestShown = useRef(false);
  const jumpLatestUnderInspector = useRef(false);
  const markJumpLatest = useCallback(() => {
    paneMain.current?.toggleAttribute("data-jump-latest", jumpLatestShown.current && !jumpLatestUnderInspector.current);
  }, []);
  const setJumpLatestShown = useCallback(
    (shown: boolean) => {
      jumpLatestShown.current = shown;
      markJumpLatest();
    },
    [markJumpLatest],
  );
  const setPaneMain = useCallback(
    (element: HTMLDivElement | null) => {
      paneMain.current = element;
      markJumpLatest();
    },
    [markJumpLatest],
  );
  // The ··· menu's Text & Width popover (ChatDisplaySettings.tsx), anchored to the menu button.
  const [displayAnchor, setDisplayAnchor] = useState<HTMLElement | null>(null);
  const [deleteConfirmOpen, setDeleteConfirmOpen] = useState(false);
  const [deleteConfirmSession, setDeleteConfirmSession] = useState<string>();
  const deleteInFlight = useRef<{ target: string; client: AcpmuxDirectClient; harness?: string }>(undefined);
  const inspectorOpener = useRef<HTMLElement | undefined>(undefined);
  const inspectorOpenRef = useRef(false);
  const inspectorHiddenSurfaceRef = useRef(false);
  const closeInspector = useCallback(() => {
    inspectorOpenRef.current = false;
    setInspectorOpen(false);
  }, []);
  useLayoutEffect(() => {
    jumpLatestUnderInspector.current = inspectorOpen;
    markJumpLatest();
  }, [inspectorOpen, markJumpLatest]);
  useLayoutEffect(() => {
    if (inspectorOpen || !inspectorOpener.current) return;
    focusRoute(inspectorOpener.current, "system", "the inspector closed: its opener");
    inspectorOpener.current = undefined;
  }, [inspectorOpen]);
  const toggleInspector = useCallback(
    (open?: boolean) => {
      if (inspectorHiddenSurfaceRef.current) {
        inspectorOpenRef.current = false;
        setInspectorOpen(false);
        return false;
      }
      const next = typeof open === "boolean" ? open : !inspectorOpenRef.current;
      inspectorOpenRef.current = next;
      if (next) {
        clearWorkflowSideTab();
        inspectorOpener.current ??= document.activeElement instanceof HTMLElement ? document.activeElement : undefined;
      }
      setInspectorOpen(next);
      return next;
    },
    [clearWorkflowSideTab],
  );
  const sessionIdRef = useRef(snapshot.sessionId);
  sessionIdRef.current = snapshot.sessionId;
  // The chat part of its subagents' draft keys (subagents/subagentDrafts.ts), for the wake state.
  const subagentDraftChat = shownSessionId ?? chatName;
  const subagentDraftChatRef = useRef(subagentDraftChat);
  subagentDraftChatRef.current = subagentDraftChat;
  /// Opens the turn's changes in a diff tab right of the chat, as the header's Changes does
  /// (Lawrence 2026-10-13: "when i click diff viewer it opens in new pane to right, not in a split in
  /// same webpage"; Leo, 2026-11-03: "just put it in a tab???"): the chat folder's diff, on the chat's
  /// machine, or for a folder outside a repository and a turn that changed a file outside it, which
  /// the folder's diff does not hold, the turn's own patch (turnChanges/viewChanges.ts). The diff
  /// never opens over the chat in this page (Lawrence 2026-11-03: "get rid of legacy code that opens
  /// in same webview as split"); where the turn holds nothing a diff can show, nothing opens. Quick
  /// Chat's panel moves the chat into the main window first. Set below, once the header's actions exist.
  const diffBeside = useRef<(rowId: string, path?: string, mode?: QuickActionMode) => Promise<boolean>>(
    async () => false,
  );
  /// The header's Changes, opened (not toggled): the palette's Commit and Push land in its diff tab.
  const openChangesTab = useRef<() => void>(() => undefined);
  const openDiff = useCallback<OpenDiff>((rowId, path) => {
    void diffBeside.current(rowId, path).catch(() => false);
  }, []);
  // An output in the summary opens the changes of the last turn that wrote it, under any of its
  // spellings, at that file.
  const openOutput = useCallback(
    (path: string) => {
      const change = lastChange(snapshot.rows, path);
      if (change) openDiff(change.rowId, change.path);
    },
    [snapshot.rows, openDiff],
  );
  // The Inspector's Background tasks and Servers read acpmux's process registry through the pane's
  // client. A reconnect makes a new client, so the source changes with it and they list again.
  const [clientEpoch, setClientEpoch] = useState(0);
  const [folderContinuation] = useState(() => new FolderContinuation());
  // The next new chat's extra folders reach the client that starts it (a reconnect makes a new one).
  // The composer names the pane's own Cloud or peer machine by its name; a start there names no peer,
  // so the client knows it as `local` (ownMachineFolders).
  const paneMachine =
    snapshot.summary?.peer || (snapshot.summary?.hostKind === "cloud" && snapshot.summary.host) || "local";
  // Only a start here takes them: a Cloud or Sandboxed start carries no extra folders (cmux#34403).
  const extraFoldersSent = sandbox.mode === "persistent" ? extraFolderDraft : undefined;
  useEffect(() => {
    directClient.current?.setNewChatFolders(ownMachineFolders(extraFoldersSent, paneMachine));
  }, [extraFoldersSent, paneMachine, clientEpoch]);
  const continuationProject = useRef(projectDraft);
  const continuationProjectGeneration = useRef(0);
  useLayoutEffect(() => {
    if (continuationProject.current !== projectDraft) continuationProjectGeneration.current += 1;
    continuationProject.current = projectDraft;
  }, [projectDraft]);
  // Session changes are fenced by the live client generation, including before React renders.
  // Invalidating on snapshot.sessionId would also cancel recovery on its own destination render.
  useLayoutEffect(() => {
    folderContinuation.invalidate();
    return () => folderContinuation.invalidate();
  }, [folderContinuation, projectDraft, clientEpoch]);

  const processSource = useMemo<ProcessSource>(
    () => ({
      listProcesses: (sessionId, recent, endedWithin) =>
        directClient.current?.listProcesses(sessionId, recent, endedWithin) ?? Promise.reject(new Error()),
      listProcessCalls: (sessionId, calls) =>
        directClient.current?.listProcessCalls(sessionId, calls) ?? Promise.reject(new Error()),
      watchProcesses: (listener) => directClient.current?.watchProcesses(listener) ?? (() => undefined),
    }),
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new client is a new source
    [clientEpoch],
  );
  const stopProcess = useCallback(
    (id: string) => directClient.current?.killProcess(id) ?? Promise.reject(new Error()),
    [],
  );
  // The Inspector's running-limit stepper (session-info/SubagentLimitStepper.tsx).
  const setRunningLimit = useCallback(
    (sessionId: string, maxRunning: number | null, from?: number) =>
      directClient.current?.setRunningLimit(sessionId, maxRunning, from) ?? Promise.reject(new Error()),
    [],
  );
  const reconnectMcp = useCallback(
    (server: string) => directClient.current?.reconnectMcp(server) ?? Promise.reject(new Error()),
    [],
  );
  // Session Info shows: every listed chat's usage is read now (direct.ts `refreshUsage`).
  const refreshUsage = useCallback(() => directClient.current?.refreshUsage(), []);
  // Session Info's Changes row reads the folder's git changes (session-info/changeCounts.ts).
  const readLiveTree = useCallback(
    () =>
      snapshot.sessionId
        ? (directClient.current?.liveTreeStatus(snapshot.sessionId) ?? Promise.resolve(undefined))
        : Promise.resolve(undefined),
    [snapshot.sessionId],
  );
  const readChanges = useCallback(
    (scope: string) => directClient.current?.gitDiffCounts(scope) ?? Promise.reject(new Error()),
    [],
  );
  const reconnectPeer = useCallback(
    (peer: string) => directClient.current?.reconnectPeer(peer) ?? Promise.reject(new Error()),
    [],
  );
  // An opened background task note reads the end of the task's output from the same registry
  // (conversation/backgroundTaskOutput.ts), once, when it opens.
  const backgroundTaskOutput = useMemo<BackgroundTaskOutputReader | undefined>(
    () =>
      shownSessionId
        ? {
            sessionId: shownSessionId,
            source: {
              listProcesses: processSource.listProcesses,
              tailProcess: (processId, maxBytes) =>
                directClient.current?.tailProcess(processId, maxBytes) ?? Promise.reject(new Error()),
              tailTask: (taskId, maxBytes) =>
                directClient.current?.bgTail(shownSessionId, taskId, maxBytes) ?? Promise.reject(new Error()),
            },
          }
        : undefined,
    [processSource, shownSessionId],
  );
  // The chat's background commands (session-info/processes.ts `backgroundCommands`): the transcript's
  // still running, and the registry's, read while the Inspector or the summary card shows, a turn
  // runs or a command is known to run (the hook stays on while one it knows runs, so its end
  // arrives). The one registry for the pane: the Inspector, the card, the tray and the counts all
  // read it. The tray shows a registry command between turns while the hook knows it runs; a quiet
  // chat sends no `_acpmux/process/list`.
  // The same pass finds what Session Info's Background tasks lists (the palette's Show Background Tasks).
  const transcriptWork = useMemo(() => transcriptBackground(snapshot.rows), [snapshot.rows]);
  const transcriptTasks = transcriptWork.tasks;
  const transcriptRunning = useMemo(
    () => transcriptTasks.filter((task) => task.state === "running"),
    [transcriptTasks],
  );
  const sessionInfoOn = useHeaderState().sessionInfo;
  // A pane opened beside another chat (a subagent's pane, a chat its agent started) has Session Info
  // of its own, closed until the person opens it there (sessionInfoState.ts `sessionInfoPaneKey`).
  const shownEntry = shownSessionId ? findSession(snapshot.sessions ?? [], shownSessionId) : undefined;
  const sessionInfoSplit = ownSubagentPane || !!(shownEntry?.startedBy || shownEntry?.spawnedBy);
  const sessionInfoOpened = useSessionInfoOpen(sessionInfoPaneKey(shownSessionId, sessionInfoSplit));
  // A subagent view's own records when the pane read them (`needsOwnLog`) and they hold more than
  // the chat's page.
  const scopedRows = useMemo(() => {
    if (shownSubagent === undefined) return undefined;
    const fromChat = snapshot.subagentViews?.[shownSubagent];
    const fromOwn = shownSubagent === subagentView ? ownLogged?.views[shownSubagent] : undefined;
    return (fromOwn?.length ?? 0) > (fromChat?.length ?? 0) ? fromOwn : fromChat;
  }, [shownSubagent, snapshot.subagentViews, subagentView, ownLogged]);
  // The whole history is read only while a list of it shows: Session Info, the Background tasks
  // panel, or the summary card, which lists every task while Session Info is off (SummaryTasks.tsx).
  const wholeProcessList =
    (sessionInfoOn && sessionInfoOpened) || backgroundOpen || (!sessionInfoOn && summaryCard.shown);
  // Otherwise the registry holds the running processes, the ones that ended last or within the
  // tray's linger (with a minute for the clocks, subagents/trayLinger.ts), and those of every call
  // the transcript's tasks and a subagent view's rows name, so the tray, the running line and the
  // counts (`backgroundRows`, with `omitted`) are the whole history's (session-info/processes.ts
  // `RegistryWindow`).
  const registryCalls = useMemo(() => {
    const calls = new Set(transcriptTasks.map((task) => task.id));
    if (scopedRows) for (const call of callIds(scopedRows)) calls.add(call);
    return [...calls];
  }, [transcriptTasks, scopedRows]);
  const registryWindow = useMemo(
    () => (wholeProcessList ? undefined : { calls: registryCalls, endedWithin: TRAY_LINGER_MS + 60_000 }),
    [wholeProcessList, registryCalls],
  );
  const processRegistry = useProcessRegistry(
    processSource,
    shownSessionId,
    (sessionInfoOn && sessionInfoOpened) ||
      summaryCard.shown ||
      backgroundOpen ||
      snapshot.isWorking ||
      transcriptRunning.length > 0,
    registryWindow,
  );
  const runningCommandList = useMemo(
    () =>
      backgroundCommands(processRegistry.processes, transcriptRunning, processRegistry.listed).filter(
        (command) => command.state === "running",
      ),
    [processRegistry, transcriptRunning],
  );
  const cardBackground = useMemo(
    () => ({ ...processRegistry, running: transcriptRunning, onStop: stopProcess }),
    [processRegistry, transcriptRunning, stopProcess],
  );
  const runningChildSessions = useMemo(
    () => childSessions.filter((child) => child.state === "running"),
    [childSessions],
  );
  const cardSessions = useMemo(() => ({ list: childSessions, onOpen: openOfferChat }), [childSessions]);
  // The Background tasks panel's commands, the ended ones too, and its groups: only while it is open.
  const panelCommands = useMemo(
    () =>
      backgroundOpen ? backgroundCommands(processRegistry.processes, transcriptTasks, processRegistry.listed) : [],
    [backgroundOpen, processRegistry, transcriptTasks],
  );
  const backgroundDismissed = backgroundPanel?.dismissed;
  const backgroundList = useMemo(
    () =>
      backgroundOpen
        ? backgroundGroups(
            {
              rows: snapshot.rows,
              views: snapshot.subagentViews,
              commands: panelCommands,
              sessions: childSessions,
              chatName,
              sessionId: shownSessionId,
              dismissed: backgroundDismissed,
            },
            backgroundCache.current,
          )
        : [],
    [
      backgroundOpen,
      snapshot.rows,
      snapshot.subagentViews,
      panelCommands,
      childSessions,
      chatName,
      shownSessionId,
      backgroundDismissed,
    ],
  );
  // A workflow agent's transcript in the panel reads as the workflow pane's does (Labs only).
  const backgroundWorkflowReads = useMemo(
    () =>
      workflowLabsEnabled
        ? { sessionId: shownSessionId, chat: chatName, connection: snapshot.connection, read: readWorkflowAgent }
        : undefined,
    [workflowLabsEnabled, shownSessionId, chatName, snapshot.connection, readWorkflowAgent],
  );
  // Hunk decisions outlive the view, so reopening a turn shows what was already decided.
  const [hunkDecisions, setHunkDecisions] = useState<ReadonlyMap<string, HunkDecision>>(() => new Map());
  const hunkReview = useMemo<HunkReview>(() => {
    const mark = (keys: string[], decision: HunkDecision, only?: HunkDecision) =>
      setHunkDecisions((current) => {
        const next = new Map(current);
        for (const key of keys) if (!only || next.get(key) === only) next.set(key, decision);
        return next;
      });
    return {
      decisions: hunkDecisions,
      decide: (key, decision) =>
        setHunkDecisions((current) => {
          const next = new Map(current);
          if (decision) next.set(key, decision);
          else next.delete(key);
          return next;
        }),
      requestRevert: (keys, prompt) => {
        const previous = keys.map((key) => [key, hunkDecisions.get(key)] as const);
        mark(keys, "requested");
        callNative("chat.send", { text: prompt }).catch(() =>
          setHunkDecisions((current) => restoredDecisions(current, previous)),
        );
      },
    };
  }, [hunkDecisions]);
  // Tool call ids belong to one session.
  useEffect(() => setHunkDecisions((current) => (current.size ? new Map() : current)), [snapshot.sessionId]);
  useEffect(() => setStatusCardOpen(false), [snapshot.sessionId]);
  // The first open after a launch: acpmux has not listed its harnesses yet, so none is missing yet.
  const harnessesChecking = useIsFetching({ queryKey: ["acpmux", "harnesses"] }) > 0 && snapshot.catalog.length === 0;
  // Add harness (cx-uj5g8): the Harnesses page, in place of what the pane shows.
  const [harnessesOpen, setHarnessesOpen] = useState(false);
  const setupContinuation = useRef<((harness: string) => void) | undefined>(undefined);
  const setupStart = useRef<{ harness: string; resume: (harness: string) => void } | undefined>(undefined);
  // Session Info's View Prompt: the Context screen (context/ContextScreen.tsx), in place of the chat.
  const [contextOpen, setContextOpen] = useState(false);
  // Another chat in this pane (the sidebar, a link) shows that chat, not the page.
  useEffect(() => {
    setupContinuation.current = undefined;
    setupStart.current = undefined;
    setHarnessesOpen(false);
    setContextOpen(false);
  }, [snapshot.sessionId]);
  useEffect(() => {
    if (harnessesOpen) return;
    const start = setupStart.current;
    setupStart.current = undefined;
    // Child effects reconnect first, including the attachment waiter's scope effect. Queueing
    // the send before revealing Activity would let that effect discard the pending send.
    start?.resume(start.harness);
  }, [harnessesOpen]);
  // A chat it starts, and a login it runs, go to the chat's folder (a new chat's start folder).
  const harnessFolder = snapshot.summary?.cwd ?? startFolder;
  const retryHarness = pickerCatalog.harnesses.find(
    (entry) => entry.acpmuxHarness === snapshot.summary?.harness || entry.id === snapshot.summary?.harness,
  );
  const runningModel = snapshot.summary?.model;
  const hasRunningModel = typeof runningModel === "string" && runningModel.length > 0;
  // Named as the composer's picker names them (its short name under its harness, "Opus 5.5").
  const retryModelsKey = (retryHarness?.models ?? [])
    .filter(
      (model) =>
        (!model.unavailable || (hasRunningModel && (model.id === runningModel || model.release === runningModel))) &&
        !isDefaultChoice(model),
    )
    .map(
      (model) =>
        `${model.id}\t${model.shortName || model.name || model.id}\t${model.release ?? ""}\t${model.family ?? ""}`,
    )
    .join("\n");
  const retryHarnessName = retryHarness?.name;
  const retryTop = retryHarness?.topModels;
  const retryModels = useMemo(
    () =>
      retryModelsKey
        ? retryModelsKey.split("\n").map((line) => {
            const [id = "", name = "", release = "", family = ""] = line.split("\t");
            return { id, name: name || id, ...(release ? { release } : {}), ...(family ? { family } : {}) };
          })
        : [],
    [retryModelsKey],
  );
  // Retry sends the turn's prompt as the composer would; a failed send shows in the transcript.
  // A prompt's versions (cx-ncc.61), kept the same map while they stay the same.
  const versionsKey = branchesKey(
    messageBranches(
      snapshot.summary?.sessionId,
      snapshot.rows,
      snapshot.sessions,
      snapshot.forkedAtSeq,
      !snapshot.canLoadOlder,
    ),
  );
  const stableBranches = useMemo(() => branchesFromKey(versionsKey), [versionsKey]);
  // Which of the chats a prompt's versions open are working (UserBubble.tsx's spinner). Only those:
  // every other chat starting or ending a turn (a sub-session, a lane) would make a new set, and
  // with it new turn actions, which every received card and bubble reads and so draws again for.
  // The same set while its members are the same.
  const lastRunningBranches = useRef<ReadonlySet<string>>(NO_SESSION_IDS);
  const runningBranchSessions = useMemo(() => {
    if (stableBranches.size === 0) return (lastRunningBranches.current = NO_SESSION_IDS);
    const versions = new Set<string>();
    for (const branch of stableBranches.values()) for (const id of branch.sessions) versions.add(id);
    const running = new Set(
      snapshot.sessions
        .filter(
          (entry) =>
            versions.has(entry.sessionId) &&
            (entry.lane === "working" || entry.indicator === "working" || entry.status === "running"),
        )
        .map((entry) => entry.sessionId),
    );
    const last = lastRunningBranches.current;
    if (running.size === last.size && [...running].every((id) => last.has(id))) return last;
    return (lastRunningBranches.current = running);
  }, [snapshot.sessions, stableBranches]);
  const restartChat = restartOwner({
    connected,
    sessionId: snapshot.sessionId,
    watching: Boolean(snapshot.summary?.watching),
    readOnly: readOnlySubagent,
    canSend: remoteComposer(snapshot).canSend,
  });
  // The questions waiting on the person, in the composer hat (question/hatModel.ts): this chat's
  // own, the tagged ask its last turn ended on, and those of the chats it started. The list keeps its
  // identity while it draws the same, so a streamed chunk never redraws the hat.
  const hatQuestionsKept = useRef<readonly HatQuestion[]>(NO_HAT_QUESTIONS);
  const hatQuestionsRead = useMemo(
    () =>
      childRows || quick
        ? NO_HAT_QUESTIONS
        : hatQuestions({
            ...(shownSessionId ? { sessionId: shownSessionId } : {}),
            ...(individualPermission ? { permission: individualPermission } : {}),
            ...(snapshot.permissionsQueued ? { queued: snapshot.permissionsQueued } : {}),
            rows: chatPresentation === "messages" ? sourceRows : turnRowsShown,
            messages: chatPresentation === "messages",
            ...(restartChat ? { nextStepOwner: restartChat } : {}),
            sessions: snapshot.sessions,
            asks: snapshot.asks ?? [],
          }),
    [
      childRows,
      quick,
      shownSessionId,
      individualPermission,
      snapshot.permissionsQueued,
      chatPresentation,
      sourceRows,
      turnRowsShown,
      restartChat,
      snapshot.sessions,
      snapshot.asks,
    ],
  );
  // The ones the person put away (the hat's × or Escape, question/hatSeen.ts) leave it; they share
  // the pinned asks' dismissals, so a tagged ask put away in one place leaves both.
  // Nor the ones a card in the asks stack above it already shows (a pinned tagged ask, a
  // sub-session's ask): one ask renders once (question/hatSeen.ts `hatQuestionsShown`).
  const onStackCards = useMemo(() => stackCardKeys(pinnedAsks, childAsk), [pinnedAsks, childAsk]);
  const hatQuestionsUnseen = useMemo(
    () => hatQuestionsShown(hatQuestionsRead, askedAway, onStackCards),
    [hatQuestionsRead, askedAway, onStackCards],
  );
  const hatQuestionList = sameHatQuestions(hatQuestionsKept.current, hatQuestionsUnseen)
    ? hatQuestionsKept.current
    : (hatQuestionsKept.current = hatQuestionsUnseen);
  // Who asks in this chat: its agent by name, as the trust card names it. An answer to its ask
  // quotes the ask under this name (nextStepAsk.ts `answerPrompt`).
  const asker = snapshot.summary?.harness
    ? agentName(snapshot.summary.harness, catalog.find((entry) => entry.id === snapshot.summary?.harness)?.name)
    : undefined;
  const askerRef = useRef(asker);
  askerRef.current = asker;
  // The hat's × reaches the shown chat's dismissals; the ref follows it after each commit (never in render).
  const dismissPinnedAskRef = useRef(dismissPinnedAsk);
  useLayoutEffect(() => {
    dismissPinnedAskRef.current = dismissPinnedAsk;
  }, [dismissPinnedAsk]);
  const hatQuestionActions = useMemo(
    () =>
      hatActions(
        () => focusRoute(composerHandle.current, "system", "the composer, after a panel"),
        (owner) => restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession),
        () => askerRef.current,
        (question) => dismissPinnedAskRef.current(hatSeenKey(question)),
      ),
    [],
  );
  // A subagent's own pane sends to the chat, which passes the message on (subagents/subagentMessage.ts):
  // the chat Restart would send to, as the pane's composer reaches it.
  const subagentRelayChat = restartOwner({
    connected,
    sessionId: snapshot.sessionId,
    watching: Boolean(snapshot.summary?.watching),
    readOnly: false,
    canSend: remoteComposer(snapshot).canSend,
  });
  const shownSubagentId = subagentView ?? requestedSubagent;
  const shownSubagentTarget = useMemo(() => {
    if (!readOnlySubagent) return undefined;
    if (workflowRequest)
      return selectedWorkflowAgent && workflowAgentTarget(selectedWorkflowAgent, translate("tray.kind.subagent"));
    const agent = freshAgents.find((entry) => entry.id === shownSubagentId);
    return agent && subagentTarget(agent, snapshot.summary?.family ?? snapshot.summary?.harness?.split(/[-_/]/)[0]);
  }, [
    readOnlySubagent,
    workflowRequest,
    selectedWorkflowAgent,
    freshAgents,
    shownSubagentId,
    snapshot.summary?.family,
    snapshot.summary?.harness,
  ]);
  // Only to the chat the pane shows and the client has selected, and only once the pane knows which
  // subagent it is for: a prompt never goes to a target the composer does not name.
  const relaySteers = subagentRelaySteers(snapshot);
  const sendToSubagent =
    subagentRelayChat && shownSubagentTarget
      ? ((owner: string, target: NonNullable<typeof shownSubagentTarget>) => (message: string) => {
          if (!restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession))
            return Promise.reject(new Error(translate("error.notOpen")));
          // A steer only into a running turn (subagentRelaySteers), else a prompt of its own. A refusal
          // the chat keeps as a row of its own (Retry, Edit) stays there, never also back in this composer.
          // It settles once the chat took the message (`accepted`), not when the turn ends: from then the
          // chat holds it, and the composer no longer keeps it as in flight (subagentDrafts.ts).
          return new Promise<void>((resolve, reject) => {
            callNative("chat.send", {
              text: subagentRelayPrompt(target, message, translate),
              expectedSessionId: owner,
              steer: relaySteers,
              accepted: () => resolve(),
            }).then(
              () => resolve(),
              (error: unknown) => (keptInChat(error) ? resolve() : reject(error)),
            );
          });
        })(subagentRelayChat, shownSubagentTarget)
      : undefined;
  // Another agent's waiting message's ⋯ menu actions (conversation/QueuedMessageCard.tsx), made
  // below where the side chat is known; the cards read them as they draw.
  const queuedMessageActionsRef = useRef<QueuedMessageActionsValue | undefined>(undefined);
  // The chat's Codex skills, for its sent prompts' `/$name` (conversation/skillWords.ts).
  const skillWords = useSkillWords(snapshot.commands);
  const queueRunsNext = snapshot.queue.some((entry) => !entry.heldByStop && !entry.held && !entry.awaitingOwner);
  // The waiting tagged-ask card's first answer, which the composer's ⌘↩ on an empty prompt sends
  // (NextStepCard.tsx, TurnActions `nextStepKey`).
  const [nextStepFire, setNextStepFire] = useState<{ fire: () => void }>();
  const nextStepKey = useCallback((fire: () => void) => {
    setNextStepFire({ fire });
    return () => setNextStepFire((now) => (now?.fire === fire ? undefined : now));
  }, []);
  // A background command's Bash call in the transcript (`showToolRow` below, which needs what the
  // Inspector draws): what its task row opens where its terminal cannot (a peer's or Cloud chat),
  // and a turn's waterfall bar opens (conversation/TurnWaterfall.tsx).
  const showCallRef = useRef<(toolCallId: string, startedAt?: number) => boolean>(() => false);
  const showCall = useCallback(
    (toolCallId: string, startedAt?: number) => showCallRef.current(toolCallId, startedAt),
    [],
  );
  // A chat on another machine (a Cloud one, a peer, or the machine the app's wire reaches) signs its
  // agent in there with the one-click card, never a terminal with the login command (Leo 2026-11-14:
  // "and how are the ergonomics of cmux remote tho esp in the gui?").
  const chatElsewhere =
    cloudMachineID !== undefined ||
    chatMachineOf(snapshot.summary, undefined, snapshot.peerKinds, chatPlace(snapshot)).kind !== "local";
  // A Cloud chat's agent signs in on its own machine (Leo 2026-11-01: "yes those are
  // important"): its own login, never this Mac's. Its page opens as a link click does here.
  // A chat here whose built-in Claude Code or Codex is not signed in offers Use an API key
  // (Leo 2026-10-26: "if user picks a model they don't have api key, we offer them to add
  // credits or add their own api key").
  const chatSignIns = useMemo(() => {
    const login: Parameters<typeof cloudAgentLogin>[0] = {
      connected,
      machineID: cloudMachineID,
      elsewhere: chatElsewhere,
      sessionId: snapshot.sessionId,
      harness: snapshot.summary?.harness,
      supported: directClient.current?.supportsAgentLogin === true,
      gesture: (intent) =>
        postNative<{ ticket?: string }>("transport.gesture", { intent }).then((reply) => reply?.ticket),
      openURL: (url) => void callChipHost("browser.openIn", { url, browserId: "cmux" }),
      // Claude's automatic page in a Chromium tab whose localhost is the chat's machine
      // (AgentPaneSignInPage.swift); the host refuses where it cannot, and the card pastes instead.
      openOnMachine: (url) =>
        postNative("browser.openIn", { url, browserId: SIGN_IN_ON_MACHINE }).then(
          () => true,
          () => false,
        ),
      isCurrent: (owner) => restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession),
      currentClient: () => directClient.current ?? undefined,
    };
    // A local sign-in that went through reads the agent's health again, so its notice goes with it.
    const rechecked = (signIn: CloudSignIn | undefined): CloudSignIn | undefined =>
      signIn && {
        ...signIn,
        finish: (loginId, code) => signIn.finish(loginId, code).then((done) => (done && recheckHealth(), done)),
        apiKey: (key) => signIn.apiKey(key).then((saved) => (saved && recheckHealth(), saved)),
        gateway: () => signIn.gateway().then((used) => (used && recheckHealth(), used)),
      };
    // A start refused because its agent is not signed in on the machine (hq#11225): that agent's own
    // sign-in there, which the failed start's card leads with (SwitchNotice.tsx).
    const refused =
      snapshot.switching?.phase === "failed" && snapshot.switching.code === SIGN_IN_REQUIRED
        ? snapshot.switching.harness
        : undefined;
    return {
      cloudSignIn: cloudAgentLogin(login),
      apiKeySignIn: localApiKeyLogin(login),
      // A new chat has no session yet: its machine signs the agent in there with none, where its
      // daemon can (`agent_login_machine`); elsewhere the card says to sign in on that machine.
      refusedSignIn: refused
        ? cloudAgentLogin({
            ...login,
            harness: refused,
            machineLogin: directClient.current?.supportsMachineLogin === true,
          })
        : undefined,
      // Logins done right: the same card for an agent on this Mac (localAgentLogin), the refused
      // start's and the signed-out notice's (the composer's agent; its chat's when it is the chat's).
      localRefusedSignIn: refused
        ? rechecked(
            localAgentLogin({
              ...login,
              harness: refused,
              machineLogin: directClient.current?.supportsMachineLogin === true,
            }),
          )
        : undefined,
      healthSignIn:
        healthLocal && healthHarness
          ? rechecked(
              localAgentLogin({
                ...login,
                harness: healthHarness,
                sessionId: healthHarness === snapshot.summary?.harness ? snapshot.sessionId : undefined,
                machineLogin: directClient.current?.supportsMachineLogin === true,
              }),
            )
          : undefined,
    };
  }, [
    healthLocal,
    healthHarness,
    recheckHealth,
    connected,
    cloudMachineID,
    chatElsewhere,
    snapshot.sessionId,
    snapshot.summary?.harness,
    snapshot.switching?.phase,
    snapshot.switching?.code,
    snapshot.switching?.harness,
  ]);
  // Declared before the turn actions, which read them (pane/useTurnActions.ts `turnActionsFrom`).
  const composerHandle = useRef<ComposerHandle | null>(null);
  /// The newest snapshot, for host requests that read it (pane.context).
  const snapshotRef = useRef<AcpmuxSnapshot | undefined>(initialChat?.snapshot);
  const turnActions = useMemo<TurnActions>(
    () =>
      turnActionsFrom({
        showCall,
        restartChat,
        queuedMessageActionsRef,
        stableBranches,
        runningBranchSessions,
        turnForkable,
        forkAny,
        stablePromptSeqs,
        forkSeq,
        cloudMachineID,
        tryAnotherApproachInFlight,
        cloudTurnRewind,
        rewindReady,
        rewindInFlight,
        rewindRows,
        snapshotRef,
        setCloudTurnRewind,
        directClient,
        stableEditSeqs,
        connected,
        sessionIdRef,
        queueRunsNext,
        nextStepKey,
        asker,
        snapshot: {
          sessionId: snapshot.sessionId,
          commands: snapshot.commands,
          summary: {
            hostKind: snapshot.summary?.hostKind,
            cwd: snapshot.summary?.cwd,
            harness: snapshot.summary?.harness,
            model: snapshot.summary?.model,
            backgroundsWork: snapshot.summary?.backgroundsWork,
          },
        },
        subagentRelayChat,
        retryModels,
        retryHarnessName,
        retryTop,
        composerHandle,
        loginCommand,
        chatSignIns,
        hunkReview,
        catalog,
        cloudRouteHostKind,
        cloudTeamMachine,
        chatAccounts,
        access,
      }),
    [
      access,
      showCall,
      chatSignIns,
      chatAccounts,
      snapshot.sessionId,
      stableBranches,
      runningBranchSessions,
      turnForkable,
      forkSeq,
      forkAny,
      stablePromptSeqs,
      stableEditSeqs,
      connected,
      hunkReview,
      loginCommand,
      cloudMachineID,
      cloudTurnRewind,
      rewindRows,
      rewindReady,
      cloudRouteHostKind,
      cloudTeamMachine,
      snapshot.summary?.hostKind,
      snapshot.summary?.cwd,
      snapshot.summary?.harness,
      snapshot.summary?.model,
      snapshot.summary?.backgroundsWork,
      retryModels,
      retryHarnessName,
      retryTop,
      catalog,
      restartChat,
      subagentRelayChat,
      snapshot.commands,
      queueRunsNext,
      nextStepKey,
      asker,
    ],
  );
  // Each turn's checkpoint pair, named by the row that starts the turn: the checkpoints acpmux
  // recorded on its summary, diffed on the session host.
  const turnRowsRef = useRef(snapshot.rows);
  turnRowsRef.current = snapshot.rows;
  const shownSessionRef = useRef(shownSessionId);
  useLayoutEffect(() => {
    shownSessionRef.current = shownSessionId;
  }, [shownSessionId]);
  // The image viewer holds the chat's images from when it opened; another chat closes it.
  const [imageView, setImageView] = useState<{ images: ChatImage[]; index: number } | undefined>();
  const openImage = useCallback(
    (src: string, alt: string, path?: string) => setImageView(viewerImages(turnRowsRef.current, src, alt, path)),
    [],
  );
  useEffect(() => setImageView(undefined), [snapshot.sessionId]);
  // A queued prompt's image, read from acpmux by its id (ComposerQueue's thumbnails).
  const readQueuedImage = useCallback(
    (id: string) => directClient.current?.promptImage(id) ?? Promise.resolve(undefined),
    [],
  );
  const readTurn = useCallback(
    ({ rowId }: { rowId: string }) => readTurnFromRows(turnRowsRef.current, rowId, checkpointDiff),
    [],
  );
  // A turn's before and after picture of the chat's page (turnChanges/turnShots.ts), read once per
  // turn by the cards that draw. The reader is new when a turn ends, so a card whose turn just ended
  // reads its pair; the scan stops at the newest summary, a few rows from the end.
  const [turnShotCache] = useState(() => new TurnShotCache());
  const latestSummary = useMemo(() => {
    const rows = snapshot.rows;
    for (let at = rows.length - 1; at >= 0; at -= 1) if (rows[at]!.kind === "turnSummary") return rows[at]!.id;
    return undefined;
  }, [snapshot.rows]);
  const turnShots = useMemo<TurnShotsReader>(() => {
    const sessionId = snapshot.sessionId;
    const turnOf = (rowId: string) => (sessionId ? shotTurnId(turnRowsRef.current, rowId) : undefined);
    return {
      version: latestSummary,
      peek: (rowId) => {
        const turnId = turnOf(rowId);
        return turnId ? turnShotCache.peek(`${sessionId}\u0000${turnId}`) : {};
      },
      read: (rowId) => {
        const turnId = turnOf(rowId);
        if (!turnId) return Promise.resolve(undefined);
        return turnShotCache.read(
          `${sessionId}\u0000${turnId}`,
          () => directClient.current?.turnShots(turnId) ?? Promise.resolve(undefined),
        );
      },
    };
  }, [turnShotCache, latestSummary, snapshot.sessionId]);
  const turnCheckpoints = useTurnCheckpoints(readTurn, snapshot.sessionId);
  const { request: requestTurnCheckpoint, get: turnCheckpoint } = turnCheckpoints;
  const turnKey = useCallback((rowId: string) => turnRows(turnRowsRef.current, rowId)[0]?.id ?? rowId, []);
  // The latest edited-files card shows its turn's checkpoint counts once the turn has ended.
  const endedEditTurn = endedEditRow(marks);
  useEffect(() => {
    if (endedEditTurn) requestTurnCheckpoint(turnKey(endedEditTurn));
  }, [endedEditTurn, requestTurnCheckpoint, turnKey]);
  const turnCountsFor = useCallback<TurnCountsFor>(
    (rowId, toolFiles, pathsOnly) => turnCounts(toolFiles, turnCheckpoint(turnKey(rowId)), pathsOnly),
    [turnCheckpoint, turnKey],
  );
  // The header's Changes: the last turn that edited files, with its checkpoint's counts once loaded.
  const lastEdit = useRef<{ key: string; rowId: string; files: TurnFile[]; pathsOnly: PathRef[] }>(undefined);
  const lastEditTurn = useMemo(() => {
    const rows = snapshot.rows;
    let at = rows.length - 1;
    while (at >= 0 && rowKind(rows[at]!) !== "editedFiles") at -= 1;
    if (at < 0) return undefined;
    const edit = rows[at]!;
    // Its turn: from its prompt to the next one, past steers (diff.ts turnRows, from the index found here).
    let start = at;
    while (start > 0 && !opensTurn(rows[start]!)) start -= 1;
    let end = at + 1;
    while (end < rows.length && !opensTurn(rows[end]!)) end += 1;
    const activity = rows.slice(start, end).filter((row) => row.kind === "activity");
    // Keyed by the chat too: another chat's rows never read as this one's.
    const key = `${snapshot.sessionId}\u0000${edit.id}\u0000${activity.map((row) => `${row.id}:${row.version}`).join("|")}`;
    if (lastEdit.current?.key !== key)
      lastEdit.current = {
        key,
        rowId: edit.id,
        files: turnFiles(activity),
        pathsOnly: turnPathsOnly(activity),
      };
    return lastEdit.current;
  }, [snapshot.rows, snapshot.sessionId]);
  // Its files are the diff's own (the checkpoint's once loaded), so each opens at its file there.
  const lastChanges = useMemo(
    () => (lastEditTurn ? turnCountsFor(lastEditTurn.rowId, lastEditTurn.files, lastEditTurn.pathsOnly) : undefined),
    [lastEditTurn, turnCountsFor],
  );
  // The card's Changes reads the same history its rows do: an older edit paged in under the reader's
  // scroll lands there once the scroll settles too (summary/heldWhileScrolling.ts). Its turn is held
  // with it, so a click on a held file opens that turn's diff, not a newer one's.
  const liveCardEdit = useMemo(() => ({ turn: lastEditTurn, changes: lastChanges }), [lastEditTurn, lastChanges]);
  const cardEdit = useHeldWhileScrolling(liveCardEdit, shownSessionId);
  // The header's Preview: the local page of the latest of the last few turns that started or mentioned one.
  // Each turn is scanned again only when its rows change (a row is a new object when it changes), so
  // streaming rescans the live turn alone, and that reads only the texts that are new
  // (previewUrl.ts `turnPreviewUrl`).
  const previewTurns = useRef(new Map<string, { rows: readonly AcpmuxRow[]; url: string | undefined }>());
  const previewUrl = useMemo(() => {
    const rows = snapshot.rows;
    const seen = new Map<string, { rows: readonly AcpmuxRow[]; url: string | undefined }>();
    let found: string | undefined;
    let end = rows.length;
    for (let index = rows.length - 1, turns = 0; index >= 0 && turns < PREVIEW_TURNS && !found; index -= 1) {
      const user = rows[index];
      if (user.kind !== "user") continue;
      const turn = rows.slice(index, end);
      const cached = previewTurns.current.get(user.id);
      const entry =
        cached && cached.rows.length === turn.length && cached.rows.every((row, at) => row === turn[at])
          ? cached
          : { rows: turn, url: turnPreviewUrl(user, turn.slice(1)) };
      seen.set(user.id, entry);
      found = entry.url;
      end = index;
      turns += 1;
    }
    previewTurns.current = seen;
    return found;
  }, [snapshot.rows]);
  // The summary's Changes: the turn's diff, toggled; a file of it opens the diff at that file.
  const toggleLastChanges = (path?: string) => {
    const turn = cardEdit.turn;
    if (turn) openDiff(turn.rowId, path);
  };
  const [registry, setRegistry] = useState<NativeRegistry>(defaultRegistry);
  /// For a transcript that acts on nothing live (a replay, a read-only subagent's): its recaps draw
  /// no × (ReadOnlyRecapRow), its memory offers no Accept or Dismiss, its prompt coach card no ×, and its
  /// preset approvals no Approve or Not now.
  const noDismissRegistry = useMemo(
    () => ({
      ...registry,
      recap: ReadOnlyRecapRow,
      [MEMORY_OFFER]: ReadOnlyMemoryOfferRow,
      [PROMPT_COACH]: ReadOnlyPromptCoachRow,
      [PRESET_APPROVAL]: ReadOnlyPresetApprovalRow,
    }),
    [registry],
  );
  const [newTab, setNewTab] = useState<NewTabHost | undefined>(injectedNewTabContext);
  const [newTabFixError, setNewTabFixError] = useState<string>();
  const newTabStartGeneration = useRef(0);
  const [sessionSelection, setSessionSelection] = useState<
    { sessionId: string; state: "pending" | "failed" } | undefined
  >();
  const sessionSelectionToken = useRef(0);
  // Only a New Tab page posts the chats it hears for the next one (newtab/warmSnapshot.ts).
  const showsNewTabRef = useRef(newTab !== undefined);
  showsNewTabRef.current = newTab !== undefined;
  /// The New Tab context whose leftover the field already showed (``takeNewChatLeftover``).
  const leftoverShownFor = useRef<NewTabHost | undefined>(undefined);
  /// The New Tab field's text while it holds a leftover it showed, as edited since: what a pick
  /// from the page leaves again. undefined while the field holds no leftover (a query typed to
  /// find a chat is not left).
  const leftoverInField = useRef<string | undefined>(undefined);
  // A prewarmed spare page gets its real context when Cmd-T adopts it; the generation remounts the screen
  // unless the spare already draws that context (sameNewTabScreen).
  // The spare's own handshake named the spare's start folder: the adopting tab's folder replaces it
  // (the host names a folder below home, AgentPaneStartFolders), so Cmd-T on a spare names the tab's
  // project on its first frame instead of "Choose folder".
  const adoptNewTab = useCallback((host: NewTabHost) => {
    // The adopted tab's start is measured from its own first frame (perf.ts noteStartState).
    acpmuxPerf.resetStartState();
    newTabStartGeneration.current += 1;
    leftoverInField.current = undefined;
    setNewTabAdoptions((count) => count + 1);
    setNewTab(host);
    // The host's start for the adopting tab (its project, or none with Choose Folder…), as its
    // handshake would answer; an older host's context has none, and the tab's folder stands in.
    const start = startFromContext(host.start);
    if (start) {
      startedFromHint.current = start.projectDraft;
      setProjectDraft(start.projectDraft);
      setChooseFolder(start.chooseFolder);
      return;
    }
    const cwd = host.cwd;
    const named = cwd && !isAgentHome(cwd) && !/^\/(?:(?:Users|home)(?:\/[^/]+)?)?\/?$/.test(cwd) ? cwd : undefined;
    setProjectDraft(named);
  }, []);
  // The screen the page shows now: an adopt that draws the same one keeps it mounted (SHORTCUT FRAMES F2).
  const newTabNow = useRef(newTab);
  newTabNow.current = newTab;
  const currentNewTab = useCallback(() => newTabNow.current, []);
  const newTabGeneration = useNewTabAdoption(adoptNewTab, currentNewTab);
  // A Fix from a link's failure is that New Tab visit's: the next visit starts without it.
  useEffect(() => setNewTabFixError(undefined), [newTabGeneration]);
  // `tabs.newTabApp` (newtab/NewTabAppPage.tsx): the visit (adoption) whose app page could not show
  // draws cmux's own; the next Cmd-T tries the app again, also on a spare that keeps its screen.
  const [newTabAppGone, setNewTabAppGone] = useState<number>();
  // A start owns this visit's screen until accepted, even while a switch publishes queued rows.
  // A new adoption has a different generation and never inherits this pending/error view.
  const [newTabStartPage, setNewTabStartPage] = useState<number>();
  const newTabRetainsDraft = useRef(false);
  useNewTabPlaces(setNewTab);
  // Whether the page knows it is a New Tab page or a chat: the host's context came with the
  // document (WebKit), or its `newTab.context` answer did, either way. A Chromium page gets none
  // with the document, and its window shows over the pane before the host's alpha can hide it:
  // until then the page draws no chat screen (Lucas 2026-10-24: Cmd-T spam flashed it in New Tabs).
  const [contextKnown, setContextKnown] = useState(
    () => initialChat !== undefined || injectedNewTabContext() !== undefined,
  );
  const markContextKnown = useCallback(() => setContextKnown(true), []);
  // A context that came by `newTab.context` (not injected) carries the start too: drawn with it.
  const takeEarlyNewTab = useCallback((host: NewTabHost) => {
    setNewTab(host);
    const start = startFromContext(host.start);
    if (!start || handshakenRef.current) return;
    startedFromHint.current = start.projectDraft;
    setNewSession(start.newSession);
    setProjectDraft(start.projectDraft);
    setChooseFolder(start.chooseFolder);
  }, []);
  const earlyNewTab = useEarlyNewTabContext(callNative, takeEarlyNewTab, markContextKnown);
  // A context that came with no shared part while this document keeps none: asked again (newtab/sharedPart.ts).
  const checkSharedPart = useLostSharedPart(callNative, setNewTab);
  // Agent chats live in the window's one sidebar (Projects and Recents); the pane opens what it picks.
  const selectSession = useCallback((sessionId: string) => {
    newTabStartGeneration.current += 1;
    const token = ++sessionSelectionToken.current;
    setSessionSelection({ sessionId, state: "pending" });
    void callNative("chat.select", { sessionId }).then(
      (selected) => {
        if (sessionSelectionToken.current !== token) return;
        if (selected !== sessionId) {
          setSessionSelection({ sessionId, state: "failed" });
          return;
        }
        // Keep the New Tab mounted until the accepted selection has a matching attach summary.
        // This preserves its geometry during the hold and restores it on stale or malformed opens.
        setSessionSelection(undefined);
        setNewTab(undefined);
        setNewSession(false);
      },
      () => {
        if (sessionSelectionToken.current === token) setSessionSelection({ sessionId, state: "failed" });
      },
    );
  }, []);
  /// What the DEBUG automation verbs (automation.ts) read and run: this render's chat and the
  /// same selection and changes-view paths the sidebar and the edited-files card use.
  const automationView = useRef<{
    snapshot: AcpmuxSnapshot;
    selectSession: (sessionId: string) => void;
    openDiff: OpenDiff;
  }>(undefined);
  automationView.current = {
    snapshot,
    selectSession,
    openDiff,
  };
  // Show all chats opens the command palette's chats page (agentPane.searchChats, decision K1:
  // one palette). The host pushes the live bindings through applyShortcuts, so labels follow a rebind.
  const showAllChats = () =>
    void callNative("action.run", { id: "agentPane.searchChats" }).catch(sayActionRefusal(notices.transient));
  // The + menu's Search chats and Search pages (Leo: "the chatgpt desktop app, let's do their +
  // symbol's capabiliities for our composer"): the command palette's chats page and its History
  // search page, both app actions the pane may run (AgentPaneModel.paletteActions). A refusal is
  // said in a toast, never dropped.
  const plusSearchExtensions = useMemo(() => composerPlusSearchExtensions(t), [t]);
  const runPlusSearch = (id: string) => {
    const name = id === PLUS_SEARCH_ACTIONS.pages ? t("composer.plusSearchPages") : t("sidebar.search");
    void callNative("action.run", { id }).catch(
      sayActionRefusal(notices.transient, () => translate("composer.offloadNotRun", { action: name })),
    );
  };
  // New Tab shows no transcript, so the page says a refusal itself (NewTabScreen plusRefused).
  const runNewTabPlusSearch = (id: string) => callNative("action.run", { id });
  const [shortcuts, setShortcuts] = useState<ShortcutLabels>({});
  // SSH… opens Connect to Machine; New Cloud Machine opens the host's create flow (Lawrence 2026-10-06).
  const connectMachine = (kind: ConnectKind) =>
    void callNative("action.run", { id: CONNECT_ACTIONS[kind] }).catch(sayActionRefusal(notices.transient));
  // Move to Cloud and Bring Back Local report their own progress and failures as the app's toasts;
  // the pane's toast says why the app did not start the move (its reason: "Send a first message, then
  // move this chat."), or that it did not when it gave none (turned off).
  /// `session`, when given (the title menu), binds the move to the chat whose menu offered it: the
  /// host runs it only while the tab still shows that chat (AgentPaneModel+Actions.swift).
  const offloadChat = (kind: OffloadKind, session?: string) => {
    const notRunText = () =>
      translate("composer.offloadNotRun", {
        action: translate(kind === "move" ? "composer.moveToCloud" : "composer.bringBackLocal"),
      });
    if (session !== undefined && directClient.current?.selectedSession !== session) {
      notices.transient(notRunText());
      return;
    }
    void callNative("action.run", { id: CONNECT_ACTIONS[kind], ...(session !== undefined ? { session } : {}) }).catch(
      sayActionRefusal(notices.transient, notRunText),
    );
  };
  /// `session`: the chat whose title menu offered the move. The host moves the tab only while it
  /// still shows that chat (AgentTabs+Header.swift), so a switch before the request is handled
  /// never moves the newly selected chat.
  const moveChatToMachine = (machine: string, session: string | undefined) => {
    const notRunText = () => translate("composer.offloadNotRun", { action: translate("composer.moveToMenu") });
    if (!session || directClient.current?.selectedSession !== session) {
      notices.transient(notRunText());
      return;
    }
    void callNative("pane.moveToMachine", { machine, session }).catch(sayActionRefusal(notices.transient, notRunText));
  };
  const cloudPreviewTurnId = useMemo(() => {
    for (let index = snapshot.rows.length - 1; index >= 0; index -= 1) {
      const row = snapshot.rows[index];
      if (row?.turnId) return row.turnId;
      if (row?.kind === "user") return row.id;
    }
    return undefined;
  }, [snapshot.rows]);
  const cloudPreviewChat = snapshot.summary?.hostKind === "cloud" || cloudMachineID !== undefined;
  const cloudPreviewPortList = useCloudPreviewPorts();
  // Only a Cloud pane with a card to show gets an after-latest footer: an empty one would still
  // take the composer's room below the transcript and shorten it.
  const showOpenAppCard = !quick && cloudPreviewChat && cloudPreviewPortList.length > 0;
  useEffect(() => {
    const machineID = cloudMachineID ?? snapshot.summary?.machine;
    setCloudPreviewContext({
      machineID,
      sessionId: shownSessionId,
      turnId: cloudPreviewTurnId,
      active: !quick && snapshot.isWorking && cloudPreviewChat,
    });
  }, [
    cloudPreviewChat,
    cloudMachineID,
    cloudPreviewTurnId,
    quick,
    shownSessionId,
    snapshot.isWorking,
    snapshot.summary?.machine,
  ]);
  /// The page's chat runs on another machine (cloudRun.ts): Cloud is never this new chat's choice there (cmux#47679).
  const onOtherMachinePage = pageOnOtherMachine({ cloudMachineID, origin: snapshot.origin, summary: snapshot.summary });
  /// Run as is a new chat's choice, in a pane with tabs (not the floating chat).
  /// Not once a chat is starting here (a harness pick, a deferred start): its session would replace
  /// the sandbox's result. The host refuses `sandbox.run` then too (AcpmuxPaneReplacements). Not
  /// before the host said what this tab already sent (`sandbox.checked`): a run it holds takes the
  /// chat view, so a send picked before that could only be refused, its prompt with it.
  /// Everything but the host's check: the New Tab page's project pick goes to the host under this,
  /// so a pick made before `sandbox.checked` still goes with a Cloud start (newTabProjectPick).
  const sandboxOfferable =
    freshChat &&
    !snapshot.sessionId &&
    !snapshot.summary?.sessionId &&
    snapshot.switching === undefined &&
    sessionSelection?.state !== "pending" &&
    surface !== "quick";
  const sandboxOffered = sandbox.checked && sandboxOfferable;
  /// A new chat whose local session already opened and is still empty: New Agent Chat or New Cloud
  /// Chat beside a chat starts its inherited agent at once (a harness switch), so a session shows
  /// before anything is said. Cloud is still this chat's choice: its first Send starts the chat on a
  /// Cloud machine, and the host closes this tab with the empty chat (`replacesChat`, AgentPaneHandOff).
  /// Sandboxed is not: its run's result would be this chat's, which already is one.
  /// A model pick of another agent on the empty chat (GPT-6.1 Sol on a Claude page) opens that agent's session here
  /// at once, and the switch stays in flight until it settles: the chat is still empty and still this one's to replace,
  /// so Cloud stays picked through it. Before, a Send in that window went to the new local session (cmux#45774).
  const emptyLocalChat =
    freshChat &&
    Boolean(snapshot.sessionId) &&
    (snapshot.summary?.sessionId === snapshot.sessionId || snapshot.switching !== undefined) &&
    snapshot.switching?.phase !== "failed" &&
    sessionSelection?.state !== "pending" &&
    surface !== "quick" &&
    !snapshot.summary?.peer &&
    snapshot.summary?.hostKind !== "cloud" &&
    snapshot.origin !== "remote" &&
    snapshot.origin !== "peer" &&
    cloudMachineID === undefined;
  /// A new chat whose only start is an agent or model pick (GPT-6.1 Sol on a Claude page): its switch
  /// is no chat starting here, so Cloud stays offered and the pick goes with the Cloud start (cmux#45946).
  const pickOnlyChat = pickOnlyNewChat({
    fresh: freshChat,
    sessionId: snapshot.sessionId,
    summarySessionId: snapshot.summary?.sessionId,
    switching: snapshot.switching !== undefined,
    selectionPending: sessionSelection?.state === "pending",
    quick: surface === "quick",
  });
  /// Cloud as where this new chat runs: wherever Sandboxed is, in an empty local chat, and on a page
  /// that holds only a pick.
  const cloudOfferable = !onOtherMachinePage && (sandboxOfferable || emptyLocalChat || pickOnlyChat);
  const cloudOffered = sandbox.checked && cloudOfferable;
  /// The chat a Cloud reserve made here names as the one its Send replaces: the empty local chat, else none.
  const cloudReserveReplaces = emptyLocalChat ? (snapshot.sessionId ?? undefined) : undefined;
  /// The tab's Sandboxed result (sandboxRun.ts SandboxTab): its run (running, receipt, or an answer
  /// that may hide a live Run) or a refusal before any Run.
  const sandboxView = sandbox.view();
  /// The tab's run is its result while no chat started here: the chat view shows it, with no
  /// composer, so nothing here can start a chat over it or send a second.
  const sandboxHoldsChat = !snapshot.sessionId && sandboxView !== undefined && !sandboxRetryable(sandboxView);
  const sandboxing = sandboxOffered && !sandbox.spent() && sandbox.mode === "sandboxed";
  /// Sandboxed is picked but can't run now (a chat is starting or being opened, the tab's one send
  /// is used): a send then is refused, never sent as a Persistent chat instead.
  const sandboxPickedNotOffered = sandbox.mode === "sandboxed" && !snapshot.sessionId && !sandboxing;
  const sandboxNotNow = sandbox.spent() ? "sandbox_spent" : "unavailable_now";
  /// The person picked where this new chat runs (a Run as row, Cloud, or a machine): their pick
  /// holds for this chat, and the folder's default (below) no longer changes it.
  const runModePicked = useRef(false);
  /// Cloud is this new chat's mode by default, not by the person's pick: the folder may undo it.
  const cloudByDefault = useRef(false);
  /// A Cloud start is out (the host answers once the chat opens, minutes for a new machine): the
  /// folder default changes nothing meanwhile, so the prompt it holds never turns into a local send.
  const cloudStartPending = useRef(false);
  /// A Cloud send held back because the account has no Cloud plan (`sendToCloud`): what it was, and the composer's
  /// draft as it was held (unchanged, the start takes it out once it goes). Its turn keys the held card.
  const cloudPlanHeld = useRef<
    | {
        text: string;
        attachments: ComposerAttachment[];
        start: Omit<CloudStart, "task" | "attachments">;
        fromPage: boolean;
        shown?: { text: string; attachments: ComposerAttachment[] };
      }
    | undefined
  >(undefined);
  const cloudPlanHeldTurn = useRef(0);
  /// The pricing card's Subscribe (cloudPlanSubscribe.ts): back from the browser with the plan on, the held send or
  /// the refused start goes again, once (`cloudPlanReady`, set after each commit).
  const cloudPlanReady = useRef<() => void>(() => undefined);
  const [cloudPlanStore] = useState(() => createCloudPlanSubscribe({ onReady: () => cloudPlanReady.current() }));
  /// The pricing card went (Not now, Run on This Mac, another chat or place): nothing waits on the plan any more.
  const dropCloudPlanWait = () => {
    cloudPlanHeld.current = undefined;
    cloudPlanStore.reset();
  };
  /// The cap card answered Run on This Mac (cloudRunsHere): the prompt sends here once the mode switched.
  const runHereSend = useRef(false);
  /// Counts the Cloud starts that ended, so the folder default looks again once one has.
  const [cloudStartsEnded, setCloudStartsEnded] = useState(0);
  /// The one-time Cloud hint over a new chat's composer (cloudChatHintModel.ts): its record is the app's.
  /// A pick of Cloud by any path (the hint, the Where menu, New Cloud Chat) is its use. Each adoption
  /// reads the record again: a hint one tab showed is done before the next tab takes this page.
  const cloudHint = useCloudChatHint(paneTipHost, newTabAdoptions);
  const featureTipsOn = useFeatureTipsOn();
  /// New Cloud Chat (the handshake's `pickCloud`), counted: the New Tab page or this composer picks
  /// Cloud once Cloud is offered here.
  const [cloudPickRequest, setCloudPickRequest] = useState(0);
  const [cloudPicksDone, setCloudPicksDone] = useState(0);
  /// This new chat's Cloud environment (the Environment chip, CLOUD_ENVIRONMENTS_ENABLED): Auto until
  /// picked, and Auto again once its Cloud send goes, a chat starts here or another new chat shows.
  const cloudEnvironment = useChatCloudEnvironment(`${snapshot.sessionId ?? ""}:${newTabGeneration}`);
  /// Run mode set for this new chat: by the person (`sandboxModeRows.onMode`) or an automation.
  const applyRunMode = (mode: RunMode) => {
    if (mode === "cloud") cloudHint.used();
    // Run mode is a new destination (including a brand-new Cloud machine); an account-machine
    // picker target must not survive that choice and wake the old machine on the next edit.
    cloudDraftMachineID.current = null;
    cloudTypingPrewarm.reset();
    runModePicked.current = true;
    sandbox.setMode(mode);
    const eligible = mode === "cloud" && cloudOffered ? { replaces: cloudReserveReplaces } : false;
    cloudComposeEligible.current = eligible;
    if (eligible) {
      newChatPrewarm.abandon();
      cloudReservation.selected(eligible.replaces);
    } else cloudReservation.abandon();
  };
  const sandboxModeRows = {
    mode: sandbox.mode,
    environment: cloudEnvironment.pick,
    /// The person's pick: the next new chat, in this pane or a new workspace's, starts there too (cmux#46019).
    onMode: (mode: RunMode) => {
      const place = placeOfRunMode(mode);
      if (place) rememberNewChatPlace(place);
      applyRunMode(mode);
    },
  };
  /// The composer's Run as rows: picking Cloud there is the person's pick of the chat's folder too,
  /// so the host grants it (workspace.useFolder) and the Cloud start may copy it (the same folder
  /// sendToCloud names). A folder Cloud never copies (home or above, agent-home) asks nothing.
  /// The Cloud picks' folder grants (workspace.useFolder), by folder: a Cloud start waits for the
  /// grant of the folder it sends, at most CLOUD_FOLDER_GRANT_WAIT_MS, so a Return right after
  /// picking Cloud never races the grant into path_outside_roots and a grant that never answers
  /// never holds the composer.
  const [cloudFolderGrant] = useState(() => cloudFolderGrants());
  const pickComposerMode = (mode: RunMode) => {
    if (mode === "cloud") {
      const folder = composerCloudStartFolder(composerSnapshot.summary);
      // A GitHub repository (githubRepos.ts) is cloned on the machine: no folder of this Mac to grant.
      if ("cwd" in folder && !githubFolderRepo(folder.cwd))
        cloudFolderGrant.granting(
          folder.cwd,
          pickFolder(callNative, folder.cwd, () => undefined),
        );
    }
    sandboxModeRows.onMode(mode);
  };
  // The composer takes these rows as one prop (`runMode`), so they are the same object until the mode
  // or the environment changes: a new object on each pane render drew the composer again with it. The
  // pick runs the latest handler, as the composer's own handlers do (stableHandlers.ts).
  const composerModePick = useRef(pickComposerMode);
  useLayoutEffect(() => {
    composerModePick.current = pickComposerMode;
  });
  const composerModeRows = useMemo(
    () => ({
      mode: sandboxModeRows.mode,
      environment: sandboxModeRows.environment,
      // An empty local chat offers Cloud, not Sandboxed (`emptyLocalChat`).
      ...(sandboxOffered ? {} : { sandbox: false as const }),
      onMode: (mode: RunMode) => composerModePick.current(mode),
    }),
    [sandboxModeRows.mode, sandboxModeRows.environment, sandboxOffered],
  );
  /// A Sandboxed send: text only, by an agent a sandbox runs. A page-side refusal comes back as its
  /// code (the prompt stays where it was typed); false: nothing was sent.
  const startSandbox = (text: string, attachmentCount: number, harness: string | undefined): string | boolean =>
    sandboxPageRefusal(attachmentCount, harness) ?? sandbox.send(text, sandboxAgent(harness));
  /// Cloud picked (cloudRun.ts): the first send goes to the host, which opens the chat on a Cloud
  /// machine and closes this tab. False keeps the prompt in the composer meanwhile; a string is a
  /// refusal said here, also while Cloud is picked but not offered now (as `sandboxPickedNotOffered`).
  /// The host says its own progress and failures (toasts), and the chat shows the start under the
  /// message as it goes (CloudStartView; the host's `cloudStartProgress` pushes fill it in).
  /// Never on a page of another machine (`onOtherMachinePage`): a Cloud pick carried over from the chat before
  /// is no Cloud start there, the send starts the chat in this pane on that machine.
  const cloudPicked = sandbox.mode === "cloud" && !onOtherMachinePage && (!snapshot.sessionId || emptyLocalChat);
  // The permission mode picked for that Cloud start (cloudModePick.ts).
  const cloudModePick = useCloudModePick();
  // A warm machine is reserved wherever Cloud is offered: before a chat opened here, or in an empty local chat,
  // whose reserve names the chat its Send replaces (the host reserves for a tab with a chat only for that one).
  cloudComposeEligible.current = cloudPicked && cloudOfferable ? { replaces: cloudReserveReplaces } : false;
  const cloudPickedNotOffered = cloudPicked && !cloudOffered;
  /// The New Tab page's Run as rows (sandboxRun.ts newTabRunModeRows): Cloud stays this chat's pick once an
  /// agent pick opened its empty session, as in the chat composer (cmux#45774).
  const newTabRunMode = newTabRunModeRows(sandboxModeRows, {
    sandbox: sandboxOffered,
    cloud: cloudOfferable,
    sandboxPicked: sandboxPickedNotOffered,
    cloudPicked: cloudPickedNotOffered,
  });
  const [startCloud] = useState(() =>
    grantedCloudStart(
      pickedChatCloudCall(reservedCloudCall(callNative, cloudReservation), (ms) => harnessSwitch.pickSession(ms)),
      cloudFolderGrant,
    ),
  );
  const [cloudStartKeys] = useState(() => makeCloudStartKeys());
  const [cloudStart, setCloudStart] = useState<CloudStartProgress>();
  // The host sent `attachExternal` before a composer was there to take the files (composer/externalAttach.ts).
  const externalWaiting = useRef(false);
  const cloudSignInSend = useRef<() => Promise<CloudStartAnswer> | undefined>(() => undefined);
  /// The card retries its preserved request once; native keeps the click across browser auth.
  const [cloudSignInRetry] = useState(() => makeCloudSignInRetry(() => cloudSignInSend.current()));
  /// The sign-in a start waits on (cloudSignIn.ts): leaving Cloud (another mode, chat or tab) withdraws it.
  const cloudSignInWait = useRef<CloudSignInWait | undefined>(undefined);
  /// Set up Cloud's button (cloudSetup.ts): the next sign-in resend waits on that way in instead of the
  /// account sign-in, then the start goes again on the click the host kept.
  const cloudSetUpPick = useRef<{ action: CloudSetupAction; need: CloudSetupNeed } | undefined>(undefined);
  const cancelCloudSignIn = () => {
    const wait = cloudSignInWait.current;
    cloudSignInWait.current = undefined;
    wait?.withdraw();
  };
  /// The last accepted first send, retained so choosing This Mac after a refusal can
  /// explicitly finish its Cloud key just as the native cap-card answer does.
  const lastCloudAttempt = useRef<{ key: string; request: CloudStart } | undefined>(undefined);
  /// A Cloud start is out. The composer stays open (Leo, 2026-11-09: "I can't click into the
  /// composer at all to, like potentially type other stuff while it's doing that initial load
  /// situation"), but sends nothing until the start ends. On success the host closes this tab and
  /// opens the chat with the sent prompt (#28686); the composer holds only what was typed after the
  /// Send (`cloudStartHeld` took the prompt out), which goes to the host at once as the tab's unsent
  /// text (Composer `onUnsentDraft`), and the host seeds the started chat's composer with it as a
  /// draft (CloudStartChat `openUploaded`). On failure the prompt comes back in front of it. A start
  /// the host has said nothing about for minutes (cloudStartProgress.ts `CLOUD_START_STALL_MS`)
  /// stalled: the card says so, and the start is still out.
  /// The chat view shows the start (CloudStartView: the sent prompt, its steps, a failure and Retry) in place
  /// of the new chat: one with no session, or an empty local chat the start replaces (`emptyLocalChat`).
  const cloudStartShown = cloudStart !== undefined && (!snapshot.sessionId || emptyLocalChat);
  /// The folder the shown start copies (none for a folderless one): the composer's folder chip names it (cmux#46023).
  const cloudStartFolderShown = cloudStartShown ? cloudStart?.cwd : undefined;
  const cloudStartPickShown = shownCloudStartPick(cloudStartShown, cloudStart, {
    harness: snapshot.summary?.harness,
    model: snapshot.summary?.model,
  });
  /// For `chat.model`, which the page's actions call after this render.
  const shownCloudStartPickNow = useEffectEvent(() => cloudStartPickShown);
  const cloudStarting = cloudStart?.state === "starting";
  /// Nothing that starts a chat goes from this tab while a Cloud start is out, stalled or not: if it
  /// still opens its chat, the host closes this tab, with a chat started here in it.
  const cloudSendHeld = cloudStarting;
  useEffect(
    () => watchCloudStartStall(cloudStart, (key) => setCloudStart((current) => cloudStartStalled(current, key))),
    [cloudStart],
  );
  /// The same, for dictation's recording (below), whose callbacks are made once.
  const cloudStartingNow = useRef(false);
  cloudStartingNow.current = cloudStarting;
  /// The prompt a Cloud start took out of the composer (it shows as the message, with the start under
  /// it, as a local send's does), by its start's key: a failed start puts it back. Set only where the
  /// prompt was taken out (the composer's Send, a sign-in's resend), so nothing reads the prompt off
  /// the composer's text.
  const cloudStartHeld = useRef<{ key: string; prompt: CloudStartDraft } | undefined>(undefined);
  /// What was typed during a start that failed, now after its prompt in the composer: Retry and Run
  /// on This Mac send the prompt alone and leave this in the composer (`sendStartPrompt`).
  const cloudTypedDuringStart = useRef<CloudStartDraft | undefined>(undefined);
  /// Sends the failed start's prompt (Retry, Run on This Mac) as Return would. What was typed during
  /// the start stays in the composer after it and never goes with it, while the composer still holds
  /// that prompt and that text (`promptBeforeTyped`); once the person changed it, what shows goes.
  const sendStartPrompt = () => {
    const handle = composerHandle.current;
    const typed = cloudTypedDuringStart.current;
    cloudTypedDuringStart.current = undefined;
    const split = handle && typed ? promptBeforeTyped(handle.draft(), typed) : undefined;
    if (!handle || !split) return void handle?.send();
    handle.take();
    handle.restore(split.prompt.text, split.prompt.attachments);
    // The composer sends what it rendered: send once the prompt alone has (the effect below).
    startPromptSend.current = { typed: split.typed, sent: false };
    setStartPromptSends((count) => count + 1);
  };
  /// `sendStartPrompt`'s two steps, each after the composer rendered the last: the prompt alone goes,
  /// then the typed text comes back after whatever the send left.
  const startPromptSend = useRef<{ typed: CloudStartDraft; sent: boolean } | undefined>(undefined);
  const [startPromptSends, setStartPromptSends] = useState(0);
  useEffect(() => {
    const step = startPromptSend.current;
    const handle = composerHandle.current;
    if (!step || !handle) return;
    if (!step.sent) {
      step.sent = true;
      handle.send();
      setStartPromptSends((count) => count + 1);
      return;
    }
    startPromptSend.current = undefined;
    handle.restore(step.typed.text, step.typed.attachments, true);
  }, [startPromptSends]);
  /// A Cloud send from the New Tab page opens the chat at once, as a local send does (Leo, 2026-11-04:
  /// "i should never be seeing this it should just insta send me to a new chat just like local"): the
  /// page goes for this visit (its generation), and the chat view shows the sent message with the
  /// start under it (CloudStartView) until the host opens the chat on its machine.
  const [cloudLeftPage, setCloudLeftPage] = useState<number>();
  /// The page's draft as it went (leaveNewTabDraft): the chat composer gets it back when the start
  /// fails or the cap card runs it on this Mac, so the prompt is never lost with the page.
  const newTabCloudSent = useRef(false);
  const cloudPageDraft = useRef<{ text: string; attachments: ComposerAttachment[] } | undefined>(undefined);
  /// The same transition as the native cap card's Run on This Mac answer: keep the
  /// failed Cloud prompt in the composer, change its destination and send it once.
  const runCloudHere = (expectedKey?: string) => {
    if (expectedKey === undefined && cloudStart?.state === "failed") {
      const previous = lastCloudAttempt.current;
      if (previous?.key === cloudStart.key)
        cloudStartKeys.ended(previous.request, { ok: false, code: "run_on_this_mac" });
      lastCloudAttempt.current = undefined;
    }
    cloudSignInRetry.reset();
    if (expectedKey === undefined) dropCloudPlanWait();
    setCloudStart((current) => (expectedKey && current?.key !== expectedKey ? current : undefined));
    runModePicked.current = true;
    runHereSend.current = true;
    sandbox.setMode("persistent");
  };
  /// The folder the latest Cloud send named (the card's "Start without a folder", or its project): Retry
  /// repeats this exact folder, even when a New Tab pick changed from project A to project B.
  const cloudRetryFolder = useRef<ReturnType<typeof cloudStartFolder> | undefined>(undefined);
  const dismissCloudFailure = () => {
    cloudRetryFolder.current = undefined;
    dropCloudPlanWait();
    setCloudStart(undefined);
  };
  /// Set up Cloud's button: its way in runs on this Mac, and the prompt goes again once a connection
  /// serves the model (the sign-in resend, `cloudSignInSend`), with no retyping.
  const setUpCloud = (action: CloudSetupAction) => {
    const need = cloudStart?.state === "failed" ? cloudStart.cloudSetup : undefined;
    if (!need) return;
    // The resend takes the pick at once (`beginCloudSend`); a retry that sent nothing (one already out
    // or resumed, an edited prompt, a reset) leaves none, so a later Sign in signs in.
    void retryWithSetUpPick(cloudSetUpPick, { action, need }, cloudSignInRetry);
  };
  /// The model picker's Connect row (claudeConnect.ts `setupConnect`) while this chat's Cloud start
  /// waits for a connection: shown only for the family the host's Set up Cloud need names, so a local
  /// chat, or a Cloud one a connection serves, never shows it. Connect runs the card's first button.
  const setUpCloudNow = useRef(setUpCloud);
  useEffect(() => {
    setUpCloudNow.current = setUpCloud;
  });
  const cloudSetupNeed = cloudStart?.state === "failed" ? cloudStart.cloudSetup : undefined;
  const cloudSetupWaiting = cloudStart?.signingIn === true;
  const modelConnect = useMemo(
    () => setupConnect(cloudSetupNeed, cloudSetupWaiting, (action) => setUpCloudNow.current(action)),
    [cloudSetupNeed, cloudSetupWaiting],
  );
  /// Set up Cloud's Not now: a wait still out is withdrawn (the start then ends here), else the card goes.
  const dismissCloudSetUp = () => (cloudStart?.signingIn ? cancelCloudSignIn() : dismissCloudFailure());
  /// The plan card's Switch to <team>: the next Cloud send carries the team, and the host switches to it
  /// (the team picker's switch) before it starts, under the same click.
  const [cloudSwitchTeam] = useState(() => cloudStartTeam());
  /// The Cloud send that waits on the tab's check (cloudRun.ts cloudSendAfterCheck), while it waits.
  const [cloudAfterCheck] = useState(() => cloudSendAfterCheck());
  /// The held send's state on the page: waiting on the check, or the refusal it came back with
  /// (and the prompt, for its New Cloud chat action).
  const [cloudHeld, setCloudHeld] = useState<"checking" | { refusal: string; prompt: string; cwd?: string }>();
  const cloudWaitsForCheck = cloudHeld === "checking";
  /// The held send came from the New Tab page: the page locks while it waits, as during a start,
  /// so the send that goes is what the page shows. A check that fails (Check again) drops a page's
  /// held send and unlocks the page, its prompt still in it.
  const cloudHeldOnPage = useRef(false);
  const cloudPageHeld = cloudWaitsForCheck && cloudHeldOnPage.current && !sandbox.unread;
  const sendToCloudLatest = useRef<typeof sendToCloud>(() => false);
  /// The send held for the plan goes now (the plan read fresh admits it), once: the prompt taken from the composer as a
  /// Send that went at once would, unless the person changed it meanwhile.
  const sendHeldForPlan = (held: CloudPlanHeld) => sendHeldForPlanWith(cloudSendDeps(), held);
  /// The Cloud send (pane/useCloudSend.ts `sendToCloudWith`), over this render's values.
  const sendToCloud: SendToCloud = (...args) => sendToCloudWith(cloudSendDeps(), ...args);
  // The held send runs the render's latest `sendToCloud` (its offerable and checked), set after commit, not during render.
  useLayoutEffect(() => {
    sendToCloudLatest.current = sendToCloud;
    cloudPlanReady.current = () => {
      // The page's own hold (no plan at Send): that send goes now, the prompt taken from the composer as a Send that
      // went at once would, unless the person changed it meanwhile.
      const held = cloudPlanHeld.current;
      if (held) {
        sendHeldForPlan(held);
        return;
      }
      // The platform's refusal (no plan, or a machine larger than the plan includes): the same start again, once.
      if (
        cloudStart?.state === "failed" &&
        (cloudStart.code === "cloud_plan_required" || cloudStart.code === "cloud_size_locked")
      )
        retryCloudStart();
    };
  });
  // The held send goes once Cloud is offered here; leaving Cloud, a chat opening here or another
  // New Tab drops it.
  // The check answered that a chat is starting in this tab: the held send can't go, so its notice
  // becomes that refusal, with New Cloud chat.
  useEffect(() => {
    if (!cloudWaitsForCheck) return;
    if (sandbox.mode !== "cloud" || (snapshot.sessionId && !emptyLocalChat)) {
      cloudAfterCheck.drop();
      setCloudHeld(undefined);
    } else if (cloudOffered) {
      cloudAfterCheck.offered();
    } else if (sandbox.unread && cloudHeldOnPage.current) {
      cloudAfterCheck.drop();
      setCloudHeld(undefined);
    } else if (sandbox.checked && !cloudOfferable) {
      const held = cloudAfterCheck.take();
      setCloudHeld({
        refusal: translate("cloudStart.chatStartingHere"),
        prompt: held?.prompt ?? "",
        ...(held?.cwd ? { cwd: held.cwd } : {}),
      });
    }
  }, [
    cloudAfterCheck,
    cloudWaitsForCheck,
    cloudOffered,
    cloudOfferable,
    emptyLocalChat,
    sandbox.checked,
    sandbox.unread,
    sandbox.mode,
    snapshot.sessionId,
  ]);
  // Another New Tab, or leaving Cloud, ends what the held send said.
  useEffect(() => {
    cloudAfterCheck.drop();
    setCloudHeld(undefined);
  }, [cloudAfterCheck, newTabGeneration]);
  useEffect(() => {
    if (sandbox.mode !== "cloud") setCloudHeld((held) => (held === "checking" ? held : undefined));
  }, [sandbox.mode]);
  /// A Cloud start, after a sign-in when `signingIn` (pane/useCloudSend.ts `beginCloudSendWith`).
  const beginCloudSend: BeginCloudSend = (...args) => beginCloudSendWith(cloudSendDeps(), ...args);
  /// What the Cloud send (pane/useCloudSend.ts) reads of this render, built at each call.
  const cloudSendDeps = (): CloudSendDeps => ({
    cloudPlanHeld,
    composerHandle,
    setCloudStart,
    sendToCloudLatest,
    cloudOfferable,
    sandbox,
    cloudAfterCheck,
    setCloudHeld,
    cloudHeldOnPage,
    cloudStartPending,
    cloudPlanHeldTurn,
    sendHeldForPlan,
    cloudEnvironment,
    cloudSwitchTeam,
    emptyLocalChat,
    snapshot,
    cloudReservation,
    cloudStartKeys,
    beginCloudSend,
    startCloud,
    cancelCloudSignIn,
    cloudSetUpPick,
    cloudSignInWait,
    dropCloudPlanWait,
    cloudSignInSend,
    cloudTypedDuringStart,
    lastCloudAttempt,
    cloudStartHeld,
    newTabCloudSent,
    cloudPageDraft,
    setCloudLeftPage,
    newTabGeneration,
    setCloudStartsEnded,
    heldBack,
    runCloudHere,
    cloudRetryFolder,
    harnessSwitch,
    notices,
  });
  /// A chat shows here while the tab's run is out or ended: a notice offers it, and Show opens it in
  /// place of the chat until Back: a paid run's receipt stays reachable.
  const sandboxElsewhere =
    snapshot.sessionId && sandboxView && !sandboxRetryable(sandboxView) ? sandboxView : undefined;
  const [sandboxViewing, setSandboxViewing] = useState(false);
  /// What only the composer held (shell mode, its line, attachments) while the receipt took its
  /// place: Back puts it back. It belongs to that chat, so another chat or a new one drops it.
  const sandboxWake = useRef<ComposerWake | undefined>(undefined);
  /// The New Tab page handed a prompt to a Sandboxed send: its draft isn't moved again as it goes.
  const newTabSandboxSent = useRef(false);
  const cloudShownView = useRef<CloudIdentityView>({
    ...(snapshot.sessionId ? { session: snapshot.sessionId } : {}),
    generation: newTabGeneration,
  });
  useEffect(() => {
    // The empty chat's own first session (a model pick of another agent opened it at once, `emptyLocalChat`) is
    // still this new chat: a Cloud start sent from it keeps its card, its held prompt and its reservation here.
    // Dropping them hid the start and its failure, and the prompt with it (cmux#45774).
    // Any such session, with either place picked: a model pick never resets where the chat runs (cmux#47677).
    const shown = cloudShownView.current;
    const next = { ...(snapshot.sessionId ? { session: snapshot.sessionId } : {}), generation: newTabGeneration };
    if (sameNewChat(shown, next, emptyLocalChat, snapshot.switching !== undefined)) {
      cloudShownView.current = next;
      return;
    }
    setSandboxDraftMoved(false);
    setSandboxViewing(false);
    sandboxWake.current = undefined;
    runModePicked.current = false;
    cloudReservation.reset();
    cloudSwitchTeam.reset();
    cloudPlanHeld.current = undefined;
    cloudPlanStore.reset();
    // Another chat shows here: a Cloud start's card belongs to the new chat it was sent from.
    cancelCloudSignIn();
    cloudSignInRetry.reset();
    setCloudStart(undefined);
    cloudSignInSend.current = () => undefined;
    cloudPageDraft.current = undefined;
    cloudStartHeld.current = undefined;
    cloudTypedDuringStart.current = undefined;
    newTabCloudSent.current = false;
    cloudDraftMachineID.current = undefined;
    cloudTypingPrewarm.reset();
    const view = { ...(snapshot.sessionId ? { session: snapshot.sessionId } : {}), generation: newTabGeneration };
    if (!cloudIdentityKept(cloudShownView.current, view)) cloudIdentityBound.current = false;
    cloudShownView.current = view;
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the retry is made once (useState); the cancel reads only refs
  }, [snapshot.sessionId, newTabGeneration, cloudTypingPrewarm, cloudReservation]);
  /// The person picked another place to run after a Cloud start failed: its card goes.
  useEffect(() => {
    if (sandbox.mode !== "cloud") {
      cloudReservation.abandon();
      cloudSwitchTeam.reset();
      cloudPlanHeld.current = undefined;
      cloudPlanStore.reset();
      cancelCloudSignIn();
      cloudSignInRetry.reset();
      setCloudStart((current) => (current?.state === "failed" ? undefined : current));
      cloudSignInSend.current = () => undefined;
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the retry is made once (useState); the cancel reads only refs
  }, [sandbox.mode, cloudReservation]);
  /// Run on This Mac from the cap card (runHereSend): the kept prompt sends once the mode is this Mac's.
  useEffect(() => {
    if (!runHereSend.current || sandbox.mode !== "persistent") return;
    runHereSend.current = false;
    sendStartPrompt();
  }, [sandbox.mode]);
  const viewedSandbox = sandboxViewing && snapshot.sessionId ? sandboxView : undefined;
  /// The chat view shows the tab's run as a card (SandboxRunView), which offers its own Check again.
  const sandboxCard =
    viewedSandbox !== undefined ||
    (sandboxView !== undefined && !snapshot.sessionId && (sandboxHoldsChat || sandbox.mode === "sandboxed"));
  /// The newest read didn't answer and no card says so: a notice does (the chat's, or the New Tab
  /// page's, where Sandboxed waits for a read that answers).
  const sandboxUncheckedNotice = sandbox.unread && !sandboxCard;
  const sandboxUnchecked = (
    <output className="acpmux-switch-notice acpmux-folder-choice">
      <span>{t("sandbox.unchecked")}</span>{" "}
      <button type="button" className="acpmux-folder-choice-button" onClick={() => void sandbox.read()}>
        {t("sandbox.checkAgain")}
      </button>
    </output>
  );
  /// The header's tools in the pane's tab row, while the App offers one (header/tabRow.ts).
  const tabRow = useTabRow();
  const inTabRow = tabRow.height > 0 && !quick;
  useTabRowRoot(shell, inTabRow);
  /// A one-tab pane's row has no band: the transcript runs up under it (header/tabRow.ts `soloTab`, header.css).
  const soloTab = inTabRow && tabRow.soloTab === true;
  /// The lines in flow under the header (header/underHeader.ts): each renders below only when its flag is set,
  /// and the transcript runs up under the row only when none is, so it never covers one.
  /// The tab's chat is not listed yet and its last-read rows are drawn (direct.ts `drawMissingTail`):
  /// why it is not here is a line under the header, over the transcript, not the centered state.
  const missingRows = !!snapshot.unavailable && snapshot.missingSession !== undefined && snapshot.rows.length > 0;
  const underHeader: UnderHeaderLines = {
    checkpointReview: checkpoints.review != null,
    unavailable: missingRows && snapshot.unavailable?.reason !== "connecting",
    liveChat: !!snapshot.liveChat,
    peerCopy: !!snapshot.peerCopy?.offline,
    watching: !!snapshot.summary?.watching,
    handoffError: !reviewing && !!snapshot.handoff?.error,
  };
  const soloUnder = runsUnderTabRow(soloTab, underHeader);
  const tabRowTools = useTabRowTools(inTabRow ? tabRow : undefined, reportTabRowTools);
  // Ctrl-B moves a Claude Code chat's running command or subagent to the background, and a
  // running command's row says so (conversation/runInBackground.ts).
  const canBackground = backgroundsWork(snapshot.summary);
  // Only Claude Code's agents and workflows stop on their own (acpmux `_acpmux/subagent_stop`, which
  // this acpmux serves where it moves work: a Claude Code chat whatever its harness is named).
  const stopsSubagents = canBackground;
  const stopSubagent = useMemo(
    () =>
      stopsSubagents
        ? (id: string) => directClient.current?.stopSubagent(id) ?? Promise.reject(new Error())
        : undefined,
    [stopsSubagents],
  );
  // When nothing moves (nothing in the foreground, a refusal, no answer), a line above the composer
  // says so (conversation/backgroundNotice.ts).
  const background = useBackgroundNotice(shownSessionId);
  const trackBackground = background.track;
  // The calls in the foreground now, read when a move is checked (backgroundNotice.ts "kept").
  const foregroundNow = useRef<readonly string[]>([]);
  const runInBackground = useCallback(
    (toolCallId?: string) => {
      const asked = toolCallId ? [toolCallId] : foregroundNow.current;
      trackBackground(directClient.current?.backgroundWork(toolCallId), () =>
        asked.some((id) => foregroundNow.current.includes(id)),
      );
    },
    [trackBackground],
  );
  const foreground = useMemo(
    () => (canBackground && snapshot.isWorking ? foregroundCalls(snapshot.rows) : []),
    [canBackground, snapshot.isWorking, snapshot.rows],
  );
  foregroundNow.current = foreground;
  const [autoOpenSubagents, setAutoOpenSubagents] = useAutoOpenSubagents();
  /// Shows subagent `id`: a person's open in a pane of its own right of the chat, focused; a new
  /// subagent's own open (`focus` false) only while the summary card's switch is on
  /// (subagents/subagentPanes.ts).
  const showSubagent = useCallback(
    (id: string, focus = true) =>
      void showSubagentIn(callNative, id, focus, {
        panes: autoOpenSubagents,
        inSubagentPane: subagentPane.current,
        here: setSubagentView,
        title: subagentTitleRef.current.title(id),
        tone: workflowPaneRequest(id) ? undefined : agentTone(id),
        // Seed a new pane from this chat's kept tail before its own attach answers: carried on the
        // pane's request, so the host holds it before it decides how the pane opens (#36650).
        beforeOpen: () => directClient.current?.tailHandOver(),
        mark: workflowPaneRequest(id) ? undefined : subagentTitleRef.current.mark(id),
      }),
    [autoOpenSubagents],
  );
  /// Shows subagent `id`'s view in place, or the chat's (`undefined`). In a pane opened on a subagent
  /// (beside the chat that opened it), going to the chat goes back to that chat's own tab instead and
  /// closes this one, so the chat never shows twice (subagentPanes.ts backToOpeningChat); a pane no
  /// chat opened shows the chat in place.
  const navigateSubagent = useCallback((id: string | undefined) => {
    if (id !== undefined || !subagentPane.current) return setSubagentView(id);
    void backToOpeningChat(callNative).then((back) => {
      if (!back) setSubagentView(undefined);
    });
  }, []);
  // Escape closes a subagent's view to the chat's, as its pill's × does (subagents/subagentEscape.ts).
  useEscapeClosesSubagent(!quick && !!subagentView, () => navigateSubagent(undefined));
  // A pane opened on a subagent shows the chat's other subagents in place, and its "Subagent of" pill goes
  // back to the chat: its tab's name follows what it shows (review of #28497 at 995299ff). Not before
  // the subagent it was opened on has shown, or the name the app gave the tab would flash away; and not
  // while this page has no rows for the subagent yet (they load after the pane opens), which would name
  // it "Subagent of" over the name the chat's page gave it.
  // A subagent the chat's rows no longer hold is known from its own records (subagentOwnLog.ts).
  const shownAgent = subagentView
    ? (freshAgents.find((agent) => agent.id === subagentView) ?? ownLogged?.agent)
    : undefined;
  const shownSubagentTitle =
    ownSubagentPane && subagentView && shownAgent
      ? subagentTabTitle(shownAgent, `${t("subagents.of")} ${chatName}`)
      : undefined;
  const shownFacts = useMemo(
    () => (shownAgent ? shownSubagentFacts(shownAgent, snapshot.clockOffsetMs ?? 0) : undefined),
    [shownAgent, snapshot.clockOffsetMs],
  );
  // Its tab's hover card and spinner say the subagent's own state, not its chat's.
  useShownSubagent(
    callNative,
    ownSubagentPane,
    subagentView,
    shownSubagentTitle,
    shownFacts,
    subagentRowMark(shownAgent, chatMark, senderBadge),
  );
  const showWorkflowAgent = useCallback(
    (agent: WorkflowAgent) => {
      const workflow = workflows.find((entry) => entry.agents.some((candidate) => candidate.id === agent.id));
      const request = workflow && workflowDetailRequest(workflow, agent);
      if (request) showSubagent(workflowPaneId(request));
    },
    [workflows, showSubagent],
  );
  useOpenNewSubagents(
    quick || subagentPane.current ? undefined : shownSessionId,
    snapshot.rows,
    snapshot.subagentViews,
    autoOpenSubagents,
    (id) => showSubagent(id, false),
    snapshot.clockOffsetMs ?? 0,
  );
  // Each subagent's color (agentTones.ts), which the transcript's subagent rows share. A streamed
  // chunk makes a new list of the same agents: the last one stays while nothing a row shows changed,
  // so a snapshot that streams text redraws neither the row nor its tone.
  const producerProgress = agentProgressSource(snapshot.rows);
  // Direct snapshots carry only changed progress values from the event fold. The bridge store
  // applies those ids without rebuilding a row list or joining every agent on usage updates.
  const bridgeProgress = useMemo(
    () => ({ sessionId: shownSessionId, store: new AgentProgressStore() }),
    [shownSessionId],
  ).store;
  // Each session gets a fresh store. Track initialization by store identity so switching
  // sessions cannot leave the new store empty because a ref from the prior session was set.
  const bridgeInitialized = useRef<AgentProgressStore | undefined>(undefined);
  useLayoutEffect(() => {
    if (producerProgress) return;
    if (bridgeInitialized.current !== bridgeProgress) {
      bridgeInitialized.current = bridgeProgress;
      bridgeProgress.update(freshAgents);
      return;
    }
    for (const [id, progress] of Object.entries(snapshot.subagentProgress ?? {}))
      bridgeProgress.updateProgress(id, progress);
  }, [producerProgress, bridgeProgress, freshAgents, snapshot.subagentProgress]);
  // Older bridge/gallery snapshots have no structure version or keyed progress delta. Keep their
  // row's own snapshot value as the fallback instead of exposing a stale one-time bridge value;
  // direct snapshots and newer bridge snapshots use the keyed store above.
  const compatibilitySnapshot = snapshot.subagentStructureVersion === undefined;
  const progressStore =
    producerProgress ??
    (!compatibilitySnapshot || snapshot.subagentProgress !== undefined ? bridgeProgress : undefined);
  const producerGeneration = useRef<{ source?: AgentProgressStore; value: number }>({ value: 0 });
  if (producerGeneration.current.source !== producerProgress) {
    producerGeneration.current = {
      source: producerProgress,
      value: producerGeneration.current.value + 1,
    };
  }
  const structureVersion = producerProgress
    ? `${producerGeneration.current.value}:${snapshot.subagentStructureVersion ?? 0}`
    : (snapshot.subagentStructureVersion ?? shownSessionId);
  // Compatibility snapshots do not carry a structure version, so use their fresh row list to
  // reflect structural changes. Direct snapshots stay keyed by the producer's structure version.
  const structuralAgents = useRef({
    structureVersion,
    sessionId: shownSessionId,
    agents: freshAgents,
  });
  if (
    compatibilitySnapshot ||
    structuralAgents.current.structureVersion !== structureVersion ||
    structuralAgents.current.sessionId !== shownSessionId
  ) {
    structuralAgents.current = { structureVersion, sessionId: shownSessionId, agents: freshAgents };
  }
  const chatAgents = structuralAgents.current.agents;
  // A subagent draws no tool row (subagents/subagentFold.ts swallows the call that started it), so
  // a running foreground subagent holds Ctrl-B by itself.
  const foregroundAgent =
    canBackground && snapshot.isWorking && freshAgents.some((agent) => running(agent) && !agent.background);
  // Ctrl-B and the line's hint offer the same thing at the same time: the hint (a button) shows only
  // while Ctrl-B moves something, never over a chat or call it can't move (Leo, 2026-11-03: "this run
  // in background sometimes i can't actually do anything to put it in the background").
  const backgroundable = !quick && (foreground.length > 0 || foregroundAgent);
  useBackgroundKey(backgroundable, runInBackground);
  const backgroundHint = backgroundable ? runInBackground : undefined;
  // The chat's subagents and the chats it started take their tones together, so up to five never
  // share one (agentTones.ts; Leo, 2026-11-04: "Each subagent gets its own colour").
  const chatTones = useMemo(
    () =>
      chatAgents.length > 0 || childSessions.length > 0
        ? agentTones([
            ...chatAgents,
            ...childSessions.map((child) => ({ id: child.sessionId, startedAt: child.createdAt })),
          ])
        : undefined,
    [chatAgents, childSessions],
  );
  // A message to a subagent names it by its description, never its agentId (MessageCard.tsx).
  const chatAgentNames = useMemo(() => agentNames(chatAgents), [chatAgents]);
  // A sent message's "Sent to <subagent>" chip opens that subagent's view (MessageCard.tsx).
  const chatAgentOpen = useMemo(
    () => ({ views: agentViews(chatAgents), open: (id: string) => showSubagent(id) }),
    [chatAgents, showSubagent],
  );
  const freshWaiting = useMemo(
    () => (chatAgents.some(running) ? waitingSubagents(askedToolCalls, snapshot.subagentViews) : new Set<string>()),
    [chatAgents, askedToolCalls, snapshot.subagentViews],
  );
  const waitingKey = [...freshWaiting].sort().join(" ");
  // eslint-disable-next-line react-hooks/exhaustive-deps -- a new set only when its agents change
  const waitingAgents = useMemo(() => freshWaiting, [waitingKey]);
  /// Resume for the surfaces outside the transcript's TurnActionsContext (the tray, the summary card,
  /// Session Info): the same `resumeAgent` the end line calls (subagents/ResumeControl.tsx).
  const resumeActions = useMemo(
    () => ({ resumeAgent: turnActions.resumeAgent, retryCapabilities: turnActions.retryCapabilities }),
    [turnActions.resumeAgent, turnActions.retryCapabilities],
  );
  /// The summary card's subagents: the shown one, and a row's click shows its view.
  const cardSubagents = useMemo(
    () => ({
      views: snapshot.subagentViews,
      current: childRows ? subagentView : undefined,
      asks: askedToolCalls,
      onOpen: showSubagent,
      autoOpen: quick ? undefined : { on: autoOpenSubagents, set: setAutoOpenSubagents },
      // Resume on a stopped subagent's row in the card and Session Info (subagents/ResumeControl.tsx).
      ...(turnActions.resumeAgent && { resume: resumeActions }),
    }),
    [
      snapshot.subagentViews,
      childRows,
      subagentView,
      askedToolCalls,
      showSubagent,
      turnActions.resumeAgent,
      resumeActions,
      quick,
      autoOpenSubagents,
      setAutoOpenSubagents,
    ],
  );
  // While the pane shows a subagent's own view, the Inspector is that subagent's: its own rows, its
  // worktree, its subagents, and a back button to what spawned it (session-info/subagentScope.ts). A
  // new scope only when what it shows of the subagent changes, or its rows do.
  const scopedAgent = shownSubagent === undefined ? undefined : freshAgents.find((agent) => agent.id === shownSubagent);
  const scopedKey = scopedAgent
    ? [
        scopedAgent.id,
        scopedAgent.name,
        scopedAgent.task ?? "",
        scopedAgent.parent ?? "",
        scopedAgent.state,
        scopedAgent.tokens ?? "",
        scopedAgent.toolUses ?? "",
        scopedAgent.cwd ?? "",
        scopedAgent.isolated ? 1 : 0,
        scopedAgent.worktree?.path ?? "",
        scopedAgent.worktree?.branch ?? "",
        scopedAgent.agents ? `${scopedAgent.agents.done}/${scopedAgent.agents.started}` : "",
      ].join("\u0000")
    : "";
  // Session Info lists the subagent's rows as they stood when the reader started scrolling, until
  // the scroll settles, as the chat's card does with `cardRows` (summary/heldWhileScrolling.ts,
  // cmux#29639). Another subagent, or another chat, takes its rows at once.
  const cardScopedRows = useHeldWhileScrolling(scopedRows, `${shownSessionId ?? ""}\u0000${shownSubagent ?? ""}`);
  const sessionInfoSubagent = useMemo((): SubagentScope | undefined => {
    if (!scopedAgent) return undefined;
    const parent = scopedAgent.parent;
    return {
      agent: scopedAgent,
      rows: cardScopedRows ?? [],
      parent: parent === null ? chatName : (chatAgents.find((agent) => agent.id === parent)?.name ?? chatName),
      agents: descendants(chatAgents, scopedAgent.id),
      // As its "Subagent of" pill: back to its parent subagent's view, else the chat's.
      onBack: () => navigateSubagent(parent ?? undefined),
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new scope only when what it shows changes
  }, [scopedKey, cardScopedRows, chatName, chatAgents]);
  // How many rows Session Info's Background tasks lists for the view on screen, read as it reads
  // them (sessionInfoLists drops a transcript shell the registry no longer lists): a subagent's view
  // from its own rows (none yet: empty) and processes, with how its shells ended in the chat's rows
  // (session-info/subagentScope.ts); the chat's view from its own, with its workflows. The whole
  // history's count while the registry holds only a window: the chat's adds what it left out
  // (`omitted`: each ended, no transcript task's); a subagent view's calls are all read
  // (`registryCalls`), so none of its processes is left out.
  const registryProcesses = processRegistry.processes;
  const registryListed = processRegistry.listed;
  const registryOmitted = processRegistry.omitted ?? 0;
  const scopedOwn = useMemo(
    () => (scopedKey ? transcriptBackground(scopedRows ?? []) : undefined),
    [scopedKey, scopedRows],
  );
  const chatRows = snapshot.rows;
  const scopedTasks = useMemo(() => scopedOwn && withChatEnds(scopedOwn.tasks, chatRows), [scopedOwn, chatRows]);
  const backgroundRows = useMemo(() => {
    if (scopedOwn && scopedTasks)
      return (
        backgroundRowCount(subagentProcesses(registryProcesses, scopedRows ?? []), scopedTasks, registryListed) +
        scopedOwn.scheduled
      );
    return (
      backgroundRowCount(registryProcesses, transcriptWork.tasks, registryListed, registryOmitted) +
      transcriptWork.scheduled +
      workflows.length
    );
  }, [
    scopedOwn,
    scopedTasks,
    scopedRows,
    registryProcesses,
    registryListed,
    registryOmitted,
    transcriptWork,
    workflows.length,
  ]);
  // The Inspector (Debug Settings `agent.sessionInfo`): its toggle the first of the header's
  // top-right icons, the panel beside or over the chat. On, it takes the summary card's place.
  const sessionInfoSummary = sessionInfoSnapshot.summary;
  // On this Mac by the Session Info row's own source (chatMachine.ts): never a chat over a remote route.
  const sessionInfoLocal = chatOnThisMac(
    sessionInfoSummary,
    sessionInfoSnapshot.peerKinds,
    chatPlace(sessionInfoSnapshot),
  );
  // A subagent's edited files are in its own rows, which the chat's diff (openOutput) never reads:
  // they open the Changes viewer beside the chat on the subagent's folder, its worktree when it has
  // one (a chat on this Mac; another machine's folders are not here). The folder is found on the
  // click, not on every render: finding it reads the subagent's rows.
  const openSubagentOutput =
    sessionInfoSubagent && sessionInfoLocal
      ? () => {
          const cwd = subagentChangesFolder(sessionInfoSummary, sessionInfoSubagent);
          if (cwd) ignoreFailure(callNative("pane.action", { id: HEADER_ACTIONS.changes, cwd, mode: "open" }));
        }
      : undefined;
  // In a narrow pane the side panel covers the whole pane, the header with it (ArtifactPanel.tsx).
  const narrowPane = useArtifactCoversPane();
  const artifactCovers = narrowPane && artifact !== undefined;
  // The event Inspector and a narrow artifact cover the chat header. Keep the
  // environment chip out of the covered surface entirely so it cannot remain in the tab order or
  // flash through the overlay.
  const environmentCovered = inspectorOpen || artifactCovers;
  const uncoverChat = useCallback(() => {
    closeInspector();
    if (artifactCovers) setArtifact(undefined);
  }, [closeInspector, artifactCovers]);
  const openWorkflowSideTab = useCallback(
    (id: string, opener?: HTMLElement) => {
      workflowSideTabOpener.current =
        opener ?? (document.activeElement instanceof HTMLElement ? document.activeElement : undefined);
      closeInspector();
      setArtifact(undefined);
      setImageView(undefined);
      setHarnessesOpen(false);
      setContextOpen(false);
      setReplaying(undefined);
      setNewTab(undefined);
      // The side tab is a full-height overlay on the right: Background tasks gives it the side.
      setBackgroundPanel(undefined);
      setWorkflowSideTabId(id);
    },
    [closeInspector],
  );
  // Labs: the chat's workflows head Session Info's Background tasks (session-info/WorkflowTasks.tsx).
  const sessionInfoWorkflows = useMemo(
    () =>
      workflows.length > 0 ? { list: workflows, onStop: stopSubagent, onOpenAgent: showWorkflowAgent } : undefined,
    [workflows, stopSubagent, showWorkflowAgent],
  );
  // What the chat was granted (header/grantsMenu.ts): revoked from the chat menu's Revoke Granted
  // Access, always there, and from Session Info's Environment when it shows; never from the
  // composer's mode menu, which lists the modes alone (Leo, 2026-10-29). The trusted grant names
  // where the answer lives (the repository, a worktree's root, the folder), from the answer just
  // given or the last read.
  const trustScope =
    trustAsk.ask?.state === "decided" && trustAsk.ask.level === "trusted" ? trustAsk.ask : trustAsk.scope;
  const trustLabel = trustScope
    ? isAgentHome(trustScope.cwd)
      ? t("trust.trustedPrivate")
      : trustedLabel(t, trustScope)
    : undefined;
  const accessGrants = chatAccessGrants(
    {
      trusted: trustAsk.trusted,
      trustLabel,
      untrust: trustAsk.undo,
      chatAllowance: Boolean(snapshot.permissionGroups?.chatAllowance),
      // A grant shown from the chat's last read until its refresh lands: removable once it is read.
      allowanceUnread: snapshot.permissionGroups?.ready === false,
      revokeAllowance: () => void callNative("chat.permission_chat.revoke", {}),
    },
    t,
  );
  // Session Info's Remote Control: the App's iPhone host switch (remoteControl.ts), for a chat on
  // this Mac; no row in Quick Chat, for a peer's or Cloud chat, or while this Mac cannot serve phones.
  const remoteControlState = useRemoteControl();
  const sessionInfoRemoteControl = useMemo(
    () =>
      !quick && sessionInfoLocal && remoteControlState
        ? { on: remoteControlState.on, set: (on: boolean) => void toggleRemoteControl(on, callNative) }
        : undefined,
    [quick, sessionInfoLocal, remoteControlState],
  );
  // Compact from Session Info's Context sends the agent's own /compact
  // with the reach a context-full failure's Compact has: only where the agent lists it, never to a
  // View Only chat or a read-only pane, never the next chat during a switch's hold (#17537 had it on
  // the ring; #20454 dropped its wiring).
  // View Prompt opens the Context screen in place of the chat; the inspector steps aside, as it does
  // for a side tab.
  const openContext = useCallback(() => {
    closeInspector();
    setContextOpen(true);
  }, [closeInspector]);
  const contextSessionId = snapshot.sessionId;
  const loadContext = useCallback(() => {
    const client = directClient.current;
    return client && contextSessionId
      ? client.contextInventory(contextSessionId)
      : Promise.reject(new Error(translate("error.notOpen")));
  }, [contextSessionId]);
  const compactOffered = offersCompact(snapshot.commands);
  const compactChat = useMemo(
    () =>
      restartChat && compactOffered
        ? () => {
            if (restartReaches(restartChat, sessionIdRef.current, directClient.current?.selectedSession))
              void compactThrough(callNative)();
          }
        : undefined,
    [restartChat, compactOffered],
  );
  const sessionInfo = useSessionInfo({
    snapshot: sessionInfoSnapshot,
    split: sessionInfoSplit,
    machineName,
    repository: githubRepository,
    cloudRepositoryAvailable,
    shell,
    grants: accessGrants,
    onOpenOutput: quick ? undefined : sessionInfoSubagent ? openSubagentOutput : openOutput,
    onOpenSourceFile: quick || !sessionInfoLocal ? undefined : (path) => openSourceFile(path, callNative),
    onOpenUrl: quick
      ? undefined
      : (url) => ignoreFailure(callNative("pane.action", { id: HEADER_ACTIONS.preview, url, mode: "open" })),
    onOpenImage: quick ? undefined : openImage,
    readPromptImage: quick ? undefined : readQueuedImage,
    processes: processRegistry,
    onStopProcess: stopProcess,
    subagents: cardSubagents,
    sessions: cardSessions,
    // acpmux takes the limit only from this Mac's app (a person-proven connection), never a Web one.
    onSetRunningLimit: snapshot.origin === "local" ? setRunningLimit : undefined,
    workflows: sessionInfoWorkflows,
    // The project opens in the Files tree as a tab right of the chat (AgentBesidePlacement); a remote
    // or cloud chat's folders are not on this Mac.
    onOpenFolder:
      quick || !sessionInfoLocal
        ? undefined
        : (path) => ignoreFailure(callNative("pane.action", { id: HEADER_ACTIONS.files, cwd: path, mode: "open" })),
    // Environment's Changes: the header's Changes counts and what it opens (the chat folder's diff
    // beside the chat), only where the header offers it.
    readChanges: quick ? undefined : readChanges,
    onOpenChanges: quick ? undefined : () => openChangesTab.current(),
    // Active chat panes do not support environment.save; the native handler accepts it only from
    // New Tab. Keep the inspector's optional callback for gallery/host integrations, but do not
    // expose a button here that would always be rejected.
    onSaveEnvironment: undefined,
    // A failed MCP server's Reconnect in Connectors, where acpmux offers it (a Claude Code chat's).
    onReconnectMcp: snapshot.reconnectsMcp ? reconnectMcp : undefined,
    remoteControl: sessionInfoRemoteControl,
    // A Usage row opens that chat, this Mac's or a peer's, beside this one or in the tab showing it.
    onOpenChat: openSenderChat,
    onCompact: compactChat,
    // Only where the chat's daemon admits this connection to its context (context/contextAccess.ts).
    onViewPrompt: quick || !contextAccess(snapshot) ? undefined : openContext,
    onShowUsage: refreshUsage,
    // Quick Chat's panel has no room beside it for the side panel.
    onOpenDocument: quick ? undefined : openArtifact,
    onShowCall: quick ? undefined : showCall,
    onShowTurn: quick ? undefined : (turnId) => showTimelineTurn.current(turnId),
    subagent: sessionInfoSubagent,
    // A turn's diff in place, the event Inspector and, in a narrow pane, the side panel take the pane
    // in the chat's place, its header and the toggle with it: the panel steps aside while they show,
    // and opening it closes them.
    covered: environmentCovered || workflowSideTab !== undefined,
    onUncover: uncoverChat,
    onBeforeOpen: clearWorkflowSideTab,
    // The Background tasks column takes the side panel's room too (backgroundTasks.css).
    beside: `${artifact?.opened ?? ""}:${backgroundOpen}`,
    // A handoff review's form is wider than the transcript's column: the chat's shift is measured against it.
    wide: reviewing,
  });
  // The summary card is the fallback surface while the Session Info feature is disabled in the
  // header state. Its open-in-pane row enables that same panel before revealing the requested list.
  const revealSessionInfo = sessionInfo.reveal;
  const openSummarySection = useCallback(
    (section: "subagents" | "tasks") => {
      if (revealSessionInfo) {
        revealSessionInfo(section);
        return;
      }
      setHeaderState({ inspector: true });
      setSessionInfoSection(section, true);
      setSessionInfoPanelOpen(true);
    },
    [revealSessionInfo],
  );
  // Labs: a workflow's card opens Session Info's Background tasks, which lists its phases and agents.
  const toggleSessionInfo = useRef(sessionInfo.toggle);
  useLayoutEffect(() => {
    toggleSessionInfo.current = sessionInfo.toggle;
  }, [sessionInfo.toggle]);
  // The native palette's page commands that apply now (paletteCommands below), by command name.
  const paletteCommands = useRef<{ sessionId: string; commands: Record<string, () => void> }>({
    sessionId: "",
    commands: {},
  });
  useEffect(() => {
    const openCard = revealSessionInfo
      ? () => {
          clearWorkflowSideTab();
          revealSessionInfo("tasks");
        }
      : workflowLabsEnabled
        ? openWorkflowSideTab
        : undefined;
    configureWorkflowCardOpen(openCard);
    return () => configureWorkflowCardOpen(undefined);
  }, [clearWorkflowSideTab, openWorkflowSideTab, revealSessionInfo, workflowLabsEnabled]);
  useEffect(() => {
    configureWorkflowCardSideTab(workflowLabsEnabled ? openWorkflowSideTab : undefined);
    return () => configureWorkflowCardSideTab(undefined);
  }, [openWorkflowSideTab, workflowLabsEnabled]);
  // The running line's counts (conversation/WorkingFor.tsx), with the tray off (Debug Settings):
  // the subagents still running, the background commands that have not ended and the started chats
  // that run. A count of one opens its subagent, the command's row or the chat; of several, the
  // Inspector's section that lists them all (the summary card with the Inspector off). With the tray
  // on (the default) the tray is the count, in a turn and between turns, so the line counts nothing.
  // `child`: a row of the subagent view shown then, which only that view reveals.
  const [revealRow, setRevealRow] = useState<{ rowId: string; key: number; toolId: string; child?: true }>();
  const counting = snapshot.isWorking && !subagentTray;
  // chatAgents already lists every subagent and changes when one's state does.
  const runningAgents = useMemo(() => (counting ? chatAgents.filter(running) : NO_AGENTS), [counting, chatAgents]);
  const runningCommands = counting ? runningCommandList : NO_COMMANDS;
  const runningSessions = counting ? runningChildSessions : NO_STARTED;
  // The tray's lines (subagents/runningTray.ts): the subagents, the background commands
  // (session-info/processes.ts `backgroundCommands`, the registry's merged with the transcript's) and
  // the started chats that run. A new list only when what it shows changes, so streamed text never redraws the tray.
  const commandsKey = runningCommandList
    .map((task) =>
      [
        task.id,
        task.command,
        task.description ?? "",
        task.startedAt ?? "",
        task.processId ?? "",
        task.toolCallId ?? "",
      ].join("\u0000"),
    )
    .join("\u0001");
  // Labs: a workflow has its card in the transcript and its panel, never a tray row, running or ended.
  const trayAgents = useMemo(
    () => (workflowLabsEnabled ? chatAgents.filter((agent) => agent.kind !== "workflow") : chatAgents),
    [workflowLabsEnabled, chatAgents],
  );
  const trayList = useMemo(
    () => (subagentTray ? trayItems(trayAgents, runningCommandList, childSessions, snapshot.isWorking) : []),
    // eslint-disable-next-line react-hooks/exhaustive-deps -- runningCommandList is new on every snapshot; its key is not
    [subagentTray, trayAgents, commandsKey, childSessions, snapshot.isWorking],
  );
  // What ended stays in the hat a while as done, failed or stopped, then goes (subagents/trayLinger.ts;
  // Leo, 2026-11-07: "it's probably better to let them expire after a while. But the key point: after
  // a while. Okay, they, like, disappear instantly"): the subagents and started chats that ended, and
  // the background commands that ended (the registry's, with their exit and end, and the transcript's).
  // Never in the header's running count. A new list only when what ended changes, never per token.
  const endedCommandList = useMemo(
    () =>
      subagentTray
        ? backgroundCommands(processRegistry.processes, transcriptTasks, processRegistry.listed).filter(
            (command) => command.state !== "running",
          )
        : NO_COMMANDS,
    [subagentTray, processRegistry, transcriptTasks],
  );
  // Built when the list changes, never per render: a chat's ended commands can number thousands.
  const endedCommandsKey = useMemo(
    () =>
      endedCommandList
        .map((task) =>
          [
            task.id,
            task.state,
            task.command,
            task.description ?? "",
            task.startedAt ?? "",
            task.endedAt ?? "",
            task.toolCallId ?? "",
            task.subagent ?? "",
          ].join("\u0000"),
        )
        .join("\u0001"),
    [endedCommandList],
  );
  const endedCommandItems = useMemo((): TrayItem[] => {
    const byId = new Map(trayAgents.map((agent) => [agent.id, agent]));
    return endedCommandList.map((command) => {
      const owner = command.subagent === undefined ? undefined : byId.get(command.subagent);
      return { kind: "command", id: command.id, command, ...(owner ? { owner } : {}) };
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps -- endedCommandList is new on every snapshot; its key is not
  }, [endedCommandsKey, trayAgents]);
  const endedTray = useMemo(
    () =>
      subagentTray
        ? [...endedCommandItems, ...finishedTrayItems(trayAgents, childSessions)].filter(
            (item) => !endedInFailure(item),
          )
        : [],
    [subagentTray, endedCommandItems, trayAgents, childSessions],
  );
  const lingerLive = useMemo(() => trayList.map(trayItemKey), [trayList]);
  const lingerEnded = useMemo(
    () => endedTray.map((item) => ({ key: trayItemKey(item), endedAt: trayItemEnd(item) })),
    [endedTray],
  );
  // The hat is open or under the pointer: nothing expires until it lets go (SubagentTray.tsx `onHold`).
  const [hatHeld, setHatHeld] = useState(false);
  // The hat could be seen (SubagentTray.tsx `onSeen`): the grace counts only while it could, so what
  // ended while the person was in another window, or the hat was tucked away, waits for them.
  const [hatSeen, setHatSeen] = useState(false);
  // On the session's clock, as the ends are stamped (a peer's may run behind or ahead of this one).
  const lingerClock = useMemo(
    () => ({ offsetMs: snapshot.clockOffsetMs ?? 0, seen: hatSeen }),
    [snapshot.clockOffsetMs, hatSeen],
  );
  const lingering = useTrayLinger(shownSessionId, lingerLive, lingerEnded, hatHeld, lingerClock);
  const trayFinished = useMemo(
    () => lingeringTrayItems(endedTray, lingering.kept, lingering.ends),
    [endedTray, lingering],
  );
  // The turn's generated output tokens so far, said after its time (direct.ts `turnTokens`).
  const turnTokens = snapshot.isWorking ? snapshot.turnTokens : undefined;
  // Its output apart from what it read, when every call carried the split; held by its numbers, as
  // a new snapshot's split is a new object.
  const split = snapshot.isWorking ? snapshot.turnTokenSplit : undefined;
  const splitKey = split ? `${split.output}/${split.input}/${split.cacheRead}/${split.cacheWrite}` : "";
  const counted = useRef({
    summary: snapshot.summary,
    runningAgents,
    runningCommands,
    runningSessions,
    sourceRows,
    childRows,
    transcriptRows,
    summaryCard,
    sessionInfo,
    backgroundCommandList: runningCommandList,
  });
  counted.current = {
    summary: snapshot.summary,
    runningAgents,
    runningCommands,
    runningSessions,
    backgroundCommandList: runningCommandList,
    sourceRows,
    childRows,
    transcriptRows,
    summaryCard,
    sessionInfo,
  };
  const sendAgainConfig = useRef({
    owner: restartChat,
    rows: snapshot.rows,
    models: retryModels,
    harness: retryHarnessName,
    top: retryTop,
  });
  useLayoutEffect(() => {
    sendAgainConfig.current = {
      owner: restartChat,
      rows: snapshot.rows,
      models: retryModels,
      harness: retryHarnessName,
      top: retryTop,
    };
  }, [restartChat, snapshot.rows, retryModels, retryHarnessName, retryTop]);
  // A `?message=<id>` link's row (links.ts `revealMessageWhenShown`): the transcript scrolls it in
  // by its place in the chat, so a message far above the view works, where its element does not
  // exist yet. One message can span several rows (a tool call splits it): `messageRevealTarget`
  // takes a drawn one, and opens the turn's "Worked for" when the fold hides them all, the way a
  // running line's count does. The reveal lets go after a moment, as a count's does: it stands in
  // for Find's own target while it is set, and a target that never let go would scroll back to
  // this row whenever its id is drawn again.
  const showRows = (pick: (rows: readonly AcpmuxRow[]) => readonly string[]) => {
    const { sourceRows: rows, transcriptRows: shown } = counted.current;
    const picked = pick(rows);
    for (const id of picked) showHeldRuns(id);
    const target = messageRevealTarget(rows, shown, picked);
    if (target === undefined) return undefined;
    if (target.fold !== undefined) openFold(target.fold);
    if (target.run !== undefined) openFold(target.run);
    for (const fold of target.also ?? []) openFold(fold);
    const key = Date.now();
    setRevealRow({ rowId: target.rowId, key, toolId: "" });
    setTimeout(() => setRevealRow((current) => (current?.key === key ? undefined : current)), REVEAL_HOLD_MS);
    return target.rowId;
  };
  showMessage.current = (messageId) => showRows(() => directClient.current?.rowsOfMessage(messageId) ?? []);
  showSaid.current = (said) => showRows((rows) => saidRows(rows, said));
  // Jump to new (conversation/SinceDivider.tsx): "New since you looked" is a row like any other, so
  // the transcript brings it in by its place in the chat even when it is far above the view.
  const sinceKey = snapshot.sinceKey;
  const jumpToSince = useCallback(() => {
    const key = Date.now();
    setRevealRow({ rowId: SINCE_DIVIDER, key, toolId: "" });
    setTimeout(() => setRevealRow((current) => (current?.key === key ? undefined : current)), REVEAL_HOLD_MS);
  }, []);
  // A link waiting on replay retries against committed rows, without a polling timer.
  useLayoutEffect(() => notifyRevealRowsChanged(), [sourceRows, transcriptRows]);
  // A shell's Bash row, opening its turn's "Worked for" when that is closed and the run that
  // holds the call. The reveal lets go after a moment, so the run closes again like any other.
  // False when no loaded row holds the call (a command only the registry knows).
  const showToolRow = useCallback(
    (toolId: string | undefined, startedAt?: number) => {
      // A subagent's view finds its own calls (its footer's Timeline, subagentRows.ts `subagentFooter`).
      const { sourceRows, childRows: child, transcriptRows: shown } = counted.current;
      const rows = child ?? sourceRows;
      // A harness can reuse a call id in a later prompt: the call that started at `startedAt` (a
      // waterfall bar's, TurnWaterfall.tsx) is that one, else the first call with the id.
      const holds = (row: AcpmuxRow, timed: boolean) =>
        Boolean(row.items?.some((item) => item.tool?.id === toolId && (!timed || item.tool?.startedAt === startedAt)));
      const timed = toolId && startedAt !== undefined ? rows.findIndex((row) => holds(row, true)) : -1;
      const index = timed >= 0 ? timed : toolId ? rows.findIndex((row) => holds(row, false)) : -1;
      const row = rows[index];
      if (!row || !toolId) return false;
      showHeldRuns(row.id);
      if (!shown.some((drawn) => isFindRow(drawn, row.id))) {
        for (const fold of hiddenRowFolds(rows, shown, index)) openFold(fold);
      }
      const key = Date.now();
      setRevealRow({ rowId: row.id, key, toolId, ...(child && { child: true }) });
      setTimeout(() => setRevealRow((current) => (current?.key === key ? undefined : current)), REVEAL_HOLD_MS);
      return true;
    },
    [openFold, showHeldRuns],
  );
  showCallRef.current = showToolRow;
  // Workflow transcript links use the adapter's stable row id. Reveal the row with the same
  // bounded hold as the running-line links; if its turn is folded, open that fold first.
  const openWorkflowTranscript = useCallback(
    (rowId: string) => {
      const { sourceRows: rows, transcriptRows: shown } = counted.current;
      const index = rows.findIndex((row) => row.id === rowId);
      const row = rows[index];
      if (!row) return;
      showHeldRuns(row.id);
      if (!shown.some((drawn) => isFindRow(drawn, row.id))) {
        for (const fold of hiddenRowFolds(rows, shown, index)) openFold(fold);
      }
      const key = Date.now();
      setRevealRow({ rowId: row.id, key, toolId: "" });
      setTimeout(() => setRevealRow((current) => (current?.key === key ? undefined : current)), REVEAL_HOLD_MS);
    },
    [openFold, showHeldRuns],
  );
  // Load the clicked turn before asking the virtual transcript to draw it. The existing
  // history loader stops on a changed chat or a page that makes no progress.
  showTimelineTurn.current = (turnId) => {
    const client = directClient.current;
    const chat = client?.selectedSession;
    const span = counted.current.summary?.timeBreakdown?.spans.find((item) => item?.turnId === turnId);
    if (!client || !span) return;
    void client
      .loadThrough(span.turnSeq)
      .then((held) => {
        if (!held || client !== directClient.current || chat !== client.selectedSession) return;
        void revealMessageWhenShown(
          turnId,
          () => {
            if (chat !== client.selectedSession) return undefined;
            const row = counted.current.sourceRows.find((item) => item.turnId === turnId);
            if (!row) return undefined;
            openWorkflowTranscript(row.id);
            return row.id;
          },
          document,
          { chat: () => directClient.current?.selectedSession },
        );
      })
      .catch(() => undefined);
  };
  const workflowActionsFor = useCallback(
    (workflow: WorkflowSummary) => ({
      onOpenTranscript: openWorkflowTranscript,
      onOpenAgent: showWorkflowAgent,
      onPullAgent: readWorkflowAgent,
      // Keep Claude's stop_task route and the workflow node identity intact.
      onStop: stopSubagent
        ? () => {
            void stopSubagent(workflow.id).catch(() => undefined);
          }
        : undefined,
      onDraftWorkflow: (resume: boolean) => {
        const client = directClient.current;
        if (!client || client.selectedSession !== workflow.sessionId) return false;
        // The fold has no scriptPath/args launch contract. Refuse Resume visibly until a
        // provider supplies it; Run again remains an explicit composer message.
        if (resume) return false;
        composerHandle.current?.prefill(t("workflow.runAgainPrompt", { name: workflow.title }));
        return composerHandle.current !== null;
      },
    }),
    [openWorkflowTranscript, stopSubagent, t, showWorkflowAgent, readWorkflowAgent],
  );
  // The pages the chat's running background commands serve (conversation/PreviewChip.tsx). A Cloud
  // chat's page opens through the Cloud's preview (its localhost is not this Mac's); any other opens
  // beside the chat, as Session Info's Servers row does. Quick Chat has no side to open it in.
  // Keyed by the pages alone: another process's update leaves the rows' context as it was.
  const previews = useMemo(() => previewsOf(processRegistry.processes), [processRegistry.processes]);
  const previewsKey = [...previews.byTool].map(([tool, preview]) => `${tool}=${preview.url}`).join("\n");
  const latestPreview = previews.latest?.url;
  const previewChips = useMemo<PreviewChips | undefined>(
    () => {
      if (quick || (previews.byTool.size === 0 && !previews.latest)) return undefined;
      return {
        ...previews,
        open: (preview) =>
          void (
            cloudPreviewChat
              ? postNative("cloud.preview.open", { port: preview.port })
              : callNative("pane.action", { id: HEADER_ACTIONS.preview, url: preview.url, mode: "open" })
          ).catch(() => undefined),
      };
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps -- `previews` is new on every process update; its key is not
    [quick, previewsKey, latestPreview, cloudPreviewChat],
  );
  // "Run on a bigger machine" on this chat's slow commands (conversation/RunElsewhere.tsx): a
  // chat on this machine only (a Cloud chat's commands already run on its machine; Quick Chat has
  // no rows to put it under). One store per chat, so another chat's runs never show here.
  const runChat = snapshot.sessionId;
  const runElsewhere = useMemo<RunElsewhere | undefined>(() => {
    if (quick || cloudPreviewChat || !runChat) return undefined;
    const call = <T,>(use: (c: NonNullable<typeof directClient.current>) => Promise<unknown>) => {
      const c = directClient.current;
      return (c ? use(c) : Promise.reject(new Error(translate("runElsewhere.disconnected")))) as Promise<T>;
    };
    return {
      store: new RunElsewhereStore(),
      client: {
        plan: (command) => call<RunPlan>((c) => c.planRunElsewhere(runChat, command)),
        start: (command, machine, digest, send) =>
          call<{ task: { id: string } }>((c) => c.startRunElsewhere(runChat, command, machine, digest, send)).then(
            (r) => r.task,
          ),
        output: (taskId, fromByte) => call<RunOutput>((c) => c.bgOutput(runChat, taskId, fromByte)),
        stop: (taskId) => call((c) => c.bgStop(runChat, taskId)),
      },
    };
    // The client is read at each call, so a reconnect keeps the chat's runs and their rows.
  }, [quick, cloudPreviewChat, runChat]);
  const workingCounts = useMemo<WorkingCounts>(() => {
    return {
      agents: runningAgents.length,
      commands: runningCommands.length,
      sessions: runningSessions.length,
      tokens: turnTokens,
      split,
      ...(previewChips?.latest
        ? { preview: { url: previewChips.latest.url, open: () => previewChips.open(previewChips.latest!) } }
        : {}),
      openAgents: () => {
        const {
          runningAgents: agents,
          runningSessions: sessions,
          summaryCard: card,
          sessionInfo: panel,
        } = counted.current;
        // One count with the chats it started (WorkingFor.tsx `workingParts`): one subagent alone opens.
        if (agents.length === 1 && sessions.length === 0) showSubagent(agents[0]!.id);
        // The Inspector takes the summary card's place while it is on (its panel is never drawn).
        else if (panel.reveal) panel.reveal("subagents");
        else card.show();
      },
      openCommands: () => {
        const { runningCommands: commands, summaryCard: card, sessionInfo: panel } = counted.current;
        if (commands.length === 1 && showToolRow(commands[0]!.toolCallId)) return;
        if (panel.reveal) panel.reveal(backgroundSection(commands));
        else card.show();
      },
      openSessions: () => {
        const { runningSessions: sessions, summaryCard: card, sessionInfo: panel } = counted.current;
        if (sessions.length === 1) openOfferChat(sessions[0]!.sessionId);
        else if (panel.reveal) panel.reveal("subagents");
        else card.show();
      },
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the split is new on every snapshot; its key is not
  }, [
    runningAgents.length,
    runningCommands.length,
    runningSessions.length,
    turnTokens,
    splitKey,
    showSubagent,
    showToolRow,
    previewChips,
  ]);
  // A tray command opens its terminal beside the chat; where none opens (a peer's chat, or
  // a command only the transcript knows), the Bash call that started it in the transcript; with no
  // call loaded either, the summary card, which lists it, or, while the Inspector takes the card's
  // place, its section that lists it (Background tasks, a dev server's included).
  const openTrayCommand = useCallback(
    (command: BackgroundCommand) => {
      const local = opensProcessTerminal(counted.current.summary);
      void openCommand(command.toolCallId, { local, showCall: showToolRow }).then((opened) => {
        if (opened !== "none") return;
        const { summaryCard: card, sessionInfo: panel } = counted.current;
        // The section that lists it (processes.ts `backgroundSection`).
        if (panel.reveal) panel.reveal(backgroundSection([command]));
        else card.show();
      });
    },
    [showToolRow],
  );
  // The Quick Composer cannot show the Harnesses page: it registers no opener, so its + hides.
  useEffect(
    () =>
      quick
        ? undefined
        : registerHarnessesPage(() => {
            setupContinuation.current = undefined;
            setupStart.current = undefined;
            setHarnessesOpen(true);
          }),
    [quick],
  );
  // `/btw` opens a read-only side session beside the chat; the Quick Composer has none.
  const opensSideSessions = !quick;
  const opensSideSessionsRef = useRef(opensSideSessions);
  opensSideSessionsRef.current = opensSideSessions;
  // A side session (New side chat's, or one `/btw` opened): its composer answers in it.
  const isSideSession = snapshot.sessions.some(
    (session) => session.sessionId === snapshot.sessionId && session.side === true,
  );
  // Start Agent's floating chat (cx-b9qi): the App says when its panel holds this chat.
  const floatingHold = useFloatingState();
  const surfaceRef = useRef(surface);
  surfaceRef.current = surface;
  // Escape that no menu, picker or palette took hides the Quick Composer, keeping its draft.
  // Start Agent (cx-hkat): Return in the Quick Composer starts its chat in the background (the
  // host puts it in the sidebar), ⌘Return starts it and opens it in a window. Each waits until the
  // prompt is on its way (closing the page sooner drops it) and the chat has a session; a send
  // that fails, or Escape, cancels the hand-off.
  const handOff = useRef<{
    pending: boolean;
    landed: boolean;
    /// Return's hand-off also waits until acpmux took the prompt: one it refuses (folder trust,
    /// the remote guard) stays in this panel with its question.
    background?: { name?: string; accepted: boolean };
  }>({ pending: false, landed: false });
  const quickCwd = useRef<string | undefined>(undefined);
  const flushOpenInWindow = () => {
    const sessionId = sessionIdRef.current;
    if (!handOff.current.pending || !handOff.current.landed || !sessionId) return;
    const background = handOff.current.background;
    if (background && !background.accepted) return;
    handOff.current.pending = false;
    if (background) postStartInBackground(sessionId, quickCwd.current, background.name);
    else postOpenInWindow(sessionId);
  };
  /// Return's send in the Quick Composer: hand the chat to the sidebar once it lands.
  const startInBackground = (text: string, taken: Promise<unknown>) => {
    const next = {
      pending: true,
      landed: false,
      background: { name: quickChatName(text), accepted: false },
    };
    handOff.current = next;
    void taken.then(
      () => {
        if (handOff.current !== next) return;
        next.background.accepted = true;
        flushOpenInWindow();
      },
      () => undefined,
    );
  };
  const promptLanded = useRef(() => {});
  promptLanded.current = () => {
    handOff.current.landed = true;
    flushOpenInWindow();
  };
  const cancelOpenInWindow = () => {
    handOff.current.pending = false;
  };
  const openInWindow = (sent: boolean) => {
    if (sent) handOff.current = { pending: true, landed: false };
    else if (snapshot.sessionId) postOpenInWindow(snapshot.sessionId);
  };
  // The started chat's folder: the session's, else the one picked before the first send.
  // A peer's (SSH, Cloud) folder is a path on that machine: the host's workspace gets none.
  const remoteChat = Boolean(snapshot.summary?.peer) || snapshot.summary?.hostKind === "cloud";
  // A guest from another harness runs on this machine's daemon, which the pane reaches only for a
  // local chat (a remote chat's wire refuses `_acpmux/btw`), and only one that serves guests. Else
  // an @harness is ordinary text.
  const guestsHere =
    !remoteChat &&
    snapshot.origin !== "remote" &&
    snapshot.origin !== "peer" &&
    supportsBtwGuest(directClient.current?.capabilities);
  const remoteRef = useRef(remoteChat);
  remoteRef.current = remoteChat;
  // The repo tour's offer and Start (repoTour/) only for a chat on this Mac: not a peer's or Cloud
  // chat, and not one whose page talks to another machine's acpmux (chatMachine.ts `elsewhere`).
  const tourHere = !remoteChat && snapshot.origin !== "remote" && snapshot.origin !== "peer";
  // The one-time share nudge (share/shareNudgeModel.ts): the first chat on this Mac, its first reply.
  const shareNudgeTipsOn = useFeatureTipsOn();
  const shareNudge = useShareNudge(
    snapshot,
    { nativeHost: hasNativeHost(), quick, subagentPane: readOnlySubagent, tipsOn: shareNudgeTipsOn },
    paneTipHost,
  );
  quickCwd.current = remoteChat ? undefined : (snapshot.summary?.cwd ?? projectDraft);
  useEffect(flushOpenInWindow, [snapshot.sessionId]);
  useEscapeToDismiss(quick, () => {
    cancelOpenInWindow();
    void callNative(QUICK_MESSAGES.dismiss).catch(() => undefined);
  });
  const rowsRef = useRef<readonly AcpmuxRow[]>(initialChat?.snapshot.rows ?? []);
  /// The direct client's snapshot the pane last drew; a newer one that only grows the streaming
  /// reply's text goes to that row instead (streamingRow.ts).
  const drawnSnapshot = useRef<AcpmuxSnapshot | undefined>(undefined);
  /// The direct client's newest snapshot, drawn or not: a running command's output update is told
  /// apart from the one before it (liveToolOutput.ts `toolOutputOnly`).
  const receivedSnapshot = useRef<AcpmuxSnapshot | undefined>(undefined);
  /// The draw (liveToolOutput.ts `redraw`) of the snapshot the pane set last.
  const toolOutputEpoch = useRef(0);
  // The pane drew a new snapshot: its rows hold every call's output as of that draw again.
  useLayoutEffect(() => liveToolOutput.settle(toolOutputEpoch.current), [clientSnapshot]);
  /// The pane's transition draw of a snapshot that has not committed yet (paneSnapshotLane.ts).
  const [pendingPaneDraw] = useState(() => new PendingPaneDraw());
  useLayoutEffect(() => pendingPaneDraw.committed(clientSnapshot), [pendingPaneDraw, clientSnapshot]);
  const readSendAgain = useCallback((): SendPromptAgainState => {
    const current = snapshotRef.current;
    const config = sendAgainConfig.current;
    return {
      sessionId: current?.sessionId,
      selectedSessionId: directClient.current?.selectedSession,
      drawnSessionId: sessionIdRef.current,
      canSend: Boolean(
        current &&
        config.owner === current.sessionId &&
        config.rows === current.rows &&
        linkUp(current.connection) &&
        !current.summary?.watching &&
        remoteComposer(current).canSend &&
        harnessSwitch.view().intent === undefined &&
        !counted.current.childRows,
      ),
      rows: counted.current.transcriptRows,
      models: config.models,
      currentModel: current ? applySwitch(current, harnessSwitch.view(), catalogRef.current).summary?.model : undefined,
      harness: config.harness,
      top: config.top,
    };
  }, [harnessSwitch]);
  const readInterruptedResume = useCallback((): InterruptedResumeState => {
    const state = readSendAgain();
    const current = snapshotRef.current;
    const goal = current?.summary?.goal;
    return {
      ...state,
      family: current?.summary?.family ?? current?.summary?.harness,
      canResume: Boolean(
        state.canSend &&
        current &&
        !current.isWorking &&
        !current.queue.some((entry) => !entry.heldByStop && !entry.held && !entry.awaitingOwner) &&
        goal?.status !== "active" &&
        goal?.status !== "running",
      ),
    };
  }, [readSendAgain]);
  const interruptedResumeOwner = interruptedResumeTarget({
    sessionId: snapshot.sessionId,
    selectedSessionId: directClient.current?.selectedSession ?? (previewHost ? snapshot.sessionId : undefined),
    drawnSessionId: shownSessionId,
    canResume: Boolean(
      restartChat &&
      !snapshot.isWorking &&
      !queueRunsNext &&
      snapshot.summary?.goal?.status !== "active" &&
      snapshot.summary?.goal?.status !== "running",
    ),
    family: snapshot.summary?.family ?? snapshot.summary?.harness,
    rows: turnRowsShown,
  });
  /// The chat menu shows New side chat: the right-click menu then opens one from any turn that forks.
  const opensSideChat = useRef(false);
  const archiveChatRef = useRef<(() => void) | undefined>(undefined);
  const recheckCloudChat = useCallback(async () => {
    // A machine woken while the pane's link was down: connect again now, not at the backoff's turn.
    if (!directClient.current) retryHost.current?.();
    await directClient.current?.recheckMissing();
  }, []);
  // An open that failed on a socket still open (direct.ts emits "failed") read no chat: its
  // machine may be paused, so recovery reads it as it does a lost link.
  const cloudLinkUp = connected && snapshot.connection !== "failed";
  const cloudRecoveryShows = cloudChatRecoveryActive(
    !!snapshot.unavailable,
    snapshot.sessionId,
    snapshot.rows.length,
    cloudLinkUp,
    freshView,
  );
  /// Prompts sent in this Cloud chat wait for its machine to wake (cloudWake.ts): the recovery reads
  /// the machine and connects again meanwhile, also over a transcript the pane still shows.
  const [cloudWaking, setCloudWaking] = useState(false);
  /// The person's typing woke this chat's paused Cloud machine before any send (cloudWake.ts
  /// `cloudTypingWakes`): the recovery reads the machine and connects again meanwhile.
  const [cloudTypeWaking, setCloudTypeWaking] = useState(false);
  /// The chat whose machine typing woke in this stretch of its sleep: one wake per sleep, not per key.
  const cloudTypeWoke = useRef<string | undefined>(undefined);
  const cloudRecovery = useCloudChatRecovery({
    cloud: cloudChatIdentity,
    session: snapshot.missingSession ?? snapshot.sessionId,
    active: cloudRecoveryShows || cloudWaking || cloudTypeWaking,
    recheck: recheckCloudChat,
  });
  const cloudUnavailable =
    cloudRecoveryShows && (cloudRecovery.state === "paused" || cloudRecovery.state === "deleted")
      ? cloudChatUnavailable(snapshot.unavailable ?? { reason: "offline" }, cloudRecovery.state, machineName)
      : snapshot.unavailable;
  /// The chat a send now wakes its Cloud machine for (cloudWake.ts), or undefined.
  const cloudWakeState: CloudWakeState = {
    cloud: cloudChatIdentity !== undefined,
    chat: snapshot.sessionId ?? snapshot.missingSession,
    // `connected`, not `cloudLinkUp`: a prompt's own failure on an open socket also reads "failed",
    // and that chat's machine is live.
    linkUp: connected && Boolean(window.cmuxAcpmuxActions?.["chat.send"]),
    paused: cloudRecovery.state === "paused",
    unavailable: !!snapshot.unavailable,
  };
  const cloudWakeChat = cloudSendWakes(cloudWakeState);
  // A typing wake lasts while its chat waits for the machine: the chat back (or another shown)
  // ends it, and the next sleep may be woken by typing again.
  useEffect(() => {
    if (cloudWakeChat === cloudTypeWoke.current) return;
    cloudTypeWoke.current = undefined;
    setCloudTypeWaking(false);
  }, [cloudWakeChat]);
  const hasTray = !quick && !freshView && (trayList.length > 0 || trayFinished.length > 0 || hatPlan !== undefined);
  // The tray's motion (subagents/trayMotion.tsx): the chat on screen as of this render, which the
  // tray reads as it goes (it plays its exit only while its own chat still shows), and the chat that
  // last rendered without one (a tray that appears in it eases in; one a chat opens with is there).
  // A chat that shows again starts over: its tray, if any, is simply there.
  const trayChat = useRef(shownSessionId);
  const trayAbsentIn = useRef<string | undefined>(undefined);
  if (trayChat.current !== shownSessionId) trayAbsentIn.current = undefined;
  trayChat.current = shownSessionId;
  const trayEnters = shownSessionId !== undefined && trayAbsentIn.current === shownSessionId;
  // Absence counts only once the chat's own rows are read: a partial snapshot during a slow switch
  // would make a tray it already had look new.
  if (!hasTray && snapshot.chatRead === true) trayAbsentIn.current = shownSessionId;
  // A chat switch, or the tray moving to another placement (another host), is not the tray leaving:
  // its kept copy goes before the frame paints.
  useLayoutEffect(() => settleTrayExit(), [shownSessionId, trayPlacement]);
  const trayNode = hasTray ? (
    <BackgroundTaskOutputContext.Provider value={backgroundTaskOutput}>
      <SubagentClockContext.Provider value={snapshot.clockOffsetMs ?? 0}>
        {/* A subagent naming no harness draws the chat's mark, as in the transcript. */}
        <SubagentHarnessContext.Provider value={knownMark(snapshot.summary?.harness, snapshot.summary?.family)}>
          <SubagentTray
            key={shownSessionId}
            chat={shownSessionId}
            items={trayList}
            finished={trayFinished}
            working={snapshot.isWorking}
            waiting={waitingAgents}
            onOpen={showSubagent}
            onOpenCommand={openTrayCommand}
            canOpenTerminal={opensProcessTerminal(snapshot.summary)}
            canReadTail={
              chatProcessesHere(snapshot.summary) &&
              clientEpoch > 0 &&
              directClient.current !== undefined &&
              backgroundTaskOutput !== undefined
            }
            onOpenSession={openOfferChat}
            onOpenPanel={quick ? undefined : openBackgroundPanel}
            stop={stopSubagent}
            stopProcess={stopProcess}
            resume={resumeActions}
            placement={trayPlacement}
            shown={trayChat}
            enters={trayEnters}
            plan={hatPlan}
            planEarlier={hatEarlier}
            planKept={hatKept}
            onTuck={trayPlacement === "tray" ? tuckTray : undefined}
            tuckSide={trayHandle}
            onHold={setHatHeld}
            onSeen={setHatSeen}
          />
        </SubagentHarnessContext.Provider>
      </SubagentClockContext.Provider>
    </BackgroundTaskOutputContext.Provider>
  ) : null;
  /// The composer's prompt, which dictation writes into.
  const prompt = useRef<MarkdownFieldHandle>(null);
  /// The composer itself, which takes back prompts a harness switch held; prompts handed back
  /// while it is not mounted (a handoff review) go in when it mounts.
  /// The person's click on a Cloud start's question (CloudStartAsk): the host takes it only from this
  /// pane and only with the click's own gesture; false lets the card's buttons take another click.
  const answerCloudStart = (id: string, button: string): Promise<boolean> =>
    cloudStart?.state === "starting"
      ? callNative("cloud.answerStart", { key: cloudStart.key, id, answer: button }).then(
          () => true,
          () => false,
        )
      : Promise.resolve(false);
  /// Retry on a failed Cloud start: the composer still holds its prompt, and sending it again keys the same
  /// start (cloudRun.ts `cloudStartKeys`), so the host reaches the machine the first try made.
  /// A Retry keeps the start's own folder: a start the too-big card sent without a folder retries without one, never
  /// from the composer's folder the preflight refused (Codex review F2 on #40957).
  const retryCloudStart = () => {
    if (cloudRetryFolder.current) cloudFolderOnce.current = cloudRetryFolder.current;
    sendStartPrompt();
  };
  /// The folder the next Cloud send names instead of the composer's (a too-big folder's card: a repository inside
  /// it, another folder, or none), taken once by that send.
  const cloudFolderOnce = useRef<{ cwd: string } | { home: true } | undefined>(undefined);
  /// The too-big card's way on: the same prompt, sent again in `folder` (a new start: another folder is another key).
  const sendCloudIn = (folder: { cwd: string } | { home: true }) => {
    cloudFolderOnce.current = folder;
    sendStartPrompt();
  };
  /// A repository inside the folder, or a folder the person browses to: picked as the chat's folder (granted to the
  /// tab, shown in the composer), then sent from the pick's acceptance, so a pick the host refuses, one it only asks
  /// to confirm, or one a newer pick replaced sends nothing (Codex review F3 on #40957).
  const sendCloudInPicked = (cwd: string) => {
    void chooseProject(cwd, undefined, undefined, (folder) => sendCloudIn({ cwd: folder }));
  };
  const cloudTooBigActions = {
    onPickRepo: sendCloudInPicked,
    onPickFolder: () => {
      void callNative<{ cwd?: string }>("project.browse").then(
        (result) => result?.cwd && sendCloudInPicked(result.cwd),
        () => undefined,
      );
    },
    onStartWithoutFolder: () => sendCloudIn({ home: true }),
  };
  /// "This team has no Cloud plan": switch to the person's own team and send the same prompt again.
  const switchTeamAndRetry = (team: { id: string }) => {
    // The next Cloud send takes it (a send the composer holds for its files goes a moment later);
    // leaving Cloud or this chat drops it.
    cloudSwitchTeam.pick(team.id);
    retryCloudStart();
  };
  /// What the new chat shown leaves when its tab opens another chat (set below, cmux#32276).
  const newChatLeftover = useRef<() => { leave: () => void; cancel: () => void } | undefined>(() => undefined);
  const heldBack = useRef<{ text: string; attachments: ComposerAttachment[] }[] | undefined>(undefined);
  /// Quote in Reply picks made while no composer is mounted (a Sandboxed receipt or a handoff review
  /// in its place): they go in after the draft, in order, when it mounts (composerRestore.ts).
  const heldQuotes = useRef<string[] | undefined>(undefined);
  // The subagent pane's composer (Composer.tsx `relay`) while it shows: Quote in Reply goes there,
  // never held for the chat's composer, whose handle it never is (its held prompts are the chat's).
  const subagentComposer = useRef<ComposerHandle | null>(null);
  const quoteReply = useCallback((markdown: string) => {
    if (subagentComposer.current) subagentComposer.current.quoteReply(markdown);
    else quoteIntoComposer(composerHandle, heldQuotes, markdown);
  }, []);
  const [startingSends] = useState(
    () =>
      new StartingSends(
        setStartingRows,
        (text, attachments, error) => {
          // A prompt kept as its own failed row or in the transcript stays there; one a harness switch
          // handed back is in the composer already.
          if (keptInChat(error) || (error as { handedBack?: unknown } | null)?.handedBack === true) return;
          if (composerHandle.current) composerHandle.current.restore(text, attachments);
          else heldBack.current = [...(heldBack.current ?? []), { text, attachments }];
        },
        () => ({ chat: sessionIdRef.current || undefined, visit: directClient.current?.selectionToken ?? 0 }),
      ),
  );
  // Leo 2026-10-21 (P0): a pending folder trust question never blocks sending or steering. A
  // prompt sent while the folder's trust holds prompts (its question open, or Not now) waits in the
  // pane and goes, in order, after Trust (trustHeld.ts). acpmux lets a chat whose agent already
  // runs take prompts while the question is open (only Not now refuses them: `trust_gate.rs`
  // pending_passes, #23792), so its prompts and steers go now. The pane reads that from the chat's
  // turns; a chat it misjudges (an adopted conversation's replayed turns) is refused, and that
  // refusal joins the hold (`holdRefused`).
  const trustPasses =
    Boolean(snapshot.sessionId) &&
    (snapshot.isWorking || (snapshot.summary?.turnCount ?? 0) > 0) &&
    trustAsk.blocked?.reason !== "trust.notTrustedNoPrompts";
  // A remote chat's question is answered on its own machine, which this pane never hears about, and
  // the floating chat's Start Agent hands a prompt off as it lands (`startInBackground`): both keep
  // Send off under the question, as before, instead of holding prompts.
  const trustSendOff = !trustPasses && (trustAsk.blocked?.reason === "trust.remote" || quick);
  // A read still in flight (`{}`) holds nothing (#28088): a prompt sent then goes, and a refusal
  // joins the hold.
  const trustHolds = Boolean(trustAsk.blocked?.reason) && !trustPasses && !trustSendOff;
  // Held prompts go only once the folder is known trusted: never while its trust is read again (a
  // chat shown again), nor while a folder choice or sign-in holds Send (`blockSend`).
  const trustHeldWaits = (Boolean(trustAsk.blocked) && !trustPasses && !trustSendOff) || blockSend;
  /// Sends a prompt the folder's trust held, once it is trusted (set where the composer sends).
  const sendTrustHeld = useRef<(entry: TrustHeldPrompt) => Promise<string | undefined>>(() =>
    Promise.resolve(undefined),
  );
  const trustHeldCwd = snapshot.summary?.cwd ?? (snapshot.sessionId ? undefined : projectDraft);
  // A worktree this pane made for the chat's folder, whose recipe's setup the line follows. Before
  // the first send the folder is the draft New Worktree set, as the folder chip shows it: the
  // summary can still name the checkout the worktree was made from.
  const worktreeSetupFolder = freshChat && !snapshot.sessionId ? (projectDraft ?? trustHeldCwd) : trustHeldCwd;
  const worktreeSetupHere = useWorktreeSetupStart(worktreeSetupFolder) !== undefined;
  /// Puts prompts the hold gives back where they were typed (set below).
  const giveBackTrustHeld = useRef(
    async (
      _entries: readonly TrustHeldPrompt[],
      _behind?: boolean,
      _closing?: boolean,
      _until?: number,
    ): Promise<ComposerAttachment[]> => [],
  );
  const trustHeld = useTrustHeldPrompts({
    chat: snapshot.sessionId,
    cwd: trustHeldCwd,
    // A waking Cloud machine holds the chat's prompts too, until the chat is back (cloudWake.ts).
    holds: trustHeldWaits || (cloudWaking && cloudWakeChat !== undefined),
    send: (entry) => sendTrustHeld.current(entry),
    reserve: reserveHeldPrompt,
    putBack: (entries, behind) => void giveBackTrustHeld.current(entries, behind),
    refusedForTrust: isTrustRefusal,
    keptElsewhere: keptInChat,
  });
  const trustHeldNow = useRef(trustHeld);
  trustHeldNow.current = trustHeld;
  // The wake ends once no prompt waits for it; one that failed (or found the machine deleted) gives
  // its prompts back to the composer, as a failed send does.
  const wakingHeld = trustHeld.wakingAny();
  useEffect(() => {
    if (!wakingHeld) setCloudWaking(false);
  }, [wakingHeld]);
  // The wake belongs to the chat its prompts were sent in: another chat shown ends it (its recovery
  // stops), and the prompts go back to their chat's draft (trustHeld.ts `whereHeldGoes`).
  const wakeShownChat = snapshot.sessionId ?? snapshot.missingSession;
  useEffect(() => {
    const hold = trustHeldNow.current;
    if (!wakeShownChat || !hold.wakingAny() || hold.rowsIn(wakeShownChat).some((row) => row.waking)) return;
    void giveBackTrustHeld.current(hold.takeWaking());
  }, [wakeShownChat]);
  const cloudWakeFailed = cloudRecovery.error !== undefined || cloudRecovery.state === "deleted";
  // A typing wake that failed stops; it is not tried again on the next key, and a send still wakes.
  useEffect(() => {
    if (cloudWakeFailed) setCloudTypeWaking(false);
  }, [cloudWakeFailed]);
  useEffect(() => {
    if (!cloudWakeFailed || !trustHeldNow.current.wakingAny()) return;
    void giveBackTrustHeld.current(trustHeldNow.current.takeWaking());
  }, [cloudWakeFailed]);
  // A new chat's held prompts go to the host with its typed text the moment they are held, so the
  // tab keeps them when it moves to another chat (the host keeps no new-chat text past that).
  const newChatHeldText = snapshot.sessionId ? undefined : trustHeld.newChatTexts.join("\u0000");
  useEffect(() => {
    if (newChatHeldText === undefined) return;
    const held = newChatHeldText ? newChatHeldText.split("\u0000") : [];
    if (held.join("\u0000") === newChatDraft.held.join("\u0000")) return;
    newChatDraft.held = held;
    void postNewChatDraft();
  }, [newChatHeldText]);
  /// What the new chat shown leaves when its tab opens another chat (cmux#32276), read before the
  /// switch: its kept, held and typed text, in that order. `leave` hands it to the host for the
  /// window's next New Tab page and takes the held prompts out of the hold, so none is sent after.
  newChatLeftover.current = () => {
    if (snapshotRef.current?.sessionId) return undefined;
    const typed = leftoverInField.current ?? composerHandle.current?.draftText() ?? newChatDraft.typed;
    const kept = newChatDraft.kept;
    // No held prompt goes while the pick waits for its chat: the page still shows the new chat, so
    // one could land in the chat picked (cmux#32298 review at 94f283e).
    const resume = trustHeldNow.current.pauseNewChat();
    return {
      /// The pick landed: the held prompts leave the hold (with one whose start it cancelled).
      leave: () => {
        const held = trustHeldNow.current.takeNewChat().map((entry) => entry.text);
        resume();
        const text = [...kept, ...held, typed].filter((part) => part.trim()).join("\n\n");
        newChatDraft.kept = [];
        newChatDraft.held = [];
        newChatDraft.typed = "";
        leftoverInField.current = undefined;
        if (text) void callNative("chat.leftover", { text }).catch(() => undefined);
      },
      /// The pick failed or a later one took over: the new chat's prompts go as before.
      cancel: resume,
    };
  };
  // Held prompts given back while no composer of the new chat showed go into the next one's.
  useEffect(() => {
    const composer = composerHandle.current;
    if (snapshot.sessionId || !composer || !newChatDraft.kept.length) return;
    const kept = newChatDraft.kept;
    newChatDraft.kept = [];
    for (const text of kept) composer.restore(text, [], true);
  }, [snapshot.sessionId]);
  holdRefused.current = (text, attachments, error, sentFrom) => {
    trustHeld.hold(text, attachments, sentFrom);
    if (error && typeof error === "object") heldRefusals.add(error);
  };
  shownFrom.current = () => ({ chat: snapshot.sessionId, cwd: trustHeldCwd });
  /// Puts prompts the hold gives back where they were typed (trustHeld.ts `whereHeldGoes`): a
  /// refused one, or every one when the page quits. A new chat's with no composer showing go into the
  /// host's draft of that chat's tab (`chat.unsentDraft`), and their chips are answered (for the
  /// wake state, which carries them). `behind`: after what the composer or draft holds (sent after
  /// one already given back). `closing`: the page goes (its tab closed), its composer with it.
  giveBackTrustHeld.current = async (
    entries,
    behind = false,
    closing = false,
    until = Date.now() + DRAFT_SETTLE_MS,
  ) => {
    const composer = closing ? undefined : composerHandle.current;
    // The chips the shown chat's composer keeps, which its kept chips are now (keptAttachments.ts).
    const shownChips = closing ? (composerHandle.current?.wakeState().attachments ?? []) : undefined;
    const where = whereHeldGoes(entries, snapshot.sessionId, Boolean(composer));
    const writes: Promise<unknown>[] = [];
    // `restore` puts what comes back first: the last one goes in first, so they read in order;
    // behind what is there, the first goes first.
    for (const entry of behind ? where.composer : [...where.composer].reverse())
      composer?.restore(entry.text, entry.attachments, behind);
    // The next composer gets them only while that new chat shows, and they join its typed text
    // the host keeps. With another chat shown they stay in the host's draft of the new chat's tab,
    // where the hold put them (`newChatDraft`), out of that chat's composer.
    const shownHere = snapshot.sessionId === undefined ? where.later : [];
    if (shownHere.length) {
      heldBack.current = [
        ...(heldBack.current ?? []),
        ...shownHere.map((entry) => ({ text: entry.text, attachments: entry.attachments })),
      ];
      const text = shownHere.map((entry) => entry.text).filter((part) => part.trim());
      newChatDraft.typed = [...text, newChatDraft.typed].filter((part) => part.trim()).join("\n\n");
      newChatDraft.held = newChatDraft.held.filter((part) => !shownHere.some((entry) => entry.text === part));
    }
    const elsewhere = where.later.filter((entry) => !shownHere.includes(entry));
    newChatDraft.kept = [...newChatDraft.kept, ...elsewhere.map((entry) => entry.text).filter((part) => part.trim())];
    if (shownHere.length || elsewhere.length) writes.push(postNewChatDraft());
    await Promise.all(
      [...where.drafts].map(async ([chat, list]) => {
        const text = list.map((entry) => entry.text).filter((part) => part.trim());
        // The chat's draft as acpmux keeps it, so one saved from another client or the CLI is kept
        // beside the held prompts, never replaced; this page's remount cache only while a write of
        // its own is newer than acpmux's (hasPendingDraftWrite) or acpmux does not answer. The read
        // gets half the deadline, so the writes still land within it.
        const local = readPersistedDraft(chat);
        const read = hasPendingDraftWrite(chat)
          ? undefined
          : await settledBy(
              readDurableDraftState(chat).catch(() => undefined),
              Math.min(until, Date.now() + DRAFT_SETTLE_MS / 2),
            );
        const draft = (read ? read.draft : local) ?? "";
        writePersistedDraft(chat, (behind ? [draft, ...text] : [...text, draft]).filter(Boolean).join("\n\n"));
        const chips = keptChips(list.flatMap((entry) => entry.attachments));
        if (!chips.length) return;
        // A closing page writes the shown chat's at once: it may be gone before a read answers.
        const kept = shownChips && chat === snapshot.sessionId ? shownChips : await keptAttachments.read(chat);
        await keptAttachments
          .write(chat, [...chips, ...kept.filter((chip) => !chips.some((back) => back.id === chip.id))])
          .catch(() => undefined);
      }),
    );
    // The text reaches acpmux and the host before this answers: a closing page's bridge goes once
    // it does (AgentPageRetirer), and a write still queued then would be lost. Bounded like the
    // draft a quit settles (`until`, DRAFT_SETTLE_MS from the ask).
    await settledBy(Promise.all([settlePendingDraftWrites(), ...writes]), until);
    // Only the shown new chat's: the wake state is the shown chat's, and another chat's composer
    // never takes a new chat's chips.
    return keptChips(shownHere.flatMap((entry) => entry.attachments));
  };
  // A page that goes (its tab closed, the chat archived) puts its held prompts into their chats'
  // drafts first, as quitting does: they live only in this page. Its composer goes with it, so the
  // shown chat's go into that chat's draft too. The web page hides before React unmounts anything.
  useEffect(() => {
    const away = () => {
      const all = trustHeldNow.current.release();
      if (all.length) void giveBackTrustHeld.current(all, false, true);
    };
    window.addEventListener("pagehide", away);
    return () => window.removeEventListener("pagehide", away);
  }, []);
  const queueSideChatRef = useRef<((promptId: string, prompt: string) => Promise<boolean>) | undefined>(undefined);
  // The queue as acpmux has it now, which a waiting message's Move up/Move down places it in.
  const queueRef = useRef(snapshot.queue);
  queueRef.current = snapshot.queue;
  // Another agent's waiting message, from its card's ⋯ menu (conversation/QueuedMessageCard.tsx):
  // the queue row's Steer, Edit message (into the composer, its images too), Open in side chat and
  // Delete, Move up/down. Offered while disconnected too, as the queue row's were: a call then fails
  // and the card stays. The menu reads them as it opens.
  const sideChatOffered = Boolean(opensSideSessions && !isSideSession && snapshot.sessionId);
  // A guest's held prompt offers Approve and Decline only where acpmux serves them.
  const queueApproval = snapshot.queueApproval === true;
  const queuedMessageActions = useMemo<QueuedMessageActionsValue>(
    () => ({
      steer: (promptId) => editQueued(promptId, { op: "send_now" }),
      remove: removeQueued,
      edit: async (promptId, text, images) => {
        const attachments = await queuedAttachments(images, readQueuedImage);
        // An image that could not be read would be lost with the prompt: it stays queued.
        if (lacksImageBytes(attachments)) return false;
        const removed = await removeQueued(promptId);
        if (removed) restoreComposerDraft(composerHandle, heldBack, text, attachments);
        return removed;
      },
      // The queue row's Move up and Move down: acpmux's `move` to a place in the whole queue.
      position: (promptId) => {
        const queue = queueRef.current;
        const index = queue.findIndex((entry) => entry.id === promptId);
        return index < 0 ? undefined : { index, count: queue.length };
      },
      move: (promptId, index) => editQueued(promptId, { op: "move", index }),
      ...(queueApproval && { answerHeld }),
      ...(sideChatOffered && {
        sideChat: (promptId: string, text: string) =>
          queueSideChatRef.current?.(promptId, text) ?? Promise.resolve(false),
      }),
    }),
    [sideChatOffered, readQueuedImage, queueApproval],
  );
  // Read by the cards as they draw (TurnActions `queuedMessages`): set here, before the rows draw.
  queuedMessageActionsRef.current = queuedMessageActions;
  /// Prompts on their way through this page before the client holds them (a chat starting, a
  /// harness switch's row), and chats starting for a prompt (`chat.new`).
  const untakenSends = useRef(0);
  // WEB-SWAP: a web update's reload waits while a prompt that left the composer lives only in this
  // page: one on its way to acpmux, one waiting for a new chat, a failed one with Retry
  // (direct.ts `swapHold`, pages/shared/webSwap.ts).
  useEffect(
    () =>
      holdWebSwap(
        () =>
          directClient.current?.swapHold() ||
          (untakenSends.current > 0 ||
          startingSends.busy ||
          trustHeldNow.current.holdsAny() ||
          heldBack.current?.length ||
          heldQuotes.current?.length
            ? "composer.send-untaken"
            : null) ||
          // A Sandboxed send runs: the reload waits for it (sandboxRun.ts SandboxTab.busy, bounded).
          (sandbox.busy() ? "sandbox.running" : null),
      ),
    [startingSends, sandbox],
  );
  /// What a released page's composer held (the handshake's `wake`), for the composer once it mounts.
  const pendingWake = useRef<ComposerWake | undefined>(undefined);
  /// Where the shown transcript rests now (VirtualTranscript `anchorNow`).
  const transcriptAnchor = useRef<(() => ScrollAnchor | null | undefined) | undefined>(undefined);
  /// Prompts sent from this pane (every `chat.send`): each puts the transcript at its latest message.
  const [sends, setSends] = useState(0);
  /// VirtualTranscript updates this synchronously on reader scrolls, so a disabled send-to-bottom
  /// preference can preserve the exact visible row while the new prompt arrives below it.
  const followingTranscript = useRef(true);
  /// The composer reads it as it sends (conversation/sendTuck.ts); one function for the pane's life,
  /// so the composer's props stay the same while the transcript scrolls.
  const transcriptFollowing = useCallback(() => followingTranscript.current, []);
  const onTranscriptFollowingChange = useCallback((following: boolean) => {
    followingTranscript.current = following;
    // Only a chat followed at its latest row lets go of its oldest records (direct.ts `shedOlderHeld`).
    directClient.current?.setFollowing(following);
    // Back at the latest row: the commands held out while scrolled up go back into their runs.
    // An ended turn's Worked for held open over what they read closes there too.
    if (
      following &&
      (heldCalls.current.keys.size > 0 || heldRuns.current.keys.size > 0 || heldWorked.current.keys.size > 0)
    )
      releaseCalls();
  }, []);
  /// The oldest row the followed transcript draws: the client sheds no held record above it (direct.ts `setKeepFrom`).
  const onTranscriptKeepFrom = useCallback(
    (rowId: string | null, at?: number) => directClient.current?.setKeepFrom(rowId, at),
    [],
  );
  const composerRef = useCallback((handle: ComposerHandle | null) => {
    composerHandle.current = handle;
    if (handle && pendingWake.current) {
      handle.wake(pendingWake.current);
      pendingWake.current = undefined;
    }
    replayHeldForComposer(handle, heldBack, heldQuotes);
    // Files another app sent before this composer was there (composer/externalAttach.ts).
    if (handle && externalWaiting.current)
      externalWaiting.current = !takeExternalInto(() => composerHandle.current, callNative);
  }, []);
  const composerUnplacedQuotes = useCallback(
    (quotes: string[]) => handBackQuotes(composerHandle, heldQuotes, quotes),
    [],
  );
  // The selection's Reply chip and a row's Reply quote through the same Quote in Reply as the
  // right-click menu (`chat.quoteReply`, conversation/SelectionReply.tsx).
  useEffect(() => setQuoteReplySink(quoteReply), [quoteReply]);
  useComposerKeyboard(() => {
    // A composer parked under a New Tab page (inert, unseen) takes no keyboard: the page's field does.
    if (!prompt.current || document.querySelector(".acpmux-dock[inert]")) return false;
    prompt.current.focus();
    return true;
  }, pageHostClient());
  /// The New Tab page's field, while it shows: dictation writes there then (it has no composer).
  const newTabDictationField = useRef<DictationField | null>(null);
  const dictationTarget = useRef<{ readonly current: DictationField | null }>({
    get current() {
      return newTabDictationField.current ?? prompt.current;
    },
  }).current;
  /// The chat's agent runs on this Mac (`localCwd`, set below each render): it can open a long
  /// recording's file.
  const chatIsLocal = useRef(false);
  const dictation = useDictation(dictationTarget, callNative, {
    accepts: snapshot.summary?.promptCapabilities?.audio === true,
    attach: (audio) => {
      // A Cloud start is out: the words still land as text, which the started chat gets; the
      // recording, a chip the host would not carry, is left out.
      if (cloudStartingNow.current) return;
      const name = translate("dictation.recording");
      const recording = recordingAttachment(audio, name, chatIsLocal.current);
      if (recording) composerHandle.current?.attach(recording);
      else if (!audio.path) notices.transient(translate(recordingLeftOutNotice("tooLarge")));
      // A chat on another computer: the host sends its file there. Until it answers, the recording
      // is a pending chip that a send (Return, Send, the auto-send) waits for, as for a dropped
      // file still uploading; one that fails says so on its chip, with Retry. A chip made after the
      // pane moved to another chat is that chat's (it names a file on that chat's machine).
      else
        composerHandle.current?.attachLater(
          `${name}.wav`,
          () => remoteRecordingAttachment(audio, name, callNative),
          translate(recordingLeftOutNotice("elsewhere")),
          // Its ×: the host stops sending and drops what it staged on that machine.
          () => void callNative("dictation.recording.cancel", { path: audio.path }).catch(() => {}),
        );
    },
    omitted: (reason) => notices.transient(translate(recordingLeftOutNotice(reason))),
    chat: () => sessionIdRef.current,
    elsewhere: () => notices.transient(translate("dictation.recordingOtherChat")),
  });
  // The composer's mic, the same element while the dictation is (dictation.ts keeps it while its state is).
  const composerMic = useMemo(() => <DictationMic dictation={dictation} strip={false} />, [dictation]);
  /// Why the host could not hand this pane acpmux (not installed, a daemon that will not start),
  /// in the host's words; cleared once a handshake succeeds.
  const [hostError, setHostError] = useState<string | undefined>();
  // The host failed before its handshake: the chat view (its error card and composer) takes the
  // New Tab page's place until a retry answers, then gives it back (`showNewTab`). What was typed
  // goes along each way (the page's `onLeaveDraft`, `takeDraft`); before, it was dropped both ways.
  // `composerStoodIn`: the chat view stands in for a New Tab page now (the host failed before its
  // handshake while the tab is a New Tab page). Set from that state each render, and cleared once
  // the handshake is done (below): the page that comes back right then takes the draft, and no
  // later page (another New Tab adopted into this pane, a chat's own recovery) ever does.
  const composerStoodIn = useRef(false);
  /// The failure behind `hostError`, which hostLine.ts words plainly (a chat's machine that is not
  /// reachable, acpmux's own codes and commands behind Details).
  const [hostFailure, setHostFailure] = useState<unknown>();
  /// Whether `hostError` is said (one line above the composer, hostRetry.ts `hostErrorShows`): a
  /// refusal at once, a recovery (a daemon starting, restarting or handed off by an update) only
  /// once it has failed past its deadline. Until then the pane shows nothing; a connect clears it.
  const [hostErrorShown, setHostErrorShown] = useState(false);
  /// A Retry the user asked for that waits on the attempt in flight.
  const [retryQueued, setRetryQueued] = useState(false);
  /// Asks the host again now, after the user fixed what `hostError` says.
  const retryHost = useRef<(() => void) | undefined>(undefined);
  /// Cancels the automatic retry waiting to run (Restart acpmux asks again itself when it ends).
  const cancelRetry = useRef<(() => void) | undefined>(undefined);
  /// The host refused a daemon another binary runs on this app's socket: the card offers Restart acpmux.
  const [acpmuxRestartOffered, setAcpmuxRestartOffered] = useState(false);
  /// A Restart acpmux in flight (state for the card; the gate keeps the retry loop from asking the
  /// old daemon again while it stops, hostRetry.ts).
  const [restartingAcpmux, setRestartingAcpmux] = useState(false);
  const [restartGate] = useState(() => new AcpmuxRestartGate());
  /// When the handshake in flight began (`Date.now()` time), while it waits for acpmux; undefined
  /// when none waits. The waiting line (HostWaitingLine) counts from it and offers Restart agent
  /// service: a slow acpmux is never restarted by the app on its own (rule R5).
  const [waitingSince, setWaitingSince] = useState<number | undefined>();
  /// The host said it cannot restart what this wait waits on (a remote or Cloud chat, the Chief
  /// home's acpmux, or no lookup of this app's acpmux in flight): the line keeps its time and drops
  /// the button until the next wait.
  const [restartUnavailable, setRestartUnavailable] = useState(false);
  /// When this pane's connection to acpmux was lost (its client's `onLost`), until a handshake
  /// connects again: the quiet "Reconnecting…" line counts from it (HostRecoveringLine).
  const [relinkingSince, setRelinkingSince] = useState<number | undefined>();
  /// When the pane's trouble began (paneSnapshot.ts `troubleSince`): bounds the bare "Reconnecting…".
  const [hostTroubleSince, setHostTroubleSince] = useState<number | undefined>();
  /// The host says acpmux is restoring its chats after a start (its `acpmux-host-status` event, or
  /// a refused handshake's `details.restoring`): the line says "Restoring sessions… m:ss" instead.
  const [hostRestoring, setHostRestoring] = useState<HostRestoring | undefined>();
  useEffect(() => {
    const heard = (event: Event) => setHostRestoring(readHostRestoring((event as CustomEvent).detail, Date.now()));
    window.addEventListener("acpmux-host-status", heard);
    return () => window.removeEventListener("acpmux-host-status", heard);
  }, []);
  // The host covers the pane with its loading state until this document first draws what it is:
  // the handshake's answer, or the host error when there is none (a failed start must show, not
  // stay behind the loading state). The frames before (no hero yet, "Connecting") stay hidden.
  // One animation frame after that render, then a task: the task runs once that frame was drawn.
  // Not two frames: WebKit stops animation frames once the window is occluded, so a second frame
  // may never come although the first one drew (cx-zjtn.6; PagePaintProbe in CmuxNextPages waits
  // the same way).
  const paintReported = useRef(false);
  /// The chat whose settled frame the paint report named (`pane.painted` with `settled: true`).
  const settledReported = useRef<string | undefined>(undefined);
  // The chat whose saved draft the composer read (Composer `onDraftSettled`), and the chat whose
  // wait for it ran out: until one names the chat, its draft is not in the prompt yet.
  const [draftSettled, setDraftSettled] = useState<string>();
  // A chat read from a kept tail before its connect answers has no draft in its prompt yet: the
  // copy, which shows the draft, waits for the read, at most DRAFT_SETTLE_HOLD_MS (draftSettleHold.ts).
  const rowsReadFor = clientSnapshot.chatRead === true ? clientSnapshot.sessionId : undefined;
  const draftWaitOver = useDraftWaitOver(rowsReadFor, draftSettled);
  // A tab opening an existing chat adopted this prewarmed New Tab page (useSessionAdoption, below):
  // the chat it switches to, until that chat is drawn. Until then the page has not drawn what it is.
  const [adoptingSession, setAdoptingSession] = useState<string>();
  const [restoredTailSession, setRestoredTailSession] = useState<string>();
  // A New Tab page is what it is from its first render: its frame draws before the handshake
  // (cx-0rpl.10), and the host shows no loading mark over it. A chat the handshake named is what it
  // is once acpmux attached it: before, the page drew an empty transcript with stand-in chips, and
  // the host faded that in, then the rows, title and modes popped in (Leo 2026-10-20).
  // Not merely past "connecting": the open's hold (direct.ts OPEN_HOLD_MS) draws what it has when
  // acpmux is slow, which is the empty transcript. A failed open draws what it is too.
  const openFailed =
    clientSnapshot.connection.startsWith("connecting:") ||
    clientSnapshot.connection === "disconnected" ||
    clientSnapshot.connection === "failed";
  const adoptionDrawn =
    adoptingSession === undefined ||
    openFailed ||
    (clientSnapshot.sessionId === adoptingSession && clientSnapshot.chatRead === true);
  const chatDrawn = (!awaitsChat || clientSnapshot.chatRead === true || openFailed) && adoptionDrawn;
  const hostErrorSaid = hostError !== undefined && (hostErrorShown || restartingAcpmux);
  const showsWhatItIs =
    (!handshaken &&
      restoredTailSession !== undefined &&
      clientSnapshot.sessionId === restoredTailSession &&
      clientSnapshot.rows.length > 0 &&
      !showsChatSnapshot()) ||
    pageShowsWhatItIs({
      handshaken,
      chatDrawn,
      hostError: hostError !== undefined,
      hostErrorSaid,
      newTab: newTab !== undefined,
      // The copy from the last launch stays until the chat itself is drawn (firstPaint.ts).
      keepsLastFrame: showsChatSnapshot(),
      // A copy showing a running turn waits for acpmux's attach (or the turn's own state): a kept
      // tail keeps rows, not the turn, and taking over with it took the copy's live line off for a
      // frame and put it back once the attach answered (settled-page restart.stream, 2 shifts).
      chatRead:
        clientSnapshot.chatRead === true &&
        clientSnapshot.sessionId !== undefined &&
        (clientSnapshot.chatAttached === true || clientSnapshot.isWorking || !copyShowsRunningTurn()) &&
        adoptionDrawn &&
        (draftSettled === clientSnapshot.sessionId || draftWaitOver === clientSnapshot.sessionId),
      openRefused: clientSnapshot.connection === "failed",
      chatUnavailable: clientSnapshot.unavailable !== undefined && clientSnapshot.unavailable.reason !== "connecting",
    });
  // No chat screen before the page knows it is no New Tab page (`contextKnown`).
  const knowsWhatItIs = contextKnown || newTab !== undefined || handshaken || hostError !== undefined;
  useEffect(() => {
    if (!handshaken || chatDrawn) return;
    // A slow attach: the client draws what it has after the open's hold (direct.ts OPEN_HOLD_MS).
    const timer = window.setTimeout(() => {
      setAwaitsChat(false);
      setAdoptingSession(undefined);
    }, CHAT_DRAW_HOLD_MS);
    return () => window.clearTimeout(timer);
  }, [handshaken, chatDrawn]);
  useEffect(() => {
    if (adoptingSession !== undefined && adoptionDrawn) setAdoptingSession(undefined);
  }, [adoptingSession, adoptionDrawn]);
  // The host's spare page, adopted by a tab opening an existing chat (AgentPaneView+SessionAdopt.swift):
  // it is connected already, so it switches to the chat in place, as a sidebar pick does (`chat.select`,
  // drawing the host's kept tail when there is one). The New Tab screen goes in the event's own render,
  // and the chat's first drawn frame is reported as this page's first paint again: the host keeps
  // the page out of sight until then.
  // An adoption that came before this page's client connected (the host takes a spare whose New Tab
  // frame is drawn, which can be before its connect answers) runs once the client's actions are in.
  const pendingAdoption = useRef<SessionAdoption | undefined>(undefined);
  // The newest adoption: an older one still reading its anchor never opens over it.
  const adoptionTicket = useRef(0);
  const runAdoption = useCallback(async (adoption: SessionAdoption) => {
    const { sessionId, revealTurn } = adoption;
    const ticket = ++adoptionTicket.current;
    const before = directClient.current?.selectedSession;
    // A subagent's pane shows the subagent from its first frame and has no reading place of the
    // chat to wait for (newtab/adoption.ts `adoptionPlan`): with the tail its adopt event carried,
    // the switch below draws it in this same turn.
    const plan = adoptionPlan(adoption);
    if (plan.revealsFirst && revealTurn) revealRef.current(revealTurn);
    const revealAfter = plan.revealsFirst ? undefined : revealTurn;
    // Where the reader left this chat, before its rows draw, as a tab opened on it reads it: from the
    // adopt event when the host put it there (no round trip on the click's path), else asked.
    const anchor = plan.readsAnchor
      ? await fetchScrollAnchor(sessionId)
      : plan.revealsFirst
        ? undefined
        : carriedAnchor(adoption);
    if (ticket !== adoptionTicket.current) return;
    const now = directClient.current?.selectedSession;
    if (now !== before) {
      // A connect or reconnect opened this chat meanwhile (the host bound the tab to it): what the
      // adoption still carries is its place and its turn (a subagent's pane).
      if (now === sessionId) {
        setScrollAnchor(anchor);
        if (revealAfter) revealRef.current(revealAfter);
      }
      // Another chat was picked while the anchor was read (a page action, automation): it stands.
      else setAdoptingSession((current) => (current === sessionId ? undefined : current));
      return;
    }
    const adopt = window.cmuxAcpmuxActions?.["chat.adopt"];
    if (!adopt) {
      pendingAdoption.current = adoption;
      return;
    }
    setScrollAnchor(anchor);
    await adopt({ sessionId }).then(
      (selected) => {
        if (selected && revealAfter) revealRef.current(revealAfter);
        // A chat the daemon does not list draws why, which is this page's first paint too.
        if (!selected) setAdoptingSession((current) => (current === sessionId ? undefined : current));
      },
      // A chat that could not be read says so in the chat view (a missing chat, a failed open).
      () => setAdoptingSession((current) => (current === sessionId ? undefined : current)),
    );
  }, []);
  const runPendingAdoption = useRef(() => {});
  runPendingAdoption.current = () => {
    const pending = pendingAdoption.current;
    pendingAdoption.current = undefined;
    if (!pending) return;
    if (directClient.current?.selectedSession !== pending.sessionId) {
      void runAdoption(pending);
      return;
    }
    // A reconnect opened the chat already (the host bound the tab to it): what the adoption still
    // carries is its place and its turn (a subagent's pane).
    void (
      pending.scrollAnchor === undefined
        ? fetchScrollAnchor(pending.sessionId)
        : Promise.resolve(carriedAnchor(pending))
    ).then((anchor) => {
      if (directClient.current?.selectedSession === pending.sessionId) setScrollAnchor(anchor);
    });
    if (pending.revealTurn) revealRef.current(pending.revealTurn);
  };
  const adoptSession = useCallback(
    (adoption: SessionAdoption) => {
      // The chat's tail the host handed with the event: the switch draws it with no round trip.
      keepAdoptedTail(adoption);
      directClient.current?.bindToSession(adoption.sessionId);
      paintReported.current = false;
      settledReported.current = undefined;
      setAdoptingSession(adoption.sessionId);
      setAwaitsChat(true);
      setNewTab(undefined);
      setNewSession(false);
      setPastTurns(undefined);
      setProjectDraft(undefined);
      void runAdoption(adoption);
    },
    [runAdoption],
  );
  useSessionAdoption(adoptSession);
  // The selected tab's retained rows need no daemon or native handshake. Keep the saved HTML
  // frame when present; a tail fills its miss using the same fold as a normal cache-first attach.
  useEffect(() => {
    const selection = sessionSelectionToken.current;
    const adoption = adoptionTicket.current;
    return watchRestoredTail((next) => {
      if (
        handshakenRef.current ||
        selection !== sessionSelectionToken.current ||
        adoption !== adoptionTicket.current ||
        newTabNow.current !== undefined ||
        snapshotRef.current?.sessionId !== undefined
      )
        return;
      rowsRef.current = next.rows;
      snapshotRef.current = next;
      setSnapshot(next);
      setRestoredTailSession(next.sessionId);
      setContextKnown(true);
    });
  }, []);
  // What this frame drew, not only that it drew: a chat taken from a kept tail is on screen in the
  // frame the open landed on, so the host shows the page instead of fading it in (tailCache.ts,
  // AgentPaneView+Loading.swift). A kept tail is drawn before the frame that shows what the pane
  // is, so it is known by the time this reports; the report happens once either way.
  const drewKeptTail = clientSnapshot.drewKeptTail === true;
  // The chat on screen is acpmux's settled view of it (direct.ts `settled`, cmuxterm-hq#9655): the
  // host is told in the paint report, `settled: true`, once that frame is drawn. A report made
  // before it (the kept tail, the draw hold running out) said nothing of it, so the frame's own
  // report follows, once per chat opened.
  const settledSession =
    clientSnapshot.settled !== undefined && clientSnapshot.chatRead === true ? clientSnapshot.sessionId : undefined;
  // The first report waits for the rows' parts that draw a moment late (math, diagrams, images the
  // host reads) to settle, at most OPEN_SETTLE_MAX_MS: the host shows the page at its final layout,
  // not one that moves under the reader as they land (https://github.com/manaflow-ai/cmux/issues/48498).
  const heightsSettled = useHeightsSettledFor(showsWhatItIs);
  useEffect(() => {
    if (!showsWhatItIs || (!paintReported.current && !heightsSettled())) return;
    const settledNow = settledSession !== undefined && settledReported.current !== settledSession;
    if (paintReported.current && !settledNow) return;
    const first = !paintReported.current;
    paintReported.current = true;
    if (settledNow) settledReported.current = settledSession;
    // The page drew what it is under the chat's snapshot (chatSnapshot/boot.ts): it takes over at
    // the next frame, in one step.
    if (first) swapChatSnapshot();
    // A chat's first paint, unless its saved copy drew first and started it: what moves from here is the
    // launch's settle, reported once (launchSettle.ts). Not a New Tab page's.
    if (first && newTab === undefined) watchLaunchSettle(callNative);
    requestAnimationFrame(() =>
      setTimeout(() => {
        if (settledNow) document.documentElement.dataset.acpmuxSettledDrawn = "true";
        // When the host is told the page shows the chat, beside the report itself: the flicker log's
        // first-load record counts what moved after it apart, what the reader saw (firstLoadWatch.ts
        // `seen`); what moved before it was still under the host's cover.
        if (first) performance.mark?.(PANE_PAINTED_MARK);
        // The perf watch's page-load span ends here (perfReporter.ts): once per page.
        if (first) acpmuxPerf.markLaunch("painted");
        void callNative("pane.painted", { drewKeptTail, ...(settledNow ? { settled: true } : {}) }).catch(
          () => undefined,
        );
        if (!first) return;
        void loadHighlightedCode();
        void loadEditDiffHunks();
      }, 0),
    );
  }, [showsWhatItIs, heightsSettled, drewKeptTail, settledSession, newTab]);
  // While the chat shows, the page keeps its drawn copy for the next launch (chatSnapshot/live.ts):
  // the visible window, written when it goes quiet and when the page hides. Only the shared page host
  // keeps copies (`chat.snapshot.put`); the legacy WebKit host has no such op and would count each
  // write as the person touching the page.
  const snapshotSession = showsWhatItIs && newTab === undefined && hostError === undefined ? shownSessionId : undefined;
  useEffect(() => {
    if (!snapshotSession || !pageHostClient()) return;
    return watchChatSnapshot(snapshotSession, (params) => {
      // The chat's records go with its drawn copy: a quit can end the page without a `pagehide`,
      // and the tail the host held then was the one kept when the chat was last left, which the
      // relaunch's attach no longer meets (Leo, 2026-11-08: "what you saw when you clicked the
      // restart button ... here's literally what you just had").
      directClient.current?.handOverCurrentTail();
      // The prompt the markup shows, as text: the next launch's composer holds it from its first
      // frame (chatSnapshot/restoredDraft.ts), so the copy's composer and the live one are one size.
      // A miss (a copy too large to keep) carries it too; a forget carries nothing.
      const draft =
        "html" in params || "miss" in params ? snapshotDraft(composerHandle.current?.draft().text) : undefined;
      return callNative("chat.snapshot.put", draft ? { ...params, draft } : params);
    });
  }, [snapshotSession]);
  const summary = snapshot.summary;
  const localCwd =
    summary && !summary.peer && !(summary.host && summary.hostKind !== "local") ? summary.cwd : undefined;
  /// The chat's folder on whichever machine runs it: the diff tab reads its repository there (the
  /// session host's git), so Changes opens a tab for a Cloud or remote chat too.
  const chatCwd = summary?.cwd || undefined;
  // New Project's chat (newtab/newProject.ts) opens the first local page it serves beside it, once,
  // as the header's Preview would; every other chat waits for the person's click.
  // Only a page the agent gave counts: one the person's prompt names is not served yet, and one
  // still streaming may be cut short (`http://localhost:5` before `5173/`), so it is read at the
  // turn's end. The latest turn alone is read, and only while this chat's folder still waits.
  const servedUrl = useMemo(() => {
    if (quick || snapshot.isWorking || !awaitsProjectPreview(localCwd)) return undefined;
    const rows = snapshot.rows;
    let user = rows.length - 1;
    while (user >= 0 && rows[user].kind !== "user") user -= 1;
    return turnServedUrl(rows.slice(user + 1));
  }, [snapshot.rows, snapshot.isWorking, localCwd, quick]);
  useEffect(() => {
    if (!servedUrl || !takeProjectPreview(localCwd)) return;
    void callNative("pane.action", { id: HEADER_ACTIONS.preview, url: servedUrl, mode: "open" }).catch(() => undefined);
  }, [servedUrl, localCwd]);
  // New side chat and `/side`: forked on this Mac, or on the chat's own machine (a Cloud or SSH
  // chat), in the chat's folder there (sideChatRow.ts).
  const sidePlace = sideChatPlace({ quick, localCwd, onMachine: snapshot.sideChatOnMachine });
  // Stop reaches acpmux even when pressed while the pane reconnects (stopThroughReconnect.ts).
  const stopThroughReconnect = useStopThroughReconnect(snapshot, cancelTurn);
  const keptStopping = stopThroughReconnect.stopping;
  // A chat not listed yet (its machine wakes) shows the prompts held for it under its recorded id.
  const heldRows =
    !snapshot.sessionId && snapshot.missingSession ? trustHeld.rowsIn(snapshot.missingSession) : trustHeld.rows;
  /// Sends a prompt the folder's trust held, with its own send's ticket, in the chat it was sent in:
  /// settles with the session acpmux took it in (a new chat's, once its start made it), or rejects
  /// with its refusal; a refusal is the hold's to handle (trustHeld.ts).
  const sendTrustHeldNow = useRef<(entry: TrustHeldPrompt, ticket: string | undefined) => Promise<string | undefined>>(
    () => Promise.resolve(undefined),
  );
  sendTrustHeld.current = async (entry) => {
    const ticket = await entry.ticket;
    // This render's send, as the chat shown now has it: the ticket may have come after another
    // chat showed.
    return sendTrustHeldNow.current(entry, ticket);
  };
  sendTrustHeldNow.current = async (entry, ticket) => {
    // A prompt goes only in the chat it was sent in: with another one shown it waits again.
    if (!sentInHeld(entry, snapshot.sessionId, trustHeldCwd)) throw movedOn();
    // Not connected: the prompt goes back into the composer (the hold puts back what fails).
    // l10n-allow: never shown; the hold reads only that it failed.
    if (!window.cmuxAcpmuxActions?.["chat.send"]) throw new Error("not connected");
    const fromTrust: HeldSend = { promptId: entry.id, ...(ticket ? { ticket } : {}) };
    // A new chat's first held prompt starts it, in the folder picked (as the composer's first send
    // does); its other prompts follow into that session.
    let made = entry.chat;
    const startsChat = entry.chat === undefined;
    if (startsChat) {
      claimShellRuns.current = true;
      if (projectDraft) {
        const started = await callNative<unknown>("chat.new", {
          cwd: projectDraft,
          peer: directClient.current?.newChatPeer(),
          ...heldPick(snapshot),
        }).catch((error: unknown) => {
          if (isTrustRefusal(error)) trustAsk.refused(error, heldGoesAfterTrust);
          throw error;
        });
        // A start cancelled (another chat picked meanwhile) sends nothing: it waits again, never
        // into the chat shown by then.
        if (typeof started !== "string" || !started) throw movedOn();
        made = started;
      }
    }
    // The session acpmux took it in, as the send reports it: never the chat shown by then, which
    // may be another one picked meanwhile (a new chat's start without a picked folder makes its
    // session inside the send). Unknown, it binds nothing: the hold gives the rest back.
    let tookIn: string | undefined;
    let accept: (session: string | undefined) => void = () => undefined;
    const taken = new Promise<string | undefined>((resolve) => (accept = resolve));
    const turn = callNative("chat.send", {
      text: entry.text,
      attachments: entry.attachments,
      accepted: (session?: string) => {
        tookIn = session ?? made;
        accept(tookIn);
      },
      fromTrust,
      // It goes only to its own chat: another one selected meanwhile ends the send unsent.
      ...(made ? { expectedSessionId: made } : {}),
    });
    try {
      return await Promise.race([taken, turn.then(() => tookIn ?? made)]);
    } catch (error) {
      // Another chat showed before it went: unsent, its ticket unspent, it waits again; a new chat's
      // start that made its session binds its backlog there.
      if (
        isStartCancelled(error) ||
        (error as { message?: unknown } | null)?.message === "agent_session.changed_during_send"
      )
        throw movedOn(startsChat ? made : undefined);
      throw error;
    }
  };
  // Extension slash commands (`cmux.composer.command/1`), as the daemon lists them.
  const extensionCommands = useExtensionCommands();
  const composerSnapshot = useMemo(() => {
    const enabledCmuxActions = new Set<CmuxCommand["action"]>([
      "import",
      "model",
      "fast",
      "context",
      "plan",
      "resume",
      "login",
      "customize",
      "help",
    ]);
    if (snapshot.summary) enabledCmuxActions.add("status");
    if (!quick) enabledCmuxActions.add("cd");
    if (forkable && forkSeq !== undefined) enabledCmuxActions.add("fork");
    // A working chat offers /side too: its fork is of the chat as it is now (#38042).
    if (sideChatRefusal(snapshot, sidePlace) === undefined) enabledCmuxActions.add("side");
    if (continueAvailable) enabledCmuxActions.add("continue");
    // Reserve /btw even with the kill switch off: it must never become a steer or queued prompt.
    if (snapshot.sessionId && !isSideSession && !quick) enabledCmuxActions.add("btw");
    const withCommands = {
      ...snapshot,
      commands: withExtensionCommands(mergedCommands(snapshot.commands, enabledCmuxActions), extensionCommands),
      ...(keptStopping && { stopping: true as const }),
      // The Quick Composer's send never forks (it has no review to show), so its model menu
      // holds no pick of another harness either (review of #37196: it drew the hold, then sent
      // the message to this chat).
      ...(quick && { canHandoff: false }),
      // Cloud picked: the first send starts the chat on a Cloud machine, which decides its mode.
      ...(cloudPicked && { startsOnCloud: true as const }),
      // Its permission mode pick, for the harness the chat starts on (cloudModePick.ts).
      ...(cloudPicked &&
        cloudModeFor(cloudModePick, snapshot.summary?.harness) !== undefined && {
          cloudStartMode: cloudModeFor(cloudModePick, snapshot.summary?.harness),
        }),
    };
    // Prompts still waiting for a new chat to take them follow acpmux's queue, then the prompts the
    // folder's trust holds (trustHeld.ts). The first is the transcript's row (`withStartingPrompt`).
    const startingQueued = queuedStartingSends(shownStarting, snapshot.rows);
    if (startingQueued.length || heldRows.length)
      withCommands.queue = [...shownQueue, ...startingQueued.map(startingQueueEntry), ...heldRows];
    else if (shownQueue !== snapshot.queue) withCommands.queue = [...shownQueue];
    // While a Cloud start shows in place of the chat, the chip names the folder that start copies (cmux#46023),
    // unless the person picked a folder here since: the next send copies that pick, so the chip names it.
    const withPick = withCloudStartPick(withCommands, cloudStartPickShown);
    return projectDraft
      ? withDraftFolder(withPick, projectDraft)
      : withCloudStartFolder(withPick, cloudStartFolderShown);
  }, [
    snapshot,
    projectDraft,
    cloudStartFolderShown,
    cloudStartPickShown,
    continueAvailable,
    forkable,
    forkSeq,
    isSideSession,
    shownStarting,
    shownQueue,
    heldRows,
    sidePlace,
    quick,
    keptStopping,
    cloudPicked,
    cloudModePick,
    extensionCommands,
  ]);
  // What the composer draws from: the same object while nothing it shows changed (composer/composerView.ts),
  // so a tool call or another row added to the transcript does not draw the composer again.
  // While another machine is the pick, the model picker greys the agents it has not set up.
  const machineNote = machinePeer ? t("composer.peerHarnessMissingShort", { machine: machinePeer }) : "";
  const machineCatalog = useMemo(
    () => withMachineHarnesses(composerSnapshot.catalog, machineAgents, machineNote),
    [composerSnapshot.catalog, machineAgents, machineNote],
  );
  const composerOnMachine = useMemo(
    () =>
      machineCatalog === composerSnapshot.catalog ? composerSnapshot : { ...composerSnapshot, catalog: machineCatalog },
    [composerSnapshot, machineCatalog],
  );
  const composerDrawn = useComposerView(composerOnMachine);
  useEffect(() => {
    if (!snapshot.sessionId) return;
    setProjectDraft(undefined);
    setExtraFolderDraft(undefined);
  }, [snapshot.sessionId]);
  /// Where a new chat runs by default (runLocationDefault.ts): Cloud when its folder's newest chat
  /// went to a Cloud machine, else this Mac. Only while Cloud is offered, and only until the person
  /// picks in this pane. Sandboxed, or Cloud the person picked, is never changed; a Cloud default
  /// goes back to this Mac when the folder's history no longer says Cloud or Cloud is not offered.
  /// Settings' Start New Chats In (`agentPane.newChatsIn`) set to Cloud makes it Cloud whatever the
  /// folder's history says (newChatRunLocation); This Mac in the composer's picker still wins.
  /// Never in a tab on another machine (SSH, Cloud): its chat stays on that machine, and the host
  /// refuses `cloud.startChat` from it. A fresh connection has its origin before any summary.
  const onOtherMachine = remoteChat || snapshot.origin === "remote" || snapshot.origin === "peer";
  /// The person's last pick of where a new chat starts (lastNewChatPlace.ts), read again for each new
  /// chat here: a pick on another workspace's page since counts.
  const lastPlace = useMemo(
    () => lastNewChatPlace(),
    // eslint-disable-next-line react-hooks/exhaustive-deps -- read again per new chat, not per render
    [snapshot.sessionId, newTabGeneration],
  );
  /// The folder the default reads: this chat's first, so a later folder pick never moves the chat
  /// between This Mac and Cloud (cmux#47677).
  const [defaultFolder, setDefaultFolder] = useState<{ chat: string; folder: string } | undefined>(undefined);
  const defaultFolderNow = defaultFolderFor(
    defaultFolder,
    `${snapshot.sessionId ?? ""}:${newTabGeneration}`,
    composerSnapshot.summary?.cwd ?? newTab?.cwd,
  );
  if (defaultFolderNow !== defaultFolder) setDefaultFolder(defaultFolderNow);
  const folderRunDefault = useMemo(
    () =>
      sandboxOffered && !onOtherMachine
        ? newChatRunLocation(
            newChatsIn,
            folderRunLocation(defaultFolderNow?.folder, snapshot.sessions, snapshot.peerKinds),
            pickedRunLocation(lastPlace),
          )
        : undefined,
    [
      lastPlace,
      sandboxOffered,
      onOtherMachine,
      newChatsIn,
      defaultFolderNow?.folder,
      snapshot.sessions,
      snapshot.peerKinds,
    ],
  );
  /// The New Tab page's machine by the person's last pick (cmux#46019), while acpmux lists it.
  /// Settings' Start New Chats In set to Cloud is read on its own: the folder default waits for the host's check.
  /// Never on a page of another machine: its new chat stays on that machine.
  const newTabStartMachine = onOtherMachine
    ? undefined
    : pickedStartMachine(
        lastPlace,
        newChatsIn === "cloud" ? "cloud" : folderRunDefault,
        snapshot.peers,
        snapshot.peerConnected,
      );
  /// The chat the folder default last saw (its session, or the New Tab adoption it came with).
  const defaultedChat = useRef<string | undefined>(undefined);
  useEffect(() => {
    const chat = `${snapshot.sessionId ?? ""}:${newTabGeneration}`;
    if (defaultedChat.current !== chat) {
      defaultedChat.current = chat;
      // A new chat: Cloud carried over from the chat before (picked there) is only a default here,
      // which this folder's history may undo.
      if (sandbox.mode === "cloud") cloudByDefault.current = true;
    }
    // A chat starting here (its session not shown yet) keeps the mode it starts with.
    if (runModePicked.current || snapshot.sessionId || snapshot.summary?.sessionId || cloudStartPending.current) return;
    if (folderRunDefault === "cloud" && sandbox.mode === "persistent") {
      cloudByDefault.current = true;
      sandbox.setMode("cloud");
    } else if (folderRunDefault !== "cloud" && sandbox.mode === "cloud" && cloudByDefault.current) {
      cloudByDefault.current = false;
      sandbox.setMode("persistent");
    }
  }, [
    folderRunDefault,
    snapshot.sessionId,
    snapshot.summary?.sessionId,
    newTabGeneration,
    sandbox,
    sandbox.mode,
    cloudStartsEnded,
  ]);
  /// A fresh chat's first prompt went: the commands it ran join the session it gets.
  const claimShellRuns = useRef(false);
  useEffect(() => {
    if (!snapshot.sessionId || !claimShellRuns.current) return;
    claimShellRuns.current = false;
    shellRuns.claim(snapshot.sessionId);
  }, [snapshot.sessionId, shellRuns]);
  const shellActions = useMemo<ShellActions>(
    () => ({
      stop: (id) => shellRuns.stop(id),
      // Typed, never run: the user presses Return in the terminal.
      openInTerminal: (run) =>
        void callNative("tab.open", {
          kind: "terminal",
          text: run.command,
          run: false,
          ...(run.cwd ? { cwd: run.cwd } : {}),
        }).catch(() => undefined),
    }),
    [shellRuns],
  );
  // New Worktree while the host makes it (a git worktree add can take seconds): a line says so;
  // a newer folder pick ends it.
  /// A worktree being made, for the chat (visit) it was asked in: another fresh chat shows nothing of it.
  /// `repo`: a GitHub repository's checkout (or clone) comes first, and the line names it.
  const [worktreeCreating, setWorktreeCreating] = useState<
    false | { sessionId?: string; visit?: string; repo?: string }
  >(false);
  const worktreeCreatingHere = Boolean(
    inThisVisit(worktreeCreating, snapshot.sessionId, visitNow) && freshChat && !snapshot.sessionId,
  );
  /// A folder the user picked on this Mac: the host takes it at once or asks first
  /// (startFolder.tsx); `use` runs only with a folder the host took.
  /// Only the latest pick's answer counts (two quick picks can answer out of order).
  const folderPick = useRef(0);
  const shownSession = useRef(snapshot.sessionId);
  shownSession.current = snapshot.sessionId;
  /// Ends the folder request still waiting (its host reply, its question, or its Use Home Folder
  /// answer) as cancelled. A newer request or worktree replaces it: its folder is never used, and
  /// its sender settles instead of waiting forever (a New Tab send would stay "asking" and ignore
  /// every later Return).
  const dropFolderRequest = useRef<(() => void) | undefined>(undefined);

  const requestFolder = useCallback(
    (cwd: string, use: (folder: string) => void, cancel?: (refusal?: unknown) => void): Promise<void> => {
      dropFolderRequest.current?.();
      const pick = ++folderPick.current;
      // This request ends once: with the folder the host took, or cancelled. Only its own end
      // settles its sender; a newer request's sender keeps waiting for its own reply.
      let ended = false;
      const end = () => {
        if (ended) return false;
        ended = true;
        if (dropFolderRequest.current === dropped) dropFolderRequest.current = undefined;
        return true;
      };
      // `refusal`: the host refused the path itself, which its sender reports; else cancelled.
      const dropped = (refusal?: unknown) => {
        if (end()) cancel?.(refusal);
      };
      const took = (folder: string) => {
        if (end()) use(folder);
      };
      dropFolderRequest.current = dropped;
      folderConfirmGeneration.current += 1;
      folderConfirmInFlight.current = false;
      setFolderConfirming(false);
      const sessionId = shownSession.current;
      const visit = trustVisit();
      setFolderAsk(undefined);
      setWorktreeCreating(false);
      // The pick lands only in the chat it was made in: a chat switched to meanwhile gets nothing.
      const asked = { sessionId, ...visitOf(visit) };
      const stillHere = () => inThisVisit(asked, shownSession.current, trustVisit());
      return pickFolder(
        callNative,
        cwd,
        (folder) => {
          // A stale reply (a newer pick, another chat) uses nothing, and still ends this request.
          if (pick === folderPick.current && stillHere()) took(folder);
          else dropped();
        },
        (refusal) => (pick === folderPick.current && stillHere() ? dropped(refusal) : dropped()),
      ).then((ask) => {
        if (!ask) return;
        if (pick === folderPick.current && stillHere())
          setFolderAsk({ ask, use: took, cancel: () => dropped(), sessionId, ...visitOf(visit) });
        else dropped();
      });
    },
    [trustVisit],
  );

  const freshRef = useRef(false);
  freshRef.current = freshChat && !snapshot.sessionId;
  /// The tab's own folder (a New Tab's, `~` in a fresh workspace): a terminal's folder, never a new
  /// chat's by itself (newChatFolder). Synced after render, not written during it (React Doctor).
  const inheritedFolderRef = useSyncedRef(newTab?.cwd);
  /// The project the person picked in this pane's project picker, until they send in it: that send
  /// makes it the New Tab default (newtab/startedProject.ts). A folder the host or an agent named
  /// is no pick.
  const pickedProject = useRef<string | undefined>(undefined);
  /// Settles once the host answered the pick; `refused` hears a path the host says is no folder, and `accepted`
  /// the folder once it is this pane's pick (a confirmation shown, or a reply a newer pick replaced, is neither).
  const chooseProject = useCallback(
    (cwd: string, peer?: string, refused?: () => void, accepted?: (folder: string) => void): Promise<void> => {
      folderContinuation.invalidate();
      continuationProjectGeneration.current += 1;
      pickedProject.current = undefined;
      // A GitHub repository from a new Cloud chat's folder menu (githubRepos.ts, `github:owner/name`) is
      // no folder on this Mac: the host has nothing to check, and the Cloud start sends it as its `cwd`.
      if (!peer && githubFolderRepo(cwd)) {
        if (freshRef.current) setProjectDraft(cwd);
        accepted?.(cwd);
        return Promise.resolve();
      }
      // Another computer's folder is that computer's to check.
      if (peer) {
        rememberNewChatPlace({ kind: "machine", peer });
        void callNative("chat.new", { cwd, peer }).catch(() => undefined);
        return Promise.resolve();
      }
      // Fresh or started is read when the folder is used (an answer can come later).
      return requestFolder(
        cwd,
        (folder) => {
          pickedProject.current = folder;
          if (freshRef.current) setProjectDraft(folder);
          else void callNative("chat.new", { cwd: folder }).catch(() => undefined);
          accepted?.(folder);
        },
        // Only the host's refusal of the path is `refused`; a request a newer one replaced is not.
        (refusal) => {
          if (refusal !== undefined) refused?.();
        },
      );
    },
    [folderContinuation, requestFolder],
  );
  /// The folder another chat's `/cd --on cloud` handed this New Cloud Chat (commandPlace.ts): once
  /// the page is ready, it opens in it as a folder pick does, which checks and grants the folder.
  const [handedFolder, setHandedFolder] = useState<string>();
  useEffect(() => {
    if (!handedFolder || !handshaken) return;
    setHandedFolder(undefined);
    let refused = false;
    void chooseProject(handedFolder, undefined, () => {
      refused = true;
    }).then(() => {
      if (refused) notices.transient(translate("composer.cmuxCdNotFolder", { folder: handedFolder }));
    });
  }, [handedFolder, handshaken, chooseProject, notices]);
  /// New Worktree (cx-lyqio.2): the new chat starts in a worktree of its folder, or says why not.

  /// `cwd`: the folder the worktree was asked for, which its Retry asks again.
  /// `github`: the GitHub repository picked for this chat on this Mac (githubRepos.ts), which Retry asks for again;
  /// `message`: the host's words for why its clone failed.
  const [worktreeError, setWorktreeError] = useState<{
    cwd: string;
    sessionId?: string;
    visit?: string;
    github?: { repo: string; candidates: string[] };
    message?: string;
  }>();
  /// New Worktree, or a GitHub repository picked for a new chat on this Mac (`github`): this Mac's checkout of
  /// it, cloned first when there is none, then the chat's worktree of that, as New Worktree makes one.
  const startInWorktree = useCallback(
    (cwd: string, github?: { repo: string; candidates: string[] }) => {
      // A newer folder pick wins over this worktree, as between two picks; the request this one
      // replaces ends as cancelled.
      dropFolderRequest.current?.();
      const pick = ++folderPick.current;
      folderConfirmGeneration.current += 1;
      folderConfirmInFlight.current = false;
      setFolderConfirming(false);
      const sessionId = shownSession.current;
      const visit = trustVisit();
      // The machine the worktree is made on, as the click saw it.
      const remote = remoteRef.current;
      setFolderAsk(undefined);
      // The worktree lands only in the chat it was made for: a chat switched to meanwhile gets nothing.
      const asked = { sessionId, ...visitOf(visit) };
      const stillHere = () => inThisVisit(asked, shownSession.current, trustVisit());
      setWorktreeError(undefined);
      setWorktreeCreating(github ? { ...asked, repo: github.repo } : asked);
      const use = (folder: string) => {
        // The person's pick: a send there makes it the New Tab default (newtab/startedProject.ts).
        pickedProject.current = folder;
        // A chat that started meanwhile keeps its folder: the worktree gets a new chat of its own.
        if (freshRef.current) setProjectDraft(folder);
        else void newChatInWorktree(callNative, folder, remote).catch(() => undefined);
      };
      void newWorktree(
        callNative,
        cwd,
        (folder) => {
          if (pick === folderPick.current && stillHere()) use(folder);
        },
        github,
      )
        .then(({ ask }) => {
          // The host asks about the worktree's folder first: the question shows as a picked folder's.
          if (ask && pick === folderPick.current) setFolderAsk({ ask, use, sessionId, ...visitOf(visit) });
        })
        .catch((error: unknown) => {
          // The notice says it plainly with Retry; the host's own words go to the log.
          console.warn("agent pane: New Worktree failed", error);
          // A clone's failure says why (no access, offline, no free folder) in the host's own words; any other
          // refusal reads as New Worktree's.
          const code = (error as { code?: unknown } | null)?.code;
          const cloneFailure = code === "github.clone_failed" || code === "github.clone_no_folder";
          const message = github && cloneFailure ? errorMessage(error).trim() || undefined : undefined;
          if (pick === folderPick.current)
            setWorktreeError({ cwd, ...asked, ...(github ? { github } : {}), ...(message ? { message } : {}) });
        })
        .finally(() => {
          if (pick === folderPick.current) setWorktreeCreating(false);
        });
    },
    [trustVisit],
  );
  const automationPick = useRef<(cwd: string) => void>(undefined);
  automationPick.current = (cwd) => chooseProject(cwd);
  /// The composer for automation (automation.ts composeSend, runMode): its own Return and run row.
  const automationCompose = useRef<AutomationCompose>(undefined);
  automationCompose.current = {
    async send(text) {
      const handle = composerHandle.current;
      if (!handle) return undefined;
      handle.restore(text, []);
      // A field whose editor is still starting takes the text as state: let it render first.
      await new Promise((resolve) => setTimeout(resolve, 50));
      return composerHandle.current?.send();
    },
    runMode: () => sandbox.mode,
    setRunMode(mode) {
      // An empty local chat offers Cloud and This Mac, never Sandboxed (`emptyLocalChat`).
      const offered = sandboxOffered || (cloudOffered && mode !== "sandboxed");
      if (!offered && !sandboxPickedNotOffered && !cloudPickedNotOffered) return false;
      // An automation's mode is this chat's only, never the person's pick for the next new chat.
      applyRunMode(mode);
      return true;
    },
    cloudStart: () => cloudStart ?? null,
    // What holds Send now (a kept `compose_send` reports it): the sign-in notice's own words, else a code.
    blocked: () =>
      authBlock ??
      (pendingFolder || confirmingHere
        ? "folder_question"
        : cloudSendHeld
          ? "cloud_start_out"
          : sandboxHoldsChat && !sandboxDraftMoved
            ? "sandbox_holds_chat"
            : undefined),
  };
  const focusComposer = () => composerHandle.current?.focus();
  useEffect(() => {
    return paneSnapshotEffect({
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
      setRelinkingSince,
      setHostTroubleSince,
      setHostRestoring,
      runPendingAdoption,
      freshRef,
      inheritedFolderRef,
      setHandedFolder,
      automationPick,
      automationCompose,
      focusComposer,
    });
    // These are stable for the pane's life (state, provider client, a memoized bridge callback, and
    // the early New Tab flag and the pending pane draw, objects from useState initializers).
  }, [
    connectedClients,
    folderContinuation,
    harnessSwitch,
    readSendAgain,
    readInterruptedResume,
    newChatPrewarm,
    queryClient,
    toggleInspector,
    earlyNewTab,
    checkSharedPart,
    restartGate,
    sandbox,
    cloudTypingPrewarm,
    notices,
    quoteReply,
    inheritedFolderRef,
    pendingPaneDraw,
  ]);
  const registryChips = (window.cmuxAcpmuxRegistry as unknown as Record<string, unknown> | undefined)?.composerChips as
    | React.ComponentType<{ snapshot: AcpmuxSnapshot }>
    | undefined;
  const ComposerChips = registryChips ?? DefaultComposerChips;
  // The catalog arrives through the query cache, which composerSnapshot carries.
  // A socket the pane is already asking for again is quiet in the header; only a failure said above
  // the composer is a failure.
  // A failure the pane clears by asking again by itself (a machine rebooting) is quiet in the
  // header too: the one line above the composer says Reconnecting… (HostError.tsx).
  const header = paneHeader(composerSnapshot, t, {
    hostRecovering: !hostErrorShown || hostSelfRetrying(hostFailure, acpmuxRestartOffered),
  });
  // The pane header never says where the chat runs (Leo 2026-10-26); Session Info's Environment does.
  const handoffTargets = continueTargets(composerSnapshot.catalog, snapshot.summary?.harness, snapshot.summary?.family);
  const canContinue = continueAvailable;
  const ignoreFailure = (result: Promise<unknown>) => void result.catch(() => undefined);
  /// What a cmux-owned command's refusal rule reads (cmuxCommandRefusal), for the chat or New Tab.
  const commandState = (fresh: boolean) => ({
    summary: !fresh && !!snapshot.summary,
    forkable: !fresh && forkable && forkSeq !== undefined,
    sideFork: sideChatRefusal(snapshot, sidePlace),
    sideAvailable: !fresh && sidePlace !== undefined,
    canContinue: !fresh && canContinue,
    sideSessions: opensSideSessions,
    session: !fresh && !!snapshot.sessionId,
    isSideSession,
    targets: fresh ? [] : handoffTargets,
    cwd: snapshot.summary?.cwd,
    newTab: fresh,
    inCloud: snapshot.summary?.hostKind === "cloud",
    cloudStart: !quick,
    // Before a chat starts there is no `hostKind`: the picked run mode says where it will run.
    // A started chat on another machine (its `peer`) would customize that machine's cmux.
    startsElsewhere: newChatRunsElsewhere({
      started: !fresh && !!snapshot.sessionId,
      peer: !!snapshot.summary?.peer,
      mode: sandbox.mode,
    }),
  });
  /// A started chat's `/side --on cloud` and `/cd --on cloud`: New Cloud Chat, on the person's
  /// gesture, with `start` handed to the tab it opens under a one-time token (commandPlace.ts). That
  /// tab's first Send is its own Cloud start. A tab that did not open drops the hand-off.
  const openCloudChatWith = (start: { prompt?: string; cwd?: string }): Promise<unknown> => {
    const store = handoffStore();
    const handoff = handCloudStart(store, start, Date.now());
    return callNative("action.run", { id: "palette.newCloudChat", ...(handoff ? { handoff } : {}) }).catch(
      (error: unknown) => {
        dropHandedCloudStart(store, handoff);
        throw error;
      },
    );
  };
  /// A start refused because a chat is already starting in this tab (`unavailable_now`): the same prompt and folder
  /// go to a new Cloud chat, as the held send's refusal offers; this card closes and the composer keeps the prompt.
  const openNewCloudChatForStart = () => {
    const start = cloudStart;
    if (!start) return;
    const attempt = lastCloudAttempt.current;
    const cwd = attempt?.key === start.key ? attempt.request.cwd : undefined;
    dismissCloudFailure();
    void openCloudChatWith({ prompt: start.task, ...(cwd ? { cwd } : {}) }).catch(() => undefined);
  };
  /// A harness's local command typed alone (localCommands.ts): its GUI answer, now, mid-turn too.
  /// False where this chat has nothing to show it in (Session Info off): it goes to the harness.
  const handleLocalCommand = (command: LocalCommand): boolean => {
    const { action } = command;
    if (action.kind === "changes") {
      if (quick) return false;
      openChangesTab.current();
      return true;
    }
    if (action.kind !== "section" || !sessionInfo.reveal) return false;
    sessionInfo.reveal(action.section);
    return true;
  };
  /// Shared by the chat composer and New Tab: cmux-owned slash commands never fall through to a
  /// literal harness prompt. A string is an inline refusal; Composer/NewTab keep the draft intact.
  const handleCmuxCommand = (
    command: CmuxCommand,
    typedArgs?: string,
    fresh?: boolean,
    attachments?: ComposerAttachment[],
    gesture?: SendGesture,
  ): CmuxCommandResult =>
    runCmuxCommand(
      {
        btwNotes,
        chooseProject,
        commandState,
        composerModePick,
        composerSnapshot,
        directClient,
        forkSeq,
        handoffTargets,
        healthHarness,
        healthLocal,
        ignoreFailure,
        openCloudChatWith,
        sessionAuth,
        sessionInfo,
        setContinuing,
        setStatusCardOpen,
        showAllChats,
        signIn,
        snapshot,
        t,
        turnRowsShown,
      },
      command,
      typedArgs,
      fresh,
      attachments,
      gesture,
    );
  // The header's tools and "..." menu run app actions on this chat's tab.
  // A quick action names its mode; the App toggles the split it opened (header/quickActions.ts).
  const runHeaderAction = (id: string, cwd?: string, mode?: QuickActionMode) => {
    // Changes offers the chat's latest turn as the diff tab's Last turn (a chat on this Mac: `cwd`).
    const pair = id === HEADER_ACTIONS.changes && cwd ? latestTurnCheckpointPair(snapshot.rows) : undefined;
    const turn = pair ? { turn: { ...pair, show: false } } : {};
    ignoreFailure(
      callNative("pane.action", {
        id,
        ...(cwd ? { cwd } : {}),
        ...(mode ? { mode } : {}),
        ...turn,
      }),
    );
  };
  const runHeaderActionRef = useRef(runHeaderAction);
  runHeaderActionRef.current = runHeaderAction;
  // Continue After Error (palette, CLI, MCP) runs the failed last turn's own way on, as its card's
  // lead button and Return do (conversation/errorRecovery.ts); with none it says why.
  const continueAfterErrorRef = useRef<() => void>(() => undefined);
  continueAfterErrorRef.current = () => {
    const failed = lastFailedTurn(transcriptRows);
    const recovery = failed && errorRecovery(failed, turnActions.route, turnActions);
    // A refusal (busy, nothing failed any more) says why, as the card's note does.
    const notice = (text: string) => notices.transient(text);
    if (!recovery) notice(t("turn.nothingToContinue"));
    else
      void recovery.run().then(
        (note) => note && notice(t(note)),
        () => notice(t("retry.failed")),
      );
  };
  // The account's machine a Cloud chat runs on, for the chat menu's Pause and Resume; the
  // account's list is read when such a chat shows (and after each pick), never on a timer.
  const accountMachines = useCloudMachines();
  const chatMachine = chatCloudMachine(summary, accountMachines);
  // Leo, 2026-11-04: "as the user's selected cloud/is typing in it… that's when we can do an
  // optimistic resume". A keystroke in a Cloud chat whose machine reads paused wakes it with that
  // key's gesture (its scope credit; the Enter that sends keeps its own), once per sleep.
  const wakeOnTyping = () => {
    const chat = cloudTypingWakes({
      ...cloudWakeState,
      asleep: cloudRecovery.state === "paused" || chatMachine?.stage === "paused",
      woke: cloudTypeWoke.current,
    });
    if (!chat || cloudRecovery.state === "deleted" || snapshot.summary?.watching) return;
    cloudTypeWoke.current = chat;
    setCloudTypeWaking(true);
    cloudRecovery.resume();
  };
  const cloudChat = summary?.hostKind === "cloud";
  useEffect(() => {
    if (cloudChat) void refreshCloudMachines();
  }, [cloudChat, snapshot.sessionId]);
  // Cloud picked for a new chat: the plan is read now (`cloudMachine.list` `plan`), so a Send without one shows the
  // pricing card at once instead of a start the platform refuses.
  useEffect(() => {
    if (cloudPicked) void refreshCloudMachines();
  }, [cloudPicked]);
  // Stop and Pause waits for the chat's turn to end before it pauses (cloudMachineMenu.ts): its
  // own turn state, which a forced stop's cleared working indicator does not end.
  const stopWaiter = useMemo(createStopWaiter, []);
  useEffect(() => stopWaiter.changed(), [snapshot, stopWaiter]);
  // A remote or cloud chat's folder is not on this Mac; its terminal opens in the pane's folder.
  instructionsFolder.current = localCwd;
  chatIsLocal.current = localCwd !== undefined;
  // Another chat or folder: an instructions notice was about the one before.
  useEffect(() => setInstructionsFailure(undefined), [snapshot.sessionId, localCwd]);
  // The header's state from the chat's tab (header/headerState.ts): read when a chat opens, then pushed
  // by the App on every change. Whether the panes beside the chat show ([+] New tab reads Hide tabs) also
  // follows the App's answer to the click.
  const {
    sideTabs,
    pullRequest: headerPullRequest,
    moves,
    moveReasons,
    moveTargets,
    lit: litSplits,
  } = useHeaderState();
  // The moves the chat's own right-click menu offers now: the composer's picker offers the same.
  const offloads = useMemo(
    () => (["move", "bringBack"] as const).filter((kind) => moves.includes(CONNECT_ACTIONS[kind])),
    [moves],
  );
  // Why each offered move would refuse now: the picker greys its row and says it.
  const offloadReasons = useMemo(() => offloadReasonsOf(offloads, moveReasons), [offloads, moveReasons]);
  const toggleSideTabs = () =>
    ignoreFailure(
      callNative<{ shown?: boolean }>("pane.action", { id: "sideTabs" }).then((result) =>
        setHeaderState({ sideTabs: result?.shown === true }),
      ),
    );
  const archived = snapshot.sessions.some((session) => session.sessionId === snapshot.sessionId && session.archived);
  // Archive and Mark as Unread are acpmux requests on the pane's own connection (cx-jlzsf); only
  // closing an archived chat's tab is the host's (a tab is the window's).
  const openClient = async () => {
    const client = directClient.current;
    if (!client) throw new Error(translate("error.notOpen"));
    return client;
  };
  const archiveChat = async (archived: boolean) => {
    const client = await openClient();
    // The chat the archive acts on is the client's own (direct.ts `archive`), not a rendered id:
    // its completion is bound to that chat, even when a snapshot hold still showed it after a switch.
    const sessionId = await client.archive(archived);
    // Quick Chat's panel has no tab to close.
    if (!archived || quick || directClient.current !== client) return;
    // Archiving hides the chat from the lists, so the client may already have left it for its
    // fallback (none, or the most recent chat): that is this archive's own completion. A chat the
    // person selected while the archive was out keeps the tab (header/archiveClose.ts).
    if (archiveClosesTab(client, sessionId)) await callNative("pane.action", { id: "closeTab" });
  };
  const deleteChat = async () => {
    const target = deleteConfirmSession;
    const client = directClient.current;
    if (!target || target !== snapshot.sessionId || !client || client.selectedSession !== target) return;
    deleteInFlight.current = { target, client, harness: snapshot.summary?.harness };
    await client.purge(target);
    // The purge can resolve after the dialog was dismissed or the pane selected another chat.
    // Never close the newly selected tab for the old chat's completion.
    // A purge clears the client's selected session as part of its own notification; that is the
    // completion we want to close. A navigation, however, selects another session on the same
    // client and must win over this old deletion.
    if (
      deleteInFlight.current?.target !== target ||
      deleteInFlight.current.client !== client ||
      directClient.current !== client ||
      !deleteClosesTab(client, target)
    )
      return;
    deleteInFlight.current = undefined;
    setDeleteConfirmOpen(false);
    setDeleteConfirmSession(undefined);
    if (!quick) await callNative("pane.action", { id: "closeTab" });
  };
  const requestDelete = () => {
    if (!snapshot.sessionId) return;
    setDeleteConfirmSession(snapshot.sessionId);
    setDeleteConfirmOpen(true);
  };
  useEffect(() => {
    if (deleteConfirmSession && snapshot.sessionId && deleteConfirmSession !== snapshot.sessionId) {
      setDeleteConfirmSession(undefined);
      setDeleteConfirmOpen(false);
      deleteInFlight.current = undefined;
    }
    if (
      deleteInFlight.current?.harness &&
      snapshot.summary?.harness &&
      deleteInFlight.current.harness !== snapshot.summary.harness
    ) {
      deleteInFlight.current = undefined;
    }
    if (deleteInFlight.current && snapshot.sessionId === undefined && !directClient.current?.purgeInFlight) {
      deleteInFlight.current = undefined;
    }
  }, [deleteConfirmSession, snapshot.sessionId, snapshot.summary?.harness]);
  const archive = archiveRow(
    {
      sessionId: snapshot.sessionId,
      archived,
      local: localCwd !== undefined,
    },
    (archived) => ignoreFailure(archiveChat(archived)),
    t,
  );
  archiveChatRef.current = archive && !archived ? archive.onSelect : undefined;
  const markUnread = markUnreadRow(
    {
      sessionId: snapshot.sessionId,
      archived,
      local: localCwd !== undefined,
      unread: snapshot.sessions.some((session) => session.sessionId === snapshot.sessionId && session.unread === true),
    },
    () => ignoreFailure(openClient().then((client) => client.markUnread())),
    t,
  );
  // The session's own avatar (its cards and sender chip draw it): Set Chat Avatar… draws it, and the
  // menu offers Remove Chat Avatar with one.
  const avatarSrc = useAgentAvatar(snapshot.sessionId);
  const avatar = avatarRows(
    { sessionId: snapshot.sessionId, avatar: avatarSrc },
    {
      set: () => snapshot.sessionId && ignoreFailure(setAgentAvatar(snapshot.sessionId)),
      remove: () => snapshot.sessionId && ignoreFailure(removeAgentAvatar(snapshot.sessionId)),
    },
    t,
  );
  // What the host's mini shows (the Chief or one chat): the menu's Show in Mini row reads it.
  useChatMini(quick ? undefined : snapshot.sessionId);
  useEffect(() => {
    const run = (event: Event) => {
      const name = (event as CustomEvent<unknown>).detail;
      const parsed = parseMenuCommand(name);
      if (!parsed || !isCurrentMenuCommand(name, snapshotRef.current?.sessionId)) return;
      const { action, sessionId } = parsed;
      // A command queued for a previous chat must never act on the page now shown in this pane.
      if (!sessionId || snapshotRef.current?.sessionId !== sessionId) return;
      switch (action) {
        case "toggleDisplaySettings": {
          const anchor = Array.from(document.querySelectorAll<HTMLElement>(".acpmux-header-tools button")).find(
            (button) => button.getAttribute("aria-label") === t("chatMenu.open"),
          );
          setDisplayAnchor(anchor ?? document.querySelector<HTMLElement>(".acpmux-header-tools"));
          break;
        }
        case "replayConversation":
          // Replay is an experiment-gated page surface. A palette row cannot bypass that gate.
          if (experimentArm(sessionReplay) === "on") setReplaying(sessionId);
          break;
        case "editInstructions":
          instructionsRow(
            { cwd: localCwd, family: summary?.family || summary?.harness },
            openInstructions,
            t,
          )?.onSelect?.();
          break;
        case "addProjectFiles":
          projectFilesRow(
            { cwd: localCwd, family: summary?.family || summary?.harness },
            (cwd, name) => ignoreFailure(callNative("project.addFiles", { cwd, name })),
            t,
          )?.onSelect?.();
          break;
        case "floatingChat":
          runHeaderActionRef.current(HEADER_ACTIONS.floatingChat);
          break;
        case "toggleMinimap":
          setMinimapVisible((visible) => !visible);
          break;
        case "continueAfterError":
          continueAfterErrorRef.current();
          break;
      }
    };
    window.addEventListener("cmux-acpmux-menu-command", run);
    return () => window.removeEventListener("cmux-acpmux-menu-command", run);
  }, [localCwd, openInstructions, summary?.family, summary?.harness, t]);
  // `pair`: also ask whether a terminal runs this chat (its "..." offers Switch to terminal): the App walks every
  // machine's agents for it, so only the chat's load and its menu opening ask, never a hover.
  const readTabState = (pair = false) =>
    callNative("pane.tabState", pair ? { terminalSwitch: true } : undefined).then(setHeaderState);
  const refreshTabState = () => void readTabState().catch(() => undefined);
  // Terminal and Browser change what is beside the chat: [+] follows once their split lands.
  const runSplitAction = (id: string, cwd: string | undefined, mode: QuickActionMode) => {
    runHeaderAction(id, cwd, mode);
    window.setTimeout(refreshTabState, 400);
  };
  // Changes opens the folder's diff tab beside the chat. A folder outside a repository has no diff for
  // that tab, and the app's fallback was the folder picker in the palette (Leo, 2026-10-28: "All it does
  // is open up the command palette, and it doesn't open up the diff viewer on the right side"), so there
  // it opens the last turn's own changes in that tab, as the edited-files card does; only where no tab
  // can open does it toggle the page's changes view.
  const toggleChanges = (mode: QuickActionMode) => {
    void headerChangesInPlace(chatCwd, litSplits.includes(HEADER_ACTIONS.changes), readFolderStatus).then((inPlace) => {
      if (!inPlace) return runSplitAction(HEADER_ACTIONS.changes, chatCwd, mode);
      const turn = cardEdit.turn;
      if (turn) void diffBeside.current(turn.rowId, undefined, mode).catch(() => false);
    });
  };
  openChangesTab.current = () => toggleChanges("open");
  const togglePreview = (url: string | undefined) => {
    ignoreFailure(callNative("pane.action", { id: HEADER_ACTIONS.preview, ...(url ? { url } : {}), mode: "toggle" }));
    window.setTimeout(refreshTabState, 400);
  };
  // The header's toggles the native palette runs (AgentPaneView+Commands.swift), each only where the
  // header offers it: Quick Chat's panel has no tabs beside it, a remote chat's folder is not on this
  // Mac, and Preview needs the chat's page or the preview it opened. The App greys out the rest.
  const commands: Record<string, () => void> = {};
  if (!quick) commands.toggleSideTabs = toggleSideTabs;
  if (!quick && localCwd) commands.toggleFiles = () => runSplitAction(HEADER_ACTIONS.files, localCwd, "toggle");
  if (!quick && (previewUrl || litSplits.includes(HEADER_ACTIONS.preview)))
    commands.togglePreview = () => togglePreview(previewUrl);
  // Ctrl-B's move, while it has something to move; queueing's toggle, as a queued row's ⋯ menu has it.
  // The bridge runs these only while the client and this render still show the palette's chat
  // (`header:` above), so chat A's row never moves B's work or opens B's Session Info.
  if (!quick && (foreground.length > 0 || foregroundAgent)) commands.runInBackground = runInBackground;
  commands.toggleQueueing = () => setQueueing(!queueingOn());
  // Session Info opened at a section, while it lists rows there for the view on screen: a subagent's
  // view lists its own subagents, processes and transcript work (session-info/subagentScope.ts), the
  // chat's view its own and the chat's workflows and started chats.
  const revealSection = sessionInfo.reveal;
  const listedAgents = sessionInfoSubagent
    ? sessionInfoSubagent.agents.length
    : trayAgents.length + childSessions.length;
  if (revealSection && listedAgents > 0) commands.showSubagents = () => revealSection("subagents");
  if (revealSection && backgroundRows > 0) commands.showBackgroundTasks = () => revealSection("tasks");
  paletteCommands.current = { sessionId: snapshot.sessionId ?? "", commands };
  const commandNames = Object.keys(commands).sort().join(" ");
  // Again for every client: the host's handshake (a reconnect's too) forgets the list, and a new
  // client follows its handshake (connectHost).
  useEffect(() => {
    const available = commandNames ? commandNames.split(" ") : [];
    void callNative("pane.commandAvailability", { commands: available }).catch(() => undefined);
  }, [commandNames, snapshot.sessionId, clientEpoch]);
  diffBeside.current = async (rowId, path, mode = "open") => {
    // Quick Chat's panel has no pane beside it: the chat moves to a tab in the main window (Open in
    // Window), where View changes opens its diff on the chat's right. A remote or Cloud chat's folder
    // is read on its machine: the session host answers git.status, and the app's diff tab reads the
    // chat's machine (#25696).
    if (quick) {
      if (snapshot.sessionId) postOpenInWindow(snapshot.sessionId);
      return Boolean(snapshot.sessionId);
    }
    if (!chatCwd) return false;
    const rows = turnRowsRef.current;
    // The folder's diff is its repository's: a folder outside one, or a file the turn wrote outside
    // the repository, opens the tab on the turn's own patch (turnChanges/viewChanges.ts).
    // A remote or Cloud chat's turn always opens as its own patch, from the same checkpoint-or-edits
    // choice the page's own view made (a checkpoint that is missing, partial or pruned falls back to
    // the tool calls' edits), so the tab never shows less than the page did.
    const root = localCwd ? await repositoryRoot(chatCwd, readFolderStatus) : undefined;
    let target: Record<string, unknown>;
    if (root && viewChangesBeside(rows, rowId, root)) {
      // The tab opens on the turn (its Last turn), at the row's file; a turn with no checkpoint pair
      // opens the folder's diff.
      const turn = viewChangesTurn(rows, rowId, path, root, chatCwd);
      target = turn ? { turn } : {};
    } else {
      // The turn's checkpoint diff with its edits outside the repository, as the page's own view
      // shows a mixed turn, so a repository change no tool call made still shows.
      const files = await viewChangesFiles(rows, rowId, checkpointDiff);
      const patch = viewChangesPatch(rows, rowId, path, chatCwd, files);
      if (!patch) return false;
      target = { patch };
    }
    const reply = await callNative<{ ran?: boolean } | null>("pane.action", {
      id: HEADER_ACTIONS.changes,
      cwd: chatCwd,
      mode,
      ...target,
    });
    window.setTimeout(refreshTabState, 400);
    return reply?.ran === true;
  };
  // The label starts from the chat's layout; Quick Chat's panel has no tab to read.
  useEffect(() => {
    if (!quick) void readTabState(true).catch(() => undefined);
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- reread per chat, not per render
  }, [quick, snapshot.sessionId]);
  // A turn's end asks the App for the chat's pull request again (cx-ncc.77.1): the agent may have
  // created it or pushed to it, and the chip should not wait for its next read.
  // Which ends count: `turnEndedBetween`.
  const wasWorking = useRef({
    session: snapshot.sessionId,
    working: snapshot.isWorking,
    turnsEnded: snapshot.turnsEnded,
  });
  useEffect(() => {
    const next = { session: snapshot.sessionId, working: snapshot.isWorking, turnsEnded: snapshot.turnsEnded };
    const ended = turnEndedBetween(wasWorking.current, next);
    wasWorking.current = next;
    if (ended && !quick)
      void callNative("pane.tabState", { refresh: true })
        .then(setHeaderState)
        .catch(() => undefined);
  }, [snapshot.sessionId, snapshot.isWorking, snapshot.turnsEnded, quick]);
  const finishTurnSummary = useMemo(() => newestTurnSummary(snapshot.rows), [snapshot.rows]);
  // A long turn's end, green checks and a merge: the short "done" state and its sound (finish/).
  useFinishMoments({
    session: snapshot.sessionId,
    working: snapshot.isWorking,
    turnStartedAtMs: snapshot.turnStartedAtMs,
    clockOffsetMs: snapshot.clockOffsetMs,
    stopping: snapshot.stopping === true,
    pullRequest: headerPullRequest,
    turnSummary: finishTurnSummary,
  });
  // A floating chat's panel that held this chat before the page loaded (a tab moved there, a reload)
  // says so once; later changes are pushed, and a reread per chat could land after a newer push.
  useEffect(() => {
    if (quick)
      void callNative("quick.floatingState")
        .then(setFloatingState)
        .catch(() => undefined);
  }, [quick]);
  // Needs you (needsYou/): the header's badge and list, and the transcript's Needs your input pill.
  const needsYou = useNeedsYou({
    snapshot,
    callNative,
    sideSession: async (sessionId, question) => {
      const client = directClient.current;
      if (!client) throw new Error(translate("needsYou.askFailed"));
      await postNative("chat.sideChat", { sessionId: await client.btw(question, sessionId) });
    },
  });
  // Steer queue (steerQueue/): ⌘⇧J or the chat menu opens it over the chat. Each step opens the chat
  // it acts on first, so the step goes through the same send, Stop and fork the chat's own composer
  // and menu use, and the person sees it land in the chat under the queue.
  // The agent status island (statusIsland/, experiment `agent-status-island`, off by default): a
  // floating pill that morphs into the card of the agent that needs the person. Its answers go
  // through Needs you's own actions; it replaces nothing.
  const statusIsland = useStatusIsland(!quick && experimentArm(statusIslandExperiment) === "on", snapshot);
  const steerQueueOn = !quick && experimentArm(steerQueueExperiment) === "on";
  useEffect(() => {
    if (!steerQueueOn) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.repeat || !(event.metaKey && event.shiftKey && event.key.toLowerCase() === "j")) return;
      event.preventDefault();
      setSteering((open) => !open);
    };
    // ui-allow: the Steer queue's one opening key, page-wide while its experiment is on.
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [steerQueueOn]);
  useEffect(() => {
    if (!steering) return;
    setSteerLog(readSteerLog());
    setSteerNow(Date.now());
    // Ages tick while the queue is open, and only then.
    const timer = window.setInterval(() => setSteerNow(Date.now()), 30_000);
    return () => window.clearInterval(timer);
  }, [steering]);
  const steerItems = useMemo(
    () => (steering ? steerQueue({ sessions: snapshot.sessions, now: steerNow || Date.now(), log: steerLog }) : []),
    [steering, snapshot.sessions, steerNow, steerLog],
  );
  const steerActions = useMemo<SteerActions>(() => {
    // Opens the chat and waits until it is the one drawn: Stop and Fork act on the drawn chat, which
    // during a switch's hold is still the chat before.
    const openChat = async (sessionId: string) => {
      if (directClient.current?.selectedSession !== sessionId) await callNative("chat.select", { sessionId });
      if (!(await directClient.current?.shownAndAttached(sessionId)))
        throw new Error(translate("steerQueue.state.failed"));
    };
    // Settles once acpmux took the prompt, as a composer send does (sendWhenTaken).
    const sendTo = (sessionId: string, text: string, steer: boolean) =>
      new Promise<void>((resolve, reject) => {
        callNative("chat.send", {
          text,
          attachments: [],
          steer,
          expectedSessionId: sessionId,
          accepted: () => resolve(),
        }).then(
          () => resolve(),
          // A prompt the folder's trust holds is taken: it goes once the folder is trusted.
          (error: unknown) => (heldRefusal(error) ? resolve() : reject(error)),
        );
      });
    return {
      steer: async (item, text) => {
        await openChat(item.sessionId);
        await sendTo(item.sessionId, text, item.running);
      },
      // Stop, then the line as the next prompt: acpmux runs it once the stopped turn ends.
      redirect: async (item, text) => {
        await openChat(item.sessionId);
        await callNative("chat.cancel");
        await sendTo(item.sessionId, text, false);
      },
      stop: async (item) => {
        await openChat(item.sessionId);
        await callNative("chat.cancel");
      },
      // A fork the chat refuses (nothing to fork yet) answers nothing, and says why in its own toast.
      fork: async (item) => {
        await openChat(item.sessionId);
        if ((await callNative("chat.forkTo", {})) === undefined) throw new Error(translate("steerQueue.state.failed"));
      },
      // The queue closes once the chat is drawn, and a line typed for it goes on in its composer,
      // ahead of what it holds: a refused switch keeps the queue and the line.
      open: async (item, draft) => {
        await openChat(item.sessionId);
        setSteering(false);
        if (draft) composerHandle.current?.prefill(`${draft} `);
      },
    };
  }, []);
  const lastForkSeq = latestForkSeq(snapshot.rows);
  const sideChat = sideChatRow(
    // Quick Chat's panel is not a tab: there is no split to open beside it (no `sidePlace`).
    {
      canFork:
        sidePlace === "machine" ? !snapshot.isWorking && sideChatRefusal(snapshot, sidePlace) === undefined : forkable,
      throughSeq: lastForkSeq,
      place: sidePlace,
    },
    (throughSeq) => ignoreFailure(callNative("chat.side", { throughSeq })),
    t,
  );
  opensSideChat.current = sideChat !== undefined;
  // Sources' +: the host's panel picks files and folders on this computer, which the composer holds
  // as links for the next prompt (resource_link blocks: the agent reads them where they are).
  const attachLinks = async () => {
    for (const item of linkItems(await callNative("chat.attach.choose")))
      composerHandle.current?.attach(linkAttachment(item.path, item.folder));
    composerHandle.current?.focus();
  };
  // New terminal and New browser (the chat menu, the summary panel): another one beside the chat on
  // every click, whatever the header's Terminal and Browser buttons do.
  const newTerminal = () => runSplitAction(HEADER_ACTIONS.terminal, localCwd, "open");
  const newBrowser = () => runSplitAction(HEADER_ACTIONS.browser, undefined, "open");
  const chatMenu = (): ChatMenuItem[] =>
    chatMenuItems({
      accessGrants,
      archive,
      avatar,
      canContinue,
      chatMachine,
      checkpointLabels,
      checkpoints,
      directClient,
      forkable,
      handoffLabels,
      handoffTargets,
      ignoreFailure,
      inspectorOpener,
      lastForkSeq,
      localCwd,
      markUnread,
      moveChatToMachine,
      moveTargets,
      moves,
      newBrowser,
      newTerminal,
      notices,
      offloadChat,
      onOtherMachine,
      openBackgroundPanel,
      openInstructions,
      quick,
      readSendAgain,
      requestDelete,
      runHeaderAction,
      saveDocumentNatively,
      setDisplayAnchor,
      setReplaying,
      setShareOpen,
      setSteering,
      sideChat,
      snapshot,
      stopWaiter,
      summary,
      t,
      toggleInspector,
      turnActions,
    });
  // A double-click on the plain title renames, as ⌘R does; Quick Chat's panel is not a tab to rename.
  const renameFromTitle = quick ? undefined : () => runHeaderAction(HEADER_ACTIONS.rename);
  // Before the handshake the New Tab frame shows (cx-0rpl.10) unless the host failed: then the
  // chat view's error card with Retry shows, as before.
  const showNewTab =
    newTab !== undefined &&
    // The tab's Sandboxed result shows in the chat view (SandboxRunView). So does a draft a
    // Sandboxed refusal moved from the New Tab page into the chat composer: going back would remount
    // the page without it. A host that couldn't be read leaves the page as it is (its draft with it):
    // Sandboxed isn't offered until a read answers, and the chat view offers Check again.
    sandboxView === undefined &&
    !sandboxDraftMoved &&
    cloudLeftPage !== newTabGeneration &&
    (newTabStartPage === newTabGeneration ||
      ((sessionSelection?.state === "pending" || !snapshot.sessionId) && snapshot.rows.length === 0)) &&
    (handshaken || hostError === undefined);
  // The extension the person picked to draw the whole page (`tabs.newTabApp`), until it could not show.
  const newTabApp = showNewTab ? pickedNewTabApp(newTab, newTabAppGone, newTabAdoptions) : undefined;
  /// The chat view (header, transcript, dock and composer) shows: no page or screen stands in its place.
  const showsChatView =
    !showNewTab && !harnessesOpen && !contextOpen && !(replaying && replaying === snapshot.sessionId);
  /// A New Tab page (the prewarmed spare among them) keeps the chat view built and hidden under it
  /// (`<Activity mode="hidden">`: rendered when React is idle, no effects), so a chat it takes
  /// (`acpmux-session-adopt`, a start from the page) only shows it and draws the chat's rows: the
  /// adopt event's task was one ~70 ms React pass building the whole view in New Tab's place. The
  /// hidden view holds the (empty) transcript, not a new chat's hero and lists: a taken chat shows rows.
  const premountsChatView = showNewTab && !harnessesOpen;
  /// A chat view that showed and then went under a New Tab page (Cmd-T in this page, a host that
  /// answered after its error) is built again: the hidden one is always a fresh mount, as the view
  /// the adopt used to build, so no draft or picker state of the chat it showed carries over.
  const chatViewMount = useRef({ shown: showsChatView, key: 0 });
  if (chatViewMount.current.shown && !showsChatView) chatViewMount.current.key += 1;
  chatViewMount.current.shown = showsChatView;
  /// Experiment (bench `PARK=visible`): park the view drawn but invisible and inert instead of under
  /// `<Activity mode="hidden">`, so its effects run while parked and its reveal runs none.
  const [parkVisible] = useState(spareParkVisible);
  const parkedVisible = premountsChatView && !showsChatView && parkVisible;
  const parkStyle = parkedVisible ? PARKED_STYLE : undefined;
  if (newTab !== undefined && !handshaken && hostError !== undefined) composerStoodIn.current = true;
  /// The one-time Cloud hint shows on a new chat this Mac starts while Cloud is offered and is not
  /// its mode (cloudChatHintModel.ts); never in a quick chat or a chat on another machine.
  /// It shows at most once per install: the page asks the app when the moment fits, and the app's
  /// yes spends the tips' one 14-day budget.
  const cloudHintFacts = {
    record: cloudHint.record,
    tipsOn: featureTipsOn,
    cloudOffered: sandboxOffered,
    cloudPicked: sandbox.mode === "cloud",
    started: Boolean(snapshot.sessionId),
  };
  /// Only where it draws: the chat composer, or the New Tab screen (not the classic New Tab page,
  /// history, nor an extension's page), so a claim never spends the budget on a hint nobody saw.
  const cloudHintDraws =
    !showNewTab || (newTab !== undefined && !newTab.history && !newTabApp && shownTemplate(newTab) !== "classic");
  const cloudHintDue = !quick && !onOtherMachine && cloudHintDraws && cloudChatHintDue(cloudHintFacts);
  /// Only the page the person looks at asks: a spare in the pool never does.
  useCloudChatHintClaim(cloudHintDue, cloudHint.claim);
  const cloudHintShown = !quick && !onOtherMachine && cloudChatHintShown(cloudHintFacts);
  /// New Cloud Chat, pending until taken: the New Tab page takes it (`cloudPick`) or this composer
  /// picks Cloud once it is offered; a chat that already started drops it.
  const cloudPickPending = cloudPickRequest > cloudPicksDone;
  const takeCloudPick = useCallback(() => setCloudPicksDone(cloudPickRequest), [cloudPickRequest]);
  const pickCloudInComposer = useEffectEvent(() => {
    if (sandbox.mode !== "cloud") composerModeRows.onMode("cloud");
  });
  /// The classic page has no Where menu: New Cloud Chat leaves it for the chat composer (as a Cloud
  /// send from a page does, `cloudLeftPage`), which then picks Cloud below.
  const newTabWithoutCloud = showNewTab && !newTab.history && shownTemplate(newTab) === "classic";
  useEffect(() => {
    if (!cloudPickPending) return;
    if (newTabWithoutCloud && sandboxOffered && !onOtherMachine) return setCloudLeftPage(newTabGeneration);
    if (showNewTab) return;
    // A chat that started here drops it; an empty one whose local session opened first still takes it.
    if (
      snapshot.sessionId &&
      (snapshot.rows.length > 0 || (snapshot.summary?.sessionId === snapshot.sessionId && !freshChat))
    )
      return takeCloudPick();
    if (!cloudOffered || onOtherMachine) return;
    takeCloudPick();
    pickCloudInComposer();
  }, [
    cloudPickPending,
    newTabWithoutCloud,
    newTabGeneration,
    showNewTab,
    snapshot.sessionId,
    snapshot.summary?.sessionId,
    snapshot.rows.length,
    freshChat,
    cloudOffered,
    sandboxOffered,
    onOtherMachine,
    takeCloudPick,
  ]);
  // The handshake is done: the page that came back in that render took the draft (`takeDraft`
  // runs as it mounts, before this effect); an existing chat's recovery has no page to give it to.
  useEffect(() => {
    if (handshaken) composerStoodIn.current = false;
  }, [handshaken]);
  /// The New Tab page (either template) goes with its draft unsent, and the chat view takes its
  /// place: the tab's run, found by a read, or the chat view standing in before the handshake (a
  /// host that failed early). The draft goes to the chat view's composer.
  const leaveNewTabDraft = (text: string, attachments: ComposerAttachment[]) => {
    // The chat view's composer holds what the field held from here.
    leftoverInField.current = undefined;
    // A Sandboxed send from the page already took its prompt (or held it back).
    const handed = newTabSandboxSent.current;
    newTabSandboxSent.current = false;
    if (handed) return;
    const draft = { text: text.trim() ? text : "", attachments };
    // A Cloud send took the page's prompt: the chat shows it sent, and it waits here in case the start fails.
    if (newTabCloudSent.current) {
      newTabCloudSent.current = false;
      if (draft.text || draft.attachments.length) cloudPageDraft.current = draft;
      return;
    }
    const view = sandbox.view();
    if (view && !sandboxRetryable(view)) {
      heldBack.current = [...(heldBack.current ?? []), draft];
      setSandboxDraftMoved(true);
      return;
    }
    // After the handshake the page goes for a chat it started (its prompt sent) or one picked; a
    // submit queued for the handshake still sends its prompt itself.
    if (handshakenRef.current || pendingSubmits.current.length > 0) return;
    restoreComposerDraft(composerHandle, heldBack, draft.text, draft.attachments);
  };
  /// The New Tab field's text changed: a leftover it shows follows the edit (``leftoverInField``).
  const newTabFieldEdited = useCallback((text: string) => {
    if (leftoverInField.current !== undefined) leftoverInField.current = text;
  }, []);
  /// What a new chat of this window left (cmux#32276), handed with the page's context: the field
  /// shows it once per context, and the host's slot gives it up only now that a page shows it.
  const takeNewChatLeftover = () => {
    const host = newTabNow.current;
    if (!host?.draft || leftoverShownFor.current === host) return undefined;
    leftoverShownFor.current = host;
    leftoverInField.current = host.draft;
    void callNative("chat.leftoverTaken", { text: host.draft }).catch(() => undefined);
    return { text: host.draft, attachments: [] };
  };
  /// A page coming back after the chat view stood in for it: what that composer held, as its draft.
  const takeNewTabDraft = () => {
    if (!composerStoodIn.current) return takeNewChatLeftover();
    const waiting = composerHandle.current?.draft() ?? heldBack.current?.pop();
    if (heldBack.current?.length === 0) heldBack.current = undefined;
    return waiting;
  };
  // Activity disconnects the hidden page's draft/attachment/choice holds during setup. Keep
  // the reload hold in the parent until the page is visible and its own effects reconnect.
  useWebSwapHold(showNewTab && harnessesOpen ? "newtab.setup" : null);
  useEffect(() => {
    if (inspectorOpen || artifact || imageView || harnessesOpen || showNewTab || replaying) {
      clearWorkflowSideTab();
    }
  }, [artifact, harnessesOpen, imageView, inspectorOpen, replaying, showNewTab, clearWorkflowSideTab]);
  newTabRetainsDraft.current = showNewTab && newTabStartPage === newTabGeneration;
  const commandSession = showNewTab ? switchView.intent?.sessionId : undefined;
  const commandRevision = findSession(clientSnapshot.sessions, commandSession);
  const readSessionCommands = useCallback(
    (sessionId: string) => directClient.current?.sessionCommands(sessionId) ?? Promise.resolve([]),
    [],
  );
  const pendingCommands = useSessionCommands(commandSession, commandRevision, readSessionCommands);
  const inspectorHiddenSurface = quick || showNewTab;
  inspectorHiddenSurfaceRef.current = inspectorHiddenSurface;
  useEffect(() => {
    if (!inspectorHiddenSurface) return;
    inspectorOpenRef.current = false;
    setInspectorOpen(false);
  }, [inspectorHiddenSurface]);
  const importFile = useCallback(
    async (file: File) => {
      setImportError(undefined);
      try {
        const session = parseImportedSession(await file.text(), file.name || "transcript.jsonl");
        if (!session.messages.length) {
          setImportError(t("composer.cmuxImportFailed"));
          return;
        }
        await callNative("chat.new", session.cwd ? { cwd: session.cwd } : {});
        await callNative("chat.send", { text: importedPrompt(session), attachments: [] });
      } catch (error) {
        // The chat the transcript would start in did not open: plain words, the host's in the log.
        console.warn("agent pane: importing a transcript failed", error);
        setImportError(knownRefusalText(error) ?? t("composer.cmuxImportNotStarted"));
      }
    },
    [t],
  );
  /// The classic page's chat: a terminal or browser tab opens through `newTabPageSubmit`.
  const chatFromNewTab = (text: string, cwd?: string, attachments: ComposerAttachment[] = [], chat?: NewTabChat) => {
    const generation = ++newTabStartGeneration.current;
    const isCurrent = () => newTabStartGeneration.current === generation;
    const inherited = newTab?.cwd;
    const start = (folder?: string) =>
      void (async () => {
        if (!isCurrent()) return;
        // A chat on another machine starts only with a send (cx-k21v): with no text, the folder
        // waits for the first send.
        if (folder && !text && directClient.current?.startsOnSend) {
          heldBack.current = holdNewTabAttachments(heldBack.current, attachments);
          // Keep the New Tab on screen until the folder choice has been handed to the chat
          // composer. Clearing it before this synchronous handoff mounted the empty chat hero for
          // a frame, then replaced it again when the first prompt landed.
          setNewTab(undefined);
          return setProjectDraft(folder);
        }
        const asks = text.length > 0 || attachments.length > 0;
        const message = { text, ...(attachments.length ? { attachments } : {}) };
        // A chat the person started here with a prompt makes its project the default.
        const remembers = !!folder && !!text && !directClient.current?.startsOnSend;
        if (chat) {
          // The page's harness and model go with it: the picks it made sit on the deferred chat
          // that harness opened, and a bare `chat.new {cwd}` would start the default one instead.
          // As on the New Tab screen (screenActions.ts), the prompt goes in the same turn as the
          // switch, which queues it: sent after `chat.new` settled, a folder trust refusal left the
          // switch with nothing queued.
          const started = startNewTabTransition(
            () => callNative("chat.new", { ...chat, ...(folder ? { cwd: folder } : {}) }),
            () => setNewTab(undefined),
            isCurrent,
          ).then((session) => {
            if (isCurrent() && session && remembers) rememberStartedProject(folder, callNative);
            return session;
          });
          if (!asks) {
            // A blank Agent Return has no prompt to make a deferred switch visible. Preserve the
            // old immediate transition and observe the unresolved start only to avoid an unhandled
            // rejection; a later prompt can still reveal the switch through the composer.
            setNewTab(undefined);
            void started.catch(() => undefined);
            return;
          }
          // Queue the prompt in the same turn as the deferred switch. Waiting for chat.new here
          // deadlocks HarnessSwitch: it waits for a visible prompt before resolving its start.
          await callNative("chat.send", message);
          await started.catch(() => undefined);
          return;
        }
        // No agent named (acpmux listed none yet): a bare start in the folder, then the prompt into
        // the chat it started. Not in the same turn: with no switch to queue on, a send while the
        // start is refused would start another chat outside the folder. A refused start gives the
        // prompt to the chat composer, in that folder, as a fresh chat's own first send keeps it:
        // a trust refusal asks the folder's question and Trust sends it, once (cx-nn3e P0b).
        let started: unknown;
        try {
          started = await startNewTabTransition(
            () => (folder ? callNative("chat.new", { cwd: folder }) : Promise.resolve(undefined)),
            () => setNewTab(undefined),
            isCurrent,
          );
        } catch (error) {
          if (!isCurrent()) return;
          if (!asks) return;
          if (folder) setProjectDraft(folder);
          // Back in the chat composer ahead of anything typed there while the start was out, never
          // in its place (Composer `restore`); a composer not mounted yet gets it when it mounts.
          if (composerHandle.current) composerHandle.current.restore(text, attachments);
          else heldBack.current = [...(heldBack.current ?? []), { text, attachments }];
          if (isTrustRefusal(error)) {
            holdPrompt.current?.();
            trustRefused.current?.(error, () => {
              if (isCurrent()) composerHandle.current?.send();
            });
          }
          return;
        }
        if (!isCurrent()) return;
        if (started && remembers) rememberStartedProject(folder, callNative);
        if (asks) await callNative("chat.send", message);
      })().catch(() => undefined);
    // The page's own folder is inherited (`~` in a fresh workspace): the chat starts in its start
    // folder. Another project the user picked there goes through the host first.
    // Use Private Folder (or Keep) there gives the typed text back to the composer.
    if (cwd && cwd !== inherited)
      void requestFolder(cwd, start, text ? () => isCurrent() && setDraft(text) : undefined);
    else start(startFolder);
  };
  const loadNewTabProjects = useCallback(
    () =>
      callNative<{ projects?: string[]; repos?: unknown; machine?: boolean }>("project.list").then((result) => {
        // Each folder's repository (projectRepos.ts): the pickers fold worktrees under it.
        const repos = parseProjectRepos(result?.repos);
        const projects = (result?.projects ?? []).map((cwd): Project => {
          const repo = repos[cwd];
          return { cwd, label: projectName(cwd) ?? cwd, ...(repo ? { repo } : {}) };
        });
        // `machine`: the host listed the chat's other machine's folders, not this Mac's.
        return { projects, machine: result?.machine === true };
      }),
    [],
  );
  /// The daemon's list, with the New Tab page it was asked for (`newTabGeneration`): the list is
  /// that page's machine's, so a later page (another machine's, or this Mac's after one) never
  /// reads it, from its first render, while its own is pending or if it fails (Codex review of
  /// #24274).
  /// `projects` undefined: not answered yet.
  const [loadedProjects, setDirectProjects] = useState<{ page: number; projects?: Project[]; machine?: boolean }>({
    page: 0,
  });
  const projectsAnswered = loadedProjects.page === newTabGeneration && loadedProjects.projects !== undefined;
  const directProjects = projectsAnswered ? loadedProjects.projects! : NO_PROJECTS;
  // A chat on another machine: the folders its host listed for that machine (its folder menu).
  const machineFolders = projectsAnswered && loadedProjects.machine ? directProjects : undefined;
  const onNewTab = Boolean(newTab);
  useEffect(() => {
    // Start Agent's folder picker lists them too (cx-hkat), and so does the New Tab page: the
    // daemon's project list, where the user's renames and removals win (cx-m0p7).
    if (!freshChat && !onNewTab) return;
    let active = true;
    void loadNewTabProjects()
      .then(({ projects, machine }) => {
        if (active) setDirectProjects({ page: newTabGeneration, projects, machine });
      })
      .catch(() => undefined);
    return () => {
      active = false;
    };
    // A prewarmed spare page asks again when Cmd-T adopts it: before that its model is not wired.
  }, [freshChat, onNewTab, newTabGeneration, loadNewTabProjects]);
  // A started local chat moves to another folder in place; a Cloud chat's folder is a label.
  const canMove = Boolean(snapshot.sessionId) && composerSnapshot.summary?.hostKind !== "cloud";
  // The chats the page's context carried, while its own list has not arrived (newtab/warmSnapshot.ts):
  // the first frame lists what a page of this Mac listed last, and the live list changes rows in place.
  const warmSessions = useWarmNewTabSessions();
  const carriedSessions = shownNewTabSessions(composerSnapshot, warmSessions);
  // Over that, the New Tab page lists the chats every page shares (newtab/chatStore.ts): the newest
  // list any page received, drawn on its first frame and updated in place when another page hears a
  // change. A page on another machine's daemon and a page whose daemon is down list this page's own
  // (`sharesChatList`).
  const newTabSessions = useSharedSessions(
    carriedSessions ?? composerSnapshot.sessions,
    sharesChatList(newTab, composerSnapshot),
  );
  // What this pane's new chat's Enter would start (newChatPrewarm.ts): the held pick or switch's
  // harness (none: acpmux's default) in the picked project, the switch's folder or the pane's own.
  // The pane's own folder (`newChatCwd`) is read at the keystroke: the client is a ref.
  const freshPick = useRef<{ harness?: string; cwd?: string }>({});
  freshPick.current = {
    harness: heldPick(snapshot).harness ?? switchView.intent?.harness,
    cwd: projectDraft ?? switchView.intent?.cwd,
  };
  // Stable, so the composer's unsent-draft throttle is not rebuilt on every render.
  const onNewChatDraft = useCallback(
    (text: string) => {
      newChatDraft.typed = text;
      const sent = postNewChatDraft();
      if (cloudComposeEligible.current) {
        cloudReservation.typed(text, cloudComposeEligible.current.replaces);
        return sent;
      }
      const { harness } = freshPick.current;
      const cwd = freshPick.current.cwd ?? directClient.current?.newChatCwd();
      const target: PrewarmTarget | undefined = cwd ? { ...(harness ? { harness } : {}), cwd } : undefined;
      newChatPrewarm.typed(text, target);
      return sent;
    },
    [newChatPrewarm, cloudReservation],
  );
  const onNewTabPromptTyped = useCallback(
    (text: string, target?: { harness?: string; cwd?: string }) => {
      newTabFieldEdited(text);
      const machineID = cloudTypingMachineID(
        cloudDraftMachineID.current,
        cloudIdentityBound.current ? cloudChatIdentity?.id : undefined,
      );
      if (machineID && handshaken && !reconnectingRef.current) cloudTypingPrewarm.typed(text, { machineID });
      if (cloudComposeEligible.current) {
        cloudReservation.typed(text, cloudComposeEligible.current.replaces);
        return;
      }
      newChatPrewarm.typed(
        text,
        target?.cwd ? { ...(target.harness ? { harness: target.harness } : {}), cwd: target.cwd } : undefined,
      );
    },
    [cloudChatIdentity, cloudTypingPrewarm, handshaken, newChatPrewarm, newTabFieldEdited, cloudReservation],
  );
  const onCloudTyping = useCallback(
    (text: string, sessionId?: string) => {
      // Local chats still share this callback for multiplayer typing; only a durable session has a
      // typing presence event. A Cloud identity may temporarily be missing its session during
      // recovery, but its authenticated machine is still safe to wake.
      if (sessionId) postTyping(text, sessionId);
      if (!handshaken || reconnectingRef.current) return;
      // An explicit picker choice belongs to this draft and wins over any identity carried by a
      // previous Cloud chat until the selected machine's own handshake arrives.
      const machineID = cloudTypingMachineID(
        cloudDraftMachineID.current,
        cloudIdentityBound.current ? cloudChatIdentity?.id : undefined,
      );
      if (!machineID) return;
      cloudTypingPrewarm.typed(text, { machineID, ...(sessionId ? { sessionID: sessionId } : {}) });
    },
    [cloudChatIdentity, cloudTypingPrewarm, handshaken],
  );
  const cloudHintUsed = cloudHint.used;
  const onCloudMachinePicked = useCallback(
    (machine: CloudMachine | undefined) => {
      cloudDraftMachineID.current = machine?.id ?? null;
      // A Cloud machine picked is a pick of Cloud: the hint is done.
      if (machine) cloudHintUsed();
    },
    [cloudHintUsed],
  );
  const newTabSnapshot = useMemo(
    () =>
      newTabSessions === composerSnapshot.sessions
        ? composerSnapshot
        : { ...composerSnapshot, sessions: newTabSessions },
    [composerSnapshot, newTabSessions],
  );
  // The daemon has not listed the chats to this page yet and none are known (newtab/recentProject.ts).
  const newTabChatsPending =
    newTabSessions.length === 0 &&
    !composerSnapshot.listedSessions &&
    composerSnapshot.sessions.length === 0 &&
    composerSnapshot.connection !== "disconnected" &&
    composerSnapshot.connection !== "debug";
  // The folders the host lists as projects (no chat folders): the most recent project is one of them.
  // The daemon's list (removals win) once it has answered, else the page's own. This Mac's store
  // answering with no project (every one removed or missing) is `null`: no chat or started folder
  // counts (Codex review of #24274). Another machine's empty answer may be no answer at all
  // (AgentPaneModel `onListRemoteProjects`), so there it stays "not loaded".
  const newTabKnownProjects = useMemo((): readonly string[] | null => {
    if (directProjects.length > 0) return directProjects.map((project) => project.cwd);
    const own = newTab?.projects ?? [];
    return projectsAnswered && own.length === 0 && newTab?.home ? null : own;
  }, [directProjects, projectsAnswered, newTab?.projects, newTab?.home]);
  // The folder lists read only where each chat works and when it was active (sessionList.ts
  // `folderFields`): another chat's status, unread, title or cost changing leaves them as they are.
  // The New Tab list reads the folders apart from their order: a chat on this Mac working moves its
  // folder up (`FolderRecency`) without naming every folder again.
  const folderLists = useRef<{ newTab: SessionsBy; composer: SessionsBy; recency: FolderRecency } | null>(null);
  folderLists.current ??= {
    newTab: new SessionsBy(placeFields),
    composer: new SessionsBy(folderFields),
    recency: new FolderRecency(),
  };
  const newTabFolderSessions = folderLists.current.newTab.of(newTabSnapshot.sessions);
  const composerFolderSessions = folderLists.current.composer.of(composerSnapshot.sessions);
  const newTabRecentFolders = folderLists.current.recency.of(newTabSnapshot.sessions);
  const newTabFolders = useMemo(() => {
    const byPath = new Map<string, Project>();
    // A folder the host listed keeps its repository (projectRepos.ts) when a chat names it again.
    const listed = (cwd: string): Project => {
      const repo = byPath.get(cwd)?.repo;
      return { cwd, label: projectLabel(cwd), ...(repo ? { repo } : {}) };
    };
    for (const project of directProjects) byPath.set(project.cwd, project);
    for (const path of newTab?.projects ?? []) byPath.set(path, listed(path));
    // Each folder once: a large profile lists thousands of chats in a few hundred folders.
    const named = new Set<string>();
    for (const session of newTabFolderSessions) {
      if (typeof session.cwd !== "string" || !session.cwd || named.has(session.cwd)) continue;
      if (session.host && session.hostKind !== "local") continue;
      named.add(session.cwd);
      byPath.set(session.cwd, listed(session.cwd));
    }
    if (newTab?.cwd) byPath.set(newTab.cwd, listed(newTab.cwd));
    return [...byPath.values()];
  }, [newTabFolderSessions, newTab?.cwd, newTab?.projects, directProjects]);
  // The pickers list repositories in the order of their newest folder: the folder of the newest chat first.
  const newTabProjectList = useMemo(
    () => byRecentUse(newTabFolders, newTabRecentFolders),
    [newTabFolders, newTabRecentFolders],
  );
  // The same list while it holds the same folders in the same order (session-info/sameValue.ts): it is
  // built again from the chat list, which changes on every event of any chat that runs, and the
  // composer takes it as a prop (`projectChoices`), so a new copy of it drew the composer again four
  // times a second with another chat working (test/agent-pane-scroll-tick-composer-hat-still.test.ts).
  const newTabProjects = useSameValue(newTabProjectList);
  // The new chat's hero picker (cx-9g0w): this Mac's projects, then other machines' folders from
  // their chats (each with its machine's name), Add project and Do not work in a project.
  const heroPicker = useMemo<EmptyStateProjects | undefined>(() => {
    if (!freshChat || quick) return undefined;
    const remote = new Map<string, Project>();
    for (const session of composerFolderSessions) {
      const peer = session.peer ?? (session.hostKind === "cloud" ? session.host : undefined);
      if (!peer || typeof session.cwd !== "string" || !session.cwd || isAgentHome(session.cwd)) continue;
      const project = {
        cwd: session.cwd,
        label: projectLabel(session.cwd),
        peer,
        host: session.host ?? peer,
      };
      remote.set(`${peer}\u0000${session.cwd}`, project);
    }
    const summary = composerSnapshot.summary;
    const cwd = summary?.cwd;
    // The machine as the rows key it (ComposerContext.computerId): a peer, else a Cloud host.
    const peer = summary?.peer || (summary?.hostKind === "cloud" ? summary.host : undefined);
    return {
      // Every folder: the chooser lists one row per repository and finds the rest by search.
      projects: [...newTabProjects.filter((project) => !isAgentHome(project.cwd)), ...remote.values()],
      current: cwd && !isAgentHome(cwd) ? cwd.replace(/(.)\/+$/, "$1") : undefined,
      currentPeer: peer,
      // In no project only when it is: its folder is agent-home, or the host starts it there. A chat
      // with no folder yet may still start in the workspace's root, so nothing is checked then.
      noProject: cwd ? isAgentHome(cwd) : chooseFolder,
      onPick: chooseProject,
      onBrowse: (request?: BrowseRequest) =>
        callNative<{ cwd?: string }>("project.browse").then((result) => {
          if (result?.cwd && !request?.deferPick) void chooseProject(result.cwd);
          return result?.cwd;
        }),
      // The chat starts in its agent-home folder, never the workspace's (AcpmuxPathPolicy).
      // A refused start keeps the folder picked before.
      onNoProject: () => {
        pickedProject.current = undefined;
        // A chat on another machine starts only with a send (cx-k21v); it has no agent-home folder here.
        if (directClient.current?.startsOnSend) return setProjectDraft(undefined);
        void callNative("chat.new", { noProject: true })
          .then(() => setProjectDraft(undefined))
          .catch(() => undefined);
      },
    };
  }, [freshChat, quick, composerFolderSessions, composerSnapshot.summary, newTabProjects, chooseProject, chooseFolder]);
  // The hero's start as it shows (its project, Do not work in a project), first frame to final
  // (perf.ts noteStartState). Only a new chat with no session yet, not under a New Tab page.
  const heroShown =
    heroPicker && freshView && !snapshot.sessionId && !showNewTab
      ? `hero:${projectName(composerSnapshot.summary?.cwd) ?? ""}:${heroPicker.noProject ? 1 : 0}`
      : undefined;
  useEffect(() => {
    if (heroShown !== undefined) acpmuxPerf.noteStartState(heroShown);
  });
  // The repo tour (repoTour/): a new chat in a folder no chat on this Mac has used offers it under
  // the hero's question; Take the tour sends the tour prompt as this chat's first message, and the
  // × closes the offer for that folder.
  const [tourDismissed, setTourDismissed] = useState<ReadonlySet<string>>(() => new Set());
  const tourCwd = composerSnapshot.summary?.cwd;
  const tourOffered = useMemo(
    () =>
      Boolean(heroPicker) &&
      tourHere &&
      !cloudPicked &&
      sandbox.mode !== "sandboxed" &&
      offersTour({
        cwd: tourCwd,
        local: !composerSnapshot.summary?.peer && composerSnapshot.summary?.hostKind !== "cloud",
        listed: composerSnapshot.listedSessions === true,
        sessions: newTabSessions,
        sessionId: snapshot.sessionId,
        dismissed: (folder) => tourDismissed.has(folder) || isTourDismissed(folder),
      }),
    [
      heroPicker,
      tourHere,
      cloudPicked,
      sandbox.mode,
      tourCwd,
      composerSnapshot.summary?.peer,
      composerSnapshot.summary?.hostKind,
      composerSnapshot.listedSessions,
      newTabSessions,
      snapshot.sessionId,
      tourDismissed,
    ],
  );
  const tourOffer = useMemo<TourOfferActions | undefined>(
    () =>
      tourOffered && tourCwd
        ? {
            onTake: () => void callNative("chat.send", { text: TOUR_PROMPT }).catch(() => undefined),
            onDismiss: () => {
              dismissTour(tourCwd);
              setTourDismissed((folders) => new Set(folders).add(tourCwd.replace(/(.)\/+$/, "$1")));
            },
          }
        : undefined,
    [tourOffered, tourCwd],
  );
  // A tour task's Start (repoTour/TourCard.tsx): a new worktree of the chat's folder, then a chat
  // there given the task, tagged and opened as this chat's side chat before its prompt goes. The
  // task's prompt is the agent's words, so it never runs in the person's own checkout: no worktree
  // (not a repository, the host refused) means no task, and the card says why.
  const startTourTask = useCallback(async (task: TourTask) => {
    const client = directClient.current;
    const summary = snapshotRef.current?.summary;
    const origin = snapshotRef.current?.origin;
    if (!client || !summary?.cwd || origin === "remote" || origin === "peer")
      throw new Error(translate("error.notOpen"));
    const { root } = await newWorktree(callNative, summary.cwd, () => undefined);
    return client.startTask(root, task.prompt, {
      harness: summary.harness,
      side: summary.sessionId,
      opened: (sessionId) => postNative("chat.sideChat", { sessionId }),
    });
  }, []);
  // Stable: memoized transcript rows compare it.
  const toggleActivity = useCallback((id: string, covers?: readonly string[]) => {
    const view = chatViewRef.current;
    // A Worked for the turn's end left open over what the reader reads (`heldWorked`) is closed by
    // their click: it was never their open fold.
    if (heldWorked.current.keys.has(id)) {
      const keys = new Set(heldWorked.current.keys);
      keys.delete(id);
      heldWorked.current = { ...heldWorked.current, keys };
      releaseCalls();
      return;
    }
    // A turn's fold opens with every line in it closed, whatever the reader opened there before
    // (Lucas, 2026-11-11): its toggle forgets them. Closed, nothing in it draws, so open or close alike.
    if (isWorkedFold(id)) {
      const edits = new Set<string>();
      forgetInsideTurn(shownSessionRef.current, turnInsideIds(turnRowsRef.current, id, edits), edits);
    }
    // In Thinking and Verbose a turn's "Worked for" is open unless toggled there (viewFolds.ts):
    // the reader's open or close overrides the view, and Normal's own folds stay as they were.
    if (view !== "normal" && isWorkedFold(id)) {
      setViewToggles((current) =>
        new Map(current).set(view, toggleViewTurnFold(turnRowsRef.current, current.get(view) ?? NO_FOLD_TOGGLES, id)),
      );
      // Its runs of messages close with it in this view too.
      setExpanded((current) => {
        const next = new Set(current);
        closeTurnRuns(turnRowsRef.current, next, id);
        return next.size === current.size ? current : next;
      });
    } else setExpanded((current) => toggleTurnFold(turnRowsRef.current, current, id, covers));
  }, []);
  const loadReplay = useCallback(
    // l10n-allow: never shown; the replay says replay.failed.
    () => directClient.current?.recordedEvents(replaying ?? "") ?? Promise.reject(new Error("no connection")),
    [replaying],
  );
  const toolCards = useToolCards();
  const computerUsePreview = useComputerUsePreview();
  // The live preview card shows beside the column, which keeps its room, in a pane wide enough. With
  // Session Info open it sits under Session Info's card instead (session-info/underSessionInfo.ts). Floating,
  // the column keeps its room, so opening or closing Session Info never reflows the chat (Leo,
  // 2026-10-31: "why is the session info thing still pushing my layout when it doesnt need to???");
  // only Settings Push always, whose column already keeps the chat clear of both, gives it back.
  const previewRoom = useComputerUsePreviewRoom();
  const previewShown = computerUsePreview !== null && previewRoom && !quick && !inspectorOpen;
  const sessionInfoPushes = useChatDisplay().sessionInfo === "push";
  const previewBeside = previewShown && !(sessionInfo.shown && sessionInfoPushes);
  // The VS Code Minimap's room at the column's right (chatMinimap/paint.ts minimapReserve), on the same
  // terms as the preview's: Session Info's push pins the column itself. The transcript keeps it only in
  // a chat wide enough.
  const chatMinimapOn = useChatMinimap();
  const chatMinimapBeside = chatMinimapOn && !quick && !inspectorOpen && !(sessionInfo.shown && sessionInfoPushes);
  const columnEndReserve = previewBeside ? COMPUTER_USE_PREVIEW_RESERVE : 0;
  // What the chat waits on the person for: the running turn's line says it, never "Thinking".
  const waiting = chatWaitsOn({
    trust: trustAsk.ask,
    isWorking: snapshot.isWorking,
    individualPermission,
    permissionGroups: snapshot.permissionGroups?.supported ? snapshot.permissionGroups.groups : undefined,
    secret: Boolean(snapshot.secret),
    cards: toolCards,
  });
  // A suggested task's Options list this chat's machine and its agent's choices (offer/offerChoice.ts).
  const offerDefaultsValue = useMemo(
    () => offerDefaults(snapshot.summary, snapshot.catalog),
    [snapshot.summary, snapshot.catalog],
  );
  const transcriptContent = (
    <TranscriptChief.Provider value={chatChief}>
      {/* Quick Chat's panel has no room beside it: its fences have no Open preview. */}
      <ArtifactContext.Provider value={quick ? undefined : openArtifact}>
        <RenderPages.Provider value={pages}>
          <ImageViewerContext.Provider value={openImage}>
            <ShellActionsContext.Provider value={shellActions}>
              <TurnActionsContext.Provider value={turnActions}>
                <SkillWordsContext.Provider value={skillWords}>
                  <NewestSteerContext.Provider value={snapshot.newestOwnSteer}>
                    <RunInBackgroundContext.Provider value={backgroundHint}>
                      <TurnCountsContext.Provider value={turnCountsFor}>
                        <SessionEditsAndShots edits={editRows} shots={turnShots}>
                          <SessionCwdContext.Provider value={snapshot.summary?.cwd}>
                            <OfferDefaultsContext.Provider value={offerDefaultsValue}>
                              <SubagentNavContext.Provider value={navigateSubagent}>
                                <SubagentViewsContext.Provider value={readSubagentView}>
                                  <SubagentReplyContext.Provider value={readSubagentReply}>
                                    <SubagentPaneContext.Provider value={showSubagent}>
                                      <WorkingCountsContext.Provider value={workingCounts}>
                                        <PreviewChipsContext.Provider value={previewChips}>
                                          <RunElsewhereContext.Provider value={runElsewhere}>
                                            <WaitingOnContext.Provider value={waiting}>
                                              <SubagentStopContext.Provider value={stopSubagent}>
                                                <SubagentClockContext.Provider value={snapshot.clockOffsetMs ?? 0}>
                                                  <SubagentHarnessContext.Provider
                                                    value={knownMark(
                                                      snapshot.summary?.harness,
                                                      snapshot.summary?.family,
                                                    )}
                                                  >
                                                    <SessionHoverContext.Provider value={sessionHover}>
                                                      <SubsessionNamesProvider
                                                        subsessions={subsessions}
                                                        started={subsessionNames}
                                                      >
                                                        <StartedMentionsContext.Provider value={startedMentions}>
                                                          <FailedSendsContext.Provider value={failedSends}>
                                                            <ChatFindScope
                                                              rows={
                                                                chatPresentation === "messages"
                                                                  ? transcriptRows
                                                                  : (childRows ?? findRows)
                                                              }
                                                              shown={childRows ? undefined : transcriptRows}
                                                              openFold={openFold}
                                                              showHeld={showHeldRuns}
                                                              findRef={findRef}
                                                            >
                                                              {(find) => (
                                                                <VirtualTranscript
                                                                  key={chatPresentation}
                                                                  topInset={soloUnder ? tabRow.height : 0}
                                                                  rows={transcriptRows}
                                                                  streams={!childRows}
                                                                  earlier={
                                                                    !childRows ? snapshot.earlierPrompts : undefined
                                                                  }
                                                                  promptCount={
                                                                    !childRows ? snapshot.promptCount : undefined
                                                                  }
                                                                  loadThrough={
                                                                    !childRows
                                                                      ? (seq) =>
                                                                          directClient.current?.loadThrough(seq) ??
                                                                          Promise.resolve(false)
                                                                      : undefined
                                                                  }
                                                                  loadPromptIndex={
                                                                    !childRows
                                                                      ? () =>
                                                                          directClient.current?.loadPromptIndex() ??
                                                                          Promise.resolve(false)
                                                                      : undefined
                                                                  }
                                                                  sourceRows={childRows ? undefined : sourceRows}
                                                                  endReserve={columnEndReserve}
                                                                  minimapBeside={chatMinimapBeside}
                                                                  working={snapshot.isWorking}
                                                                  // Its stage positions Jump to latest; the Quick Composer's panel has no room for it.
                                                                  jumpButton={!quick}
                                                                  onJumpShownChange={
                                                                    quick ? undefined : setJumpLatestShown
                                                                  }
                                                                  needsYou={needsYou.pill}
                                                                  focusComposer={() => composerHandle.current?.focus()}
                                                                  // Quick Chat's panel stacks its composer below the transcript.
                                                                  dock={quick ? undefined : dock}
                                                                  queueWithdrawn={snapshot.queueWithdrawn}
                                                                  queueIds={quick ? undefined : queueIds}
                                                                  queuedTail={queuedRows}
                                                                  find={quick ? undefined : find}
                                                                  sessionId={
                                                                    childRows
                                                                      ? `${shownSessionId}:subagent:${subagentView}`
                                                                      : shownSessionId
                                                                  }
                                                                  canLoadOlder={
                                                                    workflowTranscript.rows
                                                                      ? workflowTranscript.canLoadOlder
                                                                      : !childRows && snapshot.canLoadOlder
                                                                  }
                                                                  historyFrom={
                                                                    workflowTranscript.rows
                                                                      ? workflowTranscript.historyFrom
                                                                      : childRows
                                                                        ? undefined
                                                                        : snapshot.historyFrom
                                                                  }
                                                                  onLoadOlder={
                                                                    workflowTranscript.rows
                                                                      ? workflowTranscript.loadOlder
                                                                      : !childRows
                                                                        ? (fill: boolean, rising: boolean) =>
                                                                            directClient.current?.loadOlder(
                                                                              undefined,
                                                                              fill,
                                                                              rising,
                                                                              true,
                                                                            ) ?? Promise.resolve()
                                                                        : undefined
                                                                  }
                                                                  canLoadNewer={
                                                                    !workflowTranscript.rows &&
                                                                    !childRows &&
                                                                    snapshot.canLoadNewer === true
                                                                  }
                                                                  historyThrough={
                                                                    childRows ? undefined : snapshot.historyThrough
                                                                  }
                                                                  later={childRows ? undefined : snapshot.laterPrompts}
                                                                  onLoadNewer={
                                                                    !childRows
                                                                      ? () =>
                                                                          directClient.current?.loadNewer() ??
                                                                          Promise.resolve()
                                                                      : undefined
                                                                  }
                                                                  onReturnToLatest={
                                                                    !childRows
                                                                      ? () =>
                                                                          directClient.current?.returnToLatest() ??
                                                                          Promise.resolve()
                                                                      : undefined
                                                                  }
                                                                  openAt={
                                                                    !childRows &&
                                                                    shownSessionId &&
                                                                    scrollAnchor?.sessionId === shownSessionId
                                                                      ? scrollAnchor
                                                                      : undefined
                                                                  }
                                                                  anchorNow={
                                                                    quick || childRows ? undefined : transcriptAnchor
                                                                  }
                                                                  inViewNow={
                                                                    quick || childRows ? undefined : transcriptInView
                                                                  }
                                                                  heldWorkedClosing={
                                                                    quick || childRows ? undefined : heldWorkedClosing
                                                                  }
                                                                  // A prompt goes to the chat, not to the subagent shown in its place.
                                                                  sends={childRows ? undefined : sends}
                                                                  onFollowingChange={
                                                                    childRows ? undefined : onTranscriptFollowingChange
                                                                  }
                                                                  onKeepFrom={
                                                                    childRows ? undefined : onTranscriptKeepFrom
                                                                  }
                                                                  onAnchor={
                                                                    quick || childRows || !shownSessionId
                                                                      ? undefined
                                                                      : (anchor) =>
                                                                          postScrollAnchor(shownSessionId, anchor)
                                                                  }
                                                                  expanded={folds}
                                                                  showMinimap={minimapVisible}
                                                                  reveal={
                                                                    (revealRow?.child === true) === Boolean(childRows)
                                                                      ? revealRow
                                                                      : undefined
                                                                  }
                                                                  sinceKey={childRows ? undefined : sinceKey}
                                                                  promptAuthor={directClient.current?.presence.selfId}
                                                                  onJumpToSince={jumpToSince}
                                                                  clockOffset={snapshot.clockOffsetMs ?? 0}
                                                                  coldOpen={
                                                                    !childRows && opened.cold ? opened.open : undefined
                                                                  }
                                                                  onColdOpenShown={coldOpenShown}
                                                                  // Still reading the chat: what lands after a blank or partly blank
                                                                  // first paint fades in rather than popping (shared/loadFade.ts).
                                                                  loading={
                                                                    !childRows &&
                                                                    snapshot.sessionId !== undefined &&
                                                                    snapshot.chatRead !== true
                                                                  }
                                                                  afterLatest={
                                                                    childRows || snapshot.canLoadNewer
                                                                      ? undefined
                                                                      : afterLatestFooter(
                                                                          showOpenAppCard ? (
                                                                            <OpenAppCard ports={cloudPreviewPortList} />
                                                                          ) : null,
                                                                          trayPlacement === "after-latest-message"
                                                                            ? trayNode
                                                                            : null,
                                                                        )
                                                                  }
                                                                  registry={
                                                                    readOnlySubagent ? noDismissRegistry : registry
                                                                  }
                                                                  githubRepository={githubRepository}
                                                                  fallbackRepository={
                                                                    pullRequestRef(headerPullRequest?.url ?? "")?.repo
                                                                  }
                                                                  // The Quick Composer has no room for the changes view; its file rows stay plain.
                                                                  onOpenDiff={quick ? undefined : openDiff}
                                                                  onToggleActivity={toggleActivity}
                                                                />
                                                              )}
                                                            </ChatFindScope>
                                                            <SelectionReplyChip />
                                                          </FailedSendsContext.Provider>
                                                        </StartedMentionsContext.Provider>
                                                      </SubsessionNamesProvider>
                                                    </SessionHoverContext.Provider>
                                                  </SubagentHarnessContext.Provider>
                                                </SubagentClockContext.Provider>
                                              </SubagentStopContext.Provider>
                                            </WaitingOnContext.Provider>
                                          </RunElsewhereContext.Provider>
                                        </PreviewChipsContext.Provider>
                                      </WorkingCountsContext.Provider>
                                    </SubagentPaneContext.Provider>
                                  </SubagentReplyContext.Provider>
                                </SubagentViewsContext.Provider>
                              </SubagentNavContext.Provider>
                            </OfferDefaultsContext.Provider>
                          </SessionCwdContext.Provider>
                        </SessionEditsAndShots>
                      </TurnCountsContext.Provider>
                    </RunInBackgroundContext.Provider>
                  </NewestSteerContext.Provider>
                </SkillWordsContext.Provider>
              </TurnActionsContext.Provider>
            </ShellActionsContext.Provider>
          </ImageViewerContext.Provider>
        </RenderPages.Provider>
      </ArtifactContext.Provider>
    </TranscriptChief.Provider>
  );
  const transcript = (
    <PresentationContext.Provider value={chatPresentation}>
      <ThinkingVerbsContext.Provider value={thinkingVerbs}>
        <SteerChatContext.Provider value={snapshot.sessionId ?? ""}>{transcriptContent}</SteerChatContext.Provider>
      </ThinkingVerbsContext.Provider>
    </PresentationContext.Provider>
  );
  // Folder trust's question heads the bottom stack, and the chat's other asks stay under it
  // (Leo 2026-10-21, P0: a pending trust prompt never blocks answering a question). The question
  // holds new prompts; a permission, question or secret card asks for a turn already running,
  // acpmux takes its answer whatever the folder's trust, and hiding it left that turn waiting on an
  // answer nobody could give. A trusted receipt can sit above the next ask.
  // The new chat's prompts its folder's trust held go back into the composer first, so the start
  // without a folder carries them in its draft (folderContinuation.ts `copyText`) instead of leaving
  // them held for a folder the chat no longer has.
  const continueWithoutFolder = useCallback(() => {
    const taken = trustHeldNow.current.takeShown();
    if (taken.length) void giveBackTrustHeld.current(taken);
    return callNative<void>("chat.new", folderContinuationRequest);
  }, []);
  // The same recovery in the declined folder, read-only (folderContinuation.ts).
  const continueReadOnly = useCallback(() => {
    const taken = trustHeldNow.current.takeShown();
    if (taken.length) void giveBackTrustHeld.current(taken);
    return callNative<void>("chat.new", readOnlyContinuationRequest);
  }, []);
  const secret = snapshot.secret;
  const hasPermissionGroups = Boolean(
    snapshot.permissionGroups?.supported &&
    (snapshot.permissionGroups.groups.length > 0 || snapshot.permissionGroups.error),
  );
  const trustOpen = Boolean(trustAsk.ask && (trustAsk.ask.state !== "decided" || trustAsk.ask.level === "untrusted"));
  // The trust question folds out on the fold's clock when it is answered (conversation/fold.ts), so
  // the stack's top and the transcript's rows over it travel together, instead of the stack dropping
  // its height in one frame (gallery `agent-pane.bottom-stack` trust-fold-*). While it folds it draws
  // the question as it last stood, inert, and holds no keys.
  const trustLast = useRef(trustAsk.ask);
  useLayoutEffect(() => {
    if (trustOpen) trustLast.current = trustAsk.ask;
  });
  const trustShown = trustOpen ? trustAsk.ask : trustLast.current;
  const trustFold = useFold(trustOpen, () => !trustOpen, false);
  const liveBottomAsk = Boolean(
    trustOpen || hasPermissionGroups || individualPermission || childAsk || secret || toolCards.length > 0,
  );
  // Pinned questions join the stack but never take the composer's keys (waitingAskStore.ts).
  const bottomStack = bottomAsks(liveBottomAsk, pinnedAsks.length, trustFold.present);
  const hasBottomAsk = bottomStack.holdsKeys;
  // A folder confirmation can be pending while the New Tab stays mounted. Keep the same ask in
  // that surface too: the regular composer is deliberately hidden behind the New Tab, so leaving
  // the ask there would strand the prompt with no Use or Cancel action.
  const confirmPendingFolder = useCallback(() => {
    if (!pendingFolder || folderConfirming !== false || folderConfirmInFlight.current) return;
    const pending = pendingFolder;
    const generation = ++folderConfirmGeneration.current;
    // The answer lands only in the chat it was asked in: a chat switched to while it saves gets nothing.
    const asked = { sessionId: pending.sessionId, ...visitOf(trustVisit()) };
    const use = (cwd: string) => {
      if (generation === folderConfirmGeneration.current && inThisVisit(asked, shownSession.current, trustVisit()))
        pending.use(cwd);
      // Stale (another chat, a newer pick): nothing is used, and its sender stops waiting.
      else pending.cancel?.();
    };
    folderConfirmInFlight.current = true;
    setFolderConfirming(asked);
    setFolderAsk(undefined);
    void confirmFolder(callNative, pending.ask, use).then(
      () => {
        if (generation !== folderConfirmGeneration.current) return;
        folderConfirmInFlight.current = false;
        setFolderConfirming(false);
      },
      (error: unknown) => {
        if (generation !== folderConfirmGeneration.current) return;
        folderConfirmInFlight.current = false;
        setFolderConfirming(false);
        // Use stays on the question as its Retry; the host's words go to the log.
        console.warn("agent pane: using the folder failed", error);
        setFolderAsk(
          (current) => current ?? { ...pending, error: knownRefusalText(error) ?? translate("startFolder.failed") },
        );
      },
    );
  }, [folderConfirming, pendingFolder, trustVisit]);
  const cancelPendingFolder = useCallback(() => {
    folderConfirmGeneration.current += 1;
    folderConfirmInFlight.current = false;
    setFolderConfirming(false);
    cancelTrustResend();
    pendingFolder?.cancel?.();
    setFolderAsk(undefined);
  }, [pendingFolder, cancelTrustResend]);
  const folderAskView = pendingFolder ? (
    <NewTabFolderAsk
      ask={pendingFolder.ask}
      current={freshChat && !snapshot.sessionId ? projectDraft : snapshot.summary?.cwd}
      error={pendingFolder.error}
      confirming={confirmingHere}
      onUse={confirmPendingFolder}
      onCancel={cancelPendingFolder}
    />
  ) : null;
  const trustQuestion =
    trustAsk.ask && (trustAsk.ask.state !== "decided" || trustAsk.ask.level === "untrusted") ? (
      <TrustAsk
        ask={trustAsk.ask}
        agent={snapshot.summary?.harness ? agentName(snapshot.summary.harness) : t("trust.agent")}
        onTrust={trustAsk.trust}
        onTrustRepo={trustAsk.trustRepo}
        onDistrust={trustAsk.distrust}
        onUndo={trustAsk.undo}
        answers={answersTrust}
      />
    ) : undefined;
  const asks = bottomStack.shows ? (
    <div className="acpmux-permission acpmux-asks-stack" data-leaving={bottomStack.leaving || undefined}>
      {pinnedAsks.length > 0 && (
        <PendingAsks
          asks={pinnedAsks}
          onAnswer={turnActions.answer}
          registerKey={turnActions.nextStepKey}
          onDismiss={dismissPinnedAsk}
          asker={turnActions.asker}
        />
      )}
      {trustFold.present && trustShown && (
        <div ref={trustFold.ref} className="cv-fold acpmux-trust-fold" inert={!trustOpen || undefined}>
          <TrustAsk
            ask={trustShown}
            agent={snapshot.summary?.harness ? agentName(snapshot.summary.harness) : t("trust.agent")}
            onTrust={trustAsk.trust}
            onTrustRepo={trustAsk.trustRepo}
            onDistrust={trustAsk.distrust}
            onUndo={trustAsk.undo}
            onContinueWithoutFolder={
              healthLocal &&
              !remoteChat &&
              Boolean(snapshot.sessionId) &&
              !directClient.current?.startsOnSend &&
              trustAsk.ask?.state === "decided" &&
              trustAsk.ask.level === "untrusted" &&
              !isAgentHome(trustAsk.ask.cwd)
                ? continueWithoutFolder
                : undefined
            }
            onContinueReadOnly={
              healthLocal &&
              !remoteChat &&
              Boolean(snapshot.sessionId) &&
              !directClient.current?.startsOnSend &&
              readOnlyHarness(snapshot.summary?.family) &&
              trustAsk.ask?.state === "decided" &&
              trustAsk.ask.level === "untrusted" &&
              !isAgentHome(trustAsk.ask.cwd)
                ? continueReadOnly
                : undefined
            }
            answers={answersTrust}
          />
        </div>
      )}

      {hasPermissionGroups && snapshot.permissionGroups && (
        <PermissionPanel
          state={snapshot.permissionGroups}
          working={snapshot.isWorking}
          onRespond={(groupId, revision, decision) => {
            void callNative("chat.permission_group.respond", { groupId, revision, decision });
          }}
          onRetry={() => {
            void callNative("chat.permission_group.retry", {});
          }}
          onRevoke={() => {
            void callNative("chat.permission_chat.revoke", {});
          }}
          onRefresh={() => {
            void callNative("chat.permission_groups.refresh", {});
          }}
        />
      )}
      {(individualPermission || childAsk || secret || toolCards.length > 0) && (
        <>
          <ToolCards
            cards={toolCards}
            onAnswer={(id, action, value) =>
              void callNative(
                "chat.toolCard.respond",
                value === undefined ? { id, action } : { id, action, value },
              ).catch(() => undefined)
            }
          />
          {individualPermission && (
            <PermissionAsk
              key={individualPermission.permissionId}
              permission={individualPermission}
              shortcuts={cardTakesShortcuts(snapshot.permissionGroups)}
              waiting={snapshot.permissionsWaiting}
              harness={snapshot.summary?.harness}
              fullAccessMode={fullAccessModeName(snapshot.summary)}
              focusComposer={() => composerHandle.current?.focus()}
              shownChat={shownChat}
              alwaysAtSource={chatOnPeer(snapshot)}
              onDraft={(open) => setDraftAsk(open ? individualPermission : undefined)}
            />
          )}
          {childAsk && (
            <ChildAsk
              key={childAsk.ask.permission.permissionId}
              child={childAsk}
              waiting={belowAsks.length - 1}
              shortcuts={cardTakesShortcuts(snapshot.permissionGroups)}
              focusComposer={() => composerHandle.current?.focus()}
              // That chat's tab, or on the right of this one, as Needs you opens it.
              onOpen={(sessionId) => void callNative("chat.asks.open", { sessionId }).catch(() => undefined)}
            />
          )}
          {secret?.elevation && (
            <ElevationCard
              key={secret.secretId}
              ask={secret}
              agent={snapshot.summary?.harness ? agentName(snapshot.summary.harness) : t("trust.agent")}
              onAnswer={answerSecret(secret)}
            />
          )}
          {secret && !secret.elevation && (
            <SecretCard
              key={secret.secretId}
              ask={secret}
              agent={snapshot.summary?.harness ? agentName(snapshot.summary.harness) : t("trust.agent")}
              onAnswer={answerSecret(secret)}
            />
          )}
        </>
      )}
    </div>
  ) : null;
  // A fresh chat on another machine has no summary yet: its connection's origin, or a folder list
  // its host marked as that machine's, says where it runs.
  const startsElsewhere =
    remoteChat || snapshot.origin === "remote" || snapshot.origin === "peer" || Boolean(machineFolders);
  // The login command of an agent whose start was refused for its sign-in (SwitchNotice's Sign in).
  const switchLoginCommand =
    snapshot.switching?.phase === "failed" && snapshot.switching.code === SIGN_IN_REQUIRED
      ? chatLoginCommand(catalog, snapshot.switching.harness, harnessHealth)
      : undefined;
  // A failed start of a folder harness says what it waits for, in place of the switch's Retry
  // card: Enable (sent from the button's click, then the chat starts again), or the Trust answer.
  const block =
    blockedHarness &&
    (snapshot.switching?.phase === "failed"
      ? snapshot.switching.harness === blockedHarness.harness
      : !snapshot.sessionId)
      ? blockedHarness
      : undefined;
  const blockedName = block ? (catalog.find((entry) => entry.id === block.harness)?.name ?? block.harness) : undefined;
  const harnessCard = block && (
    <HostError
      message={t(block.reason === "needs-enable" ? "harness.needsEnable" : "harness.needsTrust", {
        agent: blockedName ?? block.harness,
        folder: block.folder,
      })}
      hint={null}
      {...(block.reason === "needs-enable"
        ? {
            action: t("harness.enable"),
            onRetry: () =>
              void callNative("chat.harness.enable", {
                folder: block.folder,
                id: block.harness,
              }).catch(() => undefined),
          }
        : {})}
    />
  );
  // A new chat in a workspace without a folder starts in its private folder (FolderChoice.tsx): the
  // folder chip's menu says so, and its Choose folder… is the workspace's folder sheet, which also
  // makes the pick the folder of the pane's next chats.
  const folderChoiceOffered =
    !pendingFolder &&
    !showNewTab &&
    showsFolderChoice({
      offered: chooseFolder,
      freshChat,
      quick,
      projectDraft,
      sessionId: snapshot.sessionId,
      missingFolder: Boolean(folderNeeded && !snapshot.sessionId),
    });
  const chooseWorkspaceFolder = (request?: BrowseRequest) => {
    setFolderError(undefined);
    return callNative<{ cwd?: string }>("workspace.chooseFolder")
      .then((result) => {
        if (!result?.cwd) return;
        if (!request?.deferPick) {
          setChooseFolder(false);
          void chooseProject(result.cwd);
        }
        return result.cwd;
      })
      .catch((error: unknown) => {
        // A deferred ask's caller (the folder menu) shows the failure with its Retry; one notice, not two.
        if (request?.deferPick) throw error;
        console.warn("agent pane: Choose Folder failed", error);
        setFolderError(knownRefusalText(error) ?? translate("agentHome.chooseFailed"));
        return undefined;
      });
  };
  // A subagent's own pane is a tab on the chat's session: the chat's composer, queue and pull
  // request bars there were the chat's, and a prompt typed in it went to the chat. It draws the
  // subagent's composer instead, whose prompt the chat passes on to the subagent.
  // The subagent's draft is its own, by keys that hold while its pane is open: the chat's session and
  // the pane's own subagent id (a workflow agent's run and id). Never the relay target, whose harness
  // id, task name and connected chat arrive or change later and would remount the composer empty.
  const subagentDraftKey = `${subagentDraftChat}\u0000${shownSubagentId ?? ""}`;
  // A message that did not reach the chat comes back into the subagent's draft (subagentDrafts.ts)
  // with a note over the box, by the draft it came back to, until the next send from it.
  const [subagentFailed, setSubagentFailed] = useState<string>();
  useEffect(() => {
    if (!readOnlySubagent) return;
    return subscribeSubagentDraft(subagentDraftKey, () => setSubagentFailed(subagentDraftKey));
  }, [readOnlySubagent, subagentDraftKey]);
  // The subagent pane's composer is the chat's Composer relayed to the subagent (Composer.tsx
  // `relay`): its draft is the subagent's, and what is sent goes to the chat as a message its agent
  // passes on (subagentMessage.ts). The placeholder names the subagent, so a prompt never goes
  // anywhere the composer does not say.
  const subagentRelay: ComposerRelay | undefined = readOnlySubagent
    ? {
        placeholder: t("subagents.messagePlaceholder", { name: shownSubagentTarget?.name ?? t("tray.kind.subagent") }),
        handle: subagentComposer,
        initial: subagentDraft(subagentDraftKey),
        onChange: (draft) => keepSubagentDraft(subagentDraftKey, draft),
        subscribe: (listener) => subscribeSubagentDraft(subagentDraftKey, listener),
        // A quote taken while the editor was still being made stays this subagent's, after its draft.
        onUnplacedQuotes: (quotes) => {
          const kept = subagentDraft(subagentDraftKey);
          keepSubagentDraft(subagentDraftKey, { ...kept, text: [kept.text, ...quotes].filter(Boolean).join("\n\n") });
        },
        attachRefusal: t("subagents.messageTextOnly"),
        ...(sendToSubagent && {
          send: (text: string, attachments: ComposerAttachment[]) => {
            const message = subagentDraftMessage({ text, attachments });
            if (!message) return false;
            const key = subagentDraftKey;
            // Until the chat takes it, the message is kept as in flight, so a page closed or let go
            // meanwhile still hands it on; the prompt it leaves is empty (subagentDrafts.ts).
            const settled = sendingSubagentDraft(key, message);
            keepSubagentDraft(key, { text: "", attachments: [] });
            setSubagentFailed(undefined);
            sendToSubagent(message).then(settled, () => {
              // The message comes back to the prompt whole (afterFailedSend), over the draft kept now.
              restoreSubagentDraft(
                key,
                afterFailedSend(subagentDraft(key), { typed: text, held: attachments, message }),
              );
              settled();
            });
            return true;
          },
        }),
      }
    : undefined;
  // The live turn's notices read one phase (turnPhase.ts): never a resumed attempt's line under a
  // turn that ended. The pane draws no "may be stuck" guess (#45162): a real failure has its card.
  const liveTurnPhase = turnPhase(snapshot);
  // The chat's goal, a row of the composer hat (TaskGoalStrip.tsx; goalHat.experiment.ts places it
  // at the hat's top, the default, or its foot over the composer). Its actions are Codex's own
  // `/goal` subcommands; an edit sends `/goal <text>`, which sets the new objective in its place.
  const goalNode =
    !showNewTab && composerSnapshot.summary?.goal ? (
      <TaskGoalStrip
        // Its own key: HatQuestions, its sibling in the stack, is keyed by the chat's id.
        key={`goal:${composerSnapshot.summary.sessionId}`}
        goal={composerSnapshot.summary.goal}
        harness={composerSnapshot.summary.harness}
        command={(action, objective) =>
          callNative("chat.send", {
            text: `/goal ${action === "delete" ? "clear" : action === "edit" ? objective : action}`,
            attachments: [],
          })
        }
      />
    ) : null;
  const goalAtFoot = goalNode !== null && goalHatPlaceArm === "foot";
  // The dock draws the composer (a draft a refusal put back stays in reach even once the tab's run
  // shows), and with it the composer card's quiet row: the dock's `data-foot` (bottomStack.css).
  const dockFoot = (!sandboxHoldsChat || sandboxDraftMoved) && !viewedSandbox && (readOnlySubagent || !reviewing);
  // The managed banner's Hide: the chat is the person's again, and the composer takes the focus.
  const hideManaged = (sessionId: string) => {
    takeOverManaged(sessionId);
    setTakenOverAt(Date.now());
    composerHandle.current?.focus();
  };
  const composer = drawPaneComposer({
    markDockEdge,
    readOnlySubagent,
    subagentRelay,
    subagentDraftKey,
    subagentFailed: subagentFailed === subagentDraftKey,
    t,
    reviewing,
    snapshot,
    dictation,
    cloudHintShown,
    showNewTab,
    composerModeRows,
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
    hatQuestionList,
    NO_HAT_QUESTIONS,
    hatQuestionActions,
    trayPlacement,
    trayTucked,
    trayNode,
    trayList,
    waitingAgents,
    hatPlan,
    hatKept,
    trayHandle,
    statusCardOpen,
    setStatusCardOpen,
    openImage,
    cloudStarting,
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
  });
  // A handshake that still waits for acpmux: once it has waited long, one line says how long, with
  // Restart agent service. The person decides; the app never restarts a slow acpmux by itself.
  const restartStuck = () =>
    void restartGate.run(
      () =>
        callNative<{ stopped?: unknown } | null>("acpmux.restartStuck").then((reply) => {
          if (reply?.stopped !== true) setRestartUnavailable(true);
        }),
      {
        cancelRetries: () => cancelRetry.current?.(),
        changed: setRestartingAcpmux,
        connected: () => !!directClient.current,
        ask: () => retryHost.current?.(),
      },
    );
  // While the host recovers nothing shows (no card, no spinner, no button) and the composer stays
  // usable; a failure past its deadline, or a refusal, is one line (HostUnavailableLine).
  // The line is plain words: a chat's machine that is not reachable says so, and acpmux's own codes
  // and commands go behind Details (hostLine.ts).
  const hostWords = hostLineText(hostFailure, hostError ?? "", t, machineName);
  const hostErrorCard = (
    <Notice id="host-error" tier="error" when={hostErrorSaid}>
      <HostUnavailableLine
        message={hostWords.line}
        detail={hostWords.detail}
        retrying={retryQueued}
        onRetry={() => retryHost.current?.()}
        // The pane asks again by itself unless asking cannot change the answer: a chat too large to
        // open, or another build's acpmux holding the socket (only Restart clears it).
        selfRetrying={hostSelfRetrying(
          hostFailure,
          acpmuxRestartOffered,
          hostTroubleSince === undefined ? 0 : Date.now() - hostTroubleSince,
        )}
        restarting={restartingAcpmux}
        onRestart={
          acpmuxRestartOffered
            ? () => {
                // The person's click: the app stops the other binary's daemon (its chats are kept),
                // and the next handshake starts this app's own acpmux.
                // No handshake runs meanwhile: the old daemon is still there until it stops.
                void restartGate.run(() => callNative("acpmux.restart"), {
                  cancelRetries: () => cancelRetry.current?.(),
                  changed: setRestartingAcpmux,
                  connected: () => !!directClient.current,
                  ask: () => retryHost.current?.(),
                });
              }
            : undefined
        }
      />
    </Notice>
  );
  // One host line at a time, the newest state winning: a long wait replaces the line of an
  // earlier failed handshake (HostWaitingLine's `otherwise`).
  const daemonWaitingSince = clientSnapshot.daemonWaitingSince;
  const hostWaitingSince = waitingSince ?? daemonWaitingSince;
  const hostWaitOrError =
    hostWaitingSince !== undefined ? (
      <HostWaitingLine
        since={hostWaitingSince}
        restarting={restartingAcpmux}
        onRestart={waitingSince !== undefined && !restartUnavailable ? restartStuck : undefined}
        otherwise={hostErrorCard}
      />
    ) : (
      hostErrorCard
    );
  // While the pane gets its chat back on its own, one quiet line says so: "Restoring sessions…"
  // while the host says acpmux restores, "Reconnecting…" for a lost connection before the deadline.
  // A Restart acpmux in flight keeps its own line.
  // It is drawn out of flow, in a slot that is always there (HostLineSlot): no state of it moves a row.
  const hostLine = (
    <HostLineSlot>
      {restartingAcpmux ? (
        hostWaitOrError
      ) : (
        <HostRecoveringLine
          relinkingSince={relinkingSince}
          restoring={hostRestoring}
          failureShown={hostErrorSaid}
          // "Reconnecting…" stays until the waiting line, whose wait starts a moment later, replaces it.
          waitingSince={hostWaitingSince}
          otherwise={hostWaitOrError}
        />
      )}
    </HostLineSlot>
  );
  // A pending Fork Conversation and its Cancel, in the dock and in Quick Chat alike: Quick Chat's
  // menu forks too (review of #36979).
  const forkPendingLine = snapshot.forkPending && (
    <ForkPendingLine since={snapshot.forkPending.since} onCancel={() => directClient.current?.cancelFork()} />
  );
  // The floating chat's compact bar shows whether the chat is working or waiting on the user, and
  // the reply's last line.
  let lastReply: (typeof snapshot.rows)[number] | undefined;
  for (let index = snapshot.rows.length - 1; index >= 0 && !lastReply; index--) {
    if (snapshot.rows[index]!.kind === "assistant") lastReply = snapshot.rows[index];
  }
  const floatingSession = findSession(composerSnapshot.sessions, snapshot.sessionId);
  const quickFloating: QuickFloating | undefined = quick
    ? {
        state: floatingHold,
        status: floatingStatus(
          Boolean(snapshot.permission?.pending) ||
            Boolean(
              snapshot.permissionGroups?.groups?.some(
                (group) => group.state === "pending" || group.state === "collecting",
              ),
            ) ||
            floatingSession?.status === "waiting",
          lastReply?.streaming === true || floatingSession?.status === "running",
        ),
        title: composerSnapshot.summary?.title || t("header.agentChat"),
        line: (lastReply?.text ?? "")
          .split("\n")
          .map((part) => part.trim())
          .filter(Boolean)
          .at(-1),
        setOnTop: (onTop) => void callNative(QUICK_MESSAGES.setOnTop, { onTop }).catch(() => undefined),
        setCollapsed: (collapsed) => void callNative(QUICK_MESSAGES.setCollapsed, { collapsed }).catch(() => undefined),
        moveToTab: () => {
          if (snapshot.sessionId) postOpenInWindow(snapshot.sessionId);
        },
        includeContext: () =>
          void callNative(QUICK_MESSAGES.context)
            .then((value) => {
              const chip = contextAttachment(value, t("floating.focusedTab"));
              if (chip) composerHandle.current?.attach(chip);
              composerHandle.current?.focus();
            })
            .catch(() => undefined),
      }
    : undefined;
  const chiefDockEnabled = quick && experimentArm(chiefDock) === "on";
  const quickChiefDock = chiefDockEnabled
    ? {
        sessions: composerSnapshot.sessions,
        currentId: snapshot.sessionId,
        // The person's own queued prompts, as the composer's queue counts them.
        queueCounts:
          snapshot.sessionId && ownQueue(shownQueue).length > 0
            ? new Map([[snapshot.sessionId, ownQueue(shownQueue).length]])
            : undefined,
        steeringIds:
          snapshot.summary?.steering && snapshot.sessionId && ownQueue(shownQueue).length > 0
            ? new Set([snapshot.sessionId])
            : undefined,
        onSelect: selectSession,
        onNewChat: () => void callNative("chat.new", {}).catch(() => undefined),
        onMoveToTab: (sessionId: string) => {
          // Warm for the new tab: this chat if it is the one on screen, and otherwise whatever this
          // page already read of it, which rememberTail handed over when it was left.
          directClient.current?.handOverCurrentTail();
          void callNative("chat.openTab", { sessionId, placement: "tab" }).catch(() => undefined);
        },
      }
    : undefined;
  if (quick)
    return (
      <ShortcutsContext.Provider value={shortcuts}>
        <section className="acpmux-shell" data-surface="quick">
          <QuickSurface
            transcript={
              snapshot.rows.length > 0 || chatShellRuns.length > 0 || queuedRows.length > 0 ? transcript : undefined
            }
            asks={
              <>
                {asks}
                {hostLine}
                {forkPendingLine}
              </>
            }
            composer={composer}
            floating={quickFloating}
            chiefDock={quickChiefDock}
          />
          {imageView && (
            <ImageViewer
              images={imageView.images}
              index={imageView.index}
              onIndex={(index) => setImageView((current) => current && { ...current, index })}
              onClose={() => setImageView(undefined)}
            />
          )}
        </section>
      </ShortcutsContext.Provider>
    );
  if (paneRenderStart > 0) acpmuxPerf.span("pane.body", performance.now() - paneRenderStart);
  // Sources' Use tools (cx-thur3): only where acpmux can change the chat's tools. A browser over
  // the web relay (`remote`) cannot: acpmux refuses it there (`tools.remote`). A subagent's pane
  // is read-only.
  const chatTools =
    snapshot.summary?.toolsMutable && snapshot.summary.tools && snapshot.origin !== "remote" && !readOnlySubagent
      ? {
          rows: snapshot.summary.tools,
          set: (id: string, enabled: boolean) =>
            // l10n-allow: never shown; the row says summary.tools.failed.
            directClient.current?.setTool(id, enabled) ?? Promise.reject(new Error("no connection")),
        }
      : undefined;
  const summaryPanel = (
    // Its Subagents tab draws the transcript's subagent rows, avatars carrying the harness's mark and
    // a running one's stop button.
    <SubagentStopContext.Provider value={stopSubagent}>
      <SubagentClockContext.Provider value={snapshot.clockOffsetMs ?? 0}>
        <SubagentHarnessContext.Provider value={knownMark(snapshot.summary?.harness, snapshot.summary?.family)}>
          <SummaryCard
            key={snapshot.sessionId}
            card={summaryCard}
            environment={{
              summary: sessionInfoSubagent
                ? subagentSummary(sessionInfoSummary, sessionInfoSubagent.agent, sessionInfoSubagent.rows)
                : sessionInfoSummary,
              machineName,
              peerKinds: snapshot.peerKinds,
              place: chatPlace(snapshot),
              repository: githubRepository,
              cloudRepositoryAvailable,
              onOpenFolder:
                quick || !sessionInfoLocal
                  ? undefined
                  : (path) =>
                      ignoreFailure(callNative("pane.action", { id: HEADER_ACTIONS.files, cwd: path, mode: "open" })),
            }}
            rows={cardRows}
            cwd={snapshot.summary?.cwd}
            changes={quick ? undefined : cardEdit.changes}
            onOpenChanges={toggleLastChanges}
            onOpenOutput={quick ? undefined : openOutput}
            onOpenImage={quick ? undefined : openImage}
            subagents={cardSubagents}
            subsessions={chatSubsessions}
            background={cardBackground}
            sessions={cardSessions}
            // The picks are this computer's files: only a chat whose folder is here (not a peer's or
            // another host's) and not Quick Chat.
            // A subagent's pane has no composer to attach to.
            onAttach={
              localCwd && !quick && !readOnlySubagent ? () => void attachLinks().catch(() => undefined) : undefined
            }
            tools={chatTools}
            workflows={workflows}
            workflowActionsFor={workflowActionsFor}
            onOpenSessionInfo={openSummarySection}
          />
        </SubagentHarnessContext.Provider>
      </SubagentClockContext.Provider>
    </SubagentStopContext.Provider>
  );
  const contextSaveFn = contextSave(snapshot, directClient.current, contextSessionId);
  const contextPage = (
    <ContextScreen
      load={loadContext}
      {...(contextSaveFn ? { save: contextSaveFn } : {})}
      onClose={() => setContextOpen(false)}
    />
  );
  const harnessesPage = (
    <HarnessesScreen
      catalog={pickerCatalog}
      acpmux={snapshot.catalog}
      {...(harnessFolder ? { cwd: harnessFolder } : {})}
      callNative={harnessesNative}
      checking={harnessesChecking}
      refreshCatalog={pickerState.refresh}
      onClose={() => {
        setupContinuation.current = undefined;
        setupStart.current = undefined;
        setHarnessesOpen(false);
      }}
      {...(setupContinuation.current
        ? {
            onStartChat: (harness: string) => {
              const resume = setupContinuation.current;
              setupContinuation.current = undefined;
              setupStart.current = resume ? { harness, resume } : undefined;
              setHarnessesOpen(false);
            },
          }
        : {})}
      onStart={() => {
        setupContinuation.current = undefined;
        setupStart.current = undefined;
        setHarnessesOpen(false);
        setNewTab(undefined);
      }}
    />
  );
  const pane = drawPaneBody({
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
    dockFoot,
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
    // Each pair as the render narrowed it (PaneBody.tsx `NewTabShown`, `CloudStartShown`).
    ...(showNewTab ? { showNewTab, newTab } : { showNewTab, newTab }),
    ...(cloudStartShown ? { cloudStartShown, cloudStart } : { cloudStartShown, cloudStart }),
  });
  return (
    <SignInContext.Provider value={signIn}>
      <ChatAccountsContext.Provider value={chatAccounts}>
        <UpdateOfferContext.Provider value={updateOffer}>
          <HarnessUpdatesContext.Provider value={harnessUpdates}>
            <AgentProgressContext.Provider value={progressStore}>
              <OpenBackgroundTasks.Provider value={quick ? undefined : openBackgroundTask}>
                <ClaudeConnectContext.Provider value={modelConnect}>
                  <NoticeSlot>{pane}</NoticeSlot>
                </ClaudeConnectContext.Provider>
              </OpenBackgroundTasks.Provider>
            </AgentProgressContext.Provider>
          </HarnessUpdatesContext.Provider>
        </UpdateOfferContext.Provider>
      </ChatAccountsContext.Provider>
    </SignInContext.Provider>
  );
}
