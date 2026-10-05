// The new tab screen's pure state (variant B, plans/cmux-next/new-tab.md sections 3-4): the
// dropdown rows for the typed text, the Search | Ask mode, the `!` conversion and the chat
// cards. No React, no host: NewTabScreen renders what these return.
import type { AcpmuxSnapshot } from "../model";
import { ageLabel, recentSessions } from "../NewTabPage";
import { matchScore, type OmnibarContext } from "../omnibar";
import { sessionMark } from "../sessionList";
import { classifyNewTabInput, TERMINAL_PREFIX } from "../newTabIntent";

export type ScreenAgent = { id: string; name: string };

export type ScreenRow =
  /// Start an ACP chat with `harness`, `text` its first prompt.
  | { type: "agent"; harness: string; name: string; text: string }
  /// Search the web for `text` (the browser's search engine).
  | { type: "search"; text: string }
  /// Load `url` (what `text` resolved to).
  | { type: "open"; url: string; text: string }
  | { type: "tab"; id: string; title: string; detail?: string }
  | { type: "workspace"; id: string; title: string; detail?: string }
  | { type: "history"; url: string; title?: string }
  | { type: "action"; id: string; title: string; detail?: string };

/// Agents shown per query; more installed harnesses stay in the composer's picker.
export const MAX_AGENT_ROWS = 4;
/// Open tabs, workspaces and history matches shown under the typed rows.
export const MAX_MATCH_ROWS = 4;
/// Chat cards under the field.
export const CHAT_CARD_COUNT = 3;

/// The catalog's agents in its order, the remembered one first, capped.
export function orderedAgents(agents: readonly ScreenAgent[], lastAgent?: string): ScreenAgent[] {
  const remembered = agents.find((agent) => agent.id === lastAgent);
  const rest = agents.filter((agent) => agent !== remembered);
  return (remembered ? [remembered, ...rest] : rest).slice(0, MAX_AGENT_ROWS);
}

/// The rows under the field. Empty text: none (the cards show). `!`: none (the tab is already
/// becoming a terminal). An address: open it first. Plain text: the agents, then a web search
/// row (one input, no mode, R86). Matching open tabs, workspaces and history last.
export function screenRows(
  text: string,
  context: { agents: readonly ScreenAgent[]; omnibar: OmnibarContext; lastAgent?: string; home?: string },
): ScreenRow[] {
  const intent = classifyNewTabInput(text, context.home ? { home: context.home } : {});
  if (intent.kind === "none" || intent.kind === "terminal") return [];
  const query = text.trim();
  // Variants of one agent (`claude`, `claude-sr`) share a name; their id tells them apart.
  const names = new Map<string, number>();
  for (const agent of context.agents) names.set(agent.name, (names.get(agent.name) ?? 0) + 1);
  const agentRows: ScreenRow[] = orderedAgents(context.agents, context.lastAgent).map((agent) => ({
    type: "agent",
    harness: agent.id,
    name: (names.get(agent.name) ?? 0) > 1 ? `${agent.name} (${agent.id})` : agent.name,
    text: query,
  }));
  const search: ScreenRow = { type: "search", text: query };
  const typed: ScreenRow[] =
    intent.kind === "url"
      ? [{ type: "open", url: intent.url, text: query }, search, ...agentRows]
      : [...agentRows, search];
  return [...typed, ...matches(query, context.omnibar)];
}

function matches(query: string, omnibar: OmnibarContext): ScreenRow[] {
  const rows: { row: ScreenRow; score: number }[] = [
    ...omnibar.tabs.map((tab) => ({
      row: { type: "tab", id: tab.id, title: tab.title, ...(tab.detail ? { detail: tab.detail } : {}) } as ScreenRow,
      score: matchScore(query, tab.title, tab.detail) + 0.6,
    })),
    ...omnibar.workspaces.map((workspace) => ({
      row: {
        type: "workspace",
        id: workspace.id,
        title: workspace.name,
        ...(workspace.detail ? { detail: workspace.detail } : {}),
      } as ScreenRow,
      score: matchScore(query, workspace.name, workspace.detail) + 0.5,
    })),
    ...(omnibar.actions ?? []).map((action) => ({
      row: { type: "action", id: action.id, title: action.title, ...(action.detail ? { detail: action.detail } : {}) } as ScreenRow,
      score: matchScore(query, action.title, ...(action.keywords ?? [])) + 0.4,
    })),
    ...omnibar.history.map((entry) => ({
      row: { type: "history", url: entry.url, ...(entry.title ? { title: entry.title } : {}) } as ScreenRow,
      score: matchScore(query, entry.title, entry.url.replace(/^https?:\/\/(www\.)?/, "")) + 0.1,
    })),
  ];
  return rows
    .filter((entry) => entry.score >= 1)
    .sort((a, b) => b.score - a.score)
    .slice(0, MAX_MATCH_ROWS)
    .map((entry) => entry.row);
}

/// `!` typed into an empty field (or over a wholly selected one, a location the page put
/// there): the tab becomes a terminal now, with the rest of the edit as its first command.
/// Anything else stays as typed.
export function terminalConversion(
  previous: string,
  next: string,
  previousWasSelected: boolean,
): { command: string } | undefined {
  if (previous !== "" && !previousWasSelected) return undefined;
  if (!next.startsWith(TERMINAL_PREFIX)) return undefined;
  return { command: next.slice(TERMINAL_PREFIX.length).trim() };
}

export type ChatCard = {
  sessionId: string;
  title: string;
  harness?: string;
  age: string;
  message?: string;
  state: "idle" | "input" | "running" | "error" | "unread";
};

/// The newest chats, the ones waiting on the user first; a dropped chat is an error card.
export function recentChatCards(sessions: AcpmuxSnapshot["sessions"], now = Date.now()): ChatCard[] {
  return recentSessions(sessions, CHAT_CARD_COUNT).map((session) => ({
    sessionId: session.sessionId,
    title: session.displayTitle ?? session.sessionId,
    ...(session.harness ? { harness: session.harness } : {}),
    age: ageLabel(session.updatedAt, now),
    ...(session.preview ? { message: session.preview } : {}),
    state: sessionMark(session, false) ?? "idle",
  }));
}
