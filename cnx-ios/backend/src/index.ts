import { bearerOf, verifyStackToken, type Caller } from "./auth.ts"
import type { Env } from "./env.ts"
import { iceServers } from "./ice.ts"
import { sendTeamInvite } from "./stack.ts"
import { openStore, type Store } from "./store.ts"
import type { Attachment } from "./team-hub.ts"

export { TeamHub } from "./team-hub.ts"

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const TEAM_ID = /^[A-Za-z0-9_-]{1,128}$/
const PERSONAL = "personal-"
export const personalTeamId = (userId: string) => `${PERSONAL}${userId}`
const COLOR = /^#[0-9A-Fa-f]{6}$/
const WG_KEY = /^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/
const EMAIL = /^[^\s@]{1,64}@[^\s@]{1,255}$/

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })
const fail = (status: number, code: string, message: string) => json({ error: { code, message } }, status)

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string
  ) {
    super(message)
  }
}

const readJson = async (req: Request): Promise<Record<string, unknown>> => {
  try {
    const v = await req.json()
    if (typeof v === "object" && v !== null && !Array.isArray(v)) return v as Record<string, unknown>
  } catch {}
  throw new HttpError(400, "bad_request", "body must be a JSON object")
}

const hub = (env: Env, teamId: string) => env.TEAM_HUB.get(env.TEAM_HUB.idFromName(teamId))

const requireMember = async (env: Env, teamId: string, caller: Caller) => {
  if (!TEAM_ID.test(teamId)) throw new HttpError(400, "bad_request", "invalid teamId")
  // Personal space (PROTOCOL.md): `personal-<userId>` belongs to that user alone; no Stack call.
  if (teamId.startsWith(PERSONAL)) {
    if (teamId !== personalTeamId(caller.userId)) throw new HttpError(403, "not_member", "not a member of this team")
    return
  }
  let ok: boolean
  try {
    ok = await hub(env, teamId).isMember(teamId, caller)
  } catch (e) {
    console.log(JSON.stringify({ msg: "membership check failed", error: String(e) }))
    throw new HttpError(502, "membership_unavailable", "could not check team membership")
  }
  if (!ok) throw new HttpError(403, "not_member", "not a member of this team")
}

const withStore = async <T>(env: Env, ctx: ExecutionContext, f: (s: Store) => Promise<T>): Promise<T> => {
  const store = await openStore(env)
  try {
    return await f(store)
  } finally {
    ctx.waitUntil(store.close().catch(() => {}))
  }
}

const later = (a: string | null, b: string | null) => (!a ? b : !b ? a : a > b ? a : b)

const routes = async (req: Request, env: Env, ctx: ExecutionContext): Promise<Response> => {
  const url = new URL(req.url)
  const path = url.pathname.replace(/\/+$/, "") || "/"
  const method = req.method

  if (path === "/v1/health" && method === "GET") return json({ ok: true, version: env.API_VERSION })

  const bearer = bearerOf(req)
  const caller = bearer ? await verifyStackToken(env, bearer.token) : undefined
  if (!caller) return fail(401, "unauthorized", "missing or invalid Stack access token")

  if (path === "/v1/ice" && method === "GET") {
    const { iceServers: list, ttl } = await iceServers(env)
    return json({ iceServers: list, ttl })
  }

  if (path === "/v1/devices" && method === "POST") {
    const b = await readJson(req)
    const { deviceId, kind, name, teamId, wgPublicKey } = b
    if (typeof deviceId !== "string" || !UUID.test(deviceId.toLowerCase())) throw new HttpError(400, "bad_request", "deviceId must be a UUID")
    if (kind !== "mac" && kind !== "phone") throw new HttpError(400, "bad_request", "kind must be mac or phone")
    if (typeof name !== "string" || !name.trim() || name.length > 100) throw new HttpError(400, "bad_request", "name must be 1-100 characters")
    if (typeof teamId !== "string") throw new HttpError(400, "bad_request", "teamId is required")
    if (wgPublicKey !== undefined && wgPublicKey !== null && (typeof wgPublicKey !== "string" || !WG_KEY.test(wgPublicKey)))
      throw new HttpError(400, "bad_request", "wgPublicKey must be a base64 Curve25519 key")
    await requireMember(env, teamId, caller)
    const r = await withStore(env, ctx, (s) =>
      s.upsertDevice({ deviceId: deviceId.toLowerCase(), ownerUserId: caller.userId, teamId, kind, name: name.trim(), wgPublicKey: (wgPublicKey as string | null | undefined) ?? null })
    )
    if (r === "not_owner") throw new HttpError(403, "not_owner", "this deviceId belongs to another user")
    if (r.previousTeamId) await hub(env, r.previousTeamId).forgetMac(r.device.deviceId)
    if (r.device.kind === "mac") await hub(env, teamId).registerMac({ deviceId: r.device.deviceId, name: r.device.name, ownerUserId: r.device.ownerUserId })
    return json({ device: r.device })
  }

  const team = path.match(/^\/v1\/teams\/([^/]+)\/(macs|prefs|invites|signal)$/)
  if (!team) return fail(404, "not_found", "no such route")
  const teamId = decodeURIComponent(team[1]!)
  const action = team[2]!

  if (action === "signal" && method === "GET") {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return fail(426, "upgrade_required", "expected a WebSocket upgrade")
    const deviceId = (url.searchParams.get("deviceId") ?? "").toLowerCase()
    if (!UUID.test(deviceId)) throw new HttpError(400, "bad_request", "deviceId must be a UUID")
    await requireMember(env, teamId, caller)
    const device = await withStore(env, ctx, (s) => s.getDevice(deviceId))
    if (!device || device.ownerUserId !== caller.userId) throw new HttpError(403, "not_owner", "register this device first")
    if (device.teamId !== teamId) throw new HttpError(403, "wrong_team", "device is registered in another team")
    const att: Attachment = { userId: caller.userId, deviceId, kind: device.kind, name: device.name }
    const headers = new Headers({ upgrade: "websocket", "x-cnx-attachment": JSON.stringify(att) })
    // Echo only cnx.v1; the bearer subprotocol is never selected (it would echo the token back).
    if (bearer?.viaSubprotocol || (req.headers.get("sec-websocket-protocol") ?? "").split(",").some((p) => p.trim() === "cnx.v1")) headers.set("x-cnx-subprotocol", "cnx.v1")
    return hub(env, teamId).fetch("https://team-hub/signal", { headers })
  }

  if (action === "macs" && method === "GET") {
    await requireMember(env, teamId, caller)
    const [rows, live] = await Promise.all([withStore(env, ctx, (s) => s.listMacs(teamId)), hub(env, teamId).macs()])
    const byId = new Map(live.map((m) => [m.deviceId, m]))
    return json({
      macs: rows.map((d) => {
        const p = byId.get(d.deviceId)
        return { deviceId: d.deviceId, name: d.name, online: p?.online ?? false, lastSeenAt: later(d.lastSeenAt, p?.lastSeenAt ?? null), ownerUserId: d.ownerUserId }
      })
    })
  }

  if (action === "prefs" && method === "GET") {
    await requireMember(env, teamId, caller)
    return json(await withStore(env, ctx, (s) => s.getPrefs(caller.userId, teamId)))
  }

  if (action === "prefs" && method === "PUT") {
    const b = await readJson(req)
    const patch: { color?: string | null; emoji?: string | null } = {}
    if (b.color !== undefined) {
      if (b.color !== null && (typeof b.color !== "string" || !COLOR.test(b.color))) throw new HttpError(400, "bad_request", "color must be #RRGGBB")
      patch.color = b.color === null ? null : (b.color as string).toUpperCase()
    }
    if (b.emoji !== undefined) {
      // null = automatic (first letter), "" = none (color only), else one grapheme.
      if (b.emoji !== null && (typeof b.emoji !== "string" || (b.emoji !== "" && ([...new Intl.Segmenter().segment(b.emoji)].length !== 1 || b.emoji.length > 32 || !b.emoji.trim()))))
        throw new HttpError(400, "bad_request", "emoji must be one grapheme, empty, or null")
      patch.emoji = b.emoji as string | null
    }
    await requireMember(env, teamId, caller)
    return json(await withStore(env, ctx, (s) => s.putPrefs(caller.userId, teamId, patch)))
  }

  if (action === "invites" && method === "POST") {
    const b = await readJson(req)
    if (typeof b.email !== "string" || !EMAIL.test(b.email)) throw new HttpError(400, "bad_request", "email is required")
    await requireMember(env, teamId, caller)
    if (teamId.startsWith(PERSONAL)) throw new HttpError(400, "bad_request", "personal space has no members")
    const r = await sendTeamInvite(env, caller, teamId, b.email)
    if (!r.ok) return fail(r.status === 401 || r.status === 403 ? 403 : 502, "invite_failed", `Stack refused the invitation (${r.code})`)
    return json({ url: r.url, sent: true })
  }

  return fail(405, "method_not_allowed", "method not allowed")
}

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      return await routes(req, env, ctx)
    } catch (e) {
      if (e instanceof HttpError) return fail(e.status, e.code, e.message)
      console.log(JSON.stringify({ msg: "unhandled", error: String(e) }))
      return fail(500, "internal", "internal error")
    }
  }
} satisfies ExportedHandler<Env>
