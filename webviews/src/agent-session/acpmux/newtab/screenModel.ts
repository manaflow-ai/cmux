// The new tab screen's pure state (variant B, plans/cmux-next/new-tab.md sections 3-4): the
// rows under the field for the typed text, the `!` conversion and the chat cards. No React, no
// host: NewTabScreen renders what these return.
import type { AcpmuxSnapshot } from "../model";
import { ageLabel, recentSessions } from "../NewTabPage";
import { EMPTY_OMNIBAR, omnibarRows, type OmnibarContext, type OmnibarRow } from "../omnibar";
import { sessionMark } from "../sessionList";
import { classifyNewTabInput, TERMINAL_PREFIX } from "../newTabIntent";
import { type Translate, translate } from "../i18n";
import type { DeviceChat } from "./deviceChats";
import { TOP_SITES } from "./topSites";

export type ScreenAgent = { id: string; name: string };

/// A row in the field's popover. The omnibar (Leo 2026-10-12, over cx-e2aa's addresses-only rows):
/// URL completions from visited pages and top sites, the open tabs and workspaces that match,
/// "Search the web for …" and "Ask <agent>". The top row is Return's.
export type ScreenRow =
  /// Search the web for `text` (the browser's search engine).
  | { type: "search"; text: string }
  /// Load `url` (what `text` resolved to, or a top site that completes it).
  | { type: "open"; url: string; text: string }
  | { type: "tab"; id: string; title: string; detail?: string; icon?: string }
  | { type: "workspace"; id: string; title: string; detail?: string }
  | { type: "history"; url: string; title?: string; icon?: string }
  /// The text as a prompt to `harness`, named `agent` (its `model` when known).
  | { type: "ask"; text: string; harness: string; agent: string; model?: string };

/// The agent the Ask row names.
export type ScreenAsk = { harness: string; agent: string; model?: string };

/// Open tabs, workspaces and visited pages shown under the completions.
export const MAX_MATCH_ROWS = 4;
/// Addresses that complete the typed word ("reddit" to reddit.com).
export const MAX_COMPLETIONS = 3;
/// The shortest word an address completes: "go" or "no" stays a prompt, not google.com or notion.so.
const MIN_COMPLETION_LENGTH = 3;
/// Chat cards under the field.
export const CHAT_CARD_COUNT = 3;

/// The catalog's agents in its order, the remembered one first.
export function orderedAgents(agents: readonly ScreenAgent[], lastAgent?: string): ScreenAgent[] {
  const remembered = agents.find((agent) => agent.id === lastAgent);
  const rest = agents.filter((agent) => agent !== remembered);
  return remembered ? [remembered, ...rest] : rest;
}

/// The agent a prompt goes to before the user picks one: the remembered one, else the first
/// installed.
export function defaultHarness(agents: readonly ScreenAgent[], lastAgent?: string): string | undefined {
  return orderedAgents(agents, lastAgent)[0]?.id;
}

/// The popover's rows. Empty text and `!`: none. An address: open it, the pages and matches after
/// it, a web search (none for a local file) and Ask. A word that completes an address: the
/// completions first, then the matches, a web search and Ask. Other text: Ask first, a web search,
/// then the matching tabs, workspaces and pages.
export function screenRows(
  text: string,
  context: { omnibar: OmnibarContext; home?: string; ask?: ScreenAsk },
): ScreenRow[] {
  const intent = classifyNewTabInput(text, context.home ? { home: context.home } : {});
  if (intent.kind === "none" || intent.kind === "terminal") return [];
  const query = text.trim();
  const search: ScreenRow = { type: "search", text: query };
  const ask: ScreenRow[] = context.ask ? [{ type: "ask", text: query, ...context.ask }] : [];
  if (intent.kind === "url") {
    const open: ScreenRow = { type: "open", url: intent.url, text: query };
    const rest = distinct([open, ...completions(query, context.omnibar), ...matches(query, context.omnibar)]);
    return intent.url.startsWith("file:") ? rest : [...rest, search, ...ask];
  }
  const completed = completions(query, context.omnibar);
  const found = distinct([...completed, ...matches(query, context.omnibar)]).slice(completed.length);
  return completed.length ? [...completed, ...found, search, ...ask] : [...ask, search, ...found];
}

/// The row Return takes before Down or Ctrl-N: the top one, unless it is only a web search for a
/// prompt (no agent to ask: Return says so instead of searching).
export function defaultSelection(rows: readonly ScreenRow[]): number {
  return rows[0] && rows[0].type !== "search" ? 0 : -1;
}

/// Whether Return on `text` with no row is an address (it never becomes a prompt).
export function isAddress(text: string, home?: string): boolean {
  return classifyNewTabInput(text, home ? { home } : {}).kind === "url";
}

/// The selection after Down/Ctrl-N (`step` 1) or Up/Ctrl-P (`step` -1), wrapping; from no
/// selection Down takes the first row and Up the last.
export function stepSelection(current: number, step: 1 | -1, count: number): number {
  if (count === 0) return -1;
  if (current < 0) return step === 1 ? 0 : count - 1;
  return (current + step + count) % count;
}

function matches(query: string, omnibar: OmnibarContext): ScreenRow[] {
  // Tabs, workspaces and pages compete for the rows (no chat, folder or command). A tab or visit
  // still on a blank page is nowhere to go: it showed as "about:blank workspace-N".
  const navigable: OmnibarContext = {
    ...EMPTY_OMNIBAR,
    tabs: omnibar.tabs.filter((tab) => !blankPage(tab.title) && !blankPage(tab.detail)),
    workspaces: omnibar.workspaces,
    history: omnibar.history.filter((entry) => !blankPage(entry.url)),
  };
  return omnibarRows(query, "browser", navigable)
    .flatMap((row) => screenRow(row))
    .slice(0, MAX_MATCH_ROWS);
}

/// Visited pages, then top sites, whose address starts with the typed word.
function completions(query: string, omnibar: OmnibarContext): ScreenRow[] {
  if (query.length < MIN_COMPLETION_LENGTH || /\s/.test(query)) return [];
  const needle = bareAddress(query.toLowerCase());
  const visited = omnibar.history
    .filter((entry) => /^https?:/i.test(entry.url) && bareAddress(entry.url.toLowerCase()).startsWith(needle))
    .map((entry): ScreenRow => ({
      type: "history",
      url: entry.url,
      ...(entry.title ? { title: entry.title } : {}),
      ...(entry.icon ? { icon: entry.icon } : {}),
    }));
  const sites = TOP_SITES.filter((site) => site.startsWith(needle)).map((site): ScreenRow => ({
    type: "open",
    url: `https://${site}`,
    text: site,
  }));
  return distinct([...visited, ...sites]).slice(0, MAX_COMPLETIONS);
}

/// `about:blank` and the other internal pages.
function blankPage(text: string | undefined): boolean {
  return !!text && /^about:/i.test(text.trim());
}

/// `reddit.com/r/x` for `https://www.reddit.com/r/x/`: what two addresses compare by.
function bareAddress(url: string): string {
  return url
    .replace(/^https?:\/\//i, "")
    .replace(/^www\./i, "")
    .replace(/\/$/, "");
}

/// The rows without a second row for the same address, tab or workspace; the first one stays.
function distinct(rows: ScreenRow[]): ScreenRow[] {
  const seen = new Set<string>();
  return rows.filter((row) => {
    const key =
      row.type === "open" || row.type === "history"
        ? `url:${bareAddress(row.url.toLowerCase())}`
        : row.type === "tab" || row.type === "workspace"
          ? `${row.type}:${row.id}`
          : row.type;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function screenRow(row: OmnibarRow): ScreenRow[] {
  switch (row.type) {
    case "tab":
      return [
        {
          type: "tab",
          id: row.id,
          title: row.title,
          ...(row.detail ? { detail: row.detail } : {}),
          ...(row.icon ? { icon: row.icon } : {}),
        },
      ];
    case "workspace":
      return [{ type: "workspace", id: row.id, title: row.title, ...(row.detail ? { detail: row.detail } : {}) }];
    case "history":
      return [
        {
          type: "history",
          url: row.url,
          ...(row.title ? { title: row.title } : {}),
          ...(row.icon ? { icon: row.icon } : {}),
        },
      ];
    default:
      return [];
  }
}

/// `!` typed into an empty field (or over a wholly selected one, a location the page put
/// there): shell mode, with the rest of the edit as the command typed so far. Anything else
/// stays as typed.
export function shellEntry(
  previous: string,
  next: string,
  previousWasSelected: boolean,
): { command: string } | undefined {
  if (previous !== "" && !previousWasSelected) return undefined;
  if (!next.startsWith(TERMINAL_PREFIX)) return undefined;
  return { command: next.slice(TERMINAL_PREFIX.length).replace(/^\s+/, "") };
}

export type ChatCard = {
  sessionId: string;
  /// A device chat from the acpmux chat index (`harness:sessionId`): opens through the host's
  /// shared Open Chat path (`chats.open`), not as an acpmux session.
  chatKey?: string;
  title: string;
  harness?: string;
  age: string;
  message?: string;
  state: "idle" | "input" | "running" | "error" | "unread";
};

/// The newest chats, the ones waiting on the user first; a dropped chat is an error card. acpmux's
/// own sessions come first (they carry live state); the device chat index (the sidebar's All
/// chats source) fills the rest, newest first, without a chat whose title a session card shows.
export function recentChatCards(
  sessions: AcpmuxSnapshot["sessions"],
  now = Date.now(),
  t: Translate = translate,
  device: DeviceChat[] = [],
): ChatCard[] {
  const live = liveChatCards(sessions, now, t);
  const shown = new Set(live.map((card) => card.title.trim().toLowerCase()));
  const fill = [...device]
    .sort((a, b) => b.updatedAt - a.updatedAt)
    .filter((chat) => !shown.has((chat.title ?? "").trim().toLowerCase()))
    .slice(0, Math.max(0, CHAT_CARD_COUNT - live.length))
    .map((chat): ChatCard => ({
      sessionId: chat.key,
      chatKey: chat.key,
      title: chat.title ?? t("sidebar.newChat"),
      harness: chat.harness,
      age: ageLabel(chat.updatedAt, now, t),
      state: "idle",
    }));
  return [...live, ...fill];
}

function liveChatCards(sessions: AcpmuxSnapshot["sessions"], now: number, t: Translate): ChatCard[] {
  return recentSessions(sessions, CHAT_CARD_COUNT).map((session) => ({
    sessionId: session.sessionId,
    title: session.displayTitle ?? session.sessionId,
    ...(session.harness ? { harness: session.harness } : {}),
    age: ageLabel(session.updatedAt, now, t),
    ...(session.preview ? { message: session.preview } : {}),
    state: sessionMark(session, false) ?? "idle",
  }));
}
