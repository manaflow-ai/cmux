import type { VideoInfo } from "./composer/videoAttachments";
import type { HarnessIconSpec } from "../shared/harnessIcons";
import type { ChatUnavailable } from "./chatUnavailable";
import type { ChatPresence, Participant } from "./multiplayer/participants";
import { editedPaths } from "./toolPaths";
import type { PermissionClientState } from "./permissions/protocol";
import type { AgentQuestion } from "./question/model";
import type { WatchedAsk } from "./needsYou/model";
import type { PermissionDecision } from "./permissions/record";
import type { HandoffClientState } from "./handoff/client";
import type { Enforcement } from "./handoff/protocol";
import type { SlashCommand } from "./slashCommands";
import type { SummaryCheckpoint } from "./changes/turnCheckpointSource";
import type { IncomingMessage, IncomingPrompt } from "./conversation/incomingMessage";
import { appHref, linkHref, safeHref } from "./replyHref";
import type { ShellRun } from "./shell/shellRuns";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";
import { isRunGroup, SUBAGENT_DONE, SUBAGENT_OF, SUBAGENT_ROW, WORKFLOW_CARD } from "./subagents/subagentRows";
import type { ComposerAttachment } from "./attachments";
import { STARTED_SESSIONS, type StartedSession, hasStatusLine } from "./started/startedSessions";
import { PASTE_CHIP_HEIGHT, type PasteRange, collapsedPromptHeight, promptParts } from "./conversation/promptCollapse";
import { mcpCall } from "./conversation/mcpCalls";
import { subsessionCall } from "./conversation/subsessionCalls";
import type { ChatTool } from "./summary/chatTools";
import type { TaskGoal } from "./goal";

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
};
/// Ordered ACP content. The daemon validates blockIndex/companionOf against the actual blocks.
/// Local attachment identities and video previews survive echo; companions remain on the wire.
export type PromptContentPart =
  | { kind: "text"; text: string }
  | (PromptImage & { kind: "image"; persisted?: false; attachmentId?: string; blockIndex?: number })
  | {
      kind: "file" | "document" | "audio" | "pasted";
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
    };
/// A queued prompt's image: `src` is its data URL when the pane has its bytes (it sent them, or
/// the `queued` record carries them), else the row reads it by `id`. acpmux names an image by the
/// SHA-256 of its bytes; one the pane only sent so far has the composer's id (`local`) until
/// acpmux names it, so an edit cannot keep or drop it by id yet.
export type QueuedPromptImage = PromptImage & { src?: string; local?: boolean };

export type AcpmuxRow = {
  id: string;
  version: number;
  at: number;
  kind: string;
  /// The acpmux event a turn summary came from, where a fork through that turn ends.
  seq?: number;
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
  incoming?: Extract<IncomingPrompt, { kind: "message" | "notice" | "hidden" }>;
  /// The prompt as the agent got it, when the row shows something else (an incoming message's
  /// body): what Retry sends again.
  resend?: string;
  /// Another agent's message still waiting in the queue (conversation/queuedMessages.ts): the
  /// queue entry's promptId, which its ⋯ menu steers, edits or deletes, and whether it was sent
  /// now already (acpmux marks it `next`; it runs right after the turn).
  queuedMessage?: { promptId: string; next?: boolean };
  /// A prompt the person did not type (a task's result, another agent's message, bookkeeping),
  /// whether or not it draws as one: prompt recall leaves it out (composer/promptHistory.ts).
  untyped?: boolean;
  /// A started sessions row's chats, oldest first (started/StartedSessionCard.tsx).
  started?: StartedSession[];
  toolCount?: number;
  durationMs?: number;
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
  /// A turn footer's answer row (turns.ts), whose right-click menu the footer's More opens.
  answerId?: string;
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
  /// Work shown inside an open "Worked for": its turn has ended.
  settled?: boolean;
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
  unavailable?: string;
  shortName?: string;
  family?: string;
  efforts?: string[];
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
    usageLimits?: string;
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
  /// acpmux reconnects a Claude Code chat's failed MCP server for this connection: its `initialize`
  /// lists `_acpmux/mcp/reconnect` (an older acpmux does not), so the Inspector's Connectors offer
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
  /// The running turn's output tokens so far, its model calls' generated tokens added up,
  /// subagents' included (direct.ts `turnTokens`); unset when the harness does not report each
  /// call or the client missed the turn's start.
  turnTokens?: number;
  /// The running turn's agent has said nothing since its prompt, past acpmux's `silentTurnMs`
  /// (direct.ts `silentTurn`): the turn's line says the model has not answered.
  silentTurn?: true;
  /// This computer's clock minus the session's, for a session on a peer (SSH, Cloud) whose
  /// events carry the peer's clock; unset when they share a clock or it is not known yet.
  clockOffsetMs?: number;
  /// acpmux serves `acp.session.fork` (operations.ts), so a turn can be forked from.
  canFork?: boolean;
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
    /** The configured harness login command, when its profile declares one. */
    auth?: { login?: string };
    unavailable?: string;
    /** `unavailable` is only a failed model probe (a timeout, a rate limit): the harness may run. */
    probeFailed?: boolean;
    pickable?: boolean;
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
  /** The oldest event seq the pane holds: it moves with each older read, even one that drew no row. */
  historyFrom?: number;
  /** The agent's slash commands, for the composer's `/` menu. */
  commands?: SlashCommand[];
  /** A harness switch the pane draws ahead of acpmux (harnessSwitch.ts): starting, applying to
   * the next turn while one streams (deferred), or failed with acpmux's reason. */
  switching?: { harness: string; name: string; phase: "starting" | "deferred" | "failed"; error?: string };
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
/// A sub-session card (subagents/AgentCard.css): its 10px margins, 12px padding and 24px head, and
/// while it works or waits on the person, its 16px doing line.
const cardHeight = (state: string) => 46 + (state === "working" || state === "input" ? 16 : 0);

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

/// Ordinary tool rows use the compact rhythm. Notes and specialized MCP cards keep a conservative
/// estimate until their renderer reports its measured height (a wait can contain several three-line replies).
function activityStepHeight(item: AcpmuxActivity): number {
  const tool = item.tool;
  if (!tool) return 26;
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
/// How many lines of another agent's message its card shows before it is cut
/// (conversation/IncomingMessageCard.tsx, `.cv-received__body[data-cut]`).
// Agent and lane reports keep enough context to show a compact table or a few links before the
// card folds. The open control still reveals the complete Markdown body.
export const RECEIVED_LINES = 8;
/// The prepared texts of those messages, for their estimates; cleared past 256, as a row's are.
const receivedPrepared = new Map<string, PreparedText | null>();
const TURN_GAP = 16;
/// A prompt's meta row (`.cv-user__actions`, UserBubble.tsx). A steer the agent has not read yet
/// puts Send now first in that row (PendingSteer.tsx), including a Chief's prompt and a prompt of
/// images alone.
const userMetaHeight = (row: AcpmuxRow) => {
  const chief = row.from === "chief" || chiefEnvelope(row.text) !== undefined;
  return (
    (row.text && !row.failed && !row.queued && !chief ? META_GAP + META_ROW : 0) +
    (row.steer === "waiting" && !row.text?.trim() ? META_GAP + META_ROW : 0)
  );
};
/// The author line over a shared chat's prompt (multiplayer/multiplayer.css `.cv-author`).
const AUTHOR_HEIGHT = 22;
const chromeHeight = (row: AcpmuxRow) =>
  row.kind === "user"
    ? USER_BUBBLE_PADDING +
      userMetaHeight(row) +
      (row.status ? USER_STATUS_HEIGHT : 0) +
      (row.author ? AUTHOR_HEIGHT : 0)
    : 0;
/// The bubble's share of its row and its side padding, which sits inside that share (border-box).
const USER_BUBBLE_SHARE = 0.7;
const USER_BUBBLE_SIDES = 24;
/// Space between a row's markdown blocks, the list indent and the quote's bar and padding.
const BLOCK_GAP = 14;
const LIST_INDENT = 28;
const QUOTE_INDENT = 21;
/// Code cards: a 45.5px header over 12px monospace on 20px lines that never wraps, 13px inset.
const CODE_CHROME = 58.5;
const CODE_PADDING = 13;
/// Table rows: 23px lines with 17px of padding.
const TABLE_ROW_HEIGHT = 40;
const SCROLLBAR_HEIGHT = 15;
/// Where text can't be measured (no canvas), a generous character width.
const FALLBACK_CHAR_WIDTH = 8;
/// The chat's one column (`--cv-column` and `--cv-inset` in conversation/conversation.css): 720px,
/// 62.5% of a wider pane up to 800px (or the cap Debug Settings' `agent.chatWidth` picks, chatWidth.ts),
/// centered, at least the page edge from each side.
const PAGE_EDGE = 18;
export function transcriptColumn(paneWidth: number, { min, max, share }: ChatColumn = chatColumn()) {
  const column = Math.min(max, Math.max(min, paneWidth * share));
  const inset = Math.max(PAGE_EDGE, (paneWidth - column) / 2);
  return { inset, width: paneWidth - 2 * inset };
}
export const transcriptRowWidth = (paneWidth: number, column?: ChatColumn) =>
  Math.max(120, transcriptColumn(paneWidth, column).width);

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
export const isBeforeFooter = (row: AcpmuxRow, next: AcpmuxRow | undefined) =>
  row.kind === "assistant" &&
  (next?.kind === "turnSummary" || ((next?.kind === WORKING || next?.kind === THINKING) && next.below === true));
/// The row kind of another agent's message while it waits in the queue (conversation/queuedMessages.ts):
/// its received card after the running turn, until acpmux starts it.
export const QUEUED_MESSAGE = "queuedMessage";
/// A row that draws nothing (a turn's bookkeeping, conversation/turns.ts).
const drawsNothing = (row: AcpmuxRow) => row.incoming?.kind === "hidden";
/// The row after `index` that draws something.
export function nextDrawnRow(rows: readonly AcpmuxRow[], index: number): AcpmuxRow | undefined {
  for (let next = index + 1; next < rows.length; next += 1) if (!drawsNothing(rows[next]!)) return rows[next];
  return undefined;
}
/// The chat's last footer ends at the message gap, not the turn gap: no band over the composer
/// (App.tsx marks it `acpmux-row--last-footer`). So does a footer over another agent's line (a
/// message, a notice or a started task's result): that line belongs with the agent's text above
/// it, not a turn of its own after a band. `next` is the next row that draws.
export const isLastFooter = (row: AcpmuxRow, next: AcpmuxRow | undefined) =>
  row.kind === "turnSummary" &&
  (!next ||
    ((next.kind === "user" || next.kind === QUEUED_MESSAGE) &&
      (next.received !== undefined || next.incoming?.kind === "message" || next.incoming?.kind === "notice")));
/// What the row after a row changes about its height (`beforeFooter`), as one key.
const rowEdge = (row: AcpmuxRow, next: AcpmuxRow | undefined) =>
  isBeforeFooter(row, next) ? "footer" : isLastFooter(row, next) ? "last" : row.lastTurn ? "last-turn" : undefined;

function fallbackRowHeight(row: AcpmuxRow, width: number, beforeFooter = false, lastTurn = false): number {
  const finish = (height: number) =>
    height === 0 || !lastTurn ? height : height + TURN_GAP - (row.kind === "activity" ? TOOL_RUN_BOTTOM : MESSAGE_GAP);
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
    // A folded run (Debug toggle) draws one summary line until opened.
    if (row.foldRun && row.items && isFoldedRun(row.items))
      return finish(TOOL_RUN_TOP + TOOL_ROW_HEIGHT + TOOL_RUN_BOTTOM);
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
  if (row.kind === WORKFLOW_CARD) return finish(86);
  if (row.kind === SUBAGENT_ROW) return finish(row.status === "last" || row.status === "only" ? 56 : 48);
  // The child view's 28px "Subagent of" pill with 8px above and below it.
  if (row.kind === SUBAGENT_OF) return finish(44);
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
    row.kind === "typing"
  )
    return finish(37);
  return finish(8 + messageBelow(beforeFooter) + chromeHeight(row) + textLines * metrics().lineHeight);
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
    case "code": {
      const lines = (block as Tokens.Code).text.split("\n");
      const { codeCharWidth, codeLineHeight } = metrics();
      const scrolls = lines.some((line) => line.length * codeCharWidth > width - CODE_PADDING);
      return CODE_CHROME + lines.length * codeLineHeight + (scrolls ? SCROLLBAR_HEIGHT : 0);
    }
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

function measuredRowHeight(
  row: AcpmuxRow,
  width: number,
  cache: Map<string, PreparedRow>,
  beforeFooter = false,
  lastTurn = false,
  sessionId?: string,
): number {
  const finish = (height: number) =>
    height === 0 || !lastTurn ? height : height + TURN_GAP - (row.kind === "activity" ? TOOL_RUN_BOTTOM : MESSAGE_GAP);
  // A task's result is one 26px line, however long the prompt that brought it (offer/SuggestedTasks.tsx).
  if (row.received) return finish(26 + MESSAGE_GAP);
  // A turn's footer carries its answer's text for Copy (conversation/turns.ts); it draws one line.
  if (row.kind === "turnSummary") return fallbackRowHeight(row, width, beforeFooter);
  // The live activity line under a plan has a label, but its row still reserves the footer slot.
  if (row.kind === ACTIVITY_LINE && row.below) return fallbackRowHeight(row, width, beforeFooter, lastTurn);
  // Another agent's message: one 26px line in `.cv-received`'s 2px margins, then its glass card
  // (4px above, 6px below, 8px padding each side, 22px in from the icon column and 12px padding
  // across), its text cut to RECEIVED_LINES lines (opened, the row measures itself); a notice is a
  // tool row's line under `.cv-tools`' 2px margin (conversation/IncomingMessageCard.tsx). Each with
  // the row's message gap.
  // Its images' 120px row with 2px above and 6px below (UserBubble.tsx SENT_IMAGE_HEIGHT); no steer line.
  if (row.incoming?.kind === "message") {
    // In Minimal Mode a closed message is its line alone, images too; one the person opened
    // (incomingOpened.ts) is its whole card, uncut.
    const minimal = chatDisplay().minimal;
    const opened = messageOpened(sessionId, row.id);
    if (minimal && !opened) return finish(26 + 4 + MESSAGE_GAP);
    const { lineHeight } = metrics();
    const text = row.incoming.message.text;
    if (receivedPrepared.size > 256) receivedPrepared.clear();
    const lines = text ? textHeight(text, Math.max(80, width - 46), receivedPrepared) : lineHeight;
    const limit = RECEIVED_LINES * lineHeight;
    // .cv-user__more: a 20px control with 4px above it, only on a closed long card.
    const more = !opened && lines > limit + 1 ? 24 : 0;
    const card = 4 + 16 + (opened ? lines : Math.min(lines, limit)) + more + 6;
    return finish(26 + 4 + card + MESSAGE_GAP + (row.images?.length ? 128 : 0));
  }
  if (row.incoming?.kind === "notice") return finish(2 + 26 + MESSAGE_GAP);
  // Bookkeeping alone: a turn's start that draws nothing (conversation/turns.ts).
  if (row.incoming?.kind === "hidden") return finish(0);
  // A finished step of only quiet thoughts draws nothing (conversation/ThoughtRow.tsx).
  if (onlyQuietThoughts(row)) return finish(0);
  // A preview row's text is its address, not prose: the card's height is fixed.
  if (!row.text || row.kind === PREVIEW) return fallbackRowHeight(row, width, beforeFooter, lastTurn);
  let entry = cache.get(row.id);
  if (!entry) {
    entry = { text: "", blocks: [], closedBlocks: [], closedEnd: 0, lexedLength: 0, prepared: new Map() };
    cache.set(row.id, entry);
  }
  const pasted = row.kind === "user" && Boolean(row.pasted?.length);
  if (!pasted && (entry.text !== row.text || entry.lexedLength === 0)) {
    lexIncrementally(entry, row.text);
  }
  const contentWidth = Math.max(80, row.kind === "user" ? USER_BUBBLE_SHARE * width - USER_BUBBLE_SIDES : width);
  const usedPrepared = new Set<string>();
  let contentHeight: number;
  if (pasted) {
    // A prompt with pasted blocks: its typed parts, each a line or more, and a chip per paste
    // however long it is (conversation/UserBubble.tsx).
    const { lineHeight } = metrics();
    contentHeight = 0;
    for (const part of promptParts(row.text, row.pasted!))
      contentHeight +=
        part.kind === "paste"
          ? PASTE_CHIP_HEIGHT
          : Math.max(lineHeight, textHeight(part.text, contentWidth, entry.prepared, usedPrepared));
  } else {
    if (entry.blocks.length === 0) return fallbackRowHeight(row, width, beforeFooter, lastTurn);
    contentHeight = (entry.blocks.length - 1) * BLOCK_GAP;
    for (const block of entry.blocks) contentHeight += blockHeight(block, contentWidth, entry.prepared, usedPrepared);
  }
  // A stream changes only its tail block. Preserve prepared entries for the unchanged blocks and
  // trim stale revisions once per row, never once per token or across the transcript. `usedPrepared`
  // includes list items, whose text count can be much larger than the block count.
  trimPreparedCache(entry.prepared, entry.blocks.length, usedPrepared);
  // A long prompt opens collapsed to its first lines over Show more (conversation/UserBubble.tsx); a
  // Chief's draws its own bubble (ChiefPromptBubble.tsx).
  if (row.kind === "user" && row.from !== "chief" && !chiefEnvelope(row.text))
    contentHeight = collapsedPromptHeight(contentHeight, metrics().lineHeight);
  const height = messageBelow(beforeFooter) + chromeHeight(row) + contentHeight;
  return finish(beforeFooter ? height : Math.max(34, height));
}

/// A row's estimated height at a width, kept by the row object: rows are immutable (a change is a
/// new object), so a long chat's layout measures only the rows that changed since the last one.
/// The row's edge is kept too: a reply's height changes when its turn's footer arrives after it, and
/// a footer's when a prompt follows it.
export type RowHeights = WeakMap<AcpmuxRow, { width: number; height: number; edge?: "footer" | "last" | "last-turn" }>;

/** DOM-free row geometry. Only visible rows need their React elements painted. */
export function layoutConversation(
  rows: AcpmuxRow[],
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
      rowEdge(rows[drawn]!, nextDrawnRow(rows, drawn)) !== rowEdge(rows[drawn]!, nextDrawnRow(previous.rows, drawn))
    )
      start = drawn;
    tops.set(previous.layout.tops.subarray(0, start));
    heights.set(previous.layout.heights.subarray(0, start));
  }
  let top = start > 0 ? tops[start - 1]! + heights[start - 1]! : 0;
  // Hidden bookkeeping can span many rows. Keep the next drawn row for the whole
  // pass: searching anew for every hidden row makes one run quadratic.
  let nextDrawn = start;
  for (let index = start; index < rows.length; index += 1) {
    tops[index] = top;
    const row = rows[index]!;
    if (nextDrawn <= index) {
      nextDrawn = index + 1;
      while (nextDrawn < rows.length && drawsNothing(rows[nextDrawn]!)) nextDrawn += 1;
    }
    const edge = rowEdge(row, rows[nextDrawn]);
    const kept = known?.get(row);
    let height: number;
    if (kept && kept.width === width && kept.edge === edge) height = kept.height;
    else {
      const customHeight = measureOverride?.(row, width);
      height =
        customHeight !== undefined && Number.isFinite(customHeight) && customHeight > 0
          ? customHeight
          : measuredRowHeight(row, width, cache, edge === "footer", edge === "last-turn", sessionId);
      known?.set(row, { width, height, edge });
    }
    heights[index] = height;
    top += height;
  }
  return { tops, heights, totalHeight: top };
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
import { chatDisplay, currentChatMetrics } from "./chatDisplay";
import { messageOpened } from "./conversation/incomingOpened";

/// The pane's fallback accessible name and problem-only header status.
export function paneHeader(
  snapshot: AcpmuxSnapshot,
  t: Translate = translate,
): { title: string; status: string; detail?: string } {
  const harness = snapshot.summary?.harness;
  const title = harness
    ? agentName(harness, snapshot.catalog?.find((entry) => entry.id === harness)?.name)
    : t("header.agentChat");
  // Initial connecting and normal turn events are quiet. The client includes the failure
  // after `connecting:` while retrying, and keeps it until a successful connection.
  const connection = snapshot.connection;
  const retrying = connection.startsWith("connecting:") || connection === "reconnecting";
  const failed = /^(error|failed)(:|$)/i.test(connection) || connection === "fork failed";
  const status =
    connection === "disconnected"
      ? t("header.disconnected")
      : retrying
        ? t("header.reconnecting")
        : failed
          ? t("header.failed")
          : "";
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
