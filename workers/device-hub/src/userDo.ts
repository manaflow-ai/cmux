import { DurableObject } from "cloudflare:workers";
import { base64Decode, isValidDeviceKey, keyFingerprint, lowSHex } from "./crypto";
import { DEVICE_ID, REPLAY_WINDOW_MS, checkDeviceSignature, readDeviceHeaders } from "./deviceAuth";
import { relayEntitlement } from "./billing";
import { HOST_RELAY_HEADER, ORIGIN_HEADER, SCOPE_HEADER, SESSION_DEVICE_HEADER, STACK_TOKEN_HEADER, USER_HEADER, type Env } from "./env";
import { ApiError, badRequest, errorResponse, json, notFound } from "./errors";
import { internalCall, why } from "./internalCall";
import { REATTACH_TTL_S, TICKET_TTL_S, type Scope, mintTicket } from "./tickets";
import { type IceServer, mintTurn } from "./turn";

/** Who is calling: the hub user, the public origin, and the Stack token for the billing lookup (never stored). */
interface CallContext {
  userId: string;
  origin: string;
  stackToken: string | null;
  /**
   * `host`: a device-key renewal session, which may only serve this device as a host. `machine`:
   * a joined machine's sign-in (index.ts authMachine), which may also register and share it, never
   * anchor it: it renews only by signing in again, which asks cmux-platform each time.
   */
  scope: "full" | "host" | "machine";
  /** A host session's cmux relay entitlement, as recorded at its last anchor. */
  hostRelay: boolean;
}

/** How long an anchor lets a device renew its own host session (PROTOCOL.md, Device renewal). */
export const ANCHOR_TTL_MS = 30 * 24 * 3600 * 1000;
/** How long the billing answer recorded at an anchor stands for a host session's cmux relay. */
export const ANCHOR_RELAY_TTL_MS = 24 * 3600 * 1000;

/**
 * The platforms a device registers as. A Linux desktop hosts like a Mac (`cmux-rd linux-host`);
 * a Windows PC registers and stays online with its device key (`cmux-rd windows-host`).
 */
export type DevicePlatform = "macos" | "ios" | "linux" | "windows";
export const DEVICE_PLATFORMS: readonly DevicePlatform[] = ["macos", "ios", "linux", "windows"];
/** The platforms that host a screen: only these are anchored for device-key renewal. */
export const HOST_PLATFORMS: readonly DevicePlatform[] = ["macos", "linux", "windows"];
export function isDevicePlatform(value: unknown): value is DevicePlatform {
  return (DEVICE_PLATFORMS as readonly unknown[]).includes(value);
}
/** The share approval format the hub carries (acpmux `share_approval::VERSION`). */
export const SHARE_APPROVAL_VERSION = "cmux.share-approval.v1";

export type PermissionScope = "none" | "ask" | "view" | "full";
type SessionState = "pending" | "approved" | "live" | "ended";

interface DeviceRow {
  id: string;
  name: string;
  platform: DevicePlatform;
  signing_key: string;
  agreement_key: string;
  created_at: number;
  last_seen_at: number;
  removed_at: number | null;
  mac_screen_shared: number;
  /** The Mac it runs on, as its first registration named it (`machine`); null when it named none. Never listed. */
  machine: string | null;
  /** 1 once the switch was set on purpose (`PUT .../mac-screen`): a join never changes it after. */
  mac_screen_chosen: number;
  /** The device's own screen sharing status (`cmux.screen-share.status/1`), JSON; null until reported. */
  screen_share: string | null;
}

interface SessionRow {
  id: string;
  viewer_id: string;
  host_id: string;
  scope: Scope;
  state: SessionState;
  created_at: number;
  started_at: number | null;
  ended_at: number | null;
  end_reason: string | null;
  path: string | null;
  /** The session this one replaced (`POST /v1/sessions/:id/move`); null for one started fresh. */
  moved_from: string | null;
  /** The last billing answer a full (Stack-token) caller got for this session: 1 paid, 0 free, null never read. */
  relay_paid: number | null;
  /** When that answer was read (ms); it covers the session's host end for ANCHOR_RELAY_TTL_MS. */
  relay_read_at: number | null;
}

interface RelayRow {
  id: string;
  owner_kind: string;
  owner_id: string;
  name: string;
  urls: string;
  auth_mode: string;
  sealed: string;
  enabled: number;
  priority: number;
  updated_at: number;
}

export const PENDING_TTL_MS = 5 * 60 * 1000;
/** How long a device may stay disconnected before its sessions end (reason peer_offline). */
export const OFFLINE_GRACE_MS = 30_000;
/**
 * A socket close reported by the Session DO is provisional for this long: an
 * authoritative end (/end, revoke, removal, sharing off, sign-out) that arrives
 * in the window wins. Env CLOSE_GRACE_MS overrides it.
 */
export const CLOSE_GRACE_MS = 3_000;
/**
 * A device socket that sends nothing for this long is gone, FIN or not (a Mac
 * that slept, a phone that lost signal, a killed app): it stops counting as
 * online and is closed with SILENT_CLOSE. The apps ping every 30 s
 * (DeviceHubSocket.pingInterval), so this is two missed pings plus 15 s.
 */
export const SILENT_MS = 75_000;
/** Close code for a socket closed for silence. Not terminal: the app reconnects. */
export const SILENT_CLOSE = 4004;
const PERMISSION_SCOPES: PermissionScope[] = ["none", "ask", "view", "full"];
/**
 * The permission a host gives a device with no stored row: Full Control. Every device in this
 * Durable Object is signed in to the same account (one UserDO per user), so a session between them
 * is the person reaching their own machine, and nobody clicks Allow on the host (Leo, 2026-11-16,
 * ask-da398bba67). A permission the person set (`none`, `ask`, `view`) is stored and always wins.
 * Narrow it to `view` here to keep control behind a prompt.
 */
export const OWN_DEVICE_DEFAULT: PermissionScope = "full";
const RELAY_ID = /^[A-Za-z0-9_-]{1,64}$/;
const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PING = JSON.stringify({ type: "ping" });
const PONG = JSON.stringify({ type: "pong" });

interface WireTicket {
  sessionId: string;
  ticket: string;
  signalURL: string;
  ice: IceServer[];
  peer: { id: string; name: string; signingKey: string };
  role: "viewer" | "host";
  scope: Scope;
  /**
   * Whose devices the session joins, as this hub authenticated them: `user` is one account, both
   * devices signed in to it. The host decides from this, never from anything the viewer sends,
   * whether the session is the person's own; a later team or shared-access owner says otherwise.
   */
  ownerKind: "user";
  reattach?: boolean;
  /**
   * Set on a session the viewer did not ask for itself (its host pushed the screen, or the share
   * was moved): the viewer's app opens it with no click. `movedFrom` is the session it replaced, or null.
   */
  pushed?: true;
  movedFrom?: string | null;
}

/** How a session reached a viewer that did not ask for it: pushed by its host (`movedFrom` null), or moved. */
interface Pushed {
  movedFrom: string | null;
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS devices(
  id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL,
  signing_key TEXT NOT NULL, agreement_key TEXT NOT NULL,
  created_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL,
  removed_at INTEGER, mac_screen_shared INTEGER NOT NULL DEFAULT 0,
  name_pinned INTEGER NOT NULL DEFAULT 0,
  owner_kind TEXT NOT NULL DEFAULT 'user', owner_id TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS permissions(
  host_id TEXT NOT NULL, viewer_id TEXT NOT NULL, scope TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  owner_kind TEXT NOT NULL DEFAULT 'user', owner_id TEXT NOT NULL DEFAULT '',
  PRIMARY KEY(host_id, viewer_id));
CREATE TABLE IF NOT EXISTS relays(
  id TEXT PRIMARY KEY, owner_kind TEXT NOT NULL, owner_id TEXT NOT NULL,
  name TEXT NOT NULL, urls TEXT NOT NULL, auth_mode TEXT NOT NULL,
  sealed TEXT NOT NULL, enabled INTEGER NOT NULL, priority INTEGER NOT NULL,
  updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sessions(
  id TEXT PRIMARY KEY, viewer_id TEXT NOT NULL, host_id TEXT NOT NULL,
  scope TEXT NOT NULL, state TEXT NOT NULL, created_at INTEGER NOT NULL,
  started_at INTEGER, ended_at INTEGER, end_reason TEXT, path TEXT,
  owner_kind TEXT NOT NULL DEFAULT 'user', owner_id TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS audit(
  id TEXT PRIMARY KEY, ts INTEGER NOT NULL, event TEXT NOT NULL,
  viewer_id TEXT, host_id TEXT, scope TEXT, session_id TEXT, detail TEXT,
  duration_s INTEGER, device_id TEXT,
  owner_kind TEXT NOT NULL DEFAULT 'user', owner_id TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS audit_ts ON audit(ts);
CREATE TABLE IF NOT EXISTS offline(device_id TEXT PRIMARY KEY, since INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS closing(session_id TEXT PRIMARY KEY, reason TEXT NOT NULL, at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS replay_msg(
  device_id TEXT NOT NULL, digest TEXT NOT NULL,
  expires_at INTEGER NOT NULL, PRIMARY KEY(device_id, digest));
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS anchors(device_id TEXT PRIMARY KEY, anchored_at INTEGER NOT NULL, relay_paid INTEGER NOT NULL DEFAULT 0);
DROP TABLE IF EXISTS replay;
`;

/** Columns added after v1 shipped: added in place to existing User DOs. */
const ADDED_COLUMNS: [string, string, string][] = [
  ["devices", "name_pinned", "INTEGER NOT NULL DEFAULT 0"],
  ["devices", "owner_kind", "TEXT NOT NULL DEFAULT 'user'"],
  ["devices", "owner_id", "TEXT NOT NULL DEFAULT ''"],
  ["devices", "mac_screen_chosen", "INTEGER NOT NULL DEFAULT 0"],
  ["devices", "screen_share", "TEXT"],
  ["permissions", "owner_kind", "TEXT NOT NULL DEFAULT 'user'"],
  ["permissions", "owner_id", "TEXT NOT NULL DEFAULT ''"],
  ["sessions", "owner_kind", "TEXT NOT NULL DEFAULT 'user'"],
  ["sessions", "owner_id", "TEXT NOT NULL DEFAULT ''"],
  ["audit", "device_id", "TEXT"],
  ["audit", "owner_kind", "TEXT NOT NULL DEFAULT 'user'"],
  ["audit", "owner_id", "TEXT NOT NULL DEFAULT ''"],
  ["devices", "machine", "TEXT"],
  ["sessions", "moved_from", "TEXT"],
  ["sessions", "relay_paid", "INTEGER"],
  ["sessions", "relay_read_at", "INTEGER"],
];

/** A registration's `machine`: the lowercase hex SHA-256 the app derives from the Mac's hardware id. */
const MACHINE = /^[0-9a-f]{64}$/;
const OWNED_TABLES = ["devices", "permissions", "sessions", "audit"];

/** What a User DO socket carries across hibernation. */
interface SocketState {
  /** The server closed it (sign-out, removal, replacement, silence). */
  closed?: boolean;
  /** When it was accepted (ms). */
  openedAt?: number;
  /** When the device last sent a frame the auto-response did not answer (ms). */
  heardAt?: number;
}

function rank(scope: string): number {
  return scope === "full" ? 2 : scope === "view" ? 1 : 0;
}

function publicDevice(d: DeviceRow, online: boolean) {
  return {
    id: d.id,
    name: d.name,
    platform: d.platform,
    signingKey: d.signing_key,
    agreementKey: d.agreement_key,
    createdAt: d.created_at,
    lastSeenAt: d.last_seen_at,
    macScreenShared: d.mac_screen_shared === 1,
    screenShare: screenShareOf(d),
    online,
  };
}

/** The states of `cmux.screen-share.status/1` (acpmux `screen_share.rs`). */
const SCREEN_SHARE_STATES = ["granted", "needs_grant", "not_installed", "unsupported"];
const SCREEN_SHARE_GRANTS = ["screen_recording", "accessibility"];
const SCREEN_SHARE_SESSIONS = ["this_user", "other_user", "nobody", "unknown"];

function screenShareOf(d: DeviceRow): Record<string, unknown> | null {
  if (!d.screen_share) return null;
  try {
    return JSON.parse(d.screen_share) as Record<string, unknown>;
  } catch {
    return null;
  }
}

/**
 * A device's report of its own screen sharing status, kept to the fields a row reads: `state`,
 * `missing`, `holder`, `session`, `osVersion`, `checkedAtMs`, `detail`. Anything else is refused.
 */
export function screenShareReport(body: Record<string, unknown>): Record<string, unknown> {
  const state = body.state;
  if (typeof state !== "string" || !SCREEN_SHARE_STATES.includes(state)) throw badRequest(`state must be one of ${SCREEN_SHARE_STATES.join(", ")}`);
  const missing = body.missing ?? [];
  if (!Array.isArray(missing) || missing.some((g) => typeof g !== "string" || !SCREEN_SHARE_GRANTS.includes(g)) || new Set(missing).size !== missing.length) {
    throw badRequest(`missing must list each of ${SCREEN_SHARE_GRANTS.join(", ")} at most once`);
  }
  if ((state === "needs_grant") !== missing.length > 0) throw badRequest("missing is non-empty exactly when state is needs_grant");
  const session = body.session ?? "unknown";
  if (typeof session !== "string" || !SCREEN_SHARE_SESSIONS.includes(session)) throw badRequest(`session must be one of ${SCREEN_SHARE_SESSIONS.join(", ")}`);
  const text = (v: unknown, field: string, max: number) => {
    if (v == null) return undefined;
    if (typeof v !== "string" || v.length > max) throw badRequest(`${field} must be a string of at most ${max} characters`);
    return v;
  };
  const checkedAtMs = body.checkedAtMs;
  if (!Number.isSafeInteger(checkedAtMs) || (checkedAtMs as number) < 0) throw badRequest("checkedAtMs must be a time in ms");
  return {
    schema: "cmux.screen-share.status/1",
    state,
    missing,
    holder: text(body.holder, "holder", 100),
    session,
    osVersion: text(body.osVersion, "osVersion", 64),
    checkedAtMs,
    detail: text(body.detail, "detail", 300),
  };
}

function publicSession(s: SessionRow) {
  return { id: s.id, state: s.state, scope: s.scope, viewerId: s.viewer_id, hostId: s.host_id, createdAt: s.created_at, endReason: s.end_reason };
}

function str(v: unknown, field: string, max = 200): string {
  if (typeof v !== "string" || v.length === 0 || v.length > max) throw badRequest(`${field} must be a string of 1-${max} characters`);
  return v;
}

/**
 * One per user (idFromName(userId)). The single writer of the user's devices,
 * permissions, relays, sessions and audit log. Every device keeps a hibernating
 * WebSocket here, tagged with its device id.
 */
export class UserDO extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(SCHEMA);
    for (const [table, col, def] of ADDED_COLUMNS) {
      const cols = this.sql.exec(`PRAGMA table_info(${table})`).toArray().map((c) => c.name);
      if (!cols.includes(col)) this.sql.exec(`ALTER TABLE ${table} ADD COLUMN ${col} ${def}`);
    }
    const owner = this.sql.exec("SELECT v FROM meta WHERE k = 'user_id'").toArray()[0];
    if (owner) this.setOwner(owner.v as string);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
    // Sockets restored from hibernation need the silence check armed: a socket
    // accepted before this check existed has no clock until a sweep stamps it.
    if (ctx.getWebSockets().length > 0) void ctx.blockConcurrencyWhile(() => this.scheduleAlarm());
  }

  // ---- owner (v1: always the user; team sharing later adds 'team' rows) ----

  private ownerId = "";

  /** Records the user this DO belongs to and backfills rows written before owner columns existed. */
  private setOwner(userId: string) {
    if (this.ownerId === userId) return;
    this.ownerId = userId;
    this.sql.exec("INSERT INTO meta(k, v) VALUES ('user_id', ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", userId);
    for (const t of OWNED_TABLES) this.sql.exec(`UPDATE ${t} SET owner_kind = 'user', owner_id = ? WHERE owner_id = ''`, userId);
  }

  // ---- storage helpers ----

  private device(id: string): DeviceRow | null {
    return (this.sql.exec("SELECT * FROM devices WHERE id = ?", id).toArray()[0] as unknown as DeviceRow) ?? null;
  }

  private liveDevice(id: string): DeviceRow {
    const d = this.device(id);
    if (!d || d.removed_at !== null) throw notFound("device not found");
    return d;
  }

  private session(id: string): SessionRow | null {
    return (this.sql.exec("SELECT * FROM sessions WHERE id = ?", id).toArray()[0] as unknown as SessionRow) ?? null;
  }

  /**
   * The host's answer about the viewer, read as an answer about its Mac: the newest permission
   * between any live device of the host's Mac and any live device of the viewer's Mac. A Mac
   * gets a new device id for each tagged build (its own Keychain items) and whenever its
   * identity renews; an Always for that Mac must not end with the id it was given to.
   */
  private permission(hostId: string, viewerId: string): PermissionScope {
    const hosts = this.sameMachine(hostId);
    const viewers = this.sameMachine(viewerId);
    const row = this.sql
      .exec(
        `SELECT scope FROM permissions WHERE host_id IN (${hosts.map(() => "?").join(",")}) AND viewer_id IN (${viewers.map(() => "?").join(",")}) ORDER BY updated_at DESC LIMIT 1`,
        ...hosts,
        ...viewers,
      )
      .toArray()[0];
    return (row?.scope as PermissionScope | undefined) ?? OWN_DEVICE_DEFAULT;
  }

  /**
   * `id` and the other live devices on the same Mac (the `machine` their first registration
   * named, and the same platform); only `id` when it named none.
   */
  private sameMachine(id: string): string[] {
    const d = this.device(id);
    if (!d?.machine) return [id];
    const ids = this.sql
      .exec("SELECT id FROM devices WHERE machine = ? AND platform = ? AND removed_at IS NULL", d.machine, d.platform)
      .toArray()
      .map((r) => r.id as string);
    return ids.includes(id) ? ids : [id, ...ids];
  }

  /**
   * Live sockets only. A socket the server closed (sign-out, removal,
   * replacement) stays in getWebSockets until the client answers the close
   * frame, which an app that drops its socket never does.
   */
  private liveSockets(deviceId: string): WebSocket[] {
    const now = Date.now();
    return this.ctx.getWebSockets(deviceId).filter((ws) => this.isLive(ws, now));
  }

  /** Open, not closed by the server, and heard from within SILENT_MS (a socket from before openedAt existed counts until the next sweep stamps it). */
  private isLive(ws: WebSocket, now: number): boolean {
    if (ws.readyState !== WebSocket.OPEN) return false;
    const st = this.socketState(ws);
    if (st.closed) return false;
    return st.openedAt === undefined || this.lastHeard(ws, st) + SILENT_MS > now;
  }

  private socketState(ws: WebSocket): SocketState {
    return (ws.deserializeAttachment() as SocketState | null) ?? {};
  }

  /** The last sign of life: the open, the last ping (answered by the auto-response without waking us), or any other frame. */
  private lastHeard(ws: WebSocket, st = this.socketState(ws)): number {
    const ping = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? 0;
    return Math.max(st.openedAt ?? 0, st.heardAt ?? 0, ping);
  }

  private online(deviceId: string): boolean {
    return this.liveSockets(deviceId).length > 0;
  }

  /** Closes a device's sockets and marks them closed so they stop counting as online at once. */
  private closeSockets(deviceId: string, code: number, reason: string) {
    for (const ws of this.ctx.getWebSockets(deviceId)) {
      try {
        ws.serializeAttachment({ ...this.socketState(ws), closed: true });
        ws.close(code, reason);
      } catch {
        // already closed
      }
    }
  }

  private audit(
    event: string,
    f: { viewerId?: string | null; hostId?: string | null; deviceId?: string | null; scope?: string | null; sessionId?: string | null; detail?: string | null; durationS?: number | null },
  ) {
    this.sql.exec(
      "INSERT INTO audit(id, ts, event, viewer_id, host_id, scope, session_id, detail, duration_s, device_id, owner_kind, owner_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'user', ?)",
      crypto.randomUUID(),
      Date.now(),
      event,
      f.viewerId ?? null,
      f.hostId ?? null,
      f.scope ?? null,
      f.sessionId ?? null,
      f.detail ?? null,
      f.durationS ?? null,
      f.deviceId ?? null,
      this.ownerId,
    );
  }

  private send(deviceId: string, msg: unknown) {
    const text = JSON.stringify(msg);
    for (const ws of this.ctx.getWebSockets(deviceId)) {
      try {
        ws.send(text);
      } catch {
        // closing socket
      }
    }
  }

  private broadcast(msg: unknown, except?: string) {
    const text = JSON.stringify(msg);
    for (const ws of this.ctx.getWebSockets()) {
      if (except && this.ctx.getTags(ws).includes(except)) continue;
      try {
        ws.send(text);
      } catch {
        // closing socket
      }
    }
  }

  // ---- request entry ----

  async fetch(request: Request): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (url.pathname.startsWith("/internal/")) return await this.internal(url.pathname, request);
      const userId = request.headers.get(USER_HEADER);
      if (!userId) throw new ApiError(401, "unauthorized", "missing user");
      this.setOwner(userId);
      const origin = request.headers.get(ORIGIN_HEADER) ?? url.origin;
      const stackToken = request.headers.get(STACK_TOKEN_HEADER);
      const header = request.headers.get(SCOPE_HEADER);
      const scope = header === "host" || header === "machine" ? header : "full";
      const hostRelay = request.headers.get(HOST_RELAY_HEADER) === "1";
      const body = new Uint8Array(await request.arrayBuffer());
      const now = Date.now();
      const h = readDeviceHeaders(request.headers, now);
      // A host or machine session is one device's: every request it carries is signed by that device.
      if (scope !== "full" && request.headers.get(SESSION_DEVICE_HEADER) !== h.id) {
        throw new ApiError(403, "host_scope", "this session belongs to another device");
      }
      if (request.method === "POST" && url.pathname === "/v1/devices") {
        // A host session updates its own registration, never makes a device.
        if (scope === "host" && !this.device(h.id)) throw new ApiError(403, "host_scope", "a host session cannot register a new device");
        const registered = await this.register(request, url, body, h, now, scope);
        if (scope === "machine") this.dropMachineAnchor(h.id);
        return registered;
      }
      const existing = this.device(h.id);
      if (!existing) throw new ApiError(401, "bad_signature", "unknown device");
      if (existing.removed_at !== null) throw new ApiError(403, "device_removed", "this device was removed");
      await checkDeviceSignature(existing.signing_key, request.method, url, body, h);
      this.burnSignature(h.id, h.ts, h.sig, now);
      this.sql.exec("UPDATE devices SET last_seen_at = ? WHERE id = ?", now, h.id);
      if (scope === "machine") this.dropMachineAnchor(h.id);
      const me = { ...existing, last_seen_at: now };
      return await this.dispatch(request, url, body, me, { userId, origin, stackToken, scope, hostRelay });
    } catch (err) {
      return errorResponse(err);
    }
  }

  /** Burns (timestamp, low-S signature) for the replay window. */
  private burnSignature(deviceId: string, ts: string, sig: string, now: number) {
    const digest = `${ts}:${lowSHex(sig)}`;
    this.sql.exec("DELETE FROM replay_msg WHERE expires_at <= ?", now);
    const seen = this.sql.exec("SELECT 1 FROM replay_msg WHERE device_id = ? AND digest = ?", deviceId, digest).toArray();
    if (seen.length > 0) throw new ApiError(401, "replay", "request was already used");
    this.sql.exec("INSERT INTO replay_msg(device_id, digest, expires_at) VALUES (?, ?, ?)", deviceId, digest, now + REPLAY_WINDOW_MS);
  }

  private parse(body: Uint8Array): Record<string, unknown> {
    try {
      const v = JSON.parse(new TextDecoder().decode(body));
      if (v && typeof v === "object" && !Array.isArray(v)) return v as Record<string, unknown>;
    } catch {
      // fall through
    }
    throw badRequest("body must be a JSON object");
  }

  private async register(request: Request, url: URL, raw: Uint8Array, h: { id: string; ts: string; sig: string }, now: number, scope: CallContext["scope"]): Promise<Response> {
    const body = this.parse(raw);
    if (body.id !== h.id) throw badRequest("id must equal X-Device-Id");
    if (body.shareByJoin !== undefined && typeof body.shareByJoin !== "boolean") throw badRequest("shareByJoin must be a boolean");
    const name = str(body.name, "name", 100);
    if (!isDevicePlatform(body.platform)) {
      throw badRequest("platform must be macos, ios, linux or windows");
    }
    if (!(await isValidDeviceKey(body.signingKey))) throw badRequest("signingKey must be a base64 X9.63 P-256 key");
    if (!(await isValidDeviceKey(body.agreementKey))) throw badRequest("agreementKey must be a base64 X9.63 P-256 key");
    const signingKey = body.signingKey as string;
    const agreementKey = body.agreementKey as string;
    if (body.machine !== undefined && (typeof body.machine !== "string" || !MACHINE.test(body.machine))) {
      throw badRequest("machine must be 64 lowercase hex digits");
    }
    const machine = (body.machine as string | undefined) ?? null;
    await checkDeviceSignature(signingKey, request.method, url, raw, h);
    const existing = this.device(h.id);
    if (existing?.removed_at != null) throw new ApiError(403, "device_removed", "this device was removed; register a new device id");
    if (existing && existing.signing_key !== signingKey) throw new ApiError(409, "device_key_mismatch", "device id is registered with another signing key");
    this.burnSignature(h.id, h.ts, h.sig, now);
    if (existing) {
      // The first machine a device named stays: a later registration cannot move it to another Mac.
      this.sql.exec(
        "UPDATE devices SET name = CASE WHEN name_pinned = 1 THEN name ELSE ? END, platform = ?, agreement_key = ?, last_seen_at = ?, machine = COALESCE(machine, ?) WHERE id = ?",
        name,
        body.platform,
        agreementKey,
        now,
        machine,
        h.id,
      );
    } else {
      this.sql.exec(
        "INSERT INTO devices(id, name, platform, signing_key, agreement_key, created_at, last_seen_at, removed_at, mac_screen_shared, owner_kind, owner_id, machine) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0, 'user', ?, ?)",
        h.id,
        name,
        body.platform,
        signingKey,
        agreementKey,
        now,
        now,
        this.ownerId,
        machine,
      );
      this.audit("device_added", { deviceId: h.id, detail: `${h.id} ${name}` });
    }
    this.joinDefault(h.id, scope, body.shareByJoin === true);
    this.broadcast({ type: "devices.changed" });
    return json({ device: publicDevice(this.device(h.id)!, this.online(h.id)) });
  }

  /**
   * Joining is the consent (design remote-screen-share-zero-touch Z4): a machine the person
   * joined from their computer registers from its own machine sign-in with `shareByJoin`, and
   * its Mac Screen sharing turns on. Only while nobody set the switch on purpose: an explicit
   * off (`PUT .../mac-screen`, from the app, the CLI or the machine) always wins, and no later
   * join or update turns it back on. A device signed in through the app (`full` scope) never
   * gets it, so a Mac that was only signed in keeps its switch off.
   */
  private joinDefault(id: string, scope: CallContext["scope"], asked: boolean) {
    if (!asked || scope !== "machine") return;
    const d = this.device(id);
    if (!d || !HOST_PLATFORMS.includes(d.platform) || d.mac_screen_chosen === 1 || d.mac_screen_shared === 1) return;
    this.sql.exec("UPDATE devices SET mac_screen_shared = 1 WHERE id = ?", id);
    this.audit("shared", { hostId: id, detail: "joined" });
  }

  private async dispatch(request: Request, url: URL, raw: Uint8Array, me: DeviceRow, c: CallContext): Promise<Response> {
    const m = request.method;
    const parts = url.pathname.split("/").filter(Boolean).slice(1); // drop "v1"
    const [a, b, d] = parts;
    const n = parts.length;
    if (c.scope === "host" && !this.hostAllowed(m, parts, me, raw)) {
      throw new ApiError(403, "host_scope", "a host session can only serve this Mac; open cmux for this change");
    }
    if (c.scope === "machine" && !this.machineAllowed(m, parts, me, raw)) {
      throw new ApiError(403, "machine_scope", "a joined machine's session can only set up and serve this machine; open cmux for this change");
    }
    if (a === "auth" && b === "device" && d === "anchor" && n === 3 && m === "POST") return this.anchor(me, c);

    if (a === "me" && n === 1 && m === "GET") {
      const plan = (await this.entitlement(c)) === "paid" ? "paid" : "free";
      return json({ userId: c.userId, plan, device: publicDevice(me, this.online(me.id)) });
    }
    if (a === "user" && b === "ws" && n === 2 && m === "GET") return await this.openSocket(request, me);
    if (a === "devices") {
      if (n === 1 && m === "GET") {
        const rows = this.sql.exec("SELECT * FROM devices WHERE removed_at IS NULL ORDER BY created_at").toArray() as unknown as DeviceRow[];
        return json({ devices: rows.map((r) => publicDevice(r, this.online(r.id))) });
      }
      if (n === 2 && m === "PATCH") return this.renameDevice(b!, this.parse(raw));
      if (n === 2 && m === "DELETE") return this.removeDevice(b!);
      if (n === 3 && d === "mac-screen" && m === "PUT") return this.setSharing(me, b!, this.parse(raw));
      if (n === 3 && d === "screen-share" && m === "PUT") return this.reportScreenShare(me, b!, this.parse(raw));
      if (n === 3 && d === "sign-out" && m === "POST") return this.signOut(me, b!);
      if (n === 3 && d === "share-approval" && m === "POST") return this.carryShareApproval(me, b!, this.parse(raw), c);
    }
    if (a === "permissions") {
      if (n === 1 && m === "GET") return this.listPermissions(url.searchParams.get("host"));
      if (n === 3 && m === "PUT") return this.setPermission(me, b!, d!, this.parse(raw));
    }
    if (a === "sessions") {
      if (n === 1 && m === "GET") return this.listSessions(me, c);
      if (n === 1 && m === "POST") return this.requestSession(me, this.parse(raw), c);
      if (n === 3 && m === "POST") {
        if (!SESSION_ID.test(b!)) throw notFound("session not found");
        if (d === "move") return this.moveSession(me, b!, this.parse(raw), c);
        if (d === "decision") return this.decide(me, b!, this.parse(raw), c);
        if (d === "reattach") return this.reattach(me, b!, c);
        if (d === "end") return this.endFromDevice(me, b!, raw.length ? this.parse(raw) : {});
        if (d === "ice") return this.ice(me, b!, c);
      }
    }
    if (a === "relays") {
      if (n === 1 && m === "GET") return this.listRelays(me);
      if (n === 2 && m === "PUT") return this.putRelay(me, b!, this.parse(raw), c.userId);
      if (n === 2 && m === "DELETE") return this.deleteRelay(b!);
    }
    if (a === "audit" && n === 1 && m === "GET") return this.listAudit(url.searchParams);
    throw notFound();
  }

  // ---- devices ----

  private async openSocket(request: Request, me: DeviceRow): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") throw new ApiError(426, "bad_request", "expected a WebSocket upgrade");
    this.closeSockets(me.id, 4000, "replaced");
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], [me.id]);
    pair[1].serializeAttachment({ openedAt: Date.now() } satisfies SocketState);
    this.sql.exec("DELETE FROM offline WHERE device_id = ?", me.id);
    // Everyone refetches, including this device: its cached list may say it is offline.
    this.broadcast({ type: "devices.changed" });
    // A request waiting on this host went to a socket it no longer has (it dropped, or this one
    // replaces it): send it again so the prompt reaches the host it waits on.
    await this.resendPendingRequests(me.id);
    // The silence check: a device that never pings after connecting goes offline at the bound.
    await this.scheduleAlarm();
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, _message: string | ArrayBuffer): Promise<void> {
    // Pings are answered by the auto-response without waking us; any other frame still says the device is there.
    const st = this.socketState(ws);
    if (!st.closed) ws.serializeAttachment({ ...st, heardAt: Date.now() } satisfies SocketState);
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, reason);
    } catch {
      // already closed
    }
    const [deviceId] = this.ctx.getTags(ws);
    if (deviceId) await this.markOffline(deviceId, ws);
    this.broadcast({ type: "devices.changed" }, deviceId);
  }

  async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    const [deviceId] = this.ctx.getTags(ws);
    const reason = `error: ${why(error)}`;
    console.warn(`device-hub: device ${deviceId ?? "?"}'s socket failed (${reason})`);
    // A failed socket the runtime still lists as open must stop counting as online,
    // or the offline alarm would see it live and drop the grace entry.
    try {
      ws.serializeAttachment({ ...this.socketState(ws), closed: true } satisfies SocketState);
      ws.close(1011, reason.slice(0, 120));
    } catch {
      // already closed
    }
    if (deviceId) await this.markOffline(deviceId, ws);
    this.broadcast({ type: "devices.changed" }, deviceId);
  }

  /**
   * Closes every socket silent for SILENT_MS: the device dropped without a FIN
   * and the transport would not say so for minutes, or ever. Its offline grace
   * counts from when it was last heard, so its sessions end in this same pass.
   */
  private async sweepSilent(now: number) {
    const gone = new Set<string>();
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.readyState !== WebSocket.OPEN) continue;
      const st = this.socketState(ws);
      if (st.closed) continue;
      if (st.openedAt === undefined) {
        // Accepted before sockets carried openedAt: start its clock now.
        ws.serializeAttachment({ ...st, openedAt: now } satisfies SocketState);
        continue;
      }
      const heard = this.lastHeard(ws, st);
      if (heard + SILENT_MS > now) continue;
      const [deviceId] = this.ctx.getTags(ws);
      const silentS = Math.round((now - heard) / 1000);
      const reason = `silent ${silentS} s: no ping within ${SILENT_MS / 1000} s`;
      console.warn(`device-hub: closing device ${deviceId ?? "?"}'s socket (${reason})`);
      try {
        ws.serializeAttachment({ ...st, closed: true } satisfies SocketState);
        ws.close(SILENT_CLOSE, reason);
      } catch {
        // already closed
      }
      if (!deviceId) continue;
      await this.markOffline(deviceId, ws, heard);
      gone.add(deviceId);
    }
    for (const deviceId of gone) this.broadcast({ type: "devices.changed" }, deviceId);
  }

  /** Starts the grace period for a device whose last socket went away (at `since`, default now). */
  private async markOffline(deviceId: string, closing: WebSocket, since = Date.now()) {
    const others = this.liveSockets(deviceId).filter((w) => w !== closing);
    if (others.length > 0) return;
    const d = this.device(deviceId);
    if (!d || d.removed_at !== null) return;
    const open = this.sql.exec("SELECT 1 FROM sessions WHERE state != 'ended' AND (viewer_id = ? OR host_id = ?) LIMIT 1", deviceId, deviceId).toArray();
    if (open.length === 0) return;
    this.sql.exec("INSERT INTO offline(device_id, since) VALUES (?, ?) ON CONFLICT(device_id) DO NOTHING", deviceId, since);
    await this.scheduleAlarm();
  }

  private closeGraceMs(): number {
    const v = Number(this.env.CLOSE_GRACE_MS);
    return Number.isFinite(v) && v >= 0 && this.env.CLOSE_GRACE_MS ? v : CLOSE_GRACE_MS;
  }

  /** The next time a live socket would pass SILENT_MS without a sign of life; null with no live socket. */
  private nextSilence(now: number): number | null {
    let next: number | null = null;
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.readyState !== WebSocket.OPEN) continue;
      const st = this.socketState(ws);
      if (st.closed) continue;
      const at = st.openedAt === undefined ? now : this.lastHeard(ws, st) + SILENT_MS;
      if (next === null || at < next) next = at;
    }
    return next;
  }

  /** One alarm serves offline grace periods, provisional socket-close ends, pending expiry and socket silence. */
  private async scheduleAlarm() {
    const off = this.sql.exec("SELECT MIN(since) AS t FROM offline").one().t as number | null;
    const close = this.sql.exec("SELECT MIN(at) AS t FROM closing").one().t as number | null;
    const pending = this.sql.exec("SELECT MIN(created_at) AS t FROM sessions WHERE state = 'pending'").one().t as number | null;
    const times = [
      off === null ? null : off + OFFLINE_GRACE_MS,
      close === null ? null : close + this.closeGraceMs(),
      pending === null ? null : pending + PENDING_TTL_MS,
      this.nextSilence(Date.now()),
    ].filter((t): t is number => t !== null);
    if (times.length === 0) return;
    const at = Math.min(...times);
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > at) await this.ctx.storage.setAlarm(at);
  }

  /** Ends the sessions of devices that stayed offline past the grace period. */
  async alarm(): Promise<void> {
    const now = Date.now();
    await this.sweepSilent(now);
    const closed = this.sql.exec("SELECT session_id, reason FROM closing WHERE at + ? <= ?", this.closeGraceMs(), now).toArray();
    for (const c of closed) {
      const s = this.session(c.session_id as string);
      this.sql.exec("DELETE FROM closing WHERE session_id = ?", c.session_id);
      if (s) await this.endSession(s, c.reason as string, "ended", false);
    }
    const expired = this.sql
      .exec("SELECT * FROM sessions WHERE state = 'pending' AND created_at + ? <= ?", PENDING_TTL_MS, now)
      .toArray() as unknown as SessionRow[];
    for (const s of expired) await this.endSession(s, "expired", "revoked", false);
    const due = this.sql.exec("SELECT device_id FROM offline WHERE since + ? <= ?", OFFLINE_GRACE_MS, now).toArray();
    for (const r of due) {
      const deviceId = r.device_id as string;
      this.sql.exec("DELETE FROM offline WHERE device_id = ?", deviceId);
      if (this.online(deviceId)) continue;
      const open = this.sql
        .exec("SELECT * FROM sessions WHERE state != 'ended' AND (viewer_id = ? OR host_id = ?)", deviceId, deviceId)
        .toArray() as unknown as SessionRow[];
      for (const s of open) await this.endSession(s, "peer_offline", "ended", true);
    }
    await this.scheduleAlarm();
  }

  private renameDevice(id: string, body: Record<string, unknown>): Response {
    this.liveDevice(id);
    const name = str(body.name, "name", 100);
    this.sql.exec("UPDATE devices SET name = ?, name_pinned = 1 WHERE id = ?", name, id);
    this.broadcast({ type: "devices.changed" });
    return json({ device: publicDevice(this.device(id)!, this.online(id)) });
  }

  private async removeDevice(id: string): Promise<Response> {
    const target = this.liveDevice(id);
    this.sql.exec("UPDATE devices SET removed_at = ?, mac_screen_shared = 0 WHERE id = ?", Date.now(), id);
    this.sql.exec("DELETE FROM anchors WHERE device_id = ?", id);
    // No permission outlives its device, as host or as viewer; the hosts that listed it hear so.
    const hosts = this.sql.exec("SELECT DISTINCT host_id FROM permissions WHERE viewer_id = ? AND host_id != ?", id, id).toArray().map((r) => r.host_id as string);
    this.sql.exec("DELETE FROM permissions WHERE host_id = ? OR viewer_id = ?", id, id);
    const open = this.sql.exec("SELECT * FROM sessions WHERE state != 'ended' AND (viewer_id = ? OR host_id = ?)", id, id).toArray() as unknown as SessionRow[];
    for (const s of open) await this.endSession(s, `device_removed:${s.viewer_id === id ? "viewer" : "host"}`, "revoked", true);
    this.audit("device_removed", { deviceId: id, detail: `${id} ${target.name}` });
    this.closeSockets(id, 4001, "device removed");
    this.broadcast({ type: "devices.changed" });
    for (const hostId of hosts) this.broadcast({ type: "permissions.changed", hostId });
    return json({});
  }

  /** Ends this device's sessions now (reason signed_out) and closes its socket; the device stays registered. */
  private async signOut(me: DeviceRow, id: string): Promise<Response> {
    if (id !== me.id) {
      this.liveDevice(id);
      throw new ApiError(403, "not_host", "only the device itself can sign out");
    }
    const open = this.sql.exec("SELECT * FROM sessions WHERE state != 'ended' AND (viewer_id = ? OR host_id = ?)", id, id).toArray() as unknown as SessionRow[];
    for (const s of open) await this.endSession(s, "signed_out", "revoked", true);
    this.sql.exec("DELETE FROM offline WHERE device_id = ?", id);
    this.sql.exec("DELETE FROM anchors WHERE device_id = ?", id);
    this.closeSockets(id, 4003, "signed out");
    this.broadcast({ type: "devices.changed" }, id);
    return json({});
  }

  /** A host's own screen sharing status (`cmux.screen-share.status/1`), for every row that lists it. */
  private reportScreenShare(me: DeviceRow, id: string, body: Record<string, unknown>): Response {
    if (id !== me.id) {
      this.liveDevice(id);
      throw new ApiError(403, "not_host", "only the device itself reports its screen sharing status");
    }
    if (!HOST_PLATFORMS.includes(me.platform)) throw new ApiError(403, "not_host", "only a Mac or a Linux desktop shares its screen");
    const report = JSON.stringify(screenShareReport(body));
    if (report !== me.screen_share) {
      this.sql.exec("UPDATE devices SET screen_share = ? WHERE id = ?", report, id);
      this.broadcast({ type: "devices.changed" });
    }
    return json({ device: publicDevice(this.device(id)!, this.online(id)) });
  }

  private async setSharing(me: DeviceRow, id: string, body: Record<string, unknown>): Promise<Response> {
    if (id !== me.id) {
      this.liveDevice(id);
      throw new ApiError(403, "not_host", "only the device itself can change its Mac Screen sharing");
    }
    if (typeof body.shared !== "boolean") throw badRequest("shared must be a boolean");
    // Set on purpose: from now on a join default never changes it (joinDefault).
    if (me.mac_screen_chosen !== 1) this.sql.exec("UPDATE devices SET mac_screen_chosen = 1 WHERE id = ?", id);
    const was = me.mac_screen_shared === 1;
    if (was !== body.shared) {
      this.sql.exec("UPDATE devices SET mac_screen_shared = ? WHERE id = ?", body.shared ? 1 : 0, id);
      this.audit(body.shared ? "shared" : "unshared", { hostId: id });
      if (!body.shared) {
        // Nothing left to serve: the device no longer renews a host session until the app anchors it again.
        this.sql.exec("DELETE FROM anchors WHERE device_id = ?", id);
        const open = this.sql.exec("SELECT * FROM sessions WHERE state != 'ended' AND host_id = ?", id).toArray() as unknown as SessionRow[];
        for (const s of open) await this.endSession(s, "sharing_off", "revoked", true);
      }
      this.broadcast({ type: "devices.changed" });
    }
    return json({ device: publicDevice(this.device(id)!, this.online(id)) });
  }

  /**
   * `POST /v1/devices/:id/share-approval {approval}`: carries a signed `cmux.share-approval.v1`
   * (acpmux `share_approval.rs`) from the device the person tapped on to the Mac it names, as a
   * `share.approval` push (zero-touch Share This Mac, cmuxterm-hq#18912). The hub checks who
   * sends it: a person's full session only (a host or machine session is refused before
   * dispatch, so an agent's fleet or CLI token never sends one), as the device the approval
   * names, on this account, to a live host of it. The target checks the signature against this
   * account's device list, then turns its own sharing on (acpmux `share_host/approval.rs`).
   */
  private carryShareApproval(me: DeviceRow, id: string, body: Record<string, unknown>, c: CallContext): Response {
    const raw = body.approval;
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw badRequest("approval must be an object");
    const f = raw as Record<string, unknown>;
    if (f.v !== SHARE_APPROVAL_VERSION) throw badRequest(`approval.v must be ${SHARE_APPROVAL_VERSION}`);
    const at = f.confirmed_at;
    const atOk = (typeof at === "number" && Number.isSafeInteger(at) && at >= 0) || (typeof at === "string" && /^\d{1,15}$/.test(at));
    if (!atOk) throw badRequest("approval.confirmed_at must be whole Unix seconds");
    const name = (v: unknown, field: string) => (v === undefined || v === "" ? "" : str(v, field, 200));
    const approval = {
      v: SHARE_APPROVAL_VERSION,
      target: str(f.target, "approval.target", 64),
      target_name: name(f.target_name, "approval.target_name"),
      asker: str(f.asker, "approval.asker", 64),
      asker_name: name(f.asker_name, "approval.asker_name"),
      confirmed_by: str(f.confirmed_by, "approval.confirmed_by", 200),
      confirmed_at: at,
      nonce: str(f.nonce, "approval.nonce", 128),
      signature: str(f.signature, "approval.signature", 200),
    };
    if (approval.target !== id) throw badRequest("approval.target must be the device in the path");
    if (id === me.id) throw badRequest("a device does not send an approval to itself");
    if (approval.asker !== me.id) throw new ApiError(403, "not_asker", "only the device that signed an approval sends it");
    if (approval.confirmed_by !== c.userId) throw new ApiError(403, "other_account", "the approval names another account");
    const host = this.liveDevice(id);
    if (!HOST_PLATFORMS.includes(host.platform)) throw new ApiError(403, "not_host", "only a Mac, a Linux desktop or a Windows PC shares its screen");
    if (!this.online(id)) throw new ApiError(409, "host_offline", "the host is not connected");
    this.send(id, { type: "share.approval", from: me.id, approval });
    return json({ delivered: true, hostId: id });
  }

  // ---- permissions ----

  private listPermissions(hostId: string | null): Response {
    if (!hostId) throw badRequest("host is required");
    this.liveDevice(hostId);
    const viewers = this.sql.exec("SELECT id FROM devices WHERE removed_at IS NULL AND id != ? ORDER BY created_at", hostId).toArray();
    return json({ permissions: viewers.map((v) => ({ viewerId: v.id as string, scope: this.permission(hostId, v.id as string) })) });
  }

  private async setPermission(me: DeviceRow, hostId: string, viewerId: string, body: Record<string, unknown>): Promise<Response> {
    this.liveDevice(hostId);
    // A viewer raises its access only by asking; the host's `always` decision stores it.
    if (me.id !== hostId) throw new ApiError(403, "not_host", "only the host sets who may view it");
    this.liveDevice(viewerId);
    if (hostId === viewerId) throw badRequest("host and viewer must differ");
    const scope = body.scope as PermissionScope;
    if (!PERMISSION_SCOPES.includes(scope)) throw badRequest("scope must be none, ask, view or full");
    const now = Date.now();
    const before = await this.storePermission(hostId, viewerId, scope, now);
    return json({ permission: { hostId, viewerId, scope, previous: before, updatedAt: now } });
  }

  /** Upserts, audits and pushes a permission; lowering it revokes sessions that exceed it. */
  private async storePermission(hostId: string, viewerId: string, scope: PermissionScope, now: number): Promise<PermissionScope> {
    const before = this.permission(hostId, viewerId);
    // The newest answer about a pair of Macs wins (`permission`): never older than any stored one,
    // even when two answers land in the same millisecond.
    const newest = (this.sql.exec("SELECT MAX(updated_at) AS t FROM permissions").toArray()[0]?.t as number | null) ?? 0;
    const at = Math.max(now, newest + 1);
    // The answer is about the two Macs: it is written for every pair of their live devices, so no
    // pair keeps an older answer that a device removal could bring back (a None given to one id,
    // then that id removed, must not revive an earlier Always given to its sibling).
    const hosts = this.sameMachine(hostId);
    const viewers = this.sameMachine(viewerId);
    for (const h of hosts) {
      for (const v of viewers) {
        if (h === v) continue;
        this.sql.exec(
          "INSERT INTO permissions(host_id, viewer_id, scope, updated_at, owner_kind, owner_id) VALUES (?, ?, ?, ?, 'user', ?) ON CONFLICT(host_id, viewer_id) DO UPDATE SET scope = excluded.scope, updated_at = excluded.updated_at",
          h,
          v,
          scope,
          at,
          this.ownerId,
        );
      }
    }
    if (before !== scope) {
      this.audit("permission_changed", { hostId, viewerId, scope, detail: `${before}->${scope}` });
      // Lowering ends the sessions it no longer allows, between any devices of the two Macs:
      // none ends every session (pending requests too), view ends full ones, ask ends view and
      // full ones. A pending request above the new permission stays: it already waits for the host.
      if (scope === "none" || rank(scope) < rank(before)) {
        const open = this.sql
          .exec(
            `SELECT * FROM sessions WHERE state != 'ended' AND host_id IN (${hosts.map(() => "?").join(",")}) AND viewer_id IN (${viewers.map(() => "?").join(",")})`,
            ...hosts,
            ...viewers,
          )
          .toArray() as unknown as SessionRow[];
        for (const s of open) {
          const ends = scope === "none" || (s.state !== "pending" && rank(s.scope) > rank(scope));
          if (ends) await this.endSession(s, "permission_revoked", "revoked", true);
        }
      }
    }
    for (const id of hosts) this.broadcast({ type: "permissions.changed", hostId: id });
    return before;
  }

  // ---- sessions ----

  /**
   * The account's sessions that are not over, oldest first: what `cmux share screens` lists. A
   * host or machine session sees only those whose host or viewer is on its own machine.
   */
  private listSessions(me: DeviceRow, c: CallContext): Response {
    const rows = this.sql.exec("SELECT * FROM sessions WHERE state != 'ended' ORDER BY created_at, rowid").toArray() as unknown as SessionRow[];
    const mine = c.scope === "full" ? null : new Set(this.sameMachine(me.id));
    const names = new Map(this.sql.exec("SELECT id, name FROM devices").toArray().map((d) => [d.id as string, d.name as string]));
    return json({
      sessions: rows
        .filter((s) => !mine || mine.has(s.host_id) || mine.has(s.viewer_id))
        .map((s) => ({
          id: s.id,
          hostId: s.host_id,
          hostName: names.get(s.host_id) ?? null,
          viewerId: s.viewer_id,
          viewerName: names.get(s.viewer_id) ?? null,
          scope: s.scope,
          state: s.state,
          createdAt: s.created_at,
          startedAt: s.started_at,
          movedFrom: s.moved_from ?? null,
        })),
    });
  }

  /** A new session row, pending until approve (or the host's decision) moves it on. */
  private insertSession(viewerId: string, hostId: string, scope: Scope, movedFrom: string | null): string {
    const id = crypto.randomUUID();
    this.sql.exec(
      "INSERT INTO sessions(id, viewer_id, host_id, scope, state, created_at, owner_kind, owner_id, moved_from) VALUES (?, ?, ?, ?, 'pending', ?, 'user', ?, ?)",
      id,
      viewerId,
      hostId,
      scope,
      Date.now(),
      this.ownerId,
      movedFrom,
    );
    return id;
  }

  /**
   * The checks a session the viewer did not ask for passes before anything is written (a host
   * pushing its screen, a move): the same as a viewer's own request, but it never prompts. A
   * permission below `scope` answers needs_approval: nobody is at the viewer to see a request go
   * out, and the host's prompt would pop up for something it started itself.
   */
  private checkPushed(me: DeviceRow, hostId: string, viewerId: string, scope: Scope, c: CallContext) {
    if (hostId === viewerId) throw badRequest("a device cannot view itself");
    const host = this.liveDevice(hostId);
    this.liveDevice(viewerId);
    // A host or machine session serves its machine as a host: it never makes a device there a viewer.
    if (c.scope !== "full" && this.sameMachine(me.id).includes(viewerId)) {
      throw new ApiError(403, "machine_scope", "a machine's session is never a viewer");
    }
    if (host.mac_screen_shared !== 1) throw new ApiError(403, "not_shared", "the host does not share its screen");
    const perm = this.permission(hostId, viewerId);
    if (perm === "none") throw new ApiError(403, "permission_none", "the host does not allow this device");
    if (!this.online(hostId)) throw new ApiError(409, "host_offline", "the host is not connected");
    if (rank(perm) < rank(scope)) throw new ApiError(409, "needs_approval", "the host must allow this device first; ask from the viewer");
  }

  /** `POST /v1/sessions` with `viewerId`: the host (or a device on its machine) shares its screen to another device. */
  private async pushSession(me: DeviceRow, body: Record<string, unknown>, scope: Scope, c: CallContext): Promise<Response> {
    const hostId = str(body.hostId, "hostId", 64);
    const viewerId = str(body.viewerId, "viewerId", 64);
    if (!this.sameMachine(me.id).includes(hostId)) throw new ApiError(403, "not_host", "only the host pushes its screen to another device");
    this.checkPushed(me, hostId, viewerId, scope, c);
    const id = this.insertSession(viewerId, hostId, scope, null);
    this.audit("requested", { viewerId, hostId, scope, sessionId: id, detail: "pushed" });
    this.audit("approved", { viewerId, hostId, scope, sessionId: id, detail: "permission" });
    await this.approveOrEnd(this.session(id)!, c, { movedFrom: null });
    const s = this.session(id)!;
    return json({ session: { id: s.id, state: s.state, scope: s.scope, hostId, viewerId, movedFrom: null } });
  }

  /**
   * Hands a running share to another viewer or another host: a new session for the new pair,
   * approved with no prompt, then the old one ends (reason `moved`, `movedTo` the new id). A
   * check that fails changes nothing: the old share keeps running.
   */
  private async moveSession(me: DeviceRow, id: string, body: Record<string, unknown>, c: CallContext): Promise<Response> {
    const viewerId = body.viewerId === undefined ? undefined : str(body.viewerId, "viewerId", 64);
    const hostId = body.hostId === undefined ? undefined : str(body.hostId, "hostId", 64);
    if ((viewerId === undefined) === (hostId === undefined)) throw badRequest("a move names exactly one of viewerId and hostId");
    const old = this.session(id);
    if (!old) throw notFound("session not found");
    if (old.state !== "approved" && old.state !== "live") throw new ApiError(409, "session_not_active", "session is not active");
    const newHost = hostId ?? old.host_id;
    const newViewer = viewerId ?? old.viewer_id;
    if (newHost === old.host_id && newViewer === old.viewer_id) throw badRequest("the session already has that device");
    this.checkPushed(me, newHost, newViewer, old.scope, c);
    const newId = this.insertSession(newViewer, newHost, old.scope, old.id);
    // A move continues the same share: it keeps the billing answer its viewer's request got.
    this.sql.exec("UPDATE sessions SET relay_paid = ?, relay_read_at = ? WHERE id = ?", old.relay_paid ?? null, old.relay_read_at ?? null, newId);
    this.audit("moved", { viewerId: old.viewer_id, hostId: old.host_id, scope: old.scope, sessionId: old.id, detail: newId });
    this.audit("approved", { viewerId: newViewer, hostId: newHost, scope: old.scope, sessionId: newId, detail: "moved" });
    // The new share is up before the old one goes: a move that cannot start keeps the old share.
    await this.approveOrEnd(this.session(newId)!, c, { movedFrom: old.id });
    const current = this.session(old.id);
    if (current) await this.endSession(current, "moved", "ended", true, { movedTo: newId });
    const s = this.session(newId)!;
    return json({ session: { id: s.id, state: s.state, scope: s.scope, hostId: s.host_id, viewerId: s.viewer_id, movedFrom: s.moved_from } });
  }

  private async requestSession(me: DeviceRow, body: Record<string, unknown>, c: CallContext): Promise<Response> {
    const scope = body.scope as Scope;
    if (scope !== "view" && scope !== "full") throw badRequest("scope must be view or full");
    if (body.viewerId !== undefined) return this.pushSession(me, body, scope, c);
    const hostId = str(body.hostId, "hostId", 64);
    if (hostId === me.id) throw badRequest("a device cannot view itself");
    const host = this.liveDevice(hostId);
    if (host.mac_screen_shared !== 1) throw new ApiError(403, "not_shared", "the host does not share its screen");
    const perm = this.permission(hostId, me.id);
    if (perm === "none") throw new ApiError(403, "permission_none", "the host does not allow this device");
    // A scope above the saved permission (View Only asking for Full Control) is a
    // request to the host, decided on its prompt like a request under Ask.
    if (!this.online(hostId)) throw new ApiError(409, "host_offline", "the host is not connected");
    const id = this.insertSession(me.id, hostId, scope, null);
    this.audit("requested", { viewerId: me.id, hostId, scope, sessionId: id });
    if (rank(perm) >= rank(scope)) {
      this.audit("approved", { viewerId: me.id, hostId, scope, sessionId: id, detail: "permission" });
      await this.approveOrEnd(this.session(id)!, c);
    } else {
      // The host decides with its own session, which has no Stack token: the viewer's billing
      // answer is read now and kept on the session, so the host's approval mints the relay.
      await this.sessionEntitlement(this.session(id)!, c);
      await this.scheduleAlarm();
      this.send(hostId, await this.sessionRequest(id, me, scope));
    }
    const s = this.session(id)!;
    return json({ session: { id: s.id, state: s.state, scope: s.scope } });
  }

  private async sessionRequest(id: string, viewer: DeviceRow, scope: Scope) {
    return {
      type: "session.request",
      session: { id, viewerId: viewer.id, viewerName: viewer.name, viewerKeyFingerprint: await keyFingerprint(viewer.signing_key), scope },
    };
  }

  /** Sends `hostId` every request still pending on it, oldest first. */
  private async resendPendingRequests(hostId: string) {
    const pending = this.sql
      .exec("SELECT * FROM sessions WHERE state = 'pending' AND host_id = ? ORDER BY created_at", hostId)
      .toArray() as unknown as SessionRow[];
    for (const s of pending) {
      const viewer = this.device(s.viewer_id);
      if (viewer) this.send(hostId, await this.sessionRequest(s.id, viewer, s.scope));
    }
  }

  /** Approves, or ends the session (approve_failed) when the Session DO or tickets cannot be set up. */
  private async approveOrEnd(s: SessionRow, c: CallContext, pushed: Pushed | null = null) {
    try {
      await this.approve(s, c, pushed);
    } catch (err) {
      console.error("session approve failed", err instanceof Error ? err.message : String(err));
      const current = this.session(s.id);
      if (current) await this.endSession(current, "approve_failed", "revoked", true);
      throw new ApiError(500, "internal", "could not start the session");
    }
  }

  /** Whether the session is still approved (or already live): not ended meanwhile. */
  private stillOpen(id: string): boolean {
    const state = this.session(id)?.state;
    return state === "approved" || state === "live";
  }

  /**
   * Creates the Session DO and pushes a ticket to each device. The DO serves
   * other requests while this awaits, so a session ended meanwhile (sharing
   * off, removal, access lowered) is checked after every await and gets no ticket.
   */
  private async approve(s: SessionRow, c: CallContext, pushed: Pushed | null = null) {
    this.sql.exec("UPDATE sessions SET state = 'approved', scope = ? WHERE id = ? AND state != 'ended'", s.scope, s.id);
    if (!this.stillOpen(s.id)) return;
    // Ask billing now (in parallel with the Session DO init); fail closed.
    const entitled = this.sessionEntitlement(s, c);
    const viewer = this.device(s.viewer_id)!;
    const host = this.device(s.host_id)!;
    const stub = this.env.SESSION_DO.get(this.env.SESSION_DO.idFromName(s.id));
    const init = await internalCall(
      stub,
      "https://session.do/internal/init",
      {
        sid: s.id,
        userId: c.userId,
        scope: s.scope,
        viewer: { id: viewer.id, key: viewer.signing_key },
        host: { id: host.id, key: host.signing_key },
      },
      `session ${s.id} init`,
    );
    // Ended during init: endSession closed the Session DO (a close that got there
    // first makes init refuse), so there is nothing to start.
    if (!this.stillOpen(s.id)) return;
    if (!init.ok) throw new Error(`session init ${init.status}`);
    const tickets = await this.issueTickets(s, c, (await entitled) === "paid" ? await mintTurn(this.env) : [], TICKET_TTL_S, false, pushed);
    if (!tickets) return;
    for (const ticket of tickets) this.send(ticket.role === "viewer" ? viewer.id : host.id, { type: "session.ticket", ...ticket });
  }

  /** Mints fresh tickets for the same approved viewer/host pair. */
  private async issueTickets(s: SessionRow, c: CallContext, ice: IceServer[], ttlS: number, reattach: boolean, pushed: Pushed | null = null): Promise<[WireTicket, WireTicket] | null> {
    if (!this.stillOpen(s.id)) return null;
    const viewer = this.device(s.viewer_id);
    const host = this.device(s.host_id);
    if (!viewer || !host) return null;
    const signalURL = `${c.origin.replace(/^http/, "ws")}/v1/sessions/${s.id}/ws`;
    const result: WireTicket[] = [];
    for (const [self, peer, role] of [[viewer, host, "viewer"], [host, viewer, "host"]] as const) {
      const ticket = await mintTicket(this.env, { sid: s.id, role, dev: self.id, peer: peer.id, peerKey: peer.signing_key, scope: s.scope, ...(reattach ? { reattach: true } : {}) }, Date.now(), ttlS);
      if (!this.stillOpen(s.id)) return null;
      result.push({ sessionId: s.id, ticket, signalURL, ice, peer: { id: peer.id, name: peer.name, signingKey: peer.signing_key }, role, scope: s.scope, ownerKind: "user", ...(pushed ? { pushed: true as const, movedFrom: pushed.movedFrom } : {}) });
    }
    return result as [WireTicket, WireTicket];
  }

  /** Re-admits only the original viewer for the still-open, same-device session. */
  private async reattach(me: DeviceRow, id: string, c: CallContext): Promise<Response> {
    const s = this.session(id);
    if (!s || s.viewer_id !== me.id || (s.state !== "approved" && s.state !== "live")) throw new ApiError(409, "session_not_active", "session is not active");
    const host = this.liveDevice(s.host_id);
    if (host.mac_screen_shared !== 1) throw new ApiError(403, "not_shared", "the host does not share its screen");
    if (!this.online(host.id)) throw new ApiError(409, "host_offline", "the host is not connected");
    if (rank(this.permission(host.id, me.id)) < rank(s.scope)) throw new ApiError(403, "permission_none", "the host no longer allows this device");
    const entitled = (await this.sessionEntitlement(s, c)) === "paid";
    const tickets = await this.issueTickets(s, c, entitled ? await mintTurn(this.env) : [], REATTACH_TTL_S, true);
    if (!tickets) throw new ApiError(409, "session_not_active", "session is not active");
    for (const ticket of tickets) this.send(ticket.role === "viewer" ? me.id : host.id, { type: "session.ticket", ...ticket });
    this.audit("reattached", { viewerId: me.id, hostId: host.id, scope: s.scope, sessionId: id, detail: "viewer" });
    return json({ session: publicSession(s), ticket: tickets[0] });
  }

  private async decide(me: DeviceRow, id: string, body: Record<string, unknown>, c: CallContext): Promise<Response> {
    const s = this.session(id);
    if (!s || (s.viewer_id !== me.id && s.host_id !== me.id)) throw notFound("session not found");
    if (s.host_id !== me.id) throw new ApiError(403, "not_host", "only the host decides");
    const decision = body.decision;
    if (decision !== "deny" && decision !== "once" && decision !== "always") throw badRequest("decision must be deny, once or always");
    if (s.state !== "pending") throw new ApiError(409, "session_not_pending", "session is not pending");
    if (Date.now() - s.created_at > PENDING_TTL_MS) {
      await this.endSession(s, "expired", "revoked", false);
      throw new ApiError(409, "session_not_pending", "the request expired");
    }
    if (decision === "deny") {
      this.sql.exec("UPDATE sessions SET state = 'ended', ended_at = ?, end_reason = 'denied' WHERE id = ?", Date.now(), id);
      this.audit("denied", { viewerId: s.viewer_id, hostId: s.host_id, scope: s.scope, sessionId: id });
      this.send(s.viewer_id, { type: "session.denied", sessionId: id });
      return json({ session: publicSession(this.session(id)!) });
    }
    const scope = (body.scope ?? s.scope) as Scope;
    if (scope !== "view" && scope !== "full") throw badRequest("scope must be view or full");
    if (rank(scope) > rank(s.scope)) throw badRequest("the decision cannot grant more than was requested");
    // Leave pending before any await so a concurrent decision sees it as decided.
    this.sql.exec("UPDATE sessions SET state = 'approved', scope = ? WHERE id = ?", scope, id);
    if (decision === "always") await this.storePermission(s.host_id, s.viewer_id, scope, Date.now());
    this.audit("approved", { viewerId: s.viewer_id, hostId: s.host_id, scope, sessionId: id, detail: decision });
    await this.approveOrEnd({ ...s, scope }, c);
    return json({ session: publicSession(this.session(id)!) });
  }

  private async endFromDevice(me: DeviceRow, id: string, body: Record<string, unknown>): Promise<Response> {
    const s = this.session(id);
    if (!s || (s.viewer_id !== me.id && s.host_id !== me.id)) throw notFound("session not found");
    const fallback = s.host_id === me.id ? "host_stopped" : "viewer_disconnected";
    const reason = typeof body.reason === "string" && body.reason ? body.reason.slice(0, 100) : fallback;
    await this.endSession(s, reason, "revoked", true);
    return json({});
  }

  /**
   * Ends a session once: records it, audits `ended` with the duration, pushes
   * `session.revoked` or `session.ended` to both devices and, when asked,
   * closes the Session DO.
   */
  private async endSession(s: SessionRow, reason: string, push: "revoked" | "ended", closeSignal: boolean, extra: Record<string, unknown> = {}) {
    const current = this.session(s.id);
    if (!current || current.state === "ended") return;
    this.sql.exec("DELETE FROM closing WHERE session_id = ?", s.id);
    const now = Date.now();
    this.sql.exec("UPDATE sessions SET state = 'ended', ended_at = ?, end_reason = ? WHERE id = ?", now, reason, s.id);
    const durationS = current.started_at ? Math.round((now - current.started_at) / 1000) : null;
    this.audit("ended", { viewerId: s.viewer_id, hostId: s.host_id, scope: current.scope, sessionId: s.id, detail: reason, durationS });
    const msg = { type: push === "revoked" ? "session.revoked" : "session.ended", sessionId: s.id, reason, ...extra };
    this.send(s.viewer_id, msg);
    this.send(s.host_id, msg);
    if (closeSignal && current.state !== "pending") {
      const stub = this.env.SESSION_DO.get(this.env.SESSION_DO.idFromName(s.id));
      // The session is ended here either way; a Session DO that does not answer keeps
      // its sockets until the devices act on the push above.
      try {
        await internalCall(stub, "https://session.do/internal/close", { reason }, `session ${s.id} close (${reason})`);
      } catch (err) {
        console.error(`device-hub: ${why(err)}`);
      }
    }
  }

  private async ice(me: DeviceRow, id: string, c: CallContext): Promise<Response> {
    const s = this.session(id);
    if (!s || (s.viewer_id !== me.id && s.host_id !== me.id)) throw notFound("session not found");
    if (s.state !== "approved" && s.state !== "live") throw new ApiError(409, "session_not_active", "session is not active");
    const ice = (await this.sessionEntitlement(s, c)) === "paid" ? await mintTurn(this.env) : [];
    return json({ ice });
  }

  // ---- relays ----

  private publicRelay(r: RelayRow, deviceId: string) {
    const sealed = JSON.parse(r.sealed) as Record<string, string>;
    return {
      id: r.id,
      ownerKind: r.owner_kind,
      ownerId: r.owner_id,
      name: r.name,
      urls: JSON.parse(r.urls) as string[],
      authMode: r.auth_mode,
      sealed: deviceId in sealed ? { [deviceId]: sealed[deviceId] } : {},
      enabled: r.enabled === 1,
      priority: r.priority,
      updatedAt: r.updated_at,
    };
  }

  private listRelays(me: DeviceRow): Response {
    const rows = this.sql.exec("SELECT * FROM relays ORDER BY priority, id").toArray() as unknown as RelayRow[];
    return json({ relays: rows.map((r) => this.publicRelay(r, me.id)) });
  }

  private putRelay(me: DeviceRow, id: string, body: Record<string, unknown>, userId: string): Response {
    if (!RELAY_ID.test(id)) throw badRequest("relay id must be 1-64 of [A-Za-z0-9_-]");
    const name = str(body.name, "name", 100);
    const urls = body.urls;
    if (!Array.isArray(urls) || urls.length === 0 || urls.length > 16 || !urls.every((u) => typeof u === "string" && /^(stun|stuns|turn|turns):/.test(u) && u.length <= 512)) {
      throw badRequest("urls must be 1-16 stun:/turn:/turns: URLs");
    }
    if (body.authMode !== "shared_secret" && body.authMode !== "static") throw badRequest("authMode must be shared_secret or static");
    const sealed = body.sealed;
    if (!sealed || typeof sealed !== "object" || Array.isArray(sealed)) throw badRequest("sealed must be an object of deviceId: base64");
    for (const [k, v] of Object.entries(sealed)) {
      if (!DEVICE_ID.test(k) || typeof v !== "string" || v.length > 8192) throw badRequest("sealed must map device ids to base64 blobs");
      try {
        base64Decode(v);
      } catch {
        throw badRequest("sealed blobs must be base64");
      }
    }
    const enabled = body.enabled === undefined ? true : body.enabled;
    if (typeof enabled !== "boolean") throw badRequest("enabled must be a boolean");
    const priority = body.priority === undefined ? 0 : body.priority;
    if (typeof priority !== "number" || !Number.isInteger(priority)) throw badRequest("priority must be an integer");
    const now = Date.now();
    this.sql.exec(
      `INSERT INTO relays(id, owner_kind, owner_id, name, urls, auth_mode, sealed, enabled, priority, updated_at)
       VALUES (?, 'user', ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET name = excluded.name, urls = excluded.urls, auth_mode = excluded.auth_mode,
         sealed = excluded.sealed, enabled = excluded.enabled, priority = excluded.priority, updated_at = excluded.updated_at`,
      id,
      userId,
      name,
      JSON.stringify(urls),
      body.authMode,
      JSON.stringify(sealed),
      enabled ? 1 : 0,
      priority,
      now,
    );
    this.broadcast({ type: "relays.changed" });
    const row = this.sql.exec("SELECT * FROM relays WHERE id = ?", id).one() as unknown as RelayRow;
    return json({ relay: this.publicRelay(row, me.id) });
  }

  private deleteRelay(id: string): Response {
    const existed = this.sql.exec("SELECT 1 FROM relays WHERE id = ?", id).toArray().length > 0;
    if (!existed) throw notFound("relay not found");
    this.sql.exec("DELETE FROM relays WHERE id = ?", id);
    this.broadcast({ type: "relays.changed" });
    return json({});
  }

  // ---- audit ----

  private listAudit(q: URLSearchParams): Response {
    const limit = Math.min(Math.max(Number(q.get("limit") ?? 50) || 50, 1), 200);
    const before = q.get("before");
    const device = q.get("device");
    const where: string[] = [];
    const binds: unknown[] = [];
    if (before && /^\d+$/.test(before)) {
      where.push("ts < ?");
      binds.push(Number(before));
    }
    if (device) {
      // Device events belong to every device's History: each shows the account's devices coming and going.
      where.push("(viewer_id = ? OR host_id = ? OR event IN ('device_added', 'device_removed'))");
      binds.push(device, device);
    }
    const rows = this.sql
      .exec(`SELECT * FROM audit ${where.length ? `WHERE ${where.join(" AND ")}` : ""} ORDER BY ts DESC, rowid DESC LIMIT ?`, ...binds, limit)
      .toArray();
    // Names come from the devices table, which keeps removed devices, so rows
    // about a removed device keep its last known name.
    const names = new Map(this.sql.exec("SELECT id, name FROM devices").toArray().map((d) => [d.id as string, d.name as string]));
    const nameOf = (id: unknown) => (typeof id === "string" ? (names.get(id) ?? null) : null);
    return json({
      entries: rows.map((r) => ({
        id: r.id,
        ts: r.ts,
        event: r.event,
        viewerId: r.viewer_id,
        hostId: r.host_id,
        scope: r.scope,
        sessionId: r.session_id,
        detail: r.detail,
        durationS: r.duration_s,
        deviceId: r.device_id,
        viewerName: nameOf(r.viewer_id),
        hostName: nameOf(r.host_id),
        deviceName: nameOf(r.device_id),
      })),
    });
  }

  // ---- calls from the Session DO ----

  // ---- device renewal (PROTOCOL.md, Device renewal) ----

  /**
   * One session's relay right. Its viewer and host are one account (one UserDO per user), so
   * a paid answer from billing covers both ends. A full caller (the app, with a Stack token)
   * asks billing, fail closed, and the answer is kept on the session (a failed read clears
   * it). A host or machine caller has no Stack token: it gets the relay while its session holds
   * a paid answer read in the last ANCHOR_RELAY_TTL_MS (the same bound as an anchor's), else its
   * own (a host anchor's `rel`; a machine session's none). A move carries the answer and its
   * read time, never refreshes them. A free or failed read grants nothing to either end.
   */
  private async sessionEntitlement(s: SessionRow, c: CallContext): Promise<"paid" | "free" | "error"> {
    if (c.scope === "full") {
      const answer = await this.entitlement(c).catch(() => "error" as const);
      const paid = answer === "error" ? null : answer === "paid" ? 1 : 0;
      this.sql.exec("UPDATE sessions SET relay_paid = ?, relay_read_at = ? WHERE id = ?", paid, paid === null ? null : Date.now(), s.id);
      return answer;
    }
    const held = this.sql.exec("SELECT relay_paid, relay_read_at FROM sessions WHERE id = ?", s.id).toArray()[0];
    if (held && (held.relay_paid as number | null) === 1 && (held.relay_read_at as number) + ANCHOR_RELAY_TTL_MS > Date.now()) return "paid";
    return this.entitlement(c).catch(() => "error" as const);
  }

  /** The cmux relay entitlement: billing for a full session, the anchor's record for a host session. */
  private async entitlement(c: CallContext): Promise<"paid" | "free" | "error"> {
    if (c.scope === "host") return c.hostRelay ? "paid" : "free";
    return (await relayEntitlement(this.env, c.userId, c.stackToken)) as "paid" | "free" | "error";
  }

  /**
   * What a host session may do: serve this device as a Mac Screen host. Its
   * own socket and registration, reads, its sessions' decisions, ends and
   * ICE, its own permissions, and sharing off; pushing this machine's screen
   * to another device and moving a share this machine is part of (never with
   * a device of this machine as the viewer: moveSession, pushSession). Not:
   * another device, relay writes, a session as viewer, sharing on, anchoring.
   */
  private hostAllowed(m: string, parts: string[], me: DeviceRow, raw: Uint8Array): boolean {
    const [a, b, d] = parts;
    const n = parts.length;
    if (m === "GET") return (a === "me" && n === 1) || (a === "user" && b === "ws" && n === 2) || (a === "devices" && n === 1) || (a === "permissions" && n === 1) || (a === "relays" && n === 1) || (a === "audit" && n === 1) || (a === "sessions" && n === 1);
    if (a === "sessions" && n === 1 && m === "POST") {
      // Only a push of this machine's own screen; a session as viewer needs the signed-in app.
      let body: { hostId?: unknown; viewerId?: unknown };
      try {
        body = JSON.parse(new TextDecoder().decode(raw)) as typeof body;
      } catch {
        return false;
      }
      return typeof body?.viewerId === "string" && typeof body.hostId === "string" && this.sameMachine(me.id).includes(body.hostId);
    }
    if (a === "sessions" && n === 3 && m === "POST" && d === "move") {
      // Only a share whose host or viewer is on this machine.
      const s = this.session(b!);
      const mine = this.sameMachine(me.id);
      return !!s && (mine.includes(s.host_id) || mine.includes(s.viewer_id));
    }
    // Its own screen sharing status: what it can serve, read where it runs.
    if (a === "devices" && n === 3 && d === "screen-share" && m === "PUT" && b === me.id) return true;
    if (a === "devices" && n === 3 && d === "mac-screen" && m === "PUT" && b === me.id) {
      try {
        return (JSON.parse(new TextDecoder().decode(raw)) as { shared?: unknown }).shared === false;
      } catch {
        return false;
      }
    }
    if (a === "permissions" && n === 3 && m === "PUT") {
      // Only lower a viewer's access on this Mac: raising needs the signed-in app.
      if (b !== me.id || !d) return false;
      let scope: unknown;
      try {
        scope = (JSON.parse(new TextDecoder().decode(raw)) as { scope?: unknown }).scope;
      } catch {
        return false;
      }
      const order = PERMISSION_SCOPES as string[];
      const wanted = order.indexOf(scope as string);
      return wanted >= 0 && (scope === "none" || wanted < order.indexOf(this.permission(me.id, d)));
    }
    if (a === "sessions" && n === 3 && m === "POST" && (d === "decision" || d === "end" || d === "ice")) {
      // Only this Mac's own sessions as their host.
      return this.session(b!)?.host_id === me.id;
    }
    return false;
  }

  /**
   * What a machine session may do: what a host session may, and turn this
   * machine's sharing on. Its registration passed before dispatch. Not:
   * another device, permissions above the saved ones, relay writes, a session
   * as viewer, or an anchor: device-key renewal would outlive the credential,
   * so a revoked machine would keep its host session for 30 days.
   */
  /**
   * A device a machine session speaks for renews only by signing in again: an anchor it
   * kept from an earlier person's sign-in would let device-key renewal outlive a revoked
   * credential for the rest of its 30 days, so the machine's first signed call drops it.
   */
  private dropMachineAnchor(deviceId: string) {
    this.sql.exec("DELETE FROM anchors WHERE device_id = ?", deviceId);
  }

  private machineAllowed(m: string, parts: string[], me: DeviceRow, raw: Uint8Array): boolean {
    const [a, b, d] = parts;
    const n = parts.length;
    if (a === "devices" && n === 3 && d === "mac-screen" && m === "PUT" && b === me.id) return true;
    return this.hostAllowed(m, parts, me, raw);
  }

  /** The signed-in app lets its Mac renew its own host session for 30 days. */
  private async anchor(me: DeviceRow, c: CallContext): Promise<Response> {
    if (!HOST_PLATFORMS.includes(me.platform)) throw new ApiError(403, "not_host", "only a Mac, a Linux desktop or a Windows PC is anchored");
    const paid = (await relayEntitlement(this.env, c.userId, c.stackToken).catch(() => "error")) === "paid";
    const now = Date.now();
    this.sql.exec(
      "INSERT INTO anchors(device_id, anchored_at, relay_paid) VALUES (?, ?, ?) ON CONFLICT(device_id) DO UPDATE SET anchored_at = excluded.anchored_at, relay_paid = excluded.relay_paid",
      me.id,
      now,
      paid ? 1 : 0,
    );
    return json({ anchoredUntil: now + ANCHOR_TTL_MS });
  }

  /** `POST /v1/auth/device` from the Worker: the device's signature, the replay window and its anchor. */
  private async renewDevice(request: Request): Promise<Response> {
    try {
      const now = Date.now();
      const h = readDeviceHeaders(request.headers, now);
      const raw = new Uint8Array(await request.arrayBuffer());
      const device = this.device(h.id);
      if (!device) throw new ApiError(401, "bad_signature", "unknown device");
      if (device.removed_at !== null) throw new ApiError(403, "device_removed", "this device was removed");
      await checkDeviceSignature(device.signing_key, "POST", new URL("https://hub/v1/auth/device"), raw, h);
      const anchor = this.sql.exec("SELECT anchored_at, relay_paid FROM anchors WHERE device_id = ?", h.id).toArray()[0];
      if (!anchor || (anchor.anchored_at as number) + ANCHOR_TTL_MS <= now) {
        throw new ApiError(403, "not_anchored", "open cmux on this Mac to let it renew its session");
      }
      this.burnSignature(h.id, h.ts, h.sig, now);
      const relay = (anchor.relay_paid as number) === 1 && (anchor.anchored_at as number) + ANCHOR_RELAY_TTL_MS > now;
      return json({ deviceId: h.id, relay });
    } catch (err) {
      return errorResponse(err);
    }
  }

  /**
   * The hub user a cmux-platform user id is (machine.ts). This instance is the
   * alias `machine-alias:<project>:<platform id>`, never a user's own.
   */
  private async machineAlias(request: Request): Promise<Response> {
    this.sql.exec("CREATE TABLE IF NOT EXISTS machine_alias(k INTEGER PRIMARY KEY CHECK (k = 1), user_id TEXT NOT NULL)");
    if (request.method === "PUT") {
      const { userId } = (await request.json()) as { userId?: unknown };
      if (typeof userId !== "string" || !userId) return json({ ok: false }, 400);
      this.sql.exec("INSERT INTO machine_alias(k, user_id) VALUES (1, ?) ON CONFLICT(k) DO UPDATE SET user_id = excluded.user_id", userId);
      return json({ ok: true });
    }
    const row = this.sql.exec("SELECT user_id FROM machine_alias WHERE k = 1").toArray()[0];
    return json({ userId: (row?.user_id as string | undefined) ?? null });
  }

  private async internal(path: string, request: Request): Promise<Response> {
    if (path === "/internal/renew-device") return this.renewDevice(request);
    if (path === "/internal/machine-alias") return this.machineAlias(request);
    const body = (await request.json()) as { sid?: string; reason?: string; path?: string };
    const s = body.sid ? this.session(body.sid) : null;
    if (!s) return json({ ok: false }, 404);
    if (path === "/internal/session-started") {
      if (s.state === "approved") {
        const p = body.path === "direct" || body.path === "relay" ? body.path : null;
        this.sql.exec("UPDATE sessions SET state = 'live', started_at = ?, path = ? WHERE id = ?", Date.now(), p, s.id);
        this.audit("started", { viewerId: s.viewer_id, hostId: s.host_id, scope: s.scope, sessionId: s.id });
      }
      return json({ ok: true });
    }
    if (path === "/internal/session-path") {
      if (s.state !== "ended" && (body.path === "direct" || body.path === "relay")) {
        this.sql.exec("UPDATE sessions SET path = ? WHERE id = ?", body.path, s.id);
      }
      return json({ ok: true });
    }
    if (path === "/internal/session-ended") {
      const reason = (body.reason ?? "closed").slice(0, 100);
      if (s.state !== "ended") {
        // Provisional: a client often closes its sockets just before its /end or
        // revoke reaches us. The alarm ends it with this reason if nothing else does.
        this.sql.exec("INSERT INTO closing(session_id, reason, at) VALUES (?, ?, ?) ON CONFLICT(session_id) DO NOTHING", s.id, reason, Date.now());
        await this.scheduleAlarm();
      }
      return json({ ok: true });
    }
    return json({ ok: false }, 404);
  }
}
