import { editedPaths } from "./toolPaths";
import type { PermissionClientState } from "./permissions/protocol";
import type { AgentQuestion } from "./question/model";
import type { HandoffClientState } from "./handoff/client";
import type { Enforcement } from "./handoff/protocol";
import type { SlashCommand } from "./slashCommands";
import type { SummaryCheckpoint } from "./changes/turnCheckpointSource";
import { appHref, linkHref, safeHref } from "./replyHref";
import type { ShellRun } from "./shell/shellRuns";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";
import { SUBAGENT_OF, SUBAGENT_ROW } from "./subagents/subagentRows";
import type { ComposerAttachment } from "./attachments";

/** One item of an agent's todo list (an ACP `plan` entry). */
export type AcpmuxPlanEntry = { content: string; status: "pending" | "in_progress" | "completed" };

/** How a background shell ended (acpmux `background_task_update`, cx-ncc.84). */
export type AcpmuxBackgroundTask = {
  toolCallId: string;
  command: string;
  state: "completed" | "failed" | "stopped";
  reason?: string;
};

/// A compaction of the chat's context (acpmux `compaction`): running, then how it ended. `reason`
/// is a wrapper's ("account_switch": subrouter compacted before moving the chat to another account).
export type AcpmuxCompaction = {
  state: "running" | "completed" | "failed";
  /// Failed because its turn ended while it ran, not because it said so; a later end replaces it.
  inferred?: boolean;
  reason?: string;
  preTokens?: number;
  postTokens?: number;
};

/// acpmux moved the chat onto its fallback harness after a usage limit (a `failover` record).
export type AcpmuxFailover = { from: string; to: string };

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

export type QueuedPrompt = { id: string; prompt: string; next?: boolean };
/// An image a prompt sent: `_acpmux/attachment {sessionId, id}` reads its bytes back.
export type PromptImage = { id: string; mimeType: string; name?: string };

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
  items?: AcpmuxActivity[];
  /// A plan row's todo list (cx-ncc.80): the agent's latest `plan` update in its turn.
  plan?: AcpmuxPlanEntry[];
  /// A background task row's shell, which ended where the row sits (cx-ncc.84).
  backgroundTask?: AcpmuxBackgroundTask;
  /// A compaction row's compaction, noted where it happened.
  compaction?: AcpmuxCompaction;
  /// A failover row's harnesses.
  failover?: AcpmuxFailover;
  /// A session start row's agent, version, model, route and folder.
  sessionStart?: AcpmuxSessionStart;
  /// A suggested tasks card's offers (offer/SuggestedTasks.tsx): the offers of one group, in the
  /// order the agent made them, or one offer made without a group.
  offers?: AcpmuxSessionOffer[];
  /// A prompt acpmux sent this chat with a suggested task's result (offer/SuggestedTasks.tsx).
  received?: AcpmuxOfferResult;
  toolCount?: number;
  durationMs?: number;
  /// A turn summary's checkpoints, when acpmux recorded them (changes/turnCheckpointSource.ts).
  checkpoint?: SummaryCheckpoint;
  /// A sent prompt's images, as acpmux names them in its user_message (hub/prompt_images.rs).
  images?: PromptImage[];
  /// The originating prompt row, so Retry can restore image/PDF attachments.
  retryRowId?: string;
  retryAttachments?: ComposerAttachment[];
  status?: string;
  error?: string;
  permission?: AcpmuxPermission;
  /// A turn summary whose turn draws a "Worked for" line (conversation/turns.ts), so its
  /// footer need not repeat the time and count.
  folded?: boolean;
  /// Work shown inside an open "Worked for": its turn has ended, so each run of tool calls
  /// folds under one summary line (conversation/toolRunSummary.ts).
  settled?: boolean;
  /// A running turn's run of tool calls still in flight, drawn as its newest call alone (Debug toggle,
  /// conversation/turns.ts `codexRuns`).
  inFlight?: boolean;
  /// The live turn's latest row, whose last thought may still stream (conversation/turns.ts).
  live?: boolean;
  /// A "Worked for" disclosure of a turn without timing reads "N previous messages" (conversation/turns.ts).
  previous?: number;
  /// A prompt queued behind a harness switch (its id there), which offers Cancel (harnessSwitch.ts).
  queued?: string;
  /// A prompt sent into a running turn: `waiting` until the agent reads it (it reads a steer when
  /// the step it is on ends), then `landed`; `stopped` was sent now to an agent that cannot steer,
  /// which stopped the turn and ran it next.
  steer?: "waiting" | "landed" | "stopped";
  /// The last turn's footer carries its prompt, for Retry (conversation/turns.ts).
  prompt?: string;
  /// An edited-files card of a turn that has ended, which offers Undo (conversation/turns.ts).
  ended?: boolean;
  /// The edits an edited-files card merges (their row ids), so Find reaches each (chatFind.ts).
  merged?: string[];
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
    /// A finished shell call's exit status (Codex's `rawOutput.exit_code`).
    exitCode?: number;
    /// When the call started and, once it completed or failed, when it ended (epoch ms),
    /// for the duration a command row shows.
    startedAt?: number;
    endedAt?: number;
    diffs?: AcpmuxFileDiff[];
    locations?: { path: string; line?: number }[];
    /// Images the call returned (ACP `image` content blocks), as data URLs.
    images?: string[];
  };
};

/// A file change from an ACP tool call's `diff` content: `oldText` is absent for a new file.
/// `line` is where the change starts, when the tool call's locations name it.
export type AcpmuxFileDiff = { path: string; oldText?: string; newText: string; line?: number };

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

export type AcpmuxPermission = {
  permissionId: string;
  groupId?: string;
  turnId?: string;
  title?: string;
  command?: string;
  description?: string;
  rule?: string;
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
  contextWindow?: number;
  /** The catalog release an alias stands for (the picker catalog's alias rows). */
  release?: string;
};

/// A change to a waiting prompt (`_acpmux/queue_edit`): its text, its place (0 runs next), or
/// send it now.
export type QueueEdit =
  | { op: "update"; text: string }
  | { op: "move"; index: number }
  | { op: "send_now" }
  /** Runs a queue a failed turn paused; any of its prompts names it. */
  | { op: "resume" };

export type AcpmuxSnapshot = {
  type: "snapshot";
  protocolVersion: number;
  rows: AcpmuxRow[];
  /// Each subagent's own view by subagent id: its rows, opened from its line in a group
  /// (subagents/childRows.ts).
  subagentViews?: Record<string, AcpmuxRow[]>;
  sessions: AcpmuxSessionEntry[];
  /** Connected peer names advertised by the acpmux daemon, including peers without chats yet. */
  peers?: string[];
  /// The open chat is a fork: the seq of its `forked` event, where the copied history ends (cx-ncc.61).
  forkedAtSeq?: number;
  summary?: {
    sessionId: string;
    cwd?: string;
    turnCount?: number;
    /// Context-window tokens used of the session's window, from the agent's last usage update.
    usage?: { used: number; size: number };
    host?: string;
    peer?: string;
    hostKind?: "local" | "cloud";
    branch?: string;
    worktree?: string;
    title?: string;
    name?: string;
    harness?: string;
    /// The harness family acpmux files the session under (`codex`, `opencode`, ...), when it says.
    family?: string;
    model?: string;
    /// The model the agent last reported, when the pane draws a pick (`model`) it has not
    /// confirmed yet (harnessSwitch.ts). Unset otherwise: `model` is what it reported.
    confirmedModel?: string;
    effort?: string;
    /// ACP's: `audio` is a harness that takes voice input (the mic sends its recording).
    promptCapabilities?: { image?: boolean; audio?: boolean };
    /// The agent takes a prompt mid-turn (acpmux `steering`); without it a steer stops the turn.
    steering?: boolean;
    /// A turn failed: the queued prompts wait until the user resumes the queue (acpmux `queuePaused`).
    queuePaused?: boolean;
    /// The MCP servers the harness says it loaded (acpmux `mcpServers`, from Claude Code's
    /// system/init); unset when it reports none (every ACP harness).
    mcpServers?: { name: string; status: "connected" | "failed" | "pending" }[];
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
  /// The client has read the daemon's chat list once: `sessions` is the daemon's, not the empty
  /// list a connection starts with (newtab/chatStore.ts publishes only such a list).
  listedSessions?: true;
  sessionId?: string;
  isWorking: boolean;
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
  permission?: AcpmuxPermission;
  secret?: AcpmuxSecretAsk;
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
    /** `_acpmux/harnesses` `icon`: a brand id, or a file the host serves. */
    icon?: string;
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
  /** The agent's slash commands, for the composer's `/` menu. */
  commands?: SlashCommand[];
  /** A harness switch the pane draws ahead of acpmux (harnessSwitch.ts): starting, applying to
   * the next turn while one streams (deferred), or failed with acpmux's reason. */
  switching?: { harness: string; name: string; phase: "starting" | "deferred" | "failed"; error?: string };
  /** A `cmux://session/<id>` link named this session and the daemon has none: the pane says so
   * instead of showing another chat. Unset once a session is selected. */
  missingSession?: string;
  /** The outside chat this pane adopts is still open in another process (acpmux refused with
   * `adopt.live`): the pane offers Open Anyway, and Fork It when the harness can fork. `command`
   * is the process that holds it, when acpmux found one. Unset once a choice is sent. */
  liveChat?: { canFork: boolean; command?: string };
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

/// Metrics of conversation/conversation.css (`--cv-font-size`, `--cv-line-height`, `.cv-*`).
const MEASURE_FONT = "14px system-ui";
const MESSAGE_LINE_HEIGHT = 22.75;
/// Vertical padding of a user bubble (`.cv-user__bubble`).
const USER_BUBBLE_PADDING = 16;
/// The status line under a queued prompt (`.cv-user__status`: 4px above a 16px line).
const USER_STATUS_HEIGHT = 20;
const chromeHeight = (row: AcpmuxRow) =>
  row.kind === "user" ? USER_BUBBLE_PADDING + (row.status ? USER_STATUS_HEIGHT : 0) : 0;
/// The bubble's share of its row and its side padding, which sits inside that share (border-box).
const USER_BUBBLE_SHARE = 0.7;
const USER_BUBBLE_SIDES = 24;
/// Space between a row's markdown blocks, the list indent and the quote's bar and padding.
const BLOCK_GAP = 14;
const LIST_INDENT = 28;
const QUOTE_INDENT = 21;
/// Code cards: a 45.5px header over 12px monospace on 20px lines that never wraps, 13px inset.
const CODE_LINE_HEIGHT = 20;
const CODE_CHROME = 58.5;
const CODE_PADDING = 13;
/// Table rows: 23px lines with 17px of padding.
const TABLE_ROW_HEIGHT = 40;
const CODE_CHAR_WIDTH = 7.3;
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
/// (toolPaths.ts), and one entry with no path for each call that names none ("Unknown file").
/// Never the tool input itself.
export function plainEditLabels(items: readonly AcpmuxActivity[]): { key: string; path?: string }[] {
  const out: { key: string; path?: string }[] = [];
  const seen = new Set<string>();
  items.forEach((item, index) => {
    if (!item.tool || item.tool.diffs?.length) return;
    const paths = editedPaths(item.tool);
    if (!paths.length) out.push({ key: `unknown-${item.tool.id}-${index}` });
    for (const path of paths)
      if (!seen.has(path)) {
        seen.add(path);
        out.push({ key: `path-${path}`, path });
      }
  });
  return out;
}

/// First-layout estimates for rows not yet drawn; a drawn row places by its drawn height. Each
/// includes the row's bottom padding (`.acpmux-row` in styles.css: 16px for messages, 8px else).
function fallbackRowHeight(row: AcpmuxRow, width: number): number {
  const textLines = Math.max(1, Math.ceil((row.text?.length ?? 0) / Math.max(24, Math.floor(width / 8))));
  if (row.kind === "activity") {
    // The edited-files card (conversation/EditedFilesCard.tsx): a 58px head, and 34px for each of the first
    // three files and for "Show N more"; one file is named in the head. Otherwise tool rows
    // (`.cv-tools`: 2px above 26px rows), which is also how a copy inside an open "Worked for" draws.
    const edits = row.items?.filter((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange") ?? [];
    if (edits.length && !isFoldedCopy(row)) {
      const files = new Set(edits.flatMap((item) => item.tool?.diffs?.map((diff) => diff.path) ?? [])).size;
      return 14 + editedCardHeight(files, plainEditLabels(edits).length);
    }
    // In an open "Worked for", a run of two or more calls draws one summary line until opened.
    if (row.settled && row.items && isFoldedRun(row.items)) return 36;
    return Math.max(34, 10 + 26 * (row.items?.length ?? 1));
  }
  // A subagent group's 48px line with 8px above it, and in an open group a 48px line per
  // subagent, the last with the list's 8px below (subagents/SubagentGroup.tsx).
  if (row.kind === SUBAGENTS) return 56;
  if (row.kind === SUBAGENT_ROW) return row.status === "last" || row.status === "only" ? 56 : 48;
  // The child view's 28px "Subagent of" pill with 8px above and below it.
  if (row.kind === SUBAGENT_OF) return 44;
  // The 27px disclosure line, and the live status lines in its place.
  if (row.kind === WORKED || row.kind === WORKING || row.kind === THINKING) return 35;
  // The 20px date line with 8px above it.
  if (row.kind === DATE) return 36;
  // The preview card: its 58px head over the thumbnail, and 6px below (PreviewCard.tsx).
  // A gallery stage's live frame is taller (previewFrameHeight).
  if (row.kind === PREVIEW) return 58 + (row.text ? previewFrameHeight(row.text) : PREVIEW_FRAME_HEIGHT) + 6 + 8;
  // The render card: its 36px head over the frame before it reports a height, and 6px below.
  if (row.kind === RENDER) return 36 + RENDER_FRAME_MIN_HEIGHT + 6;
  // Card padding and border, title, button row.
  if (row.kind === "permission") return 87;
  // A suggested tasks card (offer/SuggestedTasks.tsx): its 28px heading, about 84px per open task
  // and 30px per started one, in 8px of margins.
  if (row.kind === "sessionOffer" && row.offers) {
    const open = row.offers.filter((offer) => !offer.outcome).length;
    const started = row.offers.filter((offer) => offer.outcome === "accepted").length;
    return 8 + 8 + 28 + open * 84 + started * 30;
  }
  // A session start: its facts line, and the compaction note under it until it is dismissed.
  if (row.kind === "sessionStart") return 37 + 44;
  // The plan's 20px progress line over its 22px items, inside 8px margins (conversation/PlanList.tsx).
  if (row.kind === "plan" && row.plan) return 24 + 20 + row.plan.length * 22;
  if (
    row.kind === "turnSummary" ||
    row.kind === "notice" ||
    row.kind === "backgroundTask" ||
    row.kind === "compaction" ||
    row.kind === "failover" ||
    row.kind === "plan" ||
    row.kind === "typing"
  )
    return 37;
  return 24 + chromeHeight(row) + textLines * MESSAGE_LINE_HEIGHT;
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

function textHeight(text: string, width: number, prepared: Map<string, PreparedText | null>): number {
  let measured = prepared.get(text);
  if (measured === undefined) {
    try {
      measured = prepare(text, MEASURE_FONT, { whiteSpace: "pre-wrap" });
    } catch {
      measured = null;
    }
    prepared.set(text, measured);
  }
  if (measured) return layout(measured, width, MESSAGE_LINE_HEIGHT).height;
  const perLine = Math.max(24, Math.floor(width / FALLBACK_CHAR_WIDTH));
  return (
    text.split("\n").reduce((lines, line) => lines + Math.max(1, Math.ceil(line.length / perLine)), 0) *
    MESSAGE_LINE_HEIGHT
  );
}

/// Each item's text at the list's indent, then any list nested in it a further indent in.
function listHeight(list: Tokens.List, width: number, prepared: Map<string, PreparedText | null>): number {
  const inner = width - LIST_INDENT;
  return list.items.reduce((sum, item) => {
    const nested = item.tokens.filter((token): token is Tokens.List => token.type === "list");
    const text = measuredText(
      item.tokens.filter((token) => token.type !== "list"),
      nested.length ? "" : item.text,
    );
    // An empty item (or one still streaming in) still draws its bullet's line.
    const own = text ? textHeight(text, inner, prepared) : 0;
    return (
      sum +
      Math.max(
        MESSAGE_LINE_HEIGHT,
        own + nested.reduce((total, child) => total + listHeight(child, inner, prepared), 0),
      )
    );
  }, 0);
}

function blockHeight(block: Token, width: number, prepared: Map<string, PreparedText | null>): number {
  switch (block.type) {
    // Prose (lists, quotes, paragraphs, headings) keeps its measure in a wide column (chatWidth.ts).
    case "list":
      return listHeight(block as Tokens.List, Math.min(width, chatColumn().prose), prepared);
    case "blockquote":
      return textHeight(
        measuredText((block as Tokens.Blockquote).tokens, (block as Tokens.Blockquote).text),
        Math.min(width, chatColumn().prose) - QUOTE_INDENT,
        prepared,
      );
    case "hr":
      return 2;
    case "code": {
      const lines = (block as Tokens.Code).text.split("\n");
      const scrolls = lines.some((line) => line.length * CODE_CHAR_WIDTH > width - CODE_PADDING);
      return CODE_CHROME + lines.length * CODE_LINE_HEIGHT + (scrolls ? SCROLLBAR_HEIGHT : 0);
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
      );
    // Anything else is estimated as its source; the drawn height replaces it once mounted.
    default:
      return textHeight(block.raw, width, prepared);
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

function measuredRowHeight(row: AcpmuxRow, width: number, cache: Map<string, PreparedRow>): number {
  // A task's result is one 26px line, however long the prompt that brought it (offer/SuggestedTasks.tsx).
  if (row.received) return 26 + 16;
  // A preview row's text is its address, not prose: the card's height is fixed.
  if (!row.text || row.kind === PREVIEW) return fallbackRowHeight(row, width);
  let entry = cache.get(row.id);
  if (!entry) {
    entry = { text: "", blocks: [], closedBlocks: [], closedEnd: 0, lexedLength: 0, prepared: new Map() };
    cache.set(row.id, entry);
  }
  if (entry.text !== row.text || entry.lexedLength === 0) {
    lexIncrementally(entry, row.text);
    // A streaming row prepares a new last block on every version; keep the cache bounded.
    if (entry.prepared.size > 64) entry.prepared.clear();
  }
  if (entry.blocks.length === 0) return fallbackRowHeight(row, width);
  const contentWidth = Math.max(80, row.kind === "user" ? USER_BUBBLE_SHARE * width - USER_BUBBLE_SIDES : width);
  let contentHeight = (entry.blocks.length - 1) * BLOCK_GAP;
  for (const block of entry.blocks) contentHeight += blockHeight(block, contentWidth, entry.prepared);
  return Math.max(34, 16 + chromeHeight(row) + contentHeight);
}

/// A row's estimated height at a width, kept by the row object: rows are immutable (a change is a
/// new object), so a long chat's layout measures only the rows that changed since the last one.
export type RowHeights = WeakMap<AcpmuxRow, { width: number; height: number }>;

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
): ConversationLayout {
  const tops = new Float64Array(rows.length);
  const heights = new Float64Array(rows.length);
  let start = 0;
  if (previous) {
    const limit = Math.min(rows.length, previous.rows.length);
    while (start < limit && rows[start] === previous.rows[start]) start += 1;
    tops.set(previous.layout.tops.subarray(0, start));
    heights.set(previous.layout.heights.subarray(0, start));
  }
  let top = start > 0 ? tops[start - 1]! + heights[start - 1]! : 0;
  for (let index = start; index < rows.length; index += 1) {
    tops[index] = top;
    const row = rows[index]!;
    const kept = known?.get(row);
    let height: number;
    if (kept && kept.width === width) height = kept.height;
    else {
      const customHeight = measureOverride?.(row, width);
      height =
        customHeight !== undefined && Number.isFinite(customHeight) && customHeight > 0
          ? customHeight
          : measuredRowHeight(row, width, cache);
      known?.set(row, { width, height });
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
    const known = heightAt(index);
    const height = known !== undefined && known > 0 ? known : estimate.heights[index];
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
import { PREVIEW_FRAME_HEIGHT, previewFrameHeight } from "./conversation/previewUrl";
import { RENDER_FRAME_MIN_HEIGHT } from "./conversation/renderCall";
import { DATE, isFoldedCopy, PREVIEW, RENDER, THINKING, WORKED, WORKING } from "./conversation/turns";
import type { AcpmuxSessionEntry } from "./sessionList";
import { agentName } from "./agents";
import { type Translate, translate } from "./i18n";
import { lastBlockBoundary } from "./conversation/incrementalMarkdown";
import { chatColumn, type ChatColumn } from "./chatWidth";

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
