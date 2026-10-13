import { DurableObject } from "cloudflare:workers"
import type { Caller } from "./auth.ts"
import type { Env } from "./env.ts"
import { userTeams } from "./stack.ts"

/** Per-socket identity, set by the Worker after auth and device checks (never by the client). */
export interface Attachment {
  userId: string
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

const SIGNAL_KINDS = new Set(["webrtc-offer", "webrtc-answer", "webrtc-ice", "wg-init", "wg-resp", "bye"])
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const MEMBER_TTL_MS = 60_000
const NON_MEMBER_TTL_MS = 15_000
const SESSION_TTL_MS = 24 * 3600_000
const MAX_TEXT_FRAME = 64 * 1024
const MAX_BINARY_FRAME = 32 + 65_535

/** Token buckets: text (signaling) and binary (WireGuard relay) per socket, in memory only. */
const BUCKETS = { text: { rate: 20, burst: 60 }, binary: { rate: 4000, burst: 8000 } } as const

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
 * One per team (idFromName(teamId)): signaling, Mac presence and the WireGuard relay of
 * PROTOCOL.md, on hibernating WebSockets. SQLite holds Mac presence rows and link sessions so a
 * hibernation wake keeps the admission state; the membership cache and rate buckets are memory only.
 */
export class TeamHub extends DurableObject<Env> {
  private readonly sql: SqlStorage
  private readonly members = new Map<string, { ok: boolean; at: number }>()
  private readonly buckets = new WeakMap<WebSocket, { text: { t: number; at: number }; binary: { t: number; at: number } }>()
  private readonly sessions = new Map<string, { initiator: string; responder: string }>()

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    this.sql = ctx.storage.sql
    this.sql.exec(`CREATE TABLE IF NOT EXISTS macs (device_id TEXT PRIMARY KEY, name TEXT NOT NULL, owner_user_id TEXT NOT NULL, last_seen_at INTEGER)`)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS sessions (session_id TEXT PRIMARY KEY, initiator TEXT NOT NULL, responder TEXT NOT NULL, created_at INTEGER NOT NULL)`)
  }

  // ---- RPC from the Worker -------------------------------------------------------------------

  /** Team membership through Stack, cached 60 s (15 s for a refusal). Throws when Stack fails. */
  async isMember(teamId: string, caller: Caller): Promise<boolean> {
    const hit = this.members.get(caller.userId)
    const now = Date.now()
    if (hit && now - hit.at < (hit.ok ? MEMBER_TTL_MS : NON_MEMBER_TTL_MS)) return hit.ok
    const ok = (await userTeams(this.env, caller)).includes(teamId)
    this.members.set(caller.userId, { ok, at: now })
    return ok
  }

  /** A Mac registered (or renamed) in this team. Broadcasts presence when the name changed. */
  async registerMac(m: { deviceId: string; name: string; ownerUserId: string }): Promise<void> {
    const prev = this.macRow(m.deviceId)
    this.sql.exec(
      `INSERT INTO macs (device_id, name, owner_user_id, last_seen_at) VALUES (?, ?, ?, NULL)
       ON CONFLICT(device_id) DO UPDATE SET name = excluded.name, owner_user_id = excluded.owner_user_id`,
      m.deviceId,
      m.name,
      m.ownerUserId
    )
    if (!prev || prev.name !== m.name) this.broadcast(JSON.stringify({ type: "presence", mac: this.presenceOf(m.deviceId) }))
  }

  /** A Mac moved to another team: drop it here and close its sockets. */
  async forgetMac(deviceId: string): Promise<void> {
    this.sql.exec(`DELETE FROM macs WHERE device_id = ?`, deviceId)
    for (const ws of this.ctx.getWebSockets(deviceId)) {
      ws.serializeAttachment({ ...this.attach(ws), replaced: true })
      try {
        ws.close(4001, "moved")
      } catch {}
    }
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
    const att = JSON.parse(req.headers.get("x-cnx-attachment") ?? "null") as Attachment | null
    if (!att) return new Response("missing identity", { status: 400 })
    // One live socket per device: a reconnect replaces the old socket without an offline blip.
    for (const old of this.ctx.getWebSockets(att.deviceId)) {
      old.serializeAttachment({ ...this.attach(old), replaced: true })
      try {
        old.close(4000, "replaced")
      } catch {}
    }
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    this.ctx.acceptWebSocket(server, [att.deviceId])
    server.serializeAttachment(att)
    if (att.kind === "mac") {
      this.sql.exec(
        `INSERT INTO macs (device_id, name, owner_user_id, last_seen_at) VALUES (?, ?, ?, ?)
         ON CONFLICT(device_id) DO UPDATE SET name = excluded.name, owner_user_id = excluded.owner_user_id, last_seen_at = excluded.last_seen_at`,
        att.deviceId,
        att.name,
        att.userId,
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
      if (typeof f.payload !== "object" || f.payload === null || typeof f.payload.kind !== "string" || !SIGNAL_KINDS.has(f.payload.kind))
        return this.error(ws, "bad_request", "unknown payload kind")
      if (!this.admit(att, f.to, f.sessionId)) return this.error(ws, "not_owner", "not allowed to signal this device", f.sessionId)
      const target = this.open(f.to)
      if (!target) return this.error(ws, "offline", "device is offline", f.sessionId)
      // fromUserId is always the verified sender (PROTOCOL.md); any client value is dropped.
      target.send(JSON.stringify({ type: "signal", to: f.to, from: att.deviceId, fromUserId: att.userId, sessionId: f.sessionId, payload: f.payload }))
      if (f.payload.kind === "bye") this.endSession(f.sessionId)
      return
    }
    // WireGuard relay: [16 sessionId][16 to][datagram]; `to` is rewritten to the sender.
    if (!this.take(ws, "binary")) return
    if (message.byteLength <= 32 || message.byteLength > MAX_BINARY_FRAME) return
    const bytes = new Uint8Array(message)
    const sessionId = bytesToUuid(bytes.subarray(0, 16))
    const to = bytesToUuid(bytes.subarray(16, 32))
    const s = this.session(sessionId)
    const ok = s && ((s.initiator === att.deviceId && s.responder === to) || (s.initiator === to && s.responder === att.deviceId))
    if (!ok) return this.error(ws, "not_owner", "no relay session with this device", sessionId)
    const target = this.open(to)
    if (!target) return this.error(ws, "offline", "device is offline", sessionId)
    const out = new Uint8Array(bytes)
    out.set(uuidToBytes(att.deviceId), 16)
    target.send(out)
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    this.gone(ws)
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    this.gone(ws)
  }

  // ---- internals -------------------------------------------------------------------------------

  private attach(ws: WebSocket): Attachment {
    return ws.deserializeAttachment() as Attachment
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
    return this.ctx.getWebSockets(deviceId).find((w) => w !== except && w.readyState === WebSocket.OPEN && !this.attach(w).replaced)
  }

  /**
   * PROTOCOL.md admission: `to` is a Mac owned by the sender's user (this opens or continues the
   * session), or the sender is the Mac answering an existing session. A sessionId is bound to its
   * first two parties; reusing it for anyone else is refused.
   */
  private admit(att: Attachment, to: string, sessionId: string): boolean {
    if (to === att.deviceId) return false
    const s = this.session(sessionId)
    if (s) return (s.initiator === att.deviceId && s.responder === to) || (s.initiator === to && s.responder === att.deviceId)
    const mac = this.macRow(to)
    if (!mac || mac.owner_user_id !== att.userId) return false
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
    return this.sql.exec<{ name: string; owner_user_id: string; last_seen_at: number | null }>(`SELECT name, owner_user_id, last_seen_at FROM macs WHERE device_id = ?`, deviceId).toArray()[0]
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
