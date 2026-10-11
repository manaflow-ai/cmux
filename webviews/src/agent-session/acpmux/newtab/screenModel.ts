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

export type ScreenAgent = { id: string; name: string };

/// A row under the field (cx-e2aa, Lawrence 2026-10-09): "autocomplete should only be for URLs /
/// other tabs and should only show up when it makes sense". A prompt has no row: Enter sends it
/// to the agent picked at the top of the page.
export type ScreenRow =
  /// Search the web for `text` (the browser's search engine).
  | { type: "search"; text: string }
  /// Load `url` (what `text` resolved to).
  | { type: "open"; url: string; text: string }
  | { type: "tab"; id: string; title: string; detail?: string; icon?: string }
  | { type: "history"; url: string; title?: string; icon?: string };

/// Open tabs and visited pages shown under the field.
export const MAX_MATCH_ROWS = 4;
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

/// The rows under the field. Empty text and `!`: none. An address: open it, then the open tabs
/// and visited pages that match it, then a web search (none for a local file). Other text: the
/// matching open tabs and visited pages with a web search after them, or nothing when none match
/// (the text is a prompt).
export function screenRows(text: string, context: { omnibar: OmnibarContext; home?: string }): ScreenRow[] {
  const intent = classifyNewTabInput(text, context.home ? { home: context.home } : {});
  if (intent.kind === "none" || intent.kind === "terminal") return [];
  const query = text.trim();
  const found = matches(query, context.omnibar);
  const search: ScreenRow = { type: "search", text: query };
  if (intent.kind === "url") {
    const open: ScreenRow = { type: "open", url: intent.url, text: query };
    return intent.url.startsWith("file:") ? [open, ...found] : [open, ...found, search];
  }
  return found.length ? [...found, search] : [];
}

/// The row Enter takes before Down or Ctrl-N: an address's open row; none for a prompt, whose
/// rows are only suggestions (Enter asks the agent).
export function initialSelection(text: string, home?: string): number {
  return classifyNewTabInput(text, home ? { home } : {}).kind === "url" ? 0 : -1;
}

/// The selection after Down/Ctrl-N (`step` 1) or Up/Ctrl-P (`step` -1), wrapping; from no
/// selection Down takes the first row and Up the last.
export function stepSelection(current: number, step: 1 | -1, count: number): number {
  if (count === 0) return -1;
  if (current < 0) return step === 1 ? 0 : count - 1;
  return (current + step + count) % count;
}

function matches(query: string, omnibar: OmnibarContext): ScreenRow[] {
  // Only tabs and pages compete for the rows (no workspace, chat, folder or command).
  const navigable: OmnibarContext = { ...EMPTY_OMNIBAR, tabs: omnibar.tabs, history: omnibar.history };
  return omnibarRows(query, "browser", navigable)
    .flatMap((row) => screenRow(row))
    .slice(0, MAX_MATCH_ROWS);
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
