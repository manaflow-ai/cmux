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
  cloudHost,
  listed,
  projectLabel,
  sessionPlace,
} from "../sessionList";
import { replacedSince } from "../sessionIndex";
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
/// The key an outside agent's link finds its chat by (`cmux://agent/<harness>/<session>`): the
/// harness and the harness's own session id.
export const agentLinkKey = (harness: string, agentSessionId: string) => `${harness}/${agentSessionId}`;

/// Whether two id maps say the same thing.
const sameEntries = (a: ReadonlyMap<string, string>, b: ReadonlyMap<string, string>) =>
  a.size === b.size && [...a].every(([key, value]) => b.get(key) === value);

export class SessionHoverStore {
  private infos = new Map<string, SessionHoverInfo>();
  private keys = new Map<string, string>();
  /// Each listed chat by its agent link key (``agentLinkKey``), built with the cards: a pasted
  /// agent link finds its chat in one lookup however many chats are listed.
  private agents = new Map<string, string>();
  /// Each listed chat by its harness's own session id alone: a cmux.com agent link may name the
  /// session with no harness (`?session=`), which is that id, never an acpmux one.
  private agentSessions = new Map<string, string>();
  /// The machine each chat on another machine runs on, as the session list names it.
  private hosts = new Map<string, string>();
  /// The entry each card was made from: the pane keeps an unchanged session's entry object
  /// (direct.ts `sessionEntryList`), so an entry seen last time keeps its card and key unread, and
  /// one session's change costs one card, not one per listed chat.
  private from = new Map<string, AcpmuxSessionEntry>();
  /// The list the last `set` was given: a list made from it in place (sessionIndex.ts `noteReplaced`)
  /// is patched at the replaced entries only, with no lookup per listed chat.
  private last: readonly AcpmuxSessionEntry[] | undefined;
  /// The entries in the last list, a session listed twice counted twice: with ``from``'s size it
  /// shows a list that held a duplicate, which the patch path cannot read.
  private count = -1;
  /// The last list's ids in order: the agent-link indexes take the first chat that matches, so a
  /// reordered list rebuilds them.
  private order: string[] = [];
  private readonly listeners = new Set<() => void>();

  /// Replaces the cards with `sessions`'; a card whose content did not change keeps its object.
  set(sessions: readonly AcpmuxSessionEntry[]): void {
    const last = this.last;
    this.last = sessions;
    if (this.patch(sessions, replacedSince(last, sessions))) return;
    const infos = new Map<string, SessionHoverInfo>();
    const keys = new Map<string, string>();
    const agents = new Map<string, string>();
    const agentSessions = new Map<string, string>();
    const hosts = new Map<string, string>();
    const from = new Map<string, AcpmuxSessionEntry>();
    let changed = false;
    for (const entry of sessions) {
      const agent = entry.harness && entry.agentSessionId ? agentLinkKey(entry.harness, entry.agentSessionId) : "";
      if (agent && !agents.has(agent)) agents.set(agent, entry.sessionId);
      if (entry.agentSessionId && !agentSessions.has(entry.agentSessionId))
        agentSessions.set(entry.agentSessionId, entry.sessionId);
      // This Mac's chats name no machine: only another machine's chat says where it runs.
      const host = cloudHost(entry);
      if (host) hosts.set(entry.sessionId, host);
      from.set(entry.sessionId, entry);
      const same = this.from.get(entry.sessionId) === entry && this.infos.has(entry.sessionId);
      if (same) {
        infos.set(entry.sessionId, this.infos.get(entry.sessionId)!);
        keys.set(entry.sessionId, this.keys.get(entry.sessionId)!);
        continue;
      }
      const info = hoverInfo(entry);
      const key = `${JSON.stringify(info)}\u0000${agent}\u0000${host ?? ""}`;
      const kept = this.keys.get(entry.sessionId) === key ? this.infos.get(entry.sessionId) : undefined;
      if (!kept) changed = true;
      infos.set(entry.sessionId, kept ?? info);
      keys.set(entry.sessionId, key);
    }
    // A page can list a session twice: the count that matters is of ids, not of entries.
    if (infos.size !== this.infos.size) changed = true;
    // A reorder can move which chat an agent link opens with no card changing: a link reads these.
    if (!changed && (!sameEntries(agents, this.agents) || !sameEntries(agentSessions, this.agentSessions)))
      changed = true;
    this.infos = infos;
    this.keys = keys;
    this.agents = agents;
    this.agentSessions = agentSessions;
    this.hosts = hosts;
    this.from = from;
    this.count = sessions.length;
    this.order = sessions.map((entry) => entry.sessionId);
    if (changed) for (const listener of this.listeners) listener();
  }

  /// The same sessions as last time, some of them changed: only the changed ones' cards are made
  /// again, in place. False (nothing done) when a session came or went, a page lists one twice, or a
  /// change moved what the link indexes read (its agent link, its machine): `set` rebuilds them.
  private patch(sessions: readonly AcpmuxSessionEntry[], replaced?: readonly number[]): boolean {
    if (sessions.length !== this.from.size || sessions.length !== this.count) return false;
    const changed: AcpmuxSessionEntry[] = [];
    // A recorded in-place change keeps every id where it was, so only the replaced entries are read.
    const seen = new Set<string>();
    for (const at of replaced ?? sessions.keys()) {
      const entry = sessions[at]!;
      if (!replaced && entry.sessionId !== this.order[at]) return false;
      const before = this.from.get(entry.sessionId);
      // Equal length with every id known can still hide one listed twice in place of another.
      if (!before || seen.has(entry.sessionId)) return false;
      seen.add(entry.sessionId);
      if (before === entry) continue;
      if (
        before.harness !== entry.harness ||
        before.agentSessionId !== entry.agentSessionId ||
        cloudHost(before) !== cloudHost(entry)
      )
        return false;
      changed.push(entry);
    }
    let notify = false;
    for (const entry of changed) {
      const id = entry.sessionId;
      this.from.set(id, entry);
      const info = hoverInfo(entry);
      const agent = entry.harness && entry.agentSessionId ? agentLinkKey(entry.harness, entry.agentSessionId) : "";
      const key = `${JSON.stringify(info)}\u0000${agent}\u0000${cloudHost(entry) ?? ""}`;
      if (this.keys.get(id) === key) continue;
      this.infos.set(id, info);
      this.keys.set(id, key);
      notify = true;
    }
    if (notify) for (const listener of this.listeners) listener();
    return true;
  }

  get(sessionId: string): SessionHoverInfo | undefined {
    return this.infos.get(sessionId);
  }

  /// The listed chat an agent link names (``agentLinkKey``), or undefined.
  byAgent(harness: string, agentSessionId: string): string | undefined {
    return this.agents.get(agentLinkKey(harness, agentSessionId));
  }

  /// The listed chat whose harness's own session id is `agentSessionId`, whatever its harness.
  byAgentSession(agentSessionId: string): string | undefined {
    return this.agentSessions.get(agentSessionId);
  }

  /// The machine chat `sessionId` runs on, as the session list names it.
  host(sessionId: string): string | undefined {
    return this.hosts.get(sessionId);
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
