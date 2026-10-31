// The permission requests acpmux holds open, in every chat this pane's connection watches: the
// Needs you list's asks (model.ts). The pane already watches every session (`_acpmux/watch`), and
// acpmux tells a watcher of each new request (`_acpmux/permission_pending`, `via: watch` for a
// chat the pane is not attached to) and of each change to a chat's count (`session_changed`, its
// `pendingPermissions`). What is open now is acpmux's own list (`_acpmux/info` `pending`), which the
// pane's relay never sends: the host reads it on its own connection, as the approval banners do,
// and answers `chat.asks.pending` (CmuxNextAgentPane AgentPanePendingAsks). A chat whose count
// changed in a way the page cannot account for is read again, so an ask answered anywhere (its
// card, the Feed, the CLI, another pane) leaves; a count of zero clears the chat at once.
//
// A chat on another computer (an SSH or Cloud peer's) is in the watch too, with its `peer` (acpmux
// hub/peers.rs `remote_summary`) and its count, but its asks are that computer's: it is never read
// (acpmux forwards a read of a peer's chat to the peer daemon, server/peer_forward.rs) and no ask
// of it is held, so it stays one `input` item (model.ts).
import type { AcpmuxPermission } from "../model";
import type { WatchedAsk } from "./model";

/// A session as the watch reports it: its id, how many requests it holds open, when it last
/// changed, and the peer daemon it lives on when that is another computer.
export type WatchedSession = { sessionId: string; pendingPermissions?: unknown; updatedAt?: unknown; peer?: unknown };

/// The session lives on another computer: acpmux names its peer.
export const onPeer = (session: { peer?: unknown }) => typeof session.peer === "string" && session.peer.length > 0;

/// One pending entry of `_acpmux/info`: `{permissionId, request, turnId?, groupId?}` (the host
/// hands the page only these).
export type PendingEntry = { permissionId?: unknown; request?: unknown; turnId?: unknown; groupId?: unknown };

/// Reads a chat's pending requests (`_acpmux/info` `pending`); undefined when it cannot be read (a
/// chat on another computer, a closed connection): what the page holds then stays.
export type ReadPending = (sessionId: string) => Promise<readonly PendingEntry[] | undefined>;

/// The host op that reads a chat's open requests (`cmux.agent.chat.asks.pending {sessionId}`,
/// AgentPageOps): the pane's relay refuses `_acpmux/info` (AcpmuxPaneMethods.requests).
export const PENDING_ASKS_OP = "chat.asks.pending";

/// The relay method Ask about this sends (`_acpmux/btw {sessionId, question}`): a side session
/// about the asking chat. `_acpmux/ask` is not on the relay's list (#20826).
export const SIDE_SESSION_METHOD = "_acpmux/btw";

/// How a chat's open requests are read: in the app through the host (`PENDING_ASKS_OP`), never the
/// relay; in mock mode (`native()` false, an in-page daemon with no relay) from the daemon itself.
export function pendingReader(
  native: () => boolean,
  host: (op: string, params: Record<string, unknown>) => Promise<unknown>,
  daemon: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): ReadPending {
  return async (sessionId) => {
    const info = (
      native() ? await host(PENDING_ASKS_OP, { sessionId }) : await daemon("_acpmux/info", { sessionId })
    ) as { pending?: unknown } | null | undefined;
    const pending = info?.pending;
    return Array.isArray(pending) ? (pending as PendingEntry[]) : undefined;
  };
}

/// Maps a `permission_pending` notification (or an info entry with its session) to the pane's
/// permission: direct.ts `permissionFromMessage`, the card's own mapping.
export type ParsePermission = (message: unknown, sessionId: string) => AcpmuxPermission | undefined;

const count = (value: unknown) => (typeof value === "number" && value > 0 ? Math.floor(value) : 0);

/// A grouped request (`groupId`) is answered as a group on its own card, never one by one: the list
/// leaves it to the chat's waiting item (model.ts), which opens that card.
const grouped = (value: unknown) => typeof value === "string" && value.length > 0;

export class AskTracker {
  private readonly asks = new Map<string, WatchedAsk>();
  /// When each ask was first seen, in `tick`s: a read that started before it cannot drop it.
  private readonly seen = new Map<string, number>();
  private tick = 0;
  /// Each chat's newest read: an older read that lands after it is dropped.
  private readonly reads = new Map<string, number>();
  /// The pending count acpmux last reported for each chat: a chat is read again only when it
  /// changes (or on an answer), never on every summary change.
  private readonly reported = new Map<string, number>();
  private readonly updatedAt = new Map<string, number>();
  /// Chats the watch lists on another computer: never read, and no ask of theirs is held.
  private readonly remote = new Set<string>();
  private listed: WatchedAsk[] = [];
  private stale = false;

  constructor(
    private readonly read: ReadPending,
    private readonly parse: ParsePermission,
    private readonly changed: () => void,
    private readonly now: () => number = Date.now,
  ) {}

  /// The open asks, oldest seen first; the same array until one comes or goes.
  list(): WatchedAsk[] {
    if (this.stale) {
      this.listed = [...this.asks.values()];
      this.stale = false;
    }
    return this.listed;
  }

  /// A `_acpmux/permission_pending` notification, on an attached chat or a watched one.
  /// A peer's request names its peer (`peer`, `via: "peer"`: acpmux server/pending.rs
  /// `peer_permission_pending`) and is never held, even when it beats its chat's summary.
  pending(message: unknown): void {
    const sessionId = sessionOf(message);
    const fields = message as { groupId?: unknown; peer?: unknown };
    if (!sessionId || this.remote.has(sessionId) || onPeer(fields) || grouped(fields.groupId)) return;
    const permission = this.parse(message, sessionId);
    if (!permission || this.asks.has(permission.permissionId)) return;
    // A read already on its way keeps counting: it may hold another chat's answer. It cannot drop
    // this ask, which it never saw (`reconcile` keeps asks seen after the read started).
    this.asks.set(permission.permissionId, { sessionId, permission, at: this.now() });
    this.seen.set(permission.permissionId, ++this.tick);
    this.touch();
  }

  /// The session list (the watch's first page, a reread after a lag): reads every chat whose
  /// count differs from the asks held for it.
  sessions(sessions: readonly WatchedSession[]): void {
    for (const session of sessions) this.session(session);
  }

  /// One chat's summary changed (`session_changed`). `kind` is the change's kind: an answer
  /// (`permission_decision`, `permission_resolved`) rereads the chat even when its count looks
  /// right, since another request may have taken the answered one's place.
  session(session: WatchedSession, kind?: string): void {
    if (onPeer(session)) {
      // Another computer's chat: whatever it holds stays there; a read still out for it is stale.
      this.forget(session.sessionId);
      this.remote.add(session.sessionId);
      return;
    }
    this.remote.delete(session.sessionId);
    if (typeof session.updatedAt === "number") this.updatedAt.set(session.sessionId, session.updatedAt);
    const reported = count(session.pendingPermissions);
    const before = this.reported.get(session.sessionId);
    this.reported.set(session.sessionId, reported);
    if (reported === 0) {
      // Nothing open: no read needed, and a read still in flight is stale.
      this.reads.set(session.sessionId, (this.reads.get(session.sessionId) ?? 0) + 1);
      if (this.heldFor(session.sessionId) > 0) this.forget(session.sessionId);
      return;
    }
    const changed = kind === "permission_request" || kind === "permission_decision" || kind === "permission_resolved";
    if (reported !== before || changed) void this.reread(session.sessionId);
  }

  /// After a lag (`_acpmux/lagged`), notices may be missing: every listed chat acpmux reports
  /// requests in is read again whatever its count was, and a chat no longer listed is dropped.
  /// `only`: the lag named these chats alone (an attach's lag); the others keep what they hold.
  resync(sessions: readonly WatchedSession[], only?: ReadonlySet<string>): void {
    const listed = new Set(sessions.map((session) => session.sessionId));
    if (!only)
      for (const sessionId of new Set([
        ...this.reported.keys(),
        ...[...this.asks.values()].map((ask) => ask.sessionId),
      ]))
        if (!listed.has(sessionId)) this.forget(sessionId);
    for (const session of sessions) {
      if (only && !only.has(session.sessionId)) continue;
      // Forgets the count, so the summary reads as changed: a nonzero count is read again, a zero clears.
      this.reported.delete(session.sessionId);
      this.session(session);
    }
  }

  /// A chat acpmux purged (or no longer listed): its asks go, and a read still out for it is stale.
  forget(sessionId: string): void {
    this.remote.delete(sessionId);
    this.reads.set(sessionId, (this.reads.get(sessionId) ?? 0) + 1);
    this.updatedAt.delete(sessionId);
    let removed = false;
    for (const [id, ask] of this.asks)
      if (ask.sessionId === sessionId) {
        this.asks.delete(id);
        this.seen.delete(id);
        removed = true;
      }
    this.reported.delete(sessionId);
    if (removed) this.touch();
  }

  private heldFor(sessionId: string): number {
    let held = 0;
    for (const ask of this.asks.values()) if (ask.sessionId === sessionId) held++;
    return held;
  }

  private async reread(sessionId: string): Promise<void> {
    const generation = (this.reads.get(sessionId) ?? 0) + 1;
    this.reads.set(sessionId, generation);
    const started = this.tick;
    let entries: readonly PendingEntry[] | undefined;
    try {
      entries = await this.read(sessionId);
    } catch {
      entries = undefined;
    }
    if (entries === undefined || this.reads.get(sessionId) !== generation) return;
    this.reconcile(sessionId, entries, started);
  }

  private reconcile(sessionId: string, entries: readonly PendingEntry[], started: number): void {
    const open = new Set<string>();
    let moved = false;
    for (const entry of entries) {
      if (grouped(entry.groupId)) continue;
      const permission = this.parse({ sessionId, permissionId: entry.permissionId, request: entry.request }, sessionId);
      if (!permission) continue;
      if (typeof entry.turnId === "string" && !permission.turnId) permission.turnId = entry.turnId;
      open.add(permission.permissionId);
      if (this.asks.has(permission.permissionId)) continue;
      // An ask found by a read was asked before the page saw it: the chat's last change dates it.
      const at = Math.min(this.now(), this.updatedAt.get(sessionId) ?? Number.POSITIVE_INFINITY);
      this.asks.set(permission.permissionId, { sessionId, permission, at });
      this.seen.set(permission.permissionId, ++this.tick);
      moved = true;
    }
    // An ask the read does not list was answered, unless it arrived after the read started.
    for (const [id, ask] of this.asks)
      if (ask.sessionId === sessionId && !open.has(id) && (this.seen.get(id) ?? 0) <= started) {
        this.asks.delete(id);
        this.seen.delete(id);
        moved = true;
      }
    if (moved) this.touch();
  }

  private touch(): void {
    this.stale = true;
    this.changed();
  }
}

function sessionOf(message: unknown): string | undefined {
  if (!message || typeof message !== "object") return undefined;
  const envelope = message as { sessionId?: unknown; request?: { sessionId?: unknown } };
  const id = envelope.sessionId ?? envelope.request?.sessionId;
  return typeof id === "string" && id ? id : undefined;
}
