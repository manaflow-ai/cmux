import { and, eq, sql } from "drizzle-orm"
import type { Env } from "./env.ts"
import { devices, teamPrefs } from "./schema.ts"

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

export interface Store {
  getDevice(deviceId: string): Promise<Device | undefined>
  /** Insert or update; "not_owner" when the id already belongs to another user (nothing changes). */
  upsertDevice(d: DeviceInput): Promise<{ device: Device; previousTeamId: string | null } | "not_owner">
  listMacs(teamId: string): Promise<Array<Device>>
  getPrefs(userId: string, teamId: string): Promise<Prefs>
  /** Only the given fields change; `undefined` keeps the stored value. */
  putPrefs(userId: string, teamId: string, patch: Partial<Prefs>): Promise<Prefs>
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
    async listMacs(teamId) {
      const rs = await db.select().from(devices).where(and(eq(devices.teamId, teamId), eq(devices.kind, "mac"))).orderBy(devices.name)
      return rs.map(row)
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
    close: () => client.end()
  }
}

/** In-memory store for tests (ENVIRONMENT=test, no Hyperdrive binding). Shared per isolate. */
const mem = { devices: new Map<string, Device>(), prefs: new Map<string, Prefs>() }
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
  async listMacs(teamId) {
    return [...mem.devices.values()].filter((d) => d.teamId === teamId && d.kind === "mac").sort((a, b) => a.name.localeCompare(b.name))
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
  close: async () => {}
})

export const openStore = (env: Env): Promise<Store> => {
  if (env.HYPERDRIVE) return pgStore(env.HYPERDRIVE)
  if (env.ENVIRONMENT === "test") return Promise.resolve(memoryStore())
  throw new Error("no database binding")
}
