import { composerHealthHarness } from "./composerPickerEntries";
import { forkMenuRows } from "./header/forkMenu";
import { openFork } from "./conversation/openFork";
import { setSessionRefResolver } from "./conversation/sessionRefs";
import { useStopThroughReconnect } from "./stopThroughReconnect";
import React, {
  Activity,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { LivePresenceStack, LiveTypingLine } from "./multiplayer/LivePresence";
import { composerPlusSearchExtensions, PLUS_SEARCH_ACTIONS } from "./composerPlusRegistry";
import { CONNECT_ACTIONS, type ConnectKind, type OffloadKind, thisMacName } from "./environments";
import { restoreForkSource } from "./handoff/restoreForkSource";
import { QueryClientProvider, useIsFetching, useQueryClient } from "@tanstack/react-query";
import { applyAgentTheme } from "../shared/theme";
import { agentKey } from "../shared/agentKey";
import {
  paneHeader,
  type AcpmuxPermission,
  type AcpmuxSecretAsk,
  type AcpmuxRow,
  type AcpmuxSnapshot,
  type QueueEdit,
  linkUp,
  type AcpmuxPlanEntry,
} from "./model";
import { lacksImageBytes, ownQueue, queuedAttachments, queuedMessageRows } from "./conversation/queuedMessages";
import { pendingMessagesRow, searchablePendingRows, withWaitingRows } from "./conversation/pendingMessages";
import { type HeldAnswer, type QueuedMessageActionsValue } from "./conversation/QueuedMessageCard";
import { AcpmuxDirectClient, type AcpmuxHostConfig, harnessBlock, type HarnessBlock, isTrustRefusal } from "./direct";
import { readHostTail } from "./tailCache";
import { failedRowOf, failedRowTrustRetry } from "./failedRowTrustRetry";
import {
  authBlocksSend,
  authText,
  isAuthPreflightPending,
  sessionLogin,
  slashLogin,
  useRouteAuthSwitch,
  useSessionAuth,
  UNKNOWN_AUTH,
} from "./sessionAuth";
import { postNative } from "./native";
import { CloudEnvironmentEditor } from "./CloudEnvironmentEditor";
import { NativeError } from "./nativeError";
import { errorMessage, isStartCancelled, startCancelled } from "./transportErrors";
import { pageHostClient, startHostEvents } from "./pageHost";
import { FOCUS_LOCATION_EVENT, NewTabPage, newTabHost, type NewTabChat, type NewTabHost } from "./NewTabPage";
import { setDeviceChats } from "./newtab/deviceChats";
import { setRecentlyClosed } from "./newtab/recentlyClosed";
import { setNowPlaying } from "./newtab/nowPlaying";
import { setAttentionTabs } from "./needsYou/attentionTabs";
import { NewTabScreen, type NewTabScreenActions } from "./newtab/NewTabScreen";
import { HistoryScreen } from "./newtab/HistoryScreen";
import type { AllChatsPage } from "./newtab/AllChatsList";
import { newTabScreenActions } from "./newtab/screenActions";
import { newTabChipSnapshot } from "./newtab/chipDefaults";
import { HarnessesScreen } from "./harnesses/HarnessesScreen";
import { openHarnessesPage, registerHarnessesPage, useHarnessesPage } from "./harnesses/harnessesPage";
import {
  injectedNewTabContext,
  useEarlyNewTabContext,
  useNewTabAdoption,
  useNewTabPlaces,
  useSessionAdoption,
  useNewTabWeather,
  type SessionAdoption,
  withHandshakeNewTab,
} from "./newtab/adoption";
import { markMockPage, publishSessions, sharesChatList, useSharedSessions } from "./newtab/chatStore";
import { heldPick, withDraftFolder } from "./newtab/draftFolder";
import { configurationSessionMatches, resolveEffortOption } from "./configurationActions";
import { rememberRecentFolders } from "./newtab/recentProject";
import { rememberStartedProject } from "./newtab/startedProject";
import { publishWarmNewTab, shownNewTabSessions, useWarmNewTabSessions } from "./newtab/warmSnapshot";
import { TaskGoalStrip } from "./TaskGoalStrip";
import { PageDots } from "./newtab/PageDots";
import { useSessionCommands } from "./newtab/useSessionCommands";
import { editNewTabWidgets, shownPageWidgets, withWidgetEdit } from "./newtab/pageWidgets";
import { screenTemplate, shownTemplate } from "./newtab/templates";
import { newTabPageSubmit } from "./newtab/pageSubmit";
import { holdNewTabAttachments } from "./newtab/remoteAttachmentDraft";
import { startNewTabTransition } from "./newtab/startTransition";
import { isAgentHome, projectLabel, recentLocalFolders, sessionTitle, type AcpmuxSessionEntry } from "./sessionList";
import { setBookmarkTransport } from "./threadMinimap/bookmarks";
import {
  composerDraft,
  DRAFT_SETTLE_MS,
  notifyDraftActionsChanged,
  hasPendingDraftWrite,
  readDurableDraftState,
  readPersistedDraft,
  settleDraftWithin,
  settlePendingDraftWrites,
  writePersistedDraft,
} from "./composerDraft";
import { paneContext } from "./paneContext";
import {
  createPaneQueryClient,
  followHarnessChanges,
  harnessCatalogKey,
  useHarnessCatalog,
  useHarnessesListed,
  type HarnessCatalogSource,
} from "./catalog";
import { usePickerCatalog } from "./modelCatalogHost";
import { isDefaultChoice } from "./defaultChoice";
import { applySwitch, browserSwitchClock, HarnessSwitch, lastOfferedModel, type SwitchPort } from "./harnessSwitch";
import { NewChatPrewarm, type PrewarmTarget } from "./newChatPrewarm";
import { harnessModeName, highestMode } from "./harnessModes";
import {
  CloudTypingPrewarm,
  cloudIdentityKept,
  cloudTypingMachineID,
  type CloudIdentityView,
} from "./cloudTypingPrewarm";
import { CloudComposeReservation, reservedCloudCall } from "./cloudComposeReservation";
import { harnessProfiles } from "./harnessProfiles";
import { setStartModeSource } from "./startMode";
import { setPromptSurfaces } from "./surfaces/promptSurface";
import type { MockScript } from "./mock";
import { preparedMockTransport } from "./mockTransport";
import { BridgeSocket } from "./bridgeSocket";
import { useComposerKeyboard } from "./composerFocus";
import { createAcpmuxDebug, type AcpmuxDebug } from "./debug";
import { type AutomationCompose, pageAction } from "./automation";
import { acpWire } from "./wire";
import { acpmuxPerf } from "./perf";
import { reconciledProject, startFromContext } from "./newtab/startHint";
import { drawsAsIs, setStreamingRowBlocked, streamingRow, streamingRowBlocked, textOnlyRow } from "./streamingRow";
import { remoteComposer } from "./remoteEditing";
import { Composer, type ComposerHandle, type ComposerWake } from "./Composer";
import { FolderContinuation, folderContinuationRequest } from "./folderContinuation";
import type { BrowseRequest } from "./AddProjectPanel";
import { handBackQuotes, quoteIntoComposer, replayHeldForComposer, restoreComposerDraft } from "./composerRestore";
import {
  attachmentSource,
  linkAttachment,
  linkItems,
  type ComposerAttachment,
  type DroppedKind,
  recordingAttachment,
  recordingLeftOutNotice,
  remoteRecordingAttachment,
  withSource,
} from "./attachments";
import { keptChips, type KeptAttachments } from "./composer/keptAttachments";
import { ComposerPickers, PICKER_LABELS } from "./ComposerPickers";
import { chatAccessGrants, revokeAccessRows } from "./header/grantsMenu";
import { openPicker } from "./pickerOpeners";
import { startRefusalRoute } from "./startRefusal";
import { EmptyState, type EmptyStateProjects, isNewChat, projectName } from "./EmptyState";
import { paneKnowsNewChat } from "./locationRow";
import { ChatUnavailableState } from "./ChatUnavailableState";
import { useCloudChatRecovery } from "./useCloudChatRecovery";
import { cloudChatRecoveryActive, cloudChatUnavailable, type CloudChatIdentity } from "./cloudChatRecovery";
import { cloudSendWakes, cloudTypingWakes, type CloudWakeState } from "./cloudWake";
import { PastChat, type PastTurn, readPastTurns } from "./PastChat";
import type { Project } from "./ProjectChooser";
import { byRecentUse, parseProjectRepos } from "./projectRepos";
import { answerFromHome } from "./HomeInbox";
import { HomeLists } from "./HomeLists";
import { lastChange, turnFiles, turnPathsOnly, turnRows, type PathRef, type TurnFile } from "./diff";
import { opensTurn } from "./turnStart";
import type { TrustSource } from "./folderTrust";
import { TrustAsk, trustedLabel } from "./TrustAsk";
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
import { ComputerUsePreviewCard } from "./computerUse/ComputerUsePreviewCard";
import { askOnSingleCard, cardTakesShortcuts, heldOnCard } from "./permissionKeys";
import { agentName } from "./agents";
import { translate, usePaneLanguage, useT } from "./i18n";
import { PeerCopyBanner } from "./PeerCopyBanner";
import { chatCloudMachine, cloudMachineRows, createStopWaiter } from "./cloudMachineMenu";
import {
  cloudMachineAsleep,
  readUntilMoved,
  refreshCloudMachines,
  useCloudMachines,
  type CloudMachine,
} from "./cloudMachines";
import { usePeerCloudMachine } from "./peerCloudMachine";
import { inThisVisit, useFolderTrustAsk, visitOf } from "./useFolderTrustAsk";
import { movedOn, sentIn as sentInHeld, useTrustHeldPrompts, whereHeldGoes, type TrustHeldPrompt } from "./trustHeld";
import { routeCurrentTrustRefusal, routeOwnedTrustRefusal, type TrustRefusalOwner } from "./trustRefusalRoute";
import { heldPrompts } from "./heldPrompt";
import { StartingSends, type StartingSend } from "./startingSends";
import { FILE_SEARCH_LIMIT, type FileSearchSource } from "./fileSearchModel";
import { Inspector, type ExportOutcome } from "./Inspector";
import { SummaryButton } from "./summary/SummaryButton";
import { SummaryCard } from "./summary/SummaryCard";
import { type SummaryBackgroundTask, transcriptBackground } from "./summary/sessionSummary";
import { openSourceFile } from "./session-info/SourcesSection";
import { useSessionInfo } from "./session-info/SessionInfo";
import { setRemoteControl, toggleRemoteControl, useRemoteControl } from "./remoteControl";
import {
  type BackgroundCommand,
  backgroundCommands,
  backgroundSection,
  type SessionInfoProcess,
  sessionInfoLists,
  type ProcessSource,
  useProcessRegistry,
} from "./session-info/processes";
import {
  setSessionInfoOpen as setSessionInfoPanelOpen,
  setSessionInfoSection,
  setSessionInfoTab,
  useSessionInfoOpen,
  sessionInfoPaneKey,
} from "./session-info/sessionInfoState";
import { openCommand, opensProcessTerminal } from "./processTerminal";
import {
  descendants,
  subagentChangesFolder,
  subagentProcesses,
  subagentSummary,
  withChatEnds,
  type SubagentScope,
} from "./session-info/subagentScope";
import { pendingToolCalls, waitingSubagents } from "./summary/SubagentStatusList";
import { SubagentTray } from "./subagents/SubagentTray";
import { pullTabCounts, TrayPullTab, tuckTray } from "./subagents/TrayPullTab";
import { agentProgressSource } from "./subagents/agentProgressSource";
import { AgentProgressContext, AgentProgressStore } from "./subagents/agentProgressStore";
import { BackgroundTasksPanel } from "./backgroundTasks/BackgroundTasksPanel";
import { isBackgroundPane, openBackgroundPane } from "./backgroundTasks/backgroundPane";
import { backgroundGroups, type TaskCache } from "./backgroundTasks/backgroundTasks";
import { backgroundTasksLook } from "./backgroundTasks/backgroundTasksLook.experiment";
import { settleTrayExit } from "./subagents/trayMotion";
import { runRetry, type RetryTarget } from "./subagents/retryState";
import { configureWorkflowCardOpen, configureWorkflowCardSideTab } from "./summary/WorkflowCard";
import {
  type DoneLineCache,
  configureSubagentTray,
  finishedTrayItems,
  trayItems,
  useSubagentTray,
  withSubagentLines,
} from "./subagents/runningTray";
import { configureSubagentTrayPlacement, useSubagentTrayPlacement } from "./subagents/subagentTrayPlacement";
import { configureSelectionReply, SelectionReplyChip, setQuoteReplySink } from "./conversation/SelectionReply";
import { AgentTonesContext, agentTone, agentTones } from "./subagents/agentTones";
import { useSummaryCard, useSummaryColumn } from "./summary/cardState";
import { chatHasSummaryContent } from "./summary/summaryContent";
import { createWorkflowAdapter, workflowDetailRequest, type WorkflowDetailRequest } from "./summary/foldWorkflows";
import { workflowPaneId, workflowPaneRequest } from "./summary/workflowTranscript";
import { useWorkflowTranscript } from "./summary/useWorkflowTranscript";
import { releaseReaderScroll, useHeldWhileScrolling } from "./summary/heldWhileScrolling";
import type { WorkflowAgent, WorkflowSummary } from "./summary/workflow";
import { WorkflowSideTab } from "./summary/WorkflowSideTab";
import {
  showSubagent as showSubagentIn,
  revealedSubagent,
  subagentTabTitle,
  useAutoOpenSubagents,
  useOpenNewSubagents,
} from "./subagents/subagentPanes";
import { useShownSubagent } from "./subagents/subagentShown";
import { turnCounts } from "./changes/turnCheckpoint";
import { TurnCountsContext, type TurnCountsFor } from "./changes/TurnCountsContext";
import { useTurnCheckpoints } from "./changes/useTurnCheckpoints";
import { latestTurnCheckpointPair, readTurnFromRows, type CheckpointDiff } from "./changes/turnCheckpointSource";
import {
  registerAttachmentViewHost,
  registerComposerHost,
  registerComposerRingHost,
  useComposerSettings,
} from "./composerSettings";
import { shouldScrollToBottomAfterSend } from "./sendScrollSetting";
import { restoredDecisions, type HunkDecision, type HunkReview } from "./changes/hunkReview";
import {
  configureDictation,
  deliverDictation,
  isWaitingForWords,
  useDictation,
  type DictationField,
} from "./dictation";
import type { DictationUpdate } from "./dictationText";
import { DictationMic } from "./DictationMic";
import { DictationNotice } from "./DictationNotice";
import type { MarkdownFieldHandle } from "./MarkdownField";
import { AgentNamesContext, AgentOpenContext, agentNames, agentViews } from "./conversation/agentNames";
import { setReadAloudState } from "./conversation/readAloud";
import { loadHighlightedCode } from "./conversation/CodeBlock";
import { loadEditDiffHunks } from "./conversation/EditDiff";
import { BackgroundTaskOutputContext, type BackgroundTaskOutputReader } from "./conversation/backgroundTaskOutput";
import { SessionCwdContext, SessionEditsContext, sessionEdits, type SessionEdits } from "./turnChanges/sessionRows";
import { startedNames, SubsessionNamesProvider, type StartedNames } from "./conversation/startedNames";
import {
  headerChangesInPlace,
  repositoryRoot,
  viewChangesBeside,
  viewChangesFiles,
  viewChangesPatch,
  viewChangesTurn,
} from "./turnChanges/viewChanges";
import { resendToOwner, retryFailedTurn } from "./conversation/turnRetry";
import {
  TurnActionsContext,
  chatLoginCommand,
  compactThrough,
  offersCompact,
  resumeThrough,
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
import {
  editableKey,
  editableSeqs,
  promptTurns,
  trackEditableTurns,
  type EditableTurns,
} from "./conversation/editPrompt";
import { isFindRow, type ChatFind } from "./conversation/chatFind";
import { ChatFindScope } from "./conversation/ChatFindScope";
import {
  ACTIVITY_LINE,
  DATE,
  THINKING,
  messageRevealTarget,
  openViewTurnFold,
  toggleTurnFold,
  toggleViewTurnFold,
  hiddenRowFolds,
  WORKING,
  type TurnView,
  trayWaitAgents,
  turnViewFrom,
  liveTurnPlan,
  samePlanEntries as sameEntries,
} from "./conversation/turns";
import { turnPreviewUrl } from "./conversation/previewUrl";
import { projectInboxRows } from "./conversation/laneNoticeBatches";
import {
  canFork,
  forkRefusal,
  forkToTarget,
  forksAnyTurn,
  latestForkSeq,
  messageMenuTarget,
  openReportedImage,
  setMessageMenuSource,
} from "./conversation/messageMenu";
import { actOnReportedImage } from "./conversation/imageMenuActions";
import { callChipHost } from "./chips/host";
import { pullRequestRef } from "./chips/PullRequestCard";
import { ArtifactPanel, useArtifactCoversPane, type SaveDocument } from "./conversation/ArtifactPanel";
import { branchesFromKey, branchesKey, forkAnchor, messageBranches } from "./conversation/branches";
import { ArtifactContext, type Artifact } from "./conversation/artifactPreview";
import {
  artifactVersionsForSession,
  changeArtifactPin,
  visibleArtifact,
  type OpenedArtifact,
} from "./conversation/artifactPin";
import { uniqueArtifacts } from "./conversation/artifactDedupe";
import { writtenArtifacts } from "./conversation/writtenArtifacts";
import { artifactVersions } from "./conversation/artifactVersions";
import { artifactLiveSource, mergeArtifactVersions } from "./conversation/artifactLive";
import { RenderPages, renderPages, renderVersions } from "./conversation/renderCall";
import { ShortcutsContext, readShortcuts, type ShortcutLabels } from "./shortcuts";
import {
  FALLBACK_LINK_SCHEME,
  notifyRevealRowsChanged,
  revealedMessage,
  revealMessageWhenShown,
  revealTurnWhenShown,
  setLinkScheme,
} from "./links";
import { NeedsYouButton } from "./needsYou/NeedsYou";
import { useNeedsYou } from "./needsYou/useNeedsYou";
import { copyText } from "./conversation/clipboard";
import { lastCodeBlock } from "./conversation/lastCodeBlock";
import type { ChatImage } from "./conversation/chatImages";
import { viewerImages } from "./summary/chatGallery";
import { ImageViewer } from "./conversation/ImageViewer";
import { ImageViewerContext } from "./conversation/imageViewerContext";
import { sessionLink } from "./links";
import { ChatHeaderInlineStatus, ChatHeaderStatus } from "./header/ChatHeaderStatus";
import {
  ChatHeaderTools,
  HEADER_ACTIONS,
  guardedChatMenu,
  menuGroups,
  type ChatMenuItem,
} from "./header/ChatHeaderTools";
import { ThreadTitle } from "./header/ThreadTitle";
import { deleteChatRow, moveMachineRow } from "./header/chatRows";
import { headerState, setHeaderState, useHeaderState } from "./header/headerState";
import { setTabRow, tabRowStyle, useTabRow, useTabRowTools } from "./header/tabRow";
import { SubagentComposer } from "./subagents/SubagentComposer";
import {
  draftMessage as subagentDraftMessage,
  subagentDraftUnsaved,
  takeUnsavedSubagentDrafts,
  wakeIntoSubagentDrafts,
  wakeSubagentDrafts,
} from "./subagents/subagentDrafts";
import {
  subagentRelayPrompt,
  subagentRelaySteers,
  subagentTarget,
  workflowAgentTarget,
} from "./subagents/subagentMessage";
import { runsUnderTabRow, type UnderHeaderLines } from "./header/underHeader";
import { HarnessStatusCard } from "./HarnessStatusCard";
import {
  cloudPageRefusal,
  cloudRunsHere,
  cloudFolderGrants,
  cloudStartFolder,
  cloudStartToasted,
  grantedCloudStart,
  newTabProjectPick,
  cloudStartKeys as makeCloudStartKeys,
  type CloudStart,
} from "./cloudRun";
import { repickCloudChat, type RepickMachine } from "./cloudRepick";
import { folderRunLocation, newChatRunLocation } from "./runLocationDefault";
import { harnessLabel } from "./subagents/agentRuns";
import { cloudStartBegun, cloudStartEnded, cloudStartPushed, type CloudStartProgress } from "./cloudStartProgress";
import { CloudStartView } from "./CloudStartView";
import { configureQuickActions, quickActions, type QuickActionMode } from "./header/quickActions";
import { configureChatWidth } from "./chatWidth";
import {
  registerChatDisplayHost,
  useChatDisplay,
  useChatPinnedPlan,
  useTrayHandle,
  useTrayTucked,
} from "./chatDisplay";
import { ChatDisplaySettings } from "./ChatDisplaySettings";
import { wrapOutputRow } from "./header/transcriptViewRow";
import { presentationRow } from "./header/presentationRow";
import { usePresentation } from "./conversation/presentation";
import { messagesRows } from "./conversation/messagesRows";
import { PresentationContext } from "./conversation/PresentationContext";
import { thinkingVerbsFor, ThinkingVerbsContext } from "./conversation/thinkingVerbs";
import { useStatusVerbConfig } from "./statusVerbs";
import { configureCodexToolRuns, useCodexToolRuns } from "./codexToolRuns";
import { configureLiveLineBelow, useLiveLineBelow } from "./liveLineBelow";
import { configureToolRunLook } from "./toolRunLook";
import { configureSentLook } from "./conversation/SentMessageLine";
import { configureInboxNoticeLook } from "./conversation/inboxNoticeLook";
import { configureMessageLineLook } from "./conversation/messageLineLook";
import { configureNoticeLook } from "./conversation/noticeLook";
import { mergeInboxNotices } from "./conversation/inboxNotice";
import { configureNativeSidebarPreviewVariant, configureSidebarPreviewVariant } from "./sidebarPreview";
import { cloudCredentialRecovery } from "./cloudCredentialRecovery";
import { cloudAgentLogin, localApiKeyLogin, SIGN_IN_ON_MACHINE } from "./cloudAgentLogin";
import { handoffTurns } from "./cloudHandoffTurn";
import { configureTurnActionsPlacement } from "./turnActionsPlacement";
import { archiveRow, markUnreadRow } from "./header/archiveRow";
import { archiveClosesTab, deleteClosesTab } from "./header/archiveClose";
import { afterDeleteDismiss } from "./header/deleteDismiss";
import { DeleteChatDialog } from "./header/DeleteChatDialog";
import { avatarRows } from "./header/avatarRow";
import { agentAvatarChanged, removeAgentAvatar, setAgentAvatar, useAgentAvatar } from "./agentAvatar";
import { copyRow } from "./header/copyRow";
import { recordedConversationMarkdown } from "./conversation/exportMarkdown";
import { instructionsRow, projectFilesRow } from "./header/instructionsRow";
import { opensBesideRows, sideChatRow } from "./header/sideChatRow";
import { isCurrentMenuCommand, parseMenuCommand } from "./header/menuCommands";
import { errorRecovery, lastFailedTurn } from "./conversation/errorRecovery";
import { NewestSteerContext, takeBackSteer, takesSteersBack } from "./conversation/PendingSteer";
import { type WorkingCounts, WorkingCountsContext } from "./conversation/WorkingFor";
import { chatWaitsOn, WaitingOnContext } from "./conversation/waitingOn";
import { useTranscriptView, type TranscriptView } from "./conversation/transcriptView";
import { isWorkedFold, NO_FOLD_TOGGLES, viewFolds, type Folds } from "./conversation/viewFolds";
import { callsToHold, foldsToHold, linedCallOf, withHeldFolds, withoutHeldCalls } from "./conversation/turnEndHold";
import { type HarnessHealth, HarnessHealthNotice, type UpdateOffer, UpdateOfferContext } from "./HarnessHealthNotice";
import { Notice, NoticeSlot } from "./NoticeSlot";
import { AutoResumeNotice } from "./AutoResumeNotice";
import { type ForumRule, forumRules, RulesNotice } from "./RulesNotice";
import { type SignIn, SignInContext, signedOutHarnesses, useSignIn } from "./signIn";
import { ACCESS_ACTIONS, type AccessOffer } from "./accessOffer";
import { type ChatAccounts, ChatAccountsContext, ownRouteOf, readChatAccounts } from "./chatAccounts";
import { HostError, HostUnavailableLine, HostWaitingLine } from "./HostError";
import { hostLineText } from "./hostLine";
import {
  AcpmuxRestartGate,
  hostErrorShows,
  hostIsReconnecting,
  hostRefusedTooLarge,
  nextRetryDelay,
  offersAcpmuxRestart,
} from "./hostRetry";
import { ShellRuns, shellContextAttachments, withShellRows } from "./shell/shellRuns";
import { type Subagent } from "./subagents/subagentFold";
import { restartOwner, restartPrompt, restartReaches } from "./subagents/restart";
import { type SubagentRows, childView, runningGroups, subagentRowsFrom, subagentsIn } from "./subagents/subagentRows";
import { knownMark } from "../shared/AgentMark";
import {
  SubagentHarnessContext,
  SubagentNavContext,
  SubagentPaneContext,
  SubagentClockContext,
  SubagentStopContext,
  SubagentViewsContext,
  running,
} from "./subagents/SubagentGroup";
import { useEscapeClosesSubagent } from "./subagents/subagentEscape";
import { endedEditRow, markRows, type RowMarks } from "./rowMarks";
import { ShellActionsContext, type ShellActions } from "./shell/ShellRow";
import { SwitchNotice } from "./SwitchNotice";
import { BACKGROUND_NOTICE_TEXT, useBackgroundNotice } from "./conversation/backgroundNotice";
import { InstructionsNotice, type InstructionsFailure } from "./header/InstructionsNotice";
import { FolderChoice, showsFolderChoice } from "./FolderChoice";
import { ownMachineFolders, type ExtraFolderDraft } from "./extraFolders";
import { type FolderAsk, WorktreeFailure, confirmFolder, newWorktree, pickFolder } from "./startFolder";
import { NewTabFolderAsk } from "./NewTabFolderAsk";
import { MissingFolder, chooseChatFolder } from "./missingFolder";
import { LiveChatChoice } from "./LiveChatChoice";
import { WatchBanner } from "./WatchBanner";
import { ManagedBanner } from "./ManagedBanner";
import { PaneNotices } from "./PaneNotices";
import { setPaneNotices } from "./paneNoticeStore";
import { chiefOf, isTakenOver, managedBy, managerDrivingUntil, takeOverManaged } from "./managedBy";
import { HandoffReviewMessage } from "./handoff/ReviewMessage";
import { handoffStrings } from "./handoff/strings";
import type { HandoffReviewInput } from "./handoff/review";
import {
  CMUX_PASS_THROUGH,
  CmuxCommandRefused,
  cdFolder,
  continueTargets,
  cmuxCommandRefusal,
  mergedCommands,
  resolveHarnessTarget,
  type CmuxCommand,
  type CmuxCommandResult,
} from "./cmuxCommands";
import { canContinueIn, reviewingHandoff } from "./handoff/continueIn";
import { importedPrompt, parseImportedSession } from "./importSession";
import { useCheckpoints } from "./checkpoints/controller";
import { PermissionPanel } from "./permissions/Panel";
import { groupAskedCalls, withoutAskedCalls } from "./permissions/askRows";
import { withoutQuietThoughts } from "./conversation/thoughts";
import type { PermissionDecision } from "./permissions/protocol";
import { checkpointStrings } from "./checkpoints/strings";
import { QUICK_MESSAGES, readSurface, useEscapeToDismiss, type PaneSurface } from "./paneSurface";
import { QuickSurface } from "./QuickSurface";
import { chiefDock } from "./chiefDock.experiment";
import { contextAttachment, floatingStatus, type QuickFloating } from "./FloatingChat";
import { designSelectionChips, designSelectionRemovals } from "./designSelection";
import { setFloatingState, useFloatingState } from "./floatingState";
import { FailedSendsContext, type FailedSends } from "./conversation/PromptDelivery";
import { failedRuns, failedSendText, type FailedRun } from "./sendFailure";
import { clientWaiter, lostPrompt, resentAfterLoss } from "./lostPrompt";
import { ReplayScreen } from "./replay/ReplayScreen";
import { sessionReplay } from "./replay/replay.experiment";
import { useSideSessions } from "./aside/sideSessions";
import { BtwNotes } from "./aside/btwNotes";
import { askBtwQuestion } from "./btwCapability";
import { isFastModeOption } from "./heldOptions";
import { setSuggestedTasks } from "./offer/offersShown";
import { offerWorktree } from "./offer/offerWorktree";
import { queueingOn, setQueueing } from "./queueing";
import { NO_MENTIONS, StartedMentionsContext, type StartedMentions } from "./started/StartedSessionCard";
import { type SessionHover, SessionHoverContext } from "./started/SessionHoverCard";
import { SessionHoverStore, withSessionIds } from "./started/sessionHover";
import { SubsessionStore, type Subsessions, subsessionRows } from "./subagents/subsessions";
import {
  type StartedCache,
  type StartedSession,
  offerChildren,
  spawnedSessions,
  sessionMentions,
  startedCardsShown,
  startedSessions,
  withStartedSessions,
} from "./started/startedSessions";
import { experimentArm } from "../../experiments/experiment";
import { setSessionStatus, useSessionStatus } from "./sessionStatus";
import { holdWebSwap, pageReleaseHold } from "../../pages/shared/webSwap";
import { useWebSwapHold } from "../../pages/shared/useWebSwapHold";
import { SandboxTab, sandboxAgent, sandboxPageRefusal, sandboxRetryable, type RunMode } from "./sandboxRun";
import { SandboxRunView } from "./SandboxRunView";
import { PaneFeatureTips } from "./featureTips";
import { withCloudMachineSummary } from "./cloudSummary";
import { callNative } from "./callNative";
import { type MeasurableRenderer, type NativeRegistry, type OpenDiff } from "./rows/rowProps";
import { editQueued, openOfferChat, openSenderChat } from "./rows/rowActions";
import { PermissionAsk } from "./rows/PermissionAsk";

import { defaultRegistry } from "./rows/registry";
import { NO_ROWS, type ScrollAnchor, VirtualTranscript, rowKind } from "./VirtualTranscript";
export { FOLLOW_BOTTOM_DEADBAND_PX, SCROLL_ANCHOR_SETTLE_MS, VirtualTranscript } from "./VirtualTranscript";
export type { ScrollAnchor } from "./VirtualTranscript";
export { readOnlyRegistry } from "./rows/registry";

/// The changes view comes in its own chunk (bd cx-z9kz0): it carries the diff and file-tree
/// packages, which a New Tab page never shows, so the page's first script parses without them.
/// It starts loading once the page has painted, with the transcript's highlighted code and edit
/// cards (conversation/CodeBlock.tsx, conversation/EditDiff.tsx), so opening it waits on nothing.

declare global {
  interface Window {
    cmuxAcpmuxBridge?: {
      receive(snapshot: AcpmuxSnapshot): void;
      /** Sets or toggles the inspector and returns its next visibility. */
      toggleInspector(open?: boolean): boolean;
      applyTheme(theme: Record<string, unknown>): void;
      applyCustomization(customization: {
        themeCSS?: string;
        registryJS?: string;
        layout?: Record<string, unknown>;
      }): void;
      /// An app action for the page (CmuxNextAgentPane AgentPaneView), such as "continueIn".
      command?(name: string, sessionId?: string): void;
      /// Copy Last Code Block (Opt-Cmd-;): the app reads the block and writes the pasteboard itself,
      /// since a script it runs here is no gesture the page's clipboard accepts.
      lastCodeBlock?(): string | null;
      /// Copy Conversation as Markdown: read recorded history on this page's connection; the native
      /// palette action writes the role-headed, tool-folded text to the pasteboard.
      conversationMarkdown?(): Promise<string | null>;
      /// The app's shortcuts as the user bound them, keyed by action id (shortcuts.ts).
      applyShortcuts?(labels: Record<string, string>): void;
      /// Preview features on or off (Settings > Advanced > Labs, `labs.previewFeatures`, off by
      /// default): the session coverage label.
      applyPreview?(on: boolean): void;
      /// How a Cloud start goes (cloudStartProgress.ts `cloudStartPushed`): `{key, step?, machine?,
      /// size?, secrets?, network?}` for the start `cloud.startChat {key}` began.
      cloudStartProgress?(push: unknown): void;
      /// Experimental workflow summary/detail (Labs), separate from environment preview and off by default.
      applyWorkflowLabs?(on: boolean): void;
      /// The native Debug Settings baseline for the sidebar latest-reply preview.
      applySidebarPreviewVariant?(variant: unknown): void;
      /// Claude Code desktop's in-session status (the live plan card) on or off: the
      /// Debug Settings toggle `agent.sessionStatus`, off by default (sessionStatus.ts).
      applySessionStatus?(on: boolean): void;
      /// Session `sessionId`'s avatar was set or removed in some pane: ask for it again (agentAvatar.ts).
      agentAvatarChanged?(sessionId: string): void;
      /// Suggested tasks on or off (Settings > Suggest Follow-Up Tasks, on by default, or the Debug
      /// toggle `agent.suggestedTasks` forcing them on): an agent's offers draw as the suggested tasks
      /// card (offer/offersShown.ts).
      applySuggestedTasks?(on: boolean): void;
      /// Session Info's Remote Control switch, `{on}` or null (remoteControl.ts), on the legacy host.
      applyRemoteControl?(value: unknown): void;
      /// The app's notices about the chat's agent service (paneNoticeStore.ts), on the legacy host.
      applyPaneNotices?(value: unknown): void;
      applyHeaderState?(state: unknown): void;
      /// The pane's tab row the header's tools may sit in (header/tabRow.ts).
      applyTabRow?(row: unknown): void;
      /// Start Agent's floating chat (floatingState.ts, cx-b9qi).
      applyFloatingState?(state: unknown): void;
      /// The newest device chats for the New Tab cards (newtab/deviceChats.ts).
      applyDeviceChats?(chats: unknown): void;
      /// The newest recently closed items for the New Tab page (newtab/recentlyClosed.ts).
      applyRecentlyClosed?(items: unknown): void;
      /// What plays, for the New Tab page's player (newtab/nowPlaying.ts); null while nothing does.
      applyNowPlaying?(track: unknown): void;
      /// The app's read-aloud state (conversation/readAloud.ts): `{id}`, the message it reads or null.
      applyReadAloud?(state: unknown): void;
      /// The tabs agents marked as needing the person, for Needs you (needsYou/attentionTabs.ts).
      applyAttentionTabs?(tabs: unknown): void;
      /// Scrolls to a turn a `cmux://session/<id>#turn-<turnId>` link names (links.ts), once its row
      /// renders; gives up quietly after a few seconds.
      revealTurn?(turnId: string): void;
      /// A dictation change from the host (CmuxNextAgentPane AgentPaneDictation), spliced at the prompt's cursor.
      dictation?(update: DictationUpdate): void;
      /// A design mode highlight from a browser pane (CmuxNextAgentPane AgentPaneDesignSelection):
      /// its chips join the composer and go with the next message (designSelection.ts).
      designSelection?(selection: unknown): void;
    };
    cmuxAcpmuxRegistry?: {
      register(
        kind: string,
        renderer: MeasurableRenderer,
        options?: { measure?: (row: AcpmuxRow, width: number) => number },
      ): void;
      configure(options: Record<string, unknown>): void;
    };
    cmuxAcpmuxDebug?: AcpmuxDebug;
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    /// Mock mode only: a recorded turn the in-page daemon replays (webviews/scripts/agent-pane).
    cmuxAcpmuxMockScript?: MockScript;
    React?: typeof React;
  }
}

function emptySnapshot(): AcpmuxSnapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "connecting",
    isWorking: false,
    queue: [],
    catalog: [],
    canLoadOlder: false,
  };
}

/// The latest snapshot, kept for a reload of the page (`cachedSnapshot`). A streaming reply sends
/// one a display frame, and serializing the whole transcript each frame took main-thread time that
/// grew with the chat: it is written at most every SNAPSHOT_SAVE_MS, and at once as the page hides
/// or unloads, so a reload still finds the latest one.
const SNAPSHOT_SAVE_MS = 250;
const snapshotSave: {
  next?: AcpmuxSnapshot;
  timer?: ReturnType<typeof setTimeout>;
  hooked?: boolean;
} = {};
function writeSnapshot(): void {
  clearTimeout(snapshotSave.timer);
  snapshotSave.timer = undefined;
  const next = snapshotSave.next;
  snapshotSave.next = undefined;
  if (!next) return;
  try {
    sessionStorage.setItem("cmux.acpmux.snapshot", JSON.stringify({ ...next, sessions: savedSessions(next) }));
  } catch {
    // Painting remains live when storage is unavailable or full.
  }
}

/// Whether the shown chat's turn ended between two renders (App.tsx `pane.tabState`): the same chat
/// went idle, or its client counted an end. Only the same chat counts; switching away from a working
/// chat is no turn end. A turn that started and ended between two renders (a hidden page's batch,
/// drawn as one render) shows in `turnsEnded` alone; a new client counts from 0, so any change to a
/// count above 0 is an end.
export type TurnState = { session?: string; working: boolean; turnsEnded?: number };
export function turnEndedBetween(last: TurnState, next: TurnState): boolean {
  if (last.session !== next.session) return false;
  if (last.working && !next.working) return true;
  return next.turnsEnded !== undefined && next.turnsEnded > 0 && next.turnsEnded !== last.turnsEnded;
}

/// The reload copy keeps the newest SAVED_SESSIONS chats of the list, and the shown chat with its
/// parent and its own sub-sessions and forks at any age. The whole list (3,055 chats on a busy
/// Mac) was serialized on every write and went past sessionStorage's 5 MB, so the copy was lost;
/// the live list replaces this one as soon as the watch reads it.
export const SAVED_SESSIONS = 200;
const savedList: { sessions?: readonly AcpmuxSessionEntry[]; shown?: string; saved: AcpmuxSessionEntry[] } = {
  saved: [],
};
export function savedSessions(snapshot: AcpmuxSnapshot): AcpmuxSessionEntry[] {
  const { sessions, sessionId: shown } = snapshot;
  if (sessions.length <= SAVED_SESSIONS) return sessions;
  // A streaming reply writes with the list unchanged: it is chosen again only when it changes. Each
  // snapshot maps the list into a new array of the same cached entries (direct.ts `sessionEntries`),
  // so the entries are compared, not the array.
  const last = savedList.sessions;
  if (
    savedList.shown === shown &&
    last?.length === sessions.length &&
    (last === sessions || sessions.every((entry, index) => entry === last[index]))
  )
    return savedList.saved;
  const at = (entry: AcpmuxSessionEntry) => entry.activityAt ?? entry.updatedAt ?? 0;
  const newest = new Set(
    sessions
      .map((entry, index) => ({ at: at(entry), index }))
      .sort((a, b) => b.at - a.at)
      .slice(0, SAVED_SESSIONS)
      .map(({ index }) => index),
  );
  const own = sessions.find((entry) => entry.sessionId === shown);
  const kin = new Set([own?.parentId, own?.spawnedBy, own?.startedBy]);
  const related = (entry: AcpmuxSessionEntry) =>
    shown !== undefined &&
    (entry.sessionId === shown ||
      kin.has(entry.sessionId) ||
      entry.parentId === shown ||
      entry.spawnedBy === shown ||
      entry.startedBy === shown);
  const saved = sessions.filter((entry, index) => newest.has(index) || related(entry));
  Object.assign(savedList, { sessions, shown, saved });
  return saved;
}
export function saveSnapshot(next: AcpmuxSnapshot): void {
  snapshotSave.next = next;
  if (!snapshotSave.hooked && typeof window !== "undefined") {
    snapshotSave.hooked = true;
    window.addEventListener("pagehide", writeSnapshot);
    document.addEventListener("visibilitychange", () => document.visibilityState === "hidden" && writeSnapshot());
  }
  snapshotSave.timer ??= setTimeout(writeSnapshot, SNAPSHOT_SAVE_MS);
}

function cachedSnapshot(): AcpmuxSnapshot {
  try {
    const value = JSON.parse(sessionStorage.getItem("cmux.acpmux.snapshot") ?? "null");
    if (value?.type === "snapshot" && Array.isArray(value.rows) && Array.isArray(value.sessions)) {
      acpmuxPerf.markAgent("snapshotPaint");
      // `connection`, `drewKeptTail`, `chatRead` and `turnsEnded` are facts about a live client, and this one is
      // restored: no client has drawn anything yet, so this document's first paint is its own to report.
      return {
        ...emptySnapshot(),
        ...value,
        connection: "connecting",
        drewKeptTail: undefined,
        chatRead: undefined,
        turnsEnded: undefined,
      };
    }
  } catch {
    // A corrupt or unavailable session store must never block the pane.
  }
  return emptySnapshot();
}

/// A page action: the connected client's (chat actions run against acpmux), else the native host.
/** Saves the inspector's export through the host's save panel (`pane.saveLog`): true is saved, false a cancelled panel. A host without it, or one that refuses the log, leaves the inspector to copy it. */
export async function saveLogNatively(text: string, suggestedName: string): Promise<ExportOutcome> {
  try {
    return (await callNative<boolean>("pane.saveLog", { text, suggestedName })) === true ? "saved" : "cancelled";
  } catch {
    return "unavailable";
  }
}

/** Saves a side panel document through the host's save panel (`pane.saveFile`); a host without one, or a failed write, is unavailable (the panel copies the document instead). */
const saveDocumentNatively: SaveDocument = async (text, suggestedName, kind) => {
  try {
    return (await callNative<boolean>("pane.saveFile", { text, suggestedName, kind })) === true ? "saved" : "cancelled";
  } catch {
    return "unavailable";
  }
};

/// A start the host refused with a typed code: a chat on another machine (`agent_session.*`, the
/// session daemon's agent-session-start). A trust refusal has its own question.
function isStartRefusal(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" && code.startsWith("agent_session.") && !isTrustRefusal(error);
}

/// The machine a refused handshake names (`details.machineName`), for the composer's chip.
function refusedMachine(error: unknown): string | undefined {
  const details = (error as { details?: unknown } | null)?.details;
  const name = details && typeof details === "object" ? (details as { machineName?: unknown }).machineName : undefined;
  return typeof name === "string" && name ? name : undefined;
}

/// The failed prompt rows a failure card's action names: its run's (`rowIds`), else its own.
function failedRowIds(rowId: unknown, rowIds: unknown): string[] {
  if (Array.isArray(rowIds) && rowIds.length) return rowIds.map(String);
  return [String(rowId)];
}

/// Whether a failed send's prompt stays in the chat, never back in the composer: its failed row,
/// or the transcript, which drew it once acpmux took it (direct.ts `send`).
function keptInChat(error: unknown): boolean {
  return failedRowOf(error) !== undefined || (error as { taken?: unknown } | null)?.taken === true;
}

/// Stops the shown chat's turn; refused while the pane cannot reach acpmux (stopThroughReconnect.ts).
const cancelTurn = () => callNative<unknown>("chat.cancel");

/// Withdraws a queued prompt before its turn starts; false when it already started.
const removeQueued = (promptId: string) =>
  callNative<{ removed?: boolean } | null>("chat.queue.remove", { promptId }).then(
    (result) => result?.removed === true,
  );

/// Sends a prompt that waited for a new chat; settles once acpmux took it (its turn's later failure
/// is the transcript's), and rejects when it was refused before. One acpmux refused for the folder's
/// trust that joined the pane's hold (`holdRefused`) counts as taken: it waits in the queue now.
const sendWhenTaken = (steer: boolean) => (text: string, attachments: ComposerAttachment[]) =>
  new Promise<void>((resolve, reject) => {
    callNative("chat.send", { text, attachments, accepted: () => resolve(), steer }).then(
      () => resolve(),
      (error: unknown) => (heldRefusal(error) ? resolve() : reject(error)),
    );
  });

/// Keeps the current gesture for prompt `promptId`, which the folder's trust holds (trustHeld.ts).
const reserveHeldPrompt = (promptId: string) =>
  postNative<{ ticket?: string }>("transport.gesture", {
    intent: { method: "session/prompt", params: { promptId } },
  }).then((reply) => reply?.ticket);

/// acpmux's trust refusals of prompts that joined the pane's hold (`holdRefused`): the composer that
/// sent one lets it go, as if acpmux took it, since it waits in the queue now.
const heldRefusals = new WeakSet<object>();
const heldRefusal = (error: unknown) => typeof error === "object" && error !== null && heldRefusals.has(error);
/// The Trust re-run of a refusal whose prompt the pane's hold owns: none, since the hold sends it
/// after Trust. It replaces the step a refused start kept (`client.create`'s), which would start a
/// second chat beside the hold's own send.
const heldGoesAfterTrust = () => undefined;
/// Where a prompt was sent: the chat and its folder (a new chat's picked one), as trustHeld.ts keeps them.
type SentFrom = { chat: string | undefined; cwd: string | undefined };
/// A send of a prompt the folder's trust held: its id and its send's ticket (in-page only).
type HeldSend = { promptId: string; ticket?: string };
function heldPromptParams(value: unknown): HeldSend | undefined {
  const held = value as { promptId?: unknown; ticket?: unknown } | null | undefined;
  if (typeof held?.promptId !== "string") return undefined;
  return { promptId: held.promptId, ...(typeof held.ticket === "string" ? { ticket: held.ticket } : {}) };
}

/// `promise`'s value, or undefined once `until` (a Date.now() time) passes first.
const settledBy = <T,>(promise: Promise<T>, until: number): Promise<T | undefined> =>
  Promise.race([promise, new Promise<undefined>((settled) => setTimeout(settled, Math.max(0, until - Date.now())))]);

/// A guest's queued prompt (held for the owner, or approved and waiting): a person's, drawn on its own.
const isPersonQueuedRow = (row: AcpmuxRow) => Boolean(row.queuedMessage?.person || row.queuedMessage?.held);

/// The owner's Approve or Decline of a guest's held prompt (conversation/QueuedMessageCard.tsx).
const answerHeld = (promptId: string, approve: boolean, revision?: number): Promise<HeldAnswer> =>
  callNative(approve ? "chat.queue.approve" : "chat.queue.decline", {
    promptId,
    ...(approve && revision !== undefined ? { revision } : {}),
  }).then(
    () => "ok",
    (error: { reason?: unknown } | null) =>
      error?.reason === "queue.stale" ? "stale" : error?.reason === "queue.not_found" ? "gone" : "failed",
  );

/// The width the header's tools take in the pane's tab row, so the App narrows the tabs (header/tabRow.ts).
const reportTabRowTools = (width: number) => void callNative("pane.tabRowTools", { width }).catch(() => undefined);
/// Hands the host a new chat's typed text, kept with its tab across a relaunch (cx-z5vd).
/// The composer's text changed: the chat tells acpmux this pane types (never the text itself).
const postTyping = (text: string, sessionId?: string) =>
  void window.cmuxAcpmuxActions?.["chat.typing"]?.({ text, sessionId }).catch(() => undefined);
const postUnsentDraft = (text: string) => callNative("chat.unsentDraft", { text }).catch(() => undefined);
/// The new chat's typed text, its prompts held for a trust answer, and held ones given back that no
/// composer took (`kept`, a new chat in another folder by then): the host keeps them all, so a held
/// prompt outlives the tab moving to another chat or folder as typed text does.
const newChatDraft = { typed: "", held: [] as string[], kept: [] as string[] };
const postNewChatDraft = () =>
  postUnsentDraft(
    [...newChatDraft.kept, ...newChatDraft.held, newChatDraft.typed].filter((part) => part.trim()).join("\n\n"),
  );
/// Each chat's unsent chips, kept by the host so reopening or restoring the chat brings them back
/// (AgentPaneDraftAttachments.swift). A host without the store (the gallery, an older app) keeps none.
const keptAttachments: KeptAttachments = {
  read: (sessionId) =>
    callNative<unknown>("chat.draftAttachments.get", { sessionId }).then(
      (kept) => (Array.isArray(kept) ? (kept as ComposerAttachment[]) : []),
      () => [],
    ),
  write: (sessionId, attachments) =>
    callNative<{ held?: unknown } | null>("chat.draftAttachments", { sessionId, attachments }),
};
/// The host names the tab a page a tab adopted after its handshake now is (``setSessionInfoTab``).
const PANE_TAB_EVENT = "acpmux-pane-tab";
/// Where chat `sessionId` rests, kept by its tab so a relaunch reopens it there (cx-6bgzj): the host
/// knows the pane's tab and keeps the place under it (AgentPaneScrollAnchors.swift).
const postScrollAnchor = (sessionId: string, anchor: ScrollAnchor | null) => {
  const place = { sessionId, rowId: anchor?.rowId ?? null, offset: anchor?.offset ?? 0 };
  const write = anchorWrites.get(sessionId) ?? {
    sent: 0,
    kept: 0,
    inFlight: 0,
    failed: false,
    place,
  };
  write.place = place;
  anchorWrites.set(sessionId, write);
  sendScrollAnchor(write);
};
type AnchorWrite = {
  /// The newest place sent and the newest one the host answered for (`kept` behind `sent`: not kept yet).
  sent: number;
  kept: number;
  inFlight: number;
  /// The newest write was refused: the next ask sends it again.
  failed: boolean;
  place: { sessionId: string; rowId: string | null; offset: number };
};
/// Per chat, so one chat's write never stands in for another's.
const anchorWrites = new Map<string, AnchorWrite>();
const sendScrollAnchor = (write: AnchorWrite) => {
  const n = ++write.sent;
  write.failed = false;
  write.inFlight += 1;
  void callNative("chat.scrollAnchor", write.place)
    .then(
      () => {
        if (n === write.sent) write.kept = n;
      },
      () => {
        if (n === write.sent) write.failed = true;
      },
    )
    .finally(() => {
      write.inFlight -= 1;
    });
};
// WEB-SWAP: a web update's reload reopens the chat at the kept place, so it waits for the newest
// one to be kept. A refused one goes again on the next ask (pages/shared/webSwap.ts).
holdWebSwap(() => {
  let reason: string | null = null;
  for (const write of anchorWrites.values()) {
    if (write.kept >= write.sent) continue;
    if (write.failed && write.inFlight === 0) sendScrollAnchor(write);
    reason = "transcript.place-unsaved";
  }
  return reason;
});
/// A host that does not answer `chat.scrollAnchor.get` (the gallery, an older app) never holds up the chat.
const SCROLL_ANCHOR_READ_MS = 250;
/// The longest a chat the handshake named keeps the host's loading state up for acpmux's attach. A
/// last resort only: the page reports its first paint once the chat's rows are in (`chatRead`) or
/// its open failed. A shorter hold showed a busy daemon's chat as an empty page with only its
/// composer (Leo 2026-10-21: "I LOAD IN AND IT'S A BLACK SCREEN").
const CHAT_DRAW_HOLD_MS = 10_000;
/// Where chat `sessionId` rested when it was last shown; undefined when nothing is kept.
const fetchScrollAnchor = async (sessionId: string): Promise<(ScrollAnchor & { sessionId: string }) | undefined> => {
  const anchor = await Promise.race([
    callNative<{ rowId?: unknown; offset?: unknown } | null>("chat.scrollAnchor.get", {
      sessionId,
    }).catch(() => null),
    new Promise<null>((resolve) => setTimeout(() => resolve(null), SCROLL_ANCHOR_READ_MS)),
  ]);
  return typeof anchor?.rowId === "string" && typeof anchor.offset === "number"
    ? { sessionId, rowId: anchor.rowId, offset: anchor.offset }
    : undefined;
};

/// The handshake's `wake` (AgentPaneWakeState.swift): what a released page held that acpmux does not.
/// `scrollAnchor`: the transcript's place, null at its latest message, undefined when unknown.
function readWake(
  value: unknown,
): { composer: ComposerWake; scrollAnchor?: ScrollAnchor | null; subagentDrafts?: unknown } | undefined {
  if (!value || typeof value !== "object") return undefined;
  const wake = value as {
    attachments?: unknown;
    shell?: unknown;
    shellText?: unknown;
    scrollAnchor?: unknown;
    atLatest?: unknown;
    subagentDrafts?: unknown;
  };
  const anchor = wake.scrollAnchor as { rowId?: unknown; offset?: unknown } | null | undefined;
  return {
    composer: {
      attachments: Array.isArray(wake.attachments) ? (wake.attachments as ComposerAttachment[]) : undefined,
      shell: wake.shell === true,
      shellText: typeof wake.shellText === "string" ? wake.shellText : undefined,
    },
    scrollAnchor:
      typeof anchor?.rowId === "string" && typeof anchor.offset === "number"
        ? { rowId: anchor.rowId, offset: anchor.offset }
        : wake.atLatest === true
          ? null
          : undefined,
    subagentDrafts: wake.subagentDrafts,
  };
}

/// Asks the host to show the Quick Composer's chat in a window.
const postOpenInWindow = (sessionId: string) =>
  void callNative(QUICK_MESSAGES.openInWindow, { sessionId }).catch(() => undefined);

/// The longest workspace name a background start asks for (AgentPaneQuickStart.maximumName).
const QUICK_NAME_LIMIT = 80;

/// A started chat's workspace name: the prompt's first non-empty line, or none.
export function quickChatName(text: string): string | undefined {
  const line = text
    .split("\n")
    .map((part) => part.trim())
    .find((part) => part !== "");
  // By code point, so the cut never splits a surrogate pair.
  return line ? Array.from(line).slice(0, QUICK_NAME_LIMIT).join("") : undefined;
}

/// Asks the host to put the Quick Composer's started chat in the sidebar, in the background.
const postStartInBackground = (sessionId: string, cwd: string | undefined, name: string | undefined) =>
  void callNative(QUICK_MESSAGES.startInBackground, {
    sessionId,
    ...(cwd ? { cwd } : {}),
    ...(name ? { name } : {}),
  }).catch(() => undefined);

/// Folder trust lives with acpmux (or the mock daemon), else the native host.
/// Each harness's last health answer on this page (signed out, outdated, fine), drawn at once for
/// the next chat on that harness while it is read again (Leo 2026-10-19: the notice popped in late
/// and pushed the composer on each switch and reconnect).
const knownHarnessHealth = new Map<string, HarnessHealth | undefined>();

/// Each local folder's GitHub repository (`#123` links in the transcript) from its last read.
const knownGithubRepositories = new Map<string, string | undefined>();

const trustSource: TrustSource = {
  get: (cwd) => callNative("acp.trust.get", { cwd }),
  set: (cwd, level) => callNative("acp.trust.set", { cwd, level }),
};

// The composer's Hide and Show (composerChrome.tsx) persist through the host, which pushes the
// setting back to every page and on the next launch.
registerComposerHost((method, show) => callNative(method, { show }));
/// The tab this page is, for a page a tab adopted after its handshake (a prewarmed spare,
/// AgentPaneView+SessionAdopt.swift `announceTab`): Session Info is kept by it (sessionInfoState.ts).
if (typeof window !== "undefined")
  window.addEventListener(PANE_TAB_EVENT, (event) => {
    const tab = (event as CustomEvent<{ tab?: unknown }>).detail?.tab;
    if (typeof tab === "string" && tab) setSessionInfoTab(tab);
  });
registerAttachmentViewHost((view) => callNative("pane.setAttachmentView", { view }));
registerComposerRingHost((ring) => callNative("pane.setComposerRing", { ring }));
registerChatDisplayHost((key, value) => void callNative("pane.setDisplay", { key, value }).catch(() => undefined));
/// A folder's `git.status` from the native host, named by the folder: a new chat has no session to
/// name it by (the header's worktree pill, cx-lyqio.3b).
const readFolderStatus = (cwd: string) => postNative("git.status", { cwd });
/// A turn's checkpoint pair, diffed on the session host (`git.checkpoint.diff`).
const checkpointDiff: CheckpointDiff = (from, to) =>
  callNative("git.checkpoint.diff", { from, to, include_patch: true });

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
const sameItems = <T,>(a: readonly T[], b: readonly T[]) =>
  a.length === b.length && a.every((item, index) => item === b[index]);

const currentRegistry = (): NativeRegistry => ({
  ...defaultRegistry,
  ...(window.cmuxAcpmuxRegistry as unknown as NativeRegistry | undefined),
});

/// The index of the streaming reply's row when `next` differs from `drawn` only in that row's
/// text (HOT PATH AUDIT area F, row W1), else -1. Every other field compares by identity: the client
/// keeps the same objects while they do not change (direct.ts `publishedSummary`, `NO_CATALOG`,
/// subagentFold.ts `views`), so this is O(fields + rows), with no serialization. Drawn only while
/// the transcript draws that row as the client holds it (`drawsAsIs`) and no view that reads the
/// pane's rows is open (`streamingRowBlocked`).
function streamedOnly(drawn: AcpmuxSnapshot, next: AcpmuxSnapshot): number {
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
  const listedPeer = summary?.sessionId
    ? snapshot.sessions.find((session) => session.sessionId === summary.sessionId)?.peer
    : undefined;
  return snapshot.origin === "peer" || !!summary?.peer || !!listedPeer;
}

/// The native label of the mode the chat runs now when it is its family's highest (Claude Code's
/// Bypass permissions, Codex's Full access), else nothing.
function fullAccessModeName(summary: AcpmuxSnapshot["summary"]): string | undefined {
  const current = summary?.modes?.currentModeId;
  if (!current || highestMode(summary?.family, summary?.harness)?.id !== current) return undefined;
  return harnessModeName(summary?.family, summary?.harness, current);
}

/// The composer chips on the New Tab page (cx-e2aa): no chat exists yet, so a pick starts a deferred
/// switch to the shown agent in the page's project (`chat.new {deferred}`): acpmux starts the session
/// behind the page, which stays, and the pick lands on it (harnessSwitch keeps picks made while a
/// switch runs). Enter asks the same agent in the same folder, the same switch, which then shows.
export function NewTabComposerChips({
  snapshot,
  cwd,
  onAddAgent,
}: {
  snapshot: AcpmuxSnapshot;
  cwd?: string;
  onAddAgent?(): void;
}) {
  return <DefaultComposerChips snapshot={snapshot} cwd={cwd} onAddAgent={onAddAgent} startsChat />;
}

/// The chat's own composer chips, as the pane draws them under a chat (tests drive them directly).
export function ChatComposerChips({ snapshot }: { snapshot: AcpmuxSnapshot }) {
  return <DefaultComposerChips snapshot={snapshot} />;
}

/// The host closes a New Tab page (`AgentPaneView.discardUnsentChat`).
const NEW_TAB_CLOSE_EVENT = "acpmux-newtab-close";

function DefaultComposerChips({
  snapshot,
  cwd,
  onAddAgent,
  startsChat = false,
}: {
  snapshot: AcpmuxSnapshot;
  /// The folder a chat the chips start opens in (the New Tab page's project).
  cwd?: string;
  onAddAgent?(): void;
  /// The chips belong to a page with no chat yet: a model, mode or effort pick starts one first.
  startsChat?: boolean;
}) {
  const inFolder = startsChat ? { ...(cwd ? { cwd } : {}), deferred: true } : {};
  const harnessesPage = useHarnessesPage();
  const addAgent = onAddAgent ?? harnessesPage;
  const signIn = useSignIn();
  // acpmux has answered with its harnesses: only then can the chip say none is installed.
  const harnessesListed = useHarnessesListed();
  // `chat.new` for the same agent and folder is the switch already running, so a second pick
  // never restarts it.
  const start = () => {
    const harness = snapshot.summary?.harness;
    if (!startsChat || !harness || snapshot.summary?.sessionId) return;
    void callNative("chat.new", { harness, ...inFolder }).catch(() => undefined);
  };
  const picker = usePickerCatalog(
    snapshot.catalog,
    {
      harness: snapshot.summary?.harness,
      model: snapshot.summary?.model,
      configOptions: snapshot.summary?.configOptions,
    },
    snapshot.sessions,
  );
  const [refreshStatus, setRefreshStatus] = useState<"idle" | "fetching" | "updated" | "error">("idle");
  const refreshCatalog = useCallback(async () => {
    setRefreshStatus("fetching");
    try {
      await picker.refresh();
      setRefreshStatus("updated");
    } catch {
      setRefreshStatus("error");
      // l10n-allow: a developer error for the refresh caller; the picker shows refreshStatus, never this text.
      throw new Error("models.catalog refresh failed");
    }
  }, [picker]);
  return (
    <ComposerPickers
      snapshot={startsChat ? newTabChipSnapshot(snapshot, picker.catalog) : snapshot}
      startsChat={startsChat}
      // A New Tab pick is held once acpmux's actions are connected and the chat has a harness to
      // start (start() sends chat.new first); before that a pick would reach nothing.
      holdsModePick={
        snapshot.switching !== undefined ||
        (startsChat && !!snapshot.summary?.harness && window.cmuxAcpmuxActions?.["chat.new"] !== undefined)
      }
      // A Cloud or other remote machine's chat starts with its first send: until then its mode pick
      // is held for that start (Leo 2026-11-01: "i couldn't even pick a mode for this kind aqua
      // sandpaper one"), and once its agent reports its modes, their menu replaces this one.
      holdsStartMode={!startsChat && snapshot.origin === "remote" && !snapshot.summary?.sessionId}
      onModel={(modelId) => {
        start();
        void callNative("chat.model", { modelId });
      }}
      onMode={(modeId) => {
        start();
        return callNative("chat.mode", { modeId });
      }}
      onEffort={(configId, value) => {
        start();
        void callNative("chat.effort", { configId, value });
      }}
      onHarness={(harness, model, options) =>
        void callNative("chat.new", {
          harness,
          ...(model ? { model } : {}),
          ...(options ? { options } : {}),
          ...inFolder,
        })
      }
      // A started chat forks to another harness through Continue In… (Leo 2026-10-22: "need to be
      // able to switch to different harnesses, can expose as fork"): the chat menu's own path, its
      // review in this tab, then the new chat in a tab of its own. Not while a turn or queue runs.
      {...(!startsChat && snapshot.canHandoff
        ? {
            fork: {
              to: (harness: string) => void callNative("chat.handoff.prepare", { harness }).catch(() => undefined),
              // Continue In…'s own check: no fork while a review is open or no harness can take it.
              ready: canContinueIn(snapshot),
            },
          }
        : {})}
      {...(cwd ? { folder: cwd } : {})}
      // Sent from the pick's own handler: the host's Enable confirmation needs the gesture.
      onHarnessEnable={(folder, id) => void callNative("chat.harness.enable", { folder, id }).catch(() => undefined)}
      // Add harness… (the picker's last row; the chip itself with no harness): the Harnesses page,
      // in place, from this click's gesture.
      {...(addAgent ? { onAddAgent: addAgent } : {})}
      {...(signIn ? { signIn } : {})}
      harnessesListed={harnessesListed}
      showPlan={false}
      pickerCatalog={picker.catalog}
      catalogRefresh={{ status: refreshStatus, date: picker.date, refresh: refreshCatalog }}
      // A prewarm hint for the direct client only: the native host has no daemon to warm.
      onHarnessHint={(harness) => void window.cmuxAcpmuxActions?.["chat.harness.hint"]?.({ harness })}
    />
  );
}

/** The same host theme before mount and on subsequent bridge pushes. */
export function applyPaneTheme(theme: Record<string, unknown>): void {
  applyAgentTheme(theme as never);
  configureChatWidth(theme.chatWidth);
  configureCodexToolRuns(theme.codexToolRuns);
  configureLiveLineBelow(theme.liveLineBelow);
  configureToolRunLook(theme.toolRunLook);
  configureSentLook(theme.sentLook);
  configureInboxNoticeLook(theme.inboxNoticeLook);
  configureMessageLineLook(theme.messageLineLook);
  configureNoticeLook(theme.noticeLook);
  configureTurnActionsPlacement(theme.turnActionsPlacement);
  configureSubagentTray(theme.subagentTray);
  configureSubagentTrayPlacement(theme.subagentTrayPlacement);
  configureSelectionReply(theme.selectionReply);
}

/** Install the user font/layout stylesheet before the first render when already known. */
export function applyPaneThemeCSS(themeCSS: string): void {
  let style = document.getElementById("acpmux-user-theme") as HTMLStyleElement | null;
  if (!style) {
    style = document.createElement("style");
    style.id = "acpmux-user-theme";
    document.head.append(style);
  }
  style.textContent = themeCSS;
}

/** Static preview boot state, not a production host handshake. The gallery still delivers the
 * snapshot through receive() after ready to initialize trust, harness and persistence state. */
export type InitialChat = {
  snapshot: AcpmuxSnapshot;
  machineName?: string;
  workflowLabs?: boolean;
};

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

function AcpmuxPane({ initialChat }: { initialChat?: InitialChat }) {
  // Debug measurement (acpmuxPerf): the pane's own render, before its children.
  const paneRenderStart = acpmuxPerf.enabled ? performance.now() : 0;
  acpmuxPerf.render("pane");
  const t = useT();
  const { scrollToBottomOnSend, newChatsIn } = useComposerSettings();
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
  /// What a chat opened from another tab inherited (#16620); the composer starts with it.
  const [draft, setDraft] = useState<string | undefined>();
  /// Where this New Tab page's new chat starts, as the app knew it when the page loaded
  /// (AgentPaneNewTabStart): the first frame draws its project or no project, with no acpmux round trip.
  const [injectedStart] = useState(() => startFromContext(injectedNewTabContext()?.start));
  const [newSession, setNewSession] = useState(injectedStart?.newSession === true);
  /// The chat whose recorded history plays back read-only in place of it (chat menu Replay, cx-osmw).
  const [replaying, setReplaying] = useState<string | undefined>();
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
  const [cloudRepositoryAvailable, setCloudRepositoryAvailable] = useState(false);
  const [cloudChatIdentity, setCloudChatIdentity] = useState<CloudChatIdentity>();
  // A fresh composer can select a paused Cloud machine before it has a session. Keep only that
  // explicit picker choice; never guess a machine from the account inventory. Null records a
  // non-Cloud destination and suppresses the previous identity while its handshake catches up.
  const cloudDraftMachineID = useRef<string | null | undefined>(undefined);
  // Whether `cloudChatIdentity` still names the chat shown (cloudIdentityKept): set by the
  // handshake that gave it, cleared when the pane moves to another chat or New Tab page.
  const cloudIdentityBound = useRef(false);
  const [cloudCredentialRecoveryAvailable, setCloudCredentialRecoveryAvailable] = useState(false);
  // A team Cloud machine its start passed no personal login to (handshake `cloudTeamMachine`): a
  // sign-in failure says so (failureCopy.ts isTeamMachineSignIn) and offers no login transfer.
  const [cloudTeamMachine, setCloudTeamMachine] = useState(false);
  // Automatic Cloud credential recovery survives turn-action memo rebuilds and is bounded per session.
  const automaticCloudCredentialAttempts = useRef<Set<string>>(new Set());
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
  const cloudComposeEligible = useRef(false);
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
  /// The pane's connected clients, one after another: a prompt a connection lost waits on the next
  /// one for the host's journal to send it again there (lostPrompt.ts).
  const [connectedClients] = useState(() => clientWaiter<AcpmuxDirectClient>());
  const [catalogSource, setCatalogSource] = useState<{ id: number; client: HarnessCatalogSource }>();

  /// A chat acpmux would not start because its folder harness needs the user's Enable or the
  /// folder's Trust answer first (`harness.needs_enable` / `harness.needs_trust`).
  const [blockedHarness, setBlockedHarness] = useState<HarnessBlock | undefined>();
  // The chat's folder on this Mac, whose own harness profiles the catalog then lists too; while a
  // folder harness waits for Enable or Trust (a new chat without a session), that harness's folder.
  const catalogCwd =
    clientSnapshot.summary?.hostKind !== "cloud" && !clientSnapshot.summary?.host
      ? (clientSnapshot.summary?.cwd ?? projectDraft ?? blockedHarness?.folder) || undefined
      : undefined;
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
  // The client's own snapshot never carries the catalog: every view of the pane (the Harnesses
  // page, the picker catalog, the composer) reads the fetched one from here.
  const snapshot = useMemo(
    () =>
      applySwitch(
        catalog === clientSnapshot.catalog ? clientSnapshot : { ...clientSnapshot, catalog },
        switchView,
        catalog,
      ),
    [clientSnapshot, switchView, catalog],
  );
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
  // The person's own queued prompts: another agent's message never draws in the composer's queue.
  const queueIds = useMemo(() => ownQueue(snapshot.queue).map((entry) => entry.id), [snapshot.queue]);
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
  const [backgroundPanel, setBackgroundPanel] = useState<{
    sessionId?: string;
    expanded: boolean;
    dismissed: ReadonlySet<string>;
  }>();
  if (backgroundPanel && snapshot.sessionId !== backgroundPanel.sessionId) setBackgroundPanel(undefined);
  /// This page is the chat's Background tasks tab in the right column (a `subagent:` reveal of the
  /// reserved pane id, backgroundTasks/backgroundPane.ts): it shows the panel alone, filling the tab.
  const [ownBackgroundPane, setOwnBackgroundPane] = useState(false);
  if (ownBackgroundPane && !backgroundPanel && snapshot.sessionId)
    setBackgroundPanel({ sessionId: snapshot.sessionId, expanded: false, dismissed: new Set<string>() });
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
        : (renderVersions(pages, current) ??
          artifactVersions(
            artifactRows.flatMap((row) => (row.kind === "assistant" && !row.streaming && row.text ? [row.text] : [])),
            current,
          ))
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
  /// Moves when the view follows again with commands held out, so they go back into their runs.
  const [callRelease, releaseCalls] = useReducer((count: number) => count + 1, 0);
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
  const reveal = (value: string) => {
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
  const forkSeq = latestForkSeq(snapshot.rows);
  const forkAny = forksAnyTurn(snapshot.summary?.family);
  // Edit and resend (cx-ncc.60): rebuilt when the editable prompts change, not on every streamed row.
  // A running chat still permits editing an earlier completed prompt: editResend forks through that
  // prompt's preceding turn, leaving this branch running while the edited sibling starts its own turn.
  // Keep the same served/connected gate as ordinary forks, but do not use `forkable`, which excludes
  // a working chat (Leo, 2026-10-24).
  const editsServed = snapshot.canFork && connected && !snapshot.summary?.peer;
  const lastEditTurns = useRef<EditableTurns | undefined>(undefined);
  const rowsForEdits = editsServed ? snapshot.rows : NO_ROWS;
  const editFamily = snapshot.summary?.family;
  const stableEditSeqs = useMemo(
    () => (lastEditTurns.current = trackEditableTurns(rowsForEdits, editFamily, lastEditTurns.current)).seqs,
    [rowsForEdits, editFamily],
  );
  // Each prompt's own turn, for the Fork under its bubble; rebuilt only when the turns change.
  const promptSeqsKey = editableKey(promptTurns(forkable ? snapshot.rows : []));
  const stablePromptSeqs = useMemo(() => editableSeqs(promptSeqsKey), [promptSeqsKey]);
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
  const healthHarness = composerHealthHarness(snapshot, pickerCatalog);
  const healthLocal =
    !snapshot.summary?.peer &&
    snapshot.summary?.hostKind !== "cloud" &&
    (snapshot.sessionId !== undefined || !directClient.current?.newChatPeer());
  /// `harness.health {id, refresh?, rescan?}` answered by this Mac's acpmux (the Harnesses page asks
  /// it by that name); `{}` for a chat on another machine, whose CLIs are not this Mac's, and while
  /// the pane has no acpmux connection. Stable per chat: the Harnesses page re-reads when it changes.
  const readHarnessHealth = useCallback(
    async (params: Record<string, unknown>): Promise<{ health?: HarnessHealth | null }> => {
      const client = directClient.current;
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
    if (!healthHarness || !healthLocal) {
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
  }, [connected, healthHarness, healthLocal, healthRecheck, readHarnessHealth]);
  // Another chat's harness draws its last known health in this render (no notice popping in late).
  const harnessHealth =
    healthHarness && healthLocal
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
  const signedOutRechecked = useRef(0);
  useEffect(() => {
    const client = directClient.current;
    if (!connected || !client || !healthLocal) {
      setSignedOut({});
      return;
    }
    let live = true;
    // After a Log In, acpmux checks again: its last rows would still say signed out.
    const refresh = healthRecheck !== signedOutRechecked.current;
    signedOutRechecked.current = healthRecheck;
    void Promise.resolve()
      .then(() => client.harnessHealthRows(refresh ? { refresh: true } : {}))
      .then((rows) => live && setSignedOut(signedOutHarnesses(rows)))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [connected, healthLocal, healthRecheck, catalogSource]);
  // The forum's current rules on this Mac (hq#2570), pinned above the composer: read when the pane
  // connects or opens a chat, and at each turn's start and end, when the chat's agent is told the
  // rules it has not read yet. A chat on another machine or in the cloud gets none.
  const [rules, setRules] = useState<ForumRule[]>([]);
  const turnWorking = snapshot.isWorking;
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
        void callNative("action.run", { id: ACCESS_ACTIONS.addCredits }).catch(() =>
          directClient.current?.notice(translate("composer.offloadNotRun", { action: translate("access.addCredits") })),
        ),
    }),
    [],
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
    : healthHarness && healthLocal
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
        void sessionLogin(auth, (params) => callNative("tab.open", params), snapshot.summary?.cwd).catch(
          () => undefined,
        );
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
  // Search files reads the session's folder through whoever runs the session: the acpmux
  // client (or the mock daemon), else the native host.
  const fileRoot = snapshot.summary?.cwd;
  // The + menu's Attach Screenshot… and Attach Window… (cx-ncc.71): the host runs macOS
  // screencapture's own pick and answers the PNG; a cancelled pick answers no data, and a capture
  // that would not fit the image cap answers `tooLarge` with its name.
  const captureScreen = useCallback(async (mode: "screen" | "window") => {
    const shot = await callNative<{
      name?: string;
      mimeType?: string;
      data?: string;
      tooLarge?: boolean;
      source?: unknown;
    } | null>("composer.capture", { mode }).catch(() => null);
    if (shot?.tooLarge) return { name: shot.name ?? "Screenshot.png", reason: "tooLarge" } as const;
    if (!shot?.data) return undefined;
    const bytes = Uint8Array.from(atob(shot.data), (char) => char.charCodeAt(0));
    // cmux took it: its chip wears cmux's icon (composer/attachmentSources.ts).
    const file = new File([bytes], shot.name ?? "Screenshot.png", { type: shot.mimeType ?? "image/png" });
    return withSource(file, attachmentSource(shot.source));
  }, []);
  const uploadFiles = useCallback(
    (files: File[], cancelled?: (index: number) => boolean, progress?: UploadProgressReport) =>
      uploadToMachine(files, callNative, cancelled, progress),
    [],
  );
  // A chat on this Mac links a dropped or pasted folder, or a file no block takes, where it is.
  const localPaths = useCallback((kind: DroppedKind, files: File[]) => droppedPaths(kind, files, callNative), []);
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
  // For callbacks that keep one identity (showSubagent names a pane's tab with it).
  const subagentTitleRef = useRef(subagentTitle);
  subagentTitleRef.current = subagentTitle;
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
  const childRows = useMemo(() => {
    if (workflowTranscript.rows) return workflowTranscript.rows;
    if (!subagentView) return undefined;
    if (!subagentTray) return childView(subagentView, snapshot.rows, snapshot.subagentViews, folds, chatName);
    const view = childView(subagentView, snapshot.rows, snapshot.subagentViews, NO_EXPANDED, chatName);
    return view && (withSubagentLines(view, childDoneLines.current, workflowLabsEnabled) as AcpmuxRow[]);
  }, [
    subagentView,
    snapshot.rows,
    snapshot.subagentViews,
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
  const askedToolCalls = useMemo(
    () => pendingToolCalls(snapshot),
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the asks' inputs, not the whole snapshot
    [snapshot.rows, snapshot.permission, snapshot.permissionGroups],
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
    // Each step's consecutive thoughts as one, and none that says nothing (conversation/thoughts.ts).
    return withoutQuietThoughts(rows, snapshot.isWorking);
  }, [snapshot.rows, snapshot.permissionGroups, individualPermission, snapshot.isWorking]);
  // A call the permission panel asks about is drawn by the panel's row while it waits
  // (withoutAskedCalls).
  const panelAsks = useMemo(() => groupAskedCalls(snapshot.permissionGroups), [snapshot.permissionGroups]);
  // Codex-style tool runs in a running turn (Debug toggle, codexToolRuns.ts).
  const codexRuns = useCodexToolRuns();
  // The running turn's status line as its last row (Debug toggle, liveLineBelow.ts).
  const lineBelow = useLiveLineBelow();
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
  const hoverStore = useRef<SessionHoverStore | null>(null);
  hoverStore.current ??= new SessionHoverStore();
  useLayoutEffect(() => {
    if (startedOn) hoverStore.current!.set(snapshot.sessions);
  }, [startedOn, snapshot.sessions]);
  const sessionHover = useMemo<SessionHover | null>(
    () => (startedOn ? { store: hoverStore.current!, open: openOfferChat } : null),
    [startedOn],
  );
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
      // A sender chip whose name acpmux resolves to no chat says so, in a notice line.
      senderMissing: (name: string) => directClient.current?.notice(translate("message.senderNotFound", { name })),
    }),
    [],
  );
  /// The Quick Composer panel (`"surface": "quick"` in the host's ready reply) or a tab's pane.
  const [surface, setSurface] = useState<PaneSurface>("pane");
  const quick = surface === "quick";
  // The last snapshot's turns and subagent rows: the next builds on them (turnViewFrom).
  const lastTurns = useRef<{ turns: TurnView; subagents: SubagentRows } | undefined>(undefined);
  /// Debug Settings `agent.sessionStatus`: a running turn's activity line under its todo list.
  const sessionStatus = useSessionStatus();
  const turnRowsShown = useMemo(() => {
    if (chatPresentation === "messages") return messagesRows(childRows ?? sourceRows);
    if (childRows) {
      return withoutAskedCalls(withoutQuietThoughts(childRows), panelAsks);
    }
    const startedRows = withStartedSessions(sourceRows, started, startedCache.current);
    // Labs: a Claude workflow is a card where it started (summary/WorkflowCard.tsx), not a tray line.
    const rows = subagentTray ? withSubagentLines(startedRows, doneLines.current, workflowLabsEnabled) : startedRows;
    // The tray takes the running groups out of the rows, so the live line's wait is counted first.
    const trayAgents = subagentTray ? trayWaitAgents(startedRows) : 0;
    return acpmuxPerf.timed("app.rows", () => {
      const last = lastTurns.current;
      if (heldCalls.current.session !== shownSessionId)
        heldCalls.current = { session: shownSessionId, keys: new Set() };
      // Null while the view follows the latest row: what was held out goes back in there. The view
      // following again with calls held (`callRelease`) shapes the rows again for that.
      void callRelease;
      const viewNow = transcriptInView.current?.();
      if (!viewNow && heldCalls.current.keys.size > 0) heldCalls.current = { ...heldCalls.current, keys: new Set() };
      const shapeFrom = (source: readonly AcpmuxRow[], open: Folds) =>
        turnViewFrom(
          source,
          open,
          {
            working: snapshot.isWorking,
            clockOffset: snapshot.clockOffsetMs,
            liveRuns: codexRuns,
            sessionStatus,
            lineBelow,
            // A finished turn folds as its harness family's app does: Codex under one Worked for, Claude per run.
            agentFamily: snapshot.summary?.family,
            // Other sessions' messages among them, two or more in a run, draw as one card.
            waitingSteers: snapshot.waitingSteers,
            messageBreaks,
            trayAgents,
          },
          last?.turns,
        );
      const shape = (open: Folds) => shapeFrom(withoutHeldCalls(rows, heldCalls.current.keys), open);
      // While the reader is scrolled up, an update that would fold away a row they have in view (a
      // turn's end folding its work, a run of calls closing) leaves that fold open
      // (conversation/turnEndHold.ts); the effect below puts it in `expanded`. The reader's own
      // toggles change `folds` and are left alone, as is a chat just switched to.
      const ownChange = foldsSeen.current.session !== shownSessionId || foldsSeen.current.folds !== folds;
      foldsSeen.current = { session: shownSessionId, folds };
      if (heldFolds.current.session !== shownSessionId)
        heldFolds.current = { session: shownSessionId, keys: new Set() };
      let turns = shape(withHeldFolds(folds, heldFolds.current.keys));
      const inView = ownChange ? null : transcriptInView.current?.();
      if (inView) {
        const held = foldsToHold(rows, turns.rows, last?.turns.rows, turns.reusedRows, inView, folds);
        if (held.length > 0) {
          heldFolds.current = { session: shownSessionId, keys: new Set([...heldFolds.current.keys, ...held]) };
          turns = shape(withHeldFolds(folds, heldFolds.current.keys));
        }
      }
      // A command the live line named out of its run, which it no longer names, stays out of the
      // run while the reader is scrolled up, as they saw it (turnEndHold.ts, cmux#33200).
      let lined = linedCallOf(turns.rows);
      // A held command that still runs and that the line would name again (a newer call took the
      // line and finished) goes back to the line, out of its run as before, so it never reads
      // nowhere: in neither its run nor the line. Shaped from every row only while one is held.
      if (snapshot.isWorking && heldCalls.current.keys.size > 0) {
        const again = linedCallOf(shapeFrom(rows, withHeldFolds(folds, heldFolds.current.keys)).rows);
        if (again !== undefined && heldCalls.current.keys.has(again)) {
          const keys = new Set(heldCalls.current.keys);
          keys.delete(again);
          heldCalls.current = { ...heldCalls.current, keys };
          turns = shape(withHeldFolds(folds, heldFolds.current.keys));
          lined = linedCallOf(turns.rows);
        }
      }
      const letGo = viewNow ? callsToHold(heldCalls.current.lined, lined, heldCalls.current.keys) : undefined;
      if (letGo !== undefined) {
        heldCalls.current = { ...heldCalls.current, keys: new Set([...heldCalls.current.keys, letGo]) };
        turns = shape(withHeldFolds(folds, heldFolds.current.keys));
        lined = linedCallOf(turns.rows);
      }
      heldCalls.current.lined = lined;
      // Expand inbox summaries only after turn shaping. Source rows remain the semantic anchors
      // for turn boundaries, retries and queue actions; this is a display-only projection.
      const displayRows = projectInboxRows(turns.rows, last?.turns.rows, turns.reusedRows);
      const subagents = subagentRowsFrom(displayRows, folds, last?.subagents);
      lastTurns.current = { turns, subagents };
      // After the turns: a live turn's status reads its last row, the call's included.
      return withoutAskedCalls(withShellRows(subagents.rows, chatShellRuns), panelAsks);
    });
  }, [
    chatPresentation,
    childRows,
    sourceRows,
    started,
    folds,
    snapshot.isWorking,
    snapshot.clockOffsetMs,
    codexRuns,
    sessionStatus,
    lineBelow,
    snapshot.summary?.family,
    snapshot.waitingSteers,
    messageBreaks,
    chatShellRuns,
    panelAsks,
    subagentTray,
    workflowLabsEnabled,
    shownSessionId,
    callRelease,
  ]);
  // Every message other sessions sent that the agent has not read yet, the steers its running turn
  // has not taken and the messages queued behind it, is in one group at the end
  // (conversation/pendingMessages.ts), never a loose list of rows and never composer-queue rows. A
  // chat with none keeps its rows as they are; one with some copies the row list once per change.
  const lastQueuedRows = useRef<readonly AcpmuxRow[] | undefined>(undefined);
  const queuedRows = useMemo(() => {
    if (childRows) return NO_ROWS;
    return (lastQueuedRows.current = queuedMessageRows(snapshot.queue, lastQueuedRows.current));
  }, [childRows, snapshot.queue]);
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
  // Debug Settings agent.sessionStatus draws its activity line under the pinned list, so it pins it.
  const planInHat = subagentTray && !pinnedPlan && !sessionStatus && !quick && !childRows && snapshot.isWorking;
  const hatPlanRow = useMemo(() => (planInHat ? liveTurnPlan(turnRowsShown) : undefined), [planInHat, turnRowsShown]);
  // The list's entries hold while a step's state does not change, so streamed text never redraws the hat.
  const hatPlanKept = useRef<readonly AcpmuxPlanEntry[] | undefined>(undefined);
  const hatPlan = sameEntries(hatPlanKept.current, hatPlanRow?.plan)
    ? hatPlanKept.current
    : (hatPlanKept.current = hatPlanRow?.plan);
  const transcriptRows = useMemo(() => {
    const steers =
      childRows || chatPresentation === "messages" ? NO_ROWS : (lastTurns.current?.turns.pending ?? NO_ROWS);
    // A guest's prompt is a person's, never another session's message: it draws on its own, held
    // with its Approve and Decline in view (conversation/QueuedMessageCard.tsx), never folded into
    // the group.
    const people = queuedRows.filter(isPersonQueuedRow);
    const agents = people.length ? queuedRows.filter((row) => !isPersonQueuedRow(row)) : queuedRows;
    const group = pendingMessagesRow(steers, agents, lastPending.current);
    lastPending.current = group;
    const merged = mergeInboxNotices(hatPlanRow ? turnRowsShown.filter((row) => row !== hatPlanRow) : turnRowsShown);
    const rows = withWaitingRows(merged, group ? [...people, group] : people);
    return childRows ? rows : btwNotes.rows(rows, snapshot.sessionId, btwSnapshot);
  }, [chatPresentation, childRows, turnRowsShown, hatPlanRow, queuedRows, btwNotes, btwSnapshot, snapshot.sessionId]);
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
    if (opener && document.contains(opener)) opener.focus();
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
  // After the reset above: a pane opened on a subagent shows it once its chat is shown.
  useEffect(() => {
    if (!requestedSubagent || !shownSessionId) return;
    setSubagentView(requestedSubagent);
    setRequestedSubagent(undefined);
  }, [requestedSubagent, shownSessionId]);
  // A subagent's pane shows the subagent with its own composer (SubagentComposer.tsx), never the
  // chat's composer, queue or pull request: they are the chat's. Once it shows a chat ("Subagent of", a branch pill, another
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
  const [inspectorOpen, setInspectorOpen] = useState(false);
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
    if (inspectorOpen || !inspectorOpener.current) return;
    inspectorOpener.current.focus();
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
      listProcesses: (sessionId) => directClient.current?.listProcesses(sessionId) ?? Promise.reject(new Error()),
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
  const shownEntry = shownSessionId
    ? snapshot.sessions?.find((entry) => entry.sessionId === shownSessionId)
    : undefined;
  const sessionInfoSplit = ownSubagentPane || !!(shownEntry?.startedBy || shownEntry?.spawnedBy);
  const sessionInfoOpened = useSessionInfoOpen(sessionInfoPaneKey(shownSessionId, sessionInfoSplit));
  const processRegistry = useProcessRegistry(
    processSource,
    shownSessionId,
    (sessionInfoOn && sessionInfoOpened) ||
      summaryCard.shown ||
      backgroundOpen ||
      snapshot.isWorking ||
      transcriptRunning.length > 0,
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
  // Another chat in this pane (the sidebar, a link) shows that chat, not the page.
  useEffect(() => {
    setupContinuation.current = undefined;
    setupStart.current = undefined;
    setHarnessesOpen(false);
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
  const turnActions = useMemo<TurnActions>(
    () => ({
      queuedMessages: () => queuedMessageActionsRef.current,
      ...(stableBranches.size > 0 && {
        branches: {
          of: stableBranches,
          running: runningBranchSessions,
          open: (sessionId: string) => void callNative("chat.select", { sessionId }).catch(() => undefined),
        },
      }),
      ...(forkable && {
        fork: (throughSeq: number) => void callNative("chat.fork", { throughSeq }).catch(() => undefined),
        forkSeq,
        forkAny,
        promptTurns: stablePromptSeqs,
      }),
      promptImage: (id: string) => directClient.current?.promptImage(id) ?? Promise.resolve(undefined),
      ...(stableEditSeqs.size > 0 && {
        edit: {
          seqs: stableEditSeqs,
          send: (rowId: string, throughSeq: number, text: string) =>
            callNative<boolean>("chat.editResend", { rowId, throughSeq, text }).then(
              (sent) => sent === true,
              () => false,
            ),
        },
      }),

      ...(connected &&
        ((resend: (rowId: string, prompt: string) => Promise<unknown>) => ({
          retry: (rowId: string, prompt: string) => void resend(rowId, prompt).catch(() => undefined),
          // A failed turn's Retry asks acpmux to retry the turn of the chat its row was drawn for
          // (turnRetry.ts), and sends the prompt again only where acpmux cannot. Like Continue and
          // Restart, never to a View Only chat or a read-only pane, and never to the next chat
          // during a switch's hold: checked before it asks and again before a fallback send.
          ...(restartChat && {
            retryFailed: ((owner: string) => (rowId: string | undefined, prompt: string | undefined) => {
              const reaches = () => restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession);
              const client = directClient.current;
              if (!client || !reaches()) return Promise.resolve(undefined);
              return retryFailedTurn({
                sessionId: owner,
                capabilities: client.capabilities,
                request: (method, params) => client.retry(method, params),
                resend:
                  rowId && prompt
                    ? () =>
                        resendToOwner({
                          client,
                          currentClient: () => directClient.current,
                          owns: reaches,
                          restore: () => client.resendPrompt(rowId, prompt),
                          send: (draft) =>
                            callNative("chat.send", { text: draft.input, attachments: draft.attachments }),
                        })
                    : undefined,
              });
            })(restartChat),
          }),
        }))(async (rowId: string, prompt: string) => {
          const draft = await directClient.current?.resendPrompt(rowId, prompt);
          return callNative("chat.send", { text: draft?.input ?? prompt, attachments: draft?.attachments ?? [] });
        })),

      // Continue after a stop (Codex's) sends its prompt as the composer would: it shows as the
      // reader's prompt and starts the next turn, or queues behind one already sent. Like Restart
      // (restart.ts), never to a View Only chat, a subagent's read-only pane or where the composer
      // cannot send, and only to the chat this pane still shows, never the next during a switch's hold.
      // A prompt that runs next anyway (a queued one no Stop or owner holds, such as a message acpmux
      // queued again after the Stop) starts the next turn: no Continue beside it.
      ...(restartChat &&
        !queueRunsNext && {
          resume: (
            (owner: string) => () =>
              restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession)
                ? resumeThrough(callNative)()
                : Promise.resolve()
          )(restartChat),
        }),
      // A tagged ask's answer (NextStepCard.tsx) sends as Continue does, with the same reach.
      ...(restartChat && {
        nextStepKey,
        answer: (
          (owner: string) => (text: string) =>
            restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession)
              ? answerThrough(callNative)(text)
              : Promise.resolve()
        )(restartChat),
      }),
      // A context-full failure's Compact sends the agent's own /compact as Continue sends its prompt,
      // with the same reach: never to a View Only chat or a read-only pane, never the next chat.
      ...(restartChat &&
        offersCompact(snapshot.commands) && {
          compact: (
            (owner: string) => () =>
              restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession)
                ? compactThrough(callNative)()
                : Promise.resolve()
          )(restartChat),
        }),
      // Restart sends a prompt as the composer would (restart.ts `restartOwner`, `restartReaches`):
      // never to a View Only chat, from a subagent's read-only pane or where the composer cannot send,
      // and only to the chat whose row was clicked, never to the next chat during a switch's hold.
      ...(restartChat && {
        restartSubagent: ((owner: string) => (agent: Subagent) => {
          if (!restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession)) return;
          const text = restartPrompt(agent, translate);
          if (text) void callNative("chat.send", { text }).catch(() => undefined);
        })(restartChat),
        // Retry asks acpmux, else the chat's agent, as Restart does (subagents/retryState.ts).
        retryCapabilities: directClient.current?.capabilities,
        // One it can't reach (a reconnect, a switch's hold) is refused with a note, never taken as sent.
        retryAgent: ((owner: string) => (agent: RetryTarget) => {
          const client = directClient.current;
          const reaches = () => restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession);
          if (!client) return Promise.resolve("retry.failed" as const);
          const request = (method: string, params: Record<string, unknown>) => client.retry(method, params);
          const send = (text: string) => callNative("chat.send", { text });
          return runRetry(agent, owner, { request, send, capabilities: client.capabilities, reaches }, translate);
        })(restartChat),
      }),
      ...(connected &&
        retryModels.length > 1 && {
          retryWith: {
            models: retryModels,
            current: snapshot.summary?.model,
            ...(retryHarnessName ? { harness: retryHarnessName } : {}),
            ...(retryTop ? { top: retryTop } : {}),
            retry: (rowId: string, prompt: string, model: string) =>
              void callNative("chat.retryWith", { rowId, prompt, model }).catch(() => undefined),
          },
        }),
      // The X beside a steer the agent has not read: it comes back into the composer to edit. Only
      // Claude Code's adapter takes one back (acpmux `_acpmux/steer_withdraw`), under any family.
      ...(takesSteersBack({ backgroundsWork: snapshot.summary?.backgroundsWork }, connected) && {
        unsteer: (row: AcpmuxRow) =>
          takeBackSteer(row, {
            withdraw: (promptId) => editQueued(promptId, { op: "withdraw" }),
            attachments: (rowId) => directClient.current?.promptAttachments(rowId) ?? Promise.resolve([]),
            draft: (rowId, text) =>
              directClient.current?.resendPrompt(rowId, text) ?? Promise.reject(new Error(translate("error.notOpen"))),
            restore: (text, attachments) => composerHandle.current?.restore(text, attachments),
          }),
      }),
      ...(connected &&
        loginCommand &&
        !cloudMachineID &&
        snapshot.summary?.hostKind !== "cloud" && {
          reauthenticate: () =>
            void callNative("tab.open", {
              kind: "terminal",
              text: loginCommand,
              ...(snapshot.summary?.cwd ? { cwd: snapshot.summary.cwd } : {}),
              run: true,
            }).catch(() => undefined),
        }),
      transferCloudCredentials: cloudCredentialRecovery(
        connected && cloudCredentialRecoveryAvailable && !cloudTeamMachine,
        cloudMachineID,
        snapshot.sessionId,
        snapshot.summary?.harness,
        callNative,
        (owner) => restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession),
        () => directClient.current ?? undefined,
        automaticCloudCredentialAttempts.current,
      ),
      // A Cloud chat's agent signs in on its own machine (Leo 2026-11-01: "yes those are
      // important"): its own login, never this Mac's. Its page opens as a link click does here.
      // A chat here whose built-in Claude Code or Codex is not signed in offers Use an API key
      // (Leo 2026-10-26: "if user picks a model they don't have api key, we offer them to add
      // credits or add their own api key").
      ...((login: Parameters<typeof cloudAgentLogin>[0]) => ({
        cloudSignIn: cloudAgentLogin(login),
        apiKeySignIn: localApiKeyLogin(login),
      }))({
        connected,
        machineID: cloudMachineID,
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
      }),
      review: hunkReview,
      route: {
        harness: snapshot.summary?.harness,
        name: catalog.find((entry) => entry.id === (snapshot.summary?.harness ?? ""))?.name,
        hostKind: cloudRouteHostKind,
        ...(cloudMachineID && cloudTeamMachine && { teamMachine: true }),
      },
      switchModel: () => void openPicker(translate(PICKER_LABELS.model)),
      // A failure's cmux CodeRouter action: only this Mac's acpmux lists and binds a chat's routes.
      ...(chatAccounts && snapshot.sessionId ? { ownRoute: ownRouteOf(chatAccounts, snapshot.sessionId) } : {}),
      access,
    }),
    [
      access,
      chatAccounts,
      snapshot.sessionId,
      stableBranches,
      runningBranchSessions,
      forkable,
      forkSeq,
      forkAny,
      stablePromptSeqs,
      stableEditSeqs,
      connected,
      hunkReview,
      loginCommand,
      cloudMachineID,
      cloudRouteHostKind,
      cloudCredentialRecoveryAvailable,
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
      snapshot.commands,
      queueRunsNext,
      nextStepKey,
    ],
  );
  // Each turn's checkpoint pair, named by the row that starts the turn: the checkpoints acpmux
  // recorded on its summary, diffed on the session host.
  const turnRowsRef = useRef(snapshot.rows);
  turnRowsRef.current = snapshot.rows;
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
  // Each turn is scanned again only when its rows change, so streaming rescans the live turn alone.
  const previewTurns = useRef(new Map<string, { key: string; url: string | undefined }>());
  const previewUrl = useMemo(() => {
    const rows = snapshot.rows;
    const seen = new Map<string, { key: string; url: string | undefined }>();
    let found: string | undefined;
    let end = rows.length;
    for (let index = rows.length - 1, turns = 0; index >= 0 && turns < PREVIEW_TURNS && !found; index -= 1) {
      const user = rows[index];
      if (user.kind !== "user") continue;
      const turn = rows.slice(index + 1, end);
      const key = [user, ...turn].map((row) => `${row.id}:${row.version}`).join("|");
      const cached = previewTurns.current.get(user.id);
      const entry = cached?.key === key ? cached : { key, url: turnPreviewUrl(user, turn) };
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
  const [newTab, setNewTab] = useState<NewTabHost | undefined>(injectedNewTabContext);
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
  // A start owns this visit's screen until accepted, even while a switch publishes queued rows.
  // A new adoption has a different generation and never inherits this pending/error view.
  const [newTabStartPage, setNewTabStartPage] = useState<number>();
  const newTabRetainsDraft = useRef(false);
  useNewTabPlaces(setNewTab);
  useNewTabWeather(setNewTab);
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
  const showAllChats = () => void callNative("action.run", { id: "agentPane.searchChats" }).catch(() => undefined);
  // The + menu's Search chats and Search pages (Leo: "the chatgpt desktop app, let's do their +
  // symbol's capabiliities for our composer"): the command palette's chats page and its History
  // search page, both app actions the pane may run (AgentPaneModel.paletteActions). A refusal is
  // said as the composer's notice, never dropped.
  const plusSearchExtensions = useMemo(() => composerPlusSearchExtensions(t), [t]);
  const runPlusSearch = (id: string) => {
    const name = id === PLUS_SEARCH_ACTIONS.pages ? t("composer.plusSearchPages") : t("sidebar.search");
    void callNative("action.run", { id }).catch(() =>
      directClient.current?.notice(translate("composer.offloadNotRun", { action: name })),
    );
  };
  // New Tab shows no transcript, so the page says a refusal itself (NewTabScreen plusRefused).
  const runNewTabPlusSearch = (id: string) => callNative("action.run", { id });
  const [shortcuts, setShortcuts] = useState<ShortcutLabels>({});
  // SSH… opens Connect to Machine; New Cloud Machine opens the host's create flow (Lawrence 2026-10-06).
  const connectMachine = (kind: ConnectKind) =>
    void callNative("action.run", { id: CONNECT_ACTIONS[kind] }).catch(() => undefined);
  // Move to Cloud and Bring Back Local report their own progress and failures as the app's toasts;
  // the notice says only that the app did not start the move (turned off, or not for this chat).
  /// `session`, when given (the title menu), binds the move to the chat whose menu offered it: the
  /// host runs it only while the tab still shows that chat (AgentPaneModel+Actions.swift).
  const offloadChat = (kind: OffloadKind, session?: string) => {
    const notRun = () =>
      directClient.current?.notice(
        translate("composer.offloadNotRun", {
          action: translate(kind === "move" ? "composer.moveToCloud" : "composer.bringBackLocal"),
        }),
      );
    if (session !== undefined && directClient.current?.selectedSession !== session) {
      notRun();
      return;
    }
    void callNative("action.run", { id: CONNECT_ACTIONS[kind], ...(session !== undefined ? { session } : {}) }).catch(
      notRun,
    );
  };
  /// `session`: the chat whose title menu offered the move. The host moves the tab only while it
  /// still shows that chat (AgentTabs+Header.swift), so a switch before the request is handled
  /// never moves the newly selected chat.
  const moveChatToMachine = (machine: string, session: string | undefined) => {
    const notRun = () =>
      directClient.current?.notice(translate("composer.offloadNotRun", { action: translate("composer.moveToCloud") }));
    if (!session || directClient.current?.selectedSession !== session) {
      notRun();
      return;
    }
    void callNative("pane.moveToMachine", { machine, session }).catch(notRun);
  };
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
  /// The cap card answered Run on This Mac (cloudRunsHere): the prompt sends here once the mode switched.
  const runHereSend = useRef(false);
  /// Counts the Cloud starts that ended, so the folder default looks again once one has.
  const [cloudStartsEnded, setCloudStartsEnded] = useState(0);
  const sandboxModeRows = {
    mode: sandbox.mode,
    onMode: (mode: RunMode) => {
      // Run mode is a new destination (including a brand-new Cloud machine); an account-machine
      // picker target must not survive that choice and wake the old machine on the next edit.
      cloudDraftMachineID.current = null;
      cloudTypingPrewarm.reset();
      runModePicked.current = true;
      sandbox.setMode(mode);
      cloudComposeEligible.current = mode === "cloud" && sandboxOffered;
      if (cloudComposeEligible.current) {
        newChatPrewarm.abandon();
        cloudReservation.selected();
      } else cloudReservation.abandon();
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
  const composerModeRows = {
    mode: sandboxModeRows.mode,
    onMode: (mode: RunMode) => {
      if (mode === "cloud") {
        const folder = cloudStartFolder(projectDraft ?? composerSnapshot.summary?.cwd ?? newTab?.cwd);
        if ("cwd" in folder)
          cloudFolderGrant.granting(
            folder.cwd,
            pickFolder(callNative, folder.cwd, () => undefined),
          );
      }
      sandboxModeRows.onMode(mode);
    },
  };
  /// A Sandboxed send: text only, by an agent a sandbox runs. A page-side refusal comes back as its
  /// code (the prompt stays where it was typed); false: nothing was sent.
  const startSandbox = (text: string, attachmentCount: number, harness: string | undefined): string | boolean =>
    sandboxPageRefusal(attachmentCount, harness) ?? sandbox.send(text, sandboxAgent(harness));
  /// Cloud picked (cloudRun.ts): the first send goes to the host, which opens the chat on a Cloud
  /// machine and closes this tab. False keeps the prompt in the composer meanwhile; a string is a
  /// refusal said here, also while Cloud is picked but not offered now (as `sandboxPickedNotOffered`).
  /// The host says its own progress and failures (toasts), and the chat shows the start under the
  /// message as it goes (CloudStartView; the host's `cloudStartProgress` pushes fill it in).
  const cloudPicked = sandbox.mode === "cloud" && !snapshot.sessionId;
  cloudComposeEligible.current = cloudPicked && sandboxOfferable;
  const cloudPickedNotOffered = cloudPicked && !sandboxOffered;
  const [startCloud] = useState(() =>
    grantedCloudStart(reservedCloudCall(callNative, cloudReservation), cloudFolderGrant),
  );
  const [cloudStartKeys] = useState(() => makeCloudStartKeys());
  const [cloudStart, setCloudStart] = useState<CloudStartProgress>();
  /// A Cloud start is out: the composer takes no edits until it ends (#28686 review). On success the
  /// host closes this tab with only the sent prompt, so text or files added meanwhile would be lost;
  /// on failure the prompt is still in the composer to edit and send again.
  const cloudStarting = cloudStart?.state === "starting";
  /// The same, for dictation's field getter (below), which is made once.
  const cloudStartingNow = useRef(false);
  cloudStartingNow.current = cloudStarting;
  /// A Cloud send from the New Tab page opens the chat at once, as a local send does (Leo, 2026-11-04:
  /// "i should never be seeing this it should just insta send me to a new chat just like local"): the
  /// page goes for this visit (its generation), and the chat view shows the sent message with the
  /// start under it (CloudStartView) until the host opens the chat on its machine.
  const [cloudLeftPage, setCloudLeftPage] = useState<number>();
  /// The page's draft as it went (leaveNewTabDraft): the chat composer gets it back when the start
  /// fails or the cap card runs it on this Mac, so the prompt is never lost with the page.
  const newTabCloudSent = useRef(false);
  const cloudPageDraft = useRef<{ text: string; attachments: ComposerAttachment[] } | undefined>(undefined);
  const sendToCloud = (
    text: string,
    attachments: ComposerAttachment[],
    start: Omit<CloudStart, "task" | "attachments">,
    fromPage = false,
  ): string | false => {
    const refused = cloudPageRefusal(sandboxOffered);
    if (refused === "cloud_not_now")
      return translate("composer.offloadNotRun", { action: translate("composer.cloud") });
    if (cloudStartPending.current) return false;
    const reservationKey = cloudReservation.handoff(start.environment);
    const request: CloudStart = { task: text, attachments, ...start, ...(reservationKey ? { reservationKey } : {}) };
    // A retry of the same start reuses its first key, so the host reaches the machine it made (#33493).
    const key = cloudStartKeys.keyFor(request);
    const started = startCloud(request, key);
    // Another Return while a start waits starts nothing, and the card keeps that start.
    if (!started) return false;
    cloudStartPending.current = true;
    if (fromPage) {
      newTabCloudSent.current = true;
      // The prompt as sent, for a page that leaves no draft of its own (a prefilled location it
      // counts as untyped); the page's own draft, if it hands one over, replaces it.
      cloudPageDraft.current = { text, attachments };
      setCloudLeftPage(newTabGeneration);
    }
    setCloudStart(
      cloudStartBegun(key, text, start.cwd, start.harness ? harnessLabel(start.harness) : undefined, start.home),
    );
    void started.then((answer) => {
      cloudStartKeys.ended(request, answer);
      cloudStartPending.current = false;
      setCloudStartsEnded((count) => count + 1);
      // A page's draft goes back to the chat composer unless the chat opened on its machine.
      const pageDraft = cloudPageDraft.current;
      cloudPageDraft.current = undefined;
      newTabCloudSent.current = false;
      if (pageDraft && (!answer.ok || cloudRunsHere(answer)))
        restoreComposerDraft(composerHandle, heldBack, pageDraft.text, pageDraft.attachments);
      if (cloudRunsHere(answer)) {
        // The cap card's Run on This Mac: the prompt still in the composer goes to a chat here once the mode is.
        setCloudStart((current) => (current?.key === key ? undefined : current));
        runModePicked.current = true;
        runHereSend.current = true;
        sandbox.setMode("persistent");
        return;
      }
      setCloudStart((current) => cloudStartEnded(current, key, answer));
      if (!answer.ok && !cloudStartToasted(answer))
        directClient.current?.notice(translate("composer.offloadNotRun", { action: translate("composer.cloud") }));
    });
    return false;
  };
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
    setSandboxDraftMoved(false);
    setSandboxViewing(false);
    sandboxWake.current = undefined;
    runModePicked.current = false;
    cloudReservation.reset();
    // Another chat shows here: a Cloud start's card belongs to the new chat it was sent from.
    setCloudStart(undefined);
    cloudPageDraft.current = undefined;
    newTabCloudSent.current = false;
    cloudDraftMachineID.current = undefined;
    cloudTypingPrewarm.reset();
    const view = { ...(snapshot.sessionId ? { session: snapshot.sessionId } : {}), generation: newTabGeneration };
    if (!cloudIdentityKept(cloudShownView.current, view)) cloudIdentityBound.current = false;
    cloudShownView.current = view;
  }, [snapshot.sessionId, newTabGeneration, cloudTypingPrewarm, cloudReservation]);
  /// The person picked another place to run after a Cloud start failed: its card goes.
  useEffect(() => {
    if (sandbox.mode !== "cloud") {
      cloudReservation.abandon();
      setCloudStart((current) => (current?.state === "failed" ? undefined : current));
    }
  }, [sandbox.mode, cloudReservation]);
  /// Run on This Mac from the cap card (runHereSend): the kept prompt sends once the mode is this Mac's.
  useEffect(() => {
    if (!runHereSend.current || sandbox.mode !== "persistent") return;
    runHereSend.current = false;
    composerHandle.current?.send();
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
        title: subagentTitleRef.current(id),
        tone: workflowPaneRequest(id) ? undefined : agentTone(id),
        // Seed a new pane from this chat's kept tail before its own attach answers.
        beforeOpen: () => directClient.current?.handOverCurrentTail(),
      }),
    [autoOpenSubagents],
  );
  // Escape closes a subagent's view to the chat's, as its pill's × does (subagents/subagentEscape.ts).
  useEscapeClosesSubagent(!quick && !!subagentView, () => setSubagentView(undefined));
  // A pane opened on a subagent shows the chat's other subagents in place, and its "Subagent of" pill goes
  // back to the chat: its tab's name follows what it shows (review of #28497 at 995299ff). Not before
  // the subagent it was opened on has shown, or the name the app gave the tab would flash away; and not
  // while this page has no rows for the subagent yet (they load after the pane opens), which would name
  // it "Subagent of" over the name the chat's page gave it.
  const shownSubagentKnown = !!subagentView && freshAgents.some((agent) => agent.id === subagentView);
  const shownSubagentTitle =
    ownSubagentPane && subagentView && shownSubagentKnown ? subagentTitle(subagentView) : undefined;
  useShownSubagent(callNative, ownSubagentPane, subagentView, shownSubagentTitle);
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
  /// The summary card's subagents: the shown one, and a row's click shows its view.
  const cardSubagents = useMemo(
    () => ({
      views: snapshot.subagentViews,
      current: childRows ? subagentView : undefined,
      asks: askedToolCalls,
      onOpen: showSubagent,
      autoOpen: quick ? undefined : { on: autoOpenSubagents, set: setAutoOpenSubagents },
    }),
    [
      snapshot.subagentViews,
      childRows,
      subagentView,
      askedToolCalls,
      showSubagent,
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
  const scopedRows = shownSubagent === undefined ? undefined : snapshot.subagentViews?.[shownSubagent];
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
      onBack: () => setSubagentView(parent ?? undefined),
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new scope only when what it shows changes
  }, [scopedKey, cardScopedRows, chatName, chatAgents]);
  // How many rows Session Info's Background tasks lists for the view on screen, read as it reads
  // them (sessionInfoLists drops a transcript shell the registry no longer lists): a subagent's view
  // from its own rows (none yet: empty) and processes, with how its shells ended in the chat's rows
  // (session-info/subagentScope.ts); the chat's view from its own, with its workflows.
  const registryProcesses = processRegistry.processes;
  const registryListed = processRegistry.listed;
  const scopedOwn = useMemo(
    () => (scopedKey ? transcriptBackground(scopedRows ?? []) : undefined),
    [scopedKey, scopedRows],
  );
  const chatRows = snapshot.rows;
  const scopedTasks = useMemo(() => scopedOwn && withChatEnds(scopedOwn.tasks, chatRows), [scopedOwn, chatRows]);
  const backgroundRows = useMemo(() => {
    const count = (processes: readonly SessionInfoProcess[], tasks: readonly SummaryBackgroundTask[]) => {
      const { servers, tasks: commands } = sessionInfoLists(processes, tasks, registryListed);
      return servers.length + commands.length;
    };
    if (scopedOwn && scopedTasks)
      return count(subagentProcesses(registryProcesses, scopedRows ?? []), scopedTasks) + scopedOwn.scheduled;
    return count(registryProcesses, transcriptWork.tasks) + transcriptWork.scheduled + workflows.length;
  }, [scopedOwn, scopedTasks, scopedRows, registryProcesses, registryListed, transcriptWork, workflows.length]);
  // The Inspector (Debug Settings `agent.sessionInfo`): its toggle the first of the header's
  // top-right icons, the panel beside or over the chat. On, it takes the summary card's place.
  const sessionInfoSummary = sessionInfoSnapshot.summary;
  const sessionInfoLocal =
    sessionInfoSummary !== undefined &&
    !sessionInfoSummary.peer &&
    !(sessionInfoSummary.host && sessionInfoSummary.hostKind !== "local");
  // A background command's Bash call in the transcript (`showToolRow` below, which needs what the
  // Inspector draws): what its task row opens where its terminal cannot (a peer's or Cloud chat).
  const showCallRef = useRef<(toolCallId: string) => boolean>(() => false);
  const showCall = useCallback((toolCallId: string) => showCallRef.current(toolCallId), []);
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
    onShowUsage: refreshUsage,
    // Quick Chat's panel has no room beside it for the side panel.
    onOpenDocument: quick ? undefined : openArtifact,
    onShowCall: quick ? undefined : showCall,
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
  const [revealRow, setRevealRow] = useState<{ rowId: string; key: number; toolId: string }>();
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
  // What ended, behind the tray's bounded status cards; never in its count.
  const trayFinished = useMemo(
    () => (subagentTray ? finishedTrayItems(trayAgents, childSessions) : []),
    [subagentTray, trayAgents, childSessions],
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
    transcriptRows,
    summaryCard,
    sessionInfo,
  };
  // A `?message=<id>` link's row (links.ts `revealMessageWhenShown`): the transcript scrolls it in
  // by its place in the chat, so a message far above the view works, where its element does not
  // exist yet. One message can span several rows (a tool call splits it): `messageRevealTarget`
  // takes a drawn one, and opens the turn's "Worked for" when the fold hides them all, the way a
  // running line's count does. The reveal lets go after a moment, as a count's does: it stands in
  // for Find's own target while it is set, and a target that never let go would scroll back to
  // this row whenever its id is drawn again.
  showMessage.current = (messageId) => {
    const { sourceRows: rows, transcriptRows: shown } = counted.current;
    const target = messageRevealTarget(rows, shown, directClient.current?.rowsOfMessage(messageId) ?? []);
    if (target === undefined) return undefined;
    if (target.fold !== undefined) openFold(target.fold);
    if (target.run !== undefined) openFold(target.run);
    for (const fold of target.also ?? []) openFold(fold);
    const key = Date.now();
    setRevealRow({ rowId: target.rowId, key, toolId: "" });
    setTimeout(() => setRevealRow((current) => (current?.key === key ? undefined : current)), REVEAL_HOLD_MS);
    return target.rowId;
  };
  // A link waiting on replay retries against committed rows, without a polling timer.
  useLayoutEffect(() => notifyRevealRowsChanged(), [sourceRows, transcriptRows]);
  // A shell's Bash row, opening its turn's "Worked for" when that is closed and the run that
  // holds the call. The reveal lets go after a moment, so the run closes again like any other.
  // False when no loaded row holds the call (a command only the registry knows).
  const showToolRow = useCallback(
    (toolId: string | undefined) => {
      const { sourceRows: rows, transcriptRows: shown } = counted.current;
      const index = toolId ? rows.findIndex((row) => row.items?.some((item) => item.tool?.id === toolId)) : -1;
      const row = rows[index];
      if (!row || !toolId) return false;
      if (!shown.some((drawn) => isFindRow(drawn, row.id))) {
        for (const fold of hiddenRowFolds(rows, shown, index)) openFold(fold);
      }
      const key = Date.now();
      setRevealRow({ rowId: row.id, key, toolId });
      setTimeout(() => setRevealRow((current) => (current?.key === key ? undefined : current)), REVEAL_HOLD_MS);
      return true;
    },
    [openFold],
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
      if (!shown.some((drawn) => isFindRow(drawn, row.id))) {
        for (const fold of hiddenRowFolds(rows, shown, index)) openFold(fold);
      }
      const key = Date.now();
      setRevealRow({ rowId: row.id, key, toolId: "" });
      setTimeout(() => setRevealRow((current) => (current?.key === key ? undefined : current)), REVEAL_HOLD_MS);
    },
    [openFold],
  );
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
  const workingCounts = useMemo<WorkingCounts>(() => {
    return {
      agents: runningAgents.length,
      commands: runningCommands.length,
      sessions: runningSessions.length,
      tokens: turnTokens,
      split,
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
  ]);
  // A tray command opens its terminal beside the chat; where none opens (a peer's or Cloud chat, or
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
  // `/btw` opens a read-only side session beside the chat; the Debug toggle is an explicit
  // kill switch, and the Quick Composer has none.
  const sideSessions = useSideSessions();
  const opensSideSessions = !quick && sideSessions;
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
  /// The newest snapshot, for host requests that read it (pane.context).
  const snapshotRef = useRef<AcpmuxSnapshot | undefined>(initialChat?.snapshot);
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
              opensProcessTerminal(snapshot.summary) &&
              clientEpoch > 0 &&
              directClient.current !== undefined &&
              backgroundTaskOutput !== undefined
            }
            onOpenSession={openOfferChat}
            onOpenPanel={quick ? undefined : openBackgroundPanel}
            stop={stopSubagent}
            stopProcess={stopProcess}
            placement={trayPlacement}
            shown={trayChat}
            enters={trayEnters}
            plan={hatPlan}
            onTuck={trayPlacement === "tray" ? tuckTray : undefined}
            tuckSide={trayHandle}
          />
        </SubagentHarnessContext.Provider>
      </SubagentClockContext.Provider>
    </BackgroundTaskOutputContext.Provider>
  ) : null;
  /// The composer's prompt, which dictation writes into.
  const prompt = useRef<MarkdownFieldHandle>(null);
  /// The composer itself, which takes back prompts a harness switch held; prompts handed back
  /// while it is not mounted (a handoff review) go in when it mounts.
  const composerHandle = useRef<ComposerHandle | null>(null);
  /// What the new chat shown leaves when its tab opens another chat (set below, cmux#32276).
  const newChatLeftover = useRef<() => { leave: () => void; cancel: () => void } | undefined>(() => undefined);
  const heldBack = useRef<{ text: string; attachments: ComposerAttachment[] }[] | undefined>(undefined);
  /// Quote in Reply picks made while no composer is mounted (a Sandboxed receipt or a handoff review
  /// in its place): they go in after the draft, in order, when it mounts (composerRestore.ts).
  const heldQuotes = useRef<string[] | undefined>(undefined);
  /// Prompts sent while a new chat starts, shown as queued rows until acpmux takes each, in order
  /// (startingSends.ts). One refused comes back to the composer with those behind it.
  const [startingRows, setStartingRows] = useState<readonly StartingSend[]>([]);
  const [startingSends] = useState(
    () =>
      new StartingSends(setStartingRows, (text, attachments, error) => {
        // A prompt kept as its own failed row or in the transcript stays there; one a harness switch
        // handed back is in the composer already.
        if (keptInChat(error) || (error as { handedBack?: unknown } | null)?.handedBack === true) return;
        if (composerHandle.current) composerHandle.current.restore(text, attachments);
        else heldBack.current = [...(heldBack.current ?? []), { text, attachments }];
      }),
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
  const onTranscriptFollowingChange = useCallback((following: boolean) => {
    followingTranscript.current = following;
    // Back at the latest row: the commands held out while scrolled up go back into their runs.
    if (following && heldCalls.current.keys.size > 0) releaseCalls();
  }, []);
  const composerRef = useCallback((handle: ComposerHandle | null) => {
    composerHandle.current = handle;
    if (handle && pendingWake.current) {
      handle.wake(pendingWake.current);
      pendingWake.current = undefined;
    }
    replayHeldForComposer(handle, heldBack, heldQuotes);
  }, []);
  const composerUnplacedQuotes = useCallback(
    (quotes: string[]) => handBackQuotes(composerHandle, heldQuotes, quotes),
    [],
  );
  // The selection's Reply chip and a row's Reply quote through the same Quote in Reply as the
  // right-click menu (`chat.quoteReply`, conversation/SelectionReply.tsx).
  useEffect(() => setQuoteReplySink((markdown) => quoteIntoComposer(composerHandle, heldQuotes, markdown)), []);
  useComposerKeyboard(() => {
    if (!prompt.current) return false;
    prompt.current.focus();
    return true;
  }, pageHostClient());
  /// The New Tab page's field, while it shows: dictation writes there then (it has no composer).
  const newTabDictationField = useRef<DictationField | null>(null);
  const dictationTarget = useRef<{ readonly current: DictationField | null }>({
    get current() {
      // A Cloud start is out: dictation writes nowhere, as typing doesn't (`cloudStarting`).
      if (cloudStartingNow.current) return null;
      return newTabDictationField.current ?? prompt.current;
    },
  }).current;
  /// The chat's agent runs on this Mac (`localCwd`, set below each render): it can open a long
  /// recording's file.
  const chatIsLocal = useRef(false);
  const dictation = useDictation(dictationTarget, callNative, {
    accepts: snapshot.summary?.promptCapabilities?.audio === true,
    attach: (audio) => {
      const name = translate("dictation.recording");
      const recording = recordingAttachment(audio, name, chatIsLocal.current);
      if (recording) composerHandle.current?.attach(recording);
      else if (!audio.path) directClient.current?.notice(translate(recordingLeftOutNotice("tooLarge")));
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
    omitted: (reason) => directClient.current?.notice(translate(recordingLeftOutNotice(reason))),
    chat: () => sessionIdRef.current,
    elsewhere: () => directClient.current?.notice(translate("dictation.recordingOtherChat")),
  });
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
  // The host covers the pane with its loading state until this document first draws what it is:
  // the handshake's answer, or the host error when there is none (a failed start must show, not
  // stay behind the loading state). The frames before (no hero yet, "Connecting") stay hidden.
  // One animation frame after that render, then a task: the task runs once that frame was drawn.
  // Not two frames: WebKit stops animation frames once the window is occluded, so a second frame
  // may never come although the first one drew (cx-zjtn.6; PagePaintProbe in CmuxNextPages waits
  // the same way).
  const paintReported = useRef(false);
  // A tab opening an existing chat adopted this prewarmed New Tab page (useSessionAdoption, below):
  // the chat it switches to, until that chat is drawn. Until then the page has not drawn what it is.
  const [adoptingSession, setAdoptingSession] = useState<string>();
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
  const showsWhatItIs = (handshaken && chatDrawn) || hostError !== undefined || newTab !== undefined;
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
  const runAdoption = useCallback(async ({ sessionId, revealTurn }: SessionAdoption) => {
    const ticket = ++adoptionTicket.current;
    const before = directClient.current?.selectedSession;
    // Where the reader left this chat, before its rows draw, as a tab opened on it reads it.
    const anchor = await fetchScrollAnchor(sessionId);
    if (ticket !== adoptionTicket.current) return;
    const now = directClient.current?.selectedSession;
    if (now !== before) {
      // A connect or reconnect opened this chat meanwhile (the host bound the tab to it): what the
      // adoption still carries is its place and its turn (a subagent's pane).
      if (now === sessionId) {
        setScrollAnchor(anchor);
        if (revealTurn) revealRef.current(revealTurn);
      }
      // Another chat was picked while the anchor was read (a page action, automation): it stands.
      else setAdoptingSession((current) => (current === sessionId ? undefined : current));
      return;
    }
    const adopt = window.cmuxAcpmuxActions?.["chat.adopt"];
    if (!adopt) {
      pendingAdoption.current = { sessionId, ...(revealTurn ? { revealTurn } : {}) };
      return;
    }
    setScrollAnchor(anchor);
    await adopt({ sessionId }).then(
      (selected) => {
        if (selected && revealTurn) revealRef.current(revealTurn);
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
    void fetchScrollAnchor(pending.sessionId).then((anchor) => {
      if (directClient.current?.selectedSession === pending.sessionId) setScrollAnchor(anchor);
    });
    if (pending.revealTurn) revealRef.current(pending.revealTurn);
  };
  const adoptSession = useCallback(
    (adoption: SessionAdoption) => {
      directClient.current?.bindToSession(adoption.sessionId);
      paintReported.current = false;
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
  // What this frame drew, not only that it drew: a chat taken from a kept tail is on screen in the
  // frame the open landed on, so the host shows the page instead of fading it in (tailCache.ts,
  // AgentPaneView+Loading.swift). A kept tail is drawn before the frame that shows what the pane
  // is, so it is known by the time this reports; the report happens once either way.
  const drewKeptTail = clientSnapshot.drewKeptTail === true;
  useEffect(() => {
    if (!showsWhatItIs || paintReported.current) return;
    paintReported.current = true;
    requestAnimationFrame(() =>
      setTimeout(() => {
        void callNative("pane.painted", { drewKeptTail }).catch(() => undefined);
        void loadHighlightedCode();
        void loadEditDiffHunks();
      }, 0),
    );
  }, [showsWhatItIs, drewKeptTail]);
  const summary = snapshot.summary;
  const localCwd =
    summary && !summary.peer && !(summary.host && summary.hostKind !== "local") ? summary.cwd : undefined;
  /// The chat's folder on whichever machine runs it: the diff tab reads its repository there (the
  /// session host's git), so Changes opens a tab for a Cloud or remote chat too.
  const chatCwd = summary?.cwd || undefined;
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
  const composerSnapshot = useMemo(() => {
    const enabledCmuxActions = new Set<CmuxCommand["action"]>([
      "import",
      "model",
      "fast",
      "context",
      "plan",
      "resume",
      "login",
    ]);
    if (snapshot.summary) enabledCmuxActions.add("status");
    if (!quick) enabledCmuxActions.add("cd");
    if (forkable && forkSeq !== undefined) {
      enabledCmuxActions.add("fork");
      if (localCwd !== undefined && !quick) enabledCmuxActions.add("side");
    }
    if (continueAvailable) enabledCmuxActions.add("continue");
    // Reserve /btw even with the kill switch off: it must never become a steer or queued prompt.
    if (snapshot.sessionId && !isSideSession && !quick) enabledCmuxActions.add("btw");
    const withCommands = {
      ...snapshot,
      commands: mergedCommands(snapshot.commands, enabledCmuxActions),
      ...(keptStopping && { stopping: true as const }),
    };
    // Prompts still waiting for a new chat to take them follow acpmux's queue, then the prompts the
    // folder's trust holds (trustHeld.ts).
    if (startingRows.length || heldRows.length)
      withCommands.queue = [
        ...snapshot.queue,
        ...startingRows.map((row) => ({ id: row.id, prompt: row.text, sending: true })),
        ...heldRows,
      ];
    return withDraftFolder(withCommands, projectDraft);
  }, [
    snapshot,
    projectDraft,
    continueAvailable,
    forkable,
    forkSeq,
    isSideSession,
    startingRows,
    heldRows,
    localCwd,
    quick,
    keptStopping,
  ]);
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
  const folderRunDefault = useMemo(
    () =>
      sandboxOffered && !onOtherMachine
        ? newChatRunLocation(
            newChatsIn,
            folderRunLocation(composerSnapshot.summary?.cwd ?? newTab?.cwd, snapshot.sessions, snapshot.peerKinds),
          )
        : undefined,
    [
      sandboxOffered,
      onOtherMachine,
      newChatsIn,
      composerSnapshot.summary?.cwd,
      newTab?.cwd,
      snapshot.sessions,
      snapshot.peerKinds,
    ],
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
  const [worktreeCreating, setWorktreeCreating] = useState<false | { sessionId?: string; visit?: string }>(false);
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
  /// The project the person picked in this pane's project picker, until they send in it: that send
  /// makes it the New Tab default (newtab/startedProject.ts). A folder the host or an agent named
  /// is no pick.
  const pickedProject = useRef<string | undefined>(undefined);
  /// Settles once the host answered the pick; `refused` hears a path the host says is no folder.
  const chooseProject = useCallback(
    (cwd: string, peer?: string, refused?: () => void): Promise<void> => {
      folderContinuation.invalidate();
      continuationProjectGeneration.current += 1;
      pickedProject.current = undefined;
      // Another computer's folder is that computer's to check.
      if (peer) {
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
        },
        // Only the host's refusal of the path is `refused`; a request a newer one replaced is not.
        (refusal) => {
          if (refusal !== undefined) refused?.();
        },
      );
    },
    [folderContinuation, requestFolder],
  );
  /// New Worktree (cx-lyqio.2): the new chat starts in a worktree of its folder, or says why not.

  const [worktreeError, setWorktreeError] = useState<{ message: string; sessionId?: string; visit?: string }>();
  const startInWorktree = useCallback(
    (cwd: string) => {
      // A newer folder pick wins over this worktree, as between two picks; the request this one
      // replaces ends as cancelled.
      dropFolderRequest.current?.();
      const pick = ++folderPick.current;
      folderConfirmGeneration.current += 1;
      folderConfirmInFlight.current = false;
      setFolderConfirming(false);
      const sessionId = shownSession.current;
      const visit = trustVisit();
      setFolderAsk(undefined);
      // The worktree lands only in the chat it was made for: a chat switched to meanwhile gets nothing.
      const asked = { sessionId, ...visitOf(visit) };
      const stillHere = () => inThisVisit(asked, shownSession.current, trustVisit());
      setWorktreeError(undefined);
      setWorktreeCreating(asked);
      const use = (folder: string) => {
        // The person's pick: a send there makes it the New Tab default (newtab/startedProject.ts).
        pickedProject.current = folder;
        // A chat that started meanwhile keeps its folder: the worktree gets a new chat of its own.
        if (freshRef.current) setProjectDraft(folder);
        else void callNative("chat.new", { cwd: folder }).catch(() => undefined);
      };
      void newWorktree(callNative, cwd, (folder) => {
        if (pick === folderPick.current && stillHere()) use(folder);
      })
        .then(({ ask }) => {
          // The host asks about the worktree's folder first: the question shows as a picked folder's.
          if (ask && pick === folderPick.current) setFolderAsk({ ask, use, sessionId, ...visitOf(visit) });
        })
        .catch((error: unknown) => {
          if (pick === folderPick.current)
            setWorktreeError({ message: errorMessage(error) || String(error), ...asked });
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
      if (!sandboxOffered && !sandboxPickedNotOffered && !cloudPickedNotOffered) return false;
      sandboxModeRows.onMode(mode);
      return true;
    },
    cloudStart: () => cloudStart ?? null,
  };
  useEffect(() => {
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
      lastCodeBlock: () => lastCodeBlock(snapshotRef.current?.rows ?? []) ?? null,
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
        // Integrate a Harness… from the palette or the File menu on a New Tab page (cx-9fqw): the
        // Harnesses page in place, as the page's own button shows it.
        if (name === "showHarnesses") openHarnessesPage();
        // A chat that just opened from a fork (the app's Fork Conversation): the composer takes the
        // keyboard, so the next words go to the fork.
        if (name === "focusComposer") composerHandle.current?.focus();
        // Archive Chat (Ctrl-Cmd-A), as in the Codex app: the chat menu's row, so it does nothing where
        // the menu has none or the chat is archived.
        if (name === "archiveChat") archiveChatRef.current?.();
        // Commit and Push live in the diff tab beside the chat (its Commit form and Push button).
        if (name === "gitCommit" || name === "gitPush") openChangesTab.current();
        if (
          [
            "permissionAllowOnce",
            "permissionAllowChat",
            "permissionDeny",
            "permissionExpand",
            "permissionRetry",
            "permissionRevoke",
            "permissionRefresh",
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
        // Workflows no longer follow Advanced > Labs; only applyWorkflowLabs switches them.
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
      sessionId: () => directClient.current?.selectedSession,
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
    // Once a daemon was lost, handshakes only look for one: the user may have stopped it.
    // Looking is cheap, so a daemon started again elsewhere is found within seconds.
    let reconnect = false;
    /// When the handshakes began failing (cleared by a connect): a recovery is said only once it
    /// has failed for HOST_ERROR_DEADLINE_MS (hostRetry.ts).
    let failingSince: number | undefined;
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
        const host = await callNative<{
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
          cloudCredentialRecoveryAvailable?: unknown;
          cloudTeamMachine?: unknown;
          /// The app opens a Cloud chat's hand-off turns (`cloud.handoffTurn`, cloudHandoffTurn.ts).
          cloudHandoffs?: unknown;
          cloudRepositoryAvailable?: unknown;
          githubRepository?: unknown;
          harnesses?: unknown;
          model?: unknown;
          sandboxState?: unknown;
          /// The tab this page is (AgentPaneHandshake `tab`); an older app sends none.
          tab?: unknown;
        }>("ready", reconnect ? { reconnect } : {});
        if (cancelled) return;
        // Before anything draws the chat: its Session Info is this tab's, not another tab's of the chat.
        if (typeof host.tab === "string" && host.tab) setSessionInfoTab(host.tab);
        acpmuxPerf.markAgent("handshakeReady");
        acpmuxPerf.markLaunch("handshakeReady");
        setCloudCredentialRecoveryAvailable(host.cloudCredentialRecoveryAvailable === true);
        setCloudTeamMachine(host.cloudTeamMachine === true);
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
        // A chat opened from another tab starts with what it inherited (#16620). Swift hands the
        // draft out once, so a retried `ready` after a failed connect has none and keeps this one.
        const seeded = composerDraft(host.draft);
        if (seeded) setDraft(seeded);
        // Integrate a Harness… from the palette or the menu opened this tab (cx-uj5g8).
        if (host.harnesses === true) setHarnessesOpen(true);
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
        // Mock mode runs this same client against an in-page daemon.
        const mock = host.transport === "mock";
        // Links copy in this build's scheme; only the hostless mock page falls back to Release's.
        setLinkScheme(host.linkScheme, mock ? FALLBACK_LINK_SCHEME : undefined);
        if (mock) markMockPage();
        if (mock)
          setCheckpointVariant(
            new URLSearchParams(window.location.search).get("checkpointVariant") === "expanded"
              ? "expanded"
              : "compact",
          );
        // The app's host owns the socket (`acpmux-bridge`); the page never gets an endpoint or token.
        const bridge = host.transport === "acpmux-bridge";
        if (!mock && !bridge && !(host.transport === "acpmux-websocket" && host.endpoint && host.token)) {
          // A host with no daemon to reach has nothing left to fail.
          setHostError(undefined);
          setHostErrorShown(false);
          return;
        }
        // Native chats never load the in-page daemon or its fixture transcripts. Keep this
        // await in the mock branch so the native handshake still starts in the same turn.
        const mockModule = mock ? (preparedMockTransport() ?? (await import("./mock"))) : undefined;
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
            const at = drawn ? streamedOnly(drawn, next) : -1;
            if (drawn && at >= 0) {
              streamingRow.set(next.rows[at]!, drawn.rows[at]!);
              return;
            }
            streamingRow.clear();
            drawnSnapshot.current = next;
            setSnapshot((previous) => {
              if (
                next.canHandoff &&
                !next.handoff?.ready &&
                next.sessionId === previous.sessionId &&
                previous.handoff?.record
              )
                return { ...next, handoff: { ...next.handoff, record: previous.handoff.record } };
              return next;
            });
          },
          () => {
            // The daemon went away. Ask Swift again: a restarted daemon has a new port and token.
            if (cancelled) return;
            reconnect = true;
            // A switch in flight runs again on the next client.
            harnessSwitch.disconnect(switchPort);
            setStartModeSource(undefined);
            catalogClientId.current += 1;
            directClient.current = undefined;
            delete window.cmuxAcpmuxActions;
            // Until a client connects again, an open handed this page would wait for that connect.
            if (!mock) void postNative("pane.clientReady", { ready: false }).catch(() => undefined);
            // Quiet while it comes back: nothing shows until the handshakes fail past the deadline.
            failingSince = Date.now();
            retryTimer = window.setTimeout(() => void connectHost(), retryDelay);
            retryDelay = nextRetryDelay(retryDelay, true);
          },
          mockModule
            ? () => new mockModule.MockAcpmuxSocket(undefined, window.cmuxAcpmuxMockScript) as unknown as WebSocket
            : bridge
              ? () => new BridgeSocket() as unknown as WebSocket
              : undefined,
          mock ? "daemon" : "native",
        );
        if (cancelled) {
          client.close();
          return;
        }
        acpmuxPerf.markLaunch("connected");
        connectingClient = client;
        directClient.current = client;
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
        followHarnessChanges(client, queryClient, catalogClientId.current);
        retryDelay = 250;
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
        const openOwnTab = (sessionId: string, placement?: string) => {
          if (mock) return Promise.resolve(false);
          // The new tab draws this chat from the host's tail, and this page keeps it selected, so
          // nothing else hands it over (tailCache.ts).
          client.handOverCurrentTail();
          return callNative("chat.openTab", { sessionId, placement: placement ?? "tab" }).then(
            () => true,
            () => false,
          );
        };
        /// Settles when the turn ends. `accepted` runs once acpmux took the prompt; a sender that
        /// passes it (the composer) still holds the prompt until then, so a refusal loses nothing.
        /// Without it a refused prompt goes back into the composer.
        const send = async (
          text: string,
          attachments: import("./attachments").ComposerAttachment[] = [],
          // `sessionId`: the chat acpmux took it in, once known (a held prompt binds to it).
          accepted?: (sessionId?: string) => void,
          steer = false,
          promptId?: string,
          expectedSessionId?: string,
          // Onboarding's seeded first task: no key or click of the person's sent it.
          seeded = false,
          // A prompt the folder's trust held (trustHeld.ts): its id and its own send's ticket.
          fromTrust?: HeldSend,
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
            );
          } finally {
            handedOn();
          }
        };
        /// The chat a trust refusal belongs to: the client, its selection generation and the session.
        type TrustOwner = TrustRefusalOwner<AcpmuxDirectClient>;
        // A trust refusal belongs to the request's selection and cancellation epoch.
        const routeTrustFor = (
          owner: TrustOwner,
          error: unknown,
          again?: () => void,
          declined?: () => void,
        ): boolean => {
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
          attachments: import("./attachments").ComposerAttachment[],
          accepted: ((sessionId?: string) => void) | undefined,
          steer: boolean,
          promptId: string | undefined,
          handedOn: () => void,
          expectedSessionId?: string,
          seeded = false,
          fromTrust?: HeldSend,
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
                        void send(text, attachments, accepted, steer, promptId, expectedSessionId).catch(
                          () => undefined,
                        )
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
          const switchPromptId = promptId ?? crypto.randomUUID();
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
          const heldForTrust = fromTrust ?? heldPrompt.take();
          const kept = heldForTrust ?? (client.selectedSession ? client.bindSendGesture(sendPromptId) : undefined);
          const sessionId = await client.ensureSession().catch((error: unknown) => {
            // A folder harness that waits for Enable or Trust says so on its own card.
            setBlockedHarness(harnessBlock(error));
            // A refused start (a chat on another machine, cx-k21v) says why in this page's own
            // view: the host's typed refusal, already localized, under the localized "Not sent".
            if (isStartRefusal(error)) client.notice(failedSendText(error, false));
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
          await persistSession(sessionId);
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
              () => promptLanded.current(),
            )
            .catch((error: unknown) => refused(error, Boolean(accepted)));
          // The client counts it from here (it registers the send before its first wait).
          handedOn();
          return turn;
        };
        window.cmuxAcpmuxActions = {
          // `accepted` (in-page only): the composer holds the prompt until acpmux takes it.
          // `fromTrust` (in-page only): a prompt the folder's trust held, with its id and ticket.
          "chat.send": ({ text, attachments, accepted, steer, expectedSessionId, fromTrust }) =>
            send(
              String(text ?? ""),
              Array.isArray(attachments) ? attachments : [],
              typeof accepted === "function" ? (accepted as (sessionId?: string) => void) : undefined,
              steer === true,
              undefined,
              typeof expectedSessionId === "string" ? expectedSessionId : undefined,
              false,
              heldPromptParams(fromTrust),
            ),
          "chat.cancel": () => client.cancel(),
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
          "chat.effort": async ({ configId, value, effort, expectedSessionId }) => {
            const summary = snapshotRef.current?.summary;
            if (!configurationSessionMatches(expectedSessionId, summary?.sessionId))
              // l10n-allow: a refusal for the host action's caller, which drops a stale pick; never shown.
              throw new Error("the agent chat session changed");
            const requested = typeof value === "string" && value ? value : String(effort ?? "");
            const resolved = resolveEffortOption(
              summary?.configOptions,
              typeof configId === "string" ? configId : undefined,
            );
            // l10n-allow: a refusal for the host action's caller; the picker offers no effort then.
            if (!resolved || !requested) throw new Error("the session offers no effort option");
            const current = resolved.currentValue;
            if (
              !harnessSwitch.pickConfig(
                resolved.id,
                requested,
                summary?.sessionId
                  ? {
                      sessionId: summary.sessionId,
                      current,
                    }
                  : undefined,
              )
            )
              await client.setConfig(resolved.id, requested);
          },
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
          "chat.new": async ({ harness, cwd, peer, deferred, noProject, model, options, continueWithoutFolder }) => {
            if (noProject === true && continueWithoutFolder === true) {
              let generation = client.trustGeneration;
              const trustGeneration = trustRevision.current;
              const projectGeneration = continuationProjectGeneration.current;
              const holder = composerHandle.current;
              const summary = snapshotRef.current?.summary;
              const intent = switchViewRef.current.intent;
              const selectedHarness = intent?.harness ?? summary?.harness;
              const selectedModel = intent?.config.model ?? summary?.model;
              // A pending harness switch may still hold prompts behind this folder's trust gate.
              // Recovery is a different start, so retire that intent before taking the draft.
              harnessSwitch.cancel();
              return folderContinuation.run({
                start: () => client.startSession(selectedHarness, undefined, undefined, undefined, true, selectedModel),
                current: () =>
                  directClient.current === client &&
                  client.trustGeneration === generation &&
                  trustRevision.current === trustGeneration &&
                  composerHandle.current === holder,
                copyText: (id) => writePersistedDraft(id, holder?.draftText() ?? ""),
                clearFolder: () => setProjectDraft(undefined),
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
            const folder = cwd ? String(cwd) : peer || noProject === true ? undefined : startFolderRef.current;
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
              return harnessSwitch.switchTo(String(harness), folder, {
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
          "chat.harness.hint": async ({ harness }) => harnessSwitch.hint(harness ? String(harness) : undefined),
          "chat.harness.retry": async () => harnessSwitch.retry(),
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
                if (typeof refused?.detail === "string") client.notice(refused.detail);
                else if (refused?.reason === "harness.prompt_unavailable")
                  client.notice(translate("harnesses.enableUnavailable"));
                else if (refused?.code !== "transport.harness_not_confirmed")
                  client.notice(errorMessage(error) || String(error));
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
          "chat.recap.dismiss": async ({ rowId }) => client.dismissRecap(String(rowId)),
          "chat.removeFailedPrompt": async ({ rowId, rowIds }) => {
            for (const id of failedRowIds(rowId, rowIds)) client.removeFailedPrompt(id);
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
            composerHandle.current?.focus();
          },
          // Quote in Reply (the transcript selection menu): the Markdown quote goes after the
          // draft, which stays as typed, and the caret waits in an empty paragraph below it. With no
          // composer mounted (a Sandboxed receipt shows), it waits for the composer to come back.
          "chat.quoteReply": async ({ markdown }) => {
            quoteIntoComposer(composerHandle, heldQuotes, String(markdown ?? ""));
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
              focus: () => composerHandle.current?.focus(),
            });
          },
          // Fork Conversation from the app (the palette's step, the chat's right-click menu, its
          // shortcut): a fork through the chat's latest finished turn, or of a working chat as it is
          // now, opened where the app names (`placement`). A chat that cannot fork says why in its
          // transcript.
          "chat.forkTo": async ({ placement }) => {
            const shown = snapshotRef.current;
            const refusal = shown ? forkRefusal(shown) : "unavailable";
            const target = shown ? forkToTarget(shown) : undefined;
            if (refusal || target === undefined) {
              client.notice(
                refusal === "nothingYet" ? translate("notice.forkNothingYet") : translate("notice.forkFailed"),
              );
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
              focus: () => composerHandle.current?.focus(),
            });
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
          "chat.side": async ({ throughSeq }) => {
            // The chat it is beside, read before the fork (the reader may open another chat meanwhile).
            const chat = client.selectedSession;
            const sessionId = await client.forkAside(Number(throughSeq));
            if (!sessionId || !chat) return;
            // acpmux marks it the chat's side chat; the app only opens it beside the chat.
            await client.markSide(sessionId, chat);
            await postNative("chat.sideChat", { sessionId });
          },
          // An offer's Start (cx-807da): the offered chat starts beside this one, which stays shown.
          // `worktree`: the task's Options > Start in a new worktree, else the agent's ask.
          "chat.offer.start": async ({ offerId, worktree }) => {
            const chat = client.selectedSession;
            const offer = client.offer(String(offerId));
            if (!chat || !offer) throw new Error(translate("offer.failed"));
            const fresh = typeof worktree === "boolean" ? worktree : offer.worktree;
            const cwd = fresh ? await offerWorktree(callNative, offer) : offer.cwd;
            return client.startOffer(chat, offer, cwd);
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
          // its own tab and brings this one back to the chat.
          "chat.handoff.prepare": async ({ harness }) => {
            harnessSwitch.cancel();
            return client.continueIn(String(harness));
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
            return {
              ...composer,
              ...(attachments.length ? { attachments } : {}),
              ...(subagentDrafts ? { subagentDrafts } : {}),
              ...(anchor ? { scrollAnchor: anchor } : anchor === null ? { atLatest: true } : {}),
            };
          },
        };
        // An adoption that came while this page was still connecting runs on this client.
        runPendingAdoption.current();
        // The host may now hand this page (a prewarmed New Tab page) to a tab opening an existing
        // chat: its actions answer, so the switch attaches at once (NewTabSparePool.servesChat).
        if (!mock) void postNative("pane.clientReady", { ready: true }).catch(() => undefined);
        // The native context menu's Copy Message and Fork from Here act on the row under the pointer.
        setMessageMenuSource((rowId) =>
          snapshotRef.current ? messageMenuTarget(snapshotRef.current, rowId, opensSideChat.current) : undefined,
        );
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
        const ticket = pendingTicket;
        pendingPrompt = undefined;
        pendingAttachments = undefined;
        pendingHarness = undefined;
        pendingModel = undefined;
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
              if (!cancelled && directClient.current === client) client.notice(errorMessage(error) || String(error));
            },
          );
        } else if (harness && hasPrompt) {
          void harnessSwitch.switchTo(harness, host.cwd, { model });
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
          void harnessSwitch.switchTo(harness, host.cwd, { model });
      } catch (error) {
        if (!cancelled) {
          acpWire.lifecycle("handshake failed", { message: String(error) });
          setSnapshot((current) => ({ ...current, connection: `connecting: ${String(error)}` }));
          // A chat too large to open says so in plain words; the reply's byte count stays in the log.
          const tooLarge = hostRefusedTooLarge(error);
          setHostError(tooLarge ? translate("host.tooLarge") : errorMessage(error) || String(error));
          setHostFailure(error);
          failingSince ??= Date.now();
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
            retryTimer = window.setTimeout(() => void connectHost(), retryDelay);
            retryDelay = nextRetryDelay(retryDelay, reconnect || recovering);
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
    // These are stable for the pane's life (state, provider client, a memoized bridge callback, and
    // the early New Tab flag, one object from a useState initializer).
  }, [
    connectedClients,
    folderContinuation,
    harnessSwitch,
    newChatPrewarm,
    queryClient,
    toggleInspector,
    earlyNewTab,
    restartGate,
    sandbox,
    cloudTypingPrewarm,
  ]);
  const registryChips = (window.cmuxAcpmuxRegistry as unknown as Record<string, unknown> | undefined)?.composerChips as
    | React.ComponentType<{ snapshot: AcpmuxSnapshot }>
    | undefined;
  const ComposerChips = registryChips ?? DefaultComposerChips;
  // The catalog arrives through the query cache, which composerSnapshot carries.
  // A socket the pane is already asking for again is quiet in the header; only a failure said above
  // the composer is a failure.
  const header = paneHeader(composerSnapshot, t, { hostRecovering: !hostErrorShown });
  // The pane header never says where the chat runs (Leo 2026-10-26); Session Info's Environment does.
  const handoffTargets = continueTargets(composerSnapshot.catalog, snapshot.summary?.harness, snapshot.summary?.family);
  const canContinue = continueAvailable;
  const ignoreFailure = (result: Promise<unknown>) => void result.catch(() => undefined);
  /// Shared by the chat composer and New Tab: cmux-owned slash commands never fall through to a
  /// literal harness prompt. A string is an inline refusal; Composer/NewTab keep the draft intact.
  const handleCmuxCommand = (command: CmuxCommand, args?: string, fresh = false): CmuxCommandResult => {
    const refusal = cmuxCommandRefusal(command, args, {
      summary: !fresh && !!snapshot.summary,
      forkable: !fresh && forkable && forkSeq !== undefined,
      sideAvailable: !fresh && localCwd !== undefined && !quick,
      canContinue: !fresh && canContinue,
      sideSessions: opensSideSessions,
      session: !fresh && !!snapshot.sessionId,
      isSideSession,
      targets: fresh ? [] : handoffTargets,
      cwd: snapshot.summary?.cwd,
      newTab: fresh,
    });
    if (refusal) return t(refusal);
    if (command.action === "status") {
      setStatusCardOpen(true);
      return true;
    }
    // /resume: the chats search, the same page Show all chats and Cmd-K open, where an earlier chat
    // opens again where it left off.
    // A harness other than Claude Code that lists its own /resume or /login keeps it, as before. On
    // New Tab the pane's last chat is not the one being started, so cmux's own command runs there.
    if (
      !fresh &&
      (command.action === "resume" || command.action === "login") &&
      agentKey(snapshot.summary?.family ?? snapshot.summary?.harness) !== "claude" &&
      snapshot.commands?.some((own) => own.name.toLowerCase() === command.name)
    )
      return CMUX_PASS_THROUGH;
    if (command.action === "resume") {
      showAllChats();
      return true;
    }
    if (command.action === "login") {
      // New Tab picks its own harness and machine, which this pane's sign-in answer is not about;
      // its sign-in card covers it. The default login runs only for a chat acpmux says is here.
      if (fresh) return t("composer.cmuxLoginElsewhere");
      const harness = sessionAuth.harness ?? snapshot.summary?.harness ?? healthHarness;
      const declared = composerSnapshot.catalog.find((entry) => entry.id === harness)?.auth?.login;
      const login = slashLogin(sessionAuth, healthLocal ? declared : undefined);
      if (!login) return authText(sessionAuth, t) ?? t("composer.cmuxLoginElsewhere");
      if (login.kind === "session") signIn.loginSession?.(sessionAuth);
      else signIn.logIn(harness ?? "", login.command);
      return true;
    }
    const argument = args?.trim();
    // `/cd` is the folder chip's pick, typed: a chat with no turn yet starts in the folder, a
    // started one opens a new chat there (chooseProject). Bare, it opens the folder browser.
    if (command.action === "cd") {
      if (!argument)
        return callNative<{ cwd?: string }>("project.browse").then((result) => {
          if (result?.cwd) return chooseProject(result.cwd);
        });
      const folder = cdFolder(argument, snapshot.summary?.cwd);
      if (!folder) return t("composer.cmuxCdPath");
      const summary = snapshot.summary;
      const peer = summary?.peer || (summary?.hostKind === "cloud" ? summary.host : undefined);
      let refused = false;
      return chooseProject(folder, peer, () => {
        refused = true;
      }).then(() => {
        if (refused) throw new CmuxCommandRefused(t("composer.cmuxCdNotFolder", { folder }));
      });
    }
    // The composer sends the prompt as typed through onSend, attachments and steer included, the
    // way any other prompt goes.
    if (command.action === "passThrough") return CMUX_PASS_THROUGH;
    // GUI-native commands are available even when a harness does not advertise an ACP command.
    // Arguments keep the harness form useful (`/model opus`, `/plan explain`). New Tab has no chat
    // to act on yet, so there they go to the harness as typed.
    if (command.action === "model") {
      if (argument || fresh) return CMUX_PASS_THROUGH;
      return openPicker(translate(PICKER_LABELS.model)) || CMUX_PASS_THROUGH;
    }
    if (command.action === "context") {
      if (argument || fresh) return CMUX_PASS_THROUGH;
      if (sessionInfo.reveal) {
        sessionInfo.reveal("context");
        return true;
      }
      return CMUX_PASS_THROUGH;
    }
    // A bare `/plan` with a Plan mode is the composer's own Plan/Build toggle (it remembers the mode
    // to return to); anything else goes to the harness as typed.
    if (command.action === "plan") return CMUX_PASS_THROUGH;
    if (command.action === "fast") {
      if (argument || fresh) return CMUX_PASS_THROUGH;
      const option = snapshot.summary?.configOptions?.find(isFastModeOption);
      if (option) {
        const off =
          option.options.find((choice) => /^(off|false|disabled)$/i.test(choice.value))?.value ??
          option.options[0]?.value;
        const on =
          option.options.find((choice) => /^(on|true|enabled|fast|priority)$/i.test(choice.value))?.value ??
          option.options.find((choice) => choice.value !== off)?.value;
        const next = option.currentValue === off ? on : off;
        if (next) return callNative("chat.effort", { configId: option.id, value: next });
      }
      return CMUX_PASS_THROUGH;
    }
    if (command.action === "btw") {
      const question = args?.trim();
      const sessionId = snapshot.sessionId;
      const client = directClient.current;
      if (!question || !sessionId || !client) return false;
      btwNotes.ask(
        sessionId,
        question,
        [...turnRowsShown].reverse().find((row) => ![WORKING, THINKING, ACTIVITY_LINE, DATE].includes(row.kind)),
        (question, sessionId) =>
          askBtwQuestion(client, question, sessionId, {
            inline: (question, sessionId) =>
              postNative<{ text: string }>("chat.btw.inline", { question, sessionId }).then((reply) => reply.text),
            openSide: (sessionId) => postNative("chat.sideChat", { sessionId }),
            discardSide: (sessionId) => client.discard(sessionId),
            openedMessage: () => translate("sideQuestion.opened"),
            staleMessage: () => translate("error.notOpen"),
          }),
      );
      // The pending aside keeps the whole question; typing and the main turn continue.
      return true;
    }
    if (command.action === "fork" || command.action === "side") {
      ignoreFailure(callNative(command.action === "side" ? "chat.side" : "chat.fork", { throughSeq: forkSeq }));
      return true;
    }
    if (command.action === "continue") {
      if (!args?.trim()) {
        setContinuing(true);
        return true;
      }
      const target = resolveHarnessTarget(args, handoffTargets);
      if (!target) return t("composer.cmuxContinueUnknown");
      setContinuing(false);
      ignoreFailure(callNative("chat.handoff.prepare", { harness: target.id }));
      return true;
    }
    return false;
  };
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
    const notice = (text: string) => ignoreFailure(openClient().then((client) => client.notice(text)));
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
  const { sideTabs, pullRequest: headerPullRequest, moves, moveTargets, lit: litSplits } = useHeaderState();
  // The moves the chat's own right-click menu offers now: the composer's picker offers the same.
  const offloads = useMemo(
    () => (["move", "bringBack"] as const).filter((kind) => moves.includes(CONNECT_ACTIONS[kind])),
    [moves],
  );
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
  // The session's own avatar (its cards and sender chip draw it): the menu offers Remove Avatar with one.
  const avatarSrc = useAgentAvatar(snapshot.sessionId);
  const avatar = avatarRows(
    { sessionId: snapshot.sessionId, hasAvatar: avatarSrc !== undefined },
    {
      set: () => snapshot.sessionId && ignoreFailure(setAgentAvatar(snapshot.sessionId)),
      remove: () => snapshot.sessionId && ignoreFailure(removeAgentAvatar(snapshot.sessionId)),
    },
    t,
  );
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
  const readTabState = () => callNative("pane.tabState").then(setHeaderState);
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
    if (!quick) void readTabState().catch(() => undefined);
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
  const lastForkSeq = latestForkSeq(snapshot.rows);
  const sideChat = sideChatRow(
    // Quick Chat's panel is not a tab: there is no split to open beside it.
    { canFork: forkable, throughSeq: lastForkSeq, local: localCwd !== undefined && !quick },
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
  const chatMenu = (): ChatMenuItem[] => {
    const link = snapshot.sessionId ? sessionLink(snapshot.sessionId) : undefined;
    // Pause or Resume the chat's Cloud machine (cloudMachineMenu.ts), as the account's machines in
    // the composer's machine list are.
    const machine = !quick
      ? cloudMachineRows(
          chatMachine,
          snapshot.isWorking,
          t,
          (method, params) => callNative(method, params),
          (picked) => void readUntilMoved(picked),
          () => {
            const client = directClient.current;
            return { session: client?.shownSession()?.sessionId, running: client?.turnRunning() ?? false };
          },
          (session) =>
            stopWaiter.wait(() => {
              const client = directClient.current;
              return client !== undefined && client.shownSession()?.sessionId === session && client.turnRunning();
            }),
          snapshot.sessionId,
        )
      : [];
    const copy = copyRow(
      { link, rows: snapshot.rows, sessionId: snapshot.sessionId },
      (text) => ignoreFailure(copyText(text)),
      t,
      () => window.cmuxAcpmuxBridge?.conversationMarkdown?.() ?? Promise.resolve(null),
      // The same Markdown through the host's save panel; a host without one copies it instead.
      () =>
        void (window.cmuxAcpmuxBridge?.conversationMarkdown?.() ?? Promise.resolve(null)).then(async (markdown) => {
          if (!markdown) return;
          const outcome = await saveDocumentNatively(markdown, snapshot.summary?.title ?? "", "markdown");
          if (outcome === "unavailable") ignoreFailure(copyText(markdown));
        }),
    );
    // Fork immediately; destination choices are a separate action and Option-click shortcut.
    const fork =
      forkable && lastForkSeq !== undefined ? forkMenuRows(lastForkSeq, () => turnActions.fork?.(lastForkSeq), t) : [];
    // New side chat, New terminal and New browser: something new beside the chat, every time.
    const opensBeside = opensBesideRows({ sideChat, quick }, { terminal: newTerminal, browser: newBrowser }, t);
    const continueIn: ChatMenuItem[] =
      snapshot.canHandoff && handoffTargets.length > 0
        ? [
            {
              key: "continue",
              label: handoffLabels.continueIn,
              icon: "agent.handoff",
              disabled: !canContinue,
              children: handoffTargets.map((target) => ({
                key: target.id,
                label: target.name,
                onSelect: () => ignoreFailure(callNative("chat.handoff.prepare", { harness: target.id })),
              })),
            },
          ]
        : [];
    const replay: ChatMenuItem[] =
      !quick && snapshot.sessionId && experimentArm(sessionReplay) === "on"
        ? [
            {
              key: "replay",
              label: t("replay.open"),
              icon: "history",
              onSelect: () => setReplaying(snapshot.sessionId),
            },
          ]
        : [];
    // The chat folder's CLAUDE.md or AGENTS.md, in a file tab beside the chat (a tab: not Quick Chat).
    const instructions = quick
      ? undefined
      : instructionsRow({ cwd: localCwd, family: summary?.family || summary?.harness }, openInstructions);
    // Files every chat in the folder reads: copied into it and named in that file (cx-ncc.67).
    const projectFiles = quick
      ? undefined
      : projectFilesRow({ cwd: localCwd, family: summary?.family || summary?.harness }, (cwd, name) =>
          ignoreFailure(callNative("project.addFiles", { cwd, name })),
        );
    const display = {
      key: "display",
      label: t("chatDisplay.menu"),
      onSelect: () =>
        setDisplayAnchor(
          Array.from(document.querySelectorAll<HTMLElement>(".acpmux-header-tools button")).find(
            (button) => button.getAttribute("aria-label") === t("chatMenu.open"),
          ) ?? document.querySelector<HTMLElement>(".acpmux-header-tools"),
        ),
    };
    // Normal, Thinking or Verbose for this chat, then Wrap lines (every command's output) and
    // Text & Width… under them in one submenu (header/transcriptViewRow.ts): the menu is full
    // height, and a row more pushes Archive off it.
    const transcriptView = presentationRow(snapshot.sessionId, t, [wrapOutputRow(t), display]);
    const tools: ChatMenuItem[] = [
      transcriptView ?? { ...display, icon: "site.permission.localfonts" },
      ...replay,
      ...(instructions ? [instructions] : []),
      ...(projectFiles ? [projectFiles] : []),
      {
        key: "inspector",
        label: t("inspector.title"),
        icon: "code",
        onSelect: () => {
          inspectorOpener.current = Array.from(
            document.querySelectorAll<HTMLElement>(".acpmux-header-tools button"),
          ).find((button) => button.getAttribute("aria-label") === t("chatMenu.open"));
          toggleInspector(true);
        },
      },
      // Quick Chat's panel has no right column for it.
      ...(quick
        ? []
        : [
            {
              key: "backgroundTasks",
              label: t("backgroundTasks.title"),
              icon: "task.status.backlog",
              // A workflow's side tab would cover the panel (a full-height overlay): it closes.
              onSelect: openBackgroundPanel,
            },
          ]),
      ...(checkpoints.supported
        ? [
            {
              key: "checkpoint",
              label: checkpointLabels.createCheckpoint,
              icon: "action.review",
              onSelect: checkpoints.show,
            },
          ]
        : []),
      // Revoke Granted Access: the chat's grants, revocable with default settings (header/grantsMenu.ts).
      ...revokeAccessRows(accessGrants, t),
    ];
    // Move to machine and Delete were the title's menu rows until the title became plain text
    // (header/ThreadTitle.tsx); they live here so no action is lost. Cloud targets come from the
    // host's live MachineRegistry list and dispatch through the existing CloudMove action.
    const sessionId = snapshot.sessionId;
    const client = directClient.current;
    // A menu kept open across a chat switch never moves or deletes the chat now shown.
    const sameChat = () =>
      client !== undefined && client === directClient.current && client.selectedSession === sessionId;
    const guarded = (row: ChatMenuItem | undefined): Exclude<ChatMenuItem, "separator">[] =>
      row ? guardedChatMenu([row], sameChat).filter((item) => item !== "separator") : [];
    const moveMachine = moveMachineRow(
      {
        move: moves.includes(CONNECT_ACTIONS.move),
        bringBack: moves.includes(CONNECT_ACTIONS.bringBack),
        targets: moveTargets,
      },
      {
        moveTo: (id) => moveChatToMachine(id, sessionId),
        bringBack: () => (sessionId ? offloadChat("bringBack", sessionId) : undefined),
      },
      t,
    );
    const remove = sessionId ? guarded(deleteChatRow(requestDelete, t)) : [];
    const moveRow = guarded(moveMachine);
    // Quick Chat's panel is not a tab: only the chat's own actions.
    if (quick) return menuGroups(fork, continueIn, copy ? [copy] : [], moveRow, tools, remove);
    // ChatGPT's order: the chat's name and pin, new chats from it, Copy, where it shows, then Archive.
    return menuGroups(
      [
        {
          key: "rename",
          label: t("chatMenu.rename"),
          icon: "action.edit",
          shortcutAction: HEADER_ACTIONS.rename,
          onSelect: () => runHeaderAction(HEADER_ACTIONS.rename),
        },
        {
          key: "pin",
          label: headerState().pinned ? t("chatMenu.unpin") : t("chatMenu.pin"),
          icon: "action.pin",
          shortcutAction: HEADER_ACTIONS.pin,
          onSelect: () => runHeaderAction(HEADER_ACTIONS.pin),
        },
      ],
      [...opensBeside, ...fork],
      continueIn,
      copy ? [copy] : [],
      [
        {
          key: "moveRight",
          label: t("chatMenu.moveRight"),
          icon: "pane.split.right",
          shortcutAction: HEADER_ACTIONS.moveRight,
          onSelect: () => runHeaderAction(HEADER_ACTIONS.moveRight),
        },
        {
          key: "newWorkspace",
          label: t("chatMenu.newWorkspace"),
          icon: "workspace.new",
          shortcutAction: HEADER_ACTIONS.newWorkspace,
          onSelect: () => runHeaderAction(HEADER_ACTIONS.newWorkspace),
        },
        {
          key: "newWindow",
          label: t("chatMenu.newWindow"),
          icon: "app.open.external",
          shortcutAction: HEADER_ACTIONS.newWindow,
          onSelect: () => runHeaderAction(HEADER_ACTIONS.newWindow),
        },
        ...(headerState().floatingChat && snapshot.sessionId
          ? [
              {
                key: "floatingChat",
                label: t("chatMenu.floatingChat"),
                icon: "site.permission.windowmanagement",
                onSelect: () => runHeaderAction(HEADER_ACTIONS.floatingChat),
              },
            ]
          : []),
      ],
      [...moveRow, ...machine],
      tools,
      [
        ...avatar,
        ...(markUnread ? [markUnread] : []),
        ...(archive ? [archive] : []),
        ...remove,
        {
          key: "close",
          label: t("chatMenu.close"),
          icon: "tab.close",
          shortcutAction: HEADER_ACTIONS.close,
          onSelect: () => runHeaderAction(HEADER_ACTIONS.close),
        },
      ],
    );
  };
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
  if (newTab !== undefined && !handshaken && hostError !== undefined) composerStoodIn.current = true;
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
  const commandRevision = clientSnapshot.sessions.find((session) => session.sessionId === commandSession);
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
        setImportError(errorMessage(error) || t("composer.cmuxImportFailed"));
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
  // change. Debug Settings `newTab.privateChatLists`, a page on another machine's daemon and a page
  // whose daemon is down list this page's own (`sharesChatList`).
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
        cloudReservation.typed(text);
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
        cloudReservation.typed(text);
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
  const onCloudMachinePicked = useCallback((machine: CloudMachine | undefined) => {
    cloudDraftMachineID.current = machine?.id ?? null;
  }, []);
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
  const newTabProjects = useMemo(() => {
    const byPath = new Map<string, Project>();
    // A folder the host listed keeps its repository (projectRepos.ts) when a chat names it again.
    const listed = (cwd: string): Project => {
      const repo = byPath.get(cwd)?.repo;
      return { cwd, label: projectLabel(cwd), ...(repo ? { repo } : {}) };
    };
    for (const project of directProjects) byPath.set(project.cwd, project);
    for (const path of newTab?.projects ?? []) byPath.set(path, listed(path));
    for (const session of newTabSnapshot.sessions) {
      if (typeof session.cwd !== "string" || !session.cwd) continue;
      if (session.host && session.hostKind !== "local") continue;
      byPath.set(session.cwd, listed(session.cwd));
    }
    if (newTab?.cwd) byPath.set(newTab.cwd, listed(newTab.cwd));
    // The pickers list repositories in the order of their newest folder: the folder of the newest chat first.
    return byRecentUse([...byPath.values()], recentLocalFolders(newTabSnapshot.sessions));
  }, [newTabSnapshot.sessions, newTab?.cwd, newTab?.projects, directProjects]);
  // The new chat's hero picker (cx-9g0w): this Mac's projects, then other machines' folders from
  // their chats (each with its machine's name), Add project and Do not work in a project.
  const heroPicker = useMemo<EmptyStateProjects | undefined>(() => {
    if (!freshChat || quick) return undefined;
    const remote = new Map<string, Project>();
    for (const session of composerSnapshot.sessions) {
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
  }, [
    freshChat,
    quick,
    composerSnapshot.sessions,
    composerSnapshot.summary,
    newTabProjects,
    chooseProject,
    chooseFolder,
  ]);
  // The hero's start as it shows (its project, Do not work in a project), first frame to final
  // (perf.ts noteStartState). Only a new chat with no session yet, not under a New Tab page.
  const heroShown =
    heroPicker && freshView && !snapshot.sessionId && !showNewTab
      ? `hero:${projectName(composerSnapshot.summary?.cwd) ?? ""}:${heroPicker.noProject ? 1 : 0}`
      : undefined;
  useEffect(() => {
    if (heroShown !== undefined) acpmuxPerf.noteStartState(heroShown);
  });
  // Stable: memoized transcript rows compare it.
  const toggleActivity = useCallback((id: string) => {
    const view = chatViewRef.current;
    // In Thinking and Verbose a turn's "Worked for" is open unless toggled there (viewFolds.ts):
    // the reader's open or close overrides the view, and Normal's own folds stay as they were.
    if (view !== "normal" && isWorkedFold(id))
      setViewToggles((current) =>
        new Map(current).set(view, toggleViewTurnFold(turnRowsRef.current, current.get(view) ?? NO_FOLD_TOGGLES, id)),
      );
    else setExpanded((current) => toggleTurnFold(turnRowsRef.current, current, id));
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
  // What the chat waits on the person for: the running turn's line says it, never "Thinking".
  const waiting = chatWaitsOn({
    trust: trustAsk.ask,
    isWorking: snapshot.isWorking,
    individualPermission,
    permissionGroups: snapshot.permissionGroups?.supported ? snapshot.permissionGroups.groups : undefined,
    secret: Boolean(snapshot.secret),
    cards: toolCards,
  });
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
                        <SessionEditsContext.Provider value={editRows}>
                          <SessionCwdContext.Provider value={snapshot.summary?.cwd}>
                            <SubagentNavContext.Provider value={setSubagentView}>
                              <SubagentViewsContext.Provider value={readSubagentView}>
                                <SubagentPaneContext.Provider value={showSubagent}>
                                  <WorkingCountsContext.Provider value={workingCounts}>
                                    <WaitingOnContext.Provider value={waiting}>
                                      <SubagentStopContext.Provider value={stopSubagent}>
                                        <SubagentClockContext.Provider value={snapshot.clockOffsetMs ?? 0}>
                                          <SubagentHarnessContext.Provider
                                            value={knownMark(snapshot.summary?.harness, snapshot.summary?.family)}
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
                                                      findRef={findRef}
                                                    >
                                                      {(find) => (
                                                        <VirtualTranscript
                                                          key={chatPresentation}
                                                          topInset={soloUnder ? tabRow.height : 0}
                                                          rows={transcriptRows}
                                                          streams={!childRows}
                                                          earlier={!childRows ? snapshot.earlierPrompts : undefined}
                                                          promptCount={!childRows ? snapshot.promptCount : undefined}
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
                                                          endReserve={previewBeside ? COMPUTER_USE_PREVIEW_RESERVE : 0}
                                                          working={snapshot.isWorking}
                                                          // Its stage positions Jump to latest; the Quick Composer's panel has no room for it.
                                                          jumpButton={!quick}
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
                                                                ? () =>
                                                                    directClient.current?.loadOlder() ??
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
                                                          anchorNow={quick || childRows ? undefined : transcriptAnchor}
                                                          inViewNow={quick || childRows ? undefined : transcriptInView}
                                                          // A prompt goes to the chat, not to the subagent shown in its place.
                                                          sends={childRows ? undefined : sends}
                                                          onFollowingChange={
                                                            childRows ? undefined : onTranscriptFollowingChange
                                                          }
                                                          onAnchor={
                                                            quick || childRows || !shownSessionId
                                                              ? undefined
                                                              : (anchor) => postScrollAnchor(shownSessionId, anchor)
                                                          }
                                                          expanded={folds}
                                                          showMinimap={minimapVisible}
                                                          reveal={childRows ? undefined : revealRow}
                                                          coldOpen={!childRows && opened.cold ? opened.open : undefined}
                                                          onColdOpenShown={coldOpenShown}
                                                          afterLatest={
                                                            !childRows && trayPlacement === "after-latest-message"
                                                              ? trayNode
                                                              : undefined
                                                          }
                                                          registry={registry}
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
                                  </WorkingCountsContext.Provider>
                                </SubagentPaneContext.Provider>
                              </SubagentViewsContext.Provider>
                            </SubagentNavContext.Provider>
                          </SessionCwdContext.Provider>
                        </SessionEditsContext.Provider>
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
      <ThinkingVerbsContext.Provider value={thinkingVerbs}>{transcriptContent}</ThinkingVerbsContext.Provider>
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
  const secret = snapshot.secret;
  const hasPermissionGroups = Boolean(
    snapshot.permissionGroups?.supported &&
    (snapshot.permissionGroups.groups.length > 0 || snapshot.permissionGroups.error),
  );
  const hasBottomAsk = Boolean(
    (trustAsk.ask && (trustAsk.ask.state !== "decided" || trustAsk.ask.level === "untrusted")) ||
    hasPermissionGroups ||
    individualPermission ||
    secret ||
    toolCards.length > 0,
  );
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
        setFolderAsk((current) => current ?? { ...pending, error: errorMessage(error) || String(error) });
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
  const asks = hasBottomAsk ? (
    <div className="acpmux-permission acpmux-asks-stack">
      {trustAsk.ask && (trustAsk.ask.state !== "decided" || trustAsk.ask.level === "untrusted") && (
        <TrustAsk
          ask={trustAsk.ask}
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
          answers={answersTrust}
        />
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
      {(individualPermission || secret || toolCards.length > 0) && (
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
          {secret && (
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
        setFolderError(errorMessage(error) || undefined);
        if (request?.deferPick) throw error;
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
  const composer = readOnlySubagent ? (
    <SubagentComposer
      key={subagentDraftKey}
      subagent={shownSubagentTarget?.name ?? t("tray.kind.subagent")}
      chat={chatName}
      draftKey={subagentDraftKey}
      onSend={sendToSubagent}
    />
  ) : (
    !reviewing && (
      <>
        <PaneNotices onAction={(id) => void callNative("pane.noticeAction", { id }).catch(() => undefined)} />
        <Notice id="dictation" tier="error" when={dictation.notice?.message}>
          <DictationNotice dictation={dictation} />
        </Notice>
        <Notice id="import-error" tier="error" when={importError}>
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
          <Notice
            id="switch"
            tier={snapshot.switching?.phase === "deferred" ? "status" : "error"}
            when={snapshot.switching && snapshot.switching.phase !== "starting"}
          >
            <SwitchNotice
              switching={snapshot.switching}
              onRetry={() => void callNative("chat.harness.retry")}
              // The refused prompt is back in the composer; a chat on another machine starts only
              // with a send, so the share's retry sends it again (as Trust's answer does).
              onShared={() => void callNative("chat.harness.retry").then(() => composerHandle.current?.send())}
              onAction={(action) => {
                // A fresh chat on another machine has no summary yet: its connection's origin, or a
                // folder list its host marked as that machine's, says where it runs.
                const elsewhere =
                  remoteChat || snapshot.origin === "remote" || snapshot.origin === "peer" || Boolean(machineFolders);
                const route = startRefusalRoute(action, elsewhere);
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
                (error: unknown) =>
                  setFolderNeeded((current) => current && { ...current, error: errorMessage(error) || String(error) }),
              );
            }}
          />
        </Notice>
        {!showNewTab && folderAskView}
        {/* The private folder's line is the folder chip's menu's (Composer `folderNote`); only the
            host's refusal of its Choose folder… stands over the composer, with the line to retry. */}
        <Notice id="folder-choice" tier="error" when={folderChoiceOffered && folderError}>
          <FolderChoice error={folderError} onChoose={chooseWorkspaceFolder} />
        </Notice>
        <Notice id="background" tier="status" when={background.notice}>
          <output className="acpmux-switch-notice acpmux-background-notice">
            {background.notice && t(BACKGROUND_NOTICE_TEXT[background.notice])}
          </output>
        </Notice>
        {!showNewTab && <AutoResumeNotice state={snapshot.autoResume} />}
        <Notice
          id="worktree-creating"
          tier="status"
          when={inThisVisit(worktreeCreating, snapshot.sessionId, visitNow) && freshChat && !snapshot.sessionId}
        >
          <output className="acpmux-switch-notice acpmux-worktree-creating">{t("worktree.creating")}</output>
        </Notice>
        <Notice
          id="worktree-error"
          tier="error"
          when={inThisVisit(worktreeError, snapshot.sessionId, visitNow) && freshChat && !snapshot.sessionId}
        >
          <WorktreeFailure error={worktreeError?.message ?? ""} onDismiss={() => setWorktreeError(undefined)} />
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
              onHide={() => {
                takeOverManaged(shownSessionId);
                setTakenOverAt(Date.now());
                composerHandle.current?.focus();
              }}
            />
          )}
        </Notice>
        {/* The tray (subagents/SubagentTray.tsx): in the bottom stack, right above the composer, every
          running or recently ended subagent, background command and started chat, one card each. */}
        {/* Tucked away (chatDisplay.ts TRAY_TUCKED_KEY), the hat leaves only its pull tab at the
            composer's top middle (subagents/TrayPullTab.tsx). */}
        {trayPlacement === "tray" &&
          (trayTucked && trayNode ? (
            <TrayPullTab
              chat={shownSessionId}
              {...pullTabCounts(trayList, waitingAgents)}
              working={hatPlan !== undefined && hatPlan.length > 0}
              side={trayHandle}
            />
          ) : (
            trayNode
          ))}
        {statusCardOpen && (
          <HarnessStatusCard
            summary={snapshot.summary}
            rows={snapshot.rows}
            onDismiss={() => setStatusCardOpen(false)}
          />
        )}
        {/* An attached image opens in the chat's image viewer, as a transcript image does. */}
        <ImageViewerContext.Provider value={openImage}>
          <Composer
            locked={cloudStarting}
            snapshot={composerSnapshot}
            headerCwd={snapshot.summary?.cwd ?? ""}
            sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
            placeholder={isSideSession ? t("sideSession.placeholder") : undefined}
            switching={Boolean(switchView.intent)}
            // An existing chat being restored or opened (no handshake yet, or its session not
            // attached) draws no new chat's folder and environment strip.
            chatKnown={paneKnowsNewChat({ handshaken, newSession }, composerSnapshot)}
            chips={ComposerChips}
            onOpenContext={sessionInfo.reveal ? () => sessionInfo.reveal?.("context") : undefined}
            draft={draft}
            onUnsentDraft={quick ? undefined : onNewChatDraft}
            onTyping={quick ? undefined : onCloudTyping}
            onCloudMachinePicked={quick ? undefined : onCloudMachinePicked}
            onPromptEdit={quick ? undefined : wakeOnTyping}
            onSuggestionTaken={() => directClient.current?.takeSuggestion()}
            keptAttachments={quick ? undefined : keptAttachments}
            onCmuxCommand={handleCmuxCommand}
            onSend={(text, chips, steer) => {
              // A Sandboxed new chat: the message runs once on a throwaway VM, through the
              // host, and the chat shows its receipt; no acpmux chat starts.
              // While the tab's run holds the chat nothing else sends as Sandboxed (the composer keeps
              // the prompt); a composer kept for a refused draft sends as Persistent once picked.
              // The Trust continuation uses ComposerHandle.send(force), but never bypasses auth.
              if (authBlock) return false;
              if (sandboxHoldsChat && !sandboxDraftMoved) return false;
              if (cloudPicked) {
                // The chat's project, copied to the machine; none: the machine's own folder (cloudStartFolder).
                const refused = sendToCloud(
                  text,
                  shellContextAttachments(chips ?? [], (id) => shellRuns.get(id)),
                  {
                    ...cloudStartFolder(projectDraft ?? composerSnapshot.summary?.cwd ?? newTab?.cwd),
                    ...heldPick(composerSnapshot),
                  },
                );
                if (refused) directClient.current?.notice(refused);
                return false;
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
              // Shell mode's chips carry their commands' output as it is now.
              const attachments = shellContextAttachments(chips ?? [], (id) => shellRuns.get(id));
              // The folder's trust holds prompts: this one waits in the pane and goes after Trust
              // (trustHeld.ts). One sent while earlier held prompts still go waits behind them, so
              // none overtakes another.
              if (trustHolds || trustHeld.pending()) {
                trustHeld.hold(text, attachments);
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
                  startingSends.add(text, attachments, sendWhenTaken(steer === true));
                  return true;
                }
                const holder = composerHandle.current;
                const sentOn = directClient.current;
                callNative("chat.send", { text, attachments, steer }).then(
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
                    // The connection went before acpmux took it (an acpmux restart or update): the host
                    // sends it again on the next connection, where the chat shows it. Only one that never
                    // shows comes back, saying why (lostPrompt.ts).
                    void resentAfterLoss(error, connectedClients, sentOn).then((shown) => {
                      if (shown) return promptLanded.current();
                      giveBack();
                      directClient.current?.notice(failedSendText(error, false, attachments));
                    });
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
                startingSends.add(text, attachments, sendWhenTaken(steer === true));
                return true;
              }
              let accept: (taken: true) => void = () => undefined;
              const taken = new Promise<true>((resolve) => (accept = resolve));
              const send = async () => {
                // Replying to a View Only chat takes it over first (`takeOver`); while the app that
                // runs it still does, the pane asks how, and the composer keeps the message.
                if (snapshot.summary?.watching && !(await directClient.current?.takeOver())) {
                  throw new Error("watch.notTakenOver");
                }
                if (projectDraft && !snapshot.sessionId)
                  // The chat's start is part of this send: a trust refusal there asks the folder's
                  // question, keeps this prompt (with its send's gesture) and sends it after Trust
                  // (cx-nn3e P0b; the prompt was lost when only the start ran again).
                  await callNative("chat.new", {
                    cwd: projectDraft,
                    peer: directClient.current?.newChatPeer(),
                    ...heldPick(snapshot),
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
                return callNative("chat.send", {
                  text,
                  attachments,
                  accepted: () => accept(true),
                  steer,
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
                  directClient.current?.notice(failedSendText(error, false, attachments));
                }
                throw error;
              });
              if (queues) {
                startingSends.add(text, attachments, () => held);
                return true;
              }
              held.catch(() => {
                if (composerHandle.current === holder) return;
                if (composerHandle.current) composerHandle.current.restore(text, attachments);
                else heldBack.current = [...(heldBack.current ?? []), { text, attachments }];
              });
              return held;
            }}
            // A prompt held while the agent starts goes back to the composer; else Stop stops the turn.
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
                      const fail = (error: unknown) => setBtwFailure({ sessionId, reason: errorMessage(error) });
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
            onProject={chooseProject}
            // A machine with no folder known here: the new chat starts there, in its default folder.
            onComputer={(computer) => {
              // Switching away from an explicitly selected Cloud machine must not leave a stale
              // draft target that a later keystroke could wake.
              cloudDraftMachineID.current = null;
              void callNative("chat.new", computer === "local" ? {} : { peer: computer }).catch(() => undefined);
            }}
            // A chat on a Cloud machine whose first send has not run: another Cloud machine picked moves it
            // there and sends its first prompt again (cloudRepick.ts), instead of a new empty chat.
            {...(snapshot.summary?.hostKind === "cloud" && !quick
              ? { onRepick: (machine: RepickMachine) => repickCloudChat(callNative, machine) }
              : {})}
            onNewWorktree={freshChat && !quick && !remoteChat ? startInWorktree : undefined}
            onConnect={connectMachine}
            // The floating chat has no tab to move.
            {...(quick ? {} : { onOffload: offloadChat, offloads })}
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
                    ...(remoteChat
                      ? {}
                      : {
                          onBrowse: () => callNative<{ cwd?: string }>("project.browse").then((result) => result?.cwd),
                        }),
                  },
                }
              : {})}
            {...(folderChoiceOffered ? { folderNote: t("agentHome.notice") } : {})}
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
            // The host runs commands on this Mac: a Cloud chat has no shell mode.
            onShell={
              composerSnapshot.summary?.hostKind === "cloud"
                ? undefined
                : (command) =>
                    shellRuns.start(command, {
                      ...(composerSnapshot.summary?.cwd ? { cwd: composerSnapshot.summary.cwd } : {}),
                      ...(snapshot.sessionId ? { sessionId: snapshot.sessionId } : {}),
                    })
            }
            localName={thisMacName(localMachineName, machineName, composerSnapshot.summary)}
            environments
            {...(sandboxOffered ? { runMode: composerModeRows } : {})}
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
            upload={uploadFiles}
            // A chat on this Mac (as Sources' + below); the host refuses any other.
            localPaths={localCwd !== undefined && !quick && !readOnlySubagent ? localPaths : undefined}
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
            blocked={trustSendOff || !trustAsk.blocked?.reason ? trustAsk.blocked : undefined}
            blockSend={blockSend}
            closeOnTrustAsk={Boolean(
              trustAsk.ask && (trustAsk.ask.state !== "decided" || trustAsk.ask.level === "untrusted"),
            )}
            // A preflight still disables sending, but must not insert then remove a checking row
            // above the already-painted composer. Settled authentication failures keep their notice.
            authBlock={signInNoticeVisible ? undefined : authBlock}
            authChecking={authPreflightPending}
            authBlocked={Boolean(authBlock)}
            // The composer draws the session's strip before its Send, and Send ends the session.
            accessory={<DictationMic dictation={dictation} strip={false} />}
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
    <Notice id="host-error" tier="error" when={hostError !== undefined && (hostErrorShown || restartingAcpmux)}>
      <HostUnavailableLine
        message={hostWords.line}
        detail={hostWords.detail}
        retrying={retryQueued}
        onRetry={() => retryHost.current?.()}
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
  const hostLine =
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
  // The floating chat's compact bar shows whether the chat is working or waiting on the user, and
  // the reply's last line.
  let lastReply: (typeof snapshot.rows)[number] | undefined;
  for (let index = snapshot.rows.length - 1; index >= 0 && !lastReply; index--) {
    if (snapshot.rows[index]!.kind === "assistant") lastReply = snapshot.rows[index];
  }
  const floatingSession = composerSnapshot.sessions.find((session) => session.sessionId === snapshot.sessionId);
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
          snapshot.sessionId && ownQueue(snapshot.queue).length > 0
            ? new Map([[snapshot.sessionId, ownQueue(snapshot.queue).length]])
            : undefined,
        steeringIds:
          snapshot.summary?.steering && snapshot.sessionId && ownQueue(snapshot.queue).length > 0
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
  const pane = !knowsWhatItIs ? (
    // Clear until it knows: the pane's background shows, never a chat screen a New Tab replaces.
    <ShortcutsContext.Provider value={shortcuts}>
      <section
        ref={setShell}
        className="acpmux-shell"
        data-tab-row={inTabRow ? "" : undefined}
        data-solo-tab={soloTab ? "" : undefined}
        aria-busy="true"
        style={inTabRow ? tabRowStyle(tabRow) : undefined}
      />
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
        <div
          className="acpmux-main"
          data-new-chat={freshView && !showNewTab ? "" : undefined}
          // The transcript runs the pane's height under the bottom stack (bottomStack.css) while the
          // stage shows it; a new chat's hero, a handoff review, the diff and the inspector keep it in flow.
          data-dock={!reviewing && !freshView && !inspectorOpen ? "float" : undefined}
          data-summary={summaryCard.column ? "inline" : "popover"}
          data-cu-preview={previewBeside ? "" : undefined}
        >
          {!harnessesOpen && showNewTab && !newTab.history && (
            // The page's dots, under it: Claude Minimal, Claude Minimal with the quick actions, Codex
            // Minimal (newtab/tabDots.ts, from the look and Minimal's actions widget), then with the
            // style dots on (on Minimal a widget, off by default: newtab/pageWidgets.ts) the page's
            // other styles (newtab/PageDots.tsx); a pick shows in place at once.
            <PageDots
              template={shownTemplate(newTab)}
              styleDots={shownPageWidgets(shownTemplate(newTab), newTab.pageWidgets).has("styleDots")}
              actions={shownPageWidgets("minimal", newTab.pageWidgets).has("actions")}
              callNative={callNative}
              show={(next) => setNewTab((current) => current && { ...current, template: next })}
              showWidgets={(done) => setNewTab((current) => current && withWidgetEdit(current, done))}
              onCancel={() => window.dispatchEvent(new Event(FOCUS_LOCATION_EVENT))}
            />
          )}
          {showNewTab && folderAskView}
          {showNewTab && !newTab.history && shownTemplate(newTab) !== "classic" ? (
            <>
              {/* Setup keeps this page's draft and project, while its hidden input effects stop. */}
              <Activity mode={harnessesOpen ? "hidden" : "visible"}>
                <NewTabScreen
                  onSetup={(resume) => {
                    setupContinuation.current = resume;
                    setHarnessesOpen(true);
                  }}
                  onCmuxCommand={(command, args) => handleCmuxCommand(command, args, true)}
                  onImportFile={importFile}
                  importError={importError}
                  importSandboxed={sandbox.mode === "sandboxed"}
                  onCommands={(harness, cwd) => {
                    void callNative("chat.new", { harness, ...(cwd ? { cwd } : {}), deferred: true }).catch(
                      () => undefined,
                    );
                  }}
                  key={newTabGeneration}
                  environments
                  onLeaveDraft={leaveNewTabDraft}
                  takeDraft={takeNewTabDraft}
                  {...(sandboxOffered || sandboxPickedNotOffered || cloudPickedNotOffered
                    ? {
                        runMode: sandboxModeRows,
                        // A page-side refusal goes to the chat view, which says why (SandboxRunView), with
                        // the prompt and attachments put back in its composer.
                        ...(cloudStart
                          ? {
                              cloudStatus: (
                                <CloudStartView start={cloudStart} bubble={cloudStart.state === "starting"} />
                              ),
                            }
                          : {}),
                        cloudStarting,
                        onCloud: (
                          harness: string,
                          text: string,
                          cwd: string | undefined,
                          model: string | undefined,
                          attachments: ComposerAttachment[],
                        ) =>
                          sendToCloud(
                            text,
                            attachments,
                            {
                              harness,
                              ...cloudStartFolder(cwd),
                              ...(model ? { model } : {}),
                            },
                            true,
                          ),
                        onSandbox: (harness: string, text: string, attachments: ComposerAttachment[]) => {
                          const started = sandboxPickedNotOffered
                            ? sandboxNotNow
                            : startSandbox(text, attachments.length, harness);
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
                  {...(newTab.widgets ? { widgets: true } : {})}
                  pageWidgets={shownPageWidgets(shownTemplate(newTab), newTab.pageWidgets)}
                  {...(newTab.headlineOff ? { headlineOff: true } : {})}
                  {...(newTab.allChats === false ? { allChats: false } : {})}
                  {...(newTab.suggestionOrder ? { suggestionOrder: newTab.suggestionOrder } : {})}
                  {...(newTab.weather ? { weather: newTab.weather } : {})}
                  onEditWidgets={(edit) =>
                    editNewTabWidgets(edit, {
                      callNative,
                      show: (done) => setNewTab((current) => current && withWidgetEdit(current, done)),
                    })
                  }
                  snapshot={commandSession ? { ...newTabSnapshot, commands: pendingCommands ?? [] } : newTabSnapshot}
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
                  {...newTabProjectPick(callNative, sandboxOfferable, cloudFolderGrant.granting)}
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
                      leave: () => setNewTab(undefined),
                      selectSession,
                      showAllChats,
                      runShell: (command, cwd) => {
                        if (cwd) setProjectDraft(cwd);
                        shellRuns.start(command, cwd ? { cwd } : {});
                      },
                    }),
                  )}
                />
              </Activity>
              {harnessesOpen && harnessesPage}
            </>
          ) : harnessesOpen ? (
            harnessesPage
          ) : showNewTab && newTab.history ? (
            <HistoryScreen
              load={(params) => callNative<AllChatsPage | undefined>("chats.page", params)}
              onOpen={(key) => callNative("chats.open", { key })}
              onOpenInTerminal={(key) => void callNative("chats.openInTerminal", { key }).catch(() => undefined)}
              onViewOnly={(key) => void callNative("chats.watch", { key }).catch(() => undefined)}
            />
          ) : showNewTab ? (
            <NewTabPage
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
              onSubmit={newTabPageSubmit({ callNative, whenHandshaken, startChat: chatFromNewTab })}
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
              transcript={(rows) => (
                <VirtualTranscript
                  rows={rows}
                  sessionId={`replay:${replaying}`}
                  // A replay draws under its chat's view too (conversation/viewFolds.ts), as the live transcript.
                  expanded={folds}
                  showMinimap={minimapVisible}
                  registry={registry}
                  onToggleActivity={toggleActivity}
                />
              )}
            />
          ) : (
            <>
              <div
                className={`acpmux-stage${inspectorOpen ? " acpmux-inspecting" : ""}`}
                data-solo-tab={soloUnder ? "" : undefined}
                style={inTabRow ? tabRowStyle(tabRow) : undefined}
              >
                <header className="acpmux-header" data-tab-row={inTabRow ? "" : undefined}>
                  <ChatHeaderStatus status={header.status} detail={header.detail}>
                    {!inTabRow && !showNewTab && snapshot.sessionId && (
                      <ThreadTitle key={snapshot.sessionId} title={chatName} onRename={renameFromTitle} />
                    )}
                  </ChatHeaderStatus>
                  <div className="acpmux-handoff-header-tools" ref={tabRowTools}>
                    <LivePresenceStack
                      sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
                      fallback={snapshot.presence}
                    />
                    {/* No title in the tab row: the pane's tab already names the chat (Leo, 2026-11-01). */}
                    {inTabRow && <ChatHeaderInlineStatus status={header.status} detail={header.detail} />}
                    <ChatHeaderTools
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
                      tabTools={!quick}
                      pullRequestChip={!readOnlySubagent}
                      // A new chat's picked folder too: New Worktree names its branch before the first prompt.
                      folder={localCwd ?? (remoteChat ? undefined : startFolder)}
                      readStatus={readFolderStatus}
                      statusKey={snapshot.isWorking}
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
                      summary={sessionInfo.on ? null : (native) => <SummaryButton card={summaryCard} native={native} />}
                      menu={chatMenu}
                      onMenuOpen={readTabState}
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
                    onReconnect={reconnectPeer}
                    // Only a Cloud machine pauses on its own: an ssh peer's offline copy says so at once.
                    noteDelayMs={snapshot.peerKinds?.[snapshot.peerCopy.peer] === "ssh" ? 0 : undefined}
                  />
                )}
                {/* Computer use's live preview: the app this chat's agent drives, at the top right. Always
                    mounted: with no card it draws the last one's exit, then nothing (cardMotion.ts). */}
                <ComputerUsePreviewCard
                  preview={previewShown ? computerUsePreview : null}
                  onOpen={() => ignoreFailure(callNative("chat.computerUsePreview", { action: "open" }))}
                  onClose={() => ignoreFailure(callNative("chat.computerUsePreview", { action: "close" }))}
                />
                {underHeader.watching && snapshot.summary?.watching && !snapshot.liveTakeOver && (
                  <WatchBanner
                    family={snapshot.summary.watching}
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
                ) : cloudStart && !snapshot.sessionId ? (
                  <CloudStartView start={cloudStart} />
                ) : sandboxView && !snapshot.sessionId && (sandboxHoldsChat || sandbox.mode === "sandboxed") ? (
                  <SandboxRunView
                    run={sandboxView}
                    onCheckAgain={() => void sandbox.read()}
                    unread={sandbox.unread}
                    // Sandboxed can't run here now: the person says how the message goes instead.
                    {...(sandboxRetryable(sandboxView) ? { onPersistent: () => sandbox.setMode("persistent") } : {})}
                  />
                ) : freshView ? (
                  <EmptyState project={projectName(composerSnapshot.summary?.cwd)} picker={heroPicker} />
                ) : (
                  <AgentTonesContext.Provider value={chatTones}>
                    <AgentNamesContext.Provider value={chatAgentNames}>
                      <AgentOpenContext.Provider value={chatAgentOpen}>
                        <BackgroundTaskOutputContext.Provider value={backgroundTaskOutput}>
                          {transcript}
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
                  />
                )}
              </div>
              <div ref={setDock} className="acpmux-dock">
                {asks}
                {/* Between the hero and the docked composer. */}
                {/* A Sandboxed send holds the new chat: no recent chat replaces it while it is out.
                    Neither does a Cloud start's chat, which shows its sent message (CloudStartView). */}
                {freshView && !sandboxHoldsChat && !viewedSandbox && !(cloudStart && !snapshot.sessionId) && (
                  <div className="acpmux-home-area">
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
                <LiveTypingLine
                  sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
                  fallback={snapshot.presence}
                />
                {!showNewTab && composerSnapshot.summary?.goal && (
                  <TaskGoalStrip
                    key={composerSnapshot.summary.sessionId}
                    goal={composerSnapshot.summary.goal}
                    harness={composerSnapshot.summary.harness}
                    command={(action) => {
                      return callNative("chat.send", {
                        text: `/goal ${action === "delete" ? "clear" : action}`,
                        attachments: [],
                      });
                    }}
                  />
                )}
                {/* A draft a refusal put back stays in reach even once the tab's run shows. */}
                {(!sandboxHoldsChat || sandboxDraftMoved) && !viewedSandbox && composer}
              </div>
            </>
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
        {!harnessesOpen && !showNewTab && !(replaying && replaying === snapshot.sessionId) && sessionInfo.panel}
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
            <BackgroundTasksPanel
              groups={backgroundList}
              views={snapshot.subagentViews}
              look={experimentArm(backgroundTasksLook)}
              expanded={backgroundPanel.expanded}
              stopsAgents={stopSubagent !== undefined}
              workflow={backgroundWorkflowReads}
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
  return (
    <SignInContext.Provider value={signIn}>
      <ChatAccountsContext.Provider value={chatAccounts}>
        <UpdateOfferContext.Provider value={updateOffer}>
          <AgentProgressContext.Provider value={progressStore}>
            <NoticeSlot>{pane}</NoticeSlot>
          </AgentProgressContext.Provider>
        </UpdateOfferContext.Provider>
      </ChatAccountsContext.Provider>
    </SignInContext.Provider>
  );
}
