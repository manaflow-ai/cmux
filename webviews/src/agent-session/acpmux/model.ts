import type { MachineResources } from "./machineResources";
import type { VideoInfo } from "./composer/videoAttachments";
import type { AttachmentSource } from "./attachments";
import type { HarnessIconSpec } from "../shared/harnessIcons";
import type { ChatUnavailable } from "./chatUnavailable";
import type { ChatPresence, Participant } from "./multiplayer/participants";
import { editedPaths } from "./toolPaths";
import type { PermissionClientState } from "./permissions/protocol";
import type { AgentQuestion } from "./question/model";
import type { WatchedAsk } from "./needsYou/model";
import type { PermissionDecision } from "./permissions/record";
import type { HandoffClientState } from "./handoff/client";
import type { SessionUsageStats } from "./usageStats";
import type { Enforcement } from "./handoff/protocol";
import type { SlashCommand } from "./slashCommands";
import type { SummaryCheckpoint } from "./changes/turnCheckpointSource";
import type { IncomingMessage, IncomingPrompt } from "./conversation/incomingMessage";
import type { TurnCopyPart } from "./conversation/turnCopy";
import { appHref, linkHref, safeHref } from "./replyHref";
import type { ShellRun } from "./shell/shellRuns";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";
import { BACKGROUND_TURN } from "./conversation/backgroundTurns";
import type { SubagentRetryNotice } from "./subagents/retryState";
import {
  isRunGroup,
  SUBAGENT_DONE,
  SUBAGENT_EMPTY,
  SUBAGENT_OF,
  SUBAGENT_ROW,
  WORKFLOW_CARD,
} from "./subagents/subagentRows";
import type { ComposerAttachment } from "./attachments";
import { STARTED_SESSIONS, type StartedSession, hasStatusLine } from "./started/startedSessions";
import {
  PASTE_CHIP_HEIGHT,
  type PasteRange,
  HUGE_PROMPT_HEAD_CHARS,
  collapsedPromptHeight,
  hasHugeTypedPart,
  isHugePrompt,
  promptHead,
  promptParts,
} from "./conversation/promptCollapse";
import { mcpCall } from "./conversation/mcpCalls";
import { subsessionCall } from "./conversation/subsessionCalls";
import { agentMessage } from "./conversation/agentMessages";
import type { ChatTool } from "./summary/chatTools";
import type { TaskGoal } from "./goal";
import { MessagePlacement } from "./conversation/messagePlacement";
import { isVisiblyEmptyMessage } from "./conversation/visibleMessage";

/** One item of an agent's todo list (an ACP `plan` entry). */
export type AcpmuxPlanEntry = { content: string; status: "pending" | "in_progress" | "completed" };

/** How a background shell ended (acpmux `background_task_update`, cx-ncc.84). */
export type AcpmuxBackgroundTask = {
  toolCallId: string;
  command: string;
  state: "completed" | "failed" | "stopped";
  reason?: string;
  /// Claude Code's own words on how it ended (its task notification's summary).
  summary?: string;
  /// The exit code, when the harness reports one (Codex does; Claude Code does not).
  exitCode?: number;
};

/// A shell call's life in the background, on the call that started it (direct.ts
/// `markBackgroundCall`): running there, then how it ended and when (epoch ms). Its "Ran" row draws
/// it (conversation/BackgroundMark.tsx); a separate background task row is only for a shell whose
/// call is not in the transcript.
export type AcpmuxBackgroundState = {
  state: "running" | AcpmuxBackgroundTask["state"];
  reason?: string;
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
};

/// The chat's permission policy (an acpmux policy id narrower than approve-all) that its harness
/// cannot keep (a `policy_unenforced` record): OpenCode's own settings decide what it asks
/// (`ownSettings`); another harness has no mode that asks (`noAskingMode`).
export type AcpmuxPolicyUnenforced = { policy: string; why: "ownSettings" | "noAskingMode" };

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
/// `session_info_update._meta.claude`): drawn once, where the session started
/// (conversation/SessionStartNote.tsx). `harness` and `cwd` are the chat's when the line came.
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
export type PromptDelivery = {
  state: PromptDeliveryState;
  promptId: string;
  sessionId: string;
  /// When the pane wrote `session/prompt`, acpmux recorded it, and the agent started on it.
  sentAt: number;
  acceptedAt?: number;
  readAt?: number;
  failedAt?: number;
  /// No answer for a while: the row says it is still sending.
  slow?: boolean;
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
  inlineParts?: PromptContentPart[];
  /// Another agent's message waiting here (direct.ts `queuedMessage`): it draws in the transcript
  /// as the message's received card (conversation/queuedMessages.ts), never as a queue row.
  message?: IncomingMessage;
  /// A teammate's prompt in a shared chat (its `person_message` provenance): its row names them,
  /// and only they may change it (acpmux refuses another author's edit with `queue.not_author`).
  author?: Participant;
  /// acpmux's ask to resume a failed subagent (subagents/retryState.ts `subagentRetryNotice`): its
  /// row names the subagent instead of drawing the prompt's text.
  retry?: SubagentRetryNotice;
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
      source?: AttachmentSource;
    };
/// A queued prompt's image: `src` is its data URL when the pane has its bytes (it sent them, or
/// the `queued` record carries them), else the row reads it by `id`. acpmux names an image by the
/// SHA-256 of its bytes; one the pane only sent so far has the composer's id (`local`) until
/// acpmux names it, so an edit cannot keep or drop it by id yet.
export type QueuedPromptImage = PromptImage & { src?: string; local?: boolean };

/// A turn's tokens as Anthropic counts them: what the model wrote (`output`) apart from what it read,
/// which is the fresh input, the prompt cache's reads and its writes. The running line adds up each
/// model call's (direct.ts `turnTokenSplit`); a finished turn's comes from its `turn_result`.
export type TurnTokenSplit = { output: number; input: number; cacheRead: number; cacheWrite: number };

export type AcpmuxRow = {
  id: string;
  version: number;
  at: number;
  kind: string;
  /// The acpmux event a turn summary came from, where a fork through that turn ends.
  seq?: number;
  /// The daemon's stable identity for a turn. Turn results can be replayed with a new seq, so
  /// transcript rows that belong to one turn use this identity when it is available.
  turnId?: string;
  text?: string;
  streaming?: boolean;
  pending?: boolean;
  failed?: boolean;
  /// A prompt this pane sent: where it is on its way (PromptDelivery).
  delivery?: PromptDelivery;
  items?: AcpmuxActivity[];
  /// A plan row's todo list (cx-ncc.80): the agent's latest `plan` update in its turn.
  plan?: AcpmuxPlanEntry[];
  /// A background task row's shell, which ended where the row sits (cx-ncc.84).
  backgroundTask?: AcpmuxBackgroundTask;
  /// A compaction row's compaction, noted where it happened.
  compaction?: AcpmuxCompaction;
  /// A failover row's harnesses.
  failover?: AcpmuxFailover;
  /// A background turn's line (conversation/backgroundTurns.ts): the turn it stands for.
  background?: AcpmuxBackgroundTurn;
  /// A row a background turn made: that turn's id, so its line can fold it (backgroundTurns.ts).
  inBackground?: string;
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
  inboxQueue?: { promptId: string; next?: boolean; lead?: boolean; heldByStop?: boolean };
  /// A prompt the person did not type (a task's result, another agent's message, bookkeeping),
  /// whether or not it draws as one: prompt recall leaves it out (composer/promptHistory.ts).
  untyped?: boolean;
  /// A started sessions row's chats, oldest first (started/StartedSessionCard.tsx).
  started?: StartedSession[];
  toolCount?: number;
  durationMs?: number;
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
  /// The originating prompt row, so Retry can restore image/PDF attachments.
  retryRowId?: string;
  /// A turn summary of the chat's last turn, which a failed turn's Retry asks acpmux to retry
  /// (turns.ts), even when its prompt is an attempt acpmux sent and draws nothing.
  retryable?: boolean;
  /// A turn footer's answer row (turns.ts), whose right-click menu the footer's More opens.
  answerId?: string;
  /// A turn footer's whole turn for its Copy (conversation/turnCopy.ts): the agent's replies and each
  /// run of tool calls between them, in order; undefined when the agent said nothing.
  turnCopy?: TurnCopyPart[];
  retryAttachments?: ComposerAttachment[];
  status?: string;
  error?: string;
  /// acpmux's typed reason for a failed turn (`errorCode`, a string), for its card (failureCopy.ts).
  errorCode?: string;
  permission?: AcpmuxPermission;
  /// A `questionRecord` row's question, answered or cancelled (question/record.ts).
  question?: AgentQuestion;
  /// A `permissionRecord` row's answer, its ask in `permission` (permissions/record.ts).
  decision?: PermissionDecision;
  /// A turn summary whose turn draws a "Worked for" line (conversation/turns.ts), so its
  /// footer need not repeat the time and count.
  folded?: boolean;
  /// A Worked-for row's actual open state, including a provisional key from paged history.
  foldOpen?: boolean;
  /// Work shown inside an open "Worked for": its turn has ended.
  settled?: boolean;
  /// A reply to the person (not a short note) shown inside an open "Worked for": settled, yet it
  /// keeps its own action row (hasReplyActions; conversation/turns.ts shapeTurn).
  foldedReply?: boolean;
  /// A run of finished tool calls folded under one summary line (Debug toggle
  /// `agentPane.debug.codexToolRuns`, on by default; conversation/turns.ts `codexRuns`,
  /// conversation/toolRunSummary.ts).
  /// False keeps a run waiting for edit permission in tool rows without collapsing it.
  foldRun?: boolean;
  /// The live turn's latest row, whose last thought may still stream (conversation/turns.ts).
  live?: boolean;
  /// A running turn's status line: the title of the call in flight, which it names (WorkingFor.tsx).
  doing?: string;
  /// A running turn's status line before the turn's first output: it reads "Thinking" beside the
  /// turn's time (WorkingFor.tsx).
  thinkingNow?: boolean;
  /// A running turn's status line drawn as the turn's last row (Debug Settings
  /// `agentPane.debug.liveLineBelow`, conversation/turns.ts): no rule under it, and its clock
  /// never stops while the turn runs.
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
  /// `doing` names the latest step, finished, which the live line holds until the next step
  /// (conversation/turns.ts `liftedStep`): "Ran grep …".
  doingDone?: boolean;
  /// The call in flight sends another agent a message (conversation/turns.ts `sendingTo`: a shell
  /// `acpmux send`, a sub-session's `send_message`): the line reads "Sending message to
  /// <doingSendTo>", and the sub-session `doingSendSession` by its name once the list has it.
  doingSendTo?: string;
  doingSendSession?: string;
  doingDraft?: boolean;
  untimed?: boolean;
  quietKey?: string;
  /// The call in flight is a command: the line offers "⌃B to run in background" (BackgroundHint.tsx;
  /// never on the command's own row), and leads with the terminal glyph when it names it
  /// (WorkingFor.tsx).
  doingCommand?: boolean;
  /// The disclosure of the group that draws the call's own row, and whether it opens by default: while
  /// it is open the row names the call, so the line does not (conversation/turns.ts `ownRow`).
  doingGroup?: string;
  doingGroupOpen?: boolean;
  /// A "Worked for" disclosure of a turn without timing reads "N previous messages" (conversation/turns.ts).
  previous?: number;
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
  /// A waiting steer's promptId, which its Send now names (conversation/PendingSteer.tsx).
  steerPromptId?: string;
  /// A prompt's promptId as acpmux recorded it (its `user_message` record's): the thread rail keys
  /// its tick on it, the same live, after acpmux's echo and when the history is read again.
  promptId?: string;
  /// The last turn's footer carries its prompt, for Retry (conversation/turns.ts).
  prompt?: string;
  /// The last turn's footer when the reader stopped that turn and nothing followed: it offers
  /// Continue (conversation/turns.ts, TurnRows.tsx TurnFooter).
  resumable?: boolean;
  /// The last turn's footer when that turn failed after doing work, or with no prompt to send again
  /// (a turn a notice started): its error card leads with Continue, which resumes the turn with its
  /// context, instead of Retry (conversation/errorRecovery.ts).
  continuable?: boolean;
  /// An edited-files card of a turn that has ended, which offers Undo (conversation/turns.ts).
  ended?: boolean;
  /// A todo list whose turn has ended: a step left in progress no longer spins (conversation/turns.ts).
  turnEnded?: boolean;
  /// The final drawn row of a latest turn that has no turnSummary. It keeps the same turn gap as a
  /// footer without adding a permanent runway under every turn (conversation/turns.ts).
  lastTurn?: boolean;
  /// The edits an edited-files card merges (their row ids), so Find reaches each (chatFind.ts).
  merged?: string[];
  /// The rows a run absorbed (conversation/turns.ts `mergeShortNotes`): its own, the short note and
  /// the run after it, so Find and a shell's count reach each (chatFind.ts).
  joined?: string[];
  /// The messages other sessions sent that the agent has not read yet, drawn as one group
  /// (conversation/pendingMessages.ts, PendingMessagesCard.tsx), each once, oldest first.
  pendingMessages?: { rows: readonly AcpmuxRow[]; displayRows?: readonly AcpmuxRow[]; flat?: boolean };
  /// A received row expanded from an inbox notice; used to keep its waiting run flat.
  inboxDelivery?: true;
  inboxDeliveryBatch?: true;
  /// Metadata retained for a preview-only inbox delivery so opening it can hydrate its thread.
  inboxThread?: {
    threadId: string;
    label?: string;
    sender: string;
    preview: string;
    count: number;
    promptIds: readonly string[];
    fromSession?: string;
    fromHarness?: string;
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
    inputSummary?: string;
    output?: string;
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
export type AcpmuxLocation = { path: string; line?: number; canonical?: string };

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
export type AcpmuxSecretAsk = { secretId: string; name: string; reason: string };

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
export type AcpmuxOfferResult = { offerId: string; childSessionId: string; title: string };

/** The concrete app, resource, or working directory an approval covers. */
export type AcpmuxPermissionScope = { kind: "app" | "resource" | "directory"; value: string };

export type AcpmuxPermission = {
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
  categories: { id?: string; name: string; tokens: number; kind: "used" | "free" | "buffer" | "deferred" }[];
  memoryFiles: { path: string; type: string; tokens: number }[];
  mcpTools: { name: string; serverName: string; tokens: number }[];
  /// Only when skills take context.
  skills?: { name: string; tokens: number }[];
  totalTokens: number;
  maxTokens: number;
};

/// A Claude Code chat's plan usage limits as acpmux reports them (claude_stdio `usage_limits`):
/// `id` is `session` (5 hours), `weekly`, `weekly_opus` or `weekly_sonnet`; `usedPercent` is 0-100;
/// `resetsAt` is unix seconds, only when Claude Code said when the window resets.
export type AcpmuxUsageLimits = { windows: { id: string; usedPercent: number; resetsAt?: number }[] };

/// Optional Labs workflow payload. acpmux does not emit this field yet; keeping the wire shape
/// here gives the future event a typed adapter seam without deriving workflow state from rows.
export type AcpmuxWorkflowWire = {
  id: string;
  title: string;
  state: "pending" | "running" | "paused" | "completed" | "failed";
  phase?: string;
  phases?: { id: string; name: string; state: "pending" | "running" | "completed" | "failed"; agentIds?: string[] }[];
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

export type AcpmuxSnapshot = {
  type: "snapshot";
  protocolVersion: number;
  rows: AcpmuxRow[];
  /// Each subagent's own view by subagent id: its rows, opened from its line in a group
  /// (subagents/childRows.ts).
  subagentViews?: Record<string, AcpmuxRow[]>;
  /// Agent ids whose usage/progress changed in this snapshot. This lets rows subscribe without
  /// rescanning every agent on a token update.
  subagentProgress?: Record<
    string,
    { agents?: { done: number; started: number; failed?: number; queued?: number }; tokens?: number; toolUses?: number }
  >;
  /// Monotonic structural revision for the subagent list; usage-only updates do not change it.
  subagentStructureVersion?: number;
  sessions: AcpmuxSessionEntry[];
  /// Who else has a shared chat open and who of them types (multiplayer/participants.ts).
  presence?: ChatPresence;
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
  /// Each peer's cached one-minute resource reading, as bounded by the pane's native status filter.
  peerResources?: Record<string, MachineResources>;
  /// The open chat is a fork: the seq of its `forked` event, where the copied history ends (cx-ncc.61).
  forkedAtSeq?: number;
  summary?: {
    sessionId: string;
    cwd?: string;
    turnCount?: number;
    /// Context-window tokens used of the session's window, from the agent's last usage update, and
    /// `setup`, the part the agent took before the conversation (its system prompt, tools and
    /// memory), when the harness reports it (`_meta.acpmux.setup`).
    usage?: { used: number; size: number; setup?: number };
    /// What the context holds by category, as Claude Code's /context said after the last turn
    /// (acpmux `contextBreakdown`); unset for other harnesses. Each list holds at most 50 rows,
    /// the largest.
    contextBreakdown?: AcpmuxContextBreakdown;
    /// What the session spends (acpmux `usageStats`, usageStats.ts): 24h tokens and cost, its
    /// autocompact cap, its subagents. Unset while the harness has no readable transcript.
    usageStats?: SessionUsageStats;
    host?: string;
    peer?: string;
    hostKind?: "local" | "cloud";
    branch?: string;
    worktree?: string;
    title?: string;
    name?: string;
    /** Codex's persisted thread goal, when the harness reported one. */
    goal?: TaskGoal;
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
    /// The MCP servers the harness says it loaded (acpmux `mcpServers`, from Claude Code's
    /// system/init); unset when it reports none (every ACP harness).
    mcpServers?: { name: string; status: "connected" | "failed" | "pending" }[];
    /// How many of the chats its agent started run a turn at once (acpmux `subsessionLimits`, from the attach reply's detail
    /// and its `limits` records); unset from an acpmux without the limit.
    subsessionLimits?: SubsessionLimits;
    status?: string;
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
  /// acpmux reconnects a Claude Code chat's failed MCP server for this connection: its `initialize`
  /// lists `_acpmux/mcp/reconnect` (an older acpmux does not), so Session Info's Connectors offer
  /// Reconnect.
  reconnectsMcp?: boolean;
  /// The client has read the daemon's chat list once: `sessions` is the daemon's, not the empty
  /// list a connection starts with (newtab/chatStore.ts publishes only such a list).
  listedSessions?: true;
  /// This page drew the chat from a kept tail (tailCache.ts) rather than from acpmux's attach, so
  /// its rows were on screen in the frame the open landed on. The pane's host reads it in the
  /// page's first-paint report: a chat read cold fades in over the loading state, this one shows
  /// in one frame (AgentPaneView+Loading.swift).
  drewKeptTail?: true;
  /// The selected peer chat is drawn from the Mac's copy of it (peerCopy.ts), not yet read from its
  /// machine; `offline` while that machine does not answer, when the pane marks it possibly stale.
  peerCopy?: import("./peerCopy").PeerCopyState;
  /// The selected chat's rows are in this snapshot (its attach page, or a kept tail), or none is
  /// selected: the first-paint report may say the chat is on screen (App.tsx `chatDrawn`).
  chatRead?: true;
  sessionId?: string;
  isWorking: boolean;
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
  /// The running turn's agent has said nothing since its prompt, past acpmux's `silentTurnMs`
  /// (direct.ts `silentTurn`): the turn's line says the model has not answered.
  silentTurn?: true;
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
  permission?: AcpmuxPermission;
  /// How many more asks wait behind `permission`, answered one at a time; absent when none do.
  permissionsWaiting?: number;
  secret?: AcpmuxSecretAsk;
  /// Every chat's open permission requests, for the Needs you list (needsYou/asks.ts); the same
  /// array until one comes or goes.
  asks?: WatchedAsk[];
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
    /** `_acpmux/harnesses` `start`: the model and effort acpmux starts a new chat here on (the
     * person's saved pick, else the catalog's default; acpmux start_defaults.rs). */
    start?: { model?: string; effort?: string; modelSource?: StartSource; effortSource?: StartSource };
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
  earlierPrompts?: readonly AcpmuxRow[];
  /**
   * The chat's prompt count from its summary (`turnCount`), while the pane does not hold every prompt
   * yet (the prompt index has not answered, or the daemon has none) and older history is left: the
   * thread rail starts at the height that many prompts take. Absent once `earlierPrompts` is read.
   */
  promptCount?: number;
  /** The oldest event seq the pane holds: it moves with each older read, even one that drew no row. */
  historyFrom?: number;
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
  /// Measured text by its source, kept across a streaming row's versions; null where it can't be measured.
  prepared: Map<string, PreparedText | null>;
  /// A plain user row's final line height, keyed by text, font, line height and width.
  plainHeight?: { key: string; height: number };
};

export type ConversationLayout = {
  tops: Float64Array;
  heights: Float64Array;
  totalHeight: number;
};

/// Metrics of conversation/conversation.css (`--cv-font-size`, `--cv-line-height`, `.cv-*`): the
/// text font, its line and the code sizes follow the user's chat look (chatDisplay.ts), 14px
/// system-ui on 22.75px lines and 12px code on 20px lines by default.
const metrics = () => currentChatMetrics();
/// Vertical padding of a user bubble (`.cv-user__bubble`).
const USER_BUBBLE_PADDING = 16;
/// The status line under a queued prompt (`.cv-user__status`: 4px above a 16px line).
const USER_STATUS_HEIGHT = 20;
/// The transcript's rhythm (`--cv-meta-gap`, `--cv-meta-row`, `--cv-message-gap` and `--cv-turn-gap`
/// in conversation/conversation.css): a meta row 4px under its message on a 24px line, 8px between
/// messages, 16px between turns (the paragraph gap plus a small separator).
const META_GAP = 4;
const META_ROW = 24;
const MESSAGE_GAP = 8;
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
const TOOL_RUN_TOP = 2;
const TOOL_ROW_HEIGHT = 22;
const TOOL_RUN_BOTTOM = 4;
/// A one-line row that is not a tool run (`isLineRow`) draws on the same line in the same frame as a
/// one-call run: 2px over its 22px line, 4px under it (`.acpmux-row--line` in conversation.css), and
/// none of either beside another step row, so every one-line row sits one line from the next (Leo,
/// 2026-11-01: "doesn't make sense for these to be spaced differently"). Inside a group, a member is
/// its line alone.
const LINE_FRAME = TOOL_RUN_TOP + TOOL_RUN_BOTTOM;
const LINE_ROW = LINE_FRAME + TOOL_ROW_HEIGHT;

/// Ordinary tool rows use the compact rhythm. Notes and specialized MCP cards keep a conservative
/// estimate until their renderer reports its measured height (a wait can contain several three-line replies).
/// A short interim note folded into a run (conversation.css `.cv-tool-note`): one 20px line with
/// the plain status gap above and below it.
const NOTE_LINE = 20;
const NOTE_GAP = 12;
function activityStepHeight(item: AcpmuxActivity): number {
  const tool = item.tool;
  if (!tool) return item.kind === "note" ? NOTE_LINE + 2 * NOTE_GAP : 26;
  // A message to another agent (SendMessage, `acpmux send`, a sub-session's `send_message`) is one
  // line on the tool rows' line (AgentMessageRow.tsx), as every one-line row is.
  if (agentMessage(tool)) return TOOL_ROW_HEIGHT;
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
        ) + TOOL_ROW_HEIGHT,
      );
    // A start's card, its doing line while it starts, and its prompt (cut like a reply).
    if (subsession.tool === "start" && subsession.prompt)
      return cardHeight("working") + replyHeight(subsession.prompt) + TOOL_ROW_HEIGHT;
    // A message sent to a sub-session is the sent-message row a shell `acpmux send` draws
    // (SubsessionCallCard.tsx SentLine, SentMessageLine.tsx): one tool row.
    if (subsession.tool === "send") return TOOL_ROW_HEIGHT;
    return 40;
  }
  switch (tool.kind) {
    case "execute":
    case "read":
    case "edit":
    case "delete":
    case "move":
    case "fileChange":
    case "search":
    case "fetch":
      return TOOL_ROW_HEIGHT;
    default:
      return 26;
  }
}
/// A folded run's lines as ToolRows draws them (TurnRows.tsx, toolGroups.ts `runStretches`): the
/// work between coordination cards folds under one summary line per stretch, and every card the run
/// keeps in sight is its own row. A run of agent-to-agent messages ("Sent to lane-a", a command,
/// "Sent to lane-b") is a line per entry, not the one summary line a run of plain work is, or each
/// such run grows by its other lines when it mounts and the scroll thumb jumps (Leo, 2026-10-25:
/// "when I'm seeing all of these agent messages back and forth, that's when it sort of, like, gets
/// confused").
function foldedRunSteps(row: AcpmuxRow, groups: readonly ToolGroup[]): number {
  return runStretches(row, groups).reduce(
    (height, stretch) =>
      height +
      (stretch.fold ? TOOL_ROW_HEIGHT : stretch.groups.reduce((sum, group) => sum + foldedGroupHeight(group), 0)),
    0,
  );
}

/// An entry a folded run keeps on its own line: a group starts closed there (ToolGroupRow.tsx
/// `folded`), one line, as a sent message's row is (SentMessageLine.tsx); anything else is its calls.
function foldedGroupHeight(group: ToolGroup): number {
  if (group.type === "group" || group.type === "send") return TOOL_ROW_HEIGHT;
  return ("items" in group ? group.items : [group.item]).reduce((sum, item) => sum + activityStepHeight(item), 0);
}

/// The prepared texts of those messages, for their estimates; cleared past 256, as a row's are.
const receivedPrepared = new Map<string, PreparedText | null>();
const TURN_GAP = 16;
/// The rest gap (Leo 2026-11-01: "more space between composer and latest messages ... tho maybe not
/// as much as claude code"): from the newest row's line (a turn footer's 24px action row, or the
/// running turn's live line) to the top of the floating bottom stack (the running tray, else the
/// composer card). About two and a half body lines, as Codex leaves under its action row; Claude Code
/// leaves about four and a half. The last row's own turn gap is part of it, and the room under the
/// last row adds the rest (`restRoom`). leo-workspace design/chat-transcript.md.
export const REST_GAP = 56;
/// What the room under the last row adds over a floating stack to the last row's turn gap. The
/// gallery compares other values through `<html data-rest-gap>` (composerRestGap.gallery.ts).
export function restRoom(): number {
  const set = typeof document === "undefined" ? undefined : document.documentElement.dataset.restGap;
  const gap = set === undefined || !Number.isFinite(Number(set)) ? REST_GAP : Number(set);
  return Math.max(0, gap - TURN_GAP);
}
/// A prompt's meta row (`.cv-user__actions`, UserBubble.tsx). A steer the agent has not read yet
/// puts Send now first in that row (PendingSteer.tsx), including a Chief's prompt and a prompt of
/// images alone.
const userMetaHeight = (row: AcpmuxRow) => {
  const chief = row.from === "chief" || chiefEnvelope(row.text) !== undefined;
  return (
    (row.text && !row.failed && !chief ? META_GAP + META_ROW : 0) +
    (row.steer === "waiting" && !row.text?.trim() ? META_GAP + META_ROW : 0)
  );
};
/// The author line over a shared chat's prompt (multiplayer/multiplayer.css `.cv-author`).
const AUTHOR_HEIGHT = 22;
const chromeHeight = (row: AcpmuxRow, actions: boolean) =>
  row.kind === "user"
    ? USER_BUBBLE_PADDING +
      userMetaHeight(row) +
      (row.status ? USER_STATUS_HEIGHT : 0) +
      (row.author ? AUTHOR_HEIGHT : 0)
    : // The room a reply keeps under its text (`keepsReplyRoom`): the meta gap, then a meta row's line.
      actions
      ? META_GAP + META_ROW
      : 0;
/// The bubble's share of its row and its side padding, which sits inside that share (border-box).
const USER_BUBBLE_SHARE = 0.7;
const USER_BUBBLE_SIDES = 24;
/// Space between a row's markdown blocks, the list indent and the quote's bar and padding.
const BLOCK_GAP = 14;
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
/// The chat's one column (`--cv-column` and `--cv-inset` in conversation/conversation.css): 720px,
/// 62.5% of a wider pane up to 800px (or the cap Debug Settings' `agent.chatWidth` picks, chatWidth.ts),
/// centered, at least the page edge from each side. `endReserve` is room a card keeps at the
/// column's right (the computer use live preview, `--cv-inset-end`): the column's end moves in to
/// leave it, its start stays.
const PAGE_EDGE = 18;
export function transcriptColumn(paneWidth: number, { min, max, share }: ChatColumn = chatColumn(), endReserve = 0) {
  const column = Math.min(max, Math.max(min, paneWidth * share));
  const inset = Math.max(PAGE_EDGE, (paneWidth - column) / 2);
  const insetEnd = Math.max(inset, endReserve);
  return { inset, insetEnd, width: paneWidth - inset - insetEnd };
}
export const transcriptRowWidth = (paneWidth: number, column?: ChatColumn, endReserve = 0) =>
  Math.max(120, transcriptColumn(paneWidth, column, endReserve).width);

/// A message's markdown blocks. Blank lines between blocks are only spacing, never blocks of their own.
export function markdownBlocks(source: string): Token[] {
  try {
    return lexer(source, { gfm: true, breaks: true }).filter((token) => token.type !== "space");
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

/// The edited-files card's height for `files` changed files with diffs and `plain` edits listed
/// without one (styles.css `.acpmux-edited`). A lone file with a diff is named in the head.
export function editedCardHeight(files: number, plain = 0): number {
  const entries = files + plain;
  if (entries <= 1 && plain === 0) return 58;
  return 58 + 34 * Math.min(entries, 3) + (entries > 3 ? 34 : 0);
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
      : editedPaths(tool).map((path) => ({ path, canonical: toolCanonical(tool, path) }));
    if (!diffs.length && !files.length) out.push({ key: `unknown-${tool.id}-${index}`, ...mark });
    for (const file of files) {
      const key = pathKey(file);
      const listed = at.get(key);
      const entry = { key: `path-${key}`, path: file.path, ...(file.canonical ? { canonical: file.canonical } : {}) };
      if (listed === undefined) {
        at.set(key, out.length);
        out.push({ ...entry, ...mark });
      } else if (!failed) out[listed] = entry;
    }
  });
  return out;
}

/// An edited-files card entry without counts (`plainEditLabels`): `key` is its React key.
export type PlainEditLabel = { key: string; path?: string; canonical?: string; failed?: true };

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
/// tool run, a background task's or a subagent's end, a compaction, a failover, a policy the harness
/// cannot keep, a paused agent pair, a session start, another agent's message or notice); an
/// edited-files card is a card, not a line. Between two replies it sits in the middle of the gap, as
/// Claude Code desktop's do (Leo, 2026-10-30: "see how claude code has those centered tool calls /
/// id like more alignment too"): `statusEdge`.
export const isStatusRow = (row: AcpmuxRow | undefined) =>
  row !== undefined &&
  (row.kind === "backgroundTask" ||
    row.kind === SUBAGENT_DONE ||
    row.kind === "compaction" ||
    row.kind === "failover" ||
    row.kind === "policyUnenforced" ||
    row.kind === "agentPair" ||
    row.kind === "sessionStart" ||
    (row.kind === "user" && (row.incoming?.kind === "message" || row.incoming?.kind === "notice")) ||
    (row.kind === "activity" && isToolRun(row)));
/// A tool run with at least one call, not an edited-files card (turnChanges/sessionRows.ts
/// `isEditRow`): a run of thoughts alone may draw nothing, so it keeps its own spacing. One pass
/// over the row's items.
function isToolRun(row: AcpmuxRow): boolean {
  const card = row.foldRun === undefined && !isFoldedCopy(row);
  let tool = false;
  for (const item of row.items ?? []) {
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
const STATUS_GAP = META_GAP + META_ROW + TOOL_RUN_TOP;
const STATUS_GAP_PLAIN = 12;
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
/// A one-line activity row drawn on the tool rows' line: another agent's message, a task's notice and
/// an inbox notice (each a user row, IncomingMessageCard.tsx and InboxNoticeCard.tsx), a report
/// batch's head (LaneNoticeBatch.tsx) and the waiting messages' head (PendingMessagesCard.tsx).
/// App.tsx marks it `acpmux-row--line` and joins it to the step rows beside it.
export const isLineRow = (row: AcpmuxRow) =>
  row.kind === LANE_NOTICE_BATCH ||
  row.kind === PENDING_MESSAGES ||
  (row.kind === "user" &&
    !row.received &&
    (row.incoming?.kind === "message" || row.incoming?.kind === "notice" || row.incoming?.kind === "inbox"));
/// A row that draws nothing (a turn's bookkeeping, conversation/turns.ts).
const drawsNothing = (row: AcpmuxRow) => row.incoming?.kind === "hidden";
/// The row after `index` that draws something.
export function nextDrawnRow(rows: readonly AcpmuxRow[], index: number): AcpmuxRow | undefined {
  for (let next = index + 1; next < rows.length; next += 1) if (!drawsNothing(rows[next]!)) return rows[next];
  return undefined;
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
/// A completed turn followed by more of this chat's assistant. Incoming agents are user rows,
/// so a user/agent speaker change keeps the full turn gap. Check only the next drawn row.
export const isContinuationFooter = (row: AcpmuxRow, next: AcpmuxRow | undefined) =>
  row.kind === "turnSummary" &&
  next !== undefined &&
  (next.kind === "assistant" ||
    next.kind === "activity" ||
    next.kind === "plan" ||
    next.kind === WORKED ||
    next.kind === WORKING ||
    next.kind === THINKING ||
    next.kind === ACTIVITY_LINE);
/// What the row after a row changes about its height (`beforeFooter`, and the room a reply keeps,
/// `keepsReplyRoom`), as one key.
const rowEdge = (row: AcpmuxRow, next: AcpmuxRow | undefined, prev: AcpmuxRow | undefined) => {
  const status = statusEdge(row, next, prev);
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
): number {
  const finish = (height: number) =>
    height === 0 || !lastTurn
      ? height
      : height + TURN_GAP - (row.kind === "activity" || isLineRow(row) ? TOOL_RUN_BOTTOM : MESSAGE_GAP);
  const textLines = Math.max(1, Math.ceil((row.text?.length ?? 0) / Math.max(24, Math.floor(width / 8))));
  if (row.kind === "activity") {
    // The edited-files card (conversation/EditedFilesCard.tsx): a 58px head, and 34px for each of the first
    // three files and for "Show N more"; one file is named in the head. Otherwise tool rows
    // (`.cv-tools`: 2px above compact rows, with a small run gap), which is also how a copy inside
    // an open "Worked for" draws.
    const edits = row.items?.filter((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange") ?? [];
    if (edits.length && row.foldRun === undefined && !isFoldedCopy(row)) {
      const files = new Set(
        edits.flatMap(
          (item) => item.tool?.diffs?.flatMap((diff) => (contentsUnknown(diff) ? [] : [pathKey(diff)])) ?? [],
        ),
      );
      const plain = plainEditLabels(edits).filter((entry) => !entry.path || !files.has(entry.canonical ?? entry.path));
      return finish(14 + editedCardHeight(files.size, plain.length));
    }
    // A folded run (the Codex-style runs) that keeps an entry in sight (a message to another agent)
    // draws its stretches; one with nothing kept in sight draws one summary line, or its one call.
    if (row.foldRun && row.items?.length) {
      const groups = toolGroups(row.items);
      if (groups.some(staysInSight)) return finish(TOOL_RUN_TOP + TOOL_RUN_BOTTOM + foldedRunSteps(row, groups));
      if (isFoldedRun(row.items)) return finish(TOOL_RUN_TOP + TOOL_ROW_HEIGHT + TOOL_RUN_BOTTOM);
    }
    const items = row.items ?? [];
    const steps = items.length ? items.reduce((height, item) => height + activityStepHeight(item), 0) : TOOL_ROW_HEIGHT;
    return finish(TOOL_RUN_TOP + TOOL_RUN_BOTTOM + steps);
  }
  // A subagent group's 48px line with 8px above it, and in an open group a 48px line per
  // subagent, the last with the list's 8px below (subagents/SubagentGroup.tsx).
  // An agent a shell call started (subagents/AgentRunCard.tsx): its card with its model line, its
  // reply once it ended, and the Raw toggle's row.
  if (isRunGroup(row)) {
    const agent = row.subagents![0]!;
    const reply = agent.result && agent.state !== "running" ? replyHeight(agent.result) : 0;
    return finish(cardHeight("working") + reply + TOOL_ROW_HEIGHT);
  }
  if (row.kind === SUBAGENTS) return finish(56);
  // A workflow's card (summary/WorkflowCard.css): three fixed lines in a hairline box.
  // WorkflowCard: head, metadata, latest line, progress bar and focus line.
  if (row.kind === WORKFLOW_CARD) return finish(124);
  if (row.kind === SUBAGENT_ROW) return finish(row.status === "last" || row.status === "only" ? 56 : 48);
  // The child view's 28px "Subagent of" pill with 8px above and below it.
  if (row.kind === SUBAGENT_OF) return finish(44);
  // Empty child copy is measured on mount; start with two body lines.
  if (row.kind === SUBAGENT_EMPTY) return finish(2 * metrics().lineHeight);
  // The 27px disclosure line, and the live status lines in its place.
  // The running turn's line as its last row is the footer's height (META_ROW, conversation.css
  // `.cv-worked.is-below`) and the normal turn gap, so the end-of-turn swap keeps its place.
  if ((row.kind === WORKING || row.kind === THINKING) && row.below) return finish(META_ROW + TURN_GAP);
  if (row.kind === WORKED || row.kind === WORKING || row.kind === THINKING) return finish(35);
  // The activity line under a plan is the live footer. It reserves the finished footer's 24px
  // line and turn gap so swapping in `turnSummary` never changes the transcript geometry.
  if (row.kind === ACTIVITY_LINE) return row.below ? finish(META_ROW + TURN_GAP) : finish(36);
  // The 20px date line with 8px above it.
  if (row.kind === DATE) return finish(36);
  // The preview card mounts unloaded: one compact row, and 6px below (PreviewCard.tsx). Once the
  // reader clicks Load preview, the transcript's ResizeObserver measures the head over its frame.
  if (row.kind === PREVIEW) return finish(previewCardHeight(row.text, false));
  // The render card: its 36px head over the frame before it reports a height, and 6px below.
  if (row.kind === RENDER) return finish(36 + RENDER_FRAME_MIN_HEIGHT + 6);
  // Card padding and border, title, button row.
  if (row.kind === "permission") return finish(87);
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
  // A paused agent pair: its sentence over the held count and Resume; resumed, one line.
  if (row.kind === "agentPair") return finish(row.agentPair?.resumed ? 37 : 37 + 24);
  // A session start: its facts line (conversation/SessionStartNote.tsx); the full facts open
  // below when asked.
  if (row.kind === "sessionStart") return finish(37);
  // The plan card's 24px items inside 8px of padding and 8px margins (conversation/PlanList.tsx).
  if (row.kind === "plan" && row.plan) return finish(40 + row.plan.length * 24);
  // A turn's footer: its meta line, then the normal turn gap. An empty footer (only hover controls,
  // conversation/turns.ts isEmptyFooter) takes no extra line; its gap still fits the hover controls.
  if (row.kind === "turnSummary")
    return finish(isEmptyFooter(row) ? Math.max(META_ROW, TURN_GAP) : META_ROW + TURN_GAP);
  if (
    row.kind === "notice" ||
    row.kind === "backgroundTask" ||
    row.kind === SUBAGENT_DONE ||
    row.kind === "compaction" ||
    row.kind === "failover" ||
    row.kind === "policyUnenforced" ||
    row.kind === "plan" ||
    row.kind === "typing" ||
    row.kind === BACKGROUND_TURN
  )
    return finish(37);
  return finish(8 + messageBelow(beforeFooter) + chromeHeight(row, actions) + textLines * metrics().lineHeight);
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
/// it). Keep enough entries for the current blocks plus a bounded tail of older streaming revisions.
const PREPARED_CACHE_MIN = 64;
const PREPARED_CACHE_PER_BLOCK = 4;

function trimPreparedCache(
  prepared: Map<string, PreparedText | null>,
  blockCount: number,
  used: ReadonlySet<string>,
): void {
  const limit = Math.max(PREPARED_CACHE_MIN, PREPARED_CACHE_PER_BLOCK * blockCount, used.size);
  if (prepared.size <= limit) return;
  for (const key of prepared.keys()) {
    if (prepared.size <= limit) break;
    if (!used.has(key)) prepared.delete(key);
  }
}

function textHeight(
  text: string,
  width: number,
  prepared: Map<string, PreparedText | null>,
  used?: Set<string>,
): number {
  const { measureFont, lineHeight } = metrics();
  // Keyed by font too: a new chat font measures the text again.
  const key = `${measureFont}\n${text}`;
  used?.add(key);
  let measured = prepared.get(key);
  if (measured === undefined) {
    try {
      measured = prepare(text, measureFont, { whiteSpace: "pre-wrap" });
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
  return list.items.reduce((sum, item) => {
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
  }, 0);
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
    // Prose (lists, quotes, paragraphs, headings) keeps its measure in a wide column (chatWidth.ts).
    case "list":
      return listHeight(block as Tokens.List, Math.min(width, chatColumn().prose), prepared, used);
    case "blockquote":
      return textHeight(
        measuredText((block as Tokens.Blockquote).tokens, (block as Tokens.Blockquote).text),
        Math.min(width, chatColumn().prose) - QUOTE_INDENT,
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
        Math.min(width, chatColumn().prose),
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
  if (row.received) return finish(26 + MESSAGE_GAP);
  // A turn's footer carries its answer's text for Copy (conversation/turns.ts); it draws one line.
  if (row.kind === "turnSummary") {
    const gap = continuation ? MESSAGE_GAP : TURN_GAP;
    return isEmptyFooter(row) ? Math.max(META_ROW, gap) : META_ROW + gap;
  }
  // The live activity line under a plan has a label, but its row still reserves the footer slot.
  if (row.kind === ACTIVITY_LINE && row.below) return fallbackRowHeight(row, width, beforeFooter, lastTurn, actions);
  // A task notification from another agent is a tool row's line (conversation/IncomingMessageCard.tsx)
  // in the one-line rows' frame (LINE_ROW).
  // The messages that wait, as one group (conversation/PendingMessagesCard.tsx): its head is a
  // one-line row; opened, each sender's 22px head, then each of its messages as its own row draws
  // it, 24px in, less the frame the row gives a row, which the group has once.
  if (row.kind === LANE_NOTICE_BATCH && row.laneNoticeBatch) {
    const head = finish(LINE_ROW);
    if (!messageOpened(sessionId, row.id)) return head;
    return (
      head +
      row.laneNoticeBatch.rows.reduce(
        (height, member) =>
          height + measuredRowHeight(member, Math.max(80, width - 24), cache, false, false, sessionId) - LINE_FRAME,
        0,
      )
    );
  }
  if (row.kind === PENDING_MESSAGES && row.pendingMessages) {
    const head = finish(LINE_ROW);
    if (!messageOpened(sessionId, row.id)) return head;
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
    // One line in the one-line rows' frame (LINE_ROW); one the person opened
    // (incomingOpened.ts) adds its panel (2px above, 4px below, 8px padding each side, 24px in
    // from the icon column and 10px padding across): the whole text
    // (conversation/IncomingMessageCard.tsx), its images' 128px, and Details' 24px line.
    const line = LINE_ROW;
    if (!messageOpened(sessionId, row.id)) return finish(line);
    const { lineHeight } = metrics();
    const text = row.incoming.message.text;
    if (receivedPrepared.size > 256) receivedPrepared.clear();
    const lines = text ? textHeight(text, Math.max(80, width - 44), receivedPrepared) : lineHeight;
    const details = row.incoming.message.raw.trim() === text ? 0 : 24;
    return finish(line + 2 + 4 + 16 + lines + (row.images?.length ? 128 : 0) + details);
  }
  if (row.incoming?.kind === "notice") return finish(LINE_ROW);
  if (row.incoming?.kind === "inbox") {
    // acpmux's inbox notice (conversation/InboxNoticeCard.tsx): a received line per thread, under
    // the group's line when the group look holds two or more; an opened thread adds its panel as
    // an opened message does, its text read from the notice (else its preview).
    const { threads } = row.incoming.notice;
    const line = TOOL_ROW_HEIGHT;
    // The group's head is a tool row (MessageGroupHead.tsx) on the one-line rows' line.
    const head = TOOL_ROW_HEIGHT;
    const grouped = threads.length > 1 && foldsThreads(inboxNoticeLook());
    if (grouped && !messageOpened(sessionId, row.id)) return finish(head + LINE_FRAME);
    const { lineHeight } = metrics();
    if (receivedPrepared.size > 256) receivedPrepared.clear();
    let height = (grouped ? head : 0) + (threads.length > 1 && inboxNoticeLook() === "card" ? 6 : 0);
    for (const thread of threads) {
      height += line;
      if (!messageOpened(sessionId, inboxThreadKey(row.id, thread.threadId))) continue;
      const text = thread.messages?.map((m) => m.text).join("\n\n") ?? thread.preview;
      const inset = grouped ? 24 : 0;
      height += 2 + 4 + 16 + (text ? textHeight(text, Math.max(80, width - 44 - inset), receivedPrepared) : lineHeight);
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
  // A preview row's text is its address, not prose: the card's height is fixed.
  if (!row.text || row.kind === PREVIEW) return fallbackRowHeight(row, width, beforeFooter, lastTurn, actions);
  let entry = cache.get(row.id);
  if (!entry) {
    entry = { text: "", blocks: [], closedBlocks: [], closedEnd: 0, lexedLength: 0, prepared: new Map() };
    cache.set(row.id, entry);
  }
  const pasted = row.kind === "user" && Boolean(row.pasted?.length);
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
  const plainUser =
    row.kind === "user" &&
    !pasted &&
    !row.images?.length &&
    !row.retryAttachments?.length &&
    !row.from &&
    !chiefEnvelope(row.text) &&
    isPlainUserPrompt(row.text);
  const contentWidth = Math.max(80, row.kind === "user" ? USER_BUBBLE_SHARE * width - USER_BUBBLE_SIDES : width);
  const usedPrepared = new Set<string>();
  let contentHeight: number;
  if (plainUser) {
    // UserBubble -> PromptText draws this as literal spans, so avoid preparing Markdown tokens.
    const plainWidth = Math.min(contentWidth, chatColumn().prose);
    const { measureFont, lineHeight } = metrics();
    const plainKey = `${measureFont}\n${lineHeight}\n${plainWidth}\n${row.text}`;
    if (entry.plainHeight?.key === plainKey) contentHeight = entry.plainHeight.height;
    else {
      contentHeight = textHeight(row.text, plainWidth, entry.prepared, usedPrepared);
      entry.plainHeight = { key: plainKey, height: contentHeight };
    }
  } else {
    if (!pasted && (entry.text !== row.text || entry.lexedLength === 0)) {
      lexIncrementally(entry, row.text);
    }
    if (pasted) {
      // A prompt with pasted blocks: its typed parts, each a line or more, and a chip per paste
      // however long it is (conversation/UserBubble.tsx).
      const { lineHeight } = metrics();
      contentHeight = 0;
      for (const part of promptParts(row.text, row.pasted!))
        contentHeight +=
          part.kind === "paste"
            ? PASTE_CHIP_HEIGHT
            : Math.max(
                lineHeight,
                // A huge typed part draws collapsed to its head (conversation/PromptText.tsx), so its
                // head is all there is to measure.
                textHeight(
                  isHugePrompt(part.text) ? promptHead(part.text, HUGE_PROMPT_HEAD_CHARS) : part.text,
                  contentWidth,
                  entry.prepared,
                  usedPrepared,
                ),
              );
    } else {
      if (entry.blocks.length === 0) return fallbackRowHeight(row, width, beforeFooter, lastTurn, actions);
      contentHeight = (entry.blocks.length - 1) * BLOCK_GAP;
      for (const block of entry.blocks) contentHeight += blockHeight(block, contentWidth, entry.prepared, usedPrepared);
    }
  }
  // A stream changes only its tail block. Preserve prepared entries for the unchanged blocks and
  // trim stale revisions once per row, never once per token or across the transcript. `usedPrepared`
  // includes list items, whose text count can be much larger than the block count.
  trimPreparedCache(entry.prepared, entry.blocks.length, usedPrepared);
  // A long prompt opens collapsed to its first lines over Show more (conversation/UserBubble.tsx); a
  // Chief's draws its own bubble (ChiefPromptBubble.tsx).
  if (row.kind === "user" && row.from !== "chief" && !chiefEnvelope(row.text))
    contentHeight = collapsedPromptHeight(contentHeight, metrics().lineHeight);
  const height = messageBelow(beforeFooter) + chromeHeight(row, actions) + contentHeight;
  return finish(beforeFooter ? height : Math.max(34, height));
}

/// A row's estimated height at a width, kept by the row object: rows are immutable (a change is a
/// new object), so a long chat's layout measures only the rows that changed since the last one.
/// The row's edge is kept too: a reply's height changes when its turn's footer arrives after it, and
/// a footer's when a prompt follows it.
export type RowHeights = WeakMap<AcpmuxRow, { width: number; height: number; edge?: string }>;

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
): ConversationLayout {
  const tops = new Float64Array(rows.length);
  const heights = new Float64Array(rows.length);
  const messages = new MessagePlacement(rows, previous?.layout);
  let start = 0;
  if (previous) {
    const limit = Math.min(rows.length, previous.rows.length);
    while (start < limit && rows[start] === previous.rows[start]) start += 1;
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
    tops.set(previous.layout.tops.subarray(0, start));
    heights.set(previous.layout.heights.subarray(0, start));
  }
  let top = start > 0 ? tops[start - 1]! + heights[start - 1]! : 0;
  // Hidden bookkeeping can span many rows. Keep the next drawn row for the whole
  // pass: searching anew for every hidden row makes one run quadratic.
  let nextDrawn = start;
  // The drawn row above the current one, carried along the pass for the same reason.
  let prevDrawn = prevDrawnRow(rows, start);
  for (let index = start; index < rows.length; index += 1) {
    tops[index] = top;
    const row = rows[index]!;
    messages.visit(row, index, previous?.rows[index]);
    if (nextDrawn <= index) {
      nextDrawn = index + 1;
      while (nextDrawn < rows.length && drawsNothing(rows[nextDrawn]!)) nextDrawn += 1;
    }
    const prev = prevDrawn;
    if (!drawsNothing(row)) prevDrawn = row;
    const edge = rowEdge(row, rows[nextDrawn], prev);
    const kept = known?.get(row);
    let height: number;
    if (kept && kept.width === width && kept.edge === edge) height = kept.height;
    else {
      const customHeight = measureOverride?.(row, width);
      const custom = customHeight !== undefined && Number.isFinite(customHeight) && customHeight > 0;
      height = custom
        ? customHeight
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
      // A row that draws nothing stays at 0; a custom renderer's height is its own.
      if (!custom && height > 0) height += statusDelta(row, statusEdge(row, rows[nextDrawn], prev));
      known?.set(row, { width, height, edge });
    }
    heights[index] = height;
    top += height;
  }
  const layout = { tops, heights, totalHeight: top };
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
): ConversationLayout {
  const tops = new Float64Array(estimate.heights.length);
  const heights = new Float64Array(estimate.heights.length);
  const kept = previous ? Math.min(previous.kept, previous.layout.heights.length, heights.length) : 0;
  if (kept > 0) {
    tops.set(previous!.layout.tops.subarray(0, kept));
    heights.set(previous!.layout.heights.subarray(0, kept));
  }
  let top = kept > 0 ? tops[kept - 1]! + heights[kept - 1]! : 0;
  for (let index = kept; index < heights.length; index += 1) {
    tops[index] = top;
    // A drawn 0 is a row that draws nothing (App.tsx drawnHeightOf): it takes no room.
    const known = heightAt(index);
    const height = known !== undefined && known >= 0 ? known : estimate.heights[index];
    heights[index] = height;
    top += height;
  }
  return { tops, heights, totalHeight: top };
}

function upperBound(values: Float64Array, target: number): number {
  let low = 0;
  let high = values.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (values[middle] <= target) low = middle + 1;
    else high = middle;
  }
  return low;
}

export function visibleLayoutRange(
  layoutModel: ConversationLayout,
  scrollTop: number,
  viewportHeight: number,
  overscan = 4,
) {
  if (layoutModel.tops.length === 0) return { first: 0, last: 0 };
  const first = Math.max(0, upperBound(layoutModel.tops, Math.max(0, scrollTop)) - 1 - overscan);
  const last = Math.min(layoutModel.tops.length, upperBound(layoutModel.tops, scrollTop + viewportHeight) + overscan);
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

/// The rows a transcript at `scrollTop` mounts while it moves `delta` per scroll: the view and
/// `steps` scrolls of motion ahead of it, capped at `maxLead`. A scroll past the cap (a fling or a
/// scrollbar drag that moves several viewports a frame) also mounts each view the next `steps`
/// frames reach, with a margin for uneven frames: the rows between them and the capped lead are
/// never on screen, so they are not built (cx-j33s4).
export function scrollLeadRanges(
  layoutModel: ConversationLayout,
  scrollTop: number,
  delta: number,
  viewportHeight: number,
  steps: number,
  maxLead: number,
): RowRange[] {
  const lead = Math.min(Math.abs(delta) * steps, maxLead);
  const ranges = [visibleLayoutRange(layoutModel, delta < 0 ? scrollTop - lead : scrollTop, viewportHeight + lead)];
  if (Math.abs(delta) * steps <= maxLead) return ranges;
  const margin = Math.min(Math.abs(delta) / 4, viewportHeight / 2);
  for (let step = 1; step <= steps; step += 1)
    ranges.push(visibleLayoutRange(layoutModel, scrollTop + delta * step - margin, viewportHeight + 2 * margin));
  return mergeRowRanges(ranges);
}
import { layout, prepare, type PreparedText } from "@chenglou/pretext";
import { lexer, type Token, type Tokens } from "marked";
import { runStretches, staysInSight, toolGroups, type ToolGroup } from "./conversation/toolGroups";
import { isFoldedRun } from "./conversation/toolRunSummary";
import { isQuietThought, isThought, mergeThoughts } from "./conversation/thoughts";
import { previewCardHeight } from "./conversation/previewUrl";
import { RENDER_FRAME_MIN_HEIGHT } from "./conversation/renderCall";
import {
  ACTIVITY_LINE,
  DATE,
  isEmptyFooter,
  isFoldedCopy,
  PREVIEW,
  RENDER,
  THINKING,
  WORKED,
  WORKING,
} from "./conversation/turns";
import type { AcpmuxSessionEntry } from "./sessionList";
import { agentName } from "./agents";
import { type Translate, translate } from "./i18n";
import { lastBlockBoundary } from "./conversation/incrementalMarkdown";
import { chiefEnvelope } from "./conversation/chiefEnvelope";
import { chatColumn, type ChatColumn } from "./chatWidth";
import { currentChatMetrics } from "./chatDisplay";
import { messageOpened } from "./conversation/incomingOpened";
import { inboxThreadKey } from "./conversation/inboxNotice";
import { foldsThreads, inboxNoticeLook } from "./conversation/inboxNoticeLook";
import { isDiagram, isUnlabeledLang } from "./conversation/codeShape";

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
