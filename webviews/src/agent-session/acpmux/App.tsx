import React, {
  lazy,
  memo,
  Suspense,
  useCallback,
  useDeferredValue,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { flushSync } from "react-dom";
import { chiefEnvelope } from "./conversation/chiefEnvelope";
import { QueryClientProvider, useIsFetching, useQueryClient } from "@tanstack/react-query";
import { applyAgentTheme } from "../shared/theme";
import {
  layoutConversation,
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
} from "./model";
import { AcpmuxDirectClient, type AcpmuxHostConfig, harnessBlock, type HarnessBlock, isTrustRefusal } from "./direct";
import { postNative } from "./native";
import { NativeError } from "./nativeError";
import { errorMessage } from "./transportErrors";
import { pageHostClient, startHostEvents } from "./pageHost";
import { FOCUS_LOCATION_EVENT, NewTabPage, newTabHost, type NewTabHost } from "./NewTabPage";
import { setDeviceChats } from "./newtab/deviceChats";
import { setRecentlyClosed } from "./newtab/recentlyClosed";
import { NewTabScreen, type NewTabScreenActions } from "./newtab/NewTabScreen";
import { HistoryScreen } from "./newtab/HistoryScreen";
import type { AllChatsPage } from "./newtab/AllChatsList";
import { newTabScreenActions } from "./newtab/screenActions";
import { newTabChipSnapshot } from "./newtab/chipDefaults";
import { HarnessesScreen } from "./harnesses/HarnessesScreen";
import { openHarnessesPage, registerHarnessesPage, useHarnessesPage } from "./harnesses/harnessesPage";
import { injectedNewTabContext, useEarlyNewTabContext, useNewTabAdoption, useNewTabPlaces } from "./newtab/adoption";
import { StyleSwitch } from "./newtab/StyleSwitch";
import { pageStyle, pickNewTabStyle, screenTemplate, shownTemplate } from "./newtab/templates";
import { newTabPageSubmit } from "./newtab/pageSubmit";
import { isAgentHome, projectLabel } from "./sessionList";
import { ThreadMinimap } from "./threadMinimap/ThreadMinimap";
import { setBookmarkTransport } from "./threadMinimap/bookmarks";
import { composerDraft, notifyDraftActionsChanged } from "./composerDraft";
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
import { applySwitch, HarnessSwitch, lastOfferedModel, type SwitchPort } from "./harnessSwitch";
import { harnessProfiles } from "./harnessProfiles";
import { pickedMode, setStartModeSource, startModeChanged } from "./startMode";
import { MockAcpmuxSocket, mockHost, type MockScript } from "./mock";
import { BridgeSocket } from "./bridgeSocket";
import { useComposerKeyboard } from "./composerFocus";
import { createAcpmuxDebug, type AcpmuxDebug } from "./debug";
import { acpWire } from "./wire";
import { acpmuxPerf, type MountedSpan } from "./perf";
import { followTrace } from "./followTrace";
import { ScrollPacing } from "./pacing";
import { AdaptiveRenderRate, reportScrollPacing } from "./renderPacing";
import { Composer, type ComposerHandle, type ComposerWake } from "./Composer";
import type { ComposerAttachment } from "./attachments";
import { ComposerPickers, PICKER_LABELS, type ComposerPermissionAccess } from "./ComposerPickers";
import { openPicker } from "./pickerOpeners";
import { EmptyState, type EmptyStateProjects, isNewChat, projectName } from "./EmptyState";
import { PastChat, type PastTurn, readPastTurns } from "./PastChat";
import type { Project } from "./ProjectChooser";
import { HomeLists } from "./HomeLists";
import { turnFiles, turnRows, type TurnFile } from "./diff";
import type { TrustSource } from "./folderTrust";
import { TrustAsk } from "./TrustAsk";
import { SecretCard } from "./SecretCard";
import { ToolCards } from "./toolCards/ToolCards";
import { uploadToMachine } from "./cloudUploads";
import { useToolCards } from "./toolCards/toolCardStore";
import { PermissionCard } from "./PermissionCard";
import { QuestionCard } from "./question/QuestionCard";
import type { QuestionReply } from "./question/model";
import { agentName } from "./agents";
import { type Translate, translate, useT } from "./i18n";
import { useFolderTrustAsk } from "./useFolderTrustAsk";
import { heldPrompts } from "./heldPrompt";
import { FILE_SEARCH_LIMIT, type FileSearchSource } from "./fileSearchModel";
import type { DiffFindHandle } from "./changes/diffFind";
import { Inspector, type ExportOutcome } from "./Inspector";
import { SummaryButton } from "./summary/SummaryButton";
import { SummaryCard } from "./summary/SummaryCard";
import { useSessionRail } from "./summary/SessionRail";
import { pendingToolCalls } from "./summary/SubagentStatusList";
import { useSummaryCard } from "./summary/cardState";
import {
  openSubagentPane,
  revealedSubagent,
  useAutoOpenSubagents,
  useOpenNewSubagents,
} from "./subagents/subagentPanes";
import { turnCounts, turnDisplay } from "./changes/turnCheckpoint";
import { TurnCountsContext, type TurnCountsFor } from "./changes/TurnCountsContext";
import { useTurnCheckpoints } from "./changes/useTurnCheckpoints";
import { readTurnFromRows, type CheckpointDiff } from "./changes/turnCheckpointSource";
import { registerComposerHost } from "./composerSettings";
import { WHOLE_FILE_CONTEXT } from "./changes/wholeFile";
import { restoredDecisions, type HunkDecision, type HunkReview } from "./changes/hunkReview";
import { configureDictation, deliverDictation, useDictation, type DictationField } from "./dictation";
import type { DictationUpdate } from "./dictationText";
import { DictationMic } from "./DictationMic";
import { DictationNotice } from "./DictationNotice";
import type { MarkdownFieldHandle } from "./MarkdownField";
import type { ChangesSource } from "./changes/model";
import { RevealedMarkdown } from "./conversation/RevealedMarkdown";
import { WriteKeys, type GitWriteOp } from "./changes/gitWrite";
import { ToolRows, TurnFooter, WorkedFor } from "./conversation/TurnRows";
import { EditedFilesCard } from "./conversation/EditedFilesCard";
import { loadHighlightedCode } from "./conversation/CodeBlock";
import { loadEditDiffHunks } from "./conversation/EditDiff";
import { PlanList } from "./conversation/PlanList";
import { BackgroundTaskNote } from "./conversation/BackgroundTaskNote";
import {
  SessionCwdContext,
  SessionEditsContext,
  isEditRow,
  sessionEdits,
  type SessionEdits,
} from "./turnChanges/sessionRows";
import { TurnActionsContext, chatLoginCommand, type TurnActions } from "./conversation/turnActions";
import { UserBubble } from "./conversation/UserBubble";
import { editableKey, editableSeqs, editableTurns } from "./conversation/editPrompt";
import {
  clearFindHighlights,
  FindReveal,
  findRowIndex,
  paintFindHighlights,
  type ChatFind,
} from "./conversation/chatFind";
import { ChatFindBar } from "./conversation/ChatFindBar";
import { ChatFindScope } from "./conversation/ChatFindScope";
import { DATE, PREVIEW, RENDER, THINKING, WORKED, WORKING, type TurnView, turnViewFrom } from "./conversation/turns";
import { ArrowDown, Copy } from "./conversation/icons";
import { PreviewCard } from "./conversation/PreviewCard";
import { turnPreviewUrl } from "./conversation/previewUrl";
import {
  canFork,
  forksAnyTurn,
  latestForkSeq,
  messageMenuTarget,
  openReportedImage,
  setMessageMenuSource,
} from "./conversation/messageMenu";
import { callChipHost } from "./chips/host";
import { RenderCard, canRender } from "./conversation/RenderCard";
import { ArtifactPanel, type SaveDocument } from "./conversation/ArtifactPanel";
import { branchesFromKey, branchesKey, forkAnchor, messageBranches } from "./conversation/branches";
import { ArtifactContext, type Artifact } from "./conversation/artifactPreview";
import { artifactVersions } from "./conversation/artifactVersions";
import { renderCall } from "./conversation/renderCall";
import { DateLine } from "./conversation/DateLine";
import { ShortcutsContext, readShortcuts, type ShortcutLabels } from "./shortcuts";
import { FALLBACK_LINK_SCHEME, revealTurnWhenShown, setLinkScheme } from "./links";
import { copyText, copyTextResult } from "./conversation/clipboard";
import { lastCodeBlock } from "./conversation/lastCodeBlock";
import { transcriptCopyText, transcriptRangeText } from "./conversation/transcriptCopy";
import { rovingTabStopProps } from "../../ui/listRowKeyboard";
import { chatImages, type ChatImage } from "./conversation/chatImages";
import { ImageViewer } from "./conversation/ImageViewer";
import { ImageViewerContext } from "./conversation/imageViewerContext";
import { sessionLink } from "./links";
import { ChatHeaderStatus } from "./header/ChatHeaderStatus";
import { ChatHeaderTools, HEADER_ACTIONS, menuGroups, type ChatMenuItem } from "./header/ChatHeaderTools";
import { headerState, setHeaderState, useHeaderState } from "./header/headerState";
import { setTabRow, tabRowStyle, useTabRow, useTabRowTools } from "./header/tabRow";
import { PullRequestDock } from "./summary/PullRequestDock";
import { configureQuickActions, quickActions, type QuickActionMode } from "./header/quickActions";
import { chatColumnOf, configureChatWidth, useChatWidth } from "./chatWidth";
import { configureCodexToolRuns, useCodexToolRuns } from "./codexToolRuns";
import { archiveRow, markUnreadRow } from "./header/archiveRow";
import { copyRow } from "./header/copyRow";
import { instructionsRow, projectFilesRow } from "./header/instructionsRow";
import { sideChatRow } from "./header/sideChatRow";
import { Thinking } from "./conversation/Thinking";
import { WorkingFor } from "./conversation/WorkingFor";
import { type HarnessHealth, HarnessHealthNotice } from "./HarnessHealthNotice";
import { type SignIn, SignInContext, signedOutHarnesses, useSignIn } from "./signIn";
import { HostError } from "./HostError";
import { SHELL_ROW, ShellRuns, shellContextAttachments, withShellRows } from "./shell/shellRuns";
import { SUBAGENTS } from "./subagents/subagentFold";
import {
  SUBAGENT_OF,
  SUBAGENT_ROW,
  type SubagentRows,
  childView,
  isSubagentGroup,
  subagentRowsFrom,
} from "./subagents/subagentRows";
import { knownMark } from "../shared/AgentMark";
import {
  SubagentGroupHeader,
  SubagentHarnessContext,
  SubagentListRow,
  SubagentNavContext,
  SubagentOfRow,
  SubagentPaneContext,
  SubagentStopContext,
} from "./subagents/SubagentGroup";
import { endedEditRow, markRows, type RowMarks } from "./rowMarks";
import { ShellActionsContext, ShellRow, type ShellActions } from "./shell/ShellRow";
import { SwitchNotice } from "./SwitchNotice";
import { InstructionsNotice, type InstructionsFailure } from "./header/InstructionsNotice";
import { FolderChoice, showsFolderChoice } from "./FolderChoice";
import { type FolderAsk, StartFolderAsk, WorktreeFailure, confirmFolder, newWorktree, pickFolder } from "./startFolder";
import { MissingFolder, chooseChatFolder } from "./missingFolder";
import { LiveChatChoice } from "./LiveChatChoice";
import { HandoffReviewMessage } from "./handoff/ReviewMessage";
import { handoffStrings } from "./handoff/strings";
import type { HandoffReviewInput } from "./handoff/review";
import { continueTargets, mergedCommands, resolveHarnessTarget, type CmuxCommand } from "./cmuxCommands";
import { importedPrompt, parseImportedSession } from "./importSession";
import { useCheckpoints } from "./checkpoints/controller";
import { PermissionPanel } from "./permissions/Panel";
import { groupAskedCalls, withoutAskedCalls } from "./permissions/askRows";
import type { PermissionDecision } from "./permissions/protocol";
import { checkpointStrings } from "./checkpoints/strings";
import { QUICK_MESSAGES, readSurface, useEscapeToDismiss, type PaneSurface } from "./paneSurface";
import { QuickSurface } from "./QuickSurface";
import { contextAttachment, floatingStatus, type QuickFloating } from "./FloatingChat";
import { setFloatingState, useFloatingState } from "./floatingState";
import { FailedPrompt } from "./FailedPrompt";
import { ReplayScreen } from "./replay/ReplayScreen";
import { sessionReplay } from "./replay/replay.experiment";
import { SideQuestion, type SideQuestionState } from "./aside/SideQuestion";
import { sideQuestion } from "./aside/sideQuestion.experiment";
import { ReceivedResult, SuggestedTasks, type OfferActions } from "./offer/SuggestedTasks";
import { OFFER_RESULT, setSuggestedTasks } from "./offer/offersShown";
import { offerWorktree } from "./offer/offerWorktree";
import { experimentArm } from "../../experiments/experiment";

/// The changes view comes in its own chunk (bd cx-z9kz0): it carries the diff and file-tree
/// packages, which a New Tab page never shows, so the page's first script parses without them.
/// It starts loading once the page has painted, with the transcript's highlighted code and edit
/// cards (conversation/CodeBlock.tsx, conversation/EditDiff.tsx), so opening it waits on nothing.
const loadDiffPanel = () => import("./DiffPanel");
const DiffPanel = lazy(() => loadDiffPanel().then((module) => ({ default: module.DiffPanel })));

type MeasurableRenderer = React.ComponentType<RowProps> & { measure?: (row: AcpmuxRow, width: number) => number };
type NativeRegistry = Record<string, MeasurableRenderer>;
/// `onOpenDiff` opens the changes of the turn holding `rowId`, at `path` when given; focus
/// returns to `opener` when the view closes.
type OpenDiff = (rowId: string, path?: string, opener?: HTMLElement) => void;
type RowProps = {
  row: AcpmuxRow;
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
      command?(name: string): void;
      /// Copy Last Code Block (Opt-Cmd-;): the app reads the block and writes the pasteboard itself,
      /// since a script it runs here is no gesture the page's clipboard accepts.
      lastCodeBlock?(): string | null;
      /// The app's shortcuts as the user bound them, keyed by action id (shortcuts.ts).
      applyShortcuts?(labels: Record<string, string>): void;
      /// Preview features on or off (Settings > Advanced > Labs, `labs.previewFeatures`, off by
      /// default): the session coverage label.
      applyPreview?(on: boolean): void;
      /// Suggested tasks on or off (the Debug toggle `agent.suggestedTasks`, DEV and NIGHTLY, off by
      /// default): an agent's offers draw as the suggested tasks card (offer/offersShown.ts).
      applySuggestedTasks?(on: boolean): void;
      applyHeaderState?(state: unknown): void;
      /// The pane's tab row the header's tools may sit in (header/tabRow.ts).
      applyTabRow?(row: unknown): void;
      /// Start Agent's floating chat (floatingState.ts, cx-b9qi).
      applyFloatingState?(state: unknown): void;
      /// The newest device chats for the New Tab cards (newtab/deviceChats.ts).
      applyDeviceChats?(chats: unknown): void;
      /// The newest recently closed items for the New Tab page (newtab/recentlyClosed.ts).
      applyRecentlyClosed?(items: unknown): void;
      /// Scrolls to a turn a `cmux://session/<id>#turn-<turnId>` link names (links.ts), once its row
      /// renders; gives up quietly after a few seconds.
      revealTurn?(turnId: string): void;
      /// A dictation change from the host (CmuxNextAgentPane AgentPaneDictation), spliced at the prompt's cursor.
      dictation?(update: DictationUpdate): void;
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

function cachedSnapshot(): AcpmuxSnapshot {
  try {
    const value = JSON.parse(sessionStorage.getItem("cmux.acpmux.snapshot") ?? "null");
    if (value?.type === "snapshot" && Array.isArray(value.rows) && Array.isArray(value.sessions)) {
      acpmuxPerf.markAgent("snapshotPaint");
      return { ...emptySnapshot(), ...value, connection: "connecting" };
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

function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const direct = window.cmuxAcpmuxActions?.[method];
  if (direct) return direct(params) as Promise<T>;
  return postNative<T>(method, params);
}

/// Withdraws a queued prompt before its turn starts; false when it already started.
const removeQueued = (promptId: string) =>
  callNative<{ removed?: boolean } | null>("chat.queue.remove", { promptId }).then(
    (result) => result?.removed === true,
  );

/// Changes a waiting prompt (`_acpmux/queue_edit`); false when it already started.
const editQueued = (promptId: string, edit: QueueEdit) =>
  callNative<{ ok?: boolean } | null>("chat.queue.edit", { promptId, ...edit }).then((result) => result?.ok === true);

/// The width the header's tools take in the pane's tab row, so the App narrows the tabs (header/tabRow.ts).
const reportTabRowTools = (width: number) => void callNative("pane.tabRowTools", { width }).catch(() => undefined);
/// Hands the host a new chat's typed text, kept with its tab across a relaunch (cx-z5vd).
const postUnsentDraft = (text: string) => void callNative("chat.unsentDraft", { text }).catch(() => undefined);
/// Where chat `sessionId` rests, kept by its tab so a relaunch reopens it there (cx-6bgzj).
const postScrollAnchor = (sessionId: string, anchor: ScrollAnchor | null) =>
  void callNative("chat.scrollAnchor", { sessionId, rowId: anchor?.rowId ?? null, offset: anchor?.offset ?? 0 }).catch(
    () => undefined,
  );
/// A host that does not answer `chat.scrollAnchor.get` (the gallery, an older app) never holds up the chat.
const SCROLL_ANCHOR_READ_MS = 250;
/// Where chat `sessionId` rested when it was last shown; undefined when nothing is kept.
const fetchScrollAnchor = async (sessionId: string): Promise<(ScrollAnchor & { sessionId: string }) | undefined> => {
  const anchor = await Promise.race([
    callNative<{ rowId?: unknown; offset?: unknown } | null>("chat.scrollAnchor.get", { sessionId }).catch(() => null),
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
const trustSource: TrustSource = {
  get: (cwd) => callNative("acp.trust.get", { cwd }),
  set: (cwd, level) => callNative("acp.trust.set", { cwd, level }),
};

/// The changes view reads git scopes through the client, which knows the selected session's
/// folder and asks the native host (or, in mock mode, the in-page daemon).
const changesSource: ChangesSource = {
  diff: (scope) => callNative("git.diff", { scope, include_patch: true }),
  wholeFile: (scope, path) =>
    callNative("git.diff", { scope, include_patch: true, paths: [path], context_lines: WHOLE_FILE_CONTEXT }),
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
registerComposerHost((method, show) => void callNative(method, { show }).catch(() => undefined));
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
  function MessageRow({ row, githubRepository }: RowProps) {
    const t = useT();
    // A started task's result, which acpmux sent as a prompt: one line, never the person's bubble.
    if (row.kind === "user" && row.received) return <ReceivedResult result={row.received} onOpen={openOfferChat} />;
    if (row.kind === "user") {
      // A Chief subagent's first message: the Chief's view as one collapsed line, the task as
      // the message (the session keeps the whole text).
      const envelope = chiefEnvelope(row.text);
      return (
        <div className="cv-user">
          {envelope && (
            <details className="cv-user__context">
              <summary>{t("transcript.chiefContext", { count: envelope.lines })}</summary>
              <pre className="cv-user__context-text selectable">{envelope.context}</pre>
            </details>
          )}
          {envelope ? (
            <div className="cv-user__bubble selectable">{envelope.task}</div>
          ) : (
            <UserBubble row={row} text={row.text ?? ""} />
          )}
          <FailedPrompt row={row} />
          {row.status && (
            <div className="cv-user__status">
              <span>{row.status}</span>
              {row.queued && (
                <button
                  type="button"
                  className="cv-user__cancel"
                  onClick={() =>
                    void window.cmuxAcpmuxActions?.["chat.harness.cancelPrompt"]?.({ promptId: row.queued })
                  }
                >
                  {t("switch.cancelPrompt")}
                </button>
              )}
            </div>
          )}
        </div>
      );
    }
    return (
      <RevealedMarkdown text={row.text ?? ""} streaming={row.streaming === true} githubRepository={githubRepository} />
    );
  },
  (previous, next) =>
    previous.row.id === next.row.id &&
    previous.row.version === next.row.version &&
    previous.githubRepository === next.githubRepository,
);

/// Tool calls and thoughts as quiet rows (inside an open "Worked for", or live).
const ToolActivityRow = memo(
  function ToolActivityRow({ row }: RowProps) {
    return <ToolRows row={row} />;
  },
  (previous, next) => previous.row.id === next.row.id && previous.row.version === next.row.version,
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
    const queued = row.queued;
    return (
      <Thinking
        status={row.status}
        onCancel={
          queued
            ? () => void window.cmuxAcpmuxActions?.["chat.harness.cancelPrompt"]?.({ promptId: queued })
            : undefined
        }
      />
    );
  },
  // The start status line (version 0) becomes "Thinking" (version 1) in place.
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.row.status === b.row.status &&
    a.row.queued === b.row.queued,
);
const WorkingRow = memo(
  function WorkingRow({ row }: RowProps) {
    return <WorkingFor row={row} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.row.at === b.row.at &&
    a.row.durationMs === b.row.durationMs,
);

/// How many turns back the header's Preview looks for a page.
const PREVIEW_TURNS = 8;
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
    const call = tool && canRender() ? renderCall(tool) : undefined;
    return call ? <RenderCard call={call} /> : null;
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
    return row.plan ? <PlanList entries={row.plan} /> : <div className="acpmux-muted">{row.text}</div>;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
const BackgroundTaskRow = memo(
  function BackgroundTaskRow({ row }: RowProps) {
    return row.backgroundTask ? <BackgroundTaskNote task={row.backgroundTask} /> : null;
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
    return <PermissionAsk permission={permission} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// A batch of subagents (subagents/SubagentGroup.tsx); opening it lists them below.
const SubagentGroupRow = memo(
  function SubagentGroupRow({ row, onToggleActivity, expanded }: RowProps) {
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
/// The child view's "Subagent of" pill; a click goes back to the parent's view.
const SubagentOfPillRow = memo(
  function SubagentOfPillRow({ row }: RowProps) {
    return <SubagentOfRow row={row} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.row.text === b.row.text,
);
/// The edited-files card (conversation/EditedFilesCard.tsx, data in turnChanges/).
const EditedFilesRow = memo(
  function EditedFilesRow({ row, onOpenDiff }: RowProps) {
    return <EditedFilesCard row={row} onOpenDiff={onOpenDiff} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.onOpenDiff === b.onOpenDiff,
);

/// Opens a chat started from an offer (`chat.offer.open`): beside this one, else here.
const openOfferChat = (sessionId: string) => void callNative("chat.offer.open", { sessionId }).catch(() => undefined);
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

const defaultRegistry: NativeRegistry = {
  user: MessageRow,
  assistant: MessageRow,
  activity: ToolActivityRow,
  [WORKED]: WorkedRow,
  [DATE]: DateRow,
  [THINKING]: ThinkingRow,
  [WORKING]: WorkingRow,
  [PREVIEW]: PreviewRow,
  [RENDER]: RenderRow,
  editedFiles: EditedFilesRow,
  turnSummary: SummaryRow,
  notice: NoticeRow,
  plan: PlanRow,
  backgroundTask: BackgroundTaskRow,
  sessionOffer: SessionOfferRow,
  [OFFER_RESULT]: OfferResultRow,
  typing: NoticeRow,
  permission: PermissionRow,
  [SHELL_ROW]: ShellRow,
  [SUBAGENTS]: SubagentGroupRow,
  [SUBAGENT_ROW]: SubagentRow,
  [SUBAGENT_OF]: SubagentOfPillRow,
};

/// A row's height as the page drew it at a width. It places the row until its next version is drawn.
type DrawnHeight = { sessionId?: string; version: number; width: number; height: number };
type ReportDrawn = (id: string, version: number, height: number) => void;

type TranscriptRange = { anchorId: string; focusId: string };

/// Assistant and summary rows already expose the turn's copy action in TurnFooter. Keep the
/// floating action for prompts and tool rows; it shows only for keyboard focus and a selected
/// range (a prompt's hover shows the Copy under its bubble). The child view's "Subagent of" pill
/// is navigation, with nothing to copy. The Edited files card keeps its own controls in that
/// corner, where the floating Copy covered View changes once focus was in the card (cx-ncc.106);
/// a selected range still copies it.
const transcriptHasFloatingCopy = (row: AcpmuxRow) =>
  row.kind !== "assistant" &&
  row.kind !== "turnSummary" &&
  row.kind !== SUBAGENT_OF &&
  rowKind(row) !== "editedFiles" &&
  transcriptCopyText(row).length > 0;

/// Slides the thread from `step` px below (above, when negative) to its place over 180 ms, so
/// content that grew at the latest row glides in. Glides stack (`composite: "add"`): two started
/// before one paint move the text by their sum. None under Reduce Motion.
function glide(node: HTMLElement | null, step: number): void {
  if (!node || typeof node.animate !== "function") return;
  if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return;
  node.animate([{ transform: `translateY(${step}px)` }, { transform: "translateY(0px)" }], {
    duration: GLIDE_MS,
    easing: "cubic-bezier(0.2, 0, 0, 1)",
    composite: "add",
  });
}
const GLIDE_MS = 180;

/// Whether `updates` change any drawn height in `current`.
function changesDrawn(current: Map<string, DrawnHeight>, updates: Map<string, DrawnHeight>): boolean {
  for (const [id, entry] of updates) {
    const old = current.get(id);
    if (
      !old ||
      old.sessionId !== entry.sessionId ||
      old.version !== entry.version ||
      old.width !== entry.width ||
      Math.abs(old.height - entry.height) >= 0.5
    )
      return true;
  }
  return false;
}

/// One transcript row. It reports its drawn height before the frame paints whenever it mounts or
/// its content, width or expansion changes; the transcript's ResizeObserver reports later changes
/// (a font that loads, a custom renderer that grows).
function RowFrame({
  row,
  kind,
  joinsPrevious,
  joinsNext,
  index,
  setSize,
  top,
  rowWidth,
  expanded,
  observer,
  report,
  enter,
  onEntered,
  active,
  selected,
  tabStop,
  onFocus,
  onRowKeyDown,
  onCopy,
  copySelectionKey,
  copyable,
  children,
}: {
  row: AcpmuxRow;
  kind: string;
  /// A step row (tool calls, thoughts, a background task's end) after another: no gap above it.
  joinsPrevious: boolean;
  /// A step row before another: no gap below it, so steps keep one 26px rhythm across rows.
  joinsNext: boolean;
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
  active: boolean;
  selected: boolean;
  tabStop: boolean;
  onFocus: () => void;
  onRowKeyDown: (event: React.KeyboardEvent<HTMLElement>) => void;
  onCopy?: () => Promise<void>;
  copySelectionKey: string;
  copyable: boolean;
  children: React.ReactNode;
}) {
  acpmuxPerf.span("row.renders", 1);
  // This prop participates in the memo comparator; the frame itself does not need its value.
  void copySelectionKey;
  const t = useT();
  const ref = useRef<HTMLElement>(null);
  const [entering] = useState(enter);
  const [copied, setCopied] = useState(false);
  const rowTabStop = rovingTabStopProps(tabStop && !copyable, onRowKeyDown);
  const copyTabStop = rovingTabStopProps(tabStop && copyable, onRowKeyDown);
  useLayoutEffect(() => {
    if (entering) onEntered(row.id);
    // Only the first mount enters.
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
        acpmuxPerf.timed("row.measure", () => node.getBoundingClientRect().height),
      );
  }, [row.id, row.version, rowWidth, expanded, joinsPrevious, joinsNext, report]);
  return (
    <article
      ref={ref}
      id={rowDomId(row.id)}
      data-row-id={row.id}
      data-row-card={row.ended ? "true" : undefined}
      className={`acpmux-row acpmux-${kind}${joinsPrevious ? " acpmux-row--after-step" : ""}${joinsNext ? " acpmux-row--before-step" : ""}${entering ? " acpmux-row--enter" : ""}`}
      data-transcript-active={active ? "true" : undefined}
      data-transcript-selected={selected ? "true" : undefined}
      aria-current={active ? "true" : undefined}
      {...rowTabStop}
      aria-label={speaker(kind, t)}
      aria-posinset={index + 1}
      aria-setsize={setSize}
      style={{ transform: `translateY(${top}px)` }}
      onFocus={onFocus}
    >
      {copyable && (
        <button
          type="button"
          className="acpmux-row__copy cv-iconbtn"
          {...copyTabStop}
          aria-label={copied ? t("turn.copied") : t("turn.copy")}
          title={copied ? t("turn.copied") : t("turn.copy")}
          onClick={async () => {
            try {
              await onCopy?.();
              setCopied(true);
              window.setTimeout(() => setCopied(false), 1200);
            } catch {
              setCopied(false);
            }
          }}
        >
          <Copy />
        </button>
      )}
      {children}
    </article>
  );
}

// Scroll state changes the virtual window without changing the mounted rows. Keep those rows
// out of the render path; content/geometry/selection changes still invalidate the frame.
const MemoRowFrame = memo(
  RowFrame,
  (previous, next) =>
    previous.row === next.row &&
    previous.kind === next.kind &&
    previous.joinsPrevious === next.joinsPrevious &&
    previous.joinsNext === next.joinsNext &&
    previous.index === next.index &&
    previous.setSize === next.setSize &&
    previous.top === next.top &&
    previous.rowWidth === next.rowWidth &&
    previous.expanded === next.expanded &&
    previous.observer === next.observer &&
    previous.report === next.report &&
    previous.enter === next.enter &&
    previous.active === next.active &&
    previous.selected === next.selected &&
    previous.tabStop === next.tabStop &&
    previous.copySelectionKey === next.copySelectionKey &&
    previous.copyable === next.copyable,
);

/// Who spoke, for assistive technology: each article is one message in the transcript feed.
const speaker = (kind: string, t: Translate) =>
  kind === "user" ? t("transcript.you") : kind === "assistant" ? t("transcript.agent") : undefined;
const rowKind = (row: AcpmuxRow) => (isEditRow(row) ? "editedFiles" : row.kind);
/// A row drawn as tool rows: tool calls and thoughts, or a background task's end.
const isStepRow = (row: AcpmuxRow | undefined) =>
  row !== undefined && (row.kind === "backgroundTask" || (row.kind === "activity" && !isEditRow(row)));
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

/// Where a scroller sits, read while its content still matches `totalHeight`.
const scrollPosition = (node: HTMLElement, totalHeight: number) => ({
  top: node.scrollTop,
  atLatest: node.scrollTop >= totalHeight - node.clientHeight - 1,
});

/// Scroll steps of rows mounted ahead in the scroll direction, capped in viewports.
/// A scroll commits from its event, a frame after the offset moved, so without the
/// lead a fling shows a blank edge on every frame.
const SCROLL_LEAD_STEPS = 2;
/// More new rows than this in one update are a load (a session switch, older history), not live rows.
const LIVE_ROWS_PER_UPDATE = 3;
/// How far around the last mounted range a row whose drawn height changed is looked for; farther
/// (a jump), the whole transcript is placed again.
const DRAWN_SEARCH_ROWS = 64;
const MAX_SCROLL_LEAD_VIEWPORTS = 4;
/// Viewports of rows kept mounted either side of the reader, built between frames.
const WARM_VIEWPORTS = 1;
/// How far above the latest message the reader is before Jump to latest shows.
const JUMP_LATEST_DISTANCE = 80;
/// A smooth jump lands on the latest message once this has passed, even if a streaming reply grew past it.
const JUMP_LATEST_SETTLE_MS = 600;
/// A move off the latest row the reader did not make (no wheel, pointer, touch or key in the
/// transcript this long before it) and that stays within about a line of it is not a scroll up.
/// WebKit on macOS keeps whole-pixel offsets and nudged a growing reply's offset a pixel above
/// the latest line, which stopped the chat following for good (cx-02st5).
const READER_SCROLL_MS = 1000;
const STRAY_SCROLL_PX = 24;
/// How long a reopened chat stays unseen while older pages bring back the row the reader left it on
/// (cx-odzaz): each page must land within OPEN_AT_PAGE_MS and the whole walk within OPEN_AT_SEEK_MS,
/// else the chat opens at its latest message.
const OPEN_AT_PAGE_MS = 1500;
const OPEN_AT_SEEK_MS = 8000;
/// Scrolls `scroller` so `range` sits a third of the way down it, when it is not already in view.
function scrollRangeIn(scroller: HTMLElement, range: Range) {
  const box = range.getBoundingClientRect();
  const view = scroller.getBoundingClientRect();
  if (box.top < view.top || box.bottom > view.bottom)
    scroller.scrollTop += box.top - view.top - scroller.clientHeight / 3;
}
/// How long Find keeps a new match in view while its groups open and the rows above it measure:
/// at least 600 ms and 36 frames, so a page the machine starves (fewer frames) still holds the
/// match through the measures that come late. A page hidden meanwhile draws no frames and finishes
/// the frames it has left once shown.
const FIND_REVEAL_MS = 600;
const FIND_REVEAL_FRAMES = 36;
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
/// from the latest message (ChatGPT and Codex style). Its dots say a reply is streaming below. It stays
/// mounted while hidden (inert) so it fades out as it fades in (conversation.css).
function JumpToLatest({
  shown,
  working,
  onJump,
}: {
  shown: boolean;
  working: boolean;
  /// `focused`: the button had keyboard focus, which it loses when it hides at the latest message.
  onJump: (focused: boolean) => void;
}) {
  const t = useT();
  const label = t(working ? "transcript.jumpLatestWorking" : "transcript.jumpLatest");
  return (
    <button
      type="button"
      className="acpmux-jump-latest"
      data-shown={shown ? "" : undefined}
      data-working={working ? "" : undefined}
      aria-label={label}
      // Hidden, it is inert: out of the tab order and the accessibility tree while it fades out.
      inert={!shown}
      title={label}
      // A click does not focus a button in WebKit, so focus on it means Return or Space.
      onClick={(event) => onJump(event.currentTarget === document.activeElement)}
    >
      {working ? (
        <span className="acpmux-jump-latest__dots" aria-hidden="true">
          <i />
          <i />
          <i />
        </span>
      ) : (
        <ArrowDown size={14} />
      )}
    </button>
  );
}

export function VirtualTranscript({
  rows,
  sessionId,
  onToggleActivity,
  onOpenDiff,
  expanded,
  registry = defaultRegistry,
  canLoadOlder = false,
  githubRepository,
  find,
  working = false,
  jumpButton = false,
  focusComposer,
  openAt,
  onAnchor,
  anchorNow,
  onLoadOlder,
}: {
  rows: AcpmuxRow[];
  sessionId?: string;
  /// Where the transcript opens instead of the latest message, when that row is loaded.
  openAt?: ScrollAnchor;
  /// Where it rests after each settled scroll (null at the latest message).
  onAnchor?: (anchor: ScrollAnchor | null) => void;
  /// Filled with where it last rested in view (null at the latest message, undefined when it was
  /// never in view), for a page about to let go.
  anchorNow?: React.MutableRefObject<(() => ScrollAnchor | null | undefined) | undefined>;
  /// A reply is streaming: Jump to latest shows its dots while the reader is scrolled up.
  working?: boolean;
  /// Draw Jump to latest: the chat's own stage only, which positions it above the composer.
  jumpButton?: boolean;
  /// Where a keyboard Jump to latest leaves focus, since the button hides (inert) once there.
  focusComposer?: () => void;
  onToggleActivity: (id: string) => void;
  onOpenDiff?: OpenDiff;
  expanded: Set<string>;
  registry?: NativeRegistry;
  canLoadOlder?: boolean;
  /// Pages older history in (canLoadOlder): asked again on each render while the view is near the top.
  onLoadOlder?: () => Promise<void>;
  githubRepository?: string;
  /// Find in Chat (chatFind.ts): its bar, the query to highlight and the match to bring into view.
  find?: ChatFind;
}) {
  const t = useT();
  // Debug measurement (acpmuxPerf): off until the first debug call.
  const renderStart = acpmuxPerf.enabled ? performance.now() : 0;
  acpmuxPerf.span("vt.renders", 1);
  const [scroll, setScroll] = useState({ top: 0, delta: 0 });
  /// The view follows the latest row (scrolledTo.atLatest, as of the last scroll). Jump to latest shows
  /// when it does not and the latest message is more than JUMP_LATEST_DISTANCE below, read each render,
  /// so a reply growing below or a session switch updates it without a scroll.
  const [following, setFollowing] = useState(true);
  // `scroll` events also fire for layout-driven writes to scrollTop. Keep the user's intent in a
  // ref so those events cannot turn a pinned transcript into a one-frame jump when the composer
  // stack changes height.
  const followingRef = useRef(true);
  const follow = (next: boolean) => {
    followingRef.current = next;
    setFollowing(next);
  };
  const settle = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [height, setHeight] = useState(600);
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(760);
  // The column's cap (layout.json `chatWidth`): a new one measures every row again.
  const chatWidth = useChatWidth();
  // Rows place by their drawn height once drawn, and by the estimate until then.
  const [drawn, setDrawn] = useState(new Map<string, DrawnHeight>());
  const pendingDrawn = useRef(new Map<string, DrawnHeight>());
  const measurementCache = useRef(new Map<string, import("./model").PreparedRow>());
  /// The last estimate, whose unchanged leading rows the next one keeps.
  const lastEstimate = useRef<
    { rows: readonly AcpmuxRow[]; layout: ConversationLayout; width: number; sessionId?: string } | undefined
  >(undefined);
  /// Estimated heights by row object, for the registry they were measured with.
  const rowHeights = useRef<{ registry: NativeRegistry; heights: RowHeights }>({ registry, heights: new WeakMap() });
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
  const rowWidthRef = useRef(transcriptRowWidth(width));
  rowWidthRef.current = transcriptRowWidth(width);
  const rowsRef = useRef(rows);
  rowsRef.current = rows;
  // Keyboard focus is a roving tab stop. A range is kept as stable row ids rather than DOM nodes
  // because the transcript virtualizes rows and can unmount either end while the reader moves.
  const [activeRowId, setActiveRowId] = useState(rows[0]?.id);
  const [transcriptRange, setTranscriptRange] = useState<TranscriptRange | undefined>();
  const pendingFocus = useRef<string | undefined>(undefined);
  const sessionKey = sessionId ?? "";
  // Keep the key in state so a StrictMode render cannot consume the session transition before the
  // reset effect commits. The keyed values below make the first new-session paint fresh as well.
  const [selectionSessionKey, setSelectionSessionKey] = useState(sessionKey);
  const sessionChanged = selectionSessionKey !== sessionKey;
  useEffect(() => {
    if (sessionChanged) {
      setSelectionSessionKey(sessionKey);
      setActiveRowId(rows[0]?.id);
      setTranscriptRange(undefined);
      pendingFocus.current = undefined;
      return;
    }
    // Two ids to look up: a scan, not a set of a long chat's every row on each snapshot.
    const has = (id: string) => rows.some((row) => row.id === id);
    setActiveRowId((current) => (current && has(current) ? current : rows[0]?.id));
    setTranscriptRange((current) => {
      if (!current) return current;
      return has(current.anchorId) && has(current.focusId) ? current : undefined;
    });
  }, [rows, sessionChanged, sessionKey]);
  // Rows that arrive live (a reply, a tool call, a status line) enter once. The rows at the first
  // render, and many at once (a session switch, older history), are a load and do not.
  const knownRows = useRef<Set<string> | null>(null);
  const knownFor = useRef<AcpmuxRow[] | null>(null);
  const enteringRows = useRef(new Set<string>());
  if (knownRows.current === null) knownRows.current = new Set(rows.map((row) => row.id));
  // Scroll frames render the same rows: only a new row list can bring new rows.
  else if (knownFor.current !== rows) {
    // Rows before the first one that changed were all there last time.
    const previous = knownFor.current ?? [];
    let from = 0;
    while (from < rows.length && from < previous.length && rows[from] === previous[from]) from += 1;
    const arrived: AcpmuxRow[] = [];
    for (let index = from; index < rows.length; index += 1)
      if (!knownRows.current.has(rows[index]!.id)) arrived.push(rows[index]!);
    for (const row of arrived) knownRows.current.add(row.id);
    if (arrived.length <= LIVE_ROWS_PER_UPDATE) for (const row of arrived) enteringRows.current.add(row.id);
  }
  knownFor.current = rows;
  const onEntered = useCallback((id: string) => void enteringRows.current.delete(id), []);
  const reportDrawn = useCallback<ReportDrawn>(
    (id, version, drawnHeight) => {
      // Zero is a row not laid out (hidden, or no layout at all), not a height.
      if (drawnHeight > 0)
        pendingDrawn.current.set(id, {
          sessionId,
          version,
          width: rowWidthRef.current,
          height: drawnHeight,
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
        first: number;
        last: number;
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
        const old = current.get(id);
        if (
          old &&
          old.sessionId === entry.sessionId &&
          old.version === entry.version &&
          old.width === entry.width &&
          Math.abs(old.height - entry.height) < 0.5
        )
          continue;
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
            for (const entry of entries ?? []) {
              const target = entry.target as HTMLElement;
              const row = rowsRef.current[Number(target.getAttribute("aria-posinset")) - 1];
              if (row && row.id === target.dataset.rowId)
                reportDrawn(row.id, row.version, target.getBoundingClientRect().height);
            }
            // A late size change (a font loading) must not paint a frame of overlap first. Sizes
            // that did not change render nothing: a synchronous render here for nothing was the
            // "ResizeObserver loop completed with undelivered notifications" while streaming.
            if (!changesDrawn(drawnRef.current, pendingDrawn.current)) pendingDrawn.current = new Map();
            else acpmuxPerf.timed("flush.drawn", () => flushSync(flushDrawn));
          }),
    [reportDrawn, flushDrawn],
  );
  useEffect(() => () => observer?.disconnect(), [observer]);
  // Forget rows that left the transcript (a session switch, older history unloaded).
  const previousRowList = useRef<AcpmuxRow[] | undefined>(undefined);
  useEffect(() => {
    const previous = previousRowList.current;
    previousRowList.current = rows;
    // Rows that only grew below the ones there (a streaming turn) left none behind.
    if (
      previous &&
      previous.length <= rows.length &&
      previous.every((row, index) => row === rows[index] || row.id === rows[index]!.id)
    )
      return;
    const ids = new Set(rows.map((row) => row.id));
    const cache = measurementCache.current;
    for (const id of cache.keys()) if (!ids.has(id)) cache.delete(id);
    setDrawn((current) => {
      if ([...current.keys()].every((id) => ids.has(id))) return current;
      return new Map([...current].filter(([id]) => ids.has(id)));
    });
  }, [rows]);
  useLayoutEffect(flushDrawn);
  const didOpenAtLatest = useRef(false);
  /// The open waits, unseen, while older pages bring back `openAt`'s row; expired, it opens at the latest.
  const [seeking, setSeeking] = useState(false);
  const [seekExpired, setSeekExpired] = useState(false);
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
  const previousSession = useRef(sessionId);
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    // Before the frame paints: a resized pane (its tab strip showing or hiding) otherwise drew the
    // transcript at its old offset and caught up a frame later.
    const observer = new ResizeObserver(() =>
      flushSync(() => {
        setHeight(node.clientHeight);
        setWidth(node.clientWidth);
      }),
    );
    observer.observe(node);
    setWidth(node.clientWidth);
    return () => observer.disconnect();
  }, []);
  const previousLayout = useRef<ReturnType<typeof layoutConversation> | null>(null);
  const previousRows = useRef<AcpmuxRow[]>(rows);
  const previousViewport = useRef({ height, width });
  /// The pane's width changed and no new content has come since: rows settling to their drawn
  /// heights at the new width are that resize, not growth, and never glide.
  const reflowing = useRef(false);
  const thread = useRef<HTMLDivElement>(null);
  // The reader scrolls: a glide in flight ends at once, so the view goes where they scroll.
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const endGlide = () => {
      for (const animation of thread.current?.getAnimations?.() ?? []) animation.finish();
    };
    const events = ["wheel", "touchstart", "keydown"] as const;
    for (const name of events) node.addEventListener(name, endGlide, { passive: true });
    return () => {
      for (const name of events) node.removeEventListener(name, endGlide);
    };
  }, []);
  /// The footer of the turn the pointer is over (a turnSummary row's id).
  const pointedTurn = useRef<string | undefined>(undefined);
  const scrolledTo = useRef({ top: 0, atLatest: false });
  /// Where the reader last saw it rest, measured in view; undefined until it is.
  const seenAnchor = useRef<ScrollAnchor | null | undefined>(undefined);
  /// When the reader last moved the transcript themselves (wheel, pointer, touch or key).
  const readerAt = useRef(Number.NEGATIVE_INFINITY);
  /// Whether a move off the latest row, to `top` against `latest`, is a stray rather than the reader's.
  const strayFrom = (top: number, latest: number) =>
    latest - top < STRAY_SCROLL_PX && performance.now() - readerAt.current > READER_SCROLL_MS;
  // Scroll frames re-render with the same rows; only rows, width or the registry
  // change an estimate.
  const estimated = useMemo(() => {
    const layoutStart = acpmuxPerf.enabled ? performance.now() : 0;
    // Keep the session in this memo's inputs: its cache is cleared synchronously above even
    // when a host reuses the same rows array for a newly selected chat.
    const cache = measurementSession.current === sessionId ? measurementCache.current : new Map();
    const fresh = rowHeights.current.registry !== registry || measurementSession.current !== sessionId;
    if (rowHeights.current.registry !== registry) rowHeights.current = { registry, heights: new WeakMap() };
    const rowWidth = transcriptRowWidth(width, chatColumnOf(chatWidth));
    const last = lastEstimate.current;
    const layout = layoutConversation(
      rows,
      rowWidth,
      cache,
      (row, measureWidth) => registry[rowKind(row)]?.measure?.(row, measureWidth),
      measurementSession.current === sessionId ? rowHeights.current.heights : undefined,
      !fresh && last && last.width === rowWidth && last.sessionId === sessionId ? last : undefined,
    );
    lastEstimate.current = { rows, layout, width: rowWidth, sessionId };
    return { layout, ms: acpmuxPerf.enabled ? performance.now() - layoutStart : 0 };
  }, [rows, registry, sessionId, width, chatWidth]);
  // A row that draws moves only the rows below it: place them again, measuring none.
  const measured = useMemo(() => {
    const layoutStart = acpmuxPerf.enabled ? performance.now() : 0;
    const rowWidth = transcriptRowWidth(width);
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
      drawn.size > 0
    ) {
      const limit = Math.min(rows.length, last.rows.length);
      while (kept < limit && rows[kept] === last.rows[kept]) kept += 1;
      if (changed.size > 0) {
        let found = 0;
        const from = Math.max(0, last.first - DRAWN_SEARCH_ROWS);
        const to = Math.min(rows.length, last.last + DRAWN_SEARCH_ROWS);
        for (let index = from; index < to && found < changed.size; index += 1)
          if (changed.has(rows[index]!.id)) {
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
              const known = drawn.get(rows[index].id);
              return known && known.sessionId === sessionId && known.width === rowWidth ? known.height : undefined;
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
      first: last?.first ?? 0,
      last: last?.last ?? 0,
    };
    return { layout, ms: acpmuxPerf.enabled ? performance.now() - layoutStart : 0 };
  }, [estimated, drawn, registry, rows, sessionId, width]);
  const layout = measured.layout;
  const reportedLayout = useRef<typeof measured | null>(null);
  const reportedEstimate = useRef<typeof estimated | null>(null);
  const sessionSwitched = previousSession.current !== sessionId;
  // The old scroll state remains in React until the transition layout effect runs. Render the
  // new session from the top once so its first paint cannot reuse the previous chat's mounted rows.
  const renderScroll = sessionSwitched ? { top: 0, delta: 0 } : scroll;
  const renderFollowing = sessionSwitched || following;
  const ahead = scrollLeadRanges(
    layout,
    renderScroll.top,
    renderScroll.delta,
    height,
    SCROLL_LEAD_STEPS,
    height * MAX_SCROLL_LEAD_VIEWPORTS,
  );
  // The run of mounted rows the reader sees.
  const view = visibleLayoutRange(layout, renderScroll.top, height);
  const range = ahead.find((each) => each.first <= view.first && view.first < each.last) ?? view;
  // The rows a viewport either side of where the reader was also mount, in a deferred render
  // between frames: a scroll then finds the rows it brings in already drawn and measured instead
  // of building them in its own frame. A jump past them mounts only what it shows.
  const warmTop = useDeferredValue(renderScroll.top);
  const warm = visibleLayoutRange(layout, warmTop - height * WARM_VIEWPORTS, height * (1 + 2 * WARM_VIEWPORTS));
  const mountedRanges = mergeRowRanges(warm.last < range.first || warm.first > range.last ? ahead : [...ahead, warm]);
  if (lastPlaced.current) {
    lastPlaced.current.first = mountedRanges[0]?.first ?? 0;
    lastPlaced.current.last = mountedRanges.at(-1)?.last ?? 0;
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
        (mounted.querySelector<HTMLButtonElement>(".acpmux-row__copy") ?? mounted).focus();
        pendingFocus.current = undefined;
        return;
      }
      const top = layout.tops[nextIndex] ?? 0;
      const maximum = Math.max(0, layout.totalHeight - node.clientHeight);
      const nextTop = Math.max(0, Math.min(maximum, top));
      const delta = nextTop - node.scrollTop;
      node.scrollTop = nextTop;
      setScroll((current) => ({ top: nextTop, delta: delta || nextTop - current.top }));
    },
    [layout, rows],
  );
  useLayoutEffect(() => {
    const id = pendingFocus.current;
    if (!id) return;
    const node = ref.current;
    const target = [...(node?.querySelectorAll<HTMLElement>(".acpmux-row") ?? [])].find(
      (row) => row.dataset.rowId === id,
    );
    if (target) {
      (target.querySelector<HTMLButtonElement>(".acpmux-row__copy") ?? target).focus();
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
  const activeVisible = rows.slice(range.first, range.last).some((row) => row.id === effectiveActiveRowId);
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
      // A single VirtualTranscript is reused while the selected chat changes. Discard every
      // scroll anchor from the old session before the placement pass chooses the new session's
      // openAt position or latest row.
      previousSession.current = sessionId;
      didOpenAtLatest.current = false;
      endSeek();
      setSeeking(false);
      setSeekExpired(false);
      previousLayout.current = null;
      previousRows.current = rows;
      scrolledTo.current = { top: 0, atLatest: false };
      seenAnchor.current = undefined;
      clearTimeout(settle.current);
      settle.current = undefined;
      setScroll({ top: 0, delta: 0 });
      follow(true);
    }
    const old = switched ? null : previousLayout.current;
    const oldRows = previousRows.current;
    const node = ref.current;
    const rewrapped = width !== previousViewport.current.width;
    const resized = rewrapped || height !== previousViewport.current.height;
    if (rewrapped) reflowing.current = true;
    else if (rows.length !== oldRows.length || rows.some((row, index) => row !== oldRows[index]))
      reflowing.current = false;
    if (old && node) {
      // Content that shrank under the viewport has already clamped the live offset to
      // the new end; the offset recorded before this commit is where the reader was.
      // A clamp lands exactly on the scroller's own end, which rounds the layout's
      // fractional height, so compare with that rather than allow for the rounding.
      const live = node.scrollTop;
      const clamped = live < scrolledTo.current.top - 0.5 && live >= node.scrollHeight - node.clientHeight - 0.5;
      // An offset that has not moved since it was recorded was at the latest row if it was
      // then; a shorter viewport alone would otherwise read as scrolled up.
      const unmoved = Math.abs(live - scrolledTo.current.top) <= 0.5;
      const top = clamped ? scrolledTo.current.top : live;
      const atLatest = followingRef.current
        ? true
        : clamped || unmoved
          ? scrolledTo.current.atLatest
          : top >= old.totalHeight - node.clientHeight - 1 ||
            (scrolledTo.current.atLatest && strayFrom(top, old.totalHeight - node.clientHeight));
      // At the latest row also at offset 0: a new chat's first pass can overshoot on estimated
      // heights and settle back to fit, and its reply must still be followed once it overflows
      // (cx-ubd1y). Away from it, at the first row nothing above can move it.
      if (didOpenAtLatest.current && atLatest) {
        // At the latest row: stay there as rows settle to their drawn heights.
        const latest = Math.max(0, layout.totalHeight - node.clientHeight);
        const step = latest - node.scrollTop;
        if (Math.abs(step) > 0.5) {
          node.scrollTop = latest;
          followTrace.set(latest);
        }
        // Growth glides in instead of stepping a line per frame (acp-streaming.md "Scroll"); a
        // resized viewport only moves the offset. A row that grew is placed by its estimate, then
        // again by its drawn height, both before the frame paints: each step glides, and the
        // glides add up, so the text moves by what it grew. Gliding only the first step drew the
        // text an estimate's error too low, then slid it past its place, at every token.
        // A resize (a window edge dragged, cx-sqj3h) reflows the rows in the same way, estimate
        // then drawn height, at every frame of the drag: none of that glides, and a glide in
        // flight ends, so the text sits at the end of the view on every frame.
        if (rewrapped) for (const animation of thread.current?.getAnimations?.() ?? []) animation.finish();
        if (Math.abs(step) > 0.5 && Math.abs(step) < node.clientHeight && !resized && !reflowing.current)
          glide(thread.current, step);
      } else if (top > 0 || rows[0]?.id !== oldRows[0]?.id) {
        // Keep the row at the top of the viewport where it is as rows above it change height.
        // Rows that arrived or left (a new reply segment below, older history above) move indexes,
        // so the row is found again by its id; at offset 0 too, when older history arrived above.
        // A row older history completed (a turn cut at the page's edge) has a new id: the next row
        // that kept its own anchors instead.
        const first = visibleLayoutRange(old, top, 0, 0).first;
        for (let anchor = first; anchor < Math.min(oldRows.length, first + 32); anchor++) {
          const id = oldRows[anchor].id;
          const now = rows[anchor]?.id === id ? anchor : rows.findIndex((row) => row.id === id);
          if (now < 0) continue;
          const delta = layout.tops[now] - old.tops[anchor];
          if (clamped || Math.abs(delta) > 0.5) node.scrollTop = top + delta;
          break;
        }
      }
    }
    // Runs on height too: rows that fit and then overflow on a height-only shrink keep the same memoized layout.
    if (!didOpenAtLatest.current && node) {
      const latest = Math.max(0, layout.totalHeight - node.clientHeight);
      // A chat reopened where the reader left it (cx-6bgzj), else at the latest message.
      const at = openAt ? rows.findIndex((row) => row.id === openAt.rowId) : -1;
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
      } else if (layout.totalHeight <= node.clientHeight) {
        // A tail that fits shows from the top, as before; it opens once it overflows.
        endSeek();
        setSeeking(false);
      } else {
        const top = at < 0 ? latest : Math.min(latest, layout.tops[at] + openAt!.offset);
        node.scrollTop = top;
        followTrace.set(top);
        setScroll({ top, delta: 0 });
        follow(top >= latest - 1);
        didOpenAtLatest.current = true;
        endSeek();
        setSeeking(false);
      }
    }
    previousLayout.current = layout;
    previousRows.current = rows;
    previousViewport.current = { height, width };
    if (node && node.clientHeight > 0 && didOpenAtLatest.current) {
      scrolledTo.current = scrollPosition(node, layout.totalHeight);
      seenAnchor.current = restingAnchor(node.scrollTop, scrolledTo.current.atLatest, layout, rows);
    }
    followTrace.update(node, layout.totalHeight, scrolledTo.current.atLatest);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- openAt is read once, at the first open
  }, [layout, rows, range.first, height, width, sessionId, seekExpired, canLoadOlder]);
  // Commit before this frame paints; deferring to the next animation frame left the edge blank.
  // The page picks adaptive rendering; the host supplies the display interval and applies it.
  const renderRate = useMemo(() => new AdaptiveRenderRate(), []);
  const pacing = useMemo(
    () => new ScrollPacing((intervals) => void reportScrollPacing(intervals, callNative, renderRate)),
    [renderRate],
  );
  useEffect(() => () => pacing.stop(), [pacing]);
  // Find in Chat: a new current match scrolls its row in (it may not be mounted), then, once its
  // text is drawn, the match itself; every commit repaints the highlights over the mounted rows.
  const findQuery = find?.open ? find.query : "";
  const findTarget = find?.matches[find.active];
  // Find matches the chat's rows; the transcript draws a match's row (or its copy in an open fold)
  // once its fold is open.
  const findIndex = findTarget ? findRowIndex(rows, findTarget.rowId) : -1;
  const drawnId = rows[findIndex]?.id;
  const drawnCard = Boolean(rows[findIndex]?.ended);
  const revealing = useRef<string | undefined>(undefined);
  const targetKey =
    findTarget && findQuery && drawnId !== undefined
      ? `${drawnId}:${drawnCard}:${findTarget.occurrence}:${findQuery}`
      : undefined;
  // A group or call that opens to show the match asks for a render here, so the highlights and
  // the scroll below see its text.
  const [, setRevealed] = useState(0);
  // Keyed on what it names, not the match object, which is new on each update while Find is open:
  // a new value would open again every group a reader closed.
  const findReveal = useMemo(
    () =>
      drawnId !== undefined && findQuery
        ? {
            rowId: drawnId,
            card: drawnCard,
            needle: findQuery.toLocaleLowerCase(),
            repaint: () => setRevealed((count) => count + 1),
          }
        : undefined,
    [drawnId, drawnCard, findQuery],
  );
  // The current match's reveal window: 0 until it starts, then the window's own number.
  const revealWindow = useRef(0);
  const revealWindows = useRef(0);
  useLayoutEffect(() => {
    revealing.current = targetKey;
    revealWindow.current = 0;
    const node = ref.current;
    if (!node || !findTarget || !targetKey) return;
    const top = layout.tops[findIndex];
    const bottom = top + layout.heights[findIndex];
    if (top >= node.scrollTop && bottom <= node.scrollTop + node.clientHeight) return;
    node.scrollTop = Math.max(0, top - node.clientHeight / 3);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only a new target scrolls, not a layout change
  }, [targetKey]);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    if (!findQuery) return clearFindHighlights();
    const current = paintFindHighlights(
      node,
      findQuery,
      findTarget && drawnId !== undefined
        ? { rowId: drawnId, card: drawnCard, occurrence: findTarget.occurrence }
        : undefined,
    );
    if (!current || revealing.current !== targetKey) return;
    // A match in a closed group is drawn before the group opens (with no size), and it moves as the
    // opened parts and the rows above it measure, so it is kept in view for a moment once drawn.
    if (!revealWindow.current) {
      const opened = (revealWindow.current = ++revealWindows.current);
      const start = performance.now();
      let frames = 0;
      const tick = () => {
        if (revealWindow.current !== opened) return;
        const elapsed = performance.now() - start;
        if (++frames >= FIND_REVEAL_FRAMES && elapsed >= FIND_REVEAL_MS) revealing.current = undefined;
        else requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    }
    if (current.getBoundingClientRect().height === 0) return;
    // Inner scrollers first (a command's output scrolls on its own), then the transcript.
    for (let box = current.startContainer.parentElement; box && box !== node; box = box.parentElement)
      if (box.scrollHeight > box.clientHeight && /auto|scroll/.test(getComputedStyle(box).overflowY))
        scrollRangeIn(box, current);
    scrollRangeIn(node, current);
  });
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
  const reportAnchor = () => {
    const node = ref.current;
    // Before the chat opens its offset is not the reader's: the kept place stays.
    if (!node || !onAnchor || !didOpenAtLatest.current) return;
    // A hidden pane (Home shown in its place) has no viewport: nothing it reads is where the reader is.
    anchorDeferred.current = node.clientHeight === 0;
    if (anchorDeferred.current) return;
    const { layout: placed, rows: shown } = latestLayout.current;
    const index = visibleLayoutRange(placed, node.scrollTop, 0, 0).first;
    const row = shown[index];
    const anchor: ScrollAnchor | null =
      scrolledTo.current.atLatest || !row ? null : { rowId: row.id, offset: node.scrollTop - placed.tops[index] };
    const key = JSON.stringify(anchor);
    if (key === reportedAnchor.current) return;
    reportedAnchor.current = key;
    onAnchor(anchor);
  };
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
  const onScroll = (event: React.UIEvent<HTMLDivElement>) => {
    pacing.scrolled();
    // Before the chat opens its offset moves only as pages land unseen: none of it is the reader's.
    if (!didOpenAtLatest.current) return;
    // A hidden scroller has no height, so every offset would read as scrolled up (cx-t0zqt): the view
    // keeps following until the reader scrolls a visible one.
    if (event.currentTarget.clientHeight === 0) return;
    const node = event.currentTarget;
    const next = node.scrollTop;
    const programmatic = performance.now() - readerAt.current > READER_SCROLL_MS;
    // ResizeObserver/layout work can emit a scroll event after the stack below the transcript
    // changes. While the reader is following, keep the viewport at the new end and do not let
    // that synthetic event clear the follow state. A real wheel/touch/key event marks itself first.
    // A layout-driven scroll keeps the previous offset; a reader scroll changes it. The latter is
    // also what the jsdom behavior tests dispatch without a wheel event, so do not classify every
    // programmatic-looking event as layout work.
    const layoutDriven = followingRef.current && programmatic && Math.abs(next - scrolledTo.current.top) <= 0.5;
    if (layoutDriven) {
      const latest = Math.max(0, layout.totalHeight - node.clientHeight);
      if (Math.abs(next - latest) > 0.5) node.scrollTop = latest;
      scrolledTo.current = { top: latest, atLatest: true };
      followTrace.set(latest);
      follow(true);
      setScroll((current) => ({ top: latest, delta: latest - current.top }));
      return;
    }
    const was = scrolledTo.current;
    scrolledTo.current = scrollPosition(node, layout.totalHeight);
    const latest = Math.max(0, layout.totalHeight - node.clientHeight);
    if (was.atLatest && !scrolledTo.current.atLatest && strayFrom(next, latest)) {
      // Not the reader's scroll: the view keeps following the reply.
      scrolledTo.current = { top: latest, atLatest: true };
      seenAnchor.current = null;
      node.scrollTop = latest;
      followTrace.set(latest);
      return;
    }
    if (was.atLatest && !scrolledTo.current.atLatest)
      followTrace.stopped({
        top: next,
        previous: was.top,
        latest,
        scrollHeight: node.scrollHeight,
        clientHeight: node.clientHeight,
      });
    followTrace.update(node, layout.totalHeight, scrolledTo.current.atLatest);
    seenAnchor.current = restingAnchor(next, scrolledTo.current.atLatest, layout, rows);
    acpmuxPerf.timed("flush.scroll", () =>
      flushSync(() => {
        setScroll((current) => ({ top: next, delta: next - current.top }));
        follow(scrolledTo.current.atLatest);
      }),
    );
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
    follow(true);
    if (focused) focusComposer?.();
    const reduce = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    const target = Math.max(0, layout.totalHeight - node.clientHeight);
    node.scrollTo({ top: target, behavior: reduce ? "auto" : "smooth" });
    // The landing: whether the smooth scroll arrived, was cut short as rows above settled, or the
    // reply grew past it. Only the reader's own scroll meanwhile cancels it.
    clearTimeout(settle.current);
    settle.current = setTimeout(() => {
      settle.current = undefined;
      const scroller = ref.current;
      if (scroller) scroller.scrollTop = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
    }, JUMP_LATEST_SETTLE_MS);
  };
  useEffect(() => {
    const node = ref.current;
    const reader = () => {
      readerAt.current = performance.now();
      followTrace.input();
      clearTimeout(settle.current);
      settle.current = undefined;
    };
    const inputs = ["wheel", "pointerdown", "touchstart", "keydown"] as const;
    for (const name of inputs) node?.addEventListener(name, reader, { passive: true });
    return () => {
      clearTimeout(settle.current);
      for (const name of inputs) node?.removeEventListener(name, reader);
    };
  }, []);
  // A turn's footer (TurnFooter) shows for the last turn, and for the turn the reader points at:
  // anywhere from its prompt to its footer. Marked on the mounted rows, so a hover renders nothing.
  let lastTurnId: string | undefined;
  for (let index = rows.length - 1; index >= 0 && !lastTurnId; index -= 1)
    if (rows[index]!.kind === "turnSummary") lastTurnId = rows[index]!.id;
  const markTurns = () => {
    for (const node of thread.current?.querySelectorAll<HTMLElement>(".acpmux-row") ?? []) {
      node.toggleAttribute("data-last-turn", node.dataset.rowId === lastTurnId);
      node.toggleAttribute("data-turn-revealed", node.dataset.rowId === pointedTurn.current);
    }
  };
  useLayoutEffect(markTurns);
  // Older history pages in before the reader reaches it: whenever the view is within two viewports
  // of the first loaded row, including a tail too short to fill them. The anchoring above keeps the
  // reader's row in place as each page lands.
  useEffect(() => {
    const node = ref.current;
    if (!canLoadOlder || !onLoadOlder || !node || node.clientHeight === 0) return;
    if (node.scrollTop < node.clientHeight * 2) onLoadOlder().catch(() => {});
  });
  const pointAt = (target: EventTarget | null) => {
    const row = target instanceof Element ? target.closest<HTMLElement>(".acpmux-row") : null;
    const from = row ? Number(row.getAttribute("aria-posinset")) - 1 : -1;
    let footer: string | undefined;
    for (let index = from; index >= 0 && index < rows.length && !footer; index += 1) {
      if (index > from && rows[index]!.kind === "user") break;
      if (rows[index]!.kind === "turnSummary") footer = rows[index]!.id;
    }
    if (footer === pointedTurn.current) return;
    pointedTurn.current = footer;
    markTurns();
  };
  const behind = !seeking && !renderFollowing && layout.totalHeight - height - renderScroll.top > JUMP_LATEST_DISTANCE;
  if (renderStart > 0) acpmuxPerf.span("vt.body", performance.now() - renderStart);
  return (
    <>
      <div
        ref={ref}
        className="acpmux-scroll"
        role="feed"
        aria-label={t("transcript.label")}
        onScroll={onScroll}
        // Soft edges (conversation.css): the top once scrolled from the start, the bottom while more
        // lies below. A followed reply has nothing below it, even while its growth outruns the offset.
        data-seeking={seeking || undefined}
        aria-busy={seeking || undefined}
        data-fade-top={renderScroll.top > 0.5 || undefined}
        data-fade-bottom={(!renderFollowing && layout.totalHeight - renderScroll.top - height > 0.5) || undefined}
      >
        <ThreadMinimap
          rows={rows}
          sessionId={sessionId}
          layout={layout}
          scroller={ref}
          scrollTop={renderScroll.top}
          viewportHeight={height}
          width={width}
        />
        {find?.open && <ChatFindBar find={find} />}
        <FindReveal.Provider value={findReveal}>
          <div className="acpmux-spacer" style={{ height: layout.totalHeight }}>
            <div
              ref={thread}
              className="acpmux-thread"
              onPointerOver={(event) => pointAt(event.target)}
              onPointerLeave={() => pointAt(null)}
            >
              {mountedRanges.flatMap(({ first, last }) =>
                rows.slice(first, last).map((row, index) => {
                  const absoluteIndex = first + index;
                  const kind = rowKind(row);
                  const Component = registry[kind] ?? NoticeRow;
                  const isExpanded = expanded.has(row.id);
                  const controls =
                    row.kind === WORKED && isExpanded ? disclosureControls(rows, absoluteIndex + 1) : undefined;
                  return (
                    <MemoRowFrame
                      key={`${sessionId ?? ""}:${row.id}`}
                      row={row}
                      kind={kind}
                      joinsPrevious={isStepRow(row) && isStepRow(rows[absoluteIndex - 1])}
                      joinsNext={isStepRow(row) && isStepRow(rows[absoluteIndex + 1])}
                      index={absoluteIndex}
                      setSize={canLoadOlder ? -1 : rows.length}
                      top={layout.tops[absoluteIndex]}
                      rowWidth={transcriptRowWidth(width)}
                      expanded={isExpanded}
                      observer={observer}
                      report={reportDrawn}
                      enter={enteringRows.current.has(row.id)}
                      onEntered={onEntered}
                      active={effectiveActiveRowId === row.id}
                      selected={selectedRows.has(absoluteIndex)}
                      tabStop={tabStopId === row.id}
                      onFocus={() => rowFocus(row.id)}
                      onRowKeyDown={(event) => rowKeyDown(absoluteIndex, event)}
                      copyable={transcriptHasFloatingCopy(row)}
                      onCopy={() =>
                        copyRows(
                          selectedRows.has(absoluteIndex) && selectedRowIds.length > 0 ? selectedRowIds : [row.id],
                        )
                      }
                      copySelectionKey={selectedRowIds.join("\u0000")}
                    >
                      <Component
                        row={row}
                        onToggleActivity={onToggleActivity}
                        onOpenDiff={onOpenDiff}
                        expanded={isExpanded}
                        controls={controls}
                        githubRepository={githubRepository}
                      />
                    </MemoRowFrame>
                  );
                }),
              )}
            </div>
          </div>
        </FindReveal.Provider>
      </div>
      {jumpButton && <JumpToLatest shown={behind} working={working} onJump={jumpToLatest} />}
    </>
  );
}

/// Answers `permission` with the option a button or key picked.
const answerPermission = (permission: AcpmuxPermission) => (optionId: string) =>
  void callNative("chat.permission", { permissionId: permission.permissionId, optionId });

/// Sends a question card's reply: the harness's option (absent cancels) and its answers.
const replyToQuestion = (permission: AcpmuxPermission) => (sent: QuestionReply) =>
  void callNative("chat.permission", {
    permissionId: permission.permissionId,
    ...(sent.optionId === undefined ? {} : { optionId: sent.optionId }),
    ...(sent.answers === undefined ? {} : { answers: sent.answers }),
  });

/// Answers a secret card in the page (`chat.secret`): the value goes to acpmux only.
const answerSecret = (ask: AcpmuxSecretAsk) => (value?: string) =>
  void callNative("chat.secret", { secretId: ask.secretId, ...(value ? { value } : {}) }).catch(() => undefined);

/// A permission ask: a question card when the request asks a question, else its option buttons.
function PermissionAsk({
  permission,
  harness,
  focusComposer,
}: {
  permission: AcpmuxPermission;
  harness?: string;
  focusComposer?: () => void;
}) {
  return permission.question ? (
    <QuestionCard question={permission.question} onReply={replyToQuestion(permission)} />
  ) : (
    <PermissionCard
      permission={permission}
      harness={harness}
      focusComposer={focusComposer}
      onAnswer={answerPermission(permission)}
    />
  );
}

/// The composer chips on the New Tab page (cx-e2aa): no chat exists yet, so a pick starts a deferred
/// switch to the shown agent in the page's project (`chat.new {deferred}`): acpmux starts the session
/// behind the page, which stays, and the pick lands on it (harnessSwitch keeps picks made while a
/// switch runs). Enter asks the same agent in the same folder, the same switch, which then shows.
export function NewTabComposerChips({ snapshot, cwd }: { snapshot: AcpmuxSnapshot; cwd?: string }) {
  return <DefaultComposerChips snapshot={snapshot} cwd={cwd} startsChat />;
}

/// The host closes a New Tab page (`AgentPaneView.discardUnsentChat`).
const NEW_TAB_CLOSE_EVENT = "acpmux-newtab-close";

function DefaultComposerChips({
  snapshot,
  cwd,
  permissionAccess,
  startsChat = false,
}: {
  snapshot: AcpmuxSnapshot;
  /// The folder a chat the chips start opens in (the New Tab page's project).
  cwd?: string;
  permissionAccess?: ComposerPermissionAccess;
  /// The chips belong to a page with no chat yet: a model, mode or effort pick starts one first.
  startsChat?: boolean;
}) {
  const inFolder = startsChat ? { ...(cwd ? { cwd } : {}), deferred: true } : {};
  const addAgent = useHarnessesPage();
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
    { harness: snapshot.summary?.harness, configOptions: snapshot.summary?.configOptions },
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
      permissionAccess={permissionAccess}
      onModel={(modelId) => {
        start();
        void callNative("chat.model", { modelId });
      }}
      onMode={(modeId) => {
        start();
        void callNative("chat.mode", { modeId });
      }}
      onEffort={(configId, value) => {
        start();
        void callNative("chat.effort", { configId, value });
      }}
      onHarness={(harness, model) => void callNative("chat.new", { harness, ...(model ? { model } : {}), ...inFolder })}
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

function AcpmuxPane() {
  // Debug measurement (acpmuxPerf): the pane's own render, before its children.
  const paneRenderStart = acpmuxPerf.enabled ? performance.now() : 0;
  const t = useT();
  /// What a chat opened from another tab inherited (#16620); the composer starts with it.
  const [draft, setDraft] = useState<string | undefined>();
  const [newSession, setNewSession] = useState(false);
  /// The chat whose recorded history plays back read-only in place of it (chat menu Replay, cx-osmw).
  const [replaying, setReplaying] = useState<string | undefined>();
  // The side question (`/btw`) shown above the composer, for the chat it was asked about.
  const [aside, setAside] = useState<SideQuestionState & { sessionId: string; ask: number }>();
  const asideAsks = useRef(0);
  // The host answered the handshake: the page shows what it is (a new chat's hero, a session).
  const [handshaken, setHandshaken] = useState(false);
  const handshakenRef = useRef(false);
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
    onAsk: (...args) => whenHandshaken(() => actions.onAsk(...args)),
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
    error?: string;
  }>();
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
  const [scrollAnchor, setScrollAnchor] = useState<(ScrollAnchor & { sessionId: string }) | undefined>();
  const [githubRepository, setGithubRepository] = useState<string | undefined>();
  /// What the direct client (or the host) last reported; `snapshot` draws a pending harness or
  /// model switch over it (harnessSwitch.ts).
  const [clientSnapshot, setSnapshot] = useState<AcpmuxSnapshot>(cachedSnapshot);
  const [harnessSwitch] = useState(() => new HarnessSwitch());
  const switchView = useSyncExternalStore(harnessSwitch.subscribe, harnessSwitch.view, harnessSwitch.view);
  const queryClient = useQueryClient();
  // The pane keeps the last client's catalog until the next client's arrives;
  // ids only grow, so a new client never reads an older client's cache entry.
  const catalogClientId = useRef(0);
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
  // Another chat ends the replay: coming back to this one opens it live.
  if (replaying && snapshot.sessionId !== replaying) setReplaying(undefined);
  // A side question belongs to its chat: another chat drops it.
  if (aside && snapshot.sessionId !== aside.sessionId) setAside(undefined);
  // The side preview panel (cx-ncc.63) shows a document from the open chat; another chat closes it.
  // Each open is its own panel (`opened`), which starts on its preview.
  const [artifact, setArtifact] = useState<Artifact & { sessionId?: string; opened: number }>();
  if (artifact && snapshot.sessionId !== artifact.sessionId) setArtifact(undefined);
  const artifactSession = snapshot.sessionId;
  // Its versions (cx-ncc.64): the chat's finished replies' documents of its kind and title.
  const artifactRows = artifact ? snapshot.rows : undefined;
  const artifactVersionList = useMemo(
    () =>
      artifact && artifactRows
        ? artifactVersions(
            artifactRows.flatMap((row) => (row.kind === "assistant" && !row.streaming && row.text ? [row.text] : [])),
            artifact,
          )
        : undefined,
    [artifact, artifactRows],
  );
  const openArtifact = useCallback(
    (next: Artifact) =>
      setArtifact((current) => ({ ...next, sessionId: artifactSession, opened: (current?.opened ?? 0) + 1 })),
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
    let current = true;
    void callNative<{ repository?: unknown }>("git.githubRepository", { cwd })
      .then((value) => {
        if (!current) return;
        setGithubRepository(typeof value?.repository === "string" && value.repository ? value.repository : undefined);
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
      ? { cwd: snapshot.summary.cwd, sessionId: snapshot.sessionId, hostKind: snapshot.summary.hostKind }
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
  const stopContinuing = useCallback(() => setContinuing(false), []);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  /// The subagent whose own view the transcript shows (its line in a group opens it), or none.
  const [subagentView, setSubagentView] = useState<string>();
  /// The subagent this pane was opened on (a `subagent:` reveal, subagents/subagentPanes.ts), shown
  /// once its chat is; such a pane shows the chat's other subagents in place, never in more panes.
  const [requestedSubagent, setRequestedSubagent] = useState<string>();
  const subagentPane = useRef(false);
  const reveal = (value: string) => {
    const agent = revealedSubagent(value);
    if (agent === undefined) return void revealTurnWhenShown(value);
    subagentPane.current = true;
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
  const editSeqs = editableTurns(forkable ? snapshot.rows : [], snapshot.summary?.family);
  const editSeqsKey = editableKey(editSeqs);
  const stableEditSeqs = useMemo(() => editableSeqs(editSeqsKey), [editSeqsKey]);
  // The chat's agent CLI health (cx-ny85), from this Mac's acpmux on the pane's own connection
  // (cx-jlzsf); a chat on another machine or in the cloud gets none (its CLI is not this Mac's).
  const [harnessHealth, setHarnessHealth] = useState<HarnessHealth>();
  const healthHarness = snapshot.summary?.harness;
  const healthLocal = !snapshot.summary?.peer && snapshot.summary?.hostKind !== "cloud";
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
    if (!connected || !healthHarness || !healthLocal) {
      setHarnessHealth(undefined);
      return;
    }
    let live = true;
    // Only the fetch a recheck started asks acpmux to check again.
    const refresh = healthRecheck !== healthRechecked.current;
    healthRechecked.current = healthRecheck;
    void readHarnessHealth({ id: healthHarness, ...(refresh ? { refresh: true } : {}) })
      .then((reply) => live && setHarnessHealth(reply.health ?? undefined))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [connected, healthHarness, healthLocal, healthRecheck, readHarnessHealth]);
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
  const signIn = useMemo<SignIn>(
    () => ({
      signedOut,
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
    [signedOut, snapshot.summary?.cwd],
  );
  const loginCommand = chatLoginCommand(catalog, snapshot.summary?.harness, harnessHealth);
  // A new chat centers its composer under the hero.
  const handoff = snapshot.handoff?.record;
  const reviewing =
    !!handoff &&
    handoff.target.sessionId === snapshot.sessionId &&
    ["draft", "starting"].includes(handoff.state) &&
    !snapshot.handoff?.receipt;
  const handoffLoading = !!snapshot.sessionId && !!snapshot.canHandoff && !snapshot.handoff?.ready;
  const freshChat = !reviewing && !handoffLoading && isNewChat(snapshot, newSession);
  /// The chat's start folder (startFolder.tsx): the host's folder for a new chat or the user's
  /// pick, for every start of this new chat (the agent row, a harness pick, the first Send).
  /// Undefined: the host fills the chat's folder (the workspace's agent-home folder).
  const startFolder = freshChat && !snapshot.sessionId ? projectDraft : undefined;
  const startFolderRef = useRef(startFolder);
  startFolderRef.current = startFolder;
  /// The folder question, while the chat it was asked for is still the one shown.
  const pendingFolder = folderAsk && folderAsk.sessionId === snapshot.sessionId ? folderAsk : undefined;
  const continueAvailable =
    !!snapshot.canHandoff &&
    !!snapshot.handoff?.ready &&
    !snapshot.isWorking &&
    !snapshot.queue.length &&
    !snapshot.handoff?.busy &&
    !reviewing &&
    continueTargets(catalog, snapshot.summary?.harness).length > 0;
  /// Takes acpmux's trust refusal of a prompt (useFolderTrustAsk.ts): the question shows for the
  /// folder it named, and `again` sends the held prompt after Trust.
  const trustRefused = useRef<((error: unknown, again?: () => void) => boolean) | undefined>(undefined);
  /// Keeps a send's gesture for the prompt acpmux held behind the trust question (heldPrompt.ts).
  const holdPrompt = useRef<(() => void) | undefined>(undefined);
  // A folder without a trust answer is asked about beside the chat's other permission asks as
  // soon as the chat's folder is known (a new chat's chosen one before its first prompt). No
  // prompt goes until the answer is Trust; acpmux refuses one that does (`trust_gate.rs`).
  const lastMarks = useRef<RowMarks | undefined>(undefined);
  const marks = useMemo(() => (lastMarks.current = markRows(snapshot.rows, lastMarks.current)), [snapshot.rows]);
  const promptCount = marks.prompts.length;
  const trustAsk = useFolderTrustAsk(
    trustSource,
    {
      sessionId: snapshot.sessionId,
      cwd: snapshot.summary?.cwd ?? (snapshot.sessionId ? undefined : projectDraft),
      family: snapshot.summary?.family || snapshot.summary?.harness,
      prompts: promptCount,
    },
    snapshot.origin !== "remote" || snapshot.answersTrust === true,
  );
  trustRefused.current = trustAsk.refused;
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
    const shot = await callNative<{ name?: string; mimeType?: string; data?: string; tooLarge?: boolean } | null>(
      "composer.capture",
      { mode },
    ).catch(() => null);
    if (shot?.tooLarge) return { name: shot.name ?? "Screenshot.png", reason: "tooLarge" } as const;
    if (!shot?.data) return undefined;
    const bytes = Uint8Array.from(atob(shot.data), (char) => char.charCodeAt(0));
    return new File([bytes], shot.name ?? "Screenshot.png", { type: shot.mimeType ?? "image/png" });
  }, []);
  const uploadFiles = useCallback((files: File[]) => uploadToMachine(files, callNative), []);
  const searchFiles = useCallback<FileSearchSource>(
    (query) => callNative("file.search", { ...(fileRoot ? { path: fileRoot } : {}), query, limit: FILE_SEARCH_LIMIT }),
    [fileRoot],
  );
  const chatShellRuns = useMemo(
    () => allShellRuns.filter((run) => run.sessionId === snapshot.sessionId),
    [allShellRuns, snapshot.sessionId],
  );
  /// A fresh chat shows its empty state until something is in it: a prompt, or a command it ran.
  const freshView = freshChat && chatShellRuns.length === 0;
  // Turn shape: work folds under "Worked for" until opened; shell mode's blocks sit where they ran.
  const chatName = snapshot.summary?.title || snapshot.summary?.name || "";
  const childRows = useMemo(
    () =>
      subagentView ? childView(subagentView, snapshot.rows, snapshot.subagentViews, expanded, chatName) : undefined,
    [subagentView, snapshot.rows, snapshot.subagentViews, expanded, chatName],
  );
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
    return rows;
  }, [snapshot.rows, snapshot.permissionGroups, individualPermission]);
  // A call the permission panel asks about is drawn by the panel's row while it waits
  // (withoutAskedCalls); with the panel hidden behind folder trust, it stays in the transcript.
  const trustBlocked = Boolean(trustAsk.blocked);
  const panelAsks = useMemo(
    () => (trustBlocked ? new Set<string>() : groupAskedCalls(snapshot.permissionGroups)),
    [trustBlocked, snapshot.permissionGroups],
  );
  // Codex-style tool runs in a running turn (Debug toggle, codexToolRuns.ts).
  const codexRuns = useCodexToolRuns();
  // The last snapshot's turns and subagent rows: the next builds on them (turnViewFrom).
  const lastTurns = useRef<{ turns: TurnView; subagents: SubagentRows } | undefined>(undefined);
  const transcriptRows = useMemo(() => {
    if (childRows) return withoutAskedCalls(childRows, panelAsks);
    const rows = sourceRows;
    return acpmuxPerf.timed("app.rows", () => {
      const last = lastTurns.current;
      const turns = turnViewFrom(
        rows,
        expanded,
        { working: snapshot.isWorking, clockOffset: snapshot.clockOffsetMs, liveRuns: codexRuns },
        last?.turns,
      );
      const subagents = subagentRowsFrom(turns.rows, expanded, last?.subagents);
      lastTurns.current = { turns, subagents };
      // After the turns: a live turn's status reads its last row, the call's included.
      return withoutAskedCalls(withShellRows(subagents.rows, chatShellRuns), panelAsks);
    });
  }, [
    childRows,
    sourceRows,
    expanded,
    snapshot.isWorking,
    snapshot.clockOffsetMs,
    codexRuns,
    chatShellRuns,
    panelAsks,
  ]);
  // Another chat never opens on a subagent of this one.
  const shownSessionId = snapshot.sessionId ?? snapshot.summary?.sessionId;
  const hasSubagents = useMemo(() => snapshot.rows.some(isSubagentGroup), [snapshot.rows]);
  // A subagent's pane keeps its own card choice, hidden at first: the chat's pane shows the card.
  const summaryCard = useSummaryCard(
    subagentPane.current && shownSessionId ? `${shownSessionId}#subagent` : shownSessionId,
    hasSubagents && !subagentPane.current,
  );
  useEffect(() => setSubagentView(undefined), [shownSessionId]);
  // After the reset above: a pane opened on a subagent shows it once its chat is shown.
  useEffect(() => {
    if (!requestedSubagent || !shownSessionId) return;
    setSubagentView(requestedSubagent);
    setRequestedSubagent(undefined);
  }, [requestedSubagent, shownSessionId]);
  // Find in Chat over the transcript (ChatFindScope, below the pane); the page actions read it
  // through `findRef`.
  const findRef = useRef<ChatFind | undefined>(undefined);
  const diffFindRef = useRef<DiffFindHandle | undefined>(undefined);
  const openFold = useCallback(
    (fold: string) => setExpanded((current) => (current.has(fold) ? current : new Set(current).add(fold))),
    [],
  );
  const [inspectorOpen, setInspectorOpen] = useState(false);
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
  const toggleInspector = useCallback((open?: boolean) => {
    if (inspectorHiddenSurfaceRef.current) {
      inspectorOpenRef.current = false;
      setInspectorOpen(false);
      return false;
    }
    const next = typeof open === "boolean" ? open : !inspectorOpenRef.current;
    inspectorOpenRef.current = next;
    if (next) {
      setDiffView(undefined);
      inspectorOpener.current ??= document.activeElement instanceof HTMLElement ? document.activeElement : undefined;
    }
    setInspectorOpen(next);
    return next;
  }, []);
  const sessionIdRef = useRef(snapshot.sessionId);
  sessionIdRef.current = snapshot.sessionId;
  /// Opens the chat folder's diff in its own pane right of the chat, as the header's Changes does
  /// (Lawrence 2026-10-13: "when i click diff viewer it opens in new pane to right, not in a split in
  /// same webpage"). False when the host cannot (a remote chat, Quick Chat, the gallery): the turn's
  /// diff then opens in place. Set below, once the header's actions exist.
  const diffBeside = useRef<() => Promise<boolean>>(async () => false);
  // A click does not focus a button in WebKit, so the clicked control is the opener, not the focus.
  const openDiff = useCallback<OpenDiff>((rowId, path, opener) => {
    const clicked = opener ?? (document.activeElement instanceof HTMLElement ? document.activeElement : undefined);
    const inPlace = () => {
      inspectorOpenRef.current = false;
      setInspectorOpen(false);
      setDiffView({ sessionId: sessionIdRef.current, rowId, path, opener: clicked });
    };
    void diffBeside.current().then((opened) => {
      if (!opened) inPlace();
    }, inPlace);
  }, []);
  // An output in the summary opens the changes of the last turn that wrote it, at that file.
  const openOutput = useCallback(
    (path: string) => {
      const row = [...snapshot.rows]
        .reverse()
        .find(
          (candidate) =>
            candidate.kind === "activity" &&
            candidate.items?.some((item) => item.tool?.diffs?.some((change) => change.path === path)),
        );
      if (row) openDiff(row.id, path);
    },
    [snapshot.rows, openDiff],
  );
  // The session side rail (Debug Settings `agent.sessionRail`): its button in the header, the rail beside the chat.
  const sessionRail = useSessionRail({ snapshot, machineName, onOpenOutput: openOutput });
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
  // Retry with another model (cx-ncc.62): the models the composer's picker lists for the chat's
  // harness (user-hidden ones left out, aliases folded, the session's own choices added) that it can
  // run now, kept the same array while they stay the same.
  const pickerSession = useMemo(
    () => ({ harness: snapshot.summary?.harness, configOptions: snapshot.summary?.configOptions }),
    [snapshot.summary?.harness, snapshot.summary?.configOptions],
  );
  const pickerState = usePickerCatalog(snapshot.catalog, pickerSession, snapshot.sessions);
  const pickerCatalog = pickerState.catalog;
  // The first open after a launch: acpmux has not listed its harnesses yet, so none is missing yet.
  const harnessesChecking = useIsFetching({ queryKey: ["acpmux", "harnesses"] }) > 0 && snapshot.catalog.length === 0;
  // Add harness (cx-uj5g8): the Harnesses page, in place of what the pane shows.
  const [harnessesOpen, setHarnessesOpen] = useState(false);
  // Another chat in this pane (the sidebar, a link) shows that chat, not the page.
  useEffect(() => setHarnessesOpen(false), [snapshot.sessionId]);
  // A chat it starts, and a login it runs, go to the chat's folder (a new chat's start folder).
  const harnessFolder = snapshot.summary?.cwd ?? startFolder;
  const retryModelsKey = (
    pickerCatalog.harnesses.find(
      (entry) => entry.acpmuxHarness === snapshot.summary?.harness || entry.id === snapshot.summary?.harness,
    )?.models ?? []
  )
    .filter((model) => !model.unavailable && !isDefaultChoice(model))
    .map((model) => `${model.id}\t${model.name || model.id}`)
    .join("\n");
  const retryModels = useMemo(
    () =>
      retryModelsKey
        ? retryModelsKey.split("\n").map((line) => {
            const [id = "", name = ""] = line.split("\t");
            return { id, name: name || id };
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
  const turnActions = useMemo<TurnActions>(
    () => ({
      ...(stableBranches.size > 0 && {
        branches: {
          of: stableBranches,
          open: (sessionId: string) => void callNative("chat.select", { sessionId }).catch(() => undefined),
        },
      }),
      ...(forkable && {
        fork: (throughSeq: number) => void callNative("chat.fork", { throughSeq }).catch(() => undefined),
        forkSeq,
        forkAny,
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
      ...(connected && {
        retry: (rowId: string, prompt: string) =>
          void (async () =>
            callNative("chat.send", {
              text: prompt,
              attachments: (await directClient.current?.promptAttachments(rowId)) ?? [],
            }))().catch(() => undefined),
      }),
      ...(connected &&
        retryModels.length > 1 && {
          retryWith: {
            models: retryModels,
            current: snapshot.summary?.model,
            retry: (rowId: string, prompt: string, model: string) =>
              void callNative("chat.retryWith", { rowId, prompt, model }).catch(() => undefined),
          },
        }),
      ...(connected &&
        loginCommand &&
        snapshot.summary?.hostKind !== "cloud" && {
          reauthenticate: () =>
            void callNative("tab.open", {
              kind: "terminal",
              text: loginCommand,
              ...(snapshot.summary?.cwd ? { cwd: snapshot.summary.cwd } : {}),
              run: true,
            }).catch(() => undefined),
        }),
      review: hunkReview,
      route: {
        harness: snapshot.summary?.harness,
        name: catalog.find((entry) => entry.id === (snapshot.summary?.harness ?? ""))?.name,
      },
      switchModel: () => void openPicker(translate(PICKER_LABELS.model)),
    }),
    [
      stableBranches,
      forkable,
      forkSeq,
      forkAny,
      stableEditSeqs,
      connected,
      hunkReview,
      loginCommand,
      snapshot.summary?.hostKind,
      snapshot.summary?.cwd,
      snapshot.summary?.harness,
      snapshot.summary?.model,
      retryModels,
      catalog,
    ],
  );
  // Streaming text changes rows on every chunk; only the turn's tool calls change its files.
  const diffActivity = useRef<{ key: string; files: ReturnType<typeof turnFiles> }>(undefined);
  const diffFiles = useMemo(() => {
    if (!diffView || !diffOpen) return undefined;
    const activity = turnRows(snapshot.rows, diffView.rowId).filter((row) => row.kind === "activity");
    const key = `${diffView.rowId}\u0000${activity.map((row) => `${row.id}:${row.version}`).join("|")}`;
    if (diffActivity.current?.key !== key) diffActivity.current = { key, files: turnFiles(activity) };
    return diffActivity.current.files;
  }, [diffView, diffOpen, snapshot.rows]);
  // Each turn's checkpoint pair, named by the row that starts the turn: the checkpoints acpmux
  // recorded on its summary, diffed on the session host.
  const turnRowsRef = useRef(snapshot.rows);
  turnRowsRef.current = snapshot.rows;
  // The image viewer holds the chat's images from when it opened; another chat closes it.
  const [imageView, setImageView] = useState<{ images: ChatImage[]; index: number } | undefined>();
  const openImage = useCallback((src: string, alt: string) => {
    const images = chatImages(turnRowsRef.current);
    const index = images.findIndex((image) => image.src === src);
    setImageView(index < 0 ? { images: [{ src, alt }], index: 0 } : { images, index });
  }, []);
  useEffect(() => setImageView(undefined), [snapshot.sessionId]);
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
  const diffTurnEnded =
    diffView && diffOpen ? turnRows(snapshot.rows, diffView.rowId).some((row) => row.kind === "turnSummary") : false;
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
    return turnDisplay(t, diffFiles, turnCheckpoint(diffTurn) ?? { state: "loading" }, pending);
  }, [diffFiles, diffTurn, hunkDecisions, t, turnCheckpoint]);
  // The latest edited-files card shows its turn's checkpoint counts once the turn has ended.
  const endedEditTurn = endedEditRow(marks);
  useEffect(() => {
    if (endedEditTurn) requestTurnCheckpoint(turnKey(endedEditTurn));
  }, [endedEditTurn, requestTurnCheckpoint, turnKey]);
  const turnCountsFor = useCallback<TurnCountsFor>(
    (rowId, toolFiles) => turnCounts(toolFiles, turnCheckpoint(turnKey(rowId))),
    [turnCheckpoint, turnKey],
  );
  // The header's Changes: the last turn that edited files, with its checkpoint's counts once loaded.
  const lastEdit = useRef<{ key: string; rowId: string; files: TurnFile[] }>(undefined);
  const lastEditTurn = useMemo(() => {
    const rows = snapshot.rows;
    let at = rows.length - 1;
    while (at >= 0 && rowKind(rows[at]!) !== "editedFiles") at -= 1;
    if (at < 0) return undefined;
    const edit = rows[at]!;
    // Its turn: from its prompt to the next one (diff.ts turnRows, from the index found here).
    let start = at;
    while (start > 0 && rows[start]!.kind !== "user") start -= 1;
    let end = at + 1;
    while (end < rows.length && rows[end]!.kind !== "user") end += 1;
    const activity = rows.slice(start, end).filter((row) => row.kind === "activity");
    // Keyed by the chat too: another chat's rows never read as this one's.
    const key = `${snapshot.sessionId}\u0000${edit.id}\u0000${activity.map((row) => `${row.id}:${row.version}`).join("|")}`;
    if (lastEdit.current?.key !== key) lastEdit.current = { key, rowId: edit.id, files: turnFiles(activity) };
    return lastEdit.current;
  }, [snapshot.rows, snapshot.sessionId]);
  // Its files are the diff's own (the checkpoint's once loaded), so each opens at its file there.
  const lastChanges = useMemo(
    () => (lastEditTurn ? turnCountsFor(lastEditTurn.rowId, lastEditTurn.files) : undefined),
    [lastEditTurn, turnCountsFor],
  );
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
    if (path) return lastEditTurn && openDiff(lastEditTurn.rowId, path);
    if (diffView && diffOpen) return closeDiff();
    if (lastEditTurn) openDiff(lastEditTurn.rowId);
  };
  const [registry, setRegistry] = useState<NativeRegistry>(defaultRegistry);
  const [newTab, setNewTab] = useState<NewTabHost | undefined>(injectedNewTabContext);
  // A prewarmed spare page gets its real context when Cmd-T adopts it; the generation remounts the screen.
  const newTabGeneration = useNewTabAdoption(setNewTab);
  useNewTabPlaces(setNewTab);
  const earlyNewTab = useEarlyNewTabContext(callNative, setNewTab);
  // Agent chats live in the window's one sidebar (Projects and Recents); the pane opens what it picks.
  const selectSession = useCallback((sessionId: string) => {
    void callNative("chat.select", { sessionId });
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
  const [shortcuts, setShortcuts] = useState<ShortcutLabels>({});
  const [preview, setPreview] = useState(false);
  /// The Quick Composer panel (`"surface": "quick"` in the host's ready reply) or a tab's pane.
  const [surface, setSurface] = useState<PaneSurface>("pane");
  const quick = surface === "quick";
  /// The header's tools in the pane's tab row, while the App offers one (header/tabRow.ts).
  const tabRow = useTabRow();
  const inTabRow = tabRow.height > 0 && !quick;
  const tabRowTools = useTabRowTools(inTabRow ? tabRow : undefined, reportTabRowTools);
  // Only Claude's agents and workflows stop on their own (acpmux `_acpmux/subagent_stop`).
  const stopsSubagents = snapshot.summary?.harness === "claude";
  const stopSubagent = useMemo(
    () =>
      stopsSubagents
        ? (id: string) => directClient.current?.stopSubagent(id) ?? Promise.reject(new Error())
        : undefined,
    [stopsSubagents],
  );
  /// Shows subagent `id`: in a pane of its own right of the chat (focused with `focus`), or in
  /// this pane when this is a subagent's pane or the host opens none.
  const showSubagent = useCallback((id: string, focus = true) => {
    if (subagentPane.current) return setSubagentView(id);
    void openSubagentPane(callNative, id, focus).then((opened) => {
      if (!opened && focus) setSubagentView(id);
    });
  }, []);
  const [autoOpenSubagents, setAutoOpenSubagents] = useAutoOpenSubagents();
  useOpenNewSubagents(
    quick || subagentPane.current ? undefined : shownSessionId,
    snapshot.rows,
    snapshot.subagentViews,
    autoOpenSubagents,
    (id) => showSubagent(id, false),
    snapshot.clockOffsetMs ?? 0,
  );
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
  // The Quick Composer cannot show the Harnesses page: it registers no opener, so its + hides.
  useEffect(() => (quick ? undefined : registerHarnessesPage(() => setHarnessesOpen(true))), [quick]);
  // `/btw` (cx-ef2m), behind its experiment; the Quick Composer never shows a side question.
  const asksAside = !quick && experimentArm(sideQuestion) === "on";
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
    const next = { pending: true, landed: false, background: { name: quickChatName(text), accepted: false } };
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
  const directClient = useRef<AcpmuxDirectClient | undefined>(undefined);
  /// The composer's prompt, which dictation writes into.
  const prompt = useRef<MarkdownFieldHandle>(null);
  /// The composer itself, which takes back prompts a harness switch held; prompts handed back
  /// while it is not mounted (a handoff review) go in when it mounts.
  const composerHandle = useRef<ComposerHandle | null>(null);
  const heldBack = useRef<{ text: string; attachments: ComposerAttachment[] }[] | undefined>(undefined);
  /// What a released page's composer held (the handshake's `wake`), for the composer once it mounts.
  const pendingWake = useRef<ComposerWake | undefined>(undefined);
  /// Where the shown transcript rests now (VirtualTranscript `anchorNow`).
  const transcriptAnchor = useRef<(() => ScrollAnchor | null | undefined) | undefined>(undefined);
  const composerRef = useCallback((handle: ComposerHandle | null) => {
    composerHandle.current = handle;
    if (handle && pendingWake.current) {
      handle.wake(pendingWake.current);
      pendingWake.current = undefined;
    }
    const waiting = heldBack.current;
    if (!handle || !waiting) return;
    heldBack.current = undefined;
    for (const back of waiting) handle.restore(back.text, back.attachments);
  }, []);
  useComposerKeyboard(() => {
    if (!prompt.current) return false;
    prompt.current.focus();
    return true;
  });
  /// The New Tab page's field, while it shows: dictation writes there then (it has no composer).
  const newTabDictationField = useRef<DictationField | null>(null);
  const dictationTarget = useRef<{ readonly current: DictationField | null }>({
    get current() {
      return newTabDictationField.current ?? prompt.current;
    },
  }).current;
  const dictation = useDictation(dictationTarget, callNative);
  /// Why the host could not hand this pane acpmux (not installed, a daemon that will not start),
  /// in the host's words; cleared once a handshake succeeds.
  const [hostError, setHostError] = useState<string | undefined>();
  /// A Retry the user asked for that waits on the attempt in flight.
  const [retryQueued, setRetryQueued] = useState(false);
  /// Asks the host again now, after the user fixed what `hostError` says.
  const retryHost = useRef<(() => void) | undefined>(undefined);
  // The host covers the pane with its loading state until this document first draws what it is:
  // the handshake's answer, or the host error when there is none (a failed start must show, not
  // stay behind the loading state). The frames before (no hero yet, "Connecting") stay hidden.
  // One animation frame after that render, then a task: the task runs once that frame was drawn.
  // Not two frames: WebKit stops animation frames once the window is occluded, so a second frame
  // may never come although the first one drew (cx-zjtn.6; PagePaintProbe in CmuxNextPages waits
  // the same way).
  const paintReported = useRef(false);
  // A New Tab page is what it is from its first render: its frame draws before the handshake
  // (cx-0rpl.10), and the host shows no loading mark over it.
  const showsWhatItIs = handshaken || hostError !== undefined || newTab !== undefined;
  useEffect(() => {
    if (!showsWhatItIs || paintReported.current) return;
    paintReported.current = true;
    requestAnimationFrame(() =>
      setTimeout(() => {
        void callNative("pane.painted").catch(() => undefined);
        void loadDiffPanel();
        void loadHighlightedCode();
        void loadEditDiffHunks();
      }, 0),
    );
  }, [showsWhatItIs]);
  const composerSnapshot = useMemo(() => {
    const enabledCmuxActions = new Set<CmuxCommand["action"]>(["import"]);
    if (forkable && forkSeq !== undefined) enabledCmuxActions.add("fork");
    if (continueAvailable) enabledCmuxActions.add("continue");
    if (asksAside && snapshot.sessionId) enabledCmuxActions.add("btw");
    const withCommands = { ...snapshot, commands: mergedCommands(snapshot.commands, enabledCmuxActions) };
    return projectDraft && !snapshot.sessionId
      ? { ...withCommands, summary: { sessionId: "", cwd: projectDraft } }
      : withCommands;
  }, [snapshot, projectDraft, continueAvailable, forkable, forkSeq, asksAside]);
  useEffect(() => {
    if (snapshot.sessionId) setProjectDraft(undefined);
  }, [snapshot.sessionId]);
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
  const [worktreeCreating, setWorktreeCreating] = useState(false);
  /// A folder the user picked on this Mac: the host takes it at once or asks first
  /// (startFolder.tsx); `use` runs only with a folder the host took.
  /// Only the latest pick's answer counts (two quick picks can answer out of order).
  const folderPick = useRef(0);
  const shownSession = useRef(snapshot.sessionId);
  shownSession.current = snapshot.sessionId;
  const requestFolder = useCallback((cwd: string, use: (folder: string) => void, cancel?: () => void) => {
    const pick = ++folderPick.current;
    const sessionId = shownSession.current;
    setFolderAsk(undefined);
    setWorktreeCreating(false);
    void pickFolder(callNative, cwd, (folder) => {
      if (pick === folderPick.current) use(folder);
    }).then((ask) => {
      if (ask && pick === folderPick.current) setFolderAsk({ ask, use, cancel, sessionId });
    });
  }, []);
  const freshRef = useRef(false);
  freshRef.current = freshChat && !snapshot.sessionId;
  const chooseProject = useCallback(
    (cwd: string, peer?: string) => {
      // Another computer's folder is that computer's to check.
      if (peer) {
        void callNative("chat.new", { cwd, peer }).catch(() => undefined);
        return;
      }
      // Fresh or started is read when the folder is used (an answer can come later).
      requestFolder(cwd, (folder) => {
        if (freshRef.current) setProjectDraft(folder);
        else void callNative("chat.new", { cwd: folder }).catch(() => undefined);
      });
    },
    [requestFolder],
  );
  /// New Worktree (cx-lyqio.2): the new chat starts in a worktree of its folder, or says why not.
  const [worktreeError, setWorktreeError] = useState<string | undefined>();
  const startInWorktree = useCallback((cwd: string) => {
    // A newer folder pick wins over this worktree, as between two picks.
    const pick = ++folderPick.current;
    const sessionId = shownSession.current;
    setFolderAsk(undefined);
    setWorktreeError(undefined);
    setWorktreeCreating(true);
    const use = (folder: string) => {
      // A chat that started meanwhile keeps its folder: the worktree gets a new chat of its own.
      if (freshRef.current) setProjectDraft(folder);
      else void callNative("chat.new", { cwd: folder }).catch(() => undefined);
    };
    void newWorktree(callNative, cwd, (folder) => {
      if (pick === folderPick.current) use(folder);
    })
      .then(({ ask }) => {
        // The host asks about the worktree's folder first: the question shows as a picked folder's.
        if (ask && pick === folderPick.current) setFolderAsk({ ask, use, sessionId });
      })
      .catch((error: unknown) => {
        if (pick === folderPick.current) setWorktreeError(errorMessage(error) || String(error));
      })
      .finally(() => {
        if (pick === folderPick.current) setWorktreeCreating(false);
      });
  }, []);
  const automationPick = useRef<(cwd: string) => void>(undefined);
  automationPick.current = (cwd) => chooseProject(cwd);
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
      command(name) {
        if (name === "createCheckpoint") showCheckpoint.current();
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
            // Previous Turn and Next Turn (Ctrl-Opt-Up, Ctrl-Opt-Down): the thread minimap steps the transcript.
            "previousTurn",
            "nextTurn",
            // Search Files… (Cmd-P): the composer opens its file search.
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
        try {
          sessionStorage.setItem("cmux.acpmux.snapshot", JSON.stringify(next));
        } catch {
          // Painting remains live when storage is unavailable or full.
        }
        setSnapshot(next);
      },
      applyTheme(theme) {
        applyAgentTheme(theme as never);
        configureChatWidth(theme.chatWidth);
        configureCodexToolRuns(theme.codexToolRuns);
      },
      applyShortcuts(labels) {
        setShortcuts(readShortcuts(labels));
      },
      applyPreview(on) {
        setPreview(on === true);
      },
      applySuggestedTasks(on) {
        if (setSuggestedTasks(on === true)) directClient.current?.suggestedTasksChanged();
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
          window.cmuxAcpmuxRegistry?.configure(customization.layout);
        }
      },
      dictation(update) {
        deliverDictation(update);
      },
    };
    // On the shared page host the host pushes arrive as events once the bridge exists.
    const pageHost = pageHostClient();
    if (pageHost) void startHostEvents(pageHost).catch(() => undefined);
    window.cmuxAcpmuxDebug = createAcpmuxDebug({
      replaceRows(rows) {
        rowsRef.current = rows;
        setSnapshot((current) => ({ ...current, rows, connection: "debug", isWorking: false, canLoadOlder: false }));
      },
      rowCount: () => rowsRef.current.length,
      sessionId: () => directClient.current?.selectedSession,
      automation: {
        snapshot: () => automationView.current!.snapshot,
        call: (method, params) => callNative(method, params),
        selectSession: (sessionId) => automationView.current?.selectSession(sessionId),
        openDiff: (rowId) => automationView.current?.openDiff(rowId),
        diff: () => automationView.current?.diff ?? { open: false, paths: [] },
        pickFolder: (cwd) => automationPick.current?.(cwd),
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
    const RECONNECT_MAX_DELAY_MS = 2_000;
    let reconnect = false;
    let connecting = false;
    /// The user asked to retry while an attempt was in flight; run a full one when it ends.
    let retryPending = false;
    // A seeded first prompt (onboarding's first task). Swift hands it out once, so it is kept
    // here until a connect succeeds: a first connect that fails retries without it.
    let pendingPrompt: string | undefined;
    let pendingTicket: { promptId: string; ticket: string } | undefined;
    // The harness that seeded prompt starts on (`newTab.submit --agent`), kept with it.
    let pendingHarness: string | undefined;
    /// The connected client as the harness switch sees it.
    let switchPort: SwitchPort | undefined;
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
    const restorePrompt = (text: string, attachments: ComposerAttachment[]) => {
      if (composerHandle.current) composerHandle.current.restore(text, attachments);
      else heldBack.current = [...(heldBack.current ?? []), { text, attachments }];
    };
    const connectHost = async () => {
      if (connecting) return;
      connecting = true;
      try {
        acpmuxPerf.markAgent("handshakeStart");
        acpWire.lifecycle("handshake", { reconnect });
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
          githubRepository?: unknown;
          harnesses?: unknown;
        }>("ready", reconnect ? { reconnect } : {});
        if (cancelled) return;
        acpmuxPerf.markAgent("handshakeReady");
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
        setHandshaken(true);
        handshakenRef.current = true;
        // Submits made on the New Tab page before acpmux answered go now, in order.
        for (const run of pendingSubmits.current.splice(0)) run();
        if (
          (host.newSession && !host.sessionId) ||
          (host.sessionId && snapshotRef.current?.sessionId && host.sessionId !== snapshotRef.current.sessionId)
        )
          setSnapshot(emptySnapshot());
        if (!reconnect) setSurface(readSurface(host.surface));
        setMachineName(typeof host.machineName === "string" && host.machineName ? host.machineName : undefined);
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
        // The early context lacks the folder the handshake filled in (seed, start folder): add it.
        else if (!reconnect && typeof host.cwd === "string" && host.cwd)
          setNewTab((current) => (current && !current.cwd ? { ...current, cwd: host.cwd as string } : current));
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
          pendingTicket = { promptId: host.promptTicket.promptId, ticket: host.promptTicket.ticket };
        if (typeof host.harness === "string" && host.harness) pendingHarness = host.harness;
        // Mock mode runs this same client against an in-page daemon.
        const mock = host.transport === "mock";
        // Links copy in this build's scheme; only the hostless mock page falls back to Release's.
        setLinkScheme(host.linkScheme, mock ? FALLBACK_LINK_SCHEME : undefined);
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
          return;
        }
        // A new chat in mock mode starts without a session too, as against a real daemon.
        const mockConfig: AcpmuxHostConfig = host.newSession
          ? { ...mockHost, sessionId: undefined, newSession: true }
          : mockHost;
        const client = await AcpmuxDirectClient.connect(
          mock ? mockConfig : (host as AcpmuxHostConfig),
          (next) => {
            harnessSwitch.reconcile(next);
            rowsRef.current = next.rows;
            snapshotRef.current = next;
            // What each harness reports feeds the next switch's first frame (harnessProfiles.ts).
            const summary = next.summary;
            const started = summary?.model !== undefined && startedSessions.delete(summary.sessionId);
            harnessProfiles.observe(summary, started);
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
            directClient.current = undefined;
            delete window.cmuxAcpmuxActions;
            retryTimer = window.setTimeout(() => void connectHost(), retryDelay);
            retryDelay = Math.min(retryDelay * 2, reconnect ? RECONNECT_MAX_DELAY_MS : 30_000);
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
        directClient.current = client;
        // The minimap's prompt bookmarks live in acpmux's session (threadMinimap/bookmarks.ts).
        setBookmarkTransport({
          get: (id) => client.readBookmarks(id),
          set: (id, seq, on) => client.setBookmark(id, seq, on),
        });
        // Every trust refusal (a new chat, a resumed one, a switch, a prewarm, a prompt) shows the
        // folder's one question above the composer; Trust re-runs the refused step (cx-nn3e).
        client.onTrustRefused = (refusal, again) => {
          trustRefused.current?.(refusal, again);
        };
        // Only a connected client clears the error, so a stale endpoint doesn't flicker it away.
        setHostError(undefined);
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
        /// Opens a chat this one made in a tab of its own (`chat.openTab`); false when the host opens none.
        /// A mode pick on the shown chat. acpmux decides whether it is every new chat's start mode
        /// (hub/start_mode.rs); a pending chat's kept answer follows it at once and then asks
        /// acpmux again (startMode.ts), as older daemons send no `_acpmux/start_mode_changed`.
        const setMode = async (modeId: string, ticket?: string) => {
          await client.setMode(modeId, ticket);
          const shown = snapshotRef.current;
          if (shown?.origin === "remote" || shown?.origin === "peer" || shown?.summary?.host) return;
          if (/^plan$/i.test(modeId)) return startModeChanged();
          const name = shown?.summary?.modes?.availableModes.find((mode) => mode.id === modeId)?.name;
          pickedMode(client.shownSession()?.harness ?? shown?.summary?.harness, modeId, name);
        };
        const openOwnTab = (sessionId: string) =>
          mock
            ? Promise.resolve(false)
            : callNative("chat.openTab", { sessionId }).then(
                () => true,
                () => false,
              );
        /// Settles when the turn ends. `accepted` runs once acpmux took the prompt; a sender that
        /// passes it (the composer) still holds the prompt until then, so a refusal loses nothing.
        /// Without it a refused prompt goes back into the composer.
        const send = async (
          text: string,
          attachments: import("./attachments").ComposerAttachment[] = [],
          accepted?: () => void,
          steer = false,
          promptId?: string,
        ) => {
          // acpmux holds the prompt while the folder's trust question is open (on session/new
          // or session/prompt): the question shows for the folder acpmux named, and Trust sends
          // the prompt the composer kept. `inComposer`: the composer still holds the prompt (or got it back); else it goes back.
          const refused = (error: unknown, inComposer: boolean): never => {
            if (isTrustRefusal(error)) {
              // The send's own gesture is kept for this prompt now, before the Trust click, whose
              // gesture goes to the trust answer (heldPrompt.ts).
              void heldPrompt.hold();
              if (!inComposer) restorePrompt(text, attachments);
              trustRefused.current?.(error, () => composerHandle.current?.send());
            }
            throw error;
          };
          // A harness switch holds the prompt in its own row until its session is ready, and
          // hands it back to the composer when the switch fails.
          const held = harnessSwitch.send(text, attachments, () => promptLanded.current(), promptId);
          if (held) {
            accepted?.();
            return held.catch((error: unknown) =>
              refused(error, (error as { handedBack?: unknown }).handedBack === true),
            );
          }
          // A prompt acpmux held goes with the gesture its first send kept.
          const kept = heldPrompt.take();
          const sessionId = await client.ensureSession().catch((error: unknown) => {
            // A folder harness that waits for Enable or Trust says so on its own card.
            setBlockedHarness(harnessBlock(error));
            // A refused start (a chat on another machine, cx-k21v) says why in this page's own
            // view: the host's typed refusal, already localized, under the localized "Not sent".
            if (isStartRefusal(error)) client.notice(translate("prompt.notSent", { reason: errorMessage(error) }));
            return refused(error, Boolean(accepted));
          });
          await persistSession(sessionId);
          const turn = client
            .send(text, attachments, kept?.promptId, accepted, kept?.ticket, steer)
            .catch((error: unknown) => refused(error, Boolean(accepted)));
          // The prompt is written; a Quick Composer hand-off can close this page now.
          promptLanded.current();
          return turn;
        };
        window.cmuxAcpmuxActions = {
          // `accepted` (in-page only): the composer holds the prompt until acpmux takes it.
          "chat.send": ({ text, attachments, accepted, steer }) =>
            send(
              String(text ?? ""),
              Array.isArray(attachments) ? attachments : [],
              typeof accepted === "function" ? (accepted as () => void) : undefined,
              steer === true,
            ),
          "chat.cancel": () => client.cancel(),
          "chat.queue.remove": ({ promptId }) => client.removeQueued(String(promptId)),
          "chat.queue.edit": ({ promptId, ...edit }) => client.editQueued(String(promptId), edit as QueueEdit),
          "chat.secret": ({ secretId, value }) =>
            client.secret(String(secretId), typeof value === "string" ? value : undefined),
          "chat.permission": ({ permissionId, optionId, answers }) =>
            client.permission(
              String(permissionId),
              optionId === undefined || optionId === null ? undefined : String(optionId),
              answers && typeof answers === "object" ? (answers as Record<string, unknown>) : undefined,
            ),
          "chat.permission_group.respond": ({ groupId, revision, decision }) =>
            client.permissionGroup(String(groupId), Number(revision), decision as PermissionDecision),
          "chat.permission_group.retry": () => client.permissions.retry(),
          "chat.permission_chat.revoke": () => client.permissions.revoke(),
          "chat.permission_groups.refresh": () => client.permissions.refresh(),
          // A model, mode or effort picked while a harness starts waits for its session; a model
          // picked in a live session draws at once (harnessSwitch.ts).
          "chat.model": ({ modelId }) => {
            const summary = snapshotRef.current?.summary;
            return harnessSwitch.pickModel(
              String(modelId),
              summary?.sessionId ? { sessionId: summary.sessionId, model: summary.model } : undefined,
            );
          },
          "chat.mode": async ({ modeId }) => {
            if (!harnessSwitch.pickMode(String(modeId))) await setMode(String(modeId));
          },
          "chat.effort": async ({ configId, value }) => {
            const summary = snapshotRef.current?.summary;
            const current = summary?.configOptions?.find((option) => option.id === String(configId))?.currentValue;
            if (
              !harnessSwitch.pickConfig(
                String(configId),
                String(value),
                summary?.sessionId
                  ? {
                      sessionId: summary.sessionId,
                      current,
                    }
                  : undefined,
              )
            )
              await client.setConfig(String(configId), String(value));
          },
          "chat.select": async ({ sessionId }) => {
            harnessSwitch.cancel();
            return persistSession(await client.select(String(sessionId)));
          },
          // A pick of another harness is a switch: drawn now, started behind it.
          // A new chat without a folder starts in the chat's start folder (startFolder.tsx);
          // a chat with no project (`noProject`) or for a peer gets no start folder.
          "chat.new": async ({ harness, cwd, peer, deferred, noProject, model }) => {
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
              return harnessSwitch.switchTo(String(harness), folder, {
                deferred: deferred === true,
                ...(picked ? { model: picked } : {}),
              });
            }
            harnessSwitch.cancel();
            return persistSession(
              await client.create(
                harness ? String(harness) : undefined,
                folder,
                peer ? String(peer) : undefined,
                noProject === true,
              ),
            );
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
                const refused = error as { code?: unknown; detail?: unknown; reason?: unknown } | null;
                if (typeof refused?.detail === "string") client.notice(refused.detail);
                else if (refused?.reason === "harness.prompt_unavailable")
                  client.notice(translate("harnesses.enableUnavailable"));
                else if (refused?.code !== "transport.harness_not_confirmed")
                  client.notice(errorMessage(error) || String(error));
                return undefined;
              },
            ),
          "chat.harness.cancelPrompt": async ({ promptId }) => harnessSwitch.cancelQueued(String(promptId)),
          "chat.retryPrompt": ({ rowId }) => client.retryPrompt(String(rowId)),
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
            await send(String(prompt ?? ""), await client.promptAttachments(String(rowId ?? "")));
          },
          // Edit and Resend (the message menu): the prompt goes back into the composer, before
          // anything typed since, with the caret in it.
          "chat.editPrompt": async ({ text }) => {
            restorePrompt(String(text ?? ""), []);
            composerHandle.current?.focus();
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
          "chat.adoptLive": async ({ choice }) => {
            await client.adoptLive(choice === "fork" ? "fork" : "open");
            return persistSession(client.adopted);
          },
          // The native context menu's Open Image: the image the page reported under the pointer.
          "chat.menu.openImage": async () => openReportedImage(),
          // Its Open on a path: the path chip's open, which the host checks again (link.openPath).
          "chat.menu.openPath": ({ path }) => callChipHost("link.openPath", { path: String(path ?? "") }),
          // A fork and a started Continue in… open in a tab of their own, so the chat keeps its tab
          // and stays in the sidebar (Leo 2026-10-13). A host that opens none (an older app, the
          // floating chat) gets the new chat in this tab, as before.
          "chat.fork": async ({ throughSeq }) => {
            harnessSwitch.cancel();
            const chat = client.selectedSession;
            const forked = await client.fork(Number(throughSeq), undefined, true);
            if (!forked || (await openOwnTab(forked)) || client.selectedSession !== chat) return forked;
            return persistSession(await client.select(forked));
          },
          // Edit and resend (cx-ncc.60): a fork through the turn before the prompt, which then gets the
          // edited text with the prompt's attachments; the original chat stays as it was.
          "chat.editResend": async ({ rowId, throughSeq, text }) => {
            harnessSwitch.cancel();
            const attachments = await client.promptAttachments(String(rowId ?? ""));
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
            await send(String(text ?? ""), attachments);
            return true;
          },
          "chat.ask": ({ question }) => client.ask(String(question ?? "")),
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
          // Open on a started offer: beside this chat, as a side chat opens; else here.
          "chat.offer.open": async ({ sessionId }) => {
            try {
              await postNative("chat.sideChat", { sessionId: String(sessionId) });
            } catch {
              await persistSession(await client.select(String(sessionId)));
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
            const receipt = await client.startHandoff(review as HandoffReviewInput);
            const source = client.handoff.state.record?.source.sessionId;
            const target = receipt?.targetSessionId;
            if (!target || !source || client.selectedSession !== target) return receipt;
            if (await openOwnTab(target)) {
              if (client.selectedSession === target) await persistSession(await client.select(source));
            } else await persistSession(target);
            return receipt;
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
          "pane.wakeState": async () => {
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
          create: async (harness, cwd) => {
            // After a Trust answer the switch that waited for it runs again, with its prompts
            // (the trust route, direct.ts; harnessSwitch.resumeAfterTrust).
            const again = () => harnessSwitch.resumeAfterTrust();
            const sessionId = await client.startSession(harness, cwd, undefined, again).catch((error: unknown) => {
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
          send: (text, attachments, promptId) => {
            const kept = heldPrompt.take();
            return client.send(
              text,
              attachments,
              promptId,
              undefined,
              kept?.promptId === promptId ? kept.ticket : undefined,
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
        notifyDraftActionsChanged();
        harnessSwitch.setHandlers({
          restore: restorePrompt,
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
        const ticket = pendingTicket;
        pendingPrompt = undefined;
        pendingHarness = undefined;
        pendingTicket = undefined;
        // The seeded prompt goes with its ticket, under the ticket's promptId.
        if (prompt && ticket) heldPrompt.keep(ticket);
        // A chat seeded with an agent starts on it, the prompt queued on the switch; a switch
        // that fails hands it back to the composer.
        if (harness && prompt) {
          void harnessSwitch.switchTo(harness, host.cwd);
          void send(prompt, [], undefined, false, ticket?.promptId).catch(() => undefined);
        } else if (prompt) void send(prompt, [], undefined, false, ticket?.promptId).catch(() => setDraft(prompt));
      } catch (error) {
        if (!cancelled) {
          acpWire.lifecycle("handshake failed", { message: String(error) });
          setSnapshot((current) => ({ ...current, connection: `connecting: ${String(error)}` }));
          setHostError(errorMessage(error) || String(error));
          // A refused chat of another machine still names that machine on its chip (cx-k21v).
          setMachineName((current) => refusedMachine(error) ?? current);
          // Back off so a host without a daemon is not asked four times a second.
          retryTimer = window.setTimeout(() => void connectHost(), retryDelay);
          retryDelay = Math.min(retryDelay * 2, reconnect ? RECONNECT_MAX_DELAY_MS : 30_000);
        }
      } finally {
        connecting = false;
        if (retryPending) {
          retryPending = false;
          setRetryQueued(false);
          // The attempt in flight may have connected; then there is nothing left to retry.
          if (!cancelled && !directClient.current) retryNow();
        }
      }
    };
    // The user asked: try now, and let the host start a daemon even after one was lost.
    const retryNow = () => {
      if (retryTimer !== undefined) window.clearTimeout(retryTimer);
      retryTimer = undefined;
      reconnect = false;
      retryDelay = 250;
      void connectHost();
    };
    retryHost.current = () => {
      if (cancelled) return;
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
      if (retryTimer !== undefined) window.clearTimeout(retryTimer);
      directClient.current?.close();
      directClient.current = undefined;
      setBookmarkTransport(undefined);
      delete window.cmuxAcpmuxActions;
      notifyDraftActionsChanged();
    };
    // These are stable for the pane's life (state, provider client, a memoized bridge callback, and
    // the early New Tab flag, one object from a useState initializer).
  }, [harnessSwitch, queryClient, toggleInspector, earlyNewTab]);
  const registryChips = (window.cmuxAcpmuxRegistry as unknown as Record<string, unknown> | undefined)?.composerChips as
    | React.ComponentType<{ snapshot: AcpmuxSnapshot; permissionAccess?: ComposerPermissionAccess }>
    | undefined;
  const ComposerChips = registryChips ?? DefaultComposerChips;
  // The catalog arrives through the query cache, which composerSnapshot carries.
  const header = paneHeader(composerSnapshot, t);
  const handoffTargets = continueTargets(composerSnapshot.catalog, snapshot.summary?.harness);
  const canContinue =
    !!snapshot.canHandoff &&
    !!snapshot.handoff?.ready &&
    !snapshot.isWorking &&
    !snapshot.queue.length &&
    !snapshot.handoff?.busy &&
    !reviewing &&
    handoffTargets.length > 0;
  const ignoreFailure = (result: Promise<unknown>) => void result.catch(() => undefined);
  // The header's tools and "..." menu run app actions on this chat's tab.
  // A quick action names its mode; the App toggles the split it opened (header/quickActions.ts).
  const runHeaderAction = (id: string, cwd?: string, mode?: QuickActionMode) =>
    ignoreFailure(callNative("pane.action", { id, ...(cwd ? { cwd } : {}), ...(mode ? { mode } : {}) }));
  // A remote or cloud chat's folder is not on this Mac; its terminal opens in the pane's folder.
  const summary = snapshot.summary;
  const localCwd =
    summary && !summary.peer && !(summary.host && summary.hostKind !== "local") ? summary.cwd : undefined;
  instructionsFolder.current = localCwd;
  // Another chat or folder: an instructions notice was about the one before.
  useEffect(() => setInstructionsFailure(undefined), [snapshot.sessionId, localCwd]);
  // The header's state from the chat's tab (header/headerState.ts): read when a chat opens, then pushed
  // by the App on every change. Whether the panes beside the chat show ([+] New tab reads Hide tabs) also
  // follows the App's answer to the click.
  const { sideTabs } = useHeaderState();
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
    await (await openClient()).archive(archived);
    // Quick Chat's panel has no tab to close.
    if (archived && !quick) await callNative("pane.action", { id: "closeTab" });
  };
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
  const readTabState = () => callNative("pane.tabState").then(setHeaderState);
  const refreshTabState = () => void readTabState().catch(() => undefined);
  // Terminal and Browser change what is beside the chat: [+] follows once their split lands.
  const runSplitAction = (id: string, cwd: string | undefined, mode: QuickActionMode) => {
    runHeaderAction(id, cwd, mode);
    window.setTimeout(refreshTabState, 400);
  };
  diffBeside.current = async () => {
    // A remote or cloud chat's folder is not on this Mac, and Quick Chat's panel has no tab beside it.
    if (quick || !localCwd) return false;
    const reply = await callNative<{ ran?: boolean } | null>("pane.action", {
      id: HEADER_ACTIONS.changes,
      cwd: localCwd,
      mode: "open",
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
  // Only the same chat going idle counts; switching away from a working chat is no turn end.
  const wasWorking = useRef({ session: snapshot.sessionId, working: snapshot.isWorking });
  useEffect(() => {
    const last = wasWorking.current;
    const ended = last.session === snapshot.sessionId && last.working && !snapshot.isWorking;
    wasWorking.current = { session: snapshot.sessionId, working: snapshot.isWorking };
    if (ended && !quick)
      void callNative("pane.tabState", { refresh: true })
        .then(setHeaderState)
        .catch(() => undefined);
  }, [snapshot.sessionId, snapshot.isWorking, quick]);
  // A floating chat's panel that held this chat before the page loaded (a tab moved there, a reload)
  // says so once; later changes are pushed, and a reread per chat could land after a newer push.
  useEffect(() => {
    if (quick)
      void callNative("quick.floatingState")
        .then(setFloatingState)
        .catch(() => undefined);
  }, [quick]);
  const lastForkSeq = latestForkSeq(snapshot.rows);
  const sideChat = sideChatRow(
    // Quick Chat's panel is not a tab: there is no split to open beside it.
    { canFork: forkable, throughSeq: lastForkSeq, local: localCwd !== undefined && !quick },
    (throughSeq) => ignoreFailure(callNative("chat.side", { throughSeq })),
    t,
  );
  opensSideChat.current = sideChat !== undefined;
  const chatMenu = (): ChatMenuItem[] => {
    const link = snapshot.sessionId ? sessionLink(snapshot.sessionId) : undefined;
    const copy = copyRow({ link, rows: snapshot.rows }, (text) => ignoreFailure(copyText(text)), t);
    const fork: ChatMenuItem[] =
      forkable && lastForkSeq !== undefined
        ? [
            {
              key: "fork",
              label: t("chatMenu.fork"),
              icon: "agent.fork",
              onSelect: () => turnActions.fork?.(lastForkSeq),
            },
          ]
        : [];
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
    const tools: ChatMenuItem[] = [
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
    ];
    // Quick Chat's panel is not a tab: only the chat's own actions.
    if (quick) return menuGroups([...fork, ...continueIn], copy ? [copy] : [], tools);
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
      [...(sideChat ? [sideChat] : []), ...fork, ...continueIn],
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
      tools,
      [
        ...(markUnread ? [markUnread] : []),
        ...(archive ? [archive] : []),
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
  // Before the handshake the New Tab frame shows (cx-0rpl.10) unless the host failed: then the
  // chat view's error card with Retry shows, as before.
  const showNewTab =
    newTab !== undefined &&
    !snapshot.sessionId &&
    snapshot.rows.length === 0 &&
    (handshaken || hostError === undefined);
  const inspectorHiddenSurface = quick || showNewTab;
  inspectorHiddenSurfaceRef.current = inspectorHiddenSurface;
  useEffect(() => {
    if (!inspectorHiddenSurface) return;
    inspectorOpenRef.current = false;
    setInspectorOpen(false);
  }, [inspectorHiddenSurface]);
  const importFile = useCallback(async (file: File) => {
    setImportError(undefined);
    try {
      const session = parseImportedSession(await file.text(), file.name || "transcript.jsonl");
      if (!session.messages.length) return;
      await callNative("chat.new", session.cwd ? { cwd: session.cwd } : {});
      await callNative("chat.send", { text: importedPrompt(session), attachments: [] });
    } catch (error) {
      setImportError(error instanceof Error ? error.message : undefined);
    }
  }, []);
  /// The classic page's chat: a terminal or browser tab opens through `newTabPageSubmit`.
  const chatFromNewTab = (text: string, cwd?: string) => {
    const inherited = newTab?.cwd;
    setNewTab(undefined);
    const start = (folder?: string) =>
      void (async () => {
        // A chat on another machine starts only with a send (cx-k21v): with no text, the folder
        // waits for the first send.
        if (folder && !text && directClient.current?.startsOnSend) return setProjectDraft(folder);
        if (folder) await callNative("chat.new", { cwd: folder });
        if (text) await callNative("chat.send", { text });
      })().catch(() => undefined);
    // The page's own folder is inherited (`~` in a fresh workspace): the chat starts in its start
    // folder. Another project the user picked there goes through the host first.
    // Use Private Folder (or Keep) there gives the typed text back to the composer.
    if (cwd && cwd !== inherited) requestFolder(cwd, start, text ? () => setDraft(text) : undefined);
    else start(startFolder);
  };
  const loadNewTabProjects = useCallback(
    () =>
      callNative<{ projects?: string[] }>("project.list").then((result) =>
        (result?.projects ?? []).map((cwd) => ({ cwd, label: projectName(cwd) ?? cwd })),
      ),
    [],
  );
  const [directProjects, setDirectProjects] = useState<{ cwd: string; label: string }[]>([]);
  const onNewTab = Boolean(newTab);
  useEffect(() => {
    // Start Agent's folder picker lists them too (cx-hkat), and so does the New Tab page: the
    // daemon's project list, where the user's renames and removals win (cx-m0p7).
    if (!freshChat && !onNewTab) return;
    let active = true;
    void loadNewTabProjects()
      .then((projects) => {
        if (active) setDirectProjects(projects);
      })
      .catch(() => undefined);
    return () => {
      active = false;
    };
    // A prewarmed spare page asks again when Cmd-T adopts it: before that its model is not wired.
  }, [freshChat, onNewTab, newTabGeneration, loadNewTabProjects]);
  // A started local chat moves to another folder in place; a Cloud chat's folder is a label.
  const canMove = Boolean(snapshot.sessionId) && composerSnapshot.summary?.hostKind !== "cloud";
  const newTabProjects = useMemo(() => {
    const byPath = new Map<string, { cwd: string; label: string }>();
    for (const project of directProjects) byPath.set(project.cwd, project);
    for (const path of newTab?.projects ?? []) byPath.set(path, { cwd: path, label: projectLabel(path) });
    for (const session of composerSnapshot.sessions) {
      if (typeof session.cwd !== "string" || !session.cwd) continue;
      if (session.host && session.hostKind !== "local") continue;
      byPath.set(session.cwd, { cwd: session.cwd, label: projectLabel(session.cwd) });
    }
    if (newTab?.cwd) byPath.set(newTab.cwd, { cwd: newTab.cwd, label: projectLabel(newTab.cwd) });
    return [...byPath.values()];
  }, [composerSnapshot.sessions, newTab?.cwd, newTab?.projects, directProjects]);
  // The new chat's hero picker (cx-9g0w): this Mac's projects, then other machines' folders from
  // their chats (each with its machine's name), Add project and Do not work in a project.
  const heroPicker = useMemo<EmptyStateProjects | undefined>(() => {
    if (!freshChat || quick) return undefined;
    const remote = new Map<string, Project>();
    for (const session of composerSnapshot.sessions) {
      const peer = session.peer ?? (session.hostKind === "cloud" ? session.host : undefined);
      if (!peer || typeof session.cwd !== "string" || !session.cwd || isAgentHome(session.cwd)) continue;
      const project = { cwd: session.cwd, label: projectLabel(session.cwd), peer, host: session.host ?? peer };
      remote.set(`${peer}\u0000${session.cwd}`, project);
    }
    const summary = composerSnapshot.summary;
    const cwd = summary?.cwd;
    // The machine as the rows key it (ComposerContext.computerId): a peer, else a Cloud host.
    const peer = summary?.peer || (summary?.hostKind === "cloud" ? summary.host : undefined);
    return {
      projects: [...newTabProjects.filter((project) => !isAgentHome(project.cwd)), ...remote.values()],
      current: cwd && !isAgentHome(cwd) ? cwd.replace(/(.)\/+$/, "$1") : undefined,
      currentPeer: peer,
      // In no project only when it is: its folder is agent-home, or the host starts it there. A chat
      // with no folder yet may still start in the workspace's root, so nothing is checked then.
      noProject: cwd ? isAgentHome(cwd) : chooseFolder,
      onPick: chooseProject,
      onBrowse: () => {
        void callNative<{ cwd?: string }>("project.browse")
          .then((result) => {
            if (result?.cwd) chooseProject(result.cwd);
          })
          .catch(() => undefined);
      },
      // The chat starts in its agent-home folder, never the workspace's (AcpmuxPathPolicy).
      // A refused start keeps the folder picked before.
      onNoProject: () => {
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
  const toggleActivity = (id: string) =>
    setExpanded((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  const loadReplay = useCallback(
    // l10n-allow: never shown; the replay says replay.failed.
    () => directClient.current?.recordedEvents(replaying ?? "") ?? Promise.reject(new Error("no connection")),
    [replaying],
  );
  const transcript = (
    // Quick Chat's panel has no room beside it: its fences have no Open preview.
    <ArtifactContext.Provider value={quick ? undefined : openArtifact}>
      <ImageViewerContext.Provider value={openImage}>
        <ShellActionsContext.Provider value={shellActions}>
          <TurnActionsContext.Provider value={turnActions}>
            <TurnCountsContext.Provider value={turnCountsFor}>
              <SessionEditsContext.Provider value={editRows}>
                <SessionCwdContext.Provider value={snapshot.summary?.cwd}>
                  <SubagentNavContext.Provider value={setSubagentView}>
                    <SubagentPaneContext.Provider value={showSubagent}>
                      <SubagentStopContext.Provider value={stopSubagent}>
                        <SubagentHarnessContext.Provider
                          value={knownMark(snapshot.summary?.harness, snapshot.summary?.family)}
                        >
                          <ChatFindScope
                            rows={childRows ?? sourceRows}
                            shown={childRows ? undefined : transcriptRows}
                            openFold={openFold}
                            findRef={findRef}
                          >
                            {(find) => (
                              <VirtualTranscript
                                rows={transcriptRows}
                                working={snapshot.isWorking}
                                // Its stage positions Jump to latest; the Quick Composer's panel has no room for it.
                                jumpButton={!quick}
                                focusComposer={() => composerHandle.current?.focus()}
                                find={quick ? undefined : find}
                                sessionId={childRows ? `${shownSessionId}:subagent:${subagentView}` : shownSessionId}
                                canLoadOlder={!childRows && snapshot.canLoadOlder}
                                onLoadOlder={() => directClient.current?.loadOlder() ?? Promise.resolve()}
                                openAt={
                                  !childRows && shownSessionId && scrollAnchor?.sessionId === shownSessionId
                                    ? scrollAnchor
                                    : undefined
                                }
                                anchorNow={quick || childRows ? undefined : transcriptAnchor}
                                onAnchor={
                                  quick || childRows || !shownSessionId
                                    ? undefined
                                    : (anchor) => postScrollAnchor(shownSessionId, anchor)
                                }
                                expanded={expanded}
                                registry={registry}
                                githubRepository={githubRepository}
                                // The Quick Composer has no room for the changes view; its file rows stay plain.
                                onOpenDiff={quick ? undefined : openDiff}
                                onToggleActivity={toggleActivity}
                              />
                            )}
                          </ChatFindScope>
                        </SubagentHarnessContext.Provider>
                      </SubagentStopContext.Provider>
                    </SubagentPaneContext.Provider>
                  </SubagentNavContext.Provider>
                </SessionCwdContext.Provider>
              </SessionEditsContext.Provider>
            </TurnCountsContext.Provider>
          </TurnActionsContext.Provider>
        </ShellActionsContext.Provider>
      </ImageViewerContext.Provider>
    </ArtifactContext.Provider>
  );
  const toolCards = useToolCards();
  // Folder trust is the first gate in the bottom stack. While it is being read or answered,
  // permission and secret cards stay out of the tree so the user never has two different asks
  // competing for the same answer. A trusted receipt is not blocked and can sit above the next ask.
  const trustPending = Boolean(trustAsk.blocked);
  const hasPermissionGroups = Boolean(
    snapshot.permissionGroups?.supported &&
    (snapshot.permissionGroups.groups.length > 0 || snapshot.permissionGroups.error),
  );
  const hasBottomAsk = Boolean(
    (trustAsk.ask && (trustAsk.ask.state !== "decided" || trustAsk.ask.level === "untrusted")) ||
    (!trustPending && (hasPermissionGroups || individualPermission || snapshot.secret || toolCards.length > 0)),
  );
  const asks = hasBottomAsk ? (
    <div className="acpmux-permission acpmux-asks-stack">
      {trustAsk.ask && (trustAsk.ask.state !== "decided" || trustAsk.ask.level === "untrusted") && (
        <TrustAsk
          ask={trustAsk.ask}
          agent={snapshot.summary?.harness ? agentName(snapshot.summary.harness) : t("trust.agent")}
          onTrust={trustAsk.trust}
          onDistrust={trustAsk.distrust}
          onUndo={trustAsk.undo}
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
      {!trustPending && (individualPermission || snapshot.secret || toolCards.length > 0) && (
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
              permission={individualPermission}
              harness={snapshot.summary?.harness}
              focusComposer={() => composerHandle.current?.focus()}
            />
          )}
          {snapshot.secret && (
            <SecretCard
              key={snapshot.secret.secretId}
              ask={snapshot.secret}
              agent={snapshot.summary?.harness ? agentName(snapshot.summary.harness) : t("trust.agent")}
              onAnswer={answerSecret(snapshot.secret)}
            />
          )}
        </>
      )}
    </div>
  ) : null;
  const trustLabel =
    trustAsk.ask?.state === "decided" && trustAsk.ask.level === "trusted"
      ? isAgentHome(trustAsk.ask.cwd)
        ? t("trust.trustedPrivate")
        : t("trust.trusted", { folder: projectName(trustAsk.ask.cwd) ?? trustAsk.ask.cwd })
      : undefined;
  const permissionAccess: ComposerPermissionAccess = {
    grants: [
      ...(trustAsk.trusted
        ? [
            {
              id: "folder-trust",
              label: trustLabel ?? t("trust.trustedPrivate"),
              onRemove: trustAsk.undo,
            },
          ]
        : []),
      ...(snapshot.permissionGroups?.chatAllowance
        ? [
            {
              id: "chat-permission",
              label: t("permission.allowChat"),
              onRemove: () => void callNative("chat.permission_chat.revoke", {}),
            },
          ]
        : []),
    ],
  };
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
              void callNative("chat.harness.enable", { folder: block.folder, id: block.harness }).catch(
                () => undefined,
              ),
          }
        : {})}
    />
  );
  const composer = !reviewing && !handoffLoading && (
    <>
      <PullRequestDock key={snapshot.sessionId} rows={snapshot.rows} sessionId={snapshot.sessionId} />
      <DictationNotice dictation={dictation} />
      {importError && (
        <p className="acpmux-composer-remote-note" role="alert">
          {importError}
        </p>
      )}
      <InstructionsNotice
        failure={instructionsFailure?.failure}
        onRetry={() =>
          instructionsFailure && openInstructions(instructionsFailure.cwd, instructionsFailure.failure.file)
        }
        onDismiss={() => setInstructionsFailure(undefined)}
      />
      {harnessCard ?? (
        <SwitchNotice switching={snapshot.switching} onRetry={() => void callNative("chat.harness.retry")} />
      )}
      {!harnessCard && (
        <HarnessHealthNotice
          health={harnessHealth}
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
        />
      )}
      {folderNeeded && !snapshot.sessionId && (
        <MissingFolder
          reason={folderNeeded.reason}
          error={folderNeeded.error}
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
      )}
      {pendingFolder ? (
        <StartFolderAsk
          ask={pendingFolder.ask}
          current={freshChat && !snapshot.sessionId ? projectDraft : snapshot.summary?.cwd}
          error={pendingFolder.error}
          onUse={() => {
            // The question closes on the click, so a second click cannot use the folder twice.
            const pending = pendingFolder;
            setFolderAsk(undefined);
            void confirmFolder(callNative, pending.ask, pending.use).catch((error: unknown) =>
              setFolderAsk((current) => current ?? { ...pending, error: errorMessage(error) || String(error) }),
            );
          }}
          onCancel={() => {
            pendingFolder.cancel?.();
            setFolderAsk(undefined);
          }}
        />
      ) : (
        showsFolderChoice({
          offered: chooseFolder,
          freshChat,
          quick,
          projectDraft,
          sessionId: snapshot.sessionId,
          missingFolder: Boolean(folderNeeded && !snapshot.sessionId),
        }) && (
          <FolderChoice
            error={folderError}
            onChoose={() => {
              setFolderError(undefined);
              void callNative<{ cwd?: string }>("workspace.chooseFolder")
                .then((result) => {
                  if (!result?.cwd) return;
                  setChooseFolder(false);
                  chooseProject(result.cwd);
                })
                .catch((error: unknown) => setFolderError(errorMessage(error) || undefined));
            }}
          />
        )
      )}
      {worktreeCreating && freshChat && !snapshot.sessionId && (
        <output className="acpmux-switch-notice acpmux-worktree-creating">{t("worktree.creating")}</output>
      )}
      {worktreeError && freshChat && !snapshot.sessionId && (
        <WorktreeFailure error={worktreeError} onDismiss={() => setWorktreeError(undefined)} />
      )}
      {aside && (
        <SideQuestion
          state={aside}
          githubRepository={githubRepository}
          onDismiss={() => setAside(undefined)}
          onAdd={() => {
            setAside(undefined);
            ignoreFailure(callNative("chat.send", { text: aside.question, attachments: [] }));
          }}
        />
      )}
      {/* An attached image opens in the chat's image viewer, as a transcript image does. */}
      <ImageViewerContext.Provider value={openImage}>
        <Composer
          snapshot={composerSnapshot}
          sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
          chips={ComposerChips}
          permissionAccess={permissionAccess}
          draft={draft}
          onUnsentDraft={quick ? undefined : postUnsentDraft}
          onCmuxCommand={(command, args) => {
            if (command.action === "btw") {
              const question = args?.trim();
              const sessionId = snapshot.sessionId;
              if (!asksAside || !question || !sessionId) return false;
              const ask = ++asideAsks.current;
              setAside({ sessionId, ask, question });
              const settle = (outcome: Partial<SideQuestionState>) =>
                setAside((current) => (current?.ask === ask ? { ...current, ...outcome } : current));
              callNative<string>("chat.ask", { question }).then(
                (answer) => settle({ answer: typeof answer === "string" ? answer : "" }),
                (error: unknown) => settle({ error: errorMessage(error) || String(error) }),
              );
              return true;
            }
            if (command.action === "fork") {
              if (!forkable || forkSeq === undefined || args?.trim()) return false;
              ignoreFailure(callNative("chat.fork", { throughSeq: forkSeq }));
              return true;
            }
            if (command.action !== "continue" || !canContinue) return false;
            if (!args?.trim()) {
              setContinuing(true);
              return true;
            }
            const target = resolveHarnessTarget(args, handoffTargets);
            if (!target) return false;
            setContinuing(false);
            ignoreFailure(callNative("chat.handoff.prepare", { harness: target.id }));
            return true;
          }}
          onSend={(text, chips, steer) => {
            // Until acpmux connects nothing takes a prompt; the composer keeps it.
            if (!window.cmuxAcpmuxActions?.["chat.send"]) return false;
            // Shell mode's chips carry their commands' output as it is now.
            const attachments = shellContextAttachments(chips ?? [], (id) => shellRuns.get(id));
            if (!snapshot.sessionId) claimShellRuns.current = true;
            // The composer keeps the prompt until acpmux takes it: a refusal (folder trust, the
            // remote guard, the sandbox) leaves it there to send again.
            let accept: (taken: true) => void = () => undefined;
            const taken = new Promise<true>((resolve) => (accept = resolve));
            const send = async () => {
              if (projectDraft && !snapshot.sessionId)
                // The chat's start is part of this send: a trust refusal there asks the folder's
                // question, keeps this prompt (with its send's gesture) and sends it after Trust
                // (cx-nn3e P0b; the prompt was lost when only the start ran again).
                await callNative("chat.new", { cwd: projectDraft }).catch((error: unknown) => {
                  if (isTrustRefusal(error)) {
                    holdPrompt.current?.();
                    trustRefused.current?.(error, () => composerHandle.current?.send());
                  }
                  throw error;
                });
              return callNative("chat.send", { text, attachments, accepted: () => accept(true), steer });
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
            held.catch(() => {
              if (composerHandle.current === holder) return;
              if (composerHandle.current) composerHandle.current.restore(text, attachments);
              else heldBack.current = [...(heldBack.current ?? []), { text, attachments }];
            });
            return held;
          }}
          onStop={() => void callNative("chat.cancel")}
          onQueueRemove={removeQueued}
          onQueueChange={editQueued}
          // A prompt that started while it was edited comes back to the prompt, so the edit is kept.
          onQueueLost={(text) => composerHandle.current?.restore(text, [])}
          onProject={chooseProject}
          onNewWorktree={freshChat && !quick && !remoteChat ? startInWorktree : undefined}
          // SSH… opens Connect to Machine; cmux Cloud… opens New Cloud Machine (Lawrence 2026-10-06).
          onConnect={(kind) =>
            void callNative("action.run", { id: kind === "ssh" ? "remote.connect" : "newCloudMachine" }).catch(
              () => undefined,
            )
          }
          // A started local chat lists the same folders to move to (dogfood 09); Start Agent's
          // panel lists them before its first prompt (cx-hkat).
          projectChoices={freshChat || (!quick && canMove) ? newTabProjects : undefined}
          onBrowseProject={
            freshChat && !quick
              ? () => {
                  void callNative<{ cwd?: string }>("project.browse")
                    .then((result) => {
                      if (result?.cwd) chooseProject(result.cwd);
                    })
                    .catch(() => undefined);
                }
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
          localName={machineName}
          onBrowseFolder={
            canMove
              ? () =>
                  callNative<{ cwd?: string }>("project.browse")
                    .then((result) => result?.cwd)
                    .catch(() => undefined)
              : undefined
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
          onMode={(modeId) => void callNative("chat.mode", { modeId })}
          // Without a folder there is nothing to search; the + menu leaves the item out.
          searchFiles={fileRoot ? searchFiles : undefined}
          capture={captureScreen}
          upload={uploadFiles}
          onOpenInWindow={quick ? openInWindow : undefined}
          prompt={prompt}
          handle={composerRef}
          // No prompt goes while a picked folder waits for the user's answer.
          blocked={pendingFolder ? {} : trustAsk.blocked}
          accessory={<DictationMic dictation={dictation} />}
          onImportFile={importFile}
          onEdit={(command) => ignoreFailure(callNative("pane.edit", { command }))}
        />
      </ImageViewerContext.Provider>
    </>
  );
  const hostErrorCard = hostError && (
    <HostError message={hostError} retrying={retryQueued} onRetry={() => retryHost.current?.()} />
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
  if (quick)
    return (
      <ShortcutsContext.Provider value={shortcuts}>
        <section className="acpmux-shell" data-surface="quick">
          <QuickSurface
            transcript={snapshot.rows.length > 0 || chatShellRuns.length > 0 ? transcript : undefined}
            asks={
              <>
                {asks}
                {hostErrorCard}
              </>
            }
            composer={composer}
            floating={quickFloating}
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
  const pane = (
    <ShortcutsContext.Provider value={shortcuts}>
      <section className="acpmux-shell" aria-label={composerSnapshot.summary?.title || t("header.agentChat")}>
        <div className="acpmux-main" data-new-chat={freshView && !showNewTab ? "" : undefined}>
          {!harnessesOpen && showNewTab && !newTab.history && (
            // The page's style, under it; a pick shows in place at once.
            <StyleSwitch
              current={pageStyle(shownTemplate(newTab))}
              onCancel={() => window.dispatchEvent(new Event(FOCUS_LOCATION_EVENT))}
              onPick={(style) =>
                pickNewTabStyle(style, {
                  callNative,
                  show: (next) => setNewTab((current) => current && { ...current, template: next }),
                })
              }
            />
          )}
          {harnessesOpen ? (
            <HarnessesScreen
              catalog={pickerCatalog}
              acpmux={snapshot.catalog}
              {...(harnessFolder ? { cwd: harnessFolder } : {})}
              callNative={harnessesNative}
              checking={harnessesChecking}
              refreshCatalog={pickerState.refresh}
              onClose={() => setHarnessesOpen(false)}
              onStart={() => {
                setHarnessesOpen(false);
                setNewTab(undefined);
              }}
            />
          ) : showNewTab && newTab.history ? (
            <HistoryScreen
              load={(params) => callNative<AllChatsPage | undefined>("chats.page", params)}
              onOpen={(key) => void callNative("chats.open", { key }).catch(() => undefined)}
              onOpenInTerminal={(key) => void callNative("chats.openInTerminal", { key }).catch(() => undefined)}
            />
          ) : showNewTab && shownTemplate(newTab) !== "classic" ? (
            <NewTabScreen
              key={newTabGeneration}
              accessory={<DictationMic dictation={dictation} />}
              dictationField={newTabDictationField}
              notice={<DictationNotice dictation={dictation} />}
              template={screenTemplate(shownTemplate(newTab))}
              snapshot={composerSnapshot}
              omnibar={newTab.omnibar}
              location={newTab.location}
              lastAgent={newTab.lastAgent}
              home={newTab.home}
              {...(newTab.openTabs ? { openTabs: newTab.openTabs } : {})}
              // The field takes keys from its first render (the host's buffer hands them over at
              // once); only a submit waits for acpmux (`whenHandshaken`).
              inputToken={newTab.inputToken}
              {...(newTab.cwd ? { cwd: newTab.cwd } : {})}
              {...(startFolder ? { startCwd: startFolder } : {})}
              {...((newTab.host ?? machineName) ? { machineName: (newTab.host ?? machineName)! } : {})}
              projects={newTabProjects}
              onBrowseProject={() =>
                callNative<{ cwd?: string }>("project.browse").then(
                  (result) => result?.cwd,
                  () => undefined,
                )
              }
              chips={registryChips ?? NewTabComposerChips}
              focusField={newTab.focusesField !== false}
              {...withSubmitAfterHandshake(
                newTabScreenActions({
                  callNative,
                  cwd: newTab.cwd,
                  chatCwd: startFolder,
                  requestFolder,
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
          ) : showNewTab ? (
            <NewTabPage
              key={newTabGeneration}
              snapshot={composerSnapshot}
              hotkeys={newTab.hotkeys}
              initialKind={newTab.initialKind}
              cwd={newTab.cwd}
              host={newTab.host ?? machineName}
              location={newTab.location}
              omnibar={newTab.omnibar}
              projects={newTabProjects}
              chips={ComposerChips}
              // A terminal or browser tab opens at once; a chat waits for acpmux (cx-hnpxh).
              onSubmit={newTabPageSubmit({ callNative, whenHandshaken, startChat: chatFromNewTab })}
              onJump={(target, id) => void callNative("tab.jump", { target, id })}
              onOpenSession={(sessionId) => {
                setNewTab(undefined);
                selectSession(sessionId);
              }}
              onShowAll={showAllChats}
              onBrowseProject={() =>
                callNative<{ cwd?: string }>("project.browse")
                  .then((result) => result?.cwd)
                  .catch(() => undefined)
              }
              onEditShortcut={(kind) => void callNative("shortcut.edit", { kind })}
              inputToken={newTab.inputToken}
              onInputReady={(token) => void callNative("newTab.inputReady", { token })}
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
                  expanded={expanded}
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
                  <ChatHeaderStatus status={header.status} detail={header.detail} />
                  <div className="acpmux-handoff-header-tools" ref={tabRowTools}>
                    {preview && (
                      <span
                        className="acpmux-session-coverage"
                        // tooltip-allow: the policy's enforcement detail, shown nowhere else
                        title={`${handoffLabels.unverified} · ${snapshot.summary?.enforcement?.detail ?? handoffLabels.unverifiedDetail}`}
                      >
                        {snapshot.summary?.enforcement ? handoffLabels.nativePolicy : handoffLabels.unverified}
                      </span>
                    )}
                    <ChatHeaderTools
                      tabTools={!quick}
                      // A new chat's picked folder too: New Worktree names its branch before the first prompt.
                      folder={localCwd ?? (remoteChat ? undefined : startFolder)}
                      readStatus={readFolderStatus}
                      statusKey={snapshot.isWorking}
                      // Apply brings a worktree chat's work to its main checkout (cx-lyqio.4); a new chat has none yet.
                      onApplyWorktree={
                        snapshot.sessionId && localCwd
                          ? (key: string) =>
                              callNative("git.worktree.apply", { session_id: snapshot.sessionId, idempotency_key: key })
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
                                const result = value as { merged?: unknown; queued?: unknown } | null;
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
                          callNative("pane.action", { id: HEADER_ACTIONS.preview, ...(url ? { url } : {}), mode }),
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
                      sessionRail={sessionRail.button}
                      summary={<SummaryButton card={summaryCard} />}
                      menu={chatMenu}
                      onMenuOpen={readTabState}
                      expand={continuing && canContinue ? "continue" : undefined}
                      onExpanded={stopContinuing}
                    />
                  </div>
                </header>
                <SummaryCard
                  // Another chat closes this one's gallery, as it does the image viewer.
                  key={snapshot.sessionId}
                  card={summaryCard}
                  rows={snapshot.rows}
                  changes={quick ? undefined : lastChanges}
                  onOpenChanges={toggleLastChanges}
                  onOpenOutput={quick ? undefined : openOutput}
                  onOpenImage={quick ? undefined : openImage}
                  subagents={cardSubagents}
                />
                {!diffView && checkpoints.review}
                {snapshot.missingSession && (
                  <p className="acpmux-link-missing" role="alert">
                    {t("link.sessionMissing")}
                  </p>
                )}
                {snapshot.liveChat && (
                  <LiveChatChoice
                    {...snapshot.liveChat}
                    onChoose={(choice) => void callNative("chat.adoptLive", { choice }).catch(() => undefined)}
                  />
                )}
                {!reviewing && snapshot.handoff?.error && (
                  <p className="acpmux-handoff-error" role="alert">
                    {snapshot.handoff.error}
                  </p>
                )}
                {reviewing && handoff && snapshot.handoff ? (
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
                ) : freshView && pastTurns && (!pastWaitsForTrust || trustAsk.ask) ? (
                  <PastChat turns={pastTurns} {...(githubRepository ? { githubRepository } : {})} />
                ) : freshView ? (
                  <EmptyState project={projectName(composerSnapshot.summary?.cwd)} picker={heroPicker} />
                ) : (
                  transcript
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
              {asks}
              {/* Between the hero and the docked composer. */}
              {freshView && (
                <div className="acpmux-home-area">
                  <HomeLists sessions={snapshot.sessions} currentId={snapshot.sessionId} onSelect={selectSession} />
                </div>
              )}
              {hostErrorCard}
              {composer}
            </>
          )}
        </div>
        {/* Beside the chat view only: New Tab, Harnesses and a replay have no session header. */}
        {!harnessesOpen && !showNewTab && !(replaying && replaying === snapshot.sessionId) && sessionRail.rail}
        {artifact && (
          <ArtifactPanel
            key={artifact.opened}
            artifact={artifact}
            versions={artifactVersionList}
            onClose={() => setArtifact(undefined)}
            onSave={saveDocumentNatively}
          />
        )}
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
  return <SignInContext.Provider value={signIn}>{pane}</SignInContext.Provider>;
}
