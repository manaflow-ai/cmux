import { composerHealthHarness } from "./composerPickerEntries";
import { forkMenuRows } from "./header/forkMenu";
import { openFork } from "./conversation/openFork";
import { useStopThroughReconnect } from "./stopThroughReconnect";
import React, {
  Activity,
  lazy,
  memo,
  Suspense,
  useCallback,
  useContext,
  useDeferredValue,
  useEffect,
  useLayoutEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { AnsweredBy, AuthorChip } from "./multiplayer/Faces";
import { LivePresenceStack, LiveTypingLine } from "./multiplayer/LivePresence";
import { flushSync } from "react-dom";
import { composerPlusSearchExtensions, PLUS_SEARCH_ACTIONS } from "./composerPlusRegistry";
import { CONNECT_ACTIONS, type ConnectKind, type OffloadKind, thisMacName } from "./environments";
import { chiefEnvelope } from "./conversation/chiefEnvelope";
import { restoreForkSource } from "./handoff/restoreForkSource";
import { rowPresence } from "./conversation/rowPresence";
import { QueryClientProvider, useIsFetching, useQueryClient } from "@tanstack/react-query";
import { applyAgentTheme } from "../shared/theme";
import { isAgentMotionOff } from "../shared/motion";
import { entranceAllowed } from "../shared/pageReveal";
import {
  layoutConversation,
  onlyQuietThoughts,
  type ConversationLayout,
  type RowHeights,
  paneHeader,
  placeRows,
  transcriptRowWidth,
  mergeRowRanges,
  scrollLeadRanges,
  visibleLayoutRange,
  type AcpmuxPermission,
  type AcpmuxSecretAsk,
  type AcpmuxRow,
  type AcpmuxSnapshot,
  type QueueEdit,
  nextDrawnRow,
  prevDrawnRow,
  isBeforeFooter,
  hasReplyActions,
  keepsReplyRoom,
  statusEdge,
  type StatusEdge,
  isLastFooter,
  isContinuationFooter,
  QUEUED_MESSAGE,
  PENDING_MESSAGES,
  LANE_NOTICE_BATCH,
  isLineRow,
  restRoom,
} from "./model";
import { lacksImageBytes, ownQueue, queuedAttachments, queuedMessageRows } from "./conversation/queuedMessages";
import { isVisiblyEmptyMessage } from "./conversation/visibleMessage";
import { pendingMessagesRow, searchablePendingRows } from "./conversation/pendingMessages";
import { LaneNoticeBatch } from "./conversation/LaneNoticeBatch";
import { PendingMessagesCard } from "./conversation/PendingMessagesCard";
import {
  QueuedMessageCard,
  SteerWaitingActions,
  WaitingMessageMenu,
  type HeldAnswer,
  type QueuedMessageActionsValue,
} from "./conversation/QueuedMessageCard";
import { AcpmuxDirectClient, type AcpmuxHostConfig, harnessBlock, type HarnessBlock, isTrustRefusal } from "./direct";
import { failedRowOf, failedRowTrustRetry, type TrustRouter } from "./failedRowTrustRetry";
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
import { errorMessage, startCancelled } from "./transportErrors";
import { pageHostClient, startHostEvents } from "./pageHost";
import { FOCUS_LOCATION_EVENT, NewTabPage, newTabHost, type NewTabChat, type NewTabHost } from "./NewTabPage";
import { setDeviceChats } from "./newtab/deviceChats";
import { setRecentlyClosed } from "./newtab/recentlyClosed";
import { setNowPlaying } from "./newtab/nowPlaying";
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
  useNewTabWeather,
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
import { ThreadMinimap } from "./threadMinimap/ThreadMinimap";
import { railOwnsWheel } from "./threadMinimap/railWheel";
import { animateScroll, stopScroll } from "./threadMinimap/scrollMotion";
import { JUMP_CURVE, jumpDuration } from "./threadMinimap/model";
import { cssTimeMs, foldMotion, foldMs } from "./conversation/fold";
import { ChatMinimap } from "./chatMinimap/ChatMinimap";
import type { RowsChange } from "./threadMinimap/model";
import { PromptMarksSession } from "./threadMinimap/promptMarks";
import { preserveScrollAnchorTop, scrollAnchorBase } from "./conversation/scrollAnchor";
import { attachUserScrollIntent, userScrollIntent } from "./conversation/userScroll";
import {
  clearScrollOrigin,
  layoutScrollTop,
  physicalScrollTop,
  retainScrollOrigin,
  scrollOrigin,
  writeAnchorScrollTop,
} from "./conversation/scrollCoordinates";
import { createFollowGlide, followRoom } from "./conversation/followGlide";
import { setBookmarkTransport } from "./threadMinimap/bookmarks";
import {
  composerDraft,
  DRAFT_SETTLE_MS,
  notifyDraftActionsChanged,
  settleDraftWithin,
  writePersistedDraft,
} from "./composerDraft";
import { paneContext } from "./paneContext";
import {
  createPaneQueryClient,
  followHarnessChanges,
  useHarnessCatalog,
  useHarnessesListed,
  type HarnessCatalogSource,
} from "./catalog";
import { usePickerCatalog } from "./modelCatalogHost";
import { isDefaultChoice } from "./defaultChoice";
import { applySwitch, browserSwitchClock, HarnessSwitch, lastOfferedModel, type SwitchPort } from "./harnessSwitch";
import { NewChatPrewarm, type PrewarmTarget } from "./newChatPrewarm";
import { harnessProfiles } from "./harnessProfiles";
import { setStartModeSource } from "./startMode";
import { setPromptSurfaces } from "./surfaces/promptSurface";
import { MockAcpmuxSocket, mockHost, type MockScript } from "./mock";
import { BridgeSocket } from "./bridgeSocket";
import { useComposerKeyboard } from "./composerFocus";
import { createAcpmuxDebug, type AcpmuxDebug } from "./debug";
import { type AutomationCompose, pageAction } from "./automation";
import { acpWire } from "./wire";
import { acpmuxPerf, type MountedSpan } from "./perf";
import { followTrace } from "./followTrace";
import { ScrollPacing } from "./pacing";
import { AdaptiveRenderRate, reportScrollPacing } from "./renderPacing";
import { authoritativeScrollIntent, createScrollPacer, type ScrollFrame } from "./scrollPacer";
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
import type { KeptAttachments } from "./composer/keptAttachments";
import { ComposerPickers, PICKER_LABELS } from "./ComposerPickers";
import { chatAccessGrants, revokeAccessRows } from "./header/grantsMenu";
import { openPicker } from "./pickerOpeners";
import { startRefusalRoute } from "./startRefusal";
import { EmptyState, type EmptyStateProjects, isNewChat, projectName } from "./EmptyState";
import { paneKnowsNewChat } from "./locationRow";
import { ChatUnavailableState } from "./ChatUnavailableState";
import { useCloudChatRecovery } from "./useCloudChatRecovery";
import { cloudChatRecoveryActive, cloudChatUnavailable, type CloudChatIdentity } from "./cloudChatRecovery";
import { PastChat, type PastTurn, readPastTurns } from "./PastChat";
import type { Project } from "./ProjectChooser";
import { byRecentUse, parseProjectRepos } from "./projectRepos";
import { answerFromHome } from "./HomeInbox";
import { HomeLists } from "./HomeLists";
import { endsTurn, lastChange, turnFiles, turnPathsOnly, turnRows, type PathRef, type TurnFile } from "./diff";
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
import { PermissionCard } from "./PermissionCard";
import { cardTakesShortcuts } from "./permissionKeys";
import { QuestionCard } from "./question/QuestionCard";
import { PermissionQuestion } from "./question/PermissionQuestion";
import { QUESTION_RECORD } from "./question/record";
import { DECISION_TEXT, PERMISSION_RECORD } from "./permissions/record";
import type { QuestionReply } from "./question/model";
import { agentName } from "./agents";
import { type Translate, translate, useT } from "./i18n";
import { PeerCopyBanner } from "./PeerCopyBanner";
import { chatCloudMachine, cloudMachineRows, createStopWaiter } from "./cloudMachineMenu";
import { readUntilMoved, refreshCloudMachines, useCloudMachines } from "./cloudMachines";
import { usePeerCloudMachine } from "./peerCloudMachine";
import { inThisVisit, useFolderTrustAsk, visitOf } from "./useFolderTrustAsk";
import { routeCurrentTrustRefusal, routeOwnedTrustRefusal, type TrustRefusalOwner } from "./trustRefusalRoute";
import { heldPrompts } from "./heldPrompt";
import { StartingSends, type StartingSend } from "./startingSends";
import { FILE_SEARCH_LIMIT, type FileSearchSource } from "./fileSearchModel";
import type { DiffFindHandle } from "./changes/diffFind";
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
  useSessionInfoOpen,
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
import { agentProgressSource } from "./subagents/agentProgressSource";
import { AgentProgressContext, AgentProgressStore } from "./subagents/agentProgressStore";
import { BackgroundTasksPanel } from "./backgroundTasks/BackgroundTasksPanel";
import { backgroundGroups, type TaskCache } from "./backgroundTasks/backgroundTasks";
import { backgroundTasksLook } from "./backgroundTasks/backgroundTasksLook.experiment";
import { settleTrayExit, TRAY_GHOST } from "./subagents/trayMotion";
import { SubagentDoneLine } from "./subagents/SubagentDoneLine";
import { runRetry, type RetryTarget } from "./subagents/retryState";
import { configureWorkflowCardOpen, configureWorkflowCardSideTab, WorkflowCard } from "./summary/WorkflowCard";
import {
  type DoneLineCache,
  configureSubagentTray,
  finishedTrayItems,
  trayItems,
  useSubagentTray,
  withSubagentLines,
} from "./subagents/runningTray";
import { configureSubagentTrayPlacement, useSubagentTrayPlacement } from "./subagents/subagentTrayPlacement";
import { AgentTonesContext, agentTones } from "./subagents/agentTones";
import { useSummaryCard, useSummaryColumn } from "./summary/cardState";
import { chatHasSummaryContent } from "./summary/summaryContent";
import { createWorkflowAdapter, workflowDetailRequest, type WorkflowDetailRequest } from "./summary/foldWorkflows";
import { workflowPaneId, workflowPaneRequest } from "./summary/workflowTranscript";
import { useWorkflowTranscript } from "./summary/useWorkflowTranscript";
import { noteReaderScroll, releaseReaderScroll, useHeldWhileScrolling } from "./summary/heldWhileScrolling";
import type { WorkflowAgent, WorkflowSummary } from "./summary/workflow";
import { WorkflowSideTab } from "./summary/WorkflowSideTab";
import {
  showSubagent as showSubagentIn,
  revealedSubagent,
  subagentTabTitle,
  useAutoOpenSubagents,
  useOpenNewSubagents,
} from "./subagents/subagentPanes";
import { turnCounts, turnDisplay } from "./changes/turnCheckpoint";
import { TurnCountsContext, type TurnCountsFor } from "./changes/TurnCountsContext";
import { useTurnCheckpoints } from "./changes/useTurnCheckpoints";
import { latestTurnCheckpointPair, readTurnFromRows, type CheckpointDiff } from "./changes/turnCheckpointSource";
import { registerAttachmentViewHost, registerComposerHost, useComposerSettings } from "./composerSettings";
import { shouldScrollToBottomAfterSend } from "./sendScrollSetting";
import { WHOLE_FILE_CONTEXT } from "./changes/wholeFile";
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
import type { ChangesSource } from "./changes/model";
import { RevealedMarkdown } from "./conversation/RevealedMarkdown";
import { transcriptRepositories, type RepositoryCache } from "./conversation/transcriptRepositories";
import {
  newReferenceScopeCache,
  ReferenceScopeContext,
  referenceScopes,
  turnOpener,
  type ReferenceScope,
} from "./conversation/bareReferences";
import { WriteKeys, type GitWriteOp } from "./changes/gitWrite";
import { ToolRows, TurnFooter, WorkedFor } from "./conversation/TurnRows";
import { MessageFooterRow, PromptActions, ReceivedActions, ReplyActions } from "./conversation/MessageActions";
import { AgentNamesContext, agentNames } from "./conversation/agentNames";
import { setReadAloudState, stopReadingAloud } from "./conversation/readAloud";
import { heightFoldInFlight } from "./conversation/fold";
import {
  ANCHORED_COLLAPSE_EVENT,
  atFoldBottom,
  clickFold,
  FOLD_HOLD_MIN_MS,
  FOLD_SETTLE_MS,
  foldHoldTarget,
  foldHolding,
  foldRoomFor,
  foldToggleAt,
  holdFold,
  keepFold,
  trimmedFoldRoom,
  verticalWheel,
  type FoldAnchor,
} from "./conversation/foldAnchor";
import { settleTurnFold, startTurnFold, watchTurnFold, type TurnFold } from "./conversation/turnFold";
import { EditedFilesCard } from "./conversation/EditedFilesCard";
import { loadHighlightedCode } from "./conversation/CodeBlock";
import { loadEditDiffHunks } from "./conversation/EditDiff";
import { PlanList } from "./conversation/PlanList";
import { ActivityLine } from "./conversation/ActivityLine";
import { BackgroundTaskNote } from "./conversation/BackgroundTaskNote";
import { BackgroundTaskOutputContext, type BackgroundTaskOutputReader } from "./conversation/backgroundTaskOutput";
import { IncomingMessageLine, IncomingNotice } from "./conversation/IncomingMessageCard";
import type { IncomingMessage } from "./conversation/incomingMessage";
import { CompactionNote, FailoverNote, PolicyUnenforcedNote } from "./conversation/CompactionNote";
import { BackgroundTurnLine } from "./conversation/BackgroundTurnLine";
import { BACKGROUND_TURN } from "./conversation/backgroundTurns";
import { AgentPairNote } from "./conversation/AgentPairNote";
import { installGutterSelect, type HeldRow } from "./conversation/gutterSelect";
import { SessionStartNote } from "./conversation/SessionStartNote";
import {
  SessionCwdContext,
  SessionEditsContext,
  isEditRow,
  sessionEdits,
  type SessionEdits,
} from "./turnChanges/sessionRows";
import { repositoryRoot, viewChangesBeside, viewChangesTurn } from "./turnChanges/viewChanges";
import { resendToOwner, retryFailedTurn } from "./conversation/turnRetry";
import {
  TurnActionsContext,
  chatLoginCommand,
  compactThrough,
  offersCompact,
  resumeThrough,
  type TurnActions,
} from "./conversation/turnActions";
import { useTranscriptReadOnly } from "./conversation/readOnly";
import { GuestActionsBoundary } from "./conversation/GuestActionsBoundary";
import {
  RunInBackgroundContext,
  backgroundsWork,
  foregroundCalls,
  useBackgroundKey,
} from "./conversation/runInBackground";
import { UserBubble } from "./conversation/UserBubble";
import { ChiefPromptBubble } from "./conversation/ChiefPromptBubble";
import {
  editableKey,
  editableSeqs,
  promptTurns,
  trackEditableTurns,
  type EditableTurns,
} from "./conversation/editPrompt";
import {
  clearFindHighlights,
  FIND_ACTIVE_HIGHLIGHT,
  FindReveal,
  foldFind,
  findRowIndex,
  findMemberRowId,
  isFindRow,
  paintFindHighlights,
  type ChatFind,
} from "./conversation/chatFind";
import { ChatFindBar } from "./conversation/ChatFindBar";
import { ChatFindScope } from "./conversation/ChatFindScope";
import {
  ACTIVITY_LINE,
  DATE,
  PREVIEW,
  RENDER,
  THINKING,
  WORKED,
  messageRevealTarget,
  openViewTurnFold,
  toggleTurnFold,
  toggleViewTurnFold,
  turnFoldFor,
  turnFooterFrom,
  WORKING,
  type TurnView,
  turnViewFrom,
} from "./conversation/turns";
import { ArrowDown, ChevronRight } from "./conversation/icons";
import { CopyButton } from "./conversation/CopyButton";
import { PreviewCard } from "./conversation/PreviewCard";
import { installWheelGlide } from "./wheelGlide";
import { installWheelPassThrough } from "./wheelPassThrough";
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
import { RenderToolCard, canRender } from "./conversation/RenderCard";
import { ArtifactPanel, useArtifactCoversPane, type SaveDocument } from "./conversation/ArtifactPanel";
import { branchesFromKey, branchesKey, forkAnchor, messageBranches } from "./conversation/branches";
import { ArtifactContext, type Artifact } from "./conversation/artifactPreview";
import { uniqueArtifacts } from "./conversation/artifactDedupe";
import { writtenArtifacts } from "./conversation/writtenArtifacts";
import { artifactVersions } from "./conversation/artifactVersions";
import { RenderPages, renderPages, renderVersions } from "./conversation/renderCall";
import { DateLine } from "./conversation/DateLine";
import { ShortcutsContext, readShortcuts, type ShortcutLabels } from "./shortcuts";
import {
  FALLBACK_LINK_SCHEME,
  revealedMessage,
  revealMessageWhenShown,
  revealTurnWhenShown,
  setLinkScheme,
} from "./links";
import { NeedsYouButton } from "./needsYou/NeedsYou";
import { NeedsYouPill, type TranscriptNeedsYou } from "./needsYou/JumpPill";
import { useNeedsYou } from "./needsYou/useNeedsYou";
import { copyText, copyTextResult } from "./conversation/clipboard";
import { lastCodeBlock } from "./conversation/lastCodeBlock";
import { transcriptRangeText } from "./conversation/transcriptCopy";
import { rovingTabStopProps } from "../../ui/listRowKeyboard";
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
import { SubagentPaneFooter } from "./subagents/SubagentPaneFooter";
import { RecapCard, useRecapCard } from "./RecapCard";
import { HarnessStatusCard } from "./HarnessStatusCard";
import {
  cloudPageRefusal,
  cloudStartFolder,
  cloudStartToasted,
  newTabProjectPick,
  oneCloudStart,
  type CloudStart,
} from "./cloudRun";
import { folderRunLocation, newChatRunLocation } from "./runLocationDefault";
import { harnessLabel } from "./subagents/agentRuns";
import { cloudStartBegun, cloudStartEnded, cloudStartPushed, type CloudStartProgress } from "./cloudStartProgress";
import { CloudStartView } from "./CloudStartView";
import { configureQuickActions, quickActions, type QuickActionMode } from "./header/quickActions";
import { chatColumnOf, configureChatWidth, useChatSizing } from "./chatWidth";
import { registerChatDisplayHost, useChatDisplay } from "./chatDisplay";
import { ChatDisplaySettings } from "./ChatDisplaySettings";
import { transcriptViewRow, wrapOutputRow } from "./header/transcriptViewRow";
import { configureCodexToolRuns, useCodexToolRuns } from "./codexToolRuns";
import { configureLiveLineBelow, useLiveLineBelow } from "./liveLineBelow";
import { configureToolRunLook } from "./toolRunLook";
import { configureSentLook } from "./conversation/SentMessageLine";
import { configureInboxNoticeLook } from "./conversation/inboxNoticeLook";
import { InboxNoticeCard } from "./conversation/InboxNoticeCard";
import { mergeInboxNotices, type InboxMessage } from "./conversation/inboxNotice";
import { configureNativeSidebarPreviewVariant, configureSidebarPreviewVariant } from "./sidebarPreview";
import { cloudCredentialRecovery } from "./cloudCredentialRecovery";
import { cloudAgentLogin } from "./cloudAgentLogin";
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
import { PendingSteer, takeBackSteer, takesSteersBack } from "./conversation/PendingSteer";
import { Thinking } from "./conversation/Thinking";
import { type WorkingCounts, WorkingCountsContext, WorkingFor } from "./conversation/WorkingFor";
import { chatWaitsOn, WaitingOnContext } from "./conversation/waitingOn";
import { TranscriptDisclosureProvider } from "./conversation/transcriptDisclosure";
import { useTranscriptView, type TranscriptView } from "./conversation/transcriptView";
import { isWorkedFold, NO_FOLD_TOGGLES, viewFolds, type Folds } from "./conversation/viewFolds";
import { type HarnessHealth, HarnessHealthNotice, type UpdateOffer, UpdateOfferContext } from "./HarnessHealthNotice";
import { Notice, NoticeSlot } from "./NoticeSlot";
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
import { SHELL_ROW, ShellRuns, shellContextAttachments, withShellRows } from "./shell/shellRuns";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";
import { AgentRunCard } from "./subagents/AgentRunCard";
import { SubagentEmptyRow } from "./subagents/SubagentEmptyRow";
import { restartOwner, restartPrompt, restartReaches } from "./subagents/restart";
import {
  SUBAGENT_DONE,
  SUBAGENT_EMPTY,
  SUBAGENT_OF,
  SUBAGENT_ROW,
  WORKFLOW_CARD,
  type SubagentRows,
  childView,
  isRunGroup,
  runningGroups,
  subagentRowsFrom,
  subagentsIn,
} from "./subagents/subagentRows";
import { knownMark } from "../shared/AgentMark";
import {
  SubagentGroupHeader,
  SubagentHarnessContext,
  SubagentListRow,
  SubagentNavContext,
  SubagentOfRow,
  SubagentPaneContext,
  SubagentClockContext,
  SubagentStopContext,
  running,
} from "./subagents/SubagentGroup";
import { endedEditRow, markRows, type RowMarks } from "./rowMarks";
import { ShellActionsContext, ShellRow, type ShellActions } from "./shell/ShellRow";
import { SwitchNotice } from "./SwitchNotice";
import { BACKGROUND_NOTICE_TEXT, useBackgroundNotice } from "./conversation/backgroundNotice";
import { InstructionsNotice, type InstructionsFailure } from "./header/InstructionsNotice";
import { FolderChoice, showsFolderChoice } from "./FolderChoice";
import { type FolderAsk, WorktreeFailure, confirmFolder, newWorktree, pickFolder } from "./startFolder";
import { NewTabFolderAsk } from "./NewTabFolderAsk";
import { MissingFolder, chooseChatFolder } from "./missingFolder";
import { LiveChatChoice } from "./LiveChatChoice";
import { WatchBanner } from "./WatchBanner";
import { ManagedBanner } from "./ManagedBanner";
import { isTakenOver, managedBy, takeOverManaged } from "./managedBy";
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
import { DeliveryFailure, FailedSendsContext, type FailedSends } from "./conversation/PromptDelivery";
import { failedRuns, failedSendText, type FailedRun } from "./sendFailure";
import { ReplayScreen } from "./replay/ReplayScreen";
import { sessionReplay } from "./replay/replay.experiment";
import { useSideSessions } from "./aside/sideSessions";
import { BtwNotes, type BtwRow as InlineBtwRow } from "./aside/btwNotes";
import { BtwAside } from "./aside/BtwAside";
import { askBtwQuestion } from "./btwCapability";
import { isFastModeOption } from "./heldOptions";
import { ReceivedResult, SuggestedTasks, type OfferActions } from "./offer/SuggestedTasks";
import { OFFER_RESULT, setSuggestedTasks } from "./offer/offersShown";
import { offerWorktree } from "./offer/offerWorktree";
import { queueingOn, setQueueing } from "./queueing";
import {
  NO_MENTIONS,
  StartedMentionsContext,
  StartedSessionCards,
  type StartedMentions,
} from "./started/StartedSessionCard";
import { type SessionHover, SessionHoverContext } from "./started/SessionHoverCard";
import { SessionHoverStore, withSessionIds } from "./started/sessionHover";
import { SubsessionContext, SubsessionStore, type Subsessions, subsessionRows } from "./subagents/subsessions";
import {
  STARTED_SESSIONS,
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
import { MOTION_MS } from "../../motion/scale.generated";
import { SHOWN_SCROLLER_ATTRIBUTE, followShownScrollerFade } from "../../scrollers";
import { holdWebSwap, WEB_SWAP_KEPT_SCROLL } from "../../pages/shared/webSwap";
import { useWebSwapHold } from "../../pages/shared/useWebSwapHold";
import { SandboxTab, sandboxAgent, sandboxPageRefusal, sandboxRetryable, type RunMode } from "./sandboxRun";
import { SandboxRunView } from "./SandboxRunView";
import { PaneFeatureTips } from "./featureTips";
import { playChatSwitch, type ChatSwitchPlay } from "./chatSwitch";
import { chatSwitchMotion } from "./chatSwitch.experiment";

/// The changes view comes in its own chunk (bd cx-z9kz0): it carries the diff and file-tree
/// packages, which a New Tab page never shows, so the page's first script parses without them.
/// It starts loading once the page has painted, with the transcript's highlighted code and edit
/// cards (conversation/CodeBlock.tsx, conversation/EditDiff.tsx), so opening it waits on nothing.
const loadDiffPanel = () => import("./DiffPanel");
const DiffPanel = lazy(() => loadDiffPanel().then((module) => ({ default: module.DiffPanel })));

type MeasurableRenderer = React.ComponentType<RowProps> & {
  measure?: (row: AcpmuxRow, width: number) => number;
};
type NativeRegistry = Record<string, MeasurableRenderer>;
/// `onOpenDiff` opens the changes of the turn holding `rowId`, at `path` when given; focus
/// returns to `opener` when the view closes.
type OpenDiff = (rowId: string, path?: string, opener?: HTMLElement) => void;
type RowProps = {
  row: AcpmuxRow;
  /// Whether a reply draws its own action row (model.ts `hasReplyActions`, from the row after it).
  replyActions?: boolean;
  sessionId?: string;
  onToggleActivity: (id: string) => void;
  expanded: boolean;
  controls?: string;
  onOpenDiff?: OpenDiff;
  githubRepository?: string;
};

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
      /// Claude Code desktop's in-session status (the live plan card, the recap card) on or off: the
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

function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const direct = window.cmuxAcpmuxActions?.[method];
  if (direct) return direct(params) as Promise<T>;
  return postNative<T>(method, params);
}

/// Stops the shown chat's turn; refused while the pane cannot reach acpmux (stopThroughReconnect.ts).
const cancelTurn = () => callNative<unknown>("chat.cancel");

/// Withdraws a queued prompt before its turn starts; false when it already started.
const removeQueued = (promptId: string) =>
  callNative<{ removed?: boolean } | null>("chat.queue.remove", { promptId }).then(
    (result) => result?.removed === true,
  );

/// Sends a prompt that waited for a new chat; settles once acpmux took it (its turn's later failure
/// is the transcript's), and rejects when it was refused before.
const sendWhenTaken = (steer: boolean) => (text: string, attachments: ComposerAttachment[]) =>
  new Promise<void>((resolve, reject) => {
    callNative("chat.send", { text, attachments, accepted: () => resolve(), steer }).then(() => resolve(), reject);
  });

/// Resumes the chat's paused messages with another agent (conversation/AgentPairNote.tsx).
const resumeAgentPair = (peer: string) => callNative("chat.agentPair.resume", { peer });

/// Changes a waiting prompt (`_acpmux/queue_edit`); false when it already started.
/// Keeps one footer mounted through waiting, accepted delivery and the authoritative read event.
const steerControls = (row: AcpmuxRow) =>
  row.steer === "waiting" || (row.steer === "landed" && Boolean(row.text?.trim()));

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

const editQueued = (promptId: string, edit: QueueEdit) =>
  callNative<{ ok?: boolean } | null>("chat.queue.edit", { promptId, ...edit }).then((result) => result?.ok === true);

/// The width the header's tools take in the pane's tab row, so the App narrows the tabs (header/tabRow.ts).
const reportTabRowTools = (width: number) => void callNative("pane.tabRowTools", { width }).catch(() => undefined);
/// Hands the host a new chat's typed text, kept with its tab across a relaunch (cx-z5vd).
/// The composer's text changed: the chat tells acpmux this pane types (never the text itself).
const postTyping = (text: string, sessionId?: string) =>
  void window.cmuxAcpmuxActions?.["chat.typing"]?.({ text, sessionId }).catch(() => undefined);
const postUnsentDraft = (text: string) => callNative("chat.unsentDraft", { text }).catch(() => undefined);
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
/// Where chat `sessionId` rests, kept by its tab so a relaunch reopens it there (cx-6bgzj).
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
function readWake(value: unknown): { composer: ComposerWake; scrollAnchor?: ScrollAnchor | null } | undefined {
  if (!value || typeof value !== "object") return undefined;
  const wake = value as {
    attachments?: unknown;
    shell?: unknown;
    shellText?: unknown;
    scrollAnchor?: unknown;
    atLatest?: unknown;
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

/// The last measured transcript box on this page: a transcript mounting again starts from it.
const lastTranscriptBox = { height: 600, width: 760 };

const trustSource: TrustSource = {
  get: (cwd) => callNative("acp.trust.get", { cwd }),
  set: (cwd, level) => callNative("acp.trust.set", { cwd, level }),
};

/// The changes view reads git scopes through the client, which knows the selected session's
/// folder and asks the native host (or, in mock mode, the in-page daemon).
const changesSource: ChangesSource = {
  diff: (scope) => callNative("git.diff", { scope, include_patch: true }),
  wholeFile: (scope, path) =>
    callNative("git.diff", {
      scope,
      include_patch: true,
      paths: [path],
      context_lines: WHOLE_FILE_CONTEXT,
    }),
  status: () => callNative("git.status", {}),
  commit: (params) => callNative("git.commit", params),
  push: (params) => callNative("git.push", params),
  stage: (paths, unstage) => callNative("git.stage", { paths, unstage }),
  stageHunk: (paths, hunk, unstage) => callNative("git.stageHunk", { paths, hunk, unstage }),
  pullRequest: () => callNative("git.pullRequest", {}),
  reviewThreads: () => callNative("git.pullRequest", { action: "threads" }),
};
// The composer's Hide and Show (composerChrome.tsx) persist through the host, which pushes the
// setting back to every page and on the next launch.
registerComposerHost((method, show) => callNative(method, { show }));
registerAttachmentViewHost((view) => callNative("pane.setAttachmentView", { view }));
registerChatDisplayHost((key, value) => void callNative("pane.setDisplay", { key, value }).catch(() => undefined));
/// A folder's `git.status` from the native host, named by the folder: a new chat has no session to
/// name it by (the header's worktree pill, cx-lyqio.3b).
const readFolderStatus = (cwd: string) => postNative("git.status", { cwd });
/// A turn's checkpoint pair, diffed on the session host (`git.checkpoint.diff`).
const checkpointDiff: CheckpointDiff = (from, to) =>
  callNative("git.checkpoint.diff", { from, to, include_patch: true });
/// Commit and Push keys per session, for the page's life: a view closed and opened again after a
/// write whose reply was lost retries with the same key, so the session host reports the first
/// result instead of committing or pushing twice.
const gitWriteKeys = new Map<string, WriteKeys>();
function writeKeysFor(sessionId: string | undefined): WriteKeys | undefined {
  if (!sessionId) return undefined;
  let keys = gitWriteKeys.get(sessionId);
  if (!keys) gitWriteKeys.set(sessionId, (keys = new WriteKeys()));
  return keys;
}
/// The host opens a changed file in a tab beside the agent or in the editor (`file.open`).
const openChangedFile = (path: string, where: "tab" | "editor") => callNative("file.open", { path, where });

/// A prompt draws as the user typed it, in a bubble at the right; a reply as Markdown.
const MessageRow = memo(
  function MessageRow({ row, replyActions, githubRepository }: RowProps) {
    const t = useT();
    const readOnly = useTranscriptReadOnly();
    if (isVisiblyEmptyMessage(row)) return null;
    // A started task's result, which acpmux sent as a prompt: one line, never the person's bubble.
    if (row.kind === "user" && row.received) return <ReceivedResult result={row.received} onOpen={openOfferChat} />;
    // Another agent's message as one line at the left (its sender's chip), its text as a card under
    // it cut to eight lines; a task notification as one quiet line (conversation/incomingMessage.ts).
    // Its images show with it, and its action row (age, Retry) at the line's end on hover;
    // a steer's read state does not: the message is the agent's to read.
    if (row.kind === "user" && row.incoming?.kind === "notice") return <IncomingNotice text={row.incoming.text} />;
    if (row.kind === "user" && row.inboxThread)
      return (
        <div className="cv-incoming">
          <InboxNoticeCard
            rowId={row.id}
            messageAt={row.at}
            notice={{
              threads: [
                {
                  threadId: row.inboxThread.threadId,
                  label: row.inboxThread.label ?? "",
                  from: [row.inboxThread.sender],
                  count: row.inboxThread.count,
                  preview: row.inboxThread.preview,
                  blocker: false,
                  promptIds: [...row.inboxThread.promptIds],
                  ...(row.inboxThread.fromSession ? { fromSession: row.inboxThread.fromSession } : {}),
                  ...(row.inboxThread.fromHarness ? { fromHarness: row.inboxThread.fromHarness } : {}),
                },
              ],
            }}
            onOpen={openSenderChat}
            readThread={readInboxThread}
            githubRepository={githubRepository}
            actions={row.inboxQueue ? <InboxQueueActions queue={row.inboxQueue} version={row.version} /> : undefined}
          />
        </div>
      );
    // acpmux's inbox notice: its threads as received lines, never its text for the agent
    // (conversation/InboxNoticeCard.tsx).
    if (row.kind === "user" && row.incoming?.kind === "inbox")
      return (
        <div className="cv-incoming">
          <InboxNoticeCard
            rowId={row.id}
            notice={row.incoming.notice}
            messageAt={row.at}
            onOpen={openSenderChat}
            readThread={readInboxThread}
            githubRepository={githubRepository}
          />
        </div>
      );
    if (row.kind === "user" && row.incoming?.kind === "message")
      return (
        <div className="cv-incoming">
          <IncomingMessageLine
            id={row.id}
            message={row.incoming.message}
            messageAt={row.at}
            images={row.images}
            onOpen={openSenderChat}
            onReply={readOnly ? undefined : replyToMessage}
            actions={
              readOnly ? undefined : (
                <ReceivedActions
                  row={row}
                  more={
                    row.steer === "waiting" && <SteerWaitingActions promptId={row.steerPromptId} send={sendSteerNow} />
                  }
                />
              )
            }
            githubRepository={githubRepository}
          />
        </div>
      );
    if (row.kind === "user" && row.incoming?.kind === "hidden") return null;
    if (row.kind === "user") {
      // A Chief subagent's first message: the Chief's view as one collapsed line, the task as
      // the message (the session keeps the whole text).
      const envelope = chiefEnvelope(row.text);
      return (
        <div className="cv-user">
          {envelope && (
            // The view's Copy sits outside the disclosure, over the space the summary keeps free at
            // its trailing end, so it never covers the label; a long label ends in an ellipsis.
            <div className="cv-user__context">
              <details>
                <summary>
                  <ChevronRight size={12} className="cv-user__context-chevron" />
                  <span className="cv-user__context-label">
                    {t("transcript.chiefContext", { count: envelope.lines })}
                  </span>
                </summary>
                <pre className="cv-user__context-text selectable">{envelope.context}</pre>
              </details>
              <CopyButton
                text={envelope.context}
                label={t("turn.copy")}
                className="cv-iconbtn cv-iconbtn--compact cv-user__context-copy"
              />
            </div>
          )}
          {envelope || row.from === "chief" ? (
            <>
              <ChiefPromptBubble
                text={envelope ? envelope.task : (row.text ?? "")}
                actions={
                  <PromptActions
                    row={row}
                    text={envelope ? envelope.task : (row.text ?? "")}
                    pending={
                      !readOnly && steerControls(row)
                        ? (actions) => (
                            <PendingSteer row={row} send={editQueued}>
                              {actions}
                            </PendingSteer>
                          )
                        : undefined
                    }
                  />
                }
              />
            </>
          ) : (
            // An unread steer shows only queue controls; accepted or read prompts show normal hover actions.
            <>
              {row.author && <AuthorChip author={row.author} />}
              <UserBubble
                row={row}
                text={row.text ?? ""}
                pending={
                  !readOnly && steerControls(row)
                    ? (actions) => (
                        <PendingSteer row={row} send={editQueued}>
                          {actions}
                        </PendingSteer>
                      )
                    : undefined
                }
              />
            </>
          )}
          <DeliveryFailure row={row} />
          {row.viaCli && <div className="cv-user__status">{t("transcript.viaCli", { host: row.viaCli })}</div>}
          {row.status && (
            <div className="cv-user__status">
              <span>{row.status}</span>
            </div>
          )}
        </div>
      );
    }
    const reply = (
      <RevealedMarkdown
        text={row.text ?? ""}
        streaming={row.streaming === true}
        githubRepository={githubRepository}
        messageAt={row.at}
      />
    );
    // A finished reply its turn's footer does not serve keeps its own action row, whatever follows
    // it (model.ts hasReplyActions).
    if (!replyActions) return reply;
    return (
      <>
        {reply}
        <ReplyActions row={row} />
      </>
    );
  },
  (previous, next) =>
    previous.row.id === next.row.id &&
    previous.row.version === next.row.version &&
    previous.replyActions === next.replyActions &&
    previous.githubRepository === next.githubRepository,
);

/// Tool calls and thoughts as quiet rows (inside an open "Worked for", or live).
const ToolActivityRow = memo(
  function ToolActivityRow({ row, sessionId }: RowProps) {
    // A finished step of only quiet thoughts draws nothing: no `.cv-tools` box either, so the row's
    // article is empty and takes no room (model.ts onlyQuietThoughts, conversation.css `:empty`).
    if (onlyQuietThoughts(row)) return null;
    return <ToolRows row={row} sessionId={sessionId} />;
  },
  (previous, next) =>
    previous.row.id === next.row.id &&
    previous.row.version === next.row.version &&
    previous.sessionId === next.sessionId,
);

/// "Worked for 15s": opens the turn's commentary and tool calls (turnView in conversation/turns.ts).
const WorkedRow = memo(
  function WorkedRow({ row, onToggleActivity, expanded, controls }: RowProps) {
    return <WorkedFor row={row} expanded={expanded} controls={controls} onToggle={() => onToggleActivity(row.id)} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.expanded === b.expanded &&
    a.controls === b.controls &&
    a.onToggleActivity === b.onToggleActivity,
);

/// A turn the agent ran on its own, folded to one line (conversation/backgroundTurns.ts); opening it
/// lists its rows below.
const BackgroundTurnRow = memo(
  function BackgroundTurnRow({ row, onToggleActivity, expanded }: RowProps) {
    return <BackgroundTurnLine row={row} expanded={expanded} onToggle={() => onToggleActivity(row.id)} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.expanded === b.expanded &&
    a.onToggleActivity === b.onToggleActivity,
);

/// "Sun, Sep 13 at 7:55 PM" over a prompt after an hour's gap (turnView in conversation/turns.ts).
const DateRow = memo(
  function DateRow({ row }: RowProps) {
    return <DateLine row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.at === b.row.at,
);
/// A running turn's status: "Thinking", then "Working for 42s" (turnView in conversation/turns.ts).
const ThinkingRow = memo(
  function ThinkingRow({ row }: RowProps) {
    return (
      <Thinking
        starting={row.queued !== undefined}
        since={row.at}
        doing={row.doing}
        doingAt={row.doingAt}
        doingShell={row.doingShell}
        sendTo={row.doingSendTo}
        sendSession={row.doingSendSession}
        draft={row.doingDraft}
        done={row.doingDone}
        untimed={row.untimed}
        quietKey={row.quietKey}
        below={row.below}
        command={row.doingCommand}
      />
    );
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.row.queued === b.row.queued &&
    a.row.at === b.row.at &&
    a.row.doing === b.row.doing &&
    a.row.doingAt === b.row.doingAt &&
    a.row.doingShell === b.row.doingShell &&
    a.row.doingSendTo === b.row.doingSendTo &&
    a.row.doingSendSession === b.row.doingSendSession &&
    a.row.doingDraft === b.row.doingDraft &&
    a.row.doingDone === b.row.doingDone &&
    a.row.untimed === b.row.untimed &&
    a.row.quietKey === b.row.quietKey &&
    a.row.below === b.row.below &&
    a.row.doingCommand === b.row.doingCommand,
);
const WorkingRow = memo(
  function WorkingRow({ row, sessionId }: RowProps) {
    // The session's disclosures say whether the running call's group shows its row (WorkingFor.tsx).
    return (
      <TranscriptDisclosureProvider sessionId={sessionId}>
        <WorkingFor row={row} />
      </TranscriptDisclosureProvider>
    );
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.row.at === b.row.at &&
    a.row.durationMs === b.row.durationMs &&
    a.row.doing === b.row.doing &&
    a.row.thinkingNow === b.row.thinkingNow &&
    a.row.below === b.row.below &&
    a.row.doingCommand === b.row.doingCommand &&
    a.row.doingDraft === b.row.doingDraft &&
    a.row.doingGroup === b.row.doingGroup &&
    a.row.doingGroupOpen === b.row.doingGroupOpen &&
    a.row.doingSendTo === b.row.doingSendTo &&
    a.row.doingSendSession === b.row.doingSendSession &&
    a.sessionId === b.sessionId,
);
/// The running turn's activity line under its todo list (agent.sessionStatus, cx-ncc.102).
const ActivityLineRow = memo(
  function ActivityLineRow({ row }: RowProps) {
    return <ActivityLine row={row} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.row.at === b.row.at &&
    a.row.doingSendTo === b.row.doingSendTo &&
    a.row.doingSendSession === b.row.doingSendSession,
);

/// How many turns back the header's Preview looks for a page.
const PREVIEW_TURNS = 8;
/// How long a running line count's reveal holds a run open while its row draws (WorkingFor.tsx).
const REVEAL_HOLD_MS = 2_000;
/// Asks the host for a browser tab on a turn's local web page; a host without one (the quick
/// panel) refuses, and the card's address still opens outside the pane.
const openPreview = (url: string) => void callNative("browser.open", { url }).catch(() => undefined);
/// A turn's local web page, live (conversation/PreviewCard.tsx).
const PreviewRow = memo(
  function PreviewRow({ row }: RowProps) {
    return row.text ? <PreviewCard url={row.text} onOpen={openPreview} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.text === b.row.text,
);
/// An ended turn's render call, live (conversation/RenderCard.tsx).
const RenderRow = memo(
  function RenderRow({ row }: RowProps) {
    const tool = row.items?.[0]?.tool;
    return tool && canRender() ? <RenderToolCard tool={tool} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);

const SummaryRow = memo(
  function SummaryRow({ row }: RowProps) {
    return <TurnFooter row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const PlanRow = memo(
  function PlanRow({ row }: RowProps) {
    return row.plan ? (
      <PlanList entries={row.plan} ended={row.turnEnded} />
    ) : (
      <div className="acpmux-muted">{row.text}</div>
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const BackgroundTaskRow = memo(
  function BackgroundTaskRow({ row }: RowProps) {
    return row.backgroundTask ? <BackgroundTaskNote task={row.backgroundTask} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const CompactionRow = memo(
  function CompactionRow({ row }: RowProps) {
    return row.compaction ? <CompactionNote compaction={row.compaction} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const FailoverRow = memo(
  function FailoverRow({ row }: RowProps) {
    return row.failover ? <FailoverNote failover={row.failover} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const PolicyUnenforcedRow = memo(
  function PolicyUnenforcedRow({ row }: RowProps) {
    return row.policyUnenforced ? <PolicyUnenforcedNote note={row.policyUnenforced} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const AgentPairRow = memo(
  function AgentPairRow({ row }: RowProps) {
    return row.agentPair ? <AgentPairNote pair={row.agentPair} onResume={resumeAgentPair} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const SessionStartRow = memo(
  function SessionStartRow({ row }: RowProps) {
    return row.sessionStart ? <SessionStartNote start={row.sessionStart} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const NoticeRow = memo(
  function NoticeRow({ row }: RowProps) {
    return <div className="acpmux-muted">{row.text}</div>;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const PermissionRow = memo(
  function PermissionRow({ row }: RowProps) {
    const t = useT();
    const permission = row.permission;
    if (!permission)
      return (
        <div className="acpmux-permission-card">
          <strong>{t("permission.required")}</strong>
        </div>
      );
    return <PermissionAsk permission={permission} shortcuts={false} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// A decided question's record (question/record.ts): the card's own answered or cancelled form,
/// which answers nothing.
const QuestionRecordRow = memo(
  function QuestionRecordRow({ row }: RowProps) {
    return row.question ? <QuestionCard question={row.question} onReply={ignoreReply} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const ignoreReply = () => {};
/// A single permission card's receipt (permissions/record.ts): one muted line, the decision first.
const PermissionRecordRow = memo(
  function PermissionRecordRow({ row }: RowProps) {
    const t = useT();
    const decision = row.decision;
    if (!decision) return null;
    return (
      <div className="acpmux-permission-record" data-decision={decision.kind}>
        {t(DECISION_TEXT[decision.kind], {
          action: row.permission?.title?.trim() || t("permission.required"),
          option: decision.kind === "answered" ? decision.option : "",
          mode: decision.kind === "fullAccess" ? decision.mode : "",
        })}
        {row.answeredBy && <AnsweredBy person={row.answeredBy} />}
      </div>
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// A batch of subagents (subagents/SubagentGroup.tsx); opening it lists them below.
const SubagentGroupRow = memo(
  function SubagentGroupRow({ row, onToggleActivity, expanded }: RowProps) {
    // An agent a shell call started (`codex exec`) draws as its own card where it started.
    if (isRunGroup(row)) return <AgentRunCard agent={row.subagents![0]!} />;
    return <SubagentGroupHeader row={row} expanded={expanded} onToggle={() => onToggleActivity(row.id)} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.expanded === b.expanded &&
    a.onToggleActivity === b.onToggleActivity,
);
const SubagentRow = memo(
  function SubagentRow({ row }: RowProps) {
    return <SubagentListRow row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// Where a subagent ended, while running ones sit in the tray (subagents/SubagentDoneLine.tsx).
const SubagentDoneRow = memo(
  function SubagentDoneRow({ row }: RowProps) {
    return <SubagentDoneLine row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// A Claude workflow's card where it started (Labs, summary/WorkflowCard.tsx).
const WorkflowCardRow = memo(
  function WorkflowCardRow({ row }: RowProps) {
    return (
      <>
        {(row.subagents ?? []).map((node) => (
          <WorkflowCard key={node.id} node={node} />
        ))}
      </>
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// The child view's "Subagent of" pill; a click goes back to the parent's view.
const SubagentOfPillRow = memo(
  function SubagentOfPillRow({ row }: RowProps) {
    return <SubagentOfRow row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.row.text === b.row.text,
);
/// The edited-files card (conversation/EditedFilesCard.tsx, data in turnChanges/).
const EditedFilesRow = memo(
  function EditedFilesRow({ row, sessionId, onOpenDiff }: RowProps) {
    return <EditedFilesCard row={row} sessionId={sessionId} onOpenDiff={onOpenDiff} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.sessionId === b.sessionId &&
    a.onOpenDiff === b.onOpenDiff,
);

/// Opens a chat started from an offer (`chat.offer.open`): beside this one, else here.
const openOfferChat = (sessionId: string) => void callNative("chat.offer.open", { sessionId }).catch(() => undefined);
/// Opens the chat that sent this one a message, from its received line's chip: any chat the daemon
/// lists, this Mac's or a peer's, beside this one or in the tab that shows it (`sender`).
const openSenderChat = (sessionId: string) =>
  void callNative("chat.offer.open", { sessionId, sender: true }).catch(() => undefined);
/// Send now on a steer the agent has not read (`_acpmux/queue_edit` send_now with its promptId).
const sendSteerNow = (promptId: string) => void editQueued(promptId, { op: "send_now" }).catch(() => false);
/// Another agent's message waiting in the queue: its received card after the running turn
/// (conversation/QueuedMessageCard.tsx).
const QueuedMessageRow = memo(
  function QueuedMessageRow({ row, githubRepository }: RowProps) {
    return (
      <QueuedMessageCard
        row={row}
        onOpen={openSenderChat}
        onReply={replyToMessage}
        githubRepository={githubRepository}
      />
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.githubRepository === b.githubRepository,
);
/// A queued inbox wrapper has one queue target for the whole notice. Keep its Send now/Dismiss
/// controls beside the first flattened preview row without turning every delivery into a queue row.
const InboxQueueActions = memo(function InboxQueueActions({
  queue,
  version,
}: {
  queue: NonNullable<AcpmuxRow["inboxQueue"]>;
  version: number;
}) {
  const act = useContext(TurnActionsContext).queuedMessages?.();
  const [sentAt, setSentAt] = useState<number>();
  const fail = () => undefined;
  return (
    <span className="cv-received-actions">
      <MessageFooterRow>
        <WaitingMessageMenu
          sendNow={
            act && !queue.next && sentAt !== version
              ? () => void act.steer(queue.promptId).then((ok) => ok && setSentAt(version), fail)
              : undefined
          }
          dismiss={act ? () => void act.remove(queue.promptId).catch(fail) : undefined}
        />
      </MessageFooterRow>
    </span>
  );
});
/// The messages that wait for the agent, as one group (conversation/PendingMessagesCard.tsx): each
/// message draws in it as its own row draws alone.
const PendingMessagesRow = memo(
  function PendingMessagesRow(props: RowProps) {
    const renderMessage = (message: AcpmuxRow) =>
      message.kind === LANE_NOTICE_BATCH ? (
        <LaneNoticeBatch row={message} renderMessage={renderMessage} />
      ) : message.inboxThread ? (
        <MessageRow {...props} row={message} />
      ) : message.inboxQueue ? (
        <QueuedMessageRow {...props} row={{ ...message, queuedMessage: message.inboxQueue }} />
      ) : message.kind === QUEUED_MESSAGE ? (
        <QueuedMessageRow {...props} row={message} />
      ) : (
        <MessageRow {...props} row={message} />
      );
    return <PendingMessagesCard row={props.row} onOpen={openSenderChat} renderMessage={renderMessage} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.githubRepository === b.githubRepository,
);
/// An inbox notice's thread the person opened (`chat.inbox.thread`): its messages, oldest first.
const readInboxThread = (threadId: string) => callNative<InboxMessage[]>("chat.inbox.thread", { threadId });
const LaneNoticeBatchRow = memo(function LaneNoticeBatchRow(props: RowProps) {
  return <LaneNoticeBatch row={props.row} renderMessage={(row) => <MessageRow {...props} row={row} />} />;
});
/// Reply on another agent's message card (`chat.message.reply`): its sender gets it in the thread.
const replyToMessage = (message: IncomingMessage, text: string) =>
  callNative<void>("chat.message.reply", {
    sessionId: message.sessionId,
    msgId: message.msgId,
    threadId: message.threadId,
    text,
  });
const offerActions: OfferActions = {
  start: (offerId, worktree) => callNative("chat.offer.start", { offerId, worktree }),
  here: (offerId) => callNative("chat.offer.here", { offerId }),
  dismiss: (offerId) => callNative("chat.offer.dismiss", { offerId }),
  open: openOfferChat,
};

/// An agent's suggested tasks (offer/SuggestedTasks.tsx); the reducer draws them only with Labs
/// preview features or the session-offer experiment on (offer/offersShown.ts).
const SessionOfferRow = memo(
  function SessionOfferRow({ row }: RowProps) {
    return row.offers?.length ? <SuggestedTasks offers={row.offers} actions={offerActions} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);

/// A task's result waiting in the queue: its received line (offer/SuggestedTasks.tsx).
const OfferResultRow = memo(
  function OfferResultRow({ row }: RowProps) {
    return row.received ? <ReceivedResult result={row.received} onOpen={openOfferChat} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);

const NO_STARTED: readonly StartedSession[] = [];
const NO_SESSION_IDS: ReadonlySet<string> = new Set();
const NO_ROWS: readonly AcpmuxRow[] = [];
const NO_EXPANDED: ReadonlySet<string> = new Set();
const NO_SPAWNED: readonly AcpmuxSessionEntry[] = [];
const NO_COMMANDS: readonly BackgroundCommand[] = [];
const NO_AGENTS: readonly Subagent[] = [];
const sameItems = <T,>(a: readonly T[], b: readonly T[]) =>
  a.length === b.length && a.every((item, index) => item === b[index]);

/// The chats this chat's agent started, as cards where each was started (started/StartedSessionCard.tsx).
const StartedSessionsRow = memo(
  function StartedSessionsRow({ row }: RowProps) {
    return row.started?.length ? <StartedSessionCards started={row.started} onOpen={openOfferChat} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);

const defaultRegistry: NativeRegistry = {
  btw: ({ row }) => {
    const aside = row as InlineBtwRow;
    return <BtwAside note={aside.btw} onDismiss={aside.dismissBtw} />;
  },
  user: MessageRow,
  assistant: MessageRow,
  activity: ToolActivityRow,
  [WORKED]: WorkedRow,
  [BACKGROUND_TURN]: BackgroundTurnRow,
  [DATE]: DateRow,
  [THINKING]: ThinkingRow,
  [WORKING]: WorkingRow,
  [ACTIVITY_LINE]: ActivityLineRow,
  [PREVIEW]: PreviewRow,
  [RENDER]: RenderRow,
  editedFiles: EditedFilesRow,
  turnSummary: SummaryRow,
  notice: NoticeRow,
  plan: PlanRow,
  backgroundTask: BackgroundTaskRow,
  compaction: CompactionRow,
  failover: FailoverRow,
  policyUnenforced: PolicyUnenforcedRow,
  agentPair: AgentPairRow,
  sessionStart: SessionStartRow,
  sessionOffer: SessionOfferRow,
  [OFFER_RESULT]: OfferResultRow,
  [QUEUED_MESSAGE]: QueuedMessageRow,
  [PENDING_MESSAGES]: PendingMessagesRow,
  [LANE_NOTICE_BATCH]: LaneNoticeBatchRow,
  [STARTED_SESSIONS]: StartedSessionsRow,
  typing: NoticeRow,
  permission: PermissionRow,
  [QUESTION_RECORD]: QuestionRecordRow,
  [PERMISSION_RECORD]: PermissionRecordRow,
  [SHELL_ROW]: ShellRow,
  [SUBAGENTS]: SubagentGroupRow,
  [SUBAGENT_ROW]: SubagentRow,
  [SUBAGENT_DONE]: SubagentDoneRow,
  [SUBAGENT_OF]: SubagentOfPillRow,
  [SUBAGENT_EMPTY]: SubagentEmptyRow,
  [WORKFLOW_CARD]: WorkflowCardRow,
};

/// A read-only transcript's rows (conversation/readOnly.ts): the default rows, except where a row is
/// only a control on the owner's machine or another of the owner's chats. A pending ask reads as a
/// line (the guest page says who answers it); another agent's waiting message as its received line;
/// a paused agent pair without Resume. Suggested tasks, started chats, a turn's local page and its
/// render frame are the owner's own and draw nothing.
const NoRow = () => null;
const ReadOnlyPermissionRow = memo(
  function ReadOnlyPermissionRow({ row }: RowProps) {
    const t = useT();
    return <div className="acpmux-muted">{row.permission?.title?.trim() || t("permission.required")}</div>;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const ReadOnlyQueuedMessageRow = memo(
  function ReadOnlyQueuedMessageRow({ row, githubRepository }: RowProps) {
    if (row.incoming?.kind !== "message") return null;
    // A person's message (a guest's prompt) is drawn whole here too: its text is never read as a
    // lane notice, so nothing it says is hidden from the read-only transcript either.
    const person = row.queuedMessage?.person;
    const whole = Boolean(
      person || row.queuedMessage?.held || row.queuedMessage?.declined || row.incoming.message.fromPerson,
    );
    return (
      <div className="cv-incoming">
        <IncomingMessageLine
          id={row.id}
          message={row.incoming.message}
          messageAt={row.at}
          images={row.images}
          onOpen={openSenderChat}
          githubRepository={githubRepository}
          {...(person ? { person } : {})}
          {...(whole ? { whole: true } : {})}
        />
      </div>
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.githubRepository === b.githubRepository,
);
const ReadOnlyAgentPairRow = memo(
  function ReadOnlyAgentPairRow({ row }: RowProps) {
    return row.agentPair ? <AgentPairNote pair={row.agentPair} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
export const readOnlyRegistry: NativeRegistry = {
  ...defaultRegistry,
  permission: ReadOnlyPermissionRow,
  [QUEUED_MESSAGE]: ReadOnlyQueuedMessageRow,
  agentPair: ReadOnlyAgentPairRow,
  sessionOffer: NoRow,
  [OFFER_RESULT]: NoRow,
  [STARTED_SESSIONS]: NoRow,
  [PREVIEW]: NoRow,
  [RENDER]: NoRow,
};

/// A row's height as the page drew it at a width. It places the row until its next version is drawn.
/// `actions`: whether a reply kept its action row's room then (model.ts `keepsReplyRoom`); a drawn
/// height taken without it, or with it, is stale once the row after the reply changes that.
type DrawnHeight = {
  sessionId?: string;
  version: number;
  width: number;
  height: number;
  actions?: boolean;
  /// model.ts `statusEdge` when it was drawn: the room under the row depends on it.
  status?: string;
};
/// `height` is undefined for a row the page has not laid out (drawnHeightOf).
type ReportDrawn = (
  id: string,
  version: number,
  height: number | undefined,
  actions?: boolean,
  status?: string,
) => void;

/// A mounted row's drawn height, or undefined when the page has not laid it out (an undisplayed
/// transcript, or a DOM without layout): such a box has no client rects. A laid-out row that draws
/// nothing (a step of only quiet thoughts, a render update that joined an earlier card, a payload
/// that never came) is 0 high, and is placed at 0. Dropping that 0 as "not laid out" kept the row's
/// estimate, 26px for each of its items, as blank space in the transcript (Leo, 2026-10-21: a
/// screen-tall gap under "Worked for" and under an opened fold's last command).
function drawnHeightOf(node: HTMLElement): number | undefined {
  const height = node.getBoundingClientRect().height;
  return height > 0 || node.getClientRects().length > 0 ? height : undefined;
}

type TranscriptRange = { anchorId: string; focusId: string };

/// The longest a chat opened cold takes to fade in (Leo 2026-10-21: "a fast fade in").
const CHAT_OPEN_FADE_MS = 150; // motion-allow: a ceiling on the host's fade-in token (micro, 120 ms), not a duration of its own

/// Fades the transcript of a chat this page opened cold in over the host's fade-in token (the
/// motion scale's micro step without the host), at most CHAT_OPEN_FADE_MS: opacity only, so no row
/// moves, starting on the frame its rows first draw. None when the host turned motion off or its
/// token is 0 (Reduce Motion, ui.animationSpeed off), or while the page is away (entranceAllowed).
function fadeInOpenedChat(node: HTMLElement | null): Animation | undefined {
  if (!node || typeof node.animate !== "function" || !entranceAllowed()) return undefined;
  if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return undefined;
  const style = getComputedStyle(document.documentElement);
  const token = style.getPropertyValue("--agent-motion-in").trim();
  const value = Number.parseFloat(token);
  const asked = !token || !Number.isFinite(value) ? MOTION_MS.micro : token.endsWith("ms") ? value : value * 1000;
  const duration = Math.min(asked, CHAT_OPEN_FADE_MS);
  if (!(duration > 0)) return undefined;
  return node.animate([{ opacity: 0 }, { opacity: 1 }], {
    duration,
    easing: style.getPropertyValue("--agent-ease-out").trim() || "ease-out",
  });
}

/// Whether `entry` is the height already kept for its row. Heights compare exactly: a fold's last
/// frame draws its row a fraction of a pixel short of the height it settles at (145.72px, then
/// 146px), and with any slack the row kept the frame's height, so every row below it sat that
/// fraction too high, over the row above. A height that did not change still compares equal, so
/// it renders nothing.
function sameDrawn(old: DrawnHeight | undefined, entry: DrawnHeight): boolean {
  return (
    old !== undefined &&
    old.sessionId === entry.sessionId &&
    old.version === entry.version &&
    old.width === entry.width &&
    old.height === entry.height &&
    Boolean(old.actions) === Boolean(entry.actions) &&
    old.status === entry.status
  );
}

/// Whether `updates` change any drawn height in `current`.
function changesDrawn(current: Map<string, DrawnHeight>, updates: Map<string, DrawnHeight>): boolean {
  for (const [id, entry] of updates) if (!sameDrawn(current.get(id), entry)) return true;
  return false;
}

/// RowFrame redraws only when a prop it or its row's renderer reads changed. `children` is left out:
/// it is a new element every render, built from `row` and the content props passed beside it
/// (`contentType` and the rest), so comparing every other prop is enough. The callbacks are stable
/// across snapshots (VirtualTranscript and the pane hold them), so a streaming snapshot that changes
/// only the latest row leaves every other mounted row alone.
function sameReferenceScope(previous: ReferenceScope | undefined, next: ReferenceScope | undefined): boolean {
  if (previous === next) return true;
  if (!previous || !next || previous.at !== next.at) return false;
  if (previous.evidence.linked.length !== next.evidence.linked.length) return false;
  if (!previous.evidence.linked.every((repo, index) => repo === next.evidence.linked[index])) return false;
  const sameMap = <K, V>(a: ReadonlyMap<K, V>, b: ReadonlyMap<K, V>, valueEqual: (left: V, right: V) => boolean) => {
    if (a.size !== b.size) return false;
    for (const [key, value] of a) {
      const other = b.get(key);
      if (other === undefined || !valueEqual(value, other)) return false;
    }
    return true;
  };
  const sameMentions = (
    left: readonly { at: number; repo: string }[],
    right: readonly { at: number; repo: string }[],
  ) =>
    left.length === right.length &&
    left.every((mention, index) => mention.at === right[index]?.at && mention.repo === right[index]?.repo);
  return (
    sameMap(previous.evidence.mentions, next.evidence.mentions, sameMentions) &&
    sameMap(previous.turn, next.turn, (left, right) => left === right)
  );
}

/// Whether two rows hold the same value in every own field (one level deep).
function sameFields(previous: AcpmuxRow, next: AcpmuxRow): boolean {
  if (previous === next) return true;
  const before = previous as unknown as Record<string, unknown>;
  const after = next as unknown as Record<string, unknown>;
  const keys = Object.keys(after);
  return keys.length === Object.keys(before).length && keys.every((key) => Object.is(before[key], after[key]));
}

function sameRowFrame(previous: Record<string, unknown>, next: Record<string, unknown>): boolean {
  const keys = Object.keys(next);
  if (keys.length !== Object.keys(previous).length) return false;
  return keys.every((key) => {
    if (key === "children") return true;
    if (key === "row") {
      // Snapshot rebuilding can clone unchanged rows when a prompt is sent. Row renderers already
      // use id/version as their draw identity; comparing the object here made every mounted frame
      // repaint on that send even though its content had not changed. Keep the frame's own flags in
      // the comparison because they are read outside the child renderer.
      const before = previous.row as AcpmuxRow;
      const after = next.row as AcpmuxRow;
      // The running turn's live and working lines are drawn by turns.ts on every snapshot with a
      // fixed version: what they say (the call in flight, its time, the clock offset) is in their
      // fields, so they redraw whenever a field changes.
      if (after.kind === THINKING || after.kind === WORKING) return sameFields(before, after);
      return (
        before.id === after.id &&
        before.version === after.version &&
        before.below === after.below &&
        before.ended === after.ended
      );
    }
    if (key === "referenceScope")
      return sameReferenceScope(
        previous.referenceScope as ReferenceScope | undefined,
        next.referenceScope as ReferenceScope | undefined,
      );
    return Object.is(previous[key], next[key]);
  });
}

/// One transcript row. It reports its drawn height before the frame paints whenever it mounts or
/// its content, width or expansion changes; the transcript's ResizeObserver reports later changes
/// (a font that loads, a custom renderer that grows).
const RowFrame = React.memo(function RowFrame({
  row,
  kind,
  joinsPrevious,
  joinsNext,
  beforeFooter,
  replyActions,
  status,
  lastFooter,
  continuationFooter,
  lastTurn,
  index,
  setSize,
  top,
  rowWidth,
  expanded,
  observer,
  report,
  enter,
  onEntered,
  older,
  onOlderShown,
  active,
  selected,
  tabStop,
  onFocus,
  onRowKeyDown,
  referenceScope,
  children,
}: {
  row: AcpmuxRow;
  kind: string;
  /// A step row (tool calls, thoughts, a background task's end) after another: no gap above it.
  joinsPrevious: boolean;
  /// A step row before another: no gap below it, so steps keep one 26px rhythm across rows.
  joinsNext: boolean;
  /// A reply right over its turn's footer: the footer hugs it (`--cv-meta-gap`), as a meta row.
  beforeFooter: boolean;
  /// Whether the row (a reply) keeps its action row's room (model.ts `keepsReplyRoom`): its height
  /// depends on it, so the frame redraws and measures again when it changes.
  replyActions: boolean;
  /// Next to a status row (model.ts `statusEdge`): the room between the row and the next one is the
  /// status gap, so a status line between two replies sits in the middle of it.
  status: StatusEdge | undefined;
  /// The chat's last footer: it ends at the message gap, so no band sits over the composer.
  lastFooter: boolean;
  /// The next drawn turn belongs to this same assistant: half the normal turn gap.
  continuationFooter: boolean;
  /// The final row of a latest turn without a footer: preserve the normal turn gap at the composer.
  lastTurn: boolean;
  index: number;
  setSize: number;
  top: number;
  rowWidth: number;
  expanded: boolean;
  observer: ResizeObserver | undefined;
  report: ReportDrawn;
  /// The row arrived live: it enters with the shared motion on this, its first mount.
  enter: boolean;
  onEntered: (id: string) => void;
  /// The row came in on a late page of older history and has never mounted: its first copy fades once.
  older: OlderRowFade | undefined;
  onOlderShown: (id: string) => void;
  active: boolean;
  selected: boolean;
  tabStop: boolean;
  onFocus: (id: string) => void;
  onRowKeyDown: (index: number, event: React.KeyboardEvent<HTMLElement>) => void;
  /// What the child row draws from, compared instead of `children` (a new element every render).
  contentType: unknown;
  controls?: string;
  onToggleActivity: (id: string) => void;
  onOpenDiff?: OpenDiff;
  githubRepository?: string;
  /// Which repository the row's bare `#N` names (conversation/bareReferences.ts).
  referenceScope?: ReferenceScope;
  children: React.ReactNode;
}) {
  acpmuxPerf.span("row.renders", 1);
  const t = useT();
  const ref = useRef<HTMLElement>(null);
  const [entering] = useState(enter);
  // Prompts and replies get the message-specific entrance. Tool/status rows keep the existing
  // generic rise, while the row's reserved height and absolute placement stay unchanged.
  // Hidden user rows render no content and keep the empty-row geometry. Notice rows are user-kind
  // status lines whose `.cv-tools` strip row CSS targets as the article's direct child, so they keep
  // the generic entrance too. Only real prompts and replies get the presentation wrapper.
  const messageEntering =
    entering &&
    (row.kind === "assistant" ||
      (row.kind === "user" && row.incoming?.kind !== "hidden" && row.incoming?.kind !== "notice"));
  const [olderFade] = useState(older);
  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLElement>) => onRowKeyDown(index, event),
    [index, onRowKeyDown],
  );
  const rowTabStop = rovingTabStopProps(tabStop, handleKeyDown);
  const content = (
    <ReferenceScopeContext.Provider value={referenceScope ?? null}>{children}</ReferenceScopeContext.Provider>
  );
  useLayoutEffect(() => {
    if (entering) onEntered(row.id);
    // Only the first mount enters.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || !olderFade) return;
    // A warm-window copy has rendered too: consume eligibility and start its fade before paint,
    // even offscreen. Neither a later intersection nor a remount may defer or replay it.
    onOlderShown(row.id);
    node.dataset.olderShown = "true";
    return olderFade.watch(node, () => onOlderShown(row.id));
    // Only the first mount fades.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || !observer) return;
    observer.observe(node);
    return () => observer.unobserve(node);
  }, [observer]);
  useLayoutEffect(() => {
    const node = ref.current;
    if (node)
      report(
        row.id,
        row.version,
        acpmuxPerf.timed("row.measure", () => drawnHeightOf(node)),
        replyActions,
        status,
      );
  }, [
    row.id,
    row.version,
    replyActions,
    status,
    rowWidth,
    expanded,
    joinsPrevious,
    joinsNext,
    beforeFooter,
    lastFooter,
    continuationFooter,
    lastTurn,
    report,
  ]);
  const placedTop = top + THREAD_TOP;
  const integralTop = Math.floor(placedTop);
  return (
    <article
      ref={ref}
      id={rowDomId(row.id)}
      data-row-id={row.id}
      data-row-card={row.ended ? "true" : undefined}
      className={`acpmux-row acpmux-${kind}${isLineRow(row) ? " acpmux-row--line" : ""}${row.below ? " acpmux-row--below" : ""}${joinsPrevious ? " acpmux-row--after-step" : ""}${joinsNext ? " acpmux-row--before-step" : ""}${beforeFooter ? " acpmux-row--before-footer" : ""}${replyActions ? " acpmux-row--reply-room" : ""}${status ? ` acpmux-row--${status}` : ""}${lastFooter ? " acpmux-row--last-footer" : ""}${continuationFooter ? " acpmux-row--continuation-footer" : ""}${lastTurn ? " acpmux-row--last-turn" : ""}${messageEntering ? " acpmux-row--message-enter" : entering ? " acpmux-row--enter" : ""}${olderFade ? " acpmux-row--older" : ""}`}
      data-transcript-active={active ? "true" : undefined}
      data-transcript-selected={selected ? "true" : undefined}
      aria-current={active ? "true" : undefined}
      {...rowTabStop}
      aria-label={speaker(kind, t)}
      aria-posinset={index + 1}
      aria-setsize={setSize}
      // `top`, not a transform: in the app (the page at its UI-scale zoom) a drag over a row placed
      // by `translateY` selected the line above the pointer (user 2026-10-21). A set `top` counts
      // from the thread's padding edge, not where an unset one sat, so it adds the padding.
      // Large CSS numeric offsets lose fractional bits in WebKit. Keep the integer offset and
      // its subpixel remainder separate so animated row heights remain adjacent in long chats.
      style={{ top: integralTop, marginTop: placedTop - integralTop }}
      onFocus={() => onFocus(row.id)}
    >
      {messageEntering ? (
        // The article is the virtualizer's measured box. Animate only this presentation wrapper:
        // compositor scale/opacity cannot change drawnHeightOf(article) while the entrance runs.
        <div className="acpmux-row__message-presentation">{content}</div>
      ) : (
        content
      )}
      {/* The row's own trailing padding is the only row-local empty surface owned by transcript
          selection. Keeping it as a separate hit target means content controls (including native
          media) never need to be enumerated by the gap handler. */}
      <span className="acpmux-row__gap" data-transcript-gap="row" aria-hidden="true" />
    </article>
  );
}, sameRowFrame);

/// Who spoke, for assistive technology: each article is one message in the transcript feed.
const speaker = (kind: string, t: Translate) =>
  kind === "user" ? t("transcript.you") : kind === "assistant" ? t("transcript.agent") : undefined;
const rowKind = (row: AcpmuxRow) => (isEditRow(row) ? "editedFiles" : row.kind);
/// A row drawn as tool rows: tool calls and thoughts, a background task's or a subagent's end, a
/// compaction, a failover, a policy the harness cannot keep or a session start note, and the one-line
/// rows drawn on the tool rows' line (model.ts `isLineRow`: another agent's message, a notice, an
/// inbox notice, a report batch's or the waiting group's head), so they all sit one line apart.
const isStepRow = (row: AcpmuxRow | undefined) =>
  row !== undefined &&
  (isLineRow(row) ||
    row.kind === "backgroundTask" ||
    row.kind === SUBAGENT_DONE ||
    row.kind === "compaction" ||
    row.kind === "failover" ||
    row.kind === "policyUnenforced" ||
    row.kind === "agentPair" ||
    row.kind === "sessionStart" ||
    (row.kind === "activity" && !isEditRow(row)));
const rowDomId = (id: string) => `acpmux-row-${encodeURIComponent(id)}`;
const disclosureControls = (rows: readonly AcpmuxRow[], after: number): string | undefined => {
  const ids: string[] = [];
  for (let index = after; index < rows.length; index += 1) {
    const row = rows[index]!;
    // turnView marks every row copied under an open Worked-for disclosure as settled. This
    // includes assistant commentary before the tool calls; stopping on kind alone left that
    // first commentary row outside aria-controls and made the disclosure target incomplete.
    if (!row.settled) break;
    ids.push(rowDomId(row.id));
  }
  return ids.length > 0 ? ids.join(" ") : undefined;
};
const currentRegistry = (): NativeRegistry => ({
  ...defaultRegistry,
  ...(window.cmuxAcpmuxRegistry as unknown as NativeRegistry | undefined),
});

/// The thread's top padding (styles.css `.acpmux-thread`): rows draw this far below their places
/// (each row's `top` adds it), so the transcript ends this far past their total height.
const THREAD_TOP = 16;
/// Small layout changes arrive constantly while a reply streams. Treat the bottom as a short
/// resting zone so every token does not write a new fractional scroll offset (and make the thumb
/// visibly twitch at the same cadence). A meaningful displacement still corrects immediately.
/// Four CSS pixels is below the visual rhythm of a transcript line, so the reader gets a little
/// give while a burst is measured and one correction when that burst is meaningful.
export const FOLLOW_BOTTOM_DEADBAND_PX = 4;

/// Where a scroller sits, read while its content still matches `totalHeight`.
const scrollPosition = (node: HTMLElement, totalHeight: number) => ({
  top: node.scrollTop,
  atLatest: layoutScrollTop(node) >= totalHeight - node.clientHeight - FOLLOW_BOTTOM_DEADBAND_PX,
});

/// Whether reader input moves the transcript toward its latest row: a wheel down or a key that
/// scrolls down. Such input never leaves the latest row, so follow-bottom need not wait for it.
function movingDown(event?: Event): boolean {
  if (event?.type === "wheel") return (event as WheelEvent).deltaY > 0;
  if (event?.type === "keydown")
    return ["ArrowDown", "PageDown", "End", " ", "Spacebar"].includes((event as KeyboardEvent).key);
  return false;
}

/// Puts a following view at the latest row. Anything past the browser's rounding is corrected: the
/// stack's eased growth (the queue's max-height move, #24718) comes in steps under
/// `FOLLOW_BOTTOM_DEADBAND_PX`, and a deadband here left the view resting up to that far from its end,
/// the last row under the stack. A fractional end is rounded up: WebKit floors a fractional offset
/// while it rounds the content's height, so the end as written rested a pixel short of the
/// scroller's own; past it, the browser clamps the offset to that end.
function settleFollowBottom(node: HTMLElement, latest: number): boolean {
  const end = Math.ceil(latest - 0.01);
  // Where the write lands: a scroller already clamped there is at its end.
  const lands = Math.min(end, Math.max(0, node.scrollHeight - node.clientHeight));
  const moved = Math.abs(lands - node.scrollTop) > 0.5;
  if (moved) node.scrollTop = end;
  // Measurements above the view can move the logical end by half a pixel while the physical
  // end stays rounded. Keep that fraction even when the browser already clamped to the end,
  // so releasing follow before the next wheel does not inherit a half-pixel row jump.
  retainScrollOrigin(node, latest);
  return moved;
}

/// Scroll steps of rows mounted ahead in the scroll direction, capped in viewports.
/// A scroll commits from its event, a frame after the offset moved, so without the
/// lead a fling shows a blank edge on every frame.
const SCROLL_LEAD_STEPS = 2;
/// More new rows than this in one update are a load (a session switch, older history), not live rows.
const LIVE_ROWS_PER_UPDATE = 3;

/// Viewports from the top of the loaded rows within which a page of older history came late: the
/// reader reached rows that were not loaded yet, so the page fades in. Pages ask well ahead
/// (OLDER_AHEAD_VIEWPORTS), so a page normally lands farther away and draws in place.
const OLDER_LATE_VIEWPORTS = 1;
/// Whether the reader's view is at the top of the loaded rows, read before a page lands above them.
/// A hidden or unplaced scroller draws in place (WebKit would play a hidden page's fade on return).
function readerAtLoadedTop(node: HTMLElement | null): boolean {
  if (!node || node.clientHeight === 0) return false;
  return node.scrollTop - scrollOrigin(node) < node.clientHeight * OLDER_LATE_VIEWPORTS;
}

/// Rows from a page of older history that came late (readerAtLoadedTop) fade on their first mounted copy, including warm copies
/// outside the view. Eligibility is consumed before paint; an intersection only releases the
/// observation and never starts a second fade. Opacity only, so nothing measured moves.
class OlderRowFade {
  private readonly pending = new Set<string>();
  private readonly waiting = new Map<Element, () => void>();
  private intersections: IntersectionObserver | undefined;
  constructor(private readonly root: () => HTMLElement | null) {}
  add(id: string) {
    this.pending.add(id);
  }
  has(id: string) {
    return this.pending.has(id);
  }
  shown(id: string) {
    this.pending.delete(id);
  }
  clear() {
    this.pending.clear();
  }
  /// Releases the first copy's observation when it intersects; returns the unwatch.
  watch(node: HTMLElement, shown: () => void): () => void {
    if (typeof IntersectionObserver === "undefined") {
      shown();
      return () => {};
    }
    this.intersections ??= new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          const target = entry.target as HTMLElement;
          target.dataset.olderShown = "true";
          this.intersections?.unobserve(target);
          this.waiting.get(target)?.();
          this.waiting.delete(target);
        }
      },
      { root: this.root() },
    );
    this.waiting.set(node, shown);
    this.intersections.observe(node);
    return () => {
      this.waiting.delete(node);
      this.intersections?.unobserve(node);
    };
  }
  disconnect() {
    this.intersections?.disconnect();
    this.intersections = undefined;
    this.waiting.clear();
  }
}
/// How far around the last mounted range a row whose drawn height changed is looked for; farther
/// (a jump), the whole transcript is placed again.
const DRAWN_SEARCH_ROWS = 64;
const MAX_SCROLL_LEAD_VIEWPORTS = 4;
/// Viewports of rows kept mounted either side of the reader, built between frames.
const WARM_VIEWPORTS = 1;
/// How far above the latest message the reader is before Jump to latest shows.
const JUMP_LATEST_DISTANCE = 80;
/// How long a scroll event can be attributed to the reader's most recent input. Expiring this
/// window never changes the reader's follow choice; it only distinguishes subsequent events.
const READER_SCROLL_MS = 1000;
/// How long a followed view keeps the room a queued prompt's card left, for the prompt to arrive.
const FLOOR_HOLD_MS = 1000;
/// How long it keeps the room a withdrawn prompt's card left after the reply last grew: a reply
/// streaming fills it, and a turn in a tool call or thinking brings nothing to fill it with.
const WITHDRAWN_HOLD_MS = 250;
/// How long a reopened chat stays unseen while older pages bring back the row the reader left it on
/// (cx-odzaz): each page must land within OPEN_AT_PAGE_MS and the whole walk within OPEN_AT_SEEK_MS,
/// else the chat opens at its latest message.
const OPEN_AT_PAGE_MS = 1500;
const OPEN_AT_SEEK_MS = 8000;
/// How soon the transcript asks again for an older page after an ask that brought nothing.
const OLDER_RECHECK_MS = 500;
/// How near the first loaded row, in viewports, the view asks for the next older page: far enough
/// ahead that a page read from acpmux lands before a fast scroll up reaches the top (two viewports
/// was a fraction of a second of a flick).
const OLDER_AHEAD_VIEWPORTS = 6;
/// Scrolls `scroller` so `range` sits a third of the way down it, when it is not already in view
/// above the `inset` px at its foot that the bottom stack covers.
function scrollRangeIn(scroller: HTMLElement, range: Range, inset = 0) {
  const box = range.getBoundingClientRect();
  const view = scroller.getBoundingClientRect();
  if (box.top < view.top || box.bottom > view.bottom - inset)
    scroller.scrollTop += box.top - view.top - scroller.clientHeight / 3;
}
/// Scrolls `range` into view in the scrollers between it and `transcript` (a command's capped
/// output scrolls on its own), innermost first; the transcript itself is left to the caller.
function scrollRangeInBoxes(transcript: HTMLElement, range: Range) {
  for (let box = range.startContainer.parentElement; box && box !== transcript; box = box.parentElement)
    if (box.scrollHeight > box.clientHeight && /auto|scroll/.test(getComputedStyle(box).overflowY))
      scrollRangeIn(box, range);
}
/// How long Find keeps a new match in view while its groups open and the rows above it measure:
/// at least 600 ms and 36 frames, so a page the machine starves (fewer frames) still holds the
/// match through the measures that come late. A page hidden meanwhile draws no frames and finishes
/// the frames it has left once shown.
const FIND_REVEAL_MS = 600;
const FIND_REVEAL_FRAMES = 36;
/// ...and until the match has not moved for this many frames: on a starved page the fold it opened
/// measures for seconds, each measure pushing the match down.
const FIND_REVEAL_STILL_FRAMES = 12;
/// A layout that never settles (a reply streaming above the match) ends the hold after this many.
const FIND_REVEAL_MAX_FRAMES = 600;
/// The current Find match's range, if it is drawn.
function findActiveRange(): Range | undefined {
  const highlights = (globalThis.CSS as unknown as { highlights?: Map<string, Set<Range>> } | undefined)?.highlights;
  return [...(highlights?.get(FIND_ACTIVE_HIGHLIGHT) ?? [])][0];
}
/// Where the current Find match sits in `scroller`'s content, if it is drawn.
function findMatchOffset(scroller: HTMLElement): number | undefined {
  const range = findActiveRange();
  if (!range) return undefined;
  return range.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
}
/// A scroll that rests this long is where the chat reopens (cx-6bgzj), reported once, not per frame.
export const SCROLL_ANCHOR_SETTLE_MS = 400;
/// Where a chat's transcript rests: the row at the top of the view and how far into it; null is the
/// latest message, which a reopened chat follows anyway.
export type ScrollAnchor = { rowId: string; offset: number };

/// Where a transcript scrolled to `top` rests: null at its latest message.
function restingAnchor(
  top: number,
  atLatest: boolean,
  placed: Parameters<typeof visibleLayoutRange>[0],
  shown: readonly { id: string }[],
): ScrollAnchor | null {
  const index = visibleLayoutRange(placed, top, 0, 0).first;
  const row = shown[index];
  return atLatest || !row ? null : { rowId: row.id, offset: top - placed.tops[index] };
}

/// Jump to latest: a glass circle centered above the composer, shown while the reader is scrolled up
/// from the latest message (ChatGPT and Codex style). While the agent works it stays a static arrow;
/// the working state is already represented by the shared transcript spinner. It stays mounted while
/// hidden (inert) so it fades out as it fades in (conversation.css).
function JumpToLatest({
  shown,
  working,
  onJump,
  lift,
  needsYou,
}: {
  shown: boolean;
  working: boolean;
  /// Open asks (needsYou/JumpPill.ts): the button becomes the Needs your input pill.
  needsYou?: TranscriptNeedsYou;
  /// The bottom stack's height over the transcript's foot: the button sits above it.
  lift: number;
  /// `focused`: the button had keyboard focus, which it loses when it hides at the latest message.
  onJump: (focused: boolean) => void;
}) {
  const t = useT();
  if (needsYou && needsYou.count > 0) return <NeedsYouPill {...needsYou} shown={shown} lift={lift} onJump={onJump} />;
  const label = t(working ? "transcript.jumpLatestWorking" : "transcript.jumpLatest");
  return (
    <button
      type="button"
      className="ui-glass ui-glass-floats acpmux-jump-latest"
      data-shown={shown ? "" : undefined}
      style={lift > 0 ? ({ "--acpmux-dock-space": `${lift}px` } as React.CSSProperties) : undefined}
      aria-label={label}
      // The arrow says nothing by itself; working state is carried by the shared spinner in the transcript.
      title={label}
      // Hidden, it is inert: out of the tab order and the accessibility tree while it fades out.
      inert={!shown}
      // A click does not focus a button in WebKit, so focus on it means Return or Space.
      onClick={(event) => onJump(event.currentTarget === document.activeElement)}
    >
      <span className="acpmux-jump-latest__arrow" aria-hidden="true">
        <ArrowDown size={14} />
      </span>
    </button>
  );
}

/// A read-only transcript draws inside the guest boundary (conversation/GuestActionsBoundary.tsx).
function ReadOnlyBoundary({ readOnly, children }: { readOnly: boolean; children: React.ReactNode }) {
  return readOnly ? <GuestActionsBoundary>{children}</GuestActionsBoundary> : <>{children}</>;
}
/// What the transcript's rows read from it: Find's reveal target and, for a prompt's own bookmark
/// button, the session its marks key into (threadMinimap/promptMarks.ts).
function TranscriptContext({
  find,
  sessionId,
  children,
}: {
  find: React.ContextType<typeof FindReveal>;
  sessionId?: string;
  children: React.ReactNode;
}) {
  return (
    <FindReveal.Provider value={find}>
      <PromptMarksSession.Provider value={sessionId ?? ""}>{children}</PromptMarksSession.Provider>
    </FindReveal.Provider>
  );
}

export function VirtualTranscript({
  rows,
  earlier,
  promptCount,
  loadThrough,
  sessionId,
  onToggleActivity,
  onOpenDiff,
  expanded,
  registry: givenRegistry,
  readOnly = false,
  canLoadOlder = false,
  historyFrom,
  githubRepository,
  fallbackRepository,
  sourceRows,
  find,
  reveal,
  working = false,
  jumpButton = false,
  needsYou,
  dock,
  queueWithdrawn,
  queueIds,
  queuedTail,
  focusComposer,
  openAt,
  onAnchor,
  anchorNow,
  onLoadOlder,
  sends = 0,
  onFollowingChange,
  coldOpen,
  onColdOpenShown,
  afterLatest,
  showMinimap = true,
  endReserve = 0,
}: {
  rows: readonly AcpmuxRow[];
  /// The chat's prompts older than `rows` (the snapshot's `earlierPrompts`): the thread rail lays
  /// them out from the first frame, so it never grows or shifts as history pages in.
  earlier?: readonly AcpmuxRow[];
  /// The chat's prompt count while it does not hold every prompt yet (the snapshot's `promptCount`):
  /// the rail starts at the height that many prompts take, with the held ones at their final rows.
  promptCount?: number;
  /// Pages history in until the prompt at `seq` is held (a click on an earlier prompt's tick).
  loadThrough?: (seq: number) => Promise<boolean>;
  sessionId?: string;
  /// Where the transcript opens instead of the latest message, when that row is loaded.
  openAt?: ScrollAnchor;
  /// Where it rests after each settled scroll (null at the latest message).
  onAnchor?: (anchor: ScrollAnchor | null) => void;
  /// Filled with where it last rested in view (null at the latest message, undefined when it was
  /// never in view), for a page about to let go.
  anchorNow?: React.MutableRefObject<(() => ScrollAnchor | null | undefined) | undefined>;
  /// A reply is streaming: Jump to latest remains static while the shared transcript spinner carries
  /// the working state.
  working?: boolean;
  /// Draw Jump to latest: the chat's own stage only, which positions it above the composer.
  jumpButton?: boolean;
  /// Open asks: Jump to latest becomes the Needs your input pill (needsYou/JumpPill.tsx).
  needsYou?: TranscriptNeedsYou;
  /// The chat's bottom stack, laid over the transcript's foot (bottomStack.css): the view runs under
  /// it, the scrollbar's track to the pane's bottom as in the Claude and Codex apps, and its end sits
  /// above it. Its height is room under the last row, followed as it changes before the frame paints.
  dock?: HTMLElement | null;
  /// Prompts withdrawn from the queue (snapshot `queueWithdrawn`): no row comes for one whose card
  /// leaves the stack, so the view keeps no room for it.
  queueWithdrawn?: readonly string[];
  /// IDs from the queue snapshot: a folded prompt has no card in the DOM, but remains queued and
  /// must not be recorded as withdrawn when the fold changes.
  queueIds?: readonly string[];
  /// The waiting agent messages at the rows' end (conversation/queuedMessages.ts), one array while
  /// the queue holds them.
  queuedTail?: readonly AcpmuxRow[];
  /// Where a keyboard Jump to latest leaves focus, since the button hides (inert) once there.
  focusComposer?: () => void;
  onToggleActivity: (id: string) => void;
  onOpenDiff?: OpenDiff;
  expanded: Folds;
  registry?: NativeRegistry;
  canLoadOlder?: boolean;
  /// The oldest event seq held (AcpmuxSnapshot.historyFrom): a read that drew no row still moves it.
  historyFrom?: number;
  /// Pages older history in (canLoadOlder): asked once per loaded page while the view is near the top.
  onLoadOlder?: () => Promise<void>;
  /// How many prompts this pane has sent: each new one puts the view at the latest message.
  sends?: number;
  /// Keeps the parent send path in sync with the reader's current follow state.
  onFollowingChange?: (following: boolean) => void;
  githubRepository?: string;
  /// The repository a bare `#N` means when `githubRepository` is unknown and the transcript names
  /// none before it (the header pull request's).
  fallbackRepository?: string;
  /// The client's rows, which still hold the work a closed "Worked for" folds away: where a bare
  /// `#N`'s repository is looked for (conversation/bareReferences.ts). Else `rows`.
  sourceRows?: readonly AcpmuxRow[];
  /// Find in Chat (chatFind.ts): its bar, the query to highlight and the match to bring into view.
  find?: ChatFind;
  /// A row to bring into view (a count on the running line, WorkingFor.tsx); a new `key` asks again.
  /// The run that holds call `toolId` opens, as for a Find match.
  reveal?: { rowId: string; key: number; toolId: string };
  /// A chat the page switched to and read cold, by its open (a new number per open), whose rows
  /// have not shown yet: they fade in once, on the frame they first draw (fadeInOpenedChat).
  /// Undefined for a chat drawn from a kept tail, which shows whole on the frame the switch lands
  /// ("instant if cached"), for the first chat a page shows, which the host reveals
  /// (pane.painted), and once the open's rows have shown.
  coldOpen?: number;
  /// The rows of open `coldOpen` have shown. The pane keeps that, not this transcript, so a
  /// transcript mounted again (back from New Tab or a replay) does not fade the same open twice.
  onColdOpenShown?: (open: number) => void;
  /// Optional content placed immediately after the latest message, outside the scroller.
  afterLatest?: React.ReactNode;
  /// The focused chat's palette action can hide this pane's rail without changing the configured
  /// minimap experiment or any other pane's layout.
  showMinimap?: boolean;
  /// Drawn for a reader who may not act (a shared chat's guest, conversation/readOnly.ts): the rows
  /// come from `readOnlyRegistry` unless a registry is given, and no row draws an owner's control.
  readOnly?: boolean;
  /// Room the column keeps at its right for the computer use live preview (`--cv-inset-end`,
  /// computerUse/computerUsePreview.ts): rows are laid out that much narrower.
  endReserve?: number;
}) {
  const registry = givenRegistry ?? (readOnly ? readOnlyRegistry : defaultRegistry);
  const t = useT();
  // Debug measurement (acpmuxPerf): off until the first debug call.
  const renderStart = acpmuxPerf.enabled ? performance.now() : 0;
  acpmuxPerf.span("vt.renders", 1);
  const scrollRef = useRef({ top: 0, delta: 0 });
  const [, setScroll] = useState(scrollRef.current);
  const setScrollAt = (top: number, delta = top - scrollRef.current.top) => {
    const next = { top, delta };
    scrollRef.current = next;
    setScroll(next);
  };
  /// The view follows the latest row (scrolledTo.atLatest, as of the last scroll). Jump to latest shows
  /// when it does not and the latest message is more than JUMP_LATEST_DISTANCE below, read each render,
  /// so a reply growing below or a session switch updates it without a scroll.
  const [following, setFollowing] = useState(true);
  /// Jump to latest is shown (`behind`, below): set past JUMP_LATEST_DISTANCE, cleared only back at
  /// the latest message.
  const jumpShown = useRef(false);
  // Without the folder's GitHub remote, a bare `#N` in a row means the repository the transcript
  // mentioned last (conversation/transcriptRepositories.ts); each row's text is read once per change.
  const repositoryCache = useRef<RepositoryCache>(new Map());
  const rowRepositories = useMemo(
    () => (githubRepository ? undefined : transcriptRepositories(rows, fallbackRepository, repositoryCache.current)),
    [githubRepository, fallbackRepository, rows],
  );
  // Which repository each row's bare `#N` names, by the transcript's evidence
  // (conversation/bareReferences.ts): one scope object per turn, kept while nothing new is named;
  // a streaming reply reads only its own row again.
  const referenceCache = useRef(newReferenceScopeCache());
  const scopeAt = useMemo(() => {
    const cache = referenceCache.current;
    const scopeOf = referenceScopes(sourceRows ?? rows, cache);
    return (index: number) => scopeOf(turnOpener(cache, rows, index));
  }, [rows, sourceRows]);
  // `scroll` events also fire for layout-driven writes to scrollTop. Keep the user's intent in a
  // ref so those events cannot turn a pinned transcript into a one-frame jump when the composer
  // stack changes height.
  const followingRef = useRef(true);
  const followDeferred = useRef(false);
  /// A send or a move toward the latest row asks to follow now, through the input hold that defers
  /// follow-bottom. It lasts until the reader's next input (userScroll.ts `request`).
  const followRequest = useRef<(() => boolean) | undefined>(undefined);
  /// Upward reader input whose scroll event has not come yet: the live offset already holds that
  /// movement, so the anchor pass keeps it. Once the event is processed, a later live change is
  /// layout work (#26718) and the stored offset is the base again.
  const [followResume, resumeDeferredFollow] = useReducer((count: number) => count + 1, 0);
  const follow = (next: boolean) => {
    followingRef.current = next;
    onFollowingChange?.(next);
    setFollowing(next);
  };
  const followRef = useRef(follow);
  followRef.current = follow;
  const transcriptMounted = useRef(true);
  const scrollPacer = useRef<ReturnType<typeof createScrollPacer> | undefined>(undefined);
  scrollPacer.current ??= createScrollPacer((frame: ScrollFrame) => {
    if (!transcriptMounted.current) return;
    // A wheel/default write or a rail jump may move the live scroller after an event queued this
    // frame. The queued state is stale, but dropping it starves virtualization until motion stops.
    // Commit the live offset and preserve the synchronous reader/jump intent instead.
    if (ref.current && Math.abs(ref.current.scrollTop - frame.top) > 0.5) {
      const node = ref.current;
      const top = node.scrollTop;
      const atLatest = authoritativeScrollIntent({
        top,
        scrollHeight: node.scrollHeight,
        clientHeight: node.clientHeight,
        following: followingRef.current,
        jumping: jumpTarget.current !== undefined,
        deadband: FOLLOW_BOTTOM_DEADBAND_PX,
      });
      scrollRef.current = { top, delta: top - scrollRef.current.top || scrollRef.current.delta };
      // Route recovery through the authoritative setter so the parent callback and synchronous
      // intent ref agree; a stale queued `atLatest` must not retake a parked reader.
      flushSync(() => {
        followRef.current(atLatest);
        setScroll(scrollRef.current);
      });
      return;
    }
    acpmuxPerf.timed("flush.scroll", () => {
      flushSync(() => {
        setScroll(scrollRef.current);
        // Upward intent can arrive before the browser's default moves the offset. Even at the
        // queued frame's exact position, its old follow state must not replace that live intent.
        setFollowing(followingRef.current);
      });
    });
  });
  const queueScroll = (top: number, atLatest: boolean) => {
    // Keep the intent ref synchronous so a second scroll event before the next frame sees the
    // reader's latest state; React work itself is coalesced by scrollPacer.
    followingRef.current = atLatest;
    onFollowingChange?.(atLatest);
    // The pacer may already have committed this offset (a frame-driven scroll moves it before its
    // event comes): an event that brings no new offset keeps the direction the scroll has. Its delta
    // of 0 left the next render no lead, and a fling painted blank frames (transcript-fling on the
    // CI runner, mounted rows a step behind the view).
    scrollRef.current = { top, delta: top - scrollRef.current.top || scrollRef.current.delta };
    scrollPacer.current!.enqueue({ top, atLatest });
  };
  useEffect(() => {
    transcriptMounted.current = true;
    return () => {
      transcriptMounted.current = false;
      scrollPacer.current?.cancel();
    };
  }, []);
  /// Where Jump to latest's glide is headed while it is in flight: its steps are the view following,
  /// not the reader's scroll, and nothing snaps it to the end before it arrives.
  const jumpTarget = useRef<number | undefined>(undefined);
  const wheelGlide = useRef<ReturnType<typeof installWheelGlide>>(undefined);
  /// Eases the followed view's steps with a streaming reply on the compositor (followGlide.ts).
  const followGlide = useRef<ReturnType<typeof createFollowGlide>>(undefined);
  followGlide.current ??= createFollowGlide();
  /// When the view last changed size: the passes that settle the rows after it never glide.
  const resizedAt = useRef(Number.NEGATIVE_INFINITY);
  // The last transcript box on this page until this one is measured (before its first paint, below).
  const [height, setHeight] = useState(() => lastTranscriptBox.height);
  // The native pane's width, distinct from the transcript scroller's width when Push always reserves
  // a Session Info column. The pane-pinned rail uses this so its inset never follows that column.
  const [paneWidth, setPaneWidth] = useState(() => lastTranscriptBox.width);
  /// The scrollbar's lane (scrollers.ts SHOWN_SCROLLER_ATTRIBUTE: always there, its thumb drawn while
  /// the chat overflows). The rows lay out across it, against the scroller's full width as the
  /// composer does, so the column matches the composer's and nothing reflows as a chat starts to scroll.
  const [lane, setLane] = useState(0);
  const ref = useRef<HTMLDivElement>(null);
  const stopJump = useCallback(() => {
    // Find, reveal and an asynchronous send own their new placement, even without a jump in flight.
    wheelGlide.current?.stop();
    followGlide.current?.stop();
    jumpTarget.current = undefined;
    // A footnote also owns the shared runner and must end on session/send/Find transitions.
    if (ref.current) stopScroll(ref.current);
  }, []);
  // The shared animation owns one RAF and its input listeners. Leaving this chat or unmounting
  // cancels that ride before the next session can reuse this scroller.
  useLayoutEffect(() => stopJump, [sessionId, stopJump]);
  /// The bottom stack's height over the view's foot: room under the last row, out of the view.
  const [dockSpace, setDockSpace] = useState(0);
  /// The bottom stack's reach at rest, for the prompt rail's box (`railBox`): its smallest at `height`.
  const restingDock = useRef<{ height: number; sessionId?: string; dock?: HTMLElement | null; space: number }>({
    height: -1,
    space: 0,
  });
  const dockSpaceRef = useRef(0);
  dockSpaceRef.current = dockSpace;
  /// The room the rows keep over a floating stack: its height, and the rest gap's share past the last
  /// row's own turn gap (model.ts `restRoom`), so the newest row rests the same gap over whatever the
  /// stack's top is. Read once per transcript; the masks, Jump to latest and the scroll-into-view
  /// clearance keep the stack's own height (`dockSpace`).
  const [restExtra] = useState(restRoom);
  const dockRoom = dockSpace > 0 ? dockSpace + restExtra : 0;
  const dockRoomRef = useRef(0);
  dockRoomRef.current = dockRoom;
  // Full stack height is distinct from the overlap room: a tall dock can extend beyond the
  // viewport, while an after-latest tray still needs the whole stack reserved in stage flow.
  const [dockHeight, setDockHeight] = useState(0);
  const dockHeightRef = useRef(0);
  dockHeightRef.current = dockHeight;
  /// The composer card's height, in that stack: what grows a line at a time (Shift-Return, a wrap).
  const [dockCard, setDockCard] = useState(0);
  const dockCardRef = useRef(0);
  dockCardRef.current = dockCard;
  /// The running tray's height, in that stack: what its header, View all and a command's live tail
  /// open and fold. What the reader opens or folds there the room under the last row takes only once
  /// the rows move anyway (`trayHold`).
  const [dockTray, setDockTray] = useState(0);
  const dockTrayRef = useRef(0);
  dockTrayRef.current = dockTray;
  /// The reader opened or folded something in the tray, and the room has not taken it yet.
  const trayToggled = useRef(false);
  /// The tray's height the room under the last row was last given (`trayHold` below), and the rows'
  /// own height as of the last pass, which tells a pass whose rows grew.
  const foldBase = useRef(0);
  const rowsSeen = useRef(0);
  /// A queued prompt left the bottom stack this frame: a sent one is about to come in as the latest
  /// row; a withdrawn one (deleted from the queue) never does.
  const queueLeft = useRef(false);
  const queuedIds = useRef(new Set<string>());
  /// The prompts whose cards left, which the room under the last row is kept for (`floor`).
  const heldFor = useRef(new Set<string>());
  const withdrawnSet = useMemo(() => new Set(queueWithdrawn), [queueWithdrawn]);
  const withdrawn = useRef(withdrawnSet);
  withdrawn.current = withdrawnSet;
  const dockRef = useRef(dock);
  dockRef.current = dock;
  const queueSession = useRef(sessionId);
  queueSession.current = sessionId;
  /// The chat and the stack `queuedIds` were noted in.
  const notedIn = useRef<{ sessionId?: string; dock?: HTMLElement | null }>({});
  /// Notes the stack's queued prompts; called first by each size observer (the stack's, and the
  /// view's, for a stack laid out under the transcript), so the render a size change makes knows,
  /// and by each change of the queue (below). A prompt the queue's fold hides (ComposerQueue
  /// `data-folded-ids`) is still queued: closing the fold is not its card leaving, and no room is
  /// kept under the last row for a prompt that stays queued (Leo 2026-10-21: the queue closed left a
  /// hole over the stack, then the rows dropped).
  const noteQueue = useCallback(() => {
    const dock = dockRef.current;
    const now = new Set([
      ...[...(dock?.querySelectorAll<HTMLElement>(".acpmux-queued") ?? [])].map((card) => card.dataset.promptId ?? ""),
      ...[...(dock?.querySelectorAll<HTMLElement>("[data-folded-ids]") ?? [])].flatMap((list) =>
        (list.dataset.foldedIds ?? "").split(" "),
      ),
      ...(queueIds ?? []),
    ]);
    // Another chat's queue, or another stack, starts over: the last one's prompts never left this
    // one, and no room is held for them (#24182: switched to a chat with its own queue, the last
    // chat's prompts read as cards that left, and a prompt withdrawn later kept room as a sent one).
    if (notedIn.current.sessionId !== queueSession.current || notedIn.current.dock !== dock) {
      notedIn.current = { sessionId: queueSession.current, dock };
      queuedIds.current = now;
      heldFor.current.clear();
      queueLeft.current = false;
      return;
    }
    const left = [...queuedIds.current].filter((id) => !now.has(id));
    queuedIds.current = now;
    if (!left.length) return;
    for (const id of left) heldFor.current.add(id);
    if (queueLeft.current) return;
    queueLeft.current = true;
    // Only the size change of this frame is the card leaving.
    requestAnimationFrame(() => requestAnimationFrame(() => (queueLeft.current = false)));
  }, [queueIds]);
  useLayoutEffect(() => {
    if (!dock) {
      setDockSpace(0);
      setDockHeight(0);
      setDockCard(0);
      setDockTray(0);
      return;
    }
    // Before the frame paints, as the viewport's own size is: a composer that grew a line, or a
    // queue that appeared, never draws a frame with the latest row under it. The room is how far
    // the stack reaches over the view: none for a stack in the flow under it, or with no box
    // (display: contents).
    const over = () => {
      const stack = dock.getBoundingClientRect();
      const view = ref.current?.getBoundingClientRect();
      return stack.height > 0 && view ? Math.max(0, Math.min(stack.height, view.bottom - stack.top)) : 0;
    };
    const height = () => Math.max(0, dock.getBoundingClientRect().height);
    // The composer card's height, while the stack reaches over the view.
    const card = (space: number) =>
      space > 0 ? (dock.querySelector(".acpmux-composer-box")?.getBoundingClientRect().height ?? 0) : 0;
    // The tray, at its drawn height while what it opens plays (useFold animates it); not the copy
    // of one that left (trayMotion.tsx), which fades over the stack and takes no room.
    const tray = (space: number) =>
      space > 0
        ? (dock.querySelector(`:scope > .acpmux-running-tray:not(.${TRAY_GHOST})`)?.getBoundingClientRect().height ?? 0)
        : 0;
    // A click on one of its disclosures (the header, View all, a command's line) is the reader's.
    // One that changes no height (or a tray that goes) holds nothing: the flag goes after two frames
    // unless the tray's height changed meanwhile.
    const toggled = (event: MouseEvent) => {
      const target = event.target instanceof Element ? event.target : null;
      const toggle = target?.closest("[aria-expanded]");
      if (!toggle || toggle.closest(".acpmux-running-tray")?.parentElement !== dock) return;
      trayToggled.current = true;
      const at = tray(1);
      requestAnimationFrame(() =>
        requestAnimationFrame(() => {
          if (Math.abs(tray(1) - at) < 0.5 && Math.abs(dockTrayRef.current - foldBase.current) < 0.5)
            trayToggled.current = false;
        }),
      );
    };
    dock.addEventListener("click", toggled, { capture: true });
    const observer = new ResizeObserver(() => {
      noteQueue();
      const next = over();
      const nextHeight = height();
      const nextCard = card(next);
      const nextTray = tray(next);
      // A tray that went holds nothing: the room is the stack's again.
      if (nextTray <= 0) trayToggled.current = false;
      if (
        Math.abs(next - dockSpaceRef.current) >= 0.5 ||
        Math.abs(nextHeight - dockHeightRef.current) >= 0.5 ||
        Math.abs(nextCard - dockCardRef.current) >= 0.5
      )
        flushSync(() => {
          setDockSpace(next);
          setDockHeight(nextHeight);
          setDockCard(nextCard);
          setDockTray(nextTray);
        });
    });
    observer.observe(dock);
    noteQueue();
    const space = over();
    const fullHeight = height();
    setDockSpace(space);
    setDockHeight(fullHeight);
    setDockCard(card(space));
    setDockTray(tray(space));
    return () => {
      observer.disconnect();
      dock.removeEventListener("click", toggled, { capture: true });
    };
  }, [dock, noteQueue]);
  // And each time the queue changes, in the commit that draws it. A change that leaves the stack's
  // size as it was (a prompt the fold hides, or one an opened list's cap cuts off, run by another
  // client) runs neither observer: still noted as queued, the next resize took it for a card that
  // left then, and kept room above the stack for FLOOR_HOLD_MS that then glided away (#24182).
  useLayoutEffect(() => noteQueue(), [sessionId, queueIds, noteQueue]);
  const [width, setWidth] = useState(() => lastTranscriptBox.width);
  // The column's cap (layout.json `chatWidth`): a new one measures every row again.
  const { width: chatWidth, scale: chatScale } = useChatSizing();
  // The user's chat look (font, sizes, width; chatDisplay.ts): a new one measures every row again.
  const chatLook = useChatDisplay();
  const measuredLook = useRef(chatLook);
  // Rows place by their drawn height once drawn, and by the estimate until then.
  const [drawn, setDrawn] = useState(new Map<string, DrawnHeight>());
  const pendingDrawn = useRef(new Map<string, DrawnHeight>());
  const measurementCache = useRef(new Map<string, import("./model").PreparedRow>());
  /// The last estimate, whose unchanged leading rows the next one keeps.
  const lastEstimate = useRef<
    { rows: readonly AcpmuxRow[]; layout: ConversationLayout; width: number; sessionId?: string } | undefined
  >(undefined);
  /// Estimated heights by row object, for the registry they were measured with.
  const rowHeights = useRef<{ registry: NativeRegistry; heights: RowHeights }>({
    registry,
    heights: new WeakMap(),
  });
  const measurementSession = useRef(sessionId);
  if (measurementSession.current !== sessionId) {
    // Row ids and versions are local to an acpmux session. A new session can reuse both, so
    // prepared markdown and DOM heights from the old transcript must never place the new one.
    measurementSession.current = sessionId;
    measurementCache.current.clear();
    rowHeights.current = { registry, heights: new WeakMap() };
    pendingDrawn.current.clear();
  }
  const drawnRef = useRef(drawn);
  drawnRef.current = drawn;
  const scaledRowWidth = transcriptRowWidth(width, chatColumnOf(chatWidth, chatLook, chatScale), endReserve);
  const rowWidthRef = useRef(scaledRowWidth);
  rowWidthRef.current = scaledRowWidth;
  const rowsRef = useRef(rows);
  rowsRef.current = rows;
  // Keyboard focus is a roving tab stop. A range is kept as stable row ids rather than DOM nodes
  // because the transcript virtualizes rows and can unmount either end while the reader moves.
  const [activeRowId, setActiveRowId] = useState(rows[0]?.id);
  const [transcriptRange, setTranscriptRange] = useState<TranscriptRange | undefined>();
  const activeRowRef = useRef(activeRowId);
  activeRowRef.current = activeRowId;
  const transcriptRangeRef = useRef(transcriptRange);
  transcriptRangeRef.current = transcriptRange;
  /// The end rows of a selection a drag from the margin makes (gutterSelect.ts): they stay mounted
  /// while it lasts, so the selection keeps its ends when the view scrolls them out (at most two).
  /// Each with how far from the last row it was, which older history paging in above it keeps.
  const [heldRows, setHeldRows] = useState<{ session: string; rows: (HeldRow & { fromEnd: number })[] } | undefined>();
  /// The chat a hold is for: a hold from another chat (sessions reuse row ids) mounts nothing.
  const heldSession = useRef("");
  /// Ends a margin drag and lets its held rows go (gutterSelect.ts `release`).
  const gutterRelease = useRef<(() => void) | undefined>(undefined);
  const pendingFocus = useRef<string | undefined>(undefined);
  const sessionKey = sessionId ?? "";
  heldSession.current = sessionKey;
  // Keep the key in state so a StrictMode render cannot consume the session transition before the
  // reset effect commits. The keyed values below make the first new-session paint fresh as well.
  const [selectionSessionKey, setSelectionSessionKey] = useState(sessionKey);
  const sessionChanged = selectionSessionKey !== sessionKey;
  /// A row can be newly arrived but outside the mounted virtual range. Pending entrances are
  /// page-scoped: hiding or switching chats must drop them before that row can mount later.
  const enteringRows = useRef(new Set<string>());
  useEffect(() => {
    if (sessionChanged) {
      setSelectionSessionKey(sessionKey);
      setActiveRowId(rows[0]?.id);
      setTranscriptRange(undefined);
      // A margin drag, or the selection it left, belongs to the chat it was made in.
      gutterRelease.current?.();
      setHeldRows(undefined);
      pendingFocus.current = undefined;
      enteringRows.current.clear();
      return;
    }
    const currentRange = transcriptRangeRef.current;
    const presence = rowPresence(rows, activeRowRef.current, currentRange?.anchorId, currentRange?.focusId);
    setActiveRowId((current) => (current && presence.active ? current : rows[0]?.id));
    setTranscriptRange((current) => {
      if (!current) return current;
      return presence.anchor && presence.focus ? current : undefined;
    });
  }, [rows, sessionChanged, sessionKey]);
  useEffect(() => {
    const clearHiddenEntrances = () => {
      if (document.visibilityState === "hidden") enteringRows.current.clear();
    };
    document.addEventListener("visibilitychange", clearHiddenEntrances);
    return () => document.removeEventListener("visibilitychange", clearHiddenEntrances);
  }, []);
  // Rows that arrive live (a reply, a tool call, a status line) enter once. The rows at the first
  // render, and many at once (a session switch, older history), are a load and do not.
  const knownRows = useRef<Set<string> | null>(null);
  /// A "Worked for" (or subagent group) the reader toggled, while its rows slide and fade
  /// (conversation/turnFold.ts), and the drawn copies of rows a close hid, while they fade out.
  const turnFold = useRef<TurnFold | undefined>(undefined);
  const foldGhosts = useRef(new Set<HTMLElement>());
  const knownFor = useRef<readonly AcpmuxRow[] | null>(null);
  /// Where this snapshot first differs from the last, found once below; the rail reads it instead
  /// of comparing the rows again (model.ts minimapTurns).
  const rowsChange = useRef<RowsChange | undefined>(undefined);
  /// The minimap's hook for this commit's settled offset (ThreadMinimap `placed`).
  const minimapPlaced = useRef<(() => void) | undefined>(undefined);
  const olderRows = useRef<OlderRowFade | undefined>(undefined);
  olderRows.current ??= new OlderRowFade(() => ref.current);
  // Row ids are local to a session: one still waiting to fade belongs to the chat that was shown.
  if (sessionChanged) olderRows.current.clear();
  // A switched chat starts over: its row ids are its own, and may repeat the last chat's.
  if (knownRows.current === null || sessionChanged) knownRows.current = new Set(rows.map((row) => row.id));
  // Scroll frames render the same rows: only a new row list can bring new rows.
  else if (knownFor.current !== rows) {
    // Rows before the first one that changed were all there last time.
    const previous = knownFor.current ?? [];
    let from = 0;
    while (from < rows.length && from < previous.length && rows[from] === previous[from]) from += 1;
    rowsChange.current = { base: previous, rows, from };
    // A page of older history lands above the first row that was already there (a date divider
    // moves up to the page's first turn, so the first known row, not the first row): those rows never
    // take a live row's entrance. They draw in place, as if they had always been there, unless the
    // page came late: the reader already reached the top of the loaded rows, and only then do they
    // fade in as they are first seen (Leo 2026-10-31: no fade unless it's the worst case).
    const oldFirst = rows.findIndex((row) => knownRows.current!.has(row.id));
    const arrived: AcpmuxRow[] = [];
    let olderLate: boolean | undefined;
    for (let index = from; index < rows.length; index += 1) {
      const row = rows[index]!;
      if (knownRows.current.has(row.id)) continue;
      if (index < oldFirst) {
        olderLate ??= readerAtLoadedTop(ref.current);
        if (olderLate) olderRows.current.add(row.id);
      } else arrived.push(row);
      knownRows.current.add(row.id);
    }
    // A row that arrived while the chat is hidden (another tab or workspace shows), or that lands
    // before its first frame back, came while the user was away: it draws in place. WebKit
    // suspends a hidden page's animations, so its entrance would play on return (shared/pageReveal.ts).
    // The rows a "Worked for" the reader opened reveals fade in with its fold (turnFold.ts) instead.
    if (arrived.length <= LIVE_ROWS_PER_UPDATE && entranceAllowed() && !turnFold.current?.opening)
      for (const row of arrived) enteringRows.current.add(row.id);
  }
  knownFor.current = rows;
  const onEntered = useCallback((id: string) => void enteringRows.current.delete(id), []);
  const onOlderShown = useCallback((id: string) => olderRows.current?.shown(id), []);
  useEffect(() => () => olderRows.current?.disconnect(), []);
  const reportDrawn = useCallback<ReportDrawn>(
    (id, version, drawnHeight, actions, status) => {
      // A row not laid out (hidden, or no layout at all) has no height yet; 0 is one (drawnHeightOf).
      if (drawnHeight !== undefined)
        pendingDrawn.current.set(id, {
          sessionId,
          version,
          width: rowWidthRef.current,
          height: drawnHeight,
          ...(actions ? { actions } : {}),
          ...(status ? { status } : {}),
        });
    },
    [sessionId],
  );
  // All of a commit's reports land in one update, before the frame paints.
  /// Rows whose drawn height changed since the last placement, which places again from the first.
  const changedDrawn = useRef(new Set<string>());
  /// The last placement, and the mounted range it was drawn with.
  const lastPlaced = useRef<
    | {
        rows: readonly AcpmuxRow[];
        drawn: Map<string, DrawnHeight>;
        layout: ConversationLayout;
        width: number;
        sessionId?: string;
        /// A new registry estimates every row again, so nothing is kept.
        registry: NativeRegistry;
        /// A new chat look (Minimal Mode included) estimates every row again too: nothing is kept.
        look: ReturnType<typeof useChatDisplay>;
        first: number;
        last: number;
        /// Rows mounted outside that range because a margin drag's selection holds them (at most two).
        held: readonly number[];
      }
    | undefined
  >(undefined);
  const flushDrawn = useCallback(() => {
    if (!pendingDrawn.current.size) return;
    const updates = pendingDrawn.current;
    pendingDrawn.current = new Map();
    for (const id of updates.keys()) changedDrawn.current.add(id);
    setDrawn((current) => {
      let next: Map<string, DrawnHeight> | undefined;
      for (const [id, entry] of updates) {
        if (sameDrawn(current.get(id), entry)) continue;
        next ??= new Map(current);
        next.set(id, entry);
      }
      return next ?? current;
    });
  }, []);
  const observer = useMemo(
    () =>
      typeof ResizeObserver === "undefined"
        ? undefined
        : new ResizeObserver((entries?: ResizeObserverEntry[]) => {
            const targets = (entries ?? []).map((entry) => entry.target as HTMLElement);
            const measure = () => {
              for (const target of targets) {
                const shown = rowsRef.current;
                const index = Number(target.getAttribute("aria-posinset")) - 1;
                const row = shown[index];
                // With the frame's own flag: a height reported without it is taken for a stale one.
                if (row && row.id === target.dataset.rowId)
                  reportDrawn(
                    row.id,
                    row.version,
                    drawnHeightOf(target),
                    keepsReplyRoom(row, nextDrawnRow(shown, index)),
                    statusEdge(row, nextDrawnRow(shown, index), prevDrawnRow(shown, index)),
                  );
              }
            };
            measure();
            // A late size change (a font loading) must not paint a frame of overlap first. Sizes
            // that did not change render nothing: a synchronous render here for nothing was the
            // "ResizeObserver loop completed with undelivered notifications" while streaming.
            // While the view follows the latest row the rows are placed before paint, and measured
            // again after each render until they hold: that render also commits a streaming reply's
            // next reveal step, which the observer (a target at the same depth once a frame) would
            // report a frame late. The observer fires only when a row's size changes (a streaming
            // reply: once a new line, not once a chunk). Batched (#24602), the render landed after
            // the paint whenever the main thread was busy: the frame drew the reply a line taller
            // over the live line under it, and the view a line short (agent-pane-stream-jitter's
            // settle, 23px on the CI runner). A reader scrolled up keeps the batch; a disclosure's
            // height animation is placed before paint too, or the rows below overlap its body.
            if (!changesDrawn(drawnRef.current, pendingDrawn.current)) pendingDrawn.current = new Map();
            else if (followingRef.current || targets.some(heightFoldInFlight) || foldHolding(foldAnchor.current)) {
              for (let pass = 0; pass < 3; pass += 1) {
                if (!changesDrawn(drawnRef.current, pendingDrawn.current)) {
                  pendingDrawn.current = new Map();
                  break;
                }
                acpmuxPerf.timed("flush.drawn", () => flushSync(flushDrawn));
                measure();
              }
            } else flushDrawn();
          }),
    [reportDrawn, flushDrawn],
  );
  useEffect(() => () => observer?.disconnect(), [observer]);
  // Forget rows that left the transcript (a session switch, older history unloaded).
  const previousRowList = useRef<readonly AcpmuxRow[] | undefined>(undefined);
  const previousTail = useRef<readonly AcpmuxRow[]>(NO_ROWS);
  useEffect(() => {
    const previous = previousRowList.current;
    previousRowList.current = rows;
    // The tail these rows end with, against the one the previous rows ended with (kept with them,
    // whatever happened since: another view's rows in between are not this tail).
    const tail = queuedTail ?? NO_ROWS;
    const lastTail = previousTail.current;
    previousTail.current = tail;
    // Rows that only grew below the ones there (a streaming turn) left none behind, also when the
    // running turn's line stays last under them (`below`, conversation/turns.ts).
    if (previous && previous.length <= rows.length) {
      // So do the waiting agent messages after it (conversation/queuedMessages.ts), the same tail
      // array while the queue holds: checked by identity, not row by row. A changed tail scans.
      const keptTail = lastTail === tail ? tail.length : 0;
      const before = previous.length - 1 - keptTail;
      const line =
        keptTail +
        (before >= 0 &&
        previous[before]!.below === true &&
        rows[rows.length - 1 - keptTail]?.id === previous[before]!.id
          ? 1
          : 0);
      // `rowsChange` already found the first changed object while this render was prepared. Reuse
      // that boundary instead of copying the unchanged prefix and walking it a second time for
      // every streamed snapshot. Only the changed suffix can have lost a row id.
      const change = rowsChange.current;
      const start = change?.base === previous && change.rows === rows ? change.from : 0;
      let sameIds = true;
      for (let index = Math.min(start, previous.length - line); index < previous.length - line; index += 1) {
        if (previous[index]!.id !== rows[index]?.id) {
          sameIds = false;
          break;
        }
      }
      if (sameIds) return;
    }
    const ids = new Set(rows.map((row) => row.id));
    const cache = measurementCache.current;
    for (const id of cache.keys()) if (!ids.has(id)) cache.delete(id);
    setDrawn((current) => {
      if ([...current.keys()].every((id) => ids.has(id))) return current;
      return new Map([...current].filter(([id]) => ids.has(id)));
    });
  }, [rows, queuedTail]);
  useLayoutEffect(flushDrawn);
  // Minimal Mode draws another agent's closed message as its line alone (IncomingMessageCard.tsx):
  // a toggle forgets those rows' drawn heights, so rows offscreen place by the new estimate instead of
  // their old card's height, and marks them changed so the placement starts from the first of them
  // (the toggle's own render places every row again: `look` above). One O(rows) pass, once per
  // Minimal Mode toggle, never per event or token; a mounted row reports its new height as usual.
  const drawnMinimal = useRef(chatLook.minimal);
  useLayoutEffect(() => {
    if (drawnMinimal.current === chatLook.minimal) return;
    drawnMinimal.current = chatLook.minimal;
    const incoming = new Set<string>();
    for (const row of rowsRef.current) if (row.incoming?.kind === "message") incoming.add(row.id);
    if (!incoming.size) return;
    for (const id of incoming) pendingDrawn.current.delete(id);
    setDrawn((current) => {
      let next: Map<string, DrawnHeight> | undefined;
      for (const id of incoming) {
        if (!current.has(id)) continue;
        next ??= new Map(current);
        next.delete(id);
        changedDrawn.current.add(id);
      }
      return next ?? current;
    });
  }, [chatLook.minimal]);
  const didOpenAtLatest = useRef(false);
  /// The open waits, unseen, while older pages bring back `openAt`'s row; expired, it opens at the latest.
  const [seeking, setSeeking] = useState(false);
  const [seekExpired, setSeekExpired] = useState(false);
  /// The sends this chat's view has taken in (`sends`): a new one puts the view at the latest message.
  const seenSends = useRef(sends);
  /// A prompt was sent before the chat opened (while it seeks `openAt`'s row, or while its tail still
  /// fits): it opens at the latest message, not at the reader's old place.
  const sentBeforeOpen = useRef(false);
  const seekTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  /// When the walk began, and the first row it had then: a new first row is a page landed.
  const seekStart = useRef<number | undefined>(undefined);
  const seekFirstRow = useRef<string | undefined>(undefined);
  const endSeek = () => {
    clearTimeout(seekTimer.current);
    seekTimer.current = undefined;
    seekStart.current = undefined;
    seekFirstRow.current = undefined;
  };
  useEffect(() => () => clearTimeout(seekTimer.current), []);
  // Under the opt-in fade (Debug Settings agentPane.debug.scrollerFade), the scrollbar fades in and
  // out with the scrolling marks (scrollers.ts).
  useEffect(() => (ref.current ? followShownScrollerFade(ref.current) : undefined), []);
  // Read aloud speaks one of this chat's answers: moving to another session (or closing the
  // transcript) stops it, so it neither talks over the next chat nor says Stop reading on return.
  useEffect(() => () => stopReadingAloud(), [sessionId]);
  // A cold open's rows fade in on the first frame that draws them, before that frame paints.
  const fadedOpen = useRef<number | undefined>(undefined);
  /// The chat switch motion's arm, read once per transcript (a changed arm applies on reload).
  const [switchArm] = useState(() => experimentArm(chatSwitchMotion));
  /// The fade running on this transcript. The transcript stays mounted across a switch, so a fade
  /// ends with the chat it was for: a cached chat opened mid-fade shows whole on its first frame,
  /// not under the last chat's fade, and a transcript that unmounts leaves none running.
  const openFade = useRef<Animation | undefined>(undefined);
  useLayoutEffect(
    () => () => {
      openFade.current?.cancel();
      openFade.current = undefined;
    },
    [sessionId],
  );
  // CHAT SWITCH MOTION (experiment chat-switch-motion, off by default): opening another chat plays
  // its rows, title and Session Info in as one movement, on the first frame the new chat's rows draw
  // (cached: the frame the switch lands; cold: when its rows arrive). Not the first chat a page shows,
  // and not an empty chat's first send. This effect only notes the switch (before the cold-open fade
  // below reads it); the play runs in the transcript's last layout effect, after the new chat's rows
  // are placed and scrolled (search "CHAT SWITCH PLAY"). The play's animations end on their own; the
  // next switch starts from where they are, and the transcript unmounting cancels them.
  const switchPlay = useRef<ChatSwitchPlay | undefined>(undefined);
  const switchFrom = useRef(sessionId);
  const switchPending = useRef(false);
  const hasRows = rows.length > 0;
  useLayoutEffect(() => {
    if (switchArm === "off" || switchFrom.current === sessionId) return;
    // A chat with no rows and none on the way (coldOpen undefined) is an empty chat: its first send
    // is not a switch.
    switchPending.current =
      switchFrom.current !== undefined && sessionId !== undefined && (hasRows || coldOpen !== undefined);
    switchFrom.current = sessionId;
  }, [sessionId, hasRows, coldOpen, switchArm]);
  useLayoutEffect(
    () => () => {
      switchPlay.current?.stop();
      switchPlay.current = undefined;
    },
    [],
  );
  useLayoutEffect(() => {
    if (coldOpen === undefined || rows.length === 0 || fadedOpen.current === coldOpen) return;
    fadedOpen.current = coldOpen;
    openFade.current?.cancel();
    // A switch under a chat switch motion (chatSwitch.ts) is drawn by its own play instead.
    openFade.current = switchPending.current ? undefined : fadeInOpenedChat(ref.current);
    onColdOpenShown?.(coldOpen);
  }, [coldOpen, rows.length, onColdOpenShown]);
  const previousSession = useRef(sessionId);
  // A layout effect: the first measure lands before the first paint, so a mounted transcript (a page
  // load, a new chat's first send, back from Harnesses) never draws a frame at a guessed size.
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    const measure = (resized: boolean) => {
      // A box not laid out yet (hidden, 0 high) keeps the last height rather than showing no rows.
      if (resized || node.clientHeight > 0) setHeight(node.clientHeight);
      // The column's width is the scroller's with its scrollbar's lane (`lane`). Measured as the
      // box past the content width, never below 0, so a box with no layout box (jsdom) keeps its
      // content width.
      const nextLane = Math.max(0, node.offsetWidth - node.clientWidth);
      setWidth(node.clientWidth + nextLane);
      setLane(nextLane);
      const shellWidth = node.closest<HTMLElement>(".acpmux-shell")?.clientWidth;
      setPaneWidth(shellWidth && shellWidth > 0 ? shellWidth : node.clientWidth + nextLane);
      if (node.clientHeight > 0) lastTranscriptBox.height = node.clientHeight;
      if (node.clientWidth > 0) lastTranscriptBox.width = node.clientWidth + nextLane;
    };
    // Before the frame paints: a resized pane (its tab strip showing or hiding) otherwise drew the
    // transcript at its old offset and caught up a frame later.
    const observer = new ResizeObserver(() => {
      noteQueue();
      flushSync(() => measure(true));
    });
    observer.observe(node);
    measure(false);
    return () => observer.disconnect();
  }, [noteQueue]);
  const previousLayout = useRef<ReturnType<typeof layoutConversation> | null>(null);
  const previousRows = useRef<readonly AcpmuxRow[]>(rows);
  const previousViewport = useRef({ height, width, dockSpace });
  /// The room kept under the last row (`room` below) as of the last placement pass.
  const heldRoom = useRef(dockRoom);
  /// The composer card's height the room under the last row was last made for (`grown` below).
  const cardRest = useRef(0);
  /// How far the rows were drawn up by the composer's growth (`lift` below) as of the last pass.
  const appliedLift = useRef(0);
  /// The composer's growth kept out of the room under the last row (`lifted` below) as of that pass.
  const liftedBefore = useRef(0);
  /// Before the offset is written where rows lay out (a row's place), not where a lift draws them:
  /// the view stops following, and the commit that follows (from an event or a layout effect,
  /// before the frame paints) drops the lift without moving the offset by it.
  const unlift = useCallback(() => {
    if (!appliedLift.current) return;
    appliedLift.current = 0;
    followRef.current(false);
  }, []);
  const [, roomTaken] = useReducer((count: number) => count + 1, 0);
  /// Gives the room under the last row the stack's height again, at once, before Jump to latest
  /// follows again (`room` below).
  const takeRoom = useCallback(() => {
    const held = Math.abs(foldBase.current - dockTrayRef.current) > 0.5;
    foldBase.current = dockTrayRef.current;
    trayToggled.current = false;
    if (!held && Math.abs(heldRoom.current - dockRoomRef.current) <= 0.5) return;
    heldRoom.current = dockRoomRef.current;
    flushSync(roomTaken);
  }, []);
  const thread = useRef<HTMLDivElement>(null);
  /// The footer of the turn the pointer is over (a turnSummary row's id).
  const pointedTurn = useRef<string | undefined>(undefined);
  /// Pointerover bubbles from every markdown descendant: moving between spans inside the same row
  /// does not scan for its turn's footer again.
  const pointedRow = useRef<string | undefined>(undefined);
  // The rows the cached footer was found in: a footer can appear, or stop being the last turn's,
  // while the pointer rests on the same row.
  const pointedRows = useRef<readonly AcpmuxRow[] | undefined>(undefined);
  const scrolledTo = useRef({ top: 0, atLatest: false });
  /// The disclosure line the reader just clicked, held where they clicked it while its fold plays
  /// (conversation/foldAnchor.ts).
  const foldAnchor = useRef<FoldAnchor | undefined>(undefined);
  // A bottom disclosure lays out once, then the whole thread slides to that layout. Its row
  // marker tells useFold to skip the competing height animation; away from the end nothing changes.
  type BottomStackFold = {
    toggle: HTMLElement;
    row: HTMLElement;
    beforeTop: number;
    delta: number;
    from: number;
    animation?: Animation;
    cleanupTimer?: ReturnType<typeof setTimeout>;
  };
  const bottomStackFold = useRef<BottomStackFold | undefined>(undefined);
  const stopBottomStackFold = useCallback(() => {
    const stack = bottomStackFold.current;
    if (!stack) return;
    bottomStackFold.current = undefined;
    foldAnchor.current = undefined;
    stack.row.removeAttribute("data-bottom-fold");
    clearTimeout(stack.cleanupTimer);
    if (stack.animation) {
      stack.animation.onfinish = null;
      stack.animation.oncancel = null;
      stack.animation.cancel();
    }
  }, []);
  useEffect(() => stopBottomStackFold, [stopBottomStackFold]);
  /// The content end a clicked disclosure keeps (foldAnchor.ts `foldRoomFor`): 0, or the view's end
  /// when the line was clicked. Closing a body at the transcript's end leaves that much room under
  /// the rows instead of letting the browser clamp the offset, which brought every row down by what
  /// closed (Leo, ask-a736047107: "WHEN I COLLAPSE IT JUMPS ME UP"). The room shrinks with the view's
  /// end as the reader scrolls up unless this was a bottom tool collapse. Bottom room stays until
  /// the rows grow into it again; a send or Jump to latest releases either kind.
  const [foldRoom, setFoldRoom] = useState(0);
  const foldRoomRef = useRef(0);
  foldRoomRef.current = foldRoom;
  /// A bottom collapse keeps the end created by its open body. Unlike the transient room used to
  /// hold a line clicked away from the end, this room remains while the reader scrolls up and back.
  /// It is released only when the rows grow into it, or an explicit latest/send transition drops it.
  const stickyFoldRoom = useRef<{ shrunk: boolean } | undefined>(undefined);
  /// The content's end without that room, as of the last render.
  const rowsEndRef = useRef(0);
  /// Shrinks the kept room to the view's end at `node`'s offset, and lets it go once nothing holds
  /// it (no fold in flight, the rows reach the view's end). O(1): a read of the offset and a compare.
  /// Lets the kept room go: a send or Jump to latest heads for the rows' own end. `now` commits it
  /// before the caller reads the layout (Jump to latest's target).
  const dropFoldRoom = useCallback((now = false) => {
    stickyFoldRoom.current = undefined;
    if (!foldRoomRef.current) return;
    foldRoomRef.current = 0;
    if (now) flushSync(() => setFoldRoom(0));
    else setFoldRoom(0);
  }, []);
  // Another chat starts with none (its first render already leaves it out, `keptEnd`).
  useLayoutEffect(() => dropFoldRoom(), [sessionId, dropFoldRoom]);
  const trimFoldRoom = useCallback((node: HTMLElement) => {
    const kept = foldRoomRef.current;
    if (!kept) return;
    // A tool body opened at the end gives the transcript a larger physical end. Keep that end when
    // its body closes, including through an upward scroll and a return to the latest row. The room
    // is still released once the rows themselves grow back to it.
    if (stickyFoldRoom.current) {
      // A wheel can release the clicked-line anchor before the collapse's first measurement.
      // Only growth after an observed shrink may consume this room.
      if (rowsEndRef.current < kept - 0.5) stickyFoldRoom.current.shrunk = true;
      if (stickyFoldRoom.current.shrunk && !foldHolding(foldAnchor.current) && rowsEndRef.current >= kept - 0.5) {
        stickyFoldRoom.current = undefined;
        foldRoomRef.current = 0;
        setFoldRoom(0);
      }
      return;
    }
    const holding = foldHolding(foldAnchor.current);
    // A view that follows the latest row again (the reader scrolled back to it) ends at the rows.
    if (followingRef.current && !holding) {
      foldRoomRef.current = 0;
      setFoldRoom(0);
      return;
    }
    const next = trimmedFoldRoom(
      kept,
      node.scrollTop + node.clientHeight,
      rowsEndRef.current,
      holding,
      node.clientHeight,
    );
    if (next === kept) return;
    foldRoomRef.current = next;
    setFoldRoom(next);
  }, []);
  /// Where the reader last saw it rest, measured in view; undefined until it is.
  const seenAnchor = useRef<ScrollAnchor | null | undefined>(undefined);
  /// When the reader last moved the transcript themselves (wheel, pointer, touch or key).
  const readerAt = useRef(Number.NEGATIVE_INFINITY);
  /// The last upward input has not yet been acknowledged by the native scroll event. A tiny real
  /// wheel at the old end must not be mistaken for the browser's clamp window during a layout correction.
  const readerUpPending = useRef(false);
  // Scroll frames re-render with the same rows; only rows, width or the registry
  // change an estimate.
  const estimated = useMemo(() => {
    const layoutStart = acpmuxPerf.enabled ? performance.now() : 0;
    // Keep the session in this memo's inputs: its cache is cleared synchronously above even
    // when a host reuses the same rows array for a newly selected chat.
    const cache = measurementSession.current === sessionId ? measurementCache.current : new Map();
    const lookChanged = measuredLook.current !== chatLook;
    measuredLook.current = chatLook;
    const fresh = rowHeights.current.registry !== registry || measurementSession.current !== sessionId || lookChanged;
    if (rowHeights.current.registry !== registry || lookChanged)
      rowHeights.current = { registry, heights: new WeakMap() };
    const rowWidth = scaledRowWidth;
    const last = lastEstimate.current;
    const layout = layoutConversation(
      rows,
      rowWidth,
      cache,
      (row, measureWidth) => registry[rowKind(row)]?.measure?.(row, measureWidth),
      measurementSession.current === sessionId ? rowHeights.current.heights : undefined,
      !fresh && last && last.width === rowWidth && last.sessionId === sessionId ? last : undefined,
      sessionId,
    );
    lastEstimate.current = { rows, layout, width: rowWidth, sessionId };
    return { layout, ms: acpmuxPerf.enabled ? performance.now() - layoutStart : 0 };
  }, [rows, registry, sessionId, chatLook, scaledRowWidth]);
  // A row that draws moves only the rows below it: place them again, measuring none.
  const measured = useMemo(() => {
    const layoutStart = acpmuxPerf.enabled ? performance.now() : 0;
    const rowWidth = scaledRowWidth;
    const last = lastPlaced.current;
    // The ids flushed into `drawn` since the last placement; kept until `drawn` itself changes.
    const drawnChanged = drawn !== last?.drawn;
    const changed = drawnChanged ? changedDrawn.current : new Set<string>();
    if (drawnChanged) changedDrawn.current = new Set();
    // Rows before the first that changed (by object, or by drawn height) keep their places. A
    // drawn height comes from a mounted row, so its index is looked for around the mounted range.
    let kept = 0;
    if (
      last &&
      last.width === rowWidth &&
      last.sessionId === sessionId &&
      last.registry === registry &&
      last.look === chatLook &&
      drawn.size > 0
    ) {
      const limit = Math.min(rows.length, last.rows.length);
      while (kept < limit && rows[kept] === last.rows[kept]) kept += 1;
      // A row after the kept ones can give the last kept reply its own action row (a steer or a
      // message after it): that reply is placed again, as layoutConversation estimates it again.
      let reply = kept - 1;
      while (reply >= 0 && rows[reply]!.incoming?.kind === "hidden") reply -= 1;
      if (
        reply >= 0 &&
        rows[reply]!.kind === "assistant" &&
        keepsReplyRoom(rows[reply]!, nextDrawnRow(rows, reply)) !==
          keepsReplyRoom(last.rows[reply]!, nextDrawnRow(last.rows, reply))
      )
        kept = reply;
      if (changed.size > 0) {
        let found = 0;
        const from = Math.max(0, last.first - DRAWN_SEARCH_ROWS);
        const to = Math.min(rows.length, last.last + DRAWN_SEARCH_ROWS);
        for (let index = from; index < to && found < changed.size; index += 1)
          if (changed.has(rows[index]!.id)) {
            kept = Math.min(kept, index);
            found += 1;
          }
        // A held row (a margin drag's selection end) is mounted far from that range: looked up itself.
        for (const index of last.held)
          if ((index < from || index >= to) && rows[index] && changed.has(rows[index]!.id)) {
            kept = Math.min(kept, index);
            found += 1;
          }
        if (found < changed.size) kept = 0;
      }
    }
    const layout =
      drawn.size === 0
        ? estimated.layout
        : placeRows(
            estimated.layout,
            // A row keeps its last drawn height until its new version is drawn: a streaming reply's
            // text appears after the version that holds it, so an estimate of the version ran ahead
            // of the drawn text, and its drawn height then pulled the view back a line or more at
            // every chunk (agent-pane-chat-column.test.ts under load). Growth comes from what is drawn.
            (index) => {
              const row = rows[index]!;
              const known = drawn.get(row.id);
              if (!known || known.sessionId !== sessionId || known.width !== rowWidth) return undefined;
              // A reply drawn before (or after) the row that gives it its own action row: its estimate
              // holds until it is drawn again (`hasReplyActions` reads only the next drawn row).
              const next = nextDrawnRow(rows, index);
              if (
                (row.kind === "assistant" && Boolean(known.actions) !== keepsReplyRoom(row, next)) ||
                known.status !== statusEdge(row, next, prevDrawnRow(rows, index))
              )
                return undefined;
              return known.height;
            },
            last && kept > 0 ? { layout: last.layout, kept } : undefined,
          );
    lastPlaced.current = {
      rows,
      drawn,
      layout,
      width: rowWidth,
      sessionId,
      registry,
      look: chatLook,
      first: last?.first ?? 0,
      last: last?.last ?? 0,
      held: last?.held ?? [],
    };
    return { layout, ms: acpmuxPerf.enabled ? performance.now() - layoutStart : 0 };
  }, [estimated, drawn, registry, rows, sessionId, chatLook, scaledRowWidth]);
  // The transcript's height is the rows' as drawn, under the thread's top padding: the rows' total
  // alone placed the latest row's bottom that far under the view.
  // The bottom stack's room follows the rows, so the latest row ends above it.
  // A followed view does not move down when a queued prompt's card leaves the stack: its offset stays,
  // and the room the card leaves stays under the last row for the prompt, which arrives as the latest
  // row a moment later. Dropping it moved the view down a card's height, and the prompt moved it back
  // up. That holds for a stack over the view's foot (its room shrinks) and under it (the view grows).
  // The room goes once rows grow into it, the reader leaves the latest row, the rows rewrap, or after
  // FLOOR_HOLD_MS (a prompt deleted from the queue never arrives), when the view moves down with it.
  const floor = useRef({ height: 0, width, sessionId });
  const [, releaseFloor] = useReducer((count: number) => count + 1, 0);
  const floorTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(floorTimer.current), []);
  // Kept for a prompt that was sent, or while the reply streams, which fills it. A prompt withdrawn
  // with nothing streaming brings nothing: the room goes now (the queue's update can come before
  // acpmux's `queue_removed`, which then lets it go).
  const keptFor = working || [...heldFor.current].some((id) => !withdrawn.current.has(id));
  const kept = following && keptFor && floor.current.width === width && floor.current.sessionId === sessionId;
  const box = previousViewport.current;
  const footDropped = height - dockSpace > box.height - box.dockSpace;
  // Held as the end the view would have with all the stack's room (the composer's growth not taken
  // out, `lifted` below): the content end the reader sees is that less the lift on screen.
  const floorHeight = !kept
    ? 0
    : queueLeft.current && footDropped && previousLayout.current
      ? Math.max(floor.current.height, previousLayout.current.totalHeight + liftedBefore.current - box.height + height)
      : floor.current.height;
  // The room under the last row is the stack's height while the view follows the latest row, so
  // the latest row ends above a composer that grows. Scrolled up, nothing under the stack is in view:
  // the room stays as it was, and a composer that grows or shrinks a line (Shift-Return, a wrap)
  // leaves the scroller's height, offset and scrollbar where they were (Leo 2026-10-20: a newline
  // made the transcript's scrollbar jump). Back at the latest row, the room is the stack's again.
  // Followed, the composer card's own growth since the view began following stays out of the room
  // too (`lifted` of it): the rows are drawn up by it instead (`lift`), so the latest row still ends
  // above the card while the scroller's height, offset and scrollbar stay as they were. The rest of
  // the stack (a queue, an ask) still makes room as before.
  const sessionSwitched = previousSession.current !== sessionId;
  const lifting =
    following && !sessionSwitched && didOpenAtLatest.current && dockSpace > 0 && dockCard > 0 && cardRest.current > 0;
  const grown = lifting ? Math.min(dockSpace, dockCard - cardRest.current) : 0;
  // The content's end with all the stack's height as room, as the view would hold it unlifted.
  // The last row's turn gap and the rest gap's share (`dockRoom`) make the rest gap over the
  // floating stack, which the room keeps however tall the stack grows. The old permanent TRANSCRIPT_RUNWAY (removed after #23094) kept an extra blank
  // band here; the pinned-bottom layout below already follows streaming growth before paint.
  // What the reader opens or folds in the running tray moves no row (Leo, 2026-11-01: "there's a
  // layout shift when i expand it"): what it opens lies over the transcript's foot, as a menu over
  // the composer would, and the room under the last row keeps what it was (`trayHold`, the tray's
  // change since the room last took it). The room takes it once the rows move anyway: the next pass
  // whose rows grow (a reply streaming on, a send) gives it all (what opened) or as far as they grew
  // (what folded, whose room the rows fill), and Jump to latest or the reader's wheel past the end
  // gives it at once (`takeRoom`, `giveTrayRoom`). A line that joins or leaves the tray, and the
  // tray coming or going, make room as before; scrolled up the room is held anyway.
  const rowsGrew = measured.layout.totalHeight - rowsSeen.current;
  const trayBase =
    sessionSwitched || !following || dockSpace <= 0 || !trayToggled.current
      ? dockTray
      : rowsGrew > 0.5
        ? dockTray - Math.min(0, dockTray - foldBase.current + rowsGrew)
        : foldBase.current;
  const trayHold = Math.min(dockSpace, dockTray - trayBase);
  const rowsAtDock = measured.layout.totalHeight + THREAD_TOP + dockRoom - trayHold;
  const atDock = Math.max(floorHeight, rowsAtDock);
  // A card that grew is drawn up by at most what the offset can take back: the view keeps more than
  // the follow deadband to scroll, so the reader's scroll up still leaves the latest row (and the
  // lift with it) in a transcript about a screen tall; the rest of the growth is room. While a room
  // held for a sent prompt (`floor`) reaches past the rows, it already covers the card: the lift on
  // screen stays as it is (shrinking it drew every row down by the queue card that left, and up
  // again as its prompt came), and growth meanwhile never adds to it. A card shorter than it was
  // draws the rows down within the room it left. The lift is the card's growth exactly, not rounded:
  // a composer line is fractional (22.75px at the chat font, #26523), and a rounded lift changed the
  // room under the rows by a fraction each line, which moved the content's rounded height and the
  // followed offset a pixel. The cap is whole pixels, as the offset.
  const floorHolds = floorHeight > rowsAtDock;
  const lifted =
    grown > 0
      ? Math.max(
          0,
          Math.min(
            grown,
            Math.round(atDock - height - FOLLOW_BOTTOM_DEADBAND_PX - 1),
            floorHolds ? liftedBefore.current : grown,
          ),
        )
      : grown;
  const room = sessionSwitched || following ? dockRoom - lifted - trayHold : heldRoom.current;
  const rowsHeight = measured.layout.totalHeight + THREAD_TOP + room;
  // The content's end without the room a collapse left (`foldRoom`), which it is released against.
  const rowsEnd = Math.max(floorHeight - lifted, rowsHeight);
  rowsEndRef.current = rowsEnd;
  // The held room less the lift, as the rows' end is: what the reader sees stays where it was drawn.
  // A collapse near the end keeps the content as tall as the view's end (`foldRoom`), so the offset
  // never clamps and the line the reader clicked stays on its pixel.
  const keptEnd = sessionSwitched ? 0 : foldRoom;
  const layout = useMemo(
    () => ({ ...measured.layout, totalHeight: Math.max(rowsEnd, keptEnd) }),
    [measured, rowsEnd, keptEnd],
  );
  // Where the rows draw against where they lay out: the followed offset of this layout against the
  // one the unlifted layout would hold. Negative draws them up, positive down.
  const lift = lifted ? Math.round(Math.max(0, layout.totalHeight - height) - Math.max(0, atDock - height)) : 0;
  const liftRef = useRef(lift);
  liftRef.current = lift;
  const reportedLayout = useRef<typeof measured | null>(null);
  const reportedEstimate = useRef<typeof estimated | null>(null);
  // The old scroll state remains in React until the transition layout effect runs. Render the
  // new session from the top once so its first paint cannot reuse the previous chat's mounted rows.
  const unplacedScroll = sessionSwitched ? { top: 0, delta: 0 } : scrollRef.current;
  const origin = !sessionSwitched && ref.current ? scrollOrigin(ref.current) : 0;
  // Select the rows at this commit's anchored position before React reconciles them. Correcting
  // scrollTop only in the placement effect unmounted visible rows and flashed new copies on prepend.
  // Reader intent is synchronous; React's following state may still lag the wheel by one frame.
  const projectedTop =
    !sessionSwitched && !followingRef.current && previousLayout.current && previousLayout.current !== layout
      ? preserveScrollAnchorTop({
          oldLayout: previousLayout.current,
          newLayout: layout,
          oldRows: previousRows.current,
          newRows: rows,
          liveTop: unplacedScroll.top - origin,
          anchorTop: unplacedScroll.top - origin,
        })
      : undefined;
  const placementDelta = projectedTop === undefined ? 0 : projectedTop - (unplacedScroll.top - origin);
  const renderScroll = projectedTop === undefined ? unplacedScroll : { ...unplacedScroll, top: projectedTop + origin };
  const renderFollowing = sessionSwitched || followingRef.current;
  // The content in view starts at the offset less `lift`: rows drawn up by it show content that much
  // further down.
  const shownTop = renderScroll.top - lift - origin;
  const ahead = scrollLeadRanges(
    layout,
    shownTop,
    renderScroll.delta,
    height,
    SCROLL_LEAD_STEPS,
    height * MAX_SCROLL_LEAD_VIEWPORTS,
  );
  // The run of mounted rows the reader sees.
  const view = visibleLayoutRange(layout, shownTop, height);
  const range = ahead.find((each) => each.first <= view.first && view.first < each.last) ?? view;
  // The rows a viewport either side of where the reader was also mount, in a deferred render
  // between frames: a scroll then finds the rows it brings in already drawn and measured instead
  // of building them in its own frame. A jump past them mounts only what it shows.
  const warmTop = useDeferredValue(unplacedScroll.top - origin) + placementDelta;
  const warm = visibleLayoutRange(layout, warmTop - height * WARM_VIEWPORTS, height * (1 + 2 * WARM_VIEWPORTS));
  const scrolledRanges = mergeRowRanges(warm.last < range.first || warm.first > range.last ? ahead : [...ahead, warm]);
  // A held row (gutterSelect.ts) is at its index, or as far from the end as it was when older history
  // pages in above it. At most two, so this reads two rows. Only when rows came in at both ends at once
  // is it looked for by id; the effect below then keeps where it was found (or drops a row that is
  // gone), so the next render reads it directly again.
  const held = heldRows?.session === sessionKey && !sessionChanged ? heldRows.rows : [];
  const heldAt = held.map(({ id, index, fromEnd }) =>
    rows[index]?.id === id
      ? index
      : rows[rows.length - fromEnd]?.id === id
        ? rows.length - fromEnd
        : rows.findIndex((row) => row.id === id),
  );
  const heldIndices = heldAt.filter((index) => index >= 0);
  // Where the moved rows were found, so the writeback runs again if rows move again before it commits.
  const heldMoved = held.some((each, at) => heldAt[at] !== each.index) ? `${rows.length}:${heldAt.join(",")}` : "";
  useEffect(() => {
    if (!heldMoved) return;
    setHeldRows(
      (current) =>
        current && {
          session: current.session,
          rows: current.rows.flatMap((each) => {
            const at = rowsRef.current.findIndex((row) => row.id === each.id);
            return at < 0 ? [] : [{ ...each, index: at, fromEnd: rowsRef.current.length - at }];
          }),
        },
    );
  }, [heldMoved]);
  // The row whose line a fold holds stays mounted while the hold lasts: a body that shrank under
  // the old offset (Show less on a long prompt) would otherwise drop the row, and the hold with it,
  // before the hold puts the line back (foldAnchor.ts).
  const foldAt = Number(foldAnchor.current?.toggle.closest(".acpmux-row")?.getAttribute("aria-posinset")) - 1;
  if (foldAt >= 0 && foldAt < rows.length && !heldIndices.includes(foldAt)) heldIndices.push(foldAt);
  const mountedRanges =
    heldIndices.length === 0
      ? scrolledRanges
      : mergeRowRanges([...scrolledRanges, ...heldIndices.map((index) => ({ first: index, last: index + 1 }))]);
  // Find highlights only need repainting when the query/target, row content, or mounted DOM
  // window changes. Keep this signature primitive so scroll and layout state updates that leave
  // the mounted rows alone do not walk every text node in the transcript again.
  const mountedRangeKey = mountedRanges.map(({ first, last }) => `${first}:${last}`).join(",");
  // The scrolled rows only: a held row far from the view would widen every drawn-height search
  // (`measured`) to the rows between them. The held rows are looked up by index instead.
  if (lastPlaced.current) {
    lastPlaced.current.first = scrolledRanges[0]?.first ?? 0;
    lastPlaced.current.last = scrolledRanges.at(-1)?.last ?? 0;
    lastPlaced.current.held = heldIndices;
  }
  // A session can reuse row ids. Until the reset effect commits, render the new session as a
  // fresh transcript so a stale focus or range never flashes on its first paint.
  const effectiveActiveRowId = sessionChanged ? rows[0]?.id : activeRowId;
  const effectiveTranscriptRange = sessionChanged ? undefined : transcriptRange;
  const selectedBounds = useMemo(() => {
    if (!effectiveTranscriptRange) return undefined;
    const anchor = rows.findIndex((row) => row.id === effectiveTranscriptRange.anchorId);
    const focus = rows.findIndex((row) => row.id === effectiveTranscriptRange.focusId);
    if (anchor < 0 || focus < 0) return undefined;
    return { first: Math.min(anchor, focus), last: Math.max(anchor, focus) };
  }, [rows, effectiveTranscriptRange]);
  const selectedRows = useMemo(() => {
    if (!selectedBounds) return new Set<number>();
    const selected = new Set<number>();
    for (let index = selectedBounds.first; index <= selectedBounds.last; index += 1) selected.add(index);
    return selected;
  }, [selectedBounds]);
  const selectedRowIds = useMemo(
    () => (selectedBounds ? rows.slice(selectedBounds.first, selectedBounds.last + 1).map((row) => row.id) : []),
    [rows, selectedBounds],
  );
  const focusRow = useCallback(
    (index: number) => {
      if (rows.length === 0) return;
      const nextIndex = Math.max(0, Math.min(rows.length - 1, index));
      const id = rows[nextIndex]!.id;
      setActiveRowId(id);
      pendingFocus.current = id;
      const node = ref.current;
      if (!node) return;
      const mounted = [...node.querySelectorAll<HTMLElement>(".acpmux-row")].find((row) => row.dataset.rowId === id);
      if (mounted) {
        mounted.focus();
        pendingFocus.current = undefined;
        return;
      }
      unlift();
      const top = layout.tops[nextIndex] ?? 0;
      const maximum = Math.max(0, layout.totalHeight - node.clientHeight);
      const nextTop = Math.max(0, Math.min(maximum, top));
      const physicalTop = physicalScrollTop(node, nextTop);
      const before = node.scrollTop;
      node.scrollTop = physicalTop;
      const delta = node.scrollTop - before;
      scrollPacer.current?.cancel();
      setScrollAt(node.scrollTop, delta || node.scrollTop - scrollRef.current.top);
    },
    [layout, rows, unlift],
  );
  useLayoutEffect(() => {
    const id = pendingFocus.current;
    if (!id) return;
    const node = ref.current;
    const target = [...(node?.querySelectorAll<HTMLElement>(".acpmux-row") ?? [])].find(
      (row) => row.dataset.rowId === id,
    );
    if (target) {
      target.focus();
      pendingFocus.current = undefined;
    }
  }, [range, effectiveActiveRowId]);
  const copyRows = useCallback(
    async (rowIds: string[]) => {
      const text = transcriptRangeText(rows, rowIds);
      if (text && !(await copyTextResult(text))) throw new Error("copy.failed");
    },
    [rows],
  );
  const rowKeyDown = useCallback(
    (index: number, event: React.KeyboardEvent<HTMLElement>) => {
      // Buttons and links own their keyboard behavior. A focused row itself owns only the
      // navigation and copy keys below, so selecting prose never toggles a disclosure by accident.
      if (event.target !== event.currentTarget) return;
      const move = event.key === "ArrowDown" ? 1 : event.key === "ArrowUp" ? -1 : 0;
      const jump = event.key === "Home" ? 0 : event.key === "End" ? rows.length - 1 : undefined;
      if (move || jump !== undefined) {
        event.preventDefault();
        const nextIndex = jump ?? index + move;
        const clamped = Math.max(0, Math.min(rows.length - 1, nextIndex));
        const nextId = rows[clamped]?.id;
        if (!nextId) return;
        setTranscriptRange((current) =>
          event.shiftKey ? { anchorId: current?.anchorId ?? rows[index]!.id, focusId: nextId } : undefined,
        );
        focusRow(clamped);
        return;
      }
      if (event.key === "Escape") {
        if (effectiveTranscriptRange) {
          event.preventDefault();
          setTranscriptRange(undefined);
        }
        return;
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "c") {
        const native = window.getSelection?.();
        if (native && !native.isCollapsed) return;
        event.preventDefault();
        const rowIds = selectedRowIds.length > 0 ? selectedRowIds : [rows[index]!.id];
        void copyRows(rowIds).catch(() => undefined);
      }
    },
    [copyRows, effectiveTranscriptRange, focusRow, rows, selectedRowIds],
  );
  const rowFocus = useCallback((id: string) => setActiveRowId(id), []);
  // Keep the keyboard callback stable across transcript snapshots.
  const rowKeyDownRef = useRef(rowKeyDown);
  rowKeyDownRef.current = rowKeyDown;
  const handleRowKeyDown = useCallback(
    (index: number, event: React.KeyboardEvent<HTMLElement>) => rowKeyDownRef.current(index, event),
    [],
  );
  // Avoid allocating a new slice on every scroll/follow commit. Long transcripts can dispatch
  // several state commits per frame while the reader is moving; the mounted range is already
  // bounded, so a direct scan keeps the check allocation-free.
  let activeVisible = false;
  if (effectiveActiveRowId) {
    for (let index = range.first; index < range.last; index += 1) {
      if (rows[index]?.id === effectiveActiveRowId) {
        activeVisible = true;
        break;
      }
    }
  }
  const tabStopId = activeVisible ? effectiveActiveRowId : rows[range.first]?.id;
  useLayoutEffect(() => {
    const spans = mountedRanges.map(({ first, last }): MountedSpan => [
      layout.tops[first],
      layout.tops[last - 1] + layout.heights[last - 1],
    ]);
    acpmuxPerf.mounted = spans;
    // A memo hit spent no time in geometry this render.
    const freshLayout = reportedLayout.current !== measured;
    reportedLayout.current = measured;
    const freshEstimate = reportedEstimate.current !== estimated;
    reportedEstimate.current = estimated;
    const layoutMs = (freshLayout ? measured.ms : 0) + (freshEstimate ? estimated.ms : 0);
    if (acpmuxPerf.enabled && freshLayout) acpmuxPerf.addLayout(layoutMs);
    if (acpmuxPerf.enabled && renderStart > 0) {
      const now = performance.now();
      acpmuxPerf.commit(now - renderStart, layoutMs, spans, now);
    }
  });
  useLayoutEffect(() => {
    const switched = previousSession.current !== sessionId;
    if (switched) {
      if (ref.current) clearScrollOrigin(ref.current);
      // A single VirtualTranscript is reused while the selected chat changes. Discard every
      // scroll anchor from the old session before the placement pass chooses the new session's
      // openAt position or latest row.
      readerUpPending.current = false;
      previousSession.current = sessionId;
      followDeferred.current = false;
      followRequest.current = undefined;
      wheelGlide.current?.stop();
      didOpenAtLatest.current = false;
      // Another chat's count (the subagent view takes none) is not a send in this one.
      seenSends.current = sends;
      sentBeforeOpen.current = false;
      endSeek();
      setSeeking(false);
      setSeekExpired(false);
      previousLayout.current = null;
      previousRows.current = rows;
      scrolledTo.current = { top: 0, atLatest: false };
      seenAnchor.current = undefined;
      scrollPacer.current?.cancel();
      stopJump();
      stopBottomStackFold();
      setScrollAt(0, 0);
      follow(true);
    }
    const old = switched ? null : previousLayout.current;
    const oldRows = previousRows.current;
    const node = ref.current;
    // The view stopped following with its rows drawn up by the composer's growth (`lift`): that
    // growth is room now (`heldRoom`), and the offset moves by it in this same frame, so nothing the
    // reader sees moves.
    if (old && node && !following && appliedLift.current) {
      node.scrollTop -= appliedLift.current;
      scrolledTo.current = {
        ...scrolledTo.current,
        top: scrolledTo.current.top - appliedLift.current,
      };
      // The rows mounted for this frame read the offset too, before its scroll event comes.
      const moved = node.scrollTop;
      scrollPacer.current?.cancel();
      setScrollAt(moved);
    }
    // A disclosure the reader clicked stays where they clicked it while what it opens lays out: this
    // pass neither follows the latest row nor keeps the top row, it puts the clicked line back.
    const stack = bottomStackFold.current;
    const bottomStacking = Boolean(old && node && stack && foldAnchor.current?.toggle === stack.toggle);
    const heldFrom = node?.scrollTop ?? 0;
    const folding = Boolean(!bottomStacking && old && node && foldAnchor.current && keepFold(foldAnchor.current, node));
    if (!folding && !bottomStacking) foldAnchor.current = undefined;
    if (folding && node && Math.abs(node.scrollTop - heldFrom) >= 0.5) {
      // The rows mounted for this frame read the held offset too, before its scroll event comes.
      const moved = node.scrollTop;
      scrollPacer.current?.cancel();
      setScrollAt(moved);
    }
    if (bottomStacking && node && stack) {
      // The body takes its final height before paint. Pin the scroller there, then play the
      // difference on the compositor. A late measure updates that same effect on its original clock,
      // never starts another animation or drives a per-frame layout/scroll loop.
      const latest = Math.max(0, layout.totalHeight - height);
      settleFollowBottom(node, latest);
      const delta = layoutScrollTop(node) - stack.beforeTop;
      const host = thread.current;
      if (host && Math.abs(delta - stack.delta) > 0.5) {
        if (stack.animation) {
          const effect = stack.animation.effect as KeyframeEffect;
          const progress = effect.getComputedTiming().progress;
          // The new layout moved the thread by -(delta - previousDelta). Add exactly that
          // displacement to its current transform without restarting the original animation clock.
          if (typeof progress === "number" && progress < 1) {
            stack.from += (delta - stack.delta) / (1 - progress);
            effect.setKeyframes([{ translate: `0 ${stack.from}px` }, { translate: "0 0" }]);
          }
        } else {
          stack.from = delta;
          const frames = [{ translate: `0 ${delta}px` }, { translate: "0 0" }];
          const duration = foldMs(host);
          if (duration > 0) {
            stack.animation = host.animate(frames, { duration, easing: foldMotion.easing(host) });
            stack.animation.onfinish = () => {
              if (bottomStackFold.current === stack) stopBottomStackFold();
            };
            stack.animation.oncancel = stack.animation.onfinish;
          } else stopBottomStackFold();
        }
        stack.delta = delta;
      }
      scrollPacer.current?.cancel();
      setScrollAt(node.scrollTop);
    } else if (folding && node) {
      // What opened pushed the latest row out of view, or what closed left room under it
      // (`foldRoom`): the view is the reader's now, not following, so a reply that streams on
      // grows below the view instead of being followed past blank room.
      if (
        followingRef.current &&
        (node.scrollTop < layout.totalHeight - height - FOLLOW_BOTTOM_DEADBAND_PX ||
          foldRoomRef.current > rowsEndRef.current + 0.5)
      )
        follow(false);
    } else if (old && node) {
      // Content that shrank under the viewport has already clamped the live offset to
      // the new end; the offset recorded before this commit is where the reader was.
      // A clamp lands exactly on the scroller's own end, which rounds the layout's
      // fractional height, so compare with that rather than allow for the rounding.
      // A viewport that grew clamps at the end the content had then: the room a queued prompt's
      // card leaves (`floor`) can make the content taller again in this same commit.
      const live = node.scrollTop;
      const previousOrigin = scrollOrigin(node);
      // The browser rounds the height it clamps to, so the old end allows a pixel either way.
      // The live extent may already have shrunk and clamped the offset before reconciliation.
      // Keep that boundary as well as the old total so the clamp never reads as upward input.
      const end = Math.min(node.scrollHeight, old.totalHeight) - height;
      const recentUp = readerUpPending.current && live < scrolledTo.current.top;
      const clamped = !recentUp && live < scrolledTo.current.top - 0.5 && live >= end - 1;
      // A reader's move can reach the live offset before its scroll event. Layout changes alone
      // never release or reacquire follow; the input window only identifies this event race.
      // A reader can already be parked before the next wheel/default write. The live offset is
      // still authoritative for that recent upward input; gating this on `following` reused the
      // stale acknowledged top and produced a one-frame jump when an unseen row remeasured.
      // When already parked, only an unacknowledged upward input may explain a live offset above
      // the stored one. A click or downward input refreshes readerAt too, but must not turn a
      // layout correction into a new reader move (the base reader intent rule).
      const inputAt = followingRef.current || readerUpPending.current ? readerAt.current : Number.NEGATIVE_INFINITY;
      const readerLeft =
        !clamped && performance.now() - inputAt <= READER_SCROLL_MS && scrolledTo.current.top - live > 0;
      if (readerLeft) follow(false);
      if (readerUpPending.current && readerLeft) readerUpPending.current = false;
      // A real wheel can move the live offset before its scroll event reaches React. Keep that
      // movement for this pass and mark the view away from the latest row; otherwise the stored
      // bottom offset would immediately snap the reader back. Once the event is acknowledged,
      // layout-only corrections use the stored offset because WebKit may already include a resize
      // adjustment in `live`.
      const top = scrollAnchorBase(live, scrolledTo.current.top, readerLeft);
      // Following is reader intent, not proximity. A token must not recapture a parked reader
      // just because the last recorded offset remains inside the bottom deadband.
      const atLatest = followingRef.current;
      // At the latest row also at offset 0: a new chat's first pass can overshoot on estimated
      // heights and settle back to fit, and its reply must still be followed once it overflows
      // (cx-ubd1y). Away from it, at the first row nothing above can move it.
      if (didOpenAtLatest.current && atLatest) {
        // At the latest row: stay there as rows settle to their drawn heights and as content grows,
        // in this pass, before the frame paints. Nothing glides: a glide held the new text below the
        // view's foot for its 180 ms at every streamed chunk, and on open it slid from a layout that
        // never painted (estimated heights) to the drawn one (Leo 2026-10-21: "IMMEDIATELY ... at the
        // bottom every single time").
        const latest = Math.max(0, layout.totalHeight - height);
        // Jump to latest's glide in flight heads for the new end instead of snapping there.
        const jumping = jumpTarget.current !== undefined;
        // The shared animation reads the moving end every frame on its original clock.
        // Retargeting a native smooth-scroll here restarted its easing at every measurement.
        if (jumping) jumpTarget.current = latest;
        followDeferred.current = !jumping && userScrollIntent(node).isHeld() && !followRequest.current?.();
        const settled = jumping ? clamped : (!followDeferred.current && settleFollowBottom(node, latest)) || clamped;
        if (settled) followTrace.set(latest);
        // The rise this pass took, eased on screen (followGlide.ts): the same rows, the reply's
        // new line landing in the room the live line keeps under it. Anything else (a row that came
        // or went, a resize, a fall) moves at once, as before.
        // In layout coordinates: the sub-pixel origin a settle keeps (scrollCoordinates.ts) moves the
        // rows on screen too, so a rise that only re-rounds the physical offset is no rise.
        const box = previousViewport.current;
        const rose = layoutScrollTop(node) - (scrolledTo.current.top - previousOrigin);
        const room = followRoom(rows, layout);
        // A resize (a window edge dragged, the dock growing) rewraps the rows, and they settle to
        // their drawn heights over the next passes at the same size: those are the resize too, not
        // growth, so nothing glides until the view has held its size for a motion step (cx-sqj3h).
        const now = performance.now();
        if (box.height !== height || box.width !== width || box.dockSpace !== dockSpace) {
          resizedAt.current = now;
          followGlide.current?.stop();
        }
        const resizing = now - resizedAt.current < MOTION_MS.standard;
        // A glide holding the rows back further than the room now under the last row (the live line
        // came into view to name a call) rests at once, so nothing stays under the bottom stack.
        followGlide.current?.fit(room);
        if (
          !jumping &&
          !bottomStacking &&
          !resizing &&
          rose > 0.5 &&
          rows.length === oldRows.length &&
          rows.at(-2)?.id === oldRows.at(-2)?.id
        )
          followGlide.current?.rise(thread.current, rose, room);
      } else if (top > 0 || rows[0]?.id !== oldRows[0]?.id) {
        // Keep the row at the top of the viewport where it is as rows above it change height.
        // Rows that arrived or left (a new reply segment below, older history above) move indexes,
        // so the row is found again by its id; at offset 0 too, when older history arrived above.
        // A row older history completed (a turn cut at the page's edge) has a new id: the next row
        // that kept its own anchors instead.
        const logicalTop = top - previousOrigin;
        const nextTop = preserveScrollAnchorTop({
          oldLayout: old,
          newLayout: layout,
          oldRows,
          newRows: rows,
          liveTop: logicalTop,
          anchorTop: logicalTop,
        });
        if (nextTop !== undefined && (clamped || nextTop !== logicalTop)) {
          writeAnchorScrollTop(node, nextTop);
          // Keep React's rendered offset in the same frame as the anchor correction. Otherwise a
          // rounded DOM offset arrives through scroll later and can briefly show Jump to latest.
          scrollPacer.current?.cancel();
          setScrollAt(node.scrollTop, 0);
        }
      }
    }
    // Runs on height too: rows that fit and then overflow on a height-only shrink keep the same memoized layout.
    if (!didOpenAtLatest.current && node) {
      const latest = Math.max(0, layout.totalHeight - height);
      // A chat reopened where the reader left it (cx-6bgzj), else at the latest message, as it is
      // once the reader sent a prompt into it.
      const at = openAt && !sentBeforeOpen.current ? rows.findIndex((row) => row.id === openAt.rowId) : -1;
      // That row is older than the pages loaded so far (a chat opens on its tail): page back to it
      // unseen, one older page after another: each page that lands changes `rows` and looks again
      // (cx-odzaz).
      if (openAt && at < 0 && canLoadOlder && onLoadOlder && !seekExpired) {
        const now = performance.now();
        seekStart.current ??= now;
        if (seekFirstRow.current !== rows[0]?.id || seekTimer.current === undefined) {
          seekFirstRow.current = rows[0]?.id;
          clearTimeout(seekTimer.current);
          const left = Math.min(OPEN_AT_PAGE_MS, OPEN_AT_SEEK_MS - (now - seekStart.current));
          seekTimer.current = setTimeout(() => setSeekExpired(true), Math.max(0, left));
        }
        setSeeking(true);
        onLoadOlder().catch(() => {});
      } else if (layout.totalHeight <= height) {
        // A tail that fits shows from the top, as before; it opens once it overflows.
        endSeek();
        setSeeking(false);
      } else {
        const top = at < 0 ? latest : Math.min(latest, layout.tops[at] + openAt!.offset);
        clearScrollOrigin(node);
        if (at < 0) node.scrollTop = top;
        else writeAnchorScrollTop(node, top);
        followTrace.set(node.scrollTop);
        scrollPacer.current?.cancel();
        setScrollAt(node.scrollTop, 0);
        follow(top >= latest - 1);
        didOpenAtLatest.current = true;
        endSeek();
        setSeeking(false);
      }
    }
    // The room a collapse kept follows the view's end, and goes once the rows reach it.
    if (node) trimFoldRoom(node);
    previousLayout.current = layout;
    previousRows.current = rows;
    previousViewport.current = { height, width, dockSpace };
    // With the composer's growth, which is room again once the view stops following.
    heldRoom.current = room + lifted;
    appliedLift.current = lift;
    liftedBefore.current = lifted;
    // A view that follows keeps the card height it began following at; any other takes the card's.
    if (!lifting) cardRest.current = dockCard;
    // The room a followed view keeps (`floor` above), until the rows fill it or it stops following.
    const holding = didOpenAtLatest.current && followingRef.current && floorHeight - lifted > rowsHeight;
    // Held for a sent prompt: once, for the prompt to arrive. Held only for a withdrawn one (the
    // reply was working): again at each pass, so it lasts while the reply grows and goes soon after.
    const forSent = [...heldFor.current].some((id) => !withdrawn.current.has(id));
    if (holding && (!floor.current.height || !forSent)) {
      clearTimeout(floorTimer.current);
      floorTimer.current = setTimeout(
        () => {
          floor.current = { ...floor.current, height: 0 };
          releaseFloor();
        },
        forSent ? FLOOR_HOLD_MS : WITHDRAWN_HOLD_MS,
      );
    } else if (!holding) clearTimeout(floorTimer.current);
    floor.current = { height: holding ? floorHeight : 0, width, sessionId };
    if (!holding && !queueLeft.current) heldFor.current.clear();
    if (node && node.clientHeight > 0 && height > 0 && didOpenAtLatest.current) {
      scrolledTo.current = { top: node.scrollTop, atLatest: followingRef.current };
      seenAnchor.current = restingAnchor(layoutScrollTop(node), scrolledTo.current.atLatest, layout, rows);
    }
    followTrace.update(node, layout.totalHeight, scrolledTo.current.atLatest);
    // The minimap's band reads the offset this pass settled on.
    minimapPlaced.current?.();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- openAt is read once, at the first open
  }, [
    layout,
    rows,
    range.first,
    height,
    width,
    dockSpace,
    room,
    lift,
    sessionId,
    seekExpired,
    canLoadOlder,
    followResume,
  ]);
  // What this pass gave the room of the tray's open list (`trayHold`), and the rows it measured.
  useLayoutEffect(() => {
    foldBase.current = trayBase;
    rowsSeen.current = measured.layout.totalHeight;
    if (Math.abs(trayHold) <= 0.5 && (rowsGrew > 0.5 || !following || sessionSwitched)) trayToggled.current = false;
  });
  // The reader's wheel down at the end, over a tray list opened on it: the room under the last row
  // takes the list now, below the view, and the wheel scrolls into it (the view follows again once
  // it is at the end), so the rows under the list are a scroll away, not a fold.
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const giveTrayRoom = (event: WheelEvent) => {
      if (event.deltaY <= 0 || !followingRef.current || dockTrayRef.current - foldBase.current <= 0.5) return;
      foldBase.current = dockTrayRef.current;
      trayToggled.current = false;
      heldRoom.current = dockRoomRef.current;
      flushSync(() => {
        followRef.current(false);
        roomTaken();
      });
    };
    node.addEventListener("wheel", giveTrayRoom, { passive: true });
    return () => node.removeEventListener("wheel", giveTrayRoom);
  }, []);
  // A toggled "Worked for" plays when its rows are placed again (watchTurnFold, started at the
  // toggle), not on every render. A render only checks, in O(1), whether the fold is over or another
  // chat shows, so nothing of it is left drawn over the new rows.
  useLayoutEffect(() => {
    const fold = turnFold.current;
    if (!fold || (performance.now() <= fold.until && fold.sessionId === sessionId)) return;
    settleTurnFold(thread.current, fold, foldGhosts.current);
    turnFold.current = undefined;
  });
  // Unmounted: the playing fold stops and lets go of its rows, and its copies go.
  useEffect(
    () => () => {
      settleTurnFold(thread.current, turnFold.current, foldGhosts.current);
      turnFold.current = undefined;
      for (const ghost of foldGhosts.current) ghost.remove();
      foldGhosts.current.clear();
    },
    [],
  );
  // Read at the click, so the callback stays the same across snapshots (rows compare it).
  const foldInputs = useRef({ layout, expanded, sessionId });
  foldInputs.current = { layout, expanded, sessionId };
  /// The reader's toggle of a row that opens or closes other rows ("Worked for", a subagent group):
  /// its motion starts from the rows as they are drawn now (turnFold.ts), then the pane toggles it.
  const toggleRow = useCallback(
    (id: string) => {
      const node = ref.current;
      const shown = rowsRef.current;
      const host = thread.current;
      settleTurnFold(host, turnFold.current, foldGhosts.current);
      const fold =
        node && !bottomStackFold.current
          ? startTurnFold(
              host,
              id,
              !(shown.find((row) => row.id === id)?.foldOpen ?? foldInputs.current.expanded.has(id)),
              {
                count: shown.length,
                idAt: (index) => shown[index]?.id,
                tops: foldInputs.current.layout.tops,
              },
              foldInputs.current.sessionId,
            )
          : undefined;
      turnFold.current = fold;
      // The rows as placed by the latest render, read when a pass runs.
      const read = () => {
        const placed = rowsRef.current;
        const { layout, sessionId } = foldInputs.current;
        return {
          placed: {
            count: placed.length,
            idAt: (index: number) => placed[index]?.id,
            tops: layout.tops,
          },
          sessionId,
        };
      };
      if (fold && host)
        watchTurnFold(fold, host, read, foldGhosts.current, () => {
          if (turnFold.current === fold) turnFold.current = undefined;
        });
      onToggleActivity(id);
    },
    [onToggleActivity],
  );
  // Commit before this frame paints; deferring to the next animation frame left the edge blank.
  // The page picks adaptive rendering; the host supplies the display interval and applies it.
  const renderRate = useMemo(() => new AdaptiveRenderRate(), []);
  const pacing = useMemo(
    // Read only (a guest), the owner's host takes no pacing reports.
    () =>
      new ScrollPacing((intervals) => {
        if (!readOnly) void reportScrollPacing(intervals, callNative, renderRate);
      }),
    [renderRate, readOnly],
  );
  useEffect(() => () => pacing.stop(), [pacing]);
  // Find in Chat: a new current match scrolls its row in (it may not be mounted), then, once its
  // text is drawn, the match itself; every commit repaints the highlights over the mounted rows.
  const findQuery = find?.open ? find.query : "";
  const findTarget = find?.matches[find.active];
  const findTargetRowId = findTarget?.rowId;
  const findTargetOccurrence = findTarget?.occurrence;
  // Find matches the chat's rows; the transcript draws a match's row (or its copy in an open fold)
  // once its fold is open.
  const findIndex = findTargetRowId !== undefined ? findRowIndex(rows, findTargetRowId) : -1;
  const drawnId = rows[findIndex]?.id;
  const drawnCard = Boolean(rows[findIndex]?.ended);
  // Pending and delivered notice batches retain the matched member for disclosure and highlighting.
  const matchRowId = findMemberRowId(rows[findIndex], findTargetRowId);
  const inGroup = matchRowId !== undefined;
  const paintedId = matchRowId ?? drawnId;
  const revealing = useRef<string | undefined>(undefined);
  const targetKey =
    findTargetRowId !== undefined && findTargetOccurrence !== undefined && findQuery && drawnId !== undefined
      ? `${paintedId}:${drawnId}:${drawnCard}:${findTargetOccurrence}:${findQuery}`
      : undefined;
  // A group or call that opens to show the match asks for a render here, so the highlights and
  // the scroll below see its text.
  const [revealed, setRevealed] = useState(0);
  // Keyed on what it names, not the match object, which is new on each update while Find is open:
  // a new value would open again every group a reader closed.
  const findReveal = useMemo(
    () =>
      drawnId !== undefined && findQuery
        ? {
            rowId: drawnId,
            card: drawnCard,
            needle: foldFind(findQuery),
            repaint: () => setRevealed((count) => count + 1),
            ...(matchRowId !== undefined ? { matchRowId } : {}),
          }
        : undefined,
    [drawnId, drawnCard, findQuery, matchRowId],
  );
  // Find chooses the reader's new place. Discard the previous scroll owners synchronously;
  // closing Find, a query edit or a measurement must never put that old place back.
  const findMoved = useCallback(
    (node: HTMLDivElement) => {
      stopJump();
      stopScroll(node);
      stopBottomStackFold();
      foldAnchor.current = undefined;
      scrollPacer.current?.cancel();
      const top = node.scrollTop;
      const { layout: placed, rows: shown } = latestLayout.current;
      // A selected Find match is an explicit opening place, even when the initial transcript fit
      // the viewport. Complete that handoff now so the first later overflow preserves this place
      // instead of running the unopened-chat path to the latest row.
      if (!didOpenAtLatest.current) {
        didOpenAtLatest.current = true;
        endSeek();
        setSeeking(false);
      }
      scrolledTo.current = { top, atLatest: false };
      seenAnchor.current = restingAnchor(top, false, placed, shown);
      scrollRef.current = { top, delta: top - scrollRef.current.top };
      setScroll(scrollRef.current);
      followRef.current(false);
      if (onAnchorRef.current) {
        clearTimeout(anchorTimer.current);
        anchorTimer.current = setTimeout(() => reportAnchorRef.current(), SCROLL_ANCHOR_SETTLE_MS);
      }
    },
    [stopBottomStackFold, stopJump],
  );
  // The current match's reveal window: 0 until it starts, then the window's own number.
  const revealWindow = useRef(0);
  const revealWindows = useRef(0);
  const findRequest = useRef<(() => boolean) | undefined>(undefined);
  const findFrame = useRef<number | undefined>(undefined);
  useLayoutEffect(() => {
    findRequest.current = ref.current ? userScrollIntent(ref.current).request() : undefined;
  }, [findTargetRowId, findTargetOccurrence, findQuery]);
  useLayoutEffect(() => {
    revealing.current = targetKey;
    revealWindow.current = 0;
    const node = ref.current;
    if (!node || !findTarget || !targetKey || !findRequest.current?.()) return;
    const top = layout.tops[findIndex];
    const bottom = top + layout.heights[findIndex];
    // In view where it draws (`lift` from its place while the rows follow a grown composer).
    const drawn = layoutScrollTop(node) - liftRef.current;
    if (top >= drawn && bottom <= drawn + node.clientHeight - dockSpaceRef.current) {
      findMoved(node);
      return;
    }
    unlift();
    node.scrollTop = physicalScrollTop(node, Math.max(0, top - node.clientHeight / 3));
    findMoved(node);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only a new target scrolls, not a layout change
  }, [targetKey]);
  // A row the running line's count names scrolls in once the transcript draws it (its fold may
  // open first), as a Find match does.
  const revealIndex = reveal ? findRowIndex(rows, reveal.rowId) : -1;
  const countReveal = useMemo(
    () =>
      reveal && revealIndex >= 0
        ? {
            rowId: rows[revealIndex]!.id,
            card: false,
            needle: "",
            toolId: reveal.toolId,
            repaint: () => {},
          }
        : undefined,
    // eslint-disable-next-line react-hooks/exhaustive-deps -- one reveal per key, once its row is drawn
    [reveal?.key, revealIndex >= 0],
  );
  const rowRequest = useRef<(() => boolean) | undefined>(undefined);
  useLayoutEffect(() => {
    rowRequest.current = ref.current ? userScrollIntent(ref.current).request() : undefined;
  }, [reveal?.key]);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || revealIndex < 0 || !rowRequest.current?.()) return;
    const top = layout.tops[revealIndex];
    const bottom = top + layout.heights[revealIndex];
    // In view where it draws (`lift` from its place while the rows follow a grown composer).
    const drawn = layoutScrollTop(node) - liftRef.current;
    if (top >= drawn && bottom <= drawn + node.clientHeight - dockSpaceRef.current) return;
    unlift();
    // The reader asked for this row: the view stops following the reply, or the run opening below
    // would pull it back to the latest line.
    const next = Math.max(0, top - node.clientHeight / 3);
    stopJump();
    node.scrollTop = physicalScrollTop(node, next);
    scrolledTo.current = { top: node.scrollTop, atLatest: false };
    follow(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only a new reveal scrolls, not a layout change
  }, [reveal?.key, revealIndex >= 0]);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    if (!findQuery) return clearFindHighlights();
    const current = paintFindHighlights(
      node,
      findQuery,
      findTargetRowId !== undefined && findTargetOccurrence !== undefined && drawnId !== undefined
        ? { rowId: paintedId!, card: inGroup ? false : drawnCard, occurrence: findTargetOccurrence }
        : undefined,
    );
    if (!current || revealing.current !== targetKey || !findRequest.current?.()) return;
    // A match in a closed group is drawn before the group opens (with no size), and it moves as the
    // opened parts and the rows above it measure, so it is kept in view for a moment once drawn.
    if (!revealWindow.current) {
      const opened = (revealWindow.current = ++revealWindows.current);
      const start = performance.now();
      let frames = 0;
      let still = 0;
      let placed: number | undefined;
      const tick = () => {
        if (revealWindow.current !== opened) return;
        // The reader's own scroll, click or key ends the hold: the match is theirs to leave.
        if (!findRequest.current?.()) {
          revealing.current = undefined;
          return;
        }
        // Where the match sits in the transcript's content: it moves while what is above it measures,
        // and a move with no render (a block that grew) is brought back here, not only on a commit.
        const range = findActiveRange();
        if (range && range.getBoundingClientRect().height > 0) {
          scrollRangeInBoxes(node, range);
          const before = node.scrollTop;
          scrollRangeIn(node, range, dockSpaceRef.current);
          if (node.scrollTop !== before) findMoved(node);
        }
        const at = findMatchOffset(node);
        still = at !== undefined && placed !== undefined && Math.abs(at - placed) < 0.5 ? still + 1 : 0;
        placed = at;
        const elapsed = performance.now() - start;
        const settled = frames >= FIND_REVEAL_FRAMES && elapsed >= FIND_REVEAL_MS && still >= FIND_REVEAL_STILL_FRAMES;
        if (settled || ++frames >= FIND_REVEAL_MAX_FRAMES) revealing.current = undefined;
        else findFrame.current = requestAnimationFrame(tick);
      };
      findFrame.current = requestAnimationFrame(tick);
    }
    if (current.getBoundingClientRect().height === 0) return;
    // Inner scrollers first (a command's output scrolls on its own), then the transcript.
    scrollRangeInBoxes(node, current);
    const before = node.scrollTop;
    scrollRangeIn(node, current, dockSpaceRef.current);
    if (node.scrollTop !== before) findMoved(node);
    // Rows are immutable snapshots, so their identity changes when streamed text or a revealed
    // fold changes. The mounted-range signature catches virtualization entering/leaving rows.
  }, [
    drawnCard,
    drawnId,
    findQuery,
    findTargetOccurrence,
    findMoved,
    findTargetRowId,
    inGroup,
    mountedRangeKey,
    paintedId,
    revealed,
    rows,
    targetKey,
  ]);
  useEffect(() => clearFindHighlights, []);
  // Where the view rests, once a scroll settles; the latest message is null.
  const reportedAnchor = useRef<string | undefined>(undefined);
  const anchorTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const latestLayout = useRef({ layout, rows });
  latestLayout.current = { layout, rows };
  useEffect(() => () => clearTimeout(anchorTimer.current), []);
  // A report that came due while the pane was hidden, sent once it has a viewport again.
  const anchorDeferred = useRef(false);
  useEffect(() => {
    clearTimeout(anchorTimer.current);
    anchorTimer.current = undefined;
    anchorDeferred.current = false;
    reportedAnchor.current = undefined;
  }, [sessionId]);
  const onAnchorRef = useRef(onAnchor);
  onAnchorRef.current = onAnchor;
  // WEB-SWAP: the transcript reopens at the place it reported (`chat.scrollAnchor`), so a web
  // update's reload waits only for a report still due (pages/shared/webSwap.ts). A hidden pane
  // reports where the reader last saw it (below), so it never holds the swap.
  useEffect(
    () =>
      holdWebSwap(() => (onAnchorRef.current && anchorTimer.current !== undefined ? "transcript.place-unsaved" : null)),
    [],
  );
  const reportAnchor = () => {
    anchorTimer.current = undefined;
    const node = ref.current;
    // Before the chat opens its offset is not the reader's: the kept place stays.
    if (!node || !onAnchor || !didOpenAtLatest.current) return;
    // A hidden pane (Home shown in its place) has no viewport: nothing it reads is where the reader is.
    anchorDeferred.current = node.clientHeight === 0;
    // Meanwhile it keeps where the reader last saw it (as `pane.wakeState` does); the report comes
    // again once it shows.
    if (anchorDeferred.current && seenAnchor.current === undefined) return;
    const { layout: placed, rows: shown } = latestLayout.current;
    const logicalTop = layoutScrollTop(node);
    const index = visibleLayoutRange(placed, logicalTop, 0, 0).first;
    const row = shown[index];
    const anchor: ScrollAnchor | null = anchorDeferred.current
      ? (seenAnchor.current ?? null)
      : scrolledTo.current.atLatest || !row
        ? null
        : { rowId: row.id, offset: logicalTop - placed.tops[index] };
    const key = JSON.stringify(anchor);
    if (key === reportedAnchor.current) return;
    reportedAnchor.current = key;
    onAnchor(anchor);
  };
  // Find's stable callback reports through the latest sink, even if it appeared after mount.
  const reportAnchorRef = useRef(reportAnchor);
  reportAnchorRef.current = reportAnchor;
  useEffect(() => {
    if (height > 0 && anchorDeferred.current) reportAnchor();
  });
  // A page about to let go (pane.wakeState) is hidden: it has no viewport, so its place is where
  // the reader last saw it.
  useEffect(() => {
    if (!anchorNow) return;
    anchorNow.current = () => seenAnchor.current;
    return () => {
      anchorNow.current = undefined;
    };
  }, [anchorNow]);
  // The reader sent a prompt: the view goes to the latest message before the frame paints, even
  // scrolled up, and follows the prompt's row and its reply in (Leo 2026-10-21). Only a scroll up
  // by the reader lets go of it again.
  useLayoutEffect(() => {
    if (sends === seenSends.current) return;
    seenSends.current = sends;
    const node = ref.current;
    if (!node) return;
    if (!didOpenAtLatest.current) {
      // The chat has not opened yet: it stops paging back to the reader's old place and opens at
      // the latest message (the placement pass, which `seekExpired` runs again).
      sentBeforeOpen.current = true;
      setSeekExpired(true);
      return;
    }
    revealing.current = undefined;
    revealWindow.current = 0;
    stopBottomStackFold();
    foldAnchor.current = undefined;
    dropFoldRoom();
    stopJump();
    // The room the stack grew while scrolled up is room under the last row again (`room`).
    heldRoom.current = dockRoomRef.current;
    // The placement pass already has the latest estimated total and measured viewport. Reusing
    // those values avoids forcing a style/layout flush from the send effect before the new row
    // paints; the following placement pass reconciles any drawn-height correction. A fractional
    // end is rounded up, as settleFollowBottom does, so WebKit's floor never rests a pixel short.
    clearScrollOrigin(node);
    node.scrollTop = Math.max(0, Math.ceil(layout.totalHeight - height - 0.01));
    const top = node.scrollTop;
    scrolledTo.current = { top, atLatest: true };
    seenAnchor.current = null;
    followTrace.set(top);
    scrollPacer.current?.cancel();
    setScrollAt(top);
    // The commit this asks for places the rows with the stack's room and settles at that end, even
    // inside the hold that follows the reader's last input.
    followRequest.current = userScrollIntent(node).request();
    follow(true);
    // The kept place is the latest message again: a relaunch opens there.
    if (onAnchor) {
      clearTimeout(anchorTimer.current);
      anchorTimer.current = setTimeout(reportAnchor, SCROLL_ANCHOR_SETTLE_MS);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only a new send moves the view
  }, [sends]);
  /// The older-history check (below), which every scroll event runs too.
  const checkOlderNow = useRef<() => void>(() => {});
  const onScroll = (event: React.UIEvent<HTMLDivElement>) => {
    pacing.scrolled();
    // Before the chat opens its offset moves only as pages land unseen: none of it is the reader's.
    if (!didOpenAtLatest.current) return;
    // A hidden scroller has no height, so every offset would read as scrolled up (cx-t0zqt): the view
    // keeps following until the reader scrolls a visible one.
    if (event.currentTarget.clientHeight === 0) return;
    checkOlderNow.current();
    const node = event.currentTarget;
    const next = node.scrollTop;
    trimFoldRoom(node);
    // A step of Jump to latest's glide: the view is following on its way to the end, not snapped
    // there (a first step inside the deadband read as layout work), and not stopped (a longer one
    // read as the reader's scroll up).
    if (jumpTarget.current !== undefined) {
      scrolledTo.current = { top: next, atLatest: true };
      seenAnchor.current = null;
      followTrace.set(next);
      queueScroll(next, true);
      // The kept place is the latest message again (a reopened chat opens there, not where the
      // reader was before the jump).
      if (onAnchor) {
        clearTimeout(anchorTimer.current);
        anchorTimer.current = setTimeout(reportAnchor, SCROLL_ANCHOR_SETTLE_MS);
      }
      return;
    }
    const programmatic = !userScrollIntent(node).isHeld();
    // The right-hand card holds what it shows until the reader's scroll settles
    // (summary/heldWhileScrolling.ts): older history paged in under the scroll lands there once.
    if (!programmatic) noteReaderScroll();
    // ResizeObserver/layout work can emit a scroll event after the stack below the transcript
    // changes. While the reader is following, keep the viewport at the new end and do not let
    // that synthetic event clear the follow state. A real wheel/touch/key event marks itself first.
    // A layout-driven scroll keeps the previous offset; a reader scroll changes it. The latter is
    // also what the jsdom behavior tests dispatch without a wheel event, so do not classify every
    // programmatic-looking event as layout work.
    // A held disclosure (foldAnchor) keeps the view where it is, not at the latest row.
    const layoutDriven =
      followingRef.current &&
      programmatic &&
      !foldAnchor.current &&
      Math.abs(next - scrolledTo.current.top) <= FOLLOW_BOTTOM_DEADBAND_PX;
    if (layoutDriven) {
      const latest = Math.max(0, layout.totalHeight - node.clientHeight);
      settleFollowBottom(node, latest);
      const resting = node.scrollTop;
      scrolledTo.current = { top: resting, atLatest: true };
      followTrace.set(resting);
      queueScroll(resting, true);
      return;
    }
    const was = scrolledTo.current;
    if (readerUpPending.current) readerUpPending.current = false;
    const measured = scrollPosition(node, layout.totalHeight);
    // A recent upward input is authoritative even when it moved only a pixel or two. The
    // deadband absorbs layout rounding, but must not turn a real trackpad step into bottom follow.
    const movedUp = next < was.top - 0.5;
    const recentUp = !programmatic && movedUp;
    const readerReachedBottom = !programmatic && next > was.top + 0.5 && measured.atLatest;
    scrolledTo.current = {
      top: next,
      atLatest: recentUp || (movedUp && !measured.atLatest) ? false : followingRef.current || readerReachedBottom,
    };
    const latest = Math.max(0, layout.totalHeight - node.clientHeight);
    if (was.atLatest && !scrolledTo.current.atLatest)
      followTrace.stopped({
        top: next,
        previous: was.top,
        latest,
        scrollHeight: node.scrollHeight,
        clientHeight: node.clientHeight,
      });
    followTrace.update(node, layout.totalHeight, scrolledTo.current.atLatest);
    seenAnchor.current = restingAnchor(layoutScrollTop(node), scrolledTo.current.atLatest, layout, rows);
    queueScroll(next, scrolledTo.current.atLatest);
    if (onAnchor) {
      clearTimeout(anchorTimer.current);
      anchorTimer.current = setTimeout(reportAnchor, SCROLL_ANCHOR_SETTLE_MS);
    }
  };
  // Jump to latest (the button, ChatGPT and Codex style): a smooth scroll to the latest message, then a
  // landing on it, so a reply that grew meanwhile is followed again.
  const jumpToLatest = (focused: boolean) => {
    const node = ref.current;
    if (!node) return;
    // Jump to latest is the reader leaving the Find match: end its hold, or the next tick pulls the
    // view back to the match and stops following again.
    revealing.current = undefined;
    revealWindow.current = 0;
    // The room the stack grew while scrolled up comes first, out of view, so following again moves
    // nothing and the glide runs to the end above the card instead of snapping there.
    takeRoom();
    stopBottomStackFold();
    foldAnchor.current = undefined;
    dropFoldRoom(true);
    clearScrollOrigin(node);
    follow(true);
    if (focused) focusComposer?.();
    // cmux's animations off (ui.animations) or the system's Reduce Motion: it lands in one frame, and
    // with no glide in flight nothing aims one again at a moved end.
    const reduce = isAgentMotionOff() || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    // The layout the room just taken committed (flushSync above), not the one this render closed over.
    const target = Math.max(0, latestLayout.current.layout.totalHeight - node.clientHeight);
    stopJump();
    // Use the rail's shared curve and distance duration, scaled by the host's move token.
    const move = cssTimeMs(
      node.ownerDocument.defaultView?.getComputedStyle(node).getPropertyValue("--agent-motion-move") ?? "",
    );
    const duration = reduce
      ? 0
      : jumpDuration(target - node.scrollTop) * ((move ?? MOTION_MS.standard) / MOTION_MS.standard);
    jumpTarget.current = target;
    animateScroll(
      node,
      () =>
        Math.max(
          0,
          node.scrollHeight > 0
            ? node.scrollHeight - node.clientHeight
            : latestLayout.current.layout.totalHeight - node.clientHeight,
        ),
      duration,
      JUMP_CURVE,
      () => {
        jumpTarget.current = undefined;
        scrolledTo.current = { top: node.scrollTop, atLatest: true };
        seenAnchor.current = null;
        followTrace.set(node.scrollTop);
        scrollPacer.current?.cancel();
        setScrollAt(node.scrollTop, 0);
      },
      () => {
        // A native turn/bookmark command can replace the shared ride without a DOM input event.
        // Explicit stopJump disowns first; only an external replacement releases bottom follow.
        if (jumpTarget.current === undefined) return;
        jumpTarget.current = undefined;
        scrolledTo.current = { top: node.scrollTop, atLatest: false };
        follow(false);
      },
      { explicit: true },
    );
  };
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const intent = userScrollIntent(node);
    const detachIntent = attachUserScrollIntent(node);
    const followIntent = (next: boolean) => followRef.current(next);
    const cancelProgrammatic = (event?: Event) => {
      revealing.current = undefined;
      revealWindow.current = 0;
      // A sideways wheel (a code block's own scroll) keeps a disclosure's hold; the rest lets go.
      if (!(event?.type === "wheel" && !verticalWheel(event as WheelEvent))) {
        stopBottomStackFold();
        foldAnchor.current = undefined;
      }
      if (findFrame.current !== undefined) cancelAnimationFrame(findFrame.current);
      findFrame.current = undefined;
      if (reader(event)) followIntent(false);
      // Moving toward the latest row while following keeps following through the hold.
      else if (followingRef.current && movingDown(event)) followRequest.current = intent.request();
      if (jumpTarget.current !== undefined) {
        stopJump();
        scrolledTo.current = { top: node.scrollTop, atLatest: false };
        followIntent(false);
      }
    };
    let pointerY: number | undefined;
    let touchY: number | undefined;
    const reader = (event?: Event) => {
      // The wheel over a rail that scrolls itself scrolls the rail, not the transcript: the reader is
      // not moving the transcript, so follow and a jump in flight stay as they are (railWheel.ts).
      if (event && railOwnsWheel(event)) return;
      const pointer = event?.type === "pointermove" ? (event as PointerEvent) : undefined;
      const touch = event?.type === "touchmove" ? (event as TouchEvent).touches[0] : undefined;
      const movingUp =
        event !== undefined &&
        ((event.type === "wheel" && (event as WheelEvent).deltaY < 0) ||
          (event.type === "keydown" && ["ArrowUp", "PageUp", "Home"].includes((event as KeyboardEvent).key)) ||
          (pointer !== undefined &&
            pointerY !== undefined &&
            (pointer.pointerType === "touch" ? pointer.clientY > pointerY : pointer.clientY < pointerY)) ||
          (touch !== undefined && touchY !== undefined && touch.clientY > touchY));
      if (event?.type === "pointerdown") {
        pointerY = (event as PointerEvent).clientY;
      } else if (pointer) pointerY = pointer.clientY;
      if (event?.type === "touchstart") touchY = (event as TouchEvent).touches[0]?.clientY;
      else if (touch) touchY = touch.clientY;
      readerAt.current = performance.now();
      // Wheeling on at the top of the loaded rows scrolls nothing while older history pages in: the
      // reader's input, not only its scroll events, keeps the right-hand card held
      // (summary/heldWhileScrolling.ts).
      noteReaderScroll();
      followTrace.input();
      // The reader takes the view: a follow step still easing lands where it lays out.
      followGlide.current?.stop();
      // Release the follow intent synchronously when a reader starts moving up. The browser can
      // deliver the input before its scroll event; a streamed snapshot in that gap must not pin
      // the view back to the bottom. Capture the event so nested rows cannot commit first.
      if (movingUp) followIntent(false);
      readerUpPending.current = movingUp;
      if (jumpTarget.current !== undefined) {
        stopJump();
        scrolledTo.current = { top: node.scrollTop, atLatest: false };
        followIntent(false);
      }
      return Boolean(movingUp);
    };
    const unsubscribeIntent = intent.subscribe(cancelProgrammatic);
    const unsubscribeQuiet = intent.subscribeQuiet(() => {
      if (!followDeferred.current) return;
      followDeferred.current = false;
      if (followingRef.current) resumeDeferredFollow();
    });
    // attachUserScrollIntent captures the scroller and scrollbar inputs (a drag outside the
    // scroller too), then invokes this reader through the shared subscription before layout or
    // streaming can commit. A drag's end or a canceled input leaves no upward move pending.
    const readerReleased = () => {
      readerUpPending.current = false;
    };
    const readerCanceled = (event: Event) => {
      if (event.defaultPrevented && node.contains(event.target as Node)) readerUpPending.current = false;
    };
    const ownerDocument = node.ownerDocument;
    ownerDocument.addEventListener("pointerup", readerReleased, { capture: true });
    ownerDocument.addEventListener("pointercancel", readerReleased, { capture: true });
    ownerDocument.addEventListener("lostpointercapture", readerReleased, { capture: true });
    ownerDocument.defaultView?.addEventListener("blur", readerReleased);
    const canceledInputs = ["wheel", "keydown"] as const;
    for (const name of canceledInputs) ownerDocument.addEventListener(name, readerCanceled, { passive: true });
    // A click on a disclosure line holds it where it is (foldAnchor.ts), before the row's own handler
    // opens it.
    // A turn fold still sliding rows lands first, and the offset takes up however far that moved the
    // clicked line, so the hold keeps it on the pixel it was clicked at.
    const settleFold = (line: HTMLElement) => {
      if (!turnFold.current) return;
      const before = line.getBoundingClientRect().top;
      settleTurnFold(thread.current, turnFold.current, foldGhosts.current);
      turnFold.current = undefined;
      const moved = line.getBoundingClientRect().top - before;
      if (node && Math.abs(moved) >= 0.5) node.scrollTop += moved;
    };
    // What closes keeps the content as tall as the view's end, so the offset never clamps.
    const keepFoldRoom = () => {
      if (!node) return;
      const end = foldRoomFor(node.scrollTop, node.clientHeight, foldRoomRef.current);
      if (end === foldRoomRef.current) return;
      foldRoomRef.current = end;
      setFoldRoom(end);
    };
    const keepBottomFoldRoom = () => {
      if (!node) return;
      const end = foldRoomFor(node.scrollTop, node.clientHeight, foldRoomRef.current);
      stickyFoldRoom.current = { shrunk: rowsEndRef.current < end - 0.5 };
      if (end === foldRoomRef.current) return;
      foldRoomRef.current = end;
      setFoldRoom(end);
    };
    const beginBottomStackFold = (toggle: HTMLElement, line: HTMLElement): boolean => {
      // This ask is for tool/work disclosures. Message Show more/less and other controls retain
      // their established row anchor, including the room they need when closing at the end.
      if (!toggle.matches(".cv-tool.is-toggle, .cv-worked, .cv-subagents")) {
        stopBottomStackFold();
        return false;
      }
      if (!atFoldBottom(node.scrollTop, node.clientHeight, node.scrollHeight, FOLLOW_BOTTOM_DEADBAND_PX)) {
        stopBottomStackFold();
        return false;
      }
      const row = line.closest<HTMLElement>(".acpmux-row");
      if (!row) return false;
      stopBottomStackFold();
      followGlide.current?.stop();
      stopJump();
      // A closing tool keeps its expanded extent and clicked line rather than sliding down.
      if (toggle.matches(".cv-tool.is-toggle") && toggle.getAttribute("aria-expanded") === "true") {
        keepBottomFoldRoom();
        return false;
      }
      // Reopening at the physical bottom consumes any room retained by a prior collapse. The
      // expanded body itself supplies the height; keeping the old blank room would add a second,
      // jarring gap while the stack moves up.
      if (!stickyFoldRoom.current || toggle.getAttribute("aria-expanded") === "false") dropFoldRoom();
      const stack: BottomStackFold = { toggle: line, row, beforeTop: layoutScrollTop(node), delta: 0, from: 0 };
      bottomStackFold.current = stack;
      row.setAttribute("data-bottom-fold", "");
      // The explicit toggle reacquires follow even a few pixels from the end. Streaming never does.
      followIntent(true);
      stack.cleanupTimer = setTimeout(
        () => {
          if (bottomStackFold.current === stack) stopBottomStackFold();
        },
        Math.max(FOLD_HOLD_MIN_MS, foldMs(line) + FOLD_SETTLE_MS),
      );
      return true;
    };
    const holdClicked = (event: MouseEvent) => {
      const toggle = node ? foldToggleAt(event.target, node) : undefined;
      if (!toggle) return;
      const line = foldHoldTarget(toggle, node ?? undefined);
      settleFold(line);
      const bottom = beginBottomStackFold(toggle, line);
      // A keyboard click (detail 0) had no press: an older, abandoned one is not its place.
      foldAnchor.current = clickFold(line, event.detail > 0 ? pressed : undefined);
      pressed = undefined;
      if (!bottom) keepFoldRoom();
    };
    // The press notes where the line was: if streaming moves it before the click lands, the click's
    // hold puts it back where the reader pressed it. It holds nothing itself, so the press never moves
    // or redraws the toggle under the pointer (a click needs its press and release on one node).
    let pressed: FoldAnchor | undefined;
    const notePressed = (event: PointerEvent) => {
      const toggle = event.button === 0 && node ? foldToggleAt(event.target, node) : undefined;
      pressed = toggle ? holdFold(foldHoldTarget(toggle, node ?? undefined)) : undefined;
    };
    const dropPressed = () => {
      pressed = undefined;
    };
    // A collapsible's header that asks to be held (useAnchoredCollapse.ts): a toggle from the keyboard
    // or a header that is no disclosure button, as well as the click above.
    const holdAsked = (event: Event) => {
      const header = event.target as HTMLElement | null;
      if (!node || typeof header?.closest !== "function" || !node.contains(header) || !header.closest(".acpmux-row"))
        return;
      event.preventDefault();
      settleFold(header);
      const bottom = bottomStackFold.current?.toggle === header ? true : beginBottomStackFold(header, header);
      // The click that asked for it already holds this line at the place it was pressed at: keep it.
      foldAnchor.current = clickFold(header, foldAnchor.current);
      if (!bottom) keepFoldRoom();
    };
    // The reader scrolling lets go of it.
    const release = (event: Event) => {
      const key = (event as KeyboardEvent).key;
      if (key === "Enter" || key === " ") return;
      if (event.type === "wheel" && !verticalWheel(event as WheelEvent)) return;
      stopBottomStackFold();
      foldAnchor.current = undefined;
    };
    const releases = ["wheel", "touchstart", "keydown"] as const;
    node?.addEventListener("click", holdClicked, { capture: true });
    node?.addEventListener("pointerdown", notePressed, { capture: true });
    node?.addEventListener("pointercancel", dropPressed, { capture: true });
    node?.addEventListener(ANCHORED_COLLAPSE_EVENT, holdAsked);
    for (const name of releases) node?.addEventListener(name, release, { passive: true });
    // The wheel over Jump to latest scrolls the transcript (wheelPassThrough.ts).
    // The chat's own transcript only (a replay's sits in its own screen).
    const main = node?.closest(".acpmux-stage")?.parentElement?.closest<HTMLElement>(".acpmux-main");
    const removeWheel = node && main ? installWheelPassThrough(node, main) : undefined;
    // A drag from the empty margins either side of the column selects text (gutterSelect.ts); the
    // view it scrolls past an edge is the reader's scroll.
    // A chat change ends any drag first (`gutterRelease`, below), so a hold is always this chat's.
    const gutter =
      node && thread.current
        ? installGutterSelect(
            node,
            thread.current,
            () => intent.mark(),
            (held) =>
              setHeldRows(
                held
                  ? {
                      session: heldSession.current,
                      rows: held.map((row) => ({
                        ...row,
                        fromEnd: rowsRef.current.length - row.index,
                      })),
                    }
                  : undefined,
              ),
            main,
          )
        : undefined;
    gutterRelease.current = gutter?.release;
    wheelGlide.current = node ? installWheelGlide(node) : undefined;
    return () => {
      wheelGlide.current?.remove();
      wheelGlide.current = undefined;
      stopJump();
      unsubscribeIntent();
      unsubscribeQuiet();
      detachIntent();
      if (findFrame.current !== undefined) cancelAnimationFrame(findFrame.current);
      findFrame.current = undefined;
      ownerDocument.removeEventListener("pointerup", readerReleased, { capture: true });
      ownerDocument.removeEventListener("pointercancel", readerReleased, { capture: true });
      ownerDocument.removeEventListener("lostpointercapture", readerReleased, { capture: true });
      ownerDocument.defaultView?.removeEventListener("blur", readerReleased);
      for (const name of canceledInputs) ownerDocument.removeEventListener(name, readerCanceled);
      node?.removeEventListener("click", holdClicked, { capture: true });
      node?.removeEventListener(ANCHORED_COLLAPSE_EVENT, holdAsked);
      node?.removeEventListener("pointerdown", notePressed, { capture: true });
      node?.removeEventListener("pointercancel", dropPressed, { capture: true });
      for (const name of releases) node?.removeEventListener(name, release);
      removeWheel?.();
      gutterRelease.current = undefined;
      gutter?.remove();
    };
  }, [dropFoldRoom, stopBottomStackFold, stopJump]);
  // A turn's footer (TurnFooter) shows for the turn the reader points at: anywhere after its prompt
  // to its footer. Marked on the mounted rows, so a hover renders nothing.
  // The last ended turn's prompt offers Retry under its bubble (UserBubble.tsx); turns.ts names
  // it on the turn's footer while it may be sent again.
  // Rows are immutable snapshots. Reuse the last ended turn's retry target across scroll and
  // focus commits, which do not change `rows` and otherwise walk the entire transcript.
  const retryPromptId = useMemo(() => {
    for (let index = rows.length - 1; index >= 0; index -= 1)
      if (rows[index]!.kind === "turnSummary") return rows[index]!.retryRowId;
    return undefined;
  }, [rows]);
  const markTurns = useCallback(() => {
    for (const node of thread.current?.querySelectorAll<HTMLElement>(".acpmux-row") ?? []) {
      node.toggleAttribute("data-retryable", node.dataset.rowId === retryPromptId);
      node.toggleAttribute("data-turn-revealed", node.dataset.rowId === pointedTurn.current);
    }
  }, [retryPromptId]);
  // Mark only when the mounted rows, their range, or the last turn changes. The old no-deps
  // layout effect scanned every commit, including scroll/follow state commits that cannot change
  // these attributes. `pointAt` still calls the callback directly for pointer-driven updates.
  useLayoutEffect(markTurns, [markTurns, rows, range.first, range.last]);
  // Older history pages in before the reader reaches it: whenever the view is within six viewports
  // of the first loaded row, including a tail too short to fill them. The anchoring above keeps the
  // reader's row in place as each page lands.
  // A read that drew no row above the first (records that draw nothing) moves historyFrom: ask again.
  const olderLoadKey = `${sessionKey}\u0000${rows[0]?.id ?? ""}\u0000${historyFrom ?? ""}`;
  const olderLoadRequested = useRef<string | undefined>(undefined);
  /// An older page asked for has not settled yet; and the check that follows one that brought nothing.
  const olderAsking = useRef(false);
  const olderRecheck = useRef<ReturnType<typeof setTimeout>>(undefined);
  /// The latest ask: only its settling re-arms the check, so a late answer to an earlier one (a
  /// chat switched away from) cannot cancel the recheck of the ask that followed it.
  const olderAsk = useRef(0);
  // The check reads the scroller's live offset, and runs on every scroll event as well as after
  // each commit: a page that lands moves the view down (the anchoring above) and the reader's
  // scroll back to the top could land in the same frame, so the rendered offset never changed
  // and a check that ran only on a change of it never asked for the next page (the scroll to the
  // first message stalled at the top after a few pages, perf100).
  const checkOlder = () => {
    const node = ref.current;
    if (!canLoadOlder || !onLoadOlder || !node || node.clientHeight === 0) {
      clearTimeout(olderRecheck.current);
      olderRecheck.current = undefined;
      olderAsk.current++;
      olderAsking.current = false;
      olderLoadRequested.current = undefined;
      return;
    }
    if (node.scrollTop >= node.clientHeight * OLDER_AHEAD_VIEWPORTS) {
      // Allow the next visit to the threshold to request the next page, even when the first row
      // did not change while the reader was away from the top.
      olderLoadRequested.current = undefined;
      return;
    }
    if (olderLoadRequested.current === olderLoadKey) return;
    const asked = olderLoadKey;
    olderLoadRequested.current = asked;
    olderAsking.current = true;
    const ask = ++olderAsk.current;
    // A page that lands changes the key in the commit it brings, and the check after it asks for
    // the next. An ask that brought nothing (a read that failed, or one the client dropped) leaves
    // the key as it was: ask once more a moment later, as long as the view is still near the top.
    // At the very top no scroll event comes to ask for it, and a check on every render would ask
    // on every streamed chunk (Leo 2026-10-21: a 720-turn chat stopped paging for good).
    const settled = () => {
      if (ask !== olderAsk.current) return;
      olderAsking.current = false;
      clearTimeout(olderRecheck.current);
      olderRecheck.current = setTimeout(() => {
        if (olderLoadRequested.current !== asked) return;
        olderLoadRequested.current = undefined;
        checkOlderNow.current();
      }, OLDER_RECHECK_MS);
    };
    onLoadOlder().then(settled, settled);
  };
  useLayoutEffect(() => {
    checkOlderNow.current = checkOlder;
  });
  useEffect(() => {
    checkOlderNow.current();
  }, [canLoadOlder, height, onLoadOlder, olderLoadKey, renderScroll.top]);
  useEffect(() => () => clearTimeout(olderRecheck.current), []);
  // A wheel up with the view already at the top moves nothing, so no scroll event says the reader
  // wants more: it asks itself, unless an ask is still out.
  const onWheel = (event: React.WheelEvent<HTMLDivElement>) => {
    if (event.deltaY >= 0 || event.currentTarget.scrollTop > 0 || olderAsking.current) return;
    olderLoadRequested.current = undefined;
    checkOlderNow.current();
  };
  const pointAt = (target: EventTarget | null) => {
    const row = target instanceof Element ? target.closest<HTMLElement>(".acpmux-row") : null;
    const rowId = row?.dataset.rowId;
    if (rowId === pointedRow.current && rows === pointedRows.current) return;
    pointedRow.current = rowId;
    pointedRows.current = rows;
    const from = row ? Number(row.getAttribute("aria-posinset")) - 1 : -1;
    // A prompt shows its own row, never its turn's too: one action row at a time.
    const footer = from >= 0 && rows[from]!.kind !== "user" ? turnFooterFrom(rows, from) : undefined;
    if (footer === pointedTurn.current) return;
    pointedTurn.current = footer;
    markTurns();
  };
  // Jump to latest remains shown once the reader is far behind, avoiding flicker near the threshold.
  const below = layout.totalHeight - height - (renderScroll.top - origin);
  if (seeking || renderFollowing || below <= FOLLOW_BOTTOM_DEADBAND_PX) jumpShown.current = false;
  else if (below > JUMP_LATEST_DISTANCE) jumpShown.current = true;
  const behind = jumpShown.current;
  // CHAT SWITCH PLAY: the last layout effect, so the new chat's rows are placed and scrolled to where
  // they will be drawn when the play picks the visible ones (CHAT SWITCH MOTION above).
  useLayoutEffect(() => {
    if (!switchPending.current || !hasRows) return;
    switchPending.current = false;
    switchPlay.current = playChatSwitch(ref.current, switchArm, switchPlay.current);
  }, [sessionId, hasRows, switchArm]);
  // The prompt rail's own box: the view's height, less the bottom stack at its smallest at this
  // height (the composer at rest). A composer that grows a line, a tray or bar that opens over the
  // view, or the lift a followed view takes leaves the rail where it is; a new view height, another
  // chat or another stack starts over.
  // Another stack's first measure comes in the layout effect after this render (`dockSpace` still
  // holds the old one's here), so it starts from none and takes that measure.
  const rest = restingDock.current;
  if (rest.dock !== dock) restingDock.current = { height, sessionId, dock, space: 0 };
  else if (rest.height !== height || rest.sessionId !== sessionId)
    restingDock.current = { height, sessionId, dock, space: dockSpace };
  else if (dockSpace > 0 && (restingDock.current.space <= 0 || dockSpace < restingDock.current.space))
    restingDock.current.space = dockSpace;
  // A stack not measured since it came (the latch's 0) reads as it is now.
  const railBox = { height, foot: height - (restingDock.current.space || dockSpace) };
  if (renderStart > 0) acpmuxPerf.span("vt.body", performance.now() - renderStart);
  return (
    <ReadOnlyBoundary readOnly={readOnly}>
      <div
        ref={ref}
        className="acpmux-scroll"
        role="feed"
        // A read-only transcript's right-clicks are reported to no host (conversation/messageMenu.ts).
        data-read-only-transcript={readOnly ? "" : undefined}
        // Its place comes back after a web update's reload (reportAnchor, pages/shared/webSwap.ts).
        {...(onAnchor ? { [WEB_SWAP_KEPT_SCROLL]: "kept" } : {})}
        aria-label={t("transcript.label")}
        onScroll={onScroll}
        onWheel={onWheel}
        // Its thin scrollbar stays shown while the chat overflows, as in every agent app, and never
        // flashes as rows arrive or the view follows them (scrollers.ts, Leo 2026-10-21).
        {...{ [SHOWN_SCROLLER_ATTRIBUTE]: "" }}
        // Soft edges (conversation.css): the top once scrolled from the start, the bottom while more
        // lies below. A followed reply has nothing below it, even while its growth outruns the offset.
        data-seeking={seeking || undefined}
        aria-busy={seeking || undefined}
        data-fade-top={renderScroll.top - origin > 0.5 || undefined}
        data-fade-bottom={
          (!renderFollowing && layout.totalHeight - (renderScroll.top - origin) - height > 0.5) || undefined
        }
        // Jump to latest stands in that band: the fade reaches past it, so rows (a date line) pass
        // out of sight behind it instead of reading through its glass.
        data-jump-shown={(jumpButton && behind) || undefined}
        // Under the bottom stack: rows there stay out of sight (conversation.css), and focus or Find
        // scroll a row into view above it.
        data-docked={dockSpace > 0 || undefined}
        style={dockSpace > 0 ? ({ "--acpmux-dock-space": `${dockSpace}px` } as React.CSSProperties) : undefined}
      >
        {showMinimap && (
          <ThreadMinimap
            rows={rows}
            earlier={earlier}
            promptCount={promptCount}
            loadThrough={loadThrough}
            sessionId={sessionId}
            layout={layout}
            scroller={ref}
            scrollTop={renderScroll.top - origin}
            // Above the room under the last row, so a composer that grows while the reader is scrolled
            // up leaves the map as it was, as it does the scrollbar.
            viewportHeight={height - room}
            // Where the transcript's mask ends the view (conversation.css --acpmux-view-foot): the
            // rail's rows stay above its bottom band.
            foot={height - dockSpace}
            railBox={railBox}
            scrolls={layout.totalHeight - height > 0.5}
            width={paneWidth}
            columnWidth={width}
            placed={minimapPlaced}
            change={rowsChange.current}
          />
        )}
        {/* The VS Code-style minimap at the right edge (Settings > Agent Chat > VS Code Minimap, off by default). */}
        <ChatMinimap
          // Another chat is another minimap: no canvas, placeholder or scale carried over.
          key={sessionId}
          rows={rows}
          layout={layout}
          scroller={ref}
          viewportHeight={height - room}
          foot={height - dockSpace}
          width={width}
          scrolls={layout.totalHeight - height > 0.5}
          change={rowsChange.current}
        />
        {find?.open && <ChatFindBar find={find} />}
        <TranscriptContext find={countReveal ?? findReveal} sessionId={sessionId}>
          <div
            className="acpmux-spacer"
            style={{
              height: layout.totalHeight,
              width: lane > 0 ? `calc(100% + ${lane}px)` : undefined,
            }}
          >
            <div
              ref={thread}
              className="acpmux-thread"
              style={{ top: `calc(${lift}px + var(--acpmux-scroll-origin, 0px))` }}
              onPointerOver={(event) => pointAt(event.target)}
              onPointerLeave={() => pointAt(null)}
            >
              {mountedRanges.flatMap(({ first, last }) =>
                rows.slice(first, last).map((row, index) => {
                  const absoluteIndex = first + index;
                  const next = nextDrawnRow(rows, absoluteIndex);
                  const actions = hasReplyActions(row, next);
                  const kind = rowKind(row);
                  const Component = registry[kind] ?? NoticeRow;
                  const isExpanded = row.foldOpen ?? expanded.has(row.id);
                  const controls =
                    row.kind === WORKED && isExpanded ? disclosureControls(rows, absoluteIndex + 1) : undefined;
                  return (
                    <RowFrame
                      key={`${sessionId ?? ""}:${row.id}`}
                      row={row}
                      kind={kind}
                      joinsPrevious={isStepRow(row) && isStepRow(rows[absoluteIndex - 1])}
                      joinsNext={isStepRow(row) && isStepRow(rows[absoluteIndex + 1])}
                      beforeFooter={isBeforeFooter(row, next)}
                      replyActions={keepsReplyRoom(row, next)}
                      status={statusEdge(row, next, prevDrawnRow(rows, absoluteIndex))}
                      lastFooter={isLastFooter(row, next)}
                      continuationFooter={isContinuationFooter(row, next)}
                      lastTurn={row.lastTurn === true}
                      index={absoluteIndex}
                      setSize={canLoadOlder ? -1 : rows.length}
                      top={layout.tops[absoluteIndex]}
                      rowWidth={scaledRowWidth}
                      expanded={isExpanded}
                      observer={observer}
                      report={reportDrawn}
                      // A session switch is a load, not a live arrival. The reset effect runs after
                      // this render, so gate it here as well to avoid a reused row id animating once.
                      enter={!sessionChanged && enteringRows.current.has(row.id)}
                      onEntered={onEntered}
                      older={olderRows.current!.has(row.id) ? olderRows.current : undefined}
                      onOlderShown={onOlderShown}
                      active={effectiveActiveRowId === row.id}
                      selected={selectedRows.has(absoluteIndex)}
                      tabStop={tabStopId === row.id}
                      onFocus={rowFocus}
                      onRowKeyDown={handleRowKeyDown}
                      contentType={Component}
                      controls={controls}
                      onToggleActivity={toggleRow}
                      onOpenDiff={onOpenDiff}
                      githubRepository={githubRepository ?? rowRepositories?.[absoluteIndex]}
                      referenceScope={scopeAt(absoluteIndex)}
                    >
                      <Component
                        row={row}
                        replyActions={actions}
                        sessionId={sessionId}
                        onToggleActivity={toggleRow}
                        onOpenDiff={onOpenDiff}
                        expanded={isExpanded}
                        controls={controls}
                        githubRepository={githubRepository ?? rowRepositories?.[absoluteIndex]}
                      />
                    </RowFrame>
                  );
                }),
              )}
            </div>
          </div>
        </TranscriptContext>
      </div>
      {afterLatest && (
        <div
          className="acpmux-transcript-after-latest"
          // The dock is absolute over the stage. Keep an after-latest tray in flow above its
          // measured room so the composer never covers the expansion or its live tail.
          style={dockHeight > 0 ? { marginBottom: dockHeight } : undefined}
        >
          {afterLatest}
        </div>
      )}
      {jumpButton && (
        <JumpToLatest
          // The pill also shows at the latest message while the chats this chat started wait: it cycles to them.
          shown={behind || (needsYou?.elsewhere ?? 0) > 0}
          working={working}
          onJump={(focused) => {
            // One press, one move: to the latest message when this chat's ask waits there (or no
            // ask is open), else straight to the next chat's ask.
            // With no ask open it is Jump to latest, whatever the last render read for `behind`.
            const asks = needsYou?.count ?? 0;
            const here = asks - (needsYou?.elsewhere ?? 0);
            const scroll = asks === 0 || (behind && here > 0);
            if (scroll) jumpToLatest(focused);
            if (needsYou && asks > 0) needsYou.next(scroll);
          }}
          lift={dockSpace}
          needsYou={needsYou}
        />
      )}
    </ReadOnlyBoundary>
  );
}

/// Answers `permission` with the option a button or key picked; rejects when acpmux refused it, which
/// the card shows.
const answerPermission = (permission: AcpmuxPermission) => (optionId: string) =>
  callNative("chat.permission", { permissionId: permission.permissionId, optionId });

/// Sends a question card's reply: the harness's option (absent cancels) and its answers. The card
/// shows a refusal (the promise rejects) and takes input again for a retry.
const replyToQuestion = (permission: AcpmuxPermission, sent: QuestionReply) =>
  callNative("chat.permission", {
    permissionId: permission.permissionId,
    ...(sent.optionId === undefined ? {} : { optionId: sent.optionId }),
    ...(sent.answers === undefined ? {} : { answers: sent.answers }),
    ...(sent.annotations === undefined ? {} : { annotations: sent.annotations }),
  });

/// Answers a secret card in the page (`chat.secret`): the value goes to acpmux only.
/// A provided value's failure reaches the card (it keeps the typed secret); a decline stays quiet.
const answerSecret = (ask: AcpmuxSecretAsk) => (value?: string) => {
  const sent = callNative("chat.secret", { secretId: ask.secretId, ...(value ? { value } : {}) });
  return value ? sent : sent.catch(() => undefined);
};

/// A permission ask: a question card when the request asks a question, else its option buttons.
function PermissionAsk({
  permission,
  harness,
  focusComposer,
  shownChat,
  shortcuts,
  waiting = 0,
}: {
  permission: AcpmuxPermission;
  harness?: string;
  focusComposer?: () => void;
  /// The chat shown now, read when a deny's instructions are about to go: with it, the card can deny
  /// with what the agent should do instead (`denyWithFeedback`).
  shownChat?: { readonly current: string | undefined };
  /// False while a permission group's panel takes the shortcuts (permissionKeys.ts `cardTakesShortcuts`).
  shortcuts?: boolean;
  /// More asks waiting behind this one (snapshot `permissionsWaiting`).
  waiting?: number;
}) {
  const t = useT();
  if (!permission.question)
    return (
      <PermissionCard
        permission={permission}
        harness={harness}
        focusComposer={focusComposer}
        shortcuts={shortcuts}
        onAnswer={answerPermission(permission)}
        onDenyWithFeedback={shownChat && denyWithFeedback(permission, shownChat)}
        waiting={waiting}
      />
    );
  return (
    <>
      {waiting > 0 && <p className="acpmux-permission-waiting">{t("permission.moreWaiting", { n: waiting })}</p>}
      <PermissionQuestion permission={permission} question={permission.question} send={replyToQuestion} />
    </>
  );
}

/// Denies `permission`, then gives the agent what to do instead: into the running turn now (a
/// steer; an agent that cannot steer stops the turn and takes it as the next prompt). Sent only once
/// acpmux took the deny, so the agent never reads it before its tool is refused, and only to the chat
/// that asked: another chat shown meanwhile would take it as its own. False when the deny failed.
const denyWithFeedback =
  (permission: AcpmuxPermission, shownChat: { readonly current: string | undefined }) =>
  async (optionId: string, text: string): Promise<boolean> => {
    const chat = shownChat.current;
    try {
      await callNative("chat.permission", { permissionId: permission.permissionId, optionId });
    } catch {
      return false;
    }
    if (text && shownChat.current === chat)
      await callNative("chat.send", { text, attachments: [], steer: true }).catch(() => undefined);
    return true;
  };

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

export function AcpmuxApp() {
  const [queryClient] = useState(createPaneQueryClient);
  return (
    <QueryClientProvider client={queryClient}>
      <AcpmuxPane />
    </QueryClientProvider>
  );
}

/// No projects known (a stable value, so memos keyed on it hold).
const NO_PROJECTS: Project[] = [];

function AcpmuxPane() {
  // Debug measurement (acpmuxPerf): the pane's own render, before its children.
  const paneRenderStart = acpmuxPerf.enabled ? performance.now() : 0;
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
  const [workflowLabsEnabled, setWorkflowLabsEnabled] = useState(true);
  /// What a chat opened from another tab inherited (#16620); the composer starts with it.
  const [draft, setDraft] = useState<string | undefined>();
  const [newSession, setNewSession] = useState(false);
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
  const [projectDraft, setProjectDraft] = useState<string | undefined>();
  /// The host offers Choose Folder… (a new chat in a workspace without a folder).
  const [chooseFolder, setChooseFolder] = useState(false);
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
  const [machineName, setMachineName] = useState<string | undefined>();
  // This Mac's own name (`localMachineName`): `machineName` names a seeded chat's machine instead.
  const [localMachineName, setLocalMachineName] = useState<string | undefined>();
  const [cloudMachineID, setCloudMachineID] = useState<string | undefined>();
  const [cloudRepositoryAvailable, setCloudRepositoryAvailable] = useState(false);
  const [cloudChatIdentity, setCloudChatIdentity] = useState<CloudChatIdentity>();
  const [cloudCredentialRecoveryAvailable, setCloudCredentialRecoveryAvailable] = useState(false);
  // Automatic Cloud credential recovery survives turn-action memo rebuilds and is bounded per session.
  const automaticCloudCredentialAttempts = useRef<Set<string>>(new Set());
  const [scrollAnchor, setScrollAnchor] = useState<(ScrollAnchor & { sessionId: string }) | undefined>();
  const [githubRepository, setGithubRepository] = useState<string | undefined>();
  /// What the direct client (or the host) last reported; `snapshot` draws a pending harness or
  /// model switch over it (harnessSwitch.ts).
  const [clientSnapshot, setSnapshot] = useState<AcpmuxSnapshot>(cachedSnapshot);
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
  // The page going away (its tab closed) with an unsent prompt gives the warm agent back now.
  useEffect(() => {
    const gone = () => newChatPrewarm.abandon();
    window.addEventListener("pagehide", gone);
    return () => {
      window.removeEventListener("pagehide", gone);
      gone();
    };
  }, [newChatPrewarm]);
  const queryClient = useQueryClient();
  // The pane keeps the last client's catalog until the next client's arrives;
  // ids only grow, so a new client never reads an older client's cache entry.
  const catalogClientId = useRef(0);

  const directClient = useRef<AcpmuxDirectClient | undefined>(undefined);
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
      current.summary?.peer,
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
  // The side preview panel (cx-ncc.63) shows a document from the open chat; another chat closes it.
  // Each open is its own panel (`opened`), which starts on its preview.
  const [artifact, setArtifact] = useState<Artifact & { sessionId?: string; opened: number }>();
  if (artifact && snapshot.sessionId !== artifact.sessionId) setArtifact(undefined);
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
  const backgroundOpen = backgroundPanel !== undefined;
  const backgroundCache = useRef<TaskCache>(new WeakMap());
  const artifactSession = snapshot.sessionId;
  // Its versions (cx-ncc.64): the chat's finished replies' documents of its kind and title.
  const artifactRows = artifact ? snapshot.rows : undefined;
  // Render cards by id (cx-ncc.94): a render that names an earlier one's id shows in that card.
  const pages = useMemo(() => renderPages(snapshot.rows), [snapshot.rows]);
  const artifactVersionList = useMemo(
    () =>
      artifact && artifactRows
        ? artifact.path
          ? uniqueArtifacts(writtenArtifacts(artifactRows).filter((item) => item.path === artifact.path))
          : (renderVersions(pages, artifact) ??
            artifactVersions(
              artifactRows.flatMap((row) => (row.kind === "assistant" && !row.streaming && row.text ? [row.text] : [])),
              artifact,
            ))
        : undefined,
    [artifact, artifactRows, pages],
  );
  const openArtifact = useCallback(
    (next: Artifact) =>
      setArtifact((current) => ({
        ...next,
        sessionId: artifactSession,
        opened: (current?.opened ?? 0) + 1,
      })),
    [artifactSession],
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
  const checkpoints = useCheckpoints({
    request: callNative,
    target: snapshot.summary?.cwd
      ? {
          cwd: snapshot.summary.cwd,
          sessionId: snapshot.sessionId,
          hostKind: snapshot.summary.hostKind,
        }
      : undefined,
    online: snapshot.connection === "connected",
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
  /// it read only (`readOnlySubagent`).
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
    subagentPane.current = true;
    setOwnSubagentPane(true);
    setRequestedSubagent(agent);
  };
  const revealRef = useRef(reveal);
  revealRef.current = reveal;
  // Footer actions show only while acpmux is reachable. The client reports failures in the
  // transcript; a bridge that cannot route an action has nothing to add.
  const connected = snapshot.connection !== "disconnected" && !snapshot.connection.startsWith("connecting");
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
      ? { target: { harness: healthHarness } }
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
  const authBlock = isAuthPreflightPending(routeChanging, routeAuthPending, snapshot.sessionId, authPending)
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
    },
    answersTrust,
    healthLocal && snapshot.origin !== "remote" && snapshot.origin !== "peer",
    blockSend,
  );
  // A no-folder recovery must not win over a trust answer made while its session switch is in
  // flight. The revision is advanced by Trust/Undo and by trust refusals, and read through a ref
  // because the host action handler outlives the render that installed it.
  const trustRevision = useRef(trustAsk.revision);
  trustRevision.current = trustAsk.revision;
  const trustRoute = trustAsk.refused;
  trustRefused.current = trustRoute;
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
  const individualPermission =
    snapshot.permission?.pending && !(snapshot.permissionGroups?.supported && snapshot.permission.groupId)
      ? snapshot.permission
      : undefined;
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
  const chatView = useTranscriptView(shownSessionId);
  const chatViewRef = useRef(chatView);
  chatViewRef.current = chatView;
  const viewToggled = viewToggles.get(chatView) ?? NO_FOLD_TOGGLES;
  const folds = useMemo(() => viewFolds(chatView, expanded, viewToggled), [chatView, expanded, viewToggled]);
  // Who runs this chat when it is not the person (managedBy.ts): the line over the composer.
  const [takenOverAt, setTakenOverAt] = useState(0);
  const manager = useMemo(
    () => (isTakenOver(shownSessionId) ? undefined : managedBy(shownSessionId, snapshot.sessions)),
    // takenOverAt: the person's Take over, read back from the store.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [shownSessionId, snapshot.sessions, takenOverAt],
  );
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
  // (withoutAskedCalls); with the panel hidden behind folder trust, it stays in the transcript.
  const trustBlocked = trustAsk.holdsAsks;
  const panelAsks = useMemo(
    () => (trustBlocked ? new Set<string>() : groupAskedCalls(snapshot.permissionGroups)),
    [trustBlocked, snapshot.permissionGroups],
  );
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
    () => ({ store: subsessionStore.current!, open: openOfferChat, openSender: openSenderChat }),
    [],
  );
  // The last snapshot's turns and subagent rows: the next builds on them (turnViewFrom).
  const lastTurns = useRef<{ turns: TurnView; subagents: SubagentRows } | undefined>(undefined);
  /// Debug Settings `agent.sessionStatus`: a running turn's activity line under its todo list.
  const sessionStatus = useSessionStatus();
  const turnRowsShown = useMemo(() => {
    if (childRows) {
      return withoutAskedCalls(withoutQuietThoughts(childRows), panelAsks);
    }
    const startedRows = withStartedSessions(sourceRows, started, startedCache.current);
    // Labs: a Claude workflow is a card where it started (summary/WorkflowCard.tsx), not a tray line.
    const rows = subagentTray ? withSubagentLines(startedRows, doneLines.current, workflowLabsEnabled) : startedRows;
    return acpmuxPerf.timed("app.rows", () => {
      const last = lastTurns.current;
      const turns = turnViewFrom(
        rows,
        folds,
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
        },
        last?.turns,
      );
      // Expand inbox summaries only after turn shaping. Source rows remain the semantic anchors
      // for turn boundaries, retries and queue actions; this is a display-only projection.
      const displayRows = projectInboxRows(turns.rows, last?.turns.rows, turns.reusedRows);
      const subagents = subagentRowsFrom(displayRows, folds, last?.subagents);
      lastTurns.current = { turns, subagents };
      // After the turns: a live turn's status reads its last row, the call's included.
      return withoutAskedCalls(withShellRows(subagents.rows, chatShellRuns), panelAsks);
    });
  }, [
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
  const transcriptRows = useMemo(() => {
    const steers = childRows ? NO_ROWS : (lastTurns.current?.turns.pending ?? NO_ROWS);
    // A guest's prompt is a person's, never another session's message: it draws on its own, held
    // with its Approve and Decline in view (conversation/QueuedMessageCard.tsx), never folded into
    // the group.
    const people = queuedRows.filter(isPersonQueuedRow);
    const agents = people.length ? queuedRows.filter((row) => !isPersonQueuedRow(row)) : queuedRows;
    const group = pendingMessagesRow(steers, agents, lastPending.current);
    lastPending.current = group;
    const merged = mergeInboxNotices(turnRowsShown);
    const shown = people.length ? [...merged, ...people] : merged;
    const rows = group ? [...shown, group] : shown;
    return childRows ? rows : btwNotes.rows(rows, snapshot.sessionId, btwSnapshot);
  }, [childRows, turnRowsShown, queuedRows, btwNotes, btwSnapshot, snapshot.sessionId]);
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
  const trustBlock = trustAsk.holdsAsks ? trustAsk.blocked?.reason : undefined;
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
  // A subagent's pane shows the subagent read only, never the chat's composer, queue or pull
  // request: they are the chat's. Once it shows a chat ("Subagent of", a branch pill, another
  // harness), that chat's composer is back: a prompt there goes to the chat it shows.
  const readOnlySubagent =
    workflowRequest !== undefined ||
    (ownSubagentPane && (subagentView !== undefined || requestedSubagent !== undefined));
  // Find in Chat over the transcript (ChatFindScope, below the pane); the page actions read it
  // through `findRef`.
  const findRef = useRef<ChatFind | undefined>(undefined);
  const diffFindRef = useRef<DiffFindHandle | undefined>(undefined);
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
  // The open changes view: a turn of one session, and the control that opened it.
  const [diffView, setDiffView] = useState<{
    sessionId?: string;
    rowId: string;
    path?: string;
    opener?: HTMLElement;
    /// The palette's Commit or Push for the open view (DiffPanel `gitIntent`).
    gitIntent?: { op: GitWriteOp; nonce: number };
  }>();
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
        setDiffView(undefined);
        inspectorOpener.current ??= document.activeElement instanceof HTMLElement ? document.activeElement : undefined;
      }
      setInspectorOpen(next);
      return next;
    },
    [clearWorkflowSideTab],
  );
  const sessionIdRef = useRef(snapshot.sessionId);
  sessionIdRef.current = snapshot.sessionId;
  /// Opens the chat folder's diff in its own pane right of the chat, as the header's Changes does
  /// (Lawrence 2026-10-13: "when i click diff viewer it opens in new pane to right, not in a split in
  /// same webpage"). False when the host cannot (a remote chat, Quick Chat, the gallery): the turn's
  /// diff then opens in place, as it does for a folder outside a repository and a turn that changed a
  /// file outside the repository, which the folder's diff does not hold (turnChanges/viewChanges.ts).
  /// Set below, once the header's actions exist.
  const diffBeside = useRef<(rowId: string, path?: string) => Promise<boolean>>(async () => false);
  // A click does not focus a button in WebKit, so the clicked control is the opener, not the focus.
  const openDiff = useCallback<OpenDiff>((rowId, path, opener) => {
    const clicked = opener ?? (document.activeElement instanceof HTMLElement ? document.activeElement : undefined);
    const inPlace = () => {
      inspectorOpenRef.current = false;
      setInspectorOpen(false);
      setDiffView({ sessionId: sessionIdRef.current, rowId, path, opener: clicked });
    };
    void diffBeside.current(rowId, path).then((opened) => {
      if (!opened) inPlace();
    }, inPlace);
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
  const sessionInfoOpened = useSessionInfoOpen(shownSessionId);
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
  // The palette's Commit and Push reach the open changes view, or open it on the newest turn of
  // the selected chat. A chat with no turn yet has no changes view to open.
  const gitIntents = useRef(0);
  const runGitIntent = useRef<(op: GitWriteOp) => void>(() => undefined);
  runGitIntent.current = (op) => {
    const nonce = ++gitIntents.current;
    const rowId = snapshotRef.current?.rows.at(-1)?.id;
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : undefined;
    setDiffView((view) => {
      if (view && view.sessionId === sessionIdRef.current) return { ...view, gitIntent: { op, nonce } };
      return rowId ? { sessionId: sessionIdRef.current, rowId, opener, gitIntent: { op, nonce } } : view;
    });
  };
  const clearGitIntent = useCallback(
    () => setDiffView((view) => (view?.gitIntent ? { ...view, gitIntent: undefined } : view)),
    [],
  );
  const closedByUser = useRef(false);
  const closeDiff = useCallback(() => {
    closedByUser.current = true;
    setDiffView(undefined);
  }, []);
  // Focus returns to the opener once the view is gone: until then the transcript is hidden,
  // and a hidden control can't take focus.
  const diffOpener = useRef<HTMLElement | undefined>(undefined);
  if (diffView?.opener) diffOpener.current = diffView.opener;
  useLayoutEffect(() => {
    if (diffView || !diffOpener.current) return;
    // A view that closed itself (session switch, turn gone) leaves focus where the reader put it.
    const focus = document.activeElement;
    if (closedByUser.current || !focus || focus === document.body) diffOpener.current.focus();
    closedByUser.current = false;
    diffOpener.current = undefined;
  }, [diffView]);
  // Row ids repeat across sessions (they count events), so another session closes the view.
  const diffOpen =
    diffView !== undefined &&
    diffView.sessionId === snapshot.sessionId &&
    snapshot.rows.some((row) => row.id === diffView.rowId);
  useEffect(() => {
    if (diffView && !diffOpen) setDiffView(undefined);
  }, [diffView, diffOpen]);
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
  // Address on a review thread (cx-ncc.77.3) settles once acpmux took its prompt: chat.send
  // itself settles when the turn ends, which could be long after, and a turn that fails later
  // was still sent. Until acpmux connects nothing takes a prompt.
  const addressThread = useCallback(
    (prompt: string) =>
      window.cmuxAcpmuxActions?.["chat.send"]
        ? new Promise<void>((resolve, reject) => {
            callNative("chat.send", { text: prompt, accepted: () => resolve() }).then(() => resolve(), reject);
          })
        : Promise.reject(new Error(translate("error.notOpen"))),
    [],
  );
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
  // Another agent's waiting message's ⋯ menu actions (conversation/QueuedMessageCard.tsx), made
  // below where the side chat is known; the cards read them as they draw.
  const queuedMessageActionsRef = useRef<QueuedMessageActionsValue | undefined>(undefined);
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
      ...(restartChat && {
        resume: (
          (owner: string) => () =>
            restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession)
              ? resumeThrough(callNative)()
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
        connected && cloudCredentialRecoveryAvailable,
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
      cloudSignIn: cloudAgentLogin({
        connected,
        machineID: cloudMachineID,
        sessionId: snapshot.sessionId,
        harness: snapshot.summary?.harness,
        supported: directClient.current?.supportsAgentLogin === true,
        gesture: (intent) =>
          postNative<{ ticket?: string }>("transport.gesture", { intent }).then((reply) => reply?.ticket),
        openURL: (url) => void callChipHost("browser.openIn", { url, browserId: "cmux" }),
        isCurrent: (owner) => restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession),
        currentClient: () => directClient.current ?? undefined,
      }),
      review: hunkReview,
      route: {
        harness: snapshot.summary?.harness,
        name: catalog.find((entry) => entry.id === (snapshot.summary?.harness ?? ""))?.name,
        hostKind: cloudMachineID ? "cloud" : snapshot.summary?.hostKind,
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
      cloudCredentialRecoveryAvailable,
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
    ],
  );
  // Streaming text changes rows on every chunk; only the turn's tool calls change its files.
  const diffActivity = useRef<{ key: string; files: TurnFile[]; pathsOnly: PathRef[] }>(undefined);
  const diffTurnFiles = useMemo(() => {
    if (!diffView || !diffOpen) return undefined;
    const activity = turnRows(snapshot.rows, diffView.rowId).filter((row) => row.kind === "activity");
    const key = `${diffView.rowId}\u0000${activity.map((row) => `${row.id}:${row.version}`).join("|")}`;
    if (diffActivity.current?.key !== key)
      diffActivity.current = {
        key,
        files: turnFiles(activity),
        pathsOnly: turnPathsOnly(activity),
      };
    return diffActivity.current;
  }, [diffView, diffOpen, snapshot.rows]);
  const diffFiles = diffTurnFiles?.files;
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
  const diffTurn = diffView && diffOpen ? turnKey(diffView.rowId) : undefined;
  // A turn's pair exists once it has ended, so the view asks then (and again when it ends while
  // the view is open); until then it shows the tool calls' edits.
  const diffTurnEnded = diffView && diffOpen ? turnRows(snapshot.rows, diffView.rowId).some(endsTurn) : false;
  useEffect(() => {
    if (diffTurn && diffTurnEnded) requestTurnCheckpoint(diffTurn);
  }, [diffTurn, diffTurnEnded, requestTurnCheckpoint]);
  const diffDisplay = useMemo(() => {
    if (!diffFiles || !diffTurn) return undefined;
    // An Undo chosen but not yet sent holds the tool-call view; Keep has nothing to send.
    const toolIds = new Set(diffFiles.flatMap((file) => file.edits.map((edit) => edit.toolId)));
    const pending = [...hunkDecisions].some(
      ([key, decision]) => decision === "rejected" && toolIds.has(key.split("\u0000")[0]!),
    );
    const load = turnCheckpoint(diffTurn) ?? { state: "loading" };
    return turnDisplay(t, diffFiles, load, pending, diffTurnFiles?.pathsOnly);
  }, [diffFiles, diffTurnFiles, diffTurn, hunkDecisions, t, turnCheckpoint]);
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
    if (path) return turn && openDiff(turn.rowId, path);
    if (diffView && diffOpen) return closeDiff();
    if (turn) openDiff(turn.rowId);
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
  // A prewarmed spare page gets its real context when Cmd-T adopts it; the generation remounts the screen.
  // The spare's own handshake named the spare's start folder: the adopting tab's folder replaces it
  // (the host names a folder below home, AgentPaneStartFolders), so Cmd-T on a spare names the tab's
  // project on its first frame instead of "Choose folder".
  const adoptNewTab = useCallback((host: NewTabHost) => {
    newTabStartGeneration.current += 1;
    setNewTab(host);
    const cwd = host.cwd;
    const named = cwd && !isAgentHome(cwd) && !/^\/(?:(?:Users|home)(?:\/[^/]+)?)?\/?$/.test(cwd) ? cwd : undefined;
    setProjectDraft(named);
  }, []);
  const newTabGeneration = useNewTabAdoption(adoptNewTab);
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
  const [contextKnown, setContextKnown] = useState(() => injectedNewTabContext() !== undefined);
  const markContextKnown = useCallback(() => setContextKnown(true), []);
  const earlyNewTab = useEarlyNewTabContext(callNative, setNewTab, markContextKnown);
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
    diff: { open: boolean; paths: string[] };
  }>(undefined);
  automationView.current = {
    snapshot,
    selectSession,
    openDiff,
    diff: { open: diffOpen, paths: (diffFiles ?? []).map((file) => file.path) },
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
  /// The Quick Composer panel (`"surface": "quick"` in the host's ready reply) or a tab's pane.
  const [surface, setSurface] = useState<PaneSurface>("pane");
  const quick = surface === "quick";
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
  /// Counts the Cloud starts that ended, so the folder default looks again once one has.
  const [cloudStartsEnded, setCloudStartsEnded] = useState(0);
  const sandboxModeRows = {
    mode: sandbox.mode,
    onMode: (mode: RunMode) => {
      runModePicked.current = true;
      sandbox.setMode(mode);
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
  const cloudPickedNotOffered = cloudPicked && !sandboxOffered;
  const [startCloud] = useState(() => oneCloudStart(callNative));
  const [cloudStart, setCloudStart] = useState<CloudStartProgress>();
  /// A Cloud start is out: the composer takes no edits until it ends (#28686 review). On success the
  /// host closes this tab with only the sent prompt, so text or files added meanwhile would be lost;
  /// on failure the prompt is still in the composer to edit and send again.
  const cloudStarting = cloudStart?.state === "starting";
  /// The same, for dictation's field getter (below), which is made once.
  const cloudStartingNow = useRef(false);
  cloudStartingNow.current = cloudStarting;
  const sendToCloud = (text: string, attachmentCount: number, start: Omit<CloudStart, "task">): string | false => {
    const refused = cloudPageRefusal(sandboxOffered, attachmentCount);
    if (refused === "cloud_not_now")
      return translate("composer.offloadNotRun", { action: translate("composer.cloud") });
    if (refused) return translate("composer.cloudAttachments");
    const key = crypto.randomUUID();
    const started = startCloud({ task: text, ...start }, key);
    // Another Return while a start waits starts nothing, and the card keeps that start.
    if (!started) return false;
    cloudStartPending.current = true;
    setCloudStart(
      cloudStartBegun(key, text, start.cwd, start.harness ? harnessLabel(start.harness) : undefined, start.home),
    );
    void started.then((answer) => {
      cloudStartPending.current = false;
      setCloudStartsEnded((count) => count + 1);
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
  useEffect(() => {
    setSandboxDraftMoved(false);
    setSandboxViewing(false);
    sandboxWake.current = undefined;
    runModePicked.current = false;
    // Another chat shows here: a Cloud start's card belongs to the new chat it was sent from.
    setCloudStart(undefined);
  }, [snapshot.sessionId, newTabGeneration]);
  /// The person picked another place to run after a Cloud start failed: its card goes.
  useEffect(() => {
    if (sandbox.mode !== "cloud") setCloudStart((current) => (current?.state === "failed" ? undefined : current));
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
  const runInBackground = useCallback(
    (toolCallId?: string) => trackBackground(directClient.current?.backgroundWork(toolCallId)),
    [trackBackground],
  );
  const foreground = useMemo(
    () => (canBackground && snapshot.isWorking ? foregroundCalls(snapshot.rows) : []),
    [canBackground, snapshot.isWorking, snapshot.rows],
  );
  const backgroundHint = !quick && canBackground && snapshot.isWorking ? runInBackground : undefined;
  const [autoOpenSubagents, setAutoOpenSubagents] = useAutoOpenSubagents();
  /// Shows subagent `id`: in a pane of its own right of the chat (focused with `focus`) once the
  /// summary card's switch is on, else in this pane (subagents/subagentPanes.ts).
  const showSubagent = useCallback(
    (id: string, focus = true) =>
      void showSubagentIn(callNative, id, focus, {
        panes: autoOpenSubagents,
        inSubagentPane: subagentPane.current,
        here: setSubagentView,
        title: subagentTitleRef.current(id),
        // Seed a new pane from this chat's kept tail before its own attach answers.
        beforeOpen: () => directClient.current?.handOverCurrentTail(),
      }),
    [autoOpenSubagents],
  );
  // A pane opened on a subagent shows the chat's other subagents in place, and its "Subagent of" pill goes
  // back to the chat: its tab's name follows what it shows (review of #28497 at 995299ff). Not before
  // the subagent it was opened on has shown, or the name the app gave the tab would flash away; and not
  // while this page has no rows for the subagent yet (they load after the pane opens), which would name
  // it "Subagent of" over the name the chat's page gave it.
  const shownSubagentKnown = !!subagentView && freshAgents.some((agent) => agent.id === subagentView);
  const shownSubagentTitle =
    ownSubagentPane && subagentView && shownSubagentKnown ? subagentTitle(subagentView) : undefined;
  const subagentShownOnce = useRef(false);
  useEffect(() => {
    if (!ownSubagentPane) return;
    if (subagentView) {
      subagentShownOnce.current = true;
      if (!shownSubagentTitle) return;
    } else if (!subagentShownOnce.current) return;
    void callNative(
      "chat.subagentShown",
      subagentView ? { subagent: subagentView, title: shownSubagentTitle } : {},
    ).catch(() => undefined);
  }, [ownSubagentPane, subagentView, shownSubagentTitle]);
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
  useBackgroundKey(!quick && (foreground.length > 0 || foregroundAgent), runInBackground);
  const chatTones = useMemo(() => (chatAgents.length > 0 ? agentTones(chatAgents) : undefined), [chatAgents]);
  // A message to a subagent names it by its description, never its agentId (MessageCard.tsx).
  const chatAgentNames = useMemo(() => agentNames(chatAgents), [chatAgents]);
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
  // The Inspector (Debug Settings `agent.inspector`): its toggle the first of the header's
  // top-right icons, the panel beside or over the chat. On, it takes the summary card's place.
  const sessionInfoSummary = snapshot.summary;
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
  // A diff in place, the event Inspector, and a narrow artifact cover the chat header. Keep the
  // environment chip out of the covered surface entirely so it cannot remain in the tab order or
  // flash through the overlay.
  const environmentCovered = (diffView !== undefined && diffFiles !== undefined) || inspectorOpen || artifactCovers;
  const uncoverChat = useCallback(() => {
    closeDiff();
    closeInspector();
    if (artifactCovers) setArtifact(undefined);
  }, [closeDiff, closeInspector, artifactCovers]);
  const openWorkflowSideTab = useCallback(
    (id: string, opener?: HTMLElement) => {
      workflowSideTabOpener.current =
        opener ?? (document.activeElement instanceof HTMLElement ? document.activeElement : undefined);
      closeInspector();
      setDiffView(undefined);
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
    snapshot: cardSnapshot,
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
    const key = Date.now();
    setRevealRow({ rowId: target.rowId, key, toolId: "" });
    setTimeout(() => setRevealRow((current) => (current?.key === key ? undefined : current)), REVEAL_HOLD_MS);
    return target.rowId;
  };
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
        const fold = turnFoldFor(rows, index);
        if (fold) openFold(fold);
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
        const fold = turnFoldFor(rows, index);
        if (fold) openFold(fold);
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
  const rowsRef = useRef<readonly AcpmuxRow[]>([]);
  /// The newest snapshot, for host requests that read it (pane.context).
  const snapshotRef = useRef<AcpmuxSnapshot | undefined>(undefined);
  /// The chat menu shows New side chat: the right-click menu then opens one from any turn that forks.
  const opensSideChat = useRef(false);
  const archiveChatRef = useRef<(() => void) | undefined>(undefined);
  const recheckCloudChat = useCallback(async () => {
    await directClient.current?.recheckMissing();
  }, []);
  const cloudRecovery = useCloudChatRecovery({
    cloud: cloudChatIdentity,
    session: snapshot.missingSession ?? snapshot.sessionId,
    active: cloudChatRecoveryActive(
      !!snapshot.unavailable,
      snapshot.sessionId,
      snapshot.rows.length,
      snapshot.connection === "connected",
      freshView,
    ),
    recheck: recheckCloudChat,
  });
  const cloudUnavailable =
    cloudRecovery.state === "paused" || cloudRecovery.state === "deleted"
      ? cloudChatUnavailable(snapshot.unavailable ?? { reason: "offline" }, cloudRecovery.state, machineName)
      : snapshot.unavailable;
  const hasTray = !quick && !freshView && (trayList.length > 0 || trayFinished.length > 0);
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
  const trayNode =
    !quick && !freshView && (trayList.length > 0 || trayFinished.length > 0) ? (
      <BackgroundTaskOutputContext.Provider value={backgroundTaskOutput}>
        <SubagentClockContext.Provider value={snapshot.clockOffsetMs ?? 0}>
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
            stop={stopSubagent}
            stopProcess={stopProcess}
            placement={trayPlacement}
            shown={trayChat}
            enters={trayEnters}
          />
        </SubagentClockContext.Provider>
      </BackgroundTaskOutputContext.Provider>
    ) : null;
  /// The composer's prompt, which dictation writes into.
  const prompt = useRef<MarkdownFieldHandle>(null);
  /// The composer itself, which takes back prompts a harness switch held; prompts handed back
  /// while it is not mounted (a handoff review) go in when it mounts.
  const composerHandle = useRef<ComposerHandle | null>(null);
  /// The composer is in shell mode, whose ⌘Return answers no recap card (RecapCard.tsx `keyHint`).
  const [composerShell, setComposerShell] = useState(false);
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
          (untakenSends.current > 0 || startingSends.busy || heldBack.current?.length || heldQuotes.current?.length
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
  }, []);
  const composerRef = useCallback((handle: ComposerHandle | null) => {
    composerHandle.current = handle;
    // A composer that goes takes its shell mode with it.
    if (!handle) setComposerShell(false);
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
  const chatDrawn = !awaitsChat || clientSnapshot.chatRead === true || openFailed;
  const showsWhatItIs = (handshaken && chatDrawn) || hostError !== undefined || newTab !== undefined;
  // No chat screen before the page knows it is no New Tab page (`contextKnown`).
  const knowsWhatItIs = contextKnown || newTab !== undefined || handshaken || hostError !== undefined;
  useEffect(() => {
    if (!handshaken || chatDrawn) return;
    // A slow attach: the client draws what it has after the open's hold (direct.ts OPEN_HOLD_MS).
    const timer = window.setTimeout(() => setAwaitsChat(false), CHAT_DRAW_HOLD_MS);
    return () => window.clearTimeout(timer);
  }, [handshaken, chatDrawn]);
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
        void loadDiffPanel();
        void loadHighlightedCode();
        void loadEditDiffHunks();
      }, 0),
    );
  }, [showsWhatItIs, drewKeptTail]);
  const summary = snapshot.summary;
  const localCwd =
    summary && !summary.peer && !(summary.host && summary.hostKind !== "local") ? summary.cwd : undefined;
  // Stop reaches acpmux even when pressed while the pane reconnects (stopThroughReconnect.ts).
  const stopThroughReconnect = useStopThroughReconnect(snapshot, cancelTurn);
  const keptStopping = stopThroughReconnect.stopping;
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
    // Prompts still waiting for a new chat to take them follow acpmux's queue.
    if (startingRows.length)
      withCommands.queue = [
        ...snapshot.queue,
        ...startingRows.map((row) => ({ id: row.id, prompt: row.text, sending: true })),
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
    localCwd,
    quick,
    keptStopping,
  ]);
  useEffect(() => {
    if (snapshot.sessionId) setProjectDraft(undefined);
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
        const diff = diffFindRef.current;
        const target = diff?.owns() ? diff.find : findRef.current;
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
        if (name === "gitCommit" || name === "gitPush") runGitIntent.current(name === "gitCommit" ? "commit" : "push");
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
        applyAgentTheme(theme as never);
        configureChatWidth(theme.chatWidth);
        configureCodexToolRuns(theme.codexToolRuns);
        configureLiveLineBelow(theme.liveLineBelow);
        configureToolRunLook(theme.toolRunLook);
        configureSentLook(theme.sentLook);
        configureInboxNoticeLook(theme.inboxNoticeLook);
        configureTurnActionsPlacement(theme.turnActionsPlacement);
        configureSubagentTray(theme.subagentTray);
        configureSubagentTrayPlacement(theme.subagentTrayPlacement);
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
      revealTurn(turnId) {
        revealRef.current(turnId);
      },
      applyCustomization(customization) {
        if ("themeCSS" in customization) {
          let style = document.getElementById("acpmux-user-theme") as HTMLStyleElement | null;
          if (!style) {
            style = document.createElement("style");
            style.id = "acpmux-user-theme";
            document.head.append(style);
          }
          style.textContent = customization.themeCSS ?? "";
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
      replaceRows(rows) {
        rowsRef.current = rows;
        setSnapshot((current) => ({
          ...current,
          rows,
          connection: "debug",
          isWorking: false,
          canLoadOlder: false,
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
        diff: () => automationView.current?.diff ?? { open: false, paths: [] },
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
      try {
        acpmuxPerf.markAgent("handshakeStart");
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
          /// The app opens a Cloud chat's hand-off turns (`cloud.handoffTurn`, cloudHandoffTurn.ts).
          cloudHandoffs?: unknown;
          cloudRepositoryAvailable?: unknown;
          githubRepository?: unknown;
          harnesses?: unknown;
          model?: unknown;
          sandboxState?: unknown;
        }>("ready", reconnect ? { reconnect } : {});
        if (cancelled) return;
        acpmuxPerf.markAgent("handshakeReady");
        setCloudCredentialRecoveryAvailable(host.cloudCredentialRecoveryAvailable === true);
        setCloudRepositoryAvailable(host.cloudRepositoryAvailable === true);
        setCloudMachineID(
          typeof host.cloudMachineID === "string" && host.cloudMachineID ? host.cloudMachineID : undefined,
        );
        setCloudChatIdentity(
          typeof host.cloudMachineID === "string" &&
            Array.isArray(host.cloudAccount) &&
            host.cloudAccount.every((part) => part === null || typeof part === "string")
            ? { id: host.cloudMachineID, account: host.cloudAccount as (string | null)[] }
            : undefined,
        );
        setNewSession(host.newSession === true && !host.sessionId);
        if (host.newSession && !host.sessionId && typeof host.cwd === "string" && host.cwd) setProjectDraft(host.cwd);
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
          if (composerHandle.current) composerHandle.current.wake(wake.composer);
          else pendingWake.current = wake.composer;
        }
        if (!reconnect && host.sessionId) {
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
        // A prompt a person's action seeded has a single-use host ticket bound to its promptId
        // (cx-k21v gap 4); a CLI, MCP or script seed has none and the host refuses its send.
        if (
          host.prompt &&
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
        // A new chat in mock mode starts without a session too, as against a real daemon.
        const mockConfig: AcpmuxHostConfig = host.newSession
          ? { ...mockHost, sessionId: undefined, newSession: true }
          : mockHost;
        let connectingClient: AcpmuxDirectClient | undefined;
        const client = await AcpmuxDirectClient.connect(
          mock ? mockConfig : (host as AcpmuxHostConfig),
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
            // Quiet while it comes back: nothing shows until the handshakes fail past the deadline.
            failingSince = Date.now();
            retryTimer = window.setTimeout(() => void connectHost(), retryDelay);
            retryDelay = nextRetryDelay(retryDelay, true);
          },
          mock
            ? () => new MockAcpmuxSocket(undefined, window.cmuxAcpmuxMockScript) as unknown as WebSocket
            : bridge
              ? () => new BridgeSocket() as unknown as WebSocket
              : undefined,
          mock ? "daemon" : "native",
        );
        if (cancelled) {
          client.close();
          return;
        }
        connectingClient = client;
        directClient.current = client;
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
          accepted?: () => void,
          steer = false,
          promptId?: string,
          expectedSessionId?: string,
          // Onboarding's seeded first task: no key or click of the person's sent it.
          seeded = false,
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
            return await sendThrough(text, attachments, accepted, steer, promptId, handedOn, expectedSessionId, seeded);
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
          accepted: (() => void) | undefined,
          steer: boolean,
          promptId: string | undefined,
          handedOn: () => void,
          expectedSessionId?: string,
          seeded = false,
        ) => {
          // A New Tab send may create/select its session inside ensureSession. Route a refusal by
          // the client's current selection generation rather than a render-time hook closure:
          // ensureSession can select before React has rendered the new chat.
          let sendOwner: TrustOwner = {
            client,
            generation: client.trustGeneration,
            sessionId: client.shownSession()?.sessionId ?? sessionIdRef.current,
            cancelEpoch: trustCancelEpoch.current,
          };
          const routeForSend: TrustRouter = (error, again, declined) =>
            routeTrustFor(sendOwner, error, again, declined);
          // acpmux holds the prompt while the folder's trust question is open (on session/new
          // or session/prompt): the question shows for the folder acpmux named, and Trust sends
          // the prompt the composer kept. `inComposer`: the composer still holds the prompt (or got it back); else it goes back.
          const refused = (error: unknown, inComposer: boolean): never => {
            if (isTrustRefusal(error)) {
              // A prompt kept as its own failed row: Trust sends that row again (with the gesture its
              // send kept, under its own prompt id), never what the composer holds by then.
              const row = failedRowOf(error);
              // The send's own gesture is kept for this prompt now, before the Trust click, whose
              // gesture goes to the trust answer (heldPrompt.ts).
              if (row) {
                // After Trust, the row's whole run goes again, as its card's Retry sends it.
                rowRetry.replayAfterTrust(error, routeForSend);
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
          const held = harnessSwitch.send(
            text,
            attachments,
            undefined,
            switchPromptId,
            !seeded && promptId === undefined,
          );
          if (held) {
            accepted?.();
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
          const heldForTrust = heldPrompt.take();
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
            .send(text, attachments, kept?.promptId ?? sendPromptId, accepted, sendTicket, steer, () =>
              promptLanded.current(),
            )
            .catch((error: unknown) => refused(error, Boolean(accepted)));
          // The client counts it from here (it registers the send before its first wait).
          handedOn();
          return turn;
        };
        window.cmuxAcpmuxActions = {
          // `accepted` (in-page only): the composer holds the prompt until acpmux takes it.
          "chat.send": ({ text, attachments, accepted, steer, expectedSessionId }) =>
            send(
              String(text ?? ""),
              Array.isArray(attachments) ? attachments : [],
              typeof accepted === "function" ? (accepted as () => void) : undefined,
              steer === true,
              undefined,
              typeof expectedSessionId === "string" ? expectedSessionId : undefined,
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
            if (!harnessSwitch.pickMode(String(modeId))) await setMode(String(modeId));
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
          "chat.select": async ({ sessionId }) => {
            newTabStartGeneration.current += 1;
            harnessSwitch.cancel();
            const selected = await client.select(String(sessionId));
            if (!selected || client.attachedSession() !== selected) return undefined;
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
          "pane.wakeState": async () => {
            await settleDraftWithin(composerHandle.current, DRAFT_SETTLE_MS);
            const anchor = transcriptAnchor.current?.();
            return {
              ...composerHandle.current?.wakeState(),
              ...(anchor ? { scrollAnchor: anchor } : anchor === null ? { atLatest: true } : {}),
            };
          },
        };
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
            const kept = heldPrompt.take();
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
        // A `#turn-<turnId>` link that opened this tab: scroll once the turn's row renders.
        if (typeof host.revealTurn === "string") revealRef.current(host.revealTurn);
        // Onboarding's first task runs without a Send press, once. If the chat cannot start,
        // the prompt waits in the composer instead of vanishing.
        const prompt = pendingPrompt;
        const harness = pendingHarness;
        const model = pendingModel;
        const ticket = pendingTicket;
        pendingPrompt = undefined;
        pendingHarness = undefined;
        pendingModel = undefined;
        pendingTicket = undefined;
        // The seeded prompt goes with its ticket, under the ticket's promptId.
        if (prompt && ticket) heldPrompt.keep(ticket);
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
        } else if (harness && prompt) {
          void harnessSwitch.switchTo(harness, host.cwd, { model });
          void send(prompt, [], undefined, false, ticket?.promptId, undefined, true).catch(() => undefined);
        } else if (prompt)
          void send(prompt, [], undefined, false, ticket?.promptId, undefined, true).catch(() => setDraft(prompt));
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
          setHostErrorShown(hostErrorShows(error, Date.now() - failingSince));
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
    folderContinuation,
    harnessSwitch,
    newChatPrewarm,
    queryClient,
    toggleInspector,
    earlyNewTab,
    restartGate,
    sandbox,
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
    if (command.action === "resume") {
      showAllChats();
      return true;
    }
    if (command.action === "login") {
      const harness = sessionAuth.harness ?? snapshot.summary?.harness ?? healthHarness;
      const declared = composerSnapshot.catalog.find((entry) => entry.id === harness)?.auth?.login;
      const login = slashLogin(sessionAuth, declared);
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
  diffBeside.current = async (rowId, path) => {
    // A remote or cloud chat's folder is not on this Mac, and Quick Chat's panel has no tab beside it.
    if (quick || !localCwd) return false;
    // The folder's diff is its repository's: a folder outside one, or a file the turn wrote outside
    // the repository, opens the turn's own diff in place (turnChanges/viewChanges.ts).
    const root = await repositoryRoot(localCwd, readFolderStatus);
    if (!root || !viewChangesBeside(turnRowsRef.current, rowId, root)) return false;
    // The tab opens on the turn (its Last turn), at the row's file; a turn with no checkpoint pair
    // opens the folder's diff.
    const turn = viewChangesTurn(turnRowsRef.current, rowId, path, root, localCwd);
    const reply = await callNative<{ ran?: boolean } | null>("pane.action", {
      id: HEADER_ACTIONS.changes,
      cwd: localCwd,
      mode: "open",
      ...(turn ? { turn } : {}),
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
    const transcriptView = transcriptViewRow(snapshot.sessionId, t, [wrapOutputRow(t), display]);
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
              onSelect: () => {
                clearWorkflowSideTab();
                setBackgroundPanel({ sessionId: snapshot.sessionId, expanded: false, dismissed: new Set() });
              },
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
    // A Sandboxed send from the page already took its prompt (or held it back).
    const handed = newTabSandboxSent.current;
    newTabSandboxSent.current = false;
    if (handed) return;
    const draft = { text: text.trim() ? text : "", attachments };
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
  /// A page coming back after the chat view stood in for it: what that composer held, as its draft.
  const takeNewTabDraft = () => {
    if (!composerStoodIn.current) return undefined;
    const waiting = composerHandle.current?.draft() ?? heldBack.current?.pop();
    if (heldBack.current?.length === 0) heldBack.current = undefined;
    return waiting;
  };
  // Activity disconnects the hidden page's draft/attachment/choice holds during setup. Keep
  // the reload hold in the parent until the page is visible and its own effects reconnect.
  useWebSwapHold(showNewTab && harnessesOpen ? "newtab.setup" : null);
  useEffect(() => {
    if (inspectorOpen || diffView || artifact || imageView || harnessesOpen || showNewTab || replaying) {
      clearWorkflowSideTab();
    }
  }, [artifact, diffView, harnessesOpen, imageView, inspectorOpen, replaying, showNewTab, clearWorkflowSideTab]);
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
      const sent = postUnsentDraft(text);
      const { harness } = freshPick.current;
      const cwd = freshPick.current.cwd ?? directClient.current?.newChatCwd();
      const target: PrewarmTarget | undefined = cwd ? { ...(harness ? { harness } : {}), cwd } : undefined;
      newChatPrewarm.typed(text, target);
      return sent;
    },
    [newChatPrewarm],
  );
  const onNewTabPromptTyped = useCallback(
    (text: string, target?: { harness?: string; cwd?: string }) =>
      newChatPrewarm.typed(
        text,
        target?.cwd ? { ...(target.harness ? { harness: target.harness } : {}), cwd: target.cwd } : undefined,
      ),
    [newChatPrewarm],
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
  const previewShown = computerUsePreview !== null && previewRoom && !quick && !diffView && !inspectorOpen;
  const sessionInfoPushes = useChatDisplay().sessionInfo === "push";
  const previewBeside = previewShown && !(sessionInfo.shown && sessionInfoPushes);
  // What the chat waits on the person for: the running turn's line says it, never "Thinking".
  const waiting = chatWaitsOn({
    trust: trustAsk.ask,
    holdsAsks: trustAsk.holdsAsks,
    trustBlocks: Boolean(trustAsk.blocked),
    isWorking: snapshot.isWorking,
    individualPermission,
    permissionGroups: snapshot.permissionGroups?.supported ? snapshot.permissionGroups.groups : undefined,
    secret: Boolean(snapshot.secret),
    cards: toolCards,
    silent: snapshot.silentTurn,
  });
  const transcript = (
    // Quick Chat's panel has no room beside it: its fences have no Open preview.
    <ArtifactContext.Provider value={quick ? undefined : openArtifact}>
      <RenderPages.Provider value={pages}>
        <ImageViewerContext.Provider value={openImage}>
          <ShellActionsContext.Provider value={shellActions}>
            <TurnActionsContext.Provider value={turnActions}>
              <RunInBackgroundContext.Provider value={backgroundHint}>
                <TurnCountsContext.Provider value={turnCountsFor}>
                  <SessionEditsContext.Provider value={editRows}>
                    <SessionCwdContext.Provider value={snapshot.summary?.cwd}>
                      <SubagentNavContext.Provider value={setSubagentView}>
                        <SubagentPaneContext.Provider value={showSubagent}>
                          <WorkingCountsContext.Provider value={workingCounts}>
                            <WaitingOnContext.Provider value={waiting}>
                              <SubagentStopContext.Provider value={stopSubagent}>
                                <SubagentClockContext.Provider value={snapshot.clockOffsetMs ?? 0}>
                                  <SubagentHarnessContext.Provider
                                    value={knownMark(snapshot.summary?.harness, snapshot.summary?.family)}
                                  >
                                    <SessionHoverContext.Provider value={sessionHover}>
                                      <SubsessionContext.Provider value={subsessions}>
                                        <StartedMentionsContext.Provider value={startedMentions}>
                                          <FailedSendsContext.Provider value={failedSends}>
                                            <ChatFindScope
                                              rows={childRows ?? findRows}
                                              shown={childRows ? undefined : transcriptRows}
                                              openFold={openFold}
                                              findRef={findRef}
                                            >
                                              {(find) => (
                                                <VirtualTranscript
                                                  rows={transcriptRows}
                                                  earlier={!childRows ? snapshot.earlierPrompts : undefined}
                                                  promptCount={!childRows ? snapshot.promptCount : undefined}
                                                  loadThrough={
                                                    !childRows
                                                      ? (seq) =>
                                                          directClient.current?.loadThrough(seq) ??
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
                                                        ? () => directClient.current?.loadOlder() ?? Promise.resolve()
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
                                          </FailedSendsContext.Provider>
                                        </StartedMentionsContext.Provider>
                                      </SubsessionContext.Provider>
                                    </SessionHoverContext.Provider>
                                  </SubagentHarnessContext.Provider>
                                </SubagentClockContext.Provider>
                              </SubagentStopContext.Provider>
                            </WaitingOnContext.Provider>
                          </WorkingCountsContext.Provider>
                        </SubagentPaneContext.Provider>
                      </SubagentNavContext.Provider>
                    </SessionCwdContext.Provider>
                  </SessionEditsContext.Provider>
                </TurnCountsContext.Provider>
              </RunInBackgroundContext.Provider>
            </TurnActionsContext.Provider>
          </ShellActionsContext.Provider>
        </ImageViewerContext.Provider>
      </RenderPages.Provider>
    </ArtifactContext.Provider>
  );
  // Folder trust is the first gate in the bottom stack. While its question is open (or after Don't
  // trust), permission and secret cards stay out of the tree so the user never has two different
  // asks competing for the same answer. A read in flight asks nothing and holds nothing: the cards
  // keep their place (no blink on a chat switch). A trusted receipt can sit above the next ask.
  const continueWithoutFolder = useCallback(() => callNative<void>("chat.new", folderContinuationRequest), []);
  const trustPending = trustAsk.holdsAsks;
  // A secret is the one ask held while the trust read is in flight: a value typed into it must
  // never go before the folder is known to need no trust answer first.
  const secret = trustAsk.blocked ? undefined : snapshot.secret;
  const hasPermissionGroups = Boolean(
    snapshot.permissionGroups?.supported &&
    (snapshot.permissionGroups.groups.length > 0 || snapshot.permissionGroups.error),
  );
  const hasBottomAsk = Boolean(
    (trustAsk.ask && (trustAsk.ask.state !== "decided" || trustAsk.ask.level === "untrusted")) ||
    (!trustPending && (hasPermissionGroups || individualPermission || secret || toolCards.length > 0)),
  );
  // Behind the agent.sessionStatus Debug toggle (`sessionStatus`, read above for the transcript): a
  // turn that ended on a question offers its yes above the composer (RecapCard.tsx).
  const recapCard = useRecapCard({
    rows: snapshot.rows,
    sessionId: snapshot.sessionId,
    on: sessionStatus && !snapshot.isWorking,
    // A chat the composer cannot send to (remoteEditing.ts) has no yes to offer.
    asking: hasBottomAsk || trustPending || Boolean(pendingFolder) || !remoteComposer(snapshot).canSend,
    send: (text) => addressThread(text),
    focusComposer: () => composerHandle.current?.focus(),
  });
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

      {!trustPending && hasPermissionGroups && snapshot.permissionGroups && (
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
      {!trustPending && (individualPermission || secret || toolCards.length > 0) && (
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
              focusComposer={() => composerHandle.current?.focus()}
              shownChat={shownChat}
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
  // request bars there were the chat's, and a prompt typed in it went to the chat.
  const composer = readOnlySubagent ? (
    <SubagentPaneFooter chat={chatName} />
  ) : (
    !reviewing && (
      <>
        {recapCard.recap && (
          <RecapCard
            recap={recapCard.recap}
            onReply={recapCard.reply}
            onDismiss={recapCard.dismiss}
            keyHint={!quick && !composerShell}
            failed={recapCard.failed}
          />
        )}
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
        {/* A chat the Chief or another chat's agent runs: who, and Take over (ManagedBanner.tsx). */}
        <Notice id="managed-by" tier="status" when={!quick && manager}>
          {manager && shownSessionId && (
            <ManagedBanner
              manager={manager}
              onOpenManager={openSenderChat}
              onTakeOver={() => {
                takeOverManaged(shownSessionId);
                setTakenOverAt(Date.now());
                composerHandle.current?.focus();
              }}
            />
          )}
        </Notice>
        {/* The tray (subagents/SubagentTray.tsx): in the bottom stack, right above the composer, every
          running or recently ended subagent, background command and started chat, one card each. */}
        {trayPlacement === "tray" && trayNode}
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
            onTyping={quick ? undefined : postTyping}
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
                const refused = sendToCloud(text, chips?.length ?? 0, {
                  ...cloudStartFolder(projectDraft ?? composerSnapshot.summary?.cwd ?? newTab?.cwd),
                  ...heldPick(composerSnapshot),
                });
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
              // Until acpmux connects nothing takes a prompt; the composer keeps it.
              if (!window.cmuxAcpmuxActions?.["chat.send"]) return false;
              // Shell mode's chips carry their commands' output as it is now.
              const attachments = shellContextAttachments(chips ?? [], (id) => shellRuns.get(id));
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
                    (composerHandle.current ?? holder)?.restore(text, attachments);
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
                      if (isTrustRefusal(error) && trustAsk.refused(error, () => composerHandle.current?.send())) {
                        holdPrompt.current?.();
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
              // Start Agent's Return; ⌘Return (onOpenInWindow, right after this) opens a window instead.
              if (surfaceRef.current === "quick") startInBackground(text, taken);
              const turn = send();
              turn.then(() => promptLanded.current(), cancelOpenInWindow);
              // Taken, or refused before acpmux took it (the turn's later failure is the transcript's).
              const held = Promise.race([taken, turn.then(() => true as const)]);
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
            onQueueRemove={(promptId) =>
              startingSends.owns(promptId) ? Promise.resolve(startingSends.remove(promptId)) : removeQueued(promptId)
            }
            onQueueCancelEdit={async (promptId, text, attachments) => {
              const removed = startingSends.owns(promptId)
                ? startingSends.remove(promptId)
                : await removeQueued(promptId);
              if (removed) restoreComposerDraft(composerHandle, heldBack, text, attachments);
              return removed;
            }}
            onQueueChange={(promptId, edit) =>
              startingSends.owns(promptId)
                ? Promise.resolve(edit.op === "update" && startingSends.edit(promptId, edit.text))
                : editQueued(promptId, edit)
            }
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
            onComputer={(computer) =>
              void callNative("chat.new", computer === "local" ? {} : { peer: computer }).catch(() => undefined)
            }
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
            {...(sandboxOffered ? { runMode: sandboxModeRows } : {})}
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
            onEmptyCommandReturn={recapCard.recap ? recapCard.reply : undefined}
            onShellChange={setComposerShell}
            prompt={prompt}
            handle={composerRef}
            onUnplacedQuotes={composerUnplacedQuotes}
            // No prompt goes while a picked folder waits for the user's answer, or while the chat only
            // shows a session another app runs (WatchBanner).
            blocked={trustAsk.blocked}
            blockSend={blockSend}
            closeOnTrustAsk={Boolean(
              trustAsk.ask && (trustAsk.ask.state !== "decided" || trustAsk.ask.level === "untrusted"),
            )}
            authBlock={signInNoticeVisible ? undefined : authBlock}
            authBlocked={Boolean(authBlock)}
            accessory={<DictationMic dictation={dictation} />}
            dictating={isWaitingForWords(dictation.state)}
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
  const hostLine =
    waitingSince !== undefined ? (
      <HostWaitingLine
        since={waitingSince}
        restarting={restartingAcpmux}
        onRestart={restartUnavailable ? undefined : restartStuck}
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
        aria-label={composerSnapshot.summary?.title || t("header.agentChat")}
        style={inTabRow ? tabRowStyle(tabRow) : undefined}
      >
        <div
          className="acpmux-main"
          data-new-chat={freshView && !showNewTab ? "" : undefined}
          // The transcript runs the pane's height under the bottom stack (bottomStack.css) while the
          // stage shows it; a new chat's hero, a handoff review, the diff and the inspector keep it in flow.
          data-dock={!reviewing && !freshView && !diffView && !inspectorOpen ? "float" : undefined}
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
          {!showNewTab && snapshot.summary?.goal && (
            <TaskGoalStrip
              key={snapshot.summary.sessionId}
              goal={snapshot.summary.goal}
              command={(action) => callNative("chat.send", { text: `/goal ${action}`, attachments: [] })}
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
                        ...(cloudStart ? { cloudStatus: <CloudStartView start={cloudStart} bubble={false} /> } : {}),
                        cloudStarting,
                        onCloud: (
                          harness: string,
                          text: string,
                          cwd: string | undefined,
                          model: string | undefined,
                          attachments: ComposerAttachment[],
                        ) =>
                          sendToCloud(text, attachments.length, {
                            harness,
                            ...cloudStartFolder(cwd),
                            ...(model ? { model } : {}),
                          }),
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
                  // Leo, 2026-10-31: "JUST PASSING THE SELECTED FOLDER/'PROJECT' WHEN YOU PICK CLOUD THAT'S
                  // THE BEST WAY. IT JUST GOES IT JUST WORKS". A project picked here goes to the host on its
                  // click (workspace.useFolder, as the chat composer's chip does in chooseProject), so a Cloud
                  // send copies it: cloud.startChat copies only the pane's own folders, and a recent project
                  // this page lists was none until the person sent in it here (#29294). Not on Return: the
                  // grant spends a gesture, and the Return's is the start's. Only a folder Cloud would copy
                  // (never home or above it, cloudStartFolder), and whenever Cloud may be offered, the
                  // host's sandbox check still out included (newTabProjectPick); a home or root answer
                  // asks nothing here (the local start still asks on Return).
                  {...newTabProjectPick(callNative, sandboxOfferable)}
                  {...(!handshaken ? { startPending: true } : {})}
                  {...(newTabChatsPending ? { chatsPending: true } : {})}
                  {...((newTab.host ?? machineName) ? { machineName: (newTab.host ?? machineName)! } : {})}
                  projects={newTabProjects}
                  onBrowseProject={() => callNative<{ cwd?: string }>("project.browse").then((result) => result?.cwd)}
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
              onOpen={(key) => void callNative("chats.open", { key }).catch(() => undefined)}
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
                className={`acpmux-stage${diffFiles ? " acpmux-reviewing" : ""}${inspectorOpen ? " acpmux-inspecting" : ""}`}
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
                    {inTabRow && (
                      <ChatHeaderInlineStatus status={header.status} detail={header.detail}>
                        {!showNewTab && snapshot.sessionId && (
                          <ThreadTitle key={snapshot.sessionId} title={chatName} onRename={renameFromTitle} />
                        )}
                      </ChatHeaderInlineStatus>
                    )}
                    <ChatHeaderTools
                      nativeRowTools={{
                        enabled: inTabRow && tabRow.nativeRowTools === true && !diffFiles && !inspectorOpen,
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
                      // Changes owns the diff of the chat's folder; a remote chat's folder is not on this Mac.
                      hasChanges={lastEditTurn !== undefined && localCwd !== undefined}
                      onChanges={(mode) => runSplitAction(HEADER_ACTIONS.changes, localCwd, mode)}
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
                {!diffView && checkpoints.review}
                {/* The lines under the header drop in from the top (ui/popupSurface.css `data-enter`). */}
                {snapshot.liveChat && (
                  <LiveChatChoice
                    {...snapshot.liveChat}
                    onChoose={(choice) => void callNative("chat.adoptLive", { choice }).catch(() => undefined)}
                  />
                )}
                {snapshot.peerCopy?.offline && (
                  <PeerCopyBanner
                    key={`${snapshot.sessionId ?? ""}:${snapshot.peerCopy.peer}`}
                    copy={snapshot.peerCopy}
                    machine={peerMachine.state}
                    onResume={peerMachine.resume}
                    onReconnect={reconnectPeer}
                  />
                )}
                {/* Computer use's live preview: the app this chat's agent drives, at the top right. Always
                    mounted: with no card it draws the last one's exit, then nothing (cardMotion.ts). */}
                <ComputerUsePreviewCard
                  preview={previewShown ? computerUsePreview : null}
                  onOpen={() => ignoreFailure(callNative("chat.computerUsePreview", { action: "open" }))}
                  onClose={() => ignoreFailure(callNative("chat.computerUsePreview", { action: "close" }))}
                />
                {snapshot.summary?.watching && !snapshot.liveTakeOver && (
                  <WatchBanner
                    family={snapshot.summary.watching}
                    onTakeOver={() => void directClient.current?.takeOver().catch(() => undefined)}
                    onContinue={() => void directClient.current?.continueWatched().catch(() => undefined)}
                  />
                )}
                {snapshot.summary?.watching && snapshot.liveTakeOver && (
                  <LiveChatChoice
                    {...snapshot.liveTakeOver}
                    onChoose={(choice) => void callNative("chat.adoptLive", { choice }).catch(() => undefined)}
                  />
                )}
                {!reviewing && snapshot.handoff?.error && (
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
                ) : cloudUnavailable ? (
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
                      <BackgroundTaskOutputContext.Provider value={backgroundTaskOutput}>
                        {transcript}
                      </BackgroundTaskOutputContext.Provider>
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
                {diffView && diffFiles && (
                  <Suspense fallback={null}>
                    <DiffPanel
                      files={diffDisplay?.files ?? diffFiles}
                      turn={diffDisplay}
                      initialPath={diffView.path}
                      root={snapshot.summary?.cwd}
                      onClose={closeDiff}
                      source={changesSource}
                      onOpenFile={openChangedFile}
                      checkpointAction={
                        checkpoints.supported ? (
                          <button type="button" className="acpmux-checkpoint-open" onClick={checkpoints.show}>
                            {checkpointLabels.createCheckpoint}
                          </button>
                        ) : undefined
                      }
                      checkpointReview={checkpoints.review}
                      review={hunkReview}
                      reviewFiles={diffFiles}
                      gitIntent={diffView.gitIntent}
                      onGitIntentHandled={clearGitIntent}
                      writeKeys={writeKeysFor(diffView.sessionId)}
                      onAddressThread={addressThread}
                      findHandle={diffFindRef}
                    />
                  </Suspense>
                )}
              </div>
              <div ref={setDock} className="acpmux-dock">
                {asks}
                {/* Between the hero and the docked composer. */}
                {/* A Sandboxed send holds the new chat: no recent chat replaces it while it is out. */}
                {freshView && !sandboxHoldsChat && !viewedSandbox && (
                  <div className="acpmux-home-area">
                    <HomeLists
                      sessions={snapshot.sessions}
                      currentId={snapshot.sessionId}
                      asks={snapshot.asks}
                      onSelect={selectSession}
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
          !diffView &&
          !sessionInfo.on &&
          summaryCard.column &&
          summaryPanel}
        {/* Beside the chat view only: New Tab, Harnesses and a replay have no session header. */}
        {!harnessesOpen && !showNewTab && !(replaying && replaying === snapshot.sessionId) && sessionInfo.panel}
        {artifact && (
          <ArtifactPanel
            key={artifact.opened}
            artifact={artifact}
            versions={artifactVersionList}
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
              onExpand={() => setBackgroundPanel((panel) => panel && { ...panel, expanded: !panel.expanded })}
              onClose={() => setBackgroundPanel(undefined)}
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
          !diffView &&
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
