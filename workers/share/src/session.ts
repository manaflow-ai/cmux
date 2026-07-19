// Pure session core for the share Durable Object.
//
// All protocol decisions live here, decoupled from Cloudflare APIs so the
// whole state machine unit-tests under `bun test` (same architecture as
// workers/presence: pure core + thin DO wiring). The DO owns sockets and
// storage; this core owns membership, roles, chat, cursors, subscriptions,
// and the session lifecycle, and communicates outward via effects.

import type {
  ChatMessage,
  CursorPos,
  GuestMessage,
  HostMessage,
  Participant,
  Role,
  ServerMessage,
  SessionSnapshot,
  SharedWorkspace,
  WorkspaceLayout,
} from "./protocol";
import { PROTO_VERSION } from "./protocol";

/** How long a session survives with no host connection. */
export const HOST_GRACE_MS = 120_000;
/** Chat history cap; oldest messages are dropped first. */
export const CHAT_HISTORY_LIMIT = 500;
/** Cursor-color palette size; indices wrap after this many participants. */
export const COLOR_COUNT = 8;
/** Upper bound on message text; longer chat is truncated, not rejected. */
export const CHAT_TEXT_LIMIT = 4_000;
/** Per-connection cap on pane subscriptions (a guest-supplied string set;
 * the cap bounds memory instead of trusting the client). */
export const MAX_SUBS_PER_CONN = 64;

export type ConnId = string;

export type Effect =
  | { kind: "send"; to: ConnId; msg: ServerMessage }
  | { kind: "sendBinary"; to: ConnId; data: Uint8Array }
  | { kind: "close"; to: ConnId; code: number; reason: string }
  | { kind: "setAlarm"; at: number }
  | { kind: "clearAlarm" }
  | { kind: "persist" };

interface GuestGrant {
  user: string;
  email: string;
  role: Role;
  color: number;
}

/** Verified connection identity, as attested by the worker's auth boundary. */
export interface Identity {
  user: string;
  email: string;
  /** True only for connections made with a host-claim token. */
  hostToken: boolean;
}

/** Durable state, everything that must survive DO hibernation/eviction. */
export interface PersistedSession {
  code: string;
  host: { user: string; email: string };
  createdAt: number;
  shared: SharedWorkspace[];
  layouts: WorkspaceLayout[];
  grants: GuestGrant[];
  denied: string[];
  chat: ChatMessage[];
  ended: null | "host-stopped" | "host-gone" | "expired";
  /** Set while no host socket is attached; drives the grace alarm. */
  hostDisconnectedAt: number | null;
}

interface Conn {
  id: ConnId;
  user: string;
  email: string;
  isHost: boolean;
  /** Guests start pending until the host approves them. */
  active: boolean;
  focusWs: string | null;
  subs: Set<string>;
  follow: string | null;
}

/** NUL cannot appear in workspace/pane ids, so keys never collide. */
const SUB_KEY_SEPARATOR = "\u0000";
const subKey = (ws: string, pane: string) => `${ws}${SUB_KEY_SEPARATOR}${pane}`;

export class ShareSessionCore {
  private readonly conns = new Map<ConnId, Conn>();
  private s: PersistedSession;

  constructor(persisted: PersistedSession) {
    this.s = persisted;
  }

  static create(
    code: string,
    host: { user: string; email: string },
    now: number,
  ): PersistedSession {
    return {
      code,
      host,
      createdAt: now,
      shared: [],
      layouts: [],
      grants: [],
      denied: [],
      chat: [],
      ended: null,
      hostDisconnectedAt: now,
    };
  }

  get persisted(): PersistedSession {
    return this.s;
  }

  get ended(): boolean {
    return this.s.ended !== null;
  }

  // -------------------------------------------------------------------------
  // Connection lifecycle

  /**
   * Host-ness comes from the token claim (`hostToken`), never from user-id
   * equality alone: the host user opening their own share URL in a browser
   * holds a guest token and must join as a guest, not supersede the Mac's
   * host socket. A host token for a different user is rejected upstream.
   */
  connect(id: ConnId, who: Identity, now: number): Effect[] {
    if (this.s.ended) {
      return [
        { kind: "send", to: id, msg: { t: "session-ended", reason: this.s.ended } },
        { kind: "close", to: id, code: 1000, reason: "session ended" },
      ];
    }
    if (who.hostToken && who.user === this.s.host.user) {
      return this.connectHost(id, who, now);
    }
    return this.connectGuest(id, who);
  }

  private connectHost(
    id: ConnId,
    who: { user: string; email: string },
    _now: number,
  ): Effect[] {
    const effects: Effect[] = [];
    // Single host socket: a reconnect supersedes the old connection.
    for (const conn of this.conns.values()) {
      if (conn.isHost) {
        effects.push({ kind: "close", to: conn.id, code: 4000, reason: "superseded" });
        this.conns.delete(conn.id);
      }
    }
    this.conns.set(id, {
      id,
      user: who.user,
      email: who.email,
      isHost: true,
      active: true,
      focusWs: null,
      subs: new Set(),
      follow: null,
    });
    this.s.hostDisconnectedAt = null;
    effects.push({ kind: "clearAlarm" }, { kind: "persist" });
    effects.push({ kind: "send", to: id, msg: this.snapshotFor(id) });
    effects.push(...this.broadcastPresence(id));
    // Re-surface pending join requests to the freshly (re)connected host.
    for (const conn of this.conns.values()) {
      if (!conn.isHost && !conn.active && !this.isDenied(conn.user)) {
        effects.push({
          kind: "send",
          to: id,
          msg: { t: "access-request", user: conn.user, email: conn.email },
        });
      }
    }
    return effects;
  }

  private connectGuest(id: ConnId, who: { user: string; email: string }): Effect[] {
    if (this.isDenied(who.user)) {
      return [
        { kind: "send", to: id, msg: { t: "access-denied" } },
        { kind: "close", to: id, code: 4003, reason: "denied" },
      ];
    }
    // The host user viewing from a browser needs no approval.
    const selfHost = who.user === this.s.host.user;
    const grant = this.grantFor(who.user);
    const conn: Conn = {
      id,
      user: who.user,
      email: who.email,
      isHost: false,
      active: selfHost || grant !== null,
      focusWs: null,
      subs: new Set(),
      follow: null,
    };
    this.conns.set(id, conn);
    if (conn.active) {
      return [
        { kind: "send", to: id, msg: this.snapshotFor(id) },
        ...this.broadcastPresence(id),
      ];
    }
    const effects: Effect[] = [{ kind: "send", to: id, msg: { t: "access-pending" } }];
    const hostConn = this.hostConn();
    if (hostConn) {
      effects.push({
        kind: "send",
        to: hostConn.id,
        msg: { t: "access-request", user: who.user, email: who.email },
      });
    }
    return effects;
  }

  /**
   * Re-register connections that survived DO hibernation/eviction. Volatile
   * per-connection state (subs, focus, follow) is gone; every client gets a
   * fresh snapshot plus a `resync` asking it to re-establish that state.
   */
  restore(
    conns: ReadonlyArray<{ id: ConnId } & Identity>,
    now: number,
  ): Effect[] {
    const effects: Effect[] = [];
    // Host first so pending guests can surface their access requests to it.
    const ordered = [...conns].sort((a, b) => {
      const ah = a.hostToken && a.user === this.s.host.user ? 0 : 1;
      const bh = b.hostToken && b.user === this.s.host.user ? 0 : 1;
      return ah - bh;
    });
    for (const conn of ordered) {
      effects.push(...this.connect(conn.id, conn, now));
    }
    for (const conn of this.conns.values()) {
      if (conn.isHost || conn.active) {
        effects.push({ kind: "send", to: conn.id, msg: { t: "resync" } });
      }
    }
    return effects;
  }

  disconnect(id: ConnId, now: number): Effect[] {
    const conn = this.conns.get(id);
    if (!conn) return [];
    this.conns.delete(id);
    if (conn.isHost && !this.hostConn()) {
      this.s.hostDisconnectedAt = now;
      return [
        { kind: "persist" },
        { kind: "setAlarm", at: now + HOST_GRACE_MS },
        ...this.broadcastPresence(null),
      ];
    }
    if (!conn.isHost && conn.active) {
      return [
        // The host must see subscriber counts drop, or its per-pane streamer
        // state goes stale and the next subscriber never gets a full frame.
        ...this.subCountUpdatesFor(conn),
        ...this.broadcastPresence(null),
      ];
    }
    return [];
  }

  /** Post-removal `guest-sub` updates for every pane `conn` was watching. */
  private subCountUpdatesFor(conn: Conn): Effect[] {
    const effects: Effect[] = [];
    for (const key of conn.subs) {
      const [ws, pane] = key.split(SUB_KEY_SEPARATOR);
      if (ws && pane) effects.push(...this.subCountChanged(ws, pane));
    }
    return effects;
  }

  /** Drop every subscription to a no-longer-shared workspace and tell the
   * host about the count changes, so unsharing immediately stops streams. */
  private pruneUnsharedSubs(): Effect[] {
    const dropped = new Set<string>();
    for (const conn of this.conns.values()) {
      if (conn.isHost) continue;
      for (const key of [...conn.subs]) {
        const [ws] = key.split(SUB_KEY_SEPARATOR);
        if (ws && !this.isSharedWorkspace(ws)) {
          conn.subs.delete(key);
          dropped.add(key);
        }
      }
    }
    const effects: Effect[] = [];
    for (const key of dropped) {
      const [ws, pane] = key.split(SUB_KEY_SEPARATOR);
      if (ws && pane) effects.push(...this.subCountChanged(ws, pane));
    }
    return effects;
  }

  /** Alarm fired: end the session if the host never came back. */
  alarm(now: number): Effect[] {
    if (this.s.ended) return [];
    const gone = this.s.hostDisconnectedAt;
    if (gone === null) return [];
    if (now < gone + HOST_GRACE_MS) {
      return [{ kind: "setAlarm", at: gone + HOST_GRACE_MS }];
    }
    return this.endSession("host-gone");
  }

  // -------------------------------------------------------------------------
  // Messages

  handleHost(id: ConnId, msg: HostMessage): Effect[] {
    const conn = this.conns.get(id);
    if (!conn?.isHost || this.s.ended) return [];
    switch (msg.t) {
      case "hello": {
        if (msg.proto !== PROTO_VERSION) {
          return [{ kind: "close", to: id, code: 4400, reason: "bad proto" }];
        }
        this.s.shared = msg.shared;
        this.s.layouts = msg.layouts;
        return [
          { kind: "persist" },
          ...this.broadcastActive({ t: "shared", shared: msg.shared }, id),
          ...msg.layouts.map((layout) => this.layoutBroadcast(layout, id)).flat(),
        ];
      }
      case "layout": {
        this.upsertLayout(msg.layout);
        return [{ kind: "persist" }, ...this.layoutBroadcast(msg.layout, id)];
      }
      case "shared": {
        this.s.shared = msg.shared;
        this.pruneLayouts();
        return [
          { kind: "persist" },
          ...this.pruneUnsharedSubs(),
          ...this.broadcastActive({ t: "shared", shared: msg.shared }, id),
        ];
      }
      case "approve":
        return this.approve(msg.user, msg.role);
      case "deny":
        return this.deny(msg.user);
      case "kick":
        return this.kick(msg.user);
      case "role":
        return this.setRole(msg.user, msg.role);
      case "cursor":
        return this.cursorBroadcast(conn, msg.pos);
      case "chat":
        return this.chat(conn, msg.text, msg.bubble);
      case "focus": {
        conn.focusWs = msg.ws !== null && this.isSharedWorkspace(msg.ws) ? msg.ws : null;
        return this.broadcastPresence(null);
      }
      case "compose-state":
        // Authoritative composer state; not persisted (the host re-broadcasts
        // on resync like it does full grid frames).
        return this.broadcastActive(msg, id);
      case "end":
        return this.endSession("host-stopped");
    }
  }

  handleGuest(id: ConnId, msg: GuestMessage): Effect[] {
    const conn = this.conns.get(id);
    if (!conn || conn.isHost || this.s.ended) return [];
    if (msg.t === "hello") {
      if (msg.proto !== PROTO_VERSION) {
        return [{ kind: "close", to: id, code: 4400, reason: "bad proto" }];
      }
      return [];
    }
    if (!conn.active) return []; // pending guests can only wait
    switch (msg.t) {
      case "cursor":
        return this.cursorBroadcast(conn, msg.pos);
      case "chat":
        return this.chat(conn, msg.text, msg.bubble);
      case "input": {
        if (this.roleOf(conn.user) !== "editor") return [];
        if (!this.isSharedWorkspace(msg.ws)) return [];
        const hostConn = this.hostConn();
        if (!hostConn) return [];
        return [
          {
            kind: "send",
            to: hostConn.id,
            msg: { t: "guest-input", user: conn.user, ws: msg.ws, pane: msg.pane, data: msg.data },
          },
        ];
      }
      case "compose": {
        if (this.roleOf(conn.user) !== "editor") return [];
        const hostConn = this.hostConn();
        if (!hostConn) return [];
        return [
          {
            kind: "send",
            to: hostConn.id,
            msg: {
              t: "guest-compose",
              user: conn.user,
              field: msg.field,
              rev: msg.rev,
              ops: msg.ops,
              ...(msg.caret ? { caret: msg.caret } : {}),
            },
          },
        ];
      }
      case "pointer": {
        if (this.roleOf(conn.user) !== "editor") return [];
        if (!this.isSharedWorkspace(msg.ws)) return [];
        const hostConn = this.hostConn();
        if (!hostConn) return [];
        const { t: _t, ...rest } = msg;
        return [
          { kind: "send", to: hostConn.id, msg: { t: "guest-pointer", user: conn.user, ...rest } },
        ];
      }
      case "webkey": {
        if (this.roleOf(conn.user) !== "editor") return [];
        if (!this.isSharedWorkspace(msg.ws)) return [];
        const hostConn = this.hostConn();
        if (!hostConn) return [];
        const { t: _t, ...rest } = msg;
        return [
          { kind: "send", to: hostConn.id, msg: { t: "guest-webkey", user: conn.user, ...rest } },
        ];
      }
      case "sub": {
        if (!this.isSharedWorkspace(msg.ws)) return [];
        if (conn.subs.size >= MAX_SUBS_PER_CONN && !conn.subs.has(subKey(msg.ws, msg.pane))) {
          return [
            {
              kind: "send",
              to: conn.id,
              msg: { t: "error", code: "too_many_subs", message: "subscription limit reached" },
            },
          ];
        }
        conn.subs.add(subKey(msg.ws, msg.pane));
        return this.subCountChanged(msg.ws, msg.pane);
      }
      case "unsub": {
        conn.subs.delete(subKey(msg.ws, msg.pane));
        return this.subCountChanged(msg.ws, msg.pane);
      }
      case "focus": {
        conn.focusWs = msg.ws !== null && this.isSharedWorkspace(msg.ws) ? msg.ws : null;
        return this.broadcastPresence(null);
      }
      case "follow": {
        conn.follow = msg.user;
        return [];
      }
    }
  }

  /** Host binary frame (grid/pixel) → fan out to subscribed active guests. */
  routeBinary(fromId: ConnId, ws: string, pane: string, data: Uint8Array): Effect[] {
    const conn = this.conns.get(fromId);
    if (!conn?.isHost || this.s.ended) return [];
    // Never fan out frames for a workspace the host no longer shares, even
    // if a lagging host keeps emitting them.
    if (!this.isSharedWorkspace(ws)) return [];
    const key = subKey(ws, pane);
    const effects: Effect[] = [];
    for (const c of this.conns.values()) {
      if (!c.isHost && c.active && c.subs.has(key)) {
        effects.push({ kind: "sendBinary", to: c.id, data });
      }
    }
    return effects;
  }

  // -------------------------------------------------------------------------
  // Moderation

  private approve(user: string, role: Role): Effect[] {
    if (this.isDenied(user)) this.s.denied = this.s.denied.filter((u) => u !== user);
    let grant = this.grantFor(user);
    if (!grant) {
      const email = this.emailOf(user) ?? "";
      grant = { user, email, role, color: this.nextColor() };
      this.s.grants.push(grant);
    } else {
      grant.role = role;
    }
    const effects: Effect[] = [{ kind: "persist" }];
    for (const conn of this.conns.values()) {
      if (!conn.isHost && conn.user === user && !conn.active) {
        conn.active = true;
        effects.push({ kind: "send", to: conn.id, msg: this.snapshotFor(conn.id) });
      }
    }
    effects.push(...this.broadcastPresence(null));
    return effects;
  }

  private deny(user: string): Effect[] {
    if (!this.isDenied(user)) this.s.denied.push(user);
    this.s.grants = this.s.grants.filter((g) => g.user !== user);
    const effects: Effect[] = [{ kind: "persist" }];
    const removed: Conn[] = [];
    for (const conn of [...this.conns.values()]) {
      if (!conn.isHost && conn.user === user) {
        effects.push(
          { kind: "send", to: conn.id, msg: { t: "access-denied" } },
          { kind: "close", to: conn.id, code: 4003, reason: "denied" },
        );
        this.conns.delete(conn.id);
        removed.push(conn);
      }
    }
    for (const conn of removed) effects.push(...this.subCountUpdatesFor(conn));
    effects.push(...this.broadcastPresence(null));
    return effects;
  }

  /** Kick = deny for the remainder of the session. */
  private kick(user: string): Effect[] {
    const effects = this.deny(user);
    // Replace the generic denied notice with an explicit kick for open conns
    // (deny() already closed them; the distinction only matters for copy, so
    // the kicked message is sent first when a connection existed).
    return effects.map((e) =>
      e.kind === "send" && e.msg.t === "access-denied" ? { ...e, msg: { t: "kicked" as const } } : e,
    );
  }

  private setRole(user: string, role: Role): Effect[] {
    const grant = this.grantFor(user);
    if (!grant) return [];
    grant.role = role;
    const effects: Effect[] = [{ kind: "persist" }];
    for (const conn of this.conns.values()) {
      if (conn.user === user && conn.active && !conn.isHost) {
        effects.push({ kind: "send", to: conn.id, msg: { t: "role-changed", role } });
      }
    }
    effects.push(...this.broadcastPresence(null));
    return effects;
  }

  private endSession(reason: "host-stopped" | "host-gone" | "expired"): Effect[] {
    this.s.ended = reason;
    const effects: Effect[] = [{ kind: "persist" }, { kind: "clearAlarm" }];
    for (const conn of [...this.conns.values()]) {
      effects.push(
        { kind: "send", to: conn.id, msg: { t: "session-ended", reason } },
        { kind: "close", to: conn.id, code: 1000, reason: "session ended" },
      );
      this.conns.delete(conn.id);
    }
    return effects;
  }

  // -------------------------------------------------------------------------
  // Chat + cursors

  private chat(conn: Conn, text: string, bubble: CursorPos | undefined): Effect[] {
    const trimmed = text.slice(0, CHAT_TEXT_LIMIT).trim();
    if (!trimmed) return [];
    const msg: ChatMessage = {
      id: crypto.randomUUID(),
      user: conn.user,
      text: trimmed,
      ts: Date.now(),
      ...(bubble ? { bubble } : {}),
    };
    this.s.chat.push(msg);
    if (this.s.chat.length > CHAT_HISTORY_LIMIT) {
      this.s.chat = this.s.chat.slice(-CHAT_HISTORY_LIMIT);
    }
    return [{ kind: "persist" }, ...this.broadcastActive({ t: "chat", msg }, null)];
  }

  private cursorBroadcast(conn: Conn, pos: CursorPos | null): Effect[] {
    const scrubbed = pos && this.isSharedWorkspace(pos.ws) ? pos : null;
    return this.broadcastActive({ t: "cursor", user: conn.user, pos: scrubbed }, conn.id);
  }

  // -------------------------------------------------------------------------
  // Helpers

  private upsertLayout(layout: WorkspaceLayout): void {
    const i = this.s.layouts.findIndex((l) => l.ws === layout.ws);
    if (i >= 0) this.s.layouts[i] = layout;
    else this.s.layouts.push(layout);
  }

  private pruneLayouts(): void {
    const ids = new Set(this.s.shared.map((w) => w.id));
    this.s.layouts = this.s.layouts.filter((l) => ids.has(l.ws));
  }

  private layoutBroadcast(layout: WorkspaceLayout, except: ConnId | null): Effect[] {
    return this.broadcastActive({ t: "layout", layout }, except);
  }

  private subCountChanged(ws: string, pane: string): Effect[] {
    const hostConn = this.hostConn();
    if (!hostConn) return [];
    const key = subKey(ws, pane);
    let count = 0;
    for (const c of this.conns.values()) {
      if (!c.isHost && c.active && c.subs.has(key)) count += 1;
    }
    return [{ kind: "send", to: hostConn.id, msg: { t: "guest-sub", ws, pane, count } }];
  }

  private broadcastActive(msg: ServerMessage, except: ConnId | null): Effect[] {
    const effects: Effect[] = [];
    for (const conn of this.conns.values()) {
      if (conn.id === except) continue;
      if (!conn.isHost && !conn.active) continue;
      effects.push({ kind: "send", to: conn.id, msg });
    }
    return effects;
  }

  private broadcastPresence(except: ConnId | null): Effect[] {
    return this.broadcastActive({ t: "presence", participants: this.participants() }, except);
  }

  participants(): Participant[] {
    const out: Participant[] = [];
    const connectedUsers = new Map<string, Conn>();
    for (const conn of this.conns.values()) {
      if (conn.isHost || conn.active) connectedUsers.set(conn.user, conn);
    }
    out.push({
      user: this.s.host.user,
      email: this.s.host.email,
      role: "editor",
      color: 0,
      focusWs: connectedUsers.get(this.s.host.user)?.focusWs ?? null,
      connected: this.hostConn() !== null,
      isHost: true,
    });
    for (const grant of this.s.grants) {
      const conn = connectedUsers.get(grant.user);
      out.push({
        user: grant.user,
        email: grant.email,
        role: grant.role,
        color: grant.color,
        focusWs: conn?.focusWs ?? null,
        connected: conn !== undefined,
        isHost: false,
      });
    }
    return out;
  }

  private snapshotFor(id: ConnId): SessionSnapshot {
    const conn = this.conns.get(id);
    const isHostUser = conn?.user === this.s.host.user;
    const grant = conn && !isHostUser ? this.grantFor(conn.user) : null;
    return {
      t: "session-state",
      proto: PROTO_VERSION,
      shared: this.s.shared,
      layouts: this.s.layouts,
      participants: this.participants(),
      chat: this.s.chat,
      // The host user is editor/color 0 on every device, including a browser
      // connection made with a guest token; only `isHost` distinguishes the
      // authoritative Mac socket.
      you: isHostUser
        ? { user: this.s.host.user, role: "editor", color: 0, isHost: conn?.isHost ?? false }
        : {
            user: conn?.user ?? "",
            role: grant?.role ?? "viewer",
            color: grant?.color ?? 0,
            isHost: false,
          },
    };
  }

  private hostConn(): Conn | null {
    for (const conn of this.conns.values()) if (conn.isHost) return conn;
    return null;
  }

  private grantFor(user: string): GuestGrant | null {
    return this.s.grants.find((g) => g.user === user) ?? null;
  }

  private roleOf(user: string): Role | null {
    if (user === this.s.host.user) return "editor";
    return this.grantFor(user)?.role ?? null;
  }

  private isDenied(user: string): boolean {
    return this.s.denied.includes(user);
  }

  private isSharedWorkspace(ws: string): boolean {
    return this.s.shared.some((w) => w.id === ws);
  }

  private emailOf(user: string): string | null {
    for (const conn of this.conns.values()) if (conn.user === user) return conn.email;
    return null;
  }

  private nextColor(): number {
    const used = new Set<number>([0, ...this.s.grants.map((g) => g.color)]);
    for (let i = 1; i < COLOR_COUNT; i += 1) if (!used.has(i)) return i;
    return this.s.grants.length % COLOR_COUNT;
  }
}
