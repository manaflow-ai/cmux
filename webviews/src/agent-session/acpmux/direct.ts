import { UNKNOWN_AUTH, type SessionAuthQuery } from "./sessionAuth";
import { parseJsonObjectFrame } from "../../protocol/jsonFrame";
import { isRetryContinuation, subagentRetryNotice, type SubagentRetryNotice } from "./subagents/retryState";
import { isModelRouterKind } from "./routerKinds";
import type { SwitchPort } from "./harnessSwitch";
import { OlderPageDelay } from "./conversation/olderPageDelay";
import { answeredBy, participant, promptAuthor, type Participant } from "./multiplayer/participants";
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
  AcpmuxCompaction,
  AcpmuxContextBreakdown,
  AcpmuxPlanEntry,
  AcpmuxRow,
  AcpmuxSnapshot,
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
} from "./model";
import { continuesTurn } from "./turnStart";
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
import { fitPromptBudget } from "./promptBudget";
import { liftInlineImages } from "./inlineImages";
import { primeSentImages } from "./conversation/imageEntries";
import { resentAttachments, shownPrompt } from "./pastedText";
import { isFramesNote, withoutFrames } from "./composer/videoPrompt";
import { PeerStateEvents } from "./peerStateEvents";
import { peerConnectedFromStatus, peerKindsFromStatus, peerStatesFromStatus } from "./environments";
import { peerResourcesFromStatus } from "./machineResources";
import { type ChatUnavailable, chatUnavailable, type PeerStatus, peerStatusFromStatus } from "./chatUnavailable";
import { hostKind, sessionEntry, summaryActivityAt, text, type AcpmuxSessionEntry } from "./sessionList";
import { usageLimitsOf } from "./usageLimits";
import { clampRunning, subsessionLimits } from "./subsessionLimits";
import { agentName } from "./agents";
import { FORK_OP, servesOperation } from "./operations";
import { postNative } from "./native";
import {
  forgetTail,
  keptTail,
  KEPT_EVENTS,
  readHostTail,
  rememberReadAhead,
  rememberTail,
  shareReadAhead,
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
import { acpmuxPerf } from "./perf";
import { translate } from "./i18n";
import { OFFER_RESULT, offersShown } from "./offer/offersShown";
import { cliHost, incomingPrompt, type IncomingContext, type IncomingMessage } from "./conversation/incomingMessage";
import { inboxText, type InboxMessage } from "./conversation/inboxNotice";
import { startedCardsShown } from "./started/startedSessions";
import { OfferChildren } from "./offer/offerChildren";
import { errorMessage, startCancelled } from "./transportErrors";
import { failedSendText, retryHelps, sendCause } from "./sendFailure";
import { SessionPageError, SessionPager, type SessionPage } from "./sessionPages";
import { isWarmableCwd } from "./warmFolders";
import { isPlumbingCall, showsNothing } from "./hiddenTools";
import { SubagentFold, subagentsLeft, subagentStops, type SubagentStopReason } from "./subagents/subagentFold";
import { WORKSPACE_CONTEXT } from "./workspaceContext";
import { promptContext } from "./composer/videoTranscript";
import { promptSurfaceMeta } from "./surfaces/promptSurface";
import { BOOKMARKS_KIND, bookmarksHeard } from "./threadMinimap/bookmarks";
import { type StartMode, fullAccessTicket, rememberFullAccess, startModeChanged } from "./startMode";
import { harnessModeName, highestMode } from "./harnessModes";
import { sameSessionStart, sessionStartOf } from "./conversation/sessionStart";
import { reduceAgentPair } from "./conversation/agentPairs";
import { pasteRanges } from "./conversation/promptCollapse";
import { BACKGROUND_TURN, backgroundTurnRecord, backgroundTurnRowId } from "./conversation/backgroundTurns";
import { AskTracker, pendingReader, SIDE_SESSION_METHOD } from "./needsYou/asks";
import { chatTools, toolApplied, type ToolApplied } from "./summary/chatTools";
import { taskGoal } from "./goal";
import { shownPresence } from "./multiplayer/LivePresence";
import { PresenceClient } from "./multiplayer/presenceClient";
import { recordedConversationEvents } from "./conversation/exportEvents";
import {
  markPullRequestActivityVersion,
  markPullRequestCommandVersion,
  markTranscriptSummaryVersion,
  pullRequestRowKey,
} from "./summary/transcriptPullRequests";
import { parseHarnessIconSpec, rememberHarnessIcons } from "../shared/harnessIcons";
import { handoffPromptId, namesHandoffTurn } from "./cloudHandoffTurn";
import { STALL_CHECK_MS, stallLine } from "./stallLog";

export type AcpmuxHostConfig = {
  protocolVersion: number;
  /// `acpmux-bridge`: the app's host owns the socket and its tokens (bridgeSocket.ts); this page
  /// gets neither endpoint nor token. `acpmux-websocket`: a real socket, only for the browser dev
  /// slot (devHost.ts) and mock mode.
  transport: "acpmux-websocket" | "acpmux-bridge";
  endpoint?: string;
  token?: string;
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

export function newSessionParams(
  host: Pick<AcpmuxHostConfig, "cwd" | "adopt"> & { peer?: string },
  harness?: string,
  noProject = false,
  model?: string,
): Record<string, unknown> {
  if (host.adopt)
    return {
      mcpServers: [],
      _meta: { acpmux: { harness: harness ?? host.adopt.harness, adopt: host.adopt } },
    };
  return {
    ...(host.cwd ? { cwd: host.cwd } : {}),
    mcpServers: [],
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

/// A hint that a harness is likely next, so acpmux can warm its adapter (cmux-tui acpmux lane).
export const PREWARM_METHOD = "_acpmux/prewarm";
/// Reconnects a Claude Code chat's MCP server (reconnectMcp); listed in `initialize` where served.
export const MCP_RECONNECT_METHOD = "_acpmux/mcp/reconnect";

/// Most reads of a chat's running limit one step makes when each is overtaken in flight
/// (`readRunningLimit`): enough for an attach and a record landing together, never a loop.
const LIMIT_READS = 3;
/// The slash commands are not transcript, so the pane asks for their updates by kind.
const COMMANDS_KIND = "available_commands_update";
/// How many withdrawn queue prompts a snapshot names (`queueWithdrawn`).
const QUEUE_WITHDRAWN_KEPT = 16;
/// How much of the context window the session has used; not transcript, so attach asks for it by kind.
const USAGE_KIND = "usage_update";
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
const tokenCount = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0);
/// A marked call's split: its output (`callOutputTokens`) apart from what it read, the fresh input,
/// cache reads and cache writes acpmux sends beside it (claude_stdio/inbound.rs). Unset for a call
/// that names no output or no input (an older acpmux).
function callTokenSplit(update: any, output: number | undefined): TurnTokenSplit | undefined {
  if (output === undefined || typeof update?.inputTokens !== "number") return undefined;
  return {
    output,
    input: tokenCount(update.inputTokens),
    cacheRead: tokenCount(update.cachedReadTokens),
    cacheWrite: tokenCount(update.cachedWriteTokens),
  };
}
/// A `turn_result`'s tokens (acpmux hub/turn_usage.rs: Claude Code's main loop for the turn), when
/// it names its output and has any (an all-zero result is an empty turn, with nothing to show).
function resultTokenSplit(msg: any): TurnTokenSplit | undefined {
  if (typeof msg?.outputTokens !== "number") return undefined;
  const split = {
    output: tokenCount(msg.outputTokens),
    input: tokenCount(msg.inputTokens),
    cacheRead: tokenCount(msg.cacheReadTokens),
    cacheWrite: tokenCount(msg.cacheWriteTokens),
  };
  return split.output + split.input + split.cacheRead + split.cacheWrite > 0 ? split : undefined;
}
const addSplit = (sum: TurnTokenSplit, call: TurnTokenSplit): TurnTokenSplit => ({
  output: sum.output + call.output,
  input: sum.input + call.input,
  cacheRead: sum.cacheRead + call.cacheRead,
  cacheWrite: sum.cacheWrite + call.cacheWrite,
});
const NO_TOKENS: TurnTokenSplit = { output: 0, input: 0, cacheRead: 0, cacheWrite: 0 };
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
/// The agent's own change of a config option (a reasoning level, a model): the whole option list.
const CONFIG_KIND = "config_option_update";
const SESSION_INFO_KIND = "session_info_update";
/// The chat's one session start row (conversation/SessionStartNote.tsx).
const SESSION_START_ROW = "session-start";
/// A record that opens a turn: older pages split before one, so each holds whole turns. A steer
/// joins the running turn, so it opens none.
/// The snapshot's `earlierPrompts` when there are none: one list, so the rail's memo holds.
const NO_EARLIER_PROMPTS: readonly AcpmuxRow[] = [];

const startsTurn = (event: EventRecord) =>
  event.dir === "mux" && event.kind === "user_message" && event.msg?.steer !== true;

/// A prompt the Chief sent a subagent (its task, a tell, a steer, a restart or interrupt message):
/// optchat-chief ids those `optchat-<kind>:…` (`subagents.rs` PROMPT_PREFIX), so the pane can say
/// who wrote it rather than draw it as the reader's own. The Chief's own turns (`optchat:…`, the
/// person's messages it forwards) and typed prompts are not marked.
const sentByChief = (msg: { promptId?: unknown }) =>
  typeof msg.promptId === "string" && msg.promptId.startsWith("optchat-");

/// Page size caps acpmux applies (maxBytes): opening a chat, then each older page as the reader scrolls up.
const OPEN_PAGE_BYTES = 128 * 1024;
const OLDER_PAGE_BYTES = 256 * 1024;
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
type SentAttach = { attaching: Promise<any>; reads?: AttachReads };
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

/// A settled promise's value, unread: the race waits on the settling only.
const ignore = () => undefined;

/// The session row an attach reply carries, when it is `sessionId`'s on this machine. A reply
/// acpmux forwarded from a peer names that peer at its top level (`server/peer_forward.rs`), and
/// its `session` is the peer daemon's own detail, with no `peer`: either name makes it another
/// machine's chat.
export function attachedLocalRow(result: unknown, sessionId: string): Session | undefined {
  const reply = result as { session?: unknown; peer?: unknown } | undefined;
  const row = reply?.session as Session | undefined;
  if (!row || typeof row !== "object" || row.sessionId !== sessionId) return undefined;
  return typeof row.peer === "string" || typeof reply?.peer === "string" ? undefined : row;
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
/// Pages one older read takes at most while none of them has started a turn older than the first
/// prompt drawn (about 32 MB, more when a single record is larger). An open that lands in the middle
/// of a long turn, as after a restart, draws that turn's prompt first, and nothing can show above it
/// until the turn's start is read: a read capped at a few pages left the reader asking again and
/// again with nothing new at the top, each ask replaying the whole transcript (Leo 2026-10-29: "I
/// can't fucking scroll up past the current fucking turn after restarting"). The bound keeps one
/// read from walking a whole log when a single turn is larger than this.
const OLDER_PAGES_PER_ASK = 128;
/// Pages one older read takes at least, published together so each prepend does not redraw the
/// bottom stack; once one of them starts a turn older than the first prompt drawn, the read stops here.
const OLDER_MIN_PAGES_PER_ASK = 4;
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
/// An agent's secret card and its answer (cx-ncc.42): not transcript, so attach asks for them by kind.
const SECRET_KINDS = ["secret_request", "secret_decision"];
/// The promptId acpmux gives a task result's prompt: `offer-result-<offerId>` (hub/offers.rs).
const OFFER_RESULT_PROMPT = "offer-result-";
/// A queued prompt sent now (`queue_order` `next`) or edited (`queue_updated`): not transcript in
/// acpmux (`paging.rs`), so attach asks for them by kind, or the queue never hears either live.
/// `prompt_refused`: acpmux refused a prompt sent now at dispatch (hub/web_control.rs), after it left the
/// queue; it is not a transcript record, so the pane asks for it by name.
const QUEUE_KINDS = ["queue_order", "queue_updated", "prompt_refused"];
/// acpmux's sub-session records (hub/subsessions.rs `RECORD_KIND`): a child started or ended, and
/// the chat's `limits` changing.
const SUBSESSION_KIND = "subsession";
/// acpmux's bracket around a turn the agent ran on its own (conversation/backgroundTurns.ts).
const BACKGROUND_TURN_KIND = "background_turn";
/// acpmux's refusals of an answer to a card it no longer has (hub/secrets.rs): a restart lost it,
/// or the agent stopped waiting.
const SECRET_GONE = ["no secret request with that id", "the agent stopped waiting"];

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
    diffs: permissionDiffs(toolCall),
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
): QueuedPrompt {
  return {
    id,
    prompt,
    ...(next ? { next } : {}),
    ...(sending ? { sending } : {}),
    ...(images?.length ? { images: [...images] } : {}),
    ...(message ? { message } : {}),
    ...(author ? { author } : {}),
    ...(inlineParts?.length ? { inlineParts } : {}),
    ...(retry && !message && !author ? { retry } : {}),
  };
}

/// `entry` with `from`'s Stop hold (`heldByStop`): an entry rebuilt from a record or a list keeps it
/// while it is still another agent's message. An edit makes it the person's (hub/queue_edit.rs), and
/// a person's Stop holds only other agents' messages.
function keepStopHold(entry: QueuedPrompt, from: QueuedPrompt | undefined): QueuedPrompt {
  return from?.heldByStop && !entry.heldByStop && entry.message ? { ...entry, heldByStop: true } : entry;
}

/// Whether listed chat `session` is the one `name` names: its name, its short name, or, for a chat
/// on another machine (listed as `<peer>/<name>`), its bare name, which its messages sign with.
function namesChat(session: Session, name: string): boolean {
  const listed = session.name?.trim();
  return (
    listed === name || session.shortName?.trim() === name || (!!session.peer && listed === `${session.peer}/${name}`)
  );
}

/// A `queued` record that is another agent's message, as its received line reads it once it runs
/// (conversation/incomingMessage.ts), else as acpmux's `fromAgent` names it (`acpmux send --from`),
/// its text without a leading "[name]" or "From name:" that only repeats the sender. Undefined for
/// the person's own prompt.
export function queuedMessage(msg: any, context?: IncomingContext): IncomingMessage | undefined {
  const text = String(msg?.text ?? "");
  const incoming = incomingPrompt(text, msg, context);
  if (incoming?.kind === "message") return incoming.message;
  const name = typeof msg?.fromAgent === "string" ? msg.fromAgent.trim() : "";
  if (!name) return undefined;
  const lead = text.trimStart();
  const named = [`[${name}]`, `From ${name}:`].find((prefix) => lead.toLowerCase().startsWith(prefix.toLowerCase()));
  const harness = typeof msg?.fromHarness === "string" && msg.fromHarness.trim() ? msg.fromHarness.trim() : undefined;
  return { name, ...(harness ? { harness } : {}), text: (named ? lead.slice(named.length) : text).trim(), raw: text };
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
function attachedImages(attachments: readonly ComposerAttachment[]): QueuedPromptImage[] {
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
export const deliveryTiming = { slowMs: 10_000, failMs: 60_000, localFailMs: 300_000 };

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
  const merged = listed.map((entry) => {
    const id = String(entry?.promptId ?? "");
    const preview = String(entry?.prompt ?? entry?.preview ?? "");
    const had = known.get(id);
    const whole = had !== undefined && oneLine(had.prompt).startsWith(preview.replace(/…$/, ""));
    // acpmux lists its images (after a reload or a restart too); one that lists none (an older
    // acpmux) keeps those the pane had.
    const images = Array.isArray(entry?.images) ? withKnownBytes(promptImages(entry.images), had?.images) : had?.images;
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
    const listedMessage = queuedMessage({
      ...entry,
      text: preview,
      fromAgent: listed,
      fromHarness: entry?.fromHarness,
    });
    const kept = whole ? had.message : undefined;
    // A queue listing may carry the full provenance even when its compatibility `fromAgent`
    // field is absent. Preserve that parsed agent message; only an explicit null says that the
    // prompt is the person's own. Without this, a queued agent_message was rendered as a plain
    // user prompt until it left the queue, so its received card (and reply actions) disappeared.
    const message = listed === null ? undefined : (kept ?? listedMessage);
    // A list that names the field says whose it is, null the owner's (acpmux lists it for every
    // prompt once it serves authors); an older acpmux lists none, and the records read decide.
    const author =
      entry && typeof entry === "object" && "author" in entry
        ? participant(entry.author?.id, entry.author?.name)
        : authors?.has(id)
          ? (authors.get(id) ?? undefined)
          : had?.author;
    const built = queuedEntry(
      id,
      whole ? had.prompt : preview,
      had?.next === true,
      false,
      images,
      message,
      author,
      recordedPromptParts(entry, had?.inlineParts) ?? had?.inlineParts,
      // A resume comes from acpmux's word only: the listing's `subagentRetry` (from the prompt's
      // `subagent_retry` provenance, which an edit drops), else, from an acpmux that lists none,
      // the one its `queued` record gave while the text is the same (the preview that text or cut
      // from it). An edit, seen or missed, drops it; a null listing removes it.
      message || author || edited?.has(id)
        ? undefined
        : "subagentRetry" in (entry ?? {})
          ? withRecovered(listedRetry(entry.subagentRetry), had?.retry)
          : whole && (preview.endsWith("…") || oneLine(had.prompt) === preview)
            ? had.retry
            : undefined,
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
    JSON.stringify(a.author) === JSON.stringify(b.author) &&
    JSON.stringify(a.inlineParts) === JSON.stringify(b.inlineParts) &&
    JSON.stringify(a.retry) === JSON.stringify(b.retry)
  );
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

export function mergeEventRecords(...batches: EventRecord[][]): EventRecord[] {
  const bySequence = new Map<number, EventRecord>();
  for (const event of batches.flat()) bySequence.set(event.seq, event);
  return [...bySequence.values()].sort((left, right) => left.seq - right.seq);
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
  const title = update.title ?? update.name;
  const status = String(update.status ?? before?.status ?? "in_progress");
  const ended = status === "completed" || status === "failed";
  const kind = update.kind ?? before?.kind;
  const locations = readLocations(update.locations) ?? before?.locations;
  // The input's file, from the update that carries the input.
  const input = update.rawInput ? inputPath(update) : before?.inputPath;
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
      inputSummary: update.rawInput ? JSON.stringify(update.rawInput) : before?.inputSummary,
      output:
        output || formattedOutput(update.rawOutput) || (update.content === undefined ? before?.output : undefined),
      command: shellCommand(update.rawInput) ?? before?.command,
      description: callDescription(update.rawInput) ?? before?.description,
      exitCode: exitCode(update.rawOutput) ?? before?.exitCode,
      startedAt: before?.startedAt ?? at,
      endedAt: before?.endedAt ?? (ended ? at : undefined),
      // A shell that went to the background stays there as its call's result comes in.
      ...(before?.background ? { background: before.background } : {}),
      locations,
      ...(input ? { inputPath: input } : {}),
      images: update.content === undefined ? before?.images : imagesFromContent(update.content),
      diffs,
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

function exitCode(rawOutput: any): number | undefined {
  const code = rawOutput?.exit_code ?? rawOutput?.exitCode;
  return typeof code === "number" ? code : undefined;
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
/// bridge (bridgeSocket.ts).
export type OpenSocket = (url: URL) => WebSocket;

/// The placeholder URL of a bridge connection (never dialed).
export const BRIDGE_URL = "cmux-bridge://acpmux/";

/// Where git reads go: the native host, or in mock mode the daemon the socket reaches.
export type GitRoute = "native" | "daemon";

/// How soon a hidden page draws a change other than its text stream (`emitInFrame`), as the frame
/// fallback did before.
const HIDDEN_DRAW_MS = 50;

/// What hidden pages left for their first frame once shown (`nextFrame`): at most one per client,
/// since a client waits for one frame at a time and cancels it on close.
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
export const nextFrame = (run: () => void): (() => void) => {
  let done = false;
  const frame = () => {
    if (done) return;
    if (!pageShown()) return waitForShow(frame);
    let ran = false;
    const once = () => {
      if (ran || done) return;
      ran = true;
      if (!pageShown()) return waitForShow(frame);
      done = true;
      run();
    };
    requestAnimationFrame(once);
    setTimeout(once, 50);
  };
  frame();
  return () => {
    done = true;
    stopWaiting(frame);
  };
};

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

/// Transcript rows in the daemon's event order: each row keeps the sequence number of the event
/// that created it, so two wall clocks (or one millisecond) never put a prompt under its reply.
/// A row made without an event (a prompt sending or failed, a notice, the typing row) orders after
/// the events seen when it was made, so later turns go below it; after a lag rebuild, which
/// replays events older than it, it moves after them again.
export class OrderedRows extends Map<string, AcpmuxRow> {
  private readonly order = new Map<string, number>();
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
  private pullRequestActivityVersion = Symbol();
  private pullRequestCommandVersion = Symbol();
  private transcriptSummaryVersion = {};
  /// The turns the agent ran on its own (acpmux `background_turn`): each one's started record's
  /// sequence number and its ended record's, once heard. A row an event between them made is that
  /// turn's (`inBackground`). An ended record heard first (an older page's started record comes
  /// later) waits in `backgroundEnds`.
  private backgroundSpans: { id: string; from: number; to?: number }[] = [];
  private readonly backgroundEnds = new Map<string, { seq: number; turn: AcpmuxBackgroundTurn }>();

  /// A background turn's started record at `seq`; how it ended when its ended record came first.
  openBackground(id: string, seq: number): AcpmuxBackgroundTurn | undefined {
    if (this.backgroundSpans.some((span) => span.id === id)) return undefined;
    const ended = this.backgroundEnds.get(id);
    this.backgroundSpans.push({ id, from: seq, to: ended?.seq });
    this.backgroundEnds.delete(id);
    // An older page read later: rows its events made before this record was heard are the turn's too.
    for (const [rowId, order] of this.order) {
      if (this.local.has(rowId) || order <= seq || (ended !== undefined && order >= ended.seq)) continue;
      const row = this.get(rowId);
      if (!row || row.kind === BACKGROUND_TURN || row.kind === "user" || row.inBackground === id) continue;
      const tagged = { ...row, inBackground: id };
      super.set(rowId, tagged);
      const at = this.orderedIndex.get(rowId);
      if (this.ordered && at !== undefined) this.ordered[at] = tagged;
      this.snapshot = undefined;
      this.transcriptSummaryVersion = {};
    }
    return ended?.turn;
  }

  /// A background turn's ended record at `seq`, which says how it ended (`turn`).
  closeBackground(seq: number, turn: AcpmuxBackgroundTurn): void {
    const span = this.backgroundSpans.find((span) => span.id === turn.id);
    if (span) span.to = seq;
    else this.backgroundEnds.set(turn.id, { seq, turn });
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
  /// older history in rebuilds every row.
  keepSame(previous: ReadonlyMap<string, AcpmuxRow>): void {
    const plainSame = (a: AcpmuxRow, b: AcpmuxRow) => {
      const keys = new Set([...Object.keys(a), ...Object.keys(b)]) as Set<keyof AcpmuxRow>;
      for (const key of keys) if (typeof a[key] !== "object" && a[key] !== b[key]) return false;
      return true;
    };
    let changed = false;
    for (const [id, row] of this) {
      const old = previous.get(id);
      if (!old || old === row || old.kind !== row.kind || old.version !== row.version || !plainSame(old, row)) continue;
      super.set(id, old);
      const at = this.orderedIndex.get(id);
      if (this.ordered && at !== undefined) this.ordered[at] = old;
      changed = true;
    }
    if (changed) this.snapshot = undefined;
  }

  // Producers identify stream progress from the event, even when its row retains settled tools.
  override set(id: string, row: AcpmuxRow, summaryChanged = !row.streaming): this {
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
    } else if (this.current !== undefined) this.latest = Math.max(this.latest, this.current);
    // A row an event of a background turn made is that turn's, whoever updates it later. A prompt
    // never is: it starts a turn of its own (acpmux ends the background turn before it).
    if (this.backgroundSpans.length && row.kind !== BACKGROUND_TURN && row.kind !== "user" && !this.local.has(id)) {
      const turn = this.backgroundAt(this.order.get(id)!);
      if (turn !== undefined && row.inBackground !== turn) row = { ...row, inBackground: turn };
    }
    if (this.ordered && !unchanged) this.keepOrdered(id, row, known);
    return super.set(id, row);
  }

  /// Updates the kept order for `row`: in its slot when only its content changed, at the end when it
  /// sorts after every row, otherwise ``sorted()`` sorts again.
  private keepOrdered(id: string, row: AcpmuxRow, known: boolean): void {
    const ordered = this.ordered!;
    const index = this.orderedIndex.get(id);
    if (known && index !== undefined && (ordered[index]!.at === row.at || this.ownsSlot(index))) {
      ordered[index] = row;
      return;
    }
    const last = ordered.at(-1);
    const order = this.order.get(id) ?? 0;
    const lastOrder = last ? (this.order.get(last.id) ?? 0) : -Infinity;
    if (!known && (order > lastOrder || (order === lastOrder && row.at >= last!.at))) {
      this.orderedIndex.set(id, ordered.length);
      ordered.push(row);
      return;
    }
    this.ordered = undefined;
    this.pullRequestActivityVersion = Symbol();
    this.pullRequestCommandVersion = Symbol();
    this.transcriptSummaryVersion = {};
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

  /// The place `id` sorts at: its event's sequence number, or just after the events seen before it.
  orderOf(id: string): number {
    return this.order.get(id) ?? Infinity;
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
    this.ordered = undefined;
    this.snapshot = undefined;
    this.order.delete(id);
    this.local.delete(id);
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
    this.latest = 0;
    this.backgroundSpans = [];
    this.backgroundEnds.clear();
    super.clear();
  }

  /// Drops every row but those `keep` accepts; the event order starts over (a lag rebuild
  /// replays the events), and the rows kept go after the replayed events (``placeLocalLast()``).
  retain(keep: (row: AcpmuxRow) => boolean): void {
    // A Map visits the entries left after a delete, so deleting while iterating is safe.
    for (const row of this.values()) if (!keep(row)) this.delete(row.id);
    this.latest = 0;
    // The replay hears the background turns' records again.
    this.backgroundSpans = [];
    this.backgroundEnds.clear();
  }

  /// Moves the rows made without an event after every event, keeping their order: what a lag
  /// rebuild replayed happened before them.
  placeLocalLast(): void {
    this.pullRequestActivityVersion = Symbol();
    this.pullRequestCommandVersion = Symbol();
    this.transcriptSummaryVersion = {};
    this.ordered = undefined;
    this.snapshot = undefined;
    const local = [...this.local].sort((a, b) => (this.order.get(a) ?? 0) - (this.order.get(b) ?? 0));
    local.forEach((id, index) => this.order.set(id, this.latest + 0.5 + (index + 1) * 1e-6));
  }

  /// An optimistic row has been accepted by an event: keep its id, but make the event its order.
  adoptEventOrder(id: string): void {
    if (!this.has(id)) return;
    this.local.delete(id);
    if (this.current !== undefined) {
      this.order.set(id, this.current);
      this.latest = Math.max(this.latest, this.current);
    }
    this.ordered = undefined;
    this.snapshot = undefined;
  }

  /// The rows in event order (wall-clock time breaks a tie).
  sorted(): AcpmuxRow[] {
    if (!this.ordered) {
      this.ordered = [...this.values()].sort(
        (a, b) => (this.order.get(a.id) ?? 0) - (this.order.get(b.id) ?? 0) || a.at - b.at,
      );
      this.orderedIndex = new Map(this.ordered.map((row, index) => [row.id, index]));
    }
    if (!this.snapshot) {
      this.snapshot = this.ordered.slice();
      markPullRequestActivityVersion(this.snapshot, this.pullRequestActivityVersion);
      markPullRequestCommandVersion(this.snapshot, this.pullRequestCommandVersion);
      markTranscriptSummaryVersion(this.snapshot, this.transcriptSummaryVersion);
    }
    return this.snapshot;
  }
}

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
  /// The frame this client waits for, if any: one at a time, cancelled on close (`emitInFrame`).
  private frameRequest?: { cancel?: () => void };
  private socket?: WebSocket;
  private nextRequest = 1;
  private pending = new Map<
    number | string,
    {
      resolve: (value: any) => void;
      reject: (error: Error) => void;
      timer?: ReturnType<typeof setTimeout>;
    }
  >();
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
  /// Senders of addressed prompts no listed chat named (`incomingContext`).
  private unknownSenders = new Set<string>();
  /// Each waiting prompt's author as its newest `queued` or `queue_updated` record named it (null:
  /// none), kept while it waits, so acpmux's list (which names none) keeps it (mergeQueue).
  private queueAuthors = new Map<string, Participant | null>();
  /// The waiting prompts edited since they were queued (`queue_updated`): the person's words now,
  /// never acpmux's resume, whatever their text or client says (mergeQueue).
  private queueEdited = new Set<string>();
  /// The session list a page at a time: the newest page opens the chat, the rest follow (cx-2lv1k).
  private readonly sessionPages = new SessionPager<Session>((method, params) => this.request(method, params));
  private sessionReread: ReturnType<typeof setTimeout> | undefined;
  /// The pending reread follows a watch lag: once it sets the list, Needs you's asks resync too.
  private sessionRereadResyncsAsks = false;
  /// Sidebar entries by acpmux session object. A changed session arrives as a new object, so unchanged rows keep their entry and skip rendering.
  private sessionEntries = new WeakMap<Session, AcpmuxSessionEntry>();
  /// The snapshot's session entries for the list they were mapped from: a snapshot whose list did
  /// not change (a streamed token, a row's change) hands the pane the same array, so what the pane
  /// derives from `snapshot.sessions` keeps its identity and no row redraws for it.
  private sessionEntriesOf?: { sessions: Session[]; entries: AcpmuxSessionEntry[] };
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
  /// The single permission cards asked and not yet answered, by permission id: an answer draws a
  /// receipt (`permissionRecord`, permissions/record.ts).
  private askedPermissions = new Map<string, AcpmuxPermission>();
  private commands: SlashCommand[] = [];
  private usage: { used: number; size: number; setup?: number } | undefined;
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
  /// The promptIds drawn as prompts. An older page folds in after the rows below it, so the steer
  /// a held prompt re-ran comes after that prompt: it draws nothing. Kept across that fold.
  private promptsShown = new Set<string>();
  /// Attachments sent with a prompt until its user-message event gives it a durable row id.
  private optimisticPromptAttachments = new Map<string, ComposerAttachment[]>();
  /// Attachments for completed prompts, used when their turn is retried later.
  private retryAttachments = new Map<string, ComposerAttachment[]>();
  private optimisticPromptParts = new Map<string, PromptContentPart[]>();
  private optimisticPromptInputs = new Map<string, string>();
  private retryInputs = new Map<string, string>();
  /// What a prompt's sender is told once acpmux took the prompt (its `user_message` echo, or the
  /// reply), by prompt id. A refusal comes before either, so the composer keeps the prompt.
  private promptAccepts = new Map<string, () => void>();
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
  private turnOpen = false;
  /// The open turn's agent has said nothing since its prompt, past acpmux's `silentTurnMs`
  /// (`turn_silent`, hub/silent_turn.rs): the line says the model has not answered. acpmux hearing
  /// the model (`turn_heard`), or the turn's end, clears it; the agent's own bookkeeping does not.
  private silentTurn = false;
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
  /// Session replay (replay/ReplayScreen.tsx): the recorded events are folded only through this seq.
  private replayThrough?: number;
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
  /// The attach out now, of which session: a row that says its machine is back while it is out
  /// (no copy drawn yet) is kept for after it, as for a copy's attach (`copyBack`).
  /// The attach of the selected chat that is out.
  private attachOut?: { sessionId: string };
  /// Each session and machine the selected chat's row named while an attach of it ran, from its
  /// ask until it drew its page (one entry each): the page is of none of the others (`attach`).
  private attachWatch?: AttachWatch;
  /// The attach `open` asked with the chat list, until the open takes it or drops it (`askEarly`).
  private earlyAttach?: EarlyAttach;
  /// The `createdAt` of the session the rows drawn before the attach are of (`drawKeptTail`, from
  /// the tail's summary), undefined when they do not say.
  private drawnGeneration?: number;
  readonly handoff = new HandoffClient(
    (method, params) => this.request(method, params, 15000),
    () => this.emit(),
  );
  /// Who else is in a shared chat and who types there (multiplayer/presenceClient.ts). Nothing
  /// crosses while acpmux sends no `presence` on attach. A change goes to the header faces and the
  /// typing line alone (multiplayer/LivePresence.tsx), never through the snapshot: a teammate
  /// typing redraws no transcript.
  readonly presence = new PresenceClient(
    (method, params) => this.request(method, params, 15000),
    () => shownPresence.set(this.presence.chat, this.presence.presence),
  );
  readonly permissions = new PermissionGroupClient(
    (method, params) => this.request(method, params, 15000),
    () => {
      for (const group of this.permissions.state.groups)
        for (const item of group.items) if (item.state !== "pending") this.groupedPermissions.delete(item.permissionId);
      // The groups can land after the attach drew the chat's asks (`attachWatched` no longer waits
      // for them): an ask a group now holds is the group's card, never a second one of its own.
      if (this.permissions.state.supported && this.permissions.state.ready) this.dropGroupedAsks();
      if (!this.permissions.state.supported && !this.pendingPermission)
        this.pendingPermission = [...this.groupedPermissions.values()].at(-1);
      this.emit();
    },
  );
  private forking = false;
  private streamingAssistant?: string;
  private streamingAssistantMessageId?: string;
  /// A prompt or steer came while the streaming row's message was still being written: only that
  /// message's own chunks (the same `messageId`) go on in the row, above the prompt's bubble.
  private assistantCut = false;
  private streamingActivity?: string;
  /// The open turn's plan row: its later `plan` updates redraw this one list (cx-ncc.80).
  private planRow?: string;
  /// When each compaction row last heard "still compacting": a running note within
  /// COMPACTION_REPEAT_WINDOW of it is the same compaction, even after the next turn's start or a
  /// forced Stop noted the row as failed. A row whose turn ended for good, or that ended, has none.
  private compactionHeardAt = new Map<string, number>();
  private supersededMessageIds = new Set<string>();
  /// The rows each message streamed into; tool calls split one message into several.
  private messageRows = new Map<string, string[]>();
  /// The activity row each tool call lives in, so a late update lands where the call began.
  private toolRows = new Map<string, string>();
  /// TodoWrite calls a drawn checklist stands for (cx-ncc.80): acpmux sends each one's plan just
  /// before it, so the call and its updates draw no tool row. Plumbing calls (hiddenTools.ts)
  /// draw none either.
  private planCalls = new Set<string>();
  /// Why subagents stopped, as far as this pane knows, kept across the fold's rebuilds (a new
  /// session forgets them).
  private subagentStops = subagentStops();
  /// Subagents and their records, which draw as group rows (subagents/subagentFold.ts).
  private subagents = new SubagentFold(this.subagentStops);
  private readonly listener: Listener;
  private host: AcpmuxHostConfig;
  /// A purge in flight owns the selected session's disappearance; do not replace it with another
  /// chat before the page's caller closes the tab.
  private purgingSessionId?: string;
  /// A purge that succeeded while its chat was still selected: acpmux's `purged` notification may
  /// come after the purge's answer, and that chat's leaving the list then selects nothing, not
  /// another chat, so the deletion's own completion (closing the tab) is not undone. Cleared by any
  /// other selection.
  private purgedSessionId?: string;
  /// The client's own most recent leaving of a chat that left the list (`selectFallbackSession`),
  /// at the selection generation it made: a page completion for that chat (Archive's close) can tell
  /// it apart from a navigation the person made meanwhile.
  private fallback?: { from: string; generation: number };
  private peers: string[] = [];
  /// Each peer's transport, for the environment picker's SSH and Cloud sections (environments.ts).
  private peerKinds: Record<string, "ssh" | "cloud"> = {};
  private peerConnected: Record<string, boolean> = {};
  private peerStates: Record<string, string> = {};
  private peerResources: NonNullable<AcpmuxSnapshot["peerResources"]> = {};
  /// Each peer's link state, last-seen time and failed attempts, for why a chat is not listed.
  private peerStatus: Record<string, PeerStatus> = {};
  private reconnectTimer?: number;
  private reconnectDelay = 250;
  /// Called once when an established connection drops. The host then asks Swift
  /// for a fresh handshake, because a restarted daemon has a new port and token.
  private readonly onLost?: () => void;
  private opening = false;
  private hasConnected = false;
  private closed = false;
  /// Replay clients are intentionally detached from a socket but still publish seek snapshots.
  private replayMode = false;
  /// A `fed` client (the guest page's) has no socket either, but draws what it is fed until `dispose`.
  private fedMode = false;
  private selectionGeneration = 0;
  /// The last attach sent, and what acpmux last accepted about whether the page shows its chat.
  private attaching: Promise<unknown> = Promise.resolve();
  private shownToAcpmux?: { sessionId: string; visible: boolean };
  private viewSync: Promise<void> = Promise.resolve();
  /// The selection generation whose attach reply has landed; lag resync waits for it.
  private attachedGeneration = -1;
  private historyExhausted = false;
  /// The oldest `native_history` record held (reduced): where the transcript's older turns end.
  private nativeSeed?: { seq: number; before: number; mark?: string };
  /// Where the next older native page ends, once one was read, for the held transcript
  /// (`historyEpoch`): 0 when nothing older holds a turn or the daemon serves no pages.
  private nativeNext?: { epoch: number; before: number; mark?: string };
  /// Bumped when the held transcript's older end moves on its own: a kept tail dropped because the
  /// attach page did not continue it. An older page in flight from before belongs to a transcript
  /// the chat no longer holds, so it is dropped instead of merged above the new one.
  private historyEpoch = 0;
  /// An older page is on its way: the reader's scroll asks again on every frame near the top.
  private loadingOlder?: Promise<void>;
  /// While an older page folds, the first sequence number the pane held before it.
  private foldingBelow: number | undefined;
  /// After a failed older page the next waits until then, so a reader near the top does not retry every frame.
  private olderRetryAt = 0;
  private readonly olderDelay = new OlderPageDelay();
  /// Invalidates an older-page request when its socket goes away. A late reply from that socket must
  /// not restart the backoff after the reconnect has installed a new client connection.
  private olderPagingEpoch = 0;
  /// The daemon's harness list or a harness's models changed (`_acpmux/harnesses_changed`: a
  /// profile written, live model lists refreshed); the catalog re-reads (catalog.ts
  /// followHarnessChanges).
  onHarnessesChanged?: () => void;
  /// `_acpmux/process_update` listeners (session-info/processes.ts).
  private readonly processListeners = new Set<(process: unknown) => void>();
  /// A prompt carrying the workspace context is on its way (send).
  private contextInFlight = false;

  private constructor(
    host: AcpmuxHostConfig,
    listener: Listener,
    onLost?: () => void,
    private readonly openSocket: OpenSocket = (url) => new WebSocket(url),
    private readonly gitRoute: GitRoute = "native",
    /// Every message on the socket and its lifecycle, for the ACP inspector (wire.ts).
    private readonly wire: AcpWireLog = acpWire,
  ) {
    this.host = host;
    this.listener = listener;
    this.onLost = onLost;
    this.selectedSessionId = host.sessionId;
    if (typeof document !== "undefined") document.addEventListener("visibilitychange", this.showChanged);
    // The chat on screen is handed over when this page goes away as well as when it is left, so a
    // tab closed or reloaded on a chat leaves that chat warm for the next tab (keptAttachments.ts
    // hands the composer's chips over the same way). Without this the only chat the host ever
    // learns is one the reader switched off, which is not the chat they open in a new tab.
    if (typeof window !== "undefined") window.addEventListener("pagehide", this.pageWentAway);
  }

  private pageWentAway = (): void => {
    this.rememberCurrentTail(false);
  };

  /// Hands the chat on screen to the host now, for a tab about to open it (`chat.openTab`). The
  /// page keeps it selected, so nothing else would hand it over and the new tab would open cold —
  /// the flow this cache exists for.
  handOverCurrentTail(): void {
    this.rememberCurrentTail();
  }

  /// A client with no connection that shows one recorded session as it stood at a point in it
  /// (session replay, replay/ReplayScreen.tsx). `seekReplay` moves the point; nothing is ever sent.
  static replay(sessionId: string, events: EventRecord[], listener: Listener): AcpmuxDirectClient {
    const client = new AcpmuxDirectClient({ protocolVersion: 1, transport: "acpmux-bridge", sessionId }, listener);
    client.closed = true;
    client.replayMode = true;
    client.events = events
      .filter((event) => event.seq > 0 && (event.sessionId ?? sessionId) === sessionId)
      .sort((a, b) => a.seq - b.seq);
    client.replayThrough = 0;
    return client;
  }

  /// Shows the replayed session through `throughSeq`. Moving forward folds only the events since;
  /// moving back folds again from the start.
  seekReplay(throughSeq: number): void {
    const from = this.replayThrough ?? 0;
    if (throughSeq === from) return;
    this.replayThrough = throughSeq;
    if (throughSeq < from) this.rebuild();
    else
      for (const event of this.events) {
        if (event.seq <= from || event.seq > throughSeq) continue;
        this.lastSeq = event.seq;
        this.firstSeq ??= event.seq;
        this.reduce(event);
      }
    this.emit("replay");
  }

  /// A client with no connection fed one chat's records from another source (the guest page's
  /// room, guest/shareSocket.ts). `feed` folds them; nothing is ever sent.
  static fed(sessionId: string, listener: Listener): AcpmuxDirectClient {
    const client = new AcpmuxDirectClient({ protocolVersion: 1, transport: "acpmux-bridge", sessionId }, listener);
    client.closed = true;
    client.fedMode = true;
    // Not this page's chat to hand over or to read again when shown: no page listeners.
    client.stopPageListeners();
    return client;
  }

  /// Ends a `fed` client: nothing it was fed draws after this, a frame already asked for included.
  dispose(): void {
    this.disposed = true;
    this.frameSnapshot = undefined;
    this.stopPageListeners();
  }

  /// Folds one chat's records into a `fed` client (the source carries no other chat, so each is
  /// taken as this client's). `snapshot` replaces what is held; `older` adds a page before it and
  /// folds again from the start; `live` folds only records past the newest held, in seq order,
  /// and draws once per display frame.
  feed(events: EventRecord[], mode: "snapshot" | "older" | "live"): void {
    const sessionId = this.selectedSessionId;
    const own = events
      .filter((event) => event.seq > 0)
      .map((event) => ({ ...event, sessionId }))
      .sort((a, b) => a.seq - b.seq);
    if (this.disposed) return;
    if (mode !== "live") {
      const first = this.firstSeq ?? Number.POSITIVE_INFINITY;
      this.events = mode === "snapshot" ? own : [...own.filter((event) => event.seq < first), ...this.events];
      this.rebuild();
      this.emit();
      return;
    }
    for (const event of own) {
      if (event.seq <= this.lastSeq) continue;
      this.events.push(event);
      this.lastSeq = event.seq;
      this.firstSeq ??= event.seq;
      this.reduce(event);
    }
    const schedule = AcpmuxDirectClient.scheduleFrame;
    if (!schedule) return this.emit();
    if (this.frameSnapshot !== undefined) return;
    this.frameSnapshot = "connected";
    schedule(() => {
      if (this.frameSnapshot !== undefined && !this.disposed) this.emit();
    });
  }

  /// Every recorded transcript event of a session, oldest first, for session replay.
  async recordedEvents(sessionId: string): Promise<EventRecord[]> {
    const events: EventRecord[] = [];
    for (let after = 0; ;) {
      const page = await this.typed("_acpmux/events", {
        sessionId,
        afterSeq: after,
        limit: 2000,
        kinds: ["transcript"],
      });
      const batch = records(page?.events);
      events.push(...batch);
      const last = batch.at(-1)?.seq;
      if (!page?.hasMore || last === undefined || last <= after) return events;
      after = last;
    }
  }

  /// An export stays on this connection and selection, including while a history page is in flight.
  async conversationEvents(isCurrent: () => boolean): Promise<EventRecord[]> {
    const sessionId = this.selectedSessionId;
    const generation = this.selectionGeneration;
    const connection = this.socket;
    const current = () =>
      !this.closed &&
      this.socket === connection &&
      generation === this.selectionGeneration &&
      this.selectedSessionId === sessionId &&
      isCurrent();
    if (!sessionId) throw new Error("conversation_export_no_session");
    return recordedConversationEvents(
      sessionId,
      {
        detail: async () => {
          // Events is already allowed on the pane bridge; its sequence watermark avoids exposing
          // the daemon's broader, native-only session detail surface to page code.
          const page = await this.typed("_acpmux/events", {
            sessionId,
            afterSeq: 0,
            limit: 1,
            kinds: ["transcript"],
          });
          return { lastSeq: page.lastSeq };
        },
        page: async (params) => {
          const page = await this.typed("_acpmux/events", params);
          return { events: records(page.events), hasMore: page.hasMore };
        },
      },
      current,
    );
  }

  static async connect(
    host: AcpmuxHostConfig,
    listener: Listener,
    onLost?: () => void,
    openSocket?: OpenSocket,
    gitRoute?: GitRoute,
    wire?: AcpWireLog,
  ): Promise<AcpmuxDirectClient> {
    const client = new AcpmuxDirectClient(host, listener, onLost, openSocket, gitRoute, wire);
    try {
      await client.open();
      return client;
    } catch (error) {
      client.close();
      throw error;
    }
  }

  private async open(): Promise<void> {
    if (this.opening || this.closed) return;
    this.features.clear();
    this.opening = true;
    // A new socket must advertise its own feature and proven origin before its notes are accepted.
    this.peerEvents.configure(undefined);
    // A reconnect owns the attach of the copy on screen from its start: a row that says its machine
    // is back meanwhile waits for it (`copyBack`), never a second attach over the same copy.
    if (this.peerCopy && this.peerCopy.sessionId === this.selectedSessionId) this.peerCopy.attaching = true;
    // Any attach of the copy already out (a select's, a recovery's) leaves it to this one when it
    // fails, copy drawn yet or not.
    let mine = ++this.copyAttaches;
    // A chat another tab read already is held by the app host: ask for its tail now, while the
    // socket connects and acpmux lists the chats, so drawing it below costs this open no round
    // trip of its own (tailCache.ts). A page that read the chat itself has the newer tail.
    const cold = this.selectedSessionId;
    if (cold && this.events.length === 0 && !keptTail(cold)) void readHostTail(cold).catch(() => undefined);
    // Over the bridge the URL names nothing: the host knows its daemon.
    const url = new URL(this.host.endpoint ?? BRIDGE_URL);
    if (this.host.token) url.searchParams.set("token", this.host.token);
    this.wire.lifecycle("connecting", {
      endpoint: this.host.endpoint ? redactEndpoint(this.host.endpoint) : BRIDGE_URL,
      sessionId: this.selectedSessionId,
    });
    const openingSocket = await new Promise<WebSocket>((resolve, reject) => {
      const socket = this.openSocket(url);
      this.socket = socket;
      let opened = false;
      socket.onopen = () => {
        opened = true;
        this.wire.lifecycle("open");
        resolve(socket);
      };
      socket.onerror = () => {
        this.wire.lifecycle("error", { message: opened ? "WebSocket error" : "Unable to connect" });
        this.opening = false;
        reject(new Error(translate("error.connectFailed")));
      };
      socket.onclose = (event?: CloseEvent) => {
        if (this.socket !== socket || this.closed) return;
        this.wire.lifecycle("close", {
          code: event?.code,
          reason: event?.reason || undefined,
          wasClean: event?.wasClean,
          established: opened,
        });
        if (!opened) {
          this.opening = false;
          reject(new Error(translate("error.closedBeforeConnect")));
          return;
        }
        this.cancelOlderPaging();
        this.handoff.disconnect();
        // acpmux drops a connection's attaches with it; the next attach watches them again.
        this.offerChildren.reset(false);
        this.groupedPermissions.clear();
        this.permissions.disconnected();
        this.rejectPending();
        // Delivery is no longer observable on this connection. A reconnect must not inherit Stop.
        this.stopAfterSeq = undefined;
        this.stopSuperseded = false;
        this.stopOpenerSeen = false;
        this.stopTurnId = undefined;
        this.stoppingEnded();
        this.emit("disconnected");
        if (!this.hasConnected || this.closed) return;
        if (this.onLost) {
          this.wire.lifecycle("lost", { message: "asking for a fresh handshake" });
          const onLost = this.onLost;
          this.close();
          onLost();
        } else this.scheduleReconnect();
      };
      // A socket this client replaced still answers what was asked on it (an export that watches for
      // the swap rejects on that answer); only its peer notes, about a connection that is gone, drop.
      socket.onmessage = (message) =>
        acpmuxPerf.timed("client.receive", () => this.receive(String(message.data), this.socket !== socket));
    }).catch((error: unknown) => {
      this.releaseCopyAttach(mine);
      throw error;
    });
    // The pane keeps what it shows (the page's cached chat, or the chat before a reconnect) until
    // the open has read the chat: no half-read frame (an empty transcript, no composer) in between.
    const hold = this.holdSnapshots(OPEN_HOLD_MS);
    let early: EarlyAttach | undefined;
    try {
      const initialized = await this.request("initialize", {
        protocolVersion: 1,
        clientInfo: { name: "cmux-react-agent-pane", version: "1" },
        clientCapabilities: {},
      });
      this.canFork = servesOperation(initialized, FORK_OP);
      const features = initialized?._meta?.acpmux?.features;
      this.features = new Set(
        Array.isArray(features) ? features.filter((value): value is string => typeof value === "string") : [],
      );
      const capabilities = initialized?._meta?.acpmux?.capabilities;
      this.capabilities = Array.isArray(capabilities) ? new Set(capabilities.map(String)) : undefined;
      const extensions = initialized?._meta?.acpmux?.extensions;
      this.extensions = Array.isArray(extensions) ? extensions.map(String) : [];
      this.localOrigin = initialized?._meta?.acpmux?.origin === "local";
      const origin = initialized?._meta?.acpmux?.origin;
      this.origin = origin === "local" || origin === "remote" || origin === "peer" ? origin : "unknown";
      this.ownerCloud = this.origin === "remote" && initialized?._meta?.acpmux?.ownerCloud === true;
      this.handoffSupported = supportsHandoff(initialized);
      this.peerEvents.configure(initialized);
      const groupedPermissionsSupported = supportsPermissionGroups(initialized);
      if (!groupedPermissionsSupported) this.groupedPermissions.clear();
      this.permissions.configure(groupedPermissionsSupported);
      // Everything the chat's first frame waits on goes out at once after the handshake: the
      // machines, the chat list, and the chat's own attach with its permission and handoff reads.
      // acpmux answers a connection's requests side by side (server/mod.rs spawns each), so the
      // frame waits on one round trip rather than one per read (Leo, 2026-10-29: "as in i want
      // ours to load fast too :(").
      const peersSince = this.peerEvents.statusStarted();
      const peersRead = this.request("_acpmux/status", {}).catch(() => undefined);
      const listRead = this.sessionPages.first();
      // Awaited below, after the machines: a list that fails meanwhile is not left unobserved.
      listRead.catch(() => undefined);
      early = this.askEarly();
      this.readPeers(await peersRead, peersSince);
      // The chat's own row, when its attach answered before the list: the chat opens on it, and the
      // list settles behind the open (`attachedBeforeList`).
      const attachedRow = early && (await this.attachedBeforeList(early, listRead));
      const first = attachedRow ? undefined : await listRead;
      // After the list's `_acpmux/watch` answered, so no peer note falls between the read and the
      // watch; not awaited, so the first frame keeps its one round trip (#27755). An open drawn
      // from the attach reads it once the list behind it settles.
      if (this.peerEvents.supported) {
        if (attachedRow) void listRead.then(ignore, ignore).then(() => this.refreshPeerStatesAndEmit());
        else void this.refreshPeerStatesAndEmit();
      }
      let laterPages = first?.next ? first : undefined;
      const linkedLater =
        first !== undefined &&
        laterPages !== undefined &&
        this.selectedSessionId !== undefined &&
        !first.sessions.some((session) => session.sessionId === this.selectedSessionId);
      if (attachedRow)
        this.sessions = [
          attachedRow,
          ...this.sessions.filter((session) => session.sessionId !== attachedRow.sessionId),
        ];
      else if (first && !linkedLater) this.sessions = first.sessions;
      else {
        // A linked chat older than the first page, or a lagged watch restarted the list: read the
        // whole list before calling the chat missing.
        this.sessions = this.sessionPages.settle(await this.sessionPages.whole());
        laterPages = undefined;
      }
      this.listedSessions = !attachedRow && (first !== undefined || this.sessions.length > 0);
      // A chat on another machine: that machine's daemon attached the session its store records for
      // this tab (agent-session-attach checks it), so that session is the tab's chat even when this
      // page holds another name for it: a session name the tab recorded, or the id from before the
      // tab was rebound there. It opens; the tab's chat is never called missing for that.
      const tabSession = first?.tab;
      if (
        tabSession !== undefined &&
        this.selectedSessionId !== undefined &&
        tabSession !== this.selectedSessionId &&
        !this.sessions.some((session) => session.sessionId === this.selectedSessionId) &&
        this.sessions.some((session) => session.sessionId === tabSession)
      ) {
        this.wire.lifecycle("tab session", { asked: this.selectedSessionId, attached: tabSession });
        this.selectedSessionId = tabSession;
        this.selectionGeneration += 1;
        this.resetSessionState();
      }
      if (this.selectedSessionId && !this.sessions.some((session) => session.sessionId === this.selectedSessionId)) {
        // A linked session the daemon lacks is refused, never replaced by the most recent chat.
        if (this.host.sessionMustExist) {
          this.noteMissing(this.selectedSessionId);
          this.missingReason = "notListedAtOpen";
        }
        const purging =
          this.selectedSessionId !== undefined &&
          (this.purgingSessionId === this.selectedSessionId || this.purgedSessionId === this.selectedSessionId);
        if (purging) this.purgedSessionId = undefined;
        const from = this.selectedSessionId;
        this.selectedSessionId = this.host.sessionMustExist || purging ? undefined : this.sessions[0]?.sessionId;
        this.selectionGeneration += 1;
        this.fallback = { from, generation: this.selectionGeneration };
        this.resetSessionState();
        // The machine the chat was on, from what the app host kept of it (another tab read it).
        const missing = this.missingSession;
        if (missing && this.missingPeer === undefined) {
          await readHostTail(missing).catch(() => undefined);
          if (this.missingSession === missing) this.missingPeer = keptPeer(missing);
        }
      }
      this.selectedSessionId = initialSession(
        this.selectedSessionId,
        this.sessions,
        this.host.newSession || this.missingSession !== undefined,
      );
      if (this.selectedSessionId) this.markSeen(this.selectedSessionId);
      this.seedListedSummary();
      // A reconnect to the same session keeps its transcript; the attach page holds only the newest events.
      const sessionId = this.selectedSessionId;
      const generation = this.selectionGeneration;
      // A reconnect while the chat shows the Mac's copy attaches it as a kept tail, from the copy's
      // newest seq, as when its machine comes back: never a gap read from records past a hole.
      const heldCopy = sessionId && this.peerCopy?.sessionId === sessionId ? this.peerCopy : undefined;
      if (heldCopy) {
        heldCopy.attaching = true;
        heldCopy.offline = false;
      }
      const resumeAfter = heldCopy ? 0 : this.lastSeq;
      // The attach asked with the list is the open's only while it is of the chat opened now, on
      // this machine as the list names it: anything else (another chat chosen, a chat on another
      // machine, which may be down and draw the Mac's copy first) is attached as before.
      const adopted =
        early &&
        sessionId === early.sessionId &&
        generation === early.generation &&
        !heldCopy &&
        resumeAfter === 0 &&
        typeof this.sessions.find((session) => session.sessionId === sessionId)?.peer !== "string"
          ? early
          : undefined;
      if (early && !adopted) this.dropEarly(early);
      if (sessionId) {
        // The chat as it was last read, drawn on the frame this open lands with its attach still
        // in flight: from this page when it read the chat before, else from the app host, which is
        // what makes a chat opened in a NEW TAB instant too (tailCache.ts). Only on a cold page: a
        // reconnect already holds the chat's own events, which are newer than any tail.
        let keptThrough = heldCopy?.lastSeq ?? 0;
        if (!heldCopy && resumeAfter === 0 && this.events.length === 0) {
          const hostTail = readHostTail(sessionId).catch(() => undefined);
          // An attach that answered already is newer than any tail the host holds: the chat draws
          // from it rather than waiting out the host's read (at most `HOST_TAIL_READ_MS`).
          await (adopted ? Promise.race([hostTail, adopted.sent.attaching.then(ignore, ignore)]) : hostTail);
          // A switch that landed while the host answered chose another chat: its own select draws
          // that one, and these rows belong to the chat this open was for.
          if (generation === this.selectionGeneration && this.selectedSessionId === sessionId) {
            keptThrough = this.drawKeptTail(sessionId);
          }
          if (keptThrough === 0) keptThrough = await this.drawPeerCopy(sessionId, generation);
          if (keptThrough > 0) {
            // Where the caller decides, not where the tail is read: a tail that drew no row is a
            // cold open, and the host must not be told rows are on screen that are not.
            this.drewKeptTail = true;
            this.emit("selected");
            this.releaseSnapshots(hold);
          }
        }
        let page: EventRecord[] = [];
        // The attach that goes out last decides the chat: a select's that went out before this one
        // (while the socket connected or the chats were listed) leaves the chat to it. Only when this
        // attach goes out: one a select took over while the tail or copy was read sends nothing, and
        // must not take the chat from the select's attach.
        if (generation === this.selectionGeneration && this.selectedSessionId === sessionId) mine = ++this.copyAttaches;
        try {
          page = await this.attach(sessionId, generation, keptThrough, 1, adopted);
        } catch (error) {
          // A newer attach of the chat (a select, a switch) took it over while this one was out:
          // its outcome decides, so this one's failure neither draws, clears nor fails the open on
          // the socket that newer attach read the chat over.
          const superseded =
            mine !== this.copyAttaches ||
            generation !== this.selectionGeneration ||
            this.selectedSessionId !== sessionId;
          if (!superseded || this.socket?.readyState !== WebSocket.OPEN) {
            // A peer chat whose machine is down keeps what it drew, marked as the Mac's copy, and
            // reads the machine when its row says it is back (`sessionChanged`): the page stays open.
            const kept = await this.keepPeerCopy(sessionId, generation, error);
            // The chat could not be read: a tail drawn from the host must not stay on screen as if
            // this page had read the chat, here as in `select` — and the pane has to be told, or it
            // keeps drawing the snapshot that carried those rows.
            if (!kept && !superseded && keptThrough > 0) {
              forgetTail(sessionId);
              this.peerCopy = undefined;
              this.copyLive = undefined;
              this.events = [];
              this.queue = [];
              // Those rows are off screen again, so the frame the host shows is the failure, not a
              // chat: it fades in as any first draw of a chat does.
              this.drewKeptTail = false;
              this.rebuild();
              this.emit(this.socket?.readyState === WebSocket.OPEN ? "failed" : "disconnected");
            }
            if (!kept) throw error;
          }
        }
        const oldest = page.length > 0 ? Math.min(...page.map((event) => event.seq)) : 0;
        if (resumeAfter > 0 && oldest > resumeAfter + 1)
          await this.fetchMissedEvents(sessionId, generation, resumeAfter, false).catch((error: unknown) => {
            // The gap stays: usage before the new page is no longer whole (the turn's tokens hide).
            if (generation === this.selectionGeneration && this.selectedSessionId === sessionId) {
              this.usageFromSeq = Math.max(this.usageFromSeq, oldest);
              this.rebuildKeepingLiveState();
            }
            throw error;
          });
      } else if (this.host.adopt) {
        await this.adoptChat(this.host.adopt);
      }
      // Permission and handoff reads tolerate their own failures. A socket lost during those
      // reads must still fail the handshake, so the host retries instead of keeping a dead client.
      if (this.closed || openingSocket !== this.socket || openingSocket.readyState !== WebSocket.OPEN)
        throw new Error(translate("error.interrupted"));
      this.hasConnected = true;
      this.reconnectDelay = 250;
      this.wire.lifecycle("connected", {
        sessionId: this.selectedSessionId,
        sessions: this.sessions.length,
      });
      this.emit("connected");
      if (laterPages) void this.readLaterSessions(laterPages);
      if (attachedRow) void this.listAfterOpen(listRead);
      this.scheduleReadAhead(READ_AHEAD_DELAY_MS);
    } catch (error) {
      this.wire.lifecycle("connect failed", {
        message:
          error instanceof SessionPageError
            ? `${error.message} (${error.detail})`
            : error instanceof Error
              ? error.message
              : String(error),
      });
      this.releaseCopyAttach(mine);
      this.socket?.close();
      throw error;
    } finally {
      // An attach asked with a list that never answered (a failed handshake) is no one's.
      if (early && this.earlyAttach === early) this.dropEarly(early, true);
      this.opening = false;
      this.releaseSnapshots(hold);
    }
  }

  /** Drops everything that belongs to the previously selected session, before another one attaches. */
  private resetSessionState(): void {
    this.cancelTrustStart?.();
    // Typing and presence stop with the chat at once, not when the next attach lands: a keystroke
    // meanwhile never reaches the chat before.
    this.presence.detached();
    // A resend wait for a chat this pane no longer shows says no (`awaitResent`).
    for (const [settle, sessionId] of this.resendWaits) if (sessionId !== this.selectedSessionId) settle();
    // The chats started from the chat before are no longer watched.
    this.offerChildren.reset(this.socket?.readyState === WebSocket.OPEN);
    this.stopAfterSeq = undefined;
    this.stopSuperseded = false;
    this.stopOpenerSeen = false;
    this.stopTurnId = undefined;
    this.runningTurnId = undefined;
    this.stoppingEnded();
    this.events = [];
    this.turnOpener = undefined;
    this.turnPrompt = undefined;
    this.historyExhausted = false;
    this.nativeSeed = undefined;
    this.nativeNext = undefined;
    this.olderRetryAt = 0;
    this.olderDelay.cancel();
    // Nothing is drawn, so nothing drawn came from a kept tail: the next open says for itself.
    this.drewKeptTail = false;
    this.peerCopy = undefined;
    this.copyLive = undefined;
    this.drawnGeneration = undefined;
    this.rowsGeneration = undefined;
    this.rowsPeer = undefined;
    // A page still in flight belongs to the session before; it is dropped when it lands.
    this.loadingOlder = undefined;
    this.rows.clear();
    this.queueAuthors.clear();
    this.queueEdited.clear();
    this.forkedAtSeq = undefined;
    for (const id of this.failedPrompts.keys()) this.clearedBySwitch.add(id);
    for (const id of this.clearedBySwitch) {
      if (this.clearedBySwitch.size <= 256) break;
      this.clearedBySwitch.delete(id);
    }
    this.failedPrompts.clear();
    for (const { timers } of this.deliveries.values()) timers.forEach(clearTimeout);
    this.deliveries.clear();
    this.firstSeq = undefined;
    this.promptIndex = undefined;
    this.lastSeq = 0;
    this.clockOffset = undefined;
    this.summary = undefined;
    this.configSeq = 0;
    this.limitsSeq = 0;
    this.limitsVersion += 1;
    this.goalSeq = 0;
    this.usage = undefined;
    this.turnTokens = undefined;
    this.turnTokenSplit = undefined;
    this.usageFromSeq = Infinity;
    this.queue = [];
    this.queueWithdrawn = [];
    this.turnOpen = false;
    this.silentTurn = false;
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
    this.assistantCut = false;
    this.streamingActivity = undefined;
    this.planRow = undefined;
    this.optimisticPromptRows.clear();
    this.promptRowKeys.clear();
    this.optimisticPromptTexts.clear();
    this.optimisticPromptAttachments.clear();
    this.optimisticPromptParts.clear();
    this.optimisticPromptInputs.clear();
    this.retryInputs.clear();
    this.queuedSends.clear();
    this.waitingSteers = [];
    this.interrupting = undefined;
    this.awaiting = undefined;
    this.endedTurns.clear();
    this.supersededTurns.clear();
    this.retiredCompactionTurnId = undefined;
    this.compactionFenceSeq = undefined;
    this.continuations.clear();
    this.steerRows.clear();
    this.promptsShown.clear();
    this.retryAttachments.clear();
    this.supersededMessageIds.clear();
    this.messageRows.clear();
    this.offerRows.clear();
    this.receivedOffers.clear();
    this.toolRows.clear();
    this.planCalls.clear();
    this.planRow = undefined;
    this.compactionHeardAt.clear();
    this.subagentStops = subagentStops();
    this.subagents = new SubagentFold(this.subagentStops);
    this.pendingPermission = undefined;
    this.waitingPermissions.clear();
    this.pendingSecret = undefined;
    this.groupedPermissions.clear();
    this.openQuestions.clear();
    this.askedQuestions.clear();
    this.askedPermissions.clear();
    this.heldEdits.clear();
    // The chat's commands from its last visit on this page, so `/` lists them before the attach.
    this.commands = (this.selectedSessionId && knownCommands.get(this.selectedSessionId)) || [];
    this.commandsApplied = false;
    this.handoff.select(this.selectedSessionId);
    this.permissions.select(this.selectedSessionId);
  }

  /// Keeps the chat on screen as this page last read it, for its next open (``KeptTail``). Only a
  /// chat whose own events are drawn: a chat still attaching, or one shown through a replay
  /// (`replayThrough`, a fork's preview), would be kept half-read.
  ///
  /// `forThisPage` is false when this client is the one going away, so the tail goes to the app
  /// host alone and not into this page's map (tailCache.ts `rememberTail`).
  private rememberCurrentTail(forThisPage = true): void {
    const sessionId = this.selectedSessionId;
    if (!sessionId || this.events.length === 0 || this.replayThrough !== undefined) return;
    if (this.attachedGeneration !== this.selectionGeneration) return;
    const events = this.events.slice(-KEPT_EVENTS);
    rememberTail(
      sessionId,
      {
        events,
        // The machine and session its rows are of, which the attach's detail does not name
        // (`keptPeer`): a tail drawn later is told from another machine's journal by them (`attach`).
        summary: this.provenSummary(),
        turnOpener: this.turnOpener,
        // Only a whole transcript is exhausted: a tail cut at KEPT_EVENTS has older events to read.
        historyExhausted: this.historyExhausted && events.length === this.events.length,
        queue: this.queue,
        configSeq: this.configSeq,
        usageFromSeq: this.usageFromSeq,
      },
      forThisPage,
    );
  }

  /// The summary a kept tail carries: the row as listed now, but naming only the machine and the
  /// session the rows on screen are proven of (`rowsPeer`, `rowsGeneration`). A `session_changed`
  /// merges a later row into `summary`, so its `peer` and `createdAt` may be of a session the rows
  /// are not; a tail kept under them would join that session's journal when drawn again.
  private provenSummary(): Record<string, any> | undefined {
    if (!this.summary && !this.rowsPeer && this.rowsGeneration === undefined) return this.summary;
    const summary: Record<string, any> = { ...this.summary };
    delete summary.peer;
    delete summary.createdAt;
    if (this.rowsPeer) summary.peer = this.rowsPeer;
    if (this.rowsGeneration !== undefined) summary.createdAt = this.rowsGeneration;
    return summary;
  }

  /// Draws `sessionId` from what its last visit left, for the frame a switch to it lands on, and
  /// answers the kept tail's newest seq (0 when nothing was kept), which the attach needs to tell
  /// whether its page continues that tail.
  ///
  /// What the tail says about the chat's *past* is drawn: its rows, its history and its queued
  /// prompts' whole text. What it says about what the chat is *doing* is not, because the chat ran
  /// on while it was away: the session list is live (`session_changed` keeps it current), so
  /// running or idle comes from there, and nothing waits for an answer until the attach says what
  /// acpmux holds (an ask answered meanwhile must not come back as a card). A running chat still
  /// shows the kept turn's clock for the attach's round trip, which the attach then corrects.
  /// Draws peer chat `sessionId` from the Mac's copy of it (`_acpmux/peer_snapshot`, peerCopy.ts)
  /// and answers how far the copy covers (its `lastSeq`, which may be past its newest record: seqs
  /// of kinds a page does not ask for), 0 when it draws nothing: a chat on this machine, a daemon
  /// with no copy or no such method, one that does not answer within ``PEER_COPY_READ_MS``, or a
  /// copy of another generation than the session listed now.
  private async drawPeerCopy(sessionId: string, generation: number, again = true): Promise<number> {
    // A selection that moved on reads nothing, and never takes the read marker of the chat shown.
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return 0;
    const listed = this.sessions.find((session) => session.sessionId === sessionId);
    if (typeof listed?.peer !== "string" || !listed.peer) return 0;
    // A row that says the machine is back while this read is out is kept for after it (`copyBack`),
    // and one that changes at all, for a read of another session (`changed`).
    const reading = { sessionId, changed: false };
    this.peerCopyReading = reading;
    const reply = await Promise.race([
      this.typed("_acpmux/peer_snapshot", { sessionId }).catch(() => undefined),
      new Promise<undefined>((resolve) => setTimeout(() => resolve(undefined), PEER_COPY_READ_MS)),
    ]);
    if (this.peerCopyReading === reading) this.peerCopyReading = undefined;
    const changed = reading.changed;
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return 0;
    // Read of the session before a row change: the session listed now is read once more.
    const redo = () => (changed && again ? this.drawPeerCopy(sessionId, generation, false) : 0);
    // A reply of this session only (its own id or `HOST/id`).
    const named = reply as { sessionId?: unknown; qualifiedSessionId?: unknown } | undefined;
    if (named?.sessionId !== sessionId && named?.qualifiedSessionId !== sessionId) return redo();
    const read = peerCopyTail(reply, sessionId);
    // The session as listed now, not when the read was asked (its row may have changed meanwhile).
    if (!read || !this.copyOfRow(read.copy)) return redo();
    const current = this.sessions.find((session) => session.sessionId === sessionId);
    // Rows of another session than this copy's on screen (the row changed while it was read):
    // everything of that session goes first, its queue and unsent prompts too, as for a switch.
    const held = this.peerCopy?.sessionId === sessionId ? this.peerCopy : undefined;
    // Rows not proven of this copy's machine and session count as another's.
    const otherRows = held
      ? held.peer !== read.copy.peer || !sameGeneration(held.generation, read.copy.generation)
      : this.events.length > 0 &&
        (this.rowsPeer !== read.copy.peer || !sameGeneration(this.rowsGeneration, read.copy.generation));
    if (otherRows) this.resetSessionState();
    // Drawn from the reply itself, never from a cache another read filled meanwhile.
    const drawn = this.drawKeptTail(sessionId, read.tail);
    // Its attach follows at once (`attaching`), so no row change starts another meanwhile.
    if (drawn === 0) return 0;
    this.peerCopy = { ...read.copy, offline: current?.stale === true, attaching: true };
    // An attach page that starts right after the copy continues it (`attach`'s `keptThrough`).
    return Math.max(drawn, read.copy.lastSeq);
  }

  /// Whether `copy` is of the session its row names now: the same machine and the same generation
  /// (its `createdAt`). A session moved to another machine, or recreated, is another chat.
  private copyOfRow(copy: PeerCopy | undefined): copy is PeerCopy {
    const row = copy && this.sessions.find((session) => session.sessionId === copy.sessionId);
    return !!row && row.peer === copy.peer && sameGeneration(copy.generation, row.createdAt);
  }

  /// After an attach of `sessionId` failed: when its machine is down (or the socket to the daemon
  /// dropped, which reconnects), a peer chat shows the Mac's copy, marked `offline`, and the pane
  /// is told: the copy already drawn, else the copy read now in place of a tail drawn from a cache
  /// (the daemon's is what it confirmed). Live records that came during the attempt go: the copy
  /// is what was confirmed, and the next attach continues from its newest seq, never from a record
  /// past a hole. Answers whether the chat is shown: its copy, or, with none, the machine read once
  /// more when its row said it was back (`attachIfBack`).
  private async keepPeerCopy(sessionId: string, generation: number, error: unknown): Promise<boolean> {
    const selected = () => generation === this.selectionGeneration && this.selectedSessionId === sessionId;
    if (!selected() || !(peerDown(error) || this.socket?.readyState !== WebSocket.OPEN)) return false;
    // Only a copy of the session listed now: one the machine recreated (or another machine took)
    // while the attach was out is not this chat, so it goes and the copy of the session listed now
    // is read, if the Mac has one.
    // Everything of the old session goes with it, its queue and unsent prompts too, as in
    // `redrawPeerCopy`: rows of a copy not of the row now, or of a tail or attach of another
    // session than the row names.
    const rowNow = this.sessions.find((session) => session.sessionId === sessionId);
    const held = this.peerCopy?.sessionId === sessionId ? this.peerCopy : undefined;
    const otherRows = held
      ? !this.copyOfRow(held)
      : (this.rowsGeneration !== undefined && !sameGeneration(this.rowsGeneration, rowNow?.createdAt)) ||
        (this.rowsPeer !== undefined && this.rowsPeer !== rowNow?.peer);
    if (otherRows) this.resetSessionState();
    if (this.peerCopy?.sessionId !== sessionId && (await this.drawPeerCopy(sessionId, generation)) === 0)
      return this.attachIfBack(sessionId, generation);
    const copy = this.peerCopy;
    if (!selected() || copy?.sessionId !== sessionId || !this.copyOfRow(copy)) return false;
    copy.offline = true;
    copy.attaching = false;
    this.copyLive = undefined;
    if (this.events.some((event) => event.seq > copy.lastSeq)) {
      this.events = this.events.filter((event) => event.seq <= copy.lastSeq);
      this.rebuild();
    }
    this.emit("peer offline");
    this.reattachIfBack(sessionId);
    return true;
  }

  /// After an attach failed with no copy of the chat to draw: its row said the machine was back
  /// while that attach or the copy's read was out (`copyBack`), so the machine is read once more
  /// now, from nothing (what the failed attach drew is not proven). Once, never a loop: answers
  /// whether the chat is shown, and a failure is the open's.
  private async attachIfBack(sessionId: string, generation: number): Promise<boolean> {
    const row = this.sessions.find((session) => session.sessionId === sessionId);
    if (this.copyBack !== sessionId || !peerBack(row)) return false;
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return false;
    this.copyBack = undefined;
    this.resetSessionState();
    return this.attach(sessionId, generation, 0).then(
      () => true,
      () => false,
    );
  }

  /// Whether the selected chat, attached with nothing out, is listed now as another session than
  /// the one its rows are of: the machine recreated it (another `createdAt`) or it moved to another
  /// machine (another `peer`, or a peer's chat now on this Mac). Its rows are another journal then,
  /// and records of the new session would land under them (`apply` takes a record by its id and
  /// seq alone). A row that names no `createdAt` says nothing of its session.
  private rowMovedOn(row: SessionSummary): boolean {
    if (this.attachedGeneration !== this.selectionGeneration || this.attachOut) return false;
    // Rows proven of a session (an attach set these): none drawn says nothing to compare, so a
    // read that failed is not tried again on every row change.
    if (this.rowsPeer === undefined && typeof this.rowsGeneration !== "number") return false;
    const peer = typeof row.peer === "string" ? row.peer : undefined;
    if (peer !== this.rowsPeer) return true;
    return (
      typeof row.createdAt === "number" &&
      typeof this.rowsGeneration === "number" &&
      row.createdAt !== this.rowsGeneration
    );
  }

  /// The chat on screen is listed as another session now (`rowMovedOn`): its rows go, and the
  /// session listed now is read from nothing, as a switch to it would, behind the same snapshot hold
  /// (the pane keeps what it drew until the page is in). One attach per such row change, owned as
  /// any (`copyAttaches`): a reconnect's that starts meanwhile decides. Down, the Mac's copy of the
  /// new session is drawn if it has one (`keepPeerCopy`); else the pane says it could not read it.
  private async reattachMovedRow(sessionId: string): Promise<void> {
    // A selection of its own, as a switch takes: every read still out for the session before (an
    // older page, its commands, the reads after its attach) checks the generation it was asked
    // under, so it lands on nothing.
    const generation = ++this.selectionGeneration;
    const hold = this.holdSnapshots(SWITCH_HOLD_MS);
    this.resetSessionState();
    // An older page in flight was read of the session before: it lands on nothing (`fetchOlder`).
    this.historyEpoch += 1;
    const mine = ++this.copyAttaches;
    try {
      await this.attach(sessionId, generation, 0);
    } catch (error) {
      if (mine !== this.copyAttaches) return;
      if (await this.keepPeerCopy(sessionId, generation, error)) return;
      if (generation === this.selectionGeneration && this.selectedSessionId === sessionId)
        this.emit(this.socket?.readyState === WebSocket.OPEN ? "failed" : "disconnected");
    } finally {
      this.releaseSnapshots(hold);
    }
  }

  /// After a copy was marked offline: its row said the machine was back while the copy's attach
  /// or read was out (`copyBack`), so it is read from the machine again now. Once per such row
  /// change, never a loop: an attach that fails again waits for the next one.
  private reattachIfBack(sessionId: string): void {
    if (this.copyBack !== sessionId) return;
    this.copyBack = undefined;
    void this.reattachPeerCopy(sessionId);
  }

  /// The machine of the chat shown from the Mac's copy answers again: the chat attaches as on open,
  /// with the rows drawn as its kept tail (a page that joins them continues them, each seq once; one
  /// that does not, or a recreated session, replaces them). Down again, the copy stays offline; any
  /// other failure takes the copy off screen, as a failed open does. One attach of the copy at a
  /// time (`attaching`, set by the open's attach too).
  private async reattachPeerCopy(sessionId: string): Promise<void> {
    const copy = this.peerCopy;
    if (!copy?.offline || copy.attaching || copy.sessionId !== sessionId) return;
    this.copyBack = undefined;
    copy.offline = false;
    copy.attaching = true;
    const generation = this.selectionGeneration;
    const mine = ++this.copyAttaches;
    try {
      await this.attach(sessionId, generation, copy.lastSeq);
    } catch (error) {
      // A reconnect's attach took the copy over meanwhile: its outcome decides.
      if (mine !== this.copyAttaches) return;
      if (await this.keepPeerCopy(sessionId, generation, error)) return;
      if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return;
      this.dropPeerCopy(sessionId);
    }
  }

  /// The session of a chat shown offline from the Mac's copy was recreated while its machine stays
  /// down: the old copy goes, and the Mac's copy of the new session is drawn, offline, when it has
  /// one; else the chat is off screen as after a failed open, and opens again once the machine is.
  private async redrawPeerCopy(sessionId: string): Promise<void> {
    const generation = this.selectionGeneration;
    // Everything of the old session goes, its queue and prompts not yet sent too, as for a switch.
    this.resetSessionState();
    const drawn = await this.drawPeerCopy(sessionId, generation);
    const copy = this.peerCopy as PeerCopy | undefined;
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return;
    if (drawn === 0 || copy?.sessionId !== sessionId) {
      this.dropPeerCopy(sessionId);
      // A machine that came back meanwhile opens the chat itself.
      const row = this.sessions.find((session) => session.sessionId === sessionId);
      if (this.copyBack === sessionId && peerBack(row)) {
        this.copyBack = undefined;
        // Owned like any attach of the copy: a reconnect's takes it over; down again, the
        // Mac's copy is drawn if it has one.
        const mine = ++this.copyAttaches;
        void this.attach(sessionId, generation, 0).catch(async (error: unknown) => {
          if (mine === this.copyAttaches) await this.keepPeerCopy(sessionId, generation, error);
        });
      }
      return;
    }
    copy.offline = true;
    copy.attaching = false;
    this.emit("peer offline");
    this.reattachIfBack(sessionId);
  }

  /// An open that failed before its attach of the copy answered (the socket, the handshake or the
  /// list) leaves the copy offline with no attach out, so a row that says its machine is back
  /// reads it again (`sessionChanged`). Only while no later attach of the copy took it over.
  private releaseCopyAttach(mine: number): void {
    const copy = this.peerCopy;
    if (mine !== this.copyAttaches || !copy?.attaching || copy.sessionId !== this.selectedSessionId) return;
    copy.attaching = false;
    copy.offline = true;
    this.emit("peer offline");
  }

  /// The rows drawn from the Mac's copy are not the chat (its machine failed another way, or the
  /// session was recreated while it is offline): as after a failed open or select, they go, and no
  /// tail of the chat is drawn again as if it had been read.
  private dropPeerCopy(sessionId: string): void {
    forgetTail(sessionId);
    // Everything of it goes, its cursors too: a recreated session's attach later starts its seqs
    // over, and none of them may read as already held.
    this.resetSessionState();
    this.rebuild();
    this.emit("failed");
  }

  private drawKeptTail(sessionId: string, kept = keptTail(sessionId)): number {
    if (!kept) return 0;
    this.drawnGeneration = typeof kept.summary?.createdAt === "number" ? kept.summary.createdAt : undefined;
    this.rowsGeneration = this.drawnGeneration;
    const keptPeer = (kept.summary as { peer?: unknown } | undefined)?.peer;
    this.rowsPeer = typeof keptPeer === "string" ? keptPeer : undefined;
    const listed = this.sessions.find((session) => session.sessionId === sessionId);
    this.events = [...kept.events];
    this.turnOpener = kept.turnOpener;
    this.historyExhausted = kept.historyExhausted;
    this.configSeq = kept.configSeq;
    this.usageFromSeq = kept.usageFromSeq;
    // Seed replay from the kept session identity before rebuilding: SubagentFold must know the
    // native root while it consumes the historical events, not after the malformed tree is drawn.
    const keptSummary = { ...kept.summary, ...listed };
    this.summary = keptSummary;
    this.rebuild();
    // A session_changed can carry newer live state than the kept tail. Restore it after replay;
    // only the root identity needs to be visible during the fold rebuild itself.
    this.summary = keptSummary;
    this.learnChatThread();
    // A paused queue's failed turn no longer runs, whatever status acpmux last listed (`staleRun`).
    this.turnOpen = listed?.status === "running" && !this.staleRun(listed);
    // Only acpmux says what is pending (attach's `session.pending`): a replayed ask is history
    // here. The marks it left on its own rows (an edit "awaiting permission") stand until the
    // attach replays the page, as they do on a page whose decision it does not hold either.
    this.pendingPermission = undefined;
    this.waitingPermissions = new Map();
    this.pendingSecret = undefined;
    // A teammate's prompt whose authored record fell out of the kept tail keeps the author its row
    // had when the tail was kept (this page's or another tab's): acpmux's list names none.
    for (const entry of kept.queue) {
      const author = participant(entry?.author?.id, entry?.author?.name);
      if (author && !this.queueAuthors.has(entry.id)) this.queueAuthors.set(entry.id, author);
    }
    // The replayed `queued` records carry each prompt's whole text; acpmux's list gives the order.
    this.queue = mergeQueue(this.queue, listed?.queue ?? kept.queue, this.queueAuthors, this.queueEdited);
    // From the frame the rows are drawn, not from the attach: a live record of the chat that comes
    // before it is asked (while the chat left detaches) is held too (`copyLive`).
    if (this.lastSeq > 0) this.copyLive = new Map();
    return this.lastSeq;
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer !== undefined || this.closed) return;
    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(delay * 2, 30_000);
    this.wire.lifecycle("reconnect scheduled", { delayMs: delay });
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = undefined;
      void this.open().catch(() => this.scheduleReconnect());
    }, delay);
  }

  private receive(raw: string, stale = false): void {
    this.wire.received(raw);
    // A frame that is not a JSON object is dropped like one that is not JSON (`null` would throw at `in`).
    const message = parseJsonObjectFrame(raw) as Reply | Notification | null;
    if (!message) return;
    if ("id" in message && (typeof message.id === "number" || typeof message.id === "string")) {
      const request = this.pending.get(message.id);
      if (!request) return;
      this.pending.delete(message.id);
      if (request.timer) clearTimeout(request.timer);
      // The failure's code (`validation.invalid`, ...) and details ride along for callers that
      // tell failures apart.
      if (message.error) {
        const data = message.error.data as
          | { code?: unknown; details?: unknown; reason?: unknown; detail?: unknown }
          | undefined;
        request.reject(
          Object.assign(new AcpmuxRpcError(message.error), {
            code: data?.code ?? message.error.code,
            ...(data?.details === undefined ? {} : { details: data.details }),
            // acpmux's own refusals name their reason (`trust.pending`, `remote.mode_not_asking`).
            ...(typeof data?.reason === "string" ? { reason: data.reason } : {}),
            // A host refusal can carry acpmux's own words (a refused Enable harness prompt).
            ...(typeof data?.detail === "string" ? { detail: data.detail } : {}),
            // A trust refusal names the folder it asks about (the folder acpmux resolved).
            ...(typeof (data as { cwd?: unknown } | undefined)?.cwd === "string"
              ? { cwd: (data as { cwd: string }).cwd }
              : {}),
          }),
        );
      } else request.resolve(message.result);
      return;
    }
    const notification = message as Notification;
    if (notification.method === "_acpmux/peer_state_changed") {
      if (!stale && !this.closed && this.peerEvents.changed(notification.params)) {
        this.applyPeerStates();
        if (!this.snapshotHold) this.emit();
      }
      return;
    }
    // The host captured Return before the card's handler. Adopt its id before the native send,
    // retaining the normal RPC refusal, timeout and disconnect behavior for the waiting card.
    if (notification.method === "_cmux/question_key_request") {
      const request = notification.params;
      if (isQuestionKeyRequest(request) && !this.pending.has(request.id)) {
        deliverQuestionKeyRequest(request, this.expectReply(request.id, "_acpmux/permission_respond", 30_000));
      }
      return;
    }
    // Who else is in the chat, ephemeral (multiplayer/presenceClient.ts): never a record.
    if (notification.method === "_acpmux/presence") {
      this.presence.notification(notification.params);
      return;
    }
    if (notification.method === "_acpmux/event") {
      // A chat started from an offer here, watched for its row (offer/offerChildren.ts).
      const params = notification.params ?? {};
      if (params.sessionId !== this.selectedSessionId && this.offerChildren.event(params)) return;
      this.observeClock(notification.params?.sessionId, notification.params?.at);
      this.apply(notification.params as EventRecord);
    } else if (notification.method === "session/update") {
      this.observeClock(notification.params?.sessionId, notification.params?._meta?.acpmux?.at);
      this.apply({
        sessionId: notification.params?.sessionId,
        seq: Number(notification.params?._meta?.acpmux?.seq ?? 0),
        at: Number(notification.params?._meta?.acpmux?.at ?? Date.now()),
        dir: "in",
        kind: String(notification.params?.update?.sessionUpdate ?? ""),
        msg: { method: "session/update", params: { update: notification.params?.update } },
      });
    } else if (isNotification(notification, "_acpmux/session_changed")) this.sessionChanged(notification.params);
    else if (isNotification(notification, "_acpmux/permission_pending")) {
      this.asks.pending(notification.params);
      this.applyPermission(notification.params);
    } else if (notification.method === "_acpmux/lagged") this.resyncAfterLag(notification.params);
    // acpmux took a prompt this connection sent; it comes even when the event stream lags.
    else if (notification.method === "_acpmux/prompt_accepted") {
      const promptId = notification.params?.promptId;
      if (typeof promptId === "string") {
        this.promptAccepts.get(promptId)?.();
        this.promptShown?.(promptId);
      }
    }
    // A profile change may pin or free a harness's mode, which changes a new chat's start mode too.
    else if (notification.method === "_acpmux/harnesses_changed") {
      this.onHarnessesChanged?.();
      startModeChanged();
    } else if (notification.method === "_acpmux/process_update")
      for (const listener of this.processListeners) listener(notification.params?.process);
    // A new chat's start mode may have changed (a config reload, the
    // `agents.defaultPermissionMode` setting): pending chats ask acpmux again (startMode.ts).
    else if (notification.method === "_acpmux/start_mode_changed") startModeChanged();
    // acpmux refused this pane's Stop, which as a notification has no answer of its own.
    else if (notification.method === "_acpmux/cancel_refused") this.stopRefused(notification.params);
  }

  /// A Stop acpmux refused (`_acpmux/cancel_refused`: a chat on another machine that only its owner
  /// can stop, a mode a paired device cannot stop): the turn runs on, so it no longer reads as
  /// stopping, and the chat says why instead of looking as if Stop did nothing. Only the answer to the
  /// Stop still waiting counts: none waits, or the refusal names another turn than the one stopped
  /// (`turnId`), and it is a late answer to an earlier Stop.
  private stopRefused(params: any): void {
    if (typeof params?.sessionId !== "string" || params.sessionId !== this.actingSessionId) return;
    if (this.stoppingAfterSeq === undefined) return;
    if (typeof params.turnId === "string" && this.stoppedTurnId !== undefined && params.turnId !== this.stoppedTurnId)
      return;
    this.stopAfterSeq = undefined;
    this.stoppingEnded();
    const reason =
      typeof params.message === "string" && params.message ? params.message : translate("transport.refused");
    this.notice(translate("queue.stopRefused", { reason }));
  }

  /// The daemon dropped events for this client. Fetch what came after the last
  /// one seen and merge it in, keeping the transcript on screen meanwhile.
  /// agent-gui daemons send {sessionIds, watch, dropped}; older ones send only
  /// {dropped}, so a notice without sessionIds resyncs the selected session.
  private resyncAfterLag(params: any): void {
    // Peer state notices may be among the dropped ones: read the snapshot again, so a machine that
    // went down while this client lagged never shows as connected (no session needs to be open).
    if (this.peerEvents.supported) void this.refreshPeerStatesAndEmit();
    // Needs you's asks: notices of new or answered requests may be lost, so every chat with open
    // requests is read again (after the session list, which drops the chats acpmux no longer lists).
    if (params?.watch === true)
      void this.refreshSessions()
        .then((settled) => {
          // Not settled: a newer read sets the list; the reread after it resyncs the asks.
          if (settled) this.asks.resync(this.sessions);
          else this.rereadSessionsLater(true);
        })
        .catch(() => this.rereadSessionsLater(true));
    else if (Array.isArray(params?.sessionIds)) this.asks.resync(this.sessions, new Set(params.sessionIds.map(String)));
    const sessionId = this.selectedSessionId;
    // Before the attach reply lands there is no cursor; the reply carries the latest events.
    if (!sessionId || this.attachedGeneration !== this.selectionGeneration) return;
    if (Array.isArray(params?.sessionIds) && !params.sessionIds.map(String).includes(sessionId)) return;
    this.emit("resyncing");
    void this.permissions.refresh().catch(() => {});
    const generation = this.selectionGeneration;
    void this.fetchMissedEvents(sessionId, generation, this.lastSeq).catch(() => {
      if (!this.closed && generation === this.selectionGeneration)
        this.emit(this.socket?.readyState === WebSocket.OPEN ? "failed" : "disconnected");
    });
  }

  /// The pane positions whose stall was checked already (`checkStall`): one check per position.
  private readonly stallChecked = new Set<string>();
  /// A send to the shown chat went slow: when acpmux holds an event after the pane's last one that it
  /// wrote a while ago, the pane missed the chat's events, and the log says so (stallLog.ts). A hidden
  /// page holds its frames on purpose, so it is not checked; each position is checked once.
  private checkStall(sessionId: string): void {
    if (this.closed || this.selectedSessionId !== sessionId || !pageShown()) return;
    const paneSeq = this.lastSeq;
    const key = `${sessionId} ${paneSeq}`;
    if (this.stallChecked.has(key)) return;
    this.stallChecked.add(key);
    const connection = this.socket?.readyState === WebSocket.OPEN ? "open" : "not open";
    void this.typed("_acpmux/events", { sessionId, afterSeq: paneSeq, limit: 1 }, STALL_CHECK_MS).then(
      (result) => {
        const line = stallLine(sessionId, paneSeq, records(result?.events)[0], Date.now(), connection);
        if (line) console.error(line);
      },
      (error: unknown) =>
        console.error(
          `agent pane stall check: session ${sessionId}: acpmux did not answer its events after seq ${paneSeq}: ${String((error as { code?: unknown } | null)?.code ?? error)}; connection ${connection}`,
        ),
    );
  }

  /// Pages from its own cursor: live events keep advancing lastSeq meanwhile.
  /// The live summary, queue and permission survive the rebuild; after a lag the
  /// missed events are replayed onto them, while a fresh attach is already current.
  private async fetchMissedEvents(
    sessionId: string,
    generation: number,
    afterSeq: number,
    replayLiveState = true,
  ): Promise<void> {
    for (let cursor = afterSeq; ;) {
      const result = await this.typed("_acpmux/events", {
        sessionId,
        afterSeq: cursor,
        limit: 5_000,
      });
      if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return;
      const missed = records(result?.events);
      this.events = mergeEventRecords(this.events, missed);
      this.sawPrompts(missed);
      this.rebuildKeepingLiveState(replayLiveState ? cursor : undefined);
      if (result?.hasMore !== true || missed.length === 0) break;
      cursor = Math.max(cursor, ...missed.map((event) => event.seq));
    }
    this.emit("resynced");
  }

  /// session_changed notices dropped by a watch lag: reread the whole list.
  /// A selection made while the request was out is newer than the list.
  /// True once this read set the list (false when a newer reread will).
  private async refreshSessions(firstRead = this.sessionPages.first()): Promise<boolean> {
    const generation = this.selectionGeneration;
    const first = await firstRead;
    // A newer reread started meanwhile; it sets the list.
    if (!first) return false;
    let list = first.sessions;
    const add = (more: Session[]) => {
      list = [...list, ...more];
    };
    if (first.next && !(await this.sessionPages.rest(first, () => list, add))) return false;
    // Changes that came while the pages did are newer than the pages.
    this.sessions = this.sessionPages.settle(list);
    this.listedSessions = true;
    this.recheckSenders(this.sessions);
    this.learnChatThread();
    const missing =
      this.selectedSessionId !== undefined &&
      !this.sessions.some((session) => session.sessionId === this.selectedSessionId);
    if (missing && generation === this.selectionGeneration) this.selectFallbackSession("session changed");
    else if (!this.reopenMissing()) this.emit("session changed");
    return true;
  }

  /// The open's chat row from the attach asked with the list (`askEarly`), when that attach answers
  /// first, for this chat on this machine: the open then draws the chat without the list. A busy
  /// acpmux paces its full session list (hub/list_guard.rs: one build per window, up to 15 s, and
  /// every streaming agent makes the last build stale), so a cold open waited on it for 3 to 30 s
  /// behind "Waiting for the agent service" while the attach had answered in under a second (Leo,
  /// 2026-10-30: "WHY DID IT TAKE 30 FUCKING SECONDS TO LOAD YOUR CHAT"). The attach's answer
  /// proves the chat is there; the list settles behind the open (`listAfterOpen`). Undefined: the
  /// list came first, or the attach failed or named another chat or machine, so the open waits
  /// for the list and decides with it as before. A remote wire's pane keeps the list first: its
  /// machine names the tab's chat there (`tab`).
  private async attachedBeforeList(early: EarlyAttach, listRead: Promise<unknown>): Promise<Session | undefined> {
    if (!this.localOrigin) return undefined;
    const listed = listRead.then(ignore, ignore);
    return Promise.race([
      listed,
      early.sent.attaching.then(
        (result) => attachedLocalRow(result, early.sessionId) ?? listed,
        () => listed,
      ),
    ]);
  }

  /// The list an open that drew its chat from the attach (`attachedBeforeList`) did not wait for:
  /// read to its end and laid over what changed meanwhile, as a reread after a lag is. A list that
  /// fails is read again a moment later.
  private async listAfterOpen(listRead: Promise<SessionPage<Session> | undefined>): Promise<void> {
    await this.refreshSessions(listRead).catch(() => this.rereadSessionsLater());
  }

  /// Notes that the tab's chat `sessionId` is not listed: from now on the pane says why
  /// (chatUnavailable.ts) until the chat is listed again or another one is selected.
  private noteMissing(sessionId: string | undefined): void {
    if (sessionId === undefined) return;
    if (this.missingSession !== sessionId) {
      this.missingSince = Date.now();
      // The machine the chat was on: the summary it had here (it went away while shown, or before a
      // reconnect), else what this page or the app host kept of it.
      const shown = this.summary?.sessionId === sessionId ? this.summary?.peer : undefined;
      this.missingPeer = typeof shown === "string" && shown ? shown : keptPeer(sessionId);
    }
    this.missingSession = sessionId;
  }

  /// The missing chat is listed again (its machine connected and acpmux listed its chats): it
  /// opens, as the tab's own chat. True when it does. An open that fails (its machine dropped again
  /// before the attach) leaves the chat missing as it was, so the pane says why again and the next
  /// listing or Reconnect opens it.
  private reopenMissing(): boolean {
    const missing = this.missingSession;
    if (this.selectedSessionId !== undefined || missing === undefined || this.closed) return false;
    if (!this.sessions.some((session) => session.sessionId === missing)) return false;
    const [reason, since, peer] = [this.missingReason, this.missingSince, this.missingPeer];
    const opening = this.select(missing);
    // select() takes its generation before its first await: a newer selection (even of this same
    // chat, switching away and back) moves it, and this failure is then not the pane's to undo.
    const generation = this.selectionGeneration;
    void opening.catch(() => {
      if (this.closed || generation !== this.selectionGeneration || this.selectedSessionId !== missing) return;
      this.wire.lifecycle("reopen failed", { sessionId: missing });
      this.selectedSessionId = undefined;
      this.selectionGeneration += 1;
      this.resetSessionState();
      [this.missingSession, this.missingReason, this.missingSince, this.missingPeer] = [missing, reason, since, peer];
      this.emit("session changed");
      void this.refreshPeers()
        .catch(() => undefined)
        .then(() => {
          if (!this.closed && !this.snapshotHold) this.emit();
        });
    });
    return true;
  }

  /// Why the tab's chat is not here, while the pane shows none; a machine still connecting is read
  /// again shortly, so the pane says "offline" only once acpmux gave up on its first attempts.
  private unavailableNow(): ChatUnavailable | undefined {
    if (this.selectedSessionId !== undefined || this.missingSession === undefined) return undefined;
    const unavailable = chatUnavailable({
      ...(this.missingPeer !== undefined ? { peer: this.missingPeer } : {}),
      peers: this.peerStatus,
      waitedMs: Date.now() - this.missingSince,
      seenListed: this.missingReason === "leftListWhileShown",
    });
    if (unavailable.reason === "connecting" && this.missingRecheck === undefined && !this.closed)
      this.missingRecheck = setTimeout(() => {
        this.missingRecheck = undefined;
        if (this.closed) return;
        void this.refreshPeers()
          .catch(() => undefined)
          .then(() => {
            if (!this.closed && !this.snapshotHold) this.emit();
          });
      }, MISSING_RECHECK_MS);
    return unavailable;
  }

  /// Reconnect on the unavailable chat: reads the machines and the chat list again now, and opens
  /// the chat when it is listed.
  async recheckMissing(): Promise<void> {
    if (this.missingSession === undefined || this.selectedSessionId !== undefined) return;
    await this.refreshPeers().catch(() => undefined);
    await this.refreshSessions().catch(() => undefined);
    // Listed but not open (an earlier open failed): open it now.
    if (!this.reopenMissing() && !this.closed && !this.snapshotHold) this.emit();
  }

  /// The selected session is gone: a tab bound to its session (`sessionMustExist`) says so;
  /// any other pane shows the most recent remaining one, or none.
  private selectFallbackSession(reason: string): void {
    if (this.host.sessionMustExist) {
      this.noteMissing(this.selectedSessionId);
      this.missingReason = "leftListWhileShown";
    }
    const purging =
      this.selectedSessionId !== undefined &&
      (this.purgingSessionId === this.selectedSessionId || this.purgedSessionId === this.selectedSessionId);
    if (purging) this.purgedSessionId = undefined;
    const from = this.selectedSessionId;
    this.selectedSessionId = this.host.sessionMustExist || purging ? undefined : this.sessions[0]?.sessionId;
    if (this.selectedSessionId) this.markSeen(this.selectedSessionId);
    const generation = ++this.selectionGeneration;
    this.fallback = from ? { from, generation } : undefined;
    const hold = this.selectedSessionId ? this.holdSnapshots(SWITCH_HOLD_MS) : undefined;
    this.resetSessionState();
    this.emit(reason);
    // The tab's chat went away while shown: why (chatUnavailable.ts) reads the machines as they are now.
    if (this.host.sessionMustExist && this.selectedSessionId === undefined && this.missingSession !== undefined)
      void this.refreshPeers().catch(() => undefined);
    if (this.selectedSessionId)
      void this.attach(this.selectedSessionId, generation)
        .catch(() => undefined)
        .finally(() => {
          if (hold !== undefined) this.releaseSnapshots(hold);
        });
  }

  /// The pages after the first, read once the chat is open. acpmux owns `unread` (cx-n8ou): the
  /// pane only tells it whether it shows its chat (`attach` `visible`, `_acpmux/view`).
  private async readLaterSessions(first: SessionPage<Session>): Promise<void> {
    await this.sessionPages.rest(first, () => this.sessions, this.addSessions).catch(() => this.rereadSessionsLater());
  }

  /// A list that could not be read to its end (a page and the whole-list fallback both failed)
  /// is read again once, a moment later, rather than left at the pages that came. `resyncAsks`:
  /// the read follows a watch lag, so once it sets the list Needs you's asks are read again too.
  private rereadSessionsLater(resyncAsks = false): void {
    if (resyncAsks) this.sessionRereadResyncsAsks = true;
    if (this.closed || this.sessionReread) return;
    this.sessionReread = setTimeout(() => {
      this.sessionReread = undefined;
      const resync = this.sessionRereadResyncsAsks;
      this.sessionRereadResyncsAsks = false;
      if (!this.closed)
        void this.refreshSessions()
          .then((settled) => {
            if (settled && resync) this.asks.resync(this.sessions);
          })
          .catch(() => undefined);
    }, SESSION_REREAD_MS);
  }

  private addSessions = (more: Session[]): void => {
    this.sessions = [...this.sessions, ...more];
    this.recheckSenders(more);
    this.learnChatThread();
    if (!this.opening) this.emit("session changed");
  };

  /// The page was hidden or shown (a tab in a background workspace, an occluded window): acpmux
  /// leaves a turn that ends while nobody shows the chat unread, and showing it is seeing it.
  private showChanged = (): void => {
    if (this.listChangedWhileHidden && pageShown() && !this.closed) {
      this.listChangedWhileHidden = false;
      this.emitInFrame("session changed");
    }
    const sessionId = this.selectedSessionId;
    if (!sessionId || this.closed) return;
    this.syncView();
    if (pageShown()) this.markSeen(sessionId);
  };

  /// Brings acpmux's view of the selected chat up to the page's. acpmux handles each request on
  /// its own task, so a view must wait for the attach it changes and for the view before it.
  private syncView(): void {
    const generation = this.selectionGeneration;
    this.viewSync = this.viewSync.then(async () => {
      await this.attaching;
      const sessionId = this.selectedSessionId;
      const visible = pageShown();
      if (
        generation !== this.selectionGeneration ||
        !sessionId ||
        this.closed ||
        this.shownToAcpmux?.sessionId !== sessionId
      )
        return;
      if (this.shownToAcpmux.visible === visible) return;
      await this.typed("_acpmux/view", { sessionId, visible }).then(
        () => {
          if (generation === this.selectionGeneration && this.selectedSessionId === sessionId)
            this.shownToAcpmux = { sessionId, visible };
        },
        () => undefined,
      );
    });
  }

  /// Selecting a session is seeing it, including an unread flag acpmux sent.
  private markSeen(sessionId: string): void {
    this.sessions = this.sessions.map((session) =>
      session.sessionId === sessionId && session.unread === true ? { ...session, unread: false } : session,
    );
  }

  /// Whether the user trusts `cwd` (folderTrust.ts).
  trustGet(cwd: string): Promise<unknown> {
    return this.request("acp.trust.get", {
      cwd,
      ...(this.selectedSessionId ? { sessionId: this.selectedSessionId } : {}),
    });
  }

  /// Records the user's trust in `cwd` in acpmux's own record, never the agents' config files (folderTrust.ts).
  trustSet(cwd: string, level: string): Promise<unknown> {
    return this.request("acp.trust.set", {
      cwd,
      level,
      ...(this.selectedSessionId ? { sessionId: this.selectedSessionId } : {}),
    });
  }

  /// Chat `sessionId`'s background processes (acpmux docs/background-processes.md).
  listProcesses(sessionId: string): Promise<unknown> {
    return this.request("_acpmux/process/list", { sessionId });
  }

  /// Each `_acpmux/process_update` for the attached chat; returns the listener's removal.
  watchProcesses(listener: (process: unknown) => void): () => void {
    this.processListeners.add(listener);
    return () => void this.processListeners.delete(listener);
  }

  /// The end of background process `processId`'s output, at most `maxBytes` (acpmux reads at most
  /// 1 MiB): `{data (base64), fromByte, nextByte, eof}`. Claude Code's processes only.
  tailProcess(processId: string, maxBytes: number): Promise<unknown> {
    return this.request("_acpmux/process/tail", { processId, maxBytes });
  }

  /// Stops background process `processId` (Claude's stop_task, Codex's terminate). A harness
  /// that never answers fails it after 10 s. It names its chat (`<sessionId>/<taskId>`'s): the host
  /// lets only a chat in the pane's scope stop one, and acpmux stops only that chat's process.
  killProcess(processId: string): Promise<unknown> {
    const sessionId = processId.split("/")[0] ?? "";
    return this.request("_acpmux/process/kill", { sessionId, processId }, 10_000);
  }

  /// How many of chat `sessionId`'s sub-sessions run a turn at once: `maxRunning` (1 to 1000), or
  /// `null` to drop the chat's own limit for the one it inherits (an ancestor's, the workspace's,
  /// the settings' or acpmux's default). acpmux answers `{sessionId, subsessionLimits}` and logs a
  /// `limits` record; the selected chat's summary takes the reply's limits at once.
  ///
  /// A step (− or +) names the limit it stepped `from`. A chat's inherited limit moves with no
  /// record of its own (an ancestor's, the workspace's or the settings' changed), so unless the
  /// chat's own limit is known here, acpmux is read first, and a limit that is no longer `from`
  /// is stepped from instead: + on a stale 16 when acpmux holds 20 sets 21, never 17. Changes run
  /// one after another, each from the answer before it, so quick clicks never step from the same
  /// number twice.
  setRunningLimit(sessionId: string, maxRunning: number | null, from?: number): Promise<void> {
    const run = this.limitsChain.then(() => this.applyRunningLimit(sessionId, maxRunning, from));
    this.limitsChain = run.catch(() => undefined);
    return run;
  }

  private async applyRunningLimit(sessionId: string, maxRunning: number | null, from?: number): Promise<void> {
    let value = maxRunning;
    if (value !== null && from !== undefined) {
      // The chat's own limit is current here only once this selection's attach is in: a kept tail
      // drawn before it is what an earlier visit saw, and another client may have moved it since.
      const attached = sessionId === this.selectedSessionId && this.attachedSession() === sessionId;
      const known = attached ? subsessionLimits(this.summary?.subsessionLimits) : undefined;
      const current = known?.maxRunningSource === "session" ? known : await this.readRunningLimit(sessionId);
      if (current && current.maxRunning !== from) value = clampRunning(current.maxRunning + (value - from));
    }
    const seen = this.limitsVersion;
    const result = await this.request("_acpmux/subsession/limits", { sessionId, maxRunning: value }, 10_000);
    this.takeRunningLimit(sessionId, result?.subsessionLimits, seen);
  }

  /// Chat `sessionId`'s limits as acpmux holds them now (`_acpmux/subsession/limits` naming no
  /// field only reads them). A read that something overtook while it was in flight (a `limits`
  /// record, a chat selected or attached: `limitsVersion` moved) may be older than acpmux's limit,
  /// and neither the summary nor a kept tail proves which is newer, so it is read again, at most
  /// `LIMIT_READS` times. A step builds only on a read nothing overtook: if every read was, the
  /// step is refused (the stepper says so and shows acpmux's limit) rather than written from a
  /// number known to be stale.
  private async readRunningLimit(sessionId: string) {
    for (let read = 0; read < LIMIT_READS; read++) {
      const seen = this.limitsVersion;
      const result = await this.request("_acpmux/subsession/limits", { sessionId }, 10_000);
      this.takeRunningLimit(sessionId, result?.subsessionLimits, seen);
      if (this.limitsVersion === seen) return subsessionLimits(result?.subsessionLimits);
    }
    // l10n-allow: a developer error for the limit's reader; never shown.
    throw new Error("the running limit kept changing while it was read");
  }

  /// A reply carries no seq, so it is current only as of the request: a `limits` record, a new
  /// attach or another chat selected while it was in flight (`limitsVersion` moved) is newer, and
  /// the reply never takes the limit back from it (a streamed 20 then the older reply's 9 would
  /// make the next + send 10).
  private takeRunningLimit(sessionId: string, limits: unknown, seen: number) {
    if (sessionId !== this.selectedSessionId || !limits || typeof limits !== "object") return;
    if (this.limitsVersion !== seen) return;
    this.summary = { ...this.summary, subsessionLimits: limits };
    this.emit("subsession limits");
  }

  /// Ctrl-B: moves the selected Claude Code chat's foreground work to the background, only the
  /// call `toolCallId` started or all of it (Claude Code's `background_tasks`). acpmux answers
  /// `{backgrounded}` and refuses another harness's chat; a Claude that never answers fails it
  /// after 10 s.
  backgroundWork(toolCallId?: string): Promise<unknown> {
    if (!this.selectedSessionId) return Promise.reject(new Error());
    const params = { sessionId: this.selectedSessionId, ...(toolCallId ? { toolCallId } : {}) };
    return this.request("_acpmux/process/background", params, 10_000);
  }

  /// Reconnects MCP server `server` (its `mcpServers` name) of the Claude Code chat on screen: acpmux
  /// sends Claude Code's mcp_reconnect and answers `{}`, or Claude Code's error; another harness's
  /// chat is refused. Once it reconnected, the server reads connected in the chat's `mcpServers`.
  /// During a switch's hold that is the chat the Inspector still draws (`actingSessionId`), whose
  /// server the button names, not the chat opening.
  /// The app's pane relay must allow `_acpmux/mcp/reconnect` (cmux-agent-pane-policy) first.
  reconnectMcp(server: string): Promise<unknown> {
    const sessionId = this.actingSessionId;
    if (!sessionId) return Promise.reject(new Error());
    return this.request(MCP_RECONNECT_METHOD, { sessionId, server }, 35_000);
  }

  /// Reads only this pane's selected chat; the native relay enforces the same scope.
  readWorkflowAgent(params: {
    sessionId: string;
    runId: string;
    agentId: string;
    before?: number;
    after?: number;
  }): Promise<unknown> {
    // l10n-allow: internal selection race; the transcript surface renders its own localized state.
    if (params.sessionId !== this.selectedSessionId) return Promise.reject(new Error("Session changed"));
    return this.request("_acpmux/subagent_transcript", params, 15_000);
  }

  /// Asks the local daemon to retry the configured peer and wait for its doctor result.
  /// The daemon returns the refreshed peer list; a settled state other than `connected` is a
  /// doctor refusal, which the offline banner renders as its failure detail.
  async reconnectPeer(peer: string): Promise<unknown> {
    const result = await this.request("_acpmux/peer_reconnect", { name: peer, wait: true }, 35_000);
    this.readPeers(result);
    const row = Array.isArray(result?.peers)
      ? result.peers.find((candidate: any) => candidate?.name === peer)
      : undefined;
    if (row?.state !== "connected") {
      const detail =
        typeof row?.error === "string"
          ? row.error
          : typeof row?.error?.message === "string"
            ? row.error.message
            : `peer ${peer} is ${typeof row?.state === "string" ? row.state : "unreachable"}`;
      throw new Error(detail);
    }
    // A reconnect can settle without changing the session summary, so no
    // `session_changed` notice is guaranteed to arrive. Take the held copy
    // over directly once the daemon's doctor says this peer is connected.
    const copy = this.peerCopy;
    if (copy?.offline && copy.peer === peer) await this.reattachPeerCopy(copy.sessionId);
    return result;
  }

  /// Stops one of the selected session's running subagents (a Claude agent or workflow); acpmux
  /// sends Claude's stop_task and answers with Claude's answer, and the subagent ends as cancelled
  /// when Claude stops it. A Claude that never answers fails it after 10 s.
  stopSubagent(subagentSessionId: string): Promise<unknown> {
    if (!this.selectedSessionId) return Promise.reject(new Error());
    // Its end, when Claude stops it, reads "stopped by you" (subagentFold.ts `stopReasonOf`).
    const requested = this.subagentStops.requested;
    requested.add(subagentSessionId);
    return this.request(
      "_acpmux/subagent_stop",
      { sessionId: this.selectedSessionId, subagentSessionId },
      10_000,
    ).catch((error: unknown) => {
      requested.delete(subagentSessionId);
      throw error;
    });
  }

  /// acpmux's on-demand retry (subagents/retryState.ts `runRetry`): fires a waiting retry now, or
  /// retries the last failed turn or subagent. Its refusals name their code (`retry.busy`).
  retry(method: string, params: Record<string, unknown>): Promise<unknown> {
    return this.request(method, params, 15_000);
  }

  /// The capability ids acpmux's `initialize` named (`_meta.acpmux.capabilities`), or undefined
  /// from one that names none.
  capabilities: ReadonlySet<string> | undefined;

  /// Reads the selected session's durable composer draft from acpmux.
  readDraft(sessionId: string): Promise<unknown> {
    return this.request("_acpmux/draft_get", { sessionId });
  }

  /// Persists or clears the selected session's composer draft in acpmux.
  writeDraft(sessionId: string, text: string): Promise<unknown> {
    return this.request("_acpmux/draft_set", { sessionId, text });
  }

  /// The session's prompt bookmarks (`{bookmarks: [seq...]}`), kept in acpmux (threadMinimap/bookmarks.ts).
  readBookmarks(sessionId: string): Promise<unknown> {
    return this.request("_acpmux/bookmark_get", { sessionId });
  }

  /// Marks or unmarks the prompt logged at `seq`; acpmux answers with the session's marks.
  setBookmark(sessionId: string, seq: number, bookmarked: boolean): Promise<unknown> {
    return this.request("_acpmux/bookmark_set", { sessionId, seq, bookmarked });
  }

  /// Files under `path` (else the selected session's folder) whose path matches `query`, best
  /// first (fileSearchModel.ts). acpmux serves no file search: the native host runs it on the
  /// session host as `git.files.search`, and mock mode's in-page daemon answers it.
  fileSearch(path: string | undefined, query: string, limit: number): Promise<unknown> {
    if (this.gitRoute === "daemon") return this.request("file.search", { ...(path ? { path } : {}), query, limit });
    const sessionId = this.selectedSessionId;
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const entry = this.sessions.find((session) => session.sessionId === sessionId);
    const cwd = path ?? text(summary?.cwd) ?? text(entry?.cwd);
    if (!cwd) return Promise.reject(new Error(translate("error.noFolderSearch")));
    return postNative("file.search", { cwd, query, limit });
  }

  /// The selected session's repository changes in one git scope (changes/model.ts); `narrow` names
  /// files (`paths`) and their unchanged context (`context_lines`, changes/wholeFile.ts).
  gitDiff(scope: string, narrow: { paths?: string[]; context_lines?: number } = {}): Promise<unknown> {
    return this.git("git.diff", { scope, include_patch: true, ...narrow });
  }

  /// The selected session's branch, upstream and how far it is ahead and behind.
  gitStatus(): Promise<unknown> {
    return this.git("git.status", {});
  }

  /// Commits in the selected session's repository (`git.commit`; changes/gitWrite.ts builds
  /// the params and the idempotency key).
  gitCommit(params: Record<string, unknown>): Promise<unknown> {
    if (this.gitRoute === "daemon") return Promise.reject(new Error(translate("error.noFolderChanges")));
    return this.git("git.commit", params);
  }

  /// Pushes the selected session's branch (`git.push`); never forced.
  gitPush(params: Record<string, unknown>): Promise<unknown> {
    if (this.gitRoute === "daemon") return Promise.reject(new Error(translate("error.noFolderChanges")));
    return this.git("git.push", params);
  }

  /// Stages (or unstages) files of the selected session's repository, named as `git.diff` names
  /// them. Only the native host on this Mac writes: a chat read through a daemon has no Stage.
  gitStage(paths: string[], unstage: boolean): Promise<unknown> {
    if (this.gitRoute === "daemon") return Promise.reject(new Error(translate("error.noFolderChanges")));
    return this.git(unstage ? "git.unstage" : "git.stage", { paths });
  }

  /// Stages (or unstages) one hunk of a file (and a rename's previous path), named as for `gitStage`: `hunk` is its lines as
  /// `git.diff` showed them, and the native host applies only the hunk it finds with those lines.
  gitStageHunk(paths: string[], hunk: string[], unstage: boolean): Promise<unknown> {
    if (this.gitRoute === "daemon") return Promise.reject(new Error(translate("error.noFolderChanges")));
    return this.git(unstage ? "git.unstageHunk" : "git.stageHunk", { paths, hunk });
  }

  /// Opens the pull request of the selected session's pushed branch (`{url, number}`), or with
  /// `{action: "threads"}` reads its review threads (`{url, number, threads}`), or with
  /// `{action: "merge", number, url}` merges it (cx-ncc.77.4). Only the native host on this Mac runs
  /// it, as for Stage.
  gitPullRequest(params: { action?: "threads" | "merge"; number?: number; url?: string } = {}): Promise<unknown> {
    if (this.gitRoute === "daemon") return Promise.reject(new Error(translate("error.noFolderChanges")));
    return this.git("git.pullRequest", params);
  }

  /// acpmux serves no git methods: the native host runs them on the session host in the selected
  /// session's folder, and mock mode's in-page daemon answers them by session.
  /// One turn's repository changes: checkpoint `from` against checkpoint `to`.
  gitCheckpointDiff(from: string, to: string): Promise<unknown> {
    return this.git("git.checkpoint.diff", { from, to, include_patch: true });
  }

  private git(
    method:
      | "git.diff"
      | "git.status"
      | "git.checkpoint.diff"
      | "git.commit"
      | "git.push"
      | "git.stage"
      | "git.unstage"
      | "git.stageHunk"
      | "git.unstageHunk"
      | "git.pullRequest",
    params: Record<string, unknown>,
  ): Promise<unknown> {
    const sessionId = this.selectedSessionId;
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const entry = this.sessions.find((session) => session.sessionId === sessionId);
    const cwd = text(summary?.cwd) ?? text(entry?.cwd);
    if (!sessionId || !cwd) return Promise.reject(new Error(translate("error.noFolderChanges")));
    // The native host runs the read on the machine whose acpmux runs the session (a Cloud or
    // SSH machine's chat reads through that machine's daemon), so no page-side machine check.
    // The host refuses a commit or push whose session folder is not on this Mac.
    const asked =
      this.gitRoute === "daemon"
        ? this.request(method, { sessionId, cwd, ...params })
        : postNative(method, { cwd, ...params });
    // A status read names the session it read, so a commit or push built on it says which
    // session's repository the reader saw; the host refuses one for another session.
    return method === "git.status"
      ? asked.then((value) =>
          value && typeof value === "object" ? { ...(value as object), session_id: sessionId } : value,
        )
      : asked;
  }

  /// `request` with params and result typed by acpmux's registry (`protocol/generated`).
  private typed<M extends AcpmuxRequestName>(
    method: M,
    params: AcpmuxRequests[M]["params"],
    deadline?: number,
  ): Promise<AcpmuxRequests[M]["result"]> {
    return typedRequest((name, body, until) => this.request(name, body, until), method, params, deadline);
  }
  private request(method: string, params: Record<string, unknown>, deadline?: number): Promise<any> {
    if (this.socket?.readyState !== WebSocket.OPEN)
      return Promise.reject(
        Object.assign(new Error(translate("error.notOpen")), {
          code: "native.not_connected",
          origin: "native",
        }),
      );
    const id = this.nextRequest++;
    const result = this.expectReply(id, method, deadline);
    try {
      const text = JSON.stringify({ jsonrpc: "2.0", id, method, params });
      this.wire.sent(text, method, id);
      this.socket!.send(text);
    } catch (error) {
      const request = this.pending.get(id);
      this.pending.delete(id);
      if (request?.timer) clearTimeout(request.timer);
      request?.reject(error instanceof Error ? error : new Error(String(error)));
    }
    return result;
  }

  private expectReply(id: number | string, method: string, deadline?: number): Promise<any> {
    return new Promise((resolve, reject) => {
      const timer = deadline
        ? setTimeout(() => {
            this.pending.delete(id);
            reject(
              Object.assign(new Error(translate("error.timedOut")), {
                code: "native.timed_out",
                origin: "native",
              }),
            );
          }, deadline)
        : undefined;
      this.pending.set(id, {
        resolve,
        reject: (error: unknown) => {
          warnIfNotAllowlisted(method, error);
          reject(error);
        },
        timer,
      });
    });
  }

  /// The newest turn-opening prompt before `events` when they start mid-turn and older history
  /// exists: one small read of `user_message` records only, so a capped open page still shows
  /// what its turn was asked. A failed read leaves it out; the pane draws as before.
  private async fetchTurnOpener(
    sessionId: string,
    events: EventRecord[],
    hasMore: boolean,
  ): Promise<EventRecord | undefined> {
    const first = events[0];
    if (!hasMore || !first || first.seq <= 1 || startsTurn(first)) return undefined;
    const known = this.turnOpener;
    if (known && known.sessionId === sessionId && known.seq < first.seq) return known;
    try {
      const result = await this.typed("_acpmux/events", {
        sessionId,
        beforeSeq: first.seq,
        // Steers into the turn are user_message records too; the opener is the newest that is not one.
        limit: 16,
        kinds: ["user_message"],
      });
      const prompts = records(result?.events);
      const opener = [...prompts].reverse().find(startsTurn);
      return opener ? { ...opener, sessionId: opener.sessionId ?? sessionId } : undefined;
    } catch {
      return undefined;
    }
  }

  /// Asks acpmux to attach `sessionId` (its newest page, then its records live) and, with
  /// `reads`, the reads the chat draws with (`startAttachReads`) in the same round trip.
  private sendAttach(sessionId: string, generation: number, reads: boolean): SentAttach {
    const visible = pageShown();
    const attaching = this.typed("_acpmux/attach", {
      sessionId,
      // The visible page must not wait for the daemon's restart-time full-log restoration. The
      // attach page can read the newest records directly; queue/status restoration continues in
      // the daemon and arrives on the attached event stream (Leo: the window must be well under 1 s).
      waitLogs: false,
      limit: 400,
      // The most opening a chat downloads, however large its tool output (a remote session's open).
      maxBytes: OPEN_PAGE_BYTES,
      // At most 8 kinds: a remote cmux-tui before cx-kpd0v refuses more. Session offers come with
      // "transcript" (acpmux paging.rs, since offers exist). The queue's live kinds go only to a
      // local acpmux, which takes any number; a remote chat's queue follows its session changes.
      kinds: [
        "transcript",
        COMMANDS_KIND,
        USAGE_KIND,
        CONFIG_KIND,
        BOOKMARKS_KIND,
        ...SECRET_KINDS,
        // The chat's sub-session records: its running limit's `limits` changes (the eighth kind).
        SUBSESSION_KIND,
        ...(this.localOrigin ? QUEUE_KINDS : []),
      ],
      eventStream: true,
      visible,
    });
    const out = { sessionId };
    this.attachOut = out;
    const settled = () => {
      if (this.attachOut === out) this.attachOut = undefined;
    };
    this.attaching = attaching.then(
      () => {
        settled();
        if (generation === this.selectionGeneration && this.selectedSessionId === sessionId)
          this.shownToAcpmux = { sessionId, visible };
      },
      () => settled(),
    );
    return { attaching, reads: reads ? this.startAttachReads(sessionId) : undefined };
  }

  /// The chat's permission groups and handoff, read as its attach is asked rather than once it
  /// answers: each is a round trip as slow as the attach on a busy daemon, and the chat shows only
  /// once they are in (its asks and a handoff come with its rows, so nothing lands under them a
  /// moment later; Leo 2026-10-21, a 690-turn chat after a restart: "I LOAD IN AND IT'S A BLACK
  /// SCREEN").
  private startAttachReads(sessionId: string): AttachReads {
    this.permissions.select(sessionId);
    if (this.handoffSupported) this.handoff.select(sessionId);
    return {
      permissions: this.permissions.refresh().catch(() => {}),
      handoff: this.handoffSupported
        ? this.handoff.refresh().catch(() => {
            /* No mutation until a recovery read succeeds. */
          })
        : undefined,
    };
  }

  /// The attach of the chat this open is for, asked with the chat list (`open`): on a page that
  /// holds nothing of the chat yet, for a chat not known to run on another machine (whose open may
  /// draw the Mac's copy first, `drawPeerCopy`). The open takes it once the list says it is the
  /// chat opened (`takeEarly`) or drops it (`dropEarly`). It is asked as shown, as the open's own
  /// attach is: it names the chat id the page opens on, which the list only confirms. An id the
  /// daemon lacks fails there, waking and marking nothing.
  private askEarly(): EarlyAttach | undefined {
    const sessionId = this.selectedSessionId;
    if (!sessionId || this.events.length > 0 || this.lastSeq > 0 || this.peerCopy?.sessionId === sessionId)
      return undefined;
    const known = this.sessions.find((session) => session.sessionId === sessionId) ?? keptTail(sessionId)?.summary;
    if (typeof (known as { peer?: unknown } | undefined)?.peer === "string") return undefined;
    const generation = this.selectionGeneration;
    const watch: AttachWatch = { sessionId, seen: new Map() };
    this.attachWatch = watch;
    const early: EarlyAttach = {
      sessionId,
      generation,
      watch,
      sent: this.sendAttach(sessionId, generation, true),
      live: [],
    };
    // A dropped one is never awaited: its refusal (a peer chat's machine down) is not unhandled.
    early.sent.attaching.catch(() => undefined);
    this.earlyAttach = early;
    return early;
  }

  /// The open's attach is the one asked with the list: the chat's records that came before are
  /// applied now, in order, as they would have come had it been asked here.
  private takeEarly(early: EarlyAttach): void {
    if (this.earlyAttach === early) this.earlyAttach = undefined;
    for (const event of early.live.splice(0)) this.apply(event);
  }

  /// The attach asked with the list is not the open's: another chat opens, or this one attaches
  /// again as a chat on another machine does. A chat no longer shown is detached. One still shown
  /// is not: acpmux keeps one subscription per chat and connection (server/view.rs `attach`), which
  /// the next attach takes over, so it streams once. Its live records stay held until that attach
  /// takes them (`attachWatched`), so none applies before the rows the open draws first (a kept
  /// tail, the Mac's copy). That attach discards them: its page holds every record of the session
  /// that came before it, and any of a session since recreated is not this chat's. Its reads start
  /// over with that attach. `final`: the open ended, so nothing waits for them.
  private dropEarly(early: EarlyAttach, final = false): void {
    if (this.attachWatch === early.watch) this.attachWatch = undefined;
    const shown = early.sessionId === this.selectedSessionId && early.generation === this.selectionGeneration;
    if (final || !shown) {
      if (this.earlyAttach === early) this.earlyAttach = undefined;
      early.live.length = 0;
    }
    if (early.sessionId !== this.selectedSessionId) {
      // Once the attach is in: acpmux runs each request on its own task, so a detach sent now could
      // run before it and leave its subscription behind. Not if the chat was chosen again meanwhile.
      const detach = () => {
        if (early.sessionId === this.selectedSessionId || this.closed) return;
        void this.typed("_acpmux/detach", { sessionId: early.sessionId }).catch(() => undefined);
      };
      void early.sent.attaching.then(detach, () => undefined);
      return;
    }
    if (final) return;
    // Unread again, so a read asked with the dropped attach changes nothing (each client ignores a
    // read of a selection before its last).
    this.permissions.select(undefined);
    this.permissions.select(early.sessionId);
    if (this.handoffSupported) {
      this.handoff.select(undefined);
      this.handoff.select(early.sessionId);
    }
  }

  /// Returns the attach page's events, or none when the selection moved on. `keptThrough` is the
  /// newest seq of a tail drawn from ``drawKeptTail`` before this attach, so a page that does not
  /// continue that tail can drop it instead of leaving a hole in the middle of the transcript.
  private async attach(
    sessionId: string,
    generation = this.selectionGeneration,
    keptThrough = 0,
    tries = 1,
    early?: EarlyAttach,
  ): Promise<EventRecord[]> {
    // A selection that moved on attaches nothing, and never takes the watch of the attach out.
    if (this.selectedSessionId !== sessionId || generation !== this.selectionGeneration) return [];
    // The attach asked with the list watched the row from its ask (`askEarly`).
    const watch: AttachWatch = early?.watch ?? { sessionId, seen: new Map() };
    this.attachWatch = watch;
    const token = this.copyAttaches;
    try {
      return await this.attachWatched(watch, sessionId, generation, keptThrough, tries, early);
    } catch (error) {
      // Failed after the row named another session or machine: what came live meanwhile may be
      // that one's, so nothing drawn stays as this chat's. The failure's handling reads the Mac's
      // copy of the session listed now (`keepPeerCopy`), or fails the open.
      if (
        token === this.copyAttaches &&
        generation === this.selectionGeneration &&
        this.selectedSessionId === sessionId &&
        strayedFrom(watch)
      )
        this.resetSessionState();
      throw error;
    } finally {
      if (this.attachWatch === watch) this.attachWatch = undefined;
    }
  }

  private async attachWatched(
    watch: AttachWatch,
    sessionId: string,
    generation: number,
    keptThrough: number,
    tries: number,
    early?: EarlyAttach,
  ): Promise<EventRecord[]> {
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return [];
    // An attach of the chat that started after this one (`copyAttaches`: a reconnect's, a
    // recovery's) decides: this one's reply then changes nothing, on success as on failure.
    const token = this.copyAttaches;
    const current = () =>
      generation === this.selectionGeneration && this.selectedSessionId === sessionId && token === this.copyAttaches;
    // Rows drawn before it (a kept tail, the Mac's copy): what comes live from their draw
    // (`drawKeptTail`) until this attach answers is held until it says whether they are this
    // session's.
    if (keptThrough > 0 || this.peerCopy?.sessionId === sessionId) this.copyLive ??= new Map();
    // The machine the row names when the attach is asked: a reply that comes after the session
    // moved to another is that machine's journal, not the one the row names now.
    // The session it names too: a row that changed while the attach was out may name another.
    const askedRow = this.sessions.find((session) => session.sessionId === sessionId);
    const askedOf = askedRow?.peer;
    const askedGen = askedRow?.createdAt;
    // An attach asked with the list went out before the row was read: it is held to the row as the
    // list names it, and its reply to that row's session (`recreated`, below).
    watch.asked = { createdAt: askedGen, peer: askedOf };
    // A chat on another machine reads its asks and handoff once its attach answers, as before:
    // its machine may be down, and the Mac's copy shown then has none to read.
    const sent = early?.sent ?? this.sendAttach(sessionId, generation, typeof askedOf !== "string");
    // What came live of the chat since the attach asked with the list applies now, once its rows
    // are drawn and held (`copyLive`). One the open dropped: this attach's page holds what it
    // streamed, so none of it applies (`dropEarly`), and what comes from here on does.
    if (early) this.takeEarly(early);
    else if (this.earlyAttach?.sessionId === sessionId) {
      this.earlyAttach.live.length = 0;
      this.earlyAttach = undefined;
    }
    const result = await sent.attaching;
    this.syncView();
    if (!current()) return [];
    // The row changed while the attach was out to name another session than the reply's (another
    // `createdAt`, earlier or later), or another machine: the reply is not of the session listed
    // now, so that one is attached instead. A row that did not change meanwhile only lags what the
    // machine answered. Every reply is held to the row as it answers, a retry's too; a row that
    // keeps changing fails the open.
    const rowNow = this.sessions.find((session) => session.sessionId === sessionId);
    const listedNow = rowNow?.createdAt;
    const replyOf = result?.session?.createdAt;
    const recreated =
      typeof listedNow === "number" && listedNow !== askedGen && typeof replyOf === "number" && replyOf !== listedNow;
    // The row named another session or machine than the one asked of at some point since the ask
    // (A then B, or A, B, A again), or than the reply's: live records of that one may be among
    // those drawn or held, so nothing drawn is kept, and the session listed now is attached.
    const strayed = () => strayedFrom(watch, replyOf);
    const again = () => {
      // l10n-allow: an attach's internal retry bound; the pane says its own open failure.
      if (tries >= ATTACH_TRIES) throw new Error("the session changed while it was opened");
      this.resetSessionState();
      this.copyLive = new Map();
      return this.attach(sessionId, generation, 0, tries + 1);
    };
    if (strayed()) return again();
    // An attach asked before the list was read, whose reply is of another session than the list
    // names, or whose row moved machines since: the records it streamed before the open took it
    // (applied above, `takeEarly`) may be that other session's, so none of them stays.
    if (
      early &&
      ((typeof askedGen === "number" && typeof replyOf === "number" && replyOf !== askedGen) ||
        recreated ||
        rowNow?.peer !== askedOf)
    )
      return again();
    if (recreated || rowNow?.peer !== askedOf) {
      // l10n-allow: an attach's internal retry bound; the pane says its own open failure.
      if (tries >= ATTACH_TRIES) throw new Error("the session changed while it was opened");
      return this.attach(sessionId, generation, keptThrough, tries + 1);
    }
    this.presence.attached(sessionId, result);
    const page = records(result?.events);
    const oldest = page.length > 0 ? Math.min(...page.map((event) => event.seq)) : 0;
    // The chat ran on past what one page holds while the reader was away, so the kept tail and
    // this page do not meet: the tail goes (only events this page holds or newer stay), and the
    // chat holds the page alone, as one read for the first time does. Keeping both would leave a
    // hole in the middle of the transcript that no older page can fill. Everything the dropped
    // tail stood behind goes with it: where its history started, its fork point, its usage.
    // The session was recreated since the rows drawn were kept (another `createdAt` than the tail's
    // or the Mac's copy's): none of them is this session's, so the page alone is the chat
    // (peerCopy.ts), with the live records that came while it was asked, which were the new
    // session's. A peer chat's rows that do not say their session are not taken for it either. A
    // machine back on an older log (its `lastSeq` below the rows', same `createdAt`) is the same:
    // the newer rows are no longer its history.
    const copy = this.peerCopy?.sessionId === sessionId ? this.peerCopy : undefined;
    const held = [...(this.copyLive?.values() ?? [])];
    this.copyLive = undefined;
    // How far the machine's log went when it read the page (`pageThrough`, acpmux 5/8 and later);
    // an older one says only `lastSeq`, read after its page.
    const through = result?.pageThrough ?? result?.lastSeq;
    const hostLast = typeof through === "number" ? through : undefined;
    const createdAt = result?.session?.createdAt;
    const drawnThrough = copy?.lastSeq ?? keptThrough;
    const row = this.sessions.find((s) => s.sessionId === sessionId);
    const peerChat = typeof row?.peer === "string";
    const drawnOf = copy ? copy.generation : this.drawnGeneration;
    // A copy of another machine than the row names now (the session moved while this attach was
    // out) is not this machine's journal either.
    // Rows not proven of the machine the row names are another journal as well: for a peer chat a
    // tail of another machine or of none known, for a chat on this Mac a tail of a machine.
    const otherMachine = (peerChat || this.rowsPeer !== undefined) && this.rowsPeer !== row?.peer;
    const otherSession =
      drawnThrough > 0 &&
      ((copy !== undefined ? copy.peer !== row?.peer : otherMachine) ||
        (peerChat || copy !== undefined
          ? !sameGeneration(drawnOf, createdAt)
          : typeof drawnOf === "number" && typeof createdAt === "number" && drawnOf !== createdAt));
    const replaced =
      otherSession || (drawnThrough > 0 && peerChat && hostLast !== undefined && hostLast < drawnThrough);
    this.drawnGeneration = undefined;
    // Rows of another session: everything of it goes, its queue and unsent prompts too, as for a
    // switch; the live records held for this attach are the new session's and stay.
    if (otherSession) this.resetSessionState();
    this.rowsGeneration = typeof createdAt === "number" ? createdAt : undefined;
    this.rowsPeer = typeof row?.peer === "string" ? row.peer : undefined;
    if (replaced) {
      // A record can come live twice (a reconnect replays it): each seq once, in order.
      this.events = held.sort((a, b) => a.seq - b.seq);
      this.lastSeq = this.events.at(-1)?.seq ?? 0;
      this.firstSeq = this.events[0]?.seq;
    }
    if (replaced || (keptThrough > 0 && oldest > keptThrough + 1)) {
      if (!replaced) this.events = this.events.filter((event) => event.seq >= oldest);
      this.turnOpener = undefined;
      this.historyExhausted = false;
      // The prompt index was read for the held history that just went: read it again.
      this.promptIndex = undefined;
      this.usageFromSeq = Infinity;
      this.forkedAtSeq = undefined;
      this.usage = undefined;
      // An older page already in flight was read for the transcript that just went.
      this.historyEpoch += 1;
    }
    // A reconnect to the same session keeps its events, and open() fills the gap to the new page
    // (every kind, usage included): the client still holds what it held. A fresh attach (Infinity,
    // whatever live events landed before this reply) holds the page only.
    const usageFrom = result?.hasMore === true && page.length > 0 ? oldest : 0;
    this.usageFromSeq = Math.min(this.usageFromSeq, usageFrom);
    const detail = result?.session ?? {};
    // An agent usually lists its commands once, at start, which is older than the page. acpmux
    // names the newest list in the session (`availableCommands`); only an older acpmux, or a
    // session last run before it kept the list, needs the log read back to find it.
    const keptCommands = page.some((event) => event.kind === COMMANDS_KIND)
      ? undefined
      : commandsFromUpdate(detail.availableCommands);
    if (keptCommands && !this.commandsApplied) {
      this.commands = keptCommands;
      rememberCommands(sessionId, keptCommands);
      this.emit("commands");
    }
    // Read back once this attach is kept (below): an attempt the row moves on from is retried
    // under the same generation, so a read it sent could answer for the retry's session.
    const readCommandsThrough =
      !keptCommands &&
      !page.some((event) => event.kind === COMMANDS_KIND) &&
      typeof result?.lastSeq === "number" &&
      result.lastSeq > 0
        ? result.lastSeq
        : undefined;
    this.summary = detail;
    this.configSeq = Array.isArray(detail.configOptions) && typeof result?.lastSeq === "number" ? result.lastSeq : 0;
    this.limitsSeq = typeof result?.lastSeq === "number" ? result.lastSeq : 0;
    this.limitsVersion += 1;
    this.goalSeq = typeof result?.lastSeq === "number" ? result.lastSeq : 0;
    this.queue = [];
    // The chat's permission groups and handoff (`startAttachReads`): asked with the attach, or now
    // for a chat on another machine. The rows draw without waiting for them: each client draws its
    // answer when it lands (its `changed`), in the asks and composer stack under the transcript,
    // where a live ask lands too, and a chat read before shows its last groups until then
    // (`PermissionGroupClient.select`). Waiting cost every cold open the slowest of the reads.
    if (!sent.reads) this.startAttachReads(sessionId);
    // acpmux names the turn's opener with its page; only an older one (or a kept tail drawn first)
    // leaves it to a read of its own. That read stays awaited: the opener is the first row of the
    // open, and older pages are read from it (`fetchOlder`).
    const served = servedTurnOpener(result, page, mergeEventRecords(page, this.events), sessionId);
    if (served === undefined) {
      const opener = await this.fetchTurnOpener(
        sessionId,
        mergeEventRecords(page, this.events),
        result?.hasMore === true,
      );
      if (!current()) return [];
      // The row moved on while the read was out: what this attach staged is not the chat's.
      if (strayed() || this.sessions.find((session) => session.sessionId === sessionId)?.peer !== askedOf)
        return again();
      this.turnOpener = opener;
    } else this.turnOpener = served ?? undefined;
    if (readCommandsThrough !== undefined)
      void this.fetchCommands(sessionId, generation, readCommandsThrough).catch(() => {});
    // Merged after the opener's read: live events that landed meanwhile are kept.
    this.events = mergeEventRecords(page, this.events);
    this.sawPrompts(page);
    this.rebuild();
    // acpmux's list is the order; the replayed `queued` records give each prompt its whole text.
    const latest = watch.latestSummary;
    const latestIsNew =
      latest !== undefined &&
      (latest.seq === undefined || typeof detail.lastSeq !== "number" || latest.seq >= detail.lastSeq);
    if (latestIsNew) this.summary = { ...this.summary, ...latest.session };
    this.queue = mergeQueue(
      this.queue,
      (latestIsNew ? latest?.session.queue : detail.queue) ?? [],
      this.queueAuthors,
      this.queueEdited,
    );
    // acpmux holds nothing older than the page: the pane offers no more history.
    if (result?.hasMore === false) this.historyExhausted = true;
    this.attachedGeneration = generation;
    // The machine answered: these rows are its chat now, not the Mac's copy.
    this.peerCopy = undefined;
    if (this.copyBack === sessionId) this.copyBack = undefined;
    if (Array.isArray(detail.pending)) {
      const groupedIds = new Set(
        this.permissions.state.supported
          ? this.permissions.state.groups.flatMap((group) => group.items.map((item) => item.permissionId))
          : [],
      );
      const asks: AcpmuxPermission[] = detail.pending
        .map((item: any) => permissionFromMessage({ ...item, sessionId }, sessionId))
        .filter(
          (item: AcpmuxPermission | undefined): item is AcpmuxPermission =>
            !!item && (!this.permissions.state.supported || (!item.groupId && !groupedIds.has(item.permissionId))),
        );
      // acpmux lists them in no order: oldest first, by the record that asked (else by id, a
      // time-ordered UUIDv7), so the card keeps the ask the replay showed.
      const asked = new Map<string, number>();
      for (const event of this.events)
        if (event.kind === "permission_request" && event.msg?.permissionId)
          asked.set(String(event.msg.permissionId), event.seq);
      const at = (ask: AcpmuxPermission) => asked.get(ask.permissionId) ?? Number.POSITIVE_INFINITY;
      asks.sort((a, b) => at(a) - at(b) || (a.permissionId < b.permissionId ? -1 : 1));
      this.pendingPermission = asks[0];
      this.waitingPermissions = new Map(asks.slice(1).map((item) => [item.permissionId, item]));
    }
    this.emit("attached");
    return page;
  }

  /// A chat opened with nothing of it drawn yet (no kept tail, no Mac's copy) takes its listed row as
  /// its summary until the attach's detail replaces it, as a read-ahead tail does: whatever draws
  /// before the attach (the hold running out on a slow daemon, a live row) shows the chat's title,
  /// harness, model and folder, never "New chat" with no chips. The hold itself is unchanged: a
  /// switch still draws all of the chat before or all of this one (agent-pane-switch-frames).
  private seedListedSummary(): void {
    const sessionId = this.selectedSessionId;
    if (!sessionId || this.summary) return;
    const listed = this.sessions.find((session) => session.sessionId === sessionId);
    if (listed) this.summary = { ...listed };
  }

  /// Drops the attach's own asks that a permission group read since holds (`permissions`' change).
  private dropGroupedAsks(): void {
    if (!this.pendingPermission && this.waitingPermissions.size === 0) return;
    const grouped = new Set(
      this.permissions.state.groups.flatMap((group) => group.items.map((item) => item.permissionId)),
    );
    if (grouped.size === 0) return;
    const asks = [this.pendingPermission, ...this.waitingPermissions.values()].filter(
      (ask): ask is AcpmuxPermission => !!ask && !grouped.has(ask.permissionId),
    );
    if (asks.length === (this.pendingPermission ? 1 : 0) + this.waitingPermissions.size) return;
    this.pendingPermission = asks[0];
    this.waitingPermissions = new Map(asks.slice(1).map((item) => [item.permissionId, item]));
  }

  /// Read commands for a deferred chat without selecting or attaching it.
  async sessionCommands(sessionId: string): Promise<SlashCommand[]> {
    // `_acpmux/events` scans oldest-first unless `beforeSeq` is present. Use the protocol's
    // highest safe cursor so the one-row backwards page is the latest publication.
    const result = await this.typed("_acpmux/events", {
      sessionId,
      beforeSeq: Number.MAX_SAFE_INTEGER,
      limit: 1,
      kinds: [COMMANDS_KIND],
    });
    const event = records(result?.events).at(-1);
    return (event && commandsFromUpdate(sessionUpdate(event))) || [];
  }

  /// The newest command list at or before `lastSeq`, unless a live update already arrived.
  private async fetchCommands(sessionId: string, generation: number, lastSeq: number): Promise<void> {
    const result = await this.typed("_acpmux/events", {
      sessionId,
      beforeSeq: lastSeq + 1,
      limit: 1,
      kinds: [COMMANDS_KIND],
    });
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId || this.commandsApplied) return;
    const event: EventRecord | undefined = records(result?.events).at(-1);
    const commands = event ? commandsFromUpdate(sessionUpdate(event)) : undefined;
    if (!commands) return;
    this.commands = commands;
    rememberCommands(sessionId, commands);
    this.emit("commands");
  }

  /// A summary of a paused queue that says "running" from before its turn failed: it names no
  /// running turn, or one this page saw end. A turn sent now while prompts stay held runs.
  private staleRun(summary: Record<string, any>): boolean {
    if (summary.queuePaused !== true) return false;
    const turnId = summary.turn?.turnId;
    return typeof turnId !== "string" || this.endedTurns.has(turnId);
  }

  private sessionChanged(params: SessionChanged): void {
    // Only a purge carries the id alone; every other change carries the whole summary.
    const session = params?.session as SessionSummary | undefined;
    if (params?.kind === "purged" && session?.sessionId) {
      this.asks.forget(session.sessionId);
      // Nothing of a chat acpmux dropped is drawn again from this page.
      forgetTail(session.sessionId);
      this.sessionPages.purgedSession(session.sessionId);
      this.sessions = this.sessions.filter((item) => item.sessionId !== session.sessionId);
      if (session.sessionId === this.selectedSessionId && this.handoff.state.busy !== "discarding")
        this.selectFallbackSession("session purged");
      else this.emit("session purged");
      return;
    }
    if (!session?.sessionId) return;
    this.asks.session(session, typeof params?.kind === "string" ? params.kind : undefined);
    this.sessionPages.changedSession(session);
    const added = !this.sessions.some((item) => item.sessionId === session.sessionId);
    this.sessions = [...this.sessions.filter((item) => item.sessionId !== session.sessionId), session];
    const watch = this.attachWatch?.sessionId === session.sessionId ? this.attachWatch : undefined;
    watch?.seen.set(`${String(session.createdAt)} ${String(session.peer)}`, {
      createdAt: session.createdAt,
      peer: session.peer,
    });
    if (added) this.recheckSenders([session]);
    // A chat read ahead ran on: read it again once the list settles (``readAhead`` throttles it).
    if (this.readAheadAt.has(session.sessionId)) this.scheduleReadAhead(READ_AHEAD_DELAY_MS);
    if (session.sessionId === this.selectedSessionId) {
      this.summary = { ...this.summary, ...session };
      // A harness restart or a new conversation names a new native root without a rebuild: the
      // fold learns it now, or a record naming it as a parent would not repair its child. One
      // that records already folded named (a retired root, too) drew rows that are now wrong:
      // folded again by lineage, as ``learnChatThread`` does, with no later update needed.
      if (seedRoots(this.subagents, session)) this.rebuildKeepingLiveState();
      this.learnChatThread();
      // A change that doesn't carry the queue keeps the one already mapped.
      if (session.queue) {
        if (watch) watch.latestSummary = { session, seq: typeof params?.seq === "number" ? params.seq : undefined };
        this.queue = mergeQueue(this.queue, session.queue, this.queueAuthors, this.queueEdited);
      }
      // The machine of a chat shown from the Mac's copy is back: read the chat from it now (an
      // attach of a recreated session replaces the copy). A row naming another session while the
      // machine is still down leaves no copy of the old one on screen as if it were this chat. An
      // attach of the copy that is out decides for itself (`attach`, `keepPeerCopy`).
      // Back while that attach (or a read of the copy) is out, it is read again once it fails
      // (`reattachIfBack`). A session moved to another machine is another chat, as a recreated one.
      const copy = this.peerCopy?.sessionId === session.sessionId ? this.peerCopy : undefined;
      const id = session.sessionId;
      const back = peerBack(session);
      const reading = this.peerCopyReading?.sessionId === id ? this.peerCopyReading : undefined;
      if (copy?.attaching || reading || (!copy && this.attachOut?.sessionId === id)) {
        if (reading) reading.changed = true;
        if (back) this.copyBack = id;
      } else if (copy?.offline && copy.peer !== session.peer) {
        // Read from the new machine (once back) only after the old one's rows are off screen.
        if (back) this.copyBack = id;
        void this.redrawPeerCopy(id);
      } else if (copy?.offline && !sameGeneration(copy.generation, session.createdAt)) {
        // A recreated session: the old one's rows go first, then the machine (once back) is read.
        if (back) this.copyBack = id;
        void this.redrawPeerCopy(id);
      } else if (copy?.offline && back) void this.reattachPeerCopy(id);
      else if (!copy && this.rowMovedOn(session)) void this.reattachMovedRow(id);
    }
    if (this.offerChildIds().includes(session.sessionId) || this.isStartedChild(session))
      this.childChanged(session.sessionId);
    // The tab's chat is listed again (its machine connected): it opens, shown or hidden.
    if (this.reopenMissing()) return;
    // The picker lists every session, so a change elsewhere still needs a snapshot, but each pane
    // hears every running chat's changes: a burst draws once, in the next frame, and a hidden pane
    // draws other chats' changes when it shows again (agent-pane-session-change-coalesce.test.ts).
    if (session.sessionId !== this.selectedSessionId && !pageShown()) {
      this.listChangedWhileHidden = true;
      return;
    }
    this.emitInFrame("session changed");
  }

  private applyPermission(message: any): void {
    const permission = permissionFromMessage(message, this.selectedSessionId ?? "");
    if (!permission) return;
    if (permission.groupId && this.permissions.state.supported) {
      this.groupedPermissions.set(permission.permissionId, permission);
      return;
    }
    const shown = this.pendingPermission;
    if (shown?.pending && shown.permissionId !== permission.permissionId) {
      // Another ask is on the card: this one waits its turn (a repeat keeps its place).
      this.waitingPermissions.set(permission.permissionId, permission);
    } else this.pendingPermission = permission;
    this.emit("permission");
  }

  /// Takes the oldest ask waiting behind the card, for the card once its ask is answered.
  private nextWaitingPermission(): AcpmuxPermission | undefined {
    const [next] = this.waitingPermissions.values();
    if (next) this.waitingPermissions.delete(next.permissionId);
    return next;
  }

  /// A live event's stamp, to tell the session's clock from this computer's.
  private observeClock(sessionId: unknown, at: unknown): void {
    if (sessionId !== this.selectedSessionId || typeof at !== "number" || !(at > 0)) return;
    const offset = Date.now() - at;
    this.clockOffset = this.clockOffset === undefined ? offset : Math.min(this.clockOffset, offset);
  }

  private apply(event: EventRecord): void {
    if (!event?.seq || event.sessionId !== this.selectedSessionId) return;
    // Came before the open took the attach asked with the list: applied when it does (`takeEarly`).
    const early = this.earlyAttach;
    if (early && early.sessionId === event.sessionId) {
      early.live.push(event);
      return;
    }
    // Held until the attach says whether the copy drawn is this session's history (`copyLive`).
    this.copyLive?.set(event.seq, event);
    // A copy shown offline once its attach failed is what the Mac confirmed: a late record of that
    // attach is not shown past it (`keepPeerCopy`); the next attach reads on from its newest seq.
    const copy = this.peerCopy;
    if (copy?.offline && !copy.attaching && copy.sessionId === event.sessionId && event.seq > copy.lastSeq) return;
    if (event.seq <= this.lastSeq) return;
    this.events.push(event);
    this.sawPrompt(event);
    this.lastSeq = event.seq;
    this.firstSeq = this.firstSeq === undefined ? event.seq : Math.min(this.firstSeq, event.seq);
    this.streamGrew = false;
    this.reduce(event);
    this.noticeRefusal(event);
    this.emitInFrame(event.kind, this.streamGrew);
  }

  /// A queued prompt acpmux refused when its turn came, heard live, that this client did not send
  /// (it waited in a chat moved here, or across a restart: hub/queue.rs `resume_queues`): it left
  /// the queue, and the chat says why in acpmux's words. Only a live record: one in the history
  /// a page loads was said when it happened, so opening the chat again does not repeat it.
  private noticeRefusal(event: EventRecord): void {
    if (event.kind !== "prompt_refused") return;
    const msg = (event.msg ?? {}) as { promptId?: unknown; error?: unknown };
    const promptId = typeof msg.promptId === "string" ? msg.promptId : "";
    if (!promptId || this.sentPrompts.has(promptId)) return;
    const reason = typeof msg.error === "string" && msg.error ? msg.error : translate("transport.refused");
    const id = noticeId("notice-refused");
    this.rows.set(id, {
      id,
      version: 1,
      at: event.at,
      kind: "notice",
      text: translate("queue.promptRefused", { reason }),
    });
  }

  /// Snapshots before the next display frame, once for every event that lands before it.
  private emitInFrame(connection: string, streamGrew = false): void {
    const schedule = AcpmuxDirectClient.scheduleFrame;
    if (!schedule) return this.emit(connection);
    const scheduled = this.frameSnapshot !== undefined;
    this.frameSnapshot = connection;
    // A hidden page's frames wait for it to show (`nextFrame`), and only the reply's and the
    // thought's text growing waits for them: the token stream, the bulk of a running chat's events.
    // Everything else draws within 50 ms as before, since the page's effects still act on it while
    // hidden (a subagent's own pane, the tab's header). A turn starting or ending draws at once, each
    // one, so the header refreshes on every end (App.tsx `pane.tabState`).
    if (!pageShown() && this.workingNow() !== this.drawnWorking) return this.emit(connection);
    if (!pageShown() && !streamGrew) {
      this.hiddenDraw ??= setTimeout(() => {
        this.hiddenDraw = undefined;
        const pending = this.frameSnapshot;
        if (pending !== undefined && !this.closed) this.emit(pending);
      }, HIDDEN_DRAW_MS);
      return;
    }
    // A snapshot drawn since (a turn's start or end on a hidden page) left this frame nothing to
    // draw, but it is still asked for: no second one, however many events land before it.
    if (scheduled || this.frameRequest) return;
    const request: { cancel?: () => void } = {};
    this.frameRequest = request;
    request.cancel =
      schedule(() => {
        if (this.frameRequest === request) this.frameRequest = undefined;
        const pending = this.frameSnapshot;
        if (pending !== undefined && !this.closed) this.emit(pending);
      }) ?? undefined;
  }

  /// Whether the chat runs a turn, as the snapshot says it (`isWorking`).
  private workingNow(summary = this.summary): boolean {
    return (
      this.replayThrough === undefined &&
      // acpmux may still list a paused queue as running after its turn failed.
      (this.turnOpen || (summary?.status === "running" && !this.staleRun(summary)))
    );
  }

  /// This chat's names and the listed chats', which tell an agent's message addressed
  /// `sender -> receiver: …` from the person's words (conversation/incomingMessage.ts). This chat
  /// is the summary, or its listed entry while the summary is not in yet (a kept tail's replay).
  /// A sender no listed chat names is kept, so a list that names it later reads the rows again.
  private incomingContext(): IncomingContext {
    return {
      isThisChat: (name) => {
        const listed = this.sessions.find((session) => session.sessionId === this.selectedSessionId);
        const lower = name.toLowerCase();
        return [this.summary, listed].some((chat) =>
          [chat?.name, chat?.shortName].some((own) => typeof own === "string" && own.trim().toLowerCase() === lower),
        );
      },
      isChat: (name) => {
        const known = this.sessions.some((session) => namesChat(session, name));
        if (!known) this.unknownSenders.add(name);
        return known;
      },
    };
  }

  /// The list gained chats (a later page, a new chat): when one is a sender an addressed prompt
  /// named before it was listed, the rows are read again, so that prompt draws as its message. The
  /// queue keeps its live order and text; a prompt waiting in it whose `queued` record still holds
  /// that text is read again too, unless the person edited it since (an edit makes it theirs).
  private recheckSenders(added: readonly Session[]): void {
    if (this.unknownSenders.size === 0 || !this.selectedSessionId || this.events.length === 0) return;
    if (![...this.unknownSenders].some((name) => added.some((session) => namesChat(session, name)))) return;
    this.rebuildKeepingLiveState();
    const queued = new Map<string, any>();
    for (const event of [...this.events].sort((a, b) => a.seq - b.seq)) {
      const id = event.msg?.promptId ? String(event.msg.promptId) : "";
      if (event.kind === "queued" && id) queued.set(id, event.msg);
      else if (event.kind === "queue_updated" && id) queued.delete(id);
    }
    this.queue = this.queue.map((entry) => {
      const msg = queued.get(entry.id);
      if (entry.message || !msg || String(msg.text ?? "") !== entry.prompt) return entry;
      const message = queuedMessage(msg, this.incomingContext());
      return message
        ? keepStopHold(
            queuedEntry(
              entry.id,
              entry.prompt,
              entry.next === true,
              entry.sending === true,
              entry.images,
              message,
              entry.author,
              entry.inlineParts,
            ),
            entry,
          )
        : entry;
    });
  }

  /// The selected chat's own agent session (its harness thread), from its summary or its listing:
  /// never one of its subagents (subagents/subagentFold.ts ``isChat``).
  private chatThread(): string | undefined {
    const listed = this.sessions.find((session) => session.sessionId === this.selectedSessionId);
    const thread = this.summary?.agentSessionId ?? listed?.agentSessionId;
    return typeof thread === "string" && thread ? thread : undefined;
  }

  /// The chat's thread became known after its records were folded (an attach, a listing, a reread):
  /// when an older acpmux recorded that thread as one of its own subagents, a parent or an owner (a Codex child reporting its parent thread), they are
  /// folded again by lineage, so the chat's own rows come back and its subagents stop nesting.
  private learnChatThread(): void {
    const thread = this.chatThread();
    if (thread) {
      this.subagents.setRoot(thread);
      this.takeSubagentRows();
    }
    // A shell call that started another family's agent before the chat's harness was known draws
    // as that agent now (subagentFold.ts ``deferredRun``).
    if (this.summary?.harness && !this.subagents.harness && this.subagents.deferredRun) {
      this.rebuildKeepingLiveState();
      return;
    }
    if (!thread || this.subagents.chat === thread || !this.subagents.names(thread)) return;
    this.rebuildKeepingLiveState();
  }

  private rebuild(): void {
    const through = this.replayThrough ?? Number.POSITIVE_INFINITY;
    const events = this.events.filter((event) => event.seq <= through).sort((a, b) => a.seq - b.seq);
    const from = Math.min(events[0]?.seq ?? Infinity, this.turnOpener?.seq ?? Infinity);
    // Preserve a checkpoint only when it precedes the retained event window and the seek point.
    // Otherwise replay must derive retirement/fencing in sequence, not inherit its future state.
    const retiredAt = this.retiredCompactionTurnId
      ? this.rows.get(`summary-${this.retiredCompactionTurnId}`)?.seq
      : undefined;
    if (retiredAt === undefined || retiredAt >= from || retiredAt > through) this.retiredCompactionTurnId = undefined;
    if (this.compactionFenceSeq !== undefined && (this.compactionFenceSeq >= from || this.compactionFenceSeq > through))
      this.compactionFenceSeq = undefined;
    const previous = new Map(this.rows);
    this.unknownSenders.clear();
    // A prompt still in flight keeps its optimistic row until an event settles it; a failed one stays to show it was not sent.
    // Only prompts still awaiting acceptance are retained before replay. Durable keys are used
    // when their replayed user_message is reduced, but retaining every historical key here would
    // keep future rows visible when a seek replays only an earlier event window.
    const inFlight = new Set(this.optimisticPromptRows.values());
    // Those rows keep their place in the order.
    this.rows.retain((row) => row.failed === true || inFlight.has(row.id));
    this.waitingSteers = [];
    this.interrupting = undefined;
    this.awaiting = undefined;
    this.endedTurns.clear();
    this.supersededTurns.clear();
    this.steerRows.clear();
    this.promptsShown.clear();
    this.firstSeq = undefined;
    // Found again as the held events are reduced (`reduceEvent`).
    this.nativeSeed = undefined;
    this.lastSeq = 0;
    this.turnOpen = false;
    this.runningTurnId = undefined;
    this.turnPrompt = undefined;
    this.silentTurn = false;
    this.turnTokens = undefined;
    this.turnTokenSplit = undefined;
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
    this.assistantCut = false;
    this.streamingActivity = undefined;
    this.supersededMessageIds.clear();
    this.messageRows.clear();
    this.offerRows.clear();
    this.receivedOffers.clear();
    this.compactionHeardAt.clear();
    this.toolRows.clear();
    this.planCalls.clear();
    this.subagents = new SubagentFold(this.subagentStops);
    // Replay knows the native harness ids from the session summary, the earlier ones a restart
    // retired too. Seed them before any persisted acpmux records so an echoed root thread cannot
    // be reconstructed as a child of its reporter.
    seedRoots(this.subagents, this.summary);
    this.pendingPermission = undefined;
    this.waitingPermissions = new Map();
    this.pendingSecret = undefined;
    const opener = this.turnOpener;
    if (opener && (events[0]?.seq ?? Number.POSITIVE_INFINITY) <= opener.seq) this.turnOpener = undefined;
    // Drawn first, but neither firstSeq nor lastSeq moves: older pages still load from the held history.
    else if (opener && opener.seq <= through) this.reduce(opener);
    for (const event of events) {
      this.lastSeq = Math.max(this.lastSeq, event.seq);
      this.firstSeq = this.firstSeq === undefined ? event.seq : Math.min(this.firstSeq, event.seq);
      this.reduce(event);
    }
    // Rows kept from before (a prompt that failed or still sends) are newer than every replayed event.
    this.rows.placeLocalLast();
    this.rows.keepSame(previous);
  }

  /// rebuild() replays a partial event window, so keep the live summary, queue and
  /// permission; events after replayAfterSeq are then reapplied on top of them.
  private rebuildKeepingLiveState(replayAfterSeq?: number): void {
    const summary = this.summary;
    // The summary's running limit goes back with it, so the seq it was read at must too: else the
    // rebuild's own pass leaves limitsSeq past a missed `limits` record and its reapply below is
    // refused, keeping the old limit.
    const limitsSeq = this.limitsSeq;
    const limitsVersion = this.limitsVersion;
    const queue = this.queue;
    const permission = this.pendingPermission;
    const waiting = this.waitingPermissions;
    const secret = this.pendingSecret;
    this.rebuild();
    this.summary = summary;
    this.limitsSeq = limitsSeq;
    this.limitsVersion = limitsVersion;
    this.queue = queue;
    this.pendingPermission = permission;
    this.waitingPermissions = waiting;
    this.pendingSecret = secret;
    if (replayAfterSeq !== undefined)
      for (const event of this.events)
        if (event.seq > replayAfterSeq && event.dir === "mux") this.reduceLiveState(event);
  }

  /// Mux events that move the live summary, queue or permission.
  private reduceLiveState(event: EventRecord): void {
    const msg = event.msg ?? {};
    if (event.kind === "queue_updated") {
      // An edit keeps the prompt's place, and makes it the person's: acpmux drops an agent's
      // provenance and sender (hub/queue.rs), so its row loses the sender too. A teammate's own
      // edit keeps their `person_message` provenance, so the row keeps its author.
      const id = String(msg.promptId ?? "");
      // Kept also when the row is not in yet: an attach's page may begin after its `queued` record.
      if (id) this.queueAuthors.set(id, promptAuthor(msg) ?? null);
      if (id) this.queueEdited.add(id);
      const parts = recordedPromptParts(
        msg,
        this.optimisticPromptParts.get(id) ?? this.queue.find((entry) => entry.id === id)?.inlineParts,
      );
      this.optimisticPromptInputs.delete(id);
      this.optimisticPromptAttachments.delete(id);
      if (parts && this.optimisticPromptParts.has(id)) this.optimisticPromptParts.set(id, parts);
      this.queue = this.queue.map((entry) =>
        entry.id === id
          ? keepStopHold(
              queuedEntry(
                id,
                String(msg.text ?? ""),
                entry.next === true,
                false,
                recordImages(msg),
                undefined,
                promptAuthor(msg),
                recordedPromptParts(msg, entry.inlineParts) ?? entry.inlineParts,
              ),
              entry,
            )
          : entry,
      );
    } else if (event.kind === "queue_order" && Array.isArray(msg.order)) {
      const at = new Map(msg.order.map((id: unknown, index: number) => [String(id), index]));
      // A prompt sent now goes first and stops the turn: only the last one sent now is next.
      const next = msg.next === true ? String(msg.promptId ?? "") : undefined;
      // Into a running turn, it stops that turn. Only while it still waits: a record replayed over
      // the live queue (rebuildKeepingLiveState) is of a prompt that already ran. After Stop, the
      // turn's end is the Stop's.
      if (next && this.turnOpen && !this.stopAffectsRunningTurn() && this.queue.some((entry) => entry.id === next))
        this.interrupting = next;
      this.queue = [...this.queue]
        .sort((a, b) => (at.get(a.id) ?? at.size) - (at.get(b.id) ?? at.size))
        .map((entry) =>
          next === undefined
            ? entry
            : keepStopHold(
                queuedEntry(
                  entry.id,
                  entry.prompt,
                  entry.id === next,
                  false,
                  entry.images,
                  entry.message,
                  entry.author,
                  entry.inlineParts,
                  entry.retry,
                ),
                // Sent now, it is no longer held (hub/queue.rs `put_next`).
                entry.id === next ? undefined : entry,
              ),
        );
    } else if (event.kind === "queue_paused" || event.kind === "queue_resumed") {
      // A person's Stop holds other agents' messages (`reason: "stop"`, hub/cancel.rs) until their
      // next turn completes or the queue is resumed; a resume names the prompts it let go, or none
      // for the whole queue.
      const ids = (value: unknown) => (Array.isArray(value) ? new Set(value.map(String)) : undefined);
      if (event.kind === "queue_paused" && msg.reason === "stop") {
        const held = ids(msg.held);
        if (held)
          this.queue = this.queue.map((entry) =>
            held.has(entry.id) && !entry.heldByStop ? { ...entry, heldByStop: true } : entry,
          );
      } else if (event.kind === "queue_resumed") {
        const resumed = ids(msg.promptIds);
        this.queue = this.queue.map((entry) => {
          if (!entry.heldByStop || (resumed && !resumed.has(entry.id))) return entry;
          const { heldByStop: _, ...released } = entry;
          return released;
        });
      }
    } else if (event.kind === "queued") {
      const id = String(msg.promptId ?? "");
      // A task's result waiting behind the turn draws its received line now (offer/SuggestedTasks.tsx).
      if (this.queuedResult(msg, event.at)) return;
      if (id) {
        this.queueAuthors.set(id, promptAuthor(msg) ?? null);
        // acpmux names the images it kept; a record that names none (an older acpmux) keeps those
        // this pane sent.
        const named = recordImages(msg);
        const images = named.length ? named : this.queue.find((entry) => entry.id === id)?.images;
        this.queue = [
          ...this.queue.filter((entry) => entry.id !== id),
          queuedEntry(
            id,
            String(msg.text ?? ""),
            false,
            false,
            images,
            queuedMessage(msg, this.incomingContext()),
            promptAuthor(msg),
            recordedPromptParts(
              msg,
              this.optimisticPromptParts.get(id) ?? this.queue.find((entry) => entry.id === id)?.inlineParts,
            ) ?? this.optimisticPromptParts.get(id),
            subagentRetryNotice(String(msg.text ?? ""), msg),
          ),
        ];
      }
      // acpmux took a prompt that waits behind the turn: its queue row shows it now, and the
      // composer is free for the next one.
      if (id && this.optimisticPromptRows.has(id)) {
        settleOptimisticPrompt(this.rows, this.optimisticPromptRows, msg);
        this.optimisticPromptTexts.delete(id);
        this.queuedSends.add(id);
        this.promptAccepts.get(id)?.();
      }
    } else if (event.kind === "queue_removed" || event.kind === "dequeued" || event.kind === "prompt_refused") {
      const id = String(msg.promptId ?? "");
      this.queue = this.queue.filter((entry) => entry.id !== id);
      this.queueAuthors.delete(id);
      this.queueEdited.delete(id);
      if (event.kind === "queue_removed" && id)
        this.queueWithdrawn = [...this.queueWithdrawn.filter((each) => each !== id), id].slice(-QUEUE_WITHDRAWN_KEPT);
      // A prompt sent now that will never run: the turn it stopped ends as it did.
      if (event.kind !== "dequeued") {
        if (id === this.interrupting) this.interrupting = undefined;
        if (id === this.awaiting) this.dropContinuation(id);
      }
    } else if (event.kind === "permission_request") {
      const asked = msg.permissionId
        ? questionFromPermission({
            permissionId: String(msg.permissionId),
            session: event.sessionId ?? "",
            request: msg.request,
          })
        : undefined;
      if (asked) this.askedQuestions.set(asked.id, asked);
      this.openQuestions.add(String(msg.permissionId ?? `permission-${event.seq}`));
      this.markAwaitingPermission(msg.request?.toolCall?.toolCallId);
      this.applyPermission({ ...msg, sessionId: event.sessionId });
      // A single card (not the grouped panel's, not a question's) leaves a receipt once answered.
      const card = this.pendingPermission;
      if (!asked && card && card.permissionId === String(msg.permissionId ?? ""))
        this.askedPermissions.set(card.permissionId, card);
    } else if (event.kind === "permission_decision") {
      this.recordQuestion(event, msg);
      this.recordPermission(event, msg);
      if (msg.permissionId) this.groupedPermissions.delete(String(msg.permissionId));
      else this.groupedPermissions.clear();
      if (msg.permissionId) this.openQuestions.delete(String(msg.permissionId));
      else this.openQuestions.clear();
      if (msg.permissionId) this.waitingPermissions.delete(String(msg.permissionId));
      else this.waitingPermissions.clear();
      if (!msg.permissionId || this.pendingPermission?.permissionId === msg.permissionId)
        this.pendingPermission =
          this.nextWaitingPermission() ??
          (this.permissions.state.supported ? undefined : [...this.groupedPermissions.values()].at(-1));
    } else if (event.kind === "permission_auto" && typeof msg.fullAccess === "string")
      this.recordFullAccess(event, msg);
    else if (event.kind === "secret_request")
      this.pendingSecret = {
        secretId: String(msg.secretId ?? ""),
        name: String(msg.name ?? ""),
        reason: String(msg.reason ?? ""),
      };
    else if (event.kind === "secret_decision") {
      if (this.pendingSecret?.secretId === msg.secretId) this.pendingSecret = undefined;
    } else if (event.kind === "permission_group" || event.kind === "permission_chat_allowance")
      void this.permissions.refresh().catch(() => {});
    else if (event.kind === "status") this.summary = { ...this.summary, status: msg.status };
    // The chat's sub-session limits changed (acpmux hub/subsessions.rs: the person, or an ancestor).
    else if (event.kind === SUBSESSION_KIND && msg.event === "limits" && msg.limits && typeof msg.limits === "object") {
      if (event.seq && event.seq <= this.limitsSeq) return;
      this.summary = { ...this.summary, subsessionLimits: msg.limits };
      if (event.seq) this.limitsSeq = event.seq;
      this.limitsVersion += 1;
    }
  }

  /// What is ending the running turn, as `event` finds it: a prompt sent now (its `queue_order`
  /// set `interrupting`), or this pane's Stop, pressed before the event. Else unknown.
  private stopAffectsRunningTurn(): boolean {
    return (
      this.stopAfterSeq !== undefined &&
      !this.stopSuperseded &&
      (this.runningTurnId === undefined || this.stopTurnId === this.runningTurnId)
    );
  }

  /// A turn opening after a Stop bound to a known turn: one that is not that turn ends the Stop's
  /// hold on what runs (a legacy turn with no id included).
  private stopSeesTurnOpen(event: EventRecord, turnId: string | undefined, opensNewTurn: boolean): void {
    for (const known of [this.runningTurnId, this.stopTurnId])
      if (known !== undefined && known !== turnId) this.supersededTurns.add(known);
    if (this.stopAfterSeq === undefined || event.seq <= this.stopAfterSeq) return;
    if (this.stopTurnId !== undefined) {
      if (turnId !== this.stopTurnId) this.stopSuperseded = true;
      return;
    }
    // A Stop of a turn that names none: a later prompt (or agent-started turn) opens another turn,
    // unless the Stop went out before its own turn opened and this is that turn's first opener.
    if (!opensNewTurn) return;
    if (this.stoppedTurnOpener === "pending" && !this.stopOpenerSeen) this.stopOpenerSeen = true;
    else this.stopSuperseded = true;
  }

  /// A `background_turn` record: its started record makes the turn's line, which the rows its events
  /// make fold under (OrderedRows `inBackground`); its ended record says whether that turn was
  /// quiet. acpmux decides that; the pane never does.
  private reduceBackgroundTurn(event: EventRecord, msg: Record<string, unknown>): void {
    const record = backgroundTurnRecord(msg);
    if (!record) return;
    const { state, ...turn } = record;
    const id = backgroundTurnRowId(turn.id);
    const existing = this.rows.get(id);
    // Its text, tool calls and plan never run on into the turn before it, nor the next turn's into its
    // own: a real turn that opens with a tool call or a thought gets a row of its own.
    this.endAssistantSegment();
    this.streamingActivity = undefined;
    this.planRow = undefined;
    // Nor does a subagent group: the next subagent starts a group of its own, in its own turn.
    this.subagents.closeBatch();
    if (state === "started") {
      // An older page's started record after its ended one: the line keeps how it ended.
      const ended = this.rows.openBackground(turn.id, event.seq);
      if (existing) return;
      this.rows.set(id, {
        id,
        version: 1,
        at: event.at,
        seq: event.seq,
        kind: BACKGROUND_TURN,
        background: ended ?? turn,
      });
      return;
    }
    this.rows.closeBackground(event.seq, turn);
    if (!existing) return;
    this.rows.set(id, { ...existing, version: existing.version + 1, background: turn });
  }

  private turnStopCause(event: EventRecord): SubagentStopReason | undefined {
    if (this.interrupting !== undefined) return "sendNow";
    if (this.stopAffectsRunningTurn() && event.seq > this.stopAfterSeq!) return "user";
    return undefined;
  }

  /// Only a terminal event of the stopped turn answers its cancellation: its turn_result, or a legacy
  /// turn_end / turn_error naming it (or any, for a Stop with no identity). A compaction update or
  /// another turn's end is not evidence that this Stop settled.
  private stopAnswered(event: EventRecord): void {
    if (this.stopAfterSeq === undefined || event.seq <= this.stopAfterSeq) return;
    const turnId = typeof event.msg?.turnId === "string" && event.msg.turnId ? event.msg.turnId : undefined;
    // A legacy daemon may end the turn with turn_end alone: it answers a Stop that has no turn
    // identity, or one whose identity it names. A Stop bound to a turn otherwise waits for its result.
    const legacyEnd =
      (event.kind === "turn_end" || event.kind === "turn_error") &&
      (this.stopTurnId === undefined || turnId === this.stopTurnId);
    if (event.kind !== "turn_result" && !legacyEnd) return;
    if (this.stopTurnId !== undefined && turnId !== this.stopTurnId) return;
    this.stopAfterSeq = undefined;
    this.stopSuperseded = false;
    this.stopOpenerSeen = false;
    this.stopTurnId = undefined;
  }

  /// A turn that opens after a Stop, with none open, is a new one, unless Stop went out before the
  /// stopped turn opened here (`stoppedTurnOpener`): then that first opening, and its replays, are the
  /// stopped turn's own.
  private stoppingOpens(event: EventRecord): void {
    if (this.stoppingAfterSeq === undefined || event.seq <= this.stoppingAfterSeq) return;
    const turnId = typeof event.msg?.turnId === "string" ? event.msg.turnId : undefined;
    if (turnId && this.stoppedTurnId && turnId !== this.stoppedTurnId) {
      this.stoppingEnded();
      return;
    }
    if (turnId) {
      this.stoppedTurnId = turnId;
      // Stop may precede its first opener. Bind its newly learned identity before the
      // running turn starts so duplicate Stop and send-now keep the same attribution.
      if (this.stoppedTurnOpener === "pending" && this.stopTurnId === undefined) this.stopTurnId = turnId;
    }
    if (this.turnOpen) return;
    if (this.stoppedTurnOpener === "pending") this.stoppedTurnOpener = event.seq;
    else if (this.stoppedTurnOpener === undefined || event.seq > this.stoppedTurnOpener) this.stoppingEnded();
  }

  private stoppingEnded(): void {
    this.stoppingAfterSeq = undefined;
    this.stoppedTurnOpener = undefined;
    this.stoppedTurnId = undefined;
  }

  /// A decided question stays in the transcript as a compact record where its card was: what was
  /// chosen, or that it went unanswered. acpmux's log holds both records, so a reload draws it again.
  private recordQuestion(event: EventRecord, msg: any): void {
    const id = msg.permissionId ? String(msg.permissionId) : undefined;
    const asked = id ? this.askedQuestions.get(id) : undefined;
    if (!id || !asked) return;
    this.askedQuestions.delete(id);
    const rowId = `question-${id}`;
    // Drawn already: a resync replays the live records after its rebuild drew them, and closing
    // the stream again then would split the reply that streams on.
    if (this.rows.has(rowId)) return;
    const question = decidedQuestion(asked, msg.outcome, msg.answeredBy);
    this.closeSegment();
    this.rows.set(rowId, {
      id: rowId,
      version: 1,
      at: event.at,
      kind: QUESTION_RECORD,
      question,
      // What Copy reads.
      text:
        question.state.kind === "answered"
          ? summaryLines(question, question.state.answer).join("\n")
          : translate(cancelledKey(question), cancelledArgs(question)),
    });
  }

  /// A single permission card, answered, leaves a one-line receipt where it was answered: "Allowed:
  /// Run npm test", or Denied, Always allowed, Not answered. The grouped panel keeps its own.
  private recordPermission(event: EventRecord, msg: any): void {
    const id = msg.permissionId ? String(msg.permissionId) : undefined;
    const asked = id ? this.askedPermissions.get(id) : undefined;
    if (!id || !asked) return;
    this.askedPermissions.delete(id);
    const rowId = `permission-${id}`;
    // Drawn already: a resync replays the live records after its rebuild drew them, and closing
    // the stream again then would split the reply that streams on.
    if (this.rows.has(rowId)) return;
    const decision = permissionDecision(asked, msg.outcome);
    this.closeSegment();
    this.rows.set(rowId, {
      id: rowId,
      version: 1,
      at: event.at,
      kind: PERMISSION_RECORD,
      permission: asked,
      decision,
      ...(answeredBy(msg.answeredBy) && { answeredBy: answeredBy(msg.answeredBy) }),
      // What Copy reads; the row draws its words in the pane's language as it is then.
      text: translate(DECISION_TEXT[decision.kind], {
        action: asked.title?.trim() || translate("permission.required"),
        option: decision.kind === "answered" ? decision.option : "",
      }),
    });
  }

  /// An ask a chat in its highest mode answered unasked (acpmux hub/permissions.rs
  /// `full_access_allow`: Claude Code's own guards in bypassPermissions, and any plain tool ask)
  /// leaves the receipt line a card would, using that harness's native mode label, so what ran
  /// unasked can be seen afterwards.
  private recordFullAccess(event: EventRecord, msg: any): void {
    const permission = permissionFromMessage({ ...msg, sessionId: event.sessionId }, this.selectedSessionId ?? "");
    if (!permission) return;
    const rowId = `permission-${permission.permissionId}`;
    // Drawn already (a resync replays the live records after its rebuild drew them).
    if (this.rows.has(rowId)) return;
    this.closeSegment();
    const mode = harnessModeName(this.summary?.family, this.summary?.harness, msg.fullAccess);
    this.rows.set(rowId, {
      id: rowId,
      version: 1,
      at: event.at,
      kind: PERMISSION_RECORD,
      permission,
      decision: { kind: "fullAccess", mode },
      text: translate(DECISION_TEXT.fullAccess, {
        action: permission.title?.trim() || translate("permission.required"),
        mode,
      }),
    });
  }

  /// The text and tool fold before a record close, as a tool call's would: the work after an answer
  /// draws below its record, never in the row above it.
  private closeSegment(): void {
    this.endAssistantSegment();
    this.streamingActivity = undefined;
  }

  /// Takes tool call `callId` out of the row that drew it, and the row with it when it held only that.
  private dropToolItem(callId: string): void {
    const id = this.toolRows.get(callId);
    if (id === undefined) return;
    this.toolRows.delete(callId);
    const row = this.rows.get(id);
    if (!row?.items) return;
    const items = row.items.filter((item) => item.tool?.id !== callId);
    if (items.length === 0) {
      this.rows.delete(id);
      if (this.streamingActivity === id) this.streamingActivity = undefined;
    } else
      this.rows.set(id, {
        ...row,
        version: row.version + 1,
        items,
        toolCount: items.filter((entry) => entry.kind === "tool").length,
      });
  }

  /// The subagent group rows that changed, into the transcript.
  private takeSubagentRows(): void {
    for (const row of this.subagents.takeRows()) {
      // A late root seed can empty a previously emitted group after removing a phantom root.
      // Remove that stale row instead of leaving a blank disclosure in the transcript.
      if (!row.subagents?.length) {
        this.rows.delete(row.id);
        continue;
      }
      // A new group ends the text and tool calls before it, like a tool call does.
      if (!this.rows.has(row.id)) {
        this.endAssistantSegment();
        this.streamingActivity = undefined;
      }
      const previous = this.rows.get(row.id)?.subagents;
      const changed =
        row.subagents?.length !== previous?.length ||
        row.subagents?.some(
          (agent, index) =>
            agent.id !== previous?.[index]?.id ||
            agent.state !== previous?.[index]?.state ||
            agent.name !== previous?.[index]?.name,
        );
      const current = this.rows.current;
      if (!this.rows.has(row.id) && row.seq !== undefined) this.rows.current = row.seq;
      this.rows.set(row.id, row, changed ?? false);
      this.rows.current = current;
    }
  }

  private reduce(event: EventRecord): void {
    this.rows.current = event.seq;
    try {
      this.reduceEvent(event);
    } finally {
      this.rows.current = undefined;
      if (event.seq) this.rows.saw(event.seq);
    }
  }

  private reduceEvent(event: EventRecord): void {
    const msg = event.msg ?? {};
    if (event.dir === "mux" && event.kind === NATIVE_HISTORY_KIND) {
      // Draws nothing: where the transcript's older turns end. The oldest one held is the seeded
      // page's (a page of the log seq order puts first).
      const before = Number(msg.before);
      if (event.seq >= 1 && before > 0 && (this.nativeSeed === undefined || event.seq < this.nativeSeed.seq))
        this.nativeSeed = { seq: event.seq, before, mark: typeof msg.mark === "string" ? msg.mark : undefined };
      return;
    }
    const update = sessionUpdate(event);
    const resultTurnId =
      event.kind === "turn_result" && typeof msg.turnId === "string" && msg.turnId ? msg.turnId : undefined;
    if (event.dir === "mux" && ["turn_end", "turn_result", "turn_error"].includes(event.kind)) {
      const terminalTurnId = typeof msg.turnId === "string" && msg.turnId ? msg.turnId : undefined;
      // An end naming a turn is late when another named turn runs, or when it names a turn that has
      // ended (its result came) or that a newer turn opened over. A late end only settles its own Stop.
      const late =
        terminalTurnId !== undefined &&
        (this.runningTurnId !== undefined
          ? terminalTurnId !== this.runningTurnId
          : this.supersededTurns.has(terminalTurnId) || this.endedTurns.has(terminalTurnId));
      // Behind the compaction fence an end naming no turn cannot say which turn it closes.
      const ambiguous = this.compactionFenceSeq !== undefined && terminalTurnId === undefined;
      if (ambiguous || late) {
        // The old Stop can be acknowledged independently, before any turn-scoped side effects
        // (including foreground subagents) see a result that belongs to a different turn.
        if (terminalTurnId !== undefined && terminalTurnId === this.stopTurnId) this.stopAnswered(event);
        return;
      }
    }
    // Route child updates before session metadata's early returns too: a helper's init or
    // usage belongs to that helper, just like its text and tools.
    if (update) {
      this.subagents.cause = this.turnStopCause(event);
      this.subagents.chat = this.chatThread();
      this.subagents.session = this.selectedSessionId;
      this.subagents.harness = this.summary?.harness;
      if (this.subagents.reduce(event, update)) {
        // A later command update can associate a shell call with its recorded child session.
        if (typeof update.toolCallId === "string" && this.subagents.isRun(update.toolCallId))
          this.dropToolItem(update.toolCallId);
        this.takeSubagentRows();
        return;
      }
    }
    if (update?.sessionUpdate === USAGE_KIND) {
      const used = Number(update.used);
      const size = Number(update.size);
      // `used` is the last call's prompt/context size. Only an explicitly reported generated
      // count belongs on the running line; adding `used` here counted the whole context again on
      // every tool step (for example, 5 × 100K input became 500K instead of 5K output). What the
      // calls read stays apart, in the split, for the line's "in" and its hover.
      if (this.turnTokens !== undefined && isCallUsage(update)) {
        const output = callOutputTokens(update);
        if (output !== undefined) this.turnTokens += output;
        const split = callTokenSplit(update, output);
        this.turnTokenSplit = split && this.turnTokenSplit ? addSplit(this.turnTokenSplit, split) : undefined;
      }
      if (Number.isFinite(used) && Number.isFinite(size) && size > 0) {
        const setup = usageSetup(update, used);
        this.usage = setup === undefined ? { used, size } : { used, size, setup };
      }
      return;
    }
    if (update?.sessionUpdate === CONFIG_KIND) {
      // The event at attach's own lastSeq may be newer than the options it names (acpmux numbers the
      // event before it writes them): only events before it are history.
      if (!Array.isArray(update.configOptions) || (event.seq && event.seq < this.configSeq)) return;
      this.summary = { ...this.summary, configOptions: update.configOptions };
      if (event.seq) this.configSeq = event.seq;
      return;
    }
    // Claude Code's /context after a turn (acpmux claude_stdio): the session detail's
    // `contextBreakdown` from then on. Before the detail is in, the detail itself carries it.
    // The same update may carry more (a title, Claude Code's facts), which the code below reads.
    const breakdown =
      update?.sessionUpdate === SESSION_INFO_KIND
        ? contextBreakdownOf(update?._meta?.acpmux?.contextBreakdown)
        : undefined;
    if (breakdown && this.summary) this.summary = { ...this.summary, contextBreakdown: breakdown };
    // Codex owns its goal lifecycle in `_meta.goal`; apply live completion and clearing before
    // the session-start row's early return so the persistent strip follows the harness event.
    if (
      update?.sessionUpdate === SESSION_INFO_KIND &&
      this.summary &&
      event.seq >= this.goalSeq &&
      Object.prototype.hasOwnProperty.call(update._meta ?? {}, "goal")
    ) {
      this.summary = { ...this.summary, goal: taskGoal(update._meta.goal) };
    }
    // An update that carries only the breakdown has nothing more to draw.
    if (breakdown && update.title === undefined && Object.keys(update._meta ?? {}).every((key) => key === "acpmux"))
      return;
    // Claude Code names its version and model on every turn's init line: one row, where the
    // session first said so, that a later line with other facts (a restart on a new version, a
    // model switch) updates in place.
    const start =
      update?.sessionUpdate === SESSION_INFO_KIND
        ? sessionStartOf(update, { harness: this.summary?.harness, cwd: this.summary?.cwd })
        : undefined;
    if (start) {
      const existing = this.rows.get(SESSION_START_ROW);
      if (sameSessionStart(existing?.sessionStart, start)) return;
      this.rows.set(SESSION_START_ROW, {
        id: SESSION_START_ROW,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        seq: existing?.seq ?? event.seq,
        kind: "sessionStart",
        sessionStart: start,
      });
      return;
    }
    if (event.dir === "mux") {
      // A stopped or completed turn, or a gone agent, ends the subagents it would never report again.
      const left = subagentsLeft(event.kind, msg);
      this.subagents.cause = this.turnStopCause(event);
      if (left && this.subagents.stopRunning(left, event.at)) this.takeSubagentRows();
      if (event.kind === BOOKMARKS_KIND) {
        // Another pane (or the TUI) marked a prompt: the minimap shows acpmux's marks.
        bookmarksHeard(event.sessionId ?? this.selectedSessionId, event.msg?.bookmarks);
      } else if (event.kind === "forked") {
        this.forkedAtSeq = event.seq;
        // An agent that could not fork the working chat: the fork's agent reads the chat's
        // transcript instead, and the fork says so in one line (acpmux `hub/fork.rs`).
        if (msg.from === "transcript") {
          const id = `fork-note-${event.seq}`;
          const harness = typeof msg.harness === "string" ? msg.harness : "";
          this.rows.set(id, {
            id,
            version: 1,
            at: event.at,
            kind: "notice",
            text: translate("notice.forkFromTranscript", { harness }),
          });
        }
      } else if (event.kind === "failover") {
        // acpmux moved the chat to its fallback harness (`hub/turns.rs`); the turn goes on there.
        if (typeof msg.from === "string" && typeof msg.to === "string") {
          this.endAssistantSegment();
          this.streamingActivity = undefined;
          // The last harness's /context is not the fallback's: acpmux drops it there too.
          if (this.summary?.contextBreakdown) this.summary = { ...this.summary, contextBreakdown: undefined };
          const id = `failover-${event.seq}`;
          this.rows.set(id, {
            id,
            version: 1,
            at: event.at,
            kind: "failover",
            failover: { from: msg.from, to: msg.to },
          });
        }
      } else if (event.kind === BACKGROUND_TURN_KIND) {
        this.reduceBackgroundTurn(event, msg);
      } else if (event.kind === "host_notice") {
        // A line from outside the chat, such as cmux Cloud's after it resized the machine
        // (acpmux `server/host_notice.rs`): one muted notice where it happened.
        if (typeof msg.text === "string" && msg.text.trim()) {
          // What the agent writes or does after the notice goes below it, not into the row above.
          this.closeSegment();
          const id = `host-notice-${event.seq}`;
          this.rows.set(id, { id, version: 1, at: event.at, kind: "notice", text: msg.text });
        }
      } else if (event.kind === "policy_unenforced") {
        // The chat's policy is narrower than approve-all and its harness has no mode that asks
        // (`hub/policy_mode.rs`): its agent runs without the asks the policy would answer.
        if (typeof msg.policy === "string") {
          const id = `policy-unenforced-${event.seq}`;
          // From the record alone, so a rebuild before the summary is back draws the same note: acpmux's
          // reason (never shown) says whether OpenCode's own settings decide; the family only for a
          // record without one.
          const opencode =
            typeof msg.reason === "string" ? msg.reason.startsWith("opencode") : this.summary?.family === "opencode";
          this.rows.set(id, {
            id,
            version: 1,
            at: event.at,
            kind: "policyUnenforced",
            policyUnenforced: {
              policy: msg.policy,
              why: opencode ? "ownSettings" : "noAskingMode",
            },
          });
        }
      } else if (event.kind === "subagent_retry") {
        // acpmux's step of a subagent's retry: whether it gave up (subagents/retryState.ts).
        this.subagents.reduceRetryStep(msg);
        this.takeSubagentRows();
      } else if (event.kind === "subsession" && msg.event === "limits") {
        // The chat's running limit changed: its summary's, not a child's card.
        this.reduceLiveState(event);
      } else if (event.kind === "subsession") {
        // A child an `acpmux run --parent` call of this chat started (acpmux #25019): that call's
        // run, whose card stands for the call's row from now on.
        this.subagents.harness = this.summary?.harness;
        const call = this.subagents.reduceChild(event, msg);
        if (call) this.dropToolItem(call);
        this.takeSubagentRows();
      } else if (event.kind === "session_offer") {
        // Off by default: off, an offer draws nothing (offer/offersShown.ts).
        const offer = offersShown() ? sessionOffer(msg) : undefined;
        if (offer) this.addOffer(offer, event.at);
      } else if (event.kind === "session_offer_decision") {
        this.answerOffer(msg);
      } else if (
        event.kind === "user_message" &&
        msg.steer === true &&
        typeof msg.promptId === "string" &&
        this.promptsShown.has(msg.promptId)
      ) {
        // The steer of a prompt already drawn below (it ran as that prompt): shown once, as the prompt.
      } else if (event.kind === "user_message") {
        // A prompt, or a steer (which starts no turn but splits it), starts a new checklist.
        this.planRow = undefined;
        const promptId = typeof msg.promptId === "string" ? msg.promptId : undefined;
        if (msg.steer !== true) {
          const openedTurnId = typeof msg.turnId === "string" && msg.turnId ? msg.turnId : undefined;
          this.stopSeesTurnOpen(event, openedTurnId, true);
          this.runningTurnId = openedTurnId;
          // The fence covers the turn the forced Stop's next prompt started. A later explicit prompt
          // starts a turn whose unscoped boundaries are its own again, so its compactions can end.
          if (this.compactionFenceSeq !== undefined && event.seq > this.compactionFenceSeq)
            this.compactionFenceSeq = undefined;
          // A forced compaction result can follow the next prompt's echo. Retire the old inferred
          // row before that prompt so the delayed boundary cannot complete it or close the new turn.
          if (this.retiredCompactionTurnId !== undefined) {
            this.compactionFenceSeq = event.seq;
            this.settleCompactions(event.seq, false);
            this.retiredCompactionTurnId = undefined;
          }
        }
        const text = typeof msg.text === "string" ? msg.text : undefined;
        const fallbackPromptId =
          promptId ??
          (text ? [...this.optimisticPromptTexts.entries()].find(([, value]) => value === text)?.[0] : undefined);
        // Capture the queue metadata before acceptance removes its row: an older or capped
        // user_message may carry only text, while the queue still holds its paste/file parts.
        const knownParts = fallbackPromptId
          ? (this.optimisticPromptParts.get(fallbackPromptId) ??
            this.queue.find((entry) => entry.id === fallbackPromptId)?.inlineParts)
          : undefined;
        // Keep the optimistic row as the durable row. React keys transcript rows by `id`, so
        // replacing it with `user-${event.seq}` would unmount the prompt exactly when the echo
        // arrives (and again when the turn starts). The queue path still removes its row above.
        const optimisticRowId = settleOptimisticPrompt(
          this.rows,
          this.optimisticPromptRows,
          { ...msg, promptId: fallbackPromptId },
          false,
        );
        if (fallbackPromptId) {
          this.optimisticPromptTexts.delete(fallbackPromptId);
          this.promptAccepts.get(fallbackPromptId)?.();
          // A prompt the pane put in the queue that ran at once (the turn ended meanwhile).
          if (this.queue.some((entry) => entry.id === fallbackPromptId))
            this.queue = this.queue.filter((entry) => entry.id !== fallbackPromptId);
        }
        this.subagents.closeBatch();
        // An agent reads a steer once the reply it writes ends (Claude Code): the rest of that
        // reply still streams after the steer's row and stays in its row above it, and the next
        // message's text starts below (cx-f51kv). A prompt is the same when it lands while a reply
        // streams: Claude Code woke on its own (a background task's notice) and acpmux took the
        // chat for idle, so the prompt is no steer, yet the message goes on after it. Leo
        // 2026-10-31: "why was i able to cut my prompt in between your messages? that's s***
        // rendering". Without message ids that end cannot be told.
        if (!this.streamingAssistantMessageId) this.endAssistantSegment();
        else this.assistantCut = true;
        // A call id names a call within its prompt: an adapter that numbers calls per process
        // reuses one in a later prompt, whose call draws under that prompt (cx-jzhka). A steer
        // splits a turn whose calls may still update.
        if (msg.steer !== true) {
          this.toolRows.clear();
          this.planCalls.clear();
        }
        this.streamingActivity = undefined;
        // A task's result is not the person's prompt, shown or not: it never enters prompt recall.
        const taskResult = offerResult(msg);
        const received = offersShown() ? taskResult : undefined;
        // Another agent's message or harness bookkeeping (conversation/incomingMessage.ts): the row
        // keeps the sender's words, or the typed prompt without the bookkeeping. Bookkeeping alone
        // keeps an empty row that draws nothing, so the answer it brought stays its own turn
        // (turns.ts). Retry resends a message as the agent got it (`resend`); a notice, like
        // bookkeeping, is the harness's, not a prompt to send again, so it offers no Retry.
        const raw = String(msg.text ?? "");
        // A prompt with nothing to read and no image draws nothing, never an empty bubble: a blank
        // text, a record without `text` (one acpmux left out of the page for its size, paging.rs
        // `fit`, keeps only `_meta`), or a steer that carried none. It stays a turn's start, as
        // bookkeeping does. A prompt of images alone keeps its row: the images are what it says.
        // acpmux's own continuation of a failed turn or subagent (its retry, automatic or the Retry
        // button's) is not the person's prompt: it draws nothing either (subagents/retryState.ts).
        const blank = !received && (isRetryContinuation(msg) || (!raw.trim() && promptImages(msg.images).length === 0));
        const incoming = received
          ? undefined
          : blank
            ? ({ kind: "hidden" } as const)
            : incomingPrompt(raw, msg, this.incomingContext());
        const shown =
          incoming?.kind === "message"
            ? { text: incoming.message.text, incoming, resend: raw }
            : incoming?.kind === "notice"
              ? { text: incoming.text, incoming }
              : incoming?.kind === "inbox"
                ? { text: inboxText(incoming.notice), incoming }
                : incoming?.kind === "hidden"
                  ? { text: "", incoming }
                  : { text: incoming?.kind === "prompt" ? incoming.text : raw };
        const untyped = taskResult !== undefined || (incoming !== undefined && incoming.kind !== "prompt");
        // Its queued line, if the result waited, gives way to this prompt's.
        if (received) this.rows.delete(`received-${received.offerId}`);
        if (received) this.receivedOffers.add(received.offerId);
        // The steer this prompt is (its turn ended first) was never read: its row gives way to this one.
        const steered = msg.steer !== true && promptId ? this.steerRows.get(promptId) : undefined;
        if (promptId && steered) {
          this.rows.delete(steered);
          this.steerRows.delete(promptId);
          this.waitingSteers = this.waitingSteers.filter((waiting) => waiting.rowId !== steered);
        }
        // The prompt is in the transcript now: a queue row of it (its `dequeued` record missed, or a
        // listing from before it went in) gives way, so the message never shows twice.
        if (promptId && this.queue.some((entry) => entry.id === promptId))
          this.queue = this.queue.filter((entry) => entry.id !== promptId);
        // A newer prompt means any steer before it was read; a second steer can come in the same step.
        if (msg.steer !== true) this.landSteer();
        if (msg.steer !== true && promptId) this.promptsShown.add(promptId);
        if (promptId !== undefined && promptId === this.interrupting) this.interrupting = undefined;
        // A prompt sent now that ended the turn it went into goes on with that turn. Another prompt
        // opening a turn first means it never ran.
        const steer = msg.steer === true ? "waiting" : undefined;
        const continues = promptId !== undefined && this.continuations.has(promptId);
        if (continues) this.continueTurn(promptId!);
        else if (this.awaiting !== undefined && msg.steer !== true) this.dropContinuation(this.awaiting);
        const durableRowId =
          optimisticRowId ??
          (fallbackPromptId ? this.promptRowKeys.get(fallbackPromptId) : undefined) ??
          `user-${event.seq}`;
        if (fallbackPromptId) this.promptRowKeys.set(fallbackPromptId, durableRowId);
        // A new list, never one changed in place: the snapshot names its rows by the list's identity.
        if (steer === "waiting") this.waitingSteers = [...this.waitingSteers, { rowId: durableRowId, promptId }];
        if (steer === "waiting" && promptId) this.steerRows.set(promptId, durableRowId);
        const inlineParts = recordedPromptParts(msg, knownParts) ?? knownParts;
        const optimisticRow = optimisticRowId ? this.rows.get(optimisticRowId) : undefined;
        this.rows.set(durableRowId, {
          id: durableRowId,
          version: (optimisticRow?.version ?? 0) + 1,
          at: event.at,
          kind: "user",
          ...shown,
          ...(untyped ? { untyped } : {}),
          ...(sentByChief(msg) ? { from: "chief" as const } : {}),
          ...(!untyped && promptAuthor(msg) ? { author: promptAuthor(msg) } : {}),
          ...(!untyped && cliHost(msg.client) ? { viaCli: cliHost(msg.client) } : {}),
          ...(received ? { received } : {}),
          ...(steer ? { steer } : {}),
          ...(continues ? { continues } : {}),
          ...(steer === "waiting" && promptId ? { steerPromptId: promptId } : {}),
          ...(promptId ? { promptId } : {}),
          ...(typeof msg.turnId === "string" ? { turnId: msg.turnId } : {}),
          ...(promptImages(msg.images).length > 0 && { images: promptImages(msg.images) }),
          ...(inlineParts?.length ? { inlineParts } : {}),
          // The blocks the composer sent as pastes, by where they sit in the text acpmux recorded;
          // only while the row shows that text as recorded (a harness note it hides moves them).
          ...(shown.text === raw &&
            pasteRanges(msg.pasted, raw).length > 0 && { pasted: pasteRanges(msg.pasted, raw) }),
          ...(fallbackPromptId && this.optimisticPromptAttachments.get(fallbackPromptId)?.length
            ? { retryAttachments: this.optimisticPromptAttachments.get(fallbackPromptId) }
            : {}),
        });
        if (optimisticRowId) this.rows.adoptEventOrder(durableRowId);
        if (fallbackPromptId) {
          const attachments = this.optimisticPromptAttachments.get(fallbackPromptId);
          if (attachments?.length) this.retryAttachments.set(durableRowId, attachments);
          const input = this.optimisticPromptInputs.get(fallbackPromptId);
          if (input !== undefined) this.retryInputs.set(durableRowId, input);
          this.optimisticPromptInputs.delete(fallbackPromptId);
          this.optimisticPromptParts.delete(fallbackPromptId);
          this.optimisticPromptAttachments.delete(fallbackPromptId);
          // This pane's prompt reached the agent: its row (now acpmux's) shows it read.
          this.setDelivery(fallbackPromptId, { state: "read", readAt: event.at }, durableRowId);
        }
        this.stoppingOpens(event);
        // A prompt opens its turn; a steer goes into the turn already open.
        if (promptId && msg.steer !== true) this.turnPrompt = promptRoot(promptId);
        this.turnOpen = true;
      } else if (event.kind === "turn_silent") {
        this.silentTurn = this.turnOpen;
      } else if (event.kind === "turn_heard") {
        this.silentTurn = false;
      } else if (event.kind === "turn_started") {
        const startedTurnId = typeof msg.turnId === "string" && msg.turnId ? msg.turnId : undefined;
        // A prompt opens its turn (user_message); one opening with none open, and naming no turn, is
        // a turn the agent started on its own, never the turn before's.
        const agentStarted = !this.turnOpen && startedTurnId === undefined;
        this.stoppingOpens(event);
        this.stopSeesTurnOpen(event, startedTurnId, agentStarted);
        // A turn that does not name its prompt is no known one's: never the turn before's.
        this.turnPrompt = typeof msg.promptId === "string" && msg.promptId ? promptRoot(msg.promptId) : undefined;
        this.turnOpen = true;
        if (startedTurnId !== undefined) this.runningTurnId = startedTurnId;
        else if (agentStarted) this.runningTurnId = undefined;
        this.silentTurn = false;
        this.turnTokens = event.seq >= this.usageFromSeq ? 0 : undefined;
        this.turnTokenSplit = this.turnTokens === undefined ? undefined : NO_TOKENS;
        this.subagents.startTurn();
        this.settleCompactions(event.seq, true);
        // A Stop before this turn never judges it.
        this.stopAnswered(event);
        this.rows.set("typing", { id: "typing", version: 1, at: event.at, kind: "typing" });
      } else if (event.kind === "message_superseded") {
        const oldMessageId = typeof msg.oldMessageId === "string" ? msg.oldMessageId : undefined;
        if (oldMessageId) {
          applySupersededMessage(this.rows, this.messageRows, this.supersededMessageIds, oldMessageId);
          if (this.streamingAssistantMessageId === oldMessageId) {
            this.streamingAssistant = undefined;
            this.streamingAssistantMessageId = undefined;
          }
        }
      } else if (event.kind === "steer_withdrawn") {
        // A steer taken back before the agent read it (the X beside it): its bubble goes, and its
        // text went back to the composer that took it.
        const id = String(msg.promptId ?? "");
        const rowId = this.steerRows.get(id);
        if (rowId) {
          this.rows.delete(rowId);
          this.steerRows.delete(id);
          this.waitingSteers = this.waitingSteers.filter((waiting) => waiting.rowId !== rowId);
        }
      } else if (event.kind === "turn_error") {
        // turn_result follows with the turn's summary; a Stop it answers settles now.
        this.stopAnswered(event);
      } else if (event.kind === "turn_end" || event.kind === "turn_result") {
        // Only this turn's unfinished compaction needs a delayed-boundary fence. An unrelated
        // historical inferred row must not turn an ordinary forced Stop into a compaction Stop.
        const compactionWasRunning =
          resultTurnId !== undefined &&
          [...this.rows.values()].some(
            (row) =>
              row.kind === "compaction" &&
              row.turnId === resultTurnId &&
              (row.compaction?.state === "running" || row.compaction?.inferred === true),
          );
        this.turnOpen = false;
        this.turnPrompt = undefined;
        this.silentTurn = false;
        this.turnTokens = undefined;
        this.turnTokenSplit = undefined;
        this.settleCompactions(event.seq, event.kind === "turn_result" && msg.cancelForced === true);
        this.landSteer();
        // Only the daemon's turn-end event completes Stop, never a client-side deadline.
        this.stopAnswered(event);
        if (this.stoppingAfterSeq !== undefined && event.seq > this.stoppingAfterSeq) this.stoppingEnded();
        this.pendingPermission = undefined;
        this.waitingPermissions.clear();
        this.groupedPermissions.clear();
        this.openQuestions.clear();
        this.heldEdits.clear();
        // A new row, never an in-place change: emitted snapshots share row objects, and the
        // transcript's memo compares the drawn row's version with the next one.
        this.endAssistantSegment();
        this.rows.delete("typing");
        const checkpoint = event.kind === "turn_result" ? readSummaryCheckpoint(msg) : undefined;
        const status = String(msg.status ?? "completed");
        const summaryId = `summary-${resultTurnId ?? event.seq}`;
        // A turn a prompt sent now cancelled goes on under that prompt; one that ended first did not.
        // Whatever ended it (acpmux's cancel, or the agent's end_turn), but not a failure, which shows.
        const continued = event.kind === "turn_result" && status !== "failed" && this.interrupting !== undefined;
        if (continued) {
          this.continuations.set(this.interrupting!, summaryId);
          this.awaiting = this.interrupting;
        }
        if (event.kind === "turn_result") this.interrupting = undefined;
        const turnId = resultTurnId;
        if (event.kind === "turn_result" && turnId) {
          if (msg.cancelForced === true && compactionWasRunning) this.retiredCompactionTurnId = turnId;
          this.endedTurns.add(turnId);
          if (this.runningTurnId === turnId) this.runningTurnId = undefined;
        }
        if (event.kind === "turn_result")
          this.rows.set(summaryId, {
            id: summaryId,
            version: 1,
            at: event.at,
            kind: "turnSummary",
            // A turn paged in from the transcript (`fetchNativeOlder`) is in no log: nothing forks or
            // edits through it, as acpmux forks only through a logged record (`fork_through.rs`).
            ...(event.seq >= 1 ? { seq: event.seq } : {}),
            ...(turnId ? { turnId } : {}),
            ...this.turnTotals(event.at),
            ...(event.kind === "turn_result" && resultTokenSplit(msg) ? { tokens: resultTokenSplit(msg) } : {}),
            status,
            ...(continued ? { continued } : {}),
            // An agent that could not start ends its turn with `error` and no `errorText`
            // (acpmux fail_unstarted_turn): the row still names it, as the paused queue's note does.
            error: msg.errorText ?? (status === "failed" && typeof msg.error === "string" ? msg.error : undefined),
            ...(typeof msg.errorCode === "string" && msg.errorCode ? { errorCode: msg.errorCode } : {}),
            ...(checkpoint ? { checkpoint } : {}),
          });
        // acpmux ended a turn whose agent did not answer Stop (`hub/cancel.rs`). After the summary, so its fold never hides it.
        if (event.kind === "turn_result" && msg.cancelForced === true) {
          const noticeId = `notice-stop-${turnId ?? event.seq}`;
          this.rows.set(noticeId, {
            id: noticeId,
            version: 1,
            at: event.at,
            kind: "notice",
            text: translate("stop.forced"),
          });
        }
        this.streamingAssistant = undefined;
        this.streamingAssistantMessageId = undefined;
        this.streamingActivity = undefined;
      } else if (!reduceAgentPair(this.rows, event)) this.reduceLiveState(event);
      return;
    }
    if (!update) return;
    const commands = commandsFromUpdate(update);
    if (commands) {
      this.commands = commands;
      this.commandsApplied = true;
      if (this.selectedSessionId) rememberCommands(this.selectedSessionId, commands);
      return;
    }
    const text = textFromContent(update.content);
    if (event.kind === "agent_message_chunk" && text) {
      acpmuxPerf.markAgent("firstToken");
      // Subagents spawned after the session's own text form a new group.
      this.subagents.closeBatch();
      const messageId = typeof update.messageId === "string" ? update.messageId : undefined;
      if (messageId && this.supersededMessageIds.has(messageId)) return;
      if (messageId && this.streamingAssistantMessageId && messageId !== this.streamingAssistantMessageId) {
        const prior = this.streamingAssistant ? this.rows.get(this.streamingAssistant) : undefined;
        if (prior) this.rows.set(prior.id, { ...prior, version: prior.version + 1, streaming: false });
        this.streamingAssistant = undefined;
        this.streamingAssistantMessageId = undefined;
      }
      // After a cut only the cut message's own text goes on in its row; anything else starts below.
      if (this.assistantCut && messageId !== this.streamingAssistantMessageId) this.endAssistantSegment();
      const sameMessage = Boolean(
        this.streamingAssistant &&
        (!messageId || !this.streamingAssistantMessageId || this.streamingAssistantMessageId === messageId),
      );
      if (!sameMessage) this.assistantCut = false;
      const id = sameMessage ? this.streamingAssistant! : `assistant-${event.seq}`;
      this.streamGrew = sameMessage;
      // A message after the reply that was streaming when the steer went: the agent read it.
      if (!sameMessage) this.landSteer();
      const existing = this.rows.get(id);
      // Text after tool calls is a new segment; the next tool call opens a new fold.
      this.streamingActivity = undefined;
      this.rows.set(id, {
        id,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "assistant",
        text: `${existing?.text ?? ""}${text}`,
        streaming: true,
      });
      this.streamingAssistant = id;
      this.streamingAssistantMessageId = messageId;
      if (messageId) {
        const ids = this.messageRows.get(messageId) ?? [];
        if (!ids.includes(id)) this.messageRows.set(messageId, [...ids, id]);
      }
      this.rows.delete("typing");
    } else if (event.kind === "agent_thought_chunk" && text) {
      const steers = this.waitingSteers.length;
      this.landSteer();
      this.endAssistantSegment();
      const id = this.streamingActivity ?? `activity-${event.seq}`;
      const existing = this.rows.get(id);
      const last = existing?.items?.at(-1);
      this.streamGrew = steers === 0 && last?.kind === "thought" && !last.tool;
      this.rows.set(id, {
        id,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "activity",
        toolCount: existing?.toolCount ?? 0,
        items: appendThought(existing?.items ?? [], text, event.at),
        streaming: true,
      });
      this.streamingActivity = id;
    } else if (event.kind === "tool_call" || event.kind === "tool_call_update") {
      const callId = String(update.toolCallId ?? `tool-${event.seq}`);
      const tool = update._meta?.claude?.tool ?? update.title;
      if (event.kind === "tool_call" && tool === "TodoWrite" && this.planRow) this.planCalls.add(callId);
      // Plumbing (Claude Code's ToolSearch) draws no row and leaves the text segment open.
      if (isPlumbingCall(update)) this.planCalls.add(callId);
      if (this.planCalls.has(callId)) return;
      // An update to a call already shown stays in its fold; a new call ends the text segment.
      const known = this.toolRows.get(callId);
      const knownRow = known && this.rows.has(known) ? known : undefined;
      // The result of a call this page never saw, naming nothing (a hidden call's, hiddenTools.ts).
      if (!knownRow && event.kind === "tool_call_update" && showsNothing(update)) return;
      if (!knownRow) this.endAssistantSegment();
      const id = knownRow ?? this.streamingActivity ?? `activity-${event.seq}`;
      const existing = this.rows.get(id);
      const items = [...(existing?.items ?? [])];
      const itemIndex = items.findIndex((item) => item.tool?.id === callId);
      const item = this.holdEdit(
        mergeToolItem(itemIndex >= 0 ? items[itemIndex] : undefined, update, callId, text, event.at),
        itemIndex < 0 || items[itemIndex].tool?.status === "pending",
      );
      const priorTool = itemIndex >= 0 ? items[itemIndex].tool : undefined;
      // Streaming output alone leaves the summary unchanged; metadata is visible immediately.
      const summaryChanged = (
        ["title", "description", "command", "inputSummary", "kind", "status", "exitCode", "startedAt"] as const
      ).some((key) => priorTool?.[key] !== item.tool?.[key]);
      if (itemIndex >= 0) items[itemIndex] = item;
      else items.push(item);
      const row: AcpmuxRow = {
        id,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "activity",
        toolCount: items.filter((entry) => entry.kind === "tool").length,
        items,
        streaming: item.tool?.status !== "completed" && item.tool?.status !== "failed",
      };
      this.rows.set(id, row, itemIndex < 0 || !row.streaming || summaryChanged);
      this.toolRows.set(callId, id);
      if (!knownRow) this.streamingActivity = id;
    } else if (event.kind === "background_task_update") {
      const task = backgroundTask(update);
      if (!task) return;
      // The shell's state goes on the call that started it: its "Ran" row turns from running in
      // the background to finished where it is, in whichever turn (Leo 2026-10-20: never a
      // second row).
      if (this.markBackgroundCall(task, event.at)) return;
      // Without its call (on a page not loaded) only how it ended is noted.
      if (task.state === "running") return;
      // Noted where it ended: the text and tool fold before it close, as a tool call's would.
      this.endAssistantSegment();
      this.streamingActivity = undefined;
      const id = `bgtask-${event.seq}`;
      this.rows.set(id, {
        id,
        version: 1,
        at: event.at,
        kind: "backgroundTask",
        backgroundTask: { ...task, state: task.state },
      });
    } else if (event.kind === "compaction") {
      const compaction = compactionOf(update);
      if (!compaction) return;
      // The cancelled compaction's boundary may arrive even after the next prompt starts another
      // compaction. Running updates carry no identity either, so they cannot lift this fence.
      // Keep unscoped boundaries from claiming completion; the turn's terminal result settles
      // any running row with the existing inferred outcome.
      if (this.compactionFenceSeq !== undefined && compaction.state !== "running") return;
      // A note between messages: the text and tool fold before it close.
      this.endAssistantSegment();
      this.streamingActivity = undefined;
      // One row per compaction: its end replaces the latest running note before it, or the
      // latest one its turn's end noted as failed (a Stop acpmux forced while the compaction
      // went on: its end comes after the turn's). Claude Code says it is compacting again every
      // 30 seconds, so a running note joins the latest one still running, or the latest one the
      // next turn's start noted as failed (it kept running into that turn); otherwise it starts
      // its own row. An older history page binds to its own rows, never to a live one.
      let running: AcpmuxRow | undefined;
      for (const row of this.rows.values())
        if (
          row.kind === "compaction" &&
          (row.compaction?.state === "running" ||
            (row.compaction?.inferred === true &&
              (compaction.state !== "running" ||
                event.at - (this.compactionHeardAt.get(row.id) ?? -Infinity) <= COMPACTION_REPEAT_WINDOW))) &&
          (compaction.state !== "running" ||
            row.turnId === undefined ||
            this.runningTurnId === undefined ||
            row.turnId === this.runningTurnId) &&
          (row.seq ?? 0) < event.seq &&
          (row.seq ?? 0) > (running?.seq ?? -1) &&
          (this.compactionFenceSeq === undefined || (row.seq ?? 0) >= this.compactionFenceSeq)
        )
          running = row;
      const id = running?.id ?? `compaction-${event.seq}`;
      const compactionTurnId = compaction.state === "running" ? this.runningTurnId : running?.turnId;
      if (compaction.state === "running") this.compactionHeardAt.set(id, event.at);
      else this.compactionHeardAt.delete(id);
      this.rows.set(id, {
        id,
        version: (running?.version ?? 0) + 1,
        at: running?.at ?? event.at,
        seq: running?.seq ?? event.seq,
        kind: "compaction",
        // Local attribution comes only from the daemon's real running turn identity; the
        // unscoped source boundary itself is never promoted to terminal-turn authority.
        ...(compactionTurnId ? { turnId: compactionTurnId } : {}),
        compaction:
          compaction.state === "running" && running?.compaction
            ? stillRunning(running.compaction, compaction)
            : compaction,
      });
    } else if (event.kind === "plan") {
      const plan = planEntries(update.entries);
      const existing = this.planRow ? this.rows.get(this.planRow) : undefined;
      // A cleared list (TodoWrite with no todos, Codex's empty plan) takes the checklist away.
      if (Array.isArray(update.entries) && plan.length === 0) {
        if (existing) this.rows.delete(existing.id);
        this.planRow = undefined;
        return;
      }
      // A new checklist ends the text and tool fold before it, as the call it stands for would.
      if (!existing) {
        this.endAssistantSegment();
        this.streamingActivity = undefined;
      }
      const id = existing ? existing.id : `plan-${event.seq}`;
      this.planRow = id;
      this.rows.set(id, {
        id,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "plan",
        ...(plan.length > 0 ? { plan } : { text: text || JSON.stringify(update.entries ?? update.content ?? "") }),
      });
    }
  }

  /// Puts a background shell's update on the call that started it, and says whether it found the
  /// call. The row's version moves, so the row draws its new state wherever it is, an ended turn's
  /// included (conversation/turns.ts reshapes the turn whose row changed). A shell ends once: a
  /// late `running` leaves an ended one as it is.
  private markBackgroundCall(task: BackgroundUpdate, at: number): boolean {
    const found = this.backgroundCall(task);
    if (!found) return false;
    const [row, index] = found;
    const items = [...(row.items ?? [])];
    const item = items[index]!;
    const tool = item.tool!;
    const ended = task.state !== "running";
    if (!ended && tool.background && tool.background.state !== "running") return true;
    const background: AcpmuxBackgroundState = {
      state: task.state,
      ...(task.reason ? { reason: task.reason } : {}),
      ...(ended ? { endedAt: at } : {}),
    };
    items[index] = { ...item, tool: { ...tool, background } };
    this.rows.set(row.id, { ...row, version: row.version + 1, items }, true);
    return true;
  }

  /// The call a background shell's update is about: the newest call with its tool call id (an
  /// adapter that numbers calls per process reuses one, cx-jzhka). An update without one goes on
  /// the newest shell call that ran the same command and has not ended in the background.
  private backgroundCall(task: BackgroundUpdate): [AcpmuxRow, number] | undefined {
    let found: [AcpmuxRow, number] | undefined;
    for (const row of this.rows.values()) {
      if (row.kind !== "activity") continue;
      (row.items ?? []).forEach((item, index) => {
        const tool = item.tool;
        if (!tool) return;
        const same = task.toolCallId
          ? tool.id === task.toolCallId
          : tool.kind === "execute" &&
            !!task.command &&
            tool.command === task.command &&
            (tool.background?.state ?? "running") === "running";
        if (same) found = [row, index];
      });
    }
    return found;
  }

  /// A call that asks before it runs waits on its permission ("pending") until it completes or
  /// fails: Claude sends a proposed edit, diff included, before it asks, and it is not an edit yet.
  private markAwaitingPermission(callId: unknown): void {
    if (callId != null) this.heldEdits.add(String(callId));
    const id = callId == null ? undefined : this.toolRows.get(String(callId));
    const row = id ? this.rows.get(id) : undefined;
    if (!row) return;
    const items = (row.items ?? []).map((item) =>
      item.tool?.id === String(callId) && item.tool.status === "in_progress"
        ? { ...item, tool: { ...item.tool, status: "pending" } }
        : item,
    );
    this.rows.set(row.id, { ...row, version: row.version + 1, items });
  }

  /// `item` as the transcript shows it: an edit that waits on a permission question stays
  /// "pending". Claude asks one question at a time, so an edit that arrives while another's
  /// question is open sends its diff before its own question, and waits too. `isNew` is whether
  /// the call had not run yet: acpmux names a call as its block starts, pending, and its input
  /// (diff included) comes in its update.
  private holdEdit(item: AcpmuxActivity, isNew: boolean): AcpmuxActivity {
    const tool = item.tool;
    if (!tool) return item;
    if (tool.status === "completed" || tool.status === "failed") {
      this.heldEdits.delete(tool.id);
      return item;
    }
    const isEdit = tool.kind === "edit" || tool.kind === "fileChange";
    if (isNew && isEdit && this.openQuestions.size > 0) this.heldEdits.add(tool.id);
    if (!this.heldEdits.has(tool.id) || tool.status === "pending") return item;
    return { ...item, tool: { ...tool, status: "pending" } };
  }

  /// The tool calls and time since the turn's user message. A prompt still sending (queued
  /// behind this turn) or one that failed to send did not start a turn.
  private turnTotals(endedAt: number): { durationMs?: number; toolCount: number } {
    // An older page's turn ends below the held rows: its own prompt is the last one before them.
    const below = this.foldingBelow;
    const rows = this.rows
      .sorted()
      .filter((row) => !row.pending && !row.failed && (below === undefined || this.rows.orderOf(row.id) < below));
    // A steer goes on with its turn: the turn's time and calls run from the prompt that opened it.
    let start = rows.length;
    while (start > 0 && (rows[start - 1]!.kind !== "user" || continuesTurn(rows[start - 1]!))) start -= 1;
    const user = rows[start - 1];
    const toolCount = rows
      .slice(start)
      .reduce((sum, row) => sum + (row.kind === "activity" ? (row.toolCount ?? 0) : 0), 0);
    return { durationMs: user ? Math.max(0, endedAt - user.at) : undefined, toolCount };
  }

  /// Closes the assistant text being streamed, so later text starts a new row below.
  /// The prompt sent now `promptId` ran: the turn it ended goes on under it.
  private continueTurn(promptId: string): void {
    if (this.awaiting === promptId) this.awaiting = undefined;
  }

  /// The prompt sent now `promptId` will not run (removed, refused, its turn failed, or another
  /// prompt ran first): the turn it ended reads as ended (Stop's "You stopped after", its footer and
  /// checkpoint). Only on a record that says so: between `dequeued` and its own record the chat reads
  /// idle while the prompt is about to run.
  private dropContinuation(promptId: string): void {
    const id = this.continuations.get(promptId);
    const summary = id ? this.rows.get(id) : undefined;
    if (summary?.continued)
      this.rows.set(summary.id, { ...summary, continued: undefined, version: summary.version + 1 });
    this.continuations.delete(promptId);
    if (this.awaiting === promptId) this.awaiting = undefined;
  }

  /// The rows of the steers that wait (snapshot `waitingSteers`), one array while the list holds.
  private steerRowIds(): readonly string[] {
    if (this.waitingSteerRows?.from !== this.waitingSteers)
      this.waitingSteerRows = {
        from: this.waitingSteers,
        rows: this.waitingSteers.map((waiting) => waiting.rowId),
      };
    return this.waitingSteerRows.rows;
  }

  /// The waiting steers (or the one `promptId` names) were read: their rows say so.
  private landSteer(promptId?: string): void {
    const read = this.waitingSteers.filter((waiting) => promptId === undefined || waiting.promptId === promptId);
    if (!read.length) return;
    this.waitingSteers = this.waitingSteers.filter((waiting) => !read.includes(waiting));
    for (const waiting of read) {
      const row = this.rows.get(waiting.rowId);
      if (row?.steer === "waiting") this.rows.set(row.id, { ...row, version: row.version + 1, steer: "landed" });
    }
  }

  /// A compaction still running when its turn ends (a Stop, the agent process exiting, a
  /// relaunch) or the next turn starts may never send how it ended: it is noted as failed, so
  /// the row stops spinning, live and when the history is read again. `inferred` lets an end
  /// that does come later (a forced Stop the compaction outlived) take the row back, and
  /// `mayGoOn` lets its next running note do so too, while it comes on time.
  private settleCompactions(seq: number, mayGoOn = false) {
    for (const row of this.rows.values())
      if (row.kind === "compaction" && row.compaction?.state === "running" && (row.seq ?? 0) < seq) {
        if (!mayGoOn) this.compactionHeardAt.delete(row.id);
        this.rows.set(row.id, {
          ...row,
          version: row.version + 1,
          compaction: { ...row.compaction, state: "failed", inferred: true },
        });
      }
  }

  private endAssistantSegment(): void {
    this.assistantCut = false;
    if (!this.streamingAssistant) return;
    const row = this.rows.get(this.streamingAssistant);
    if (row) this.rows.set(row.id, { ...row, version: row.version + 1, streaming: false });
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
  }

  /// The selected chat's rows are in, from its attach or a kept tail, or no chat is selected: what
  /// the pane draws now is the chat, not a transcript still waiting on acpmux.
  private chatRead(): boolean {
    return !this.selectedSessionId || this.drewKeptTail || this.attachedGeneration === this.selectionGeneration;
  }

  private emit(connection = this.socket?.readyState === WebSocket.OPEN ? "connected" : "disconnected"): void {
    acpmuxPerf.timed("client.emit", () => this.emitNow(connection));
  }

  /// The session list as the snapshot's entries, the same array while `this.sessions` is.
  private sessionEntryList(): AcpmuxSessionEntry[] {
    if (this.sessionEntriesOf?.sessions === this.sessions) return this.sessionEntriesOf.entries;
    const entries = this.sessions.map((session) => {
      let entry = this.sessionEntries.get(session);
      if (!entry) {
        entry = sessionEntry(session);
        this.sessionEntries.set(session, entry);
      }
      return entry;
    });
    this.sessionEntriesOf = { sessions: this.sessions, entries };
    return entries;
  }

  private emitNow(connection: string): void {
    if (this.closed && !this.replayMode && !(this.fedMode && !this.disposed)) return;
    if (this.snapshotHold) {
      this.snapshotHold.connection = connection;
      // The release draws everything since: no frame-batched snapshot is left waiting.
      this.frameSnapshot = undefined;
      return;
    }
    this.shownSessionId = this.selectedSessionId;
    // This snapshot carries every event so far, so a snapshot waiting for the frame has nothing left.
    this.frameSnapshot = undefined;
    // A new session list (the watch's page, a reread): chats whose counts moved are read again.
    if (this.askedSessions !== this.sessions) {
      this.askedSessions = this.sessions;
      this.asks.sessions(this.sessions);
    }
    const summary = this.summary;
    const limits = subsessionLimits(summary?.subsessionLimits);
    const working = this.workingNow(summary);
    if (this.drawnWorking && !working && this.drawnWorkingSession === this.selectedSessionId) this.turnsEnded += 1;
    this.drawnWorking = working;
    this.drawnWorkingSession = this.selectedSessionId;
    // A chat no longer working has no Stop pending, even when no turn event said the turn ended.
    if (!working && this.replayThrough === undefined) this.stoppingEnded();
    const effort = (summary?.configOptions ?? []).find(
      (option: any) => option.category === "thought_level" || option.id === "reasoning_effort",
    );
    this.listener({
      type: "snapshot",
      protocolVersion: 1,
      rows: this.rows.sorted(),
      subagentViews: this.subagents.views(),
      sessions: this.sessionEntryList(),
      peers: this.peers,
      peerKinds: this.peerKinds,
      peerConnected: this.peerConnected,
      peerStates: this.peerStates,
      peerResources: this.peerResources,
      ...(this.forkedAtSeq !== undefined ? { forkedAtSeq: this.forkedAtSeq } : {}),
      summary: summary
        ? {
            sessionId: summary.sessionId,
            cwd: summary.cwd,
            turnCount: summary.turnCount,
            usage: this.usage,
            contextBreakdown: contextBreakdownOf(summary.contextBreakdown),
            host: text(summary.host),
            peer: text(summary.peer),
            hostKind: hostKind(summary.hostKind),
            // acpmux's session detail names the folder's branch `gitBranch` (when the session started).
            branch: text(summary.branch) ?? text(summary.gitBranch),
            worktree: text(summary.worktree),
            title: summary.title,
            name: summary.name,
            goal: taskGoal(summary.goal),
            harness: summary.harness,
            family: typeof summary.family === "string" ? summary.family : undefined,
            agentInfo:
              summary.agentInfo && typeof summary.agentInfo === "object" && !Array.isArray(summary.agentInfo)
                ? summary.agentInfo
                : undefined,
            authSource: text(summary.authSource),
            baseUrl: text(summary.baseUrl),
            route: text(summary.route),
            settingsSources: summary.settingsSources,
            usageLimits: usageLimitsOf(summary.usageLimits) ?? text(summary.usageLimits),
            // acpmux reports `model: null` for a harness with no model (one known only from its config).
            model: text(summary.model),
            effort: effort?.currentValue,
            // `audio` only while the picked model hears it (takesAudio).
            promptCapabilities: summary.agentCapabilities?.promptCapabilities && {
              ...summary.agentCapabilities.promptCapabilities,
              audio: takesAudio(summary.agentCapabilities.promptCapabilities, summary.configOptions),
            },
            steering: summary.steering === true,
            backgroundsWork: summary.backgroundsWork === true,
            queuePaused: summary.queuePaused === true,
            ...(text(summary.watching) ? { watching: text(summary.watching) } : {}),
            ...(Array.isArray(summary.mcpServers) ? { mcpServers: summary.mcpServers } : {}),
            ...(limits ? { subsessionLimits: limits } : {}),
            status: summary.status,
            enforcement: sessionEnforcement(summary.enforcement),
            modes: summary.modes,
            configOptions: summary.configOptions,
            tools: chatTools(summary.tools),
            toolsMutable: summary.toolsMutable === true,
          }
        : undefined,
      connection,
      origin: this.origin,
      ...(this.listedSessions ? { listedSessions: true as const } : {}),
      ...(this.drewKeptTail ? { drewKeptTail: true as const } : {}),
      ...(this.peerCopy
        ? {
            peerCopy: {
              peer: this.peerCopy.peer,
              capturedAt: this.peerCopy.capturedAt,
              offline: this.peerCopy.offline,
            },
          }
        : {}),
      ...(this.chatRead() ? { chatRead: true as const } : {}),
      ...(this.extensions.includes("acp.trust.set") ? { answersTrust: true } : {}),
      ...(this.ownerCloud ? { ownerCloud: true as const } : {}),
      ...(this.extensions.includes(MCP_RECONNECT_METHOD) ? { reconnectsMcp: true } : {}),
      sessionId: this.selectedSessionId,
      // A replayed turn is history: no live "Working for" clock.
      isWorking: working,
      turnsEnded: this.turnsEnded,
      // A Stop whose turn has not ended yet (`stoppingAfterSeq`).
      ...(working && this.stoppingAfterSeq !== undefined ? { stopping: true as const } : {}),
      ...(working && this.turnPrompt ? { turnPrompt: this.turnPrompt } : {}),
      ...(this.replayThrough === undefined && this.turnTokens ? { turnTokens: this.turnTokens } : {}),
      ...(this.replayThrough === undefined && this.turnTokens && this.turnTokenSplit
        ? { turnTokenSplit: this.turnTokenSplit }
        : {}),
      ...(this.replayThrough === undefined && this.turnOpen && this.silentTurn ? { silentTurn: true as const } : {}),
      // Only a peer runs on another clock; this computer's own sessions need no correction.
      ...(summary?.peer && this.clockOffset !== undefined ? { clockOffsetMs: this.clockOffset } : {}),
      canFork: this.canFork,
      canHandoff: this.handoffSupported,
      handoff: this.handoff.state,
      permissionGroups: this.permissions.state,
      queue: this.shownQueue(),
      ...(this.queueWithdrawn.length ? { queueWithdrawn: this.queueWithdrawn } : {}),
      // Two or more steers the agent has not read: the transcript draws other sessions' as one card.
      ...(this.waitingSteers.length > 1 ? { waitingSteers: this.steerRowIds() } : {}),
      permission: this.pendingPermission,
      ...(this.pendingPermission && this.waitingPermissions.size > 0
        ? { permissionsWaiting: this.waitingPermissions.size }
        : {}),
      secret: this.pendingSecret,
      asks: this.asks.list(),
      catalog: [],
      commands: this.commands,
      canLoadOlder: this.seqHistoryLeft() || this.nativeBefore() !== undefined,
      ...(this.shownEarlierPrompts().length ? { earlierPrompts: this.shownEarlierPrompts() } : {}),
      ...(this.promptCountAwaited() !== undefined ? { promptCount: this.promptCountAwaited() } : {}),
      historyFrom: this.firstSeq,
      missingSession: this.selectedSessionId ? undefined : this.missingSession,
      unavailable: this.unavailableNow(),
      missingReason: this.selectedSessionId ? undefined : this.missingReason,
      liveChat: this.liveAdopt && {
        canFork: this.liveAdopt.canFork,
        command: this.liveAdopt.command,
      },
      liveTakeOver: this.liveTakeOverFor === this.selectedSessionId ? this.liveTakeOver : undefined,
    });
  }

  snapshot(): void {
    this.emit();
  }
  /** The session this pane shows, if any. */
  get selectedSession(): string | undefined {
    return this.selectedSessionId;
  }
  /** Changes on every selection, including leaving and returning to the same session. */
  get selectionToken(): number {
    return this.selectionGeneration;
  }
  /** Whether the client's latest selection change was its own fallback away from `sessionId`
   *  (the chat left the list), not a chat the person selected since. */
  fellBackFrom(sessionId: string | undefined): boolean {
    return (
      sessionId !== undefined &&
      this.fallback?.from === sessionId &&
      this.fallback.generation === this.selectionGeneration
    );
  }
  /** Whether a purge owns the selected session's disappearance. */
  get purgeInFlight(): boolean {
    return this.purgingSessionId !== undefined;
  }
  /** A copy of the selected session's recorded events, oldest first, for the inspector. */
  sessionEvents(): EventRecord[] {
    return this.events.slice();
  }
  /** The rows message `messageId` streamed into, oldest first; empty when this session has none.
   *  A `message=<id>` link scrolls to the first one that is on screen (links.ts). */
  rowsOfMessage(messageId: string): readonly string[] {
    return this.messageRows.get(messageId) ?? [];
  }
  /** A new chat starting (`create`): a Send meanwhile waits for it and goes to the new chat, not to
   *  the session still on screen (a harness pick), and a Send with no session joins it. */
  private creating?: Promise<string | undefined>;

  /// Opens a chat's Cloud hand-off turn before a prompt that starts one (cloudHandoffTurn.ts); set
  /// by the page only for a chat on a Cloud machine whose app opens them.
  handoffTurn?: (sessionId: string) => Promise<number | undefined>;
  /// The hand-off turn each chat asks the app for now (sendNow), with the selection it was asked in.
  private handoffAsks = new Map<string, { generation: number; ask: Promise<number | undefined> }>();
  /// The newest hand-off turn each chat sent a prompt under: the store may still say it is `starting`
  /// (the machine's reports go on their own time), and another prompt never names it.
  private handoffTurnsSent = new Map<string, number>();
  /// A New Tab start suspended for Trust settles when its selection or client goes away.
  private cancelTrustStart?: () => void;

  async ensureSession(): Promise<string | undefined> {
    // This send belongs to the requested chat. A refused or empty start must not send it to
    // the previous chat, or start the default harness instead of the one the person picked.
    if (this.creating || !this.selectedSessionId) {
      // A rejected seeded peer start stays sessionless. The next Send retries that peer,
      // with its own folder, instead of silently falling back to a local session.
      const sessionId = await (this.creating ??
        this.create(this.host.harness, this.host.peer ? this.host.cwd : undefined, this.host.peer));
      // The app also calls this before send(): an empty result must stop that preflight,
      // otherwise send() would ensure again after the failed creation has been cleared.
      if (!sessionId) throw new Error(translate("error.notOpen"));
      return sessionId;
    }
    return this.selectedSessionId;
  }

  /// Starts one live agent child for each of the most recent project sessions whose folder an
  /// agent may use unasked (`isWarmableCwd`).
  /// Old daemons simply reject this extension, so warming never blocks chat.
  async warmRecentProjects(limit = 3): Promise<void> {
    const ids: string[] = [];
    const seen = new Set<string>();
    // By real activity: warming moves `updatedAt`, so sorting on it would keep re-warming the same chats.
    const recent = (session: Record<string, any>) => summaryActivityAt(session) ?? 0;
    for (const session of [...this.sessions].sort((a, b) => recent(b) - recent(a))) {
      const cwd = typeof session.cwd === "string" ? session.cwd : "";
      // Never the home folder or a privacy-protected one (warmFolders.ts).
      if (!cwd || seen.has(cwd) || !isWarmableCwd(cwd)) continue;
      seen.add(cwd);
      ids.push(session.sessionId);
      if (ids.length >= limit) break;
    }
    if (!ids.length) return;
    await this.request("_acpmux/warm", { sessionIds: ids, limit }).catch(() => undefined);
  }
  /// Sends a prompt. `promptId` keys its optimistic row (`local-<promptId>`), so a prompt the
  /// pane drew while a harness started keeps its row once it goes out (harnessSwitch.ts).
  /// `accepted` runs once acpmux took the prompt (its echo or its reply); a refusal comes before
  /// that, and then a caller that passed `accepted` still holds the prompt (the composer keeps
  /// it), so the prompt leaves no bubble and the refusal names its reason in the transcript.
  /// `ticket`: the gesture a send kept for this prompt while acpmux held it for the folder trust
  /// answer (heldPrompt.ts); it rides as `_meta.cmuxGesture`, and the host strips it. Without one,
  /// a send into a shown chat binds the person's Enter or click to this prompt before any waits.
  /// `steer`: into the running turn, read when the agent's current step ends; an agent that
  /// cannot steer queues it behind the turn. Nothing sent stops the turn: only Stop does (Leo
  /// 2026-10-20), so no send carries `_meta.acpmux.interrupt`. No send carries
  /// `_meta.acpmux.resend` either: the host refuses a page frame that does, and marks a resend
  /// itself (#22881, AgentPanePromptRelay.swift).
  /// The composer's text changed (`chat.typing`): acpmux hears only that this pane types.
  typing(text: string, sessionId?: string): void {
    this.presence.typed(text, sessionId);
  }

  /// Binds the person's current gesture to one prompt before the caller waits for a start or
  /// persistence. The host still refuses frames without a ticket, so forged/script sends remain
  /// denied; a ticket is scoped to this prompt id and can be spent only once.
  bindSendGesture(
    promptId: string = crypto.randomUUID(),
  ): { promptId: string; ticket: Promise<string | undefined> } | undefined {
    return { promptId, ticket: reservePromptGesture(promptId) };
  }

  async send(
    input: string,
    attachments: ComposerAttachment[] = [],
    promptId: string = crypto.randomUUID(),
    accepted?: () => void,
    ticket?: string | Promise<string | undefined>,
    steer = false,
    /// Safe to close the page: acpmux has acknowledged this prompt, including a queued one.
    onTaken?: () => void,
  ): Promise<string | undefined> {
    const reserved = ticket ?? this.bindSendGesture(promptId)?.ticket;
    this.presence.stopTyping();
    this.untakenSends += 1;
    let untaken = true;
    const settle = () => {
      if (untaken) this.untakenSends -= 1;
      untaken = false;
    };
    try {
      return await this.sendNow(input, attachments, promptId, accepted, reserved, steer, settle, onTaken);
    } finally {
      settle();
    }
  }

  /// WEB-SWAP: why a web update's reload would lose a prompt this page holds: one acpmux has not
  /// taken yet, or a failed one whose Retry lives only in this page (pages/shared/webSwap.ts).
  swapHold(): string | null {
    if (this.untakenSends > 0) return "composer.send-untaken";
    return this.failedPrompts.size ? "composer.send-failed" : null;
  }

  private async sendNow(
    input: string,
    attachments: ComposerAttachment[],
    promptId: string,
    accepted: (() => void) | undefined,
    ticket: string | Promise<string | undefined> | undefined,
    steer: boolean,
    /// acpmux took it: the page no longer holds the only copy.
    tookIt: () => void,
    onTaken?: () => void,
  ): Promise<string | undefined> {
    const trustCancellation = this.trustCancellation;
    // A `data:` image written into the prompt goes as an image, never as text: the bubble, the
    // agent and the chat's compaction never see base64 (inlineImages.ts, Leo 2026-10-20).
    ({ text: input, attachments } = liftInlineImages(input, attachments));
    // A chat opening (a switch) is drawn first: the prompt goes to it once it shows, never while the
    // pane still draws the chat before.
    while (this.snapshotHold && this.shownSessionId !== this.selectedSessionId) await this.snapshotHold.released;
    // A handoff not read yet (the pane draws the composer meanwhile) is read now; one that cannot be
    // read is a connection problem, not a continuation to review.
    if (this.handoffSupported && this.selectedSessionId && !this.handoff.state.ready) {
      await this.handoff.refresh().catch(() => undefined);
      if (!this.handoff.state.ready) throw new Error(translate("error.notOpen"));
    }
    const record = this.handoff.state.record;
    if (
      this.handoffSupported &&
      this.selectedSessionId &&
      (!this.handoff.state.ready ||
        (record?.target.sessionId === this.selectedSessionId &&
          record.state !== "started" &&
          record.state !== "discarded" &&
          !this.handoff.state.receipt))
    )
      throw new Error(translate("error.reviewContinuation"));
    // A shown session takes the prompt in this task, so its row draws in the frame of the send;
    // while a new chat starts, the prompt waits for it (ensureSession).
    const shown = this.creating ? undefined : this.selectedSessionId;
    const sessionId = shown ?? (await this.ensureSession());
    // No chat took it: the sender gets the prompt back (a started chat's composer let go of it).
    if (!sessionId) throw new Error(translate("error.notOpen"));
    // A chat on a Cloud machine: a prompt that starts a turn names the hand-off turn the app opened
    // for it (cloudHandoffTurn.ts), so the machine reports that turn. Not a steer or a prompt behind
    // a running turn or the queue (it starts no turn of its own), and never a prompt that already
    // names one: a Retry keeps its id, so a copy acpmux took runs once.
    // One ask per chat at a time: a send while an ask is out goes behind that prompt (it starts no
    // turn of its own) and under its own id, once the ask ends. Either await lets the selection move:
    // a prompt whose chat is no longer the one shown goes back to its sender, never drawn in the
    // other chat. An ask from before the chat was shown again belongs to such a prompt: a send now
    // asks again, and the app names the turn that ask opened (a turn not run yet is named again).
    // A Retry keeps the id its prompt first went with, named or not: acpmux may hold that copy.
    /// The turn this prompt claimed (`handoffTurnsSent`) and the claim before it.
    let claim: { turn: number; before: number | undefined } | undefined;
    if (this.handoffTurn && !steer && !namesHandoffTurn(promptId) && !this.retriedPrompts.has(promptId)) {
      const generation = this.selectionGeneration;
      let named: number | undefined;
      const asking = this.handoffAsks.get(sessionId);
      if (asking?.generation === generation) await asking.ask;
      else if (!(shown === sessionId && (this.turnOpen || this.queue.length > 0))) {
        const entry = { generation, ask: this.handoffTurn(sessionId) };
        this.handoffAsks.set(sessionId, entry);
        let turn: number | undefined;
        try {
          turn = await entry.ask;
        } finally {
          if (this.handoffAsks.get(sessionId) === entry) this.handoffAsks.delete(sessionId);
        }
        // A turn this page already sent a prompt under is that prompt's, even while the store has not
        // heard it run yet; a turn the app opened after the wait ran out is named (nothing ran under it).
        if (turn !== undefined && turn > (this.handoffTurnsSent.get(sessionId) ?? 0)) named = turn;
      }
      if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId)
        throw new Error(translate("error.notOpen"));
      if (named !== undefined) {
        claim = { turn: named, before: this.handoffTurnsSent.get(sessionId) };
        this.handoffTurnsSent.set(sessionId, named);
        promptId = handoffPromptId(named, promptId);
      }
    }
    // A paste sent as its own block shows in the bubble as acpmux's echo will have it (pastedText.ts).
    const supportsAudio = takesAudio(this.summary?.agentCapabilities?.promptCapabilities, this.summary?.configOptions);
    const audible = supportsAudio ? attachments : attachments.filter((attachment) => attachment.kind !== "audio");
    // A video's frames go as images (composer/videoPrompt.ts): an agent that takes none gets its link.
    const sendAttachments =
      this.summary?.agentCapabilities?.promptCapabilities?.image === false ? withoutFrames(audible) : audible;
    const dropped = new Set(
      attachments.filter((attachment) => !audible.includes(attachment)).map((attachment) => attachment.id),
    );
    const options = { dropped: (id: string) => dropped.has(id) };
    // The prompt is one acpmux message: past its budget, the largest image previews go as the links
    // to their saved originals (promptBudget.ts). The row and a Retry keep what the prompt carried:
    // such an image is its original's link, drawn as a file as acpmux's echo and a reload draw it.
    const carried = fitPromptBudget(input, sendAttachments, options);
    if (carried !== sendAttachments) {
      const linked = new Map(carried.map((chip) => [chip.id, chip]));
      attachments = attachments.map((chip) => linked.get(chip.id) ?? chip);
    }
    const blocks = promptBlocks(input, carried, options);
    const inline = inlinePrompt(input, carried);
    const fileDisplay = inline?.display ?? stripFileDisplay(blocks, carried);
    const { text, pasted } = inline
      ? blocks.reduce(
          (shown, block) => {
            // A video's frames note is the agent's; the bubble draws the video's tile.
            if (block.type !== "text" || isFramesNote(block.text)) return shown;
            if (shown.text) shown.text += "\n";
            const start = shown.text.length;
            shown.text += block.text;
            if (block._meta?.cmux.pasted) shown.pasted.push({ start, end: shown.text.length });
            return shown;
          },
          { text: "", pasted: [] as { start: number; end: number }[] },
        )
      : shownPrompt(promptText(input, carried, options), carried);
    const rowId = `local-${promptId}`;
    const at = Date.now();
    this.promptRowKeys.set(promptId, rowId);
    this.optimisticPromptRows.set(promptId, rowId);
    this.optimisticPromptTexts.set(promptId, text);
    if (attachments.length) {
      this.optimisticPromptAttachments.set(promptId, attachments);
      if (inline) {
        this.optimisticPromptParts.set(promptId, inline.parts);
        this.optimisticPromptInputs.set(promptId, input);
      }
      // The sent bubble draws these images from the pane's own bytes, at their shape, the moment
      // acpmux's echo names them (conversation/imageEntries.ts).
      void primeSentImages(attachments);
    }
    // A prompt behind the shown chat's running turn waits in the queue: it shows there from the
    // send on, never first as a transcript bubble that acpmux's `queued` record then moves.
    const waits = !steer && shown === sessionId && this.turnOpen;
    const generation = this.selectionGeneration;
    // The prompt's way to acpmux and the agent, drawn on its row (composer-delivery-DESIGN.md).
    const before = this.deliveries.get(promptId);
    before?.timers.forEach(clearTimeout);
    const delivery: PromptDelivery = {
      state: "sending",
      promptId,
      sessionId,
      sentAt: at,
      ...(this.summary?.host ? { connection: String(this.summary.host) } : {}),
    };
    this.deliveries.set(promptId, { delivery, rowId, timers: [] });
    if (waits) {
      this.queue = [
        ...this.queue.filter((entry) => entry.id !== promptId),
        queuedEntry(promptId, text, false, true, attachedImages(attachments), undefined, undefined, inline?.parts),
      ];
      // A Retry behind the turn waits in the queue: its failed bubble goes.
      this.rows.delete(rowId);
    }
    // A Retry draws over its failed row: a newer version, so the memoized row redraws.
    else
      this.rows.set(rowId, {
        id: rowId,
        version: (this.rows.get(rowId)?.version ?? 0) + 1,
        at,
        kind: "user",
        text,
        ...(pasted.length ? { pasted } : {}),
        ...(inline ? { inlineParts: inline.parts } : {}),
        ...(attachments.length ? { images: attachedImages(attachments), retryAttachments: attachments } : {}),
        pending: true,
        delivery,
      });
    let taken = false;
    let released = false;
    // The chat's first prompt carries its workspace context, once: a prompt acpmux took used it,
    // and a prompt sent while one carrying it is in flight goes without it.
    const workspace = this.host.workspaceContext && !this.contextInFlight ? WORKSPACE_CONTEXT : undefined;
    if (workspace) this.contextInFlight = true;
    // Each attached video's speech, as the host heard it, goes beside it (composer/videoTranscript.ts).
    const context = promptContext(workspace, carried);
    /// The sender (the composer) lets go of the prompt.
    const release = () => {
      if (released) return;
      released = true;
      accepted?.();
    };
    const accept = () => {
      this.promptAccepts.delete(promptId);
      if (taken) return;
      taken = true;
      tookIt();
      if (workspace) this.host = { ...this.host, workspaceContext: undefined };
      if (this.setDelivery(promptId, { state: "delivered", acceptedAt: Date.now() })) this.emit();
      release();
      onTaken?.();
    };
    this.promptAccepts.set(promptId, accept);
    this.sentPrompts.add(promptId);
    // A prompt behind the turn is drawn in the queue now: that row shows the send, so the composer
    // is free for the next prompt without waiting for acpmux (a lagged event stream can lose its
    // `queued` record). The context is spent only when acpmux takes it.
    if (waits) release();
    // No answer for a while: the row says it is still sending, and then that it failed, with Retry
    // (the same prompt id, so a copy acpmux did take runs once). A late acceptance still lands.
    const timers = this.deliveries.get(promptId)!.timers;
    // On a connection to this Mac's acpmux, a delayed acknowledgement is usually an in-flight prompt
    // (a busy session; the native relay journals the approved frame for the same promptId), so it
    // fails only after the longer `localFailMs`: the journal may not have kept it (too large,
    // evicted, no journal), and the page cannot tell, so it never stays sending forever. Other
    // connections have no relay journal and fail after `failMs`. Both fail with Retry under the
    // same promptId and keep the slow marker; an explicit RPC refusal below fails at once. A sender
    // that still holds the prompt (`accepted`: a new chat's, the Quick Composer's or a View Only
    // chat's composer; a started chat's composer lets go at once) keeps it in its composer at either
    // deadline, as before: there is no failed row then, so no second copy to send.
    timers.push(
      setTimeout(() => {
        if (this.deliveries.get(promptId)?.delivery.state === "sending" && this.setDelivery(promptId, { slow: true })) {
          this.emit();
          this.checkStall(sessionId);
        }
      }, deliveryTiming.slowMs),
    );
    timers.push(
      setTimeout(
        () => {
          if (this.deliveries.get(promptId)?.delivery.state !== "sending") return;
          // A sender that still holds the prompt (a new chat's composer) keeps it there: no second
          // copy as a failed row.
          if (accepted !== undefined && !released) return;
          this.queue = this.queue.filter((entry) => entry.id !== promptId);
          const shownRow = this.rows.get(rowId) ?? {
            id: rowId,
            version: 1,
            at,
            kind: "user",
            text,
            images: attachedImages(attachments),
            retryAttachments: attachments,
            ...(inline ? { inlineParts: inline.parts } : {}),
          };
          this.rows.set(rowId, {
            ...shownRow,
            pending: false,
            failed: true,
            error: translate("prompt.delivery.noAnswer"),
            version: shownRow.version + 1,
          });
          this.deliveries.get(promptId)!.rowId = rowId;
          this.failedPrompts.set(rowId, { input, attachments, promptId });
          this.setDelivery(promptId, {
            state: "failed",
            failedAt: Date.now(),
            hop: "acpmux",
            code: "timeout",
            error: translate("prompt.delivery.noAnswer"),
          });
          this.emit();
        },
        this.localOrigin ? deliveryTiming.localFailMs : deliveryTiming.failMs,
      ),
    );
    this.emit();
    const gesture = await ticket;
    try {
      await this.request("session/prompt", {
        sessionId,
        // A recording goes only to a harness that takes voice input; one moved to another
        // harness (a switch, a held prompt put back) goes as its transcript.
        prompt: blocks,
        _meta: {
          acpmux: {
            promptId,
            ...(steer ? { steer: true } : {}),
            ...(context ? { context } : {}),
            ...(fileDisplay.length ? { inlineParts: fileDisplay } : {}),
            ...promptSurfaceMeta(),
          },
          ...(gesture ? { cmuxGesture: gesture } : {}),
        },
      });
      accept();
      // A steer's answer comes once the agent read it (Claude Code's `steered`) or its turn ended.
      if (
        steer &&
        this.selectedSessionId === sessionId &&
        this.waitingSteers.some((waiting) => waiting.promptId === promptId)
      ) {
        this.landSteer(promptId);
        this.emit();
      }
      // Ran or withdrawn: what it held for its bubble and queue row is done with.
      if (this.queue.some((entry) => entry.id === promptId))
        this.queue = this.queue.filter((entry) => entry.id !== promptId);
      this.queuedSends.delete(promptId);
    } catch (error) {
      this.promptAccepts.delete(promptId);
      // A Send now refused at dispatch answers its sender with the refusal (a remote acpmux sends the
      // pane no prompt_refused record): the turn it ended reads as ended. A transport error (a
      // closed socket fails every request with `native.*`) is no refusal: acpmux still runs it.
      const code = (error as { code?: unknown } | null)?.code;
      if (promptId === this.awaiting && !String(code ?? "").startsWith("native.")) {
        this.dropContinuation(promptId);
        this.emit();
      }
      // A refused prompt did not use the context: the next send carries it.
      if (workspace && !taken) this.contextInFlight = false;
      // A queued prompt refused when its turn came gets its bubble back, to fail with Retry.
      const queued = this.queuedSends.delete(promptId);
      // Only into the chat it was sent in, still shown: its Retry sends there.
      const here = generation === this.selectionGeneration && this.selectedSessionId === sessionId;
      if (here && (queued || waits)) {
        this.queue = this.queue.filter((entry) => entry.id !== promptId);
        this.optimisticPromptRows.set(promptId, rowId);
        if (!this.rows.has(rowId))
          this.rows.set(rowId, {
            id: rowId,
            version: 1,
            at,
            kind: "user",
            text,
            pending: true,
            images: attachedImages(attachments),
            retryAttachments: attachments,
            ...(inline ? { inlineParts: inline.parts } : {}),
          });
      }
      const refused = typeof code === "string" && code.startsWith("transport.");
      // acpmux holds every prompt while the folder's trust question is open (`trust_gate.rs`), and
      // a sender that holds its prompt (`accepted`) keeps every refused one: the prompt never
      // went, so it leaves no bubble, and the pane keeps it in (or puts it back in) the composer.
      const held = !released && accepted !== undefined;
      // The folder's trust question (the one route); the pane's sender adds the re-send.
      if (here && trustCancellation === this.trustCancellation) this.routeTrustRefusal(error);
      if (held) {
        // Refused before acpmux took it, back in the composer: it never ran, so its turn is free for
        // the next Send (an ambiguous failure keeps the claim: acpmux may run it).
        if (claim && refused && !taken && this.handoffTurnsSent.get(sessionId) === claim.turn) {
          if (claim.before === undefined) this.handoffTurnsSent.delete(sessionId);
          else this.handoffTurnsSent.set(sessionId, claim.before);
        }
        this.rows.delete(rowId);
        this.optimisticPromptRows.delete(promptId);
        this.optimisticPromptTexts.delete(promptId);
        this.optimisticPromptAttachments.delete(promptId);
        this.optimisticPromptParts.delete(promptId);
        this.optimisticPromptInputs.delete(promptId);
        this.deliveries.get(promptId)?.timers.forEach(clearTimeout);
        this.deliveries.delete(promptId);
        // The prompt is still in the composer, so Enter sends it again (no Retry button). A refusal
        // for want of a real key or click (dictation's autoSend after a session ended by itself)
        // says just that, not the generic refusal's pick wording (cx-w2p8r).
        if (held && !isTrustRefusal(error))
          this.notice(
            code === "transport.gesture_required"
              ? translate("prompt.notSentAgain")
              : failedSendText(error, false, sendAttachments),
          );
        else this.emit();
        throw error;
      }
      const refusedAtTurn = queued && !String(code ?? "").startsWith("native.");
      // The connection went before acpmux took it (`rejectPending`, a closed client): this client's
      // rows go with it, so the sender gets the prompt back instead of a row nobody will see.
      if (!taken && (this.closed || code === "native.timed_out")) {
        this.rows.delete(rowId);
        this.failedPrompts.delete(rowId);
        this.optimisticPromptRows.delete(promptId);
        this.optimisticPromptTexts.delete(promptId);
        this.optimisticPromptAttachments.delete(promptId);
        this.optimisticPromptParts.delete(promptId);
        this.optimisticPromptInputs.delete(promptId);
        this.deliveries.get(promptId)?.timers.forEach(clearTimeout);
        this.deliveries.delete(promptId);
        this.emit(refused ? undefined : "failed");
        throw error;
      }
      const row = this.rows.get(rowId);
      if (row && taken && !refusedAtTurn) {
        // The daemon already echoed this prompt. Its durable row intentionally remains mounted, so
        // a later transport error must not turn an accepted prompt into a failed retry card.
        this.deliveries.get(promptId)?.timers.forEach(clearTimeout);
        this.deliveries.delete(promptId);
        if (error && typeof error === "object") Object.assign(error, { taken: true });
      } else if (row) {
        // A new row object: the transcript's rows are memoized on identity and version. The
        // bubble says why it got no reply in one plain sentence chosen by the refusal's reason and
        // code (sendFailure.ts); the refuser's own words and code stay for Details.
        const reason = (error as { reason?: unknown } | null)?.reason;
        this.rows.set(rowId, {
          ...row,
          pending: false,
          failed: true,
          error: failedSendText(error, this.retriedPrompts.has(promptId), sendAttachments),
          version: row.version + 1,
        });
        this.failedPrompts.set(rowId, { input, attachments, promptId });
        this.setDelivery(promptId, {
          state: "failed",
          failedAt: Date.now(),
          hop: deliveryHop(typeof code === "string" ? code : undefined, taken),
          ...(typeof code === "string" ? { code } : {}),
          ...(typeof reason === "string" ? { reason } : {}),
          error: error instanceof Error ? error.message : errorMessage(error),
        });
        // The prompt stays as this failed row: the pane's sender puts nothing back in the composer,
        // and a Trust answer re-sends this row (not whatever the composer holds then).
        if (error && typeof error === "object") Object.assign(error, { failedRow: rowId });
      } else {
        this.deliveries.get(promptId)?.timers.forEach(clearTimeout);
        this.deliveries.delete(promptId);
        // acpmux took it and its echo drew it in the transcript: what ends its request later (the
        // turn's error, a steer's, a dropped connection) is the transcript's, and the prompt never
        // goes back to the composer, where a send would run it twice. A queued prompt refused when
        // its turn came never ran: that refusal is still the sender's to give back.
        if (taken && !refusedAtTurn && error && typeof error === "object") Object.assign(error, { taken: true });
      }
      this.optimisticPromptRows.delete(promptId);
      this.optimisticPromptTexts.delete(promptId);
      this.optimisticPromptAttachments.delete(promptId);
      this.optimisticPromptParts.delete(promptId);
      this.optimisticPromptInputs.delete(promptId);
      // The host refused one frame and answered it: the connection is as it was.
      this.emit(refused ? undefined : "failed");
      throw error;
    }
    return sessionId;
  }

  /// Moves prompt `promptId` on its way (states only go forward; a send that timed out still takes
  /// a late acceptance) and redraws the row or queue entry that shows it. False when nothing changed.
  private setDelivery(promptId: string, patch: Partial<PromptDelivery>, rowId?: string): boolean {
    const entry = this.deliveries.get(promptId);
    if (!entry) return false;
    const { delivery } = entry;
    const timedOut = delivery.state === "failed" && delivery.code === "timeout";
    if (patch.state && patch.state !== "failed") {
      if (delivery.state === "failed" && !timedOut) return false;
      if (!timedOut && DELIVERY_RANK[patch.state] < DELIVERY_RANK[delivery.state]) return false;
    }
    if (patch.state === "failed" && delivery.state === "failed" && !timedOut) return false;
    const next: PromptDelivery = { ...delivery, ...patch };
    if (next.state !== "failed") {
      delete next.hop;
      delete next.code;
      delete next.reason;
      delete next.error;
      delete next.failedAt;
    }
    if (next.state !== "sending") delete next.slow;
    entry.delivery = next;
    if (rowId) entry.rowId = rowId;
    if (next.state !== "sending" && next.state !== "failed") {
      entry.timers.forEach(clearTimeout);
      entry.timers = [];
    }
    const recovered = timedOut && next.state !== "failed";
    if (recovered) this.failedPrompts.delete(`local-${promptId}`);
    const row = this.rows.get(entry.rowId);
    if (row) {
      this.rows.set(entry.rowId, {
        ...row,
        delivery: next,
        ...(recovered ? { failed: false, error: undefined, pending: next.state === "sending" } : {}),
        version: row.version + 1,
      });
    }
    if (this.queue.some((queued) => queued.id === promptId && Boolean(queued.sending) !== (next.state === "sending")))
      this.queue = this.queue.map((queued) =>
        queued.id === promptId
          ? queuedEntry(
              queued.id,
              queued.prompt,
              queued.next === true,
              next.state === "sending",
              queued.images,
              queued.message,
              queued.author,
              queued.inlineParts,
              queued.retry,
            )
          : queued,
      );
    return true;
  }
  /// The delivery of prompt row `rowId`, for its Details.
  promptDelivery(rowId: string): PromptDelivery | undefined {
    return this.rows.get(rowId)?.delivery;
  }

  /// Retry on a prompt that was not sent: its bubble goes and the same prompt goes again, under the
  /// same prompt id, so a copy acpmux did take answers as that one and runs no second turn (acpmux runs
  /// a prompt id once). It carries no `resend`: the host refuses that from the page (#22881) and marks
  /// a prompt id it sent the daemon before a resend itself, so acpmux also finds a first copy in the
  /// chat's log after a daemon restart.
  /// `ticket`: the gesture a trust refusal kept for this prompt (heldPrompt.ts).
  async retryPrompt(rowId: string, ticket?: string): Promise<string | undefined> {
    const failed = this.failedPrompts.get(rowId);
    if (!failed) return undefined;
    this.failedPrompts.delete(rowId);
    // A prompt with an id goes again under it, over its own row; an older one gets a new row.
    if (!failed.promptId) {
      this.rows.delete(rowId);
      this.emit();
    }
    // A Retry refused again says "Still not sent", so the click visibly did something (hq#2569 item 5).
    const promptId = failed.promptId ?? crypto.randomUUID();
    this.retriedPrompts.add(promptId);
    try {
      return await this.send(failed.input, failed.attachments, promptId, undefined, ticket);
    } finally {
      this.retriedPrompts.delete(promptId);
    }
  }
  /// Retry on a card for a run of prompts that were not sent for one cause (sendFailure.ts). One
  /// click is one gesture, which the host spends on one `session/prompt`, so the run goes again as
  /// one prompt: its texts in order, its attachments together, over `anchor`'s row and under its
  /// prompt id (a trust refusal's kept gesture is bound to that id, heldPrompt.ts). The run's other
  /// rows go.
  async retryPrompts(rowIds: readonly string[], ticket?: string, anchor?: string): Promise<string | undefined> {
    // A prompt too large to send is refused the same way again, from any Retry (the card, the
    // message menu): it stays failed until Edit takes an attachment out.
    const run = rowIds.filter((id) => this.failedPrompts.has(id) && retryHelps(sendCause(this.rows.get(id)?.delivery)));
    const kept = anchor && run.includes(anchor) ? anchor : run[run.length - 1];
    if (!kept) return undefined;
    if (run.length > 1) {
      const failed = run.map((id) => this.failedPrompts.get(id)!);
      const into = this.failedPrompts.get(kept)!;
      for (const id of run) if (id !== kept) this.dropFailedPrompt(id, this.failedPrompts.get(id)?.promptId);
      this.failedPrompts.set(kept, {
        input: failed.map((prompt) => prompt.input).join("\n\n"),
        attachments: failed
          .flatMap((prompt) => prompt.attachments)
          .filter((attachment, index, all) => all.findIndex((other) => other.id === attachment.id) === index),
        ...(into.promptId ? { promptId: into.promptId } : {}),
      });
    }
    return this.retryPrompt(kept, ticket);
  }
  /// What a run of failed rows holds now, for a Trust replay to keep across a chat switch.
  failedPromptCopies(rowIds: readonly string[]): FailedPromptCopy[] {
    return rowIds.flatMap((rowId) => {
      const failed = this.failedPrompts.get(rowId);
      return failed ? [{ rowId, ...failed }] : [];
    });
  }
  /// Puts back the failed prompts of `copies` that a chat switch cleared, so a Trust replay sends
  /// them. One the person removed or took back into the composer stays gone, and each comes back once.
  restoreFailedPrompts(copies: readonly FailedPromptCopy[]): void {
    for (const { rowId, ...failed } of copies)
      if (!this.failedPrompts.has(rowId) && this.clearedBySwitch.delete(rowId)) this.failedPrompts.set(rowId, failed);
  }
  /// Edit on a prompt that was not sent: its row goes and what it held comes back, for the composer.
  takeFailedPrompt(rowId: string): { input: string; attachments: ComposerAttachment[] } | undefined {
    // The person's Edit, also on the snapshot a held chat switch still shows: no replay brings it back.
    this.clearedBySwitch.delete(rowId);
    const failed = this.failedPrompts.get(rowId);
    if (!failed) return undefined;
    this.dropFailedPrompt(rowId, failed.promptId);
    return { input: failed.input, attachments: failed.attachments };
  }
  /// Remove on a prompt that was not sent: its row goes.
  removeFailedPrompt(rowId: string): void {
    // The person's Remove, also on the snapshot a held chat switch still shows: no replay brings it back.
    this.clearedBySwitch.delete(rowId);
    const failed = this.failedPrompts.get(rowId);
    if (failed) this.dropFailedPrompt(rowId, failed.promptId);
  }
  private dropFailedPrompt(rowId: string, promptId: string | undefined): void {
    this.failedPrompts.delete(rowId);
    this.rows.delete(rowId);
    if (promptId) {
      this.deliveries.get(promptId)?.timers.forEach(clearTimeout);
      this.deliveries.delete(promptId);
    }
    this.emit();
  }
  async resendPrompt(rowId: string, text: string): Promise<{ input: string; attachments: ComposerAttachment[] }> {
    const failed = this.failedPrompts.get(rowId);
    if (failed) return { input: failed.input, attachments: failed.attachments };
    const row = this.rows.get(rowId);
    const sent = this.retryInputs.get(rowId);
    const kept = this.retryAttachments.get(rowId);
    if (kept && sent === undefined) return { input: text, attachments: resentAttachments(kept) };
    if (sent !== undefined && kept && hasInlineMarks(sent, kept)) {
      if (text === (row?.resend ?? row?.text)) return { input: sent, attachments: kept };
      return {
        input: carryInline(sent, text, kept),
        attachments: kept.filter((a) => a.kind !== "pasted" && a.kind !== "text"),
      };
    }
    if (row?.inlineParts?.length) return restoreInline(row, text, (id) => this.promptImageData(id));
    return { input: text, attachments: await this.promptAttachments(rowId) };
  }
  /// What to send again with prompt row `rowId` (Retry, Edit): the attachments this page sent, else
  /// its images read back from acpmux (a prompt sent before a reload, or from another window).
  async promptAttachments(rowId: string): Promise<ComposerAttachment[]> {
    // The text sent again is the echo, which holds each paste: the pasted chips stay out.
    const kept = this.retryAttachments.get(rowId);
    if (kept?.length) return resentAttachments(kept);
    const images = this.rows.get(rowId)?.images ?? [];
    const read = await Promise.all(
      images.map(async (image, index): Promise<ComposerAttachment | undefined> => {
        const data = await this.promptImageData(image.id);
        if (!data) return undefined;
        return {
          id: `sent-${image.id}`,
          kind: "image",
          name: image.name ?? `image-${index + 1}`,
          mimeType: data.mimeType,
          size: Math.floor((data.data.length * 3) / 4),
          data: data.data,
          ...(image.source ? { source: image.source } : {}),
        };
      }),
    );
    return read.filter((attachment): attachment is ComposerAttachment => attachment !== undefined);
  }
  /// The image `id` a prompt of the open chat sent, as a data URL; undefined when acpmux has none.
  /// An id names the image's bytes, so one read serves every bubble that shows it.
  async promptImage(id: string): Promise<string | undefined> {
    const shown = this.promptImageUrls.get(id);
    if (shown) return shown;
    const data = await this.promptImageData(id);
    const url = data && `data:${data.mimeType};base64,${data.data}`;
    if (url) this.promptImageUrls.set(id, url);
    return url;
  }
  private readonly promptImageUrls = new Map<string, string>();
  private async promptImageData(id: string): Promise<{ mimeType: string; data: string } | undefined> {
    const sessionId = this.selectedSession;
    if (!sessionId) return undefined;
    try {
      const reply = await this.request("_acpmux/attachment", { sessionId, id });
      return typeof reply?.data === "string"
        ? {
            mimeType: typeof reply.mimeType === "string" ? reply.mimeType : "image/png",
            data: reply.data,
          }
        : undefined;
    } catch {
      return undefined;
    }
  }
  async continueIn(harness: string): Promise<string | undefined> {
    if (!this.handoffSupported || this.turnOpen || this.summary?.status === "running" || this.queue.length > 0) return;
    const generation = this.selectionGeneration;
    const record = await this.handoff.prepare(harness);
    if (!record || generation !== this.selectionGeneration) return;
    return this.select(record.target.sessionId);
  }
  saveHandoff(review: HandoffReviewInput) {
    return this.handoff.save(review);
  }
  startHandoff(review: HandoffReviewInput) {
    return this.handoff.start(review);
  }
  async discardHandoff(): Promise<string | undefined> {
    const generation = this.selectionGeneration;
    const record = await this.handoff.discard();
    if (!record || generation !== this.selectionGeneration) return;
    return this.select(record.source.sessionId);
  }
  refreshHandoff() {
    return this.handoff.refresh();
  }
  async cancel(): Promise<void> {
    const sessionId = this.actingSessionId;
    if (!sessionId) return;
    const socket = this.socket;
    if (this.closed || socket?.readyState !== WebSocket.OPEN)
      throw Object.assign(new Error(translate("error.notOpen")), {
        code: "native.not_connected",
        origin: "native",
      });
    // Deduplicate Stop only against the loaded chat; the visible chat may be held during a switch.
    if (sessionId === this.selectedSessionId && this.stopAffectsRunningTurn()) return;
    // session/cancel is a notification: completing this send does not mean the turn ended.
    const text = JSON.stringify({
      jsonrpc: "2.0",
      method: "session/cancel",
      params: { sessionId },
    });
    this.wire.sent(text, "session/cancel");
    socket.send(text);
    // During a switch's hold Stop targets the chat still drawn, never the hidden chat loading.
    // Only record it after a successful send, and only against that chat's loaded state.
    if (sessionId === this.selectedSessionId) {
      this.interrupting = undefined;
      this.stopAfterSeq = this.lastSeq;
      this.stopSuperseded = false;
      this.stopOpenerSeen = false;
      this.stoppingAfterSeq = this.lastSeq;
      this.stoppedTurnOpener = this.turnOpen ? undefined : "pending";
      let opener: EventRecord | undefined;
      if (this.turnOpen) {
        for (let index = this.events.length - 1; index >= 0; index--) {
          const event = this.events[index]!;
          if (event.kind === "turn_started" || event.kind === "user_message") {
            opener = event;
            break;
          }
        }
      }
      const turnId = opener?.msg?.turnId ?? this.summary?.turn?.turnId;
      this.stopTurnId = this.runningTurnId ?? (typeof turnId === "string" && turnId ? turnId : undefined);
      this.stoppedTurnId = this.stopTurnId;
      this.emit();
    }
  }
  /// Withdraws a queued prompt before its turn starts; `removed` is false once it started.
  async removeQueued(promptId: string): Promise<{ removed: boolean }> {
    const sessionId = this.actingSessionId;
    if (!sessionId) return { removed: false };
    return this.request("_acpmux/queue_remove", { sessionId, promptId });
  }
  /// Resumes the shown chat's paused messages with `peer` (acpmux `hub/agent_pairs.rs`): acpmux
  /// delivers what the pair held, and its `agent_pair_resumed` record ends the pause.
  resumeAgentPair(peer: string): Promise<{ resumed?: number; delivered?: number }> {
    const sessionId = this.actingSessionId;
    if (!sessionId) return Promise.reject(new Error(translate("error.notOpen")));
    return this.request("_acpmux/agent_pair_resume", { sessionId, peerSessionId: peer });
  }
  /// Take over (`held`) or Hand back the shown chat its manager runs (acpmux `hub/agent_hold.rs`):
  /// while held, acpmux holds the manager's messages to it; Hand back delivers them in order.
  agentHold(held: boolean): Promise<{ held?: boolean; delivered?: number }> {
    const sessionId = this.actingSessionId;
    if (!sessionId) return Promise.reject(new Error(translate("error.notOpen")));
    return this.request("_acpmux/agent_hold", { sessionId, held });
  }
  /// Archive has acpmux tag the selected chat `archived` (the lists hide it; acpmux values it with
  /// when); Unarchive removes the tag. The page sends it on its own connection (cx-jlzsf).
  /// Resolves to the chat it acted on (the shown one during a snapshot hold), which its caller's
  /// completion is bound to.
  async archive(archived: boolean): Promise<string> {
    const sessionId = this.actingSessionId;
    if (!sessionId) throw new Error(translate("error.notOpen"));
    await this.request("_acpmux/archive", { sessionId, archived });
    return sessionId;
  }
  /// Permanently removes the shown session from acpmux history. The caller closes the tab only
  /// after this authenticated, session-scoped purge succeeds.
  async purge(sessionId: string): Promise<void> {
    // The confirmation belongs to its original chat, even between a hold's release and React's
    // next commit. Never resolve this destructive target from the client's mutable selection.
    if (!sessionId || sessionId !== this.selectedSessionId || sessionId !== this.actingSessionId)
      throw new Error(translate("error.notOpen"));
    this.purgingSessionId = sessionId;
    try {
      await this.request("_acpmux/kill", { sessionId, purge: true });
      if (this.selectedSessionId === sessionId) this.purgedSessionId = sessionId;
    } finally {
      if (this.purgingSessionId === sessionId) this.purgingSessionId = undefined;
    }
  }
  /// Mark as Unread (cx-ncc.78): acpmux keeps the selected chat unread until it is hidden and
  /// shown again.
  async markUnread(): Promise<void> {
    const sessionId = this.actingSessionId;
    if (!sessionId) throw new Error(translate("error.notOpen"));
    await this.typed("_acpmux/markUnread", { sessionId });
  }
  /// New side chat: acpmux tags the fork `sessionId` as a side chat of `chat` (the `side` tag),
  /// which keeps it off the lists (cx-jlzsf).
  async markSide(sessionId: string, chat: string): Promise<void> {
    await this.request("_acpmux/side", { sessionId, chat });
  }
  /// Use tools (cx-thur3): turns the shown chat's tool `id` on or off for this chat. acpmux keeps
  /// the choice and says when it applies; its reply's tools replace the chat's (its
  /// session_changed says so too, later).
  async setTool(id: string, enabled: boolean): Promise<ToolApplied> {
    // The chat on screen: during a switch's hold the menu clicked is still the chat before's.
    const sessionId = this.actingSessionId;
    if (!sessionId) throw new Error(translate("error.notOpen"));
    const generation = this.selectionGeneration;
    const result = await this.request("_acpmux/set_tools", { sessionId, id, enabled });
    // `summary` is the selected chat's: after a switch (even back to this chat) the reply is stale.
    if (
      generation === this.selectionGeneration &&
      this.selectedSessionId === sessionId &&
      this.summary &&
      Array.isArray(result?.tools)
    ) {
      this.summary = { ...this.summary, tools: result.tools, toolsMutable: result.toolsMutable };
      this.emit("session changed");
    }
    return toolApplied(result?.applied);
  }
  /// The shown chat's offer `offerId` (cx-807da), while its card is drawn.
  offer(offerId: string): AcpmuxSessionOffer | undefined {
    const row = this.rows.get(this.offerRows.get(offerId) ?? "");
    return row?.offers?.find((offer) => offer.offerId === offerId);
  }
  /// A `queued` record of a task's result (acpmux queues it when the chat is busy and its agent
  /// does not steer): one received line in the thread, never a queued prompt. False for others.
  private queuedResult(msg: any, at: number): boolean {
    const received = offersShown() ? offerResult(msg) : undefined;
    if (!received) return false;
    const id = `received-${received.offerId}`;
    if (!this.receivedOffers.has(received.offerId) && !this.rows.has(id))
      this.rows.set(id, {
        id,
        version: 1,
        at,
        kind: OFFER_RESULT,
        text: String(msg.text ?? ""),
        received,
      });
    return true;
  }
  /// The queue the composer shows: a task's result waiting there draws as its received line instead.
  /// One array per queue, so a snapshot that leaves the queue as it was gives the same queue (the
  /// transcript reads another agent's waiting messages from it: conversation/queuedMessages.ts).
  private shownQueue(): { id: string; prompt: string }[] {
    if (!offersShown()) return this.queue;
    if (this.shownQueueOf?.queue === this.queue) return this.shownQueueOf.shown;
    const shown = this.queue.filter((entry) => !entry.id.startsWith(OFFER_RESULT_PROMPT));
    const kept = shown.length === this.queue.length ? this.queue : shown;
    this.shownQueueOf = { queue: this.queue, shown: kept };
    return kept;
  }
  private shownQueueOf?: { queue: QueuedPrompt[]; shown: { id: string; prompt: string }[] };
  /// Suggested tasks turned on or off (`sessions.promptSuggestions` or the Debug tunable): offers draw or go at once.
  suggestedTasksChanged(): void {
    if (!this.selectedSessionId || this.events.length === 0) return;
    this.rebuildKeepingLiveState();
    this.emit();
  }
  /// Do it here on an offer (cx-lo9yf): acpmux records it answered `here`; the caller then sends
  /// the offer's prompt to this chat as the person's own.
  async offerHere(sessionId: string, offerId: string): Promise<void> {
    await this.request("_acpmux/offer_respond", { sessionId, offerId, outcome: "here" });
  }
  /// Dismiss on an offer's chip: acpmux records the answer, and its record closes the chip.
  async dismissOffer(sessionId: string, offerId: string): Promise<void> {
    await this.request("_acpmux/offer_respond", { sessionId, offerId, outcome: "dismissed" });
  }
  /// Start on an offer's chip: starts the offered chat in `cwd` on the offer's agent and model
  /// without showing it, answers the offer with it (acpmux makes `sessionId` its parent), then
  /// sends it the offer's prompt. A refused answer ends the new chat. Returns the new chat.
  async startOffer(sessionId: string, offer: AcpmuxSessionOffer, cwd: string): Promise<string> {
    const params = newSessionParams({ cwd }, offer.harness);
    if (offer.model) params.model = offer.model;
    // A trust question routes as any new chat's does; Trust starts the offer again.
    const again = () => void this.startOffer(sessionId, offer, cwd).catch(() => undefined);
    const child = (await this.newSession(params, again))?.sessionId;
    if (!child) throw new Error(translate("offer.failed"));
    try {
      await this.request("_acpmux/offer_respond", {
        sessionId,
        offerId: offer.offerId,
        outcome: "accepted",
        childSessionId: String(child),
      });
    } catch (error) {
      this.discard(String(child));
      throw error;
    }
    void this.promptUnseen(String(child), offer.prompt);
    return String(child);
  }
  /// Sends `text` to chat `sessionId`, which this pane does not show. acpmux attaches a prompt's
  /// sender to its chat, as a viewer, which would mark its turn seen: attached hidden first (for
  /// the tool calls its started row shows), the prompt adds nothing, and the attach ends with the
  /// turn (unless the pane shows it by then).
  private async promptUnseen(sessionId: string, text: string): Promise<void> {
    await this.offerChildren
      .prompting(sessionId, () =>
        // The reply comes when the turn ends; the chat shows how it goes.
        this.request("session/prompt", {
          sessionId,
          prompt: promptBlocks(text, []),
          _meta: { acpmux: { promptId: crypto.randomUUID() } },
        }),
      )
      // A prompt acpmux refused shows in the chat itself.
      .catch(() => undefined);
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
  /// A thread of the chat's inbox (acpmux `_acpmux/inbox_thread`), oldest first, for an inbox
  /// notice's line the person opened (conversation/InboxNoticeCard.tsx). It marks nothing read: the
  /// person reading it is not the agent.
  async inboxThread(threadId: string): Promise<InboxMessage[]> {
    const sessionId = this.selectedSessionId;
    if (!sessionId || !threadId) throw new Error(translate("error.notOpen"));
    const reply = (await this.request("_acpmux/inbox_thread", { sessionId, threadId }, 15_000)) as {
      messages?: unknown;
    } | null;
    const messages = Array.isArray(reply?.messages) ? reply.messages : [];
    return messages
      .flatMap((m): InboxMessage[] => {
        const r = m as Record<string, unknown> | null;
        if (!r || typeof r.text !== "string") return [];
        return [
          {
            from: typeof r.from === "string" ? r.from : "",
            text: r.text,
            ...(typeof r.promptId === "string" && { promptId: r.promptId }),
            ...(typeof r.at === "number" && { at: r.at }),
          },
        ];
      })
      .reverse();
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
  async select(sessionId: string): Promise<string | undefined> {
    const previousSessionId = this.selectedSessionId;
    // The chat being left is kept for its own next open, while it is still the selected one.
    this.rememberCurrentTail();
    const generation = ++this.selectionGeneration;
    if (this.purgedSessionId !== sessionId) this.purgedSessionId = undefined;
    // What the pane shows (the chat before, a new chat's hero) stays drawn until this chat's attach page is in.
    const hold = this.holdSnapshots(SWITCH_HOLD_MS);
    this.selectedSessionId = sessionId;
    this.missingSession = undefined;
    this.missingReason = undefined;
    // A hidden pane does not see the chat it opens (the tab's missing chat came back while its
    // workspace was in the background): it stays unread until the page shows (`showChanged`).
    if (pageShown()) this.markSeen(sessionId);
    this.resetSessionState();
    // A chat this page read already draws from what that visit left, on the frame the switch lands;
    // its attach lays what acpmux holds now over that (Leo: "instant if cached").
    let keptThrough = this.drawKeptTail(sessionId);
    if (keptThrough === 0) {
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
    if (keptThrough > 0) {
      this.drewKeptTail = true;
      this.emit("selected");
      this.releaseSnapshots(hold);
    }
    let mine = this.copyAttaches;
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
      if (keptThrough > 0 && generation === this.selectionGeneration && this.selectedSessionId === sessionId) {
        forgetTail(sessionId);
        this.peerCopy = undefined;
        this.copyLive = undefined;
        this.events = [];
        this.queue = [];
        this.drewKeptTail = false;
        this.rebuild();
        this.emit(this.socket?.readyState === WebSocket.OPEN ? "failed" : "disconnected");
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
  private async newSession(params: Record<string, unknown>, again?: () => void, declined?: () => void): Promise<any> {
    const generation = this.selectionGeneration;
    const trustCancellation = this.trustCancellation;
    try {
      const result = await this.request("session/new", params);
      // A canceled start owns neither the next Trust question nor one-shot startup defaults.
      if (generation !== this.selectionGeneration || trustCancellation !== this.trustCancellation) return undefined;
      return result;
    } catch (error) {
      if (generation === this.selectionGeneration && trustCancellation === this.trustCancellation)
        this.routeTrustRefusal(error, again, declined);

      throw error;
    }
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
      if (this.closed || generation !== this.selectionGeneration) return undefined;
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
    const result = await this.newSession(
      newSessionParams(newSessionHost(this.host, cwd, peer, noProject), harness, noProject, model),
      again,
      declined,
    );
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
  /// its harness reuses it), its harness, and its folder when it runs on this machine (the new
  /// chat starts there; a cloud or peer session's folder is not one acpmux can start in here).
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
      empty: this.rows.size === 0 && this.queue.length === 0 && turns === 0 && !this.turnOpen,
      ...(local && typeof summary?.cwd === "string" && summary.cwd ? { cwd: summary.cwd } : {}),
      ...(Array.isArray(summary?.configOptions) ? { configOptions: summary.configOptions } : {}),
    };
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
    return this.turnOpen || this.summary?.status === "running";
  }
  /// Stops showing the selected session: a harness switch draws its new chat meanwhile. The
  /// session keeps running in acpmux; only this client's attach ends.
  leave(): void {
    const previous = this.selectedSessionId;
    if (!previous) return;
    if (this.purgingSessionId === previous) this.purgingSessionId = undefined;
    if (this.purgedSessionId === previous) this.purgedSessionId = undefined;
    this.selectedSessionId = undefined;
    this.selectionGeneration += 1;
    this.resetSessionState();
    this.emit();
    void this.typed("_acpmux/detach", { sessionId: previous }).catch(() => undefined);
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
  /// Reads out now, by chat, so a switch to one can wait on it briefly.
  private readingAhead = new Map<string, Promise<void>>();
  /// Chats waiting for a read, the next one first.
  private readAheadQueue: string[] = [];
  private readAheadTimer?: ReturnType<typeof setTimeout>;

  /// Reads the list's most recent chats ahead once the pane is idle for `delayMs`.
  private scheduleReadAhead(delayMs: number): void {
    if (this.closed || this.readAheadTimer !== undefined) return;
    this.readAheadTimer = setTimeout(() => {
      this.readAheadTimer = undefined;
      const recent = [...this.sessions]
        .filter((session) => session.sessionId && session.sessionId !== this.selectedSessionId)
        .sort((a, b) => Number(b.updatedAt ?? 0) - Number(a.updatedAt ?? 0))
        .slice(0, READ_AHEAD_RECENT)
        .map((session) => session.sessionId);
      this.queueReadAhead(recent, false);
    }, delayMs);
  }

  private queueReadAhead(sessionIds: string[], first: boolean): void {
    const now = Date.now();
    const wanted = sessionIds.filter((sessionId) => {
      if (!sessionId || sessionId === this.selectedSessionId || this.readingAhead.has(sessionId)) return false;
      const readAt = this.readAheadAt.get(sessionId);
      // A chat this page opened keeps the tail it read itself; one read ahead is read again only
      // when it ran on since, and not more often than READ_AHEAD_REFRESH_MS.
      if (readAt === undefined) return !keptTail(sessionId);
      if (now - readAt < READ_AHEAD_REFRESH_MS) return false;
      const listed = this.sessions.find((session) => session.sessionId === sessionId);
      return Number(listed?.updatedAt ?? 0) > readAt || !keptTail(sessionId);
    });
    const rest = this.readAheadQueue.filter((sessionId) => !wanted.includes(sessionId));
    this.readAheadQueue = first ? [...wanted, ...rest] : [...rest, ...wanted];
    this.pumpReadAhead();
  }

  private pumpReadAhead(): void {
    while (!this.closed && this.readingAhead.size < READ_AHEAD_LANES && this.readAheadQueue.length > 0) {
      const sessionId = this.readAheadQueue.shift()!;
      if (sessionId === this.selectedSessionId) continue;
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
  /// tail. What it cannot know without an attach (what is pending, the turn's opener when it is
  /// older than the page) the attach that follows a switch adds, as it does for any kept tail.
  private async readAhead(sessionId: string): Promise<void> {
    if (this.socket?.readyState !== WebSocket.OPEN) return;
    this.readAheadAt.set(sessionId, Date.now());
    // The session and machine its row names when asked: a page read while the row changed is of
    // the session before, so it is not kept under the new one's row.
    const asked = this.sessions.find((session) => session.sessionId === sessionId);
    const result = await this.typed("_acpmux/events", {
      sessionId,
      beforeSeq: Number.MAX_SAFE_INTEGER,
      limit: KEPT_EVENTS,
      maxBytes: OPEN_PAGE_BYTES,
      kinds: ["transcript", COMMANDS_KIND, USAGE_KIND, CONFIG_KIND, BOOKMARKS_KIND, ...SECRET_KINDS],
    });
    // The chat was opened meanwhile: its attach holds the newer read.
    if (this.closed || sessionId === this.selectedSessionId) return;
    const page = records(result?.events);
    if (page.length === 0) return;
    const oldest = Math.min(...page.map((event) => event.seq));
    const listed = this.sessions.find((session) => session.sessionId === sessionId);
    if (listed?.peer !== asked?.peer || listed?.createdAt !== asked?.createdAt) return;
    rememberReadAhead(sessionId, {
      events: page,
      summary: listed ? { ...listed } : undefined,
      turnOpener: undefined,
      historyExhausted: result?.hasMore === false,
      queue: [],
      configSeq: 0,
      usageFromSeq: result?.hasMore === true ? oldest : 0,
    });
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
    return this.host.peer;
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
  /// The shown chat `sessionId` has prompt `promptId`: its record or its queue row.
  showsPrompt(sessionId: string, promptId: string): boolean {
    if (this.selectedSessionId !== sessionId) return false;
    return (
      this.queue.some((entry) => entry.id === promptId) ||
      this.events.some(
        (event) => (event.kind === "user_message" || event.kind === "queued") && event.msg?.promptId === promptId,
      )
    );
  }
  /// The `awaitResent` waits, with their chat: each settles false once this connection closes or
  /// the pane shows another chat.
  private resendWaits = new Map<() => void, string>();
  /// A prompt an earlier connection lost before acpmux took it (`lostPrompt.ts`), which the host
  /// sends again on this one: true once this chat shows it (its record, its queue row, or acpmux's
  /// acceptance), false when it does not within `timeoutMs`, this pane shows (or moves to) another
  /// chat, or this connection closes.
  awaitResent(sessionId: string, promptId: string, timeoutMs: number): Promise<boolean> {
    if (this.closed || this.selectedSessionId !== sessionId) return Promise.resolve(false);
    const shown = () => this.showsPrompt(sessionId, promptId);
    if (shown()) return Promise.resolve(true);
    return new Promise((resolve) => {
      const done = (landed: boolean) => {
        clearTimeout(timer);
        if (this.promptAccepts.get(promptId) === accept) this.promptAccepts.delete(promptId);
        this.resendWaits.delete(gone);
        resolve(landed);
      };
      const accept = () => done(true);
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
      this.notice(errorMessage(error) || String(error));
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
  /// A line in the shown transcript (a pick the agent refused); its row id, for `dismissNotice`.
  notice(text: string, id = noticeId("notice")): string {
    const at = Date.now();
    this.rows.set(id, { id, version: 1, at, kind: "notice", text });
    this.emit();
    return id;
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
  /// stays there. `stay` keeps this chat open and only answers the fork, for its own tab.
  /// `"live"`: the whole chat as it is now, also while its turn runs (Fork Conversation).
  async fork(throughSeq: number | "live", from?: string, stay = false): Promise<string | undefined> {
    if (!this.canFork || !this.actingSessionId || this.forking) return undefined;
    this.forking = true;
    const generation = this.selectionGeneration;
    // Fork Conversation (`stay`): the chat says "Forking…" until acpmux answers and the app opens
    // the fork, so a slow fork never looks like nothing happened.
    const pendingId = stay ? noticeId("notice-forking") : undefined;
    if (pendingId) {
      this.rows.set(pendingId, {
        id: pendingId,
        version: 1,
        at: Date.now(),
        kind: "notice",
        text: translate("notice.forking"),
      });
      this.emit();
    }
    try {
      const sessionId = from ?? this.actingSessionId;
      const result = await this.request(
        FORK_OP,
        throughSeq === "live" ? { sessionId, live: true } : { sessionId, throughSeq },
      );
      if (!result?.sessionId || generation !== this.selectionGeneration) return undefined;
      if (stay) return String(result.sessionId);
      return await this.select(String(result.sessionId));
    } catch (error) {
      if (generation === this.selectionGeneration) {
        const at = Date.now();
        const reason = errorMessage(error) || undefined;
        const id = noticeId("notice-fork");
        this.rows.set(id, {
          id,
          version: 1,
          at,
          kind: "notice",
          text: reason ? translate("notice.forkFailedReason", { reason }) : translate("notice.forkFailed"),
        });
        this.emit("fork failed");
      }
      return undefined;
    } finally {
      this.forking = false;
      if (pendingId && this.rows.has(pendingId)) {
        this.rows.delete(pendingId);
        this.emit();
      }
    }
  }
  /// Forks the open session through `throughSeq` and stays on it: New side chat's copy, which the
  /// host opens beside this chat. One fork at a time, as `fork`.
  async forkAside(throughSeq: number): Promise<string | undefined> {
    if (!this.canFork || !this.selectedSessionId || this.forking) return undefined;
    this.forking = true;
    try {
      const result = await this.request(FORK_OP, { sessionId: this.selectedSessionId, throughSeq });
      return result?.sessionId ? String(result.sessionId) : undefined;
    } finally {
      this.forking = false;
    }
  }
  /// `/btw <question>`: acpmux starts a read-only side session about the open chat, on a fast model,
  /// asks it `question` and answers with its id at once (`_acpmux/btw`). The chat is not touched,
  /// so this works while its turn runs. Rejects with acpmux's message when it refuses.
  /// `sessionId`: Needs you's Ask about this names the asking chat (acpmux hub/btw.rs); the relay
  /// sends it only for a chat in the pane's scope (AcpmuxPaneMethods.sessionScoped) and on a click
  /// (its gesture rule), and its reply's session joins the scope, so the host may open it beside
  /// the chat (`chat.sideChat`).
  async btw(question: string, sessionId = this.actingSessionId): Promise<string> {
    if (!sessionId) throw new Error(translate("error.notOpen"));
    const result = await this.request(SIDE_SESSION_METHOD, { sessionId, question });
    // No id: the caller says the side session did not start, without a reason it does not have.
    if (typeof result?.sessionId !== "string" || !result.sessionId) throw new Error("");
    return result.sessionId;
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
    const [names, probed] = await Promise.all([
      cwd
        ? this.request("_acpmux/harnesses", { cwd }).catch(() => this.request("_acpmux/harnesses", {}))
        : this.request("_acpmux/harnesses", {}),
      this.request("_acpmux/models", {}).catch(() => undefined),
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
    this.peerResources = peerResourcesFromStatus(status);
    this.peerStatus = peerStatusFromStatus(status);
    if (this.peerEvents.observed) this.applyPeerStates();
  }
  /// Probes every agent's live model list again (`_acpmux/models {refresh: true}`): acpmux forgets
  /// the lists it has and asks each harness before it answers (the picker's Refresh models).
  refreshModels(): Promise<unknown> {
    return this.request("_acpmux/models", { refresh: true });
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
  private promptIndex?: { sessionId: string; generation: number; rows?: AcpmuxRow[]; failed?: boolean };
  /// `shownEarlierPrompts`' last answer, by what it was read from.
  private earlierShown?: { rows: AcpmuxRow[]; before: number; list: readonly AcpmuxRow[] };

  /// The indexed prompts older than every held row (the snapshot's `earlierPrompts`). The first ask
  /// for a chat with older history starts the index's one read.
  private shownEarlierPrompts(): readonly AcpmuxRow[] {
    const sessionId = this.selectedSessionId;
    if (!sessionId || !this.seqHistoryLeft() || !this.firstSeq) return NO_EARLIER_PROMPTS;
    const index = this.promptIndex;
    if (!index || index.sessionId !== sessionId || index.generation !== this.selectionGeneration) {
      this.readPromptIndex(sessionId, this.firstSeq);
      return NO_EARLIER_PROMPTS;
    }
    if (!index.rows) return NO_EARLIER_PROMPTS;
    // The turn opener drawn above the held page is held: only prompts before it are earlier.
    const before = Math.min(this.firstSeq, this.turnOpener?.seq ?? Infinity);
    const kept = this.earlierShown;
    if (kept && kept.rows === index.rows && kept.before === before) return kept.list;
    let end = index.rows.length;
    while (end > 0 && Number(index.rows[end - 1]!.id.slice(5)) >= before) end -= 1;
    const list = end === index.rows.length ? index.rows : index.rows.slice(0, end);
    this.earlierShown = { rows: index.rows, before, list };
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
    if (index?.rows && !index.failed && index.sessionId === sessionId && index.generation === this.selectionGeneration)
      return undefined;
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const count = Number(summary?.turnCount ?? 0);
    return count > 0 ? count : undefined;
  }

  private readPromptIndex(sessionId: string, before: number): void {
    const generation = this.selectionGeneration;
    const entry: { sessionId: string; generation: number; rows?: AcpmuxRow[]; failed?: boolean } = {
      sessionId,
      generation,
    };
    this.promptIndex = entry;
    void this.typed("_acpmux/events", {
      sessionId,
      beforeSeq: before,
      promptIndex: true,
      kinds: ["user_message"],
      limit: 5000,
      maxBytes: OLDER_PAGE_BYTES,
    })
      .then((result: any) => {
        if (this.closed || this.promptIndex !== entry) return;
        entry.rows = records(result?.events)
          .filter(startsTurn)
          .map((event): AcpmuxRow => {
            const promptId = typeof event.msg?.promptId === "string" ? event.msg.promptId : undefined;
            return {
              id: `user-${event.seq}`,
              version: 1,
              at: event.at,
              kind: "user",
              text: String(event.msg?.text ?? "").slice(0, 240),
              ...(promptId ? { promptId } : {}),
            };
          });
        this.emit();
      })
      .catch(() => {
        // Without the index the rail keeps the summary's count (promptCountAwaited) while pages load.
        if (this.promptIndex !== entry) return;
        entry.rows = [];
        entry.failed = true;
      });
  }

  /// Pages history in until the record at `seq` is held: a click on the rail's tick of a prompt
  /// older than the held rows (`earlierPrompts`). Each step is `loadOlder`, with its guards; a step
  /// that moves nothing, or another chat, ends it.
  /// Resolves true once the prompt is held, false when the read stopped short of it.
  async loadThrough(seq: number): Promise<boolean> {
    const generation = this.selectionGeneration;
    const held = () => generation === this.selectionGeneration && this.firstSeq !== undefined && this.firstSeq <= seq;
    for (let pages = 0; pages < 200; pages++) {
      const from = this.firstSeq;
      if (held()) return true;
      if (generation !== this.selectionGeneration || from === undefined || !this.seqHistoryLeft()) return false;
      await this.loadOlder();
      if (this.firstSeq === from) return held();
    }
    return held();
  }

  /// Pages older transcript events in without reattaching, so the live summary,
  /// queue and permission stay as they are. A page that lands after the
  /// selection changed belongs to another session and is dropped.
  loadOlder(): Promise<void> {
    if (!this.canPageOlder()) return Promise.resolve();
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
                ? this.fetchOlder(pagingEpoch)
                : undefined,
            )
        : this.fetchOlder(pagingEpoch);
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
  private canPageOlder(epoch = this.olderPagingEpoch): boolean {
    return !this.closed && epoch === this.olderPagingEpoch && this.socket?.readyState === WebSocket.OPEN;
  }
  private cancelOlderPaging(): void {
    this.olderPagingEpoch += 1;
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

  private async fetchOlder(pagingEpoch = this.olderPagingEpoch): Promise<void> {
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
    // Newest page first; joined once at the end, so a long read copies its records once.
    const read: EventRecord[][] = [];
    let more = true;
    let found = false;
    // A page can draw nothing above the first row: a prompt queued with a big paste or image is a
    // page of its own, a page that ends in the opener already drawn adds no turn, and every page of
    // a long turn the open landed in is that turn's. Read on until a turn older than the first row
    // starts, at most OLDER_PAGES_PER_ASK pages; a capped read still moves `historyFrom`, which
    // makes the transcript ask again.
    for (
      let before = this.firstSeq, pages = 0;
      more && pages < OLDER_PAGES_PER_ASK && (pages < OLDER_MIN_PAGES_PER_ASK || !found);
      pages++
    ) {
      if (!this.canPageOlder(pagingEpoch)) return;
      const result = await this.typed("_acpmux/events", {
        sessionId,
        beforeSeq: before,
        limit: 400,
        maxBytes: OLDER_PAGE_BYTES,
        kinds: ["transcript"],
      });
      if (
        !this.canPageOlder(pagingEpoch) ||
        generation !== this.selectionGeneration ||
        this.selectedSessionId !== sessionId
      )
        return;
      // The held transcript's older end moved while this read was out (a kept tail the attach
      // page did not continue): these records sit above a transcript the chat no longer holds. The
      // ask brings nothing, and the transcript asks again (App.tsx checkOlder).
      if (epoch !== this.historyEpoch) return;
      const page = records(result?.events);
      read.push(page);
      found ||= page.some(opensOlderTurn);
      more = result?.hasMore === true && page.length > 0 && page[0]!.seq < before;
      if (page.length > 0) before = Math.min(before, page[0]!.seq);
    }
    let older = read.reverse().flat();
    // Records before the oldest turn start finish a turn further back: the next read takes them, so
    // what lands holds whole turns.
    const start = more ? older.findIndex(opensOlderTurn) : 0;
    if (start > 0) older = older.slice(start);
    const foldsAbove = start >= 0 && (this.events.length === 0 || startsTurn(this.events[0]!));
    this.events = mergeEventRecords(older, this.events);
    this.sawPrompts(older);
    // A page exposing a forced result can establish a fence at a prompt already drawn below it.
    // Replay that boundary chronologically; merging rows cannot recover the held prompt's effect.
    const crossesStop = older.some(
      (event) =>
        event.dir === "mux" &&
        event.kind === "turn_result" &&
        event.msg?.cancelForced === true &&
        typeof event.msg?.turnId === "string",
    );
    // Ordinary whole-turn pages retain the incremental fold. Fenced pages also replay so a
    // live fence never leaks backward into history that predates the cancellation.
    if (
      foldsAbove &&
      !crossesStop &&
      this.compactionFenceSeq === undefined &&
      this.retiredCompactionTurnId === undefined
    )
      this.foldOlder(older);
    else this.rebuildKeepingLiveState();
    this.historyExhausted = !more || older.length === 0 || (this.firstSeq ?? 1) <= 1;
    this.emit("history");
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
      // The running turn's prompt is the held events', never an older page's.
      turnPrompt: this.turnPrompt,
      silentTurn: this.silentTurn,
      turnTokens: this.turnTokens,
      turnTokenSplit: this.turnTokenSplit,
      streamingAssistant: this.streamingAssistant,
      streamingAssistantMessageId: this.streamingAssistantMessageId,
      assistantCut: this.assistantCut,
      streamingActivity: this.streamingActivity,
      planRow: this.planRow,
      messageRows: this.messageRows,
      toolRows: this.toolRows,
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
    this.turnPrompt = undefined;
    this.silentTurn = false;
    this.turnTokens = undefined;
    this.turnTokenSplit = undefined;
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
    this.assistantCut = false;
    this.streamingActivity = undefined;
    this.planRow = undefined;
    this.messageRows = new Map();
    this.toolRows = new Map();
    this.planCalls = new Set();
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
    try {
      for (const event of [...older].sort((a, b) => a.seq - b.seq)) {
        this.firstSeq = Math.min(this.firstSeq ?? event.seq, event.seq);
        this.reduce(event);
      }
    } finally {
      this.foldingBelow = undefined;
    }
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
      [...this.rows.values()].filter(
        (row) =>
          row.kind === "compaction" &&
          !held.has(row.id) &&
          (row.compaction?.state === "running" || row.compaction?.inferred === true),
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
      if (row.backgroundTask && this.markBackgroundCall(row.backgroundTask, row.at)) {
        held.delete(row.id);
        this.rows.delete(row.id);
      }
    // A fork older than every held event is only in this page.
    const forkedAtSeq = live.forkedAtSeq ?? this.forkedAtSeq;
    // The folded page's rows answer for their own messages: a `?message=<id>` link to a message
    // from before this page keeps finding its row (links.ts). The held events' entries win, since
    // they are the live turn's.
    const messageRows = new Map([...this.messageRows, ...live.messageRows]);
    Object.assign(this, live, { forkedAtSeq, messageRows });
    // Older turns end on their own result; a row of the live turn it closed (its typing row) stays.
    for (const [id, row] of held) if (!this.rows.has(id)) this.rows.set(id, row);
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
    this.presence.detached();
    // Before anything is torn down: the chat on screen is still readable here, and a tab closing on
    // it should leave it warm for the next one. The host alone keeps it: this client is going away,
    // and a tail left in this page's map would be drawn by whatever client comes after it.
    this.rememberCurrentTail(false);
    this.replayMode = false;
    this.fedMode = false;
    this.closed = true;

    clearTimeout(this.hiddenDraw);
    this.frameRequest?.cancel?.();
    this.frameRequest = undefined;
    this.cancelTrustStart?.();

    for (const gone of this.resendWaits.keys()) gone();
    this.cancelOlderPaging();
    const hold = this.snapshotHold;
    if (hold) clearTimeout(hold.timer);
    this.snapshotHold = undefined;
    hold?.release();
    this.sessionPages.stop();
    clearTimeout(this.readAheadTimer);
    this.readAheadTimer = undefined;
    this.readAheadQueue = [];
    this.hoverReads.stop();
    this.shareOnRead.clear();
    clearTimeout(this.sessionReread);
    this.sessionReread = undefined;
    clearTimeout(this.missingRecheck);
    this.missingRecheck = undefined;
    this.stopAfterSeq = undefined;
    this.stopSuperseded = false;
    this.stopOpenerSeen = false;
    this.stoppingEnded();
    this.stopPageListeners();
    if (this.reconnectTimer !== undefined) window.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    this.permissions.disconnected();
    this.socket?.close();
    this.socket = undefined;
    this.rejectPending();
  }
  private stopPageListeners(): void {
    if (typeof document !== "undefined") document.removeEventListener("visibilitychange", this.showChanged);
    if (typeof window !== "undefined") window.removeEventListener("pagehide", this.pageWentAway);
  }
  private rejectPending(): void {
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
  }
}

/// The params field that carries a pick's gesture ticket, or nothing without one.
/// Reserves the person's current gesture for one prompt. A page or script without a trusted
/// AppKit event gets no ticket; the host's normal gesture check then refuses its send.
const reservePromptGesture = (promptId: string): Promise<string | undefined> => {
  try {
    return postNative<{ ticket?: string }>("transport.gesture", {
      intent: { method: "session/prompt", params: { promptId } },
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

function backgroundTask(update: any): BackgroundUpdate | undefined {
  const state = update.state;
  if (typeof update.toolCallId !== "string" || !["running", "completed", "failed", "stopped"].includes(state))
    return undefined;
  return {
    toolCallId: update.toolCallId,
    command: typeof update.command === "string" ? update.command : "",
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

function pageShown(): boolean {
  return typeof document === "undefined" || document.visibilityState !== "hidden";
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

/// Whether the pane's host refused to relay a request (`data.origin: "native"`): acpmux never saw it.
function refusedByHost(error: AcpmuxRpcError): boolean {
  const data = error.data && typeof error.data === "object" ? (error.data as Record<string, unknown>) : undefined;
  return data?.origin === "native";
}
