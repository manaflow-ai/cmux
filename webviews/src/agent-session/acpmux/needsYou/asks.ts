// The permission requests acpmux holds open, in every chat this pane's connection watches: the
// Needs you list's asks (model.ts). The pane already watches every session (`_acpmux/watch`), and
// acpmux tells a watcher of each new request (`_acpmux/permission_pending`, `via: watch` for a
// chat the pane is not attached to) and of each change to a chat's count (`session_changed`, its
// `pendingPermissions`). What is open now is acpmux's own list, read with `_acpmux/info`
// (`pending`), as the Feed bridge and `acpmux pending` read it: a chat whose count changed in a way
// the page cannot account for is read again, so an ask answered anywhere (its card, the Feed, the
// CLI, another pane) leaves; a count of zero clears the chat at once.
import type { AcpmuxPermission } from "../model";
import type { WatchedAsk } from "./model";

/// A session as the watch reports it: its id, how many requests it holds open, when it last changed.
export type WatchedSession = { sessionId: string; pendingPermissions?: unknown; updatedAt?: unknown };

/// One pending entry of `_acpmux/info`: `{permissionId, request, turnId?, ...}`.
export type PendingEntry = { permissionId?: unknown; request?: unknown; turnId?: unknown; groupId?: unknown };

/// Reads a chat's pending requests (`_acpmux/info` `pending`); undefined when it cannot be read (a
/// chat on another computer, a closed connection): what the page holds then stays.
export type ReadPending = (sessionId: string) => Promise<readonly PendingEntry[] | undefined>;

/// Maps a `permission_pending` notification (or an info entry with its session) to the pane's
/// permission: direct.ts `permissionFromMessage`, the card's own mapping.
export type ParsePermission = (message: unknown, sessionId: string) => AcpmuxPermission | undefined;

const count = (value: unknown) => (typeof value === "number" && value > 0 ? Math.floor(value) : 0);

export class AskTracker {
  private readonly asks = new Map<string, WatchedAsk>();
  /// Each chat's newest read: an older read that lands after it is dropped.
  private readonly reads = new Map<string, number>();
  private readonly updatedAt = new Map<string, number>();
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
  pending(message: unknown): void {
    const sessionId = sessionOf(message);
    if (!sessionId) return;
    const permission = this.parse(message, sessionId);
    if (!permission || this.asks.has(permission.permissionId)) return;
    // A read already on its way may predate this ask, and would drop it: it no longer counts.
    this.reads.set(sessionId, (this.reads.get(sessionId) ?? 0) + 1);
    this.asks.set(permission.permissionId, { sessionId, permission, at: this.now() });
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
    if (typeof session.updatedAt === "number") this.updatedAt.set(session.sessionId, session.updatedAt);
    const reported = count(session.pendingPermissions);
    const held = this.heldFor(session.sessionId);
    if (reported === 0) {
      // Nothing open: no read needed, and a read still in flight is stale.
      this.reads.set(session.sessionId, (this.reads.get(session.sessionId) ?? 0) + 1);
      if (held > 0) this.forget(session.sessionId);
      return;
    }
    const answered = kind === "permission_decision" || kind === "permission_resolved";
    if (reported !== held || answered) void this.reread(session.sessionId);
  }

  /// A chat acpmux purged: its asks go.
  forget(sessionId: string): void {
    let removed = false;
    for (const [id, ask] of this.asks)
      if (ask.sessionId === sessionId) {
        this.asks.delete(id);
        removed = true;
      }
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
    let entries: readonly PendingEntry[] | undefined;
    try {
      entries = await this.read(sessionId);
    } catch {
      entries = undefined;
    }
    if (entries === undefined || this.reads.get(sessionId) !== generation) return;
    this.reconcile(sessionId, entries);
  }

  private reconcile(sessionId: string, entries: readonly PendingEntry[]): void {
    const open = new Set<string>();
    let moved = false;
    for (const entry of entries) {
      const permission = this.parse({ sessionId, permissionId: entry.permissionId, request: entry.request }, sessionId);
      if (!permission) continue;
      if (typeof entry.turnId === "string" && !permission.turnId) permission.turnId = entry.turnId;
      open.add(permission.permissionId);
      if (this.asks.has(permission.permissionId)) continue;
      // An ask found by a read was asked before the page saw it: the chat's last change dates it.
      const at = Math.min(this.now(), this.updatedAt.get(sessionId) ?? Number.POSITIVE_INFINITY);
      this.asks.set(permission.permissionId, { sessionId, permission, at });
      moved = true;
    }
    for (const [id, ask] of this.asks)
      if (ask.sessionId === sessionId && !open.has(id)) {
        this.asks.delete(id);
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
