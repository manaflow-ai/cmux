// SPDX-License-Identifier: GPL-3.0-or-later
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
import {
  BINARY_KIND_GRID,
  isCurrentTerminalPane,
  isCursorPos,
  isIdentityEmail,
  isProtocolId,
  isRole,
  MAX_BINARY_FRAME_BYTES,
  MAX_CHAT_TEXT_BYTES,
  MAX_SERVER_JSON_FRAME_BYTES,
  MAX_TERMINAL_INPUT_BYTES,
  parseCursorPos,
  parseSharedWorkspaces,
  parseWorkspaceLayouts,
  PROTO_VERSION,
  utf8ByteLength,
} from "./protocol";

/** How long a session survives with no host connection. */
export const HOST_GRACE_MS = 120_000;
/** Ended-code tombstones outlive the 300-second share-token TTL. This
 * ten-minute window prevents a create token from materializing the same code
 * after cleanup, while bounding Durable Object storage growth. */
export const ENDED_TOMBSTONE_RETENTION_MS = 10 * 60_000;
/** Chat history cap; oldest messages are dropped first. */
export const CHAT_HISTORY_LIMIT = 500;
/** Serialized chat history byte cap; oldest messages are dropped first. */
export const CHAT_HISTORY_BYTE_LIMIT = 256 * 1024;
/** Cursor-color palette size; indices wrap after this many participants. */
export const COLOR_COUNT = 8;
/** Upper bound on UTF-8 chat text bytes; longer direct-core input is
 * truncated, while the wire validator rejects it. */
export const CHAT_TEXT_LIMIT = MAX_CHAT_TEXT_BYTES;
/** Per-connection cap on pane subscriptions (a guest-supplied string set;
 * the cap bounds memory instead of trusting the client). */
export const MAX_SUBS_PER_CONN = 64;
/** Total sockets one session will hold, host included. Beyond this a new
 * connection is rejected outright (error + close 4429) and never retained. */
export const MAX_CONNECTIONS_PER_SESSION = 32;
/** How many unapproved guests may sit in the pending queue at once. */
export const MAX_PENDING_REQUESTS_PER_SESSION = 16;
/** Close code for capacity rejections (mirrors HTTP 429). */
export const CAPACITY_CLOSE_CODE = 4429;
/** Persisted authorization collections are bounded independently of sockets. */
export const MAX_GRANTS_PER_SESSION = 256;
export const MAX_DENIED_PER_SESSION = 256;
/** Fixed-window cursor budget. It is intentionally small and per socket. */
export const CURSOR_RATE_LIMIT = 30;
export const CURSOR_RATE_WINDOW_MS = 1_000;
export const CURSOR_ROOM_SOURCE_LIMIT = 240;
export const CURSOR_ROOM_DELIVERY_LIMIT = 4_096;
export const CHAT_RATE_LIMIT_PER_SOCKET = 2;
export const CHAT_RATE_LIMIT_PER_ROOM = 8;
export const INPUT_RATE_LIMIT_PER_SOCKET = 60;
export const INPUT_RATE_LIMIT_PER_ROOM = 240;
export const SUB_RATE_LIMIT_PER_SOCKET = 64;
export const SUB_RATE_LIMIT_PER_ROOM = 256;
export const APPLICATION_RATE_WINDOW_MS = 1_000;
export const RATE_LIMIT_CLOSE_CODE = 4008;
export const RATE_LIMIT_CLOSE_REASON = "rate_limited";

export type ConnId = string;

export type Effect =
  | { kind: "send"; to: ConnId; msg: ServerMessage }
  | { kind: "sendBinary"; to: ConnId; data: Uint8Array }
  | { kind: "close"; to: ConnId; code: number; reason: string }
  | { kind: "setAlarm"; at: number }
  | { kind: "clearAlarm" }
  | { kind: "deleteAllStorage" }
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
  /** End time used to derive the fixed tombstone cleanup alarm. */
  endedAt: number | null;
  /** Set while no host socket is attached; drives the grace alarm. */
  hostDisconnectedAt: number | null;
}

type UnknownRecord = Record<string, unknown>;

function unknownRecord(value: unknown): UnknownRecord | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as UnknownRecord)
    : null;
}

/** Validate and defensively clone Durable Object storage before it enters the
 * session core. Oversized historical collections are clipped, malformed
 * structural state fails closed. */
export function restorePersistedSession(value: unknown): PersistedSession | null {
  const obj = unknownRecord(value);
  const host = unknownRecord(obj?.host);
  if (
    !obj ||
    !isProtocolId(obj.code) ||
    !host ||
    !isProtocolId(host.user) ||
    !isIdentityEmail(host.email) ||
    typeof obj.createdAt !== "number" ||
    !Number.isSafeInteger(obj.createdAt) ||
    obj.createdAt < 0
  ) {
    return null;
  }

  const shared = parseSharedWorkspaces(obj.shared);
  const layouts = parseWorkspaceLayouts(obj.layouts);
  if (!shared || !layouts) return null;
  const sharedIds = new Set(shared.map((workspace) => workspace.id));
  if (layouts.some((layout) => !sharedIds.has(layout.ws))) return null;

  if (!Array.isArray(obj.grants) || !Array.isArray(obj.denied) || !Array.isArray(obj.chat)) {
    return null;
  }

  const grantsByUser = new Map<string, GuestGrant>();
  for (const raw of obj.grants.slice(-MAX_GRANTS_PER_SESSION)) {
    const grant = unknownRecord(raw);
    if (
      !grant ||
      !isProtocolId(grant.user) ||
      !isIdentityEmail(grant.email) ||
      !isRole(grant.role) ||
      !Number.isSafeInteger(grant.color) ||
      (grant.color as number) < 0 ||
      (grant.color as number) >= COLOR_COUNT
    ) {
      return null;
    }
    if (grant.user === host.user) continue;
    grantsByUser.set(grant.user, {
      user: grant.user,
      email: grant.email,
      role: grant.role,
      color: grant.color as number,
    });
  }

  const denied: string[] = [];
  const deniedSet = new Set<string>();
  for (const user of obj.denied.slice(-MAX_DENIED_PER_SESSION)) {
    if (!isProtocolId(user)) return null;
    if (user !== host.user && !deniedSet.has(user)) {
      deniedSet.add(user);
      denied.push(user);
    }
  }

  const grants = [...grantsByUser.values()].filter((grant) => !deniedSet.has(grant.user));
  const chat: ChatMessage[] = [];
  let chatBytes = 2;
  for (const raw of obj.chat.slice(-CHAT_HISTORY_LIMIT)) {
    const message = unknownRecord(raw);
    if (
      !message ||
      !isProtocolId(message.id) ||
      !isProtocolId(message.user) ||
      typeof message.text !== "string" ||
      message.text.length === 0 ||
      utf8ByteLength(message.text) > CHAT_TEXT_LIMIT ||
      typeof message.ts !== "number" ||
      !Number.isFinite(message.ts) ||
      message.ts < 0
    ) {
      return null;
    }
    const parsedBubble = message.bubble === undefined ? undefined : parseCursorPos(message.bubble);
    const bubble =
      parsedBubble &&
      sharedIds.has(parsedBubble.ws) &&
      isCurrentTerminalPane(layouts, parsedBubble.ws, parsedBubble.pane)
        ? parsedBubble
        : undefined;
    const restored: ChatMessage = {
      id: message.id,
      user: message.user,
      text: message.text,
      ts: message.ts,
      ...(bubble ? { bubble } : {}),
    };
    const bytes = serializedBytes(restored);
    chat.push(restored);
    chatBytes += bytes + (chat.length > 1 ? 1 : 0);
    while (chat.length > 0 && chatBytes > CHAT_HISTORY_BYTE_LIMIT) {
      const removed = chat.shift();
      if (removed) chatBytes -= serializedBytes(removed) + (chat.length > 0 ? 1 : 0);
    }
  }

  const ended =
    obj.ended === null ||
    obj.ended === "host-stopped" ||
    obj.ended === "host-gone" ||
    obj.ended === "expired"
      ? obj.ended
      : undefined;
  if (ended === undefined) return null;
  let endedAt: number | null;
  if (ended === null) {
    // Missing is accepted only for active records written before this field
    // existed. An explicit timestamp on an active session is inconsistent.
    if (obj.endedAt !== undefined && obj.endedAt !== null) return null;
    endedAt = null;
  } else if (obj.endedAt === undefined) {
    // Legacy ended records did not record their end time. Creation time is a
    // conservative deterministic fallback: cleanup remains at least ten
    // minutes after the only create token could have been minted.
    endedAt = obj.createdAt;
  } else if (
    typeof obj.endedAt === "number" &&
    Number.isSafeInteger(obj.endedAt) &&
    obj.endedAt >= obj.createdAt
  ) {
    endedAt = obj.endedAt;
  } else {
    return null;
  }
  if (
    endedAt !== null &&
    !Number.isSafeInteger(endedAt + ENDED_TOMBSTONE_RETENTION_MS)
  ) {
    return null;
  }
  const hostDisconnectedAt =
    obj.hostDisconnectedAt === null
      ? null
      : typeof obj.hostDisconnectedAt === "number" &&
          Number.isSafeInteger(obj.hostDisconnectedAt) &&
          obj.hostDisconnectedAt >= 0 &&
          Number.isSafeInteger(obj.hostDisconnectedAt + HOST_GRACE_MS)
        ? obj.hostDisconnectedAt
        : undefined;
  if (hostDisconnectedAt === undefined) return null;

  return {
    code: obj.code,
    host: { user: host.user, email: host.email },
    createdAt: obj.createdAt,
    shared,
    layouts,
    grants,
    denied,
    chat,
    ended,
    endedAt,
    hostDisconnectedAt,
  };
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
  cursorWindowStartedAt: number;
  cursorEventsInWindow: number;
  chatWindowStartedAt: number;
  chatEventsInWindow: number;
  chatRateLimitNotified: boolean;
  inputWindowStartedAt: number;
  inputEventsInWindow: number;
  inputRateLimitNotified: boolean;
  subWindowStartedAt: number;
  subEventsInWindow: number;
  subRateLimitNotified: boolean;
}

interface DirtyCursor {
  pos: CursorPos | null;
  eligibleAt: number;
}

/** NUL cannot appear in workspace/pane ids, so keys never collide. */
const SUB_KEY_SEPARATOR = "\u0000";
const subKey = (ws: string, pane: string) => `${ws}${SUB_KEY_SEPARATOR}${pane}`;

export class ShareSessionCore {
  private readonly conns = new Map<ConnId, Conn>();
  private s: PersistedSession;
  private chatBytes: number;
  private readonly dirtyCursors = new Map<ConnId, DirtyCursor>();
  private cursorRoomWindowStartedAt = Number.NEGATIVE_INFINITY;
  private cursorSourceBroadcastsInWindow = 0;
  private cursorRecipientDeliveriesInWindow = 0;
  private chatRoomWindowStartedAt = Number.NEGATIVE_INFINITY;
  private chatRoomEventsInWindow = 0;
  private inputRoomWindowStartedAt = Number.NEGATIVE_INFINITY;
  private inputRoomEventsInWindow = 0;
  private subRoomWindowStartedAt = Number.NEGATIVE_INFINITY;
  private subRoomEventsInWindow = 0;
  private scheduledAlarmAt: number | null;

  constructor(persisted: PersistedSession) {
    this.s = persisted;
    this.chatBytes = serializedArrayBytes(persisted.chat);
    this.scheduledAlarmAt =
      persisted.endedAt !== null
        ? persisted.endedAt + ENDED_TOMBSTONE_RETENTION_MS
        : persisted.hostDisconnectedAt === null
          ? null
          : persisted.hostDisconnectedAt + HOST_GRACE_MS;
    this.trimChatHistory();
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
      endedAt: null,
      hostDisconnectedAt: now,
    };
  }

  get persisted(): PersistedSession {
    return this.s;
  }

  get ended(): boolean {
    return this.s.ended !== null;
  }

  get rateLimitProfileSizes(): Readonly<{ connections: number; dirtyCursors: number }> {
    return { connections: this.conns.size, dirtyCursors: this.dirtyCursors.size };
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
      // The host reconnect always wins (it supersedes the old socket), so it
      // is exempt from the capacity checks below.
      return this.connectHost(id, who, now);
    }
    // Capacity rejections never retain the socket, so a rejected user can
    // neither occupy a slot nor resurface as pending on host reconnect.
    // While the host is in its grace window, reserve its slot so guests
    // cannot lock it out by filling the room before it reconnects.
    const occupiedSlots = this.conns.size + (this.hostConn() ? 0 : 1);
    if (occupiedSlots >= MAX_CONNECTIONS_PER_SESSION) {
      return this.capacityRejection(id, "session_full", "session is full");
    }
    const isKnown =
      who.user === this.s.host.user || this.grantFor(who.user) !== null || this.isDenied(who.user);
    if (!isKnown && this.pendingCount() >= MAX_PENDING_REQUESTS_PER_SESSION) {
      return this.capacityRejection(
        id,
        "too_many_pending",
        "too many pending join requests",
      );
    }
    return this.connectGuest(id, who, now);
  }

  private capacityRejection(
    id: ConnId,
    code: "session_full" | "too_many_pending",
    message: string,
  ): Effect[] {
    return [
      { kind: "send", to: id, msg: { t: "error", code, message } },
      { kind: "close", to: id, code: CAPACITY_CLOSE_CODE, reason: message },
    ];
  }

  private pendingCount(): number {
    let count = 0;
    for (const conn of this.conns.values()) {
      if (!conn.isHost && !conn.active) count += 1;
    }
    return count;
  }

  private newConnection(
    id: ConnId,
    user: string,
    email: string,
    isHost: boolean,
    active: boolean,
    now: number,
  ): Conn {
    return {
      id,
      user,
      email,
      isHost,
      active,
      focusWs: null,
      subs: new Set(),
      cursorWindowStartedAt: now,
      cursorEventsInWindow: 0,
      chatWindowStartedAt: now,
      chatEventsInWindow: 0,
      chatRateLimitNotified: false,
      inputWindowStartedAt: now,
      inputEventsInWindow: 0,
      inputRateLimitNotified: false,
      subWindowStartedAt: now,
      subEventsInWindow: 0,
      subRateLimitNotified: false,
    };
  }

  private connectHost(
    id: ConnId,
    who: { user: string; email: string },
    now: number,
  ): Effect[] {
    const effects: Effect[] = [];
    // Single host socket: a reconnect supersedes the old connection.
    for (const conn of this.conns.values()) {
      if (conn.isHost) {
        effects.push({ kind: "close", to: conn.id, code: 4000, reason: "superseded" });
        this.conns.delete(conn.id);
        this.dirtyCursors.delete(conn.id);
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
      cursorWindowStartedAt: now,
      cursorEventsInWindow: 0,
      chatWindowStartedAt: now,
      chatEventsInWindow: 0,
      chatRateLimitNotified: false,
      inputWindowStartedAt: now,
      inputEventsInWindow: 0,
      inputRateLimitNotified: false,
      subWindowStartedAt: now,
      subEventsInWindow: 0,
      subRateLimitNotified: false,
    });
    this.s.hostDisconnectedAt = null;
    effects.push(...this.reconcileAlarm(), { kind: "persist" });
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

  private connectGuest(
    id: ConnId,
    who: { user: string; email: string },
    now: number,
  ): Effect[] {
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
      cursorWindowStartedAt: now,
      cursorEventsInWindow: 0,
      chatWindowStartedAt: now,
      chatEventsInWindow: 0,
      chatRateLimitNotified: false,
      inputWindowStartedAt: now,
      inputEventsInWindow: 0,
      inputRateLimitNotified: false,
      subWindowStartedAt: now,
      subEventsInWindow: 0,
      subRateLimitNotified: false,
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
   * per-connection state (subs, focus, cursor budget) is gone; every client gets a
   * fresh snapshot plus a `resync` asking it to re-establish that state.
   */
  restore(
    conns: ReadonlyArray<{ id: ConnId } & Identity>,
    now: number,
  ): Effect[] {
    const effects: Effect[] = [];
    this.conns.clear();
    this.dirtyCursors.clear();
    if (this.s.ended) {
      const cleanupAt = this.tombstoneCleanupAt();
      if (cleanupAt !== null) {
        this.scheduledAlarmAt = cleanupAt;
        effects.push({ kind: "setAlarm", at: cleanupAt });
      }
      for (const conn of conns) {
        effects.push(
          { kind: "send", to: conn.id, msg: { t: "session-ended", reason: this.s.ended } },
          { kind: "close", to: conn.id, code: 1000, reason: "session ended" },
        );
      }
      return effects;
    }

    // Host first so pending guests can surface their access requests to it.
    const ordered = [...conns].sort((a, b) => {
      const ah = a.hostToken && a.user === this.s.host.user ? 0 : 1;
      const bh = b.hostToken && b.user === this.s.host.user ? 0 : 1;
      return ah - bh;
    });

    // Rebuild the complete bounded membership before constructing any
    // snapshots. Calling connect() here would emit intermediate presence after
    // every survivor, causing O(n²) restore fan-out and artificial credit
    // exhaustion before ACK events can interleave.
    for (const survivor of ordered) {
      const isHost = survivor.hostToken && survivor.user === this.s.host.user;
      if (isHost) {
        const previous = this.hostConn();
        if (previous) {
          this.conns.delete(previous.id);
          effects.push({
            kind: "close",
            to: previous.id,
            code: 4000,
            reason: "superseded",
          });
        }
        this.conns.set(
          survivor.id,
          this.newConnection(
            survivor.id,
            survivor.user,
            survivor.email,
            true,
            true,
            now,
          ),
        );
        continue;
      }

      const occupiedSlots = this.conns.size + (this.hostConn() ? 0 : 1);
      if (occupiedSlots >= MAX_CONNECTIONS_PER_SESSION) {
        effects.push(...this.capacityRejection(survivor.id, "session_full", "session is full"));
        continue;
      }
      if (this.isDenied(survivor.user)) {
        effects.push(
          { kind: "send", to: survivor.id, msg: { t: "access-denied" } },
          { kind: "close", to: survivor.id, code: 4003, reason: "denied" },
        );
        continue;
      }
      const selfHost = survivor.user === this.s.host.user;
      const active = selfHost || this.grantFor(survivor.user) !== null;
      if (!active && this.pendingCount() >= MAX_PENDING_REQUESTS_PER_SESSION) {
        effects.push(
          ...this.capacityRejection(
            survivor.id,
            "too_many_pending",
            "too many pending join requests",
          ),
        );
        continue;
      }
      this.conns.set(
        survivor.id,
        this.newConnection(
          survivor.id,
          survivor.user,
          survivor.email,
          false,
          active,
          now,
        ),
      );
    }

    const host = this.hostConn();
    let persistenceChanged = false;
    if (host && this.s.hostDisconnectedAt !== null) {
      this.s.hostDisconnectedAt = null;
      persistenceChanged = true;
    } else if (!host && this.s.hostDisconnectedAt === null) {
      this.s.hostDisconnectedAt = now;
      persistenceChanged = true;
    }
    effects.push(...this.reconcileAlarm());
    if (persistenceChanged) effects.push({ kind: "persist" });

    for (const conn of this.conns.values()) {
      if (conn.isHost || conn.active) {
        effects.push(
          { kind: "send", to: conn.id, msg: this.snapshotFor(conn.id) },
          { kind: "send", to: conn.id, msg: { t: "resync" } },
        );
      } else {
        effects.push({ kind: "send", to: conn.id, msg: { t: "access-pending" } });
        if (host) {
          effects.push({
            kind: "send",
            to: host.id,
            msg: { t: "access-request", user: conn.user, email: conn.email },
          });
        }
      }
    }
    return effects;
  }

  disconnect(id: ConnId, now: number): Effect[] {
    const conn = this.conns.get(id);
    if (!conn) return [];
    this.conns.delete(id);
    this.dirtyCursors.delete(id);
    if (conn.isHost && !this.hostConn()) {
      this.s.hostDisconnectedAt = now;
      return [
        { kind: "persist" },
        ...this.reconcileAlarm(),
        ...this.broadcastPresence(null),
      ];
    }
    if (!conn.isHost && conn.active) {
      return [
        // The host must see subscriber counts drop, or its per-pane streamer
        // state goes stale and the next subscriber never gets a full frame.
        ...this.subCountUpdatesFor(conn),
        ...this.broadcastPresence(null),
        ...this.reconcileAlarm(),
      ];
    }
    return this.reconcileAlarm();
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

  /** Drop subscriptions whose workspace/pane is no longer an authoritative
   * terminal leaf and tell the host so its streamer counts stay exact. */
  private pruneInvalidSubs(): Effect[] {
    const dropped = new Set<string>();
    for (const conn of this.conns.values()) {
      if (conn.isHost) continue;
      for (const key of [...conn.subs]) {
        const [ws, pane] = key.split(SUB_KEY_SEPARATOR);
        if (ws && pane && !this.isCurrentTerminalPane(ws, pane)) {
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

  /** One storage alarm serves cursor coalescing, host grace, and tombstones. */
  alarm(now: number): Effect[] {
    this.scheduledAlarmAt = null;
    if (!Number.isSafeInteger(now) || now < 0) return this.reconcileAlarm();
    if (this.s.ended) {
      const cleanupAt = this.tombstoneCleanupAt();
      if (cleanupAt === null || now < cleanupAt) return this.reconcileAlarm();
      return [{ kind: "deleteAllStorage" }];
    }
    const gone = this.s.hostDisconnectedAt;
    if (gone !== null && now >= gone + HOST_GRACE_MS) {
      return this.endSession("host-gone", now);
    }
    const effects = this.drainCursorQueue(now);
    effects.push(...this.reconcileAlarm());
    return effects;
  }

  // -------------------------------------------------------------------------
  // Messages

  handleHost(id: ConnId, msg: HostMessage, now: number = Date.now()): Effect[] {
    const conn = this.conns.get(id);
    if (!conn?.isHost || this.s.ended) return [];
    switch (msg.t) {
      case "hello": {
        if (msg.proto !== PROTO_VERSION) {
          return [{ kind: "close", to: id, code: 4400, reason: "bad proto" }];
        }
        const shared = parseSharedWorkspaces(msg.shared);
        const layouts = parseWorkspaceLayouts(msg.layouts);
        if (!shared || !layouts) return [];
        const sharedIds = new Set(shared.map((workspace) => workspace.id));
        if (layouts.some((layout) => !sharedIds.has(layout.ws))) return [];
        this.s.shared = shared;
        this.s.layouts = layouts;
        return [
          { kind: "persist" },
          ...this.pruneInvalidSubs(),
          ...this.broadcastActive({ t: "shared", shared }, id),
          ...layouts.map((layout) => this.layoutBroadcast(layout, id)).flat(),
        ];
      }
      case "layout": {
        const layouts = parseWorkspaceLayouts([msg.layout]);
        const layout = layouts?.[0];
        if (!layout || !this.isSharedWorkspace(layout.ws)) return [];
        this.upsertLayout(layout);
        return [
          { kind: "persist" },
          ...this.pruneInvalidSubs(),
          ...this.layoutBroadcast(layout, id),
        ];
      }
      case "shared": {
        const shared = parseSharedWorkspaces(msg.shared);
        if (!shared) return [];
        this.s.shared = shared;
        this.pruneLayouts();
        return [
          { kind: "persist" },
          ...this.pruneInvalidSubs(),
          ...this.broadcastActive({ t: "shared", shared }, id),
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
        return this.cursorBroadcast(conn, msg.pos, now);
      case "chat":
        return this.chat(conn, msg.text, msg.bubble, now);
      case "focus": {
        conn.focusWs = msg.ws !== null && this.isSharedWorkspace(msg.ws) ? msg.ws : null;
        return this.broadcastPresence(null);
      }
      case "end":
        return this.endSession("host-stopped", now);
    }
  }

  handleGuest(id: ConnId, msg: GuestMessage, now: number = Date.now()): Effect[] {
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
        return this.cursorBroadcast(conn, msg.pos, now);
      case "chat":
        return this.chat(conn, msg.text, msg.bubble, now);
      case "input": {
        if (this.roleOf(conn.user) !== "editor") return [];
        if (!this.isCurrentTerminalPane(msg.ws, msg.pane)) return [];
        if (
          msg.data.length === 0 ||
          msg.data.length > MAX_TERMINAL_INPUT_BYTES ||
          utf8ByteLength(msg.data) > MAX_TERMINAL_INPUT_BYTES
        ) {
          return [];
        }
        const hostConn = this.hostConn();
        if (!hostConn) return [];
        if (!this.consumeSocketRate(conn, "input", INPUT_RATE_LIMIT_PER_SOCKET, now)) {
          return [
            {
              kind: "close",
              to: conn.id,
              code: RATE_LIMIT_CLOSE_CODE,
              reason: RATE_LIMIT_CLOSE_REASON,
            },
          ];
        }
        if (!this.consumeRoomRate("input", INPUT_RATE_LIMIT_PER_ROOM, now)) {
          return this.rateLimitedOnce(conn, "input");
        }
        return [
          {
            kind: "send",
            to: hostConn.id,
            msg: { t: "guest-input", user: conn.user, ws: msg.ws, pane: msg.pane, data: msg.data },
          },
        ];
      }
      case "sub": {
        if (!this.isCurrentTerminalPane(msg.ws, msg.pane)) return [];
        const key = subKey(msg.ws, msg.pane);
        if (conn.subs.has(key)) return [];
        if (conn.subs.size >= MAX_SUBS_PER_CONN) {
          return [
            {
              kind: "send",
              to: conn.id,
              msg: { t: "error", code: "too_many_subs", message: "subscription limit reached" },
            },
          ];
        }
        if (!this.consumeSocketRate(conn, "sub", SUB_RATE_LIMIT_PER_SOCKET, now)) {
          return this.rateLimitedOnce(conn, "sub");
        }
        if (!this.consumeRoomRate("sub", SUB_RATE_LIMIT_PER_ROOM, now)) {
          return this.rateLimitedOnce(conn, "sub");
        }
        conn.subs.add(key);
        return this.subCountChanged(msg.ws, msg.pane);
      }
      case "unsub": {
        const key = subKey(msg.ws, msg.pane);
        if (!conn.subs.has(key)) return [];
        if (!this.consumeSocketRate(conn, "sub", SUB_RATE_LIMIT_PER_SOCKET, now)) {
          return this.rateLimitedOnce(conn, "sub");
        }
        if (!this.consumeRoomRate("sub", SUB_RATE_LIMIT_PER_ROOM, now)) {
          return this.rateLimitedOnce(conn, "sub");
        }
        conn.subs.delete(key);
        return this.subCountChanged(msg.ws, msg.pane);
      }
      case "focus": {
        conn.focusWs = msg.ws !== null && this.isSharedWorkspace(msg.ws) ? msg.ws : null;
        return this.broadcastPresence(null);
      }
    }
  }

  /** Host terminal grid frame -> subscribed active guests. */
  routeBinary(
    fromId: ConnId,
    ws: string,
    pane: string,
    data: Uint8Array,
    kind: number = BINARY_KIND_GRID,
  ): Effect[] {
    const conn = this.conns.get(fromId);
    if (!conn?.isHost || this.s.ended) return [];
    if (
      kind !== BINARY_KIND_GRID ||
      data.byteLength >= MAX_BINARY_FRAME_BYTES ||
      !this.isCurrentTerminalPane(ws, pane)
    ) {
      return [];
    }
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
      if (this.s.grants.length >= MAX_GRANTS_PER_SESSION) {
        // Prefer forgetting an inactive historical grant. With at most 32
        // sockets, a 256-entry collection always has one in normal state.
        const replace = this.s.grants.findIndex(
          (candidate) =>
            ![...this.conns.values()].some(
              (conn) => !conn.isHost && conn.active && conn.user === candidate.user,
            ),
        );
        if (replace < 0) return this.hostError("too_many_grants", "grant limit reached");
        this.s.grants.splice(replace, 1);
      }
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
    if (!this.isDenied(user)) {
      if (this.s.denied.length >= MAX_DENIED_PER_SESSION) this.s.denied.shift();
      this.s.denied.push(user);
    }
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
        this.dirtyCursors.delete(conn.id);
        removed.push(conn);
      }
    }
    for (const conn of removed) effects.push(...this.subCountUpdatesFor(conn));
    effects.push(...this.broadcastPresence(null));
    effects.push(...this.reconcileAlarm());
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

  private endSession(
    reason: "host-stopped" | "host-gone" | "expired",
    now: number,
  ): Effect[] {
    if (
      !Number.isSafeInteger(now) ||
      now < 0 ||
      !Number.isSafeInteger(now + ENDED_TOMBSTONE_RETENTION_MS)
    ) {
      return [];
    }
    this.s.ended = reason;
    this.s.endedAt = now;
    this.s.hostDisconnectedAt = null;
    const cleanupAt = now + ENDED_TOMBSTONE_RETENTION_MS;
    this.scheduledAlarmAt = cleanupAt;
    const effects: Effect[] = [
      { kind: "persist" },
      { kind: "setAlarm", at: cleanupAt },
    ];
    for (const conn of [...this.conns.values()]) {
      effects.push(
        { kind: "send", to: conn.id, msg: { t: "session-ended", reason } },
        { kind: "close", to: conn.id, code: 1000, reason: "session ended" },
      );
      this.conns.delete(conn.id);
      this.dirtyCursors.delete(conn.id);
    }
    return effects;
  }

  // -------------------------------------------------------------------------
  // Chat + cursors

  private chat(
    conn: Conn,
    text: string,
    bubble: CursorPos | undefined,
    now: number,
  ): Effect[] {
    const trimmed = truncateUtf8(text.trim(), CHAT_TEXT_LIMIT);
    if (!trimmed) return [];
    if (!this.consumeSocketRate(conn, "chat", CHAT_RATE_LIMIT_PER_SOCKET, now)) {
      return this.rateLimitedOnce(conn, "chat");
    }
    if (!this.consumeRoomRate("chat", CHAT_RATE_LIMIT_PER_ROOM, now)) {
      return this.rateLimitedOnce(conn, "chat");
    }
    const scrubbedBubble =
      bubble &&
      isCursorPos(bubble) &&
      this.isCurrentTerminalPane(bubble.ws, bubble.pane)
        ? parseCursorPos(bubble) ?? undefined
        : undefined;
    const msg: ChatMessage = {
      id: crypto.randomUUID(),
      user: conn.user,
      text: trimmed,
      ts: now,
      ...(scrubbedBubble ? { bubble: scrubbedBubble } : {}),
    };
    this.s.chat.push(msg);
    this.chatBytes += serializedBytes(msg) + (this.s.chat.length > 1 ? 1 : 0);
    this.trimChatHistory();
    return [{ kind: "persist" }, ...this.broadcastActive({ t: "chat", msg }, null)];
  }

  private cursorBroadcast(conn: Conn, pos: CursorPos | null, now: number): Effect[] {
    const scrubbed =
      pos && isCursorPos(pos) && this.isCurrentTerminalPane(pos.ws, pos.pane)
        ? parseCursorPos(pos)
        : null;
    const eligible = this.consumeCursorBudget(conn, now);
    const existing = this.dirtyCursors.get(conn.id);
    this.dirtyCursors.set(conn.id, {
      pos: scrubbed,
      eligibleAt: eligible
        ? now
        : Math.max(
            existing?.eligibleAt ?? now,
            conn.cursorWindowStartedAt + CURSOR_RATE_WINDOW_MS,
          ),
    });
    const effects = this.drainCursorQueue(now);
    effects.push(...this.reconcileAlarm());
    return effects;
  }

  // -------------------------------------------------------------------------
  // Helpers

  private consumeCursorBudget(conn: Conn, now: number): boolean {
    if (!Number.isFinite(now)) return false;
    if (
      now < conn.cursorWindowStartedAt ||
      now >= conn.cursorWindowStartedAt + CURSOR_RATE_WINDOW_MS
    ) {
      conn.cursorWindowStartedAt = now;
      conn.cursorEventsInWindow = 0;
    }
    if (conn.cursorEventsInWindow >= CURSOR_RATE_LIMIT) return false;
    conn.cursorEventsInWindow += 1;
    return true;
  }

  private resetCursorRoomWindow(now: number): void {
    if (
      now < this.cursorRoomWindowStartedAt ||
      now >= this.cursorRoomWindowStartedAt + CURSOR_RATE_WINDOW_MS
    ) {
      this.cursorRoomWindowStartedAt = now;
      this.cursorSourceBroadcastsInWindow = 0;
      this.cursorRecipientDeliveriesInWindow = 0;
    }
  }

  /** Each dirty sender appears at most once in insertion order. A blocked
   * sender is moved to the tail, so the next window drains round-robin and
   * delivers only that sender's latest coalesced position. */
  private drainCursorQueue(now: number): Effect[] {
    this.resetCursorRoomWindow(now);
    const effects: Effect[] = [];
    const candidates = this.dirtyCursors.size;
    for (let index = 0; index < candidates; index += 1) {
      const next = this.dirtyCursors.entries().next().value as
        | [ConnId, DirtyCursor]
        | undefined;
      if (!next) break;
      const [id, dirty] = next;
      this.dirtyCursors.delete(id);
      const conn = this.conns.get(id);
      if (!conn) continue;
      if (dirty.eligibleAt > now) {
        this.dirtyCursors.set(id, dirty);
        continue;
      }
      const recipients = [...this.conns.values()].filter(
        (candidate) =>
          candidate.id !== id && (candidate.isHost || candidate.active),
      );
      if (recipients.length === 0) continue;
      if (
        this.cursorSourceBroadcastsInWindow >= CURSOR_ROOM_SOURCE_LIMIT ||
        recipients.length >
          CURSOR_ROOM_DELIVERY_LIMIT - this.cursorRecipientDeliveriesInWindow
      ) {
        this.dirtyCursors.set(id, {
          ...dirty,
          eligibleAt: Math.max(
            dirty.eligibleAt,
            this.cursorRoomWindowStartedAt + CURSOR_RATE_WINDOW_MS,
          ),
        });
        continue;
      }
      this.cursorSourceBroadcastsInWindow += 1;
      this.cursorRecipientDeliveriesInWindow += recipients.length;
      const pos =
        dirty.pos && this.isCurrentTerminalPane(dirty.pos.ws, dirty.pos.pane)
          ? dirty.pos
          : null;
      for (const recipient of recipients) {
        effects.push({
          kind: "send",
          to: recipient.id,
          msg: { t: "cursor", user: conn.user, pos },
        });
      }
    }
    return effects;
  }

  private desiredAlarmAt(): number | null {
    const cleanupAt = this.tombstoneCleanupAt();
    if (cleanupAt !== null) return cleanupAt;
    let desired =
      this.s.hostDisconnectedAt === null
        ? null
        : this.s.hostDisconnectedAt + HOST_GRACE_MS;
    for (const dirty of this.dirtyCursors.values()) {
      if (desired === null || dirty.eligibleAt < desired) desired = dirty.eligibleAt;
    }
    return desired;
  }

  private tombstoneCleanupAt(): number | null {
    return this.s.ended !== null && this.s.endedAt !== null
      ? this.s.endedAt + ENDED_TOMBSTONE_RETENTION_MS
      : null;
  }

  private reconcileAlarm(): Effect[] {
    const desired = this.desiredAlarmAt();
    if (desired === this.scheduledAlarmAt) return [];
    this.scheduledAlarmAt = desired;
    return desired === null
      ? [{ kind: "clearAlarm" }]
      : [{ kind: "setAlarm", at: desired }];
  }

  private consumeSocketRate(
    conn: Conn,
    kind: "chat" | "input" | "sub",
    limit: number,
    now: number,
  ): boolean {
    const startedKey = `${kind}WindowStartedAt` as const;
    const eventsKey = `${kind}EventsInWindow` as const;
    const notifiedKey = `${kind}RateLimitNotified` as const;
    if (
      now < conn[startedKey] ||
      now >= conn[startedKey] + APPLICATION_RATE_WINDOW_MS
    ) {
      conn[startedKey] = now;
      conn[eventsKey] = 0;
      conn[notifiedKey] = false;
    }
    if (conn[eventsKey] >= limit) return false;
    conn[eventsKey] += 1;
    return true;
  }

  private consumeRoomRate(
    kind: "chat" | "input" | "sub",
    limit: number,
    now: number,
  ): boolean {
    const startedKey = `${kind}RoomWindowStartedAt` as const;
    const eventsKey = `${kind}RoomEventsInWindow` as const;
    if (
      now < this[startedKey] ||
      now >= this[startedKey] + APPLICATION_RATE_WINDOW_MS
    ) {
      this[startedKey] = now;
      this[eventsKey] = 0;
    }
    if (this[eventsKey] >= limit) return false;
    this[eventsKey] += 1;
    return true;
  }

  private rateLimitedOnce(conn: Conn, kind: "chat" | "input" | "sub"): Effect[] {
    const notifiedKey = `${kind}RateLimitNotified` as const;
    if (conn[notifiedKey]) return [];
    conn[notifiedKey] = true;
    return [
      {
        kind: "send",
        to: conn.id,
        msg: {
          t: "error",
          code: RATE_LIMIT_CLOSE_REASON,
          message: "rate limit exceeded",
        },
      },
    ];
  }

  private trimChatHistory(): void {
    while (
      this.s.chat.length > 0 &&
      (this.s.chat.length > CHAT_HISTORY_LIMIT || this.chatBytes > CHAT_HISTORY_BYTE_LIMIT)
    ) {
      const removed = this.s.chat.shift();
      if (removed) {
        this.chatBytes -= serializedBytes(removed) + (this.s.chat.length > 0 ? 1 : 0);
      }
    }
    if (this.chatBytes < 2) this.chatBytes = 2;
  }

  private hostError(code: string, message: string): Effect[] {
    const host = this.hostConn();
    return host ? [{ kind: "send", to: host.id, msg: { t: "error", code, message } }] : [];
  }

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
    const snapshot: SessionSnapshot = {
      t: "session-state",
      proto: PROTO_VERSION,
      shared: this.s.shared,
      layouts: this.s.layouts,
      participants: this.participants(),
      chat: [...this.s.chat],
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
    // Snapshot construction is the only place where several individually
    // bounded persisted collections meet. If their combined JSON reaches the
    // server ceiling, omit oldest chat from this snapshot only until it fits.
    // Persisted history remains intact for later, smaller snapshots.
    let snapshotBytes = serializedBytes(snapshot);
    while (snapshot.chat.length > 0 && snapshotBytes >= MAX_SERVER_JSON_FRAME_BYTES) {
      const removed = snapshot.chat.shift();
      if (removed) {
        snapshotBytes -= serializedBytes(removed) + (snapshot.chat.length > 0 ? 1 : 0);
      }
    }
    return snapshot;
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

  private isCurrentTerminalPane(ws: string, pane: string): boolean {
    return this.isSharedWorkspace(ws) && isCurrentTerminalPane(this.s.layouts, ws, pane);
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

function serializedBytes(value: unknown): number {
  return utf8ByteLength(JSON.stringify(value));
}

function serializedArrayBytes(values: readonly unknown[]): number {
  let total = 2 + Math.max(0, values.length - 1);
  for (const value of values) total += serializedBytes(value);
  return total;
}

function truncateUtf8(value: string, maxBytes: number): string {
  if (value.length <= maxBytes && utf8ByteLength(value) <= maxBytes) return value;
  let out = "";
  let bytes = 0;
  for (const codepoint of value) {
    const size = utf8ByteLength(codepoint);
    if (bytes + size > maxBytes) break;
    out += codepoint;
    bytes += size;
  }
  return out;
}
