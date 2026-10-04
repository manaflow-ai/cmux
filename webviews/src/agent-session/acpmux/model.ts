import type { PermissionClientState } from "./permissions/protocol";
import type { HandoffClientState } from "./handoff/client";
import type { Enforcement } from "./handoff/protocol";
import type { SlashCommand } from "./slashCommands";
import type { SummaryCheckpoint } from "./changes/turnCheckpointSource";

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
  toolCount?: number;
  durationMs?: number;
  /// A turn summary's checkpoints, when acpmux recorded them (changes/turnCheckpointSource.ts).
  checkpoint?: SummaryCheckpoint;
  status?: string;
  error?: string;
  permission?: AcpmuxPermission;
  /// A turn summary whose turn draws a "Worked for" line (conversation/turns.ts), so its
  /// footer need not repeat the time and count.
  folded?: boolean;
  /// Work shown inside an open "Worked for": its turn has ended, so each run of tool calls
  /// folds under one summary line (conversation/toolRunSummary.ts).
  settled?: boolean;
  /// A "Worked for" disclosure of a turn without timing reads "N previous messages" (conversation/turns.ts).
  previous?: number;
  /// A prompt queued behind a harness switch (its id there), which offers Cancel (harnessSwitch.ts).
  queued?: string;
  /// The last turn's footer carries its prompt, for Retry (conversation/turns.ts).
  prompt?: string;
  /// An edited-files card of a turn that has ended, which offers Undo (conversation/turns.ts).
  ended?: boolean;
};

export type AcpmuxActivity = {
  kind: string;
  text: string;
  status?: string;
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
  };
};

/// A file change from an ACP tool call's `diff` content: `oldText` is absent for a new file.
/// `line` is where the change starts, when the tool call's locations name it.
export type AcpmuxFileDiff = { path: string; oldText?: string; newText: string; line?: number };

export type AcpmuxPermission = {
  permissionId: string;
  groupId?: string;
  turnId?: string;
  title?: string;
  kind?: string;
  pending: boolean;
  options: { id: string; name: string; allow: boolean }[];
};

export type AcpmuxSnapshot = {
  type: "snapshot";
  protocolVersion: number;
  rows: AcpmuxRow[];
  sessions: AcpmuxSessionEntry[];
  summary?: {
    sessionId: string;
    cwd?: string;
    turnCount?: number;
    /// Context-window tokens used of the session's window, from the agent's last usage update.
    usage?: { used: number; size: number };
    host?: string;
    hostKind?: "local" | "cloud";
    branch?: string;
    worktree?: string;
    title?: string;
    name?: string;
    harness?: string;
    model?: string;
    /// The model the agent last reported, when the pane draws a pick (`model`) it has not
    /// confirmed yet (harnessSwitch.ts). Unset otherwise: `model` is what it reported.
    confirmedModel?: string;
    effort?: string;
    promptCapabilities?: { image?: boolean };
    status?: string;
    enforcement?: Enforcement;
    modes?: { availableModes: { id: string; name?: string; description?: string }[]; currentModeId?: string };
    configOptions?: {
      id: string;
      name?: string;
      category?: string;
      currentValue?: string;
      options: { value: string; name?: string }[];
    }[];
  };
  connection: string;
  sessionId?: string;
  isWorking: boolean;
  /// acpmux serves `acp.session.fork` (operations.ts), so a turn can be forked from.
  canFork?: boolean;
  canHandoff?: boolean;
  handoff?: HandoffClientState;
  permissionGroups?: PermissionClientState;
  queue: { id: string; prompt: string }[];
  permission?: AcpmuxPermission;
  /** `unavailable`: why acpmux will not run that model (its backend refused it), or that harness
   * (its launcher check or its model probe failed). */
  catalog: {
    id: string;
    name: string;
    models: { id: string; name?: string; unavailable?: string }[];
    unavailable?: string;
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
};

export type RowChange = { added: AcpmuxRow[]; updated: AcpmuxRow[]; removed: string[] };

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
const USER_BUBBLE_PADDING = 20;
/// The status line under a queued prompt (`.cv-user__status`: 4px above a 16px line).
const USER_STATUS_HEIGHT = 20;
const chromeHeight = (row: AcpmuxRow) =>
  row.kind === "user" ? USER_BUBBLE_PADDING + (row.status ? USER_STATUS_HEIGHT : 0) : 0;
/// The bubble's share of its row and its side padding, which sits inside that share (border-box).
const USER_BUBBLE_SHARE = 0.7;
const USER_BUBBLE_SIDES = 32;
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
/// Rows are at most 720px wide, inside 26.5px side gutters (`--cv-column` and `--cv-gutter`
/// in conversation/conversation.css).
const MAX_ROW_WIDTH = 720;
const ROW_GUTTER = 26.5;
export const transcriptRowWidth = (paneWidth: number) =>
  Math.max(120, Math.min(MAX_ROW_WIDTH, paneWidth - 2 * ROW_GUTTER));

/// A message's markdown blocks. Blank lines between blocks are only spacing, never blocks of their own.
export function markdownBlocks(source: string): Token[] {
  try {
    return lexer(source, { gfm: true, breaks: true }).filter((token) => token.type !== "space");
  } catch {
    return [{ type: "text", raw: source, text: source } as Token];
  }
}

export function diffRows(previous: Map<string, AcpmuxRow>, next: AcpmuxRow[]): RowChange {
  const nextById = new Map(next.map((row) => [row.id, row]));
  const added: AcpmuxRow[] = [];
  const updated: AcpmuxRow[] = [];
  for (const row of next) {
    const before = previous.get(row.id);
    if (!before) added.push(row);
    else if (before.version !== row.version) updated.push(row);
  }
  const removed = [...previous.keys()].filter((id) => !nextById.has(id));
  return { added, updated, removed };
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

/// What an edit without a diff lists as in the edited-files card, deduped.
export function plainEditLabels(items: readonly AcpmuxActivity[]): string[] {
  return [
    ...new Set(items.filter((item) => !item.tool?.diffs?.length).map((item) => item.tool?.inputSummary || item.text)),
  ];
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
  // The 27px disclosure line, and the live status lines in its place.
  if (row.kind === WORKED || row.kind === WORKING || row.kind === THINKING) return 35;
  // The 20px date line with 8px above it.
  if (row.kind === DATE) return 36;
  // The preview card: its 58px head over the thumbnail, and 6px below (PreviewCard.tsx).
  if (row.kind === PREVIEW) return 58 + PREVIEW_FRAME_HEIGHT + 6 + 8;
  // Card padding and border, title, button row.
  if (row.kind === "permission") return 87;
  if (row.kind === "turnSummary" || row.kind === "notice" || row.kind === "plan" || row.kind === "typing") return 37;
  return 24 + chromeHeight(row) + textLines * MESSAGE_LINE_HEIGHT;
}

/// A link target the page opens: http and https only.
export function safeHref(href: string): string | undefined {
  try {
    return /^https?:$/i.test(new URL(href, "https://cmux.invalid").protocol) ? href : undefined;
  } catch {
    return undefined;
  }
}

/// The text `renderInline` in conversation/Markdown.tsx draws for `tokens`, as the estimator
/// measures it. Inline code draws in 12px monospace (conversation.css), no wider per character than the prose font's digits,
/// so each of its characters measures as a "0". A monospace space is a full cell, so a code
/// space measures as a "0" and a space, which keeps the line break.
export function measuredText(tokens: Token[] | undefined, fallback: string): string {
  if (!tokens?.length) return fallback;
  return tokens
    .map((token) => {
      if (token.type === "codespan") return (token as Tokens.Codespan).text.replace(/\S/g, "0").replace(/ /g, "0 ");
      if (token.type === "link" && !safeHref((token as Tokens.Link).href)) return (token as Tokens.Link).text;
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
    case "list":
      return listHeight(block as Tokens.List, width, prepared);
    case "blockquote":
      return textHeight(
        measuredText((block as Tokens.Blockquote).tokens, (block as Tokens.Blockquote).text),
        width - QUOTE_INDENT,
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
        width,
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
  if (!row.text) return fallbackRowHeight(row, width);
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

/** DOM-free row geometry. Only visible rows need their React elements painted. */
export function layoutConversation(
  rows: AcpmuxRow[],
  width: number,
  cache = new Map<string, PreparedRow>(),
  measureOverride?: (row: AcpmuxRow, width: number) => number | undefined,
): ConversationLayout {
  const tops = new Float64Array(rows.length);
  const heights = new Float64Array(rows.length);
  let top = 0;
  for (let index = 0; index < rows.length; index += 1) {
    tops[index] = top;
    const customHeight = measureOverride?.(rows[index], width);
    const height =
      customHeight !== undefined && Number.isFinite(customHeight) && customHeight > 0
        ? customHeight
        : measuredRowHeight(rows[index], width, cache);
    heights[index] = height;
    top += height;
  }
  return { tops, heights, totalHeight: top };
}

/// Places rows again over `estimate`, taking a row's height from `heightAt` when it has one.
/// No row is measured, so this costs one pass over the rows' heights.
export function placeRows(
  estimate: ConversationLayout,
  heightAt: (index: number) => number | undefined,
): ConversationLayout {
  const tops = new Float64Array(estimate.heights.length);
  const heights = new Float64Array(estimate.heights.length);
  let top = 0;
  for (let index = 0; index < heights.length; index += 1) {
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
import { layout, prepare, type PreparedText } from "@chenglou/pretext";
import { lexer, type Token, type Tokens } from "marked";
import { isFoldedRun } from "./conversation/toolRunSummary";
import { PREVIEW_FRAME_HEIGHT } from "./conversation/previewUrl";
import { DATE, isFoldedCopy, PREVIEW, THINKING, WORKED, WORKING } from "./conversation/turns";
import type { AcpmuxSessionEntry } from "./sessionList";
import { agentName } from "./agents";
import { lastBlockBoundary } from "./conversation/incrementalMarkdown";

/// The pane header: the agent the session runs (its first prompt already titles the session
/// picker and opens the transcript), and a status only when it says something to act on.
export function paneHeader(snapshot: AcpmuxSnapshot): { title: string; status: string } {
  const harness = snapshot.summary?.harness;
  const title = harness
    ? agentName(harness, snapshot.catalog?.find((entry) => entry.id === harness)?.name)
    : "Agent Chat";
  // A turn running when the connection dropped never ends, so connection trouble wins over Working.
  const connection = snapshot.connection;
  const status =
    connection === "disconnected"
      ? "Reconnecting"
      : connection.startsWith("connecting")
        ? "Connecting"
        : snapshot.isWorking
          ? "Working"
          : connection === "mock"
            ? "Mock"
            : "";
  return { title, status };
}
