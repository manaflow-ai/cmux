import { DurableObject } from "cloudflare:workers"
import { primaryProject, type Caller } from "./auth.ts"
import type { Env } from "./env.ts"
import { userTeams } from "./stack.ts"

/** Per-socket identity, set by the Worker after auth and device checks (never by the client). */
export interface Attachment {
  userId: string
  /** The Stack project of `userId`; identity is the pair. */
  projectId: string
  deviceId: string
  kind: "mac" | "phone"
  name: string
  /** Set before the hub closes a socket that a newer connection of the same device replaced. */
  replaced?: boolean
}

export interface MacPresence {
  deviceId: string
  name: string
  online: boolean
  lastSeenAt: string | null
  ownerUserId: string
}

const SIGNAL_KINDS = new Set(["webrtc-offer", "webrtc-answer", "webrtc-ice", "wg-init", "wg-resp", "wg-endpoints", "bye"])
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const MEMBER_TTL_MS = 60_000
const NON_MEMBER_TTL_MS = 15_000
const SESSION_TTL_MS = 24 * 3600_000
const MAX_TEXT_FRAME = 64 * 1024
/**
 * The WireGuard relay frames (`[16 sessionId][16 to][datagram]`) are retired (PROTOCOL.md): WireGuard without a
 * UDP path uses TURN over TLS. An older client still sends them until its route is confirmed; each is dropped,
 * and its sender hears `relay_retired` at most once per socket and session in this interval. The error always
 * names the frame's session: a sessionless error would fail every dial that client has in progress.
 */
export const RELAY_ERROR_INTERVAL_MS = 5000

/**
 * Token buckets per socket, in memory only: text (signaling), and binary (an older client's retired relay
 * frames), which bounds how often a flood of them costs a refusal check; excess frames are dropped silently.
 */
export const BUCKETS = { text: { rate: 20, burst: 60 }, binary: { rate: 12000, burst: 24000 } } as const

export const uuidToBytes = (id: string): Uint8Array => {
  const hex = id.replace(/-/g, "")
  const out = new Uint8Array(16)
  for (let i = 0; i < 16; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16)
  return out
}

export const bytesToUuid = (b: Uint8Array): string => {
  const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("")
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}

/**
 * One per team (idFromName(teamId)): signaling (introductions) and Mac presence of
 * PROTOCOL.md, on hibernating WebSockets. SQLite holds Mac presence rows and link sessions so a
 * hibernation wake keeps the admission state; the membership cache and rate buckets are memory only.
 */
export class TeamHub extends DurableObject<Env> {
  private readonly sql: SqlStorage
  private readonly members = new Map<string, { ok: boolean; at: number }>()
  private readonly buckets = new WeakMap<WebSocket, { text: { t: number; at: number }; binary: { t: number; at: number } }>()
  private readonly sessions = new Map<string, { initiator: string; responder: string }>()
  /** Deserialized attachments: read on every frame, and deserializing each time is the costly part. */
  private readonly attachments = new WeakMap<WebSocket, Attachment>()
  private colo: string | null | undefined
  private readonly relayErrors = new WeakMap<WebSocket, Map<string, number>>()
  /** The open socket of each device, so a signal needs no socket scan (rebuilt lazily after hibernation). */
  private readonly live = new Map<string, WebSocket>()

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    this.sql = ctx.storage.sql
    this.sql.exec(`CREATE TABLE IF NOT EXISTS macs (device_id TEXT PRIMARY KEY, name TEXT NOT NULL, owner_user_id TEXT NOT NULL, last_seen_at INTEGER)`)
    // owner_project_id: added with multi-project support; NULL (older rows) means the primary project.
    if (!this.sql.exec<{ name: string }>(`PRAGMA table_info(macs)`).toArray().some((c) => c.name === "owner_project_id"))
      this.sql.exec(`ALTER TABLE macs ADD COLUMN owner_project_id TEXT`)
    // Devices registered in this team (both kinds), so a signal socket is admitted here without a
    // database round trip (the Worker falls back to the database for a device this hub has not seen).
    this.sql.exec(`CREATE TABLE IF NOT EXISTS devices (device_id TEXT PRIMARY KEY, owner_key TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL)`)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS sessions (session_id TEXT PRIMARY KEY, initiator TEXT NOT NULL, responder TEXT NOT NULL, created_at INTEGER NOT NULL)`)
  }

  // ---- RPC from the Worker -------------------------------------------------------------------

  /** Team membership through Stack, cached 60 s (15 s for a refusal). Throws when Stack fails. */
  async isMember(teamId: string, caller: Caller): Promise<boolean> {
    const key = `${caller.projectId}\u0000${caller.userId}`
    const hit = this.members.get(key)
    const now = Date.now()
    if (hit && now - hit.at < (hit.ok ? MEMBER_TTL_MS : NON_MEMBER_TTL_MS)) return hit.ok
    const ok = (await userTeams(this.env, caller)).includes(teamId)
    this.members.set(key, { ok, at: now })
    return ok
  }

  /** A device registered in this team (POST /v1/devices): admits its signal socket here later. */
  async rememberDevice(d: { deviceId: string; ownerKey: string; kind: "mac" | "phone"; name: string }): Promise<void> {
    this.sql.exec(
      `INSERT INTO devices (device_id, owner_key, kind, name) VALUES (?, ?, ?, ?)
       ON CONFLICT(device_id) DO UPDATE SET owner_key = excluded.owner_key, kind = excluded.kind, name = excluded.name`,
      d.deviceId,
      d.ownerKey,
      d.kind,
      d.name
    )
  }

  /** A device moved to another team: this hub no longer admits it (its open socket stays until it reconnects). */
  async forgetRegistration(deviceId: string): Promise<void> {
    this.sql.exec(`DELETE FROM devices WHERE device_id = ?`, deviceId)
  }

  /** A Mac registered (or renamed) in this team. Broadcasts presence when the name changed. */
  async registerMac(m: { deviceId: string; name: string; ownerUserId: string; ownerProjectId: string }): Promise<void> {
    const prev = this.macRow(m.deviceId)
    this.sql.exec(
      `INSERT INTO macs (device_id, name, owner_user_id, owner_project_id, last_seen_at) VALUES (?, ?, ?, ?, NULL)
       ON CONFLICT(device_id) DO UPDATE SET name = excluded.name, owner_user_id = excluded.owner_user_id, owner_project_id = excluded.owner_project_id`,
      m.deviceId,
      m.name,
      m.ownerUserId,
      m.ownerProjectId
    )
    if (!prev || prev.name !== m.name) this.broadcast(JSON.stringify({ type: "presence", mac: this.presenceOf(m.deviceId) }))
  }

  /** A Mac moved to another team: drop it here and close its sockets. */
  async forgetMac(deviceId: string): Promise<void> {
    this.sql.exec(`DELETE FROM devices WHERE device_id = ?`, deviceId)
    this.sql.exec(`DELETE FROM macs WHERE device_id = ?`, deviceId)
    for (const ws of this.ctx.getWebSockets(deviceId)) {
      this.setAttach(ws, { ...this.attach(ws), replaced: true })
      try {
        ws.close(4001, "moved")
      } catch {}
    }
  }

  /**
   * A device was deleted (PROTOCOL.md `DELETE /v1/devices/:deviceId`): drop a Mac from presence with a last
   * `removed` frame, close the device's socket with 4002 `removed`, and end its signaling sessions.
   */
  async forgetDevice(deviceId: string): Promise<void> {
    this.sql.exec(`DELETE FROM devices WHERE device_id = ?`, deviceId)
    const mac = this.macRow(deviceId)
    if (mac) {
      this.sql.exec(`DELETE FROM macs WHERE device_id = ?`, deviceId)
      const lastSeenAt = mac.last_seen_at ? new Date(mac.last_seen_at).toISOString() : null
      this.broadcast(JSON.stringify({ type: "presence", mac: { deviceId, name: mac.name, online: false, lastSeenAt, removed: true } }))
    }
    for (const ws of this.ctx.getWebSockets(deviceId)) {
      this.setAttach(ws, { ...this.attach(ws), replaced: true })
      try {
        ws.close(4002, "removed")
      } catch {}
    }
    this.live.delete(deviceId)
    for (const r of this.sql.exec<{ session_id: string }>(`SELECT session_id FROM sessions WHERE initiator = ? OR responder = ?`, deviceId, deviceId).toArray())
      this.sessions.delete(r.session_id)
    this.sql.exec(`DELETE FROM sessions WHERE initiator = ? OR responder = ?`, deviceId, deviceId)
  }

  /** The colo this hub runs in (diagnostics: a hub stays where it was first created). */
  async placement(): Promise<{ colo: string | null }> {
    if (this.env.ENVIRONMENT === "test") return { colo: null }
    if (this.colo === undefined) {
      try {
        const trace = await (await fetch("https://www.cloudflare.com/cdn-cgi/trace")).text()
        this.colo = /^colo=(\w+)$/m.exec(trace)?.[1] ?? null
      } catch {
        return { colo: null }
      }
    }
    return { colo: this.colo }
  }

  async macs(): Promise<Array<MacPresence>> {
    return this.sql
      .exec<{ device_id: string }>(`SELECT device_id FROM macs ORDER BY name`)
      .toArray()
      .map((r) => this.presence(r.device_id)!)
  }

  // ---- WebSocket -------------------------------------------------------------------------------

  override async fetch(req: Request): Promise<Response> {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("expected websocket", { status: 426 })
    let att = JSON.parse(req.headers.get("x-cnx-attachment") ?? "null") as Attachment | null
    // The Worker's fast path: only the caller's identity and device id; the device row is this hub's.
    const claim = JSON.parse(req.headers.get("x-cnx-claim") ?? "null") as { userId: string; projectId: string; deviceId: string; ownerKey: string } | null
    if (!att && claim) {
      const row = this.sql
        .exec<{ owner_key: string; kind: string; name: string }>(`SELECT owner_key, kind, name FROM devices WHERE device_id = ?`, claim.deviceId)
        .toArray()[0]
      if (!row) return new Response("unknown device", { status: 409 })
      if (row.owner_key !== claim.ownerKey) return new Response("not owner", { status: 403 })
      att = { userId: claim.userId, projectId: claim.projectId, deviceId: claim.deviceId, kind: row.kind === "mac" ? "mac" : "phone", name: row.name }
    }
    if (!att) return new Response("missing identity", { status: 400 })
    if (!claim) {
      // The slow path checked the database: remember the device for next time.
      const ownerKey = req.headers.get("x-cnx-owner-key")
      if (ownerKey) await this.rememberDevice({ deviceId: att.deviceId, ownerKey, kind: att.kind, name: att.name })
    }
    // One live socket per device: a reconnect replaces the old socket without an offline blip.
    for (const old of this.ctx.getWebSockets(att.deviceId)) {
      this.setAttach(old, { ...this.attach(old), replaced: true })
      try {
        old.close(4000, "replaced")
      } catch {}
    }
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    this.ctx.acceptWebSocket(server, [att.deviceId])
    this.setAttach(server, att)
    this.live.set(att.deviceId, server)
    if (att.kind === "mac") {
      this.sql.exec(
        `INSERT INTO macs (device_id, name, owner_user_id, owner_project_id, last_seen_at) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(device_id) DO UPDATE SET name = excluded.name, owner_user_id = excluded.owner_user_id, owner_project_id = excluded.owner_project_id, last_seen_at = excluded.last_seen_at`,
        att.deviceId,
        att.name,
        att.userId,
        att.projectId,
        Date.now()
      )
    }
    server.send(JSON.stringify({ type: "hello", you: att.deviceId, macs: await this.macs() }))
    if (att.kind === "mac") this.broadcast(JSON.stringify({ type: "presence", mac: this.presenceOf(att.deviceId) }), server)
    const proto = req.headers.get("x-cnx-subprotocol")
    return new Response(null, { status: 101, webSocket: client, ...(proto ? { headers: { "sec-websocket-protocol": proto } } : {}) })
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const att = this.attach(ws)
    if (att.replaced) return
    if (typeof message === "string") {
      if (!this.take(ws, "text")) return this.error(ws, "rate_limited", "too many signaling frames")
      if (message.length > MAX_TEXT_FRAME) return this.error(ws, "bad_request", "frame too large")
      let f: { type?: unknown; to?: unknown; from?: unknown; sessionId?: unknown; payload?: { kind?: unknown } }
      try {
        f = JSON.parse(message)
      } catch {
        return this.error(ws, "bad_request", "invalid JSON")
      }
      if (f.type !== "signal") return this.error(ws, "bad_request", "unknown frame type")
      if (typeof f.to !== "string" || !UUID.test(f.to)) return this.error(ws, "bad_request", "to must be a deviceId")
      if (f.from !== undefined && f.from !== att.deviceId) return this.error(ws, "bad_request", "from must be your deviceId")
      if (typeof f.sessionId !== "string" || !UUID.test(f.sessionId)) return this.error(ws, "bad_request", "sessionId must be a UUID")
      // Named by session: a refused signal of one session must not fail the client's other dials.
      if (typeof f.payload !== "object" || f.payload === null || typeof f.payload.kind !== "string" || !SIGNAL_KINDS.has(f.payload.kind))
        return this.error(ws, "bad_request", "unknown payload kind", f.sessionId)
      if (!this.admit(att, f.to, f.sessionId)) return this.error(ws, "not_owner", "not allowed to signal this device", f.sessionId)
      const target = this.open(f.to)
      if (!target) return this.error(ws, "offline", "device is offline", f.sessionId)
      // fromUserId is always the verified sender (PROTOCOL.md); any client value is dropped.
      target.send(JSON.stringify({ type: "signal", to: f.to, from: att.deviceId, fromUserId: att.userId, sessionId: f.sessionId, payload: f.payload }))
      if (f.payload.kind === "bye") this.endSession(f.sessionId)
      return
    }
    // A retired relay frame from an older client: [16 sessionId][16 to][datagram]. Never forwarded.
    if (!this.take(ws, "binary")) return
    if (message.byteLength < 16) return
    const sessionId = bytesToUuid(new Uint8Array(message, 0, 16))
    this.relayError(ws, "relay_retired", "WireGuard relay frames are retired; this app version needs an update to connect without UDP", sessionId)
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    this.gone(ws)
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    this.gone(ws)
  }

  // ---- internals -------------------------------------------------------------------------------

  /** Rows and attachments from before multi-project support carry no project: they are the primary project's. */
  private get primary(): string {
    return primaryProject(this.env).id
  }

  private attach(ws: WebSocket): Attachment {
    let att = this.attachments.get(ws)
    if (!att) {
      att = ws.deserializeAttachment() as Attachment
      if (att) this.attachments.set(ws, att)
    }
    return att
  }

  private setAttach(ws: WebSocket, att: Attachment) {
    ws.serializeAttachment(att)
    this.attachments.set(ws, att)
  }

  private gone(ws: WebSocket) {
    const att = this.attach(ws)
    try {
      ws.close(1000, "bye")
    } catch {}
    if (!att || att.replaced || att.kind !== "mac") return
    if (this.open(att.deviceId, ws)) return
    this.sql.exec(`UPDATE macs SET last_seen_at = ? WHERE device_id = ?`, Date.now(), att.deviceId)
    if (this.macRow(att.deviceId)) this.broadcast(JSON.stringify({ type: "presence", mac: this.presenceOf(att.deviceId) }), ws)
  }

  /** The open, non-replaced socket of a device (excluding `except`). */
  private open(deviceId: string, except?: WebSocket): WebSocket | undefined {
    const usable = (w: WebSocket) => w !== except && w.readyState === WebSocket.OPEN && !this.attach(w).replaced
    const hit = this.live.get(deviceId)
    if (hit && usable(hit)) return hit
    const found = this.ctx.getWebSockets(deviceId).find(usable)
    if (found) this.live.set(deviceId, found)
    else if (hit && hit !== except) this.live.delete(deviceId)
    return found
  }

  /**
   * PROTOCOL.md admission: `to` is a Mac owned by the sender's user, the same sub in the same Stack project (this opens or continues the
   * session), or the sender is the Mac answering an existing session. A sessionId is bound to its
   * first two parties; reusing it for anyone else is refused.
   */
  private admit(att: Attachment, to: string, sessionId: string): boolean {
    if (to === att.deviceId) return false
    const s = this.session(sessionId)
    if (s) return (s.initiator === att.deviceId && s.responder === to) || (s.initiator === to && s.responder === att.deviceId)
    const mac = this.macRow(to)
    if (!mac || mac.owner_user_id !== att.userId || (mac.owner_project_id ?? this.primary) !== (att.projectId ?? this.primary)) return false
    const now = Date.now()
    this.sql.exec(`DELETE FROM sessions WHERE created_at < ?`, now - SESSION_TTL_MS)
    this.sql.exec(`INSERT INTO sessions (session_id, initiator, responder, created_at) VALUES (?, ?, ?, ?)`, sessionId, att.deviceId, to, now)
    this.sessions.set(sessionId, { initiator: att.deviceId, responder: to })
    return true
  }

  private session(id: string): { initiator: string; responder: string } | undefined {
    const hit = this.sessions.get(id)
    if (hit) return hit
    const r = this.sql.exec<{ initiator: string; responder: string; created_at: number }>(`SELECT initiator, responder, created_at FROM sessions WHERE session_id = ?`, id).toArray()[0]
    if (!r || Date.now() - r.created_at > SESSION_TTL_MS) return undefined
    const s = { initiator: r.initiator, responder: r.responder }
    this.sessions.set(id, s)
    return s
  }

  private endSession(id: string) {
    this.sessions.delete(id)
    this.sql.exec(`DELETE FROM sessions WHERE session_id = ?`, id)
  }

  private macRow(deviceId: string) {
    return this.sql
      .exec<{ name: string; owner_user_id: string; owner_project_id: string | null; last_seen_at: number | null }>(
        `SELECT name, owner_user_id, owner_project_id, last_seen_at FROM macs WHERE device_id = ?`,
        deviceId
      )
      .toArray()[0]
  }

  private presence(deviceId: string): MacPresence | undefined {
    const r = this.macRow(deviceId)
    if (!r) return undefined
    return { deviceId, name: r.name, online: !!this.open(deviceId), lastSeenAt: r.last_seen_at ? new Date(r.last_seen_at).toISOString() : null, ownerUserId: r.owner_user_id }
  }

  /** The presence frame body: PROTOCOL.md `{deviceId, name, online, lastSeenAt}`. */
  private presenceOf(deviceId: string) {
    const p = this.presence(deviceId)!
    return { deviceId: p.deviceId, name: p.name, online: p.online, lastSeenAt: p.lastSeenAt }
  }

  private broadcast(text: string, except?: WebSocket) {
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === except || ws.readyState !== WebSocket.OPEN || this.attach(ws)?.replaced) continue
      try {
        ws.send(text)
      } catch {}
    }
  }

  private error(ws: WebSocket, code: string, message: string, sessionId?: string) {
    try {
      ws.send(JSON.stringify({ type: "error", code, message, ...(sessionId ? { sessionId } : {}) }))
    } catch {}
  }

  private relayError(ws: WebSocket, code: string, message: string, sessionId: string) {
    let sent = this.relayErrors.get(ws)
    if (!sent) {
      sent = new Map()
      this.relayErrors.set(ws, sent)
    }
    const now = Date.now()
    const last = sent.get(sessionId)
    if (last !== undefined && now - last < RELAY_ERROR_INTERVAL_MS) return
    if (sent.size >= 256) sent.clear()
    sent.set(sessionId, now)
    this.error(ws, code, message, sessionId)
  }

  private take(ws: WebSocket, kind: "text" | "binary"): boolean {
    const now = Date.now()
    let b = this.buckets.get(ws)
    if (!b) {
      b = { text: { t: BUCKETS.text.burst, at: now }, binary: { t: BUCKETS.binary.burst, at: now } }
      this.buckets.set(ws, b)
    }
    const s = b[kind]
    s.t = Math.min(BUCKETS[kind].burst, s.t + ((now - s.at) / 1000) * BUCKETS[kind].rate)
    s.at = now
    if (s.t < 1) return false
    s.t -= 1
    return true
  }
}
