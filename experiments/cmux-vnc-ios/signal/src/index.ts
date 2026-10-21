/**
 * Signaling for cmux VNC over WebRTC. A room joins one host (a Mac running
 * `cmux-vnc-host`) and one viewer (the cmux VNC iOS app):
 *
 *   GET /v1/rooms/<room>/ws?role=host|viewer   WebSocket; header or query `secret`
 *   GET /v1/rooms/<room>/ice                   ICE servers for this room (same secret)
 *
 * The host's first connection fixes the room's secret (its SHA-256 is stored,
 * never the secret). Every later connection must present it. The room relays
 * text messages (offer, answer, candidate, bye) between the two sockets and
 * tells each side when the other joins or leaves. Media never passes here.
 */

export interface Env {
  ROOMS: DurableObjectNamespace
  CLOUDFLARE_TURN_KEY_ID?: string
  CLOUDFLARE_TURN_KEY_API_TOKEN?: string
}

const ROOM_ID = /^[a-f0-9]{32}$/
const STUN = { urls: ["stun:stun.cloudflare.com:3478"] }
const TURN_TTL_SECONDS = 3600

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)
    const match = url.pathname.match(/^\/v1\/rooms\/([^/]+)\/(ws|ice)$/)
    if (url.pathname === "/health") return Response.json({ ok: true })
    if (!match || !ROOM_ID.test(match[1])) return new Response("not found", { status: 404 })
    const room = env.ROOMS.get(env.ROOMS.idFromName(match[1]))
    if (match[2] === "ice") {
      // The room checks the secret; the Worker mints (its env always has the current secrets).
      const verdict = await room.fetch(request)
      if (verdict.status !== 204) return verdict
      const turn: { status: string } = { status: "" }
      return Response.json({ iceServers: await iceServers(env, turn), turn: turn.status })
    }
    return room.fetch(request)
  },
}

/** Sends, ignoring a socket that died without a close event (a reset connection). */
function send(socket: WebSocket, message: string): void {
  try {
    socket.send(message)
  } catch {
    try { socket.close(1011, "dead") } catch { /* gone */ }
  }
}

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("")
}

function secretOf(request: Request, url: URL): string | null {
  const value = request.headers.get("x-room-secret") ?? url.searchParams.get("secret")
  return value && value.length >= 32 && value.length <= 128 ? value : null
}

export class Room implements DurableObject {
  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url)
    const secret = secretOf(request, url)
    if (!secret) return new Response("missing secret", { status: 401 })
    const digest = await sha256(secret)
    const stored = await this.state.storage.get<string>("secret")
    const kind = url.pathname.endsWith("/ice") ? "ice" : "ws"
    const role = url.searchParams.get("role")

    if (!stored) {
      // Only a host may create a room.
      if (kind !== "ws" || role !== "host") return new Response("no such room", { status: 404 })
      await this.state.storage.put("secret", digest)
    } else if (stored !== digest) {
      return new Response("wrong secret", { status: 403 })
    }

    if (kind === "ice") return new Response(null, { status: 204 })
    if (request.headers.get("upgrade") !== "websocket") return new Response("expected websocket", { status: 426 })
    if (role !== "host" && role !== "viewer") return new Response("bad role", { status: 400 })

    // One socket per role: a new one replaces the old.
    for (const old of this.state.getWebSockets(role)) {
      try { old.close(4000, "replaced") } catch { /* already closed */ }
    }
    const pair = new WebSocketPair()
    this.state.acceptWebSocket(pair[1], [role])
    const other = role === "host" ? "viewer" : "host"
    const peers = this.state.getWebSockets(other)
    pair[1].send(JSON.stringify({ type: "hello", role, peer: peers.length > 0 }))
    for (const peer of peers) send(peer, JSON.stringify({ type: "peer-joined", role }))
    return new Response(null, { status: 101, webSocket: pair[0] })
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string" || message.length > 64 * 1024) return
    const [role] = this.state.getTags(socket)
    const other = role === "host" ? "viewer" : "host"
    for (const peer of this.state.getWebSockets(other)) send(peer, message)
  }

  async webSocketClose(socket: WebSocket): Promise<void> {
    const [role] = this.state.getTags(socket)
    const other = role === "host" ? "viewer" : "host"
    for (const peer of this.state.getWebSockets(other)) send(peer, JSON.stringify({ type: "peer-left", role }))
  }

  async webSocketError(socket: WebSocket): Promise<void> {
    await this.webSocketClose(socket)
  }
}

/** STUN always; Cloudflare Realtime TURN when the key is configured. */
/** `turn.status` says why there is no relay (no key, an HTTP status, an error); no secret values. */
async function iceServers(env: Env, turn: { status: string }): Promise<Array<{ urls: string[]; username?: string; credential?: string }>> {
  const keyId = env.CLOUDFLARE_TURN_KEY_ID?.trim()
  const token = env.CLOUDFLARE_TURN_KEY_API_TOKEN?.trim()
  if (!keyId || !token) {
    turn.status = "not configured"
    return [STUN]
  }
  try {
    const res = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(keyId)}/credentials/generate-ice-servers`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ ttl: TURN_TTL_SECONDS }),
    })
    if (!res.ok) {
      turn.status = `provider answered ${res.status}`
      return [STUN]
    }
    const body = (await res.json()) as { iceServers?: unknown }
    const raw = Array.isArray(body.iceServers) ? body.iceServers : body.iceServers ? [body.iceServers] : []
    const servers = (raw as Array<Record<string, unknown>>).flatMap((s) => {
      const urls = (Array.isArray(s.urls) ? s.urls : [s.urls]).filter((u): u is string => typeof u === "string" && /^(stun|turn|turns):/.test(u))
      return urls.length ? [{ urls, username: s.username as string | undefined, credential: s.credential as string | undefined }] : []
    })
    turn.status = servers.length ? "ok" : "no servers"
    return servers.length ? servers : [STUN]
  } catch (error) {
    turn.status = `error: ${String(error).slice(0, 120)}`
    return [STUN]
  }
}
