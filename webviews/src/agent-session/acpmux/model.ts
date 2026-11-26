import type { BrowserWorkspaces } from "./browser/workspaces";
import type { ApprovedPlan } from "./approvedPlan";
import { experimentArm } from "../../experiments/experiment";
import type { PromptHeads } from "./promptHeads";
import { nextStepCardHeight, permissionCardHeight } from "./permissions/cardHeight";
import { freshMeasureContext } from "./measureContext";
import type { SentFrom } from "./conversation/sentFromHarness";
import type { PeerLinkDetail } from "./linkState";
import type { ComposerStatus } from "./composerStatusModel";
import { BUBBLE } from "./transcriptSpacing";
import {
  footerAfter,
  gridLength,
  MARK_FOOTER,
  MARK_FOOTER_ROW,
  MARK_LIVE_STEP,
  MARK_CARD,
  MARK_STATUS,
  MARK_STEP,
  MARK_OPENS_TURN,
  MARK_HEADS_TURN,
  MARK_TOPS_TURN,
  MARK_WORKED,
  rowMark,
  gridScale,
  restBand,
  tailGap,
  TRANSCRIPT_RUN_GAP,
  TRANSCRIPT_FOOTER_CONTROL,
  TRANSCRIPT_INNER_GAP,
  TRANSCRIPT_LINE_ROW,
  transcriptLineRow,
  liveStepHeight,
  transcriptGap,
} from "./transcriptGrid";
import type { MachineResources } from "./machineResources";
import type { AutoResumeStatus } from "./autoResumeStatus";
import type { AutoSession } from "./autoSession/autoSession";
import type { CapacityWaitState } from "./capacityWait";
import type { VideoInfo } from "./composer/videoAttachments";
import type { AttachmentSource } from "./attachments";
import type { HarnessIconSpec } from "../shared/harnessIcons";
import type { ChatUnavailable } from "./chatUnavailable";
import type { ChatPresence, Participant } from "./multiplayer/participants";
import { editedPaths } from "./toolPaths";
import type { PermissionClientState } from "./permissions/protocol";
import type { AgentQuestion } from "./question/model";
import type { NextStepAsk } from "./conversation/nextStepAsk";
import { webSources } from "./conversation/webSourceList";
import { isRunPart } from "./conversation/runPartId";
import { keptPrefix } from "./conversation/prefixFlatMap";
import { outputTail, stripAnsi } from "./conversation/toolOutputModel";
import type { WatchedAsk } from "./needsYou/model";
import type { PermissionDecision } from "./permissions/record";
import type { HandoffClientState } from "./handoff/client";
import type { SessionUsageStats } from "./usageStats";
import type { Enforcement } from "./handoff/protocol";
import type { SlashCommand } from "./slashCommands";
import type { SummaryCheckpoint } from "./changes/turnCheckpointSource";
import type { IncomingMessage, IncomingPrompt } from "./conversation/incomingMessage";
import type { InboxNotice } from "./conversation/inboxNotice";
import { MEMORY_OFFER, memoryCardState, type MemoryOffer } from "./conversation/memoryInbox";
import { COACH_LINE_PX, coachLines, PROMPT_COACH, type PromptCoach } from "./conversation/promptCoach";
import { PRESET_APPROVAL, type PresetApproval } from "./conversation/presetApproval";
import type { TurnCopyPart } from "./conversation/turnCopy";
import type { LiveWait } from "./conversation/liveWait";
import type { GitHubConnectNeed } from "./conversation/githubConnect";
import { appHref, linkHref, safeHref } from "./replyHref";
import type { ShellRun } from "./shell/shellRuns";
import { SUBAGENTS, type Subagent } from "./subagents/subagent";
import { BACKGROUND_TURN } from "./conversation/backgroundTurns";
import { TASK_LINE, type StartedTask } from "./conversation/taskLineKind";
import type { SubagentRetryNotice } from "./subagents/retryState";
import {
  isRunGroup,
  SUBAGENT_DONE,
  SUBAGENT_STARTED,
  SUBAGENT_EMPTY,
  SUBAGENT_ROW,
  WORKFLOW_CARD,
} from "./subagents/subagentRows";
import type { ComposerAttachment } from "./attachments";
import { STARTED_SESSIONS, type StartedSession, hasStatusLine } from "./started/startedSessions";
import { PLAN_BUILD_KIND, planBuildHeight, type PlanBuild } from "./planBuild/planBuild";
import {
  COLLAPSED_PROMPT_LINES,
  PASTE_FROM_HEIGHT,
  PROMPT_MORE_HEIGHT,
  type PasteRange,
  HUGE_PROMPT_HEAD_CHARS,
  collapsedPromptHeight,
  drawnBody,
  hasHugeTypedPart,
  isHugePrompt,
  promptHead,
  recordedBody,
} from "./conversation/promptCollapse";
import { sentPasteJoin } from "./conversation/sentPasteJoin.experiment";
import { attachmentOnlyPrompt, bubbleLayout, stripAttachments } from "./conversation/bubbleParts";
import { composerSettingsSnapshot } from "./composerSettings";
import { isPromptMarkdown } from "./conversation/promptMarkdown";
import { sentUIPick, sentUIPickSegments, type SentPromptSegment } from "./conversation/sentUIPickModel";
import { linkedImagePath, sentImageSize, sentVideoSize } from "./conversation/userBubbleModel";
import { sentVideoOf, sentVideosOf } from "./conversation/sentVideos";
import { fileSizeLabel, shownFileSize } from "./fileAttachmentModel";
import { mcpCall } from "./conversation/mcpCalls";
import { hidesEveryCall, visibleToolItems } from "./conversation/mcpPresentation";
import { subsessionCall } from "./conversation/subsessionCalls";
import { agentMessage } from "./conversation/agentMessages";
import type { ChatTool } from "./summary/chatTools";
import type { TaskGoal } from "./goal";
import { MessagePlacement } from "./conversation/messagePlacement";
import { isVisiblyEmptyMessage } from "./conversation/visibleMessage";
import {
  geometryFromArrays,
  geometryFromIndex,
  geometryOf,
  type IndexedLayoutGeometry,
  type LayoutGeometry,
} from "./conversationGeometry";
import { PASS_MARK, PlacedHeightIndex } from "./placedHeightIndex";

export type { HeightChange, IndexedLayoutGeometry, LayoutGeometry } from "./conversationGeometry";
export { applyHeightChanges, geometryFromHeights, geometryFromIndex } from "./conversationGeometry";

/** How a background shell ended (acpmux `background_task_update`, cx-ncc.84). */
export type AcpmuxBackgroundTask = {
  toolCallId: string;
  command: string;
  /// The helper or subagent that started this shell, when the harness identifies it.
  ownerId?: string;
  ownerTitle?: string;
  /// The call's description, retained for clients that need a compact activity label.
  description?: string;
  startedAt?: number;
  endedAt?: number;
  state: "completed" | "failed" | "stopped";
  reason?: string;
  /// Claude Code's own words on how it ended (its task notification's summary).
  summary?: string;
  /// The exit code, when the harness reports one (Codex does; acpmux reads Claude Code's from its
  /// summary).
  exitCode?: number;
};

/// A shell call's life in the background, on the call that started it (direct.ts
/// `markBackgroundCall`): running there, then how it ended and when (epoch ms). Its "Ran" row draws
/// it (conversation/BackgroundMark.tsx); a separate background task row is only for a shell whose
/// call is not in the transcript.
export type AcpmuxBackgroundState = {
  state: "running" | AcpmuxBackgroundTask["state"];
  reason?: string;
  /// The exit code its end reported (Codex's, and Claude Code's from its summary).
  exitCode?: number;
  endedAt?: number;
};

/// A compaction of the chat's context (acpmux `compaction`): running, then how it ended. `reason`
/// is a wrapper's ("account_switch": subrouter compacted before moving the chat to another account).
export type AcpmuxCompaction = {
  state: "running" | "completed" | "failed";
  /// Failed because its turn ended while it ran, not because it said so; a later end replaces it.
  inferred?: boolean;
  reason?: string;
  /// Why a failed compaction failed, in Claude Code's words ("Prompt is too long").
  error?: string;
  preTokens?: number;
  postTokens?: number;
};

/// acpmux moved the chat onto its fallback harness after a usage limit (a `failover` record).
export type AcpmuxFailover = { from: string; to: string };

/// A session recap (acpmux `recap` record, `hub/away_recap.rs`): where the chat stands, shown when
/// the person comes back after 5+ minutes away. Never a prompt; the daemon decides when.
/// `key`: the chat and the record's seq, which the dismissal remembers (conversation/recapDismissed.ts).
export type AcpmuxRecap = { key: string; text: string; awayMs?: number };

/// "New since you looked" (conversation/SinceDivider.tsx): where the person left the chat, drawn
/// after the record they had seen (acpmux `seenSeq`, `hub/seen.rs`) when turns ended since. The
/// recap made for the same return (`since` on its record) draws on it instead of on its own row.
export const SINCE_DIVIDER = "sinceDivider";
/// `key`: the chat and the seq, which Jump to new follows the line by (seqs repeat across chats).
export type AcpmuxSince = {
  key: string;
  seq: number;
  turns: number;
  recap?: AcpmuxRecap;
  /// A return by hand to a chat that stayed on screen (direct.ts `attentionChanged`), not a chat
  /// picked: a line in view at once sits over rows the reader already had in front of them, and is
  /// read without drawing (conversation/unreadState.ts `noteUnreadSide`).
  inPlace?: true;
};

/// A turn the agent ran on its own, which nobody prompted (acpmux `background_turn` records): a
/// background task or subagent finished (`task_notification`), a scheduled wakeup or /loop tick
/// (`scheduled`), or a hook (`system`). `running` until its ended record; then `quiet` is acpmux's
/// word on whether its reply has nothing new to tell (one short line, no question, no link), and
/// `reason` how it ended (`prompt`: a prompt started a real turn while it ran).
export type AcpmuxBackgroundTurn = {
  id: string;
  trigger: string;
  running: boolean;
  quiet?: boolean;
  reason?: string;
  /// A row of its own draws something, so its line opens to it. A turn whose events only update
  /// rows that are not its own (a call an earlier turn started, a subagent's work) has none.
  hasRows?: true;
  /// What started it, when acpmux knows: the background task that ended and whether that is worth
  /// a response (acpmux hub/background_cause.rs). A log from before acpmux said so has none.
  cause?: AcpmuxBackgroundCause;
  /// Its task's end went onto the call that started the task (`AcpmuxBackgroundReaction`), so the
  /// transcript draws no line for it.
  attached?: true;
  /// Its task's end went onto a call and it said something (direct.ts `settleReaction`): its rows
  /// draw as the agent's own turn, at the reply column with a footer of its own, never inside the
  /// call or the subagent row that started it (Leo, 2026-11-08: "the text in this situation isn't
  /// from the subagent?"; 2026-11-09: "your response was weirdly folded into the rende?").
  ownTurn?: true;
  /// Where its task came from, cited on its line (direct.ts `backgroundSource`; Leo, 2026-11-05:
  /// "cite the helper/add atribution ... and display the actual code in the raw").
  source?: AcpmuxBackgroundSource;
};

/// The task a background turn answered, as its line cites it: the command as typed, and the helper
/// that ran it when the chat did not (a subagent's or workflow agent's shell).
export type AcpmuxBackgroundSource = {
  command?: string;
  description?: string;
  ownerId?: string;
  ownerTitle?: string;
};

/// How much a background task's end is worth (Leo, 2026-11-03: "there's like... background tasks
/// worth responding to and not worth responding to"), decided by acpmux from the task's own event
/// in one table keyed by the task's kind and status: `silent` (an interim stop, a subagent's step,
/// a stop, a monitor tick), `result` (a final report, a command that exited), `failure`.
export type AcpmuxBackgroundWeight = "silent" | "result" | "failure";

/// The task a background turn answered: its kind (`subagent`, `subagent_step`, `monitor`,
/// `shell`, `unknown`), the notification's status, its weight, the tool call that started it
/// (`origin`) and the notification's own summary.
export type AcpmuxBackgroundCause = {
  kind: string;
  status: string;
  weight: AcpmuxBackgroundWeight;
  origin?: string;
  summary?: string;
};

/// What a background turn left on the call that started its task: `fresh` for a final result the
/// person has not seen (a small mark at the row's edge until their next prompt). The turn's own words
/// are never part of it: they draw as the agent's own message (direct.ts `settleReaction`).
export type AcpmuxBackgroundReaction = {
  turn: string;
  weight: AcpmuxBackgroundWeight;
  fresh?: true;
  /// The task's end was interim (acpmux's cause status `interim`: Claude Code said the agent "is
  /// waiting on its own background work"): it has not given its final report yet. A later end of
  /// the same call replaces the reaction, which clears it.
  interim?: true;
};

/// What a run of background-task notifications' line counts (conversation/backgroundRuns.ts): quiet
/// task turns and finished shells, stopped shells, scheduled checks, other quiet background turns,
/// and the ids of the rows it folds (Find and links open it for one).
export type AcpmuxBackgroundRun = {
  finished: number;
  stopped: number;
  /// Failed shells: the line names how many.
  failed: number;
  scheduled: number;
  other: number;
  /// How many members are background shells' ends: a run of only those reads "N background commands".
  commands: number;
  /// How many members are subagents' ends (a harness event, folded as a tool call is), and how they
  /// ended when they all ended alike: a run of only those reads "N subagents stopped".
  subagents?: number;
  subagentEnd?: "finished" | "stopped" | "disconnected" | "failed";
  rows: string[];
};

/// The chat's permission policy (an acpmux policy id narrower than approve-all) that its harness
/// cannot keep (a `policy_unenforced` record): OpenCode's own settings decide what it asks
/// (`ownSettings`); another harness has no mode that asks (`noAskingMode`).
export type AcpmuxPolicyUnenforced = {
  policy: string;
  why: "ownSettings" | "noAskingMode";
};

/// A message to this chat that acpmux holds while its pair is paused (`agent_pair_held`).
export type AcpmuxHeldMessage = { promptId: string; text: string };

/// acpmux paused messages between this chat and another agent's (an `agent_pair_paused` record,
/// conversation/agentPairs.ts): why, what it still holds, what it settled, and whether it resumed.
export type AcpmuxAgentPair = {
  peer: string;
  peerName: string;
  /// Back and forth without progress, the same message again, more than the cap within
  /// `windowSecs`, or a held message acpmux could not deliver after a resume.
  reason: "alternating" | "repeating" | "cap" | "release_failed";
  count: number;
  windowSecs?: number;
  /// Why a release failed (`release_failed`).
  error?: string;
  /// Messages still held, once each, in the order acpmux held them; a re-pause takes over what an
  /// earlier pause with the same peer still held.
  held: AcpmuxHeldMessage[];
  /// Held messages acpmux delivered (`agent_pair_released`).
  released: number;
  /// Held messages it gave up on (`agent_pair_dropped`).
  dropped: number;
  resumed?: boolean;
};

/// What the chat's agent runs on, from its own start line (Claude Code's system/init, acpmux's
/// `session_info_update._meta.claude`): the chat's summary keeps the latest, and a transcript line
/// (conversation/SessionStartNote.tsx) marks a turn whose model or route is new. `harness` and `cwd`
/// are the chat's when the line came.
export type AcpmuxSessionStart = {
  agent: "claude";
  version: string;
  model?: string;
  harness?: string;
  cwd?: string;
};

/// Where a sent prompt is on its way (plans/cmux-next/composer-delivery-DESIGN.md): `sending` until
/// acpmux records it, `delivered` once it did, `read` once the agent started on it, else `failed`.
export type PromptDeliveryState = "sending" | "delivered" | "read" | "failed";
/// The hop a send stopped at: the pane could not reach acpmux, acpmux refused it or never answered,
/// or the agent's turn for it failed.
export type PromptDeliveryHop = "connection" | "acpmux" | "agent";
/// How long a sent prompt shows nothing before its pending state does (PromptDelivery.tsx): a fast
/// send never says it is on its way.
export const PROMPT_PENDING_AFTER_MS = 1000;
export type PromptDelivery = {
  state: PromptDeliveryState;
  promptId: string;
  sessionId: string;
  /// When the pane wrote `session/prompt`, acpmux recorded it, and the agent started on it.
  sentAt: number;
  acceptedAt?: number;
  readAt?: number;
  failedAt?: number;
  /// No answer for a while: the pane checks whether it missed the chat's events (stallLog.ts). The
  /// row says nothing more than it did: one pending state until the prompt lands or fails.
  slow?: boolean;
  /// A steer sent into the running turn: while on its way the row says it is queued behind that
  /// turn, never "Not sent".
  queued?: boolean;
  /// acpmux is starting or reconnecting: the pane holds the prompt and sends it once acpmux answers
  /// (sendWhenReady.ts). The row says "Sending when ready".
  waitingForHost?: boolean;
  hop?: PromptDeliveryHop;
  /// The refusal's code and acpmux's reason (`trust.pending`): the failure's cause, which the card's
  /// words and actions follow (sendFailure.ts). `error` is the refuser's own words, for Details.
  code?: string;
  reason?: string;
  error?: string;
  /// The machine acpmux runs on, when it is not this one.
  connection?: string;
};

/// A prompt waiting for the running turn, with the images it sends, in its order (Leo,
/// 2026-10-21: a queued row showed only its text).
export type QueuedPrompt = {
  id: string;
  prompt: string;
  next?: boolean;
  sending?: boolean;
  images?: QueuedPromptImage[];
  /// Not acpmux's: the pane holds it until the folder is trusted (trustHeld.ts).
  held?: boolean;
  /// A held prompt that waits for the chat's Cloud machine to wake instead (cloudWake.ts).
  waking?: boolean;
  inlineParts?: PromptContentPart[];
  /// Another agent's message waiting here (direct.ts `queuedMessage`): it draws in the transcript
  /// as the message's received card (conversation/queuedMessages.ts), never as a queue row.
  message?: IncomingMessage;
  /// acpmux's inbox notice waiting here (provenance `inbox_notice`, hub/inbox.rs): other agents'
  /// messages, not the person's prompt. Like `message`, it draws in the transcript's one group of
  /// waiting messages as its threads (conversation/queuedMessages.ts), never as a queue row.
  inbox?: InboxNotice;
  /// A teammate's prompt in a shared chat (its `person_message` provenance): its row names them,
  /// and only they may change it (acpmux refuses another author's edit with `queue.not_author`).
  author?: Participant;
  /// acpmux's ask to resume a failed subagent (subagents/retryState.ts `subagentRetryNotice`): its
  /// row names the subagent instead of drawing the prompt's text.
  retry?: SubagentRetryNotice;
  /// acpmux's own prompt to the chat's agent, by its provenance kind (`surge_digest`,
  /// `subagent_retry`, `auto_resume`, ...; acpmux `QueuedPromptSummary.origin` `acpmux`,
  /// hub/queue_origin.rs). Not the person's: it draws apart from their steer rows, with none of
  /// their actions (ComposerQueue.tsx `SystemNotes`; Leo, 2026-11-24).
  system?: string;
  /// Another agent's message the person's Stop holds (acpmux `queue_paused` with `reason: "stop"`,
  /// hub/cancel.rs): it waits until the person's next turn completes or the queue is resumed, not
  /// for the turn to end, and its card says so (conversation/QueuedMessageCard.tsx).
  heldByStop?: true;
  /// A guest's prompt that waits for the owner's Approve or Decline (acpmux `awaitingOwner`,
  /// `_acpmux/queue_approve`): it never runs until approved (conversation/QueuedMessageCard.tsx).
  awaitingOwner?: boolean;
  /// The revision of the text the pane holds for it (a guest's edit makes a new one), which Approve
  /// names: always from the same record as `prompt`.
  revision?: number;
  /// acpmux lists a newer revision whose whole text has not reached the pane yet: Approve waits.
  updating?: boolean;
  /// The newest revision acpmux listed or recorded for it, which `updating` waits for.
  listedRevision?: number;
  /// The queued incarnation acpmux names for a held prompt (its record's or listing's `turnId`),
  /// which Approve names with the revision (`_acpmux/queue_approve` requires both).
  turnId?: string;
};
/// An image a prompt sent: `_acpmux/attachment {sessionId, id}` reads its bytes back.
/// A prompt's image as acpmux names it; `width`/`height` are its natural size when the record
/// carries them, so its thumbnail is reserved at its own shape before it is read.
export type PromptImage = {
  id: string;
  mimeType: string;
  name?: string;
  width?: number;
  height?: number;
  src?: string;
  /// The app it came from (attachments.ts `AttachmentSource`), as acpmux kept it with the prompt.
  source?: AttachmentSource;
};
/// Ordered ACP content. The daemon validates blockIndex/companionOf against the actual blocks.
/// Local attachment identities and video previews survive echo; companions remain on the wire.
/// `placed`: the composer put this attachment in the text (inlinePrompt.ts), so the sent bubble
/// draws the prompt in this order; an unplaced prompt's parts have none (UserBubble.tsx).
export type PromptContentPart =
  | { kind: "text"; text: string }
  | (PromptImage & {
      kind: "image";
      persisted?: false;
      attachmentId?: string;
      blockIndex?: number;
      placed?: true;
    })
  | {
      kind: "file" | "document" | "audio" | "pasted";
      placed?: true;
      id?: string;
      attachmentId?: string;
      companionOf?: number;
      name: string;
      mimeType?: string;
      size?: number;
      text?: string;
      pageCount?: number;
      uri?: string;
      video?: VideoInfo;
      /// A video's picture size, which acpmux keeps with its part (hub/prompt_images.rs), so its
      /// sent tile has its box from the first frame after a reload (conversation/sentVideos.ts).
      width?: number;
      height?: number;
      source?: AttachmentSource;
    };
/// A queued prompt's image: `src` is its data URL when the pane has its bytes (it sent them, or
/// the `queued` record carries them), else the row reads it by `id`. acpmux names an image by the
/// SHA-256 of its bytes; one the pane only sent so far has the composer's id (`local`) until
/// acpmux names it, so an edit cannot keep or drop it by id yet.
export type QueuedPromptImage = PromptImage & { src?: string; local?: boolean };

/// A turn's tokens as Anthropic counts them: what the model wrote (`output`) apart from what it read,
/// which is the fresh input, the prompt cache's reads and its writes, each its calls added up. The
/// running line adds up each model call's (direct.ts `turnTokenSplit`); a finished turn's comes from
/// its `turn_result`. `context` is what the chat's context held after the turn's last call, and
/// `calls` how many calls the counts add up, when acpmux names them (tokenSplit.ts).
export type TurnTokenSplit = {
  output: number;
  input: number;
  cacheRead: number;
  cacheWrite: number;
  context?: number;
  calls?: number;
};

/// One retry of a turn's failed model request, as acpmux logs it (`turn_retrying`): Claude Code's
/// `system/api_retry` (attempt of maxRetries, error, errorStatus) or Codex's stream error.
export type AcpmuxTurnRetry = {
  attempt?: number;
  maxRetries?: number;
  error?: string;
  errorStatus?: number;
  /// What acpmux classified the failure as (hub/outage.rs): the connection failed, not the model.
  cause?: "dns" | "refused" | "timeout" | "unreachable";
  /// The host that could not be reached, when the harness's words name one.
  host?: string;
  /// When the harness tries again, epoch ms (acpmux adds the harness's delay to its own clock).
  retryAt?: number;
};

/// The client's row that carries the running turn's retries (direct.ts): kind "typing", so no
/// view draws it; the live line reads it (conversation/turns.ts `withRetry`).
export const TURN_RETRY = "turn-retry";

/// One claim a reply makes and what its turn's own runs say of it (acpmux hub/claim_check.rs):
/// `backed`, the newest matching run exited 0; `failed`, it did not; `none`, no run matched.
export type ClaimCheck = {
  text: string;
  kind: "tests" | "build" | "lint" | "typecheck" | "ran";
  verdict: "backed" | "failed" | "none";
  toolCallId?: string;
  command?: string;
};

/// The chat a fork came from, on the fork's "Forked from" notice row (direct.ts `forked`): its
/// session, and its title as the row's text names it (conversation/ForkedFromLine.tsx links it).
export type ForkedFrom = { parentId: string; chat: string };

export type AcpmuxRow = {
  id: string;
  version: number;
  at: number;
  kind: string;
  /// The row-store group whose children this activity row comes from. Closed groups are paged on
  /// demand when their transcript disclosure opens.
  foldId?: number;
  /// The acpmux event a turn summary came from, where a fork through that turn ends.
  seq?: number;
  /// The daemon's stable identity for a turn. Turn results can be replayed with a new seq, so
  /// transcript rows that belong to one turn use this identity when it is available.
  turnId?: string;
  text?: string;
  /// A fork's "Forked from" notice: the chat its name links to (conversation/ForkedFromLine.tsx).
  forkedFrom?: ForkedFrom;
  /// Codex's explicit message phase; absent for harnesses and history without phase metadata.
  assistantPhase?: "commentary" | "final_answer";
  /// A reply or summary's actual turn start, retained after the snapshot's live clock clears.
  turnStartedAtMs?: number;
  /// A finished reply's checked claims ("tests pass"), from acpmux's `claim_checks` at its turn's
  /// end (hub/claim_check.rs): each one's phrase draws a mark (conversation/ClaimMark.tsx).
  claims?: ClaimCheck[];
  streaming?: boolean;
  pending?: boolean;
  failed?: boolean;
  /// A prompt this pane sent: where it is on its way (PromptDelivery).
  delivery?: PromptDelivery;
  items?: AcpmuxActivity[];
  /// A background task row's shell, which ended where the row sits (cx-ncc.84).
  backgroundTask?: AcpmuxBackgroundTask;
  /// A compaction row's compaction, noted where it happened.
  compaction?: AcpmuxCompaction;
  /// A failover row's harnesses.
  failover?: AcpmuxFailover;
  /// A recap row's recap.
  recap?: AcpmuxRecap;
  /// The "New since you looked" row's mark.
  since?: AcpmuxSince;
  /// A plan build row's builds (planBuild/PlanBuildCard.tsx): what a plan approval started off this chat.
  planBuild?: PlanBuild;
  /// A memory inbox row's offer (conversation/memoryInbox.ts): facts for the instructions file.
  memory?: MemoryOffer;
  /// A prompt coach row's rewrite (conversation/promptCoach.ts): the chat's first prompt said at once.
  coach?: PromptCoach;
  /// A no-prompt preset's approval card (conversation/presetApproval.ts): the preset an agent of
  /// this chat tried to start a chat on another machine from, and the person's answer.
  presetApproval?: PresetApproval;
  /// A background turn's line (conversation/backgroundTurns.ts): the turn it stands for.
  background?: AcpmuxBackgroundTurn;
  /// A row a background turn made: that turn's id, so its line can fold it (backgroundTurns.ts).
  inBackground?: string;
  /// A row of the running turn that was already there when the chat was opened or reloaded (a v1
  /// chat: direct.ts `noteReadWork`), with how many of its items were (an activity row's; 0 for any
  /// other row). The running turn draws what of it its fold will hold folded from the first frame,
  /// as the row store sends an open turn's settled work (turns.ts `withoutReadWork`).
  readAtOpen?: number;
  /// An agent reply to the person's own prompt (conversation/turns.ts answeringPerson): its text
  /// draws even when it is only punctuation (visibleMessage.ts).
  answersPerson?: true;
  /// A run of background-task notifications folded under one line (conversation/backgroundRuns.ts):
  /// drawn as a background turn's line, with what it counts and the rows it folds.
  backgroundRun?: AcpmuxBackgroundRun;
  /// A policy note's policy and why the chat's harness cannot keep it.
  policyUnenforced?: AcpmuxPolicyUnenforced;
  /// An agent pair row's pause (conversation/AgentPairNote.tsx).
  agentPair?: AcpmuxAgentPair;
  /// A session start row's agent, version, model, route and folder.
  sessionStart?: AcpmuxSessionStart;
  /// A suggested tasks card's offers (offer/SuggestedTasks.tsx): the offers of one group, in the
  /// order the agent made them, or one offer made without a group.
  offers?: AcpmuxSessionOffer[];
  /// A prompt acpmux sent this chat with a suggested task's result (offer/SuggestedTasks.tsx).
  received?: AcpmuxOfferResult;
  /// A prompt that is not the person's: another agent's message, or harness bookkeeping
  /// (conversation/incomingMessage.ts).
  incoming?: Extract<IncomingPrompt, { kind: "message" | "notice" | "inbox" | "hidden" }>;
  /// The prompt as the agent got it, when the row shows something else (an incoming message's
  /// body): what Retry sends again.
  resend?: string;
  /// Another agent's message still waiting in the queue (conversation/queuedMessages.ts): the
  /// queue entry's promptId, which its ⋯ menu steers, edits or deletes, and whether it was sent
  /// now already (acpmux marks it `next`; it runs right after the turn).
  /// `lead`: the first queued message, which explains a Stop hold for the run.
  /// `heldByStop`: the person's Stop holds it (QueuedPrompt `heldByStop`).
  /// A person's (a guest's) waiting prompt names them (`person`): `held` while it waits for the
  /// owner's Approve, `declined` once the owner declined it (one quiet line, never removed silently).
  /// `revision` is the held prompt's as this row draws it, which Approve names (a guest's edit since
  /// makes acpmux answer `queue.stale`).
  queuedMessage?: {
    promptId: string;
    next?: boolean;
    lead?: boolean;
    heldByStop?: boolean;
    person?: Participant;
    held?: boolean;
    declined?: boolean;
    revision?: number;
    /// A newer revision is on its way: the card says so and offers no Approve until it shows.
    updating?: boolean;
  };
  /// A flattened inbox delivery that came from a queued message. Keep the source queue target
  /// separate from `queuedMessage` so one wrapper prompt does not become every delivery's identity.
  inboxQueue?: {
    promptId: string;
    next?: boolean;
    lead?: boolean;
    heldByStop?: boolean;
  };
  /// A prompt the person did not type (a task's result, another agent's message, bookkeeping),
  /// whether or not it draws as one: prompt recall leaves it out (composer/promptHistory.ts).
  untyped?: boolean;
  /// A started sessions row's chats, oldest first (started/StartedSessionCard.tsx).
  started?: StartedSession[];
  /// A finished turn's task line's sub-sessions, in the order it started them (conversation/TaskLine.tsx).
  tasks?: StartedTask[];
  toolCount?: number;
  durationMs?: number;
  /// When a footer's `durationMs` ended, if not at its own `at`: a stretch the person came in on
  /// (turns.ts `supersededFooters`) worked until his steer, while its time is its last reply's. Its
  /// Timeline (conversation/waterfallSpans.ts `waterfall`) starts at this less `durationMs`.
  workEndedAt?: number;
  /// A turn summary's tokens, when its harness reported them on the `turn_result` (Claude Code:
  /// its main loop's, acpmux hub/turn_usage.rs).
  tokens?: TurnTokenSplit;
  /// A turn summary's checkpoints, when acpmux recorded them (changes/turnCheckpointSource.ts).
  checkpoint?: SummaryCheckpoint;
  /// A sent prompt's images, as acpmux names them in its user_message (hub/prompt_images.rs).
  images?: PromptImage[];
  inlineParts?: PromptContentPart[];
  /// A sent prompt's pasted blocks (`user_message.pasted`, UTF-16 ranges into `text`), each drawn
  /// as a chip that opens in place (conversation/promptCollapse.ts).
  pasted?: PasteRange[];
  /// Who sent a prompt that the reader did not type here: `chief` for the Chief's task, tell,
  /// steer or restart message to a subagent (its `user_message` promptId `optchat-<kind>:…`).
  from?: "chief";
  /// The person who sent a prompt in a shared chat (multiplayer/participants.ts `promptAuthor`);
  /// unset for the chat owner's own, which draws as it always has.
  author?: Participant;
  /// The person who answered a `permissionRecord` row's ask (`answeredBy`).
  answeredBy?: Participant;
  /// The machine the person's own `acpmux send` ran on (acpmux records it on the client, as
  /// `acpmux-cli#…@big-red`): "via CLI on big-red" under their prompt.
  viaCli?: string;
  /// The harness or app the prompt was sent from with `acpmux send` (acpmux's `sender_claim`
  /// record, conversation/sentFromHarness.ts): a sender chip under it, which never says who sent it.
  sentFrom?: SentFrom;
  /// Part of the person's typed text reads as another agent's output (acpmux `agentText`, a paste
  /// from a client that marks none): the agent it names, if any. One quiet line under the prompt.
  agentText?: { from?: string };
  /// The originating prompt row, so Retry can restore image/PDF attachments.
  retryRowId?: string;
  /// A turn summary of the chat's last turn, which a failed turn's Retry asks acpmux to retry
  /// (turns.ts), even when its prompt is an attempt acpmux sent and draws nothing.
  retryable?: boolean;
  /// A turn summary whose footer offers Retry with `prompt` (turns.ts retryTargetAt): the chat's last
  /// turn, or the last one a prompt opened when only notices and reminders came after it.
  retryTarget?: true;
  /// The turn's completed edit diff proves it changed files. Retry keeps this hint in its tooltip;
  /// missing or incomplete checkpoint data stays neutral (conversation/turns.ts).
  changedFiles?: true;
  /// A turn footer's answer row (turns.ts), whose right-click menu the footer's More opens.
  answerId?: string;
  /// A turn footer's whole turn for its Copy (conversation/turnCopy.ts): the agent's replies and each
  /// run of tool calls between them, in order; undefined when the agent said nothing.
  turnCopy?: TurnCopyPart[];
  /// A finished turn footer's timed tool calls and thoughts, in order, for its waterfall
  /// (conversation/waterfallSpans.ts `turnWork`, TurnWaterfall.tsx); undefined when none was timed.
  turnWork?: AcpmuxActivity[];
  /// The chat's last turn's GitHub call that found no GitHub connection for this chat
  /// (conversation/githubConnect.ts): its footer draws the Connect GitHub card.
  githubConnect?: GitHubConnectNeed;
  /// A footer turns.ts `supersededFooters` added where the person came in on a stretch of a turn (a
  /// steer that landed in it, or a new prompt over a turn with no summary): the stretch counts as
  /// ended, and the footer offers its Copy.
  superseded?: boolean;
  retryAttachments?: ComposerAttachment[];
  status?: string;
  error?: string;
  /// acpmux's typed reason for a failed turn (`errorCode`, a string), for its card (failureCopy.ts).
  errorCode?: string;
  permission?: AcpmuxPermission;
  /// A `questionRecord` row's question, answered or cancelled (question/record.ts).
  question?: AgentQuestion;
  /// A `nextStep` row's tagged ask and, once a later prompt picked one of its answers, that answer
  /// (conversation/nextStepAsk.ts, NextStepCard.tsx). `superseded`: a later turn ended on a card of
  /// its own, so this one folds; `answer` then holds what the person said after it, if anything.
  nextStep?: { ask: NextStepAsk; answer?: string; superseded?: boolean };
  /// A `walkthrough` row's browser walkthrough (conversation/walkthroughModel.ts, Walkthrough.tsx).
  walkthrough?: Walkthrough;
  /// A `permissionRecord` row's answer, its ask in `permission` (permissions/record.ts).
  decision?: PermissionDecision;
  /// A turn summary whose turn draws a "Worked for" line (conversation/turns.ts), so its
  /// footer need not repeat the time and count.
  folded?: boolean;
  /// A Worked-for row's actual open state, including a provisional key from paged history.
  foldOpen?: boolean;
  /// A turn's header ("Worked for", turns.ts `turnHeaderId`) is one row from the turn's start to its
  /// end: `running` while the turn runs ("Working for 32s", its clock ticking from `at`, or held at
  /// `durationMs` once the answer came), unset once it ended.
  turnPhase?: "running";
  /// Work shown inside an open "Worked for": its turn has ended.
  settled?: boolean;
  /// A reply to the person (not a short note) shown inside an open "Worked for": settled, yet it
  /// keeps its own action row (hasReplyActions; conversation/turns.ts shapeTurn).
  foldedReply?: boolean;
  /// A run of finished tool calls folded under one summary line (conversation/turns.ts `codexRuns`,
  /// conversation/toolRunSummary.ts).
  /// False keeps a run waiting for edit permission in tool rows without collapsing it.
  foldRun?: boolean;
  /// A folded run inside the open "Worked for" of a turn the person steered: its line starts open, so
  /// opening Worked for shows all its work at once (conversation/turns.ts, turnFoldSteered.experiment.ts).
  runOpen?: true;
  /// A "Worked for" line that names the work it holds after its time (turnFoldSteered `header` arm).
  workedRuns?: AcpmuxActivity[];
  /// The calls a "Worked for" hides, which its line counts with the Fold Summary Counts switch on
  /// (conversation/turns.ts `workedCountsText`, `FOLD_COUNTS_SWITCH`).
  foldCalls?: AcpmuxActivity[];
  /// A run of one-line rows carrying messages between agents, folded under one line
  /// (conversation/messageRuns.ts): what its line counts and the rows it folds.
  messageRun?: AcpmuxMessageRun;
  /// The transcript frame the row draws in, when it is not the row's id: a message run's line takes
  /// over its first row's frame (conversation/messageRuns.ts), so the run on screen stays the same
  /// element when it folds, and does not unmount and enter again. The React key and the live
  /// entrance follow it (`rowFrameKey`); everything else (the fold set, Find, selection) keys by id.
  frame?: string;
  /// The live turn's latest row, whose last thought may still stream (conversation/turns.ts).
  live?: boolean;
  /// A running turn's status line: the title of the call in flight, which it names (WorkingFor.tsx).
  doing?: string;
  /// A running turn's status line before the turn's first output: it reads "Thinking" beside the
  /// turn's time (WorkingFor.tsx).
  thinkingNow?: boolean;
  /// The running turn's harness retries a model request that failed (acpmux `turn_retrying`,
  /// hub/turn_retry.rs): on the client's `TURN_RETRY` row while it retries, and on the live line,
  /// which then says the model cannot be reached instead of "Thinking" (conversation/Thinking.tsx).
  retry?: AcpmuxTurnRetry;
  /// On the `TURN_RETRY` row: how long the turn's finished retries took, which the live line's
  /// "Thinking" time leaves out (conversation/turns.ts `withRetry`).
  retriedMs?: number;
  /// A running turn's status line drawn as the turn's last row (conversation/turns.ts): no rule
  /// under it, and its clock never stops while the turn runs.
  below?: boolean;
  /// The Codex-style live line (conversation/turns.ts `codexLiveTurn`, Thinking.tsx): the call in
  /// flight's start on this computer's clock, which its time counts from; whether `doing` is a raw
  /// command line, which reads "Running <command>" (or "Running a command" when empty); whether
  /// the agent still writes that command (`doingDraft`: a pending shell call with no command yet,
  /// "Writing a command"); no time beside "Thinking" (`untimed`, the older layout's line, whose
  /// "Working for" over the work timed the turn); and the streaming text it waits
  /// behind, by id and version, while that text still moves.
  doingAt?: number;
  doingShell?: boolean;
  /// The acpmux tool kind of the call the live line names (`execute`, `read`, ...): a look's thinking
  /// glyph plays the document's trigger for it (conversation/thinkingGlyphModel.ts `glyphTrigger`).
  doingKind?: string;
  /// The Codex-style live line names a command still running in an earlier run, which that run
  /// draws no row for (conversation/turns.ts `lineCall`, `codexRuns`): its call id. While the reader
  /// is scrolled up, the call stays out of its run when the line lets go of it
  /// (conversation/turnEndHold.ts `callsToHold`).
  linedCall?: string;
  /// `doing` names the latest step, finished, which the live line holds until the next step
  /// (conversation/turns.ts `liftedStep`): "Ran grep …".
  doingDone?: boolean;
  /// The id of the call `doing` names, running or just finished (conversation/turns.ts
  /// `codexLiveTurn`): while it stays the same call the line's words change in place, with no roll.
  doingCall?: string;
  /// How long that finished step took, its own start to its own end (conversation/turns.ts
  /// `liftedStep`): the live line says it beside the step, never the turn's time.
  doingForMs?: number;
  /// What the Codex-style live line says when it names no call (conversation/turns.ts
  /// `codexLiveTurn`): the agent waits on its foreground subagents (`liveAgents` of them still
  /// running), or writes its reply. Neither reads "Thinking" (Leo, 2026-11-03: "i think the
  /// "thinking" accounting is also off pretty frequently"), and neither does a compaction
  /// (`compacting`: `liveCompaction` running, timed from its start at `doingAt`, or just completed):
  /// its own row folds into the line (Leo, 2026-11-07: "You're not thinking during this time ...
  /// That should replace the thinking area").
  liveState?: "subagents" | "writing" | "compacting";
  liveAgents?: number;
  /// The names of the foreground subagents the line waits on, as the tray shows them (conversation/
  /// turns.ts `foregroundAgentNames`): "Waiting on subagent Explore auth", never only a count.
  liveAgentNames?: readonly string[];
  liveCompaction?: AcpmuxCompaction;
  /// With the line reading "Thinking" past the first step (conversation/turns.ts `liveClock`, this
  /// computer's clock): when this stretch of thinking began, the time beside the word ticking from
  /// it, and when the turn last heard anything, after which a silence of SILENT_MS reads "Waiting".
  /// `heardKey` changes with every event the turn's rows take (Thinking.tsx `useChangedAt`).
  phaseAt?: number;
  heardAt?: number;
  heardKey?: string;
  /// What a silent line waits on, so it never reads a bare "Waiting" (conversation/liveWait.ts):
  /// the model reading the call that just returned, its first reply, another agent's message, the
  /// person's queued message, or its next step.
  liveWait?: LiveWait;
  /// With the line reading "Waiting on N subagents" (conversation/turns.ts, this computer's clock):
  /// when that wait began, the last moment the turn's own rows did anything, so the time beside the
  /// words is the wait's, never the turn's whole time.
  waitAt?: number;
  /// The live line's clock is the turn's whole time, past its first step: it reads "4m" beside the label, or "2s · 4m" after a step's own time, so
  /// the time never reads as what the line names (conversation/Thinking.tsx).
  turnTotal?: boolean;
  /// The call in flight sends another agent a message (conversation/turns.ts `sendingTo`: a shell
  /// `acpmux send`, a sub-session's `send_message`): the line reads "Sending message to
  /// <doingSendTo>", and the sub-session `doingSendSession` by its name once the list has it.
  doingSendTo?: string;
  doingSendSession?: string;
  doingDraft?: boolean;
  untimed?: boolean;
  /// The live line's turn, by its prompt's row id (conversation/thinkingVerbs.ts): kept from send to
  /// the echo, so the line's verb stays one word for the whole turn.
  verbKey?: string;
  quietKey?: string;
  /// When the reply `quietKey` names was written, on this page's clock (conversation/turns.ts).
  quietAt?: number;
  /// The call in flight is a command: the line offers "⌃B to run in background" (BackgroundHint.tsx;
  /// never on the command's own row), and leads with the terminal glyph when it names it
  /// (WorkingFor.tsx).
  doingCommand?: boolean;
  /// The disclosure of the group that draws the call's own row, and whether it opens by default: while
  /// it is open the row names the call, so the line does not (conversation/turns.ts `ownRow`).
  doingGroup?: string;
  doingGroupOpen?: boolean;
  /// The run line that takes `doingGroup`'s place when the run folds (TurnRows.tsx `runLinks`), none for
  /// an edits group: the group reads open or closed with it, as its own line does (WorkingFor.tsx).
  doingRun?: string;
  /// A "Worked for" disclosure whose fold mixes the agent's messages with its work reads "N previous
  /// messages", as Codex's does (conversation/turns.ts `foldMixesMessages`).
  previous?: number;
  /// The messages between agents a finished turn's "Worked for" folds, which its label names in the
  /// `messages` arm of workedForMessages.experiment.ts (conversation/turns.ts `shapeTurn`).
  workedMessages?: { sent: number; received: number };
  /// A finished turn that drew nothing but its closed "Worked for" (a wake that only ran tools), and
  /// the bare turns right after it joined into its one line (conversation/turns.ts `joinBareWorked`):
  /// each member's fold key. Opened, every member draws its own line, and `head` names the first
  /// one's, under which a click on any of them closes them all (`foldCovers`).
  workedRun?: { ids: readonly string[]; head?: string };
  /// A finished turn's "Worked for" line: every call the turn made, said after its time (turnFoldStyle.ts
  /// `countsCalls`).
  workedCalls?: number;
  /// The prompt of other agents' messages a finished turn's "Worked for" folds (conversation/turns.ts
  /// `shapedTurn`): the line stands for that prompt where the closed fold draws none, so the turn
  /// keeps its minimap tick (threadMinimap/model.ts `minimapTurns`).
  foldedPrompt?: AcpmuxRow;
  /// A prompt queued behind a harness switch (its id there), which offers Cancel (harnessSwitch.ts).
  queued?: string;
  /// A prompt sent into a running turn: `waiting` until the agent reads it (it reads a steer when
  /// the step it is on ends), then `landed`.
  steer?: "waiting" | "landed";
  /// A prompt sent now that ended the turn it went into (acpmux cancels it, or the agent ends it
  /// with `end_turn`) and runs next: accepted, drawn inside that turn (turnStart.ts
  /// ``continuesTurn``), with no mark of its own.
  continues?: boolean;
  /// The summary of a turn a prompt sent now ended, not Stop or Esc (direct.ts): the turn goes on
  /// under that prompt, so it draws no "You stopped after" (conversation/turns.ts).
  continued?: boolean;
  /// A stopped turn's summary that acpmux ended itself because the agent never answered Stop
  /// (`cancelForced`, hub/cancel.rs). It draws as any stop; only the footer's tooltip says so.
  stopForced?: true;
  /// A steer logged after its turn's Stop and never read: drawn as a plain message below the stop
  /// (direct.ts `deferLateSteers`), until acpmux runs it again as the next prompt.
  afterStop?: true;
  /// A waiting steer's promptId, which its Send now names (conversation/PendingSteer.tsx).
  steerPromptId?: string;
  /// A prompt's promptId as acpmux recorded it (its `user_message` record's): the thread rail keys
  /// its tick on it, the same live, after acpmux's echo and when the history is read again.
  promptId?: string;
  /// The last turn's footer carries its prompt, for Retry (conversation/turns.ts).
  prompt?: string;
  /// A failed turn that was itself a retry of an earlier failed one (its prompt acpmux's
  /// `P~resume-n`): its card says it failed again, so a Retry that failed as fast as the first
  /// (a gateway outage) is not read as a click that did nothing (cmux#34369).
  failedAgain?: true;
  /// A failed turn a later turn of the chat finished after (conversation/turns.ts `markRecovered`):
  /// the chat went on (Continue, a fork, a new message), so its error card no longer draws (cmux#48434).
  recovered?: true;
  /// The latest stopped turn with no successor: the empty composer can offer Resume.
  /// Kept as eligibility metadata; it adds no footer control or height.
  resumable?: boolean;
  /// The last turn's footer when that turn failed after doing work, or with no prompt to send again
  /// (a turn a notice started): its error card leads with Continue, which resumes the turn with its
  /// context, instead of Retry (conversation/errorRecovery.ts).
  continuable?: boolean;
  /// An edited-files card of a turn that has ended, which offers Undo (conversation/turns.ts).
  ended?: boolean;
  /// The final drawn row of a latest turn that has no turnSummary. It keeps the same turn gap as a
  /// footer without adding a permanent runway under every turn (conversation/turns.ts).
  lastTurn?: boolean;
  /// The edits an edited-files card merges (their row ids), so Find reaches each (chatFind.ts).
  merged?: string[];
  /// The rows a run absorbed (conversation/turns.ts `mergeShortNotes`): its own, the short note and
  /// the run after it, so Find and a shell's count reach each (chatFind.ts).
  joined?: string[];
  /// A closed fold's line that draws only a step's calls, not its edits (conversation/turns.ts
  /// `lineWork`): it is not that step's open-fold copy, so a Find match in the step opens the fold
  /// (chatFind.ts isFindRow).
  partial?: boolean;
  /// The messages other sessions sent that the agent has not read yet, drawn as one group
  /// (conversation/pendingMessages.ts, PendingMessagesCard.tsx), each once, oldest first.
  pendingMessages?: {
    rows: readonly AcpmuxRow[];
    displayRows?: readonly AcpmuxRow[];
    flat?: boolean;
  };
  /// A received row expanded from an inbox notice; used to keep its waiting run flat.
  inboxDelivery?: true;
  /// The id of the inbox notice row a delivery was expanded from (laneNoticeBatches.ts
  /// `inboxChildren`): a turn the notice opened keeps the notice's fold key and minimap anchor
  /// (conversation/turns.ts `turnFoldFor`, threadMinimap/model.ts `minimapTurns`).
  inboxSource?: string;
  inboxDeliveryBatch?: true;
  /// Metadata retained for a preview-only inbox delivery so opening it can hydrate its thread.
  inboxThread?: {
    threadId: string;
    label?: string;
    sender: string;
    preview: string;
    /// The newest message whole, when acpmux sent it (inboxNotice.ts `newest`).
    newest?: string;
    count: number;
    promptIds: readonly string[];
    fromSession?: string;
    fromHarness?: string;
    /// acpmux could not verify its sender (conversation/senderIdentity.ts).
    unverified?: true;
    /// Its sender as acpmux recorded it (inboxNotice.ts `SenderRef`): the chip asks for that chat
    /// by it, never by the bare name the line shows.
    senderRecord?: { session?: string; label?: string };
  };
  laneNoticeBatch?: {
    kind: "report" | "inbox";
    rows: readonly AcpmuxRow[];
    verdicts: Partial<Record<"SHIP" | "BLOCK" | "FIX" | "HOLD", number>>;
    threads: readonly { id: string; sender: string }[];
  };
  /// A shell mode command's block (shell/shellRuns.ts), which the page adds; never from acpmux.
  shell?: ShellRun;
  /// A subagent group's subagents (subagents/subagentFold.ts).
  subagents?: Subagent[];
  /// A start line's: how many of its `subagents` it names; it counts the rest (runningTray.ts `startedLineModel`).
  startedNamed?: number;
  /// On a background turn's line: the subagent whose report started the turn, which the line names
  /// (subagents/runningTray.ts `withSubagentLines`; conversation/BackgroundTurnLine.tsx).
  subagentReport?: Subagent;
  /// That report is the subagent's first, drawn right under its "Subagent finished" line.
  subagentReportFirst?: true;
};

export type AcpmuxActivity = {
  kind: string;
  text: string;
  status?: string;
  /// A thought's first and latest chunk (epoch ms), for a folded thought's "Thought for 12s"
  /// (conversation/ThoughtRow.tsx `thoughtDuration`).
  startedAt?: number;
  endedAt?: number;
  tool?: {
    id: string;
    title: string;
    kind?: string;
    status: string;
    /// A result whose call this view has not read (an older page holds it) and that shows
    /// nothing on its own: kept so paging can join it to its call, and drawn and counted as
    /// nothing until then (hiddenTools.ts `isCompletedPlumbingTool`).
    awaitingCall?: true;
    inputSummary?: string;
    output?: string;
    /// The output starts after the beginning of what the call printed: a long call's oldest lines went
    /// with their records when the chat let go of its oldest (direct.ts `shedOlderHeld`), and scrolling
    /// up reads them back (`foldOlder`). Its Shell block marks the cut as a read tail's is marked.
    earlierOutput?: true;
    /// A shell call's command line (`rawInput.command`), for its Shell block.
    command?: string;
    /// What the call says it does in a few words (Claude Code's Bash `rawInput.description`): a
    /// command row reads it instead of its raw command line, which its Shell block still shows.
    description?: string;
    /// A finished shell call's exit status (Codex's `rawOutput.exit_code`).
    exitCode?: number;
    /// When the call started and, once it completed or failed, when it ended (epoch ms),
    /// for the duration a command row shows.
    startedAt?: number;
    endedAt?: number;
    diffs?: AcpmuxFileDiff[];
    locations?: AcpmuxLocation[];
    /// The input's file (`rawInput.file_path`) and its canonical path (acpmux
    /// `_meta.acpmux.canonicalPath` on the update), when acpmux recorded one.
    inputPath?: { path: string; canonical: string };
    /// Images the call returned (ACP `image` content blocks), as data URLs.
    images?: string[];
    /// A shell that went on in the background: running there, then how it ended.
    background?: AcpmuxBackgroundState;
    /// The agent's reaction to its background task ending (`AcpmuxBackgroundReaction`).
    reaction?: AcpmuxBackgroundReaction;
    /// The person approved this call's permission ask (Allow, Always allow, or a switch to the
    /// harness's highest mode while its card was open): the row says "Approved" at its edge
    /// instead of a receipt line of its own (direct.ts `markApproved`).
    approved?: true;
    /// The harness metadata that names a built-in tool. Titles are user-visible labels and are
    /// not sufficient to identify plumbing calls with names such as ToolSearch.
    provenance?: { claudeTool?: string; claudeCodeToolName?: string };
    /// The name of the subagent a SendMessage call goes to, as the daemon's subagent list names
    /// it (`_meta.acpmux.recipient`, acpmux subagents.rs `recipient`): the "Sent to" row reads it
    /// when the page holds no row of the subagent's Agent call.
    recipient?: string;
  };
};

/// A file change from an ACP tool call's `diff` content: `oldText` is absent for a new file.
/// `line` is where the change starts, when the tool call's locations name it. `fragment`: the
/// texts are part of the file, not all of it (`_meta.acpmux.fragment`, a reopened Codex hunk).
/// `fromInput`: the page read it from the call's input, not a `diff` item (direct.ts `inputDiffs`).
/// `canonical`: the file's one spelling, as acpmux recorded it (`_meta.acpmux.canonicalPath`).
export type AcpmuxFileDiff = {
  path: string;
  oldText?: string;
  newText: string;
  line?: number;
  fragment?: true;
  fromInput?: true;
  canonical?: string;
};

/// A file a tool call names (ACP `locations`), with its canonical path as for `AcpmuxFileDiff`.
export type AcpmuxLocation = {
  path: string;
  line?: number;
  canonical?: string;
};

/// What tells two tool call paths apart: the canonical path acpmux recorded, absolute with links,
/// `.`, `..` and the volume's letter case resolved, so `./notes.txt`, a folder link's path and
/// `Notes.txt` on a volume that ignores case are one file; for a file in a repository it is the
/// turn checkpoint's `${root}/${path}`. A path recorded without one (an older log or peer) is
/// itself. Rows, diffs and Undo still use the agent's `path`.
export const pathKey = (file: { path: string; canonical?: string }) => file.canonical ?? file.path;

/// The canonical path a tool call recorded for `path`, one of its own: on a diff, a location or
/// its input.
export function toolCanonical(tool: NonNullable<AcpmuxActivity["tool"]>, path: string): string | undefined {
  const named = (file: { path: string; canonical?: string }) => file.path === path && file.canonical !== undefined;
  return (
    tool.diffs?.find(named)?.canonical ??
    tool.locations?.find(named)?.canonical ??
    (tool.inputPath?.path === path ? tool.inputPath.canonical : undefined)
  );
}

/// A Write whose old contents are unknown: its whole new text with no old text, still a fragment
/// because its result neither confirmed a create nor carried the old text (acpmux claude_stdio
/// `settle_write`: an overwrite without `originalFile`, an oversized one, no result yet, a cut-off
/// adopted Write). Its lines are not added lines, so the turn's files leave its file out (diff.ts
/// `turnFiles`) and the edited-files card lists its path without counts (`plainEditLabels`). A Write
/// read from its input is known: direct.ts `inputDiffs` builds one only when the result said created.
export const contentsUnknown = (diff: AcpmuxFileDiff) =>
  diff.oldText == null && diff.fragment === true && diff.fromInput !== true;

/// An agent's ask for a secret (cx-ncc.42, acpmux `hub/secrets.rs`): the `secret_request` record
/// holds only the name and reason, never a value. The card answers with `_acpmux/secret_submit`.
export type AcpmuxSecretAsk = {
  secretId: string;
  name: string;
  reason: string;
  /// A sudo card (acpmux `hub/elevation.rs`, `elevation_request`): the exact argv sudo runs, on
  /// which machine, and its time limit. Its answer is the same `secret_submit`, with the password.
  elevation?: { argv: string[]; host: string; timeoutSecs?: number };
};

/// An agent's offer of a parallel chat (cx-807da, acpmux `hub/offers.rs`): the `session_offer`
/// record, and its `session_offer_decision` once the person answered. Title and prompt are the
/// agent's text, drawn as plain text.
export type AcpmuxSessionOffer = {
  offerId: string;
  title: string;
  prompt: string;
  cwd: string;
  worktree: boolean;
  harness?: string;
  model?: string;
  /// The offers an agent suggested together (`suggest_tasks`) share one; they draw as one card.
  groupId?: string;
  /// `here`: the person had this chat do it; its prompt went to this chat.
  outcome?: "accepted" | "dismissed" | "here";
  childSessionId?: string;
  /// A started offer's chat, while the page watches it: its status (acpmux's session list) and
  /// its latest tool call's title.
  childStatus?: string;
  activity?: string;
};

/// The `_meta.provenance` acpmux puts on the prompt that brings a started offer's result back to
/// the chat that offered it (cx-lo9yf).
export type AcpmuxOfferResult = {
  offerId: string;
  childSessionId: string;
  title: string;
};

/** The concrete app, resource, or working directory an approval covers. */
export type AcpmuxPermissionScope = {
  kind: "app" | "resource" | "directory";
  value: string;
};

/** A daemon-owned OS access block. Approving retries one retained operation, never grants OS rights. */
export type ExternalAccess = {
  kind: "files_and_folders" | "full_disk_access";
  target: string;
  operation: "read_text_file";
  platform: "macos";
};

export type AcpmuxPermission = {
  externalAccess?: ExternalAccess;
  /// A risky step on a Cloud machine (acpmux fork_risky.rs, behind `cloud.autoCloud`): "Fork first"
  /// has the app fork the machine under `clientKey` before the step runs; the copy stays as the checkpoint.
  forkOffer?: { machine: string; reason: string; clientKey: string };
  permissionId: string;
  groupId?: string;
  turnId?: string;
  title?: string;
  command?: string;
  description?: string;
  rule?: string;
  /** The target carried by ACP v2's permission subject, when one is provided. */
  scope?: AcpmuxPermissionScope;
  kind?: string;
  /// The tool call it asks about: a subagent's own call when a subagent asks (summary/SubagentStatusList.tsx).
  toolCallId?: string;
  /// Proposed changes from this ask only; these have not been applied to the workspace.
  diffs?: AcpmuxFileDiff[];
  /// The plan a plan approval asks about, as Markdown (Claude Code's ExitPlanMode, Grok's
  /// `x.ai/exit_plan_mode`, Cursor's `create_plan`; direct.ts `permissionPlan`).
  plan?: string;
  /// Whether the person may edit the plan before approving it: Claude Code's ExitPlanMode, whose
  /// allow carries the edited plan back to the agent (`_acpmux/plan/build` `plan`).
  planEditable?: boolean;
  pending: boolean;
  options: {
    id: string;
    name: string;
    allow: boolean;
    kind?: string;
    description?: string;
    rule?: string;
  }[];
  /// The question this permission asks (AskUserQuestion, Codex user input, an interactive ACP
  /// ask, the Chief), mapped from the request by question/model.ts; unset for a tool permission.
  question?: AgentQuestion;
};

/** A model acpmux probed or a profile declared (`_acpmux/models`); declared entries may carry
 *  catalog metadata, which ranks between the cmux catalog and the user's overrides. */
export type AcpmuxCatalogModel = {
  id: string;
  name?: string;
  /** Daemon catalog metadata is not proof the account reported this model. */
  curated?: boolean;
  declared?: boolean;
  unavailable?: string;
  shortName?: string;
  family?: string;
  efforts?: string[];
  /** Present when the catalog/profile explicitly supplied the effort capability, including []. */
  effortsDeclared?: boolean;
  defaultEffort?: string;
  fast?: boolean;
  inlineFast?: boolean;
  serviceTiers?: (string | { id: string; name?: string; description?: string })[];
  contextWindow?: number;
  /** The catalog release an alias stands for (the picker catalog's alias rows). */
  release?: string;
};

/// A change to a waiting prompt (`_acpmux/queue_edit`): its text, its place (0 runs next), send it
/// now (steered into the running turn, whose step stops, when its agent steers), or `interrupt`:
/// stop the running turn and run it next.
export type QueueEdit =
  /** New text; the prompt keeps its images, or with `images` (acpmux ids) only those. */
  | { op: "update"; text: string; images?: string[] }
  | { op: "move"; index: number }
  | { op: "send_now" }
  | { op: "interrupt" }
  /** Runs a queue a failed turn paused; any of its prompts names it. */
  | { op: "resume" }
  /** Takes back a steer the agent has not read yet (the X beside it); false once it was read. */
  | { op: "withdraw" };

/** Where a chat's running limit comes from: its own override, an ancestor's, the workspace's, the
 *  settings' (`agents.subsessions.maxRunning`) or acpmux's default. */
export type SubsessionLimitSource = "session" | "inherited" | "workspace" | "settings" | "default";

/** How many of a chat's sub-sessions run a turn at once (acpmux `subsessionLimits.maxRunning`,
 *  1 to 1000), and acpmux's own count of those running and waiting for a slot when it read them. */
export type SubsessionLimits = {
  maxRunning: number;
  maxRunningSource?: SubsessionLimitSource;
  running?: number;
  queued?: number;
};

/// Claude Code's /context breakdown as acpmux keeps it (claude_stdio `context_breakdown`).
export type AcpmuxContextBreakdown = {
  /// `id` is Claude Code's (`system_prompt`, `mcp_tools_deferred`, `free_space`, ...) when it names
  /// one; `name` is its display name.
  categories: {
    id?: string;
    name: string;
    tokens: number;
    kind: "used" | "free" | "buffer" | "deferred";
  }[];
  memoryFiles: { path: string; type: string; tokens: number }[];
  mcpTools: { name: string; serverName: string; tokens: number }[];
  /// Only when skills take context.
  skills?: { name: string; tokens: number }[];
  totalTokens: number;
  maxTokens: number;
};

/// A Claude Code chat's plan usage limits as acpmux reports them (claude_stdio `usage_limits`):
/// `id` is `session` (5 hours), `weekly`, `weekly_opus` or `weekly_sonnet` (Codex's other lengths are
/// their minutes, `60m`, or their slot, `primary`); `usedPercent` is 0-100; `resetsAt` is unix
/// seconds, only when the harness said when the window resets; `windowMins` is the window's length
/// when Codex named it. `plan` (Codex's `planType`, such as `pro`) and `credits` (the balance, or
/// unlimited) only when the harness reported them; Claude Code names neither.
export type AcpmuxUsageLimits = {
  windows: {
    id: string;
    usedPercent: number;
    resetsAt?: number;
    windowMins?: number;
  }[];
  plan?: string;
  credits?: { balance?: string; unlimited?: boolean };
};

/// Optional Labs workflow payload. acpmux does not emit this field yet; keeping the wire shape
/// here gives the future event a typed adapter seam without deriving workflow state from rows.
export type AcpmuxWorkflowWire = {
  id: string;
  title: string;
  state: "pending" | "running" | "paused" | "completed" | "failed";
  phase?: string;
  phases?: {
    id: string;
    name: string;
    state: "pending" | "running" | "completed" | "failed";
    agentIds?: string[];
  }[];
  agents?: {
    id: string;
    name: string;
    state: "pending" | "running" | "waiting" | "completed" | "failed";
    doing?: string;
    tokens?: number;
    transcriptRowId?: string;
  }[];
  elapsedMs?: number;
  tokens?: number;
  large?: boolean;
  selectedAgentId?: string;
};

/** Why a tab's chat is missing: the daemon's list lacked it when the pane opened
 * (`notListedAtOpen`), or it left the list while the pane showed it (`leftListWhileShown`). */
export type MissingSessionReason = "notListedAtOpen" | "leftListWhileShown";

/// Whether the pane's link to acpmux is up. A snapshot's `connection` names why the client emitted
/// it ("connected", "session changed", a streamed event's kind, "failed" for a refused request on
/// an open socket), not the link's state: only a lost ("disconnected") or opening ("connecting…")
/// connection is down. Never compare it with "connected" to ask whether the link is up.
export function linkUp(connection: string): boolean {
  return connection !== "disconnected" && !connection.startsWith("connecting");
}

/** Incremental journal attribution for the Session Info "Where the time went" chart. */
export type AcpmuxTimeCategory = {
  id: string;
  wallMs: number;
  tokens?: number;
};
export type AcpmuxTimeSpan = {
  turnSeq: number;
  turnId?: string;
  category: string;
  startAt: number;
  endAt: number;
  tokens?: number;
  /** Measured usage for the whole turn; phase/category attribution may be unavailable. */
  turnTokens?: number;
};
export type AcpmuxTimeBreakdown = {
  totalMs: number;
  totalTokens?: number;
  tokensComplete: boolean;
  categories: AcpmuxTimeCategory[];
  spans: AcpmuxTimeSpan[];
};

export type AcpmuxSnapshot = {
  type: "snapshot";
  /// The one-shot admission warning of an Auto start: with no `sessionId` while `session/new` waits
  /// for a machine being added (`_acpmux/admission_waiting`), then the one `session/new` returned,
  /// while its chat is starting.
  startupAdmission?: { sessionId?: string; scalingUp: true };
  /** The selected chat's daemon-owned retry, including the last automatic attempt. */
  autoResume?: AutoResumeStatus;
  /** The chat acpmux holds for capacity (hub/capacity_wait.rs): one calm state, never red. */
  capacityWait?: CapacityWaitState;
  protocolVersion: number;
  rows: AcpmuxRow[];
  /// Reply row ids removed by explicit message_superseded events; refresh retention must not restore them.
  supersededRows?: string[];
  /// Each subagent's own view by subagent id: its rows, opened from its line in a group
  /// (subagents/childRows.ts).
  subagentViews?: Record<string, AcpmuxRow[]>;
  /// Agent ids whose usage/progress changed in this snapshot. This lets rows subscribe without
  /// rescanning every agent on a token update.
  subagentProgress?: Record<
    string,
    {
      agents?: {
        done: number;
        started: number;
        failed?: number;
        queued?: number;
      };
      tokens?: number;
      toolUses?: number;
    }
  >;
  /// Monotonic structural revision for the subagent list; usage-only updates do not change it.
  subagentStructureVersion?: number;
  sessions: AcpmuxSessionEntry[];
  browserWorkspaces?: BrowserWorkspaces;
  /// Who else has a shared chat open and who of them types (multiplayer/participants.ts).
  presence?: ChatPresence;
  /// A Fork Conversation acpmux has not answered yet, since when (Unix ms): the line above the
  /// composer with its Cancel (ForkPendingLine.tsx).
  forkPending?: { since: number };
  /// Present only when an acpmux workflow event is available; the Labs surface stays hidden otherwise.
  workflow?: AcpmuxWorkflowWire;
  /** Connected peer names advertised by the acpmux daemon, including peers without chats yet. */
  peers?: string[];
  /// Each peer's transport by name: `ssh` for an `ssh://` peer, `cloud` for any other (environments.ts).
  peerKinds?: Record<string, "ssh" | "cloud">;
  /// Whether each peer is connected, as `_acpmux/status` last said (environments.ts).
  peerConnected?: Record<string, boolean>;
  /// Each peer's link state (`connected`, `reconnecting`, …), as `_acpmux/status` last said (environments.ts).
  peerStates?: Record<string, string>;
  /// Each peer's whole link state (`link`, `cause`, `nextRetryAt`, …) as acpmux said it, from a daemon
  /// that sends it (linkState.ts); the composer's machine row draws it (peerLink.ts).
  peerLinks?: Record<string, PeerLinkDetail>;
  /// Each peer's cached one-minute resource reading, as bounded by the pane's native status filter.
  peerResources?: Record<string, MachineResources>;
  /// The open chat is a fork: the seq of its `forked` event, where the copied history ends (cx-ncc.61).
  forkedAtSeq?: number;
  /// The chat's held surge, its newest snapshot (conversation/surgeHold.ts): Session Info's Background
  /// tasks row (session-info/agentSide.ts).
  surge?: SurgeHold;
  summary?: {
    sessionId: string;
    cwd?: string;
    turnCount?: number;
    /// Context-window tokens used of the session's window, from the agent's last usage update, and
    /// `setup`, the part the agent took before the conversation (its system prompt, tools and
    /// memory), when the harness reports it (`_meta.acpmux.setup`).
    usage?: {
      used: number;
      size: number;
      setup?: number;
      /// When the chat's prompt cache lapses (unix ms; acpmux claude_stdio/prompt_cache.rs).
      cacheExpiresAt?: number;
    };
    /// What the context holds by category, as Claude Code's /context said after the last turn
    /// (acpmux `contextBreakdown`); unset for other harnesses. Each list holds at most 50 rows,
    /// the largest.
    contextBreakdown?: AcpmuxContextBreakdown;
    /// What the session spends (acpmux `usageStats`, usageStats.ts): 24h tokens and cost, its
    /// autocompact cap, its subagents. Unset while the harness has no readable transcript.
    usageStats?: SessionUsageStats;
    /// Incremental per-turn wall-time and token attribution for the Session Info timeline.
    timeBreakdown?: AcpmuxTimeBreakdown;
    host?: string;
    /// What Claude Code's last init line said the chat runs on: its version, model id, route and
    /// folder, for Session Info's Environment and the `/status` card.
    sessionStart?: AcpmuxSessionStart;
    /// The machine acpmux runs the chat on (acpmux `machine`), for the `/status` card only:
    /// unlike `host` it is set for a local chat too.
    machine?: string;
    peer?: string;
    hostKind?: "local" | "cloud";
    /// The composer footer's status dot items and quiet facts, as acpmux decided them
    /// (`composerStatus`, acpmux `protocol/composer_status.rs`); absent from an older acpmux. Read
    /// through composerStatusModel.ts `readComposerStatus`, which takes a null field as absent.
    composerStatus?: ComposerStatus;
    /// Where an Auto chat stands (acpmux `autoSession`, autoSession/autoSession.ts): unset from an
    /// acpmux without Auto, and the pane then offers and draws nothing of it.
    autoSession?: AutoSession;
    /// The folders the chat sees beside its own (acpmux `additionalDirectories`, cmux#32811).
    additionalDirectories?: readonly string[];
    branch?: string;
    worktree?: string;
    title?: string;
    name?: string;
    /** The name it was given (acpmux `displayName`, "Mango"): the header shows it first. */
    displayName?: string;
    /** Its names before its renames, oldest first (acpmux `formerNames`): the header's "fka". */
    formerNames?: string[];
    /** The icon it set (acpmux `icon`), drawn in place of its harness mark. */
    icon?: HarnessIconSpec;
    /** Codex's persisted thread goal, when the harness reported one. */
    goal?: TaskGoal;
    /// The plan the person approved, kept while the agent builds it (acpmux `approvedPlan`,
    /// approvedPlan.ts). Unset until a plan approval is answered with an allow.
    approvedPlan?: ApprovedPlan;
    harness?: string;
    /// The harness family acpmux files the session under (`codex`, `opencode`, ...), when it says.
    family?: string;
    model?: string;
    /// Harness-reported metadata used by `/status`; values must be labels, never credentials.
    agentInfo?: Record<string, unknown>;
    authSource?: string;
    baseUrl?: string;
    route?: string;
    settingsSources?: unknown;
    /// acpmux's structured limits, or a harness's own text for them.
    usageLimits?: AcpmuxUsageLimits | string;
    /// False when acpmux knows the sign-in has no plan usage limits (an API key, a cloud
    /// provider): the `/status` card hides the row. Unset: they apply, reported or not yet.
    usageLimitsApply?: boolean;
    /// The model the agent last reported, when the pane draws a pick (`model`) it has not
    /// confirmed yet (harnessSwitch.ts). Unset otherwise: `model` is what it reported.
    confirmedModel?: string;
    effort?: string;
    /// ACP's: `audio` is a harness that takes voice input (the mic sends its recording).
    promptCapabilities?: { image?: boolean; audio?: boolean };
    /// The agent takes a prompt mid-turn (acpmux `steering`); without it a steer stops the turn.
    steering?: boolean;
    /// acpmux's Ctrl-B (`_acpmux/process/background`) moves its running work: a Claude Code
    /// chat, whatever its harness is named (acpmux `backgroundsWork`).
    backgroundsWork?: boolean;
    /// A turn failed: the queued prompts wait until the user resumes the queue (acpmux `queuePaused`).
    queuePaused?: boolean;
    /// The family (`claude`, `codex`) of a conversation another app runs that this chat only shows
    /// (acpmux `watching`): no prompt goes until the user takes it over.
    watching?: string;
    /// The harness's own session id for the conversation (Claude Code's, Codex's thread id), when
    /// acpmux knows it: Move to Terminal resumes it there (header/terminalMoveRow.ts).
    agentSessionId?: string;
    /// A watched Claude or Codex desktop session acpmux delivers replies into (`bridgedWatch`): a reply goes
    /// to the app and takes nothing over.
    bridged?: boolean;
    /// A chat handed to a cmux terminal (`terminalWatch`): the terminal and the chat are two live views of one
    /// session, so the chat takes prompts (into the terminal's harness) and shows no View Only banner.
    terminal?: boolean;
    /// The MCP servers the harness says it loaded (acpmux `mcpServers`, from Claude Code's
    /// system/init); unset when it reports none (every ACP harness).
    mcpServers?: { name: string; status: "connected" | "failed" | "pending" }[];
    /// How many of the chats its agent started run a turn at once (acpmux `subsessionLimits`, from the attach reply's detail
    /// and its `limits` records); unset from an acpmux without the limit.
    subsessionLimits?: SubsessionLimits;
    status?: string;
    /** Existing daemon silence signal; no client-side threshold or timer. */
    stalledSince?: number;
    loopEpisode?: {
      episodeId: number;
      since: number;
      count: number;
      diagnosis: string;
      hint: string;
    };
    enforcement?: Enforcement;
    modes?: {
      availableModes: { id: string; name?: string; description?: string }[];
      currentModeId?: string;
    };
    configOptions?: {
      id: string;
      name?: string;
      category?: string;
      currentValue?: string;
      options: { value: string; name?: string; description?: string }[];
    }[];
    /// The chat's tools (acpmux `tools`, cx-thur3) and whether `_acpmux/set_tools` can change them.
    tools?: ChatTool[];
    toolsMutable?: boolean;
  };
  connection: string;
  /** The first request that crossed its progress threshold while the socket stayed open. */
  daemonWaitingSince?: number;
  /// The origin acpmux names for this connection in `initialize` (`_meta.acpmux.origin`):
  /// `remote` gets its Web rules (no Codex or opencode, remoteEditing.ts); `unknown` is an older
  /// acpmux that names none. Unset in a snapshot no client built (fixtures).
  origin?: "local" | "remote" | "peer" | "unknown";
  /// The connection takes the person's folder trust answer although it is `remote`: the app's
  /// wire to a chat on another machine lists `acp.trust.set` (cx-1bhjj); acpmux never lists it,
  /// so a remote browser still cannot answer.
  answersTrust?: boolean;
  /// The connection is the app's wire to a chat on the person's OWN Cloud machine: the Cloud API
  /// said the signed-in caller owns it (`vmKind: "owner"`), and that machine's daemon checks the
  /// same answer again at each start. A disposable VM of the person's own is its own boundary, so
  /// Codex and opencode chats send there (remoteEditing.ts). Never set for a team machine,
  /// another person's computer or a remote browser.
  ownerCloud?: boolean;
  /// Composer only: this new chat's first send starts it on a Cloud machine (Cloud picked as where
  /// it runs, `cloud.startChat`), not on this Mac. That machine decides the chat's start mode.
  startsOnCloud?: true;
  /// Composer only, with `startsOnCloud`: the permission mode picked for that Cloud start
  /// (cloudModePick.ts), which the send carries (`CloudStart.mode`).
  cloudStartMode?: string;
  /// acpmux reconnects a Claude Code chat's failed MCP server for this connection: its `initialize`
  /// lists `_acpmux/mcp/reconnect` (an older acpmux does not), so Session Info's Connectors offer
  /// Reconnect.
  reconnectsMcp?: boolean;
  /// The client has read the daemon's chat list once: `sessions` is the daemon's, not the empty
  /// list a connection starts with (newtab/chatStore.ts publishes only such a list).
  listedSessions?: true;
  /// With `listedSessions`: `sessions` is only the newest window of the daemon's list (the first
  /// `SESSION_PAGE` rows and their changes; sessionPages.ts `holdsAll` false), not the whole list,
  /// so it says nothing about the chats older than its oldest row (newtab/chatStore.ts merges it).
  sessionsWindowed?: true;
  /// This page drew the chat from a kept tail (tailCache.ts) rather than from acpmux's attach, so
  /// its rows were on screen in the frame the open landed on. The pane's host reads it in the
  /// page's first-paint report: a chat read cold fades in over the loading state, this one shows
  /// in one frame (AgentPaneView+Loading.swift).
  drewKeptTail?: true;
  /// The chat on screen was opened from acpmux's settled view of it (`settled-attach-v1`,
  /// cmuxterm-hq#9655): where that frame ends and the turn ends a fork can go through. The page tells
  /// the host once the frame is drawn (`pane.painted` with `settled: true`).
  settled?: { lastSeq: number; forkSeqs: readonly number[] };
  /// The selected peer chat is drawn from the Mac's copy of it (peerCopy.ts), not yet read from its
  /// machine; `offline` while that machine does not answer, when the pane marks it possibly stale.
  peerCopy?: import("./peerCopy").PeerCopyState;
  /// The selected chat's rows are in this snapshot (its attach page, or a kept tail), or none is
  /// selected: the first-paint report may say the chat is on screen (App.tsx `chatDrawn`).
  chatRead?: true;
  /// acpmux's attach of the selected chat answered: its rows and its running turn are acpmux's,
  /// not only a kept tail's (which keeps rows, not whether a turn runs). App.tsx holds the last
  /// launch's copy for it while that copy shows a running turn the tail cannot draw.
  chatAttached?: true;
  sessionId?: string;
  isWorking: boolean;
  /// The current turn's daemon start time, in the session clock. Unset when no turn is running.
  turnStartedAtMs?: number;
  /**
   * The agent's guess at the person's next prompt (acpmux's `prompt_suggestion` update, Claude
   * Code's prompt suggestions), for the composer's ghost text: set only between turns, while no
   * newer prompt or turn start came after it, and never during a replay. `seq` is its record's, so
   * the composer can tell one suggestion from the next. An older acpmux never sends one.
   */
  promptSuggestion?: { text: string; seq: number };
  /// How many of the shown chat's turns this client saw end: it only grows, so an end is seen even
  /// when React draws a turn's start and end as one render (App.tsx `pane.tabState`).
  turnsEnded?: number;
  /// The running turn's output tokens so far, its model calls' generated tokens added up,
  /// subagents' included (direct.ts `turnTokens`); unset when the harness does not report each
  /// call or the client missed the turn's start.
  turnTokens?: number;
  /// The turn's output (`turnTokens`) beside what its calls read, when every call this turn named
  /// its input and output (`inputTokens`, `cachedReadTokens`, `cachedWriteTokens`, `outputTokens`,
  /// claude_stdio/inbound.rs); unset otherwise.
  turnTokenSplit?: TurnTokenSplit;
  /// Stop (or Esc) was sent and the running turn has not ended yet (direct.ts `cancel`): Stop
  /// turns and says it is stopping, so a press never looks like it did nothing.
  stopping?: true;
  /// The prompt the running turn runs, by its root (direct.ts `turnPrompt`): acpmux's continuation
  /// of a cut turn counts as that turn. Unset when no turn runs or its prompt is not known.
  turnPrompt?: string;
  /// This computer's clock minus the session's, for a session on a peer (SSH, Cloud) whose
  /// events carry the peer's clock; unset when they share a clock or it is not known yet.
  clockOffsetMs?: number;
  /// acpmux serves `acp.session.fork` (operations.ts), so a turn can be forked from.
  canFork?: boolean;
  /// acpmux forks a subagent's own context into a chat of its own (`acp.session.fork.subagent.v1`):
  /// a subagent's chips offer Fork with <model>… and Fork with <mode>… (SubagentForkChips.tsx).
  canForkSubagent?: true;
  /// The chat's own machine (a Cloud or SSH chat) opens its side chats there: New side chat and
  /// `/side` (direct.ts `sideChatOnMachine`).
  sideChatOnMachine?: true;
  /// acpmux serves the owner's Approve and Decline of a guest's prompt (initialize `queueApproval`).
  queueApproval?: boolean;
  canHandoff?: boolean;
  handoff?: HandoffClientState;
  permissionGroups?: PermissionClientState;
  /// Prompts waiting behind the running turn, in order. `next`: sent now (⌘Return on an agent that
  /// cannot steer): it stops the running turn and runs next, so it reads as a steer, not a queued
  /// prompt (acpmux `queue_order` with `next`).
  queue: QueuedPrompt[];
  /// The latest prompts withdrawn from the queue (acpmux `queue_removed`), newest last: they left it
  /// without running, so no row comes for them (VirtualTranscript keeps no room for one).
  queueWithdrawn?: readonly string[];
  /// The rows of the steers the agent has not read yet (direct.ts `waitingSteers`), oldest first, only
  /// while two or more wait: the transcript draws other sessions' among them as one card.
  waitingSteers?: readonly string[];
  /// While two or more steers wait: the row of the person's newest one, the only one that offers
  /// Send now (direct.ts `newestOwnSteer`, conversation/PendingSteer.tsx).
  newestOwnSteer?: string;
  /// The mark of "New since you looked" drawn in the rows (`SINCE_DIVIDER`, its `key`): Jump to new
  /// follows it.
  sinceKey?: string;
  /// A return placed that line (the chat picked, shown again, the reader back): the view opens at
  /// it, not at the latest message (App.tsx). Unset for the line a scroll up placed.
  sinceLands?: true;
  permission?: AcpmuxPermission;
  /// How many more asks wait behind `permission`, answered one at a time; absent when none do.
  permissionsWaiting?: number;
  /// Those asks, in the order they come next (the composer hat steps to each, question/hatModel.ts).
  permissionsQueued?: readonly AcpmuxPermission[];
  secret?: AcpmuxSecretAsk;
  /// Every chat's open permission requests, for the Needs you list (needsYou/asks.ts); the same
  /// array until one comes or goes.
  asks?: WatchedAsk[];
  /// The grouped ones, which Needs you leaves to their chat's card: the chat above a sub-session
  /// draws them (subagents/childAsks.ts).
  groupedAsks?: WatchedAsk[];
  /** `unavailable`: why acpmux will not run that model (its backend refused it), or that harness
   * (its launcher check or its model probe failed). */
  catalog: {
    id: string;
    name: string;
    models: AcpmuxCatalogModel[];
    /** The harness's own model-menu ids, in its order; absent until it reports a list. */
    topModels?: string[];
    /** The configured harness login command, when its profile declares one. */
    auth?: { login?: string };
    unavailable?: string;
    /** `unavailable` is only a failed model probe (a timeout, a rate limit): the harness may run. */
    probeFailed?: boolean;
    /** acpmux's `_acpmux/harnesses` named no default harness (default_harness.rs): New Tab starts
     * on no agent until one is picked. */
    noDefault?: true;
    pickable?: boolean;
    /** The declared launcher or route kind; routers cannot represent a harness family. */
    kind?: string;
    /** acpmux's family for the harness (`_acpmux/harnesses` `family`): joins it to a catalog harness. */
    family?: string;
    /** `_acpmux/harnesses` `icon`: the profile's own icon value (a brand id, an emoji, an SF
     * Symbol name or a file path). Draw `iconSpec`, not this. */
    icon?: string;
    /** `_acpmux/harnesses` `iconSpec`: the one icon acpmux resolved for the harness. */
    iconSpec?: HarnessIconSpec;
    /** Its chats report no permission modes (`_acpmux/harnesses` `reported`, permissionModes.ts):
     * Pi's ACP modes only copy its thinking levels. Absent while unknown. */
    modeless?: true;
    /** Its chats, or its startup probe, report permission modes (`_acpmux/harnesses` `reported`,
     * permissionModes.ts). Absent while unknown or none. */
    reportsModes?: true;
    /** Those modes (`_acpmux/harnesses` `reported.modes`): a new chat's Mode menu before any chat of
     * the harness is open here. Present with `reportsModes`. */
    reportedModes?: { id: string; name?: string; description?: string }[];
    /** The mode the harness's own `session/new` starts a chat in when acpmux sets none
     * (`reported.startModeId`, its startup probe's answer): Antigravity's Default. */
    ownStartMode?: string;
    /** `_acpmux/harnesses` `start`: the model and effort acpmux starts a new chat here on (the
     * person's saved pick, else the catalog's default; acpmux start_defaults.rs). */
    start?: {
      model?: string;
      effort?: string;
      modelSource?: StartSource;
      effortSource?: StartSource;
    };
    /** A profile from the chat's folder (`<folder>/.cmux/harnesses/<id>.toml`), with its state:
     * enabled, waiting for the user's Enable, waiting for the folder's Trust answer, or broken
     * (`diagnostic`: its first problem). Global harnesses have none. */
    folder?: {
      folder: string;
      path?: string;
      state: "enabled" | "needs-enable" | "needs-trust" | "error";
      diagnostic?: string;
    };
  }[];
  canLoadOlder: boolean;
  /**
   * The chat's prompts older than the rows it holds, from acpmux's prompt index (one read at open):
   * the thread rail lays out every turn from the first frame, and pages loaded later fill them in
   * instead of adding ticks. Each is a `user` row (`user-<seq>`, its promptId and the start of its
   * text) that opens a turn. Absent while unread, and for a chat with no older history.
   */
  earlierPrompts?: PromptHeads;
  /**
   * The chat's prompt count from its summary (`turnCount`), while the pane does not hold every prompt
   * yet (the prompt index has not answered, or the daemon has none) and older history is left: the
   * thread rail starts at the height that many prompts take. Absent once `earlierPrompts` is read.
   */
  promptCount?: number;
  /** The oldest event seq the pane holds: it moves with each older read, even one that drew no row. */
  historyFrom?: number;
  /**
   * The time of the oldest event the pane holds. A row older than it left with the records a chat left open let go
   * of (direct.ts `shedOlderHeld`), so the view does not keep it on screen (conversation/turns.ts
   * `retainVisibleReplies`).
   */
  heldFromAt?: number;
  /**
   * The chat goes on past the rows: a reader scrolled far up holds a window of the chat, whose newest records
   * are read again as the view nears the rows' end (direct.ts `loadNewer`), or with the newest page when the
   * reader goes to the latest message (`returnToLatest`). Absent while the rows reach the chat's end.
   */
  canLoadNewer?: boolean;
  /** The newest event seq the pane holds while `canLoadNewer`: it moves with each newer read. */
  historyThrough?: number;
  /**
   * The chat's prompts newer than the rows while `canLoadNewer`, as `earlierPrompts` are for older ones: the
   * thread rail keeps their ticks after the held ones.
   */
  laterPrompts?: PromptHeads;
  /** The agent's slash commands, for the composer's `/` menu. */
  commands?: SlashCommand[];
  /** A harness switch the pane draws ahead of acpmux (harnessSwitch.ts): starting, applying to
   * the next turn while one streams (deferred), or failed with acpmux's reason. */
  switching?: {
    harness: string;
    name: string;
    phase: "starting" | "deferred" | "failed";
    error?: string;
    /// The start refusal's code, for the failed card's one-click way out (startRefusal.ts).
    code?: string;
    /// `agent_session.sign_in_required` for a sign-in that expired (`errorKind` `auth.expired`).
    signInExpired?: true;
    /// What actually failed, in one line, for the failed card's Details (startFailure.ts).
    cause?: string;
  };
  /** A `cmux://session/<id>` link named this session and the daemon has none: the pane says so
   * instead of showing another chat. Unset once a session is selected. */
  missingSession?: string;
  /** Why `missingSession` is not here: deleted, or on a machine that is not connected (or still
   * connecting, which the pane shows as loading). chatUnavailable.ts. */
  unavailable?: ChatUnavailable;
  /** Why `missingSession` is set (the pane reports each one to the app's log, `chat.missing`). */
  missingReason?: MissingSessionReason;
  /** The outside chat this pane adopts is still open in another process (acpmux refused with
   * `adopt.live`): the pane offers Open Anyway, and Fork It when the harness can fork. `command`
   * is the process that holds it, when acpmux found one. Unset once a choice is sent. */
  liveChat?: { canFork: boolean; command?: string };
  /** Take Over of a watched chat was refused because the other app still runs it (`adopt.live`):
   * the pane offers Open Anyway, and Fork It when the harness can fork. */
  liveTakeOver?: { canFork: boolean; command?: string };
};

export type PreparedRow = {
  text: string;
  /// The row's markdown blocks, as the estimator measures them (conversation/Markdown.tsx draws them).
  blocks: Token[];
  /// A growing row (a streaming reply) lexes once the text before its last safe block boundary
  /// (lastBlockBoundary): those blocks and where they end. Only the text after it is lexed again.
  closedBlocks: Token[];
  closedEnd: number;
  /// The characters the last update lexed (tests, perf).
  lexedLength: number;
  /// The blocks the last update measured (tests, perf): the ones closed since, and the tail's.
  measuredBlocks?: number;
  /// Measured text by its source, kept across a streaming row's versions; null where it can't be measured.
  prepared: Map<string, PreparedText | null>;
  /// A plain user row's final line height, keyed by text, font, line height and width.
  plainHeight?: { key: string; height: number };
  /// The summed heights of the first `count` closed blocks (`last` the last of them), at the width
  /// and metrics `key` names, and the prepared texts they read: a streaming reply measures only
  /// the blocks that closed since and its tail, never every block again for each delta.
  closedHeight?: { key: string; count: number; last: Token | undefined; height: number; used: Set<string> };
};

export type ConversationLayout = {
  tops: Float64Array;
  heights: Float64Array;
  totalHeight: number;
  /// Container-owned space before each content row; hover-only footers own no space.
  gaps?: Float64Array;
  /// Each row's kind for the gap rules (transcriptGrid.ts rowMark): prompts, messages and the live
  /// line, so placement after DOM-empty rows are skipped picks the same gaps.
  marks?: Uint8Array;
  /// The composer gap under the last drawn row (transcriptGrid.ts tailGap).
  tailGap?: number;
  /// The interface scale the gaps were placed at (transcriptGrid.ts gridScale).
  scale?: number;
  /// The transcript look's gap factor they were placed at (chatDisplay.ts transcriptGapScale), when not 1.
  gapScale?: number;
  /// Over a floating stack, the band under the last drawn row before the rest gap: a trailing turn
  /// footer's action row lies there (transcriptGrid.ts restBand).
  restBand?: number;
  /// Room above the first row for history not loaded yet (conversation/olderReserve.ts): every top
  /// and the total include it. Absent is 0.
  origin?: number;
  /// Some row keeps its height from another width (layoutConversation `near`), so the tops below it
  /// are not this width's: nothing may keep them as measured (transcriptHeights.ts keepPromptTops).
  remembered?: true;
  /// A cold open's layout (layoutConversation `roughAbove`): rows above the measured end hold rough
  /// heights until the transcript lays the chat out whole, after the first paint. Also `remembered`.
  rough?: true;
};

/// Metrics of conversation/conversation.css (`--cv-font-size`, `--cv-line-height`, `.cv-*`): the
/// text font, its line and the code sizes follow the user's chat look (chatDisplay.ts), 14px
/// system-ui on 22.75px lines and 12px code on 20px lines by default.
/// While a reply or a prompt is measured, its own text (a transcript look's `reply.*` and
/// `userMessage.font*`, chatDisplay.ts ChatMetrics `reply` and `prompt`; conversation.css rebinds the
/// same font, size and line inside `.cv-reply` and `.cv-user__bubble`).
const metrics = (): ChatMetrics => {
  const base = currentChatMetrics();
  if (measuringPart === null) return base;
  // A reply's prose measures in `replyMeasureFont` (proseFont); its line is the reply's own.
  if (measuringPart === "reply") return { ...base, lineHeight: base.reply.lineHeight };
  return { ...base, measureFont: base.prompt.measureFont, lineHeight: base.prompt.lineHeight };
};
/// Which part's row is being measured: the agent's reply, whose prose a font pack or a look can set
/// apart (chatDisplay.ts `replyMeasureFont`, conversation.css `.cv-reply`), or the person's prompt;
/// layoutConversation sets it around each row.
let measuringPart: "reply" | "prompt" | null = null;
/// The canvas font of the text being measured: the reply's while a reply is, else the chat's (or
/// the prompt's).
const proseFont = () => (measuringPart === "reply" ? metrics().replyMeasureFont : metrics().measureFont);
/// Codex's user bubble keeps 10px padding on each side, at the chat's density text scale (`.cv-user__bubble`:
/// the grid's Interface Size scale times the bubble's own, which together are the text scale).
/// A transcript look's padding (conversation/transcriptLook.ts userBubbleBox) replaces the 10 per side.
const userBubblePadding = () =>
  2 * (userBubbleBox(chatDisplay().transcriptLook).padBlock ?? 2.5 * gridLength("base")) * chatDensityTextScale();
/// The status line under a queued prompt (`.cv-user__status`: 4px above a 16px line).
const USER_STATUS_HEIGHT = 20;
/// The transcript's rhythm (`--cv-meta-gap`, `--cv-meta-row`, `--cv-message-gap` and `--cv-turn-gap`
/// in conversation/conversation.css): a meta row 4px under its message on a 24px line, 8px between
/// messages, 16px between turns (the paragraph gap plus a small separator).
const META_GAP = 0;
/// Grid lengths scale with the Interface Size as their CSS tokens do (desktop.css `calc(Npx *
/// var(--cmux-interface-scale, 1))`). layoutConversation sets the factor once per pass, so the row
/// estimates match the drawn rows at any size.
let chromeScale = 1;
const META_ROW_PT = gridLength("transcript-action-control");
const metaRow = () => META_ROW_PT * chromeScale;
/// A reply footer's line: its 32 buttons (transcriptGrid.ts `TRANSCRIPT_FOOTER_CONTROL`).
const footerRow = () => TRANSCRIPT_FOOTER_CONTROL * chromeScale;
/// The Connect GitHub card above a footer: its line and button, in the failure card's padding.
const GITHUB_CONNECT_CARD = 56;
const MESSAGE_GAP = 0;
/// A collapsed sub-session disclosure (subagents/AgentCard.css): one 26px line plus its transcript
/// rhythm margins. Expanded Markdown is measured by the virtual transcript after the reader opens it.
const cardHeight = (_state: string) => 32;

/// A sub-session reply under its card (SubsessionCallCard.tsx `Cut`): up to three 16px detail lines of
/// about 60 characters, and the toggle once it is cut.
function replyHeight(reply: string): number {
  const lines = reply.split("\n").reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / 60)), 0);
  return Math.min(lines, 3) * 16 + (lines > 3 ? 20 : 0);
}

/// The compact tool run rhythm (`conversation.css --cv-tool-row-height` and its run bottom gap).
const TOOL_RUN_TOP = 0;
/// A step row: a tool run, the live run line over its work, or a one-line row (transcriptGrid.ts
/// MARK_STEP).
const isStepRow = (row: AcpmuxRow) =>
  row.kind === "activity" ||
  row.kind === SUBAGENT_ROW ||
  (row.kind === SUBAGENTS && !isRunGroup(row)) ||
  isWorkedLine(row) ||
  isLineRow(row);
/// The running turn's live line, drawn as its last row (`below`, conversation/turns.ts).
export const isLiveLine = (row: AcpmuxRow) => row.below === true && (row.kind === WORKING || row.kind === THINKING);
/// The running turn's line as its last row (`below`) right under a step row or a status row ("Subagent
/// finished", "Scheduled check", a compaction): its box and the gap over it are transcriptGrid.ts's
/// (TRANSCRIPT_LIVE_STEP_BOX, MARK_LIVE_STEP; `.acpmux-row--below.acpmux-row--after-step`); the waiting
/// messages' head draws over it (pendingMessages.ts `withWaitingRows`). Under a status row it took the footer's
/// slot a block gap away, 55 and 70 from its neighbours (Leo, 2026-11-03: "this is pretty bad
/// spacing and formatting"; design/transcript-spacing.md rule 3).
export const isLiveStep = (row: AcpmuxRow, prev: AcpmuxRow | undefined) =>
  isLiveLine(row) && prev !== undefined && (isStepRow(prev) || isStatusRow(prev));
/// A row's kind for the gap rules (transcriptGrid.ts transcriptGap), `prev` the drawn row above it.
/// A live line under a step is MARK_LIVE_STEP, not another step, which would sit flush.
/// `above`, the drawn row over `prev`, tells a received line under its own turn's "Working for" apart
/// from one that opens its turn over that line (`headsIncomingTurn`).
export const gridMark = (row: AcpmuxRow, prev: AcpmuxRow | undefined, above?: AcpmuxRow): number =>
  (wokenUnderFooter(row, prev) && wokenGapLook() === "tail" ? MARK_STATUS : rowGridMark(row, prev)) |
  (opensBackgroundTurn(row, prev) ? MARK_OPENS_TURN : 0) |
  (headsIncomingTurn(row, prev, above) ? MARK_HEADS_TURN : 0) |
  (topsIncomingTurn(row, prev) ? MARK_TOPS_TURN : 0);
/// Whether `row` is the top of a turn another agent's line opened, right under the turn before's last
/// reply (transcriptGrid.ts MARK_TOPS_TURN): that notice or message (not a steer into the running turn,
/// which is that turn's own), or the turn's "Working for" / "Worked for" line drawn over it. A person's
/// prompt opens its turn under its own mark, so "Working for" is under a reply only when another
/// agent's line opened the turn. O(1).
const topsIncomingTurn = (row: AcpmuxRow, prev: AcpmuxRow | undefined): boolean =>
  prev !== undefined &&
  prev.kind === "assistant" &&
  (prev.text?.length ?? 0) > 0 &&
  (isWorkedLine(row) ||
    (row.kind === "user" &&
      (row.incoming !== undefined || row.received !== undefined) &&
      row.incoming?.kind !== "hidden" &&
      row.steer === undefined));
/// Whether `row` heads a turn another agent's line opened (transcriptGrid.ts MARK_HEADS_TURN): the
/// running turn's live line right under that notice or message, or the notice or message itself right
/// under the closed "Worked for" line of a turn that ended on work (its footer draws nothing), where it
/// stood flush as that turn's last step. Under an opened "Worked for" the message is that fold's own
/// entry (the message that opened its turn, folded in as its first entry, turns.ts `foldsPrompt`, or one
/// received mid-turn): an activity row, flush as a tool row is there. With the head gap it stood 16
/// under the fold's rule, over its "Sent to" (Leo, 2026-11-22 08:29Z, ST-02: "this one seems to have an
/// unnecessary gap due to being a recieved message. these aren't categorized properly under our tool
/// call formatting"; sim scenario `received-sent-as-activity`). O(1).
/// Neither when the line sits under its own turn's "Working for" / "Worked for" (`worked-<its id>`,
/// conversation/turns.ts): that line already heads the turn, and the received line is one step of
/// its work, flush under it on the tool rows' pitch, with the live line a step's gap under it. The
/// head gap there drew it as a prompt, 16 under the turn's line and 16 over "Thinking" (Leo,
/// 2026-11-22: "sometimes you get these way-too-big gaps. i think it's the message recieving not
/// properly getting treated like the tool call ish thing it should be and instead as if it were a
/// message?"; sim/scenarios.ts `incoming-message-turn`, rule (d)).
const headsIncomingTurn = (row: AcpmuxRow, prev: AcpmuxRow | undefined, above?: AcpmuxRow): boolean =>
  prev !== undefined &&
  (prev.kind === "user"
    ? isLiveLine(row) && isStatusRow(prev) && !isOwnTurnLine(above, prev)
    : prev.kind === "worked" &&
      prev.foldOpen !== true &&
      row.kind === "user" &&
      isStatusRow(row) &&
      !(prev.turnPhase === "running" && isOwnTurnLine(prev, row)));
/// Under its own turn's ended, closed "Worked for" the line still opens the next turn: the head gap stays
/// (test/received-sent-activity-gap.test.ts, ST-02); only the running header takes it in as a step.
/// Whether `line` is the "Working for" / "Worked for" line of the turn `user` opened. O(1).
const isOwnTurnLine = (line: AcpmuxRow | undefined, user: AcpmuxRow): boolean =>
  line !== undefined && isWorkedLine(line) && line.id === `${WORKED}-${user.id}`;
/// Whether `row` is the first tool row of a turn the agent ran on its own, right under the footer
/// row of the turn before it: a background task's end woke the agent after that turn ended, and the
/// task's line between them draws nothing (backgroundTurns.ts `drawsBackgroundLine`). O(1).
const wokenUnderFooter = (row: AcpmuxRow, prev: AcpmuxRow | undefined): boolean =>
  row.kind === "activity" &&
  row.inBackground !== undefined &&
  prev !== undefined &&
  prev.inBackground !== row.inBackground &&
  rowMark(prev) === MARK_FOOTER_ROW;
/// How that row stands under the footer (gallery `agent-pane.woken-turn-gap`, `<html data-woken-gap>`):
/// `block`, shipped, the block gap any row under a footer stands; `turn`, the turn gap it stood
/// before; `tail`, the 8 a status line under a footer stands, in the hidden line's place. Read only
/// for such a row, so a layout pass pays nothing for it.
export function wokenGapLook(): "block" | "turn" | "tail" {
  const set = typeof document === "undefined" ? undefined : document.documentElement.dataset.wokenGap;
  return set === "turn" || set === "tail" ? set : "block";
}
/// Whether `row` is the first drawn row of a turn the agent ran on its own that draws as its own
/// turn (a reply or a tool run with no background line over it, backgroundTurns.ts
/// `foldsBackground`): `prev`, the drawn row above, is neither its line nor one of its rows. O(1).
/// Right under "Worked for" it opens nothing: that line is the turn's header and keeps its own room
/// under its rule (transcriptGrid.ts MARK_WORKED), so a turn gap there doubled it (Leo, 2026-11-10:
/// "too much space in between here"). Right under a subagent's start line it opens nothing either:
/// that line says the agent started it, so nothing under it reads as the subagent's words, and the
/// reply keeps the run gap a reply has under any status line, whichever turn it came in (Leo,
/// 2026-11-14: "the spacing after the subagent starting is inconsistent? it grows too big"). Right
/// under a received line (a background task's notice, another agent's message) it opens nothing
/// either: that line is what the agent answers with the turn, its prompt, and a prompt is never
/// tracked as the turn's row (direct.ts), so the run under it took the 32 turn gap where every other
/// line in the group sits flush on the 22 pitch (Leo, 2026-11-16: "why is the background task space
/// after so big"; test/agent-pane-worked-group-pitch-browser.test.ts).
/// A tool row right under the ended turn's footer row opens nothing either (`wokenUnderFooter`): the
/// footer already closes the turn above, and the turn gap over a muted tool row, with no prompt in
/// it, left an empty band the hidden task line seemed to leave behind (Leo, 2026-11-15: "idk it
/// loads funny sometimes"). A reply there keeps the turn gap, as a prompt has.
export const opensBackgroundTurn = (row: AcpmuxRow, prev: AcpmuxRow | undefined): boolean =>
  row.inBackground !== undefined &&
  !(wokenUnderFooter(row, prev) && wokenGapLook() !== "turn") &&
  (row.kind === "activity" || (row.kind === "assistant" && (row.text?.length ?? 0) > 0)) &&
  prev !== undefined &&
  prev.kind !== WORKED &&
  prev.kind !== SUBAGENT_STARTED &&
  !(prev.kind === "user" && !prev.received && isIncomingLine(prev.incoming?.kind)) &&
  prev.inBackground !== row.inBackground &&
  !(prev.kind === BACKGROUND_TURN && prev.background?.id === row.inBackground);
/// A turn's "Worked for" line, or the running turn's "Working for" over its work (turns.ts
/// `shapeLiveTurn`), which keeps its place and room.
const isWorkedLine = (row: AcpmuxRow) => row.kind === WORKED || (row.kind === WORKING && row.below !== true);
const rowGridMark = (row: AcpmuxRow, prev: AcpmuxRow | undefined): number =>
  isWorkedLine(row)
    ? MARK_WORKED
    : isEditCard(row)
      ? MARK_CARD
      : isStepRow(row)
        ? MARK_STEP
        : isLiveStep(row, prev)
          ? MARK_LIVE_STEP
          : isStatusRow(row)
            ? MARK_STATUS
            : rowMark(row);
const LIVE_STEP_EDGE = "+step";
/// One-line activity rows are one row apart top to top (design/chat-transcript.md "One-line row pitch",
/// #29965), `--cv-tool-row-height`: their 22 line and the row air (transcriptGrid.ts ROW_AIR_LOOKS).
/// The room around "Worked for"'s rule (Lucas, 2026-11-07; Leo, 2026-11-09): 4 under its words, 8 over the next row,
/// conversation.css `.cv-worked.has-divider.is-toggle`; no stack gap follows (MARK_WORKED).
const WORKED_GAP_PT = gridLength("gap-foot") + gridLength("gap");
/// Read once per layout pass (layoutConversation). `--cv-tool-row-height` is 22px plus the row air at every
/// Interface Size (conversation.css `:root`), so the row is too: scaled with the grid, a closed group's line was
/// placed 22 × (scale − 1) px too tall at a larger Interface Size.
let lineRowPt = TRANSCRIPT_LINE_ROW;
const toolRowHeight = () => (editsEstimateOn() ? lineRowPt : lineRowPt * chromeScale);
/// Settings > Advanced > Experiments > Expanded Edits Estimate (`experiments.expandedEditsEstimate`, default off;
/// Leo, 2026-11-24, ask-82b08b7ed7: UI changes wait behind a switch). On: an opened edits group is estimated at
/// its files' diff cards (`openEditsBody`) and a tool row at its drawn 22 px line at every Interface Size. Off:
/// the estimates as they were, an edits group at its closed line and a tool row scaled with the grid.
const editsEstimateOn = () => experimentSwitchOn("expandedEditsEstimate");
/// A later part of a running turn's long run keeps the room the run's flex gap gave its first entry
/// (conversation/runParts.ts; conversation.css `.acpmux-row--run-part`).
const runPartTop = (row: AcpmuxRow) => (isRunPart(row) ? gridLength("base") * chromeScale : 0);
const TOOL_RUN_BOTTOM = 0;
/// A one-line row that is not a tool run (`isLineRow`) draws one tool row's line, as a one-call run
/// does (#29965; Leo, 2026-11-01: "doesn't make sense for these to be spaced differently"). On the
/// grid the run adds no frame of its own (the stack's gap is the spacing), so the frame is 0.
const LINE_FRAME = TOOL_RUN_TOP + TOOL_RUN_BOTTOM;
const lineRow = () => LINE_FRAME + toolRowHeight();
/// A message row (a send, SentMessageLine.tsx and AgentMessageRow.tsx; another agent's received line;
/// a folded group's head): one tool row (the single look, conversation/messageLineLook.ts, the
/// default), and in the stacked gallery look its first line's own line under it while it is shut and
/// has one.
const messagePreviewLine = (shown: boolean) =>
  shown && messageLineLook() === "stacked" ? MESSAGE_PREVIEW_LINE_PT * chromeScale : 0;
const messageRowHeight = (preview: boolean) => toolRowHeight() + messagePreviewLine(preview);

/// Ordinary tool rows use the compact rhythm. Notes and specialized MCP cards keep a conservative
/// estimate until their renderer reports its measured height (a wait can contain several three-line replies).
/// A short interim note folded into a run (conversation.css `.cv-tool-note`): its text on 20px
/// lines at the column's width, with the plain status gap above and below it. A note that wraps
/// draws a line per wrap, so it is estimated from its text as a reply is (cmux#31148).
const NOTE_LINE = 20;
/// The room above and below a note (#30400's --cv-note-gap): the run gap, as for any prose by a run,
/// since a run's lines are otherwise flush (conversation.css `.cv-tool-note`).
const noteGap = () => TRANSCRIPT_RUN_GAP * chromeScale;
/// The prepared texts of those notes, for their estimates; cleared past 256, as a row's are.
const notePrepared = new Map<string, PreparedText | null>();
function noteHeight(text: string | undefined, width: number): number {
  if (notePrepared.size > 256) notePrepared.clear();
  // `.cv-tool-note` wraps with the default `white-space: normal`, so a newline or a run of spaces in
  // the note draws as one space: measure the text that way, not as the replies' pre-wrap.
  const flat = text?.replace(/\s+/g, " ").trim();
  const lines = flat ? textHeight(flat, width, notePrepared, undefined, NOTE_LINE) : NOTE_LINE;
  return Math.max(NOTE_LINE, lines) + 2 * noteGap();
}
/// What a step's estimate reads of the reader's open lines (transcriptDisclosureModel.ts,
/// thoughtChoices.ts): the chat (`sessionId`) and, for a thought, its id (`thought`, TurnRows.tsx
/// `${rowId}:thought:<n>`). Without them a step is estimated closed.
type StepState = { sessionId?: string; thought?: string };
function activityStepHeight(item: AcpmuxActivity, width: number, state: StepState = {}): number {
  const tool = item.tool;
  if (!tool) {
    if (item.kind === "note") return noteHeight(item.text, width);
    // A done thought is one tool line (ThoughtRow.tsx, StepThought), over its text once the reader
    // opened it.
    if (isThought(item)) {
      const open = state.thought !== undefined && thoughtChoices.get(state.thought) === true;
      return toolRowHeight() + (open ? openThoughtBody(item.text, width) : 0);
    }
    return 26;
  }
  // A message to another agent (SendMessage, `acpmux send`, a sub-session's `send_message`) is one
  // line on the tool rows' line (AgentMessageRow.tsx), as every one-line row is; opened, an `acpmux
  // send` draws its message under it.
  const message = agentMessage(tool);
  if (message) return messageRowHeight(Boolean(message.text.trim())) + openSendBody(tool, width, state.sessionId);
  const mcp = mcpCall(tool);
  if (mcp) {
    const subsession = subsessionCall(tool, mcp);
    if (!subsession) return 26;
    // Each card (cardHeight), a finished one's reply under it (replyHeight), and the Raw toggle's row.
    if ((subsession.tool === "wait" || subsession.tool === "list") && !subsession.running)
      return Math.max(
        40,
        subsession.sessions.reduce(
          (sum, session) =>
            sum +
            cardHeight(session.state) +
            (session.reply && session.state !== "working" ? replyHeight(session.reply) : 0),
          0,
        ) + toolRowHeight(),
      );
    // A start's card, its doing line while it starts, and its prompt (cut like a reply).
    if (subsession.tool === "start" && subsession.prompt)
      return cardHeight("working") + replyHeight(subsession.prompt) + toolRowHeight();
    // A message sent to a sub-session is the sent-message row a shell `acpmux send` draws
    // (SubsessionCallCard.tsx SentLine, SentMessageLine.tsx): one tool row.
    if (subsession.tool === "send") return messageRowHeight(Boolean(subsession.text.trim()));
    return 40;
  }
  switch (tool.kind) {
    case "execute":
      return toolRowHeight() + openShellBody(tool, width, state.sessionId);
    case "read":
    case "edit":
    case "delete":
    case "move":
    case "fileChange":
    case "search":
      return toolRowHeight();
    // A web call's sources chip draws one 24px line under it, 4px below (WebSources.tsx).
    case "fetch":
      return toolRowHeight() + (webSources(tool).length ? 28 : 0);
    default:
      return 26;
  }
}
/// The steps of a run's `items`, each as `activityStepHeight` estimates it, with its thoughts numbered
/// as ToolRows numbers them (TurnRows.tsx `thoughtIds`): from `thoughts` on, `${rowId}:thought:<n>`.
/// A quiet thought draws nothing (ThoughtRow.tsx), unless it is the last of a live row (`live`), which
/// may still stream.
function stepsHeight(
  items: readonly AcpmuxActivity[],
  width: number,
  sessionId: string | undefined,
  rowId: string,
  thoughts = 0,
  live = false,
): number {
  let height = 0;
  for (const [index, item] of items.entries()) {
    const thought = !item.tool && item.kind !== "note";
    if (thought && isQuietThought(item) && !(live && index === items.length - 1)) {
      thoughts += 1;
      continue;
    }
    const id = thought ? `${rowId}:thought:${thoughts}` : undefined;
    height += activityStepHeight(item, width, { sessionId, thought: id });
    if (thought) thoughts += 1;
  }
  return height;
}

/// The prepared texts of opened thoughts and sent messages, for their estimates; cleared past 256.
const openedPrepared = new Map<string, PreparedText | null>();
/// The tools' text column, where an opened thought's text starts (conversation.css `.cv-thought__body`,
/// `--cv-tool-text-inset`, the grid's transcript text gap).
const TOOL_TEXT_INSET_PT = 24;
/// An opened thought's text under its line (ThoughtRow.tsx): the fold's gap, then its parts on 20px
/// lines from the tools' text column, a title 10px under the text before it (`.cv-thought__title`).
function openThoughtBody(text: string, width: number): number {
  if (openedPrepared.size > 256) openedPrepared.clear();
  const room = Math.max(80, width - TOOL_TEXT_INSET_PT * chromeScale);
  let height = gridLength("base") * chromeScale;
  let after = false;
  for (const part of thoughtParts(text.trim())) {
    const title = "title" in part;
    if (title && after) height += 10;
    height += textHeight(title ? part.title : part.text, room, openedPrepared, undefined, 20);
    after = !title;
  }
  return height;
}

/// A shell call the reader opened (`useRowDisclosure`, ToolRow.tsx): the fold's gap over its Shell
/// card (ShellBlock.tsx, conversation.css `.cv-shell`): 4px above and 8px below it, 12px of padding,
/// the 20px "Shell" label, the command's 18px lines 8px under it (8px and the rule below them), the
/// exit code's 20px line 8px under that when it failed, and its output's 18px lines 8px under that,
/// at most PREVIEW_LINES of them before the box scrolls; a long output's Show all under the box
/// (toolOutputModel.ts `outputTail`, ShellBlock.tsx `OutputMore`), 4px over a 16px detail line, its
/// height the same shown or not. Closed, nothing.
const SHELL_LINE = 18;
function openShellBody(tool: NonNullable<AcpmuxActivity["tool"]>, width: number, sessionId?: string): number {
  if (!tool.command || !disclosureOpen(sessionId, callDisclosureKey(tool.id))) return 0;
  // A monospace cell is about 0.6 of the 12px font; the card's sides take its 12px padding.
  const perLine = Math.max(20, Math.floor((width - 24) / 7.2));
  const command = tool.command
    .trim()
    .split("\n")
    .reduce((sum, line) => sum + Math.max(1, Math.ceil((line.length + 2) / perLine)), 0);
  const output = tool.output?.replace(/\n$/, "") ?? "";
  const lines = output ? Math.min(PREVIEW_LINES, output.split("\n").length) : 0;
  const failed = tool.exitCode !== undefined && tool.exitCode !== 0;
  const card = 12 + 20 + 8 + command * SHELL_LINE + 9 + (failed ? 28 : 0) + (lines ? 8 + lines * SHELL_LINE : 0) + 12;
  const more = output && outputTail(stripAnsi(output)) !== undefined ? gridLength("base") + 16 : 0;
  return (gridLength("base") + 4 + 8 + more) * chromeScale + card;
}

/// An `acpmux send` the reader opened (SentMessageLine.tsx, its `send:` disclosure): the message whole
/// in the card under its line (`.cv-agentmsg__open`, 12px under it and 12px under its end; the card's
/// 12px padding, its text on the replies' lines 62px narrower than the row), and the 24px Raw line
/// under the card. A message with no words to show (a file's) opens to Raw alone, which this leaves
/// out. Closed, nothing.
function openSendBody(
  tool: NonNullable<AcpmuxActivity["tool"]>,
  width: number,
  sessionId?: string,
  sends = acpmuxSendCalls(tool),
): number {
  if (!sends) return 0;
  let height = 0;
  for (const send of sends) {
    if (!send.text?.trim() || !disclosureOpen(sessionId, sendDisclosureKey(tool.id, send.index))) continue;
    if (openedPrepared.size > 256) openedPrepared.clear();
    height += 12 + 24 + textHeight(send.text.trim(), Math.max(80, width - 62), openedPrepared) + 24 + 12;
  }
  return height;
}

/// A folded run's lines as ToolRows draws them (TurnRows.tsx, toolGroups.ts `runStretches`): the
/// work between coordination cards folds under one summary line per stretch, and every card the run
/// keeps in sight is its own row. A run of agent-to-agent messages ("Sent to lane-a", a command,
/// "Sent to lane-b") is a line per entry, not the one summary line a run of plain work is, or each
/// such run grows by its other lines when it mounts and the scroll thumb jumps (Leo, 2026-10-25:
/// "when I'm seeing all of these agent messages back and forth, that's when it sort of, like, gets
/// confused").
/// Each stretch starts as ToolRows draws it (toolGroups.ts `stretchStart`): a folding stretch is its
/// summary line, with its steps under it when the line starts open (`runOpen`; ToolRunSteps.tsx draws
/// each call on its own line, a quiet thought not at all); another stretch is its entries, groups
/// closed or open alike.
/// A line or group the reader opened or closed (transcriptDisclosureModel.ts) is estimated as they left
/// it, read with the same key, default and links ToolRows gives it (TurnRows.tsx): the estimate is what
/// places the row whenever its drawn height is gone (another width, its fold closed and opened again,
/// history paged out and back).
/// `live`: the row is the live turn's latest, so its last entry's thought may still stream (TurnRows.tsx).
function foldedRunSteps(
  row: AcpmuxRow,
  groups: readonly ToolGroup[],
  width: number,
  sessionId?: string,
  live = false,
): number {
  // `.cv-tools` and `.cv-tool-run` stack their lines flush (conversation.css), 22 apart.
  const stretches = runStretches(row, groups);
  // Each entry's thoughts are numbered from the row's earlier ones (TurnRows.tsx `thoughtIds`).
  const thoughts = thoughtIds(groups);
  return stretches.reduce((height, stretch, index) => {
    const start = stretchStart(row, stretch);
    const runKey = runDisclosureKey(stretch, row.id);
    if (stretch.fold) {
      const open = disclosureOpen(sessionId, runKey, start.lineOpen, {
        ...runLinks(stretch, row.id),
        members: callDisclosureKeys(stretch.items),
      });
      if (!open) return height + toolRowHeight();
      const steps = stepsHeight(stretch.items, width, sessionId, row.id, thoughts[stretch.from]);
      return height + toolRowHeight() + openRunBody(steps);
    }
    return (
      height +
      stretch.groups.reduce((sum, group, offset) => {
        const key = group.type === "group" ? groupDisclosureKey(group, stretch.from + offset, row.id) : undefined;
        // ToolGroupRow.tsx: open by default unless the run keeps it closed; an edits group keeps its own state.
        const edits = group.type === "group" && group.kind === "edits";
        const open =
          key !== undefined &&
          disclosureOpen(sessionId, key, !edits && !start.groupsClosed, {
            inherits: edits ? undefined : [runKey],
            closedBy: edits ? undefined : [runKey],
            members: callDisclosureKeys("items" in group ? group.items : [group.item]),
          });
        const before = thoughts[stretch.from + offset];
        const last = live && index === stretches.length - 1 && offset === stretch.groups.length - 1;
        return sum + foldedGroupHeight(group, width, !open, sessionId, row.id, before, last);
      }, 0)
    );
  }, 0);
}

/// An opened run line's or group's body under its line (ToolRun.tsx, ToolGroupRow.tsx): the line's
/// gap, held inside the fold (conversation.css `.cv-tools > * + .cv-fold::before`), over its steps,
/// which the default arm keeps to a 56-unit (224px) scroll box (RunScroll.tsx `.cv-run-scroll`).
const RUN_SCROLL_UNITS = 56;
export function openRunBody(steps: number): number {
  const base = gridLength("base") * chromeScale;
  return base + (experimentArm(runScroll) === "box" ? Math.min(steps, RUN_SCROLL_UNITS * base) : steps);
}

/// An opened edits group's body under its line (ToolGroupRow.tsx, its `kind === "edits"` arm): the
/// line's gap, then a diff card per changed file (EditDiff.tsx) and a row for each edit that carried
/// no diff (a delete, a move); with no file to show, the edits' rows. No scroll box: the cards are as
/// tall as they draw.
function openEditsBody(
  items: readonly AcpmuxActivity[],
  width: number,
  sessionId?: string,
  rowId = "",
  thoughts = 0,
): number {
  const files = toolFiles(items.flatMap((item) => (item.tool ? [item.tool] : [])));
  const gap = gridLength("base") * chromeScale;
  if (!files.length) return gap + stepsHeight(items, width, sessionId, rowId, thoughts);
  const plain = items.filter((item) => !item.tool?.diffs?.length);
  return (
    gap +
    files.reduce((sum, file) => sum + editDiffHeight(file, width), 0) +
    (plain.length ? stepsHeight(plain, width, sessionId, rowId, thoughts) : 0)
  );
}

/// One changed file's diff card (EditDiff.tsx, conversation.css `.cv-edit-diff`), at the lengths the card draws
/// with (conversation/editDiffBox.ts, at the chat's text and code size and the Interface Size): the room above and
/// below it, its head, and its body: the edits' rows, with the separator Pierre draws before a hunk that skips
/// lines of the file (EditDiffLoading.tsx `editParts`, whose placeholder is drawn at the rendered diff's height),
/// and the scrollbar lane under unwrapped rows (`--cv-edit-diff-lane`, padded in every engine). Past PREVIEW_LINES rows the body is cut to that many
/// and the lane (`--cv-block-cut`). An edit with no line changes is its note. Wrapped (a prose file, by default), a
/// row takes as many lines as its text needs at the card's width.
function editDiffHeight(file: TurnFile, width: number): number {
  const box = editDiffBox(drawnFontSize(chatDisplay()), chatCodeBlock(), chromeScale);
  const wrap = blockWrapOf(fileBlockKind(file.path));
  // The card is as wide as the group's body, inside its icon column (conversation.css `.cv-tool-group`).
  const card = width - gridLength("icon-box") * chromeScale;
  let rows = 0;
  let body = 0;
  for (const edit of file.edits) {
    if (!edit.hunks.length) {
      body += box.empty;
      continue;
    }
    // Wrapped, a row's room: the card less the number column (or the unnumbered indicator lane) and the
    // row's hanging indent (sideways.ts PIERRE_BLOCK_CSS), in monospace cells.
    const room = wrap ? wrapRoom(edit, card, box.code) : undefined;
    let lastEnd = 0;
    for (const hunk of edit.hunks) {
      const kept = hunk.lines.filter((line) => line.type !== "del");
      const start = kept[0]?.newLine ?? Math.max(0, (hunk.lines.find((line) => line.type !== "add")?.oldLine ?? 1) - 1);
      if (start - 1 - lastEnd > 0) body += box.separator;
      lastEnd = start + kept.length - 1;
      for (const line of hunk.lines) {
        const lines = room ? wrappedRows(line.text, room.first, room.rest) : 1;
        rows += lines;
        body += lines * box.row;
      }
    }
  }
  if (rows > PREVIEW_LINES) body = PREVIEW_LINES * box.row + (wrap ? 0 : EDIT_DIFF_LANE);
  else if (!wrap && rows) body += EDIT_DIFF_LANE;
  return box.margins + box.head + body;
}

/// A wrapped diff row's room in monospace cells (a cell is `monoAdvance()` of the code's size): the card's width less
/// Pierre's number column (its digits, 4 at least, 3ch of padding and a 2px divider; EditDiffLoading.tsx draws the
/// same) or, unnumbered, its 6px indicator lane, then the row's 1ch end padding and its hanging indent: 2ch on its
/// first line, 4ch under it (sideways.ts PIERRE_BLOCK_CSS).
function wrapRoom(edit: TurnFile["edits"][number], card: number, code: number): { first: number; rest: number } {
  const cell = code * monoAdvance();
  let digits = 4;
  for (const hunk of edit.hunks)
    for (const line of hunk.lines)
      digits = Math.max(digits, String(Math.max(line.newLine ?? 0, line.oldLine ?? 0)).length);
  const lead = edit.numbered ? (digits + 3) * cell + 2 : 6;
  const cells = (card - lead) / cell - 1;
  return { first: Math.max(8, Math.floor(cells - 2)), rest: Math.max(8, Math.floor(cells - 4)) };
}

/// A monospace cell's width per px of size, in the face the chat's code draws in (`--cv-mono`, or the chat's own
/// code font, chatDisplay.ts): read once per code font from a probe the page lays out, so a wrapped diff's rows
/// break where the engine's face breaks them (Menlo and SF Mono are 0.602; a face with another advance moves a
/// long line's wrap by a row). 0.602 where nothing lays out or the font is still loading (not kept then).
const MONO_ADVANCE = 0.602;
const monoAdvanceRead = new Map<string, number>();
function monoAdvance(): number {
  const display = chatDisplay();
  const key = display.codeFamily ?? "";
  const known = monoAdvanceRead.get(key);
  if (known !== undefined) return known;
  if (typeof document === "undefined" || !document.body) return MONO_ADVANCE;
  const family = chatDisplayVariables(display)["--cv-mono"] ?? "var(--cv-mono)";
  const probe = document.createElement("span");
  probe.style.cssText = "position:absolute;left:-10000px;top:0;visibility:hidden;white-space:pre";
  probe.style.fontFamily = family;
  probe.textContent = "0".repeat(50);
  document.body.append(probe);
  // The probe takes the page's own size (no size of its own, webviews/src/ui/README.md Type scale): the
  // advance is a share of whatever size it drew at.
  const width = probe.getBoundingClientRect().width;
  const size = Number.parseFloat(document.defaultView?.getComputedStyle(probe).fontSize ?? "");
  probe.remove();
  const styled =
    (document.defaultView?.getComputedStyle(document.documentElement).getPropertyValue("--cv-mono").trim() ?? "") !==
    "";
  if (!styled || !(width > 0) || !(size > 0) || document.fonts?.status === "loading") return MONO_ADVANCE;
  const advance = width / (50 * size);
  monoAdvanceRead.set(key, advance);
  return advance;
}

/// How many lines `text` takes wrapped as `pre-wrap` with `break-word` does: whole words while they fit, a word
/// longer than a line broken where the line ends; `first` cells on its first line, `rest` on the others.
function wrappedRows(text: string, first: number, rest: number): number {
  let rows = 1;
  let room = first;
  let used = 0;
  for (const word of text.split(" ")) {
    let left = word.length;
    if (used > 0 && used + 1 + left <= room) {
      used += 1 + left;
      continue;
    }
    if (used > 0) {
      rows += 1;
      room = rest;
    }
    while (left > room) {
      left -= room;
      rows += 1;
      room = rest;
    }
    used = left;
  }
  return rows;
}

/// An entry a folded run keeps on its own line: a group starts closed there (ToolGroupRow.tsx
/// `folded`), one line, as a sent message's row is (SentMessageLine.tsx); anything else is its calls.
/// Open (`closed` false), a group is its line over its calls; an edits group, over its files' diffs
/// (`openEditsBody`).
/// `sessionId`, `rowId` and `thoughts` (the row's thoughts before it) read the lines in it the reader
/// opened (`stepsHeight`); `live`, its last thought may still stream.
function foldedGroupHeight(
  group: ToolGroup,
  width: number,
  closed = true,
  sessionId?: string,
  rowId = "",
  thoughts = 0,
  live = false,
): number {
  if (group.type === "group" && !closed && (group.kind !== "edits" || editsEstimateOn()))
    return (
      toolRowHeight() +
      (group.kind === "edits"
        ? openEditsBody(group.items, width, sessionId, rowId, thoughts)
        : openRunBody(stepsHeight(group.items, width, sessionId, rowId, thoughts)))
    );
  if (group.type === "send")
    return (
      messageRowHeight(group.send.state !== "failed" && Boolean(group.send.text?.trim() || group.send.file)) +
      openSendBody(group.item.tool!, width, sessionId, [group.send])
    );
  // A group of sends starts closed: its head, a message row naming the recipients
  // (SentMessageLine.tsx `SentMessageGroup`, MessageGroupHead.tsx).
  if (group.type === "sendGroup") return messageRowHeight(true);
  if (group.type === "group") return toolRowHeight();
  // `.cv-tool-group` lists its calls flush too.
  const items = "items" in group ? group.items : [group.item];
  return stepsHeight(items, width, sessionId, rowId, thoughts, live);
}

/// The prepared texts of those messages, for their estimates; cleared past 256, as a row's are.
const receivedPrepared = new Map<string, PreparedText | null>();

/// An inbox thread's card under its line (conversation/InboxNoticeCard.tsx), from the messages it
/// draws (the notice's, else what the line read, else the preview): shut, the newest message, cut to
/// CLAMPED_LINES lines with Show more under it when it runs past them (whole once the person showed
/// it all); opened, the newest THREAD_PAGE messages (and "Show earlier messages" over them when there
/// are more), each under its head when there are several, or, in the drill look, a row per message
/// under the back control.
function inboxThreadCard(
  sessionId: string | undefined,
  key: string,
  messages: readonly { text: string }[] | undefined,
  preview: string,
  width: number,
  newest?: string,
): number {
  // A short one-line newest message reads on the line, with no card (inboxThreadRead.ts `fitsLine`).
  if (!messageOpened(sessionId, key) && fitsLine(messages?.at(-1)?.text ?? newest)) return messagePreviewLine(true);
  const { lineHeight } = metrics();
  if (receivedPrepared.size > 256) receivedPrepared.clear();
  const measure = (text: string) => (text ? textHeight(text, Math.max(80, width - 44), receivedPrepared) : lineHeight);
  // 2px above, 4px below, 8px padding each side, as an opened received message's panel.
  const panel = 2 + 4 + 16;
  if (!messageOpened(sessionId, key)) {
    // What the card draws (InboxNoticeCard.tsx `newestText`): the message read, else acpmux's whole
    // newest, else the preview.
    const height = measure(messages?.at(-1)?.text ?? newest ?? preview);
    const limit = CLAMPED_LINES * lineHeight;
    if (height <= limit + 1) return panel + height;
    return panel + (messageOpened(sessionId, newestWholeKey(key)) ? height : limit) + CLAMP_MORE_HEIGHT;
  }
  const list = messages ?? [{ text: newest ?? preview }];
  // The back control's line over a 22px row per message.
  if (inboxThreadLook() === "drill" && messages) return panel + 4 + 24 + 22 * list.length;
  const shown = list.slice(-THREAD_PAGE);
  // Several each have their 20px head, 8px apart (InboxNoticeCard.css `.cv-inbox__message`).
  const heads = list.length > 1 ? shown.length * lineHeight + (shown.length - 1) * 8 : 0;
  const earlier = list.length > shown.length ? CLAMP_MORE_HEIGHT + 8 : 0;
  return panel + earlier + heads + shown.reduce((sum, m) => sum + measure(m.text), 0);
}

/// A row keeps no gap of its own on the grid (grid.md 5.5): the stack gives it.
const TURN_GAP = 0;
/// The rest gap (Leo 2026-11-01: "more space between composer and latest messages ... tho maybe not
/// as much as claude code"): from the newest row's line (a turn footer's action row, laid in the band
/// under its reply (transcriptGrid.ts `restBand`), or the running turn's live line) to the top of the
/// floating bottom stack (the running tray, else the composer card). About two and a half body lines, as Codex leaves under its action row; Claude Code
/// leaves about four and a half. The last row's own turn gap is part of it, and the room under the
/// last row adds the rest (`restRoom`). leo-workspace design/chat-transcript.md.
/// settled-spacing: rest-gap (schemas/layout-grid/settled-spacing.json)
export const REST_GAP = 56;
/// What the room under the last row adds over a floating stack to the last row's turn gap. The
/// gallery compares other values through `<html data-rest-gap>` (composerRestGap.gallery.ts).
export function restRoom(): number {
  const set = typeof document === "undefined" ? undefined : document.documentElement.dataset.restGap;
  const gap = set === undefined || !Number.isFinite(Number(set)) ? REST_GAP : Number(set);
  return Math.max(0, gap - TURN_GAP);
}
/// A prompt's meta row (`.cv-user__actions`, UserBubble.tsx). Under a bubble it takes no layout
/// height, waiting steer or sent (design/grid.md 5.5: the action row is laid in the turn gap), so
/// sending a steer changes no row's height. A waiting prompt of images alone has no bubble to lay
/// the row under, so its row (Send now first, PendingSteer.tsx) stays in flow.
const userMetaHeight = (row: AcpmuxRow) => (row.steer === "waiting" && !row.text?.trim() ? META_GAP + metaRow() : 0);
/// The author line over a shared chat's prompt (multiplayer/multiplayer.css `.cv-author`): the taller
/// of its 18 line and its face (`--cv-author-face`, five grid units, 20 at 1x, scaling with the
/// interface), and the 4 under it.
const AUTHOR_LINE = 18;
const AUTHOR_FACE = 20;
const AUTHOR_GAP = 4;
const authorHeight = () => Math.max(AUTHOR_LINE, AUTHOR_FACE * chromeScale) + AUTHOR_GAP;
const chromeHeight = (row: AcpmuxRow, _actions: boolean) =>
  row.kind === "user"
    ? userBubblePadding() +
      userMetaHeight(row) +
      (row.status ? USER_STATUS_HEIGHT : 0) +
      (row.author ? authorHeight() : 0)
    : 0; // Reply controls overlay the container gap.
/// The bubble's share of its row and its side padding, which sits inside that share (border-box).
/// A transcript look's share and side padding replace them (`--cv-user-bubble-share`, `-pad-inline`).
const USER_BUBBLE_SHARE = 0.7;
const userBubbleShare = () => userBubbleBox(chatDisplay().transcriptLook).share ?? USER_BUBBLE_SHARE;
const userBubbleSides = () =>
  2 * (userBubbleBox(chatDisplay().transcriptLook).padInline ?? BUBBLE.paddingInline) * chatDensityTextScale();
/// Space between a row's markdown blocks, the list indent and the quote's bar and padding.
const blockGap = () => TRANSCRIPT_INNER_GAP * chromeScale;
const LIST_INDENT = 28;
const QUOTE_INDENT = 21;
/// Code cards: a 45.5px header over 12px monospace on 20px lines that never wraps, 13px inset. An
/// unlabeled fence has no header row (CodeHeader.tsx), only the inset above and below; a box-drawing
/// diagram's lines are 1.15 of its font (conversation.css `.cv-codeblock--diagram`).
const CODE_CHROME = 58.5;
const CODE_PADDING = 13;
const UNLABELED_CODE_CHROME = 2 * CODE_PADDING;
const DIAGRAM_LINE_RATIO = 1.15;
/// The text's share of a card's width: the body's 13px and 1px margins and the plain card's 8px and
/// 12px padding (conversation.css `.cv-codeblock__body`, `.cv-code-plain`).
const CODE_TEXT_INSET = 34;
/// The room an unlabeled card's first line keeps after its end for the corner actions
/// (conversation.css `--cv-code-corner-reserve`, 30px an action and 5): copy on a diagram, wrap and
/// copy on a highlighted card.
const codeCornerReserve = (diagram: boolean) => (diagram ? 1 : 2) * 30 + 5;
/// Table rows: 23px lines with 17px of padding.
const TABLE_ROW_HEIGHT = 40;
const SCROLLBAR_HEIGHT = 15;
/// Where text can't be measured (no canvas), a generous character width.
const FALLBACK_CHAR_WIDTH = 8;
/// The chat's one column (`--cv-column` and `--cv-inset` in conversation/conversation.css): the pane's
/// width up to Chat Text Width (chatWidth.ts, 800px by default), at least 720px or that width, centered, at least the page edge from each side. `endReserve` is room a card keeps at the
/// column's right (the computer use live preview, `--cv-inset-end`): the column's end moves in to
/// leave it, its start stays.
const PAGE_EDGE = gridLength("icon-box");
/// The column's own width (`--cv-column`), before the page edge limits it.
export const transcriptColumnSpan = (paneWidth: number, { min, max }: ChatColumn = chatColumn()) =>
  Math.min(max, Math.max(min, paneWidth));
export function transcriptColumn(paneWidth: number, chat: ChatColumn = chatColumn(), endReserve = 0) {
  const column = transcriptColumnSpan(paneWidth, chat);
  const inset = Math.max(PAGE_EDGE * gridScale(), (paneWidth - column) / 2);
  const insetEnd = Math.max(inset, endReserve);
  return { inset, insetEnd, width: paneWidth - inset - insetEnd };
}
/// Where a row starts in from the column's left edge (`--cv-lead` in conversation/conversation.css): the
/// composer's + glyph's center less half a row's icon box, the + at the composer's density, less the
/// composer card's 8px narrow outset under 298px of column.
const NARROW_COMPOSER_COLUMN = 297.5;
const NARROW_COMPOSER_OUTSET = 8;
export function transcriptLead(columnWidth: number): number {
  const scale = gridScale();
  const density = Math.max(0.8, composerDensityScale() ?? scale);
  const lead = gridLength("composer-lead-center") * density - (gridLength("transcript-icon-box") * scale) / 2;
  return lead - (columnWidth < NARROW_COMPOSER_COLUMN ? NARROW_COMPOSER_OUTSET : 0);
}
function composerDensityScale(): number | undefined {
  if (typeof document === "undefined") return undefined;
  const raw = parseFloat(document.documentElement?.style?.getPropertyValue?.("--cmux-density-scale") ?? "");
  return Number.isFinite(raw) && raw > 0 ? raw : undefined;
}
export const transcriptRowWidth = (paneWidth: number, column?: ChatColumn, endReserve = 0) => {
  const { width } = transcriptColumn(paneWidth, column, endReserve);
  return Math.max(120, width - transcriptLead(width));
};

/// A message's markdown blocks. Blank lines between blocks are only spacing, never blocks of their own.
/// A setext underline (`===` or `---` alone on its line, up to 3 spaces in) on one of `src`'s lines after
/// its first and before its first blank line: the only text marked's `lheading` rule can match (its
/// body never crosses a blank line). False means the rule cannot match `src`; true, that it may.
const SETEXT_UNDERLINE = /^ {0,3}(?:=+|-+) *$/;
export function maySetextHeading(src: string): boolean {
  let start = src.indexOf("\n") + 1;
  while (start > 0) {
    const end = src.indexOf("\n", start);
    const line = end < 0 ? src.slice(start) : src.slice(start, end);
    if (SETEXT_UNDERLINE.test(line)) return true;
    if (line.trim() === "") return false;
    start = end + 1;
  }
  return false;
}

/// marked's tokenizer, its `lheading` rule asked only of text that may hold a setext heading. Under
/// JavaScriptCore (WKWebView) that rule's regex costs time quadratic in a paragraph's length when it
/// fails, which is nearly always: the streaming reply's open paragraph, lexed again on every token
/// (`lexIncrementally`), spent most of its estimate there (bench/markdown-estimate-lex.bench.ts).
/// The tokens are the same: the rule is skipped only where it cannot match.
class EstimateTokenizer extends Tokenizer {
  override lheading(src: string) {
    return maySetextHeading(src) ? super.lheading(src) : undefined;
  }
}

export function markdownBlocks(source: string): Token[] {
  try {
    return lexer(source, { gfm: true, breaks: true, tokenizer: new EstimateTokenizer() }).filter(
      (token) => token.type !== "space",
    );
  } catch {
    return [{ type: "text", raw: source, text: source } as Token];
  }
}

export function visibleRowRange(
  rowCount: number,
  scrollTop: number,
  viewportHeight: number,
  estimate = 96,
  overscan = 8,
) {
  const first = Math.max(0, Math.floor(scrollTop / estimate) - overscan);
  const last = Math.min(rowCount, Math.ceil((scrollTop + viewportHeight) / estimate) + overscan);
  return { first, last };
}

/// The room under the edited-files card (styles.css `.acpmux-edited` margin-bottom).
const EDITED_CARD_BELOW = 6;
/// The edited-files card's height for `files` changed files with diffs and `plain` edits listed
/// without one (styles.css `.acpmux-edited`): its one 64px row, and, once the reader opened it, the
/// stacked diffs under it (EditedFilesCard.css `.acpmux-edited-stack`): a file's 32px name and about
/// six lines, a plain edit's 36px line, the box at most 60% of `viewport` tall. The drawn height
/// replaces it once measured.
export function editedCardHeight(files: number, plain = 0, open = false, viewport = 800): number {
  if (!open || files + plain === 0) return 64;
  return 64 + Math.min(files * (32 + 6 * 18) + plain * 36, Math.round(viewport * 0.6));
}

/// What edits without a diff list as in the edited-files card: each path they name, once
/// (toolPaths.ts), and one entry with no path for each call that names none ("Unknown file"). A
/// Write whose old contents are unknown (`contentsUnknown`) lists its diff's path the same way.
/// `failed`: only calls that failed named it, so it lists as failed. Never the tool input itself.
/// Paths are one file by `pathKey`; an entry carries the canonical path when there is one.
export function plainEditLabels(items: readonly AcpmuxActivity[]): PlainEditLabel[] {
  const out: PlainEditLabel[] = [];
  const at = new Map<string, number>();
  items.forEach((item, index) => {
    // An edit still waiting for its permission has changed nothing yet.
    const tool = item.tool;
    if (!tool || tool.status === "pending") return;
    const diffs = tool.diffs ?? [];
    const failed = tool.status === "failed";
    const mark = failed ? { failed: true as const } : {};
    const files = diffs.length
      ? diffs.filter(contentsUnknown)
      : editedPaths(tool).map((path) => ({
          path,
          canonical: toolCanonical(tool, path),
        }));
    if (!diffs.length && !files.length) out.push({ key: `unknown-${tool.id}-${index}`, ...mark });
    for (const file of files) {
      const key = pathKey(file);
      const listed = at.get(key);
      const entry = {
        key: `path-${key}`,
        path: file.path,
        ...(file.canonical ? { canonical: file.canonical } : {}),
      };
      if (listed === undefined) {
        at.set(key, out.length);
        out.push({ ...entry, ...mark });
      } else if (!failed) out[listed] = entry;
    }
  });
  return out;
}

/// An edited-files card entry without counts (`plainEditLabels`): `key` is its React key.
export type PlainEditLabel = {
  key: string;
  path?: string;
  canonical?: string;
  failed?: true;
};

/// First-layout estimates for rows not yet drawn; a drawn row places by its drawn height. Each
/// includes the row's bottom padding (`.acpmux-row` in styles.css: the message gap for messages,
/// 8px else; a turn's footer row closes with the turn gap).
/// The space under a message row: the meta gap over its turn's footer (`.acpmux-row--before-footer`,
/// which also drops the row's 34px floor), else the message gap.
const messageBelow = (beforeFooter: boolean) => (beforeFooter ? META_GAP : MESSAGE_GAP);
/// A reply right over its turn's footer, or over the running turn's line drawn as its last row
/// (`below`), which the footer takes the place of at its height when the turn ends: the reply keeps
/// the one gap, so the end moves nothing (the message gap there slid the reply down 4px at every
/// turn's end). App.tsx marks the same rows `acpmux-row--before-footer`.
/// Whether a reply draws its own action row (MessageActions.tsx ReplyActions). None does: a turn has
/// one action row, its footer at the bottom, whose Copy copies the whole turn (conversation/turnCopy.ts),
/// as Claude Code desktop draws it (Leo, 2026-10-31: "claude code doesn't have individual copy
/// pastable things for the entire thing, only the bottom. ironically we have literally the complete
/// opposite. so let's invert our behaviour"). This replaces the per-reply row of 2026-10-29. The
/// callers' height plumbing stays until ReplyActions goes in a follow-up.
export const hasReplyActions = (_row: AcpmuxRow, _next: AcpmuxRow | undefined) => false;
/// Whether a reply keeps the room its own action row took on 2026-10-30 (its meta gap and 24px line,
/// then the message gap: 36px under its text) though it draws no row there now. Leo, 2026-11-01, on a
/// capture of that build: "i like this spacing kinda i prefer it to what we have now tho it's just
/// minor differences". Every finished reply with text that something follows (a prompt, a steer,
/// another agent's message, a tool run), as `hasReplyActions` read it then; never the reply over its
/// turn's footer (the footer is its row), nor one still streaming. Inside an opened "Worked for"
/// (`settled`) only a reply to the person (`foldedReply`, which kept its action row) keeps it; a short
/// note there stays quiet. So a turn's end, which marks its earlier replies settled, moves nothing. App.tsx marks the rows `acpmux-row--reply-room` (conversation.css
/// `--cv-reply-room`); the estimate counts it as the action row's chrome.
export const keepsReplyRoom = (row: AcpmuxRow, next: AcpmuxRow | undefined) =>
  row.kind === "assistant" &&
  next !== undefined &&
  !isBeforeFooter(row, next) &&
  row.streaming !== true &&
  (row.settled !== true || row.foldedReply === true) &&
  (row.text ?? "").trim().length > 0;
export const isBeforeFooter = (row: AcpmuxRow, next: AcpmuxRow | undefined) =>
  row.kind === "assistant" &&
  (next?.kind === "turnSummary" || ((next?.kind === WORKING || next?.kind === THINKING) && next.below === true));
/// A status row: one quiet line the transcript draws in the tool rows' column among the replies (a
/// tool run, a background task's or a subagent's end, a background turn's line, a compaction, a
/// failover, a policy the harness cannot keep, a paused agent pair, a session start, another agent's
/// message or notice); an
/// edited-files card is a card, not a line. Between two replies it sits in the middle of the gap, as
/// Claude Code desktop's do (Leo, 2026-10-30: "see how claude code has those centered tool calls /
/// id like more alignment too"): `statusEdge`.
export const isStatusRow = (row: AcpmuxRow | undefined) =>
  row !== undefined && (row.kind === "user" ? isIncomingLine(row.incoming?.kind) : isStatusKind(row));
/// `incoming` is read once per call here and in isLineRow: layoutConversation asks both of every
/// row, hidden bookkeeping included, and rowLayoutLinearity.test.ts counts those reads.
const isIncomingLine = (kind: string | undefined) => kind === "message" || kind === "notice";
const isStatusKind = (row: AcpmuxRow) =>
  row.kind === "backgroundTask" ||
  row.kind === SUBAGENT_DONE ||
  row.kind === SUBAGENT_STARTED ||
  row.kind === "compaction" ||
  row.kind === "failover" ||
  row.kind === "policyUnenforced" ||
  row.kind === "agentPair" ||
  row.kind === BACKGROUND_TURN ||
  row.kind === TASK_LINE ||
  row.kind === MESSAGE_RUN ||
  (row.kind === "activity" && isToolRun(row));
/// A row the transcript draws as an edited-files card (turnChanges/sessionRows.ts `isEditRow`, which
/// reads this): a run of its own, not shaped (`foldRun`) or a folded copy, with an edit that ran.
export function isEditCard(row: AcpmuxRow): boolean {
  if (row.kind !== "activity" || row.foldRun !== undefined || isFoldedCopy(row)) return false;
  for (const item of row.items ?? [])
    if ((item.tool?.kind === "edit" || item.tool?.kind === "fileChange") && item.tool.status !== "pending") return true;
  return false;
}
/// A tool run with at least one call, not an edited-files card (turnChanges/sessionRows.ts
/// `isEditRow`): a run of thoughts alone may draw nothing, so it keeps its own spacing. One pass
/// over the row's items.
function isToolRun(row: AcpmuxRow): boolean {
  const card = row.foldRun === undefined && !isFoldedCopy(row);
  let tool = false;
  for (const item of visibleToolItems(row.items) ?? []) {
    if (!item.tool) continue;
    tool = true;
    if (card && (item.tool.kind === "edit" || item.tool.kind === "fileChange") && item.tool.status !== "pending")
      return false;
  }
  return tool;
}
/// Where a row stands next to a status row, read from the next drawn row alone as the other edges
/// are (no pass over the turn). A reply over a status row: its action row (MessageActions.tsx
/// ReplyActions, its meta gap and line) is the room above the line (`before-status`), or, for a
/// reply without one (a copy inside an opened "Worked for", one still streaming), the plain gap
/// (`before-status-plain`). A status row over a reply takes the same room under its line: the action
/// row's (`before-reply`), or the plain gap over a copy inside an opened fold (`before-reply-plain`),
/// whose replies draw no action row. A status row takes that room only between two replies: one
/// under a prompt (a turn that starts with a tool) keeps its own spacing, so `prev`, the drawn row
/// above, is read for that side alone. App.tsx marks the rows `acpmux-row--<edge>` (conversation.css
/// `--cv-status-gap`, `--cv-status-gap-plain`).
export type StatusEdge = "before-status" | "before-status-plain" | "before-reply" | "before-reply-plain";
export const statusEdge = (
  row: AcpmuxRow,
  next: AcpmuxRow | undefined,
  prev: AcpmuxRow | undefined,
): StatusEdge | undefined =>
  row.kind === "assistant"
    ? // A reply that keeps its room (`keepsReplyRoom`) ends at that room, whatever follows it.
      isStatusRow(next) && !isBeforeFooter(row, next) && !keepsReplyRoom(row, next)
      ? hasReplyActions(row, next)
        ? "before-status"
        : "before-status-plain"
      : undefined
    : next?.kind === "assistant" && prev?.kind === "assistant" && isStatusRow(row)
      ? // The same room as above the line, read from the same reply, so the two always match.
        hasReplyActions(prev, row)
        ? "before-reply"
        : "before-reply-plain"
      : undefined;
/// The room above and below a status row between two replies, line box to text box
/// (conversation.css `--cv-status-gap`): a reply's action row (its meta gap and line) and the step's
/// 2px top margin; between the copies inside an opened fold, the plain gap.
/// On the grid (grid.md 5.5) the block gap above and below a status row already centres it, so these
/// add nothing (conversation.css `--cv-status-gap`, `--cv-status-gap-plain`: 0).
const STATUS_GAP = 0;
const STATUS_GAP_PLAIN = 0;
/// How much a row's estimate changes at a status edge, against the bottom it has elsewhere.
function statusDelta(row: AcpmuxRow, edge: StatusEdge | undefined): number {
  if (edge === "before-status") return -MESSAGE_GAP;
  if (edge === "before-status-plain") return STATUS_GAP_PLAIN - TOOL_RUN_TOP - MESSAGE_GAP;
  if (edge === undefined) return 0;
  const gap = edge === "before-reply" ? STATUS_GAP : STATUS_GAP_PLAIN;
  // A tool run and a one-line row (another agent's line, a notice) both end at the run gap elsewhere.
  if (row.kind === "activity" || isLineRow(row)) return gap - TOOL_RUN_BOTTOM;
  return gap - MESSAGE_GAP;
}
/// The row kind of another agent's message while it waits in the queue (conversation/queuedMessages.ts):
/// its received card after the running turn, until acpmux starts it.
export const QUEUED_MESSAGE = "queuedMessage";
/// The row kind of the one group of messages that wait for the agent (conversation/pendingMessages.ts).
export const PENDING_MESSAGES = "pendingMessages";
export const LANE_NOTICE_BATCH = "laneNoticeBatch";
/// The row kind of a run of one-line rows that carries messages between agents, folded under one
/// line (conversation/messageRuns.ts, MessageRunLine.tsx).
export const MESSAGE_RUN = "messageRun";
/// What a message run's line says (conversation/messageRuns.ts): the messages sent and received, the
/// other calls (counted as a tool run counts them), failures, whether one still runs, and the ids of
/// the rows it folds (Find and links open it for one).
export type AcpmuxMessageRun = {
  sent: number;
  received: number;
  work: AcpmuxActivity[];
  failed: number;
  running: boolean;
  rows: string[];
  /// The ids of the messages it received (each message's `msgId`, an inbox notice's prompt ids):
  /// laneNoticeBatches.ts never draws one of these again in a "Received N messages" row.
  messages?: string[];
  /// Its phrases' kinds in the order each first came in the run ("sent", "received", or a work
  /// category, toolRunSummary.ts): the line reads in that order, so a phrase that comes in later
  /// joins the end and none before it moves (messageRuns.ts `messageRunSummary`).
  order?: string[];
};
/// A one-line activity row drawn on the tool rows' line: another agent's message, a task's notice and
/// an inbox notice (each a user row, IncomingMessageCard.tsx and InboxNoticeCard.tsx), a report
/// batch's head (LaneNoticeBatch.tsx) and the waiting messages' head (PendingMessagesCard.tsx).
/// App.tsx marks it `acpmux-row--line` and joins it to the step rows beside it.
/// The frame a row draws in: its `frame`, else its id (the transcript's React key and entrance key).
export const rowFrameKey = (row: AcpmuxRow) => row.frame ?? row.id;

export const isLineRow = (row: AcpmuxRow) =>
  row.kind === LANE_NOTICE_BATCH ||
  row.kind === MESSAGE_RUN ||
  row.kind === PENDING_MESSAGES ||
  (row.kind === "user" && !row.received && isIncomingRunLine(row.incoming?.kind));
const isIncomingRunLine = (kind: string | undefined) => isIncomingLine(kind) || kind === "inbox";
/// A row that draws nothing: a turn's bookkeeping (conversation/turns.ts), a session start
/// (rows/SessionStartRow.tsx), which the transcript no longer draws, or a run whose every call is hidden.
const drawsNothing = (row: AcpmuxRow) =>
  row.incoming?.kind === "hidden" || row.kind === "sessionStart" || hidesEveryCall(row);
/// The row after `index` that draws something.
export function nextDrawnRow(rows: readonly AcpmuxRow[], index: number): AcpmuxRow | undefined {
  for (let next = index + 1; next < rows.length; next += 1) if (!drawsNothing(rows[next]!)) return rows[next];
  return undefined;
}
/// The rows a mounted row's frame props are read from (VirtualTranscript's step joins, footer and
/// status edges, reply room): from the drawn row above `index - 1` through the next drawn row under
/// `index`, both included. `last` is `rows.length` when nothing drawn follows, so a row appended
/// after it changes the window too.
export function rowPropsWindow(rows: readonly AcpmuxRow[], index: number): { first: number; last: number } {
  let first = index - 2;
  while (first > 0 && drawsNothing(rows[first]!)) first -= 1;
  let last = index + 1;
  while (last < rows.length && drawsNothing(rows[last]!)) last += 1;
  return { first: Math.max(0, first), last };
}
/// The drawn row above `index` (`statusEdge` reads it for a status row over a reply).
export function prevDrawnRow(rows: readonly AcpmuxRow[], index: number): AcpmuxRow | undefined {
  for (let prev = index - 1; prev >= 0; prev -= 1) if (!drawsNothing(rows[prev]!)) return rows[prev];
  return undefined;
}
/// The chat's last footer ends at the message gap, not the turn gap: no band over the composer
/// (App.tsx marks it `acpmux-row--last-footer`). So does a footer over another agent's line (a
/// message, a notice or a started task's result): that line belongs with the agent's text above
/// it, not a turn of its own after a band. `next` is the next row that draws.
export const isLastFooter = (row: AcpmuxRow, next: AcpmuxRow | undefined) =>
  row.kind === "turnSummary" &&
  (!next ||
    next.kind === PENDING_MESSAGES ||
    next.kind === LANE_NOTICE_BATCH ||
    ((next.kind === "user" || next.kind === QUEUED_MESSAGE) &&
      (next.received !== undefined ||
        next.incoming?.kind === "message" ||
        next.incoming?.kind === "notice" ||
        next.incoming?.kind === "inbox")));
/// The footer whose actions show at rest (App.tsx `acpmux-row--final-footer`): the chat's last
/// ended turn, as ChatGPT's and Claude's last reply keep Copy in sight, until the person's next
/// prompt opens a turn. Another agent's message, a notice, a recap or a background line drawn under
/// it leaves it shown (Leo, 2026-11-04: "we don't have ... the thing always showing at hte bottom").
export function finalFooterId(rows: readonly AcpmuxRow[]): string | undefined {
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const row = rows[index]!;
    // An empty footer (turns.ts isEmptyFooter: a turn of bookkeeping with no answer) draws nothing
    // at rest, so the answer above it keeps its row in sight.
    if (row.kind === "turnSummary" && !isBlankFooter(row)) return row.id;
    if (row.kind === "turnSummary") continue;
    // A later turn's own work (one another agent's message started, or one with no summary yet)
    // or the person's own prompt: that turn's footer, not this one, is the chat's last.
    if (row.lastTurn || isTurnWork(row)) return undefined;
    if (row.kind === "user" && !row.incoming && row.received === undefined) return undefined;
  }
  return undefined;
}
/// turns.ts isEmptyFooter, which this module cannot import.
const isBlankFooter = (row: AcpmuxRow) =>
  row.status !== "failed" &&
  row.status !== "error" &&
  !row.text &&
  !row.githubConnect &&
  !((row.turnCopy?.length ?? 0) > 0);
const isTurnWork = (row: AcpmuxRow) =>
  row.kind === "assistant" ||
  row.kind === "activity" ||
  row.kind === WORKED ||
  row.kind === WORKING ||
  row.kind === THINKING;
/// A completed turn followed by more of this chat's assistant. Incoming agents are user rows,
/// so a user/agent speaker change keeps the full turn gap. Check only the next drawn row.
export const isContinuationFooter = (row: AcpmuxRow, next: AcpmuxRow | undefined) =>
  row.kind === "turnSummary" &&
  next !== undefined &&
  (next.kind === "assistant" ||
    next.kind === "activity" ||
    next.kind === WORKED ||
    next.kind === WORKING ||
    next.kind === THINKING);
/// What the row after a row changes about its height (`beforeFooter`, and the room a reply keeps,
/// `keepsReplyRoom`), as one key.
const rowEdge = (row: AcpmuxRow, next: AcpmuxRow | undefined, prev: AcpmuxRow | undefined) => {
  const status = statusEdge(row, next, prev);
  if (isLiveStep(row, prev)) return LIVE_STEP_EDGE;
  const edge = status ? `${footerEdge(row, next) ?? ""}${STATUS_EDGE}${status}` : footerEdge(row, next);
  return keepsReplyRoom(row, next) ? `${edge ?? ""}${ACTIONS_EDGE}` : edge;
};
const STATUS_EDGE = "+";
const ACTIONS_EDGE = "+actions";
const footerEdge = (row: AcpmuxRow, next: AcpmuxRow | undefined) =>
  isBeforeFooter(row, next)
    ? "footer"
    : isContinuationFooter(row, next)
      ? "continuation"
      : isLastFooter(row, next)
        ? "last"
        : row.lastTurn
          ? "last-turn"
          : undefined;

function fallbackRowHeight(
  row: AcpmuxRow,
  width: number,
  beforeFooter = false,
  lastTurn = false,
  actions = false,
  /// The chat the row is from, which keys the lines the reader opened (transcriptDisclosureModel.ts).
  sessionId?: string,
): number {
  const finish = (height: number) =>
    height === 0 || !lastTurn
      ? height
      : height + TURN_GAP - (row.kind === "activity" || isLineRow(row) ? TOOL_RUN_BOTTOM : MESSAGE_GAP);
  const textLines = Math.max(1, Math.ceil((row.text?.length ?? 0) / Math.max(24, Math.floor(width / 8))));
  if (row.kind === "activity") {
    const items = visibleToolItems(row.items) ?? [];
    // Successful discovery normally leaves no rendered steps, but keep a mountable slot so Find
    // can reveal the original call before the row's ToolRows projection is expanded.
    if (row.items?.length && !items.length) return finish(toolRowHeight());
    // The edited-files card (conversation/EditedFilesCard.tsx, `editedCardHeight`), its 6px under it;
    // one file is named in the head. Otherwise tool rows
    // (`.cv-tools`: 2px above compact rows, with a small run gap), which is also how a copy inside
    // an open "Worked for" draws.
    const edits = items.filter((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange");
    if (edits.length && row.foldRun === undefined && !isFoldedCopy(row)) {
      const files = new Set(
        edits.flatMap(
          (item) => item.tool?.diffs?.flatMap((diff) => (contentsUnknown(diff) ? [] : [pathKey(diff)])) ?? [],
        ),
      );
      const plain = plainEditLabels(edits).filter((entry) => !entry.path || !files.has(entry.canonical ?? entry.path));
      // One row until the reader opens it (EditedFilesCard.tsx, turnChanges/openStore.ts); opened, its
      // stacked diffs in a box at most 60% of the view tall.
      const open = cardOpen(row.id);
      const viewport = typeof window === "undefined" ? undefined : window.innerHeight || undefined;
      return finish(EDITED_CARD_BELOW + editedCardHeight(files.size, plain.length, open, viewport));
    }
    // A folded run (the Codex-style runs) that keeps an entry in sight (a message to another agent)
    // draws its stretches; one with nothing kept in sight draws one summary line, or its one call.
    if (row.foldRun && items.length) {
      const groups = toolGroups(items);
      // A run line open from the start (`runOpen`) draws each stretch's line over its steps; one the
      // reader opened draws them too. An edits group draws as its group even alone (a lone edit with a
      // diff, toolGroups.ts), its line opening to its files' diffs (`openEditsBody`).
      const editsGroup = editsEstimateOn() && groups.some((group) => group.type === "group" && group.kind === "edits");
      if (row.runOpen || groups.some(staysInSight) || isFoldedRun(items) || editsGroup)
        return finish(runPartTop(row) + TOOL_RUN_TOP + TOOL_RUN_BOTTOM + foldedRunSteps(row, groups, width, sessionId));
    }
    if (!items.length) return finish(runPartTop(row) + TOOL_RUN_TOP + TOOL_RUN_BOTTOM + toolRowHeight());
    // Any other row draws its entries as ToolRows does (TurnRows.tsx): one node per group, so a run of
    // commands is one "Ran N commands" group, open by default in its scroll box (`openRunBody`), not a
    // line per call (Leo, 2026-11-17: a gap under the row, and rows shifting when it was measured).
    return finish(
      runPartTop(row) +
        TOOL_RUN_TOP +
        TOOL_RUN_BOTTOM +
        foldedRunSteps(row, toolGroups(items), width, sessionId, row.live === true),
    );
  }
  // A subagent group's 48px line with 8px above it, and in an open group a 48px line per
  // subagent, the last with the list's 8px below (subagents/SubagentGroup.tsx).
  // An agent a shell call started (subagents/AgentRunCard.tsx): one collapsed disclosure line; its
  // reply and Raw are measured once the reader opens it.
  if (isRunGroup(row)) return finish(cardHeight("working"));
  // Image/file-only user prompts still draw their attachment strip before the action footer.
  // Reserve the fixed thumbnail height so virtualization never places the next row over it.
  // A prompt whose recorded parts give it nothing to read (bubbleParts.ts `attachmentOnlyPrompt`)
  // draws the same strip and no bubble, whatever blank text it carries (UserBubble.tsx).
  if (
    row.kind === "user" &&
    (!row.text?.trim() || attachmentOnlyPrompt(row)) &&
    (row.images?.length || row.retryAttachments?.length || row.inlineParts?.some((part) => part.kind !== "text"))
  ) {
    // A prompt whose recorded parts are its attachments alone draws them in the strip
    // (UserBubble.tsx `inlineAttachmentOnly`), each at its own sent size: measured as that strip,
    // so a short wide video or screenshot is not reserved a 160px row.
    // One whose `images` hold more than its parts (UserBubble.tsx `looseImages`) keeps the rows below.
    const recorded = attachmentOnlyPrompt(row) ? stripAttachments(row) : undefined;
    const recordedImages = recorded?.filter((part) => part.kind === "image").length ?? 0;
    if (recorded?.length && (row.images?.length ?? 0) <= recordedImages) {
      const bandWidth = USER_BUBBLE_SHARE * width + 2 * INLINE_ATTACHMENT_MARGIN.x;
      const band =
        attachmentBandHeight(row, recorded, bandWidth, new Map(), new Set()) +
        ATTACHMENT_BAND_BELOW -
        INLINE_ATTACHMENT_MARGIN.y;
      return finish(band + messageBelow(beforeFooter) + chromeHeight(row, actions));
    }
    // The thumbnail band (conversation.css .cv-user__images: flex-wrap in the 70% user column, an
    // 8px gap): the video tiles lead, then the images, each at its own sent size (UserBubble.tsx
    // sentVideoSize, sentImageSize; a 160px square when no size is known), so a short wide video or
    // screenshot reserves its own height, not a 160px row.
    const inlineParts = row.inlineParts ?? [];
    const videos = sentVideosOf(row);
    const imageSources = [
      row.images ?? [],
      inlineParts.filter((part) => part.kind === "image"),
      row.retryAttachments?.filter((part) => part.kind === "image") ?? [],
    ];
    const images = imageSources.reduce((most, one) => (one.length > most.length ? one : most), imageSources[0]!);
    const boxes = [
      ...videos.map((video) => sentVideoSize(video)),
      ...images.map((image) => sentImageSize(image as { width?: number; height?: number })),
    ];
    const column = width * USER_BUBBLE_SHARE;
    let bandHeight = 0;
    let rowWidth = 0;
    let rowHeight = 0;
    for (const box of boxes) {
      const shown = Math.min(box.width, column);
      const tall = (box.height * shown) / box.width;
      if (rowWidth > 0 && rowWidth + 8 + shown > column) {
        bandHeight += rowHeight + 8;
        rowWidth = 0;
        rowHeight = 0;
      }
      rowWidth += (rowWidth > 0 ? 8 : 0) + shown;
      rowHeight = Math.max(rowHeight, tall);
    }
    bandHeight += rowHeight;
    const otherAttachments = Math.max(
      0,
      Math.max(
        row.retryAttachments?.filter((part) => part.kind !== "image").length ?? 0,
        inlineParts.filter((part) => part.kind !== "text" && part.kind !== "image").length,
      ) - videos.length,
    );
    // The band and the gap under it (its ATTACHMENT_BAND_BELOW margin), then each file chip.
    const attachmentHeight = (boxes.length ? bandHeight + ATTACHMENT_BAND_BELOW : 0) + otherAttachments * 36;
    // Its pending state is its footer's time slot (PromptDelivery.tsx), taking no line of its own,
    // so the row keeps its height when the send lands.
    return finish(attachmentHeight + messageBelow(beforeFooter) + chromeHeight(row, actions));
  }
  if (row.kind === SUBAGENTS) return finish(56);
  // A workflow's card (summary/WorkflowCard.css): three fixed lines in a hairline box.
  // WorkflowCard: head, metadata, latest line, progress bar and focus line.
  if (row.kind === WORKFLOW_CARD) return finish(124);
  if (row.kind === SUBAGENT_ROW) return finish(row.status === "last" || row.status === "only" ? 56 : 48);
  // Empty child copy is measured on mount; start with two body lines.
  if (row.kind === SUBAGENT_EMPTY) return finish(2 * metrics().lineHeight);
  // The 27px disclosure line, and the live status lines in its place.
  // The running turn's line as its last row is the footer's slot (footerRow(), conversation.css
  // `.cv-worked.is-below`; transcriptGrid.ts MARK_FOOTER_SLOT), so the end-of-turn swap keeps its place.
  if ((row.kind === WORKING || row.kind === THINKING) && row.below) return finish(footerRow());
  // A finished work disclosure is one activity line, including when opened. Its estimate and
  // MARK_STEP use the same 22px rhythm as the calls it reveals (transcript-spacing.md rule 3).
  // Plus the room over and under its rule (conversation.css `.cv-worked.has-divider.is-toggle`).
  // The running turn's "Working for" over its work keeps the "Worked for" line's box (WorkingFor.tsx).
  if (row.kind === WORKED || row.kind === WORKING) return finish(toolRowHeight() + WORKED_GAP_PT * chromeScale);
  if (row.kind === WORKING || row.kind === THINKING) return finish(metaRow());
  // The 20px date line with 8px above it.
  if (row.kind === DATE) return finish(20);
  // A tagged ask's card (conversation/NextStepCard.tsx), the same in every pane, waiting or answered
  // (permissions/cardHeight.ts `nextStepCardHeight`).
  if (row.kind === NEXT_STEP && row.nextStep) {
    const { ask, answer, superseded } = row.nextStep;
    return finish(nextStepCardHeight(ask, width, { answer, superseded }));
  }
  // A walkthrough strip (conversation/Walkthrough.tsx): its 28px head and, open, the 96px row of
  // shots over two 16px caption lines, with 8px above and below.
  if (row.kind === WALKTHROUGH) return finish(8 + 28 + 8 + 96 + 6 + 32 + 8);
  // The render card: its 36px head over the frame before it reports a height, and 8px below.
  if (row.kind === RENDER) return finish(36 + RENDER_FRAME_MIN_HEIGHT + 8);
  // Permission and question cards have different frames and content at the grid padding.
  if (row.kind === "permission") return finish(permissionCardHeight(row.permission, width, chromeScale));
  // A suggested tasks card (offer/SuggestedTasks.tsx): its 28px heading, about 84px per open task
  // and 30px per started one, in 8px of margins.
  if (row.kind === "sessionOffer" && row.offers) {
    const open = row.offers.filter((offer) => !offer.outcome).length;
    const started = row.offers.filter((offer) => offer.outcome === "accepted").length;
    return finish(8 + 8 + 28 + open * 84 + started * 30);
  }
  // A turn's started chats (started/StartedSessionCard.tsx): one card, its 1px edges, a 34px row
  // for each, 50px with its status line, 1px hairlines between, in 8px of row padding.
  if (row.kind === STARTED_SESSIONS && row.started)
    return finish(
      8 + 2 + row.started.reduce((sum, child) => sum + (hasStatusLine(child) ? 50 : 34), 0) + (row.started.length - 1),
    );
  // A plan's builds (planBuild/PlanBuildCard.tsx): every column reserves its lines, so one height per width.
  if (row.kind === PLAN_BUILD_KIND && row.planBuild) return finish(planBuildHeight(row.planBuild, width));
  // A finished turn's task lines (conversation/TaskLine.tsx): one tool row each.
  if (row.kind === TASK_LINE && row.tasks) return finish(row.tasks.length * toolRowHeight());
  // A paused agent pair: its sentence over the held count and Resume; resumed, one line.
  if (row.kind === "agentPair") return finish(row.agentPair?.resumed ? 37 : 37 + 24);
  // A recap's heading and bullet points; the unread divider already supplies its heading.
  if (row.kind === "recap")
    return finish(recapHeight(row.recap?.text ?? "", width, metrics().lineHeight, currentLanguage()));
  // The unread line takes no height (conversation/SinceDivider.tsx: it lies over the gap it
  // marks, so it never moves a row); only its recap, which is content, does.
  if (row.kind === SINCE_DIVIDER)
    return finish(
      row.since?.recap ? recapHeight(row.since.recap.text, width, metrics().lineHeight, currentLanguage(), false) : 0,
    );
  // A memory offer (conversation/MemoryOfferCard.tsx): its file line, a 24px diff line per open fact
  // and the heading's, Accept all under two or more, in its 1px edges and 8px of row margins; settled,
  // its one 24px note.
  if (row.kind === MEMORY_OFFER && row.memory) {
    const card = memoryCardState(row.memory);
    if (card.settled) return finish(8 + 24);
    return finish(
      8 +
        2 +
        16 +
        24 +
        (card.pending + (card.heading ? 1 : 0)) * 24 +
        (card.pending > 1 ? 32 : 0) +
        (card.error ? 22 : 0),
    );
  }
  // A prompt coach card (conversation/PromptCoachCard.tsx): 12px padding, its 24px label line, 8px,
  // the rewrite block's 16px padding and 20px lines (at most eight, then it scrolls), 12px padding.
  // Off in Settings, it draws nothing.
  if (row.kind === PROMPT_COACH && row.coach)
    return finish(
      promptCoachEnabled() ? 12 + 24 + 8 + 16 + coachLines(row.coach.rewrite, width) * COACH_LINE_PX + 12 : 0,
    );
  // A preset approval card (conversation/PresetApprovalCard.tsx): open, its 8px padding around the
  // question, the preset's description, what it starts and the warning (20px lines, English
  // lengths), an error's line, and the 32px foot of buttons, in its 1px edges and 8px of row
  // margins; closed, its one 24px note.
  if (row.kind === PRESET_APPROVAL && row.presetApproval) {
    const { ask, outcome, error } = row.presetApproval;
    if (outcome) return finish(8 + 24);
    const perLine = Math.max(120, width - 40) / 7.5;
    const lines = (chars: number) => (chars > 0 ? Math.max(1, Math.ceil(chars / perLine)) : 0);
    const starts = [ask.harness, ask.model, ask.effort, ask.policy, ask.host].join(" ").length;
    // The question's, what it starts and the warning's English words around their values.
    const text = lines(ask.preset.length + 40) + lines(ask.description?.length ?? 0) + lines(starts + 24) + lines(98);
    return finish(8 + 2 + 16 + text * 20 + 4 + (error ? 28 : 0) + 32);
  }
  // A session start draws nothing (rows/SessionStartRow.tsx): no height, no gap.
  if (row.kind === "sessionStart") return finish(0);
  // A turn's footer: its line of buttons (the stack gives the gaps). An empty footer (only hover
  // controls, conversation/turns.ts isEmptyFooter) takes no extra line; its gap fits the controls.
  // A Connect GitHub card (conversation/GitHubConnectCard.tsx) adds its one line and button above it.
  if (row.kind === "turnSummary")
    return finish(
      isEmptyFooter(row) ? Math.max(metaRow(), TURN_GAP) : footerRow() + (row.githubConnect ? GITHUB_CONNECT_CARD : 0),
    );
  // A finished subagent's line: the chat's reply to its end is the chat's own message, never under it
  // (direct.ts `settleReaction`).
  if (row.kind === SUBAGENT_DONE || row.kind === SUBAGENT_STARTED) return finish(toolRowHeight());
  if (
    row.kind === "notice" ||
    row.kind === "backgroundTask" ||
    row.kind === "compaction" ||
    row.kind === "failover" ||
    row.kind === "policyUnenforced" ||
    row.kind === "typing" ||
    row.kind === BACKGROUND_TURN
  )
    // A standalone note is one `.cv-tools` line: a grid row (conversation.css), no frame of its own.
    return finish(toolRowHeight());
  return finish(messageBelow(beforeFooter) + chromeHeight(row, actions) + textLines * metrics().lineHeight);
}

/// A link target the page opens: absolute http and https only (replyHref.ts).
export { appHref, linkHref, safeHref };

/// The text `renderInline` in conversation/Markdown.tsx draws for `tokens`, as the estimator
/// measures it. Inline code draws in 12px monospace (conversation.css), no wider per character than the prose font's digits,
/// so each of its characters measures as a "0". A monospace space is a full cell, so a code
/// space measures as a "0" and a space, which keeps the line break.
export function measuredText(tokens: Token[] | undefined, fallback: string): string {
  if (!tokens?.length) return fallback;
  return tokens
    .map((token) => {
      if (token.type === "codespan") return (token as Tokens.Codespan).text.replace(/\S/g, "0").replace(/ /g, "0 ");
      if (token.type === "link" && !linkHref((token as Tokens.Link).href)) return (token as Tokens.Link).text;
      if ("tokens" in token) return measuredText(token.tokens, "text" in token ? token.text : (token.raw ?? ""));
      return token.raw ?? ("text" in token ? token.text : "");
    })
    .join("");
}

/// The prepared text cache is per row, so its key is the text revision (and the font that measured
/// it). A streamed tail never goes back to an earlier text, so a revision the row's last measure did
/// not use is dead: the cache keeps the ones it used and this many more, the most recent (a font or
/// look that flips back). It kept max(64, 4 x blocks) before, each a whole prepared block, in every
/// row of every chat in the renderer the chats share, and a session of streaming agents grew that
/// renderer's live heap until it stopped answering input (cmux#45888).
export const PREPARED_CACHE_SPARE = 4;

/// The rows whose prepared text (PreparedRow) the transcript keeps, the most recently measured: the
/// rows around the view and the live ones, which every pass measures, and a short tail of the rest.
/// A chat at any length holds this many (cmuxterm-hq goals/chats-flat-at-any-length.md); one entry per
/// row ever measured was most of a long chat's live heap, and V8's memory reducer kept collecting it
/// while the chat sat idle. A row that left is lexed and prepared again from its text when it is
/// measured again; a new width keeps its last height instead while it is away from the view
/// (layoutConversation `near`).
export const PREPARED_ROWS = 256;

/// `id`'s prepared text, made the most recent, or a new empty entry. A Map keeps insertion order, so
/// its first key is the least recently measured. A pass trims to PREPARED_ROWS when it ends
/// (trimPreparedRows), so the rows cached when it began are still there when it reaches them; within
/// it the oldest goes only past twice that, which bounds a pass that measures every row.
function preparedRow(cache: Map<string, PreparedRow>, id: string): PreparedRow {
  let entry = cache.get(id);
  if (entry) cache.delete(id);
  else
    entry = {
      text: "",
      blocks: [],
      closedBlocks: [],
      closedEnd: 0,
      lexedLength: 0,
      prepared: new Map(),
    };
  cache.set(id, entry);
  if (cache.size > 2 * PREPARED_ROWS) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  return entry;
}

/// The text layout library keeps every segment it ever measured, for the page's life: its per-font
/// segment cache, with each word's grapheme advances. A chat's every new word (an id, a count, a path)
/// is a new entry, so that cache grew with the chat too (about 30 MB of a 100k-row chat's live heap,
/// under prepare's `getSegmentBreakableFitAdvances`). Blink bounds its own word shape cache the same
/// way (ShapeCache clears itself whole past its size cap): after PREPARED_TEXT_CHARS characters prepared
/// since the last clear, the library's caches start over. Prepared text already made keeps its widths;
/// the next prepare measures its words again. Blink's own copy of every word the library measured,
/// held by the canvas it measures on, goes with that canvas (measureContext.ts).
export const PREPARED_TEXT_CHARS = 1_000_000;
let preparedTextChars = 0;
const clearMeasureCaches = () => {
  clearTextCaches();
  freshMeasureContext();
};

/// Counts `length` characters prepared, and clears the library's caches (`clear`) past
/// PREPARED_TEXT_CHARS. True when it cleared.
export function notePreparedText(length: number, clear: () => void = clearMeasureCaches): boolean {
  preparedTextChars += length;
  if (preparedTextChars <= PREPARED_TEXT_CHARS) return false;
  preparedTextChars = 0;
  clear();
  return true;
}

/// Drops the least recently measured rows' prepared text past PREPARED_ROWS.
function trimPreparedRows(cache: Map<string, PreparedRow>): void {
  if (cache.size <= PREPARED_ROWS) return;
  for (const id of cache.keys()) {
    cache.delete(id);
    if (cache.size <= PREPARED_ROWS) break;
  }
}

function trimPreparedCache(
  prepared: Map<string, PreparedText | null>,
  used: ReadonlySet<string>,
  /// The closed blocks' prepared texts, measured once (`closedHeight`) and kept as used.
  kept?: ReadonlySet<string>,
): void {
  const limit = used.size + (kept?.size ?? 0) + PREPARED_CACHE_SPARE;
  if (prepared.size <= limit) return;
  for (const key of prepared.keys()) {
    if (prepared.size <= limit) break;
    if (!used.has(key) && !kept?.has(key)) prepared.delete(key);
  }
}

/// The sum of `entry`'s closed block heights in a column `width` wide: the blocks measured before
/// at the same width and metrics count as they did, and only the ones that closed since measure.
// perf-hot: 1ms/delta agent-chat-stream-reveal
function closedBlocksHeight(entry: PreparedRow, width: number): { height: number; used: Set<string> } {
  const closed = entry.closedBlocks;
  const { lineHeight, blockCodeSize, codeLineHeight, codeCharWidth } = metrics();
  // proseFont: a reply measures in the reply face (measuringReply), another row in the chat's.
  const key = `${width}\n${proseFont()}\n${lineHeight}\n${blockCodeSize}\n${codeLineHeight}\n${codeCharWidth}`;
  let kept = entry.closedHeight;
  // The closed blocks only grow by appending; dropped (a text that is not this one's continuation),
  // their objects are new, so the last one measured is not where it was.
  if (!kept || kept.key !== key || kept.count > closed.length || (kept.count && closed[kept.count - 1] !== kept.last))
    kept = { key, count: 0, last: undefined, height: 0, used: new Set() };
  let height = kept.height;
  entry.measuredBlocks = closed.length - kept.count;
  for (let index = kept.count; index < closed.length; index += 1)
    height += blockHeight(closed[index]!, width, entry.prepared, kept.used);
  entry.closedHeight = { key, count: closed.length, last: closed.at(-1), height, used: kept.used };
  return entry.closedHeight;
}

function textHeight(
  text: string,
  width: number,
  prepared: Map<string, PreparedText | null>,
  used?: Set<string>,
  /// The rows' line height when it is not the prose's (a folded note's 20px lines).
  lineHeight = metrics().lineHeight,
): number {
  const measureFont = proseFont();
  // Keyed by font too: a new chat font measures the text again.
  const key = `${measureFont}\n${text}`;
  used?.add(key);
  let measured = prepared.get(key);
  if (measured === undefined) {
    try {
      measured = prepare(text, measureFont, { whiteSpace: "pre-wrap" });
      notePreparedText(text.length);
    } catch {
      measured = null;
    }
  }
  // Refresh the entry's recency on every hit. This keeps the live block revisions in the cache while
  // allowing older streaming tails to be evicted by trimPreparedCache.
  prepared.delete(key);
  prepared.set(key, measured);
  if (measured) return layout(measured, width, lineHeight).height;
  const perLine = Math.max(24, Math.floor(width / FALLBACK_CHAR_WIDTH));
  return (
    text.split("\n").reduce((lines, line) => lines + Math.max(1, Math.ceil(line.length / perLine)), 0) * lineHeight
  );
}

/// Each item's text at the list's indent, then any list nested in it a further indent in.
function listHeight(
  list: Tokens.List,
  width: number,
  prepared: Map<string, PreparedText | null>,
  used?: Set<string>,
): number {
  const inner = width - LIST_INDENT;
  // `.cv-list` stacks its items with the inner gap (conversation.css), scaled per pass.
  const itemGaps = Math.max(0, list.items.length - 1) * blockGap();
  return (
    itemGaps +
    list.items.reduce((sum, item) => {
      const nested = item.tokens.filter((token): token is Tokens.List => token.type === "list");
      const text = measuredText(
        item.tokens.filter((token) => token.type !== "list"),
        nested.length ? "" : item.text,
      );
      // An empty item (or one still streaming in) still draws its bullet's line.
      const own = text ? textHeight(text, inner, prepared, used) : 0;
      return (
        sum +
        Math.max(
          metrics().lineHeight,
          own + nested.reduce((total, child) => total + listHeight(child, inner, prepared, used), 0),
        )
      );
    }, 0)
  );
}

/** A fenced code card's estimated height in a column `width` wide, without its outer margin. */
export function codeCardHeight(text: string, info: string | undefined, width: number): number {
  // marked keeps the fence's whole info string (`text title="tree"`); the card reads its first word
  // (Markdown.tsx), so `text title="tree"` draws unlabeled.
  const lang = info?.trim().split(/\s/, 1)[0];
  const lines = text.split("\n");
  const { codeCharWidth, codeLineHeight, blockCodeSize } = metrics();
  const unlabeled = isUnlabeledLang(lang);
  const diagram = isDiagram(text, lang);
  const room = width - CODE_TEXT_INSET;
  const reserve = unlabeled ? codeCornerReserve(diagram) : 0;
  const scrolls = lines.some((line, index) => line.length * codeCharWidth + (index ? 0 : reserve) > room);
  const chrome = unlabeled ? UNLABELED_CODE_CHROME : CODE_CHROME;
  const lineHeight = diagram ? blockCodeSize * DIAGRAM_LINE_RATIO : codeLineHeight;
  return chrome + lines.length * lineHeight + (scrolls ? SCROLLBAR_HEIGHT : 0);
}

function blockHeight(
  block: Token,
  width: number,
  prepared: Map<string, PreparedText | null>,
  used?: Set<string>,
): number {
  switch (block.type) {
    case "list":
      return listHeight(block as Tokens.List, width, prepared, used);
    case "blockquote":
      return textHeight(
        measuredText((block as Tokens.Blockquote).tokens, (block as Tokens.Blockquote).text),
        width - QUOTE_INDENT,
        prepared,
        used,
      );
    case "hr":
      return 2;
    case "code":
      return codeCardHeight((block as Tokens.Code).text, (block as Tokens.Code).lang, width);
    case "table":
      return (1 + (block as Tokens.Table).rows.length) * TABLE_ROW_HEIGHT;
    case "paragraph":
    case "text":
    case "heading":
      return textHeight(
        measuredText("tokens" in block ? block.tokens : undefined, (block as Tokens.Text).text),
        width,
        prepared,
        used,
      );
    // Anything else is estimated as its source; the drawn height replaces it once mounted.
    default:
      return textHeight(block.raw, width, prepared, used);
  }
}

/// Lexes `text` into `entry`, reusing the blocks before the last safe boundary when `text` grew.
function lexIncrementally(entry: PreparedRow, text: string): void {
  if (!text.startsWith(entry.text.slice(0, entry.closedEnd))) {
    entry.closedBlocks = [];
    entry.closedEnd = 0;
  }
  entry.lexedLength = 0;
  const boundary = lastBlockBoundary(text, entry.closedEnd);
  if (boundary > entry.closedEnd) {
    const chunk = text.slice(entry.closedEnd, boundary);
    entry.closedBlocks = [...entry.closedBlocks, ...markdownBlocks(chunk)];
    entry.lexedLength += chunk.length;
    entry.closedEnd = boundary;
  }
  const tail = text.slice(entry.closedEnd);
  entry.lexedLength += tail.length;
  entry.blocks = [...entry.closedBlocks, ...markdownBlocks(tail)];
  entry.text = text;
}

/// An activity row whose items are all thoughts that draw no row once done (thoughts.ts
/// `isQuietThought`, after `mergeThoughts` joins neighbours as ToolRows does). The live turn's latest
/// step may still stream its thought, so it is never one. Such a row draws no element at all
/// (App.tsx ToolActivityRow), so its article is empty and takes no room (conversation.css).
export const onlyQuietThoughts = (row: AcpmuxRow) =>
  row.kind === "activity" &&
  !row.live &&
  (row.items?.length ?? 0) > 0 &&
  mergeThoughts(row.items!).every((item) => isThought(item) && isQuietThought(item));

/**
 * UserBubble renders this narrow class as literal spans. Keep the fast path deliberately
 * conservative: anything whose Markdown meaning could differ from its source stays on the
 * parser-backed estimator until the DOM can measure it. Every Markdown marker promptMarkdown.ts
 * looks for (`$` too) is excluded here, so a row PromptText sends to Markdown never lands here.
 */
const PLAIN_MARKDOWN_CHARS = "\\`*_~<>[]{}#|&/$";

function isPlainUserPrompt(text: string): boolean {
  return (
    text.length > 0 &&
    text.trim() === text &&
    !/[\r\n\t]/.test(text) &&
    !PLAIN_MARKDOWN_CHARS.split("").some((character) => text.includes(character)) &&
    !/^- *(?:- *){2,}$/.test(text) &&
    !/^(?:[-+*]\s|\d+[.)]\s|!\s?)/.test(text)
  );
}

function measuredRowHeight(
  row: AcpmuxRow,
  width: number,
  cache: Map<string, PreparedRow>,
  beforeFooter = false,
  lastTurn = false,
  sessionId?: string,
  continuation = false,
  /// Whether a reply keeps its action row's room (`keepsReplyRoom`).
  actions = false,
): number {
  const finish = (height: number) =>
    height === 0 || !lastTurn
      ? height
      : height + TURN_GAP - (row.kind === "activity" || isLineRow(row) ? TOOL_RUN_BOTTOM : MESSAGE_GAP);
  // A task's result is one 26px line, however long the prompt that brought it (offer/SuggestedTasks.tsx).
  if (row.received) return finish(metaRow());
  // A turn's footer carries its answer's text for Copy (conversation/turns.ts); it draws one line.
  if (row.kind === "turnSummary") {
    if (isOverlayFooter(row)) return 0;
    return footerRow();
  }
  // A message run's line (conversation/messageRuns.ts): its rows, when open, are rows of their own.
  if (row.kind === MESSAGE_RUN) return finish(lineRow());
  // A task notification from another agent is a tool row's line (conversation/IncomingMessageCard.tsx)
  // in the one-line rows' frame (lineRow).
  // The messages that wait, as one group (conversation/PendingMessagesCard.tsx): its head is a
  // one-line row; opened, each sender's 22px head, then each of its messages as its own row draws
  // it, 24px in, less the frame the row gives a row, which the group has once.
  if (row.kind === LANE_NOTICE_BATCH && row.laneNoticeBatch) {
    // Shut, a waiting inbox batch's head draws its senders under its count (stacked look); a
    // delivered one names them only in its hover (LaneNoticeBatch.tsx `received`).
    if (!messageOpened(sessionId, row.id)) {
      const waiting = row.laneNoticeBatch.rows.some(
        (member) => member.kind === "queuedMessage" || member.steer === "waiting",
      );
      return finish(lineRow() + messagePreviewLine(row.laneNoticeBatch.kind === "inbox" && waiting));
    }
    const head = finish(lineRow());
    // An inbox batch's messages sit on its own columns, with no indent (LaneNoticeBatch.css).
    const inner = row.laneNoticeBatch.kind === "inbox" ? width : width - 24;
    return (
      head +
      row.laneNoticeBatch.rows.reduce(
        (height, member) =>
          height + measuredRowHeight(member, Math.max(80, inner), cache, false, false, sessionId) - LINE_FRAME,
        0,
      )
    );
  }
  if (row.kind === PENDING_MESSAGES && row.pendingMessages) {
    // One message waiting draws as its own line, with no group head (PendingMessagesCard.tsx).
    const shown = row.pendingMessages.displayRows ?? row.pendingMessages.rows;
    if (shown.length === 1 && shown[0]!.incoming?.kind === "message")
      return measuredRowHeight(shown[0]!, width, cache, beforeFooter, lastTurn, sessionId);
    // Shut, its head draws the senders under the count (stacked look).
    if (!messageOpened(sessionId, row.id)) return finish(lineRow() + messagePreviewLine(true));
    const head = finish(lineRow());
    const senders = new Set<string>();
    let height = head;
    for (const member of row.pendingMessages.displayRows ?? row.pendingMessages.rows) {
      const from =
        member.incoming?.kind === "message"
          ? (member.incoming.message.sessionId ?? member.incoming.message.name)
          : member.id;
      if (!row.pendingMessages.flat && member.kind !== LANE_NOTICE_BATCH && !senders.has(from)) {
        senders.add(from);
        height += 22;
      }
      // A Stop-held queued message's lead note sits above its received line. Keep the
      // virtualized group estimate in sync with `.cv-received__queued-head`'s 18px line.
      const heldLead = member.queuedMessage?.lead && member.queuedMessage.heldByStop ? 18 : 0;
      height +=
        heldLead + measuredRowHeight(member, Math.max(80, width - 24), cache, false, false, sessionId) - LINE_FRAME;
    }
    return height;
  }
  if (row.incoming?.kind === "message") {
    // A message that says nothing but "." draws nothing (visibleMessage.ts isBareAgentText).
    if (isVisiblyEmptyMessage(row)) return finish(0);
    // One line in the one-line rows' frame (lineRow()); one the person opened
    // (incomingOpened.ts) adds its panel (2px above, 4px below, 8px padding each side, 24px in
    // from the icon column and 10px padding across): the whole text
    // (conversation/IncomingMessageCard.tsx), its images' 128px, and Details' 24px line.
    const line = lineRow();
    // Shut, its first line sits under the sender (stacked look); a tool's notice keeps its title
    // on the line (IncomingMessageCard.tsx).
    // A preview-only inbox thread's line (rows/MessageRow.tsx `inboxThread`) keeps its open state
    // under its thread's key (inboxNotice.ts `inboxThreadKey`), which the digest's head opens too.
    const openKey = row.inboxThread ? inboxThreadKey(row.id, row.inboxThread.threadId) : row.id;
    // Its card is always under it, shut or open (inboxThreadCard).
    if (row.inboxThread) {
      const read = threadRead(sessionId, openKey, readForIds(row.inboxThread.promptIds)) ?? undefined;
      return finish(
        line + inboxThreadCard(sessionId, openKey, read, row.incoming.message.text, width, row.inboxThread.newest),
      );
    }
    const message = row.incoming.message;
    // The `card` look's message row (conversation/receivedLook.ts; not a tool's notice or a lane's
    // report, which keep their own line): its card is under the line shut too, the words cut to
    // CLAMPED_LINES lines with Show more.
    const card = receivedLook() === "card" && !message.notice && !laneNotice(message);
    const opened = messageOpened(sessionId, openKey);
    if (!opened && !card) return finish(line + messagePreviewLine(!message.notice));
    const { lineHeight } = metrics();
    const text = message.text;
    if (receivedPrepared.size > 256) receivedPrepared.clear();
    // A notice of a title alone opens to its title (agentNotice.ts `openedNoticeText`).
    const shown = text || (message.notice?.title ?? "");
    const whole = shown ? textHeight(shown, Math.max(80, width - 44), receivedPrepared) : lineHeight;
    const cut = card && whole > CLAMPED_LINES * lineHeight + 1;
    const lines = cut && !opened ? CLAMPED_LINES * lineHeight : whole;
    const details = opened && message.raw.trim() !== text ? 24 : 0;
    return finish(line + 2 + 4 + 16 + lines + (cut ? CLAMP_MORE_HEIGHT : 0) + (row.images?.length ? 128 : 0) + details);
  }
  if (row.incoming?.kind === "notice") return finish(lineRow());
  if (row.incoming?.kind === "inbox") {
    // acpmux's inbox notice (conversation/InboxNoticeCard.tsx): a received line per thread, under
    // the group's line when the group look holds two or more, each with its card (inboxThreadCard).
    const { threads } = row.incoming.notice;
    const line = toolRowHeight();
    // The group's head is a tool row (MessageGroupHead.tsx) on the one-line rows' line.
    const head = toolRowHeight();
    const grouped = threads.length > 1 && foldsThreads(inboxNoticeLook());
    if (grouped && !messageOpened(sessionId, row.id))
      return finish(head + LINE_FRAME + messagePreviewLine(inboxNoticeLook() !== "group-count"));
    let height = (grouped ? head : 0) + (threads.length > 1 && inboxNoticeLook() === "card" ? 6 : 0);
    for (const thread of threads) {
      const key = inboxThreadKey(row.id, thread.threadId);
      // A tool's notice shut is its one compact line (noticeRowLook.ts), no card under it.
      if (thread.notice && noticeRowLook() !== "off" && !messageOpened(sessionId, key)) {
        height += line + messagePreviewLine(true);
        continue;
      }
      const messages = thread.messages?.length
        ? thread.messages
        : (threadRead(sessionId, key, readForIds(thread.promptIds)) ?? undefined);
      height +=
        line + inboxThreadCard(sessionId, key, messages, thread.preview, width - (grouped ? 24 : 0), thread.newest);
    }
    return finish(height + LINE_FRAME);
  }
  // Empty or zero-width message text has no article; attachments and incoming cards returned
  // above remain visible through `isVisiblyEmptyMessage`'s content checks.
  if (isVisiblyEmptyMessage(row)) return finish(0);
  // Bookkeeping alone: a turn's start that draws nothing (conversation/turns.ts).
  if (row.incoming?.kind === "hidden") return finish(0);
  // A finished step of only quiet thoughts draws nothing (conversation/ThoughtRow.tsx).
  if (onlyQuietThoughts(row)) return finish(0);
  if (!row.text) return fallbackRowHeight(row, width, beforeFooter, lastTurn, actions, sessionId);
  // A prompt with only attachments in its recorded parts draws them in the strip and no bubble
  // (UserBubble.tsx `inlineAttachmentOnly`), so its text is never measured as a bubble's.
  if (row.kind === "user" && row.from !== "chief" && !chiefEnvelope(row.text) && attachmentOnlyPrompt(row))
    return fallbackRowHeight(row, width, beforeFooter, lastTurn, actions);
  const entry = preparedRow(cache, row.id);
  const pasted = row.kind === "user" && Boolean(row.pasted?.length);
  // Whether the reader opened the prompt's fold (PromptText.tsx `prompt:${rowId}`): open, a paste in it
  // draws whole.
  const promptOpen = row.kind === "user" && disclosureOpen(sessionId, `prompt:${row.id}`);
  // A huge prompt opens collapsed to its first lines whatever it holds (conversation/PromptText.tsx):
  // its height is those lines and Show more, never a lex or measure of megabytes of text.
  // A prompt recorded in parts is huge by its typed parts alone (a pasted block is a chip).
  if (
    row.kind === "user" &&
    !pasted &&
    row.from !== "chief" &&
    isHugePrompt(row.text) &&
    (!row.inlineParts || hasHugeTypedPart(row.inlineParts)) &&
    !chiefEnvelope(row.text)
  ) {
    const height =
      messageBelow(beforeFooter) +
      chromeHeight(row, actions) +
      collapsedPromptHeight(Number.POSITIVE_INFINITY, metrics().lineHeight);
    return finish(beforeFooter ? height : Math.max(34, height));
  }
  // A prompt drawn in its parts' order (conversation/InlinePromptContent.tsx) measures what its
  // bubble draws, never its recorded text: a text file's body is behind its chip, and the runs of
  // a placed prompt join as the draft had them. The pane's attachment view says which attachments
  // draw in the row above the bubble instead (UserBubble.tsx: the strip view draws them all there).
  const layout =
    row.kind === "user" && row.inlineParts && row.from !== "chief" && !chiefEnvelope(row.text)
      ? bubbleLayout(row, composerSettingsSnapshot().attachmentView)
      : undefined;
  const inline = layout?.parts;
  const plainUser =
    row.kind === "user" &&
    !inline &&
    !pasted &&
    !row.images?.length &&
    !row.retryAttachments?.length &&
    !row.from &&
    !chiefEnvelope(row.text) &&
    isPlainUserPrompt(row.text);
  const contentWidth = Math.max(80, row.kind === "user" ? userBubbleShare() * width - userBubbleSides() : width);
  const picks = row.kind === "user" && !inline && !pasted && !plainUser ? sentUIPickSegments(row.text) : undefined;
  const usedPrepared = new Set<string>();
  let keptPrepared: Set<string> | undefined;
  // A long prompt shut on its fold draws its first lines and Show more whatever follows them
  // (collapsedPromptHeight, below): when its head is past the fold already, the head is all there
  // is to lex and measure. Measured whole, a prompt sent from a draft of thousands of lines laid
  // out every line in the send's own task, which the composer's collapse waited on (Leo, 2026-11-22:
  // "THE FUCSKING COLLAPSING OF THE FUCKING COMPOSER / IT TAKES TOO FUCKING LONG"). A head that is
  // not past the fold (a very wide bubble) measures the whole text, as before.
  const foldLimit = COLLAPSED_PROMPT_LINES * metrics().lineHeight + 1;
  const shutLong =
    row.kind === "user" &&
    !promptOpen &&
    row.from !== "chief" &&
    !chiefEnvelope(row.text) &&
    row.text.length > HUGE_PROMPT_HEAD_CHARS;
  let contentHeight: number;
  if (plainUser) {
    // UserBubble -> PromptText draws this as literal spans, so avoid preparing Markdown tokens.
    const plainWidth = contentWidth;
    const { measureFont, lineHeight } = metrics();
    const plainKey = `${measureFont}\n${lineHeight}\n${plainWidth}\n${row.text}`;
    if (entry.plainHeight?.key === plainKey) contentHeight = entry.plainHeight.height;
    else {
      const head = shutLong
        ? textHeight(promptHead(row.text, HUGE_PROMPT_HEAD_CHARS), plainWidth, entry.prepared, usedPrepared)
        : 0;
      contentHeight = head > foldLimit ? head : textHeight(row.text, plainWidth, entry.prepared, usedPrepared);
      entry.plainHeight = { key: plainKey, height: contentHeight };
    }
  } else {
    // The text lexed: a shut long prompt's head first (`shutLong`).
    let lexed = shutLong ? promptHead(row.text, HUGE_PROMPT_HEAD_CHARS) : row.text;
    if (!inline && !pasted && !picks && (entry.text !== lexed || entry.lexedLength === 0)) {
      lexIncrementally(entry, lexed);
    }
    if (inline) {
      contentHeight = inlinePromptHeight(row, inline, contentWidth, entry.prepared, usedPrepared);
    } else if (picks) {
      // A prompt with inspector picks draws each as its chip (conversation/SentUIPick.tsx), the text
      // around it as before: never the report's fenced lines.
      contentHeight = pickedPromptHeight(picks, contentWidth, entry.prepared, usedPrepared);
    } else if (pasted) {
      // A prompt with pasted blocks: one body of its typed text and the person's pastes, and a paste
      // another agent wrote apart under its "Pasted from" line (conversation/PromptText.tsx). A huge
      // part draws collapsed to its head, so its head is all there is to measure; the fold caps it.
      const { lineHeight } = metrics();
      contentHeight = 0;
      for (const part of recordedBody(row.text, row.pasted!, experimentArm(sentPasteJoin)))
        contentHeight +=
          (part.kind === "paste" ? PASTE_FROM_HEIGHT : 0) +
          Math.max(
            lineHeight,
            textHeight(
              (part.kind === "paste" && !promptOpen) || isHugePrompt(part.text)
                ? promptHead(part.text, HUGE_PROMPT_HEAD_CHARS)
                : part.text,
              contentWidth,
              entry.prepared,
              usedPrepared,
            ),
          );
    } else {
      if (entry.blocks.length === 0) return fallbackRowHeight(row, width, beforeFooter, lastTurn, actions);
      // `entry.blocks` is the closed blocks followed by the tail's (lexIncrementally): the closed ones
      // are measured once each (closedBlocksHeight), the tail's every time.
      const blocksHeight = () => {
        const closed = closedBlocksHeight(entry, contentWidth);
        keptPrepared = closed.used;
        let height = (entry.blocks.length - 1) * blockGap() + closed.height;
        for (let index = entry.closedBlocks.length; index < entry.blocks.length; index += 1)
          height += blockHeight(entry.blocks[index]!, contentWidth, entry.prepared, usedPrepared);
        entry.measuredBlocks! += entry.blocks.length - entry.closedBlocks.length;
        return height;
      };
      contentHeight = blocksHeight();
      if (lexed !== row.text && contentHeight <= foldLimit) {
        lexIncrementally(entry, (lexed = row.text));
        contentHeight = blocksHeight();
      }
    }
  }
  // A stream changes only its tail block. Preserve prepared entries for the unchanged blocks and
  // trim stale revisions once per row, never once per token or across the transcript. `usedPrepared`
  // includes list items, whose text count can be much larger than the block count.
  trimPreparedCache(entry.prepared, usedPrepared, keptPrepared);
  // A long prompt opens collapsed to its first lines over Show more (conversation/UserBubble.tsx); a
  // Chief's draws its own bubble (ChiefPromptBubble.tsx). One the reader opened (PromptText.tsx, its
  // `prompt:` disclosure) draws whole over the same line, Show less.
  if (row.kind === "user" && row.from !== "chief" && !chiefEnvelope(row.text))
    contentHeight = promptOpen
      ? contentHeight + (contentHeight > COLLAPSED_PROMPT_LINES * metrics().lineHeight + 1 ? PROMPT_MORE_HEIGHT : 0)
      : collapsedPromptHeight(contentHeight, metrics().lineHeight);
  // The band's tiles span the bubble's column (conversation.css `.cv-user__inline-strip`: 70% and
  // its tiles' side margins), with its gap to the bubble under it.
  const bandWidth = USER_BUBBLE_SHARE * width + 2 * INLINE_ATTACHMENT_MARGIN.x;
  const band = layout?.band.length
    ? attachmentBandHeight(row, layout.band, bandWidth, entry.prepared, usedPrepared) +
      ATTACHMENT_BAND_BELOW -
      INLINE_ATTACHMENT_MARGIN.y
    : 0;
  // A strip prompt with nothing to read beside its attachments draws no bubble (UserBubble.tsx).
  if (layout && !layout.parts.some((part) => part.kind !== "text" || part.text.trim()))
    return finish(messageBelow(beforeFooter) + chromeHeight(row, actions) - userBubblePadding() + band);
  const height = messageBelow(beforeFooter) + chromeHeight(row, actions) + band + contentHeight;
  return finish(height);
}

/// The gap from a prompt's attachments to its bubble (conversation.css --cv-user-attachment-gap): the
/// legacy image band's margin under it, and the strip's with its tiles' 2px margin.
export const ATTACHMENT_BAND_BELOW = 6;
/// A sent attachment in a bubble's text (`.cv-user__inline-image`, `.cv-user__inline-file`):
/// an inline block 4px from its neighbors and 2px above and below, on the text's line.
export const INLINE_ATTACHMENT_MARGIN = { x: 4, y: 2 };
/// A sent file's chip (composerAttachments.css `.acpmux-file-chip`): 32px tall, at most 340px wide,
/// 8px each side of its 16px glyph, its name and its size, 6px apart.
export const INLINE_FILE_CHIP = {
  height: 32,
  maxWidth: 340,
  side: 8,
  glyph: 16,
  gap: 6,
};
/// An inspector pick's chip in a sent message (composerAttachments.css `.cv-user__chip`): a block of
/// its own, its face two control rows tall, 4px above and below. Closed: an opened one is measured.
export const SENT_UI_PICK_CHIP = { height: 48, marginY: 4 };
const SENT_UI_PICK_BOX = SENT_UI_PICK_CHIP.height + 2 * SENT_UI_PICK_CHIP.marginY;

/// `text` prepared for a walk of its lines, kept in the row's prepared map with its text heights.
function preparedLines(
  text: string,
  prepared: PreparedRow["prepared"],
  used: Set<string>,
): PreparedTextWithSegments | null {
  const font = proseFont();
  const key = `lines\n${font}\n${text}`;
  used.add(key);
  let measured = prepared.get(key) as PreparedTextWithSegments | null | undefined;
  if (measured === undefined) {
    try {
      measured = prepareWithSegments(text, font, {
        whiteSpace: "pre-wrap",
      });
      notePreparedText(text.length);
    } catch {
      measured = null;
    }
  }
  prepared.delete(key);
  prepared.set(key, measured);
  return measured;
}

/// One line of `text` (no line break in it) laid on from `x` of a line `width` wide, as the bubble's
/// `pre-wrap` text flows (`.cv-user__inline-content`): whether it starts on a new line (its first
/// word does not fit what is left of this one), how many more lines it ends after the one it
/// starts on, and the width it takes of its last line.
function flowRun(
  text: string,
  width: number,
  x: number,
  prepared: PreparedRow["prepared"],
  used: Set<string>,
): { wraps: boolean; breaks: number; end: number } {
  const lines = preparedLines(text, prepared, used);
  if (!lines) {
    const word = text.match(/^\s*\S*/)![0].length * FALLBACK_CHAR_WIDTH;
    const wraps = x > 0 && x + word > width;
    const total = (wraps ? 0 : x) + text.length * FALLBACK_CHAR_WIDTH;
    const breaks = Math.max(0, Math.ceil(total / width) - 1);
    return { wraps, breaks, end: total - breaks * width };
  }
  let cursor: LayoutCursor = { segmentIndex: 0, graphemeIndex: 0 };
  let first = x > 0 ? layoutNextLineRange(lines, cursor, Math.max(1, width - x)) : null;
  // A word cut on what is left of the line goes to the next line whole, as the browser breaks
  // before it (an attachment is a break opportunity).
  const wraps =
    first !== null &&
    first.end.graphemeIndex > 0 &&
    lines.segments.slice(0, first.end.segmentIndex).every((segment) => !segment.trim());
  if (wraps) first = null;
  let end = x;
  let breaks = 0;
  let started = first !== null;
  if (first) {
    end = x + first.width;
    cursor = first.end;
  }
  for (let next = layoutNextLineRange(lines, cursor, width); next; next = layoutNextLineRange(lines, next.end, width)) {
    if (started) breaks += 1;
    started = true;
    end = next.width;
  }
  return { wraps, breaks, end };
}

/// A text's width on one line (a file chip's name).
function lineWidth(text: string, prepared: PreparedRow["prepared"], used: Set<string>): number {
  const lines = preparedLines(text, prepared, used);
  return lines ? measureNaturalWidth(lines) : text.length * FALLBACK_CHAR_WIDTH;
}

/// A prompt drawn in its parts' order, as InlinePromptContent.tsx draws it, laid out as its CSS
/// flows it (`.cv-user__inline-content`, `pre-wrap`): its one body's lines, with each attachment an
/// inline block on the text's line (an image's thumbnail at its own size, UserBubble.tsx
/// `sentImageSize`; a video's tile; a file's chip as wide as its name and size), a line as tall as
/// its tallest; a part drawn as Markdown, and a paste another agent wrote under its "Pasted from"
/// line, a block of its own. A huge part is only its head. A text file is its chip alone: its body is
/// not drawn. `parts` are bubbleParts.ts `bubbleParts`, what the bubble draws.
/// A sent attachment's box with its margins (`.cv-user__inline-image`, `.cv-user__inline-file`), in
/// a bubble's text or the attachment row above it, in a line `width` wide: an image's thumbnail at
/// its own size (UserBubble.tsx `sentImageSize`), a video's tile, a file's chip as wide as its name
/// and size.
function attachmentBox(
  part: Exclude<PromptContentPart, { kind: "text" }>,
  videos: ReturnType<typeof sentVideosOf>,
  width: number,
  prepared: PreparedRow["prepared"],
  used: Set<string>,
): { width: number; height: number } {
  const { x: marginX, y: marginY } = INLINE_ATTACHMENT_MARGIN;
  const thumbnail = (size: { width: number; height: number }) => {
    // `max-width: calc(100% - 8px)`: a narrow bubble scales it down whole.
    const shown = Math.min(size.width, Math.max(1, width - 2 * marginX));
    return {
      width: shown + 2 * marginX,
      height: (size.height * shown) / size.width + 2 * marginY,
    };
  };
  if (part.kind === "image") return thumbnail(sentImageSize(part));
  const video = part.kind === "file" ? sentVideoOf(part, videos) : undefined;
  // A video's tile: its own shape under the same rule (UserBubble.tsx `sentVideoSize`).
  if (video) return thumbnail(sentVideoSize(video));
  // An image sent as its file's link draws as a sent image of unknown size (UserBubble.tsx
  // `SentLinkedImage`) until it is read.
  if (linkedImagePath(part)) return thumbnail(sentImageSize({}));
  const chip = INLINE_FILE_CHIP;
  // The Transcript Work Log's chip says "added to context" in place of the size (PromptFile).
  const size = experimentSwitchOn("transcriptWorkLog")
    ? translate("worklog.addedToContext")
    : part.name.endsWith("/")
      ? undefined
      : fileSizeLabel(shownFileSize(part), "en");
  const content =
    2 * chip.side +
    chip.glyph +
    chip.gap +
    lineWidth(part.name, prepared, used) +
    (size ? chip.gap + lineWidth(size, prepared, used) : 0);
  return {
    width: Math.min(chip.maxWidth, content) + 2 * marginX,
    height: chip.height + 2 * marginY,
  };
}

/// The row of attachments above a prompt's bubble (UserBubble.tsx `.cv-user__inline-strip`, a
/// `.cv-user__files` flex row that wraps, 4px between): each attachment's box, the row `width` wide.
const ATTACHMENT_BAND_GAP = 4;
function attachmentBandHeight(
  row: AcpmuxRow,
  parts: readonly Exclude<PromptContentPart, { kind: "text" }>[],
  width: number,
  prepared: PreparedRow["prepared"],
  used: Set<string>,
): number {
  const videos = sentVideosOf(row);
  let height = 0;
  let line = 0;
  let x = 0;
  for (const part of parts) {
    const box = attachmentBox(part, videos, width, prepared, used);
    if (x > 0 && x + ATTACHMENT_BAND_GAP + box.width > width) {
      height += line + ATTACHMENT_BAND_GAP;
      line = 0;
      x = 0;
    }
    x += (x > 0 ? ATTACHMENT_BAND_GAP : 0) + box.width;
    line = Math.max(line, box.height);
  }
  return height + line;
}

function inlinePromptHeight(
  row: AcpmuxRow,
  parts: readonly PromptContentPart[],
  width: number,
  prepared: PreparedRow["prepared"],
  used: Set<string>,
): number {
  const { lineHeight } = metrics();
  const videos = sentVideosOf(row);
  let height = 0;
  // The open line: the width taken of it and its height, 0 while none is open.
  let x = 0;
  let line = 0;
  const close = () => {
    height += line;
    line = 0;
    x = 0;
  };
  const attachment = (box: { width: number; height: number }) => {
    if (line > 0 && x > 0 && x + box.width > width) close();
    x += box.width;
    line = Math.max(line, lineHeight, box.height);
  };
  const text = (value: string) =>
    value.split("\n").forEach((run, index) => {
      // A line break ends the line, an empty one included.
      if (index > 0) {
        line = Math.max(line, lineHeight);
        close();
      }
      if (!run) return;
      const flow = flowRun(run, width, x, prepared, used);
      if (flow.wraps) close();
      line = Math.max(line, lineHeight);
      if (flow.breaks > 0) {
        height += line + (flow.breaks - 1) * lineHeight;
        line = lineHeight;
      }
      x = flow.end;
    });
  const block = (blockHeight: number) => {
    close();
    height += blockHeight;
  };
  const measure = (value: string) => Math.max(lineHeight, textHeight(value, width, prepared, used));
  const body = drawnBody(parts, experimentArm(sentPasteJoin));
  body.forEach((part, index) => {
    // Two text parts side by side read as the recorded text does, a newline between.
    if (index > 0 && part.kind === "text" && body[index - 1]!.kind === "text") text("\n");
    if (part.kind === "text") {
      const huge = ("huge" in part && part.huge === true) || isHugePrompt(part.text);
      // PromptText.tsx PromptTyped: plain text is a span of the line; Markdown is its blocks.
      if (huge) text(isHugePrompt(part.text) ? promptHead(part.text, HUGE_PROMPT_HEAD_CHARS) : part.text);
      else if (isPromptMarkdown(part.text)) block(measure(part.text));
      else text(part.text);
    } else if (part.kind === "pasted" && part.text) {
      block(PASTE_FROM_HEIGHT + measure(promptHead(part.text, HUGE_PROMPT_HEAD_CHARS)));
    } else if (part.kind === "file" && !part.uri && part.text && sentUIPick(part.text)) {
      // An inspector pick placed in the text: its chip, a block of its own (InlinePromptContent.tsx).
      block(SENT_UI_PICK_BOX);
    } else {
      attachment(attachmentBox(part, videos, width, prepared, used));
    }
  });
  close();
  return height;
}

/// A legacy prompt with inspector picks (`sentUIPickSegments` of its text), as PromptText.tsx
/// PromptTyped draws it: each text segment its lines, each pick its chip.
function pickedPromptHeight(
  segments: readonly SentPromptSegment[],
  width: number,
  prepared: PreparedRow["prepared"],
  used: Set<string>,
): number {
  const { lineHeight } = metrics();
  let height = 0;
  for (const segment of segments)
    height +=
      segment.kind === "pick"
        ? SENT_UI_PICK_BOX
        : Math.max(
            lineHeight,
            textHeight(
              isHugePrompt(segment.text) ? promptHead(segment.text, HUGE_PROMPT_HEAD_CHARS) : segment.text,
              width,
              prepared,
              used,
            ),
          );
  return height;
}

/// A row's estimated height at a width, kept by the row object: rows are immutable (a change is a
/// new object), so a long chat's layout measures only the rows that changed since the last one.
/// The row's edge is kept too: a reply's height changes when its turn's footer arrives after it, and
/// a footer's when a prompt follows it.
/// `scale` is the Interface Size it was measured at (gridScale), which a remembered height must share.
/// `open` is the row's state signature then (conversation/rowOpenState.ts): an estimate taken with a
/// run, group, call or message open is never reused for the row once it is closed, or the other way.
/// `width` and `height` are the newest measure; `older` holds the ones before it at other widths, newest
/// first, up to ROW_HEIGHT_WIDTHS in all: a divider dragged narrow and back finds every row's height at
/// the width it comes back to and measures none of them again. The older ones share the newest's edge,
/// scale and open state (`withHeight` drops them when one changes).
export type RowHeights = WeakMap<AcpmuxRow, RowHeight>;
export interface RowHeight {
  width: number;
  height: number;
  edge?: string;
  scale?: number;
  open?: string;
  older?: readonly { width: number; height: number }[];
}
/// How many widths a row's estimated height is kept at (`RowHeight.older`).
export const ROW_HEIGHT_WIDTHS = 4;
/// The row's kept height at `width`, when it was measured there at this edge and scale.
function heightAt(
  kept: RowHeight | undefined,
  width: number,
  edge: string | undefined,
  scale: number,
): number | undefined {
  if (!kept || kept.edge !== edge || (kept.scale ?? 1) !== scale) return undefined;
  if (kept.width === width) return kept.height;
  return kept.older?.find((entry) => entry.width === width)?.height;
}
/// The row's entry with `height` at `width` as its newest measure; its other widths stay while the edge,
/// scale and open state do.
function withHeight(
  kept: RowHeight | undefined,
  width: number,
  height: number,
  edge: string | undefined,
  scale: number,
  open: string | undefined,
): RowHeight {
  if (!kept || kept.edge !== edge || (kept.scale ?? 1) !== scale || (kept.open ?? "") !== (open ?? ""))
    return { width, height, edge, scale, open };
  if (kept.width === width) return { ...kept, height };
  const older = [{ width: kept.width, height: kept.height }];
  for (const entry of kept.older ?? [])
    if (entry.width !== width && older.length < ROW_HEIGHT_WIDTHS - 1) older.push(entry);
  return { width, height, edge, scale, open, older };
}

/// A footer with nothing to show at rest (turns.ts isEmptyFooter) lays its hover controls over the gap
/// and takes no height. A reply's footer is a row of its own: ChatGPT's 32 line of buttons, 8 under
/// the reply (transcriptGrid.ts `MARK_FOOTER_ROW`; Leo, 2026-11-02: "didn't i always say we can do it
/// like chatgpt").
export const isOverlayFooter = (row: AcpmuxRow) => row.kind === "turnSummary" && isEmptyFooter(row);

/** DOM-free row geometry. Only visible rows need their React elements painted. */
export function layoutConversation(
  rows: readonly AcpmuxRow[],
  width: number,
  cache = new Map<string, PreparedRow>(),
  measureOverride?: (row: AcpmuxRow, width: number) => number | undefined,
  known?: RowHeights,
  /// The last layout at this width, whose rows (by object) the new rows may start with: those
  /// keep their places, and only the rows after the first change are placed again.
  previous?: { rows: readonly AcpmuxRow[]; layout: ConversationLayout },
  /// The chat the rows are from, which keys the messages the person opened (incomingOpened.ts).
  sessionId?: string,
  /// A live resize (a divider dragged): the last layout, at another width, and the rows around the
  /// view `[from, to)`. Only those rows are measured at `width`; every other row that is the same
  /// object keeps its height from that layout until the resize settles and a full layout runs. A drag
  /// frame then costs the rows in view, not the whole chat (Leo, 2026-11-11: "the dragging
  /// responsiveness is slow for agent chat but fast for browser hmmm").
  resizing?: {
    rows: readonly AcpmuxRow[];
    layout: ConversationLayout;
    from: number;
    to: number;
  },
  /// The rows around the view `[from, to)`. Every other row whose prepared text the cache no longer
  /// holds (PREPARED_ROWS) and that was measured at another width, at this scale and edge, keeps that
  /// height (`known`) instead of being lexed and prepared again: a new width costs the rows near the
  /// view and the cached ones, not the whole chat. This is Chromium's `content-visibility: auto` with
  /// `contain-intrinsic-size: auto`: content off screen keeps its last remembered size and is laid out
  /// again as it is rendered; here the row's drawn height replaces it once it mounts.
  /// `all`: every row away from the view keeps its last height, prepared or not, whatever it draws: a
  /// new box width (a divider that held, a window edge, a sidebar) then costs the rows near the view
  /// whatever the chat's length, not every prepared row and every row with no text again.
  near?: { from: number; to: number; all?: boolean },
  /// A cold open at the chat's end: the rows within this many px of the end are measured, and every
  /// row above them with no known height takes its rough height (`fallbackRowHeight`, no text is
  /// prepared). The layout is then `rough`, and the transcript lays it out whole after the first
  /// paint. The open's first frame costs the rows it mounts, not the whole page of history.
  roughAbove?: number,
): ConversationLayout {
  const gaps = new Float64Array(rows.length);
  const marks = new Uint8Array(rows.length);
  const tops = new Float64Array(rows.length);
  const heights = new Float64Array(rows.length);
  const messages = new MessagePlacement(rows, previous?.layout);
  const scale = gridScale();
  chromeScale = scale;
  lineRowPt = transcriptLineRow();
  // The gaps between rows also take the transcript look's density and row spacing (1 at cmux).
  const gapFactor = transcriptGapScale();
  const gapScale = scale * gapFactor;
  let start = 0;
  // Kept rows keep their gaps only at the scale they were placed at.
  if (previous && (previous.layout.scale ?? 1) === scale && (previous.layout.gapScale ?? 1) === gapFactor) {
    // Asked of the same two row arrays by the pane's other passes too: walked once a pair, or not at
    // all where the rows' maker said how many it kept (prefixFlatMap.ts `noteKeptPrefix`).
    start = keptPrefix(previous.rows, rows);
    // A row after the kept ones can change the height of the last kept row that draws (a footer
    // after a reply, a prompt after the last footer, past rows that draw nothing): place it again.
    let drawn = start - 1;
    while (drawn >= 0 && drawsNothing(rows[drawn]!)) drawn -= 1;
    if (
      drawn >= 0 &&
      rowEdge(rows[drawn]!, nextDrawnRow(rows, drawn), prevDrawnRow(rows, drawn)) !==
        rowEdge(rows[drawn]!, nextDrawnRow(previous.rows, drawn), prevDrawnRow(previous.rows, drawn))
    )
      start = drawn;
    if (previous.layout.gaps) gaps.set(previous.layout.gaps.subarray(0, start));
    if (previous.layout.marks) marks.set(previous.layout.marks.subarray(0, start));
    tops.set(previous.layout.tops.subarray(0, start));
    heights.set(previous.layout.heights.subarray(0, start));
  }
  let top = start > 0 ? tops[start - 1]! + heights[start - 1]! : 0;
  // Kept rows may hold a remembered height of their own.
  let remembered = start > 0 && previous?.layout.remembered === true;
  let previousContent = start - 1;
  while (previousContent >= 0 && heights[previousContent] === 0) previousContent -= 1;
  let beforeContent = previousContent - 1;
  while (beforeContent >= 0 && heights[beforeContent] === 0) beforeContent -= 1;
  // Hidden bookkeeping can span many rows. Keep the next drawn row for the whole
  // pass: searching anew for every hidden row makes one run quadratic.
  let nextDrawn = start;
  // The drawn row above the current one, carried along the pass for the same reason.
  let prevDrawn = prevDrawnRow(rows, start);
  // The first row measured whole in a cold open (`roughAbove`); rows before it are rough.
  let roughBefore = 0;
  let rough = false;
  if (roughAbove !== undefined && start === 0 && !resizing) {
    let below = 0;
    roughBefore = rows.length;
    while (roughBefore > 0 && below < roughAbove) {
      roughBefore -= 1;
      const row = rows[roughBefore]!;
      if (!drawsNothing(row)) below += fallbackRowHeight(row, width);
    }
  }
  for (let index = start; index < rows.length; index += 1) {
    const row = rows[index]!;
    // The mark is taken against the row the gap is taken from (`previousContent`, the last row with
    // height), not the last row that is not bookkeeping: a run that draws 0 px (only a thought, a call
    // the live line names, a run split by a steer) between a steer and "Thinking" marked the line a
    // live step while its gap came from the steer, the turn gap (32) where 24 is due.
    marks[index] = gridMark(
      row,
      previousContent >= 0 ? rows[previousContent] : prevDrawn,
      beforeContent >= 0 ? rows[beforeContent] : undefined,
    );
    messages.visit(row, index, previous?.rows[index]);
    if (nextDrawn <= index) {
      nextDrawn = index + 1;
      while (nextDrawn < rows.length && drawsNothing(rows[nextDrawn]!)) nextDrawn += 1;
    }
    const prev = prevDrawn;
    if (!drawsNothing(row)) prevDrawn = row;
    const edge = rowEdge(row, rows[nextDrawn], prev);
    const kept = known?.get(row);
    // The row's open state now (rowOpenState.ts), read only when a remembered estimate could place it:
    // one taken in another open state is estimated again, from the same stores the DOM opens from.
    const open = kept ? rowOpenState(sessionId, row) : undefined;
    const keptOpen = kept !== undefined && (kept.open ?? "") === open;
    const keptHere = heightAt(kept, width, edge, scale);
    let height: number;
    if (keptOpen && keptHere !== undefined) height = keptHere;
    else if (
      resizing &&
      (resizing.layout.scale ?? 1) === scale &&
      (index < resizing.from || index >= resizing.to) &&
      index < resizing.layout.heights.length &&
      resizing.rows[index] === row
    )
      // Out of view during a live resize: its height at the last width, never recorded as this width's.
      height = resizing.layout.heights[index]!;
    else {
      const away =
        near !== undefined &&
        kept !== undefined &&
        keptOpen &&
        kept.edge === edge &&
        (kept.scale ?? 1) === scale &&
        (index < near.from || index >= near.to);
      const customHeight = away && near.all ? undefined : measureOverride?.(row, width);
      const custom = customHeight !== undefined && Number.isFinite(customHeight) && customHeight >= 0;
      if (
        !custom &&
        index < roughBefore &&
        !kept &&
        (row.kind === "assistant" || row.kind === "user") &&
        row.text &&
        !row.received &&
        !cache.has(row.id)
      ) {
        // Above a cold open's measured rows: its rough height, never recorded as this width's.
        height = fallbackRowHeight(
          row,
          width,
          edge?.startsWith("footer") === true,
          edge?.startsWith("last-turn") === true,
          edge?.endsWith(ACTIONS_EDGE) === true,
          sessionId,
        );
        if (height > 0) height += statusDelta(row, statusEdge(row, rows[nextDrawn], prev));
        rough = true;
        remembered = true;
      } else if (away && (near.all || (!custom && row.text && !cache.has(row.id)))) {
        // Away from the view, at a new width or with its prepared text gone (PREPARED_ROWS): its last height, never
        // recorded as this width's. Its drawn height replaces it once it mounts, and a layout that
        // measures it (near the view, after a change above it) records this width's.
        height = kept.height;
        remembered = true;
      } else {
        // A reply's text measures in the reply's face (`proseFont`).
        measuringPart = row.kind === "assistant" ? "reply" : row.kind === "user" ? "prompt" : null;
        try {
          height = custom
            ? customHeight
            : edge === LIVE_STEP_EDGE
              ? liveStepHeight() * chromeScale
              : measuredRowHeight(
                  row,
                  width,
                  cache,
                  edge?.startsWith("footer") === true,
                  edge?.startsWith("last-turn") === true,
                  sessionId,
                  edge?.startsWith("continuation") === true,
                  edge?.endsWith(ACTIONS_EDGE) === true,
                );
        } finally {
          measuringPart = null;
        }
        // A row that draws nothing stays at 0; a custom renderer's height is its own.
        if (!custom && height > 0) height += statusDelta(row, statusEdge(row, rows[nextDrawn], prev));
        known?.set(row, withHeight(kept, width, height, edge, scale, open ?? rowOpenState(sessionId, row)));
      }
    }
    if (height > 0) {
      if (previousContent >= 0) gaps[index] = transcriptGap(marks[previousContent]!, marks[index]!) * gapScale;
      top += gaps[index]!;
      beforeContent = previousContent;
      previousContent = index;
    }
    tops[index] = top;
    heights[index] = height;
    top += height;
  }
  const layout = {
    tops,
    heights,
    gaps,
    marks,
    tailGap: tailGap(marks[previousContent] ?? 0, marks[beforeContent] ?? 0, footerAfter(marks, heights)) * scale,
    restBand: restBand(footerAfter(marks, heights)) * scale,
    scale,
    ...(gapFactor !== 1 ? { gapScale: gapFactor } : {}),
    totalHeight: top,
    ...(remembered ? { remembered: true as const } : {}),
    ...(rough ? { rough: true as const } : {}),
  };
  trimPreparedRows(cache);
  messages.finish(rows, layout);
  return layout;
}

/// Places rows again over `estimate`, taking a row's height from `heightAt` when it has one.
/// No row is measured, so this costs one pass over the rows' heights.
/// `kept` rows at the start keep their places from `previous` (the last placement, which they
/// had the same heights in).
export function placeRows(
  estimate: ConversationLayout,
  heightAt: (index: number) => number | undefined,
  previous?: { layout: ConversationLayout; kept: number },
  /// Where the first row starts (ConversationLayout.origin). Kept rows keep their places only at it.
  origin = 0,
): ConversationLayout {
  const tops = new Float64Array(estimate.heights.length);
  const heights = new Float64Array(estimate.heights.length);
  // The gaps take the Interface Size now, not the estimate's (it may predate a change), and the kept
  // rows keep their places only at the scale they were placed at.
  const scale = gridScale();
  const gapFactor = transcriptGapScale();
  const gapScale = scale * gapFactor;
  const kept =
    previous &&
    (previous.layout.scale ?? 1) === scale &&
    (previous.layout.gapScale ?? 1) === gapFactor &&
    (previous.layout.origin ?? 0) === origin
      ? Math.min(previous.kept, previous.layout.heights.length, heights.length)
      : 0;
  if (kept > 0) {
    tops.set(previous!.layout.tops.subarray(0, kept));
    heights.set(previous!.layout.heights.subarray(0, kept));
  }
  let top = kept > 0 ? tops[kept - 1]! + heights[kept - 1]! : origin;
  let previousContent = kept - 1;
  while (previousContent >= 0 && heights[previousContent] === 0) previousContent -= 1;
  let beforeContent = previousContent - 1;
  while (beforeContent >= 0 && heights[beforeContent] === 0) beforeContent -= 1;
  const marks = estimate.marks;
  for (let index = kept; index < heights.length; index += 1) {
    // A drawn 0 is a row that draws nothing (App.tsx drawnHeightOf): it takes no room.
    const known = heightAt(index);
    const height = known !== undefined && known >= 0 ? known : estimate.heights[index];
    if (height > 0) {
      if (previousContent >= 0)
        top += marks ? transcriptGap(marks[previousContent]!, marks[index]!) * gapScale : (estimate.gaps?.[index] ?? 0);
      beforeContent = previousContent;
      previousContent = index;
    }
    tops[index] = top;
    heights[index] = height;
    top += height;
  }
  return {
    tops,
    heights,
    gaps: estimate.gaps,
    marks,
    tailGap: marks
      ? tailGap(marks[previousContent] ?? 0, marks[beforeContent] ?? 0, footerAfter(marks, heights)) * scale
      : estimate.tailGap,
    restBand: marks ? restBand(footerAfter(marks, heights)) * scale : estimate.restBand,
    scale,
    ...(gapFactor !== 1 ? { gapScale: gapFactor } : {}),
    totalHeight: top,
    ...(origin ? { origin } : {}),
  };
}

/// `layout` with its first row starting at `origin` instead (ConversationLayout.origin): one pass
/// over the tops, run only when the room above the rows changes, never per streamed token.
export function withOrigin(layout: ConversationLayout, origin: number): ConversationLayout {
  const by = origin - (layout.origin ?? 0);
  if (by === 0) return layout;
  const tops = new Float64Array(layout.tops.length);
  for (let index = 0; index < tops.length; index += 1) tops[index] = layout.tops[index]! + by;
  const { origin: _, ...rest } = layout;
  return {
    ...rest,
    tops,
    totalHeight: layout.totalHeight + by,
    ...(origin ? { origin } : {}),
  };
}

/// A transcript placed by drawn heights: its rows' geometry (an immutable gap-aware index once
/// rows draw, the estimate's arrays before), and the estimate's marks and tail metrics. It carries
/// no `tops` or `heights` arrays: readers ask `geometry`, so a drawn height or a streamed token
/// never copies every row.
export type PlacedLayout = {
  geometry: LayoutGeometry;
  /// The content's height: the rows' end (origin included), or more where App adds room under them.
  totalHeight: number;
  gaps?: Float64Array;
  marks?: Uint8Array;
  tailGap?: number;
  scale?: number;
  gapScale?: number;
  restBand?: number;
  origin?: number;
};

/// Any placed transcript: an estimate (arrays) or a placement (geometry).
export type TranscriptLayout = ConversationLayout | PlacedLayout;

/// The geometry of either kind of layout: O(1), nothing is copied.
export const layoutGeometry = (layout: TranscriptLayout): LayoutGeometry => geometryOf(layout);

/// An estimate, unplaced, as a PlacedLayout starting at `origin` (before any row draws). O(1).
export function placedFromEstimate(estimate: ConversationLayout, origin = 0): PlacedLayout {
  const by = origin - (estimate.origin ?? 0);
  const { tops, heights, ...rest } = estimate;
  return {
    ...rest,
    geometry: geometryFromArrays(tops, heights, estimate.totalHeight, by),
    totalHeight: estimate.totalHeight + by,
    origin: origin || undefined,
  };
}

/// `layout` with its first row starting at `origin` instead (withOrigin for a placement): O(1).
export function placedWithOrigin(layout: PlacedLayout, origin: number): PlacedLayout {
  const by = origin - (layout.origin ?? 0);
  if (by === 0) return layout;
  const geometry = layout.geometry;
  const indexed = "index" in geometry ? (geometry as IndexedLayoutGeometry) : undefined;
  const moved: LayoutGeometry = indexed
    ? geometryFromIndex(indexed.index, indexed.origin + by)
    : {
        ...geometry,
        totalHeight: geometry.totalHeight + by,
        topAt: (at) => geometry.topAt(at) + by,
        upperBoundTop: (target) => geometry.upperBoundTop(target - by),
        scan: (from, to, visit) => geometry.scan(from, to, (at, top, height) => visit(at, top + by, height)),
      };
  return {
    ...layout,
    geometry: moved,
    totalHeight: layout.totalHeight + by,
    origin: origin || undefined,
  };
}

/// How far a collapsing row looks for the drawn rows on either side of it (rows that draw nothing
/// between are bookkeeping, a handful at most).
const COLLAPSE_REACH = 64;

/// A row collapsing to nothing (a read "New since you looked" line shrinking on the motion step;
/// Leo, 2026-11-17: "in the periods here"), placed so the rows under it move with it and nothing
/// steps when it reaches 0. Drawn, it sits between the drawn rows `k` above and `n` below with the
/// gaps A (k to it) and B (it to n); gone, k and n are C apart. At `f`, its drawn height over its
/// estimate (0 to 1), it is placed as a pass row (placedHeightIndex.ts PASS_MARK: no gap of its own,
/// so k and n gap as if it were not there) of height `h + f * (A + B - C)`: k to n is
/// `f * (A + h0 + B) + (1 - f) * C`, the drawn layout at 1 and the gone one at 0. Generic: any row
/// that marks itself collapsing.
export function collapsingHeight(
  index: number,
  height: number,
  estimate: ConversationLayout,
  marks: Uint8Array,
  drawnAt: (index: number) => number,
  between: (before: number, next: number) => number,
): { height: number; mark: number } {
  const full = estimate.heights[index]!;
  const f = full > 0 ? Math.min(1, Math.max(0, height / full)) : 1;
  let above = -1;
  for (let at = index - 1; at >= 0 && at >= index - COLLAPSE_REACH; at -= 1)
    if (drawnAt(at) > 0) {
      above = at;
      break;
    }
  let below = -1;
  for (let at = index + 1; at < marks.length && at <= index + COLLAPSE_REACH; at += 1)
    if (drawnAt(at) > 0) {
      below = at;
      break;
    }
  const mark = marks[index]!;
  const a = above >= 0 ? between(marks[above]!, mark) : 0;
  const b = below >= 0 ? between(mark, marks[below]!) : 0;
  const c = above >= 0 && below >= 0 ? between(marks[above]!, marks[below]!) : 0;
  return { height: Math.max(0, height + f * (a + b - c)), mark: PASS_MARK };
}

/// What a placement may skip: rows from `kept` up to `from` are the last placement's except
/// `changed` (indices in that span whose height may differ). Rows from `from` on are placed again.
export type PlacedReuse = {
  layout: PlacedLayout;
  kept: number;
  from?: number;
  changed?: readonly number[];
};

/**
 * `placeRows` through the gap-aware index (placedHeightIndex.ts): the same tops, heights, total,
 * tail gap and rest band for every input, up to float rounding of the sums. A reused placement
 * keeps its index; only `changed` rows and the rows from `from` on are read, each in O(log rows),
 * so a streamed token or a drawn height costs O(log rows + rows placed again), not O(rows).
 * With no reusable `previous` (another scale or origin, no index) every row is read once.
 */
export function placeRowsIndexed(
  estimate: ConversationLayout,
  heightAt: (index: number) => number | undefined,
  previous?: PlacedReuse,
  /// Where the first row starts (ConversationLayout.origin). Kept rows keep their places only at it.
  origin = 0,
  /// Whether a row with a drawn height is collapsing to nothing (VirtualTranscript.tsx: a row that
  /// holds `[data-row-collapsing]`): its gaps shrink with it (`collapsingHeight`).
  collapsingAt?: (index: number) => boolean,
): PlacedLayout {
  const count = estimate.heights.length;
  const scale = gridScale();
  const marks = estimate.marks;
  const gapFactor = transcriptGapScale();
  const gapScale = scale * gapFactor;
  const between = (before: number, next: number) => transcriptGap(before, next) * gapScale;
  const drawnAt = (index: number) => {
    // A drawn 0 is a row that draws nothing (App.tsx drawnHeightOf): it takes no room.
    const known = heightAt(index);
    return known !== undefined && known >= 0 ? known : estimate.heights[index]!;
  };
  /// Rows collapsing now, by index, with the height and mark they are placed at.
  const collapsing = new Map<number, { height: number; mark: number }>();
  const resolve = (index: number) => {
    const height = drawnAt(index);
    if (!marks || !collapsingAt || !(height > 0) || !collapsingAt(index)) return height;
    const placed = collapsingHeight(index, height, estimate, marks, drawnAt, between);
    collapsing.set(index, placed);
    return placed.height;
  };
  const markAt = (index: number) => collapsing.get(index)?.mark ?? marks?.[index];
  /// `marks` from `from` to `to`, with the collapsing rows' marks among them.
  const marksIn = (from: number, to: number) => {
    if (!marks) return undefined;
    let out: Uint8Array | undefined;
    for (const [at, placed] of collapsing)
      if (at >= from && at < to) (out ??= marks.slice(from, to))[at - from] = placed.mark;
    return out ?? marks.subarray(from, to);
  };
  const prior = previous?.layout.geometry;
  const reusable =
    previous &&
    prior &&
    "index" in prior &&
    (previous.layout.scale ?? 1) === scale &&
    (previous.layout.gapScale ?? 1) === gapFactor &&
    (previous.layout.origin ?? 0) === origin &&
    Boolean(previous.layout.marks) === Boolean(marks)
      ? (prior as IndexedLayoutGeometry).index
      : undefined;
  const kept = reusable ? Math.max(0, Math.min(previous!.kept, reusable.count, count)) : 0;
  let index: PlacedHeightIndex;
  if (!reusable || kept === 0) {
    const heights = new Float64Array(count);
    for (let at = 0; at < count; at += 1) heights[at] = resolve(at);
    index = PlacedHeightIndex.fromRows(heights, marksIn(0, count), marks ? undefined : estimate.gaps, {
      between: marks ? between : undefined,
    });
  } else {
    index = reusable;
    const from = Math.max(kept, Math.min(previous!.from ?? kept, reusable.count, count));
    for (const at of previous!.changed ?? [])
      if (at >= kept && at < from) {
        const height = resolve(at);
        index = index.update(at, height, markAt(at), marks ? undefined : estimate.gaps?.[at]);
      }
    const tail = new Float64Array(count - from);
    for (let at = from; at < count; at += 1) tail[at - from] = resolve(at);
    index = index.splice(from, tail, marksIn(from, count), marks ? undefined : estimate.gaps?.subarray(from, count));
  }
  const geometry = geometryFromIndex(index, origin);
  // A turn footer that draws nothing after the last drawn row (transcriptGrid.ts footerAfter):
  // only the trailing rows that draw nothing are read.
  let footer = false;
  if (marks)
    for (let at = count - 1; at >= 0 && index.heightAt(at) === 0; at -= 1)
      if (index.markAt(at) === MARK_FOOTER) {
        footer = true;
        break;
      }
  const { last, beforeLast } = index.lastMarks;
  return {
    geometry,
    totalHeight: geometry.totalHeight,
    gaps: estimate.gaps,
    marks,
    tailGap: marks ? tailGap(last, beforeLast, footer) * scale : estimate.tailGap,
    restBand: marks ? restBand(footer) * scale : estimate.restBand,
    scale,
    ...(gapFactor !== 1 ? { gapScale: gapFactor } : {}),
    ...(origin ? { origin } : {}),
  };
}

export function visibleLayoutRange(
  layoutModel: TranscriptLayout,
  scrollTop: number,
  viewportHeight: number,
  overscan = 4,
) {
  const geometry = layoutGeometry(layoutModel);
  if (geometry.count === 0) return { first: 0, last: 0 };
  const first = Math.max(0, geometry.upperBoundTop(Math.max(0, scrollTop)) - 1 - overscan);
  const last = Math.min(geometry.count, geometry.upperBoundTop(scrollTop + viewportHeight) + overscan);
  return { first, last };
}

export type RowRange = { first: number; last: number };

/// Sorted, non-overlapping ranges covering every row of `ranges`.
export function mergeRowRanges(ranges: RowRange[]): RowRange[] {
  const merged: RowRange[] = [];
  for (const range of [...ranges].filter((each) => each.last > each.first).sort((a, b) => a.first - b.first)) {
    const previous = merged.at(-1);
    if (previous && range.first <= previous.last) previous.last = Math.max(previous.last, range.last);
    else merged.push({ ...range });
  }
  return merged;
}

/// How uneven a scroll's next jump is against its last, as a share of it, that the views
/// `scrollLeadRanges` builds ahead of a jump still cover (frame-time jitter of a paced fling).
export const PREDICTED_JITTER = 0.05;

/// The rows a transcript at `scrollTop` mounts while it moves `delta` per scroll: the view and
/// `steps` scrolls of motion ahead of it, capped at `maxLead`. A scroll whose lead runs past the cap
/// also mounts each view the next `steps` frames reach, with a margin for uneven frames: the rows
/// between them are never on screen, so they are not built (cx-j33s4). A jump (more than a view a
/// frame: a fling or a scrollbar drag) mounts its view alone.
/// A moving scroll within the cap also keeps `trail` px behind the view mounted: the rows the
/// reader just passed, already drawn. Dropping them the moment they left the view made a quick
/// reversal (up and down fast) scroll the compositor into bare background for a frame before its
/// commit drew them again (Leo, 2026-11-08: "hard cutoffs where there's no text at all"). A fling
/// past the cap skips it: the rows behind a jump were never mounted, and building them costs a frame.
export function scrollLeadRanges(
  layoutModel: TranscriptLayout,
  scrollTop: number,
  delta: number,
  viewportHeight: number,
  steps: number,
  maxLead: number,
  trail = 0,
): RowRange[] {
  const lead = Math.min(Math.abs(delta) * steps, maxLead);
  // A scroll that moves more than a view in one frame never shows the rows between this frame's view
  // and the next one's: it is a jump, however far the cap reaches. A fling of 1,500 to 3,000 px a frame
  // (2 to 4 views) built the contiguous lead of up to 4 views a frame, about three times the rows any
  // frame drew, and the first layout read after the commit paid their restyle (Leo, 2026-11-16: "as
  // in i scroll up and it loads the shit").
  const jumping = Math.abs(delta) > Math.min(maxLead, viewportHeight);
  if (!jumping && Math.abs(delta) * steps <= maxLead) {
    const behind = delta === 0 ? 0 : trail;
    const top = delta < 0 ? scrollTop - lead : scrollTop - behind;
    return [visibleLayoutRange(layoutModel, top, viewportHeight + lead + behind)];
  }
  // A jump lands past the rows between the views, so each of its frames mounts its view, not the rows
  // it jumps over: a fling of tens of viewports a frame (a god
  // session) built 5 viewports of rows a frame that no frame showed. A view it lands short of (a drag
  // that stops) is mounted by the commit that draws it.
  const contiguous = jumping ? 0 : lead;
  // A jump's rows a frame are a view the next frame leaves: one row of overscan, not a margin's worth.
  const overscan = jumping ? 1 : undefined;
  const ranges = [
    visibleLayoutRange(
      layoutModel,
      delta < 0 ? scrollTop - contiguous : scrollTop,
      viewportHeight + contiguous,
      overscan,
    ),
  ];
  // A jump builds no view ahead of it. The view the next frame would reach, with the viewport of
  // margin either side its frame-to-frame unevenness needed, was three views of rows built and
  // measured (each new row's height read back from layout) in the commit of a frame that showed one;
  // a fling's next frame builds its own view in its own commit anyway. In one harness at 3,000 rows,
  // dropping it took fling React p95 from 57 to 24 ms (Chromium) and 30 to 22 ms (WebKit, 7 pairs),
  // with no blank frame either way (2026-11-24).
  if (jumping) return ranges;
  const margin = Math.min(Math.abs(delta) / 4, viewportHeight / 2);
  // The next views are built only while their margin holds a frame's unevenness (a few percent of
  // its jump): past that, the next frame lands outside the window it built as often as in it, and
  // the view it lands on is built in its own commit anyway.
  if (margin < Math.abs(delta) * PREDICTED_JITTER) return ranges;
  for (let step = 1; step <= steps; step += 1)
    ranges.push(
      visibleLayoutRange(layoutModel, scrollTop + delta * step - margin, viewportHeight + 2 * margin, overscan),
    );
  return mergeRowRanges(ranges);
}
import {
  layout,
  layoutNextLineRange,
  measureNaturalWidth,
  prepare,
  prepareWithSegments,
  clearCache as clearTextCaches,
  type LayoutCursor,
  type PreparedText,
  type PreparedTextWithSegments,
} from "@chenglou/pretext";
import { lexer, Tokenizer, type Token, type Tokens } from "marked";
import { runStretches, staysInSight, stretchStart, toolGroups, type ToolGroup } from "./conversation/toolGroups";
import {
  callDisclosureKey,
  callDisclosureKeys,
  disclosureOpen,
  sendDisclosureKey,
} from "./conversation/transcriptDisclosureModel";
import { groupDisclosureKey, runDisclosureKey, runLinks, thoughtIds } from "./conversation/turnRowsModel";
import { thoughtChoices } from "./conversation/thoughtChoices";
import { PREVIEW_LINES } from "./conversation/blockPartsModel";
import { blockWrapOf, fileBlockKind } from "./conversation/blockWrap";
import { toolFiles, type TurnFile } from "./diff";
import { cardOpen } from "./turnChanges/openStore";
import { runScroll } from "./conversation/runScroll.experiment";
import { acpmuxSendCalls } from "./conversation/acpmuxSends";
import { isFoldedRun } from "./conversation/toolRunSummary";
import { isQuietThought, isThought, mergeThoughts, thoughtParts } from "./conversation/thoughts";
import { RENDER_FRAME_MIN_HEIGHT } from "./conversation/renderCall";
import {
  DATE,
  isEmptyFooter,
  isFoldedCopy,
  NEXT_STEP,
  RENDER,
  THINKING,
  WALKTHROUGH,
  WORKED,
  WORKING,
} from "./conversation/turns";
import type { Walkthrough } from "./conversation/walkthroughModel";
import type { AcpmuxSessionEntry } from "./sessionList";
import { agentName } from "./agents";
import { type Translate, translate, currentLanguage } from "./i18n";
import { recapHeight } from "./conversation/recapPoints";
import { lastBlockBoundary } from "./conversation/incrementalMarkdown";
import { chiefEnvelope } from "./conversation/chiefEnvelope";
import { chatColumn, type ChatColumn } from "./chatWidth";
import {
  chatCodeBlock,
  chatDensityTextScale,
  chatDisplay,
  chatDisplayVariables,
  currentChatMetrics,
  type ChatMetrics,
  drawnFontSize,
  promptCoachEnabled,
  transcriptGapScale,
} from "./chatDisplay";
import { EDIT_DIFF_LANE, editDiffBox } from "./conversation/editDiffBox";
import { experimentSwitchOn } from "../../experiments/switches";
import { userBubbleBox } from "./conversation/transcriptLook";
import { messageOpened } from "./conversation/incomingOpened";
import { rowOpenState } from "./conversation/rowOpenState";
import { inboxThreadKey } from "./conversation/inboxNotice";
import { foldsThreads, inboxNoticeLook } from "./conversation/inboxNoticeLook";
import { noticeRowLook } from "./conversation/noticeRowLook";
import { fitsLine, newestWholeKey, readForIds, THREAD_PAGE, threadRead } from "./conversation/inboxThreadRead";
import { inboxThreadLook } from "./conversation/inboxThreadLook";
import { CLAMP_MORE_HEIGHT, CLAMPED_LINES } from "./conversation/lineCut";
import { laneNotice } from "./conversation/laneReport";
import { receivedLook } from "./conversation/receivedLook";
import { MESSAGE_PREVIEW_LINE_PT, messageLineLook } from "./conversation/messageLineLook";
import { isDiagram, isUnlabeledLang } from "./conversation/codeShape";
import type { SurgeHold } from "./conversation/surgeHold";

/// The pane's fallback accessible name and problem-only header status. A handshake that is
/// retrying (`connecting:`) says nothing here: the pane's retries are quiet, and a failure that
/// lasts is the one line above the composer (HostError.tsx HostUnavailableLine), never a header
/// Reconnecting (Leo, 2026-10-29: "STOP SHOWING FUCKING BULLSHIT ON LOAD"). `hostRecovering`: the
/// pane is asking the host again after its daemon went away, so a dropped socket is quiet too.
export function paneHeader(
  snapshot: AcpmuxSnapshot,
  t: Translate = translate,
  { hostRecovering = false }: { hostRecovering?: boolean } = {},
): { title: string; status: string; detail?: string } {
  const harness = snapshot.summary?.harness;
  const title = harness
    ? agentName(harness, snapshot.catalog?.find((entry) => entry.id === harness)?.name)
    : t("header.agentChat");
  // Initial connecting, retrying and normal turn events are quiet.
  const connection = snapshot.connection;
  const failed = /^(error|failed)(:|$)/i.test(connection) || connection === "fork failed";
  const status =
    connection === "disconnected" && !hostRecovering ? t("header.disconnected") : failed ? t("header.failed") : "";
  if (!status) return { title, status };
  const reason = connection.includes(":") ? connection.slice(connection.indexOf(":") + 1).trim() : undefined;
  let rowError: string | undefined;
  if (failed && !reason) {
    for (let index = snapshot.rows.length - 1; index >= 0; index--) {
      rowError = snapshot.rows[index]?.error;
      if (rowError) break;
    }
  }
  return { title, status, detail: reason || rowError || status };
}

/** Where acpmux's start model or effort comes from: `saved` (acpmux defaults or the person's
 * pick), `profile` (the harness profile's own), `catalog` (the model catalog's default). */
export type StartSource = "saved" | "profile" | "catalog";
