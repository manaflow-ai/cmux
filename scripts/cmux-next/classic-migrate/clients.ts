// The two NEXT surfaces apply calls. Both are being built alongside this tool, so each is one small typed
// interface; the HTTP shapes live only here. Every request is idempotent on (migration_id, classic_vm_id).

export interface VmApiImportRequest {
  tenant_id: string
  created_by: string
  classic_vm_id: string
  upstream_vm_id: string
  migration_id: string
}
export interface VmApiImportResult {
  id: string
}

export interface PlatformImportRequest {
  team: string
  creator_user: string
  migration_id: string
  classic_vm_id: string
  vm_api_snapshot_id: string
  name: string
  size: string | null
}
export interface PlatformImportResult {
  machine: unknown
  snapshot: unknown
}
export interface PlatformDeleteRequest {
  team: string
  migration_id: string
  classic_vm_id: string
}

/** cmux VM API, service key CMUX_VM_IMPORT_KEY. */
export interface VmApiImports {
  importSnapshot(req: VmApiImportRequest): Promise<VmApiImportResult>
  /** Resolves when the snapshot is gone, including when it was never there. */
  deleteSnapshot(snapshotId: string): Promise<void>
}

/** cmux-platform internal route, bearer INTERNAL_TOKEN. */
export interface PlatformImports {
  importMachine(req: PlatformImportRequest): Promise<PlatformImportResult>
  /** Resolves when the machine and its CloudDO snapshot row are gone, including when they never existed. */
  deleteMachine(req: PlatformDeleteRequest): Promise<void>
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

const trimOrigin = (origin: string) => origin.replace(/\/+$/, "")

export const httpVmApi = (origin: string, key: string, fetchFn: Fetch = fetch): VmApiImports => {
  const base = `${trimOrigin(origin)}/v1/imports/classic-vm-snapshots`
  return {
    importSnapshot: async (req) => {
      const body = json(await call(fetchFn, "vm api import", base, key, "POST", req)) as { id?: unknown }
      if (typeof body.id !== "string" || !body.id.startsWith("snap_"))
        throw new HttpError(200, `no snap_ id in ${JSON.stringify(body)}`, "vm api import")
      return { id: body.id }
    },
    deleteSnapshot: async (id) => {
      const r = await call(fetchFn, "vm api delete", `${base}/${encodeURIComponent(id)}`, key, "DELETE")
      if (!r.ok && r.status !== 404) throw new HttpError(r.status, r.text, r.what)
    },
  }
}

export const httpPlatform = (origin: string, token: string, fetchFn: Fetch = fetch): PlatformImports => {
  const url = `${trimOrigin(origin)}/internal/v1/migrations/classic/machines`
  return {
    importMachine: async (req) => {
      const body = json(await call(fetchFn, "platform import", url, token, "POST", req)) as Record<string, unknown>
      if (body["machine"] === undefined)
        throw new HttpError(200, `no machine in ${JSON.stringify(body)}`, "platform import")
      return { machine: body["machine"], snapshot: body["snapshot"] ?? null }
    },
    deleteMachine: async (req) => {
      const r = await call(fetchFn, "platform delete", url, token, "DELETE", req)
      if (!r.ok && r.status !== 404) throw new HttpError(r.status, r.text, r.what)
    },
  }
}

/** Resolves a user's personal VM API tenant at apply time (cmux backend ensureVmApiTenant owns the real one). */
export type PersonalTenantResolver = (who: { stack_user_id: string; user_id: string }) => Promise<string>

/** The CLI's resolver: a JSON map from Stack user id (or NEXT user id) to VM API tenant id. */
export const mapTenantResolver =
  (map: Record<string, string>): PersonalTenantResolver =>
  async (who) => {
    const t = map[who.stack_user_id] ?? map[who.user_id]
    if (!t)
      throw new Error(
        `no personal VM API tenant for Stack user ${who.stack_user_id} (${who.user_id}); pass --personal-tenants FILE`,
      )
    return t
  }
