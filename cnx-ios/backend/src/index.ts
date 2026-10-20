import { authenticate, bearerOf, primaryProject, stackProjects, type Caller } from "./auth.ts"
import type { Env } from "./env.ts"
import { iceServers } from "./ice.ts"
import { createTeam, sendTeamInvite, userTeams } from "./stack.ts"
import { apnsConfig, apnsTopics, clean, sendApns } from "./push.ts"
import { openStore, PUSH_KINDS, type Device, type PushKind, type Store } from "./store.ts"
import type { Attachment } from "./team-hub.ts"
import { Timing, timingFor } from "./timing.ts"

export { TeamHub } from "./team-hub.ts"

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const TEAM_ID = /^[A-Za-z0-9_-]{1,128}$/
const PERSONAL = "personal-"
/**
 * The personal space of a user. Keyed by `sub` alone so the wire format stays `personal-<sub>`: Stack
 * subs are random v4 UUIDs, so dev and prod users never share one in practice, and every owner check
 * behind it (device ownership, link admission) compares (project, sub), so even a shared sub could not
 * reach the other project's Macs.
 */
export const personalTeamId = (userId: string) => `${PERSONAL}${userId}`
const COLOR = /^#[0-9A-Fa-f]{6}$/
const WG_KEY = /^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/
const EMAIL = /^[^\s@]{1,64}@[^\s@]{1,255}$/
const APNS_TOKEN = /^[0-9a-f]{64,200}$/
const EVENT_ID = /^[A-Za-z0-9._:-]{1,64}$/
const OPAQUE_ID = /^[A-Za-z0-9._:-]{1,128}$/

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })
const fail = (status: number, code: string, message: string) => {
  const res = json({ error: { code, message } }, status)
  // Rate limits use one-minute windows.
  if (status === 429) res.headers.set("retry-after", "60")
  return res
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string
  ) {
    super(message)
  }
}

/** Workers rate limiting (PROTOCOL.md): a missing binding (tests, local) never limits. */
const limit = async (binding: RateLimit | undefined, key: string, what: string) => {
  if (!binding) return
  const { success } = await binding.limit({ key })
  if (!success) throw new HttpError(429, "rate_limited", `too many ${what}; try again in a minute`)
}

const readJson = async (req: Request): Promise<Record<string, unknown>> => {
  try {
    const v = await req.json()
    if (typeof v === "object" && v !== null && !Array.isArray(v)) return v as Record<string, unknown>
  } catch {}
  throw new HttpError(400, "bad_request", "body must be a JSON object")
}

/**
 * Per-project namespacing. The primary project keeps its bare names (existing hubs and rows stay where
 * they are); every other project's hubs and prefs rows are prefixed with its project id, so a team id or
 * personal space id that appeared in two projects would still be two separate spaces.
 */
const scoped = (env: Env, caller: Caller, key: string) => (caller.projectId === primaryProject(env).id ? key : `${caller.projectId}:${key}`)
/**
 * Where a new TeamHub should live: the region of the caller's own location (Cloudflare's geolocation of the
 * client), not of the colo that received the request. A Durable Object stays where it is first created, and
 * free-plan traffic is sometimes received far away (a California client was served from Paris on 2026-10-13),
 * so creating hubs next to the ingress colo stranded them across an ocean. Only affects a hub's creation.
 */
export const locationHintFor = (cf: { continent?: unknown; longitude?: unknown; country?: unknown } | undefined): DurableObjectLocationHint | undefined => {
  if (!cf || typeof cf.continent !== "string") return undefined
  const lon = typeof cf.longitude === "string" ? Number.parseFloat(cf.longitude) : typeof cf.longitude === "number" ? cf.longitude : Number.NaN
  switch (cf.continent) {
    case "NA":
      return Number.isFinite(lon) && lon < -100 ? "wnam" : "enam"
    case "SA":
      return "sam"
    case "EU":
      return Number.isFinite(lon) && lon > 20 ? "eeur" : "weur"
    case "AF":
      return "afr"
    case "OC":
      return "oc"
    case "AS":
      return ["AE", "BH", "IL", "IQ", "IR", "JO", "KW", "LB", "OM", "QA", "SA", "SY", "YE"].includes(String(cf.country)) ? "me" : "apac"
    default:
      return undefined
  }
}

/** The caller's identity plus where a hub created by this request should live. */
type Ctx = Caller & { readonly hint?: DurableObjectLocationHint; readonly t: Timing }
const hub = (env: Env, caller: Ctx, teamId: string) =>
  env.TEAM_HUB.get(env.TEAM_HUB.idFromName(scoped(env, caller, teamId)), caller.hint ? { locationHint: caller.hint } : undefined)
/**
 * The caller's identity in stored rows (devices.owner_user_id, team_prefs.user_id): the bare sub for the
 * primary project, `<projectId>:<sub>` otherwise. This records the project without a schema change, and the
 * existing ownership checks on owner_user_id then compare (project, sub). Stack subs are UUIDs (no ":").
 */
const ownerKey = (env: Env, caller: Caller) => scoped(env, caller, caller.userId)
const splitOwner = (env: Env, key: string): { projectId: string; userId: string } => {
  const i = key.indexOf(":")
  return i < 0 ? { projectId: primaryProject(env).id, userId: key } : { projectId: key.slice(0, i), userId: key.slice(i + 1) }
}

const requireMember = async (env: Env, teamId: string, caller: Ctx) => {
  if (!TEAM_ID.test(teamId)) throw new HttpError(400, "bad_request", "invalid teamId")
  // Personal space (PROTOCOL.md): `personal-<userId>` belongs to that user alone; no Stack call.
  if (teamId.startsWith(PERSONAL)) {
    if (teamId !== personalTeamId(caller.userId)) throw new HttpError(403, "not_member", "not a member of this team")
    return
  }
  let ok: boolean
  try {
    ok = await caller.t.span("member", hub(env, caller, teamId).isMember(teamId, { userId: caller.userId, projectId: caller.projectId, token: caller.token }))
  } catch (e) {
    console.log(JSON.stringify({ msg: "membership check failed", error: String(e) }))
    throw new HttpError(502, "membership_unavailable", "could not check team membership")
  }
  if (!ok) throw new HttpError(403, "not_member", "not a member of this team")
}

const withStore = async <T>(env: Env, ctx: ExecutionContext, f: (s: Store) => Promise<T>): Promise<T> => {
  const t = timingFor(ctx)
  const store = await t.span("db_connect", openStore(env))
  try {
    return await t.span("db", f(store))
  } finally {
    ctx.waitUntil(store.close().catch(() => {}))
  }
}

/** The PROTOCOL.md device object: `ownerUserId` is the bare sub (the project is recorded, not returned). */
const publicDevice = (env: Env, d: Device): Device => ({ ...d, ownerUserId: splitOwner(env, d.ownerUserId).userId })

const colo = (req: Request): string | null => {
  const c = (req as Request & { cf?: { colo?: unknown } }).cf?.colo
  return typeof c === "string" ? c : null
}

const later = (a: string | null, b: string | null) => (!a ? b : !b ? a : a > b ? a : b)

/**
 * Per-isolate caches for the launch path (Server-Timing showed each costs a round trip to Stack, the
 * database in us-east-1 or Cloudflare's TURN API on every request):
 * - devices the signal socket admits, for a minute (a registration refreshes it, a deletion drops it and
 *   evicts the device's sockets, so a stale entry cannot outlive the device);
 * - the caller's Stack teams for /me/macs, for a minute, one fetch in flight per user;
 * - TURN credentials, for a tenth of their lifetime, one fetch in flight.
 */
const DEVICE_TTL_MS = 60_000
const deviceCache = new Map<string, { device: Device; at: number }>()
const rememberDevice = (device: Device) => deviceCache.set(device.deviceId, { device, at: Date.now() })
const signalDevice = async (env: Env, ctx: ExecutionContext, deviceId: string): Promise<Device | undefined> => {
  const hit = deviceCache.get(deviceId)
  if (hit && Date.now() - hit.at < DEVICE_TTL_MS) {
    timingFor(ctx).add("device_cached", 0)
    return hit.device
  }
  const device = await withStore(env, ctx, (s) => s.getDevice(deviceId))
  if (device) rememberDevice(device)
  return device
}

const TEAMS_TTL_MS = 60_000
const teamsCache = new Map<string, { at: number; teams: Promise<ReadonlyArray<string>> }>()
const cachedUserTeams = (env: Env, caller: Caller): Promise<ReadonlyArray<string>> => {
  const key = `${caller.projectId}\u0000${caller.userId}`
  const hit = teamsCache.get(key)
  if (hit && Date.now() - hit.at < TEAMS_TTL_MS) return hit.teams
  const teams = userTeams(env, caller)
  teamsCache.set(key, { at: Date.now(), teams })
  teams.catch(() => teamsCache.delete(key))
  return teams
}

let iceCache: { at: number; ttl: number; value: Promise<Awaited<ReturnType<typeof iceServers>>> } | undefined
const cachedIceServers = (env: Env): Promise<Awaited<ReturnType<typeof iceServers>>> => {
  const now = Date.now()
  if (iceCache && now - iceCache.at < (iceCache.ttl * 1000) / 10) return iceCache.value
  const value = iceServers(env)
  const entry = { at: now, ttl: 300, value }
  iceCache = entry
  value.then(
    (v) => {
      // Only a TURN answer is worth keeping; STUN-only means TURN failed, so ask again next time.
      if (v.turn) entry.ttl = v.ttl
      else if (iceCache === entry) iceCache = undefined
    },
    () => {
      if (iceCache === entry) iceCache = undefined
    }
  )
  return value
}

const routes = async (req: Request, env: Env, ctx: ExecutionContext): Promise<Response> => {
  const url = new URL(req.url)
  const path = url.pathname.replace(/\/+$/, "") || "/"
  const method = req.method

  if (path === "/v1/health" && method === "GET")
    return json({ ok: true, version: env.API_VERSION, stackProjects: stackProjects(env).map((p) => p.id), colo: colo(req) })

  const bearer = bearerOf(req)
  if (!bearer) return fail(401, "unauthorized", "missing or invalid Stack access token")
  const t = timingFor(ctx)
  const auth = await t.span("auth", authenticate(env, bearer.token))
  // The reason (expired, restricted, unknown_key, ...) names why without echoing the token.
  if (!("caller" in auth)) return fail(401, "unauthorized", `missing or invalid Stack access token (${auth.rejection})`)
  const caller: Ctx = { ...auth.caller, t, hint: locationHintFor((req as { cf?: { continent?: unknown; longitude?: unknown; country?: unknown } }).cf) }
  const me = ownerKey(env, caller)
  await t.span("limit", limit(env.USER_LIMIT, me, "requests"))

  if (path === "/v1/ice" && method === "GET") {
    await limit(env.ICE_LIMIT, me, "ICE requests")
    const { iceServers: list, ttl, turn } = await t.span("turn", cachedIceServers(env))
    return json({ iceServers: list, ttl, turn })
  }

  if (path === "/v1/me/bootstrap" && method === "POST") {
    // The phone's launch in one round trip (PROTOCOL.md): register its devices in `teamId`, and return
    // that team's Macs, the caller's own Macs everywhere, and ICE servers. Each part runs the same route
    // as its own call, all at once; a part that fails carries its error instead of failing the rest.
    const b = await readJson(req)
    if (typeof b.teamId !== "string") throw new HttpError(400, "bad_request", "teamId is required")
    const list = Array.isArray(b.devices) ? (b.devices as Array<Record<string, unknown>>).slice(0, 4) : []
    const headers = { authorization: req.headers.get("authorization") ?? `Bearer ${bearer.token}`, "content-type": "application/json" }
    const part = async (method: string, path: string, body?: unknown) => {
      const sub = new Request(new URL(path, url), { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
      let res: Response
      try {
        res = await routes(sub, env, ctx)
      } catch (e) {
        res = e instanceof HttpError ? fail(e.status, e.code, e.message) : fail(500, "internal", "internal error")
      }
      return (await res.json()) as Record<string, unknown>
    }
    const team = encodeURIComponent(b.teamId)
    const [devices, macs, myMacs, ice] = await Promise.all([
      Promise.all(list.map((d) => part("POST", "/v1/devices", { ...d, teamId: b.teamId }))),
      part("GET", `/v1/teams/${team}/macs`),
      part("GET", "/v1/me/macs"),
      part("GET", "/v1/ice")
    ])
    return json({ devices, macs, myMacs, ice })
  }

  if (path === "/v1/me/devices" && method === "GET") {
    const rows = await withStore(env, ctx, (s) => s.listOwnerDevices(me))
    // Presence for Macs from each team's hub (only teams the caller can still reach).
    const macTeams = [...new Set(rows.filter((d) => d.kind === "mac").map((d) => d.teamId))]
    const live = new Map<string, boolean>()
    await Promise.all(
      macTeams.map(async (t) => {
        try {
          await requireMember(env, t, caller)
          for (const m of await hub(env, caller, t).macs()) live.set(m.deviceId, m.online)
        } catch {}
      })
    )
    return json({
      devices: rows.map((d) => ({
        deviceId: d.deviceId,
        kind: d.kind,
        name: d.name,
        teamId: d.teamId,
        createdAt: d.createdAt,
        updatedAt: d.updatedAt,
        lastSeenAt: d.lastSeenAt,
        online: d.kind === "mac" ? (live.get(d.deviceId) ?? false) : null,
        push: d.push
      }))
    })
  }

  if (path === "/v1/me" && method === "DELETE") {
    // Account deletion (PROTOCOL.md): purge everything stored for the caller and evict their sockets.
    const gone = await withStore(env, ctx, (s) => s.deleteOwner(me))
    for (const d of gone) deviceCache.delete(d.deviceId)
    await Promise.all(gone.map((d) => hub(env, caller, d.teamId).forgetDevice(d.deviceId).catch(() => {})))
    console.log(JSON.stringify({ msg: "account data deleted", devices: gone.length }))
    return json({ deleted: { devices: gone.length } })
  }

  const dev = path.match(/^\/v1\/devices\/([^/]+)(?:\/(push|notify))?$/)
  if (dev) {
    const deviceId = decodeURIComponent(dev[1]!).toLowerCase()
    if (!UUID.test(deviceId)) throw new HttpError(400, "bad_request", "deviceId must be a UUID")
    const sub = dev[2]
    if (!sub && method === "DELETE") {
      deviceCache.delete(deviceId)
      const r = await withStore(env, ctx, (s) => s.deleteDevice(deviceId, me))
      if (r === "not_owner") throw new HttpError(403, "not_owner", "this device belongs to another user")
      if (!r) throw new HttpError(404, "not_found", "no such device")
      await hub(env, caller, r.teamId).forgetDevice(deviceId)
      return json({ deleted: true, deviceId })
    }
    if (sub === "push" && (method === "PUT" || method === "DELETE")) {
      const device = await withStore(env, ctx, (s) => s.getDevice(deviceId))
      if (!device) throw new HttpError(404, "not_found", "no such device")
      if (device.ownerUserId !== me) throw new HttpError(403, "not_owner", "this device belongs to another user")
      if (method === "DELETE") {
        await withStore(env, ctx, (s) => s.deletePush(deviceId))
        return json({ deleted: true })
      }
      if (device.kind !== "phone") throw new HttpError(400, "bad_request", "only a phone takes push notifications")
      const b = await readJson(req)
      const token = typeof b.token === "string" ? b.token.toLowerCase() : ""
      if (!APNS_TOKEN.test(token)) throw new HttpError(400, "bad_request", "token must be the APNs device token in hex")
      if (b.environment !== "sandbox" && b.environment !== "production") throw new HttpError(400, "bad_request", "environment must be sandbox or production")
      if (typeof b.topic !== "string" || !apnsTopics(env).has(b.topic)) throw new HttpError(400, "bad_request", "topic is not an app this service pushes to")
      let kinds: Array<PushKind> = [...PUSH_KINDS]
      if (b.kinds !== undefined) {
        if (!Array.isArray(b.kinds) || b.kinds.some((k) => !(PUSH_KINDS as ReadonlyArray<unknown>).includes(k)))
          throw new HttpError(400, "bad_request", `kinds must be a list of ${PUSH_KINDS.join(", ")}`)
        kinds = [...new Set(b.kinds as Array<PushKind>)]
      }
      const r = await withStore(env, ctx, (s) => s.setPush({ deviceId, ownerUserId: me, token, environment: b.environment as "sandbox" | "production", topic: b.topic as string, kinds }))
      return json({ push: { environment: r.environment, topic: r.topic, kinds: r.kinds, updatedAt: r.updatedAt } })
    }
    if (sub === "notify" && method === "POST") {
      const b = await readJson(req)
      if (typeof b.eventId !== "string" || !EVENT_ID.test(b.eventId)) throw new HttpError(400, "bad_request", "eventId must be 1-64 of A-Z a-z 0-9 . _ : -")
      if (!(PUSH_KINDS as ReadonlyArray<unknown>).includes(b.kind)) throw new HttpError(400, "bad_request", `kind must be one of ${PUSH_KINDS.join(", ")}`)
      for (const k of ["workspaceId", "tabId", "sessionId"] as const)
        if (b[k] !== undefined && b[k] !== null && (typeof b[k] !== "string" || !OPAQUE_ID.test(b[k] as string))) throw new HttpError(400, "bad_request", `${k} must be an id`)
      const device = await withStore(env, ctx, (s) => s.getDevice(deviceId))
      if (!device) throw new HttpError(404, "not_found", "no such device")
      if (device.ownerUserId !== me || device.kind !== "mac") throw new HttpError(403, "not_owner", "notify from your own Mac")
      await limit(env.NOTIFY_LIMIT, deviceId, "notifications")
      const config = apnsConfig(env)
      const kind = b.kind as PushKind
      const targets = config ? (await withStore(env, ctx, (s) => s.listOwnerPush(me))).filter((t) => t.kinds.includes(kind)).slice(0, 20) : []
      if (!config || targets.length === 0) return json({ configured: !!config, sent: 0, failed: 0, dropped: 0 })
      const results = await sendApns(config, targets, {
        eventId: b.eventId,
        kind,
        agent: clean(b.agent, 40),
        place: clean(b.place, 60),
        macId: deviceId,
        macName: clean(device.name, 40),
        ...(typeof b.workspaceId === "string" ? { workspaceId: b.workspaceId } : {}),
        ...(typeof b.tabId === "string" ? { tabId: b.tabId } : {}),
        ...(typeof b.sessionId === "string" ? { sessionId: b.sessionId } : {})
      }, Date.now())
      const drop = results.filter((r) => r.outcome === "drop_target").map((r) => r.token)
      if (drop.length) await withStore(env, ctx, (s) => s.dropPushTokens(drop))
      const failed = results.filter((r) => r.outcome === "failed")
      if (failed.length) console.log(JSON.stringify({ msg: "apns failed", results: failed.map((r) => ({ status: r.status, reason: r.reason })) }))
      return json({ configured: true, sent: results.filter((r) => r.outcome === "sent").length, failed: failed.length, dropped: drop.length })
    }
    return fail(405, "method_not_allowed", "method not allowed")
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
      s.upsertDevice({ deviceId: deviceId.toLowerCase(), ownerUserId: ownerKey(env, caller), teamId, kind, name: name.trim(), wgPublicKey: (wgPublicKey as string | null | undefined) ?? null })
    )
    if (r === "not_owner") throw new HttpError(403, "not_owner", "this deviceId belongs to another user")
    rememberDevice(r.device)
    if (r.previousTeamId) {
      await hub(env, caller, r.previousTeamId).forgetMac(r.device.deviceId)
      await hub(env, caller, r.previousTeamId).forgetRegistration(r.device.deviceId)
    }
    await t.span("hub", hub(env, caller, teamId).rememberDevice({ deviceId: r.device.deviceId, ownerKey: r.device.ownerUserId, kind: r.device.kind, name: r.device.name }))
    if (r.device.kind === "mac")
      await hub(env, caller, teamId).registerMac({ deviceId: r.device.deviceId, name: r.device.name, ownerUserId: caller.userId, ownerProjectId: caller.projectId })
    return json({ device: publicDevice(env, r.device) })
  }

  if (path === "/v1/me/macs" && method === "GET") {
    // The caller's own Macs in every space they can reach (PROTOCOL.md): a phone finds its Mac whatever
    // team either side has selected. Only Macs the caller registered (the v1 admission rule), only teams
    // the caller still belongs to, presence from each team's hub.
    const rows = await withStore(env, ctx, (s) => s.listOwnerMacs(ownerKey(env, caller)))
    const teamIds = [...new Set(rows.map((d) => d.teamId))]
    let stackTeams: ReadonlySet<string> = new Set()
    if (teamIds.some((t) => !t.startsWith(PERSONAL))) {
      try {
        stackTeams = new Set(await t.span("stack", cachedUserTeams(env, caller)))
      } catch (e) {
        console.log(JSON.stringify({ msg: "membership check failed", error: String(e) }))
        throw new HttpError(502, "membership_unavailable", "could not check team membership")
      }
    }
    const reachable = teamIds.filter((t) => (t.startsWith(PERSONAL) ? t === personalTeamId(caller.userId) : stackTeams.has(t)))
    const live = new Map(
      await t.span("hub", Promise.all(reachable.map(async (team) => [team, new Map((await hub(env, caller, team).macs()).map((m) => [m.deviceId, m]))] as const)))
    )
    return json({
      macs: rows.flatMap((d) => {
        const presence = live.get(d.teamId)
        if (!presence) return []
        const p = presence.get(d.deviceId)
        return [{ deviceId: d.deviceId, name: d.name, teamId: d.teamId, online: p?.online ?? false, lastSeenAt: later(d.lastSeenAt, p?.lastSeenAt ?? null), ownerUserId: caller.userId }]
      })
    })
  }

  if (path === "/v1/teams" && method === "POST") {
    // Create team (PROTOCOL.md): Stack's client API refuses it, so the Worker creates the team with the
    // caller's project server key and the caller as its creator and first member.
    const b = await readJson(req)
    const name = typeof b.name === "string" ? b.name.trim() : ""
    if (!name || name.length > 64 || /\p{Cc}/u.test(name)) throw new HttpError(400, "bad_request", "name must be 1 to 64 characters, no control characters")
    await limit(env.TEAM_LIMIT, me, "team creations")
    const r = await createTeam(env, caller, name)
    if (!r.ok) {
      if (r.code === "team_creation_unavailable") return fail(503, r.code, "this service can't create teams for your account yet")
      return fail(r.status === 401 || r.status === 403 ? 403 : 502, "team_create_failed", `Stack refused the team (${r.code})`)
    }
    // The caller's cached memberships predate the new team.
    teamsCache.delete(`${caller.projectId}\u0000${caller.userId}`)
    return json({ team: { id: r.id, name: r.name } })
  }

  const team = path.match(/^\/v1\/teams\/([^/]+)\/(macs|prefs|invites|signal|hub)$/)
  if (!team) return fail(404, "not_found", "no such route")
  const teamId = decodeURIComponent(team[1]!)
  const action = team[2]!

  if (action === "signal" && method === "GET") {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return fail(426, "upgrade_required", "expected a WebSocket upgrade")
    const deviceId = (url.searchParams.get("deviceId") ?? "").toLowerCase()
    if (!UUID.test(deviceId)) throw new HttpError(400, "bad_request", "deviceId must be a UUID")
    await requireMember(env, teamId, caller)
    // Echo only cnx.v1; the bearer subprotocol is never selected (it would echo the token back).
    const subprotocol = bearer?.viaSubprotocol || (req.headers.get("sec-websocket-protocol") ?? "").split(",").some((p) => p.trim() === "cnx.v1")
    const teamHub = hub(env, caller, teamId)
    // Fast path: the team's hub knows the devices registered in it, so no database round trip.
    const claim = { userId: caller.userId, projectId: caller.projectId, deviceId, ownerKey: ownerKey(env, caller) }
    const fast = new Headers({ upgrade: "websocket", "x-cnx-claim": JSON.stringify(claim) })
    if (subprotocol) fast.set("x-cnx-subprotocol", "cnx.v1")
    const res = await t.span("hub", teamHub.fetch("https://team-hub/signal", { headers: fast }))
    if (res.status === 101) return res
    if (res.status === 403) throw new HttpError(403, "not_owner", "register this device first")
    // The hub has not seen this device (registered before hubs kept devices): check the database.
    const device = await signalDevice(env, ctx, deviceId)
    if (!device || device.ownerUserId !== ownerKey(env, caller)) throw new HttpError(403, "not_owner", "register this device first")
    if (device.teamId !== teamId) throw new HttpError(403, "wrong_team", "device is registered in another team")
    const att: Attachment = { userId: caller.userId, projectId: caller.projectId, deviceId, kind: device.kind, name: device.name }
    const headers = new Headers({ upgrade: "websocket", "x-cnx-attachment": JSON.stringify(att), "x-cnx-owner-key": device.ownerUserId })
    if (subprotocol) headers.set("x-cnx-subprotocol", "cnx.v1")
    return t.span("hub", teamHub.fetch("https://team-hub/signal", { headers }))
  }

  if (action === "hub" && method === "GET") {
    // Diagnostics (PROTOCOL.md): where this request entered Cloudflare and where the team's hub runs.
    await requireMember(env, teamId, caller)
    const placed = await hub(env, caller, teamId).placement()
    return json({ ingressColo: colo(req), hubColo: placed.colo, locationHint: caller.hint ?? null })
  }

  if (action === "macs" && method === "GET") {
    await requireMember(env, teamId, caller)
    const [rows, live] = await Promise.all([withStore(env, ctx, (s) => s.listMacs(teamId)), t.span("hub", hub(env, caller, teamId).macs())])
    const byId = new Map(live.map((m) => [m.deviceId, m]))
    return json({
      // Only Macs of the caller's project: a team (and a personal space) never spans projects.
      macs: rows.flatMap((d) => {
        const owner = splitOwner(env, d.ownerUserId)
        if (owner.projectId !== caller.projectId) return []
        const p = byId.get(d.deviceId)
        return [{ deviceId: d.deviceId, name: d.name, online: p?.online ?? false, lastSeenAt: later(d.lastSeenAt, p?.lastSeenAt ?? null), ownerUserId: owner.userId }]
      })
    })
  }

  if (action === "prefs" && method === "GET") {
    await requireMember(env, teamId, caller)
    return json(await withStore(env, ctx, (s) => s.getPrefs(ownerKey(env, caller), teamId)))
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
    return json(await withStore(env, ctx, (s) => s.putPrefs(ownerKey(env, caller), teamId, patch)))
  }

  if (action === "invites" && method === "POST") {
    const b = await readJson(req)
    if (typeof b.email !== "string" || !EMAIL.test(b.email)) throw new HttpError(400, "bad_request", "email is required")
    await limit(env.INVITE_LIMIT, me, "invitations")
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
    const t = timingFor(ctx)
    let res: Response
    try {
      res = await routes(req, env, ctx)
    } catch (e) {
      if (e instanceof HttpError) res = fail(e.status, e.code, e.message)
      else {
        console.log(JSON.stringify({ msg: "unhandled", error: String(e) }))
        res = fail(500, "internal", "internal error")
      }
    }
    const route = new URL(req.url).pathname.replace(/[0-9a-f-]{36}|personal-[0-9a-f-]+|teams\/[^/]+/g, (m) => (m.startsWith("teams/") ? "teams/:id" : ":id"))
    if (t.totalMs > 250) console.log(JSON.stringify({ msg: "timing", route, status: res.status, colo: colo(req), ...t.record() }))
    // Server-Timing on every response; a WebSocket upgrade's headers are rebuilt around its socket.
    if (res.status === 101 && res.webSocket) {
      const headers = new Headers(res.headers)
      headers.set("server-timing", t.header())
      return new Response(null, { status: 101, webSocket: res.webSocket, headers })
    }
    try {
      res.headers.set("server-timing", t.header())
      return res
    } catch {
      const headers = new Headers(res.headers)
      headers.set("server-timing", t.header())
      return new Response(res.body, { status: res.status, statusText: res.statusText, headers })
    }
  }
} satisfies ExportedHandler<Env>
