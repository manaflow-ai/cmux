import type { SlashCommand } from "./slashCommands";

export type AcpmuxRow = {
  id: string;
  version: number;
  at: number;
  kind: string;
  text?: string;
  streaming?: boolean;
  pending?: boolean;
  failed?: boolean;
  items?: AcpmuxActivity[];
  toolCount?: number;
  durationMs?: number;
  status?: string;
  error?: string;
  permission?: AcpmuxPermission;
};

export type AcpmuxActivity = {
  kind: string;
  text: string;
  status?: string;
  tool?: { id: string; title: string; kind?: string; status: string; inputSummary?: string; output?: string };
};

export type AcpmuxPermission = {
  permissionId: string;
  title?: string;
  kind?: string;
  pending: boolean;
  options: { id: string; name: string; allow: boolean }[];
};

export type AcpmuxSnapshot = {
  type: "snapshot";
  protocolVersion: number;
  rows: AcpmuxRow[];
  sessions: { sessionId: string; displayTitle?: string; title?: string; name?: string; status?: string; model?: string }[];
  summary?: { sessionId: string; title?: string; name?: string; harness?: string; model?: string; effort?: string; status?: string; modes?: { availableModes: { id: string; name?: string }[]; currentModeId?: string }; configOptions?: { id: string; name?: string; category?: string; currentValue?: string; options: { value: string; name?: string }[] }[]; promptCapabilities?: { image?: boolean; embeddedContext?: boolean }; steering?: boolean };
  connection: string;
  sessionId?: string;
  isWorking: boolean;
  queue: { id: string; prompt: string }[];
  permission?: AcpmuxPermission;
  catalog: { id: string; name: string; models: { id: string; name?: string }[] }[];
  canLoadOlder: boolean;
  /** The agent's slash commands, for the composer's `/` menu. */
  commands?: SlashCommand[];
};

export type RowChange = { added: AcpmuxRow[]; updated: AcpmuxRow[]; removed: string[] };

export type PreparedRow = {
  text: string;
  /// The row's markdown blocks, as `MarkdownBlocks` in App.tsx renders them.
  blocks: Token[];
  /// Measured text by its source, kept across a streaming row's versions; null where it can't be measured.
  prepared: Map<string, PreparedText | null>;
};

export type ConversationLayout = {
  tops: Float64Array;
  heights: Float64Array;
  totalHeight: number;
};

const MEASURE_FONT = '13px "Helvetica Neue"';
const MESSAGE_LINE_HEIGHT = 20;
/// Vertical padding of a user bubble (`.acpmux-user-bubble` in styles.css).
const USER_BUBBLE_PADDING = 18;
const chromeHeight = (row: AcpmuxRow) => row.kind === "user" ? USER_BUBBLE_PADDING : 0;
/// The bubble's share of its row and its side padding, which sits inside that share (border-box).
const USER_BUBBLE_SHARE = 0.78;
const USER_BUBBLE_SIDES = 24;
/// Space between a row's markdown blocks, the browser's list indent and the quote's rule and padding.
const BLOCK_GAP = 8;
const LIST_INDENT = 40;
const QUOTE_INDENT = 14;
/// Code blocks: 12px monospace that never wraps, in a pre with 9px padding.
const CODE_LINE_HEIGHT = 16;
const CODE_PADDING = 18;
const CODE_CHAR_WIDTH = 7.3;
const SCROLLBAR_HEIGHT = 15;
/// Where text can't be measured (no canvas), a generous character width.
const FALLBACK_CHAR_WIDTH = 8;
/// Rows are at most 760px wide, inside 18px side gutters (`.acpmux-row` in styles.css).
const MAX_ROW_WIDTH = 760;
export const transcriptRowWidth = (paneWidth: number) => Math.max(120, Math.min(MAX_ROW_WIDTH, paneWidth - 36));

/// A message's markdown blocks. Blank lines between blocks are only spacing, never blocks of their own.
export function markdownBlocks(source: string): Token[] {
  try { return lexer(source, { gfm: true, breaks: true }).filter((token) => token.type !== "space"); } catch { return [{ type: "text", raw: source, text: source } as Token]; }
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

export function visibleRowRange(rowCount: number, scrollTop: number, viewportHeight: number, estimate = 96, overscan = 8) {
  const first = Math.max(0, Math.floor(scrollTop / estimate) - overscan);
  const last = Math.min(rowCount, Math.ceil((scrollTop + viewportHeight) / estimate) + overscan);
  return { first, last };
}

/// First-layout estimates for rows not yet drawn; a drawn row places by its drawn height. Each
/// includes the row's bottom padding (`.acpmux-row` in styles.css: 16px for messages, 8px else).
function fallbackRowHeight(row: AcpmuxRow, width: number): number {
  const textLines = Math.max(1, Math.ceil((row.text?.length ?? 0) / Math.max(24, Math.floor(width / 8))));
  if (row.kind === "activity") {
    // Collapsed tool calls, or the edited-files list (a title and one line per file).
    const edits = row.items?.filter((item) => item.tool?.kind === "edit" || item.tool?.kind === "fileChange").length ?? 0;
    return edits ? 8 + 16 * (1 + edits) : 34;
  }
  // Card padding and border, title, button row.
  if (row.kind === "permission") return 87;
  if (row.kind === "turnSummary" || row.kind === "notice" || row.kind === "plan" || row.kind === "typing") return 37;
  return 24 + chromeHeight(row) + textLines * MESSAGE_LINE_HEIGHT;
}

/// A link target the page opens: http and https only.
export function safeHref(href: string): string | undefined {
  try { return /^https?:$/i.test(new URL(href, "https://cmux.invalid").protocol) ? href : undefined; } catch { return undefined; }
}

/// The text `renderInline` in App.tsx draws for `tokens`, as the estimator measures it. Inline
/// code draws in 11.5px monospace (styles.css), no wider per character than the prose font's digits,
/// so each of its characters measures as a "0". A monospace space is a full cell, so a code
/// space measures as a "0" and a space, which keeps the line break.
export function measuredText(tokens: Token[] | undefined, fallback: string): string {
  if (!tokens?.length) return fallback;
  return tokens.map((token) => {
    if (token.type === "codespan") return (token as Tokens.Codespan).text.replace(/\S/g, "0").replace(/ /g, "0 ");
    if (token.type === "link" && !safeHref((token as Tokens.Link).href)) return (token as Tokens.Link).text;
    if ("tokens" in token) return measuredText(token.tokens, "text" in token ? token.text : token.raw ?? "");
    return token.raw ?? ("text" in token ? token.text : "");
  }).join("");
}

function textHeight(text: string, width: number, prepared: Map<string, PreparedText | null>): number {
  let measured = prepared.get(text);
  if (measured === undefined) {
    try { measured = prepare(text, MEASURE_FONT, { whiteSpace: "pre-wrap" }); } catch { measured = null; }
    prepared.set(text, measured);
  }
  if (measured) return layout(measured, width, MESSAGE_LINE_HEIGHT).height;
  const perLine = Math.max(24, Math.floor(width / FALLBACK_CHAR_WIDTH));
  return text.split("\n").reduce((lines, line) => lines + Math.max(1, Math.ceil(line.length / perLine)), 0) * MESSAGE_LINE_HEIGHT;
}

function blockHeight(block: Token, width: number, prepared: Map<string, PreparedText | null>): number {
  switch (block.type) {
    // An empty item (or one still streaming in) still draws its bullet's line.
    case "list": return (block as Tokens.List).items.reduce((sum, item) => sum + Math.max(MESSAGE_LINE_HEIGHT, textHeight(measuredText(item.tokens, item.text), width - LIST_INDENT, prepared)), 0);
    case "blockquote": return textHeight(measuredText((block as Tokens.Blockquote).tokens, (block as Tokens.Blockquote).text), width - QUOTE_INDENT, prepared);
    case "hr": return 2;
    case "code": {
      const lines = (block as Tokens.Code).text.split("\n");
      const scrolls = lines.some((line) => line.length * CODE_CHAR_WIDTH > width - CODE_PADDING);
      return CODE_PADDING + lines.length * CODE_LINE_HEIGHT + (scrolls ? SCROLLBAR_HEIGHT : 0);
    }
    case "paragraph":
    case "text":
    case "heading": return textHeight(measuredText("tokens" in block ? block.tokens : undefined, (block as Tokens.Text).text), width, prepared);
    // MarkdownBlocks draws any other block as its source.
    default: return textHeight(block.raw, width, prepared);
  }
}

function measuredRowHeight(row: AcpmuxRow, width: number, cache: Map<string, PreparedRow>): number {
  if (!row.text) return fallbackRowHeight(row, width);
  let entry = cache.get(row.id);
  if (!entry) {
    entry = { text: row.text, blocks: markdownBlocks(row.text), prepared: new Map() };
    cache.set(row.id, entry);
  } else if (entry.text !== row.text) {
    entry.text = row.text;
    entry.blocks = markdownBlocks(row.text);
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
export function layoutConversation(rows: AcpmuxRow[], width: number, cache = new Map<string, PreparedRow>(), measureOverride?: (row: AcpmuxRow, width: number) => number | undefined): ConversationLayout {
  const tops = new Float64Array(rows.length);
  const heights = new Float64Array(rows.length);
  let top = 0;
  for (let index = 0; index < rows.length; index += 1) {
    tops[index] = top;
    const customHeight = measureOverride?.(rows[index], width);
    const height = customHeight !== undefined && Number.isFinite(customHeight) && customHeight > 0 ? customHeight : measuredRowHeight(rows[index], width, cache);
    heights[index] = height;
    top += height;
  }
  return { tops, heights, totalHeight: top };
}

/// Places rows again over `estimate`, taking a row's height from `heightAt` when it has one.
/// No row is measured, so this costs one pass over the rows' heights.
export function placeRows(estimate: ConversationLayout, heightAt: (index: number) => number | undefined): ConversationLayout {
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

export function visibleLayoutRange(layoutModel: ConversationLayout, scrollTop: number, viewportHeight: number, overscan = 4) {
  if (layoutModel.tops.length === 0) return { first: 0, last: 0 };
  const first = Math.max(0, upperBound(layoutModel.tops, Math.max(0, scrollTop)) - 1 - overscan);
  const last = Math.min(layoutModel.tops.length, upperBound(layoutModel.tops, scrollTop + viewportHeight) + overscan);
  return { first, last };
}
import { layout, prepare, type PreparedText } from "@chenglou/pretext";
import { lexer, type Token, type Tokens } from "marked";
