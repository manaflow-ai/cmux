import { and, eq, inArray, sql } from "drizzle-orm"
import type { Env } from "./env.ts"
import { devices, pushTokens, teamPrefs } from "./schema.ts"

export type DeviceKind = "mac" | "phone"

export interface Device {
  deviceId: string
  /** The owner key: the bare Stack sub for the primary project, `<projectId>:<sub>` otherwise (src/index.ts ownerKey). */
  ownerUserId: string
  teamId: string
  kind: DeviceKind
  name: string
  wgPublicKey: string | null
  createdAt: string
  updatedAt: string
  lastSeenAt: string | null
}

export interface DeviceInput {
  deviceId: string
  ownerUserId: string
  teamId: string
  kind: DeviceKind
  name: string
  wgPublicKey: string | null
}

export interface Prefs {
  color: string | null
  emoji: string | null
}

export type PushEnvironment = "sandbox" | "production"
export const PUSH_KINDS = ["question", "permission", "completed", "failed", "chief"] as const
export type PushKind = (typeof PUSH_KINDS)[number]

export interface PushRegistration {
  deviceId: string
  ownerUserId: string
  token: string
  environment: PushEnvironment
  topic: string
  kinds: Array<PushKind>
  updatedAt: string
}

export interface Store {
  getDevice(deviceId: string): Promise<Device | undefined>
  /** Insert or update; "not_owner" when the id already belongs to another user (nothing changes). */
  upsertDevice(d: DeviceInput): Promise<{ device: Device; previousTeamId: string | null } | "not_owner">
  /** Every Mac one owner registered, in any team or personal space (`ownerUserId` is the owner key). */
  listOwnerMacs(ownerUserId: string): Promise<Array<Device>>
  /** Every device (Mac or phone) of one owner, with whether it has a push token. */
  listOwnerDevices(ownerUserId: string): Promise<Array<Device & { push: boolean }>>
  /** Deletes a device and its push token; "not_owner" when another user owns it (nothing changes). */
  deleteDevice(deviceId: string, ownerUserId: string): Promise<Device | "not_owner" | undefined>
  /** Deletes every device, push token and pref of one owner; returns the deleted devices. */
  deleteOwner(ownerUserId: string): Promise<Array<Device>>
  setPush(p: Omit<PushRegistration, "updatedAt">): Promise<PushRegistration>
  deletePush(deviceId: string): Promise<void>
  /** Push registrations of the owner's phones. */
  listOwnerPush(ownerUserId: string): Promise<Array<PushRegistration>>
  /** Forget tokens APNs reported as gone. */
  dropPushTokens(tokens: ReadonlyArray<string>): Promise<void>
  getPrefs(userId: string, teamId: string): Promise<Prefs>
  /** Only the given fields change; `undefined` keeps the stored value. */
  putPrefs(userId: string, teamId: string, patch: Partial<Prefs>): Promise<Prefs>
  /**
   * Every team id the database knows (devices and team prefs), with the Stack project of its rows: null for the
   * primary project (bare owner keys), else the project id (`<projectId>:<sub>` keys). Names the old team hubs.
   */
  listTeamScopes(): Promise<Array<{ project: string | null; teamId: string }>>
  close(): Promise<void>
}

const iso = (d: Date | null) => (d ? d.toISOString() : null)
const row = (r: typeof devices.$inferSelect): Device => ({
  deviceId: r.deviceId,
  ownerUserId: r.ownerUserId,
  teamId: r.teamId,
  kind: r.kind,
  name: r.name,
  wgPublicKey: r.wgPublicKey,
  createdAt: r.createdAt.toISOString(),
  updatedAt: r.updatedAt.toISOString(),
  lastSeenAt: iso(r.lastSeenAt)
})

const pushRow = (r: typeof pushTokens.$inferSelect): PushRegistration => ({
  deviceId: r.deviceId,
  ownerUserId: r.ownerUserId,
  token: r.token,
  environment: r.environment,
  topic: r.topic,
  kinds: r.kinds.split(",").filter((k): k is PushKind => (PUSH_KINDS as ReadonlyArray<string>).includes(k)),
  updatedAt: r.updatedAt.toISOString()
})

/** PlanetScale Postgres through Hyperdrive; one connection per request (Hyperdrive pools). */
export const pgStore = async (hyperdrive: Hyperdrive): Promise<Store> => {
  // Loaded lazily: pg is CommonJS and only the deployed Worker (with Hyperdrive) needs it.
  const [{ default: pg }, { drizzle }] = await Promise.all([import("pg"), import("drizzle-orm/node-postgres")])
  const client = new pg.Client({ connectionString: hyperdrive.connectionString })
  await client.connect()
  const db = drizzle(client)
  return {
    async getDevice(deviceId) {
      const [r] = await db.select().from(devices).where(eq(devices.deviceId, deviceId)).limit(1)
      return r ? row(r) : undefined
    },
    async upsertDevice(d) {
      // Read the previous team for the move; the conditional update (setWhere) still refuses a racing other owner.
      const [prev] = await db.select({ teamId: devices.teamId, owner: devices.ownerUserId }).from(devices).where(eq(devices.deviceId, d.deviceId)).limit(1)
      if (prev && prev.owner !== d.ownerUserId) return "not_owner"
      const [r] = await db
        .insert(devices)
        .values({ ...d })
        .onConflictDoUpdate({
          target: devices.deviceId,
          set: { teamId: d.teamId, kind: d.kind, name: d.name, wgPublicKey: d.wgPublicKey, updatedAt: sql`now()` },
          setWhere: eq(devices.ownerUserId, d.ownerUserId)
        })
        .returning()
      if (!r) return "not_owner"
      return { device: row(r), previousTeamId: prev && prev.teamId !== d.teamId ? prev.teamId : null }
    },
    async listOwnerMacs(ownerUserId) {
      const rs = await db.select().from(devices).where(and(eq(devices.ownerUserId, ownerUserId), eq(devices.kind, "mac"))).orderBy(devices.name)
      return rs.map(row)
    },
    async listOwnerDevices(ownerUserId) {
      const rs = await db
        .select({ d: devices, token: pushTokens.token })
        .from(devices)
        .leftJoin(pushTokens, eq(pushTokens.deviceId, devices.deviceId))
        .where(eq(devices.ownerUserId, ownerUserId))
        .orderBy(devices.kind, devices.name)
      return rs.map((r) => ({ ...row(r.d), push: !!r.token }))
    },
    async deleteDevice(deviceId, ownerUserId) {
      const [prev] = await db.select().from(devices).where(eq(devices.deviceId, deviceId)).limit(1)
      if (!prev) return undefined
      if (prev.ownerUserId !== ownerUserId) return "not_owner"
      await db.delete(pushTokens).where(eq(pushTokens.deviceId, deviceId))
      const [r] = await db.delete(devices).where(and(eq(devices.deviceId, deviceId), eq(devices.ownerUserId, ownerUserId))).returning()
      return r ? row(r) : undefined
    },
    async deleteOwner(ownerUserId) {
      await db.delete(pushTokens).where(eq(pushTokens.ownerUserId, ownerUserId))
      await db.delete(teamPrefs).where(eq(teamPrefs.userId, ownerUserId))
      return (await db.delete(devices).where(eq(devices.ownerUserId, ownerUserId)).returning()).map(row)
    },
    async setPush(p) {
      const kinds = p.kinds.join(",")
      const [r] = await db
        .insert(pushTokens)
        .values({ ...p, kinds })
        .onConflictDoUpdate({ target: pushTokens.deviceId, set: { ownerUserId: p.ownerUserId, token: p.token, environment: p.environment, topic: p.topic, kinds, updatedAt: sql`now()` } })
        .returning()
      return pushRow(r!)
    },
    async deletePush(deviceId) {
      await db.delete(pushTokens).where(eq(pushTokens.deviceId, deviceId))
    },
    async listOwnerPush(ownerUserId) {
      return (await db.select().from(pushTokens).where(eq(pushTokens.ownerUserId, ownerUserId))).map(pushRow)
    },
    async dropPushTokens(tokens) {
      if (tokens.length) await db.delete(pushTokens).where(inArray(pushTokens.token, [...tokens]))
    },
    async getPrefs(userId, teamId) {
      const [r] = await db.select().from(teamPrefs).where(and(eq(teamPrefs.userId, userId), eq(teamPrefs.teamId, teamId))).limit(1)
      return { color: r?.color ?? null, emoji: r?.emoji ?? null }
    },
    async putPrefs(userId, teamId, patch) {
      const set: Record<string, unknown> = { updatedAt: sql`now()` }
      if (patch.color !== undefined) set.color = patch.color
      if (patch.emoji !== undefined) set.emoji = patch.emoji
      const [r] = await db
        .insert(teamPrefs)
        .values({ userId, teamId, color: patch.color ?? null, emoji: patch.emoji ?? null })
        .onConflictDoUpdate({ target: [teamPrefs.userId, teamPrefs.teamId], set })
        .returning()
      return { color: r?.color ?? null, emoji: r?.emoji ?? null }
    },
    async listTeamScopes() {
      const r = await client.query<{ project: string | null; team_id: string }>(
        `SELECT DISTINCT NULLIF(split_part(owner_user_id, ':', 1), owner_user_id) AS project, team_id FROM devices
         UNION SELECT DISTINCT NULLIF(split_part(user_id, ':', 1), user_id) AS project, team_id FROM team_prefs`
      )
      return r.rows.map((x) => ({ project: x.project, teamId: x.team_id }))
    },
    close: () => client.end()
  }
}

/** In-memory store for tests (ENVIRONMENT=test, no Hyperdrive binding). Shared per isolate. */
const mem = { devices: new Map<string, Device>(), prefs: new Map<string, Prefs>(), push: new Map<string, PushRegistration>() }
export const memoryStore = (): Store => ({
  async getDevice(id) {
    const d = mem.devices.get(id)
    return d ? { ...d } : undefined
  },
  async upsertDevice(d) {
    const prev = mem.devices.get(d.deviceId)
    if (prev && prev.ownerUserId !== d.ownerUserId) return "not_owner"
    const now = new Date().toISOString()
    const device: Device = { ...d, createdAt: prev?.createdAt ?? now, updatedAt: now, lastSeenAt: prev?.lastSeenAt ?? null }
    mem.devices.set(d.deviceId, device)
    return { device: { ...device }, previousTeamId: prev && prev.teamId !== d.teamId ? prev.teamId : null }
  },
  async listOwnerMacs(owner) {
    return [...mem.devices.values()].filter((d) => d.ownerUserId === owner && d.kind === "mac").sort((a, b) => a.name.localeCompare(b.name))
  },
  async listOwnerDevices(owner) {
    return [...mem.devices.values()]
      .filter((d) => d.ownerUserId === owner)
      .sort((a, b) => a.kind.localeCompare(b.kind) || a.name.localeCompare(b.name))
      .map((d) => ({ ...d, push: mem.push.has(d.deviceId) }))
  },
  async deleteDevice(id, owner) {
    const d = mem.devices.get(id)
    if (!d) return undefined
    if (d.ownerUserId !== owner) return "not_owner"
    mem.devices.delete(id)
    mem.push.delete(id)
    return { ...d }
  },
  async deleteOwner(owner) {
    const gone = [...mem.devices.values()].filter((d) => d.ownerUserId === owner)
    for (const d of gone) mem.devices.delete(d.deviceId)
    for (const [k, p] of mem.push) if (p.ownerUserId === owner) mem.push.delete(k)
    for (const k of mem.prefs.keys()) if (k.startsWith(`${owner}\u0000`)) mem.prefs.delete(k)
    return gone
  },
  async setPush(p) {
    const r = { ...p, kinds: [...p.kinds], updatedAt: new Date().toISOString() }
    mem.push.set(p.deviceId, r)
    return { ...r }
  },
  async deletePush(id) {
    mem.push.delete(id)
  },
  async listOwnerPush(owner) {
    return [...mem.push.values()].filter((p) => p.ownerUserId === owner).map((p) => ({ ...p }))
  },
  async dropPushTokens(tokens) {
    for (const [k, p] of mem.push) if (tokens.includes(p.token)) mem.push.delete(k)
  },
  async getPrefs(u, t) {
    return { ...(mem.prefs.get(`${u}\u0000${t}`) ?? { color: null, emoji: null }) }
  },
  async putPrefs(u, t, patch) {
    const k = `${u}\u0000${t}`
    const cur = mem.prefs.get(k) ?? { color: null, emoji: null }
    const next = { color: patch.color !== undefined ? patch.color : cur.color, emoji: patch.emoji !== undefined ? patch.emoji : cur.emoji }
    mem.prefs.set(k, next)
    return { ...next }
  },
  async listTeamScopes() {
    const scope = (owner: string) => (owner.includes(":") ? owner.slice(0, owner.indexOf(":")) : null)
    const all = [...[...mem.devices.values()].map((d) => ({ project: scope(d.ownerUserId), teamId: d.teamId })), ...[...mem.prefs.keys()].map((k) => ({ project: scope(k.split("\u0000")[0]!), teamId: k.split("\u0000")[1]! }))]
    return [...new Map(all.map((x) => [`${x.project}\u0000${x.teamId}`, x])).values()]
  },
  close: async () => {}
})

export const openStore = (env: Env): Promise<Store> => {
  if (env.HYPERDRIVE) return pgStore(env.HYPERDRIVE)
  if (env.ENVIRONMENT === "test") return Promise.resolve(memoryStore())
  throw new Error("no database binding")
}
