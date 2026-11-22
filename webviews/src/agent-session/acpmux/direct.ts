Warning: truncated output (original token count: 234641)
Total output lines: 17566

import type { BrowserWorkspaces } from "./browser/workspaces";
import {
  browserDeviceError,
  browserDeviceIsCurrent,
  connectBrowserDevice,
  invalidateBrowserDevice,
  prepareBrowserDevice,
  type BrowserDeviceIdentity,
} from "./browserDevice";
import { pageAttention } from "./attention";
import { sentFrom, type SentFrom } from "./conversation/sentFromHarness";
import { stuckAttention } from "./loopEpisode";
import { externalAccessFromRequest } from "./permissions/externalAccess";
import { markAgentProgressSource } from "./subagents/agentProgressSource";
import type { RaceRecord, RaceStart } from "./races/model";
import { projectLiveProgress, type LiveProgress } from "./liveProgress";
import { chatTaskListOf, type ChatTaskList } from "./chatTaskList";
import { UNKNOWN_AUTH, type SessionAuthQuery } from "./sessionAuth";
import { sameJson } from "./sameJson";
import { autoResumeAttempt, autoResumeStatus } from "./autoResumeStatus";
import { extraFoldersParam, summaryExtraFolders, type ExtraFolderDraft } from "./extraFolders";
import { parseJsonObjectFrame } from "../../protocol/jsonFrame";
import { isRetryContinuation, subagentRetryNotice, type SubagentRetryNotice } from "./subagents/retryState";
import { CACHE_EXPIRY_REASON, isCacheCompaction } from "./conversation/cacheCompaction";
import { isModelRouterKind } from "./routerKinds";
import type { SwitchPort } from "./harnessSwitch";
import { OlderPageDelay } from "./conversation/olderPageDelay";
import { answeredBy, promptAuthor, queuedAuthor, type Participant } from "./multiplayer/participants";
import type {
  AcpmuxActivity,
  AcpmuxFileDiff,
  AcpmuxLocation,
  AcpmuxPermission,
  AcpmuxPermissionScope,
  AcpmuxSecretAsk,
  AcpmuxSessionOffer,
  AcpmuxOfferResult,
  AcpmuxBackgroundState,
  AcpmuxBackgroundTask,
  AcpmuxBackgroundTurn,
  AcpmuxBackgroundReaction,
  AcpmuxBackgroundSource,
  AcpmuxCompaction,
  AcpmuxContextBreakdown,
  AcpmuxPlanEntry,
  AcpmuxRow,
  AcpmuxSessionStart,
  AcpmuxSnapshot,
  ClaimCheck,
  MissingSessionReason,
  PromptImage,
  PromptContentPart,
  QueueEdit,
  QueuedPrompt,
  QueuedPromptImage,
  PromptDelivery,
  PromptDeliveryHop,
  StartSource,
  TurnTokenSplit,
  AcpmuxRecap,
} from "./model";
import {
  PROMPT_PENDING_AFTER_MS,
  QUEUED_MESSAGE,
  SINCE_DIVIDER,
  TURN_RETRY,
  type AcpmuxSince,
  type AcpmuxTurnRetry,
  rowFrameKey,
} from "./model";
import { addSplit, callTokenSplit, NO_TOKENS, resultTokenSplit } from "./tokenSplit";
import { continuesTurn } from "./turnStart";
import { hostIsReconnecting, jitteredDelay, lostRetryDelay } from "./hostRetry";
import { sendsHeldForHost, untilHostAnswers } from "./sendWhenReady";
import { mergeModelCatalog } from "./modelCatalog";
import { commandsFromUpdate, type SlashCommand } from "./slashCommands";
import {
  attachmentSource,
  hasInlineMarks,
  promptBlocks,
  promptText,
  takesAudio,
  type AttachmentSource,
  type ComposerAttachment,
} from "./attachments";
import { carryInline, inlinePrompt, recordedPromptParts, restoreInline, stripFileDisplay } from "./inlinePrompt";
import { fitPromptBudget, promptBudgetFor, uploadsToFit } from "./promptBudget";
import type { SendPrompt, SendUploadResult } from "./sendUploads";
import { liftInlineImages } from "./inlineImages";
import { primeSentImages, withSentShapes } from "./conversation/imageEntries";
import { resentAttachments, shownPrompt } from "./pastedText";
import { frameTextOf, imageNames, withoutFrames } from "./composer/videoPrompt";
import { PeerStateEvents } from "./peerStateEvents";
import {
  peerConnectedFromStatus,
  peerKindsFromStatus,
  peerLinksFromStatus,
  peerStatesFromStatus,
} from "./environments";
import type { PeerLinkDetail } from "./linkState";
import { peerResourcesFromStatus } from "./machineResources";
import { type ChatUnavailable, chatUnavailable, type PeerStatus, peerStatusFromStatus } from "./chatUnavailable";
import { resolvedTarget } from "./conversation/sessionRefs";
import { noteReplaced } from "./sessionIndex";
import { hostKind, sessionEntry, sessionTitle, summaryActivityAt, text, type AcpmuxSessionEntry } from "./sessionList";
import { sameUsageStats, type SessionUsageStats } from "./usageStats";
import { usageLimitsOf } from "./usageLimits";
import { clampRunning, subsessionLimits } from "./subsessionLimits";
import { agentName } from "./agents";
import { forkHistoryTail, sameForkHistory } from "./forkTail";
import { FORK_OP, servesOperation } from "./operations";
import { postNative } from "./native";
import {
  COMMANDS_KIND,
  CONFIG_KIND,
  PRESET_APPROVAL_KINDS,
  SECRET_KINDS,
  SETTLED_ATTACH_CAPABILITY,
  USAGE_KIND,
  attachedDetail,
  plainAttach,
  settledAttachFailed,
} from "./attachParams";
export { SETTLED_ATTACH_CAPABILITY, attachedDetail, settledAttachFailed } from "./attachParams";
import { ChatSource } from "./rows/chatSource";
import { holdAttach, holdReads } from "./rows/holdKinds";
import {
  forgetTail,
  keptEvents,
  keptTail,
  olderThanShown,
  KEPT_EVENTS,
  type KeptTail,
  readHostTail,
  rememberReadAhead,
  rememberTail,
  shareReadAhead,
  hostTailOf,
  type TailHandOver,
} from "./tailCache";
import { HOVER_RECENT, HoverPrefetch, type HoverOptions } from "./hoverPrefetch";
import { type PeerCopy, PEER_COPY_READ_MS, peerBack, peerCopyTail, peerDown, sameGeneration } from "./peerCopy";
import { readSummaryCheckpoint } from "./changes/turnCheckpointSource";
import { HandoffClient } from "./handoff/client";
import { PermissionGroupClient } from "./permissions/client";
import { cancelledKey, questionFromPermission, summaryLines, type AgentQuestion } from "./question/model";
import { cancelledArgs, decidedQuestion, QUESTION_RECORD } from "./question/record";
import { deliverQuestionKeyRequest, isQuestionKeyRequest } from "./question/keyReply";
import { DECISION_TEXT, PERMISSION_RECORD, permissionDecision } from "./permissions/record";
import { isNotification, typedRequest } from "./protocol/client";
import type { AcpmuxRequestName, AcpmuxRequests } from "./protocol/generated/methods";
import type { SessionChanged, SessionEvent, SessionSummary } from "./protocol/generated/types";
import { supportsPermissionGroups, type PermissionDecision } from "./permissions/protocol";
import { AcpmuxRpcError, supportsHandoff } from "./handoff/protocol";
import { sessionEnforcement } from "./handoff/review";
import type { HandoffReviewInput } from "./handoff/review";
import { acpWire, redactEndpoint, type AcpWireLog } from "./wire";
import { noteTranscriptReplace } from "./flickerLog";
import { chatPerfCapture } from "./chatPerfCapture";
import { acpmuxPerf } from "./perf";
import { BUSY_TRIES, busyDelay, RequestBudget, waitsForSlot } from "./requestBudget";
import { translate } from "./i18n";
import { bgDoneNotice, bgDoneStarted } from "./conversation/bgDoneNotice";
import { approvePlan, clearPlanScope, editPaths, rememberPlanEdit } from "./planScopeDriftStore";
import { OFFER_RESULT, offersShown } from "./offer/offersShown";
import {
  cliHost,
  incomingPrompt,
  recordedAgentText,
  type IncomingContext,
  type IncomingMessage,
} from "./conversation/incomingMessage";
import { noticeRowText } from "./conversation/agentNotice";
import { inboxMessages, inboxText, type InboxMessage, type InboxNotice } from "./conversation/inboxNotice";
import { newerSurge, surgeCounts, surgeOfEvent, type SurgeHold } from "./conversation/surgeHold";
import { withoutRelayEnvelope, withoutRelayLabel, withoutRelayLabelOfMessage } from "./conversation/relayEnvelope";
import { bareSender, provenanceAuthenticated } from "./conversation/senderIdentity";
import { recapDismissed, rememberRecapDismissed } from "./conversation/recapDismissed";
import { startedCardsShown } from "./started/startedSessions";
import { PLAN_BUILD_KIND } from "./planBuild/planBuild";
import { PlanBuildRows } from "./planBuild/planBuildRows";
import { OfferChildren } from "./offer/offerChildren";
import type { OfferPicks } from "./offer/offerChoice";
import { errorMessage, startCancelled, knownRefusalText, switchFailedText } from "./transportErrors";
import { failedSendText, heldSendNotice, retryHelps, sendCause } from "./sendFailure";
import { isLostConnection, lostPrompt, type LostPrompt } from "./lostPrompt";
import type { UnsentPromptRecord, UnsentPromptStore } from "./unsentPrompts";
import {
  SessionPageError,
  SessionPager,
  withUsage,
  LIST_FOLLOW_CAPABILITY,
  USAGE_CAPABILITY,
  allSessionsWanted,
  onWantAllSessions,
  inNewestOrder,
  wantAllSessions,
  withSession,
} from "./sessionPages";
import { isWarmableCwd } from "./warmFolders";
import {
  isCodexSleep,
  isCompletedPlumbingTool,
  isMuseTodoCall,
  isPlanToolCall,
  isPlumbingCall,
  showsNothing,
  withAwaitingCall,
} from "./hiddenTools";
import { SubagentFold, subagentsLeft, subagentStops, type SubagentStopReason } from "./subagents/subagentFold";
import { WORKSPACE_CONTEXT } from "./workspaceContext";
import { promptContext } from "./composer/videoTranscript";
import { promptSurfaceMeta } from "./surfaces/promptSurface";
import { BOOKMARKS_KIND, bookmarksHeard } from "./threadMinimap/bookmarks";
import { type StartMode, fullAccessTicket, rememberFullAccess, startModeChanged } from "./startMode";
import { harnessModeName, highestMode } from "./harnessModes";
import { insertRunChange, type RunChange, sessionStartOf } from "./conversation/sessionStart";
import { reduceAgentPair } from "./conversation/agentPairs";
import { pasteRanges } from "./conversation/promptCollapse";
import {
  BACKGROUND_TURN,
  backgroundTurnRecord,
  backgroundTurnRowId,
  isQuietReply,
  saysNothing,
} from "./conversation/backgroundTurns";
import { backgroundReactionLook, reactsOnCall } from "./conversation/backgroundReaction.experiment";
import { experimentArm } from "../../experiments/experiment";
import { isVisiblyEmptyMessage } from "./conversation/visibleMessage";
import { AskTracker, pendingReader, SIDE_SESSION_METHOD } from "./needsYou/asks";
import { BTW_INLINE_HERE } from "./btwCapability";
import { chatTools, toolApplied, type ToolApplied } from "./summary/chatTools";
import { taskGoal } from "./goal";
import { shownPresence } from "./multiplayer/livePresenceModel";
import { PresenceClient } from "./multiplayer/presenceClient";
import { recordedConversationEvents } from "./conversation/exportEvents";
import {
  markPullRequestActivityVersion,
  markPullRequestCommandVersion,
  markTranscriptSummaryVersion,
  pullRequestRowKey,
} from "./summary/transcriptPullRequests";
import { markOneRowChange } from "./rowChanges";
import { noteKeptPrefix } from "./conversation/prefixFlatMap";
import { RowUpdates } from "./rowUpdates";
import { parseHarnessIconSpec, rememberHarnessIcons } from "../shared/harnessIcons";
import { liveModes, permissionModes, reportsModes, reportsNoModes } from "./permissionModes";
import { handoffPromptId, namesHandoffTurn } from "./cloudHandoffTurn";
import { STALL_CHECK_MS, type StallCause, quietDelay, stallLine, stallTiming } from "./stallLog";
import { hostTurn, hostTurnState } from "./hostTurnState";
import { bridgedWatch } from "./watchBannerModel";
import type { PlanBuildReply, PlanBuildTarget, PlanCompareReply } from "./permissions/planBuild";
import {
  MEMORY_OFFER,
  memoryOfferFromRecord,
  memoryRequestFailed,
  memoryRequestStarted,
  memoryRowId,
  settleMemoryOffer,
} from "./conversation/memoryInbox";
import { readTurnShots, type TurnShotPair } from "./turnChanges/turnShots";
import {
  coachIdOf,
  coachOfferFromRecord,
  coachRowId,
  PROMPT_COACH,
  promptCoachFromRecord,
} from "./conversation/promptCoach";
import { promptCoachDismissed, rememberPromptCoachDismissed } from "./conversation/promptCoachDismissed";
import { promptCoachEnabled } from "./chatDisplay";
import { PromptHeads, type PromptHead } from "./promptHeads";
import {
  PRESET_APPROVAL,
  PresetApprovalFold,
  presetApprovalAsk,
  presetApprovalClosed,
  presetApprovalDecision,
  presetApprovalFailed,
  presetApprovalSending,
  type PresetApproval,
  type PresetApprovalChange,
  type PresetApprovalOutcome,
} from "./conversation/presetApproval";

export type AcpmuxHostConfig = {
  protocolVersion: number;
  /// `acpmux-bridge`: the app's host owns the socket and its tokens (bridgeSocket.ts); this page
  /// gets neither endpoint nor token. `acpmux-websocket`: a real socket, only for the browser dev
  /// slot (devHost.ts) and mock mode.
  transport: "acpmux-websocket" | "acpmux-bridge";
  endpoint?: string;
  token?: string;
  /** The shipped /app/ browser shell authenticates its own device on every socket. */
  browserDevice?: boolean;
  sessionId?: string;
  /** A pane opened as a new chat: do not fall back to the most recent session; the first prompt creates one. */
  newSession?: boolean;
  /** A tab's recorded session (`sessionId`) must exist. When the daemon has no such session, or it
   * goes away, the pane says so rather than showing another chat, and marks nothing seen. */
  sessionMustExist?: boolean;
  /** A new chat's working directory, inherited from the tab it was opened from. */
  cwd?: string;
  /** Text the composer starts with. Shown, never sent by itself. */
  draft?: string;
  /** A new chat's first prompt, sent once the client connects (onboarding's first task). */
  prompt?: string;
  /** Attachments of the seeded prompt, with file references on this chat's machine. */
  promptAttachments?: ComposerAttachment[];
  /** The model a new chat starts on before its first prompt. */
  model?: string;
  /** Explicit startup harness; omitted uses the existing daemon default. */
  harness?: string;
  /** Validated peer selected by the host's New Agent Chat action. */
  peer?: string;
  /** An outside Claude Code or Codex chat this pane resumes once it connects. */
  adopt?: AcpmuxAdopt;
  /** A chat opened for its workspace (Cmd-I's chat dock): its first prompt carries the workspace
   *  context (workspaceContext.ts), hidden from the transcript. */
  workspaceContext?: boolean;
};

/** A harness's own session for acpmux to adopt (`_meta.acpmux.adopt`). */
export type AcpmuxAdopt = {
  harness: string;
  agentSessionId: string;
  ifLive?: "fork" | "open";
  /** Show the chat and follow it without running it, until Take Over (acpmux `hub/watch.rs`). */
  watch?: boolean;
};

/** `session/new` params: the host's cwd when it gave one, else acpmux's default. An adopt
 *  sends no cwd: acpmux resumes the chat where its harness recorded it. */
/// Where a new session starts: `cwd` when given; another machine (`peer`) or no project never
/// inherits this tab's folder, which is a path on this Mac (the peer starts where it defaults).
export function newSessionHost(
  host: Pick<AcpmuxHostConfig, "cwd" | "adopt">,
  cwd: string | undefined,
  peer: string | undefined,
  noProject: boolean,
): Pick<AcpmuxHostConfig, "cwd" | "adopt"> & { peer?: string } {
  return cwd ? { cwd, peer } : noProject || peer ? { peer } : { ...host, peer };
}

/// The page's `initialize` params. The app's relay checks them against its params rule
/// (AcpmuxPaneMethods+Params.swift `knownParams`), and `schemas/agent-pane/initialize-params.json`
/// holds both sides to the same keys: a key the rule does not know refuses every connection.
export function initializeParams() {
  return {
    protocolVersion: 1,
    clientInfo: { name: "cmux-react-agent-pane", version: "1" },
    clientCapabilities: {},
    // A peer's list comes as one `_acpmux/peer_rows_changed`, read by the next follow
    // (`SessionPager.peerRowsChanged`); an acpmux before it ignores the key and sends each row.
    _meta: { acpmux: { peerRowBatches: true } },
  };
}

export function newSessionParams(
  host: Pick<AcpmuxHostConfig, "cwd" | "adopt"> & { peer?: string },
  harness?: string,
  noProject = false,
  model?: string,
  additionalDirectories?: readonly string[],
): Record<string, unknown> {
  if (host.adopt)
    return {
      mcpServers: [],
      _meta: { acpmux: { harness: harness ?? host.adopt.harness, adopt: host.adopt } },
    };
  return {
    ...(host.cwd ? { cwd: host.cwd } : {}),
    mcpServers: [],
    // The folders the chat sees beside its own (extraFolders.ts, cmux#32811): the machine's own
    // paths, never its cwd; left out for none.
    ...(additionalDirectories?.length ? { additionalDirectories: [...additionalDirectories] } : {}),
    _meta: {
      acpmux: {
        harness,
        ...(host.peer ? { peer: host.peer } : {}),
        // The model the page showed, for a chat on another machine (acpmux `model_request`).
        ...(model ? { model } : {}),
        // Do not work in a project: the host starts the chat in its agent-home folder, not the
        // workspace's (AcpmuxPathPolicy), and strips this before acpmux sees it.
        ...(noProject ? { noProject: true } : {}),
      },
    },
  };
}

/** What an `adopt.live` refusal's details offer: a fork (Claude Code), and the holding process. */
/// What a `turn_retrying` record says the live line shows (acpmux hub/turn_retry.rs).
export function readTurnRetry(msg: Record<string, unknown>): AcpmuxTurnRetry {
  const count = (value: unknown) =>
    typeof value === "number" && Number.isInteger(value) && value > 0 ? value : undefined;
  const attempt = count(msg.attempt);
  const maxRetries = count(msg.maxRetries);
  const errorStatus = count(msg.errorStatus);
  const error = typeof msg.error === "string" && msg.error.trim() ? msg.error.trim() : undefined;
  return {
    ...(attempt !== undefined && { attempt }),
    ...(maxRetries !== undefined && (attempt === undefined || attempt <= maxRetries) && { maxRetries }),
    ...(errorStatus !== undefined && { errorStatus }),
    ...(error !== undefined && { error }),
  };
}

function liveDetails(details: unknown): { canFork: boolean; command?: string } {
  const d = details && typeof details === "object" ? (details as Record<string, unknown>) : {};
  return {
    canFork: d.canFork === true,
    ...(typeof d.command === "string" && d.command ? { command: d.command } : {}),
  };
}

/** True when a `session/new` result resumed `adopt`. A daemon without adopt ignores the request
 *  and starts a fresh chat, whose `agentSessionId` is its own or absent. */
export function adoptedBy(result: any, adopt: AcpmuxAdopt): boolean {
  return result?._meta?.acpmux?.agentSessionId === adopt.agentSessionId;
}

/// A session log record (acpmux's `SessionEvent`); the pane reads `msg`, a raw JSON-RPC message
/// or acpmux's payload, loosely.
export type EventRecord = Pick<SessionEvent, "seq" | "at" | "dir" | "kind"> & {
  sessionId?: string;
  msg: Record<string, any>;
};
/// The one place the pane takes acpmux's records as `EventRecord`s.
const records = (events: SessionEvent[] | undefined): EventRecord[] => (events ?? []) as EventRecord[];
type Session = Record<string, any> & { sessionId: string };
type Reply = {
  id: number | string;
  result?: any;
  error?: { message?: string; code?: unknown; data?: unknown };
};
type Notification = { method: string; params?: any };
type Listener = (snapshot: AcpmuxSnapshot) => void;
/// The snapshot's catalog: one empty array, so equal snapshots compare by identity.
const NO_CATALOG: AcpmuxSnapshot["catalog"] = Object.freeze([]) as unknown as AcpmuxSnapshot["catalog"];

/// A hint that a harness is likely next, so acpmux can warm its adapter (cmux-tui acpmux lane).
export const PREWARM_METHOD = "_acpmux/prewarm";
/// New Project (newtab/newProject.ts, acpmux server/project_new.rs).
export const PROJECT_NEW_METHOD = "_acpmux/project_new";
/// Reconnects a Claude Code chat's MCP server (reconnectMcp); listed in `initialize` where served.
export const MCP_RECONNECT_METHOD = "_acpmux/mcp/reconnect";

/// Most reads of a chat's running limit one step makes when each is overtaken in flight
/// (`readRunningLimit`): enough for an attach and a record landing together, never a loop.
const LIMIT_READS = 3;
/// The waits before each new read of the events a lag dropped, after a failed one
/// (`readMissedAfterLag`): about 15 s in all, then the pane reports the failure.
const LAG_RETRY_MS = [250, 500, 1_000, 2_000, 4_000, 8_000];
/// Finished turns' stored records to read back (`repairTurns`): after `afterSeq` through `endSeq`.
type TurnRepair = { sessionId: string; generation: number; afterSeq: number; endSeq: number; attempt: number };
/// How long a lag read may be out before the stall check stops leaving the hole to it
/// (`checkStall`): every retry's wait plus a margin. A read whose reply never comes (an acpmux
/// replaced under the bridge drops it) no longer holds the chat's recovery off.
const LAG_READ_HOLDS_STALL_MS = LAG_RETRY_MS.reduce((sum, ms) => sum + ms, 0) + 5_000;
/// The longest wait between reconnects (`scheduleReconnect`): a pane that kept failing while the
/// laptop slept or the network was down tries again within this once it is back, never minutes or
/// hours later. A wake (`online`, the page shown again) reconnects at once (`reconnectNow`).
const RECONNECT_MAX_MS = 10_000;
/// How many withdrawn queue prompts a snapshot names (`queueWithdrawn`).
const QUEUE_WITHDRAWN_KEPT = 16;
/// A `usage_update` acpmux marked as one model call's own (claude_stdio/inbound.rs, Claude Code's
/// streamed message_delta) carries the prompt-side counts plus `outputTokens`. A turn's marked
/// calls add their output tokens, subagents' calls included. Every other usage record is the
/// context a harness holds (Claude Code's result repeats its last call's for the context ring;
/// other harnesses, whatever their family, report only that), which does not add up.
const isCallUsage = (update: any) => update?._meta?.acpmux?.call === true;
/// The generated side of one model call. Older daemons only sent `used`, which is a context
/// snapshot and must never be mistaken for output; those calls therefore do not contribute.
const callOutputTokens = (update: any): number | undefined => {
  const value = Number(update?.outputTokens ?? update?.output_tokens);
  return Number.isFinite(value) && value >= 0 ? value : undefined;
};
/// acpmux's `contextBreakdown` (a Claude Code chat's /context), or unset when it sent none.
const contextBreakdownOf = (value: any): AcpmuxContextBreakdown | undefined =>
  value && typeof value === "object" && Array.isArray(value.categories) ? value : undefined;
/// The part of the held context the agent took before the conversation (its system prompt, tools
/// and memory), when the harness reports it on a usage record (`_meta.acpmux.setup`). Only a
/// count within what is used counts; without one the context ring's card draws one bar.
const usageSetup = (update: any, used: number): number | undefined => {
  const setup = Number(update?._meta?.acpmux?.setup);
  return Number.isFinite(setup) && setup > 0 && setup <= used ? setup : undefined;
};
const SESSION_INFO_KIND = "session_info_update";
/// The agent's guess at the next prompt after a turn (acpmux claude_stdio/prompt_suggestions.rs):
/// `suggestion` a string, or null to take it back. Never a transcript row. It comes on the attach's
/// "transcript" event stream, live only: pages leave it out (hub/paging.rs `matches_live`, #33085).
const SUGGESTION_KIND = "prompt_suggestion";
/// A line where the chat's model or route changed (conversation/SessionStartNote.tsx): its id is
/// this and the init line's seq.
const SESSION_START_ROW = "session-start";
/// A Claude model id without its `[1m]` window, to compare the chat's own model with the one its
/// init line names.
const baseModel = (model: string | undefined) => model?.replace(/\[1m\]$/i, "");
/// A record that opens a turn: older pages split before one, so each holds whole turns. A steer
/// joins the running turn, so it opens none.
/// A read of the chat's prompt index (`DirectAcpmuxClient.readPromptIndex`): its rows once it
/// answered; `read` while it is out; `tries` reads so far, and when a failed one may be read again.
type PromptIndexRead = {
  sessionId: string;
  generation: number;
  /// The index once read, as columns (promptHeads.ts): no object a prompt.
  heads?: PromptHeads;
  failed?: boolean;
  read?: Promise<boolean>;
  cancel?: () => void;
  tries: number;
  retryAt: number;
};
/// How long a prompt index read may take before it counts as failed and may be read again: a peer's
/// own read deadline is 30 s (acpmux `server/peer_forward.rs`).
const PROMPT_INDEX_DEADLINE_MS = 35_000;
/// The back-off after a failed prompt index read, times the reads so far.
const PROMPT_INDEX_RETRY_MS = 2_000;
/// Reads of the prompt index a chat's snapshots start by themselves; a hover asks past them.
const PROMPT_INDEX_TRIES = 3;
/// The snapshot's `earlierPrompts` when there are none: one list, so the rail's memo holds.
const NO_EARLIER_PROMPTS = PromptHeads.EMPTY;

/// How soon after a question was declined the person's prompt still counts as its answer: the hat
/// sends the typed reply right after the decline, so this only has to cover one round trip.
const ANSWERED_IN_CHAT_MS = 10_000;
/// A question the person declined (Skip, or a cancel with no reject option): never one a Stop or
/// acpmux ended, which the person did not answer at all.
const declined = (question: AgentQuestion) =>
  question.state.kind === "cancelled" && (question.state.reason === undefined || question.state.reason === "skipped");
const inChat = (question: AgentQuestion): AgentQuestion => ({
  ...question,
  state: { kind: "cancelled", reason: "answeredInChat" },
});

const startsTurn = (event: EventRecord) =>
  event.dir === "mux" && event.kind === "user_message" && event.msg?.steer !== true;

/// A prompt the Chief sent a subagent (its task, a tell, a steer, a restart or interrupt message):
/// optchat-chief ids those `optchat-<kind>:…` (`subagents.rs` PROMPT_PREFIX), so the pane can say
/// who wrote it rather than draw it as the reader's own. The Chief's own turns (`optchat:…`, the
/// person's messages it forwards) and typed prompts are not marked.
const sentByChief = (msg: { promptId?: unknown }) =>
  typeof msg.promptId === "string" && msg.promptId.startsWith("optchat-");

/// Page size caps acpmux applies (maxBytes): opening a chat, then each older page as the reader scrolls up.
/// An older page was 400 records and 256 KiB: a page of a tool-heavy chat was a few turns, so a
/// scroll up waited on a daemon round trip every few screens (Leo, 2026-11-10: "the infinite
/// scrolling does kind of work, but it's too slow. It needs to do more. It needs to do a lot").
const OPEN_PAGE_BYTES = 128 * 1024;
const OLDER_PAGE_BYTES = 1024 * 1024;
/// Records one older page asks for at most (`limit`), with OLDER_PAGE_BYTES.
const OLDER_PAGE_RECORDS = 2000;
/// An older ask the reader is not scrolling up for (`loadOlder`'s `rising` false: an open filling
/// the view, a chat at rest within OLDER_AHEAD_VIEWPORTS of its loaded top) reads the page it read
/// before older pages grew, and reads none ahead. The reader's next screens are a short page away,
/// and a 1 MiB page drawn above a chat just opened was its settle's cost: a switch to a god session
/// settled in 464 ms instead of 152 (bench/chat-switch.bench.ts, chat_switch.god.unread.settled, #42298).
export const OLDER_REST_PAGE_BYTES = 256 * 1024;
export const OLDER_REST_PAGE_RECORDS = 400;
/// The prompt index's byte cap (`loadPromptIndex`), as it was before older pages grew.
const PROMPT_INDEX_BYTES = 256 * 1024;
/// Pages read ahead of the reader once an older read lands (`readOlderAhead`): the next ask at the top
/// is answered from memory while the reader reads down through what just landed.
const OLDER_AHEAD_PAGES = 4;
/// Pages a read through a seq (`loadThrough`: a jump to the unread line or a rail tick) asks for
/// at once, each for its own stretch of seqs (`readWindow`), so a jump far back waits on about one
/// round trip instead of one per page.
const WINDOW_PARALLEL_PAGES = 16;
/// An indexed rail jump reads a bounded window around the prompt instead of walking every page
/// between the open tail and the target. The cache key is a sequence bucket; adjacent buckets are
/// warmed after the target page so a fast drag has a page ready before its next frame.
const INDEXED_PAGE_RADIUS = 240;
const INDEXED_PAGE_LIMIT = 400;
const INDEXED_PAGE_CACHE_LIMIT = 5;
/// Gap pages (`fillIndexedGaps`) merged per redraw after the first: each redraw refolds from the gap
/// to the tail, so drawing every page would cost pages × (gap + tail) folds on a long gap.
const INDEXED_GAP_PAGES_PER_DRAW = 4;

/// Prompt rows that stand in for the turns between a directly fetched target page and the held
/// tail. Keeping these rows in sequence order prevents the minimap from shrinking while pages warm.
export function indexedPromptPlaceholders(
  index: PromptHeads,
  heldSeqs: ReadonlySet<number>,
  pageStart: number,
  tailStart: number,
): AcpmuxRow[] {
  const out: AcpmuxRow[] = [];
  // Only the prompts between the page and the tail: a bounded gap, never the whole index.
  for (
    let at = PromptHeads.countBefore(index, pageStart + 1);
    at < index.length && PromptHeads.seq(index, at) < tailStart;
    at += 1
  ) {
    const seq = PromptHeads.seq(index, at);
    if (!heldSeqs.has(seq)) out.push({ ...PromptHeads.row(index, at), seq, kind: "user" });
  }
  return out;
}
/// The most pages of one subagent's own records a subagent pane reads (`readSubagentLog`).
const SUBAGENT_LOG_PAGES = 8;
/// How many times an attach is asked when its reply is of another session or machine than the row
/// names when it answers (the row changed while it was out); past that the open fails.
const ATTACH_TRIES = 3;
/// What an attach of a chat watches of its row (`AcpmuxDirectClient.attachWatch`): the session
/// and machine it asked of, and each one the row named since.
type AttachWatch = {
  sessionId: string;
  asked?: { createdAt: unknown; peer: unknown };
  seen: Map<string, { createdAt: unknown; peer: unknown }>;
  /// The newest queue summary received while attach awaits its page/read side work. The attach
  /// reply may predate this summary (a restart restores queues in the background), so its empty
  /// detail must not overwrite the row delivered by session_changed.
  latestSummary?: { session: SessionSummary; seq?: number };
};

/// The reads a chat draws with besides its page: its permission groups and its handoff, asked
/// together with its attach so the chat waits on one round trip, not two (`startAttachReads`).
type AttachReads = { permissions: Promise<void>; handoff?: Promise<void> };
/// An attach as it was sent: its reply, and the reads asked with it.
/// `dropped`: the open let it go with its chat not shown (`dropEarly`); one still waiting on the
/// switch then sends nothing (`unsent`).
type SentAttach = {
  attaching: Promise<any>;
  reads?: AttachReads;
  hold?: boolean;
  dropped?: boolean;
  unsent?: boolean;
};
/// The attach of the chat a page opens, asked with the chat list instead of after it (`askEarly`),
/// so the chat's first frame waits on one daemon reply after the handshake. `live` holds the chat's
/// records that came before the open took the attach, applied in order once it does: as if the
/// attach had been asked there, after any kept tail was drawn.
type EarlyAttach = {
  sessionId: string;
  generation: number;
  watch: AttachWatch;
  sent: SentAttach;
  live: EventRecord[];
};

/// A reconnect's attach that asks only the records after `afterSeq`, the seq its held rows are whole
/// through (`open`), instead of the chat's newest page again: on a long chat that page is up to
/// `OPEN_PAGE_BYTES` per reconnect for records the pane already holds (cmuxterm-hq#14027). `laid`:
/// the reply was taken as that forward page (`attachWatched`); unset when the attach fell back to
/// the newest page. `hasMore`: the log holds more records past the page; `lastSeq`: the log's end
/// when the page was read.
type ForwardAttach = { afterSeq: number; laid?: boolean; hasMore?: boolean; lastSeq?: number };

/// A settled promise's value, unread: the race waits on the settling only.
const ignore = () => undefined;

/// The session row an attach reply carries, when it is `sessionId`'s on this machine. A reply
/// acpmux forwarded from a peer names that peer at its top level (`server/peer_forward.rs`), and
/// its `session` is the peer daemon's own detail, with no `peer`: either name makes it another
/// machine's chat.
/// Fields of a `_acpmux/resolve` card (acpmux hub/locate.rs `card`) that are not a list row's.
const CARD_ONLY = new Set(["host", "link", "beads", "matches"]);

/// The list row a `_acpmux/resolve` reply's card stands for, when it is the chat `asked` names (its
/// id, name, harness session id or qualified id), not merely one whose name it starts. Null fields
/// are left out, as a list row leaves them out.
export function resolvedRow(reply: unknown, asked: string): Session | undefined {
  const card = (reply as { session?: unknown } | null | undefined)?.session as Record<string, unknown> | undefined;
  if (!card || typeof card !== "object" || typeof card.sessionId !== "string" || !card.sessionId) return undefined;
  const names = [card.sessionId, card.name, card.agentSessionId, card.qualifiedSessionId];
  if (!names.includes(asked)) return undefined;
  const row: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(card))
    if (value !== null && value !== undefined && !CARD_ONLY.has(key)) row[key] = value;
  return row as Session;
}

export function attachedLocalRow(result: unknown, sessionId: string): Session | undefined {
  const reply = result as { session?: unknown; peer?: unknown } | undefined;
  const row = reply?.session as Session | undefined;
  if (!row || typeof row !== "object" || row.sessionId !== sessionId) return undefined;
  return typeof row.peer === "string" || typeof reply?.peer === "string" ? undefined : row;
}

/// The settled view an attach answered with (`settled`, acpmux `settled-attach-v1`): where its frame
/// ends and the turn ends a fork can go through. Undefined for a plain attach reply (`settled: null`,
/// an older acpmux, or a reply that does not say).
export type SettledView = { lastSeq: number; forkSeqs: readonly number[] };

export function settledView(result: unknown): SettledView | undefined {
  const settled = (result as { settled?: unknown } | undefined)?.settled;
  if (!settled || typeof settled !== "object") return undefined;
  const view = settled as { lastSeq?: unknown; forkSeqs?: unknown };
  if (typeof view.lastSeq !== "number" || !Number.isFinite(view.lastSeq)) return undefined;
  const forkSeqs = Array.isArray(view.forkSeqs)
    ? view.forkSeqs.filter((seq): seq is number => typeof seq === "number" && Number.isFinite(seq))
    : [];
  return { lastSeq: view.lastSeq, forkSeqs };
}

/// The records of a settled attach page that go on from the rows drawn before the attach was asked
/// (a kept tail, the Mac's copy, a reconnect's own records): those after `drawnThrough`, when the
/// page meets it. `heldThrough` is the newest seq held now (0 for none). A live record applied while
/// the attach was out (`takeEarly`, `apply` during its awaits) past `drawnThrough` was reduced before
/// the page's records under it, so the page is not laid on top of it. Undefined, and the caller
/// merges the page and folds it all again (`rebuild`), when the page does not meet the rows (a gap),
/// nothing is held, a live record came past the rows, the page adds nothing past them, or the reply
/// is no settled view. Never empty: an empty append would read as met while it drew none of the page.
export function settledAppend(
  page: readonly EventRecord[],
  drawnThrough: number,
  heldThrough: number,
  view: SettledView | undefined,
): EventRecord[] | undefined {
  if (!view || drawnThrough <= 0 || heldThrough <= 0 || heldThrough > drawnThrough || page.length === 0)
    return undefined;
  const oldest = Math.min(...page.map((event) => event.seq));
  if (oldest > drawnThrough + 1) return undefined;
  const after = page.filter((event) => event.seq > drawnThrough).sort((a, b) => a.seq - b.seq);
  return after.length > 0 ? after : undefined;
}

/// The opener of the turn an attach page starts inside, as the reply names it (acpmux reads it
/// with the page, `server/requests/turn_opener.rs`): `undefined` when the reply does not say (an
/// older acpmux) or the rows start before the page (a kept tail drawn first), so the pane reads it
/// itself (`fetchTurnOpener`); `null` when there is none to show.
function servedTurnOpener(
  result: { turnOpener?: unknown } | undefined,
  page: EventRecord[],
  rows: EventRecord[],
  sessionId: string,
): EventRecord | null | undefined {
  if (!result || !("turnOpener" in result)) return undefined;
  const first = page[0];
  if (!first || rows[0]?.seq !== first.seq) return undefined;
  const opener = result.turnOpener as EventRecord | null | undefined;
  if (!opener || typeof opener !== "object" || typeof opener.seq !== "number") return null;
  if (opener.seq >= first.seq || !startsTurn(opener)) return null;
  return { ...opener, sessionId: opener.sessionId ?? sessionId };
}

/// Whether the row named another session or machine than the attach asked of at some point since
/// the ask (A then B, or A, B, A again), or than the reply's session (`replyOf`).
function strayedFrom(watch: AttachWatch, replyOf?: unknown): boolean {
  const asked = watch.asked;
  return [...watch.seen.values()].some(
    (seen) =>
      seen.peer !== asked?.peer ||
      (typeof seen.createdAt === "number" &&
        ((typeof asked?.createdAt === "number" && seen.createdAt !== asked.createdAt) ||
          (typeof replyOf === "number" && seen.createdAt !== replyOf))),
  );
}
/// One older read is one bounded page. It is published as soon as it arrives, so a long active turn
/// never blocks the reader on a whole-turn scan (Leo 2026-10-29: "I can't fucking scroll up past the
/// current fucking turn after restarting"). The transcript asks again while the reader remains at
/// the loaded edge, keeping each gesture and render bounded; the pages read ahead
/// (`readOlderAhead`) answer those asks from memory. A rail jump's window (`readWindow`) lands whole.
const OLDER_PAGES_PER_ASK = 1;
/// A chat adopted or watched from Claude Code has older turns in its transcript, past the newest
/// page its log was seeded with: acpmux logs a `native_history` record (its `before` cursor, a byte
/// offset into the transcript) and serves the pages before it (acpmux hub/native_history.rs).
const NATIVE_HISTORY_KIND = "native_history";
/// Native pages one older read takes at most when the ones it reads hold no turn the pane lacks
/// (pages it already holds, after its kept tail drew them). Each reads at most 16 MiB of transcript.
const NATIVE_PAGES_PER_ASK = 4;
/** How long a session list that failed to load waits before it is read once more. */
const SESSION_REREAD_MS = 2000;
/// How often the pane reads the peers again while a missing chat's machine is still connecting.
const MISSING_RECHECK_MS = 2000;

/// The machine a chat ran on, from its kept summary (this page's, or the app host's). A summary
/// with no `peer` says nothing: the attach of a peer's chat gives that daemon's own detail, which
/// names none (acpmux server/peer_forward.rs adds `peer` to the reply, not to its session).
/// The machine a `HOST/NAME` tab id names, else undefined (an id, a bare name).
function namedMachine(id: string): string | undefined {
  const slash = id.indexOf("/");
  return slash > 0 && slash < id.length - 1 && !id.includes(" ") ? id.slice(0, slash) : undefined;
}

function keptPeer(sessionId: string): string | undefined {
  const peer = keptTail(sessionId)?.summary?.peer;
  return typeof peer === "string" && peer ? peer : undefined;
}

/// Each chat's slash commands from its last attach on this page (a few dozen chats): back on a
/// chat, `/` lists them at once instead of "No commands" until the attach (Leo 2026-10-19).
const knownCommands = new Map<string, SlashCommand[]>();
function rememberCommands(sessionId: string, commands: SlashCommand[]) {
  knownCommands.delete(sessionId);
  knownCommands.set(sessionId, commands);
  while (knownCommands.size > 32) knownCommands.delete(knownCommands.keys().next().value!);
}
/// What a chat's last read left, so opening it again draws it on the frame the open lands instead
/// of after acpmux's attach round trip (Leo 2026-10-20: a chat "should be instant if cached"). The
/// attach still goes out and lays what acpmux holds now over it; an unchanged chat replays to the
/// same rows, so nothing moves (test/chat-open-perf.test.ts). The tails themselves live in
/// tailCache.ts, which also shares them with the next tab through the app host.
/// The longest a chat switch keeps the chat before on screen while the new one attaches. Match the
/// cold-open hold: a busy daemon must not expose a blank transcript between the old and new chats.
const SWITCH_HOLD_MS = 1_500;
/// The longest a chat drawn from its own rows (a copy kept while its machine was down) keeps that
/// frame while its machine's page and the records between them are read (`reattachPeerCopy`): the
/// copy, marked offline, is a whole transcript, where the page alone has a hole in it. The hold
/// ends as soon as both are in or either fails; this limit is only for a read that never answers.
const GAP_HOLD_MS = 30_000;
/// Reading ahead (``AcpmuxDirectClient.readAhead``): the user, 2026-10-21, "switching between
/// different chiefs and messages/conversations needs instant loading of messages". A chat the page
/// never read waited on its attach behind the hold above; the recent ones are read while the pane is
/// idle instead, so the first switch to one draws from memory (test/chat-switch-prefetch.test.ts).
/// How many of the list's most recent chats are read ahead, how many reads run at once (each is
/// one `_acpmux/events` page, read-only, no attach), how long after the pane's chat is in the first
/// pass starts, and how stale a read-ahead may get before a change in the list reads it again.
const READ_AHEAD_RECENT = 12;
const READ_AHEAD_LANES = 2;
const READ_AHEAD_DELAY_MS = 600;
const READ_AHEAD_REFRESH_MS = 5_000;
/// The longest a switch waits on a read-ahead already out for its chat (a hover just before the
/// press): about one local round trip, far less than the attach it stands in for.
const READ_AHEAD_WAIT_MS = 150;
/// The longest a connect keeps the pane's last snapshot on screen while it reads the chat.
const OPEN_HOLD_MS = 1500;
/// What a chat switch or open waits on: the chat list's watch, the attach and the detach before it,
/// the visibility change and the transcript reads. Each answers in one daemon round trip, so one
/// asked without a deadline of its own still counts as waiting after CHAT_OPEN_PROGRESS_MS, and the
/// daemon liveness probe runs: after acpmux restarted under an open socket, a click in the sidebar
/// gives the dead socket up and the pane reconnects to the new daemon by itself. Before, these
/// waited forever and every click did nothing until the app restarted (Leo, ask-fdfc5d8abb: "I
/// can't access any directly clicking from my workspace ... it fixes itself"). Not session/prompt
/// or the other requests that stay open while the agent works. Only a progress threshold
/// (`expectReply`): a slow daemon that answers the probe keeps every request.
const CHAT_OPEN_METHODS = new Set([
  "_acpmux/watch",
  "_acpmux/attach",
  "_acpmux/detach",
  "_acpmux/view",
  "_acpmux/events",
]);
const CHAT_OPEN_PROGRESS_MS = 10_000;
/// The chat whose last open drew its kept tail while connecting and then failed to connect: the
/// page's retries draw it only once acpmux answers, so a daemon that is down does not make the
/// rows come and go with every retry (`drawTailWhileConnecting`). Cleared by a connect that works.
let connectFailedAfterEarlyTail: string | undefined;
/// The promptId acpmux gives a task result's prompt: `offer-result-<offerId>` (hub/offers.rs).
const OFFER_RESULT_PROMPT = "offer-result-";
/// acpmux's bracket around a turn the agent ran on its own (conversation/backgroundTurns.ts).
const BACKGROUND_TURN_KIND = "background_turn";
/// acpmux's refusals of an answer to a card it no longer has (hub/secrets.rs): a restart lost it,
/// or the agent stopped waiting.
/// The capability id an acpmux with `_acpmux/agent_login/*` names (and its versioned spelling).
const AGENT_LOGIN_CAPABILITIES = ["agent_login", "agent-login-v1"];
/// The feature a new chat's wire names when its machine signs its agent in before the chat has a
/// session (RemoteAcpmuxWire `agent_login_machine`, cmux-tui `agent-session-login-machine-v1`):
/// a login step that names no chat runs there. Only a remote wire names it; a local acpmux never
/// does, so a step with no chat never signs this Mac's agent in from a Cloud chat's card.
const AGENT_LOGIN_MACHINE_FEATURE = "agent_login_machine";
/// The capability id an acpmux that serves the memory inbox names (`memory_offer` records and
/// `_acpmux/memory_resolve`): without it no memory card draws.
const MEMORY_INBOX_CAPABILITY = "memory-inbox-v1";
/// The capability id an acpmux that serves the prompt coach names (`coach_offer` and `coach` records,
/// `_acpmux/prompt_coach`): without it the page never asks for a rewrite.
const PROMPT_COACH_CAPABILITY = "prompt-coach-v1";
/// The feature a chat on another machine names (Cloud, SSH: the app's RemoteAcpmuxWire) where that
/// machine opens the chat's side chats there, with `_acpmux/side_chat`.
const SIDE_CHAT_FEATURE = "side_chat";
const SECRET_GONE = ["no secret request with that id", "the agent stopped waiting"];
/// The capability id an acpmux that keeps a turn's before and after picture of the chat's page names
/// (`_acpmux/turn_shots`, hub/turn_shots.rs): without it no turn reads its pictures.
const TURN_SHOTS_CAPABILITY = "turn-shots-v1";

const objectValue = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const stringValue = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value.trim() : undefined;

/** Keep only the stable ACP subject fields that make an approval's target legible. */
function permissionScopeFromMessage(raw: any, toolCall: any): AcpmuxPermissionScope | undefined {
  const subject = objectValue(raw?.subject);
  const subjectTool = subject?.type === "tool_call" ? objectValue(subject.toolCall) : undefined;
  const call = subjectTool ?? objectValue(toolCall);
  const input = objectValue(call?.rawInput);
  const app = stringValue(input?.app) ?? stringValue(input?.application) ?? stringValue(input?.appName);
  if (app) return { kind: "app", value: app };
  const locations = (Array.isArray(call?.locations) ? call.locations : [])
    .map((location: unknown) => stringValue(objectValue(location)?.path))
    .filter((path: string | undefined): path is string => path !== undefined);
  const resource = locations[0] ?? stringValue(input?.file_path) ?? stringValue(input?.path) ?? stringValue(input?.url);
  if (resource && call?.kind !== "execute") return { kind: "resource", value: resource };
  const cwd = (subject?.type === "command" ? stringValue(subject.cwd) : undefined) ?? stringValue(input?.cwd);
  return cwd ? { kind: "directory", value: cwd } : undefined;
}

export function permissionFromMessage(message: any, selectedSessionId: string): AcpmuxPermission | undefined {
  const envelope = message ?? {};
  const raw = envelope?.request ?? envelope;
  const sessionId = envelope?.sessionId ?? raw?.sessionId;
  const permissionId = envelope?.permissionId ?? raw?.permissionId;
  if (!permissionId || sessionId !== selectedSessionId) return undefined;
  const question = questionFromPermission({
    permissionId: String(permissionId),
    session: sessionId,
    request: raw,
  });
  const claudeMeta =
    raw.toolCall?._meta?.claude && typeof raw.toolCall._meta.claude === "object"
      ? raw.toolCall._meta.claude
      : undefined;
  const subject = objectValue(raw.subject);
  const subjectTool = subject?.type === "tool_call" ? objectValue(subject.toolCall) : undefined;
  const subjectCommand = subject?.type === "command" ? subject : undefined;
  const toolCall = raw.toolCall ?? subjectTool;
  const suggestions = Array.isArray(claudeMeta?.suggestions)
    ? claudeMeta.suggestions.flatMap((suggestion: unknown) => {
        if (typeof suggestion === "string" && suggestion.trim()) return [suggestion.trim()];
        if (!suggestion || typeof suggestion !== "object") return [];
        const rules = (suggestion as { rules?: unknown }).rules;
        return Array.isArray(rules)
          ? rules.flatMap((rule: unknown) => {
              if (typeof rule === "string" && rule.trim()) return [rule.trim()];
              if (!rule || typeof rule !== "object") return [];
              const value = rule as { toolName?: unknown; ruleContent?: unknown };
              const tool = typeof value.toolName === "string" ? value.toolName.trim() : "";
              const content = typeof value.ruleContent === "string" ? value.ruleContent.trim() : "";
              return [content || tool].filter(Boolean);
            })
          : [];
      })
    : [];
  return {
    ...(question ? { question } : {}),
    permissionId: String(permissionId),
    groupId: typeof envelope.groupId === "string" ? envelope.groupId : undefined,
    turnId: typeof envelope.turnId === "string" ? envelope.turnId : undefined,
    // ACP v2's request title names the approval itself; a subject tool title is its operation fallback.
    title: raw.title ?? toolCall?.title,
    // A string, or an argv array read the way the transcript's Shell block reads it (`sh -lc` unwrapped).
    command:
      typeof toolCall?.command === "string"
        ? toolCall.command
        : (shellCommand(toolCall?.rawInput) ??
          stringValue(subjectCommand?.command) ??
          (typeof raw.command === "string" ? raw.command : undefined)),
    description:
      typeof claudeMeta?.description === "string"
        ? claudeMeta.description
        : typeof toolCall?.description === "string"
          ? toolCall.description
          : typeof raw.description === "string"
            ? raw.description
            : undefined,
    rule:
      suggestions.length > 0
        ? translate("permission.claude.alwaysAllowRule", { rules: suggestions.join(", ") })
        : typeof toolCall?.rule === "string"
          ? toolCall.rule
          : typeof raw.rule === "string"
            ? raw.rule
            : undefined,
    kind: toolCall?.kind ?? (subjectCommand ? "execute" : undefined),
    ...(typeof toolCall?.toolCallId === "string" ? { toolCallId: toolCall.toolCallId } : {}),
    scope: permissionScopeFromMessage(raw, toolCall),
    externalAccess: externalAccessFromRequest(raw),
    diffs: permissionDiffs(toolCall),
    plan: permissionPlan(toolCall, claudeMeta),
    pending: true,
    options: (raw.options ?? []).map((option: any) => ({
      id: String(option.optionId ?? option.id),
      name: String(option.name ?? option.optionId),
      allow: String(option.kind ?? "").startsWith("allow"),
      kind: typeof option.kind === "string" ? option.kind : undefined,
      description: typeof option.description === "string" ? option.description : undefined,
      rule:
        typeof option.rule === "string"
          ? option.rule
          : typeof option.suggestion === "string"
            ? option.suggestion
            : undefined,
    })),
  };
}

/// A queue row's entry. acpmux's ask to resume a failed subagent (`retry`) comes from its `queued`
/// record (`subagentRetryNotice`) or a listing (`listedRetry`); every rebuild of the entry passes it on.
function queuedEntry(
  id: string,
  prompt: string,
  next: boolean,
  sending = false,
  images?: readonly QueuedPromptImage[],
  message?: IncomingMessage,
  author?: Participant,
  inlineParts?: PromptContentPart[],
  retry?: SubagentRetryNotice,
  hold: Hold = {},
  inbox?: InboxNotice,
): QueuedPrompt {
  return {
    id,
    prompt,
    ...(next ? { next } : {}),
    ...(sending ? { sending } : {}),
    ...(images?.length ? { images: [...images] } : {}),
    ...(message ? { message } : {}),
    ...(inbox && !message ? { inbox } : {}),
    ...(author ? { author } : {}),
    ...(inlineParts?.length ? { inlineParts } : {}),
    ...(retry && !message && !inbox && !author ? { retry } : {}),
    ...(hold.awaitingOwner ? { awaitingOwner: true } : {}),
    ...(hold.revision !== undefined ? { revision: hold.revision } : {}),
    ...(hold.awaitingOwner && hold.updating ? { updating: true } : {}),
    ...(hold.awaitingOwner && hold.listedRevision !== undefined ? { listedRevision: hold.listedRevision } : {}),
    ...(hold.awaitingOwner && hold.turnId ? { turnId: hold.turnId } : {}),
  };
}

/// `entry` with `from`'s Stop hold (`heldByStop`): an entry rebuilt from a record or a list keeps it
/// while it is still another agent's message. An edit makes it the person's (hub/queue_edit.rs), and
/// a person's Stop holds only other agents' messages.
function keepStopHold(entry: QueuedPrompt, from: QueuedPrompt | undefined): QueuedPrompt {
  return from?.heldByStop && !entry.heldByStop && entry.message ? { ...entry, heldByStop: true } : entry;
}

/// A guest's prompt's hold (acpmux `awaitingOwner`, `revision`). THE RULE: a held prompt is
/// approvable only when the pane holds its authoritative record (a `queued` / `queue_updated`
/// record, or a read of one) for its current revision. `revision` is set only from such a record,
/// with that record's text, images and parts; a listing (acpmux's queue list, a 200-character
/// preview) never sets it, whatever its preview looks like. `listedRevision` is the newest revision
/// acpmux named anywhere; `updating` (not approvable) holds while the record the pane has is older
/// than it, or there is none.
type Hold = {
  awaitingOwner?: boolean;
  revision?: number;
  updating?: boolean;
  listedRevision?: number;
  turnId?: string;
};
const heldHold = (
  awaitingOwner: boolean | undefined,
  revision: number | undefined,
  listedRevision: number,
  turnId: string | undefined,
): Hold => ({
  awaitingOwner,
  revision,
  ...(listedRevision >= 0 ? { listedRevision } : {}),
  ...(turnId ? { turnId } : {}),
  updating: awaitingOwner === true && (revision === undefined || listedRevision > revision),
});
/// The hold an authoritative record carries (`queued`, `queue_updated`): its revision is the text's.
const holdOf = (msg: any, had?: Hold): Hold => {
  const revision = typeof msg?.revision === "number" ? msg.revision : had?.revision;
  const awaitingOwner = typeof msg?.awaitingOwner === "boolean" ? msg.awaitingOwner : had?.awaitingOwner;
  const turnId = typeof msg?.turnId === "string" && msg.turnId ? msg.turnId : had?.turnId;
  return heldHold(awaitingOwner, revision, Math.max(revision ?? -1, had?.listedRevision ?? -1), turnId);
};
/// The hold a listing names: never a record. It only says which revision is current (a list older
/// than the record the pane holds names a lower one, which changes nothing).
function listedHold(entry: any, had: QueuedPrompt | undefined): Hold {
  const awaitingOwner = typeof entry?.awaitingOwner === "boolean" ? entry.awaitingOwner : had?.awaitingOwner;
  const listed = typeof entry?.revision === "number" ? entry.revision : -1;
  const turnId = typeof entry?.turnId === "string" && entry.turnId ? entry.turnId : had?.turnId;
  return heldHold(
    awaitingOwner,
    had?.revision,
    Math.max(listed, had?.listedRevision ?? -1, had?.revision ?? -1),
    turnId,
  );
}

/// Whether listed chat `session` is the one `name` names: its name, its short name, or, for a chat
/// on another machine (listed as `<peer>/<name>`), its bare name, which its messages sign with.
function namesChat(session: Session, name: string): boolean {
  const listed = session.name?.trim();
  return (
    listed === name || session.shortName?.trim() === name || (!!session.peer && listed === `${session.peer}/${name}`)
  );
}

/// The listed chat a tab's id names when it is no chat's session id: an agent opened the tab with
/// the chat's name ("cloud-demo"), its short name, or its harness's own session id (acpmux's
/// `agentSessionId`, which `acpmux ls --json` prints first) in place of acpmux's id, and the tab
/// recorded that. `session`: the one chat it names, which the tab opens and rebinds to. `ambiguous`:
/// it names more than one, so the pane cannot tell which (chatUnavailable.ts `gone`). Neither: it
/// names nothing listed (the chat may be on a machine not connected yet).
export function chatNamedBy(id: string, sessions: readonly Session[]): { session?: string; ambiguous: boolean } {
  if (!id || sessions.some((session) => session.sessionId === id)) return { ambiguous: false };
  const named = sessions.filter(
    (session) =>
      (typeof session.agentSessionId === "string" && session.agentSessionId === id) || namesChat(session, id),
  );
  if (named.length === 1) return { session: named[0]!.sessionId, ambiguous: false };
  return { ambiguous: named.length > 1 };
}

/// A `queued` record that is another agent's message, as its received line reads it once it runs
/// (conversation/incomingMessage.ts), else as acpmux's `fromAgent` names it (`acpmux send --from`),
/// its text without a leading "[name]" or "From name:" that only repeats the sender. Undefined for
/// the person's own prompt. `preview`: the text is a queue list's one-line preview, which acpmux may
/// cut inside the broker's label; a record's text is the whole message.
export function queuedMessage(msg: any, context?: IncomingContext, preview = false): IncomingMessage | undefined {
  const text = String(msg?.text ?? "");
  const incoming = incomingPrompt(text, msg, context, preview);
  if (incoming?.kind === "message") return incoming.message;
  // The list's `fromAgent` is the name acpmux shows the agent, an unverified one with its suffix
  // (conversation/senderIdentity.ts): the line names it bare and marks it.
  const sender = bareSender(typeof msg?.fromAgent === "string" ? msg.fromAgent : "");
  const name = sender.name;
  if (!name) return undefined;
  const lead = queuedText(text, msg, preview).trimStart();
  const named = [`[${name}]`, `From ${name}:`].find((prefix) => lead.toLowerCase().startsWith(prefix.toLowerCase()));
  const harness = typeof msg?.fromHarness === "string" && msg.fromHarness.trim() ? msg.fromHarness.trim() : undefined;
  return {
    name,
    ...(harness ? { harness } : {}),
    ...(sender.declared ? { unverified: true as const } : {}),
    text: (named ? lead.slice(named.length) : lead).trim(),
    raw: text,
  };
}

/// A queued message's text without the broker's label (conversation/relayEnvelope.ts): a preview
/// cut inside it reads as none of it; a whole message keeps words that only start like one, and
/// loses a head with no closing line only when acpmux proved its sender (a relay record or a stamped
/// session, senderIdentity.ts `provenanceAuthenticated`). Anyone can type a head, so a sender named
/// in `fromAgent` alone gets only a whole closed label left out.
function queuedText(text: string, msg: any, preview: boolean): string {
  if (preview) return withoutRelayLabel(text);
  const provenance = msg?._meta?.provenance;
  const relayed = provenanceAuthenticated(
    provenance && typeof provenance === "object"
      ? provenance
      : msg?.fromRelay
        ? { fromRelay: msg.fromRelay }
        : undefined,
  );
  return relayed ? withoutRelayLabelOfMessage(text) : withoutRelayEnvelope(text);
}

/// A `queued` record that is acpmux's inbox notice (provenance `inbox_notice`), as its threads.
/// Undefined for any other prompt. acpmux's queue list names no provenance, so a notice the pane
/// has only that list of shows as a queue row until its record is read.
export function queuedInbox(msg: any, context?: IncomingContext): InboxNotice | undefined {
  const incoming = incomingPrompt(String(msg?.text ?? ""), msg, context);
  return incoming?.kind === "inbox" ? incoming.notice : undefined;
}

/// The images a `queued` or `queue_updated` record names (`images`, in its prompt's order), each
/// with its bytes as a data URL when the record's `prompt` carries them, so its row draws them
/// without reading them back. acpmux names only the images it could keep: the bytes go with the
/// names only when the two lists match.
function recordImages(msg: any): QueuedPromptImage[] {
  const named = promptImages(msg?.images);
  const blocks = (Array.isArray(msg?.prompt) ? msg.prompt : []).filter(
    (block: any) => block?.type === "image" && typeof block.data === "string",
  );
  if (blocks.length !== named.length) return named;
  return named.map((image, index) => ({
    ...image,
    src: `data:${image.mimeType};base64,${blocks[index].data}`,
  }));
}

/// The images of a prompt this pane sends, from the composer's attachments: its queue row shows
/// them from the send on, before acpmux names them.
export function attachedImages(attachments: readonly ComposerAttachment[]): QueuedPromptImage[] {
  return attachments.flatMap((attachment) =>
    attachment.kind === "image" && attachment.data
      ? [
          {
            id: attachment.id,
            mimeType: attachment.mimeType,
            name: attachment.name,
            src: `data:${attachment.mimeType};base64,${attachment.data}`,
            local: true,
            ...(attachment.source ? { source: attachment.source } : {}),
          },
        ]
      : [],
  );
}

/// `images` named by acpmux, each keeping the bytes the pane already had for it.
function withKnownBytes(images: QueuedPromptImage[], known: readonly QueuedPromptImage[] | undefined) {
  const bytes = new Map((known ?? []).flatMap((image) => (image.src ? [[image.id, image.src] as const] : [])));
  // The source each image's `queued` record named, which acpmux's list does not carry: by
  // occurrence, since byte-identical images share an id but not a source.
  const sources = new Map<string, (AttachmentSource | undefined)[]>();
  for (const image of known ?? []) sources.set(image.id, [...(sources.get(image.id) ?? []), image.source]);
  const seen = new Map<string, number>();
  return images.map((image) => {
    const at = seen.get(image.id) ?? 0;
    seen.set(image.id, at + 1);
    const src = bytes.get(image.id);
    const source = image.source ?? sources.get(image.id)?.[at];
    return src || source ? { ...image, ...(src ? { src } : {}), ...(source ? { source } : {}) } : image;
  });
}

/// How long a send waits for acpmux before its row says it is still sending, and before it fails
/// (plans/cmux-next/composer-delivery-DESIGN.md): `failMs` on a connection with no native relay
/// journal, `localFailMs` on one to this Mac's acpmux (a busy session's acknowledgement may be slow,
/// and the page cannot see whether the journal kept the prompt). Tests shorten them.
/// `hostWaitMs`: how long a prompt waits for an acpmux that is starting or reconnecting
/// (sendWhenReady.ts): with no end, as long as its chat is shown and its client open. A machine
/// that rebooted comes back in minutes, and the prompt goes then by itself, never "Not sent" and
/// Retry (Leo, 2026-11-12: "try what? no, it should just automatically do stuff"). Tests shorten it.
export const deliveryTiming = {
  slowMs: 10_000,
  failMs: 60_000,
  localFailMs: 300_000,
  hostWaitMs: Number.POSITIVE_INFINITY,
};

const DELIVERY_RANK: Record<PromptDelivery["state"], number> = {
  sending: 0,
  delivered: 1,
  read: 2,
  failed: 3,
};

/// The hop a refused or failed send stopped at: a transport error is the pane's connection to
/// acpmux (a missing gesture is the host's refusal, so acpmux's hop), a failure after acpmux took
/// the prompt is the agent's turn, anything else is acpmux's answer.
export function deliveryHop(code: string | undefined, taken: boolean): PromptDeliveryHop {
  if (taken) return "agent";
  if (code?.startsWith("transport.") && code !== "transport.gesture_required") return "connection";
  return "acpmux";
}

const oneLine = (text: string) => text.split(/\s+/).filter(Boolean).join(" ");

/// acpmux's queue (a session's `queue`, in order) over the one the pane has. acpmux lists each
/// prompt's preview (its first 200 characters on one line), so a prompt the pane read whole from
/// its `queued` record keeps its whole text, and one sent now stays next. A prompt's author is the
/// one acpmux lists, else the one its newest `queued` or `queue_updated` record named (`authors`, by
/// prompt id: null when that record named none), else the one the pane had: an attach's page can
/// hold a teammate's edit without the `queued` record before it.
/// A chat's `rollingSummary` (acpmux `RollingSummary`) as the pane's summary field: nothing
/// before its first summary or for a blank one.
export function rollingSummaryOf(raw: unknown): { rollingSummary?: { text: string; next?: string } } {
  if (!raw || typeof raw !== "object") return {};
  const { text: rawText, next: rawNext } = raw as Record<string, unknown>;
  const text = typeof rawText === "string" ? rawText.trim() : "";
  if (!text) return {};
  const next = typeof rawNext === "string" ? rawNext.trim() : "";
  return { rollingSummary: next ? { text, next } : { text } };
}

/// A queue list's `subagentRetry` (acpmux `QueuedSubagentRetry`) as a row's resume.
function listedRetry(raw: unknown): SubagentRetryNotice | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const { agentId, name, error } = raw as Record<string, unknown>;
  const text = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
  const [a, n, e] = [text(agentId), text(name), text(error)];
  if (!a && !n) return undefined;
  return { ...(n ? { name: n } : {}), ...(a ? { agentId: a } : {}), ...(e ? { error: e } : {}) };
}

/// The listing's resume, keeping the name and error the pane recovered for the same agent (from the
/// `queued` record's words) where the listing names none: a resume queued before acpmux put them
/// in its provenance lists only the agent id.
function withRecovered(
  listed: SubagentRetryNotice | undefined,
  had: SubagentRetryNotice | undefined,
): SubagentRetryNotice | undefined {
  if (!listed || !had || !listed.agentId || listed.agentId !== had.agentId) return listed;
  const name = listed.name ?? had.name;
  const error = listed.error ?? had.error;
  return { ...listed, ...(name ? { name } : {}), ...(error ? { error } : {}) };
}

export function mergeQueue(
  current: readonly QueuedPrompt[],
  listed: readonly any[],
  authors?: ReadonlyMap<string, Participant | null>,
  edited?: ReadonlySet<string>,
): QueuedPrompt[] {
  const known = new Map(current.map((entry) => [entry.id, entry]));
  // A background finish waiting for its turn is never a queued card (bgDoneNotice.ts), whichever
  // listing brings it back (an attach, a reload, a session change).
  const merged = listed
    .filter((entry) => !String(entry?.promptId ?? "").startsWith("bg-done-"))
    .map((entry) => {
      const id = String(entry?.promptId ?? "");
      const preview = String(entry?.prompt ?? entry?.preview ?? "");
      const had = known.get(id);
      // A held prompt keeps its record's content whatever the list's preview says (THE RULE, Hold).
      const heldRecord = had?.awaitingOwner === true && had.revision !== undefined && entry?.awaitingOwner !== false;
      const whole = had !== undefined && (heldRecord || oneLine(had.prompt).startsWith(preview.replace(/…$/, "")));
      // acpmux lists its images (after a reload or a restart too); one that lists none (an older
      // acpmux) keeps those the pane had.
      const listedImages = Array.isArray(entry?.images)
        ? withKnownBytes(promptImages(entry.images), had?.images)
        : had?.images;
      // The `queued` record the pane read names the sender, while its text is still the one listed
      // (an edit the pane missed makes it the person's, as acpmux does). The list's `fromAgent`
      // says so too: null is the person's (an edit past the preview's cut leaves its head the
      // same), and a name is an agent's, also for a row the pane never read the record of (a
      // reload). An older acpmux lists none.
      const listed = entry?.fromAgent;
      // Keep the complete queue record here: when `fromAgent` is absent, the
      // sender lives in `_meta.provenance` and `queuedMessage` must see it.
      // Override only the text with acpmux's current preview; a stale full
      // prompt would make the provenance branch look like an edit.
      // An agent's message the person edited, or a prompt acpmux could not attribute, lists null
      // but its provenance (acpmux `QueuedPromptSummary.provenance`): its card names that sender.
      const listedProvenance =
        entry?.provenance && typeof entry.provenance === "object" ? (entry.provenance as unknown) : undefined;
      const listedMessage = queuedMessage(
        {
          ...entry,
          text: preview,
          fromAgent: listed,
          fromHarness: entry?.fromHarness,
          ...(listedProvenance ? { _meta: { ...entry?._meta, provenance: listedProvenance } } : {}),
        },
        undefined,
        true,
      );
      const kept = whole ? had.message : undefined;
      // A queue listing may carry the full provenance even when its compatibility `fromAgent`
      // field is absent. Preserve that parsed agent message; only an explicit null says that the
      // prompt is the person's own. Without this, a queued agent_message was rendered as a plain
      // user prompt until it left the queue, so its received card (and reply actions) disappeared.
      const message = listed === null ? (listedProvenance ? listedMessage : undefined) : (kept ?? listedMessage);
      // acpmux's inbox notice: the threads acpmux lists (`inboxNotice`, its provenance), else those its
      // `queued` record named while the text is the same. An edit makes it the person's (hub/queue.rs
      // drops the provenance), so it keeps none. A notice whose record the pane never read (a chat
      // reopened on a recent page) drew as the person's queued prompt under "Paused after an error"
      // (Leo, 2026-11-05: "Why is the thing still queued? ... don't show these kinds of things").
      // One that names no thread, or from an acpmux that lists none (its `[inbox]` text from acpmux),
      // is still no prompt of the person's: no thread to draw, and no queue row.
      const listedInbox =
        entry?.inboxNotice && typeof entry.inboxNotice === "object"
          ? (queuedInbox({ text: preview, _meta: { provenance: entry.inboxNotice } }) ?? { threads: [] })
          : !("inboxNotice" in (entry ?? {})) && entry?.client === "acpmux" && preview.startsWith("[inbox] ")
            ? (had?.inbox ?? { threads: [] })
            : undefined;
      const inbox =
        message || edited?.has(id)
          ? undefined
          : (listedInbox ?? (whole && !("inboxNotice" in (entry ?? {})) ? had.inbox : undefined));
      // A list that names the field says whose it is, null the owner's (acpmux lists it for every
      // prompt once it serves authors); an older acpmux lists none, and the records read decide.
      const hold = listedHold(entry, had);
      // Text, images and parts of a held prompt are its record's, together (never a list's images
      // under a record's text).
      const heldKeepsRecord = heldRecord && hold.awaitingOwner === true;
      const author =
        entry && typeof entry === "object" && "author" in entry
          ? queuedAuthor(entry.author)
          : authors?.has(id)
            ? (authors.get(id) ?? undefined)
            : had?.author;
      const built = queuedEntry(
        id,
        whole ? had.prompt : preview,
        had?.next === true,
        false,
        // A held prompt's images are its text's: the record the pane holds while it keeps that text.
        heldKeepsRecord ? had?.images : listedImages,
        message,
        author,
        heldKeepsRecord ? had?.inlineParts : (recordedPromptParts(entry, had?.inlineParts) ?? had?.inlineParts),
        // A resume comes from acpmux's word only: the listing's `subagentRetry` (from the prompt's
        // `subagent_retry` provenance, which an edit drops), else, from an acpmux that lists none,
        // the one its `queued` record gave while the text is the same (the preview that text or cut
        // from it). An edit, seen or missed, drops it; a null listing removes it.
        message || inbox || author || edited?.has(id)
          ? undefined
          : "subagentRetry" in (entry ?? {})
            ? withRecovered(listedRetry(entry.subagentRetry), had?.retry)
            : whole && (preview.endsWith("…") || oneLine(had.prompt) === preview)
              ? had.retry
              : undefined,
        // A guest's prompt that waits for the owner (acpmux lists `awaitingOwner`; an older one, none).
        hold,
        inbox,
      );
      // Whether a person's Stop holds it, as acpmux lists it (`heldByStop`); listed unheld, it was
      // let go. A list without the field (an older acpmux) keeps what the records said.
      const next =
        entry?.heldByStop === true && entry?.held !== false
          ? { ...built, heldByStop: true as const }
          : entry?.held === false || entry?.heldByStop === false
            ? built
            : keepStopHold(built, had);
      // An entry the list left as it was stays the same object: the transcript keys a waiting message's
      // card by its entry (queuedMessages.ts), so an unchanged one draws nothing again.
      return had && sameQueuedEntry(had, next) ? had : next;
    });
  // The chat's own change carries its whole queue each time (a step, its usage): the same entries
  // give the same list back, so nothing that reads the queue sees a change.
  return merged.length === current.length && merged.every((entry, index) => entry === current[index])
    ? (current as QueuedPrompt[])
    : merged;
}

/// Whether two queue entries say the same: their fields, and what their images, message, author and
/// inline parts hold (small records, compared whole).
function sameQueuedEntry(a: QueuedPrompt, b: QueuedPrompt): boolean {
  return (
    a.id === b.id &&
    a.prompt === b.prompt &&
    a.next === b.next &&
    a.sending === b.sending &&
    a.heldByStop === b.heldByStop &&
    JSON.stringify(a.images) === JSON.stringify(b.images) &&
    JSON.stringify(a.message) === JSON.stringify(b.message) &&
    JSON.stringify(a.inbox) === JSON.stringify(b.inbox) &&
    JSON.stringify(a.author) === JSON.stringify(b.author) &&
    JSON.stringify(a.inlineParts) === JSON.stringify(b.inlineParts) &&
    JSON.stringify(a.retry) === JSON.stringify(b.retry) &&
    a.awaitingOwner === b.awaitingOwner &&
    a.revision === b.revision &&
    a.updating === b.updating &&
    a.listedRevision === b.listedRevision &&
    a.turnId === b.turnId
  );
}

/// What a sent prompt goes as (its blocks and inline parts) and what its row shows (text and pasted
/// spans): one shape for a send and for the Not sent row a relaunch draws again (unsentPrompts.ts).
export function sentPromptShape(
  input: string,
  carried: ComposerAttachment[],
  options: Parameters<typeof promptBlocks>[2],
) {
  const blocks = promptBlocks(input, carried, options);
  const inline = inlinePrompt(input, carried);
  const isFrame = frameTextOf(imageNames(blocks));
  const fileDisplay = inline?.display ?? stripFileDisplay(blocks, carried);
  const { text, pasted } = inline
    ? blocks.reduce(
        (shown, block) => {
          // A video's frames note is the agent's; the bubble draws the video's tile.
          if (block.type !== "text" || isFrame(block.text)) return shown;
          if (shown.text) shown.text += "\n";
          const start = shown.text.length;
          shown.text += block.text;
          if (block._meta?.cmux.pasted) shown.pasted.push({ start, end: shown.text.length });
          return shown;
        },
        { text: "", pasted: [] as { start: number; end: number }[] },
      )
    : shownPrompt(promptText(input, carried, options), carried);
  return { blocks, inline, fileDisplay, text, pasted };
}

export function settleOptimisticPrompt(
  rows: Map<string, AcpmuxRow>,
  promptRows: Map<string, string>,
  message: any,
  removeRow = true,
): string | undefined {
  const promptId = typeof message?.promptId === "string" ? message.promptId : undefined;
  if (!promptId) return undefined;
  const rowId = promptRows.get(promptId);
  if (removeRow && rowId) rows.delete(rowId);
  promptRows.delete(promptId);
  return rowId;
}

/// The reply segment acpmux stamped on an `agent_message_chunk` record (`_meta.acpmux.segment`,
/// hub/stream.rs): one id for every chunk of one run of reply text, whatever page holds them.
export function replySegment(event: EventRecord): string | undefined {
  const segment = (event.msg as any)?.params?._meta?.acpmux?.segment;
  return typeof segment === "string" && segment.length > 0 && segment.length <= 200 ? segment : undefined;
}

export function mergeEventRecords(...batches: EventRecord[][]): EventRecord[] {
  const bySequence = new Map<number, EventRecord>();
  for (const event of batches.flat()) bySequence.set(event.seq, event);
  return [...bySequence.values()].sort((left, right) => left.seq - right.seq);
}

/// Older paging asks for records strictly before `events[0]`. Prepending that page avoids sorting
/// and copying the entire retained log through a Map on every page; the filter also makes retries
/// idempotent when a reconnect replays the boundary record.
export function prependOlderEventRecords(older: EventRecord[], events: EventRecord[]): EventRecord[] {
  if (older.length === 0) return events;
  const first = events[0]?.seq;
  const fresh = first === undefined ? older : older.filter((event) => event.seq < first);
  return fresh.length === 0 ? events : [...fresh, ...events];
}

/// The most held records a rebuild folds again (`rebuild`): a pane open on a busy chat holds every
/// record streamed since it opened, and a lag read or a repaired turn refolded all of them.
export const REBUILD_WINDOW = 5_000;
/// How many records a chat left open keeps when it lets go of its oldest (`shedOlderHeld`): one older page's
/// worth (`OLDER_PAGE_RECORDS`), so scrolling up past the cut reads one page to have them back. Kept at the
/// rebuild's whole window (5,000) and shed at twice that, a chat left open held 5,000 to 10,000 records: in the
/// god log 3,000 to 6,500 rows, against a 600-turn chat's 2,800 whole, and each streamed thought and tool call
/// cost 1.5x to 1.8x that chat's (bench/transcript-replay.bench.ts, FIXTURE=god; Leo, 2026-11-12: "even if a
/// chat is long, there should be no percievable difference").
export const HELD_KEPT = OLDER_PAGE_RECORDS;
/// How many records a chat left open holds before its oldest are let go (`shedOlderHeld`): twice what a cut
/// keeps, so it sheds at most once per `HELD_KEPT` records, each time dropping what leaves in place (`dropHeldRun`).
export const HELD_RECORDS = 2 * HELD_KEPT;
/// How many more records a chat that could not shed past `HELD_RECORDS` takes before it tries again
/// (`shedOlderHeld`): the try walks the newest `HELD_KEPT` records, so a refused one costs O(1) a record.
const HELD_RETRY = HELD_KEPT / 4;

/// The index of the first record in `events` (oldest first) at or after `seq`: a binary search, so
/// a read of the newest records costs O(log held), not a walk over every one.
export function firstHeldFrom(events: readonly EventRecord[], seq: number): number {
  let low = 0;
  let high = events.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (events[middle]!.seq < seq) low = middle + 1;
    else high = middle;
  }
  return low;
}

/// The index of the last record in `events` (oldest first) at or before `seq`, -1 when none is. A row's order need
/// not be a held seq (a prompt drawn before its record comes back sits at `latest + 0.5`, `placeLocalLast`; a page read
/// with a kinds filter leaves holes), so a cut moved back to where a row begins steps to the record before it, never
/// to the same record again (`spanCut`).
export function heldAtOrBefore(events: readonly EventRecord[], seq: number): number {
  const at = firstHeldFrom(events, seq);
  return events[at]?.seq === seq ? at : at - 1;
}

/// Where a cut at `events[cut]` goes back to so that no row is drawn from records on both sides of it: to where the
/// row spanning it begins (`spanningFrom`), until none spans it. Each pass moves the cut to an older record, so it ends
/// within `cut` passes; 0 or less when that reaches the oldest record held. Stepping to the first record at or after
/// where the row begins instead (`firstHeldFrom`) found the same cut again when no held record lay between, and spun
/// with the page's main thread held: Leo's NIGHTLY renderer at 100% CPU and 14 GB, its pages unclosable.
export function spanCut(events: readonly EventRecord[], cut: number, spanningFrom: (seq: number) => number): number {
  while (cut > 0) {
    const { seq } = events[cut]!;
    const from = spanningFrom(seq);
    if (from >= seq) break;
    const older = heldAtOrBefore(events, from);
    // ends: `older` holds a seq at or before `from`, below `seq`, so the cut moves to an older record every pass. A
    // pass that does not (a `spanningFrom` that breaks that) is logged and keeps the cut, never spins.
    if (older >= cut) {
      console.error(`agent pane: a shed cut at seq ${seq} did not move back (row from ${from}); kept`);
      break;
    }
    cut = older;
  }
  return cut;
}

/// Where a rebuild of `events` (held, oldest first) starts folding again: 0 to fold them all, when
/// they fit `window` (`REBUILD_WINDOW`); else the turn start at or before both the newest `window`
/// records and `changedFrom`, the oldest record that changed, and before `openSince` (when a
/// subagent still running started). A turn is folded whole, so the rows above the cut are the same
/// as before it, and the turn before it ended first (`endsTurnBefore`). 0 when no turn starts there.
export function rebuildCut(
  events: readonly EventRecord[],
  changedFrom: number,
  openSince = Infinity,
  window = REBUILD_WINDOW,
): number {
  if (events.length <= window) return 0;
  let at = Math.min(events.length - window, firstHeldFrom(events, changedFrom));
  // Back to the turn a subagent still running started in (`openSince`, its start time).
  while (at > 0 && events[at]!.at >= openSince) at -= 1;
  while (at > 0 && !(startsTurn(events[at]!) && endsTurnBefore(events, at))) at -= 1;
  return at;
}

/// Where a chat left open lets go of its oldest records inside a turn that has not ended (`shedOlderHeld`): a
/// coordinator's turn takes prompts and messages for days and never reaches a `turn_result`, so a cut only at a
/// turn start (`rebuildCut`) never came and the pane held every record it streamed (Leo's coordinator chat: 3.58 GB
/// and 110% CPU). The newest `keep` records, moved back over a subagent still running (`openSince`) and to the
/// oldest row a record past the cut changed (`spanningFrom`, so no row is drawn from only part of its records),
/// until neither moves it. 0 when that reaches the oldest record held. The rows kept are drawn as a page that
/// starts inside the turn is, under the turn's prompt (`turnOpener`).
export function midTurnCut(
  events: readonly EventRecord[],
  keep: number,
  openSince: number,
  spanningFrom: (seq: number) => number,
): number {
  if (events.length <= keep) return 0;
  let at = events.length - keep;
  for (;;) {
    const moved = at;
    while (at > 0 && events[at]!.at >= openSince) at -= 1;
    if (at <= 0) return 0;
    const from = spanningFrom(events[at]!.seq);
    if (from < events[at]!.seq) at = heldAtOrBefore(events, from);
    if (at <= 0) return 0;
    if (at === moved) return at;
  }
}

/// Whether the turn before `events[at]` ended before it: its `turn_result` comes after the agent's
/// last update before `at`. A prompt into a running turn (no result between) goes on drawing that
/// turn's reply in the same row, so a refold that started at it would draw the reply's rest again.
function endsTurnBefore(events: readonly EventRecord[], at: number): boolean {
  for (let index = at - 1; index >= 0; index -= 1) {
    const event = events[index]!;
    if (event.dir === "mux" && event.kind === "turn_result") return true;
    if (event.dir !== "mux" || startsTurn(event)) return false;
  }
  return true;
}

/// Merges `added` into the held `events` (oldest first) in place: records past the newest held one
/// are appended, others merged into the newest part from the oldest of them, so a read of a recent
/// hole costs O(hole), not a copy of every held record. A record already held is replaced.
export function mergeIntoHeld(events: EventRecord[], added: readonly EventRecord[]): void {
  if (added.length === 0) return;
  const sorted = [...added].sort((left, right) => left.seq - right.seq);
  const from = firstHeldFrom(events, sorted[0]!.seq);
  if (from === events.length) {
    let last = events.at(-1)?.seq ?? -Infinity;
    for (const event of sorted)
      if (event.seq > last) {
        events.push(event);
        last = event.seq;
      } else events[events.length - 1] = event;
    return;
  }
  const tail = mergeEventRecords(events.slice(from), sorted);
  // Not `splice(from, n, ...tail)`: a spread of a long tail overflows the call's argument limit.
  events.length = from;
  for (const event of tail) events.push(event);
}

export function applySupersededMessage(
  rows: Map<string, AcpmuxRow>,
  messageRows: Map<string, string[]>,
  superseded: Set<string>,
  oldMessageId: string,
): void {
  superseded.add(oldMessageId);
  for (const rowId of messageRows.get(oldMessageId) ?? []) rows.delete(rowId);
  messageRows.delete(oldMessageId);
}

/** The session to attach after connect: the selected one, else the most recent unless the pane is a new chat. */
export function initialSession(
  selected: string | undefined,
  sessions: { sessionId: string }[],
  newSession?: boolean,
): string | undefined {
  if (selected) return selected;
  return newSession ? undefined : sessions[0]?.sessionId;
}

/// The file changes in a tool call's content (ACP `diff` items), placed by the call's locations.
export function toolDiffs(content: any, locations: any): AcpmuxFileDiff[] | undefined {
  if (!Array.isArray(content)) return undefined;
  const lines = new Map<string, number>();
  for (const location of Array.isArray(locations) ? locations : [])
    if (
      typeof location?.path === "string" &&
      Number.isInteger(location.line) &&
      location.line > 0 &&
      !lines.has(location.path)
    )
      lines.set(location.path, location.line);
  const diffs = content
    .filter((item: any) => item?.type === "diff" && typeof item.path === "string" && typeof item.newText === "string")
    .map((item: any): AcpmuxFileDiff => ({
      path: item.path,
      oldText: typeof item.oldText === "string" ? item.oldText : undefined,
      newText: item.newText,
      line: lines.get(item.path),
      ...(item.fragment === true || item._meta?.acpmux?.fragment === true ? { fragment: true as const } : {}),
      ...canonicalOf(item),
    }));
  return diffs.length ? diffs : undefined;
}

/// The canonical path acpmux recorded beside an item's path (hub/tool_paths.rs), as `canonical`:
/// a `diff` item's or location's `_meta.acpmux.canonicalPath`, or a diff this page placed again.
/// Composed (NFC), as every canonical path the page compares is (turnCheckpoint.ts `checkpointFiles`).
function canonicalOf(item: any): { canonical?: string } {
  const canonical = item?._meta?.acpmux?.canonicalPath ?? item?.canonical;
  return typeof canonical === "string" && canonical ? { canonical: canonical.normalize("NFC") } : {};
}

/// A call's locations with their canonical paths read (`canonicalOf`).
function readLocations(locations: any): AcpmuxLocation[] | undefined {
  if (!Array.isArray(locations)) return undefined;
  return locations.map((location: any) =>
    location && typeof location === "object" ? { ...location, ...canonicalOf(location) } : location,
  );
}

/// The input's file and the canonical path acpmux recorded for it on the update (`_meta.acpmux`).
function inputPath(update: any): { path: string; canonical: string } | undefined {
  const path = update.rawInput?.file_path;
  const { canonical } = canonicalOf(update);
  return typeof path === "string" && canonical ? { path, canonical } : undefined;
}

/// Claude Code's result for a Write that made a new file ("File created successfully at: …"). An
/// overwrite says the file was updated, and its old text is not in the call.
const CREATED_RESULT = /^\s*File created successfully at\b/;

/// An edit call's change read from its own input, for a call whose content carries no `diff` item:
/// Claude Code's Edit (`old_string`, `new_string`), MultiEdit (`edits`), and Write (`file_path`,
/// `content`) once its `result` says it created the file; a Write over a file has no old text to
/// diff against, so it stays a path without counts. Each is marked `fragment` (the page never saw the
/// file around it, so Undo, turnChanges/model.ts `fileUndo`, never writes a file back from these)
/// and `fromInput` (a later input replaces them).
export function inputDiffs(rawInput: any, result?: string, canonical?: string): AcpmuxFileDiff[] | undefined {
  const path = rawInput?.file_path;
  if (typeof path !== "string" || !path) return undefined;
  const mark = {
    fragment: true as const,
    fromInput: true as const,
    ...(canonical ? { canonical } : {}),
  };
  if (typeof rawInput.content === "string")
    return result !== undefined && CREATED_RESULT.test(result)
      ? [{ path, newText: rawInput.content, ...mark }]
      : undefined;
  const edits: any[] = Array.isArray(rawInput.edits) ? rawInput.edits : [rawInput];
  const diffs = edits
    .filter((edit) => typeof edit?.old_string === "string" && typeof edit.new_string === "string")
    .map((edit): AcpmuxFileDiff => ({
      path,
      oldText: edit.old_string,
      newText: edit.new_string,
      ...mark,
    }));
  return diffs.length ? diffs : undefined;
}

/// The ask's proposed edits. Explicit ACP diffs win over input fragments, including acpmux's Write
/// fragment with no old text, which shows the text the Write will put there (`toolFiles`). An edit
/// tool's input is read only when no diff came: there a Write's content is left out, since before
/// approval there is no result proving it creates a new file.
export function permissionDiffs(
  tool: { kind?: unknown; content?: unknown; locations?: unknown; rawInput?: unknown } | undefined,
): AcpmuxFileDiff[] | undefined {
  return toolDiffs(tool?.content, tool?.locations) ?? (tool?.kind === "edit" ? inputDiffs(tool.rawInput) : undefined);
}

/// The plan a plan approval asks about: one acpmux attached (`_meta.acpmux.plan.markdown`, as for
/// Gemini's plan file), Claude Code's ExitPlanMode input `plan`, or the plan acpmux puts in a
/// `switch_mode` ask it builds from Grok's and Cursor's own plan approvals (hub xai.rs,
/// cursor_ext.rs), from its input or else its text content. Undefined for any other ask, and for a
/// plan approval with no plan text.
export function permissionPlan(
  tool: { kind?: unknown; content?: unknown; rawInput?: unknown; _meta?: unknown } | undefined,
  claudeMeta?: { tool?: unknown },
): string | undefined {
  const attached = stringValue(objectValue(objectValue(objectValue(tool?._meta)?.acpmux)?.plan)?.markdown)?.trim();
  if (attached) return attached;
  if (claudeMeta?.tool !== "ExitPlanMode" && tool?.kind !== "switch_mode") return undefined;
  const input = stringValue(objectValue(tool?.rawInput)?.plan)?.trim();
  if (input) return input;
  const text = Array.isArray(tool?.content)
    ? tool.content
        .map((item: any) => (item?.type === "content" && item.content?.type === "text" ? item.content.text : ""))
        .filter((part: unknown): part is string => typeof part === "string" && part.trim() !== "")
        .join("\n\n")
        .trim()
    : "";
  return text || undefined;
}

/// The input an earlier event of a call carried, kept as its `inputSummary` JSON.
function storedInput(summary: string | undefined): unknown {
  if (!summary) return undefined;
  try {
    return JSON.parse(summary);
  } catch {
    return undefined;
  }
}

/// Diffs placed again by an update that brings only locations; diffs read from the input stay marked.
function placeDiffs(diffs: AcpmuxFileDiff[] | undefined, locations: any): AcpmuxFileDiff[] | undefined {
  if (!diffs || !Array.isArray(locations)) return diffs;
  const placed = toolDiffs(
    diffs.map((diff) => ({ type: "diff", ...diff })),
    locations,
  );
  return (
    placed?.map((diff, index) => (diffs[index]?.fromInput ? { ...diff, fromInput: true as const } : diff)) ?? diffs
  );
}

/// A tool call folded with an update to it. ACP updates carry only the fields that changed;
/// content, when present, replaces the call's content. `at` is the event's time: the call
/// starts at its first event and ends at the first that reports it completed or failed.
export function mergeToolItem(
  previous: AcpmuxActivity | undefined,
  update: any,
  callId: string,
  output: string,
  at?: number,
): AcpmuxActivity {
  const before = previous?.tool;
  const provenance =
    typeof update._meta?.claude?.tool === "string" || typeof update._meta?.claudeCode?.toolName === "string"
      ? {
          ...(typeof update._meta?.claude?.tool === "string" ? { claudeTool: update._meta.claude.tool } : {}),
          ...(typeof update._meta?.claudeCode?.toolName === "string"
            ? { claudeCodeToolName: update._meta.claudeCode.toolName }
            : {}),
        }
      : before?.provenance;
  const title = update.title ?? update.name;
  const status = String(update.status ?? before?.status ?? "in_progress");
  const ended = status === "completed" || status === "failed";
  const kind = update.kind ?? before?.kind;
  const locations = readLocations(update.locations) ?? before?.locations;
  // ACP sends an empty object when an update changes status or output without changing the
  // call's input. Keep the input from the initial call so a draft command never regresses to
  // the blank/Thinking state after that update.
  const hasRawInput =
    update.rawInput !== undefined &&
    update.rawInput !== null &&
    !(objectValue(update.rawInput) && Object.keys(update.rawInput).length === 0);
  // The input's file, from the update that carries the input.
  const input = hasRawInput ? inputPath(update) : before?.inputPath;
  const placed =
    update.content === undefined ? placeDiffs(before?.diffs, update.locations) : toolDiffs(update.content, locations);
  // An edit whose content names no `diff` (Claude Code's Edit, whose result is plain text) still
  // changed its file: its input has the change, read again from the latest input. A failed one
  // changed nothing. A `diff` in the content always wins over the input.
  let diffs = placed;
  if (kind === "edit" && (!placed || placed.every((diff) => diff.fromInput))) {
    const result = output || textFromContent(update.content) || before?.output;
    diffs =
      status === "failed"
        ? undefined
        : (inputDiffs(update.rawInput ?? storedInput(before?.inputSummary), result, input?.canonical) ?? placed);
  }
  return {
    kind: "tool",
    text: String(title ?? previous?.text ?? callId),
    tool: {
      id: callId,
      title: String(update.title ?? update.name ?? before?.title ?? callId),
      kind,
      status,
      inputSummary: hasRawInput ? JSON.stringify(update.rawInput) : before?.inputSummary,
      output:
        output ||
        formattedOutput(update.rawOutput) ||
        terminalOutput(update, before?.output) ||
        (update.content === undefined ? before?.output : undefined),
      command: shellCommand(update.rawInput) ?? before?.command,
      description: callDescription(update.rawInput) ?? before?.description,
      exitCode: exitCode(update) ?? before?.exitCode,
      startedAt: before?.startedAt ?? at,
      endedAt: before?.endedAt ?? (ended ? at : undefined),
      // A shell that went to the background stays there as its call's result comes in.
      ...(before?.background ? { background: before.background } : {}),
      // An approval stays on its call as the call's result comes in.
      ...(before?.approved ? { approved: true as const } : {}),
      // What a background task's end left on it (`attachReaction`) stays as later updates come in.
      ...(before?.reaction ? { reaction: before.reaction } : {}),
      locations,
      ...(input ? { inputPath: input } : {}),
      images: update.content === undefined ? before?.images : imagesFromContent(update.content),
      diffs,
      ...(provenance ? { provenance } : {}),
    },
  };
}

/// What a call says it does, in a few words: Claude Code's Bash `description` ("Run the web
/// tests"), which a command row reads instead of its raw command line.
export function callDescription(rawInput: any): string | undefined {
  const description = rawInput?.description;
  return typeof description === "string" && description.trim() ? description.trim() : undefined;
}

/// The command line a shell call ran, from `rawInput.command`: a string, or an argv array. An
/// argv that runs a script through a shell (`zsh -lc "cd x && bun test"`) shows the script;
/// otherwise a part with spaces or quotes is single-quoted, so the line reads as typed.
export function shellCommand(rawInput: any): string | undefined {
  const command = rawInput?.command;
  if (typeof command === "string") return command;
  if (!Array.isArray(command) || !command.every((part) => typeof part === "string") || !command.length)
    return undefined;
  const [program, flag, script] = command as string[];
  if (command.length === 3 && /(^|\/)(ba|z|da|fi)?sh$/.test(program!) && /^-l?c$/.test(flag!)) return script;
  return (command as string[])
    .map((part) => (/^[\w@%+=:,./-]+$/.test(part) ? part : `'${part.replace(/'/g, "'\\''")}'`))
    .join(" ");
}

const CLAIM_KINDS = new Set(["tests", "build", "lint", "typecheck", "ran"]);
const CLAIM_VERDICTS = new Set(["backed", "failed", "none"]);

/// The claims of a `claim_checks` record a page can draw; one of a kind or verdict this page does
/// not know draws nothing.
export function readClaims(raw: unknown[]): ClaimCheck[] {
  return raw.flatMap((item): ClaimCheck[] => {
    const claim = item as Record<string, unknown> | null;
    if (!claim || typeof claim.text !== "string" || !claim.text.trim()) return [];
    if (!CLAIM_KINDS.has(String(claim.kind)) || !CLAIM_VERDICTS.has(String(claim.verdict))) return [];
    return [
      {
        text: claim.text,
        kind: claim.kind as ClaimCheck["kind"],
        verdict: claim.verdict as ClaimCheck["verdict"],
        ...(typeof claim.toolCallId === "string" ? { toolCallId: claim.toolCallId } : {}),
        ...(typeof claim.command === "string" ? { command: claim.command } : {}),
      },
    ];
  });
}

/// A finished shell call's exit status: `rawOutput.exit_code` (Codex; acpmux puts the others'
/// there too, hub/tool_shell.rs), else where an agent reported it in a record logged before acpmux
/// did: pi's `_meta.terminal_exit.exit_code`, OpenCode's `rawOutput.metadata.exit`.
function exitCode(update: any): number | undefined {
  const raw = update.rawOutput;
  const code = raw?.exit_code ?? raw?.exitCode ?? update._meta?.terminal_exit?.exit_code ?? raw?.metadata?.exit;
  return typeof code === "number" ? code : undefined;
}

/// pi (pi-acp) streams a bash call's output only as `_meta.terminal_output.data`, each update the
/// part printed since the last (the terminal-in-a-tool-call `_meta` extension): it adds to what
/// the call printed so far. Undefined for an update without it.
function terminalOutput(update: any, before: string | undefined): string | undefined {
  const data = update._meta?.terminal_output?.data;
  return typeof data === "string" && data ? (before ?? "") + data : undefined;
}

/// Codex reports a shell call's output in `rawOutput` when the call carries no content.
function formattedOutput(rawOutput: any): string {
  const text = rawOutput?.formatted_output;
  return typeof text === "string" ? text : "";
}

export function textFromContent(content: any): string {
  if (typeof content === "string") return content;
  if (content?.type === "text") return String(content.text ?? "");
  // A tool call's content blocks wrap their text: `{ type: "content", content: { type: "text" } }`.
  if (content?.type === "content") return textFromContent(content.content);
  if (Array.isArray(content)) return content.map(textFromContent).join("");
  return "";
}

/// Whether a tool call update's content is text alone (a streamed shell's output so far).
function textOnlyContent(update: any): boolean {
  const content = update?.content;
  return (
    Array.isArray(content) &&
    content.length > 0 &&
    content.every(
      (block: any) => block?.type === "text" || (block?.type === "content" && block.content?.type === "text"),
    )
  );
}

/// The call a tool call record belongs to, for thinning: its id within its owner (a subagent's own
/// calls are numbered apart from the chat's, and a Codex thread names its own session).
function streamedCallKey(event: EventRecord): string | undefined {
  if (event.kind !== "tool_call" && event.kind !== "tool_call_update") return undefined;
  const params = event.msg?.params;
  const callId = params?.update?.toolCallId;
  if (typeof callId !== "string") return undefined;
  const owner = params?._meta?.acpmux?.subagent;
  return `${typeof owner === "string" ? owner : ""}\u0000${String(params?.sessionId ?? "")}\u0000${callId}`;
}

/// A record that bounds a call's updates: a prompt or a turn's start or end. An adapter can reuse a
/// call id in a later prompt, even without a new `tool_call`, so no update supersedes one across it.
const endsStreamedCalls = (event: EventRecord) =>
  event.dir === "mux" &&
  (event.kind === "user_message" ||
    event.kind === "turn_started" ||
    event.kind === "turn_end" ||
    event.kind === "turn_result" ||
    event.kind === "turn_error");

/// Each thinned record (`withoutSupersededContent`) and the seq of the update whose content made its
/// own moot (a seq, never the record: that would hold the content again), for a cut (`cutAfter`) and
/// the inspector.
const thinnedRecords = new WeakMap<EventRecord, number>();

/// `event` without its update's content, for a held tool call update whose call's next update
/// (seq `by`) carried the call's whole content again (ACP: an update's content replaces the call's).
export function withoutSupersededContent(event: EventRecord, by: number): EventRecord {
  const params = event.msg.params;
  const { content: _superseded, ...update } = params.update;
  const thinned = { ...event, msg: { ...event.msg, params: { ...params, update } } };
  thinnedRecords.set(thinned, by);
  return thinned;
}

/// `events` through `lastSeq`. A call whose newest content went with the cut gets it back on its
/// newest thinned record kept (held without its content), unless a later record kept carries content: the call still shows the whole
/// output it had, never only its first record's (a copy cut back to what the Mac confirmed).
export function cutAfter(events: readonly EventRecord[], lastSeq: number): EventRecord[] {
  const kept: EventRecord[] = [];
  // Each call's newest content among the records cut.
  const cutContent = new Map<string, { seq: number; content: unknown }>();
  for (const event of events) {
    if (event.seq <= lastSeq) {
      kept.push(event);
      continue;
    }
    const update = sessionUpdate(event);
    const callId = streamedCallKey(event);
    if (callId && update?.content !== undefined && event.seq > (cutContent.get(callId)?.seq ?? -1))
      cutContent.set(callId, { seq: event.seq, content: update.content });
  }
  if (cutContent.size === 0) return kept;
  // The calls whose newest content kept is settled: a later record kept carries content, or took it back.
  const settled = new Set<string>();
  for (let index = kept.length - 1; index >= 0; index -= 1) {
    const event = kept[index]!;
    const update = sessionUpdate(event);
    const callId = streamedCallKey(event);
    if (!callId || settled.has(callId)) continue;
    if (update?.content !== undefined) settled.add(callId);
    const by = thinnedRecords.get(event);
    const content = cutContent.get(callId);
    if (by === undefined || by <= lastSeq || !content) continue;
    settled.add(callId);
    const params = event.msg.params;
    kept[index] = {
      ...event,
      msg: { ...event.msg, params: { ...params, update: { ...params.update, content: content.content } } },
    };
  }
  return kept;
}

/// `events` with every text-only tool call update that a later text-only update of
/// the same call supersedes held without its content (`withoutSupersededContent`); a call's first
/// record keeps its own, and a call started again under its id starts over. The same array when
/// none is; otherwise a new one, the records not thinned shared. Folding either from the start
/// ends on the same rows.
export function thinStreamedOutputs(events: readonly EventRecord[]): EventRecord[] {
  const calls = new Map<string, { first: number; last?: number }>();
  let thinned: EventRecord[] | undefined;
  for (let index = 0; index < events.length; index += 1) {
    const event = events[index]!;
    if (endsStreamedCalls(event)) calls.clear();
    const callId = streamedCallKey(event);
    if (!callId) continue;
    const update = sessionUpdate(event);
    const call = calls.get(callId);
    if (!call || event.kind === "tool_call") calls.set(callId, { first: index });
    else if (textOnlyContent(update) && event.seq > events[call.first]!.seq) {
      // Of two updates the older by seq is the moot one, whichever the array holds first.
      const last = call.last;
      const moot = last === undefined ? undefined : events[last]!.seq < event.seq ? last : index;
      if (moot !== undefined) {
        thinned ??= [...events];
        thinned[moot] = withoutSupersededContent(events[moot]!, moot === index ? events[last!]!.seq : event.seq);
      }
      if (moot !== index) call.last = index;
    }
  }
  return thinned ?? (events as EventRecord[]);
}

/// The largest image block a tool call keeps (its base64 text): a bigger one is left out.
const MAX_TOOL_IMAGE_LENGTH = 8 * 1024 * 1024;

/// The data URLs of ACP `image` content blocks (`{type: "image", mimeType, data}`, bare or in a
/// `content` wrapper), images only and each under the cap.
function imagesFromContent(content: any): string[] | undefined {
  const found: string[] = [];
  const visit = (block: any) => {
    if (Array.isArray(block)) return block.forEach(visit);
    if (block?.type === "content") return visit(block.content);
    if (block?.type !== "image" || typeof block.data !== "string") return;
    const type = String(block.mimeType ?? "");
    if (/^image\/(png|jpeg|gif|webp)$/.test(type) && block.data.length <= MAX_TOOL_IMAGE_LENGTH)
      found.push(`data:${type};base64,${block.data}`);
  };
  visit(content);
  return found.length ? found : undefined;
}

function sessionUpdate(event: EventRecord): any | undefined {
  return event.dir === "in" && event.msg.method === "session/update" ? event.msg.params?.update : undefined;
}

/// Opens the client's socket; mock mode passes an in-page daemon (mock.ts), the app the host
/// bridge (bridgeSocket.ts). `protocols` carries the listener token (`tokenProtocols`): acpmux
/// takes it only from a header, never the URL, which logs, history and a Referer keep.
export type OpenSocket = (url: URL, protocols?: string[]) => WebSocket;

/// The subprotocol acpmux answers a browser's upgrade with; it never echoes the token.
export const ACPMUX_PROTOCOL = "acpmux.v1";

/// The WebSocket subprotocols that carry `token`: a browser cannot set an Authorization header.
export function tokenProtocols(token: string): string[] {
  return [ACPMUX_PROTOCOL, `acpmux.token.${token}`];
}

/// The placeholder URL of a bridge connection (never dialed).
export const BRIDGE_URL = "cmux-bridge://acpmux/";

/// Where git reads go: the native host, or in mock mode the daemon the socket reaches.
export type GitRoute = "native" | "daemon";

/// How soon a hidden page draws a change other than its text stream (`emitInFrame`), as the frame
/// fallback did before.
const HIDDEN_DRAW_MS = 50;

/// How often other chats' changes may draw a shown chat (`drawOtherChats`): each snapshot walks the
/// whole session list in App.tsx, a cost that grows with history (12,000 chats on Leo's Mac).
const OTHER_CHATS_DRAW_MS = 500;
/// How long after the person's last wheel tick or scroll other chats' changes still wait.
const SCROLL_QUIET_MS = 150;
/// The longest a scroll holds them: a page that keeps scrolling itself never rests.
const SCROLL_HOLD_MAX_MS = 2_000;

/// When the person last scrolled anything in this page (a wheel tick or a scroll), on the monotonic
/// clock, from one passive capture listener per window, added the first time a client asks.
const scrolledAt = new WeakMap<Window, number>();
function lastScrollAt(): number {
  if (typeof window === "undefined") return Number.NEGATIVE_INFINITY;
  const win = window;
  const at = scrolledAt.get(win);
  if (at !== undefined) return at;
  scrolledAt.set(win, Number.NEGATIVE_INFINITY);
  const note = () => scrolledAt.set(win, performance.now());
  for (const type of ["wheel", "scroll"]) win.addEventListener(type, note, { capture: true, passive: true });
  return Number.NEGATIVE_INFINITY;
}

/// What hidden pages left for their first frame once shown: a client's snapshot and deferred
/// prompt index each wait once and cancel on close. All waits share one visibility listener.
const waitingForShow = new Set<() => void>();
function waitForShow(wait: () => void): void {
  if (waitingForShow.size === 0) document.addEventListener("visibilitychange", drawShown);
  waitingForShow.add(wait);
}
function stopWaiting(wait: () => void): void {
  if (waitingForShow.delete(wait) && waitingForShow.size === 0)
    document.removeEventListener("visibilitychange", drawShown);
}
function drawShown(): void {
  if (!pageShown()) return;
  document.removeEventListener("visibilitychange", drawShown);
  const due = [...waitingForShow];
  waitingForShow.clear();
  for (const wait of due) wait();
}

/// Runs `run` once before the next display frame, or after 50 ms when a shown page draws no frames
/// (an occluded window). A hidden page draws nothing: `run` waits until it shows, also when the page
/// hides before the frame comes, and its first frame then draws everything that landed meanwhile
/// (`emitInFrame` holds one waiting snapshot). Every page's waits share one listener, which goes
/// with that show. The returned cancel stops it in any state, so a closed client leaves nothing
/// waiting. A hidden page used to draw the shown chat's stream every 50 ms that nobody could see.
/// Whichever of the frame and the 50 ms fallback comes first cancels the other: the fallback left
/// waiting woke the page 50 ms after every drawn frame to do nothing (CMUX-571 idle wakeups).
export const nextFrame = (run: () => void): (() => void) => {
  let done = false;
  let stopPending: (() => void) | undefined;
  const frame = () => {
    if (done) return;
    if (!pageShown()) return waitForShow(frame);
    let ran = false;
    let drawn: unknown;
    let fallback: ReturnType<typeof setTimeout> | undefined;
    const stop = () => {
      if (typeof cancelAnimationFrame === "function" && typeof drawn === "number") cancelAnimationFrame(drawn);
      if (fallback !== undefined) clearTimeout(fallback);
      stopPending = undefined;
    };
    const once = () => {
      if (ran || done) return;
      ran = true;
      stop();
      if (!pageShown()) return waitForShow(frame);
      done = true;
      run();
    };
    stopPending = stop;
    drawn = requestAnimationFrame(once);
    fallback = setTimeout(once, 50);
    // A frame that came at once (a test's clock) leaves no fallback behind.
    if (ran) stop();
  };
  frame();
  return () => {
    done = true;
    stopPending?.();
    stopWaiting(frame);
  };
};

/** Run non-visible work after a visible frame, never while its page is hidden.
 * The task after rAF lets the browser paint before work (including a fast RPC reply) starts.
 * The existing visible-frame queue also holds hidden pages; selection/close cancels all work.
 */
function afterPaint(run: () => void): () => void {
  let frame: number | undefined;
  let task: ReturnType<typeof setTimeout> | undefined;
  let done = false;
  const hidden = () => typeof document !== "undefined" && document.visibilityState === "hidden";
  const stop = () => {
    done = true;
    if (frame !== undefined) cancelAnimationFrame(frame);
    if (task !== undefined) clearTimeout(task);
    stopWaiting(schedule);
  };
  const finish = () => {
    task = undefined;
    if (done) return;
    if (hidden()) return waitForShow(schedule);
    stop();
    run();
  };
  const schedule = () => {
    if (done || frame !== undefined || task !== undefined) return;
    if (hidden()) return waitForShow(schedule);
    if (typeof requestAnimationFrame === "undefined") {
      task = setTimeout(finish, 0);
      return;
    }
    frame = requestAnimationFrame(() => {
      frame = undefined;
      if (!done) task = setTimeout(finish, 0);
    });
  };
  schedule();
  return stop;
}

/// "New since you looked" comes only from the daemon's persisted unread cursor.
/// A missing cursor is the never-focused state and must stay empty on first open.

/// A thought chunk continues the thought it follows: a thought streams into one growing item,
/// not one row per chunk. `at` (the chunk's time) dates the thought's first and latest chunk, so
/// a folded thought can read "Thought for 12s" (conversation/ThoughtRow.tsx `thoughtDuration`).
export function appendThought(items: AcpmuxActivity[], text: string, at?: number): AcpmuxActivity[] {
  const last = items.at(-1);
  if (last?.kind === "thought" && !last.tool)
    return [...items.slice(0, -1), { ...last, text: last.text + text, ...(at !== undefined && { endedAt: at }) }];
  return [...items, { kind: "thought", text, ...(at !== undefined && { startedAt: at, endedAt: at }) }];
}

/// Notices made in one millisecond each keep their row: the id carries a counter, not the time.
let notices = 0;
const noticeId = (kind: string) => `${kind}-${(notices += 1)}`;

/// The images a `user_message` names (`images: [{id, mimeType, name?, width?, height?}]`),
/// malformed entries left out.
function promptImages(value: unknown): PromptImage[] {
  if (!Array.isArray(value)) return [];
  const dimension = (n: unknown) => typeof n === "number" && Number.isInteger(n) && n > 0;
  return value.flatMap((image) =>
    image && typeof image.id === "string" && typeof image.mimeType === "string"
      ? [
          {
            id: image.id,
            mimeType: image.mimeType,
            ...(typeof image.name === "string" && { name: image.name }),
            ...(dimension(image.width) && dimension(image.height) && { width: image.width, height: image.height }),
            ...(attachmentSource(image.source) && { source: attachmentSource(image.source) }),
          },
        ]
      : [],
  );
}

/// More than one slot of the kept order changed, or it was rebuilt (`OrderedRows.changedSlot`).
const MANY_SLOTS = Symbol("many");

/// Whether two texts are one message at different completeness: one holds the other's opening or
/// ending whole (a repair read back chunks before or after it, or split a reply a lost call had
/// joined), 40 characters of it, and the shorter is at least half as long, so a short reply is never
/// taken for part of a long one, nor two replies for one by a common opening line. Linear in the longer; under 8 characters, only itself.
function sameWords(a: string | undefined, b: string | undefined): boolean {
  const [x, y] = [a?.trim() ?? "", b?.trim() ?? ""];
  if (!x || !y) return false;
  if (x === y) return true;
  const [short, long] = x.length <= y.length ? [x, y] : [y, x];
  if (short.length < 8 || short.length * 2 < long.length) return false;
  const holds = (text: string, other: string) => text.includes(other.slice(0, 40)) || text.includes(other.slice(-40));
  return holds(long, short) || holds(short, long);
}

/// Transcript rows in the daemon's event order: each row keeps the sequence number of the event
/// that created it, so two wall clocks (or one millisecond) never put a prompt under its reply.
/// A row made without an event (a prompt sending or failed, a notice, the typing row) orders after
/// the events seen when it was made, so later turns go below it; after a lag rebuild, which
/// replays events older than it, it moves after them again.
export class OrderedRows extends Map<string, AcpmuxRow> {
  /// How many times any chat's rows were sorted whole (longChatCost.test.ts counts them per update).
  static sorts = 0;
  private readonly order = new Map<string, number>();
  /// The newest event that wrote each streamed reply (`assistant`), where it differs from the one
  /// that made it: a reply the person left mid-stream goes on past where they left (`placeAfter`).
  private readonly lastWrite = new Map<string, number>();
  private readonly local = new Set<string>();
  private made = 0;
  /// The sequence number of the event being reduced.
  current: number | undefined;
  /// The newest event reduced so far.
  private latest = 0;
  /// The rows in order as of the last ``sorted()``, and each one's index there: a snapshot of a
  /// long chat whose rows only changed in place copies this instead of sorting every row again.
  private ordered: AcpmuxRow[] | undefined;
  private orderedIndex = new Map<string, number>();
  /// The array handed to snapshots. Metadata updates can emit without changing a transcript row;
  /// reuse this reference so the pane's derived rows stay memoized.
  private snapshot: AcpmuxRow[] | undefined;
  /// The one slot of `ordered` written in place since `snapshot` was made, when that is all that
  /// changed (MANY_SLOTS for any other change): the next snapshot says so (rowChanges.ts
  /// `markOneRowChange`), so the pane reads that row alone, not every row.
  private changedSlot: number | typeof MANY_SLOTS | undefined;
  /// The first slot of `ordered` any change since `snapshot` was made could have touched (MANY_SLOTS
  /// when the order was rebuilt or moved): the next snapshot says its rows before it are the last
  /// one's (prefixFlatMap.ts `noteKeptPrefix`), so every per-snapshot pass that reads only the rows
  /// after the kept prefix (markRows, sessionEdits, startedNames, prefixFlatMap) starts there with no
  /// walk over the chat. A tool call's start is a new slot at the end, its end a write in place.
  private firstChanged: number | typeof MANY_SLOTS | undefined;
  /// The last snapshot handed out, which the next one's change is from.
  private published: AcpmuxRow[] | undefined;
  private pullRequestActivityVersion = Symbol();
  private pullRequestCommandVersion = Symbol();
  private transcriptSummaryVersion = {};
  private readonly artifactUpdates = new RowUpdates((id) => this.get(id));
  /// The turns the agent ran on its own (acpmux `background_turn`): each one's started record's
  /// sequence number and its ended record's, once heard. A row an event between them made is that
  /// turn's (`inBackground`). An ended record heard first (an older page's started record comes
  /// later) waits in `backgroundEnds`.
  private backgroundSpans: { id: string; from: number; to?: number }[] = [];
  private readonly backgroundClaims = new Map<string, string[]>();
  private readonly backgroundEnds = new Map<string, { seq: number; turn: AcpmuxBackgroundTurn }>();
  /// Each background turn's reply rows, in order (`markBackgroundRows`).
  private readonly backgroundReplies = new Map<string, string[]>();

  /// What background turn `turn` replied, its messages' words in order; "" for none.
  backgroundReply(turn: string): string {
    const words: string[] = [];
    for (const id of this.backgroundReplies.get(turn) ?? []) {
      const row = this.get(id);
      if (row?.kind === "assistant" && row.inBackground === turn && !isVisiblyEmptyMessage(row))
        words.push(row.text!.trim());
    }
    return words.join("\n\n");
  }

  /// A background turn's started record at `seq`: how it ended when its ended record came first,
  /// and whether rows its events made before this record was heard draw something (`hasRows`).
  openBackground(id: string, seq: number): { ended?: AcpmuxBackgroundTurn; hasRows: boolean } {
    if (this.backgroundSpans.some((span) => span.id === id)) return { hasRows: false };
    const ended = this.backgroundEnds.get(id);
    this.backgroundSpans.push({ id, from: seq, to: ended?.seq });
    this.backgroundEnds.delete(id);
    let hasRows = false;
    const claimed: string[] = [];
    // An older page read later: rows its events made before this record was heard are the turn's too.
    for (const [rowId, order] of this.order) {
      if (this.local.has(rowId) || order <= seq || (ended !== undefined && order >= ended.seq)) continue;
      const row = this.get(rowId);
      if (!row || row.kind === BACKGROUND_TURN || row.kind === "user" || row.inBackground === id) continue;
      if (this.promptsReply(rowId, row, id)) continue;
      const tagged = { ...row, inBackground: id };
      claimed.push(rowId);
      if (!isVisiblyEmptyMessage(tagged)) hasRows = true;
      if (row.kind === "assistant") this.backgroundReplies.set(id, [...(this.backgroundReplies.get(id) ?? []), rowId]);
      super.set(rowId, tagged);
      const at = this.orderedIndex.get(rowId);
      if (this.ordered && at !== undefined) this.ordered[at] = tagged;
      this.snapshot = undefined;
      this.changedSlot = MANY_SLOTS;
      this.changedFrom(this.ordered && at !== undefined ? at : MANY_SLOTS);
      this.transcriptSummaryVersion = {};
    }
    if (!ended && claimed.length) this.backgroundClaims.set(id, claimed);
    return { ended: ended?.turn, hasRows };
  }

  /// A row of background turn `turn` that draws something: its line opens to it from now on. Its
  /// replies are kept by id (a few per turn), for the call its reaction goes onto.
  private markBackgroundRows(turn: string, row: AcpmuxRow): void {
    if (row.kind === "assistant") {
      const replies = this.backgroundReplies.get(turn);
      if (!replies) this.backgroundReplies.set(turn, [row.id]);
      else if (!replies.includes(row.id)) replies.push(row.id);
    }
    if (isVisiblyEmptyMessage(row)) return;
    const id = backgroundTurnRowId(turn);
    const line = this.get(id);
    if (!line?.background || line.background.hasRows) return;
    this.set(id, { ...line, version: line.version + 1, background: { ...line.background, hasRows: true } });
  }

  /// A background turn's ended record at `seq`, which says how it ended (`turn`).
  closeBackground(seq: number, turn: AcpmuxBackgroundTurn): void {
    const span = this.backgroundSpans.find((span) => span.id === turn.id);
    // A span a prompt already closed (`openBackgroundsBefore`) keeps that end: acpmux's own ended
    // record, heard later, says how the turn ended and never takes the prompt's rows back.
    if (span) span.to = span.to === undefined ? seq : Math.min(span.to, seq);
    else this.backgroundEnds.set(turn.id, { seq, turn });
    // An older page's start can arrive before its end while newer rows are already held.
    // The start attributed those rows provisionally; the end bounds that attribution.
    const claimed = this.backgroundClaims.get(turn.id) ?? [];
    this.backgroundClaims.delete(turn.id);
    for (const id of claimed) {
      const row = this.get(id);
      if (row?.inBackground !== turn.id || this.orderOf(id) < seq) continue;
      const { inBackground: _background, ...untagged } = row;
      const owner = this.backgroundAt(this.orderOf(id));
      const restored = owner === undefined ? untagged : { ...untagged, inBackground: owner };
      super.set(id, restored);
      const at = this.orderedIndex.get(id);
      if (this.ordered && at !== undefined) this.ordered[at] = restored;
      this.snapshot = undefined;
      this.changedSlot = MANY_SLOTS;
      this.changedFrom(this.ordered && at !== undefined ? at : MANY_SLOTS);
      this.transcriptSummaryVersion = {};
    }
    const replies = this.backgroundReplies.get(turn.id);
    if (replies)
      this.backgroundReplies.set(
        turn.id,
        replies.filter((id) => this.get(id)?.inBackground === turn.id),
      );
  }

  /// The background turns still open at `seq`: started before it, with no ended record heard.
  openBackgroundsBefore(seq: number): string[] {
    return this.backgroundSpans.filter((span) => span.to === undefined && span.from < seq).map((span) => span.id);
  }

  /// Whether a reply row is a prompt's turn's own, whatever span its event falls in: acpmux names a
  /// reply's row by its segment, which starts with the acpmux turn it was written in, or "-" for a
  /// turn the agent ran on its own (hub/stream.rs `before_agent_update`). A background finish's turn
  /// is an acpmux turn the pane brackets itself (bgDoneNotice.ts), so its replies stay its own.
  private promptsReply(id: string, row: AcpmuxRow, turn: string): boolean {
    if (row.kind !== "assistant" || turn.startsWith("bg-done-")) return false;
    const owner = /^assistant-([^.]+)\.[^.]+\.\d+$/.exec(id)?.[1];
    return owner !== undefined && owner !== "-";
  }

  /// The background turn an event at `order` belongs to.
  private backgroundAt(order: number): string | undefined {
    for (let at = this.backgroundSpans.length - 1; at >= 0; at -= 1) {
      const span = this.backgroundSpans[at]!;
      if (span.from < order && (span.to === undefined || order < span.to)) return span.id;
    }
    return undefined;
  }

  /// Puts back the earlier object of each row a rebuild made again unchanged (same kind, version and
  /// plain fields: a turn's totals change with what was folded before it, not its version), so what
  /// is keyed on the object (drawn heights, memoized rows, reused turns) survives the rebuild: paging
  /// older history in rebuilds every row. A background turn's line is compared whole: how it ended
  /// is in its `background`, and a line a prompt ended whose own result then arrived late has the
  /// same version either way (started, ended), so the earlier object kept "ended by a prompt".
  keepSame(previous: ReadonlyMap<string, AcpmuxRow>): void {
    const plainSame = (a: AcpmuxRow, b: AcpmuxRow) => {
      const keys = new Set([...Object.keys(a), ...Object.keys(b)]) as Set<keyof AcpmuxRow>;
      for (const key of keys) if (typeof a[key] !== "object" && a[key] !== b[key]) return false;
      return a.background === b.background || JSON.stringify(a.background) === JSON.stringify(b.background);
    };
    let changed = false;
    // Only the rows `previous` holds can be kept (a rebuild past a cut passes the refolded ones).
    for (const [id, old] of previous) {
      const row = this.get(id);
      if (!row || old === row || old.kind !== row.kind || old.version !== row.version || !plainSame(old, row)) continue;
      super.set(id, old);
      const at = this.orderedIndex.get(id);
      if (this.ordered && at !== undefined) this.ordered[at] = old;
      changed = true;
    }
    if (changed) {
      this.snapshot = undefined;
      this.changedSlot = MANY_SLOTS;
      this.firstChanged = MANY_SLOTS;
    }
  }

  /// The frame each message a rebuild made under a new id keeps drawing in (``adoptFrames``).
  private readonly frames = new Map<string, string>();

  /// Keeps on screen, in the element it drew in, each prompt and reply a rebuild made again under a
  /// new id. A reply's id is the first of its chunks the pane held, so a turn repaired from its
  /// stored records after its first chunk was lost (`checkFinishedTurn`, a lag's reread), an older
  /// page or a reconnect's replay names it anew; as a new frame it unmounted and faded in again
  /// while the tool calls around it, keyed by their call ids, stayed (Leo, 2026-11-11: "it keeps
  /// showing and then hiding, and then showing and then hiding your responses, or my responses").
  /// Each message of a kind that went gives its frame to the new message of that kind whose words it
  /// holds or that holds its words, the nearest to it in length (an older page brings many new
  /// replies, and only the one it was cut from is it); that message's later updates keep the frame
  /// (``set``). Gone and new messages are few beside the chat: an older page's replies are new, but
  /// a page that names no shown message again leaves none gone, and returns at once.
  adoptFrames(previous: ReadonlyMap<string, AcpmuxRow>): void {
    const isMessage = (row: AcpmuxRow) => row.kind === "user" || row.kind === "assistant";
    const gone = [...previous.values()].filter((row) => isMessage(row) && !this.has(row.id));
    // Written outside any event: the row keeps its place and its last write.
    const current = this.current;
    this.current = undefined;
    // A frame whose own row came back (a fuller read named it as before) is that row's again: two
    // rows never draw in one frame.
    for (const [id, frame] of this.frames) {
      if (this.has(id) && !this.has(frame)) continue;
      this.frames.delete(id);
      const row = this.get(id);
      if (row?.frame === frame) this.set(id, { ...row, frame: undefined });
    }
    if (gone.length === 0) {
      this.current = current;
      return;
    }
    const fresh = [...this.values()].filter(
      (row) => isMessage(row) && row.frame === undefined && !previous.has(row.id),
    );
    // The frames rows draw in now. `previous` holds the rows shown before a reset too, which can name
    // a frame a row since took: a frame in use is never given again, so no two rows share one.
    const inUse = new Set<string>();
    for (const row of this.values()) inUse.add(rowFrameKey(row));
    for (const old of gone) {
      const frame = rowFrameKey(old);
      if (inUse.has(frame)) continue;
      const length = old.text?.trim().length ?? 0;
      let best: AcpmuxRow | undefined;
      // A tie goes to the newer row: the one a rebuild named anew is the newest of its copies.
      for (const row of fresh)
        if (
          row.kind === old.kind &&
          !this.frames.has(row.id) &&
          sameWords(old.text, row.text) &&
          (!best ||
            Math.abs((row.text?.trim().length ?? 0) - length) <= Math.abs((best.text?.trim().length ?? 0) - length))
        )
          best = row;
      if (!best) continue;
      inUse.add(frame);
      this.frames.set(best.id, frame);
      this.set(best.id, best);
    }
    this.current = current;
  }

  // Producers identify stream progress from the event, even when its row retains settled tools.
  override set(id: string, row: AcpmuxRow, summaryChanged = !row.streaming): this {
    const adopted = this.frames.get(id);
    if (adopted !== undefined && row.frame !== adopted) row = { ...row, frame: adopted };
    const known = this.order.has(id);
    const previous = this.get(id);
    const unchanged = known && previous === row;
    if (!unchanged && pullRequestRowKey(previous) !== pullRequestRowKey(row))
      this.pullRequestActivityVersion = Symbol();
    if (!unchanged && row.kind === "activity" && pullRequestRowKey(previous) !== pullRequestRowKey(row))
      this.pullRequestCommandVersion = Symbol();
    if (!unchanged && (!known || summaryChanged)) this.transcriptSummaryVersion = {};
    if (!unchanged) this.snapshot = undefined;
    if (!known) {
      if (this.current !== undefined) {
        this.order.set(id, this.current);
        this.latest = Math.max(this.latest, this.current);
      } else {
        this.order.set(id, this.latest + 0.5 + (this.made += 1e-6));
        this.local.add(id);
      }
    } else if (this.current !== undefined) {
      this.latest = Math.max(this.latest, this.current);
      if (row.kind === "assistant") this.lastWrite.set(id, this.current);
      if (!unchanged && this.current > (this.order.get(id) ?? Infinity)) this.noteChange(id, this.current);
    }
    // A row an event of a background turn made is that turn's, whoever updates it later. A prompt
    // never is: it starts a turn of its own (acpmux ends the background turn before it).
    let turn: string | undefined;
    if (this.backgroundSpans.length && row.kind !== BACKGROUND_TURN && row.kind !== "user" && !this.local.has(id)) {
      turn = this.backgroundAt(this.order.get(id)!);
      if (turn !== undefined && this.promptsReply(id, row, turn)) turn = undefined;
      if (turn !== undefined && row.inBackground !== turn) row = { ...row, inBackground: turn };
    }
    if (!known && this.prepending && (this.order.get(id) ?? Infinity) < this.prepending.below)
      this.prepending.made.push(id);
    if (this.ordered && !unchanged) this.keepOrdered(id, row, known);
    if (row.kind === "compaction") this.compactionIds.add(id);
    else if (previous?.kind === "compaction") this.compactionIds.delete(id);
    super.set(id, row);
    if (!unchanged) this.artifactUpdates.note(row, this.current ?? this.order.get(id) ?? row.at);
    if (turn !== undefined) this.markBackgroundRows(turn, row);
    return this;
  }

  /// Updates the kept order for `row`: in its slot when only its content changed, at the end when it
  /// sorts after every row, otherwise ``sorted()`` sorts again.
  private keepOrdered(id: string, row: AcpmuxRow, known: boolean): void {
    const ordered = this.ordered!;
    const index = this.orderedIndex.get(id);
    // An older page's row while it folds (`beginPrepend`): it waits to be merged in, and the held
    // rows' order stands.
    const prepend = this.prepending;
    if (prepend && index === undefined && (this.order.get(id) ?? Infinity) < prepend.below) {
      if (!known) prepend.pending.push(id);
      this.changedSlot = MANY_SLOTS;
      this.firstChanged = MANY_SLOTS;
      return;
    }
    if (known && index !== undefined && (ordered[index]!.at === row.at || this.ownsSlot(index))) {
      ordered[index] = row;
      this.changedSlot = this.changedSlot === undefined || this.changedSlot === index ? index : MANY_SLOTS;
      this.changedFrom(index);
      return;
    }
    this.changedSlot = MANY_SLOTS;
    const last = ordered.at(-1);
    const order = this.order.get(id) ?? 0;
    const lastOrder = last ? (this.order.get(last.id) ?? 0) : -Infinity;
    if (!known && (order > lastOrder || (order === lastOrder && row.at >= last!.at))) {
      this.orderedIndex.set(id, ordered.length);
      this.changedFrom(ordered.length);
      ordered.push(row);
      return;
    }
    this.ordered = undefined;
    this.pullRequestActivityVersion = Symbol();
    this.pullRequestCommandVersion = Symbol();
    this.transcriptSummaryVersion = {};
  }

  /// Notes a change at slot `index` of the kept order (MANY_SLOTS: anywhere).
  private changedFrom(index: number | typeof MANY_SLOTS): void {
    const first = this.firstChanged;
    this.firstChanged =
      index === MANY_SLOTS || first === MANY_SLOTS ? MANY_SLOTS : first === undefined ? index : Math.min(first, index);
  }

  /// Whether the row at `index` of the kept order sorts by its event alone, so a change of its
  /// time (the tie-break, which a streamed delta moves) cannot move it.
  private ownsSlot(index: number): boolean {
    const ordered = this.ordered!;
    const order = this.order.get(ordered[index]!.id);
    const before = ordered[index - 1];
    const after = ordered[index + 1];
    return (!before || this.order.get(before.id) !== order) && (!after || this.order.get(after.id) !== order);
  }

  /// Moves `id` after every row the event being reduced made, and before the next event's: a steer
  /// its stopped turn never read goes below that turn's end (`deferLateSteers`).
  placeAfterCurrent(id: string): void {
    if (!this.has(id) || this.current === undefined) return;
    this.order.set(id, this.current + 0.25);
    this.local.delete(id);
    this.pullRequestActivityVersion = Symbol();
    this.pullRequestCommandVersion = Symbol();
    this.transcriptSummaryVersion = {};
    this.ordered = undefined;
    this.snapshot = undefined;
  }

  /// Where "New since you looked" goes for a person who had seen through the event at `seq`: right
  /// after it, or before a reply that started at or before it and streamed on past it, so the rest
  /// of that reply reads as new. One pass over the rows, made only when the line is placed.
  placeAfter(seq: number): number {
    let place = seq + 0.5;
    for (const [id, last] of this.lastWrite) {
      const first = this.order.get(id);
      if (first !== undefined && first <= seq && last > seq) place = Math.min(place, first - 0.25);
    }
    return place;
  }

  /// Sets `row` to sort at `place` (`placeAfter`): "New since you looked" (`SINCE_DIVIDER`), which no
  /// event of its own makes.
  setAt(place: number, row: AcpmuxRow): void {
    if (this.order.get(row.id) !== place) {
      this.order.set(row.id, place);
      this.local.delete(row.id);
      this.ordered = undefined;
      this.transcriptSummaryVersion = {};
    } else if (this.ordered) {
      // Same place, new content (a recap arrived or was dismissed): its slot of the kept order too.
      const at = this.orderedIndex.get(row.id);
      if (at === undefined) this.ordered = undefined;
      else this.ordered[at] = row;
    }
    super.set(row.id, row);
    this.snapshot = undefined;
    this.changedSlot = MANY_SLOTS;
    this.firstChanged = MANY_SLOTS;
  }

  /// The place `id` sorts at: its event's sequence number, or just after the events seen before it.
  orderOf(id: string): number {
    return this.order.get(id) ?? Infinity;
  }

  /// Each write of a row by a later record than the one that made it, in record order: the
  /// record's seq and the row's id. Folding forward appends; a refold past a cut or an older page
  /// reads older records again and adds nothing (their writes are here already, or are older than
  /// any cut). A reply's chunks write its row one after another and take one entry.
  private changeSeqs: number[] = [];
  private changeIds: string[] = [];
  /// Where each changed row sorts (its maker's seq), kept here so a row a later record deleted
  /// still spans the records between.
  private changeOrders: number[] = [];

  private noteChange(id: string, seq: number, order = this.order.get(id) ?? Infinity): void {
    const last = this.changeSeqs.length - 1;
    if (last < 0 || seq >= this.changeSeqs[last]!) {
      if (last >= 0 && this.changeIds[last] === id && this.changeOrders[last] === order) this.changeSeqs[last] = seq;
      else {
        this.changeSeqs.push(seq);
        this.changeIds.push(id);
        this.changeOrders.push(order);
      }
      return;
    }
    // A write by an older record than the newest noted (a repair's record refolded past a cut, an
    // older page) goes in its place: a later cut between it and its row must still see it.
    const at = this.changesFrom(seq + 1);
    this.changeSeqs.splice(at, 0, seq);
    this.changeIds.splice(at, 0, id);
    this.changeOrders.splice(at, 0, order);
  }

  /// The index of the first change noted at or after record `seq`.
  private changesFrom(seq: number): number {
    let low = 0;
    let high = this.changeSeqs.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (this.changeSeqs[middle]! < seq) low = middle + 1;
      else high = middle;
    }
    return low;
  }

  /// A refold past a cut at `seq` writes every change from it on again: the ones noted go first,
  /// so the log does not grow with each repair.
  forgetChangesFrom(seq: number): void {
    const at = this.changesFrom(seq);
    this.changeSeqs.length = at;
    this.changeIds.length = at;
    this.changeOrders.length = at;
  }

  /// The oldest place of a row made before record `seq` that a record from `seq` on changed:
  /// a rebuild cut at `seq` would draw it again from only part of its records (direct.ts
  /// `rebuild`). Infinity when none. O(changes from `seq` on).
  spanningFrom(seq: number): number {
    let from = Infinity;
    for (let index = this.changeSeqs.length - 1; index >= 0 && this.changeSeqs[index]! >= seq; index -= 1) {
      const order = this.changeOrders[index]!;
      if (order < seq) from = Math.min(from, order);
    }
    return from;
  }

  /// A full rebuild folds every record again from the start, noting each change again.
  forgetChanges(): void {
    this.changeSeqs = [];
    this.changeIds = [];
    this.changeOrders = [];
  }

  /// Row `from`, made by record `made`, was merged into the older row `into` (an older page's fold
  /// joins a compaction's notes or a shell's end to rows it brought): `from`'s changes and the
  /// record that made it are `into`'s. Kept in record order; O(changes), on an older page only.
  mergeChanges(from: string, into: string, made: number): void {
    const order = this.order.get(into) ?? Infinity;
    for (let index = 0; index < this.changeIds.length; index += 1)
      if (this.changeIds[index] === from) {
        this.changeIds[index] = into;
        this.changeOrders[index] = order;
      }
    if (!Number.isFinite(made)) return;
    const at = this.changesFrom(made + 1);
    this.changeSeqs.splice(at, 0, made);
    this.changeIds.splice(at, 0, into);
    this.changeOrders.splice(at, 0, order);
  }

  /// An event was reduced (it may have made no row).
  saw(seq: number): void {
    this.latest = Math.max(this.latest, seq);
  }

  override delete(id: string): boolean {
    // Every text delta drops the typing row, which is usually gone already.
    if (!this.has(id)) return false;
    this.pullRequestActivityVersion = Symbol();
    this.pullRequestCommandVersion = Symbol();
    this.transcriptSummaryVersion = {};
    // A row a later record takes away changed too: a cut between them would draw it again.
    const made = this.order.get(id);
    if (this.current !== undefined && made !== undefined && made < this.current)
      this.noteChange(id, this.current, made);
    this.dropOrdered(id);
    this.snapshot = undefined;
    this.compactionIds.delete(id);
    this.order.delete(id);
    this.local.delete(id);
    this.lastWrite.delete(id);
    return super.delete(id);
  }

  override clear(): void {
    this.pullRequestActivityVersion = Symbol();
    this.pullRequestCommandVersion = Symbol();
    this.transcriptSummaryVersion = {};
    this.ordered = undefined;
    this.snapshot = undefined;
    this.order.clear();
    this.local.clear();
    this.lastWrite.clear();
    this.frames.clear();
    this.latest = 0;
    this.backgroundSpans = [];
    this.backgroundClaims.clear();
    this.backgroundEnds.clear();
    this.compactionIds.clear();
    this.forgetChanges();
    super.clear();
  }

  /// Takes row `id` out of the kept order, so the next ``sorted()`` does not sort every row again
  /// (``retain`` gathers its deletes and mends the order once, from the oldest one).
  private dropOrdered(id: string): void {
    const ordered = this.ordered;
    if (!ordered) return;
    const at = this.orderedIndex.get(id);
    if (this.dropping) {
      if (at !== undefined) this.dropping.from = Math.min(this.dropping.from, at);
      return;
    }
    if (at === undefined) {
      // An older page's row not merged in yet: the merge leaves out what is gone.
      if (this.prepending && (this.order.get(id) ?? Infinity) < this.prepending.below) return;
      this.ordered = undefined;
      return;
    }
    // Out of its slot, the rows after it moving up one: O(rows after it), which for the rows a turn
    // drops (its typing row, a retry line) is the turn's few. Making the order again sorted every
    // row the chat held, once per turn live and once per turn of every rebuild.
    ordered.splice(at, 1);
    this.orderedIndex.delete(id);
    for (let index = at; index < ordered.length; index += 1) this.orderedIndex.set(ordered[index]!.id, index);
    this.changedSlot = MANY_SLOTS;
    // The rows from its slot on moved: the next snapshot keeps only the ones before it.
    this.changedFrom(at);
  }

  /// The oldest slot of the kept order a ``retain`` deleted, while it runs.
  private dropping: { from: number } | undefined;

  /// The compaction rows' ids: a turn's start and end settle the ones still running
  /// (`settleCompactions`), which walked every row the chat held, once per turn.
  private readonly compactionIds = new Set<string>();

  /// The compaction rows, in no particular order: O(compactions), not O(rows).
  compactionRows(): AcpmuxRow[] {
    const rows: AcpmuxRow[] = [];
    for (const id of this.compactionIds) {
      const row = this.get(id);
      if (row?.kind === "compaction") rows.push(row);
    }
    return rows;
  }

  /// Drops every row but those `keep` accepts; the event order starts over (a lag rebuild
  /// replays the events), and the rows kept go after the replayed events (``placeLocalLast()``).
  /// The kept order is mended from the oldest row dropped, so a rebuild that keeps the older rows
  /// as drawn (`rebuild`'s cut) costs the rows after the cut, not a sort of every row.
  retain(keep: (row: AcpmuxRow) => boolean): void {
    this.drop(this.values(), keep);
  }

  /// ``retain`` for the rows from event `seq` on and the rows made without an event: every older
  /// row stays, and only the rows read are paid for (`rebuild`'s cut).
  retainFrom(seq: number, keep: (row: AcpmuxRow) => boolean): void {
    const read = [...this.rowsFrom(seq)];
    for (const id of this.local) {
      const row = this.get(id);
      if (row && this.orderOf(id) < seq) read.push(row);
    }
    this.drop(read, keep);
  }

  /// The rows from event `seq` on, oldest first: a binary search of the kept order, O(rows returned).
  rowsFrom(seq: number): readonly AcpmuxRow[] {
    const ordered = this.inOrder();
    let low = 0;
    let high = ordered.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (this.orderOf(ordered[middle]!.id) < seq) low = middle + 1;
      else high = middle;
    }
    return ordered.slice(low);
  }

  /// Drops the rows made at `from` and up to `before` (records' seqs; either end open), but the ones `keep` accepts and
  /// the rows made without a record, with what the order and the change log kept of them, and the background turns
  /// that lie wholly between: the rows a run of held records at one end of the held window drew leave with them, in
  /// place (direct.ts `dropHeldRun`). Nothing is folded again and the rows left keep their objects and their order.
  /// The rows left after the run move up its length in the kept order (an index each); the rows dropped and the
  /// change log's entries for them cost O(what leaves). Returns the ids dropped.
  dropMade(from: number, before: number, keep: (row: AcpmuxRow) => boolean): Set<string> {
    this.inOrder();
    const ordered = this.ordered!;
    const firstAt = (seq: number) => {
      let low = 0;
      let high = ordered.length;
      while (low < high) {
        const middle = (low + high) >>> 1;
        if (this.orderOf(ordered[middle]!.id) < seq) low = middle + 1;
        else high = middle;
      }
      return low;
    };
    const start = from === -Infinity ? 0 : firstAt(from);
    const end = before === Infinity ? ordered.length : firstAt(before);
    const gone = new Set<string>();
    for (let index = start; index < end; index += 1) {
      const row = ordered[index]!;
      if (!this.local.has(row.id) && !keep(row)) gone.add(row.id);
    }
    if (gone.size > 0) {
      // Not a later record's change: no record is being reduced.
      const current = this.current;
      this.current = undefined;
      this.dropping = { from: Infinity };
      try {
        for (const id of gone) {
          this.frames.delete(id);
          this.delete(id);
        }
      } finally {
        this.current = current;
        this.dropping = undefined;
      }
      // The kept order closes over the run: one splice, the rows after it an index each.
      let write = start;
      for (let index = start; index < end; index += 1) {
        const row = ordered[index]!;
        if (gone.has(row.id)) this.orderedIndex.delete(row.id);
        else ordered[write++] = row;
      }
      if (write < end) {
        ordered.splice(write, end - write);
        for (let index = start; index < ordered.length; index += 1) this.orderedIndex.set(ordered[index]!.id, index);
      }
      this.snapshot = undefined;
      this.changedSlot = MANY_SLOTS;
      this.changedFrom(start);
    }
    // The change log: the writes the records that left made, one splice (it is in record order). The caller's run is
    // one no row spans, so no record kept wrote to a row that left.
    const low = from === -Infinity ? 0 : this.changesFrom(from);
    const high = before === Infinity ? this.changeSeqs.length : this.changesFrom(before);
    if (low < high) {
      this.changeSeqs.splice(low, high - low);
      this.changeIds.splice(low, high - low);
      this.changeOrders.splice(low, high - low);
    }
    // The background turns that began and ended in the run, and their replies.
    this.backgroundSpans = this.backgroundSpans.filter((span) => {
      const inside = span.from >= from && span.to !== undefined && span.to < before;
      if (inside) this.backgroundReplies.delete(span.id);
      return !inside;
    });
    for (const [id, end] of this.backgroundEnds)
      if (end.seq >= from && end.seq < before) this.backgroundEnds.delete(id);
    return gone;
  }

  private drop(rows: Iterable<AcpmuxRow>, keep: (row: AcpmuxRow) => boolean): void {
    this.dropping = { from: Infinity };
    // A Map visits the entries left after a delete, so deleting while iterating is safe.
    try {
      for (const row of rows) if (!keep(row)) this.delete(row.id);
    } finally {
      const from = this.dropping.from;
      this.dropping = undefined;
      const ordered = this.ordered;
      if (ordered && from !== Infinity) {
        const tail = ordered.slice(from).filter((row) => super.get(row.id) === row);
        for (const row of ordered.slice(from)) this.orderedIndex.delete(row.id);
        ordered.length = from;
        for (const row of tail) {
          this.orderedIndex.set(row.id, ordered.length);
          ordered.push(row);
        }
        this.changedSlot = MANY_SLOTS;
        this.changedFrom(from);
      }
    }
    this.latest = 0;
    // The replay hears the background turns' records again.
    this.backgroundSpans = [];
    this.backgroundClaims.clear();
    this.backgroundEnds.clear();
  }

  /// Moves the rows made without an event after every event, keeping their order: what a lag
  /// rebuild replayed happened before them.
  placeLocalLast(): void {
    this.pullRequestActivityVersion = Symbol();
    this.pullRequestCommandVersion = Symbol();
    this.transcriptSummaryVersion = {};
    // With no such rows the kept order stands.
    if (this.local.size > 0) this.ordered = undefined;
    this.snapshot = undefined;
    const local = [...this.local].sort((a, b) => (this.order.get(a) ?? 0) - (this.order.get(b) ?? 0));
    local.forEach((id, index) => {
      const place = this.latest + 0.5 + (index + 1) * 1e-6;
      this.order.set(id, this.withinTurn(id, place));
    });
  }

  /// An optimistic row has been accepted by an event: keep its id, but make the event its order.
  adoptEventOrder(id: string): void {
    if (!this.has(id)) return;
    this.local.delete(id);
    if (this.current !== undefined) {
      this.order.set(id, this.withinTurn(id, this.current));
      this.latest = Math.max(this.latest, this.current);
    }
    this.ordered = undefined;
    this.snapshot = undefined;
  }

  /// Where a steer row may sort, given `place`: never after the end of the turn it went into. Its
  /// echo or a rebuild can come after that turn's summary (a busy daemon, a reconnect), and sorting
  /// it there drew the person's message under the agent's answer to it and opened the next turn
  /// with it (Leo, 2026-11-12: "in this case you didnt respond to me at all..."). It keeps the
  /// place it was sent at, or goes just before that summary.
  private withinTurn(id: string, place: number): number {
    const row = this.get(id);
    if (!row?.steer || !row.turnId) return place;
    const end = this.order.get(`summary-${row.turnId}`);
    if (end === undefined || place < end) return place;
    const sent = this.order.get(id);
    return sent !== undefined && sent < end ? sent : end - 0.5;
  }

  /// The rows in event order, as `sorted()` has them, without making a snapshot of them: a read of
  /// the newest rows walks back from the end, O(rows read), while the order is kept.
  inOrder(): readonly AcpmuxRow[] {
    if (this.ordered && this.prepending?.pending.length) this.mergePrepended();
    if (!this.ordered) {
      // A whole sort takes in a folding page's rows too: none waits to be merged again.
      if (this.prepending) this.prepending.pending = [];
      OrderedRows.sorts += 1;
      this.changedSlot = MANY_SLOTS;
      this.firstChanged = MANY_SLOTS;
      this.ordered = [...this.values()].sort(
        (a, b) => (this.order.get(a.id) ?? 0) - (this.order.get(b.id) ?? 0) || a.at - b.at,
      );
      this.orderedIndex = new Map(this.ordered.map((row, index) => [row.id, index]));
    }
    return this.ordered;
  }

  /// An older page folding in above every held row (`foldOlder`): the rows it makes, all ordered
  /// before `below`, wait in `pending` and are merged into the kept order once (`mergePrepended`), so
  /// the fold sorts the page's rows, not every row the chat holds. Each of the page's turn ends read
  /// the order back to its prompt (`turnTotals`), and every row the page made before it had thrown
  /// the kept order away: a page of 500 turns sorted the whole held chat 500 times, which on a 100k-row
  /// chat was most of an older page's 0.2-1.8 s (bench/transcript-scroll-up.bench.ts, FIXTURE=flat).
  /// `made` lists the page's rows in the order they were made (their records' order), for `turnTotals`.
  private prepending: { below: number; pending: string[]; made: string[] } | undefined;

  /// Starts an older page's fold above the rows ordered from `below` on (`prepending`).
  beginPrepend(below: number): void {
    this.inOrder();
    this.prepending = { below, pending: [], made: [] };
  }

  /// Ends the fold `beginPrepend` started: its rows go into the kept order.
  endPrepend(): void {
    if (this.ordered && this.prepending?.pending.length) this.mergePrepended();
    this.prepending = undefined;
  }

  /// The rows the folding page made, oldest first (`prepending`); undefined outside a fold.
  prependedRows(): readonly string[] | undefined {
    return this.prepending?.made;
  }

  /// Merges the folding page's rows into the kept order: a sort of the page's rows and one pass over
  /// the held ones, O(held + page log page) once a page, never a sort of every row.
  private mergePrepended(): void {
    const prepend = this.prepending!;
    const ordered = this.ordered!;
    const key = (row: AcpmuxRow) => this.order.get(row.id) ?? 0;
    const seen = new Set<string>();
    const page: AcpmuxRow[] = [];
    for (const id of prepend.pending) {
      if (seen.has(id)) continue;
      seen.add(id);
      const row = this.get(id);
      if (row) page.push(row);
    }
    prepend.pending = [];
    page.sort((a, b) => key(a) - key(b) || a.at - b.at);
    const merged: AcpmuxRow[] = [];
    let left = 0;
    let right = 0;
    while (left < page.length && right < ordered.length) {
      const a = page[left]!;
      const b = ordered[right]!;
      if (key(a) - key(b) < 0 || (key(a) === key(b) && a.at <= b.at)) merged.push(page[left++]!);
      else merged.push(ordered[right++]!);
    }
    while (left < page.length) merged.push(page[left++]!);
    while (right < ordered.length) merged.push(ordered[right++]!);
    this.ordered = merged;
    this.orderedIndex = new Map();
    for (let index = 0; index < merged.length; index += 1) this.orderedIndex.set(merged[index]!.id, index);
    this.changedSlot = MANY_SLOTS;
    this.firstChanged = MANY_SLOTS;
    this.snapshot = undefined;
  }

  /// The rows in event order (wall-clock time breaks a tie).
  sorted(): AcpmuxRow[] {
    const ordered = this.inOrder();
    if (!this.snapshot) {
      const from = this.published;
      this.snapshot = ordered.slice();
      if (typeof this.changedSlot === "number" && from && from.length === this.snapshot.length)
        markOneRowChange(this.snapshot, from, this.changedSlot);
      if (from && this.firstChanged !== MANY_SLOTS)
        noteKeptPrefix(this.snapshot, from, Math.min(this.firstChanged ?? Infinity, from.length, this.snapshot.length));
      this.published = this.snapshot;
      this.changedSlot = undefined;
      this.firstChanged = undefined;
      this.artifactUpdates.publish(this.snapshot);
      markPullRequestActivityVersion(this.snapshot, this.pullRequestActivityVersion);
      markPullRequestCommandVersion(this.snapshot, this.pullRequestCommandVersion);
      markTranscriptSummaryVersion(this.snapshot, this.transcriptSummaryVersion);
    }
    return this.snapshot;
  }
}

/// Rows a snapshot drew, of which chat, and the machine and session they were proven of.
type ShownRows = {
  sessionId: string | undefined;
  rows: readonly AcpmuxRow[];
  peer: string | undefined;
  generation: number | undefined;
};

/// Rows a page of a chat's process list asks for: acpmux's most (hub/processes.rs).
const PROCESS_LIST_PAGE = 1_000;
/// Pages one read of a chat's process list takes at most (100,000 processes): past it the daemon
/// is naming new cursors without end.
const PROCESS_LIST_MAX_PAGES = 100;

/// The chat a client held when its connection was lost, handed to the client the page connects
/// next (`carriedChat`, `connect`). Leo, 2026-11-11: "it keeps showing and then hiding, and then
/// showing and then hiding your responses, or my responses". In the app every lost connection
/// (`onLost`) made a new client, which read the chat again from nothing: a kept tail (the page's
/// oldest read of it) or the newest attach page alone, so the rows read since went and came back,
/// and every reply the page cut came back under another id, remounted and faded in again. The new
/// client starts from this instead: the same records, the same row ids and the rows on screen, and
/// the attach of the reconnect merges into them as a reconnect of one client does (`open`'s
/// `resumeAfter`), so a row once shown stays shown and keeps its node.
export type CarriedChat = {
  sessionId: string;
  events: EventRecord[];
  rows: readonly AcpmuxRow[];
  generation: number | undefined;
  peer: string | undefined;
  summary: Record<string, any> | undefined;
  turnOpener: EventRecord | undefined;
  historyExhausted: boolean;
  queue: QueuedPrompt[];
  configSeq: number;
  usageFromSeq: number;
  promptRowKeys: ReadonlyMap<string, string>;
  optimisticPromptRows: ReadonlyMap<string, string>;
  optimisticPromptTexts: ReadonlyMap<string, string>;
  queueAuthors: ReadonlyMap<string, Participant | null>;
  /// How far the records run, and from where: the next open resumes after `lastSeq`, and older
  /// pages load from `firstSeq`.
  lastSeq: number;
  firstSeq: number | undefined;
  /// The holes a gap read had not filled when the connection went (`gapReads`): the next open
  /// resumes from the lowest of them, so no record in one is skipped.
  gapSeqs: number[];
  /// Where the next older page of the agent's own transcript ends (`nativeNext`), when one was read.
  nativeNext: { before: number; mark?: string } | undefined;
};

/** Direct browser client for the authenticated acpmux WebSocket protocol. */
/// Every native root a session summary names into `fold`: the chat's current agent session and
/// the earlier ones acpmux retired (`retiredAgentSessionIds`), which older records still name.
/// True when a record already folded named one of them: the rows drawn from it are stale.
function seedRoots(
  fold: SubagentFold,
  summary: { agentSessionId?: unknown; retiredAgentSessionIds?: unknown } | undefined,
): boolean {
  const retired = summary?.retiredAgentSessionIds;
  let named = false;
  if (Array.isArray(retired)) for (const id of retired) named = fold.setRoot(text(id)) || named;
  return fold.setRoot(text(summary?.agentSessionId)) || named;
}

export class AcpmuxDirectClient {
  // A busy daemon may legitimately emit no frame for many seconds, so quiet alone never ends a
  // socket. Once a request has waited this long, and the daemon proved itself no sooner, the pane
  // asks the daemon one cheap question on it (`probeDaemon`): the daemon's own answer, even an
  // error, says it is alive and only slow, and its socket and requests are kept. Timed from the
  // request, never from the last frame: the app's bridge answers some requests itself
  // (`_acpmux/status`, refusals), also with no daemon, and such frames prove nothing.
  private static readonly DAEMON_PROBE_AFTER_MS = 5_000;
  // No frame at all this long after that question: nothing behind the open socket answers (acpmux
  // restarted under the app's bridge). The pane gives the socket up and asks its host for a fresh
  // handshake, which finds the new daemon; before, it waited two minutes of silence and said
  // "Waiting for the agent service" meanwhile (ask-34b8c4ef25). Under the line's 25 s deadline, so
  // a dead socket is replaced before the line shows.
  private static readonly DAEMON_PROBE_ANSWER_MS = 15_000;
  // A wire that cannot carry the probe (a chat on another machine: `RemoteAcpmuxWire` serves no
  // daemon-backed method that cheap and refuses `_acpmux/peers` as `remote.unsupported`) keeps the
  // older bound: its socket is given up only after this long with no frame while a request waits.
  private static readonly DAEMON_LIVENESS_GRACE_MS = 120_000;
  /// Coalesces the snapshots of acpmux events that land within one display frame: a fast stream
  /// sends several deltas per frame, and each snapshot re-renders the transcript. The page that
  /// draws the transcript sets it (main.tsx: ``nextFrame``); unset, each event snapshots at once.
  static scheduleFrame: ((run: () => void) => (() => void) | void) | undefined;
  /// The connection state of the snapshot waiting for the next frame.
  private frameSnapshot?: string;
  /// Another chat changed while the page was hidden: the list draws again when it shows.
  private listChangedWhileHidden = false;
  /// `isWorking` as the last snapshot said it, and a hidden page's draw of a change other than its
  /// text stream (`emitInFrame`): one 50 ms timer at a time, which ends when it fires or on close.
  private drawnWorking = false;
  private drawnWorkingSession?: string;
  /// The event just reduced only grew the streaming reply's or thought's text (`emitInFrame`).
  private streamGrew = false;
  /// Turns of the shown chat this client saw end (`turnsEnded` in the snapshot).
  private turnsEnded = 0;
  private hiddenDraw?: ReturnType<typeof setTimeout>;
  /// Other chats' changes waiting for their turn to draw (`drawOtherChats`), and when they last drew.
  private otherChatsDraw?: ReturnType<typeof setTimeout>;
  private otherChatsDrawnAt = Number.NEGATIVE_INFINITY;
  /// When the first of the waiting changes came (`drawOtherChats`).
  private otherChatsSince?: number;
  /// The frame this client waits for, if any: one at a time, cancelled on close (`emitInFrame`).
  private frameRequest?: { cancel?: () => void };
  private socket?: WebSocket;
  private browserIdentity?: BrowserDeviceIdentity;
  private browserDeviceReady = false;
  private nextRequest = 1;
  private pending = new Map<
    number | string,
    {
      resolve: (value: any) => void;
      reject: (error: Error) => void;
      timer?: ReturnType<typeof setTimeout>;
      waiting?: boolean;
      retryable: boolean;
      /// Puts the request on the wire again (a busy refusal's retry).
      send: () => void;
      /// Busy refusals it has had.
      busy: number;
      /// When it was first sent: the liveness probe is timed from the oldest waiting one.
      since: number;
      /// What it asked: a reply to `_acpmux/status`, which the bridge answers, proves no daemon.
      method: string;
    }
  >();
  /// A request crossed its progress threshold on an open socket. This is a UI state, never a
  /// failure: a busy daemon may answer later, while a close still rejects promptly.
  private daemonWaitingSince?: number;
  /// How many `pending` requests are `waiting` (`markWaiting`, `noteRequestSettled`): a reply asks
  /// whether any still waits without walking every pending request (draining N cost N²).
  private waitingRequests = 0;
  private daemonLastFrameAt = Date.now();
  /// The liveness probe out on the current socket, by request id and when it went; none while no
  /// request waits or once the daemon answered it.
  private daemonProbe?: { at: number; id: number };
  /// When the current socket's daemon last proved itself (its open, or its answer to the probe).
  private daemonProvedAt = Date.now();
  /// The last frame on this socket only the daemon makes: a notification (a chat's events), or a
  /// result to a request the bridge does not answer itself. A daemon that sends these is alive, if
  /// slow, whatever its probe is waiting on; host-made error frames and `_acpmux/status` never count.
  private daemonFrameAt = 0;
  /// The host refused the probe on the current socket (a remote wire): `DAEMON_LIVENESS_GRACE_MS`.
  private daemonProbeRefused = false;
  private daemonLivenessTimer?: ReturnType<typeof setTimeout>;
  /// The daemon's count of this connection's work requests: a page never sends past it
  /// (requestBudget.ts). Reset with the connection.
  private budget = new RequestBudget();
  private events: EventRecord[] = [];
  private rows = new OrderedRows();
  /// Each drawn offer's row (a suggested tasks card), by offer id (offer/SuggestedTasks.tsx).
  private offerRows = new Map<string, string>();
  /// Offers whose result prompt reached this chat (its user_message): a replayed `queued` record
  /// of it draws no second line.
  private receivedOffers = new Set<string>();
  /// The chats started from this chat's offers, watched while they run for their rows' subtitles.
  private readonly offerChildren = new OfferChildren(
    (method, params) => this.request(method, params, 15000),
    () => this.selectedSessionId,
    (child) => this.childChanged(child),
  );
  private sessions: Session[] = [];
  private browserWorkspaces?: BrowserWorkspaces;
  private workspaceRead = 0;
  /// Senders of addressed prompts no listed chat named (`incomingContext`).
  private unknownSenders = new Set<string>();
  /// Each waiting prompt's author as its newest `queued` or `queue_updated` record named it (null:
  /// none), kept while it waits, so acpmux's list (which names none) keeps it (mergeQueue).
  private queueAuthors = new Map<string, Participant | null>();
  /// The waiting prompts edited since they were queued (`queue_updated`): the person's words now,
  /// never acpmux's resume, whatever their text or client says (mergeQueue).
  private queueEdited = new Set<string>();
  /// The session list: the newest page opens the chat and the pane follows its changes from there
  /// (cx-2lv1k); the later pages are read only when something asks for every chat
  /// (`readAllSessions`). Its cursor and rows are kept for the page's next client of the same
  /// connection (`SessionPager.share`), so a reconnect reads the rows changed since (`follows`).
  private readonly sessionPages = new SessionPager<Session>(
    (method, params) => this.request(method, params),
    () => this.sessions,
    () => this.readPeerRows(),
  );
  /// The later pages being read (`readAllSessions`), and whether a list read anew meanwhile asks
  /// for them again once that read ends (it ends early when a newer list starts).
  private laterRead?: Promise<void>;
  private laterAgain = false;
  /// Stops listening for `wantAllSessions`.
  private stopWantAll?: () => void;
  private sessionReread: ReturnType<typeof setTimeout> | undefined;
  /// The list read asked for peer batch rows (`readPeerRows`), not yet started.
  private peerRowsRead: ReturnType<typeof setTimeout> | undefined;
  /// The pending reread follows a watch lag: once it sets the list, Needs you's asks resync too.
  private sessionRereadResyncsAsks = false;
  /// Sidebar entries by acpmux session object. A changed session arrives as a new object, so unchanged rows keep their entry and skip rendering.
  private sessionEntries = new WeakMap<Session, AcpmuxSessionEntry>();
  /// The snapshot's session entries for the list they were mapped from: a snapshot whose list did
  /// not change (a streamed token, a row's change) hands the pane the same array, so what the pane
  /// derives from `snapshot.sessions` keeps its identity and no row redraws for it.
  private sessionEntriesOf?: { sessions: Session[]; entries: AcpmuxSessionEntry[] };
  /// How `this.sessions` (`to`) was made from `from` by in-place changes (`sessionChanged`): the
  /// positions replaced, each by a session of the same id. `sessionEntryList` patches only those.
  private sessionsReplaced?: { from: Session[]; to: Session[]; at: number[] };
  /// The snapshot summary's `usageStats`, kept while acpmux's numbers are the same (sameUsageStats).
  private summaryUsage?: SessionUsageStats;
  /// The snapshot summary's `taskList`, kept while acpmux's list is the same (chatTaskListOf).
  private publishedTaskList?: ChatTaskList;
  private publishedSummaryOf?: {
    summary: unknown;
    usage: unknown;
    start: AcpmuxSessionStart | undefined;
    value: AcpmuxSnapshot["summary"];
  };
  /// The usage read in flight (refreshUsage).
  private usageRead?: Promise<void>;
  private selectedSessionId?: string;
  /** The session a link named that the daemon does not have (`sessionMustExist`). */
  private missingSession?: string;
  /// When the pane found `missingSession` unlisted, and the machine its kept summary named: why it
  /// is missing (chatUnavailable.ts) reads both.
  private missingSince = 0;
  private missingPeer?: string;
  /// Reads the peers again while the missing chat's machine is still connecting.
  private missingRecheck?: ReturnType<typeof setTimeout>;
  /** Why `missingSession` is set: the daemon's list lacked it when the pane opened, or it left the list while shown. */
  private missingReason?: MissingSessionReason;
  /// More than one listed chat goes by `missingSession` (`chatNamedBy`): the pane says the session
  /// no longer exists instead of waiting for a machine.
  private missingAmbiguous = false;
  /// What acpmux's resolver (`_acpmux/resolve`) said `asked`, a missing tab id no listed chat goes
  /// by, names: `session` when it named one, none when it named nothing (`resolveMissing`).
  private missingResolved?: { asked: string; session?: string; done: boolean };
  /// `missingPeer` was read from the tab's id (`HOST/NAME`), not from a chat this Mac saw.
  private missingPeerNamed = false;
  /** The adopt acpmux refused because its chat is live elsewhere, until the user picks a way on. */
  private liveAdopt?: { adopt: AcpmuxAdopt; canFork: boolean; command?: string };
  /** Take Over refused because the watched chat's app still runs it, until the user picks a way on. */
  private liveTakeOver?: { canFork: boolean; command?: string };
  /// The chat `liveTakeOver` asks about: the choice is shown only on that chat.
  private liveTakeOverFor?: string;
  private summary: Record<string, any> | undefined;
  /// The event seq the summary's config options are current as of: attach's `lastSeq` (its session
  /// names the options it runs now), then each newer config update. A replayed update before it is
  /// history and never takes the current options back (a chat moved from Low to High).
  private configSeq = 0;
  /// The seq the selected chat's `subsessionLimits` were read at (the attach's `lastSeq`, then each
  /// newer `limits` record): an older record replayed with the page never takes them back.
  private limitsSeq = 0;
  /// Bumped each time the summary's limits come from anything but a `_acpmux/subsession/limits`
  /// reply: a chat selected, an attach, a newer `limits` record. A reply is current only as of its
  /// request, so one that finds this moved is older than what the summary holds. A seq alone can't
  /// tell: a re-attach can install a newer inherited limit at the same `lastSeq`.
  private limitsVersion = 0;
  /// The running-limit changes in flight, one after another: each steps from the answer before it.
  private limitsChain: Promise<unknown> = Promise.resolve();
  /// The session detail's goal is current through attach's lastSeq; older session-info history
  /// must not replace it while newer live goal events still apply.
  private goalSeq = 0;
  private queue: QueuedPrompt[] = [];
  /// Prompts that left the queue without running (snapshot `queueWithdrawn`), the last QUEUE_WITHDRAWN_KEPT.
  private queueWithdrawn: readonly string[] = [];
  private pendingPermission?: AcpmuxPermission;
  /// Asks that came while `pendingPermission` waits, oldest first, by permission id: acpmux keeps
  /// every pending ask (a question beside a command, two subagents asking), and the card answers
  /// them one at a time.
  private waitingPermissions = new Map<string, AcpmuxPermission>();
  private pendingSecret?: AcpmuxSecretAsk;
  private groupedPermissions = new Map<string, AcpmuxPermission>();
  /// Every chat's open permission requests, for the Needs you list (needsYou/asks.ts).
  /// The pane's relay never sends `_acpmux/info`, so the app's host reads it (asks.ts `pendingReader`).
  private readonly asks = new AskTracker(
    pendingReader(
      // Read when called: the field is set before the constructor's `gitRoute`.
      () => this.gitRoute === "native",
      (op, params) => postNative(op, params),
      (method, params) => this.request(method, params),
    ),
    permissionFromMessage,
    () => this.emitInFrame("asks"),
  );
  /// The session list the tracker last compared counts against.
  private askedSessions?: readonly Session[];
  /// The turn's open permission questions, and the edits that wait on one (cx-p5fgx): an edit
  /// is "pending" from its question, or from arriving while one is open, until it completes.
  private openQuestions = new Set<string>();
  private heldEdits = new Set<string>();
  /// The questions asked and not yet decided, by permission id: a decision draws a record of what
  /// was chosen where the card was (`questionRecord`, question/record.ts).
  private askedQuestions = new Map<string, AgentQuestion>();
  /// Questions the person wrote a prompt of their own while they waited (`answeredInChat`).
  private repliedWhileAsked = new Set<string>();
  /// The last question that ended declined or cancelled, until the person's next prompt.
  private lastUnanswered?: { rowId: string; at: number };
  /// The single permission cards asked and not yet answered, by permission id: an answer draws a
  /// receipt (`permissionRecord`, permissions/record.ts).
  private askedPermissions = new Map<string, AcpmuxPermission>();
  private commands: SlashCommand[] = [];
  /// The newest prompt suggestion (`SUGGESTION_KIND`) still valid: unset by a newer clear, prompt
  /// or turn start. `suggestionSeq` is the newest suggestion record seen (a set or a clear), and
  /// `suggestionFence` the newest prompt or turn start: a record older than either is history (an
  /// older page folded in) and changes nothing.
  private promptSuggestion: { text: string; seq: number } | undefined;
  /// The person took the shown suggestion into the composer (`takeSuggestion`); the next send says so.
  private suggestionTaken = false;
  private suggestionSeq = 0;
  private suggestionFence = 0;
  private usage: { used: number; size: number; setup?: number; cacheExpiresAt?: number } | undefined;
  /// The running turn's output tokens: its model calls' generated usage added up from
  /// `turn_started`, the running line's count (conversation/WorkingFor.tsx). Unset outside a
  /// turn, and for a turn whose start this client did not see (it missed calls before it attached).
  private turnTokens: number | undefined;
  /// The turn's output (`turnTokens`) beside what its calls read, while every call so far named both
  /// (claude_stdio/inbound.rs); unset from the first that did not (an older acpmux), so the line
  /// never shows a split that leaves calls out.
  private turnTokenSplit: TurnTokenSplit | undefined;
  /// The first seq whose usage this client holds: the attach page's first record when acpmux has
  /// older ones (older pages carry no usage), else 0. A turn that started before it has calls this
  /// client never saw, so every rebuild leaves its tokens unset. Infinity until an attach answers:
  /// live events can land before its reply, and those alone are not a whole turn.
  private usageFromSeq = Infinity;
  /// Set once an update for this session is applied, so an older fetched list cannot replace it.
  private commandsApplied = false;
  private optimisticPromptRows = new Map<string, string>();
  /// A prompt's transcript row id survives replay after acpmux accepts it, so an echo never
  /// becomes a different `user-${seq}` row when a live rebuild happens.
  private promptRowKeys = new Map<string, string>();
  /// The held events' prompt rows while an older page folds (`foldOlder` swaps `promptRowKeys`
  /// for the page's own), so a `sender_claim` on that page still reaches a row already drawn.
  private heldPromptRowKeys: Map<string, string> | undefined;
  private optimisticPromptTexts = new Map<string, string>();
  /// Prompts of this pane that wait in acpmux's queue: their bubble went when they were queued,
  /// and comes back (failed, with Retry) if acpmux refuses them when their turn comes.
  private queuedSends = new Set<string>();
  /// The steers the agent has not read yet, by row (the reply that was streaming when one went
  /// still streams above it; a later message means the agent read them).
  private waitingSteers: readonly { rowId: string; promptId?: string }[] = [];
  /// The rows of `waitingSteers` as the snapshot names them, made again only when that list changes.
  private waitingSteerRows: { from: readonly { rowId: string }[]; rows: readonly string[] } | undefined;
  /// A prompt sent now to an agent that cannot steer while a turn ran (acpmux `queue_order`
  /// `next`): acpmux ends that turn (a cancel, or the agent's `end_turn`, acpmux #22808) and runs
  /// the prompt next. That end is not a Stop: its summary is `continued`, and the prompt then
  /// draws inside the turn it went into.
  private interrupting?: string;
  /// The prompts sent now that ended the turn they went into, each with that turn's summary row:
  /// each `continues` the turn.
  private continuations = new Map<string, string>();
  /// The prompt sent now whose turn ended (`continued`) and that has not run yet. It may never run:
  /// removed, withdrawn or refused, the turn it ended reads as ended again (``dropContinuation``).
  private awaiting?: string;
  /// The turns this page saw end (`turn_result`): a summary that still names one as running was
  /// read before it ended (``staleRun``).
  private endedTurns = new Set<string>();
  /// Named turns a newer turn opened over: an end naming one is late, whatever the running turn names.
  private supersededTurns = new Set<string>();
  /// A forced Stop retires its compaction. The next explicit prompt fences the old compaction's
  /// delayed boundary; a new running update after that prompt starts a fresh row but cannot
  /// attribute a later unscoped boundary. Only the turn's terminal result can settle that row.
  private retiredCompactionTurnId?: string;
  private compactionFenceSeq?: number;
  /// Each steer's row by its promptId. A steer that reaches the agent as its turn ends runs as the
  /// next prompt with the same promptId, recorded again: that prompt's row replaces the steer's.
  private steerRows = new Map<string, string>();
  /// The running turn acpmux logged as stopping (its `stopping` record, hub/cancel.rs), until it ends.
  private stoppingTurn?: { turnId?: string };
  /// Steers logged after their turn's `stopping` record. The agent never reads one: if the turn ends
  /// stopped, each goes below the stop (`deferLateSteers`), where it belongs in time, and acpmux sends
  /// it again as the next prompt with the same promptId, whose row replaces it (`steerRows`).
  private lateSteers: string[] = [];
  /// The promptIds drawn as prompts. An older page folds in after the rows below it, so the steer
  /// a held prompt re-ran comes after that prompt: it draws nothing. Kept across that fold.
  private promptsShown = new Set<string>();
  /// Where each prompt was sent from, by prompt id (`sender_claim`, conversation/sentFromHarness.ts): a
  /// row drawn after its claim reads it here, and a claim after its row (the daemon writes it once
  /// the prompt is kept, an older page folds in later) updates that row.
  private sentFromPrompts = new Map<string, SentFrom>();
  /// The inbox notice row that names each prompt id (agentInbox's route of another agent's send): a
  /// claim that comes after its notice reaches that row's thread.
  private inboxClaimRows = new Map<string, string>();
  /// Attachments sent with a prompt until its user-message event gives it a durable row id.
  private optimisticPromptAttachments = new Map<string, ComposerAttachment[]>();
  /// Attachments for completed prompts, used when their turn is retried later.
  private retryAttachments = new Map<string, ComposerAttachment[]>();
  private optimisticPromptParts = new Map<string, PromptContentPart[]>();
  private optimisticPromptInputs = new Map<string, string>();
  private retryInputs = new Map<string, string>();
  /// What a prompt's sender is told once acpmux took the prompt (its `user_message` echo, or the
  /// reply), by prompt id. A refusal comes before either, so the composer keeps the prompt.
  private promptAccepts = new Map<string, (accepted?: { steer?: unknown; state?: unknown }) => void>();
  /// The prompt ids this client sent: acpmux's refusal of one answers its request (a failed bubble
  /// with Retry), so its `prompt_refused` record adds no notice (``noticeRefusal``).
  private readonly sentPrompts = new Set<string>();
  /// Told each prompt id acpmux took in the shown chat (`_acpmux/prompt_accepted`, or a live or
  /// read `user_message` or `queued` record): the pane retires a lost prompt's id the host sent
  /// again after its sender gave up waiting (lostPrompt.ts).
  promptShown?: (promptId: string) => void;
  private sawPrompt(event: EventRecord): void {
    if (!this.promptShown || (event.kind !== "user_message" && event.kind !== "queued")) return;
    const promptId = event.msg?.promptId;
    if (typeof promptId === "string") this.promptShown(promptId);
  }
  private sawPrompts(events: readonly EventRecord[]): void {
    if (this.promptShown) for (const event of events) this.sawPrompt(event);
  }
  /// A prompt that was not sent, by its row: what Retry sends again.
  private failedPrompts = new Map<string, { input: string; attachments: ComposerAttachment[]; promptId?: string }>();
  /// The host's store of prompts no agent has taken yet (unsentPrompts.ts), and what this page put
  /// there, by promptId. Never cleared by a chat switch: only an agent taking the prompt, Remove or
  /// Edit takes one out, so a relaunch draws every one again as its Not sent row.
  private unsentStore?: UnsentPromptStore;
  private unsentKept = new Map<string, { sessionId: string; record: UnsentPromptRecord }>();
  /// Prompt ids whose Not sent row came from the host's store (`drawUnsentRow`): a lost prompt's
  /// sender may draw the same prompt on its way over one (`drawLostPrompt`).
  private restoredUnsent = new Set<string>();
  /// Failed prompt rows a chat switch cleared (``select``), never ones the person removed or took
  /// back: a Trust replay kept for one (failedRowTrustRetry.ts) still sends it once its chat shows
  /// again (``restoreFailedPrompts``). Row ids only, the oldest dropped past a bound.
  private clearedBySwitch = new Set<string>();
  /// Prompts sent from this page that acpmux has not taken yet: they live only here until then.
  private untakenSends = 0;
  /// The promptIds a Retry is sending: a refusal of one says "Still not sent".
  private retriedPrompts = new Set<string>();
  /// Where each prompt this pane sent is on its way, by prompt id, and the row that shows it.
  private deliveries = new Map<
    string,
    { delivery: PromptDelivery; rowId: string; timers: ReturnType<typeof setTimeout>[] }
  >();
  private firstSeq?: number;
  /// Pages fetched by an indexed rail jump. They are scoped by session generation in the key, so a
  /// reconnect or chat switch can never reuse rows from another journal. Values are promises to
  /// coalesce a click and a nearby scrub into one daemon read.
  private indexedPages = new Map<string, Promise<EventRecord[]>>();
  /// Prompt rows named by the index but not present in a sparse target page. They keep the full
  /// rail geometry stable while the adjacent transcript pages warm; a real event row supersedes
  /// the placeholder on the next snapshot.
  private indexedPlaceholders = new Map<string, AcpmuxRow>();
  /// Stretches between an indexed page and the history held below it (`mergeIndexedPage`), newest
  /// jump first, read forward one bounded page at a time (`fillIndexedGaps`) so the turns between a
  /// rail target and the tail draw whole instead of as prompt-only placeholders.
  private indexedGaps: { after: number; before: number }[] = [];
  private indexedGapFill?: Promise<void>;
  /// The prompt that opened the turn the held history starts in, when that prompt is older than
  /// every held event: a Chief subagent's first prompt carries the Chief's whole view (100+ KB),
  /// so once its turn's output passes the open page's cap the page starts mid-turn and the prompt
  /// would never draw (Lawrence 2026-10-19). It draws first but is not history: older pages still
  /// load from `firstSeq`, and it gives way once a page brings it.
  private turnOpener?: EventRecord;
  /// The prompt the open turn runs, by its root: acpmux's automatic continuation of a cut turn runs
  /// `P~resume-n`, which is `P`'s (hub/auto_resume.rs). A Stop kept through a reconnect stops only
  /// that turn (stopThroughReconnect.ts).
  private turnPrompt?: string;
  private lastSeq = 0;
  /// The chat's held surge, its newest snapshot by seq (conversation/surgeHold.ts): the composer hat's
  /// one row for it (SurgeHoldRow.tsx). A full refold keeps it: its events set it again or leave a
  /// listing's newer one.
  private surge?: SurgeHold;
  /// Each gap read out or failed (`fetchMissedEvents`), by its own key: the seq the chat's records
  /// are whole through below a page merged past that gap. A copy kept, or the next open's resume,
  /// continues from the lowest of them, not from `lastSeq`, so the records in a hole are read once
  /// the machine answers. One per read: a lag's read and a reconnect's can be out together, and
  /// one that lands never clears another's hole.
  private readonly gapReads = new Map<number, { sessionId: string; seq: number }>();
  /// A lag marker that came while the chat's attach was out (`resyncAfterLag`), read once it lands.
  private lagOwed?: { sessionId: string; generation: number };
  /// The host leaves a chat's stream out while nobody sees its pane (AcpmuxPaneSocket+Hidden.swift): from its start
  /// marker on (`hostHidden`), the seq the chat is whole through. The turn boundaries a hidden page still gets move
  /// `lastSeq` past the hole, so the read when the pane shows starts here (`resyncAfterLag`, reason `host_hidden`).
  private hiddenHole?: { sessionId: string; generation: number; afterSeq: number };
  private hostHidden = false;
  /// A read of what a lag dropped that gave up while the socket stayed open (`readMissedAfterLag`).
  private lagReadOwed?: { sessionId: string; generation: number; afterSeq: number };
  /// The read of what a lag dropped that is out or waits to try again (`readMissedAfterLag`), and
  /// the oldest cursor of the lags heard meanwhile (`again`), read once it lands.
  private lagRead?: { sessionId: string; generation: number; again?: number; at: number };
  private gapReadKeys = 0;
  private turnOpen = false;
  /// The pane's fold saw its last turn end (`turn_end`, `turn_result`, or acpmux holding none,
  /// ``hostEndedTurn``) and no turn start since. It is the one "turn ended" signal every end path
  /// sets: a summary that still says "running" without naming a turn the pane has not seen end is
  /// from before that end (``staleRun``), so the live line and its Thinking clock go with the end,
  /// not with acpmux's later status change (Leo, 2026-11-21: "the thinking timer is overstaying its
  /// welome after you just replied!").
  private turnEndSeen = false;
  /// The open turn's daemon start (its `turn_started`, or the summary's `turn.startedAt` when that
  /// record is outside the held page): the live line's clock counts from it, never from an older
  /// prompt a resumed turn still opens with. Unset falls back to the prompt's time (turns.ts).
  private turnStartedAtMs?: number;
  /// When the prompt that opened the open turn was recorded: a summary start before it is an earlier
  /// turn's (`dateTurnFromHost`).
  private turnPromptAtMs?: number;
  private autoResumedAttempt: number | undefined;
  /// The latest prompt was acpmux's cache compaction (conversation/cacheCompaction.ts): the
  /// compaction after it ran before the prompt cache expired, not because the person asked.
  private cacheCompactPrompt = false;
  /// The last seq seen when Stop was pressed: only a turn event after it answers that Stop. A
  /// rebuild (loadOlder, lag resync) replays older ones, which must not answer a later Stop.
  private stopAfterSeq?: number;
  /// The daemon turn a Stop was sent to. A later result for another turn cannot settle this Stop.
  private stopTurnId?: string;
  /// A turn opened after a Stop bound to a known turn, and it is not that turn (it names another, or
  /// none): the Stop no longer covers what runs, though its own result still answers it.
  private stopSuperseded = false;
  /// A Stop sent before its turn opened has seen that turn's first opener (`stopSeesTurnOpen`).
  private stopOpenerSeen = false;
  /// The daemon's current turn identity, when the live records name one.
  private runningTurnId?: string;
  /// The last seq seen when Stop was sent to the loaded chat: the snapshot says `stopping` until that
  /// turn ends, or a turn opens after it. Apart from `stopAfterSeq`, which the stopped turn's own late
  /// `turn_started` answers.
  private stoppingAfterSeq?: number;
  /// Stop went out while acpmux listed the chat running but its turn had not opened here yet:
  /// `"pending"` until the next turn opens, then that opener's seq, so a rebuild replaying the same
  /// opener still treats it as the stopped turn's own.
  private stoppedTurnOpener?: "pending" | number;
  /// The daemon's turn identity distinguishes a late opener from a new turn after a missed end.
  private stoppedTurnId?: string;
  /// A fork's `forked` boundary event: its copied history ends there (cx-ncc.61's versions).
  private forkedAtSeq: number | undefined;
  /// Where the chat's init lines change its model or route (sessionStart.ts `insertRunChange`).
  private runChanges: RunChange[] = [];
  /// The newest init line by seq: what the chat runs on now (version and folder included), which
  /// Session Info and /status show. Kept apart from `runChanges`, whose points keep the facts of
  /// where a run started.
  private latestStart?: { seq: number; start: AcpmuxSessionStart };
  /// The ids of the transcript lines `drawRunChanges` drew.
  private runChangeRows = new Set<string>();
  /// Session replay (replay/ReplayScreen.tsx): the recorded events are folded only through this seq.
  private replayThrough?: number;
  /// The events `replay` sorted by seq, while they are still `events`: a seek forward starts at the
  /// first event after the last one shown instead of walking every event before it.
  private replaySorted?: readonly EventRecord[];
  /// A `fed` client its page let go of (`dispose`).
  private disposed = false;
  /// This computer's clock minus the session's (an SSH or Cloud peer stamps events with its own
  /// clock): the smallest arrival lag of a live event, since delays only make it larger.
  private clockOffset?: number;
  /// acpmux lists `acp.session.fork` among the operations it serves.
  private canFork = false;
  private handoffSupported = false;
  private readonly peerEvents = new PeerStateEvents();
  /// The `_acpmux/*` methods acpmux's `initialize` lists (`_meta.acpmux.extensions`).
  private extensions: readonly string[] = [];
  private features = new Set<string>();
  /// acpmux calls this connection local (`_meta.acpmux.origin: "local"`). Without that, a
  /// WebSocket connection is remote-origin to acpmux, which never pools for it.
  private localOrigin = false;
  /// The origin acpmux names for this connection; `unknown` until (or unless) it names one.
  private origin: NonNullable<AcpmuxSnapshot["origin"]> = "unknown";
  /// The app's wire says this chat runs on the person's own Cloud machine (`ownerCloud`).
  private ownerCloud = false;
  /// `sessions` holds the daemon's list: its first page has been read.
  private listedSessions = false;
  /// This page drew a chat from a kept tail (`drawKeptTail`), so those rows were on screen before
  /// any attach answered. The pane's host reads it in the first-paint report and shows such a chat
  /// in one frame instead of fading it in (tailCache.ts, AgentPaneView+Loading.swift).
  private drewKeptTail = false;
  /// The settled view the open's attach answered with (`settled-attach-v1`), for the chat and
  /// selection it was read for: its frame is the one the pane draws first, and the host is told
  /// once it is on screen (`settled` in the snapshot, App.tsx `pane.painted`).
  private settled?: SettledView & { sessionId: string; generation: number };
  /// A kept tail a cold open drew while its socket was still connecting (`drawTailWhileConnecting`):
  /// the chat, the selection it was drawn for and the newest seq drawn. The open's attach takes it
  /// as the tail it lays its page over, as it does a tail it read itself; anything that clears the
  /// rows (`resetSessionState`) clears it.
  private earlyTail?: { sessionId: string; generation: number; through: number };
  /// The selection an open in flight may still draw a tail for while it connects; cleared once
  /// the open reaches its own draw, which then decides.
  private earlyTailWindow?: number;
  /// The hold of the open in flight (`OPEN_HOLD_MS`): a tail drawn for the open's chat ends it.
  private openHold?: number;
  /// The selected peer chat was drawn from the Mac's copy of it (peerCopy.ts): set from the draw
  /// until an attach reads the chat, and kept, `offline`, while its machine does not answer.
  private peerCopy?: PeerCopy;
  /// Every live record that came while an attach over rows drawn from a kept tail or the Mac's copy
  /// was out. Those above the rows apply as they come; if the attach says the rows are not this
  /// session's history (recreated, or a machine back on an older log), these alone are kept with
  /// its page (`attach`). One per seq (a reconnect's replay takes its place): at most one entry
  /// for each record the session streamed meanwhile, as the transcript holds.
  private copyLive?: Map<number, EventRecord>;
  /// The chat whose row said its machine is back while its copy's attach or read was out: read
  /// from the machine once that ends offline (`reattachIfBack`). One flag, no timer.
  private copyBack?: string;
  /// The read `drawPeerCopy` has out, so a row change meanwhile waits for it; `changed` says its
  /// row changed meanwhile: a read that turns out to be of another session than the row names now
  /// is read once more. Each read has its own, so one read never clears another's.
  private peerCopyReading?: { sessionId: string; changed: boolean };
  /// The session (`createdAt`) the rows on screen are of, when known: from the tail drawn or the
  /// attach that answered. A copy drawn in their place of another session resets the session.
  private rowsGeneration?: number;
  /// The machine the rows on screen are of, when known (the tail's row, or the attach's).
  private rowsPeer?: string;
  /// Counts the attaches of the copy on screen: one that a newer one (a reconnect's) took over
  /// leaves the copy to it when it fails.
  private copyAttaches = 0;
  /// The chat whose rows the last snapshot drew (the tab's chat while it is missing), those rows,
  /// and the machine and session (`createdAt`) they were proven of.
  private drawn?: ShownRows;
  /// The chat held when the connection was lost, for the client the page connects next (`takeCarried`).
  private carried?: CarriedChat;
  /// The rows a reset took off screen (`resetSessionState`), until the chat's next frame says
  /// whether it drew them again or replaced them (`noteReplace`).
  private cleared?: ShownRows & { cause: string };
  /// The tail of the tab's chat that left the list while drawn, for its reopen (`select`).
  private leftTail?: { sessionId: string; tail: KeptTail };
  /// The rows on screen when the chat was reset, for its next rebuild (`shownRowsToKeep`): a
  /// resync of the same chat lays its rows over these, so each unchanged row keeps its object, and
  /// the pane its node, instead of every row being built anew.
  private shownBefore?: ShownRows;
  /// Each chat's full transcript replaces on this page (`noteReplace`), for the flicker log and tests.
  private readonly replaces = new Map<string, number>();
  /// The attach out now, of which session: a row that says its machine is back while it is out
  /// (no copy drawn yet) is kept for after it, as for a copy's attach (`copyBack`).
  /// The attach of the selected chat that is out.
  private attachOut?: { sessionId: string };
  /// Each session and machine the selected chat's row named while an attach of it ran, from its
  /// ask until it drew its page (one entry each): the page is of none of the others (`attach`).
  private attachWatch?: AttachWatch;
  /// The attach `open` asked with the chat list, until the open takes it or drops it (`askEarly`).
  private earlyAttach?: EarlyAttach;
  /// The `createdAt` of the session the rows drawn before the attach ar…134641 tokens truncated… `/side`'s staged files, in the
  /// prompt as a send puts them (#40066); past one message's budget, the largest image previews go
  /// as links to their saved originals (promptBudget.ts).
  /// A recording goes only to an agent that takes voice, a video's frames only to one that takes
  /// images, as a send's do. `gesture`: the Enter a `/side` held for its files bound
  /// (`bindSideGesture`); the prompt goes under its prompt id and redeems its ticket.
  async promptSide(
    sessionId: string,
    text: string,
    attachments: ComposerAttachment[] = [],
    gesture?: { promptId: string; ticket: Promise<string | undefined> },
  ): Promise<void> {
    const capabilities = this.summary?.agentCapabilities?.promptCapabilities;
    const audible = takesAudio(capabilities, this.summary?.configOptions)
      ? attachments
      : attachments.filter((attachment) => attachment.kind !== "audio");
    const sendable = capabilities?.image === false ? withoutFrames(audible) : audible;
    const carried = sendable.length ? fitPromptBudget(text, sendable, {}, promptBudgetFor(this.socket)) : sendable;
    const ticket = gesture ? await gesture.ticket : undefined;
    await this.offerChildren.prompting(sessionId, () =>
      this.request("session/prompt", {
        sessionId,
        prompt: promptBlocks(text, carried),
        _meta: {
          acpmux: { promptId: gesture?.promptId ?? crypto.randomUUID() },
          ...(ticket ? { cmuxGesture: ticket } : {}),
        },
      }),
    );
  }
  /// Binds the person's current gesture to `/side`'s prompt, held for its files: bound to no chat
  /// (the side chat it goes to does not exist yet), so the side chat's prompt redeems it by its
  /// prompt id (AgentPaneUserGestures `redeem`). Not a send ticket: it holds no uploads.
  bindSideGesture(promptId: string = crypto.randomUUID()): { promptId: string; ticket: Promise<string | undefined> } {
    return { promptId, ticket: reservePromptGesture(promptId) };
  }
  /// Reply in place to another agent's message (conversation/IncomingMessageCard.tsx): `text`
  /// goes to the chat that sent it as this chat's cmux agent message in the same thread, as
  /// `cmux agent message --reply-to` sends one. `_acpmux/app_reply` names this chat, the sending
  /// chat (its bare id), the message and its thread; acpmux checks that this chat got that message
  /// from that chat (server/app_reply.rs) and signs it with this chat's own name, and the app sends
  /// it as this chat on its own daemon connection (CmuxNextAgentPane AgentPaneAgentReply.swift).
  /// The daemon stores it under its own id and delivers it with its `Reply with` line, so
  /// `--reply-to`, unsend and the inbox know it. `replyId` is its idempotency key in the store
  /// (each Send is a new one). Resolves once the daemon stored it; rejects with the refusal.
  async reply(message: Pick<IncomingMessage, "sessionId" | "msgId" | "threadId">, text: string): Promise<void> {
    const from = this.selectedSessionId;
    // `cmux agent message` names its sender `acp:<id>`; acpmux's chat id is the bare one.
    const to = message.sessionId?.replace(/^acp:/, "");
    const body = text.trim();
    if (!from || !to || to === from || !message.msgId || !body) throw new Error(translate("message.replyFailed"));
    await this.request("_acpmux/app_reply", {
      sessionId: from,
      to,
      replyTo: message.msgId,
      threadId: message.threadId ?? message.msgId,
      text: body,
      replyId: `m-${crypto.randomUUID()}`,
    });
  }
  /// The session an agent link or a `HOST/NAME` names (acpmux `_acpmux/resolve`, hub/locate.rs):
  /// only sessions this daemon lists, its own and its peers', resolve; any other rejects.
  async resolveSession(query: string): Promise<unknown> {
    const value = query.trim();
    if (!value) throw new Error(translate("error.notOpen"));
    return this.request("_acpmux/resolve", { query: value }, 10_000);
  }
  /// A thread of the chat's inbox (acpmux `_acpmux/inbox_thread`), oldest first, for an inbox
  /// notice's line the person opened (conversation/InboxNoticeCard.tsx). It marks nothing read: the
  /// person reading it is not the agent.
  async inboxThread(threadId: string): Promise<InboxMessage[]> {
    const sessionId = this.selectedSessionId;
    if (!sessionId || !threadId) throw new Error(translate("error.notOpen"));
    const reply = (await this.request("_acpmux/inbox_thread", { sessionId, threadId }, 15_000)) as {
      messages?: unknown;
    } | null;
    return inboxMessages(Array.isArray(reply?.messages) ? reply.messages : []).reverse();
  }
  /// The chat's inbox threads (acpmux `_acpmux/inbox_threads`), as acpmux sent them, for the held
  /// surge's panel (SurgeHoldRow.tsx). A reply that carries the surge's snapshot is as new as every
  /// event the page has heard, so it takes the row's place until a later event moves it.
  async inboxThreads(): Promise<unknown> {
    const sessionId = this.selectedSessionId;
    if (!sessionId) throw new Error(translate("error.notOpen"));
    const reply = (await this.request("_acpmux/inbox_threads", { sessionId }, 15_000)) as {
      surge?: unknown;
    } | null;
    const counts = surgeCounts(reply?.surge);
    if (counts && this.selectedSessionId === sessionId) {
      this.surge = newerSurge(this.surge, { ...counts, seq: this.lastSeq });
      this.emit();
    }
    return reply;
  }
  /// An offer the reducer draws: offers of one group share one card, in the order they came.
  private addOffer(offer: AcpmuxSessionOffer, at: number): void {
    const id = offer.groupId ? `offers-${offer.groupId}` : `offer-${offer.offerId}`;
    const row = this.rows.get(id);
    if (!row) {
      this.endAssistantSegment();
      this.streamingActivity = undefined;
    }
    const offers = [...(row?.offers ?? []).filter((item) => item.offerId !== offer.offerId), offer];
    this.offerRows.set(offer.offerId, id);
    this.rows.set(id, {
      id,
      version: (row?.version ?? 0) + 1,
      at: row?.at ?? at,
      kind: "sessionOffer",
      offers,
    });
  }
  /// A `session_offer_decision`: the offer's task is started, dismissed or done here.
  private answerOffer(msg: any): void {
    const offerId = String(msg.offerId ?? "");
    const id = this.offerRows.get(offerId);
    const row = id ? this.rows.get(id) : undefined;
    const outcome = ["accepted", "dismissed", "here"].includes(msg.outcome) ? msg.outcome : undefined;
    if (!id || !row?.offers || !outcome) return;
    const child = typeof msg.childSessionId === "string" ? { childSessionId: msg.childSessionId } : {};
    const offers = row.offers.map((offer) =>
      offer.offerId === offerId ? this.liveOffer({ ...offer, outcome, ...child }) : offer,
    );
    this.rows.set(id, { ...row, version: row.version + 1, offers });
    this.watchOfferChildren();
  }
  /// A started offer with its chat's status and latest tool call, as its row shows them.
  private liveOffer(offer: AcpmuxSessionOffer): AcpmuxSessionOffer {
    const { childStatus: _status, activity: _activity, ...rest } = offer;
    const child = rest.outcome === "accepted" ? rest.childSessionId : undefined;
    if (!child) return rest;
    const status = this.sessions.find((session) => session.sessionId === child)?.status;
    const activity = this.offerChildren.activity(child);
    return {
      ...rest,
      ...(typeof status === "string" ? { childStatus: status } : {}),
      ...(activity ? { activity } : {}),
    };
  }
  /// The chats started from the shown chat's offers.
  private offerChildIds(): string[] {
    return [...new Set(this.offerRows.values())].flatMap(
      (id) => this.rows.get(id)?.offers?.flatMap((offer) => (offer.childSessionId ? [offer.childSessionId] : [])) ?? [],
    );
  }
  /// A chat the shown chat's agent started, while started session cards draw (started/startedSessions.ts).
  private isStartedChild(session: Session): boolean {
    return !!this.selectedSessionId && session.spawnedBy === this.selectedSessionId && startedCardsShown();
  }
  /// Attaches to the started chats that run, for their rows' subtitles (offer/offerChildren.ts).
  private watchOfferChildren(): void {
    this.offerChildren.want(
      this.offerChildIds().map((child) => ({
        child,
        status: this.sessions.find((session) => session.sessionId === child)?.status,
      })),
    );
  }
  /// Chat `child`, started from an offer here, changed: its row redraws.
  private childChanged(child: string): void {
    for (const id of new Set(this.offerRows.values())) {
      const row = this.rows.get(id);
      if (!row?.offers?.some((offer) => offer.childSessionId === child)) continue;
      this.rows.set(id, {
        ...row,
        version: row.version + 1,
        offers: row.offers.map((offer) => this.liveOffer(offer)),
      });
    }
    this.watchOfferChildren();
    this.emitInFrame("offer child");
  }
  /// This Mac's acpmux health row for harness `id` (`_acpmux/harness/health`, cx-ny85), or
  /// undefined: `refresh` checks again; `rescan` has acpmux look for harnesses first (after an
  /// install from the Harnesses page).
  async harnessHealth(id: string, options: { refresh?: boolean; rescan?: boolean } = {}): Promise<unknown> {
    const rows = await this.harnessHealthRows(options);
    return rows.find((row) => (row as { id?: unknown } | null)?.id === id);
  }
  /// Every harness's health row from this Mac's acpmux (`_acpmux/harness/health`): its last check
  /// unless `refresh`; the model picker's rail reads which ones are signed out (cx-ae9eb).
  async harnessHealthRows(options: { refresh?: boolean; rescan?: boolean } = {}): Promise<unknown[]> {
    const reply = await this.request("_acpmux/harness/health", {
      ...(options.refresh ? { refresh: true } : {}),
      ...(options.rescan ? { rescan: true } : {}),
    });
    return Array.isArray(reply?.harnesses) ? reply.harnesses : [];
  }
  /// This Mac's acpmux forum rules (`_acpmux/forum/rules`, hq#2570): the current rule per key.
  async forumRules(): Promise<unknown> {
    return this.request("_acpmux/forum/rules", {});
  }
  /// Auth for this exact chat or a prospective New Tab target; the daemon owns freshness and
  /// returns unknown when no current credential evidence exists. Never use cached harness health.
  /// Whether this acpmux runs an agent's own login on its machine (`agent_login` in `initialize`'s
  /// `_meta.acpmux.features`, or `agent-login-v1` in its capabilities): a Cloud chat's sign-in card.
  get supportsAgentLogin(): boolean {
    return AGENT_LOGIN_CAPABILITIES.some((id) => this.capabilities?.has(id) || this.features.has(id));
  }
  /// Whether a new chat with no session yet signs its agent in on its machine (`agent_login_machine`
  /// in `initialize`'s features): the failed start's sign-in card (hq#11225).
  get supportsMachineLogin(): boolean {
    return this.features.has(AGENT_LOGIN_MACHINE_FEATURE);
  }
  /// Whether this acpmux serves the prompt coach (`prompt-coach-v1` in its capabilities).
  get supportsPromptCoach(): boolean {
    return this.capabilities?.has(PROMPT_COACH_CAPABILITY) === true || this.features.has(PROMPT_COACH_CAPABILITY);
  }
  /// Whether this acpmux serves the memory inbox (`memory-inbox-v1` in its capabilities).
  get supportsMemoryInbox(): boolean {
    return this.capabilities?.has(MEMORY_INBOX_CAPABILITY) === true || this.features.has(MEMORY_INBOX_CAPABILITY);
  }
  /// Starts `agent`'s own login on chat `sessionId`'s machine (`_acpmux/agent_login/start`; acpmux
  /// forwards a call that names a chat to the machine it lives on): the page to open, Codex's
  /// device code, and whether the page gives a code to paste back (Claude). With no `sessionId` (a
  /// new chat's, ``supportsMachineLogin``) the step runs on the chat's machine itself.
  agentLoginStart(agent: string, sessionId: string | undefined): Promise<unknown> {
    return this.request("_acpmux/agent_login/start", { agent, ...(sessionId ? { sessionId } : {}) });
  }
  /// Finishes login `loginId` (`_acpmux/agent_login/finish`) with Claude's pasted `code`, or waits
  /// for Codex's approval; acpmux restarts chat `sessionId`'s agent signed in. The wire log keeps
  /// no code (wire.ts).
  agentLoginFinish(loginId: string, sessionId: string | undefined, code?: string): Promise<unknown> {
    return this.request("_acpmux/agent_login/finish", {
      loginId,
      ...(sessionId ? { sessionId } : {}),
      ...(code ? { code } : {}),
    });
  }
  /// Saves an API key for `agent` on the machine (`_acpmux/agent_login/api_key`) and restarts chat
  /// `sessionId`'s agent on it. The wire log keeps no key (wire.ts).
  agentLoginApiKey(agent: string, sessionId: string | undefined, key: string): Promise<unknown> {
    return this.request("_acpmux/agent_login/api_key", { agent, key, ...(sessionId ? { sessionId } : {}) });
  }
  /// Stops login `loginId` on chat `sessionId`'s machine (`_acpmux/agent_login/cancel`).
  agentLoginCancel(loginId: string, sessionId: string | undefined): Promise<unknown> {
    return this.request("_acpmux/agent_login/cancel", { loginId, ...(sessionId ? { sessionId } : {}) });
  }
  async sessionAuth(query: SessionAuthQuery, refresh = false): Promise<unknown> {
    if (!this.features.has("sessionAuth")) return UNKNOWN_AUTH;
    try {
      return await this.request("_acpmux/session/auth", {
        ...query,
        ...(refresh ? { refresh: true } : {}),
      });
    } catch (error) {
      // The pane's host refusing to relay the check (its allowlist, AcpmuxPaneMethods) means no
      // answer, the same as a daemon without `sessionAuth`: unknown, never a sign-in prompt.
      // `warnIfNotAllowlisted` already said so in the console.
      if (error instanceof AcpmuxRpcError && refusedByHost(error)) return UNKNOWN_AUTH;
      throw error;
    }
  }
  /// The routes acpmux has (`_acpmux/route/list`) with `sessionId`'s active one: the composer's
  /// Account menu. Each route says whether it `serves` the session's harness family.
  async routes(sessionId: string): Promise<unknown> {
    return this.request("_acpmux/route/list", { sessionId });
  }
  /// Binds chat `sessionId` to route `routeId` (null: back to its default) through
  /// `_acpmux/chat/route.set`. acpmux restarts the harness on it and resumes the same agent
  /// session, now when idle, else once the running turn ends.
  async setChatRoute(sessionId: string, routeId: string | null): Promise<unknown> {
    return this.request("_acpmux/chat/route.set", { sessionId, routeId, when: "after-turn" });
  }
  /// Changes a waiting prompt (`_acpmux/queue_edit`): `update` its text, `move` it to `index`
  /// (0 runs next), `send_now` or `interrupt`. `ok` is false when it no longer waits.
  async editQueued(promptId: string, edit: QueueEdit): Promise<{ ok: boolean }> {
    if (!this.actingSessionId) return { ok: false };
    return this.request("_acpmux/queue_edit", {
      sessionId: this.actingSessionId,
      promptId,
      ...edit,
    });
  }
  /// Answers a permission: `optionId` picks an option (absent cancels the request), and
  /// `answers` carries a question's harness-shaped answers (question/model.ts `reply`). An option
  /// pick, a question's answer too, first takes a gesture ticket for this prompt, option, answers
  /// and annotations (`transport.gesture`): the host signs an allow or an answer for another
  /// machine's agent daemon only for that exact pick (cx-0q7o).
  async permission(
    permissionId: string,
    optionId?: string,
    answers?: Record<string, unknown>,
    /// Another chat's ask (the Needs you list); the shown chat's by default.
    session?: string,
    /// Claude Code's AskUserQuestion annotations beside `answers` (question/model.ts `reply`).
    annotations?: Record<string, unknown>,
  ): Promise<void> {
    const sessionId = session ?? this.actingSessionId;
    // Nothing was sent, so the answer is refused: a card that waits on it lets the person answer again.
    // l10n-allow: refuses the card's answer so it stays answerable; never shown.
    if (!sessionId) throw new Error("no chat to answer in");
    const ticket =
      optionId === undefined
        ? undefined
        : await postNative<{ ticket?: string }>("transport.gesture", {
            intent: {
              method: "_acpmux/permission_respond",
              params: {
                sessionId,
                permissionId,
                optionId,
                ...(answers === undefined ? {} : { answers }),
                ...(annotations === undefined ? {} : { annotations }),
              },
            },
          }).then(
            (reply) => reply?.ticket,
            () => undefined,
          );
    await this.typed("_acpmux/permission_respond", {
      sessionId,
      permissionId,
      ...(optionId === undefined ? {} : { optionId }),
      ...(answers === undefined ? {} : { answers }),
      ...(annotations === undefined ? {} : { annotations }),
      ...gestureMeta(ticket),
    });
  }
  /// Builds a plan the chat's plan approval asks about (`_acpmux/plan/build`): `here` approves it
  /// in this chat; `worktree` and `compare` start it in new worktrees as sub-sessions (one, or one
  /// per harness) and answer the ask so this chat stays free. Takes a gesture ticket for that
  /// exact build, as an answer does.
  async planBuild(permissionId: string, target: PlanBuildTarget, session?: string): Promise<PlanBuildReply> {
    const sessionId = session ?? this.actingSessionId;
    // l10n-allow: refuses the card's answer so it stays answerable; never shown.
    if (!sessionId) throw new Error("no chat to build in");
    const params = { sessionId, permissionId, target };
    const ticket = await postNative<{ ticket?: string }>("transport.gesture", {
      intent: { method: "_acpmux/plan/build", params },
    }).then(
      (reply) => reply?.ticket,
      () => undefined,
    );
    return (await this.request("_acpmux/plan/build", { ...params, ...gestureMeta(ticket) })) as PlanBuildReply;
  }
  /// A plan build's runs side by side (`_acpmux/plan/compare`): each one's state and diff.
  async planCompare(buildId: string, session?: string): Promise<PlanCompareReply> {
    const sessionId = session ?? this.actingSessionId;
    // l10n-allow: a refusal the compare card shows as its error; never a label.
    if (!sessionId) throw new Error("no chat to compare in");
    return (await this.request("_acpmux/plan/compare", { sessionId, buildId })) as PlanCompareReply;
  }
  /// Keeps one run of a plan build (`_acpmux/plan/keep`): its branch stays, the others are archived.
  async planKeep(buildId: string, keep: string, session?: string): Promise<PlanCompareReply> {
    const sessionId = session ?? this.actingSessionId;
    // l10n-allow: a refusal the compare card shows as its error; never a label.
    if (!sessionId) throw new Error("no chat to keep a build in");
    return (await this.request("_acpmux/plan/keep", { sessionId, buildId, keep })) as PlanCompareReply;
  }
  /// Answers a secret card: `value` provides it (acpmux keeps it in memory and gives the agent a
  /// one-use ref), none declines. The wire log never holds the value (wire.ts).
  async secret(secretId: string, value?: string): Promise<void> {
    const sessionId = this.actingSessionId;
    if (!sessionId) return;
    try {
      await this.request("_acpmux/secret_submit", {
        sessionId,
        secretId,
        ...(value ? { value } : {}),
      });
    } catch (error) {
      // A card acpmux no longer has never gets its answer: close it. Any other refusal keeps it.
      const message = error instanceof Error ? error.message : "";
      if (!SECRET_GONE.some((gone) => message.includes(gone))) throw error;
      if (this.pendingSecret?.secretId === secretId) this.pendingSecret = undefined;
      this.emit();
    }
  }
  async permissionGroup(groupId: string, revision: number, decision: PermissionDecision): Promise<void> {
    // During a switch's hold the card drawn is the chat before's, while the group client already
    // reads the next chat: refuse here, so the next chat's permission state gets no error.
    if (this.snapshotHold && this.shownSessionId !== this.selectedSessionId)
      throw new Error(translate("permission.error.selectionChanged"));
    await this.permissions.respond(groupId, revision, decision);
  }
  /// Detaches a switch has sent and acpmux has not answered, by chat. A chat left twice in a row
  /// (A, B, A, B before the first detach answers) has its detaches chained: the entry settles only
  /// when every detach of that chat sent so far has answered, so an attach that waits on it is
  /// never answered before one of them. An entry lives only until that (a reply, a refusal, or the
  /// socket closing rejects it), so the map holds at most the chats left within one round trip.
  private detaching = new Map<string, Promise<void>>();
  private detachInBackground(sessionId: string): void {
    const earlier = this.detaching.get(sessionId);
    const reply = this.typed("_acpmux/detach", { sessionId }).then(
      () => undefined,
      () => undefined,
    );
    const sent: Promise<void> = Promise.all([earlier, reply]).then(() => {
      if (this.detaching.get(sessionId) === sent) this.detaching.delete(sessionId);
    });
    this.detaching.set(sessionId, sent);
  }
  /// `adopting`: the spare page's open of its tab's chat (`adoptSession`). A chat its list lacks that
  /// fails to attach keeps the tail it drew on screen, for `adoptSession` to say why under it or drop.
  /// Shows and attaches `sessionId`: the chat once its attach is in, undefined when a selection of
  /// another chat won. A newer selection of this same chat (its store sub fell and opened it again as
  /// v1, `chatRows.fell`; a pick of it again) decides for this one too: its outcome is this one's,
  /// never undefined while that open attached the chat (issue 44964: a New Tab's first send read the
  /// superseded open as "cmux did not start a session" with the chat on screen).
  select(sessionId: string, adopting = false): Promise<string | undefined> {
    const opening = this.selectOnce(sessionId, adopting);
    const mine: { sessionId: string; result: Promise<string | undefined> } = { sessionId, result: opening };
    const sameChatAfter = () => {
      const newer = this.latestSelect;
      return newer !== mine && newer?.sessionId === sessionId ? newer.result : undefined;
    };
    mine.result = opening.then(
      (selected) => selected ?? sameChatAfter(),
      (error: unknown) => {
        const after = sameChatAfter();
        if (after) return after;
        throw error;
      },
    );
    this.latestSelect = mine;
    return mine.result;
  }
  /// The newest `select`, read by an older one of the same chat whose generation it moved.
  private latestSelect?: { sessionId: string; result: Promise<string | undefined> };

  private async selectOnce(sessionId: string, adopting: boolean): Promise<string | undefined> {
    this.pendingPeerTrust = undefined;
    this.refusedPeerTrust = undefined;
    const previousSessionId = this.selectedSessionId;
    // The chat is on screen already (picked again, or listed again after it left the list): with no
    // tail of this page's own, that frame stays until its attach is in, which keeps its rows
    // (`shownRowsToKeep`). The host's tail or the Mac's copy may hold fewer rows than are shown,
    // which would leave and come back.
    const onScreen = this.drawn?.sessionId === sessionId && this.drawn.rows.length > 0;
    // Refresh the loaded transcript, not its bounded 400-record cache. Capture before changing
    // the selection generation or resetting events so older visible replies survive a slow attach.
    const fullRefreshTail = onScreen && previousSessionId === sessionId ? this.currentTail(true) : undefined;
    // The chat being left is kept for its own next open, while it is still the selected one.
    this.rememberCurrentTail();
    // The tail of a chat that left the list while drawn (`selectFallbackSession`), taken once.
    const leftTail = this.leftTail?.sessionId === sessionId ? this.leftTail.tail : undefined;
    this.leftTail = undefined;
    const generation = ++this.selectionGeneration;
    if (this.purgedSessionId !== sessionId) this.purgedSessionId = undefined;
    // What the pane shows (the chat before, a new chat's hero) stays drawn until this chat's attach page is in.
    let hold = this.holdSnapshots(SWITCH_HOLD_MS);
    this.selectedSessionId = sessionId;
    this.missingSession = undefined;
    this.missingReason = undefined;
    this.missingAmbiguous = false;
    // A hidden pane does not see the chat it opens (the tab's missing chat came back while its
    // workspace was in the background): it stays unread until the page shows (`showChanged`). Nor
    // does a reader who stepped away: a chat reopened on its own (`reopenMissing`, a started chat)
    // stays unread until their hand is back (`attentionChanged`). A pick by hand in this page came
    // with its click or key, so the reader is here for it.
    if (readerHere()) this.markSeen(sessionId);
    this.resetSessionState("select");
    // A chat this page read already draws from what that visit left, on the frame the switch lands;
    // its attach lays what acpmux holds now over that (Leo: "instant if cached").
    // Listed again while held also prefers its full loaded tail, including older pages.
    // A chat left on the store draws the window it kept instead, where its v1 tail would be.
    const keptWindow = this.chatRows.drawKept(sessionId, this.capabilities);
    const tailToDraw = fullRefreshTail ?? (onScreen ? leftTail : undefined);
    let keptThrough = keptWindow ? 0 : this.drawKeptTail(sessionId, tailToDraw);
    if (keptThrough === 0 && !onScreen && !keptWindow) {
      // A chat this page never read, which another tab did: the host's tail draws it here too. It
      // costs one in-process round trip, where the attach it stands in for is a daemon one. A
      // read-ahead already out for it (a hover just before the press) is waited on as briefly.
      const ahead = this.readingAhead.get(sessionId);
      await Promise.all([
        readHostTail(sessionId).catch(() => undefined),
        ahead
          ? Promise.race([ahead, new Promise<void>((resolve) => setTimeout(resolve, READ_AHEAD_WAIT_MS))])
          : undefined,
      ]);
      if (generation === this.selectionGeneration && this.selectedSessionId === sessionId)
        keptThrough = this.drawKeptTail(sessionId);
      // A peer chat no tab read: the Mac's own copy of it, so a machine that is paused or offline
      // still opens on its history (peerCopy.ts).
      if (keptThrough === 0) keptThrough = await this.drawPeerCopy(sessionId, generation);
      if (generation === this.selectionGeneration) this.seedListedSummary();
    }
    if (keptThrough > 0 || keptWindow) {
      this.drewKeptTail = true;
      this.emit("selected");
      this.releaseSnapshots(hold);
    }
    let mine = this.copyAttaches;
    // Once what the kept draw drew is on screen, the switch is asked, and the v1 attach (the hold or
    // the plain one) goes after its answer. With the switch off nothing waits.
    const onStore = this.chatRows.asks(this.capabilities) && (await this.chatRows.choose(sessionId, this.capabilities));
    if (!onStore && generation === this.selectionGeneration) {
      this.chatRows.close();
      // A kept window whose chat fell to v1 stays until the v1 attach's page replaces it.
      if (keptWindow) hold = this.holdSnapshots(SWITCH_HOLD_MS);
    } else if (onStore && !this.chatRows.view(sessionId)) {
      // Its first window ends the hold, not the attach (`chatRows`, `rows`).
      this.storeHold = hold;
      hold = 0;
    }
    try {
      // The chat being left is detached alongside the attach, not before it: acpmux keeps one
      // subscription per chat (server/view.rs), so a detach of another chat never touches this
      // attach, and awaiting it cost every switch a daemon round trip. Only a detach of this same
      // chat (a switch away and straight back) is waited on, since acpmux runs each request on its
      // own task and a detach answered after the attach would drop the new subscription. A refused
      // detach (acpmux no longer resolves the chat) never stops the chat being opened.
      if (previousSessionId && previousSessionId !== sessionId) this.detachInBackground(previousSessionId);
      const detaching = this.detaching.get(sessionId);
      if (detaching) await detaching;
      else if (previousSessionId === sessionId)
        await this.typed("_acpmux/detach", { sessionId }).catch(() => undefined);
      mine = this.copyAttaches;
      await this.attach(sessionId, generation, keptThrough);
      // A reconnect's attach took the chat over meanwhile: its outcome decides.
      if (mine !== this.copyAttaches) return sessionId;
    } catch (error) {
      // A reconnect's attach took the chat over meanwhile: its outcome decides.
      if (mine !== this.copyAttaches) return sessionId;
      // A peer chat whose machine is down keeps what it drew, marked as the Mac's copy.
      if (await this.keepPeerCopy(sessionId, generation, error)) return sessionId;
      // The chat could not be read: a tail drawn from this page's own memory must not stay on
      // screen as if it were the chat, so the pane drops it and says it could not read the chat.
      // An adopted chat the list lacks (its machine still connecting) keeps it: `adoptSession` reads
      // the list and draws it under why the chat is not here, with no empty frame between.
      const listed = this.sessions.some((session) => session.sessionId === sessionId);
      if (keptThrough > 0 && generation === this.selectionGeneration && this.selectedSessionId === sessionId) {
        if (!adopting || listed) this.dropDrawnTail(sessionId, listed);
      }
      throw error;
    } finally {
      this.releaseSnapshots(hold);
    }
    const selected =
      generation === this.selectionGeneration && this.selectedSessionId === sessionId ? sessionId : undefined;
    if (selected && this.summary?.sessionId !== selected) {
      // A daemon may answer an attach with events but no session detail. Treat that as a failed
      // selection and leave the client unselected, so a recovered New Tab cannot send into the
      // malformed target through ensureSession's selected-session fast path.
      this.leave();
      // l10n-allow: a host protocol error for the attach's caller; never shown.
      throw new Error("chat attach did not return a matching session summary");
    }
    return selected;
  }

  /// While a chat is opened (a connect or reconnect, a switch, a new chat's first send, a fallback
  /// after the chat went away), the client draws no snapshot until the chat's attach page is in:
  /// the pane keeps what it showed, then draws the chat whole, never the emptied state in between
  /// (the New chat screen or a blank transcript, no composer, no access chip, no permission state
  /// for the attach's round trip; Leo 2026-10-19, test/agent-pane-switch-frames.test.ts). A slow
  /// open draws what it has after its limit anyway. One hold at a time: a newer one replaces it.
  private snapshotHold?: {
    key: number;
    timer: ReturnType<typeof setTimeout>;
    connection?: string;
    released: Promise<void>;
    release: () => void;
    /// Ends with the next snapshot, which it draws (`releaseSnapshotsOnEmit`).
    untilEmit?: boolean;
  };
  private holdKeys = 0;
  /// The chat the last snapshot drawn showed.
  private shownSessionId?: string;

  /// The chat a person's action (Stop, an answer, a pick, archive) is for: the one on screen. During
  /// a hold the pane still draws the chat before while `selectedSessionId` already names the next
  /// one, and an action from the drawn chat's controls must not reach the hidden one.
  private get actingSessionId(): string | undefined {
    return this.snapshotHold && this.shownSessionId !== undefined ? this.shownSessionId : this.selectedSessionId;
  }

  private holdSnapshots(limitMs: number): number {
    const key = ++this.holdKeys;
    const before = this.snapshotHold;
    if (before) clearTimeout(before.timer);
    let release = () => {};
    const released = new Promise<void>((resolve) => (release = resolve));
    // Whoever waited on the hold before waits on this one.
    if (before) void released.then(before.release);
    this.snapshotHold = {
      key,
      connection: before?.connection,
      released,
      release,
      timer: setTimeout(() => this.releaseSnapshots(key), limitMs),
    };
    return key;
  }

  /// Hold `key` ends with the next snapshot, drawing it: the state a failure's handling commits,
  /// never what was held back before it. Its limit still ends it if nothing is drawn.
  private releaseSnapshotsOnEmit(key: number): void {
    if (this.snapshotHold?.key !== key) return;
    this.snapshotHold.untilEmit = true;
  }

  /// Ends hold `key` and draws the snapshot it held back, if any.
  private releaseSnapshots(key: number): void {
    if (this.snapshotHold?.key !== key) return;
    clearTimeout(this.snapshotHold.timer);
    const { connection, release } = this.snapshotHold;
    this.snapshotHold = undefined;
    // A closed client draws nothing more (its pane has a new client).
    if (connection !== undefined && !this.closed) this.emit(connection);
    release();
  }
  /// The one route of a trust refusal (cx-nn3e): acpmux refuses `session/new`, `session/prompt`
  /// and a prewarm in a folder without a Trust answer (`trust_gate.rs`). Every caller hands its
  /// refusal here with the step to re-run after Trust; the pane shows the folder's one question.
  /// A refusal that comes before the pane set its route (an adopt while connecting) waits for it.
  get onTrustRefused(): TrustRoute | undefined {
    return this.trustRoute;
  }
  set onTrustRefused(route: TrustRoute | undefined) {
    this.trustRoute = route;
    const waiting = this.waitingTrust;
    this.waitingTrust = undefined;
    if (route && waiting && !this.closed && waiting.generation === this.selectionGeneration)
      route(waiting.refusal, waiting.again, waiting.declined);
  }
  /// Only a successful retry of this pending peer start retires its refused trust question.
  onPeerSessionStarted?: () => void;
  private trustRoute?: TrustRoute;
  private trustCancellation = 0;
  /// Cancel the retry intent without navigating away. Refusals retain their request-time
  /// generation, so replacing the UI callback cannot revive a canceled request.
  cancelTrustRefusals(): void {
    this.trustCancellation += 1;
    this.waitingTrust = undefined;
  }
  private waitingTrust?: { refusal: TrustRefusal; again?: () => void; declined?: () => void; generation: number };

  /// True when `error` is a trust refusal, which then went to the route.
  routeTrustRefusal(error: unknown, again?: () => void, declined?: () => void): boolean {
    const refusal = trustRefusal(error);
    if (!refusal) return false;
    if (this.closed) return true;
    if (this.trustRoute) this.trustRoute(refusal, again, declined);
    else this.waitingTrust = { refusal, again, declined, generation: this.selectionGeneration };
    return true;
  }
  /// `session/new` for every caller: a trust refusal goes to the one route, then rejects as before.
  private async newSession(
    params: Record<string, unknown>,
    again?: () => void,
    current: () => boolean = () => true,
    failed?: (error: unknown) => void,
    declined?: () => void,
    fenced = true,
  ): Promise<any> {
    const generation = this.selectionGeneration;
    const trustCancellation = this.trustCancellation;
    try {
      const result = await this.request("session/new", params);
      // A canceled start owns neither the next Trust question nor one-shot startup defaults. One
      // whose caller owns its cancellation (`fenced` false: a harness switch's start, which a
      // selection of the same chat moves on, issue 44964) is fenced on Trust only. A session
      // dropped here is discarded, never left running with no tab.
      if ((fenced && generation !== this.selectionGeneration) || trustCancellation !== this.trustCancellation) {
        // Only a start this request made fresh is ours to end. An adopt resumes the person's own
        // conversation, which acpmux may already have bound to another pane: never killed here.
        const adopting = Boolean((params._meta as { acpmux?: { adopt?: unknown } } | undefined)?.acpmux?.adopt);
        if (result?.sessionId && !this.closed && !adopting) this.discard(String(result.sessionId));
        return undefined;
      }
      return result;
    } catch (error) {
      const ownsRefusal =
        generation === this.selectionGeneration && current() && trustCancellation === this.trustCancellation;
      failed?.(error);
      if (ownsRefusal) this.routeTrustRefusal(error, again, declined);
      throw error;
    }
  }
  /// Reserve the chip's gesture before preparing the checkout. Trust can hold preparation;
  /// only the final launch spends the exact-parameter ticket, once.
  async fixFromLink(url: string, cwd?: string, harness?: string, model?: string): Promise<string | undefined> {
    this.cancelTrustStart?.();
    const generation = this.selectionGeneration;
    const trustCancellation = this.trustCancellation;
    const params = { url, ...(cwd ? { cwd } : {}), ...(harness ? { harness } : {}), ...(model ? { model } : {}) };
    const ticket = postNative<{ ticket?: string }>("transport.gesture", {
      intent: { method: "chat.fix_from_link", params },
    }).then(
      (reply) => reply?.ticket,
      () => undefined,
    );
    return new Promise<string>((resolve, reject) => {
      let settled = false;
      let running = false;
      const finish = (id?: string, error?: unknown) => {
        if (settled) return;
        settled = true;
        if (this.cancelTrustStart === cancel) this.cancelTrustStart = undefined;
        if (id) resolve(id);
        else reject(error ?? startCancelled());
      };
      const cancel = () => {
        if (settled) return;
        this.cancelTrustRefusals();
        finish();
      };
      const current = () =>
        !this.closed && generation === this.selectionGeneration && trustCancellation === this.trustCancellation;
      const launch = async () => {
        const proof = await ticket;
        if (!current() || settled) return cancel();
        const result = await this.request("chat.fix_from_link", { ...params, ...gestureMeta(proof) }, 120_000);
        if (!current()) return cancel();
        const sessionId = typeof result?.sessionId === "string" ? result.sessionId : undefined;
        // l10n-allow: internal transport shape failure; the user sees the host error surface.
        finish(sessionId, sessionId ? undefined : new Error("fix-from-link did not return a session"));
      };
      const run = () => {
        if (settled || running) return;
        if (!current()) return cancel();
        running = true;
        void this.request("chat.fix_from_link.prepare", params, 120_000).then(
          () => void launch().catch((error: unknown) => finish(undefined, error)),
          (error: unknown) => {
            running = false;
            if (settled) return;
            if (!current()) return cancel();
            // The daemon checks its canonical checkout root, whether auto-discovered or
            // selected through a subfolder. Retrying preparation never launches an agent.
            if (!this.routeTrustRefusal(error, run, cancel)) finish(undefined, error);
          },
        );
      };
      this.cancelTrustStart = cancel;
      run();
    });
  }

  /// A new session, in `cwd` when given; otherwise in the inherited cwd, then where acpmux defaults.
  /// `noProject` starts it in no project: the host's agent-home folder, never the inherited cwd.
  /// `model`: the model to start on (a chat on another machine starts on the one the page showed).
  /// `waitForTrust`: New Tab still owns the first prompt; keep this start pending through its Trust answer
  /// only when this connection can record one. Other origins reject so the retained draft can retry later.
  create(
    harness: string | undefined = this.host.harness,
    cwd?: string,
    peer?: string,
    noProject = false,
    model: string | undefined = this.host.model,
    waitForTrust = false,
  ): Promise<string | undefined> {
    this.cancelTrustStart?.();
    const generation = this.selectionGeneration;
    // The one-shot startup picks a successful start consumes (startSession): a start the person
    // left gives them back, so the pane's next new chat still starts on them (issue 44964).
    const picks = { cwd: this.host.cwd, harness: this.host.harness, model: this.host.model, peer: this.host.peer };
    const folders = this.newChatFolders;
    const started = (async () => {
      // The New Tab request still owns its draft, attachments and machine. Trust resumes this
      // same promise, so its sender runs once and never targets an unmounted chat composer.
      const canAnswerTrust = this.origin !== "remote" || this.extensions.includes("acp.trust.set");
      const sessionId =
        waitForTrust && canAnswerTrust
          ? await new Promise<string | undefined>((resolve, reject) => {
              let settled = false;
              let running = false;
              const finish = (id?: string, error?: unknown) => {
                if (settled) return;
                settled = true;
                if (this.cancelTrustStart === cancel) this.cancelTrustStart = undefined;
                if (error) reject(error);
                else resolve(id);
              };
              const cancel = () => {
                if (settled) return;
                // The request can still reply after this promise settles. Fence its refusal
                // before a newer start installs the retry it would otherwise overwrite.
                this.cancelTrustRefusals();
                finish();
              };
              this.cancelTrustStart = cancel;
              const run = () => {
                if (this.closed || generation !== this.selectionGeneration) return cancel();
                if (settled || running) return;
                running = true;
                void this.startSession(harness, cwd, peer, run, noProject, model, () =>
                  finish(undefined, startCancelled()),
                ).then(
                  (id) => finish(id),
                  (error: unknown) => {
                    running = false;
                    if (!isTrustRefusal(error)) finish(undefined, error);
                  },
                );
              };
              run();
            })
          : await this.startSession(
              harness,
              cwd,
              peer,
              () => void this.create(harness, cwd, peer, noProject, model).catch(() => undefined),
              noProject,
              model,
            );
      // A user who opened another chat while session/new was out owns that selection.
      if (this.closed || generation !== this.selectionGeneration) {
        if (sessionId && !this.closed) {
          this.discard(sessionId);
          this.host = {
            ...this.host,
            cwd: this.host.cwd ?? picks.cwd,
            harness: this.host.harness ?? picks.harness,
            model: this.host.model ?? picks.model,
            peer: this.host.peer ?? picks.peer,
          };
          this.newChatFolders ??= folders;
        }
        return undefined;
      }
      if (sessionId) this.startedChat = { sessionId, visit: generation };
      return sessionId ? this.select(sessionId) : undefined;
    })();
    const tracked = started.finally(() => {
      if (this.creating === tracked) this.creating = undefined;
    });
    // A rejection is the caller's to handle; the tracked copy only orders sends behind it.
    tracked.catch(() => undefined);
    this.creating = tracked;
    return started;
  }
  /// The folders the next new chat sees beside its own (the composer's Add folder…, extraFolders.ts),
  /// and the machine they are on: sent in its `session/new` as `additionalDirectories` only when it
  /// starts on that machine (another machine's paths mean nothing there), then dropped once it started.
  private newChatFolders?: ExtraFolderDraft;
  setNewChatFolders(draft: ExtraFolderDraft | undefined): void {
    this.newChatFolders = draft?.folders.length ? draft : undefined;
  }
  /// `session/new` without showing it: a harness switch starts the session behind the pane's
  /// new chat and shows it once it is ready (harnessSwitch.ts).
  /// `again` re-runs the caller's step after a Trust answer (the trust route).
  async startSession(
    harness?: string,
    cwd?: string,
    peer?: string,
    again?: () => void,
    noProject = false,
    model?: string,
    declined?: () => void,
  ): Promise<string | undefined> {
    const startHost = newSessionHost(this.host, cwd, peer, noProject);
    const folders = this.newChatFolders;
    const onMachine = folders && folders.machine === (startHost.peer || "local") ? folders.folders : undefined;
    const pending = { peer: startHost.peer, generation: this.selectionGeneration };
    this.pendingPeerTrust = pending;
    this.refusedPeerTrust = undefined;
    this.waitingTrust = undefined;
    this.emit();
    const result = await this.newSession(
      newSessionParams(startHost, harness, noProject, model, extraFoldersParam(onMachine, startHost.cwd)),
      again,
      () => this.pendingPeerTrust === pending && (!pending.peer || !this.selectedSessionId),
      (error) => {
        if (this.pendingPeerTrust !== pending) return;
        this.pendingPeerTrust = undefined;
        if (!this.selectedSessionId && !this.closed && trustRefusal(error))
          this.refusedPeerTrust = { peer: pending.peer, generation: pending.generation };
        this.emit();
      },
      declined,
      // A local start's caller fences it (`create`, HarnessSwitch); a peer start is fenced below.
      Boolean(pending.peer),
    );
    // A deferred local harness switch intentionally leaves the displayed chat at first Send;
    // HarnessSwitch owns that start's cancellation. Only peer starts use this route fence.
    if (
      this.closed ||
      (pending.peer && (this.pendingPeerTrust !== pending || pending.generation !== this.selectionGeneration))
    ) {
      if (result?.sessionId && !this.closed) this.discard(String(result.sessionId));
      return undefined;
    }
    if (
      result?.sessionId &&
      pending.peer &&
      !this.selectedSessionId &&
      this.pendingPeerTrust === pending &&
      pending.generation === this.selectionGeneration &&
      !this.closed
    ) {
      this.waitingTrust = undefined;
      this.onPeerSessionStarted?.();
    }
    // The folders were this start's (a failed one keeps them for its retry).
    if (result?.sessionId && onMachine && this.newChatFolders === folders) this.newChatFolders = undefined;
    // Startup picks handed to this new-chat page are one-shot defaults: consume them only after
    // session/new succeeds, so a failed start can retry with the same picks. The inherited cwd
    // keeps its existing first-chat behavior for local starts. A peer's explicit folder is
    // remote, so it must leave with the startup peer before a later local chat can inherit it.
    if (result?.sessionId) {
      this.host = {
        ...this.host,
        ...(cwd && !peer && !this.host.peer ? {} : { cwd: undefined }),
        harness: undefined,
        model: undefined,
        peer: undefined,
      };
    }
    return result?.sessionId ? String(result.sessionId) : undefined;
  }
  /// Fences delayed Trust answers/replays when selection changes before the next snapshot paints.
  get trustGeneration(): number {
    return this.selectionGeneration;
  }
  /// The shown session, for a harness switch: whether it has nothing in it yet (a pick back to
  /// its harness reuses it), its harness, its mode and options (a pick it has is not sent), and its
  /// folder when it runs on this machine (the new chat starts there; a cloud or peer session's folder
  /// is not one acpmux can start in here).
  shownSession(): ReturnType<SwitchPort["shown"]> {
    const sessionId = this.selectedSessionId;
    if (!sessionId) return undefined;
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const turns = Number(summary?.turnCount ?? 0);
    const local = hostKind(summary?.hostKind) !== "cloud" && !text(summary?.host);
    return {
      sessionId,
      harness: typeof summary?.harness === "string" ? summary.harness : undefined,
      ...(typeof summary?.model === "string" && summary.model ? { model: summary.model } : {}),
      ...(typeof summary?.modes?.currentModeId === "string" ? { modeId: summary.modes.currentModeId } : {}),
      empty: this.rows.size === 0 && this.queue.length === 0 && turns === 0 && !this.turnOpen,
      ...(local && typeof summary?.cwd === "string" && summary.cwd ? { cwd: summary.cwd } : {}),
      ...(Array.isArray(summary?.configOptions) ? { configOptions: summary.configOptions } : {}),
    };
  }
  /// Whether `sessionId` is the chat on screen and attached, once a switch's hold has let it draw:
  /// an action that reads the drawn chat (Stop, Fork) then reaches it and never the chat before.
  async shownAndAttached(sessionId: string): Promise<boolean> {
    while (this.snapshotHold && this.shownSessionId !== this.selectedSessionId) await this.snapshotHold.released;
    return (
      this.selectedSessionId === sessionId && this.actingSessionId === sessionId && this.attachedSession() === sessionId
    );
  }
  /// The selected chat's attach has supplied a matching summary for this selection generation.
  /// A stale or malformed attach can otherwise make `select()` resolve with only its requested id.
  attachedSession(): string | undefined {
    return this.attachedGeneration === this.selectionGeneration && this.summary?.sessionId === this.selectedSessionId
      ? this.selectedSessionId
      : undefined;
  }
  /// A turn is running in the shown session.
  turnRunning(): boolean {
    return this.turnOpen || this.summaryRuns(this.summary);
  }
  /// Stops showing the selected session: a harness switch draws its new chat meanwhile. The
  /// session keeps running in acpmux; only this client's attach ends.
  leave(): void {
    const previous = this.selectedSessionId;
    const pendingPeer = this.pendingPeerTrust?.peer || this.refusedPeerTrust?.peer;
    if (!previous && !pendingPeer) return;
    if (this.purgingSessionId === previous) this.purgingSessionId = undefined;
    if (this.purgedSessionId === previous) this.purgedSessionId = undefined;
    this.pendingPeerTrust = undefined;
    this.refusedPeerTrust = undefined;
    this.selectedSessionId = undefined;
    this.selectionGeneration += 1;
    this.resetSessionState("leave");
    this.emit();
    if (previous) void this.typed("_acpmux/detach", { sessionId: previous }).catch(() => undefined);
  }
  /// Ends a session a superseded harness switch started and nobody used.
  discard(sessionId: string): void {
    if (sessionId === this.selectedSessionId) return;
    void this.request("_acpmux/kill", { sessionId, purge: true }).catch(() => undefined);
  }
  /// Reads `sessionId`'s newest page ahead of an open, so a switch to it draws from memory on the
  /// frame it lands instead of after its attach (tailCache.ts ``rememberReadAhead``). For a press
  /// that is likely next: a hover over its row, the host's `chat.prefetch`. Read-only (an
  /// `_acpmux/events` page, no attach, nothing marked seen); never awaited by a caller that draws.
  prefetch(sessionId: string): void {
    this.queueReadAhead([sessionId], true);
  }

  /// The sidebar's pointer is on `sessionId`'s row (undefined: on no chat's row), forwarded by the
  /// host's `chat.prefetch` with `hover`. Once it rests there (hoverPrefetch.ts), the chat is read
  /// ahead and its tail handed to the app host, so the tab the click opens draws it from the host's
  /// copy (`chat.tail.get`) instead of after its attach: that tab is another page.
  hoverPrefetch(sessionId: string | undefined, options: HoverOptions = {}): void {
    this.hoverReads.hover(sessionId, options);
  }
  private hoverReads = new HoverPrefetch((sessionId) => this.prefetchForHost(sessionId));
  /// Chats whose next read ahead is handed to the host (a rested hover), at most HOVER_RECENT. An
  /// entry leaves when its read ends, read or not (`pumpReadAhead`), and on close.
  private shareOnRead = new Set<string>();
  private prefetchForHost(sessionId: string): void {
    if (this.closed || sessionId === this.selectedSessionId) return;
    this.shareOnRead.delete(sessionId);
    this.shareOnRead.add(sessionId);
    while (this.shareOnRead.size > HOVER_RECENT) this.shareOnRead.delete(this.shareOnRead.keys().next().value!);
    this.queueReadAhead([sessionId], true);
    // Nothing to read: this page holds a tail of the chat it counts as current, so that one goes,
    // and the host keeps it only over an older one (`shareReadAhead`).
    if (!this.readingAhead.has(sessionId) && !this.readAheadQueue.includes(sessionId)) {
      this.shareOnRead.delete(sessionId);
      shareReadAhead(sessionId);
    }
  }

  /// Chats read ahead, by when their read went out.
  private readAheadAt = new Map<string, number>();
  /// Chats read ahead, by the row's `transcriptSeq` when their read went out: acpmux moves it only
  /// for a transcript record, so a chat whose row moved only for bookkeeping (an agent start's
  /// `agent_start_waiting` every 10 s, usage, git, process counts all move `updatedAt`) is not read
  /// again. Any other value is a change, a lower one too (a peer's chat restored to an older log).
  /// Absent for a row without one (a peer on an older acpmux): `updatedAt` decides instead.
  private readAheadSeq = new Map<string, number>();
  /// Reads out now, by chat, so a switch to one can wait on it briefly.
  private readingAhead = new Map<string, Promise<void>>();
  /// Chats waiting for a read, the next one first.
  private readAheadQueue: string[] = [];
  private readAheadTimer?: ReturnType<typeof setTimeout>;
  /// The idle read ahead came due while the page was hidden: it runs once the page shows (`showChanged`).
  private readAheadOwed = false;

  /// A chat acpmux purged: nothing of its read ahead is kept. Kept, each closed chat the read ahead
  /// had read stayed in `readAheadAt` and `readAheadSeq` for the pane's life
  /// (test/state-growth.test.ts, session-churn). A read still out drops its page (`readAhead`
  /// keeps a tail only for a listed row).
  private forgetReadAhead(sessionId: string): void {
    this.readAheadAt.delete(sessionId);
    this.readAheadSeq.delete(sessionId);
    this.shareOnRead.delete(sessionId);
    if (this.readAheadQueue.includes(sessionId))
      this.readAheadQueue = this.readAheadQueue.filter((queued) => queued !== sessionId);
  }

  /// Reads the list's most recent chats ahead once the pane is idle for `delayMs`.
  /// A hidden page reads nothing ahead: every workspace's pages read the same recent chats, so N
  /// hidden pages read each one N times for a switch only the shown page takes (Leo, 2026-11-18:
  /// "And other general perf"). Its read ahead runs when it shows. A hover or a host's prefetch
  /// (`queueReadAhead` with `first`) still reads at once.
  private scheduleReadAhead(delayMs: number): void {
    if (this.closed || this.readAheadTimer !== undefined) return;
    if (!pageShown()) {
      this.readAheadOwed = true;
      return;
    }
    this.readAheadTimer = setTimeout(() => {
      this.readAheadTimer = undefined;
      if (!pageShown()) {
        this.readAheadOwed = true;
        return;
      }
      const recent = [...this.sessions]
        .filter((session) => session.sessionId && session.sessionId !== this.selectedSessionId && !session.coldArchive)
        .sort((a, b) => Number(b.updatedAt ?? 0) - Number(a.updatedAt ?? 0))
        .slice(0, READ_AHEAD_RECENT)
        .map((session) => session.sessionId);
      this.queueReadAhead(recent, false);
    }, delayMs);
  }

  /// A chat whose log is in acpmux's cold archive: any read of its log brings it back
  /// (hub/cold_archive.rs), so only opening it reads it, never a read ahead or a hover (review of
  /// #39141: the 12 recent chats' reads undid Compress Chat on a page with no kept tails).
  private listedCold(sessionId: string): boolean {
    return Boolean(this.sessions.find((session) => session.sessionId === sessionId)?.coldArchive);
  }

  private queueReadAhead(sessionIds: string[], first: boolean): void {
    const now = Date.now();
    const wanted = sessionIds.filter((sessionId) => {
      if (!sessionId || sessionId === this.selectedSessionId || this.readingAhead.has(sessionId)) return false;
      if (this.listedCold(sessionId)) return false;
      const readAt = this.readAheadAt.get(sessionId);
      // A chat this page opened keeps the tail it read itself; one read ahead is read again only
      // when it ran on since, and not more often than READ_AHEAD_REFRESH_MS.
      if (readAt === undefined) return !keptTail(sessionId);
      if (now - readAt < READ_AHEAD_REFRESH_MS) return false;
      const listed = this.sessions.find((session) => session.sessionId === sessionId);
      // A chat whose turn runs is read again once its turn ends, not on each change in the list
      // while it streams: with dozens of busy chats that re-read 12 pages every few seconds. Its
      // kept tail is behind meanwhile; the attach a switch sends lays the turn over it. A hover
      // (`first`) still reads it.
      if (!first && listed?.status === "running" && keptTail(sessionId)) return false;
      const seq = transcriptSeq(listed);
      const seen = this.readAheadSeq.get(sessionId);
      const ranOn = seq !== undefined && seen !== undefined ? seq !== seen : Number(listed?.updatedAt ?? 0) > readAt;
      return ranOn || !keptTail(sessionId);
    });
    const rest = this.readAheadQueue.filter((sessionId) => !wanted.includes(sessionId));
    this.readAheadQueue = first ? [...wanted, ...rest] : [...rest, ...wanted];
    this.pumpReadAhead();
  }

  private pumpReadAhead(): void {
    while (!this.closed && this.readingAhead.size < READ_AHEAD_LANES && this.readAheadQueue.length > 0) {
      const sessionId = this.readAheadQueue.shift()!;
      if (sessionId === this.selectedSessionId || this.listedCold(sessionId)) continue;
      const read = this.readAhead(sessionId)
        .catch(() => undefined)
        .finally(() => {
          this.readingAhead.delete(sessionId);
          this.shareOnRead.delete(sessionId);
          this.pumpReadAhead();
        });
      this.readingAhead.set(sessionId, read);
    }
  }

  /// One read ahead: the chat's newest page, the same kinds and bound an attach reads, kept as a
  /// tail. Prepare the first partial turn's opener here, off the click path, so the cached frame
  /// already has the same turn boundaries as attach. Pending asks still come from the attach.
  private async readAhead(sessionId: string): Promise<void> {
    if (this.socket?.readyState !== WebSocket.OPEN) return;
    const connection = this.socket;
    this.readAheadAt.set(sessionId, Date.now());
    // The session and machine its row names when asked: a page read while the row changed is of
    // the session before, so it is not kept under the new one's row.
    const asked = this.sessions.find((session) => session.sessionId === sessionId);
    const askedSeq = transcriptSeq(asked);
    const result = await this.typed("_acpmux/events", {
      sessionId,
      beforeSeq: Number.MAX_SAFE_INTEGER,
      limit: KEPT_EVENTS,
      maxBytes: OPEN_PAGE_BYTES,
      // The preset approval cards as at attach: a local acpmux only (a remote one takes 8 kinds).
      kinds: [
        "transcript",
        COMMANDS_KIND,
        USAGE_KIND,
        CONFIG_KIND,
        BOOKMARKS_KIND,
        ...SECRET_KINDS,
        ...(this.localOrigin ? PRESET_APPROVAL_KINDS : []),
      ],
    });
    // The chat was opened meanwhile: its attach holds the newer read.
    if (this.closed || this.socket !== connection || sessionId === this.selectedSessionId) return;
    const page = records(result?.events);
    if (page.length === 0) return;
    const oldest = Math.min(...page.map((event) => event.seq));
    const turnOpener = await this.fetchTurnOpener(sessionId, page, result?.hasMore === true);
    // The opener read may finish after an open or a machine/generation change. It cannot publish
    // that older preparation over the newly selected chat or the new machine's journal.
    if (this.closed || this.socket !== connection || sessionId === this.selectedSessionId) return;
    const listed = this.sessions.find((session) => session.sessionId === sessionId);
    if (listed?.peer !== asked?.peer || listed?.createdAt !== asked?.createdAt) return;
    rememberReadAhead(sessionId, {
      events: page,
      summary: listed ? { ...listed } : undefined,
      turnOpener,
      historyExhausted: result?.hasMore === false,
      queue: [],
      configSeq: 0,
      usageFromSeq: result?.hasMore === true ? oldest : 0,
    });
    // Only a kept read counts as read at `askedSeq`: a failed, empty or dropped one is asked again
    // on the next change in the list, as before.
    if (askedSeq === undefined) this.readAheadSeq.delete(sessionId);
    else this.readAheadSeq.set(sessionId, askedSeq);
    // A rested hover asked for it: the tab its click opens is another page, which reads the host.
    if (this.shareOnRead.delete(sessionId)) shareReadAhead(sessionId);
  }

  /// acpmux serves `_acpmux/prewarm` to this connection: it lists the method and calls the
  /// connection local. A remote-origin connection is never asked (acpmux refuses it).
  get startsOnSend(): boolean {
    // A chat on another machine (the host's remote wire): its `session/new` starts the chat there,
    // so nothing creates one before the first send (cx-k21v).
    return this.origin === "remote";
  }
  /// New Project: only this Mac's own daemon makes a folder for its pane, and only one that has it.
  get newProjectSupported(): boolean {
    return !this.host.peer && this.localOrigin && this.extensions.includes(PROJECT_NEW_METHOD);
  }
  /// acpmux makes folder `name` (or `name-2` and on) in the person's projects folder, with an empty
  /// git repository, trusted; resolves with the folder.
  newProject(name: string): Promise<string> {
    return this.request(PROJECT_NEW_METHOD, { name }).then((reply: { cwd?: unknown } | undefined) => {
      if (typeof reply?.cwd !== "string" || !reply.cwd.startsWith("/"))
        throw new Error(translate("project.new.unavailable"));
      return reply.cwd;
    });
  }
  get prewarmSupported(): boolean {
    return !this.host.peer && this.localOrigin && this.extensions.includes(PREWARM_METHOD);
  }
  /// Hints acpmux's session pool that `harness` is likely next, in `cwd` when known. Never
  /// awaited; a refusal (the pool is off, a failed start) is ignored.
  prewarm(harness: string, cwd?: string): void {
    if (!this.prewarmSupported) return;
    const generation = this.selectionGeneration;
    const trustCancellation = this.trustCancellation;
    // A prewarm in a folder without a Trust answer asks the question early (nothing to re-run).
    void this.request(PREWARM_METHOD, cwd ? { harness, cwd } : { harness }).catch((error: unknown) => {
      if (generation === this.selectionGeneration && trustCancellation === this.trustCancellation)
        this.routeTrustRefusal(error);
    });
  }
  /// The folder a new chat's bare start goes to (`startSession` with no folder: the pane's
  /// inherited one); undefined when acpmux picks it or the chat starts on another machine.
  newChatCwd(): string | undefined {
    return this.startsOnSend ? undefined : this.host.cwd;
  }
  /// A seeded peer remains the destination until its first chat starts successfully.
  newChatPeer(): string | undefined {
    const route = this.newChatTrustRoute;
    return route ? route.peer : this.host.peer;
  }
  /// The typing prewarm of a new chat (newChatPrewarm.ts): hints acpmux's pool like `prewarm`,
  /// without a harness for acpmux's default. Silent: a folder without a Trust answer asks nothing
  /// while the person types; the chat's own start asks at Enter.
  typingPrewarm(harness: string | undefined, cwd: string): void {
    if (!this.prewarmSupported) return;
    void this.request(PREWARM_METHOD, harness ? { harness, cwd } : { cwd }).catch(() => undefined);
  }
  /// Takes a typing prewarm back (the prompt cleared, the chat left unsent): its warm agent ends.
  releasePrewarm(harness: string | undefined, cwd: string): void {
    if (!this.prewarmSupported) return;
    void this.request(PREWARM_METHOD, {
      ...(harness ? { harness } : {}),
      cwd,
      release: true,
    }).catch(() => undefined);
  }
  /// The permission mode acpmux would start a new chat on `harness` in `cwd` in (cx-wx93i),
  /// as acpmux decides it; undefined when it would set none, does not know, or predates the method.
  /// Rejects when it could not be asked (no socket, the request failed): that is no answer.
  async startMode(harness: string, cwd?: string): Promise<StartMode | undefined> {
    const ticket = fullAccessTicket();
    try {
      const answer = (await this.request("_acpmux/start_mode", cwd ? { harness, cwd } : { harness })) as {
        harness?: unknown;
        modeId?: unknown;
        name?: unknown;
        level?: unknown;
        fullAccess?: unknown;
      } | null;
      // Read before any mode check: an answer that names no mode still says full access is managed off.
      rememberFullAccess(answer?.fullAccess, ticket);
      // Full access on a harness whose modes acpmux has not seen yet (no chat of it since acpmux
      // started: a first Codex chat): acpmux names no mode, and sets the harness's full-access mode
      // once it reports its modes. The chip names that mode now, never nothing.
      if (answer?.modeId == null && answer?.level === "fullAccess") {
        const highest = highestMode(undefined, typeof answer.harness === "string" ? answer.harness : harness);
        return highest ? { modeId: highest.id, name: highest.name } : undefined;
      }
      if (typeof answer?.modeId !== "string" || !answer.modeId) return undefined;
      return {
        modeId: answer.modeId,
        ...(typeof answer.name === "string" && answer.name ? { name: answer.name } : {}),
      };
    } catch (error) {
      // acpmux refused (an unknown harness, a method it predates): it sets none there. A request
      // that never reached it, or whose socket closed, answered nothing (startMode.ts keeps what it had).
      // The pane's host refusing to relay it (`data.origin: "native"`, such as a new workspace's home
      // folder outside the roots it relays) is one of those: acpmux never saw the ask.
      // Only a daemon that predates the method (method not found) manages nothing; any other
      // refusal comes from a daemon that may still manage full access, so the mark stays.
      if (error instanceof AcpmuxRpcError && !refusedByHost(error)) {
        if (error.code === METHOD_NOT_FOUND) rememberFullAccess(undefined, ticket);
        return undefined;
      }
      throw error;
    }
  }
  /// Resumes `adopt` in this pane now (a chat whose folder was missing, after Choose Folder): the
  /// same path as an adopt on connect, so a trust refusal asks the question (the trust route).
  async resume(adopt: AcpmuxAdopt): Promise<string | undefined> {
    await this.adoptChat(adopt);
    return this.adopted;
  }
  /** The session an adopt on connect resumed, for the host to keep as the tab's session. */
  adopted?: string;
  /** The chat the tab's recorded id only named (`chatNamedBy`: its name or its harness's session
   *  id): the host keeps it as the tab's session, so the tab is rebound to acpmux's id. Not an
   *  adopt: the tab's harness and start are as they were. */
  rebound?: string;
  /** Called each time this client adopts a chat as the tab's (`adopted`) after the connect: a
   *  fork or Open Anyway from the live-chat choice, or an adopt retried after Trust. The host
   *  keeps it as the tab's session, so restoring the tab reopens it. */
  onAdopted?: (sessionId: string) => void;
  private markAdopted(sessionId: string): void {
    this.adopted = sessionId;
    this.onAdopted?.(sessionId);
  }
  /// Resumes the outside chat the host named, once. A session that didn't adopt it (an acpmux
  /// without adopt starts a fresh one) is removed, and the pane says so instead of posing as it.
  /// A socket that drops meanwhile fails the connect, so the host reconnects and adopts again
  /// (acpmux maps one chat to one session).
  private async adoptChat(adopt: AcpmuxAdopt): Promise<void> {
    this.host = { ...this.host, adopt: undefined };
    // A person who moved to another chat while this one adopted keeps it shown.
    const generation = this.selectionGeneration;
    let result: any;
    try {
      // After Trust the same chat is adopted again, unless the person moved to another chat since.
      result = await this.newSession(newSessionParams({ adopt }), () => {
        if (!this.closed && generation === this.selectionGeneration) void this.adoptChat(adopt).catch(() => undefined);
      });
    } catch (error) {
      if (this.socket?.readyState !== WebSocket.OPEN) throw error;
      // The trust route asks about the folder; this is no failure to resume.
      if (trustRefusal(error)) return;
      if (error instanceof AcpmuxRpcError && error.reason === "adopt.live" && !adopt.ifLive) {
        // The person moved to another chat while acpmux answered: nothing shows for this one.
        if (this.closed || generation !== this.selectionGeneration) return;
        const live = liveDetails((error as { details?: unknown }).details);
        if (!adopt.watch && (await this.watchLive(adopt))) return;
        if (this.closed || generation !== this.selectionGeneration) return;
        this.liveAdopt = { adopt, ...live };
        this.emit();
        return;
      }
      this.adoptFailed(errorMessage(error) || undefined);
      return;
    }
    const sessionId = result?.sessionId ? String(result.sessionId) : undefined;
    // A fork is a new conversation: its harness session is its own, not the adopted one.
    if (sessionId && (adopt.ifLive === "fork" || adoptedBy(result, adopt))) {
      if (this.closed || generation !== this.selectionGeneration) return;
      // The tab keeps it only once the pane shows it (a switch during the attach keeps the other).
      if ((await this.select(sessionId)) === sessionId) this.markAdopted(sessionId);
      return;
    }
    if (sessionId) await this.request("_acpmux/kill", { sessionId, purge: true }).catch(() => undefined);
    this.adoptFailed(translate("notice.resumeUnsupported"));
  }
  /// The chat acpmux refused to resume because another app still runs it (`adopt.live`), shown
  /// here View Only instead: its transcript at once, following that app, under the View Only
  /// banner. "there's frequently nothing wrong with showing the same session but in two different
  /// places" (Leo, 2026-10-29). It asks nothing on open: Fork It and Open Anyway show only once
  /// the person replies or takes over and acpmux refuses that as live (`takeOver`). "the fact that
  /// it's asking me to fork while im inside an existing claude code chat is bad" (Leo,
  /// 2026-10-30). False when it cannot be watched (a daemon or harness without watching): the
  /// choice shows alone. True also when the person moved to another chat (or the pane closed)
  /// meanwhile: then nothing more shows for this one.
  private async watchLive(adopt: AcpmuxAdopt): Promise<boolean> {
    const watch: AcpmuxAdopt = { harness: adopt.harness, agentSessionId: adopt.agentSessionId, watch: true };
    const generation = this.selectionGeneration;
    const moved = () => this.closed || generation !== this.selectionGeneration;
    let result: any;
    try {
      result = await this.request("session/new", newSessionParams({ adopt: watch }));
    } catch {
      return moved();
    }
    // A watch answered after the person moved on stays listed, as any chat opened and then left
    // does. It is never removed here: acpmux answers with the watch it already has for this chat,
    // which may be another pane's (the same session shown in two places).
    if (moved()) return true;
    const sessionId = result?.sessionId ? String(result.sessionId) : undefined;
    if (!sessionId) return false;
    if (!adoptedBy(result, watch)) {
      await this.request("_acpmux/kill", { sessionId, purge: true }).catch(() => undefined);
      return moved();
    }
    if ((await this.select(sessionId)) === sessionId) this.markAdopted(sessionId);
    return true;
  }
  /// Adopts the chat acpmux refused as live elsewhere anyway: `open` resumes it as it is (two
  /// processes then write one conversation), `fork` starts a new chat from it. Once; a second
  /// click while it adopts does nothing.
  async adoptLive(choice: "fork" | "open"): Promise<void> {
    const live = this.liveAdopt;
    if (!live) {
      // The same choice over a watched chat (a reply or Take Over refused as live): it forks
      // or takes that chat over; `adopted` names the chat the tab keeps.
      const sessionId = this.selectedSessionId;
      const generation = this.selectionGeneration;
      if (!sessionId || !(await this.takeOver(choice)) || choice !== "open") return;
      // Taken over while the person stayed on it: the tab keeps it.
      if (!this.closed && generation === this.selectionGeneration) this.markAdopted(sessionId);
      return;
    }
    if (choice === "fork" && !live.canFork) return;
    this.liveAdopt = undefined;
    this.emit();
    await this.adoptChat({ ...live.adopt, ifLive: choice });
  }
  /// This client's connection is gone (`close`): it shows nothing more.
  get isClosed(): boolean {
    return this.closed;
  }
  /// The shown chat `sessionId` has prompt `promptId`: its record, its queue row, or a sent row the
  /// attach drew for it (a chat opened from acpmux's view holds rows, not every record).
  showsPrompt(sessionId: string, promptId: string): boolean {
    if (this.selectedSessionId !== sessionId) return false;
    if (this.queue.some((entry) => entry.id === promptId)) return true;
    if (
      this.events.some(
        (event) => (event.kind === "user_message" || event.kind === "queued") && event.msg?.promptId === promptId,
      )
    )
      return true;
    for (const row of this.rows.values())
      if (row.kind === "user" && row.promptId === promptId && !row.pending && !row.failed) return true;
    return false;
  }
  /// A prompt an earlier connection lost before this pane heard acpmux take it (lostPrompt.ts): it
  /// shows here as its own row, on its way, until acpmux's record of it lands on that same row (the
  /// echo settles it as any send's does) or the wait gives up (`failLostPrompt`). Never a second
  /// copy: nothing when the chat already shows it, or shows another chat.
  drawLostPrompt(sessionId: string, promptId: string, input: string, attachments: ComposerAttachment[]): boolean {
    if (this.closed || this.selectedSessionId !== sessionId || this.showsPrompt(sessionId, promptId)) return false;
    const rowId = `local-${promptId}`;
    // A Not sent row the host's store drew for it meanwhile (a relaunch, this connection's restore)
    // is the same prompt: it is on its way again, so that row says so instead of a second copy.
    if (this.rows.has(rowId) && !this.restoredUnsent.delete(promptId)) return true;
    this.failedPrompts.delete(rowId);
    const at = Date.now();
    const delivery: PromptDelivery = { state: "sending", promptId, sessionId, sentAt: at - PROMPT_PENDING_AFTER_MS };
    this.deliveries.get(promptId)?.timers.forEach(clearTimeout);
    this.deliveries.set(promptId, { delivery, rowId, timers: [] });
    // Drawn as its send drew it (`sentPromptShape`): a paste is the bubble's text, never a token.
    const { inline, text, pasted } = sentPromptShape(input, attachments, { dropped: () => false });
    this.promptRowKeys.set(promptId, rowId);
    this.optimisticPromptRows.set(promptId, rowId);
    this.optimisticPromptTexts.set(promptId, text);
    this.optimisticPromptInputs.set(promptId, input);
    if (attachments.length) this.optimisticPromptAttachments.set(promptId, attachments);
    if (inline) this.optimisticPromptParts.set(promptId, inline.parts);
    this.rows.set(rowId, {
      id: rowId,
      version: 1,
      at,
      kind: "user",
      text,
      ...(pasted.length ? { pasted } : {}),
      ...(inline ? { inlineParts: inline.parts } : {}),
      ...(attachments.length ? { images: attachedImages(attachments), retryAttachments: attachments } : {}),
      pending: true,
      delivery,
    });
    this.emit();
    return true;
  }
  /// The lost prompt drawn by `drawLostPrompt` never showed in acpmux's record: its row fails with
  /// Retry, which sends it again under the same prompt id (acpmux runs a prompt id once), never a
  /// line apart from the row while the row still looks sent. False when there is no such row.
  failLostPrompt(promptId: string, error: unknown): boolean {
    const entry = this.deliveries.get(promptId);
    const row = entry ? this.rows.get(entry.rowId) : undefined;
    if (!entry || !row || entry.delivery.state !== "sending") return false;
    const input = this.optimisticPromptInputs.get(promptId) ?? row.text ?? "";
    const attachments = this.optimisticPromptAttachments.get(promptId) ?? [];
    // The mapping stays until the row settles: acpmux's record may still come (the prompt waited
    // behind the turn), and it lands on this row, which then is the sent one, never a failed copy.
    const code = (error as { code?: unknown } | null)?.code;
    this.rows.set(entry.rowId, {
      ...row,
      pending: false,
      failed: true,
      error: failedSendText(error, false, attachments),
      version: row.version + 1,
    });
    this.failedPrompts.set(entry.rowId, { input, attachments, promptId });
    this.setDelivery(promptId, {
      state: "failed",
      failedAt: Date.now(),
      hop: "connection",
      ...(typeof code === "string" ? { code } : {}),
      error: error instanceof Error ? error.message : errorMessage(error),
    });
    this.emit();
    return true;
  }
  /// Whether the host's prompt journal keeps a prompt of these blocks that this connection lost
  /// (Swift `AgentPanePromptRelay`): only on a connection to this Mac's acpmux.
  private journalsPrompts(): boolean {
    return this.localOrigin;
  }
  /// The `awaitResent` waits, with their chat: each settles false once this connection closes or
  /// the pane shows another chat.
  private resendWaits = new Map<() => void, string>();
  /// A prompt an earlier connection lost before acpmux took it (`lostPrompt.ts`), which the host
  /// sends again on this one: true once this chat shows it (its record, its queue row, or acpmux's
  /// acceptance), false when it does not within `timeoutMs`, this pane shows (or moves to) another
  /// chat, or this connection closes.
  /// `draw`: the prompt as it was sent, drawn meanwhile as its own row on its way (`drawLostPrompt`).
  awaitResent(
    sessionId: string,
    promptId: string,
    timeoutMs: number,
    draw?: { input: string; attachments: ComposerAttachment[] },
  ): Promise<boolean> {
    if (this.closed || this.selectedSessionId !== sessionId) return Promise.resolve(false);
    const shown = () => this.showsPrompt(sessionId, promptId);
    if (shown()) return Promise.resolve(true);
    if (draw) this.drawLostPrompt(sessionId, promptId, draw.input, draw.attachments);
    return new Promise((resolve) => {
      const done = (landed: boolean) => {
        clearTimeout(timer);
        if (this.promptAccepts.get(promptId) === accept) this.promptAccepts.delete(promptId);
        this.resendWaits.delete(gone);
        resolve(landed);
      };
      // acpmux took it (`_acpmux/prompt_accepted`) before its echo: the row says so now.
      const accept = () => {
        if (this.setDelivery(promptId, { state: "delivered", acceptedAt: Date.now() })) this.emit();
        done(true);
      };
      const gone = () => done(false);
      const timer = setTimeout(() => done(shown()), timeoutMs);
      this.promptAccepts.set(promptId, accept);
      this.resendWaits.set(gone, sessionId);
    });
  }
  /// Takes over the watched chat shown here (`_acpmux/watch_take_over`), so it runs the
  /// conversation itself. While the app that runs it still does, acpmux refuses (`adopt.live`) and
  /// the pane offers Open Anyway and, for Claude Code, Fork It, which call this with `ifLive`.
  /// Resolves true once the chat runs the conversation, false when it still only views it.
  async takeOver(ifLive?: "fork" | "open"): Promise<boolean> {
    const sessionId = this.selectedSessionId;
    if (!sessionId) return false;
    const live = this.liveTakeOverFor === sessionId ? this.liveTakeOver : undefined;
    if (ifLive && (!live || (ifLive === "fork" && !live.canFork))) return false;
    this.liveTakeOver = undefined;
    this.emit();
    // Fork It forks the watched conversation at once, from its own id (as Continue in New Chat
    // does): a fork taken over from a watch keeps its source only in the daemon's memory until its
    // first prompt, so a restart in between would lose it.
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const family = text(summary?.watching);
    const agentSessionId = text(summary?.agentSessionId);
    if (ifLive === "fork" && family && agentSessionId) {
      await this.adoptChat({ harness: family, agentSessionId, ifLive: "fork" });
      return true;
    }
    try {
      await this.request("_acpmux/watch_take_over", { sessionId, ...(ifLive ? { ifLive } : {}) });
      return true;
    } catch (error) {
      if (error instanceof AcpmuxRpcError && error.reason === "adopt.live" && !ifLive) {
        this.liveTakeOver = liveDetails((error as { details?: unknown }).details);
        this.liveTakeOverFor = sessionId;
        this.emit();
        return false;
      }
      console.warn("agent pane: taking over the session failed", error);
      this.transient(knownRefusalText(error) ?? translate("watch.takeOverFailed"), "error");
      return false;
    }
  }
  /// Continue in New Chat, View Only's way on (Leo 2026-10-19: viewing never blocks starting a
  /// session). A Claude Code chat forks the watched conversation into a new chat; a Codex one, which
  /// cannot be forked while another app runs it, starts a new Codex chat in its folder. The watched
  /// chat stays as it is, and the original is never written to.
  async continueWatched(): Promise<void> {
    const summary = this.summary?.sessionId === this.selectedSessionId ? this.summary : undefined;
    const family = text(summary?.watching);
    if (!summary || !family) return;
    const agentSessionId = text(summary.agentSessionId);
    if (family === "claude" && agentSessionId) {
      await this.adoptChat({ harness: "claude", agentSessionId, ifLive: "fork" });
      return;
    }
    await this.create(text(summary.harness), text(summary.cwd));
  }
  /// Where feedback on a click goes (App.tsx: the pane's toasts, paneToasts.ts). Unset (a test, a
  /// client with no pane), it is a transcript line as before.
  toastSink: ((text: string, kind?: "error") => void) | undefined;
  /// Feedback on the person's click or action that belongs to the moment, not the chat (a Stop the
  /// agent refused, a take-over that failed): a toast, never a transcript line. `kind: "error"`
  /// draws a failure as one.
  transient(text: string, kind?: "error"): void {
    // A closed client's late failure (a takeOver() that fails after a reconnect replaced it) is
    // about a pane that is gone: neither the new pane's toasts nor a line.
    if (this.closed) return;
    if (this.toastSink) this.toastSink(text, kind);
    else this.notice(text);
  }
  /// A line in the shown transcript (a pick the agent refused); its row id, for `dismissNotice`.
  notice(text: string, id = noticeId("notice")): string {
    const at = Date.now();
    this.rows.set(id, { id, version: 1, at, kind: "notice", text });
    this.emit();
    return id;
  }
  /// The recap's ×: it stays dismissed on this device, and its row goes. `key` is the recap the
  /// person pressed; the row goes only when it is that recap, not another chat's with the same seq
  /// (a press on the chat a switch still shows).
  dismissRecap(rowId: string, key: string): void {
    rememberRecapDismissed(key);
    if (this.latestRecap?.recap?.key === key) this.latestRecap = { ...this.latestRecap, recap: undefined };
    if (rowId === SINCE_DIVIDER && this.since?.recap?.key === key) {
      this.since = { sessionId: this.since.sessionId, seq: this.since.seq, turns: this.since.turns };
      this.placeSince();
      this.emit();
      return;
    }
    if (this.rows.get(rowId)?.recap?.key !== key) return;
    this.rows.delete(rowId);
    this.emit();
  }
  /// Prompt coach ids whose `coach` record this page has read: never asked for again.
  private readonly coachMade = new Set<string>();
  /// Prompt coach ids this page asked acpmux for (`_acpmux/prompt_coach`): at most once each.
  private readonly coachAsked = new Set<string>();
  /// `coach_offer` records folded in the batch being applied, by coach id, with their chat.
  private readonly coachWaiting = new Map<string, string>();
  /// A `coach_offer` was folded: decide once the batch it came in is applied, since a history page
  /// that holds its `coach` record too has it after the offer.
  private considerCoach(coachId: string, sessionId: string | undefined): void {
    if (!sessionId || this.fedMode || this.replayThrough !== undefined) return;
    if (this.coachAsked.has(coachId) || this.coachMade.has(coachId)) return;
    const first = this.coachWaiting.size === 0;
    this.coachWaiting.set(coachId, sessionId);
    if (first) queueMicrotask(() => this.askCoaches());
  }
  /// Asks acpmux to write each waiting rewrite (`_acpmux/prompt_coach`, one small-model call that
  /// logs the `coach` record): only with the setting on, for a chat whose card was not dismissed on
  /// this device, and none whose `coach` record was read meanwhile. Fire and forget: the record
  /// draws the card, `{made: false}` means nothing to do, and a failure is only logged.
  private askCoaches(): void {
    const waiting = [...this.coachWaiting];
    this.coachWaiting.clear();
    if (this.closed || this.disposed) return;
    for (const [coachId, sessionId] of waiting) {
      if (this.coachMade.has(coachId) || this.coachAsked.has(coachId)) continue;
      if (!promptCoachEnabled() || promptCoachDismissed(sessionId)) continue;
      this.coachAsked.add(coachId);
      this.typed("_acpmux/prompt_coach", { sessionId, coachId }).catch((error: unknown) =>
        console.debug("cmux: prompt coach request failed", error),
      );
    }
  }
  /// The prompt coach card's ×: the chat never draws one again on this device, and its row goes. The
  /// row goes only when it is that chat's, not a card a switch drew since.
  dismissPromptCoach(rowId: string, sessionId: string): void {
    if (!sessionId) return;
    rememberPromptCoachDismissed(sessionId);
    if (this.rows.get(rowId)?.coach?.sessionId !== sessionId) return;
    this.rows.delete(rowId);
    this.emit();
  }
  /// The chat's preset approval cards, folded from their records (conversation/presetApproval.ts).
  private readonly presetApprovals = new PresetApprovalFold();
  /// The first record that named each subagent id (`SubagentFold.namedIn`), kept across rebuilds
  /// past a cut, whose fold starts over and knows only the subagents past it; a full rebuild
  /// reads it again. A cut goes back to the first record of any subagent named on both sides of
  /// it, in records the fold read or a repair just brought (`rebuild`).
  private readonly subagentFirstSeen = new Map<string, number>();
  /// The newest record that named each subagent id: with `subagentFirstSeen`, whether one spans a shed's cut
  /// (`shedOlderHeld`), or only the records it lets go named it (`dropHeldRun`).
  private readonly subagentLastSeen = new Map<string, number>();
  /// The subagents' views as a rebuild past a cut left them (`rebuild`), under the live fold's.
  private frozenSubagentViews: Record<string, AcpmuxRow[]> | undefined;
  private subagentViewsOf:
    | { frozen: Record<string, AcpmuxRow[]>; live: Record<string, AcpmuxRow[]>; merged: Record<string, AcpmuxRow[]> }
    | undefined;
  /// The snapshot's `subagentViews`: the live fold's, over those kept past a cut. The same record
  /// while neither changes, as `SubagentFold.views` keeps its own.
  private publishedSubagentViews(): Record<string, AcpmuxRow[]> {
    const live = this.subagents.views();
    const frozen = this.frozenSubagentViews;
    if (!frozen) return live;
    const kept = this.subagentViewsOf;
    if (kept?.frozen === frozen && kept.live === live) return kept.merged;
    const merged = { ...frozen, ...live };
    this.subagentViewsOf = { frozen, live, merged };
    return merged;
  }
  /// Preset approval rows the fold took away (merged into an older card) since an older page's fold
  /// began: that fold does not put them back from the rows it held (`foldOlder`).
  private readonly presetApprovalRemoved = new Set<string>();
  /// A preset approval record's change to its preset and digest's cards: rows that no longer
  /// stand for a card go, and each card's row takes its ask and outcome. A row the person answered
  /// here keeps that outcome until the decision record comes, and an open one its busy or error.
  private applyPresetApprovals(change: PresetApprovalChange): void {
    for (const id of change.removed) {
      this.rows.delete(id);
      // An older page's fold puts back the rows it held unless they are named here.
      this.presetApprovalRemoved.add(id);
    }
    for (const card of change.cards) {
      const row = this.rows.get(card.rowId);
      const earlier = row?.presetApproval;
      const outcome = card.outcome ?? earlier?.outcome;
      const approval: PresetApproval = outcome
        ? { ask: card.ask, outcome }
        : {
            ask: card.ask,
            ...(earlier?.busy ? { busy: earlier.busy } : {}),
            ...(earlier?.error ? { error: earlier.error } : {}),
          };
      if (row && earlier && earlier.ask === card.ask && earlier.outcome === approval.outcome && row.at === card.at)
        continue;
      if (!row) {
        this.endAssistantSegment();
        this.streamingActivity = undefined;
      }
      this.presetApprovalRemoved.delete(card.rowId);
      // A new row sorts at its first request, not at the record being reduced: a card a late
      // decision split off goes where its request was (rows.current is the decision's seq then).
      const current = this.rows.current;
      if (!row) this.rows.current = card.seq;
      this.rows.set(card.rowId, {
        id: card.rowId,
        version: (row?.version ?? 0) + 1,
        at: card.at,
        kind: PRESET_APPROVAL,
        presetApproval: approval,
      });
      this.rows.current = current;
    }
  }
  private updatePresetApproval(rowId: string, change: (approval: PresetApproval) => PresetApproval): boolean {
    const row = this.rows.get(rowId);
    if (!row?.presetApproval) return false;
    this.rows.set(rowId, { ...row, version: row.version + 1, presetApproval: change(row.presetApproval) });
    return true;
  }
  /// Approve or Not now on a preset approval card: `_acpmux/presets {name, approveMode,
  /// approveDigest, sessionId}` on this chat's own connection, sent on the click with no await
  /// before it (the host lets it through only on the person's gesture). acpmux records the
  /// decision in this chat, which closes the card; an accepted answer closes it at once. A refusal
  /// (the preset changed since the card was drawn, or the host refused it) keeps the card open with
  /// acpmux's message.
  async answerPresetApproval(rowId: string, approve: boolean): Promise<void> {
    const sessionId = this.actingSessionId;
    const approval = this.rows.get(rowId)?.presetApproval;
    if (!sessionId || !approval || approval.outcome || approval.busy) return;
    const outcome: PresetApprovalOutcome = approve ? "approved" : "declined";
    const { preset, digest } = approval.ask;
    const sent = this.request("_acpmux/presets", {
      name: preset,
      approveMode: approve,
      approveDigest: digest,
      sessionId,
    });
    if (this.updatePresetApproval(rowId, (current) => presetApprovalSending(current, outcome))) this.emit();
    try {
      await sent;
      if (this.selectedSessionId !== sessionId) return;
      if (
        this.updatePresetApproval(rowId, (current) =>
          current.outcome ? current : presetApprovalClosed(current, outcome),
        )
      )
        this.emit();
    } catch (error) {
      if (this.selectedSessionId !== sessionId) return;
      const message = error instanceof Error ? error.message : String(error);
      if (
        this.updatePresetApproval(rowId, (current) =>
          current.outcome ? current : presetApprovalFailed(current, message),
        )
      )
        this.emit();
    }
  }
  /// Resolutions of memory offers whose `memory_offer` record has not been read yet, by offer id.
  private readonly memoryEarly = new Map<string, unknown[]>();
  /// Settles an offer's row from a `memory_resolved` record or a `memory_resolve` result; one for an
  /// offer not drawn yet waits for it. Returns whether a row changed.
  private settleMemoryRow(offerId: string, resolution: unknown): boolean {
    const id = memoryRowId(offerId);
    const row = this.rows.get(id);
    if (!row?.memory) {
      const early = this.memoryEarly.get(offerId) ?? [];
      early.push(resolution);
      this.memoryEarly.set(offerId, early);
      return false;
    }
    const memory = settleMemoryOffer(row.memory, resolution);
    if (memory === row.memory) return false;
    this.rows.set(id, { ...row, version: row.version + 1, memory });
    return true;
  }
  private updateMemoryRow(offerId: string, change: (memory: NonNullable<AcpmuxRow["memory"]>) => AcpmuxRow["memory"]) {
    const id = memoryRowId(offerId);
    const row = this.rows.get(id);
    if (!row?.memory) return;
    this.rows.set(id, { ...row, version: row.version + 1, memory: change(row.memory) });
    this.emit();
  }
  /// Accept or Dismiss on a memory offer's facts (`_acpmux/memory_resolve`): the facts wait while
  /// the daemon writes the file, then settle from its answer (its `memory_resolved` record settles
  /// them the same way). A failed write leaves them actionable with the daemon's message on the card.
  async resolveMemory(offerId: string, accept: string[], dismiss: string[]): Promise<void> {
    const sessionId = this.selectedSessionId;
    const row = this.rows.get(memoryRowId(offerId));
    if (!sessionId || !row?.memory || (!accept.length && !dismiss.length)) return;
    const { file } = row.memory;
    const facts = [...accept, ...dismiss];
    this.updateMemoryRow(offerId, (memory) => memoryRequestStarted(memory, facts));
    try {
      // The facts go back verbatim: the daemon matches them against its offer.
      const result = await this.typed("_acpmux/memory_resolve", { sessionId, offerId, file, accept, dismiss });
      if (this.selectedSessionId !== sessionId) return;
      const answer = result && typeof result === "object" ? (result as Record<string, unknown>) : {};
      if (this.settleMemoryRow(offerId, { ...answer, offerId })) this.emit();
      // An answer that settled none of them (already settled elsewhere, or an empty answer) frees them.
      else this.updateMemoryRow(offerId, (memory) => memoryRequestFailed(memory, facts, ""));
    } catch (error) {
      if (this.selectedSessionId !== sessionId) return;
      const message = error instanceof Error ? error.message : String(error);
      this.updateMemoryRow(offerId, (memory) => memoryRequestFailed(memory, facts, message));
    }
  }
  /// Takes out a line `notice` put in (a lost prompt's "Not sent" once the host sent it after all).
  dismissNotice(id: string): void {
    if (this.rows.get(id)?.kind !== "notice") return;
    this.rows.delete(id);
    this.emit();
  }
  private adoptFailed(reason?: string): void {
    const at = Date.now();
    const id = noticeId("notice-adopt");
    this.rows.set(id, {
      id,
      version: 1,
      at,
      kind: "notice",
      text: reason ? translate("notice.resumeFailedReason", { reason }) : translate("notice.resumeFailed"),
    });
    this.emit();
  }
  /// Forks the open session (or `from`, the chat it was forked from) through the turn whose summary
  /// is `throughSeq`, and opens the fork. One fork at a time; a second click while acpmux forks does
  /// nothing. A failure says so in the transcript; a reader who opened another session meanwhile
  /// stays there. `stay` keeps this chat open and only answers the fork, for its own tab: the pane
  /// shows its pending line meanwhile (ForkPendingLine), whose Cancel is `cancelFork`.
  /// `"live"`: the whole chat as it is now, also while its turn runs (Fork Conversation).
  async fork(throughSeq: number | "live", from?: string, stay = false): Promise<string | undefined> {
    if (!this.canFork || !this.actingSessionId || this.forking) return undefined;
    this.forking = true;
    this.forkCancelled = false;
    const generation = this.selectionGeneration;
    const sessionId = from ?? this.actingSessionId;
    const cancelToken = stay ? crypto.randomUUID() : undefined;
    if (stay) {
      this.forkPendingSince = Date.now();
      this.forkPendingFrom = sessionId;
      this.forkCancelToken = cancelToken;
      this.emit();
    }
    try {
      const boundary = throughSeq === "live" ? { sessionId, live: true } : { sessionId, throughSeq };
      const result = await this.request(FORK_OP, cancelToken ? { ...boundary, cancelToken } : boundary);
      if (this.forkCancelled) {
        if (result?.sessionId) this.takeBackFork(String(result.sessionId));
        return undefined;
      }
      if (!result?.sessionId || generation !== this.selectionGeneration) return undefined;
      if (stay) {
        this.handOverForkTail(sessionId, result);
        return String(result.sessionId);
      }
      return await this.select(String(result.sessionId));
    } catch (error) {
      if (!this.forkCancelled && generation === this.selectionGeneration) {
        // Feedback on the person's Fork: a toast, never a transcript row (review of #37629).
        // The pane's own reason when it knows one (a refusal it words); acpmux's text goes to the log.
        const reason = knownRefusalText(error);
        if (!reason) console.warn("agent pane: fork failed", error);
        this.transient(
          reason ? translate("notice.forkFailedReason", { reason }) : translate("notice.forkFailed"),
          "error",
        );
      }
      return undefined;
    } finally {
      this.forking = false;
      this.forkCancelled = false;
      this.forkPendingFrom = undefined;
      this.forkCancelToken = undefined;
      if (this.forkPendingSince !== undefined) {
        this.forkPendingSince = undefined;
        this.emit();
      }
    }
  }
  /// Cancel on the pending fork: acpmux stops it where it is, by the token its request named it
  /// with, and leaves nothing of it; one already made is taken back whole. Its answer opens
  /// nothing either way, and an answer with a fork takes that back too (`takeBackFork`). "i shuold
  /// be able to cancel a fork probably" (Leo, 2026-11-06).
  cancelFork(): void {
    if (!this.forking || this.forkCancelled) return;
    this.forkCancelled = true;
    this.forkPendingSince = undefined;
    const cancelToken = this.forkCancelToken;
    if (cancelToken && this.forkPendingFrom) {
      void this.request("_acpmux/kill", { sessionId: this.forkPendingFrom, cancelFork: true, cancelToken }).catch(
        () => undefined,
      );
    }
    this.emit();
  }
  /// Removes a fork nobody used: its chat, and the conversation copy its agent made (acpmux
  /// `hub/fork_cancel.rs`). Not waited on: the pane already went back to the chat.
  private takeBackFork(sessionId: string): void {
    void this.request("_acpmux/kill", { sessionId, purge: true, cancelFork: true }).catch(() => undefined);
  }
  /// Forks the open session through `throughSeq` (`live`: a working chat as it is now, its own turn
  /// going on, as Fork Conversation does) and stays on it: New side chat's and `/side`'s copy, which
  /// the host opens beside this chat. The fork's rows go to the app host as its tail, so the side
  /// chat's page draws them at once (forkTail.ts). One fork at a time, as `fork`.
  /// A fork made while the reader opened another chat is taken back: it would be tagged the side
  /// chat of one chat and opened beside another.
  async forkAside(throughSeq: number | "live"): Promise<string | undefined> {
    const sessionId = this.selectedSessionId;
    if (!this.canFork || !sessionId || this.forking) return undefined;
    this.forking = true;
    const generation = this.selectionGeneration;
    try {
      const boundary = throughSeq === "live" ? { sessionId, live: true } : { sessionId, throughSeq };
      const result = await this.request(FORK_OP, boundary);
      if (!result?.sessionId) return undefined;
      if (generation !== this.selectionGeneration) {
        this.takeBackFork(String(result.sessionId));
        return undefined;
      }
      this.handOverForkTail(sessionId, result);
      return String(result.sessionId);
    } finally {
      this.forking = false;
    }
  }
  /// A pick of another harness's model, sent (forkHold.ts; Leo 2026-11-11: "if i switch to a
  /// different model in a chat, it should just be able to seamlesly within the same pane do stuff
  /// and stop asking so much bullshit"): acpmux forks the open chat as it is now onto `harness`,
  /// started on `model` (the caller sets the effort after), its history shown by reference and carried to the new agent
  /// with its first prompt (`acp.session.fork {live, harness}`), and this pane opens the fork in
  /// place: no review, no tab. Resolves the fork's id once it is the selected chat; rejects with
  /// acpmux's reason when it refused, or when the reader opened another chat meanwhile (the fork is
  /// then taken back), so the composer keeps the message.
  async forkTo(target: { harness: string; model?: string }): Promise<string> {
    const sessionId = this.actingSessionId;
    // l10n-allow: the composer's promise only; the composer keeps the text, never shows this.
    if (!this.canFork || !sessionId) throw new Error("chat cannot fork");
    // l10n-allow: as above.
    if (this.forking) throw new Error("a fork is already running");
    this.forking = true;
    const generation = this.selectionGeneration;
    try {
      const result = await this.request(FORK_OP, {
        sessionId,
        live: true,
        harness: target.harness,
        ...(target.model ? { model: target.model } : {}),
      });
      const forked = typeof result?.sessionId === "string" ? result.sessionId : "";
      // l10n-allow: as above.
      if (!forked) throw new Error("the fork made no chat");
      if (generation !== this.selectionGeneration) {
        this.takeBackFork(forked);
        // l10n-allow: as above.
        throw new Error("another chat was opened");
      }
      this.forking = false;
      await this.select(forked);
      // l10n-allow: as above.
      if (this.selectedSessionId !== forked) throw new Error("the fork did not open");
      return forked;
    } finally {
      this.forking = false;
    }
  }
  /// New side chat and `/side [prompt]` of a chat on another machine that opens side chats there
  /// (`sideChatOnMachine`): that machine forks the open chat through `throughSeq` (`live`: as it is
  /// now, its turn going on), tags the fork its side chat and sends it `prompt`, in one call, and
  /// the side chat runs there, in the chat's folder (the app's RemoteAcpmuxWire, cmux-tui
  /// agent_session_side.rs). Answers its id there, which the host then opens beside the chat, and
  /// `notSent`, why that machine's acpmux did not take `prompt` when it did not.
  async sideChatOnMachine(
    throughSeq: number | "live",
    prompt?: string,
  ): Promise<{ sessionId: string; notSent?: string } | undefined> {
    const sessionId = this.selectedSessionId;
    if (!this.features.has(SIDE_CHAT_FEATURE) || !sessionId || this.forking) return undefined;
    this.forking = true;
    try {
      const boundary = throughSeq === "live" ? { live: true } : { throughSeq };
      const result = await this.request("_acpmux/side_chat", {
        sessionId,
        ...boundary,
        ...(prompt ? { prompt } : {}),
      });
      if (typeof result?.sessionId !== "string" || !result.sessionId) return undefined;
      const notSent = typeof result.notSent === "string" ? { notSent: result.notSent } : {};
      return { sessionId: result.sessionId, ...notSent };
    } finally {
      this.forking = false;
    }
  }
  /// A side chat's fork that never opened beside its chat: its chat and conversation copy go.
  takeBackSide(sessionId: string): void {
    this.takeBackFork(sessionId);
  }
  /// `/btw <question>`: acpmux starts a read-only side session about the open chat, on a fast model,
  /// asks it `question` and answers with its id at once (`_acpmux/btw`). The chat is not touched,
  /// so this works while its turn runs. Rejects with acpmux's message when it refuses.
  /// `sessionId`: Needs you's Ask about this names the asking chat (acpmux hub/btw.rs); the relay
  /// sends it only for a chat in the pane's scope (AcpmuxPaneMethods.sessionScoped) and on a click
  /// (its gesture rule), and its reply's session joins the scope, so the host may open it beside
  /// the chat (`chat.sideChat`).
  async btw(question: string, sessionId = this.actingSessionId, targetHarness?: string): Promise<string> {
    if (!sessionId) throw new Error(translate("error.notOpen"));
    const result = await this.request(SIDE_SESSION_METHOD, {
      sessionId,
      question,
      ...(targetHarness ? { targetHarness } : {}),
    });
    // No id: the caller says the side session did not start, without a reason it does not have.
    if (typeof result?.sessionId !== "string" || !result.sessionId) throw new Error("");
    return result.sessionId;
  }
  /// A Cloud chat's machine answers `/btw` inline itself (`btw_inline`, RemoteAcpmuxWire).
  get answersBtwInline(): boolean {
    return this.features.has(BTW_INLINE_HERE);
  }
  /// `/btw <question>` answered inline on the chat's own machine (`_acpmux/btw` with `inline`,
  /// through its daemon's `agent-session-btw`): the answer's text. The chat is not touched.
  async btwInlineHere(question: string, sessionId = this.actingSessionId): Promise<string> {
    if (!sessionId) throw new Error(translate("error.notOpen"));
    const result = await this.request(SIDE_SESSION_METHOD, { sessionId, question, inline: true });
    if (typeof result?.text !== "string" || !result.text.trim()) throw new Error("");
    return result.text;
  }
  /// One-shot cross-harness guest reply. The daemon creates a fresh read-only side session,
  /// carries the bounded transcript context, returns its answer, and removes the guest session.
  async btwInline(question: string, targetHarness: string, sessionId = this.actingSessionId): Promise<string> {
    if (!sessionId) throw new Error(translate("error.notOpen"));
    const result = await this.request(SIDE_SESSION_METHOD, {
      sessionId,
      question,
      targetHarness,
      inline: true,
    });
    if (typeof result?.text !== "string" || !result.text.trim()) throw new Error("");
    return result.text;
  }
  /// This machine's agent spend for History > Costs (`_acpmux/ledger`, ledger/ledgerModel.ts): read
  /// from acpmux's ledger index, never a log scan. An older acpmux answers method not found.
  async ledger(params: Record<string, unknown>): Promise<unknown> {
    return this.request("_acpmux/ledger", params, 15_000);
  }
  /// The team's agent spend for History > Team (`_acpmux/team_audit`, teamAudit/teamAuditModel.ts):
  /// acpmux reads cmux-platform with its sign-in. An older acpmux answers method not found.
  async teamAudit(params: Record<string, unknown>): Promise<unknown> {
    return this.request("_acpmux/team_audit", params, 45_000);
  }
  /// Every ask waiting on the person across agents and machines, for History > Waiting on you
  /// (`_acpmux/review_queue`, queue/queueModel.ts).
  async reviewQueue(params: Record<string, unknown> = {}): Promise<unknown> {
    return this.request("_acpmux/review_queue", params, 15_000);
  }
  /// A pull request item's Accept or Request changes (`_acpmux/review_verdict`). Sent on the click
  /// or key with no await before it: the relay takes a verdict only on the person's gesture.
  async reviewVerdict(params: Record<string, unknown>): Promise<unknown> {
    return this.request("_acpmux/review_verdict", params, 15_000);
  }
  /// One page of the approvals audit trail (`_acpmux/audit`): `{entries, next?}`.
  async audit(params: Record<string, unknown> = {}): Promise<unknown> {
    return this.request("_acpmux/audit", params, 15_000);
  }
  /// The chat's effective prompt context for the Context screen (`_acpmux/context`, acpmux
  /// context_inventory.rs): what cmux adds in full, the harness's own parts as counts.
  async contextInventory(sessionId = this.actingSessionId): Promise<unknown> {
    if (!sessionId) throw new Error(translate("error.notOpen"));
    return this.request("_acpmux/context", { sessionId });
  }
  /// Saves (or with `text: null` removes) the guidance new chats get, for every chat (`user`) or
  /// this folder's (`project`), and answers with the inventory after it (`_acpmux/context_override`).
  /// Sent on the Save click with no await before it: the relay takes it only on a gesture.
  async setContextOverride(
    change: { scope: "user" | "project"; text: string | null; partId?: string },
    sessionId = this.actingSessionId,
  ): Promise<unknown> {
    if (!sessionId) throw new Error(translate("error.notOpen"));
    return this.request("_acpmux/context_override", { sessionId, ...change });
  }
  async setModel(modelId: string): Promise<void> {
    if (this.actingSessionId) await this.request("session/set_model", { sessionId: this.actingSessionId, modelId });
  }
  /// `ticket`: a gesture ticket a held pick took (pane-native transport, `transport.gesture`); it
  /// rides as `_meta.cmuxGesture`, and the host strips it before acpmux.
  async setMode(modeId: string, ticket?: string): Promise<void> {
    if (this.actingSessionId)
      await this.request("session/set_mode", {
        sessionId: this.actingSessionId,
        modeId,
        ...gestureMeta(ticket),
      });
  }
  /// The session's summary reads the agent's answer, its whole option list: acpmux sends no
  /// session change for it, so without this the chip and menu keep the old level.
  async setConfig(configId: string, value: string, ticket?: string): Promise<void> {
    const sessionId = this.actingSessionId;
    if (!sessionId) return;
    const generation = this.selectionGeneration;
    const result = await this.request("session/set_config_option", {
      sessionId,
      configId,
      value,
      ...gestureMeta(ticket),
    });
    // `summary` is the selected chat's: during a hold that is already the next chat, not the one acted on.
    if (generation !== this.selectionGeneration || sessionId !== this.selectedSessionId) return;
    if (!Array.isArray(result?.configOptions)) return;
    this.summary = { ...this.summary, configOptions: result.configOptions };
    this.emit();
  }
  /** The harness and model catalog. Server state the pane caches with TanStack Query (catalog.ts), so connect does not wait on it.
   *  With `cwd` (the chat's folder) it also holds that folder's harness profiles (`folder` entries,
   *  docs/add-your-harness.md). A refused `cwd` (an older acpmux, a folder outside the roots)
   *  falls back to the list without it, so the catalog never empties over a folder. */
  async harnesses(cwd?: string): Promise<AcpmuxSnapshot["catalog"]> {
    // The harness list carries no models; acpmux serves the probed ones apart (modelCatalog.ts).
    // Only this machine's: mergeModelCatalog drops peer rows, and asking the peers waited up to
    // their 10 s budget before the picker had a list (Leo 2026-11-08: "this shouldn't be so slow
    // to load in"). An acpmux without `localOnly` ignores it and answers as before.
    const [names, probed] = await Promise.all([
      cwd
        ? this.request("_acpmux/harnesses", { cwd }).catch(() => this.request("_acpmux/harnesses", {}))
        : this.request("_acpmux/harnesses", {}),
      this.request("_acpmux/models", { localOnly: true }).catch(() => undefined),
    ]);
    const catalog = mergeModelCatalog(names, probed);
    const profiles = normalizeFolderProfiles(names);
    if (profiles.length === 0) return catalog;
    // A probed folder profile keeps its models; it is listed once, as the folder's.
    const ids = new Set(profiles.map((profile) => profile.id));
    const models = new Map(catalog.map((entry) => [entry.id, entry.models]));
    return [
      ...catalog.filter((entry) => !ids.has(entry.id)),
      ...profiles.map((profile) => ({
        ...profile,
        models: models.get(profile.id) ?? profile.models,
      })),
    ];
  }
  /// Another machine's agents: acpmux forwards `_acpmux/harnesses` to the peer `_meta.acpmux.peer`
  /// names (requests.rs, 5 s limit) and answers with that machine's reply plus `peer`. The composer
  /// checks the agent a new chat there will start with (machineHarnesses.ts); a refusal or a timeout
  /// rejects, which holds nothing.
  peerHarnesses(peer: string): Promise<unknown> {
    return this.request("_acpmux/harnesses", { _meta: { acpmux: { peer } } });
  }
  /// Reads acpmux's peers again (`_acpmux/status`): the environment picker asks as it opens, so a
  /// machine that connected or dropped since shows as it is now. Local/app peer events keep the
  /// closed control current when the daemon advertises them; older daemons keep their last snapshot.
  async refreshPeers(): Promise<void> {
    const since = this.peerEvents.statusStarted();
    const status = await this.request("_acpmux/status", {}).catch(() => undefined);
    if (status === undefined) return;
    this.readPeers(status, since);
    // A held snapshot (a chat being switched or reattached) draws the peers when it is released;
    // emitting now would record "connected" on the hold before setup says so.
    if (!this.snapshotHold) this.emit();
  }
  private async refreshPeerStates(): Promise<boolean> {
    const read = this.peerEvents.readStarted();
    if (!this.peerEvents.snapshot(await this.request("_acpmux/peers", {}), read)) return false;
    this.applyPeerStates();
    return true;
  }
  /// Reads the peer snapshot off the caller's path and draws it when it lands; a held snapshot (or a
  /// connection still opening) draws it with its own emit.
  private async refreshPeerStatesAndEmit(): Promise<void> {
    const applied = await this.refreshPeerStates().catch(() => false);
    if (applied && !this.closed && !this.opening && !this.snapshotHold) this.emit();
  }
  private applyPeerStates(): void {
    const peers = [...this.peerEvents.entries()];
    // A peer the status read lists but an authoritative snapshot omits (removed since, or a row it
    // could not read) is not connected: with no entry at all the picker would read it as ready.
    const unlisted = this.peerEvents.authoritative
      ? Object.fromEntries(this.peers.map((peer) => [peer, false] as const))
      : this.peerConnected;
    this.peerStates = {
      ...(this.peerEvents.authoritative ? {} : this.peerStates),
      ...Object.fromEntries(peers.map(([peer, link]) => [peer, link.state])),
    };
    const links = Object.fromEntries(
      peers.flatMap(([peer, link]) => (link.detail ? [[peer, link.detail] as const] : [])),
    );
    // A note from an older daemon (no detail) leaves no stale whole state behind.
    const said = new Set(peers.map(([peer]) => peer));
    this.peerLinks = {
      ...Object.fromEntries(
        Object.entries(this.peerEvents.authoritative ? {} : this.peerLinks).filter(([peer]) => !said.has(peer)),
      ),
      ...links,
    };
    this.peerConnected = {
      ...unlisted,
      ...Object.fromEntries(peers.map(([peer, link]) => [peer, link.connected])),
    };
    this.peerStatus = {
      ...(this.peerEvents.authoritative
        ? Object.fromEntries(
            this.peers.map((peer) => {
              // Keeps what the status read last said (`lastSeen`, `attempts`) for the offline banner.
              const { state: _state, ...seen } = this.peerStatus[peer] ?? {};
              return [peer, { ...seen, connected: false }];
            }),
          )
        : this.peerStatus),
      ...Object.fromEntries(peers.map(([peer, link]) => [peer, { ...this.peerStatus[peer], ...link }])),
    };
    const peer = this.sessions.find((session) => session.sessionId === this.selectedSessionId)?.peer;
    if (typeof peer === "string" && this.peerConnected[peer] === true) this.retryOwedLagRead();
  }
  /// `since`: the status read's tick (`PeerStateEvents.statusStarted`); omitted for a reply that is
  /// not a fresh read of every peer's state, which then never replaces an event entry.
  private readPeers(status: any, since?: number): void {
    // Asked before a status read that already landed: it would put back what that one replaced.
    if (since !== undefined && !this.peerEvents.statusRead(since)) return;
    this.peers = Array.isArray(status?.peers)
      ? status.peers
          .map((peer: any) => (typeof peer?.name === "string" ? peer.name : undefined))
          .filter((peer: string | undefined): peer is string => Boolean(peer))
      : [];
    this.peerKinds = peerKindsFromStatus(status);
    this.peerConnected = peerConnectedFromStatus(status);
    this.peerStates = peerStatesFromStatus(status);
    this.peerLinks = peerLinksFromStatus(status);
    this.peerResources = peerResourcesFromStatus(status);
    this.peerStatus = peerStatusFromStatus(status);
    if (this.peerEvents.observed) this.applyPeerStates();
  }
  /// Probes every agent's live model list again (`_acpmux/models {refresh: true}`): acpmux forgets
  /// the lists it has and asks each harness before it answers (the picker's Refresh models).
  refreshModels(): Promise<unknown> {
    return this.request("_acpmux/models", { refresh: true });
  }
  /// The model catalog acpmux uses (`catalog.get`: its fetched, stored or bundled copy with the
  /// public feed's newer models over it); `refresh` makes it fetch both first (`catalog.refresh`).
  async modelCatalog(refresh = false): Promise<unknown> {
    if (refresh) await this.request("catalog.refresh", {});
    return this.request("catalog.get", {});
  }
  /// Enables a folder profile (`_acpmux/harness_enable {folder, id}`). Call it straight from the
  /// click or key handler, with no await before it: the host takes the gesture, shows its own
  /// confirmation and adds the file's hash itself (the pane never sends one). A Cancel there
  /// rejects with code `transport.harness_not_confirmed`; when acpmux refused to give the prompt
  /// (no Trust answer, an invalid file), that rejection carries its reason as `detail`; when
  /// acpmux gave no prompt (down, too slow), `reason` is `harness.prompt_unavailable`.
  harnessEnable(folder: string, id: string): Promise<unknown> {
    return this.request("_acpmux/harness_enable", { folder, id });
  }
  /// The chat's every prompt older than its open page, read once per chat from acpmux's prompt
  /// index (`_acpmux/events` `promptIndex`, `hub/paging.rs` `prompt_index`): seq, promptId and the
  /// start of the text, in one reply however long the chat. A daemon without the index reads the
  /// bounded `user_message` page the request also names, which covers what it holds.
  private promptIndex?: PromptIndexRead;
  /// `shownEarlierPrompts`' last answer, by what it was read from.
  private earlierShown?: { heads: PromptHeads; before: number; list: PromptHeads };

  /// The indexed prompts older than every held row (the snapshot's `earlierPrompts`). The first ask
  /// for a chat with older history starts the index's one read.
  private shownEarlierPrompts(): PromptHeads {
    const sessionId = this.selectedSessionId;
    if (!sessionId || !this.seqHistoryLeft() || !this.firstSeq) return NO_EARLIER_PROMPTS;
    const index = this.promptIndex;
    if (!index || index.sessionId !== sessionId || index.generation !== this.selectionGeneration) {
      void this.readPromptIndex(sessionId, this.firstSeq);
      return NO_EARLIER_PROMPTS;
    }
    // A read that failed (a reconnect cut it, a peer's read deadline) is asked again by the next
    // snapshot past its back-off, PROMPT_INDEX_TRIES reads in all; the rail's hover asks past that.
    if (index.failed && index.tries < PROMPT_INDEX_TRIES && Date.now() >= index.retryAt) {
      void this.readPromptIndex(sessionId, this.firstSeq, index.tries);
      return NO_EARLIER_PROMPTS;
    }
    if (!index.heads) return NO_EARLIER_PROMPTS;
    // The turn opener drawn above the held page is held: only prompts before it are earlier.
    const before = Math.min(this.firstSeq, this.turnOpener?.seq ?? Infinity);
    const kept = this.earlierShown;
    if (kept && kept.heads === index.heads && kept.before === before) return kept.list;
    const list = PromptHeads.before(index.heads, before);
    this.earlierShown = { heads: index.heads, before, list };
    return list;
  }

  /// The chat's prompt count as its summary has it (`turnCount`), while the rail does not hold every
  /// prompt yet: older history is left and the prompt index has not answered, or this daemon has none.
  /// The rail takes its full height from it on the first frame instead of growing as the index or
  /// older pages arrive (snapshot `promptCount`; Leo, 2026-11-01: "i also want the left scroll rail to
  /// be starting off to its max height if there truly are that many prompts in the chat").
  private promptCountAwaited(): number | undefined {
    const sessionId = this.selectedSessionId;
    if (!sessionId || !this.seqHistoryLeft()) return undefined;
    const index = this.promptIndex;
    if (index?.heads && !index.failed && index.sessionId === sessionId && index.generation === this.selectionGeneration)
      return undefined;
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const count = Number(summary?.turnCount ?? 0);
    return count > 0 ? count : undefined;
  }

  /// The rail's ask for the prompt index, from a hover or a click on a pending tick (ThreadMinimap
  /// `loadPromptIndex`): resolves true once the index has named the chat's earlier prompts, false
  /// when it cannot. One read at a time per chat, its answer kept for the chat; a failed read is
  /// read again past its back-off, so a sweep across a hundred ticks asks at most once.
  loadPromptIndex(): Promise<boolean> {
    const sessionId = this.selectedSessionId;
    if (!sessionId || !this.seqHistoryLeft() || !this.firstSeq) return Promise.resolve(false);
    const index = this.promptIndex;
    if (!index || index.sessionId !== sessionId || index.generation !== this.selectionGeneration)
      return this.readPromptIndex(sessionId, this.firstSeq);
    if (index.read) return index.read;
    if (!index.failed) return Promise.resolve(index.heads !== undefined);
    if (Date.now() < index.retryAt) return Promise.resolve(false);
    return this.readPromptIndex(sessionId, this.firstSeq, index.tries);
  }

  private readPromptIndex(sessionId: string, before: number, tries = 0): Promise<boolean> {
    const generation = this.selectionGeneration;
    this.promptIndex?.cancel?.();
    const entry: PromptIndexRead = { sessionId, generation, tries: tries + 1, retryAt: 0 };
    this.promptIndex = entry;
    let finish!: (value: boolean) => void;
    entry.read = new Promise<boolean>((resolve) => {
      finish = resolve;
    });
    let settled = false;
    const settle = (value: boolean) => {
      if (settled) return;
      settled = true;
      finish(value);
    };
    // This read scans every historical prompt, and its reply parses/maps them all. The first
    // snapshot only needs the bounded tail; promptCount keeps the rail's final geometry while
    // its labels arrive. Do not let even a local daemon's immediate reply precede that paint.
    const cancelPaint = afterPaint(() => {
      entry.cancel = undefined;
      if (this.closed || this.promptIndex !== entry || generation !== this.selectionGeneration) {
        settle(false);
        return;
      }
      void this.typed(
        "_acpmux/events",
        {
          sessionId,
          beforeSeq: before,
          promptIndex: true,
          kinds: ["user_message"],
          limit: 5000,
          maxBytes: PROMPT_INDEX_BYTES,
        },
        PROMPT_INDEX_DEADLINE_MS,
      )
        .then((result: any) => {
          if (this.closed || this.promptIndex !== entry) {
            settle(false);
            return false;
          }
          entry.read = undefined;
          // Kept as columns (promptHeads.ts): a 100k-row chat's index was 50k rows here and a turn, a tick and a
          // key each in the rail, about 15 MB of renderer heap a chat (bench/chat-100k-flat.bench.ts).
          const heads: PromptHead[] = [];
          for (const event of records(result?.events)) {
            if (!startsTurn(event)) continue;
            const promptId = typeof event.msg?.promptId === "string" ? event.msg.promptId : undefined;
            heads.push({
              seq: event.seq,
              at: event.at,
              text: String(event.msg?.text ?? "").slice(0, 240),
              ...(promptId ? { promptId } : {}),
            });
          }
          entry.heads = PromptHeads.of(heads);
          this.emit();
          settle(true);
          return true;
        })
        .catch(() => {
          // Without the index the rail keeps the summary's count (promptCountAwaited) while pages load,
          // and reads the index again past the back-off (shownEarlierPrompts, loadPromptIndex).
          if (this.promptIndex !== entry) {
            settle(false);
            return false;
          }
          entry.read = undefined;
          entry.heads = PromptHeads.EMPTY;
          entry.failed = true;
          entry.retryAt = Date.now() + PROMPT_INDEX_RETRY_MS * entry.tries;
          settle(false);
          return false;
        });
    });
    entry.cancel = () => {
      cancelPaint();
      settle(false);
    };
    return entry.read;
  }

  /// Reads the transcript window containing an indexed prompt. `_acpmux/events` accepts both
  /// cursors, so the daemon can seek to the target in one bounded read; this is deliberately
  /// separate from `fetchOlder`, whose cursor must walk from the currently held tail.
  private indexedPage(seq: number): Promise<EventRecord[]> | undefined {
    const sessionId = this.selectedSessionId;
    const generation = this.selectionGeneration;
    if (!sessionId || !Number.isFinite(seq) || seq < 1) return undefined;
    const bucket = Math.floor(seq / INDEXED_PAGE_RADIUS);
    const key = `${sessionId}:${generation}:${bucket}`;
    const held = this.indexedPages.get(key);
    if (held) return held;
    const after = Math.max(0, seq - INDEXED_PAGE_RADIUS);
    const before = seq + INDEXED_PAGE_RADIUS + 1;
    const kinds = ["transcript", ...(this.localOrigin ? PRESET_APPROVAL_KINDS : [])];
    const read = this.typed(
      "_acpmux/events",
      {
        sessionId,
        afterSeq: after,
        beforeSeq: before,
        limit: INDEXED_PAGE_LIMIT,
        maxBytes: OLDER_PAGE_BYTES,
        kinds,
      },
      PROMPT_INDEX_DEADLINE_MS,
    )
      .then((result: any) => {
        if (this.closed || generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return [];
        return records(result?.events);
      })
      .catch(() => []);
    this.indexedPages.set(key, read);
    // Keep only a small neighborhood. The target stays first in the map until the adjacent reads
    // settle, while old drag targets cannot grow this cache with a whole chat's pages.
    while (this.indexedPages.size > INDEXED_PAGE_CACHE_LIMIT) {
      const oldest = this.indexedPages.keys().next().value;
      if (oldest === undefined || oldest === key) break;
      this.indexedPages.delete(oldest);
    }
    return read;
  }

  private mergeIndexedPage(page: EventRecord[]): boolean {
    if (!page.length) return false;
    const before = this.events.length ? this.events[0]!.seq : Number.POSITIVE_INFINITY;
    const pageStart = Math.min(...page.map((event) => event.seq));
    const tailStart = this.firstSeq ?? Number.POSITIVE_INFINITY;
    this.events = mergeEventRecords(this.events, page);
    this.sawPrompts(page);
    // Preserve the live queue/permissions and the reconnect reader anchor while replaying the
    // newly held records, as `checkFinishedTurn` does for a narrow repair read.
    this.rebuildKeepingLiveState(Math.min(before, ...page.map((event) => event.seq)) - 1);
    const held = new Set(this.events.map((event) => event.seq));
    for (const row of indexedPromptPlaceholders(
      this.promptIndex?.heads ?? PromptHeads.EMPTY,
      held,
      pageStart,
      tailStart,
    ))
      this.indexedPlaceholders.set(row.id, row);
    this.emit("history");
    // The page sits below the held tail with a hole between them: no older page reads across it
    // (they page down from `firstSeq`), so read it forward from the page's end, in the background.
    const pageEnd = Math.max(...page.map((event) => event.seq));
    if (Number.isFinite(tailStart) && pageEnd + 1 < tailStart) {
      this.indexedGaps.unshift({ after: pageEnd, before: tailStart });
      this.startIndexedGapFill();
    }
    return true;
  }

  private clearIndexedHistory(): void {
    // `?.`: a client a test builds from the prototype has none of these yet.
    this.indexedPlaceholders?.clear();
    this.indexedPages?.clear();
    this.indexedGaps = [];
  }

  /// Runs `fillIndexedGaps` unless one is running. A fill that ended stale (another chat or held history
  /// while its read was out) starts again for the gaps queued since; a failed read is read again on
  /// LAG_RETRY_MS, and past its last step the gaps wait for the next jump.
  private startIndexedGapFill(attempt = 0): void {
    if (this.indexedGapFill || this.closed) return;
    this.indexedGapFill = this.fillIndexedGaps().then((ended) => {
      this.indexedGapFill = undefined;
      if (this.closed || this.indexedGaps.length === 0) return;
      if (ended === "stale") this.startIndexedGapFill();
      else if (ended === "failed") {
        const delay = LAG_RETRY_MS[attempt];
        const generation = this.selectionGeneration;
        if (delay !== undefined)
          setTimeout(() => {
            if (generation === this.selectionGeneration) this.startIndexedGapFill(attempt + 1);
          }, delay);
      }
    });
  }

  /// Reads each indexed gap forward, one page of at most OLDER_PAGE_BYTES at a time (a relayed
  /// daemon's socket never carries more than one), merging every page as it lands so the turns just
  /// below the reader's jump target draw first. A new jump's gap goes first; another chat, visit or
  /// held history (`clearIndexedHistory`) ends the fill.
  private async fillIndexedGaps(): Promise<"done" | "stale" | "failed"> {
    const sessionId = this.selectedSessionId;
    const generation = this.selectionGeneration;
    const epoch = this.historyEpoch;
    const stale = () =>
      this.closed ||
      generation !== this.selectionGeneration ||
      this.selectedSessionId !== sessionId ||
      epoch !== this.historyEpoch;
    const kinds = ["transcript", ...(this.localOrigin ? PRESET_APPROVAL_KINDS : [])];
    // Merged pages not yet drawn: the oldest seq among them, and how many.
    let undrawnFrom = Number.POSITIVE_INFINITY;
    let undrawn = 0;
    let drawn = 0;
    const draw = () => {
      if (undrawn === 0) return;
      this.rebuildKeepingLiveState(undrawnFrom - 1);
      for (const [id, row] of this.indexedPlaceholders)
        if (row.seq !== undefined && this.events[firstHeldFrom(this.events, row.seq)]?.seq === row.seq)
          this.indexedPlaceholders.delete(id);
      this.emit("history");
      undrawnFrom = Number.POSITIVE_INFINITY;
      undrawn = 0;
      drawn += 1;
    };
    if (!sessionId) return "done";
    while (!stale()) {
      const gap = this.indexedGaps[0];
      if (!gap) {
        draw();
        return "done";
      }
      if (gap.after + 1 >= gap.before) {
        this.indexedGaps.shift();
        continue;
      }
      let result: any;
      try {
        // `afterSeq` alone: with `beforeSeq` too acpmux reads the stretch newest first
        // (server/requests.rs), which would skip the gap's oldest records.
        result = await this.typed("_acpmux/events", {
          sessionId,
          afterSeq: gap.after,
          limit: OLDER_PAGE_RECORDS,
          maxBytes: OLDER_PAGE_BYTES,
          kinds,
        });
      } catch {
        if (stale()) return "stale";
        draw();
        return "failed";
      }
      if (stale()) return "stale";
      const read = records(result?.events);
      const page = read.filter((event) => event.seq > gap.after && event.seq < gap.before);
      const reachedTail = result?.hasMore !== true || read.some((event) => event.seq >= gap.before - 1);
      if (page.length === 0) {
        if (this.indexedGaps[0] === gap) this.indexedGaps.shift();
        continue;
      }
      gap.after = reachedTail ? gap.before - 1 : Math.max(...page.map((event) => event.seq));
      this.events = mergeEventRecords(this.events, page);
      this.sawPrompts(page);
      undrawnFrom = Math.min(undrawnFrom, page[0]!.seq);
      undrawn += 1;
      // The page just below the jump target draws at once; later ones in batches.
      if (drawn === 0 || undrawn >= INDEXED_GAP_PAGES_PER_DRAW) draw();
    }
    return "stale";
  }

  /// Pages history in until the record at `seq` is held: a click on the rail's tick of a prompt
  /// older than the held rows (`earlierPrompts`). Each step is `loadOlder` reading on through `seq`
  /// (up to OLDER_PAGES_PER_ASK pages in one commit), with its guards; a step that moves nothing, or
  /// another chat, ends it.
  /// Resolves true once the prompt is held, false when the read stopped short of it.
  async loadThrough(seq: number): Promise<boolean> {
    const generation = this.selectionGeneration;
    const held = () => generation === this.selectionGeneration && this.firstSeq !== undefined && this.firstSeq <= seq;
    // The prompt index gives us the target's sequence before its transcript page is held. Fetch
    // that window first, then warm one page on each side for the next scrub step. If an older
    // daemon cannot serve the bounded read, the established page walker remains the fallback.
    const heads = this.promptIndex?.heads;
    const indexed = heads && PromptHeads.indexOfSeq(heads, seq) >= 0 ? this.indexedPage(seq) : undefined;
    if (indexed) {
      const page = await indexed;
      if (generation !== this.selectionGeneration || this.selectedSessionId === undefined) return false;
      if (page.some((event) => event.seq === seq)) {
        this.mergeIndexedPage(page);
        void this.indexedPage(Math.max(1, seq - INDEXED_PAGE_RADIUS));
        void this.indexedPage(seq + INDEXED_PAGE_RADIUS);
        if (held()) return true;
      }
    }
    // Each loadOlder call publishes one bounded page (or a rail jump's window), so keep walking
    // until the target is held. A fixed iteration cap here would make a far minimap jump fail once a
    // long chat spans more than that many pages.
    for (;;) {
      const from = this.firstSeq;
      if (held()) return true;
      if (generation !== this.selectionGeneration || from === undefined || !this.seqHistoryLeft()) return false;
      await this.loadOlder(seq);
      if (this.firstSeq === from) return held();
    }
  }

  /// Pages older transcript events in without reattaching, so the live summary,
  /// queue and permission stay as they are. A page that lands after the
  /// selection changed belongs to another session and is dropped.
  /// `through`: read on until the record at that seq is held (a rail jump, `loadThrough`), not only
  /// until an older turn starts. `fill`: the held rows do not fill the view; the read lands with the
  /// first page that starts an older turn. `rising`: the reader is scrolling up now (the transcript's
  /// OlderAhead); only then does a read ask for the big page (OLDER_PAGE_BYTES) and read pages ahead. `ahead`: the
  /// transcript's own read-ahead asks (VirtualTranscript `checkOlder`), not the reader or a command (`chat.history`).
  loadOlder(through?: number, fill = false, rising = false, ahead = false): Promise<void> {
    // A chat on the store pages from it.
    if (this.selectedSessionId && this.chatRows.holds(this.selectedSessionId))
      return Promise.resolve(void this.chatRows.page(this.selectedSessionId));
    if (!this.canPageOlder()) return Promise.resolve();
    // A view that follows the latest row reads back none of what a shed let go of while it followed: the page brought
    // the shed records back, the next streamed record shed them again, and each page refolded the held window (about
    // 7 a second at 60 chunks and 2,000 lines a second, a third of the main thread). The shed keeps the rows in view
    // (`setKeepFrom`); a scroll up stops following and reads them again. Only the transcript's read-ahead is declined:
    // a rail jump or find (`through`) and an explicit ask (`chat.history`) still read.
    if (ahead && this.following && this.shedFollowingGeneration === this.selectionGeneration) return Promise.resolve();
    if (this.loadingOlder) return this.loadingOlder;
    // An ask inside the back-off after a failed page waits it out, then reads. One that returned
    // at once read nothing, and the transcript that asked at the very top had no scroll left to
    // ask again with: a 720-turn chat stopped paging for good (Leo 2026-10-21).
    const wait = this.olderRetryAt - Date.now();
    const generation = this.selectionGeneration;
    const pagingEpoch = this.olderPagingEpoch;
    const read =
      wait > 0
        ? this.olderDelay
            .wait(wait)
            .then((ready) =>
              ready && this.canPageOlder(pagingEpoch) && generation === this.selectionGeneration
                ? this.fetchOlder(pagingEpoch, through, fill, rising)
                : undefined,
            )
        : this.fetchOlder(pagingEpoch, through, fill, rising);
    const loading = read
      .catch((error: unknown) => {
        if (this.canPageOlder(pagingEpoch) && generation === this.selectionGeneration)
          this.olderRetryAt = Date.now() + 2_000;
        throw error;
      })
      .finally(() => {
        if (this.loadingOlder === loading) this.loadingOlder = undefined;
      });
    this.loadingOlder = loading;
    return loading;
  }
  /// Older pages read ahead of the reader (`readOlderAhead`), by the `beforeSeq` each was asked with, for
  /// the chat, visit, held history and paging epoch they were read in (`olderKey`).
  private olderAhead?: { key: string; pages: Map<number, Promise<any>> };
  /// The records an older page read but did not land (`fetchOlder` keeps whole turns, so the end
  /// of a turn further back waits): `before` is the oldest seq read, `from` the held records' first
  /// seq they end at. The next ask reads on from `before` and lands them with its page, so no read
  /// asks again for records already read (and read-ahead chains from `before`).
  private olderCarry?: { key: string; before: number; from: number; events: EventRecord[] };
  /// The carried records for this chat's next older read, while they still end where the held ones
  /// begin; otherwise none.
  private olderCarryFor(sessionId: string, pagingEpoch: number) {
    const carry = this.olderCarry;
    return carry?.key === this.olderKey(sessionId, pagingEpoch) && carry.from === this.firstSeq ? carry : undefined;
  }
  private olderKey(sessionId: string, pagingEpoch: number): string {
    return `${sessionId}\u0000${this.selectionGeneration}\u0000${this.historyEpoch}\u0000${pagingEpoch}`;
  }
  /// The older page of `sessionId` that ends before `before`: the one read ahead for it, else a read.
  /// `rest`: the reader is not scrolling up, so a read asks for the rest page (OLDER_REST_PAGE_BYTES).
  private olderPage(sessionId: string, before: number, pagingEpoch: number, rest = false): Promise<any> {
    const ahead = this.olderAhead;
    const kept = ahead?.key === this.olderKey(sessionId, pagingEpoch) ? ahead.pages.get(before) : undefined;
    if (kept) {
      ahead!.pages.delete(before);
      return kept;
    }
    return this.typed("_acpmux/events", {
      sessionId,
      beforeSeq: before,
      limit: rest ? OLDER_REST_PAGE_RECORDS : OLDER_PAGE_RECORDS,
      maxBytes: rest ? OLDER_REST_PAGE_BYTES : OLDER_PAGE_BYTES,
      // acpmux's "transcript" leaves out the preset approval records (paging.rs): a card older
      // than the attach's page comes with the older page that holds it, on a local acpmux as at
      // attach (three kinds, within a remote cmux-tui's eight either way).
      kinds: ["transcript", ...(this.localOrigin ? PRESET_APPROVAL_KINDS : [])],
    });
  }
  /// Reads the next OLDER_AHEAD_PAGES older pages after an older read lands, one after another, and
  /// keeps them for the next ask (`olderPage`). A page that fails is dropped, and the ask reads it
  /// again. Another chat, visit, held history or paging epoch keys the kept pages out.
  private readOlderAhead(pagingEpoch: number): void {
    const sessionId = this.selectedSessionId;
    if (!sessionId || this.historyExhausted || !this.firstSeq || this.firstSeq <= 1 || !this.canPageOlder(pagingEpoch))
      return;
    const key = this.olderKey(sessionId, pagingEpoch);
    // Reuse only the next contiguous chain. Trimming a partial turn changes its cursor;
    // unrelated pages from previous chains must not accumulate across a long scroll.
    const previous = this.olderAhead?.key === key ? this.olderAhead.pages : undefined;
    const pages = new Map<number, Promise<any>>();
    const ahead = { key, pages };
    this.olderAhead = ahead;
    // Past the records already read and carried (`olderCarry`), where the next ask reads.
    let before = this.olderCarryFor(sessionId, pagingEpoch)?.before ?? this.firstSeq;
    void (async () => {
      for (let read = 0; read < OLDER_AHEAD_PAGES; read++) {
        if (this.olderAhead !== ahead || !this.canPageOlder(pagingEpoch)) return;
        const asked = before;
        const page = previous?.get(asked) ?? this.olderPage(sessionId, asked, pagingEpoch);
        pages.set(asked, page);
        let result: any;
        try {
          result = await page;
        } catch {
          if (pages.get(asked) === page) pages.delete(asked);
          return;
        }
        const events = records(result?.events);
        if (result?.hasMore !== true || events.length === 0 || events[0]!.seq >= asked) return;
        before = events[0]!.seq;
      }
    })();
  }
  /// The records from below `through` up to `from` (exclusive), newest page first, read at once: the
  /// stretch is cut into slots of OLDER_PAGE_RECORDS seqs, and each slot's page (the newest records
  /// before its top) is asked together, WINDOW_PARALLEL_PAGES at a time. A page reaches at least its
  /// slot's foot unless its byte cap ends it first; that gap is read page by page before the next
  /// slot's records are taken, so what comes back holds every record from its oldest page up.
  /// Undefined when the read went stale (another chat, visit, held history or paging epoch).
  private async readWindow(
    sessionId: string,
    from: number,
    through: number,
    pagingEpoch: number,
    stale: () => boolean,
  ): Promise<{ pages: EventRecord[][]; before: number; more: boolean } | undefined> {
    const pages: EventRecord[][] = [];
    let before = from;
    let more = true;
    const take = (result: any) => {
      const page = records(result?.events).filter((event) => event.seq < before);
      if (page.length > 0) {
        pages.push(page);
        before = page[0]!.seq;
      }
      more = result?.hasMore === true && page.length > 0;
      return page.length > 0;
    };
    // A slot's page the gap reads above already passed (they ran below its top past a byte cap)
    // holds nothing older than `before`; that says nothing of what is left below, so it is
    // skipped, and the next round reads on from `before`. Only an empty read at `before` ends it.
    const takeSlot = (result: any) => {
      if (records(result?.events).some((event) => event.seq < before)) take(result);
    };
    while (more && before > through && before > 1) {
      const slots: number[] = [];
      // Down to the first slot that starts at or below `through`: its page holds the records just
      // above the place, and usually the prompt of the turn the place is in.
      for (let top = before; slots.length < WINDOW_PARALLEL_PAGES && top > 1; top -= OLDER_PAGE_RECORDS) {
        slots.push(top);
        if (top <= through) break;
      }
      const results = await Promise.all(slots.map((top) => this.olderPage(sessionId, top, pagingEpoch)));
      if (stale()) return undefined;
      for (let slot = 0; slot < slots.length && more; slot++) {
        // The page above ended short of this slot (its byte cap): read the gap page by page.
        while (more && before > slots[slot]!) {
          const result = await this.olderPage(sessionId, before, pagingEpoch);
          if (stale()) return undefined;
          if (!take(result)) more = false;
        }
        // A slot read at `before` itself is the read that ends the window when it comes back empty.
        if (more) (slots[slot] === before ? take : takeSlot)(results[slot]);
      }
    }
    return { pages, before, more };
  }
  private canPageOlder(epoch = this.olderPagingEpoch): boolean {
    return !this.closed && epoch === this.olderPagingEpoch && this.socket?.readyState === WebSocket.OPEN;
  }
  private cancelOlderPaging(): void {
    this.olderPagingEpoch += 1;
    this.olderAhead = undefined;
    this.olderDelay.cancel();
    this.olderRetryAt = 0;
  }
  /// Whether the log holds records older than the held ones.
  private seqHistoryLeft(): boolean {
    return !this.historyExhausted && (this.firstSeq ?? 1) > 1;
  }

  /// Where the next older page of the chat's Claude Code transcript ends, once the log's own
  /// history is all held; undefined when there is none to read, or the daemon serves none.
  private nativeBefore(): number | undefined {
    if (!this.extensions.includes("_acpmux/native_history") || this.seqHistoryLeft()) return undefined;
    const next = this.nativeNext?.epoch === this.historyEpoch ? this.nativeNext.before : this.nativeSeed?.before;
    return next !== undefined && next > 0 ? next : undefined;
  }

  private async fetchOlder(
    pagingEpoch = this.olderPagingEpoch,
    through?: number,
    _fill = false,
    rising = false,
  ): Promise<void> {
    if (!this.canPageOlder(pagingEpoch)) return;
    if (this.selectedSessionId && !this.seqHistoryLeft() && this.nativeBefore() !== undefined)
      return this.fetchNativeOlder();
    if (!this.selectedSessionId || !this.firstSeq || this.firstSeq <= 1 || this.historyExhausted) return;
    const sessionId = this.selectedSessionId;
    const generation = this.selectionGeneration;
    const epoch = this.historyEpoch;
    // The prompt drawn first: the open turn's opener when the held events start mid-turn.
    const drawnFrom = this.turnOpener?.seq ?? this.firstSeq;
    const opensOlderTurn = (event: EventRecord) => startsTurn(event) && event.seq < drawnFrom;
    // Keep the target's preceding turn, including when byte caps end a page at the target prompt.
    const opensAbove = (event: EventRecord) => through !== undefined && startsTurn(event) && event.seq < through;
    const stale = () =>
      !this.canPageOlder(pagingEpoch) ||
      generation !== this.selectionGeneration ||
      this.selectedSessionId !== sessionId ||
      epoch !== this.historyEpoch;
    // Publish each page as soon as it arrives. A long active turn must not hide the first readable
    // older records behind a whole-turn scan. Records before the oldest older turn start finish a
    // turn further back and remain for the next bounded ask; on the final page there is no next
    // ask, so its prefix stays too (native adoption history can begin before its first prompt).
    // What the last ask read but left for this one (`olderCarry`): it lands with this ask's page.
    const key = this.olderKey(sessionId, pagingEpoch);
    let carried = this.olderCarryFor(sessionId, pagingEpoch);
    // Set only by a bench (bench/transcript-scroll-up.bench.ts SPLIT=1): each page's reply and fold, timed.
    const trace = typeof window === "undefined" ? undefined : window.__cmuxOlderTrace;
    const publish = (read: EventRecord[], pageMore: boolean) => {
      trace?.("fold", performance.now(), -1);
      publishPage(read, pageMore);
      trace?.("published", performance.now(), -1);
    };
    const publishPage = (read: EventRecord[], pageMore: boolean) => {
      const older = carried ? [...read, ...carried.events] : read;
      carried = undefined;
      this.olderCarry = undefined;
      // The open landed inside the turn on screen: the page holding its prompt makes it whole, and
      // the rest of a longer turn above it waits for the next ask (the user, 2026-11-03: a reply
      // starting mid-sentence under its prompt, and nothing above).
      const cutOpener =
        this.turnOpener && this.firstSeq !== undefined && this.turnOpener.seq < this.firstSeq
          ? this.turnOpener.seq
          : undefined;
      let start = pageMore ? older.findIndex(opensOlderTurn) : -1;
      if (start < 0 && pageMore && cutOpener !== undefined) start = older.findIndex((event) => event.seq >= cutOpener);
      const page = start > 0 ? older.slice(start) : older;
      if (page.length === 0) return;
      // The records left above the page were read: the next ask reads on past them, not again.
      if (start > 0)
        this.olderCarry = { key, before: older[0]!.seq, from: page[0]!.seq, events: older.slice(0, start) };
      // The held records start inside a turn, and this page brings that turn's start: refold it whole
      // once, so it draws as reading the whole record does. Pages inside the turn before it fold
      // incrementally (`foldOlder`), so a long turn costs one refold, not one per page.
      const completesCutTurn =
        this.events.length > 0 && !startsTurn(this.events[0]!) && page.some((event) => startsTurn(event));
      this.events = prependOlderEventRecords(page, this.events);
      this.sawPrompts(page);
      // A page exposing a forced result can establish a fence at a prompt already drawn below it.
      // Replay that boundary chronologically; merging rows cannot recover the held prompt's effect.
      const crossesStop = page.some(
        (event) =>
          event.dir === "mux" &&
          event.kind === "turn_result" &&
          event.msg?.cancelForced === true &&
          typeof event.msg?.turnId === "string",
      );
      if (
        !completesCutTurn &&
        !crossesStop &&
        this.compactionFenceSeq === undefined &&
        this.retiredCompactionTurnId === undefined
      )
        this.foldOlder(page);
      else this.rebuildKeepingLiveState();
      this.historyExhausted = false;
      this.emit("history");
    };
    let more = true;
    let before = carried?.before ?? this.firstSeq;
    let windowed = false;
    let foundThrough = through === undefined;
    // A rail jump far back reads the window down to its target at once (`readWindow`) and lands it.
    if (through !== undefined && through < before) {
      const window = await this.readWindow(sessionId, before, through, pagingEpoch, stale);
      if (!window || stale()) return;
      windowed = true;
      foundThrough = window.pages.some((page) => page.some(opensAbove));
      before = window.before;
      more = window.more;
      publish(window.pages.reverse().flat(), more);
    }
    // The reader asked for this (scrolling up, or a rail jump to a place): the big page, and pages ahead.
    const reading = rising || through !== undefined;
    // A page can draw nothing above the first row: a prompt queued with a big paste or image is a
    // page of its own, and every page of a long turn the open landed in is that turn's. Each ask
    // reads OLDER_PAGES_PER_ASK pages and moves `historyFrom`, which makes the transcript ask again.
    for (let pages = 0; more && pages < OLDER_PAGES_PER_ASK && (!windowed || !foundThrough); pages++) {
      if (!this.canPageOlder(pagingEpoch)) return;
      const result = await this.olderPage(sessionId, before, pagingEpoch, !reading);
      trace?.("reply", performance.now(), -1);
      if (stale()) return;
      const page = records(result?.events);
      const pageMore = result?.hasMore === true && page.length > 0 && page[0]!.seq < before;
      publish(page, pageMore);
      more = pageMore;
      if (page.length > 0) before = Math.min(before, page[0]!.seq);
    }
    this.historyExhausted = !more || (this.firstSeq ?? 1) <= 1;
    if (this.historyExhausted) this.emit("history");
    // Pages ahead only for a reader on the way up (or a rail jump): a chat at rest reads no 4 MiB it may never show.
    if (reading) this.readOlderAhead(pagingEpoch);
  }

  /// Pages older turns in from the chat's Claude Code transcript, past the newest page its log was
  /// seeded with (`nativeBefore`). acpmux sends them as the records adopting logs, numbered below 1
  /// (oldest first, the same numbers for the same cursor), so they sort above every logged record
  /// and stay out of the log's own bookkeeping: `seqHistoryLeft` is false once one is held. Records
  /// the pane already holds (a kept tail drew them) are dropped, and the read goes on to an older
  /// page. Each page is whole turns that end, so it folds above the held rows (`foldOlder`) and
  /// the transcript keeps the reader's place as for any older page.
  private async fetchNativeOlder(): Promise<void> {
    const sessionId = this.selectedSessionId!;
    const generation = this.selectionGeneration;
    const epoch = this.historyEpoch;
    let before = this.nativeBefore();
    let mark = this.nativeNext?.epoch === epoch ? this.nativeNext.mark : this.nativeSeed?.mark;
    // A kept tail cut inside a native turn holds that turn's end only (KEPT_EVENTS): the turn comes
    // again whole with its page, so the part held goes and the rows are drawn again.
    const cut = this.events[0] !== undefined && this.events[0].seq < 1 && this.events[0].kind !== "turn_started";
    const whole = cut ? this.events.find((event) => event.seq >= 1 || event.kind === "turn_started") : this.events[0];
    const heldFrom = whole?.seq ?? Infinity;
    let older: EventRecord[] = [];
    for (let pages = 0; before !== undefined && before > 0 && pages < NATIVE_PAGES_PER_ASK; pages++) {
      let result: any;
      try {
        result = await this.request("_acpmux/native_history", { sessionId, before, mark }, 15_000);
      } catch (error) {
        // An older daemon serves no pages, an older host relays none, a peer that serves none is
        // never asked, and a Web client may not read the transcript: the chat stops paging, as at
        // its first turn.
        const { code, reason } = (error ?? {}) as { code?: unknown; reason?: unknown };
        const unserved =
          code === METHOD_NOT_FOUND ||
          code === "transport.method_refused" ||
          reason === "transcriptRead.unsupported" ||
          reason === "transcriptRead.remote" ||
          reason === "transcriptRead.stale";
        if (!unserved) throw error;
        result = { events: [], before: 0 };
      }
      if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return;
      if (epoch !== this.historyEpoch) return;
      const page = records(result?.events).filter(
        (event) => typeof event?.seq === "number" && event.seq < 1 && event.seq < heldFrom,
      );
      older = [...page, ...older];
      const next = Number(result?.before);
      // A cursor moves back, or the transcript is done.
      before = Number.isFinite(next) && next > 0 && next < before ? next : 0;
      mark = typeof result?.mark === "string" ? result.mark : undefined;
      if (older.some(startsTurn)) break;
    }
    this.nativeNext = { epoch, before: before ?? 0, mark };
    if (cut) this.events = this.events.filter((event) => event.seq >= heldFrom);
    if (older.length > 0) {
      this.events = mergeEventRecords(older, this.events);
      this.sawPrompts(older);
    }
    if (cut) this.rebuildKeepingLiveState();
    else if (older.length > 0) this.foldOlder(older);
    this.emit("history");
  }

  /// Folds whole turns older than every held event into rows above them, without folding the held
  /// events again: the cost of a page stays the page's however much history is loaded. The fold
  /// starts from a clean turn and leaves the live state (an open turn, its stream and typing row,
  /// asks, commands, usage, prompts in flight) as the held events made it.
  private foldOlder(older: EventRecord[]): void {
    const live = {
      turnOpen: this.turnOpen,
      turnEndSeen: this.turnEndSeen,
      turnStartedAtMs: this.turnStartedAtMs,
      turnPromptAtMs: this.turnPromptAtMs,
      // The running turn's prompt is the held events', never an older page's.
      turnPrompt: this.turnPrompt,
      turnTokens: this.turnTokens,
      turnTokenSplit: this.turnTokenSplit,
      streamingAssistant: this.streamingAssistant,
      streamingAssistantMessageId: this.streamingAssistantMessageId,
      // The live reply's segment (`replySegment`): the page's chunks never take its place.
      streamingSegment: this.streamingSegment,
      assistantCut: this.assistantCut,
      streamingActivity: this.streamingActivity,
      planRow: this.planRow,
      progressRow: this.progressRow,
      progressSuperseded: this.progressSuperseded,
      messageRows: this.messageRows,
      toolRows: this.toolRows,
      toolRowScopes: this.toolRowScopes,
      currentToolScope: this.currentToolScope,
      planCalls: this.planCalls,
      subagents: this.subagents,
      summary: this.summary,
      queue: this.queue,
      pendingPermission: this.pendingPermission,
      waitingPermissions: this.waitingPermissions,
      pendingSecret: this.pendingSecret,
      groupedPermissions: this.groupedPermissions,
      openQuestions: this.openQuestions,
      heldEdits: this.heldEdits,
      usage: this.usage,
      forkedAtSeq: this.forkedAtSeq,
      optimisticPromptRows: this.optimisticPromptRows,
      promptRowKeys: this.promptRowKeys,
      optimisticPromptTexts: this.optimisticPromptTexts,
      promptAccepts: this.promptAccepts,
      compactionHeardAt: this.compactionHeardAt,
      runningTurnId: this.runningTurnId,
      stopTurnId: this.stopTurnId,
      // Older events never move the live compaction fence (loadOlder folds only pages that cannot set it).
      retiredCompactionTurnId: this.retiredCompactionTurnId,
      compactionFenceSeq: this.compactionFenceSeq,
      // A Send now still waiting for the cancel it causes is the live turn's, never the page's.
      interrupting: this.interrupting,
      awaiting: this.awaiting,
    };
    const held = new Map(this.rows);
    this.runningTurnId = undefined;
    this.turnOpen = false;
    this.turnEndSeen = false;
    this.turnStartedAtMs = undefined;
    this.turnPromptAtMs = undefined;
    this.turnPrompt = undefined;
    this.turnTokens = undefined;
    this.turnTokenSplit = undefined;
    this.lastReplyRow = undefined;
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
    this.streamingSegment = undefined;
    this.assistantCut = false;
    this.streamingActivity = undefined;
    this.planRow = undefined;
    this.progressRow = undefined;
    this.progressSuperseded = false;
    this.messageRows = new Map();
    this.toolRows = new Map();
    this.toolRowScopes = new Map();
    // An older page's records are older than every live turn: until the page's own prompt or turn
    // start sets it, the turn they belong to is unknown, never the live one.
    this.currentToolScope = undefined;
    this.planCalls = new Set();
    this.bgDoneTurns = new Map();
    this.subagents = new SubagentFold(this.subagentStops);
    // An older page replays persisted records too: seed the native roots as the full replay does.
    seedRoots(this.subagents, this.summary);
    this.groupedPermissions = new Map();
    this.waitingPermissions = new Map();
    this.openQuestions = new Set();
    this.heldEdits = new Set();
    // An older prompt never settles one still sending, however alike their text.
    this.optimisticPromptRows = new Map();
    this.promptRowKeys = new Map();
    this.optimisticPromptTexts = new Map();
    this.promptAccepts = new Map();
    this.compactionHeardAt = new Map();
    this.interrupting = undefined;
    this.awaiting = undefined;
    this.foldingBelow = this.firstSeq ?? Infinity;
    this.heldPromptRowKeys = live.promptRowKeys;
    this.presetApprovalRemoved.clear();
    const below = this.foldingBelow;
    let pageMade: readonly string[] | undefined;
    this.rows.beginPrepend(below);
    try {
      for (const event of [...older].sort((a, b) => a.seq - b.seq)) {
        this.firstSeq = Math.min(this.firstSeq ?? event.seq, event.seq);
        this.reduce(event);
      }
    } finally {
      // The rows the page made, read below instead of every row the chat holds.
      pageMade = this.rows.prependedRows();
      this.rows.endPrepend();
      this.foldingBelow = undefined;
      this.heldPromptRowKeys = undefined;
    }
    // A page can split a tool call: its completed update may have been held first, then the
    // older page brings the call opener. Keep the held row as the authoritative later state and
    // remove the page's duplicate item, while retaining page-only calls in the incremental fold.
    // `toolRows` is keyed by call id and is intentionally reset at every prompt. Capture every
    // page row before restoring the live map; adapters may reuse an id in several turns.
    const pageToolRows: { callId: string; rowId: string; item: AcpmuxActivity; scope?: string }[] = [];
    for (const rowId of new Set(pageMade)) {
      const row = this.rows.get(rowId);
      if (!row || held.has(rowId) || row.kind !== "activity") continue;
      for (const item of row.items ?? []) {
        if (item.tool) pageToolRows.push({ callId: item.tool.id, rowId, item, scope: this.toolRowScopes.get(rowId) });
      }
    }
    const pageMessageRows = new Map<string, string[]>();
    for (const [messageId, rowIds] of this.messageRows)
      pageMessageRows.set(
        messageId,
        rowIds.filter((rowId) => !held.has(rowId)),
      );
    this.timeTurnsOpenedAbove(below);
    this.sinceStale = true;
    // The held events' compactions take up the ones the page left open, in order, as reading the
    // whole record does (`compaction` above). One whose first record is a running note continues a
    // compaction the page left running, or noted as failed while it may go on (a forced Stop, or an
    // account switch's that runs between turns), if that was heard on time. One whose first record
    // already says how it ended found nothing open in the held events, so it ends the latest
    // compaction still open, however long after: the end goes on that row, where the compaction
    // started, and the held row goes, so a page further back takes nothing more for it.
    // How a held compaction's first record says it stands; undefined when that record is not held.
    const openedAs = (row: AcpmuxRow) => {
      const opening = this.events.find((event) => event.seq === row.seq);
      return opening ? compactionOf(sessionUpdate(opening))?.state : undefined;
    };
    const openRows = () =>
      this.rows
        .compactionRows()
        .filter(
          (row) => !held.has(row.id) && (row.compaction?.state === "running" || row.compaction?.inferred === true),
        );
    let continued = false;
    for (const next of [...held.values()]
      .filter((row) => row.kind === "compaction")
      .sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0))) {
      const opened = openedAs(next);
      if (opened === undefined) continue;
      if (opened === "running") {
        if (continued) continue;
        continued = true;
        const onTime = openRows()
          .filter((row) => row.turnId === undefined || next.turnId === undefined || row.turnId === next.turnId)
          .filter((row) => next.at - (this.compactionHeardAt.get(row.id) ?? -Infinity) <= COMPACTION_REPEAT_WINDOW)
          .sort((a, b) => (b.seq ?? 0) - (a.seq ?? 0));
        const [into, ...rest] = onTime;
        for (const row of rest) this.rows.delete(row.id);
        // It goes on where that compaction started, as the whole record draws it, so a page
        // further back still finds the earliest note it was heard at.
        if (into?.compaction && next.compaction) {
          const joined: AcpmuxRow = {
            ...into,
            version: Math.max(into.version, next.version) + 1,
            compaction:
              next.compaction.state === "running" ? stillRunning(into.compaction, next.compaction) : next.compaction,
          };
          const heard = live.compactionHeardAt.get(next.id);
          live.compactionHeardAt.delete(next.id);
          if (heard !== undefined) live.compactionHeardAt.set(into.id, heard);
          this.rows.mergeChanges(next.id, into.id, this.rows.orderOf(next.id));
          held.delete(next.id);
          this.rows.delete(next.id);
          // The held events' row now: what they said of it stands.
          held.set(into.id, joined);
          this.rows.set(into.id, joined);
        }
        continue;
      }
      const open = openRows()
        .filter((row) => row.turnId === undefined || next.turnId === undefined || row.turnId === next.turnId)
        .sort((a, b) => (b.seq ?? 0) - (a.seq ?? 0))[0];
      if (!open || !next.compaction) continue;
      this.rows.set(open.id, { ...open, version: open.version + 1, compaction: next.compaction });
      this.rows.mergeChanges(next.id, open.id, this.rows.orderOf(next.id));
      held.delete(next.id);
      this.rows.delete(next.id);
    }
    // One still running that nothing continued never said how it ended: noted as failed, as the
    // next turn's start would.
    for (const row of openRows())
      if (row.compaction?.state === "running")
        this.rows.set(row.id, {
          ...row,
          version: row.version + 1,
          compaction: { ...row.compaction, state: "failed", inferred: true },
        });
    // A background shell the held events saw end while its call was not loaded ends on that call's
    // row now that this page brought it, and its own row goes.
    for (const row of held.values())
      if (row.backgroundTask && this.markBackgroundCall(row.backgroundTask, row.at, this.rows.orderOf(row.id))) {
        held.delete(row.id);
        this.rows.delete(row.id);
      }
    // A fork older than every held event is only in this page.
    const forkedAtSeq = live.forkedAtSeq ?? this.forkedAtSeq;
    // The folded page's rows answer for their own messages: a `?message=<id>` link to a message
    // from before this page keeps finding its row (links.ts). The held events' entries win, since
    // they are the live turn's.
    const messageRows = new Map([...this.messageRows, ...live.messageRows]);
    // History brings ended agents absent from the live fold; preserve their progress without
    // replacing newer live values. This reconciliation runs only when loading an older page.
    for (const agent of this.subagents.all()) {
      if (!live.subagents.progressSource.has(agent.id)) live.subagents.progressSource.updateAgent(agent);
    }
    // Progress stays the live chat's latest plan; an older page's only when the live events hold none,
    // and then as ended, since a later turn came after it.
    const progressRow = live.progressRow !== undefined ? live.progressRow : this.progressRow;
    const progressSuperseded =
      live.progressRow !== undefined ? live.progressSuperseded : this.progressRow !== undefined;
    Object.assign(this, live, {
      forkedAtSeq,
      messageRows,
      progressRow,
      progressSuperseded,
      toolRowScopes: new Map(live.toolRowScopes),
      currentToolScope: live.currentToolScope,
    });
    // A message id is stable across streamed chunks. Join only the boundary pair (the last older
    // fragment to the first held fragment), preserving deliberate cuts within either side.
    for (const [messageId, pageIds] of pageMessageRows) {
      const liveIds = live.messageRows.get(messageId) ?? [];
      const pageId = [...pageIds].reverse().find((rowId) => this.rows.get(rowId)?.kind === "assistant");
      const liveId = liveIds.find((rowId) => this.rows.get(rowId)?.kind === "assistant");
      if (!pageId || !liveId || pageId === liveId) continue;
      const pageRow = this.rows.get(pageId);
      const liveRow = this.rows.get(liveId);
      if (!pageRow?.text || !liveRow?.text || pageRow.at > liveRow.at) continue;
      this.rows.set(liveId, {
        ...liveRow,
        version: Math.max(pageRow.version, liveRow.version) + 1,
        text: `${pageRow.text}${liveRow.text}`,
      });
      this.rows.delete(pageId);
      this.messageRows.set(
        messageId,
        (this.messageRows.get(messageId) ?? []).filter((rowId) => rowId !== pageId),
      );
    }
    // Index retained tools once. Paging must reconcile O(page tools) rows, never scan all retained
    // rows for every item (a 20k-row chat otherwise makes one page quadratic).
    const heldTools = new Map<string, { rowId: string; tool: NonNullable<AcpmuxActivity["tool"]>; scope?: string }[]>();
    for (const row of held.values())
      for (const entry of row.items ?? [])
        if (entry.tool) {
          const key = `${entry.tool.id}\u0000${this.toolRowScopes.get(row.id) ?? ""}`;
          const list = heldTools.get(key) ?? [];
          list.push({ rowId: row.id, tool: entry.tool, scope: this.toolRowScopes.get(row.id) });
          heldTools.set(key, list);
        }
    for (const { callId, rowId, item, scope } of pageToolRows) {
      const liveRowId = live.toolRows.get(callId);
      const pageTool = item.tool;
      if (!pageTool) continue;
      const compatible = (left: typeof pageTool | undefined, right: typeof pageTool | undefined) =>
        left?.title === right?.title ||
        left?.title === callId ||
        right?.title === callId ||
        (left?.command !== undefined && left.command === right?.command);
      const scopeMatches = (candidateScope: string | undefined) =>
        scope === undefined || candidateScope === undefined || scope === candidateScope;
      const candidates = [
        ...(liveRowId
          ? [
              {
                rowId: liveRowId,
                row: this.rows.get(liveRowId),
                tool: this.rows.get(liveRowId)?.items?.find((entry) => entry.tool?.id === callId)?.tool,
                scope: live.toolRowScopes.get(liveRowId),
              },
            ]
          : []),
        ...(heldTools.get(`${callId}\u0000${scope ?? ""}`) ?? []),
        ...(scope === undefined
          ? [...heldTools.entries()]
              .filter(([key]) => key.startsWith(`${callId}\u0000`))
              .flatMap(([, entries]) => entries)
          : []),
      ];
      const seenCandidates = new Set<string>();
      const match = candidates
        // Every candidate's row as it stands now: held rows stay in `rows` through the fold.
        .map((candidate) => ({
          ...candidate,
          row: this.rows.get(candidate.rowId),
          key: `${candidate.rowId}\u0000${candidate.tool?.id ?? callId}`,
        }))
        .filter((candidate) => {
          if (seenCandidates.has(candidate.key)) return false;
          seenCandidates.add(candidate.key);
          return true;
        })
        .find(
          ({ rowId: candidateId, row: candidateRow, tool, scope: candidateScope }) =>
            candidateId !== rowId &&
            candidateRow !== undefined &&
            tool !== undefined &&
            candidateRow.at >= (this.rows.get(rowId)?.at ?? 0) &&
            scopeMatches(candidateScope) &&
            compatible(pageTool, tool),
        );
      if (match) {
        const pageRow = this.rows.get(rowId);
        if (pageRow?.items) {
          const remaining = pageRow.items.filter((entry) => entry !== item);
          if (remaining.length === 0) this.rows.delete(rowId);
          else
            this.rows.set(rowId, {
              ...pageRow,
              version: pageRow.version + 1,
              items: remaining,
              toolCount: remaining.filter((entry) => entry.kind === "tool").length,
            });
        }
        const retainedRow = this.rows.get(match.rowId);
        if (retainedRow?.items) {
          const retainedItems = retainedRow.items.map((entry) => {
            if (entry.tool?.id !== callId) return entry;
            return {
              ...entry,
              tool: {
                ...withAwaitingCall(entry.tool, false),
                title: entry.tool.title === callId ? pageTool.title : entry.tool.title,
                kind: entry.tool.kind ?? pageTool.kind,
                inputSummary: entry.tool.inputSummary ?? pageTool.inputSummary,
                command: entry.tool.command ?? pageTool.command,
                description: entry.tool.description ?? pageTool.description,
                locations: entry.tool.locations ?? pageTool.locations,
                startedAt: entry.tool.startedAt ?? pageTool.startedAt,
              },
            };
          });
          this.rows.set(match.rowId, { ...retainedRow, version: retainedRow.version + 1, items: retainedItems });
        }
        this.toolRows.set(callId, match.rowId);
        continue;
      }
      if (!this.toolRows.has(callId)) this.toolRows.set(callId, rowId);
      if (scope !== undefined) this.toolRowScopes.set(rowId, scope);
    }
    // Older turns end on their own result; a row of the live turn it closed (its typing row) stays.
    // A model change line the page moved back (`drawRunChanges` dropped it) stays gone.
    // A preset approval card the page merged into an older one stays gone.
    for (const [id, row] of held)
      if (
        !this.rows.has(id) &&
        !this.presetApprovalRemoved.has(id) &&
        (row.kind !== "sessionStart" || this.runChangeRows.has(id))
      )
        this.rows.set(id, row);
    this.presetApprovalRemoved.clear();
    // A held page can start at a prompt sent now whose cancel only this page holds: its row,
    // drawn before, goes on with that turn now, so the turn never reads as stopped.
    for (const event of this.events) {
      const promptId = event.kind === "user_message" ? event.msg?.promptId : undefined;
      if (typeof promptId !== "string" || !this.continuations.has(promptId)) continue;
      const row = this.rows.get(this.promptRowKeys.get(promptId) ?? `user-${event.seq}`);
      if (row && !row.continues) this.rows.set(row.id, { ...row, continues: true, version: row.version + 1 });
    }
  }
  /// The socket's own onclose ignores a socket close() already let go of, so settle requests here.
  close(): void {
    this.raceListeners.clear();
    this.pendingPeerTrust = undefined;
    this.refusedPeerTrust = undefined;
    this.presence.detached();
    // Before anything is torn down: the chat on screen is still readable here, and a tab closing on
    // it should leave it warm for the next one. The host alone keeps it: this client is going away,
    // and a tail left in this page's map would be drawn by whatever client comes after it.
    this.rememberCurrentTail(false);
    this.chatRows.dispose();
    this.replayMode = false;
    this.fedMode = false;
    this.closed = true;
    this.toastSink = undefined;
    this.promptIndex?.cancel?.();

    clearTimeout(this.hiddenDraw);
    clearTimeout(this.otherChatsDraw);
    clearTimeout(this.stopStallTimer);
    this.stopStallTimer = undefined;
    this.stopStallOwed = undefined;
    this.stopQuietWatch();
    this.frameRequest?.cancel?.();
    this.frameRequest = undefined;
    this.cancelTrustStart?.();

    for (const gone of this.resendWaits.keys()) gone();
    // A prompt's slow and failed deadlines (sendNow) would fire on a closed client: emit to a pane
    // that is gone and look for a stall on a socket that is closed.
    for (const { timers } of this.deliveries.values()) timers.forEach(clearTimeout);
    this.cancelOlderPaging();
    const hold = this.snapshotHold;
    if (hold) clearTimeout(hold.timer);
    this.snapshotHold = undefined;
    hold?.release();
    // The rows and the cursor they are current to, for this page's next client of the connection.
    this.sessionPages.keep();
    this.sessionPages.stop();
    clearTimeout(this.readAheadTimer);
    this.readAheadTimer = undefined;
    this.readAheadQueue = [];
    this.hoverReads.stop();
    this.shareOnRead.clear();
    clearTimeout(this.sessionReread);
    this.sessionReread = undefined;
    clearTimeout(this.peerRowsRead);
    this.peerRowsRead = undefined;
    clearTimeout(this.missingRecheck);
    this.missingRecheck = undefined;
    this.stopAfterSeq = undefined;
    this.stopSuperseded = false;
    this.stopOpenerSeen = false;
    this.stoppingEnded();
    this.stopPageListeners();
    if (this.reconnectTimer !== undefined) window.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    if (this.daemonLivenessTimer !== undefined) clearTimeout(this.daemonLivenessTimer);
    this.daemonLivenessTimer = undefined;
    this.permissions.disconnected();
    this.socket?.close();
    this.socket = undefined;
    this.rejectPending();
  }
  private stopPageListeners(): void {
    this.stopWantAll?.();
    this.stopWantAll = undefined;
    if (typeof document !== "undefined") document.removeEventListener("visibilitychange", this.showChanged);
    this.stopAttention?.();
    this.stopAttention = undefined;
    if (typeof window !== "undefined") {
      window.removeEventListener("pagehide", this.pageWentAway);
      window.removeEventListener("online", this.cameOnline);
    }
  }
  private rejectPending(): void {
    // The daemon's count went with the connection; busy retries waiting for their time stop here.
    this.budget.reset();
    for (const request of this.pending.values()) {
      if (request.timer) clearTimeout(request.timer);
      // The timeout code stays (git writes, checkpoints and permissions read it); `reason` tells a
      // closed connection from a deadline (conversation/backgroundNotice.ts).
      request.reject(
        Object.assign(new Error(translate("error.interrupted")), {
          code: "native.timed_out",
          origin: "native",
          reason: "interrupted",
          // The connection went, not the request's own time (`lostPrompt.ts`).
          interrupted: true,
        }),
      );
    }
    this.pending.clear();
    this.waitingRequests = 0;
    this.daemonWaitingSince = undefined;
    this.daemonProbe = undefined;
    if (this.daemonLivenessTimer !== undefined) clearTimeout(this.daemonLivenessTimer);
    this.daemonLivenessTimer = undefined;
  }
}

/// The params field that carries a pick's gesture ticket, or nothing without one.
/// Reserves the person's current gesture for one prompt. A page or script without a trusted
/// AppKit event gets no ticket; the host's normal gesture check then refuses its send.
/// The newest chat-bound send tickets a client remembers (`boundSendTickets`); a send takes its own.
/// A local dispatch fence proves this frame never reached the wire; held-send cleanup may
/// therefore release its Cloud turn claim, unlike an ambiguous connection failure.
function staleContinuation(): Error & { code: string } {
  return Object.assign(new Error(translate("error.notOpen")), { code: "transport.continuation_changed" });
}

const BOUND_SEND_TICKETS_KEPT = 16;

const reservePromptGesture = (promptId: string, sessionId?: string): Promise<string | undefined> => {
  try {
    return postNative<{ ticket?: string }>("transport.gesture", {
      intent: { method: "session/prompt", params: { promptId, ...(sessionId ? { sessionId } : {}) } },
    }).then(
      (reply) => reply?.ticket,
      () => undefined,
    );
  } catch {
    // Tests and non-webview callers have no native host. They still send through the normal
    // relay path; the absent ticket leaves the host's gesture guard in force.
    return Promise.resolve(undefined);
  }
};

const gestureMeta = (ticket?: string) => (ticket ? { _meta: { cmuxGesture: ticket } } : {});

/// Why acpmux says a harness will not start: its launcher check, else its failed model probe.
/// A prompt acpmux refused because the session's folder has no Trust answer (`trust_gate.rs`).
/// A failed prompt row's prompt, kept by a Trust replay (``failedPromptCopies``).
export type FailedPromptCopy = {
  rowId: string;
  input: string;
  attachments: ComposerAttachment[];
  promptId?: string;
};

export function isTrustRefusal(error: unknown): boolean {
  // The reasons acpmux's trust gate writes (trust_gate.rs; checked against trust_gate.json).
  const reason = (error as { reason?: unknown } | null)?.reason;
  return reason === "trust.pending" || reason === "trust.untrusted";
}

/// What a trust refusal names: its reason and the folder acpmux asks about.
export type TrustRefusal = { reason: "trust.pending" | "trust.untrusted"; cwd?: string };
/// The pane's handler of every trust refusal (`AcpmuxDirectClient.onTrustRefused`).
export type TrustRoute = (refusal: TrustRefusal, again?: () => void, declined?: () => void) => void;

export function trustRefusal(error: unknown): TrustRefusal | undefined {
  if (!isTrustRefusal(error)) return undefined;
  const fields = error as { reason: TrustRefusal["reason"]; cwd?: unknown };
  return {
    reason: fields.reason,
    ...(typeof fields.cwd === "string" && fields.cwd ? { cwd: fields.cwd } : {}),
  };
}

export function harnessRefusal(entry: { unavailable?: unknown; probeError?: unknown } | undefined): string | undefined {
  for (const reason of [entry?.unavailable, entry?.probeError]) if (typeof reason === "string" && reason) return reason;
  return undefined;
}

const FOLDER_STATES = ["enabled", "needs-enable", "needs-trust", "error"] as const;

/// The folder profiles of a `_acpmux/harnesses {cwd}` reply (`folderProfiles`) as catalog entries.
/// An entry without an id, a folder or a known state is dropped.
export function normalizeFolderProfiles(value: any): AcpmuxSnapshot["catalog"] {
  const profiles: any[] = Array.isArray(value?.folderProfiles) ? value.folderProfiles : [];
  return profiles.flatMap((profile) => {
    const id = typeof profile?.id === "string" ? profile.id : "";
    const folder = typeof profile?.folder === "string" ? profile.folder : "";
    const state = FOLDER_STATES.find((candidate) => candidate === profile?.state);
    if (!id || !folder || !state) return [];
    const first = Array.isArray(profile.diagnostics) ? profile.diagnostics[0] : undefined;
    const diagnostic =
      typeof first === "string" ? first : typeof first?.message === "string" ? first.message : undefined;
    return [
      {
        id,
        name: typeof profile.displayName === "string" && profile.displayName ? profile.displayName : id,
        models: Array.isArray(profile.models) ? profile.models.map((model: unknown) => catalogModel(model)) : [],
        ...(typeof profile.family === "string" && profile.family ? { family: profile.family } : {}),
        ...(typeof profile.icon === "string" && profile.icon ? { icon: profile.icon } : {}),
        folder: {
          folder,
          ...(typeof profile.path === "string" ? { path: profile.path } : {}),
          state,
          ...(diagnostic ? { diagnostic } : {}),
        },
      },
    ];
  });
}

/// A `session/new` acpmux refused because the chat's folder profile is not enabled yet
/// (`harness.needs_enable`) or its folder has no Trust answer (`harness.needs_trust`).
export type HarnessBlock = {
  reason: "needs-enable" | "needs-trust";
  harness: string;
  folder: string;
};

export function harnessBlock(error: unknown): HarnessBlock | undefined {
  const data = (error as { data?: unknown } | null)?.data as
    | { reason?: unknown; harness?: unknown; folder?: unknown }
    | undefined;
  const reason =
    data?.reason === "harness.needs_enable"
      ? "needs-enable"
      : data?.reason === "harness.needs_trust"
        ? "needs-trust"
        : undefined;
  if (!reason || typeof data?.harness !== "string" || typeof data.folder !== "string") return undefined;
  return { reason, harness: data.harness, folder: data.folder };
}

/// Claude Code says it is still compacting every 30 seconds (2.1.305): a running note this soon
/// after a row's last one is that compaction going on; a later one is a new compaction.
const COMPACTION_REPEAT_WINDOW = 90_000;

/// A compaction's next running note on its row: what the row knew (a wrapper's reason), still running.
function stillRunning(prior: AcpmuxCompaction, next: AcpmuxCompaction): AcpmuxCompaction {
  const { inferred: _inferred, ...known } = prior;
  return { ...known, ...next };
}

/// A `compaction` update's state, sizes and, for a failed one, why; undefined for a state
/// acpmux does not send.
function compactionOf(update: any): AcpmuxCompaction | undefined {
  const state = update?.state;
  if (state !== "running" && state !== "completed" && state !== "failed") return undefined;
  const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);
  return {
    state,
    ...(typeof update.reason === "string" && update.reason ? { reason: update.reason } : {}),
    ...(state === "failed" && typeof update.error === "string" && update.error.trim()
      ? { error: update.error.trim() }
      : {}),
    ...(count(update.preTokens) !== undefined ? { preTokens: count(update.preTokens) } : {}),
    ...(count(update.postTokens) !== undefined ? { postTokens: count(update.postTokens) } : {}),
  };
}

/// A `background_task_update`'s shell and how it ended; undefined when it names neither.
/// A `session_offer` record's offer, or undefined when it lacks an id, title, prompt or folder.
function sessionOffer(msg: any): AcpmuxSessionOffer | undefined {
  const field = (key: string) => (typeof msg?.[key] === "string" ? (msg[key] as string) : "");
  const [offerId, title, prompt, cwd] = ["offerId", "title", "prompt", "cwd"].map(field);
  if (!offerId || !title || !prompt || !cwd) return undefined;
  return {
    offerId,
    title,
    prompt,
    cwd,
    worktree: msg.worktree === true,
    ...(field("harness") ? { harness: field("harness") } : {}),
    ...(field("model") ? { model: field("model") } : {}),
    ...(field("groupId") ? { groupId: field("groupId") } : {}),
  };
}

/// The started offer a `user_message` brings the result of (`_meta.provenance`, kind
/// `offer_result`), or undefined for any other prompt.
function offerResult(msg: any): AcpmuxOfferResult | undefined {
  const provenance = msg?._meta?.provenance;
  if (provenance?.kind !== "offer_result") return undefined;
  const [offerId, childSessionId, title] = [provenance.offerId, provenance.childSessionId, provenance.title];
  if (typeof offerId !== "string" || typeof childSessionId !== "string" || typeof title !== "string" || !title)
    return undefined;
  return { offerId, childSessionId, title };
}

/// A background shell's update: running in the background, or how it ended.
type BackgroundUpdate = Omit<AcpmuxBackgroundTask, "state"> & {
  state: AcpmuxBackgroundState["state"];
};

export function backgroundTask(update: any, at?: number): BackgroundUpdate | undefined {
  const state = update.state;
  if (typeof update.toolCallId !== "string" || !["running", "completed", "failed", "stopped"].includes(state))
    return undefined;
  const ownerId =
    typeof update.ownerId === "string"
      ? update.ownerId
      : typeof update.subagentSessionId === "string"
        ? update.subagentSessionId
        : typeof update.subagent === "string"
          ? update.subagent
          : typeof update?._meta?.acpmux?.subagent === "string"
            ? update._meta.acpmux.subagent
            : undefined;
  const ownerTitle =
    typeof update.ownerTitle === "string"
      ? update.ownerTitle.trim()
      : typeof update.subagentTitle === "string"
        ? update.subagentTitle.trim()
        : undefined;
  const startedAt = typeof update.startedAt === "number" ? update.startedAt : undefined;
  const endedAt = state === "running" ? undefined : typeof update.endedAt === "number" ? update.endedAt : at;
  return {
    toolCallId: update.toolCallId,
    command: typeof update.command === "string" ? update.command : "",
    ...(ownerId ? { ownerId } : {}),
    ...(ownerTitle ? { ownerTitle } : {}),
    ...(typeof update.description === "string" && update.description.trim()
      ? { description: update.description.trim() }
      : {}),
    ...(startedAt !== undefined ? { startedAt } : {}),
    ...(endedAt !== undefined ? { endedAt } : {}),
    state,
    ...(typeof update.reason === "string" && update.reason ? { reason: update.reason } : {}),
    ...(typeof update.summary === "string" && update.summary ? { summary: update.summary } : {}),
    ...(Number.isInteger(update.exitCode) ? { exitCode: update.exitCode as number } : {}),
  };
}

/// An ACP `plan` update's entries as a todo list; an entry without text is left out.
function planEntries(entries: unknown): AcpmuxPlanEntry[] {
  if (!Array.isArray(entries)) return [];
  return entries.flatMap((entry) => {
    const content = typeof entry?.content === "string" ? entry.content.trim() : "";
    if (!content) return [];
    const status = entry.status === "completed" || entry.status === "in_progress" ? entry.status : "pending";
    return [{ content, status }];
  });
}

/// One `_acpmux/models` entry: id and name, plus the metadata a declared profile model carries.
export function catalogModel(model: any): AcpmuxSnapshot["catalog"][number]["models"][number] {
  const entry: AcpmuxSnapshot["catalog"][number]["models"][number] = {
    id: String(model?.id ?? model?.modelId),
    name: typeof model?.name === "string" ? model.name : undefined,
  };
  if (typeof model?.unavailable === "string") entry.unavailable = model.unavailable;
  for (const key of ["curated", "declared"] as const) if (typeof model?.[key] === "boolean") entry[key] = model[key];
  for (const key of ["shortName", "family", "defaultEffort"] as const)
    if (typeof model?.[key] === "string" && model[key]) entry[key] = model[key];
  if (Array.isArray(model?.efforts))
    entry.efforts = model.efforts.filter((value: unknown) => typeof value === "string");
  if (typeof model?.fast === "boolean") entry.fast = model.fast;
  if (Number.isInteger(model?.contextWindow) && model.contextWindow > 0) entry.contextWindow = model.contextWindow;
  return entry;
}

/// A harness map's entries in acpmux's order: its default (`defaultHarness`) first, then by id. The
/// native relay re-encodes the reply, so the map's own key order means nothing (a first launch
/// asked the model router instead of Claude Code).
function harnessEntries(harnesses: Record<string, unknown>, preferred: unknown): any[] {
  const ids = Object.keys(harnesses).sort((a, b) =>
    a === preferred ? -1 : b === preferred ? 1 : a < b ? -1 : a > b ? 1 : 0,
  );
  return ids.map((id) => ({ id, ...(harnesses[id] as any) }));
}

/// `_acpmux/harnesses` `start` ({model?, effort?, modelSource?, effortSource?}), with only its
/// known fields.
function harnessStart(value: unknown): AcpmuxSnapshot["catalog"][number]["start"] {
  if (!value || typeof value !== "object") return undefined;
  const { model, effort, modelSource, effortSource } = value as Record<string, unknown>;
  const source = (raw: unknown) =>
    raw === "saved" || raw === "profile" || raw === "catalog" ? (raw as StartSource) : undefined;
  const start = {
    ...(typeof model === "string" && model ? { model } : {}),
    ...(typeof effort === "string" && effort ? { effort } : {}),
    ...(source(modelSource) ? { modelSource: source(modelSource) } : {}),
    ...(source(effortSource) ? { effortSource: source(effortSource) } : {}),
  };
  return start.model || start.effort ? start : undefined;
}

export function normalizeCatalog(value: any): AcpmuxSnapshot["catalog"] {
  const harnesses = value?.harnesses ?? value?.items ?? value ?? [];
  const entries: any[] = Array.isArray(harnesses) ? harnesses : harnessEntries(harnesses, value?.defaultHarness);
  const catalog = entries.map(catalogEntry);
  // Every AgentMark given a harness id draws its icon (shared/harnessIcons.ts).
  rememberHarnessIcons(catalog);
  return catalog;
}

function catalogEntry(harness: any): AcpmuxSnapshot["catalog"][number] {
  const iconSpec = parseHarnessIconSpec(harness.iconSpec);
  return {
    id: String(harness.id ?? harness.name),
    name: agentName(
      String(harness.id ?? harness.name),
      typeof harness.displayName === "string" && harness.displayName
        ? harness.displayName
        : harness.name == null
          ? undefined
          : String(harness.name),
    ),
    models: (harness.models ?? []).map((model: any) => catalogModel(model)),
    ...(typeof harness.kind === "string" ? { kind: harness.kind } : {}),
    ...(typeof harness.family === "string" && harness.family ? { family: harness.family } : {}),
    ...(typeof harness.icon === "string" && harness.icon ? { icon: harness.icon } : {}),
    ...(iconSpec ? { iconSpec } : {}),
    // Terminals and model routers are not chat harness choices. A real launcher can still have
    // a cmux-prefixed ID: only the declared kind determines whether it belongs in the picker.
    // acpmux's `pickerHidden`: the cmux model router profile, Claude's automatic fallback.
    ...(harness.kind === "terminal" || isModelRouterKind(harness.kind) || harness.pickerHidden === true
      ? { pickable: false }
      : {}),
    ...(harnessStart(harness.start) ? { start: harnessStart(harness.start) } : {}),
    // Its chats report no permission modes (`reported`): a new chat on it draws no Mode chip.
    ...(reportsNoModes(harness.reported) ? { modeless: true as const } : {}),
    // Its chats (or its startup probe) report permission modes: a new chat holds its Mode chip.
    ...(reportsModes(harness.reported) ? { reportsModes: true as const } : {}),
    ...(typeof harness.auth?.login === "string" && harness.auth.login.trim()
      ? { auth: { login: harness.auth.login.trim() } }
      : {}),
    // Why acpmux will not start it, when it says: its launcher check (`unavailable`), else its
    // failed model probe (`probeError`).
    ...(harnessRefusal(harness) ? { unavailable: harnessRefusal(harness) } : {}),
    ...(!harness.unavailable && harnessRefusal(harness) ? { probeFailed: true } : {}),
  };
}

/// Whether the person can see the page: WebKit reports `hidden` for a web view out of its window,
/// hidden, or in an occluded window.
/// The prompt a turn runs for: acpmux's continuation `P~resume-n` of a cut turn is `P`'s
/// (hub/auto_resume.rs `SUFFIX`).
export function promptRoot(promptId: string): string {
  return promptId.replace(/~resume-\d+$/, "");
}

/// A row's `transcriptSeq` (acpmux `SessionSummary::transcript_seq`), or undefined from an acpmux
/// that does not send it.
function transcriptSeq(session: Session | undefined): number | undefined {
  const seq = session?.transcriptSeq;
  return typeof seq === "number" && Number.isFinite(seq) ? seq : undefined;
}

function pageShown(): boolean {
  return typeof document === "undefined" || document.visibilityState !== "hidden";
}

/// Whether the reader sees the chat: the page shows and their hand was on it lately (attention.ts).
/// What acpmux hears as `visible`, so a turn that ends while they are away is unread.
function readerHere(): boolean {
  return pageShown() && (pageAttention()?.present() ?? true);
}

/// JSON-RPC's method-not-found code: a daemon that predates the method.
const METHOD_NOT_FOUND = -32601;

/// Methods the pane's host refused because they are not on its allowlist, said once each.
const notAllowlisted = new Set<string>();
/// A page request the host refuses as `transport.method_refused` is missing from its allowlist
/// (AcpmuxPaneMethods.swift and cmux-agent-pane-policy policy.json): a bug, not a user error. Say
/// so once per method in the console, so a missing entry never fails silently.
function warnIfNotAllowlisted(method: string, error: unknown): void {
  if (!(error instanceof AcpmuxRpcError) || !refusedByHost(error) || error.code !== "transport.method_refused") return;
  if (notAllowlisted.has(method)) return;
  notAllowlisted.add(method);
  console.warn(`cmux: the host refused ${method}: it is not on the agent pane's relay allowlist`);
}

/// Whether `notification` is one the app's host made, not the daemon: its question key requests
/// (`_cmux/*`, AgentPaneTransport+QuestionKeys.swift) and the lag notice it writes when its own queue
/// to the page fills (AcpmuxPaneShedding.swift, `host_queue_full`). Neither proves a daemon alive.
function hostNotification(notification: Notification): boolean {
  const method = notification.method;
  if (typeof method !== "string" || method.startsWith("_cmux/")) return true;
  return method === "_acpmux/lagged" && notification.params?.reason === "host_queue_full";
}

/// The host's refusals of the liveness probe's method itself (`probeAnswered`): no daemon saw it.
const probeRefusals = new Set(["remote.unsupported", "transport.method_refused", "native.unsupported"]);

/// Whether the pane's host refused to relay a request (`data.origin: "native"`): acpmux never saw it.
function refusedByHost(error: AcpmuxRpcError): boolean {
  const data = error.data && typeof error.data === "object" ? (error.data as Record<string, unknown>) : undefined;
  return data?.origin === "native";
}
