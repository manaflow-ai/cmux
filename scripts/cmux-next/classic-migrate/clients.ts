// The one NEXT surface apply calls: cmux-platform's internal classic migration route (cmux-platform
// src/server/cloud/ClassicMigrationRoute.ts, bearer INTERNAL_TOKEN). The platform imports the classic VM's provider
// VM through the VM API itself, under the team's own tenant, so this tool sends only the upstream VM id. Every
// request is idempotent on (migration_id, classic_vm_id); the HTTP shapes live only here.

/** The platform's opaque id shape for migration_id and classic_vm_id (ClassicMigrationOps.ts CLASSIC_REF). */
export const CLASSIC_REF = /^[A-Za-z0-9._:/@-]{1,63}$/

/** CloudMachineSize as the route takes it: every axis optional, whole numbers in these bounds. */
export interface MachineSize {
  cpu?: number
  memory_mb?: number
  disk_mb?: number
}
export const SIZE_BOUNDS: Readonly<Record<keyof MachineSize, readonly [number, number]>> = {
  cpu: [1, 64],
  memory_mb: [512, 262144],
  disk_mb: [1024, 1048576],
}

export interface PlatformImportRequest {
  team: string
  creator_user: string
  migration_id: string
  classic_vm_id: string
  upstream_vm_id: string
  name?: string
  size: MachineSize
}
/** What the ledger keeps of a 201 (created) or 200 (existing) answer. */
export interface PlatformImportResult {
  status: string
  machine: string
  snapshot: string | null
  vm_api_snapshot_id: string | null
}
export interface PlatformDeleteRequest {
  team: string
  migration_id: string
  classic_vm_id: string
}
/** `deleting`: the provider delete is still running (the platform's alarm finishes it). */
export type PlatformDeleteStatus = "deleted" | "deleting" | "absent"
export interface PlatformListItem {
  classic_vm_id: string
  /** created | snapshot_only */
  status: string
  machine: { id: string; status: string } | null
  snapshot: { id: string } | null
}

export interface PlatformImports {
  importMachine(req: PlatformImportRequest): Promise<PlatformImportResult>
  /** Resolves when the platform has removed the machine, its snapshot row and its VM API imports (or found none). */
  deleteMachine(req: PlatformDeleteRequest): Promise<PlatformDeleteStatus>
  /** Every machine and snapshot row one migration made in one team. */
  list(team: string, migrationId: string): Promise<PlatformListItem[]>
}

/** A refused request: `permanent` (4xx but 408/409/429) means retrying the same body cannot succeed. */
export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly body: string,
    readonly what: string,
  ) {
    super(`${what}: HTTP ${status} ${body.slice(0, 300)}`)
  }
  get permanent() {
    return this.status >= 400 && this.status < 500 && ![408, 409, 429].includes(this.status)
  }
}

type Fetch = (input: string, init: RequestInit) => Promise<Response>

const call = async (fetchFn: Fetch, what: string, url: string, token: string, method: string, body?: unknown) => {
  const res = await fetchFn(url, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  const text = await res.text()
  return { status: res.status, ok: res.ok, text, what }
}

const json = (r: { status: number; ok: boolean; text: string; what: string }) => {
  if (!r.ok) throw new HttpError(r.status, r.text, r.what)
  try {
    return JSON.parse(r.text) as unknown
  } catch {
    throw new HttpError(r.status, `not JSON: ${r.text}`, r.what)
  }
}

const idOf = (v: unknown): string | null =>
  v !== null && typeof v === "object" && typeof (v as { id?: unknown }).id === "string" ? (v as { id: string }).id : null

export const PLATFORM_PATH = "/internal/v1/migrations/classic/machines"

export const httpPlatform = (origin: string, token: string, fetchFn: Fetch = fetch): PlatformImports => {
  const url = `${origin.replace(/\/+$/, "")}${PLATFORM_PATH}`
  return {
    importMachine: async (req) => {
      const body = json(await call(fetchFn, "platform import", url, token, "POST", req)) as Record<string, unknown>
      const machine = idOf(body["machine"])
      if (machine === null) throw new HttpError(200, `no machine in ${JSON.stringify(body)}`, "platform import")
      const snap = body["snapshot"] as Record<string, unknown> | null | undefined
      return {
        status: typeof body["status"] === "string" ? body["status"] : "created",
        machine,
        snapshot: idOf(snap),
        vm_api_snapshot_id: typeof snap?.["vm_api_snapshot_id"] === "string" ? snap["vm_api_snapshot_id"] : null,
      }
    },
    deleteMachine: async (req) => {
      const r = await call(fetchFn, "platform delete", url, token, "DELETE", req)
      if (r.status === 404) return "absent"
      const body = json(r) as { status?: unknown }
      const s = body.status
      if (s !== "deleted" && s !== "deleting" && s !== "absent")
        throw new HttpError(r.status, `unknown delete status in ${r.text}`, r.what)
      return s
    },
    list: async (team, migrationId) => {
      const q = `?team=${encodeURIComponent(team)}&migration_id=${encodeURIComponent(migrationId)}`
      const body = json(await call(fetchFn, "platform list", `${url}${q}`, token, "GET")) as { items?: unknown }
      if (!Array.isArray(body.items)) throw new HttpError(200, "no items in the list answer", "platform list")
      return body.items.map((raw) => {
        const i = raw as Record<string, unknown>
        const m = i["machine"] as Record<string, unknown> | null
        return {
          classic_vm_id: String(i["classic_vm_id"]),
          status: String(i["status"] ?? ""),
          machine: m && typeof m["id"] === "string" ? { id: m["id"], status: String(m["status"] ?? "") } : null,
          snapshot: idOf(i["snapshot"]) ? { id: idOf(i["snapshot"])! } : null,
        }
      })
    },
  }
}

/**
 * The VM API's classic snapshot imports, for ledgers written by the earlier CLI only: that CLI made a VM API import
 * itself (`vm_api_import` step) before calling the platform, so rolling such a ledger back deletes that import here.
 * New runs never call the VM API. Service key CMUX_VM_IMPORT_KEY.
 */
export interface LegacyVmApi {
  /** Resolves when the snapshot is gone, including when it was never there (404). */
  deleteSnapshot(snapshotId: string): Promise<void>
}

export const httpLegacyVmApi = (origin: string, key: string, fetchFn: Fetch = fetch): LegacyVmApi => {
  const base = `${origin.replace(/\/+$/, "")}/v1/imports/classic-vm-snapshots`
  return {
    deleteSnapshot: async (id) => {
      const r = await call(fetchFn, "vm api delete", `${base}/${encodeURIComponent(id)}`, key, "DELETE")
      if (!r.ok && r.status !== 404) throw new HttpError(r.status, r.text, r.what)
    },
  }
}
