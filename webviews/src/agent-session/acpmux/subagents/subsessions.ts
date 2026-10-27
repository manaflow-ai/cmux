// The chats this chat's agent started with the cmux-subsessions `start_session` tool (acpmux
// `startedBy`, hub/subsessions.rs), as the pane follows them: each one's name among its parent's
// (`shortName`), its live state (working, waiting on the person, failed, done), whether it has news,
// how many messages wait behind its turn, what its turn does now, and while it waits on the
// person, what for (a question or a permission, which only the person answers). The summary card's Subagents
// section lists them under the chat's own subagents (summary/SubagentStatusList.tsx), and the
// transcript's sub-session cards (conversation/SubsessionCallCard.tsx) read one's state live from
// a small store fed from the session list, so a card never redraws its turn when a session changes.
import { createContext, useContext, useSyncExternalStore } from "react";
import type { StringKey, Translate } from "../i18n";
import type { RetryState } from "./retryState";
import { cloudHost, type AcpmuxSessionEntry, type SessionWaiting } from "../sessionList";

/// What a sub-session is doing: its turn runs, it waits on the person (a permission or a question),
/// its turn failed or its agent went away, or it is done until it is sent more.
export type SubsessionState = "working" | "input" | "failed" | "done";

export type SubsessionInfo = {
  sessionId: string;
  /// Its short name, else its title.
  name: string;
  state: SubsessionState;
  /// Its last turn ended and nobody has looked at it yet.
  unread?: true;
  /// Messages waiting behind its running turn.
  queued?: number;
  /// What its running turn does now, while it works.
  doing?: string;
  /// What it waits on the person for, while it does and acpmux says.
  waiting?: SessionWaiting;
  /// It waits for a run slot (its parent runs `maxRunning` already): it has not started.
  slot?: true;
  /// Its model, as acpmux names it.
  model?: string;
  /// acpmux's retry of its failed turn, while one waits (retryState.ts).
  retry?: RetryState;
  /// acpmux settles, starts or runs its failed turn's retry: no Retry meanwhile.
  retryDeciding?: true;
  /** Why its turn failed, while it is failed (acpmux's `lane.error`). */
  error?: string;
};

/// What a sub-session waiting on the person waits for, in one line: a question (and its first
/// prompt, which the line cuts when there is no room) or a tool's permission. Only the person
/// answers it, in its chat (person proof): its parent's agent cannot, so the line says where.
export function waitingLine(t: Translate, waiting: SessionWaiting): string {
  if (waiting.on === "permission") return t("subsession.waitingPermission");
  const line = t("subsession.waitingQuestion");
  return waiting.prompt ? `${line} · ${waiting.prompt}` : line;
}

/// Each state's word.
export const SUBSESSION_STATE_LABEL: Record<SubsessionState, StringKey> = {
  working: "subsession.state.working",
  input: "subsession.state.input",
  failed: "subagents.state.failed",
  done: "subagents.state.completed",
};

/// acpmux's lane (`lane.state`) when it gives one, else its status dot, else its status.
export function subsessionState(entry: AcpmuxSessionEntry): SubsessionState {
  switch (entry.lane ?? entry.indicator) {
    case "working":
      return "working";
    case "input":
      return "input";
    case "failed":
    case "lost":
      return "failed";
    case "idle":
    case "done":
      return "done";
  }
  if (entry.status === "running") return "working";
  if (entry.status === "waiting") return "input";
  return "done";
}

export function subsessionInfo(entry: AcpmuxSessionEntry): SubsessionInfo {
  const state = subsessionState(entry);
  return {
    sessionId: entry.sessionId,
    name: entry.shortName || entry.displayTitle || entry.title || entry.sessionId,
    state,
    ...(state === "done" && entry.unread ? { unread: true as const } : {}),
    ...(entry.queued ? { queued: entry.queued } : {}),
    ...(state === "working" && entry.doing ? { doing: entry.doing } : {}),
    ...(state === "input" && entry.waitingOn ? { waiting: entry.waitingOn } : {}),
    ...(entry.waitsForSlot ? { slot: true as const } : {}),
    ...(entry.model ? { model: entry.model } : {}),
    // Read through retryState.ts ``sessionRetry``, which ignores them on a row that isn't failed.
    ...(entry.retry ? { retry: entry.retry } : {}),
    ...(entry.retryDeciding ? { retryDeciding: true as const } : {}),
    ...(state === "failed" && !entry.retry && entry.laneError ? { error: entry.laneError } : {}),
  };
}

/// A sub-session's row in the summary card: `depth` 0 for one this chat started, 1 for one that
/// one started, and so on.
export type SubsessionRow = SubsessionInfo & { depth: number };

/// Each state's place on one level: what needs the person first, then what runs, then what ended.
const RANK: Record<SubsessionState, number> = { input: 0, working: 1, failed: 2, done: 2 };

/// The sub-sessions chat `chatId` started, each followed by its own, depth first; archived ones
/// left out. On each level, those waiting on the person first, then the working ones, then the
/// ended ones, each newest first.
export function subsessionRows(sessions: readonly AcpmuxSessionEntry[], chatId: string | undefined): SubsessionRow[] {
  if (!chatId) return [];
  const children = new Map<string, AcpmuxSessionEntry[]>();
  for (const entry of sessions) {
    if (!entry.startedBy || entry.archived) continue;
    const list = children.get(entry.startedBy);
    if (list) list.push(entry);
    else children.set(entry.startedBy, [entry]);
  }
  const out: SubsessionRow[] = [];
  // A session listed twice (a peer's copy) or a loop in the links draws once.
  const seen = new Set<string>([chatId]);
  const visit = (parent: string, depth: number) => {
    const level = (children.get(parent) ?? [])
      .filter((entry) => !seen.has(entry.sessionId))
      .map((entry) => ({ entry, info: subsessionInfo(entry) }))
      .sort((a, b) => RANK[a.info.state] - RANK[b.info.state] || (b.entry.createdAt ?? 0) - (a.entry.createdAt ?? 0));
    for (const { entry, info } of level) {
      if (seen.has(entry.sessionId)) continue;
      seen.add(entry.sessionId);
      out.push({ ...info, depth });
      visit(entry.sessionId, depth + 1);
    }
  };
  visit(chatId, 0);
  return out;
}

/// Every listed session's sub-session view by id, which cards read with ``useSubsessionInfo``.
export class SubsessionStore {
  private infos = new Map<string, SubsessionInfo>();
  private keys = new Map<string, string>();
  private readonly listeners = new Set<() => void>();

  private entries = new Map<string, AcpmuxSessionEntry>();
  /// Every listed chat's id by its names (its name, its short name; not its title, which can be
  /// "New chat"), and by id its harness and the other machine it runs on: another agent's message
  /// names its sender, which a card marks with its harness and opens, its tooltip naming that
  /// machine. Their readers have their own listeners, so a chat's name changing never tells a
  /// sub-session card.
  private named = new Map<string, string>();
  private harnesses = new Map<string, string>();
  private hosts = new Map<string, string>();
  /// Where each listed chat works, by id: its folder and the other machine it runs on, for the
  /// files its messages name (IncomingMessageCard.tsx), read with the same listeners.
  private places = new Map<string, SenderPlace>();
  private ids = new Set<string>();
  private namedKey = "";
  private readonly nameListeners = new Set<() => void>();

  /// Replaces the views with those of the sub-sessions among `sessions`; one whose content did not
  /// change keeps its object. The pane sends the list with every snapshot, reusing the entry of a
  /// session that did not change, so an entry seen last time is not read again.
  set(sessions: readonly AcpmuxSessionEntry[]): void {
    const infos = new Map<string, SubsessionInfo>();
    const keys = new Map<string, string>();
    const entries = new Map<string, AcpmuxSessionEntry>();
    let changed = false;
    const named = new Map<string, string>();
    const harnesses = new Map<string, string>();
    // A name a later chat shares never takes an earlier chat's place; a live chat's name comes
    // before an archived one's.
    const live = [...sessions].sort((a, b) => Number(Boolean(a.archived)) - Number(Boolean(b.archived)));
    for (const field of ["name", "shortName"] as const)
      for (const entry of live) {
        const name = entry[field]?.trim();
        if (name && !named.has(name)) named.set(name, entry.sessionId);
      }
    // A chat on another machine is listed as `<peer>/<name>` (acpmux hub/peers.rs); its message
    // signs with the bare name ("[chief-ui] ..."), which finds it after every chat's full name.
    for (const entry of live) {
      const name = entry.name?.trim();
      const bare = entry.peer && name?.startsWith(`${entry.peer}/`) ? name.slice(entry.peer.length + 1) : undefined;
      if (bare && !named.has(bare)) named.set(bare, entry.sessionId);
    }
    const hosts = new Map<string, string>();
    const places = new Map<string, SenderPlace>();
    for (const entry of sessions) {
      if (entry.harness) harnesses.set(entry.sessionId, entry.harness);
      const host = cloudHost(entry);
      if (host) hosts.set(entry.sessionId, host);
      const cwd = entry.cwd?.trim();
      if (cwd || host) places.set(entry.sessionId, { ...(cwd && { cwd }), ...(host && { host }) });
    }
    const namedKey = JSON.stringify([
      [...named],
      [...harnesses],
      [...places],
      sessions.map((entry) => entry.sessionId),
    ]);
    const renamed = namedKey !== this.namedKey;
    this.named = named;
    this.ids = new Set(sessions.map((entry) => entry.sessionId));
    this.harnesses = harnesses;
    this.hosts = hosts;
    if (renamed) this.places = places;
    this.namedKey = namedKey;
    if (renamed) for (const listener of this.nameListeners) listener();
    for (const entry of sessions) {
      if (!entry.startedBy) continue;
      const id = entry.sessionId;
      const before = this.infos.get(id);
      let info: SubsessionInfo;
      let key: string;
      if (before && this.entries.get(id) === entry) {
        info = before;
        key = this.keys.get(id)!;
      } else {
        const next = subsessionInfo(entry);
        key = JSON.stringify(next);
        info = before && this.keys.get(id) === key ? before : next;
        if (info !== before) changed = true;
      }
      infos.set(id, info);
      keys.set(id, key);
      entries.set(id, entry);
    }
    if (infos.size !== this.infos.size) changed = true;
    this.infos = infos;
    this.keys = keys;
    this.entries = entries;
    if (changed) for (const listener of this.listeners) listener();
  }

  get(sessionId: string): SubsessionInfo | undefined {
    return this.infos.get(sessionId);
  }

  /// The listed chat named `name`, if one is.
  find(name: string): string | undefined {
    return this.named.get(name.trim());
  }

  /// Whether the list has chat `sessionId` (any listed chat, not only a sub-session).
  has(sessionId: string): boolean {
    return this.ids.has(sessionId);
  }

  harness(sessionId: string): string | undefined {
    return this.harnesses.get(sessionId);
  }

  /// The other machine listed chat `sessionId` runs on; undefined for this Mac's.
  host(sessionId: string): string | undefined {
    return this.hosts.get(sessionId);
  }

  /// Where listed chat `sessionId` works: its folder, and the other machine it runs on.
  place(sessionId: string): SenderPlace | undefined {
    return this.places.get(sessionId);
  }

  subscribeNames = (listener: () => void): (() => void) => {
    this.nameListeners.add(listener);
    return () => this.nameListeners.delete(listener);
  };

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
}

/// Where the cards read sessions from, and how a click opens one beside this chat. Absent (a
/// gallery stage, a test), a card draws its name without its state and without a link.
export type Subsessions = {
  store: SubsessionStore;
  open(sessionId: string): void;
  /// Opens the chat that sent this one a message (its received line's chip): any listed chat, not
  /// only this chat's family; `open` when absent.
  openSender?(sessionId: string): void;
};
export const SubsessionContext = createContext<Subsessions | null>(null);

const EMPTY = new SubsessionStore();

/// Session `sessionId`'s view, live while the component shows; undefined while the list does not
/// have it.
export function useSubsessionInfo(sessionId: string | undefined): SubsessionInfo | undefined {
  const store = useContext(SubsessionContext)?.store ?? EMPTY;
  const read = () => (sessionId ? store.get(sessionId) : undefined);
  return useSyncExternalStore(store.subscribe, read, read);
}

/// Where a message's sender works: its folder (`cwd`), and the other machine it runs on (`host`,
/// undefined for this Mac's).
export type SenderPlace = { cwd?: string; host?: string };

/// Where the chat a message came from works, while the list has it (subsessions.ts `place`).
export function useSenderPlace(sessionId: string | undefined): SenderPlace | undefined {
  const store = useContext(SubsessionContext)?.store ?? EMPTY;
  const read = () => (sessionId ? store.place(sessionId) : undefined);
  return useSyncExternalStore(store.subscribeNames, read, read);
}

/// The chat a message's sender is: its own id when the message gives one, else the listed chat
/// with its name (a message `acpmux send` sent from a shell names its sender only, a chat on
/// another machine its bare name), that chat's harness and the other machine it runs on. Undefined
/// while the list has neither.
export function useSenderChat(
  name: string,
  sessionId: string | undefined,
): { sessionId?: string; harness?: string; host?: string } {
  const store = useContext(SubsessionContext)?.store ?? EMPTY;
  const readId = () => sessionId ?? store.find(name);
  const id = useSyncExternalStore(store.subscribeNames, readId, readId);
  const readHarness = () => (id ? store.harness(id) : undefined);
  const harness = useSyncExternalStore(store.subscribeNames, readHarness, readHarness);
  const readHost = () => (id ? store.host(id) : undefined);
  const host = useSyncExternalStore(store.subscribeNames, readHost, readHost);
  return { ...(id && { sessionId: id }), ...(harness && { harness }), ...(host && { host }) };
}
