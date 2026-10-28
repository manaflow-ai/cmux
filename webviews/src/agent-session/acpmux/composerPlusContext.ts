import type { AcpmuxSessionEntry } from "./sessionList";
import { listed, sessionTitle } from "./sessionList";
import type { ComposerPlusExtension } from "./composerPlusRegistry";

/** A stable source chosen from the + menu. Native tab ids are opaque and are never inferred from focus. */
export type ComposerPlusContextSelection =
  | { kind: "session"; sessionId: string }
  | { kind: "tab"; tabId: string; source: "browser" | "terminal" | "pane" };

/** A live row supplied by the native catalog or by the session snapshot. */
export type ComposerPlusContextItem = {
  id: string;
  section: "sessions" | "tabs";
  name: string;
  description: string;
  icon: string;
  keywords?: readonly string[];
  selection: ComposerPlusContextSelection;
};

/** Convert live context rows to the shared + registry without inventing a command id. */
export function composerPlusContextEntries(items: readonly ComposerPlusContextItem[]): ComposerPlusExtension[] {
  const seen = new Set<string>();
  return items.flatMap((item): ComposerPlusExtension[] => {
    if (
      !item.id ||
      seen.has(item.id) ||
      (item.section !== "sessions" && item.section !== "tabs") ||
      !item.name.trim() ||
      !item.description.trim() ||
      !item.selection
    )
      return [];
    if (
      (item.selection.kind === "session" && (!item.selection.sessionId || item.section !== "sessions")) ||
      (item.selection.kind === "tab" && (!item.selection.tabId || item.section !== "tabs"))
    )
      return [];
    seen.add(item.id);
    return [
      {
        id: `context:${item.id}`,
        section: item.section,
        name: item.name,
        description: item.description,
        icon: item.icon,
        keywords: [...(item.keywords ?? []), item.name, item.description],
        action: { kind: "context", itemId: item.id },
      },
    ];
  });
}

/**
 * Recent chats and lanes are local, already validated session summaries. A row carries only the
 * daemon's session id; the native provider remains responsible for validating chosen tabs.
 */
export function recentComposerSessions(
  sessions: readonly AcpmuxSessionEntry[],
  currentSessionId?: string,
  limit = 12,
): ComposerPlusContextItem[] {
  return sessions
    .filter((session) => session.sessionId !== currentSessionId && listed(session))
    .sort((a, b) => (b.activityAt ?? b.updatedAt ?? 0) - (a.activityAt ?? a.updatedAt ?? 0))
    .slice(0, limit)
    .map((session) => {
      const title = (session.displayTitle?.trim() || sessionTitle(session)).replace(/\s+/g, " ").trim();
      const location = session.host ?? session.peer ?? session.cwd;
      return {
        id: `session:${session.sessionId}`,
        section: "sessions" as const,
        name: title || session.sessionId,
        description: location ? `Insert from ${location}` : "Insert this chat as context",
        icon: "agent.chat",
        keywords: ["chat", "session", session.harness ?? "", session.branch ?? ""],
        selection: { kind: "session" as const, sessionId: session.sessionId },
      };
    });
}

/** The insertion format is the same session reference already used by the @ picker. */
export function contextSessionMention(title: string, sessionId: string): { markdown: string; shown: string } {
  const shown = `cmux session ${JSON.stringify(title)} (${sessionId}) `;
  return { markdown: shown.replace(/[\\`*_[\]~<&]/g, "\\$&"), shown };
}

/** Insert a chosen session at the field caret while preserving both draft sides. */
export function insertContextSession(
  text: string,
  caret: number,
  title: string,
  sessionId: string,
): { text: string; caret: number } {
  const { markdown, shown } = contextSessionMention(title, sessionId);
  return { text: text.slice(0, caret) + markdown + text.slice(caret), caret: caret + shown.length };
}
