// The row layout settings (CMUX-383): `sidebar.workspaceRow.lines`, `.linesByKind` and
// `.linesByAgent`, the token lines a workspace row draws. The Rust reducer
// (cmux-tui/crates/cmux-layout-reducer/src/sidebar_row_layout.rs) resolves a row from them and the
// daemon (cmux-config) refuses a value it would drop parts of, saying where (`accepted.problems`).
// This file is the editor's model only: it reads a stored value into what the editor shows, makes
// each edit, and writes a value inside the reducer's bounds, so an edit made here is never refused.
// The names and bounds below are the reducer's (TOKENS, SLOTS, MAX_LINES, MAX_TOKENS).

export const LINES_KEY = "sidebar.workspaceRow.lines";
export const BY_KIND_KEY = "sidebar.workspaceRow.linesByKind";
export const BY_AGENT_KEY = "sidebar.workspaceRow.linesByAgent";
export const LAYOUT_KEYS = [LINES_KEY, BY_KIND_KEY, BY_AGENT_KEY] as const;
export type LayoutKey = (typeof LAYOUT_KEYS)[number];

export function isLayoutKey(key: string): key is LayoutKey {
  return (LAYOUT_KEYS as readonly string[]).includes(key);
}

/** Every token, in the reducer's order. */
export const TOKENS = [
  "icon",
  "name",
  "working",
  "progress",
  "notification",
  "directory",
  "branch",
  "process",
  "agentStatus",
  "tabCount",
  "ports",
  "lastActivity",
  "pullRequest",
  "log",
] as const;
export type Token = (typeof TOKENS)[number];

/** The fixed slots: writing one turns it on; the native grid owns where it draws. */
export const SLOTS = ["icon", "working", "progress"] as const;
export type Slot = (typeof SLOTS)[number];

/** The tokens that draw text on a line, in the order the Add Item menu lists them. */
export const TEXT_TOKENS = TOKENS.filter((token) => token !== "name" && !isSlot(token)) as Exclude<
  Token,
  Slot | "name"
>[];
export type TextToken = (typeof TEXT_TOKENS)[number];

export const MAX_LINES = 3;
/** Text tokens on one line, the name not counted. */
export const MAX_TOKENS = 6;
/** The row kinds `linesByKind` names (the kinds of `sidebar.workspaceRow.<kind>.*`). */
export const KINDS = ["terminal", "agent", "browser", "mixed"] as const;
export type Kind = (typeof KINDS)[number];
/** `linesByAgent`'s shape: at most 32 agents, ids of 1 to 64 characters. */
export const MAX_AGENTS = 32;
export const MAX_AGENT_ID = 64;

export function isSlot(token: string): token is Slot {
  return (SLOTS as readonly string[]).includes(token);
}

function isToken(token: unknown): token is Token {
  return typeof token === "string" && (TOKENS as readonly string[]).includes(token);
}

/**
 * One layout as the editor shows it: the slots that are on, and the text lines. `lines[0]` is line
 * one and always exists; the name leads it and is never in `lines` (it cannot move or go).
 */
export type Layout = { slots: ReadonlySet<Slot>; lines: TextToken[][] };

/** Where a chip is: its line and its place among the line's text tokens. */
export type Place = { line: number; index: number };

/**
 * A stored layout (a list of token lists) as it applies: known tokens once each, the name first on
 * line one, empty lines dropped, at most MAX_LINES lines of MAX_TOKENS text tokens (what the reducer
 * draws from the same value). Null when the value is not a list.
 */
export function readLayout(value: unknown): Layout | null {
  if (!Array.isArray(value)) return null;
  const slots = new Set<Slot>();
  const seen = new Set<Token>();
  const lines: TextToken[][] = [];
  for (const line of value.slice(0, MAX_LINES)) {
    if (!Array.isArray(line)) continue;
    const out: TextToken[] = [];
    for (const token of line) {
      if (!isToken(token) || seen.has(token)) continue;
      seen.add(token);
      if (isSlot(token)) slots.add(token);
      else if (token !== "name" && out.length < MAX_TOKENS) out.push(token);
    }
    // A line that held only the name or slots still keeps line one's place (the name leads it).
    if (out.length > 0 || lines.length === 0) lines.push(out);
  }
  if (lines.length === 0) lines.push([]);
  return { slots, lines };
}

/** The value to store: the icon before the name, working and progress after line one's text. */
export function writeLayout(layout: Layout): Token[][] {
  const lines = layout.lines.filter((line, index) => index === 0 || line.length > 0).slice(0, MAX_LINES);
  return lines.map((line, index) => {
    if (index > 0) return [...line];
    const has = (slot: Slot) => layout.slots.has(slot);
    return [
      ...(has("icon") ? (["icon"] as Token[]) : []),
      "name",
      ...line,
      ...(has("working") ? (["working"] as Token[]) : []),
      ...(has("progress") ? (["progress"] as Token[]) : []),
    ];
  });
}

export function usedTokens(layout: Layout): Set<TextToken> {
  return new Set(layout.lines.flat());
}

/** The text tokens a line can still take, in menu order. */
export function addable(layout: Layout): TextToken[] {
  const used = usedTokens(layout);
  return TEXT_TOKENS.filter((token) => !used.has(token));
}

export function lineFull(layout: Layout, line: number): boolean {
  return (layout.lines[line]?.length ?? 0) >= MAX_TOKENS;
}

function withLines(layout: Layout, lines: TextToken[][]): Layout {
  // A line other than line one that an edit emptied is gone.
  return { slots: layout.slots, lines: lines.filter((line, index) => index === 0 || line.length > 0) };
}

/** `token` at the end of `line`; `line` one past the last starts a new line (up to MAX_LINES). */
export function addToken(layout: Layout, line: number, token: TextToken): Layout {
  if (usedTokens(layout).has(token)) return layout;
  if (line > layout.lines.length || line >= MAX_LINES || lineFull(layout, line)) return layout;
  const lines = layout.lines.map((items) => [...items]);
  if (line === lines.length) lines.push([]);
  lines[line]!.push(token);
  return withLines(layout, lines);
}

export function removeToken(layout: Layout, at: Place): Layout {
  const lines = layout.lines.map((items, index) =>
    index === at.line ? items.filter((_, i) => i !== at.index) : items,
  );
  return withLines(layout, lines);
}

/** Line `line` and its tokens removed; line one stays (it holds the name), so it only empties. */
export function removeLine(layout: Layout, line: number): Layout {
  if (line === 0) return { slots: layout.slots, lines: [[], ...layout.lines.slice(1)] };
  return withLines(
    layout,
    layout.lines.filter((_, index) => index !== line),
  );
}

/**
 * The chip at `from` moved to `to` (`to.index` counted among the target line's tokens without the
 * moved one; `to.line` one past the last makes a new line). A move into a full line, or past the
 * line limit, changes nothing.
 */
export function moveToken(layout: Layout, from: Place, to: Place): Layout {
  const token = layout.lines[from.line]?.[from.index];
  if (token === undefined) return layout;
  if (to.line > layout.lines.length || to.line >= MAX_LINES) return layout;
  if (to.line !== from.line && to.line < layout.lines.length && lineFull(layout, to.line)) return layout;
  const lines = layout.lines.map((items) => [...items]);
  lines[from.line]!.splice(from.index, 1);
  if (to.line === lines.length) lines.push([]);
  const target = lines[to.line]!;
  target.splice(Math.max(0, Math.min(to.index, target.length)), 0, token);
  // Emptying a line before the target shifts it up; withLines drops the empty line either way.
  return withLines(layout, lines);
}

/**
 * The place a keyboard move takes the chip at `from` to: left and right within its line, up and
 * down to the end of the line above or below (down from the last line starts a new one). Null
 * where it cannot go.
 */
export function stepPlace(layout: Layout, from: Place, direction: "left" | "right" | "up" | "down"): Place | null {
  const line = layout.lines[from.line];
  if (!line) return null;
  if (direction === "left") return from.index > 0 ? { line: from.line, index: from.index - 1 } : null;
  if (direction === "right") return from.index < line.length - 1 ? { line: from.line, index: from.index + 1 } : null;
  const next = from.line + (direction === "up" ? -1 : 1);
  if (next < 0) return null;
  // The last line's only chip has nowhere new to go: moving it down would leave its line empty.
  if (next === layout.lines.length && line.length === 1) return null;
  if (next > layout.lines.length || next >= MAX_LINES) return null;
  if (next < layout.lines.length && lineFull(layout, next)) return null;
  return { line: next, index: layout.lines[next]?.length ?? 0 };
}

export function toggleSlot(layout: Layout, slot: Slot): Layout {
  const slots = new Set(layout.slots);
  if (slots.has(slot)) slots.delete(slot);
  else slots.add(slot);
  return { slots, lines: layout.lines };
}

/** The name the preview row shows (a sample workspace). */
// l10n-allow: sample data (a workspace name), not words.
export const PREVIEW_NAME = "cmux";

/** What the preview row shows for each text item: sample data (a path, a branch, a port). */
export const PREVIEW_SAMPLE: Record<TextToken, string> = {
  // l10n-allow: sample row values, the same in every language.
  notification: "1",
  directory: "~/cmux",
  branch: "main",
  process: "zsh",
  agentStatus: "claude",
  tabCount: "3",
  ports: ":3000",
  lastActivity: "2m",
  pullRequest: "#128",
  log: "build ✓",
};

/** The element switch keys a layout replaces (`sidebar.workspaceRow.<token>`). */
export function switchKey(token: Token): string {
  return `sidebar.workspaceRow.${token}`;
}

/**
 * Where a person starts when they customize: the row as the element switches draw it today (the
 * switched-on slots, then the switched-on text items on line two in Second Line Order), so the
 * first edit changes only what it changes.
 */
export function layoutFromSwitches(value: (key: string) => unknown): Layout {
  const on = (token: Token) => value(switchKey(token)) === true;
  const slots = new Set(SLOTS.filter(on));
  const order = value("sidebar.workspaceRow.secondLineOrder");
  const ordered = (Array.isArray(order) ? order : []).filter((token): token is TextToken =>
    (TEXT_TOKENS as readonly string[]).includes(token as string),
  );
  const second = [...new Set([...ordered, ...TEXT_TOKENS])].filter(on).slice(0, MAX_TOKENS);
  return { slots, lines: second.length > 0 ? [[], second] : [[]] };
}

/** A by-kind or by-agent map as stored: its entries that are layouts, in stored order. */
export function readMap(value: unknown): Array<[string, Layout]> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return [];
  return Object.entries(value).flatMap(([key, entry]) => {
    const layout = readLayout(entry);
    return layout ? [[key, layout] as [string, Layout]] : [];
  });
}

/** The map with `id` set to `layout` (null removes it); written in the order the editor lists. */
export function writeMap(
  entries: Array<[string, Layout]>,
  id: string,
  layout: Layout | null,
): Record<string, Token[][]> {
  const out: Record<string, Token[][]> = {};
  let placed = false;
  for (const [key, entry] of entries) {
    if (key === id) {
      placed = true;
      if (layout) out[key] = writeLayout(layout);
    } else out[key] = writeLayout(entry);
  }
  if (!placed && layout) out[id] = writeLayout(layout);
  return out;
}

/** A trimmed agent id the map can take, or null. */
export function agentId(text: string): string | null {
  const id = text.trim().toLowerCase();
  return id.length > 0 && id.length <= MAX_AGENT_ID ? id : null;
}

/** One problem of a daemon refusal (`accepted.problems`): where, why, and the token when there is one. */
export type Problem = { at: string; why: string; token?: string };

/** A problem's place: its setting, the by-kind or by-agent entry, and the line and item indexes. */
export type ProblemPlace = { key: LayoutKey; entry: string | null; line: number | null; index: number | null };

const AT = /^(sidebar\.workspaceRow\.lines(?:ByKind|ByAgent)?)(?:\.(.+?))?((?:\[\d+\])*)$/;

/** `sidebar.workspaceRow.linesByKind.agent[1][0]` to its place; null for a path of another key. */
export function problemPlace(at: string): ProblemPlace | null {
  const match = AT.exec(at);
  if (!match || !isLayoutKey(match[1]!)) return null;
  const indexes = [...match[3]!.matchAll(/\[(\d+)\]/g)].map((part) => Number(part[1]));
  return { key: match[1], entry: match[2] ?? null, line: indexes[0] ?? null, index: indexes[1] ?? null };
}

/** The problems of a refused write (the daemon's `accepted.problems`, in the error's details). */
export function refusalProblems(details: unknown): Problem[] {
  const holder = details as { accepted?: { problems?: unknown }; problems?: unknown } | null | undefined;
  const list = holder?.accepted?.problems ?? holder?.problems;
  if (!Array.isArray(list)) return [];
  return list.flatMap((item): Problem[] => {
    const problem = item as { at?: unknown; why?: unknown; token?: unknown };
    if (typeof problem.at !== "string" || typeof problem.why !== "string") return [];
    return [
      { at: problem.at, why: problem.why, ...(typeof problem.token === "string" ? { token: problem.token } : {}) },
    ];
  });
}

/**
 * The token a problem names: its own `token`, else the one the refused value had at its place
 * (the item indexes count the written list, slots included).
 */
export function problemToken(problem: Problem, written: unknown): string | null {
  if (problem.token) return problem.token;
  const place = problemPlace(problem.at);
  if (!place || place.line === null || place.index === null) return null;
  const layout = place.entry === null ? written : (written as Record<string, unknown> | null)?.[place.entry];
  const token = (layout as unknown[][] | undefined)?.[place.line]?.[place.index];
  return typeof token === "string" ? token : null;
}
