// What a session reference's hover card says (SessionHoverCard.tsx), the way a row of Claude Code
// desktop's PR list does: the title, then the status line (the status, then `· repo #N`), then what
// it is doing now (its running turn's step, what it waits on you for, else its latest reply's line),
// then where it runs (its folder, then its cloud machine, worktree or branch) and when it last
// changed. Leo, 2026-11-05, on Claude desktop's card (a status pill, the project and "now"):
// "the metadata.... ehh..": the card says what is useful about the session, not only where it is.
// The pane keeps it in one small store fed from the session list, so a chip in a reply reads the
// session's current state when its card opens, and a reply never redraws because a session changed.
import { useSyncExternalStore } from "react";
import {
  type AcpmuxSessionEntry,
  type SessionWaiting,
  activityTime,
  listed,
  projectLabel,
  sessionPlace,
} from "../sessionList";
import {
  MIN_TITLE_MENTION,
  type SessionMention,
  type SessionStatus,
  type StartedPullRequests,
  sessionStatus,
  startedPullRequests,
  startedState,
} from "./startedSessions";

export type SessionHoverInfo = {
  sessionId: string;
  title: string;
  /// What its status line leads with, as on a started chat's row (``sessionStatus``).
  status: SessionStatus;
  /// Its pull requests, as its row names them (``startedPullRequests``).
  pullRequests?: StartedPullRequests;
  /// Where it runs, for the meta line: its folder, then its cloud machine, worktree or branch
  /// (``sessionPlace``). Absent without a folder.
  meta?: string[];
  /// What its running turn does now (acpmux `doing`), absent while it runs nothing.
  doing?: string;
  /// What it waits on the person for, while it does (acpmux `waitingOn`).
  waiting?: SessionWaiting;
  /// A line of its latest reply, for a chat that runs nothing and waits on nobody.
  preview?: string;
  /// When the person or its agent last did something in it (``activityTime``), epoch ms.
  changedAt?: number;
};

/// One line of `text`: its first non-empty line, trimmed; undefined when it has none.
const oneLine = (text: string | undefined) =>
  text
    ?.split("\n")
    .map((line) => line.trim())
    .find(Boolean);

export function hoverInfo(entry: AcpmuxSessionEntry): SessionHoverInfo {
  const pullRequests = startedPullRequests(entry);
  const place = sessionPlace(entry)?.label;
  const meta = entry.cwd ? [projectLabel(entry.cwd), ...(place ? [place] : [])] : undefined;
  const doing = oneLine(entry.doing);
  const waiting = doing ? undefined : entry.waitingOn;
  const preview = doing || waiting ? undefined : oneLine(entry.preview ?? entry.lastMessage);
  const changedAt = activityTime(entry);
  return {
    sessionId: entry.sessionId,
    title: entry.displayTitle || entry.title || entry.sessionId,
    status: sessionStatus(startedState(entry), entry.unread, pullRequests),
    ...(pullRequests ? { pullRequests } : {}),
    ...(meta ? { meta } : {}),
    ...(doing ? { doing } : {}),
    ...(waiting ? { waiting } : {}),
    ...(preview ? { preview } : {}),
    ...(changedAt ? { changedAt } : {}),
  };
}

/// The shortest session id of a chat this chat did not start that a reply's text links: a full
/// acpmux id (a UUID), never a word or a short name that happens to be one.
export const MIN_ID_MENTION = 16;

/// The mentions of every listed session but `chatId` by its full id, after `mentions` (the chats this
/// chat started, by title and id) and without repeating one of theirs. Longest first.
export function withSessionIds(
  mentions: readonly SessionMention[],
  sessions: readonly AcpmuxSessionEntry[],
  chatId: string | undefined,
): SessionMention[] {
  const named = new Set(mentions.map((mention) => mention.text));
  const out = [...mentions];
  for (const entry of sessions) {
    const id = entry.sessionId;
    if (id === chatId || id.length < Math.max(MIN_ID_MENTION, MIN_TITLE_MENTION) || named.has(id) || !listed(entry))
      continue;
    named.add(id);
    out.push({ text: id, sessionId: id, title: entry.displayTitle || entry.title || id, state: startedState(entry) });
  }
  return out.sort((a, b) => b.text.length - a.text.length);
}

/// The sessions' hover cards by id, which components read with ``useSessionHoverInfo``.
export class SessionHoverStore {
  private infos = new Map<string, SessionHoverInfo>();
  private keys = new Map<string, string>();
  private readonly listeners = new Set<() => void>();

  /// Replaces the cards with `sessions`'; a card whose content did not change keeps its object.
  set(sessions: readonly AcpmuxSessionEntry[]): void {
    const infos = new Map<string, SessionHoverInfo>();
    const keys = new Map<string, string>();
    let changed = sessions.length !== this.infos.size;
    for (const entry of sessions) {
      const info = hoverInfo(entry);
      const key = JSON.stringify(info);
      const kept = this.keys.get(entry.sessionId) === key ? this.infos.get(entry.sessionId) : undefined;
      if (!kept) changed = true;
      infos.set(entry.sessionId, kept ?? info);
      keys.set(entry.sessionId, key);
    }
    this.infos = infos;
    this.keys = keys;
    if (changed) for (const listener of this.listeners) listener();
  }

  get(sessionId: string): SessionHoverInfo | undefined {
    return this.infos.get(sessionId);
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
}

/// Session `sessionId`'s card from `store`, live while the component shows; undefined while the
/// store does not know it.
export function useSessionHoverInfo(store: SessionHoverStore, sessionId: string): SessionHoverInfo | undefined {
  return useSyncExternalStore(
    store.subscribe,
    () => store.get(sessionId),
    () => store.get(sessionId),
  );
}
