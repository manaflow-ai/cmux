import { DurableObject } from "cloudflare:workers";
import { base64Decode, isValidDeviceKey, keyFingerprint, lowSHex } from "./crypto";
import { DEVICE_ID, REPLAY_WINDOW_MS, checkDeviceSignature, readDeviceHeaders } from "./deviceAuth";
import { relayEntitlement } from "./billing";
import { ORIGIN_HEADER, STACK_TOKEN_HEADER, USER_HEADER, type Env } from "./env";
import { ApiError, badRequest, errorResponse, json, notFound } from "./errors";
import { type Scope, mintTicket } from "./tickets";
import { type IceServer, mintTurn } from "./turn";

/** Who is calling: the hub user, the public origin, and the Stack token for the billing lookup (never stored). */
interface CallContext {
  userId: string;
  origin: string;
  stackToken: string | null;
}

export type PermissionScope = "none" | "ask" | "view" | "full";
type SessionState = "pending" | "approved" | "live" | "ended";

interface DeviceRow {
  id: string;
  name: string;
  platform: "macos" | "ios";
  signing_key: string;
  agreement_key: string;
  created_at: number;
  last_seen_at: number;
  removed_at: number | null;
  mac_screen_shared: number;
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
const PERMISSION_SCOPES: PermissionScope[] = ["none", "ask", "view", "full"];
const RELAY_ID = /^[A-Za-z0-9_-]{1,64}$/;
const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PING = JSON.stringify({ type: "ping" });
const PONG = JSON.stringify({ type: "pong" });

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
DROP TABLE IF EXISTS replay;
`;

/** Columns added after v1 shipped: added in place to existing User DOs. */
const ADDED_COLUMNS: [string, string, string][] = [
  ["devices", "name_pinned", "INTEGER NOT NULL DEFAULT 0"],
  ["devices", "owner_kind", "TEXT NOT NULL DEFAULT 'user'"],
  ["devices", "owner_id", "TEXT NOT NULL DEFAULT ''"],
  ["permissions", "owner_kind", "TEXT NOT NULL DEFAULT 'user'"],
  ["permissions", "owner_id", "TEXT NOT NULL DEFAULT ''"],
  ["sessions", "owner_kind", "TEXT NOT NULL DEFAULT 'user'"],
  ["sessions", "owner_id", "TEXT NOT NULL DEFAULT ''"],
  ["audit", "device_id", "TEXT"],
  ["audit", "owner_kind", "TEXT NOT NULL DEFAULT 'user'"],
  ["audit", "owner_id", "TEXT NOT NULL DEFAULT ''"],
];
const OWNED_TABLES = ["devices", "permissions", "sessions", "audit"];

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
    online,
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

  private permission(hostId: string, viewerId: string): PermissionScope {
    const row = this.sql.exec("SELECT scope FROM permissions WHERE host_id = ? AND viewer_id = ?", hostId, viewerId).toArray()[0];
    return (row?.scope as PermissionScope | undefined) ?? "ask";
  }

  /**
   * Live sockets only. A socket the server closed (sign-out, removal,
   * replacement) stays in getWebSockets until the client answers the close
   * frame, which an app that drops its socket never does.
   */
  private liveSockets(deviceId: string): WebSocket[] {
    return this.ctx.getWebSockets(deviceId).filter((ws) => ws.readyState === WebSocket.OPEN && !(ws.deserializeAttachment() as { closed?: boolean } | null)?.closed);
  }

  private online(deviceId: string): boolean {
    return this.liveSockets(deviceId).length > 0;
  }

  /** Closes a device's sockets and marks them closed so they stop counting as online at once. */
  private closeSockets(deviceId: string, code: number, reason: string) {
    for (const ws of this.ctx.getWebSockets(deviceId)) {
      try {
        ws.serializeAttachment({ closed: true });
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
      const body = new Uint8Array(await request.arrayBuffer());
      const now = Date.now();
      const h = readDeviceHeaders(request.headers, now);
      if (request.method === "POST" && url.pathname === "/v1/devices") {
        return await this.register(request, url, body, h, now);
      }
      const existing = this.device(h.id);
      if (!existing) throw new ApiError(401, "bad_signature", "unknown device");
      if (existing.removed_at !== null) throw new ApiError(403, "device_removed", "this device was removed");
      await checkDeviceSignature(existing.signing_key, request.method, url, body, h);
      this.burnSignature(h.id, h.ts, h.sig, now);
      this.sql.exec("UPDATE devices SET last_seen_at = ? WHERE id = ?", now, h.id);
      const me = { ...existing, last_seen_at: now };
      return await this.dispatch(request, url, body, me, { userId, origin, stackToken });
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

  private async register(request: Request, url: URL, raw: Uint8Array, h: { id: string; ts: string; sig: string }, now: number): Promise<Response> {
    const body = this.parse(raw);
    if (body.id !== h.id) throw badRequest("id must equal X-Device-Id");
    const name = str(body.name, "name", 100);
    if (body.platform !== "macos" && body.platform !== "ios") throw badRequest("platform must be macos or ios");
    if (!(await isValidDeviceKey(body.signingKey))) throw badRequest("signingKey must be a base64 X9.63 P-256 key");
    if (!(await isValidDeviceKey(body.agreementKey))) throw badRequest("agreementKey must be a base64 X9.63 P-256 key");
    const signingKey = body.signingKey as string;
    const agreementKey = body.agreementKey as string;
    await checkDeviceSignature(signingKey, request.method, url, raw, h);
    const existing = this.device(h.id);
    if (existing?.removed_at != null) throw new ApiError(403, "device_removed", "this device was removed; register a new device id");
    if (existing && existing.signing_key !== signingKey) throw new ApiError(409, "device_key_mismatch", "device id is registered with another signing key");
    this.burnSignature(h.id, h.ts, h.sig, now);
    if (existing) {
      this.sql.exec(
        "UPDATE devices SET name = CASE WHEN name_pinned = 1 THEN name ELSE ? END, platform = ?, agreement_key = ?, last_seen_at = ? WHERE id = ?",
        name,
        body.platform,
        agreementKey,
        now,
        h.id,
      );
    } else {
      this.sql.exec(
        "INSERT INTO devices(id, name, platform, signing_key, agreement_key, created_at, last_seen_at, removed_at, mac_screen_shared, owner_kind, owner_id) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0, 'user', ?)",
        h.id,
        name,
        body.platform,
        signingKey,
        agreementKey,
        now,
        now,
        this.ownerId,
      );
      this.audit("device_added", { deviceId: h.id, detail: `${h.id} ${name}` });
    }
    this.broadcast({ type: "devices.changed" });
    return json({ device: publicDevice(this.device(h.id)!, this.online(h.id)) });
  }

  private async dispatch(request: Request, url: URL, raw: Uint8Array, me: DeviceRow, c: CallContext): Promise<Response> {
    const m = request.method;
    const parts = url.pathname.split("/").filter(Boolean).slice(1); // drop "v1"
    const [a, b, d] = parts;
    const n = parts.length;

    if (a === "me" && n === 1 && m === "GET") {
      const plan = (await relayEntitlement(this.env, c.userId, c.stackToken)) === "paid" ? "paid" : "free";
      return json({ userId: c.userId, plan, device: publicDevice(me, this.online(me.id)) });
    }
    if (a === "user" && b === "ws" && n === 2 && m === "GET") return this.openSocket(request, me);
    if (a === "devices") {
      if (n === 1 && m === "GET") {
        const rows = this.sql.exec("SELECT * FROM devices WHERE removed_at IS NULL ORDER BY created_at").toArray() as unknown as DeviceRow[];
        return json({ devices: rows.map((r) => publicDevice(r, this.online(r.id))) });
      }
      if (n === 2 && m === "PATCH") return this.renameDevice(b!, this.parse(raw));
      if (n === 2 && m === "DELETE") return this.removeDevice(b!);
      if (n === 3 && d === "mac-screen" && m === "PUT") return this.setSharing(me, b!, this.parse(raw));
      if (n === 3 && d === "sign-out" && m === "POST") return this.signOut(me, b!);
    }
    if (a === "permissions") {
      if (n === 1 && m === "GET") return this.listPermissions(url.searchParams.get("host"));
      if (n === 3 && m === "PUT") return this.setPermission(me, b!, d!, this.parse(raw));
    }
    if (a === "sessions") {
      if (n === 1 && m === "POST") return this.requestSession(me, this.parse(raw), c);
      if (n === 3 && m === "POST") {
        if (!SESSION_ID.test(b!)) throw notFound("session not found");
        if (d === "decision") return this.decide(me, b!, this.parse(raw), c);
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

  private openSocket(request: Request, me: DeviceRow): Response {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") throw new ApiError(426, "bad_request", "expected a WebSocket upgrade");
    this.closeSockets(me.id, 4000, "replaced");
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], [me.id]);
    this.sql.exec("DELETE FROM offline WHERE device_id = ?", me.id);
    // Everyone refetches, including this device: its cached list may say it is offline.
    this.broadcast({ type: "devices.changed" });
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(_ws: WebSocket, _message: string | ArrayBuffer): Promise<void> {
    // Devices only send pings, answered by the auto-response without waking us.
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

  async webSocketError(ws: WebSocket): Promise<void> {
    const [deviceId] = this.ctx.getTags(ws);
    if (deviceId) await this.markOffline(deviceId, ws);
  }

  /** Starts the grace period for a device whose last socket went away. */
  private async markOffline(deviceId: string, closing: WebSocket) {
    const others = this.liveSockets(deviceId).filter((w) => w !== closing);
    if (others.length > 0) return;
    const d = this.device(deviceId);
    if (!d || d.removed_at !== null) return;
    const open = this.sql.exec("SELECT 1 FROM sessions WHERE state != 'ended' AND (viewer_id = ? OR host_id = ?) LIMIT 1", deviceId, deviceId).toArray();
    if (open.length === 0) return;
    this.sql.exec("INSERT INTO offline(device_id, since) VALUES (?, ?) ON CONFLICT(device_id) DO NOTHING", deviceId, Date.now());
    await this.scheduleAlarm();
  }

  private closeGraceMs(): number {
    const v = Number(this.env.CLOSE_GRACE_MS);
    return Number.isFinite(v) && v >= 0 && this.env.CLOSE_GRACE_MS ? v : CLOSE_GRACE_MS;
  }

  /** One alarm serves both offline grace periods and provisional socket-close ends. */
  private async scheduleAlarm() {
    const off = this.sql.exec("SELECT MIN(since) AS t FROM offline").one().t as number | null;
    const close = this.sql.exec("SELECT MIN(at) AS t FROM closing").one().t as number | null;
    const pending = this.sql.exec("SELECT MIN(created_at) AS t FROM sessions WHERE state = 'pending'").one().t as number | null;
    const times = [
      off === null ? null : off + OFFLINE_GRACE_MS,
      close === null ? null : close + this.closeGraceMs(),
      pending === null ? null : pending + PENDING_TTL_MS,
    ].filter((t): t is number => t !== null);
    if (times.length === 0) return;
    const at = Math.min(...times);
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > at) await this.ctx.storage.setAlarm(at);
  }

  /** Ends the sessions of devices that stayed offline past the grace period. */
  async alarm(): Promise<void> {
    const now = Date.now();
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
    this.closeSockets(id, 4003, "signed out");
    this.broadcast({ type: "devices.changed" }, id);
    return json({});
  }

  private async setSharing(me: DeviceRow, id: string, body: Record<string, unknown>): Promise<Response> {
    if (id !== me.id) {
      this.liveDevice(id);
      throw new ApiError(403, "not_host", "only the device itself can change its Mac Screen sharing");
    }
    if (typeof body.shared !== "boolean") throw badRequest("shared must be a boolean");
    const was = me.mac_screen_shared === 1;
    if (was !== body.shared) {
      this.sql.exec("UPDATE devices SET mac_screen_shared = ? WHERE id = ?", body.shared ? 1 : 0, id);
      this.audit(body.shared ? "shared" : "unshared", { hostId: id });
      if (!body.shared) {
        const open = this.sql.exec("SELECT * FROM sessions WHERE state != 'ended' AND host_id = ?", id).toArray() as unknown as SessionRow[];
        for (const s of open) await this.endSession(s, "sharing_off", "revoked", true);
      }
      this.broadcast({ type: "devices.changed" });
    }
    return json({ device: publicDevice(this.device(id)!, this.online(id)) });
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
    this.sql.exec(
      "INSERT INTO permissions(host_id, viewer_id, scope, updated_at, owner_kind, owner_id) VALUES (?, ?, ?, ?, 'user', ?) ON CONFLICT(host_id, viewer_id) DO UPDATE SET scope = excluded.scope, updated_at = excluded.updated_at",
      hostId,
      viewerId,
      scope,
      now,
      this.ownerId,
    );
    if (before !== scope) {
      this.audit("permission_changed", { hostId, viewerId, scope, detail: `${before}->${scope}` });
      // Lowering ends the sessions it no longer allows: none ends every session between
      // the pair (pending requests too), view ends full ones, ask ends view and full ones.
      // A pending request above the new permission stays: it already waits for the host.
      if (scope === "none" || rank(scope) < rank(before)) {
        const open = this.sql
          .exec("SELECT * FROM sessions WHERE state != 'ended' AND host_id = ? AND viewer_id = ?", hostId, viewerId)
          .toArray() as unknown as SessionRow[];
        for (const s of open) {
          const ends = scope === "none" || (s.state !== "pending" && rank(s.scope) > rank(scope));
          if (ends) await this.endSession(s, "permission_revoked", "revoked", true);
        }
      }
    }
    this.broadcast({ type: "permissions.changed", hostId });
    return before;
  }

  // ---- sessions ----

  private async requestSession(me: DeviceRow, body: Record<string, unknown>, c: CallContext): Promise<Response> {
    const hostId = str(body.hostId, "hostId", 64);
    const scope = body.scope as Scope;
    if (scope !== "view" && scope !== "full") throw badRequest("scope must be view or full");
    if (hostId === me.id) throw badRequest("a device cannot view itself");
    const host = this.liveDevice(hostId);
    if (host.mac_screen_shared !== 1) throw new ApiError(403, "not_shared", "the host does not share its screen");
    const perm = this.permission(hostId, me.id);
    if (perm === "none") throw new ApiError(403, "permission_none", "the host does not allow this device");
    // A scope above the saved permission (View Only asking for Full Control) is a
    // request to the host, decided on its prompt like a request under Ask.
    if (!this.online(hostId)) throw new ApiError(409, "host_offline", "the host is not connected");
    const now = Date.now();
    const id = crypto.randomUUID();
    this.sql.exec(
      "INSERT INTO sessions(id, viewer_id, host_id, scope, state, created_at, owner_kind, owner_id) VALUES (?, ?, ?, ?, 'pending', ?, 'user', ?)",
      id,
      me.id,
      hostId,
      scope,
      now,
      this.ownerId,
    );
    this.audit("requested", { viewerId: me.id, hostId, scope, sessionId: id });
    if (rank(perm) >= rank(scope)) {
      this.audit("approved", { viewerId: me.id, hostId, scope, sessionId: id, detail: "permission" });
      await this.approveOrEnd(this.session(id)!, c);
    } else {
      await this.scheduleAlarm();
      this.send(hostId, {
        type: "session.request",
        session: { id, viewerId: me.id, viewerName: me.name, viewerKeyFingerprint: await keyFingerprint(me.signing_key), scope },
      });
    }
    const s = this.session(id)!;
    return json({ session: { id: s.id, state: s.state, scope: s.scope } });
  }

  /** Approves, or ends the session (approve_failed) when the Session DO or tickets cannot be set up. */
  private async approveOrEnd(s: SessionRow, c: CallContext) {
    try {
      await this.approve(s, c);
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
  private async approve(s: SessionRow, c: CallContext) {
    this.sql.exec("UPDATE sessions SET state = 'approved', scope = ? WHERE id = ? AND state != 'ended'", s.scope, s.id);
    if (!this.stillOpen(s.id)) return;
    // Ask billing now (in parallel with the Session DO init); fail closed.
    const entitled = relayEntitlement(this.env, c.userId, c.stackToken).catch(() => "error" as const);
    const viewer = this.device(s.viewer_id)!;
    const host = this.device(s.host_id)!;
    const stub = this.env.SESSION_DO.get(this.env.SESSION_DO.idFromName(s.id));
    const init = await stub.fetch("https://session.do/internal/init", {
      method: "POST",
      body: JSON.stringify({
        sid: s.id,
        userId: c.userId,
        scope: s.scope,
        viewer: { id: viewer.id, key: viewer.signing_key },
        host: { id: host.id, key: host.signing_key },
      }),
    });
    // Ended during init: endSession closed the Session DO (a close that got there
    // first makes init refuse), so there is nothing to start.
    if (!this.stillOpen(s.id)) return;
    if (!init.ok) throw new Error(`session init ${init.status}`);
    const ice: IceServer[] = (await entitled) === "paid" ? await mintTurn(this.env) : [];
    if (!this.stillOpen(s.id)) return;
    const signalURL = `${c.origin.replace(/^http/, "ws")}/v1/sessions/${s.id}/ws`;
    for (const [self, peer, role] of [
      [viewer, host, "viewer"],
      [host, viewer, "host"],
    ] as const) {
      const ticket = await mintTicket(this.env, { sid: s.id, role, dev: self.id, peer: peer.id, peerKey: peer.signing_key, scope: s.scope });
      if (!this.stillOpen(s.id)) return;
      this.send(self.id, {
        type: "session.ticket",
        sessionId: s.id,
        ticket,
        signalURL,
        ice,
        peer: { id: peer.id, name: peer.name, signingKey: peer.signing_key },
        role,
        scope: s.scope,
      });
    }
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
  private async endSession(s: SessionRow, reason: string, push: "revoked" | "ended", closeSignal: boolean) {
    const current = this.session(s.id);
    if (!current || current.state === "ended") return;
    this.sql.exec("DELETE FROM closing WHERE session_id = ?", s.id);
    const now = Date.now();
    this.sql.exec("UPDATE sessions SET state = 'ended', ended_at = ?, end_reason = ? WHERE id = ?", now, reason, s.id);
    const durationS = current.started_at ? Math.round((now - current.started_at) / 1000) : null;
    this.audit("ended", { viewerId: s.viewer_id, hostId: s.host_id, scope: current.scope, sessionId: s.id, detail: reason, durationS });
    const msg = { type: push === "revoked" ? "session.revoked" : "session.ended", sessionId: s.id, reason };
    this.send(s.viewer_id, msg);
    this.send(s.host_id, msg);
    if (closeSignal && current.state !== "pending") {
      const stub = this.env.SESSION_DO.get(this.env.SESSION_DO.idFromName(s.id));
      await stub.fetch("https://session.do/internal/close", { method: "POST", body: JSON.stringify({ reason }) });
    }
  }

  private async ice(me: DeviceRow, id: string, c: CallContext): Promise<Response> {
    const s = this.session(id);
    if (!s || (s.viewer_id !== me.id && s.host_id !== me.id)) throw notFound("session not found");
    if (s.state !== "approved" && s.state !== "live") throw new ApiError(409, "session_not_active", "session is not active");
    const ice = (await relayEntitlement(this.env, c.userId, c.stackToken)) === "paid" ? await mintTurn(this.env) : [];
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

  private async internal(path: string, request: Request): Promise<Response> {
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
