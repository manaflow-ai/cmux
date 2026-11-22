/**
 * Throwaway PlanetScale branches for rehearsals, and short-lived roles, through
 * the pscale CLI (org `cmux` always explicit, JSON output). A role's password
 * goes from pscale's stdout into a connection URL in memory; it is never
 * printed or written. Branches are deleted by the exact name this run created.
 */
import { spawn } from "node:child_process"

export interface Connection {
  readonly url: string
  /** Deletes the role (no-op for roles on a branch that is deleted anyway). */
  release(): Promise<void>
}

export interface BranchProvider {
  /** Creates `name` as a copy of branch `from` (schema, data and roles, as of 6 minutes ago) and waits until it is ready. */
  create(database: string, name: string, from: string): Promise<void>
  /** A short-lived role on `branch`: admin (inherits postgres) or read (pg_read_all_data), plus `inherit` (existing Postgres roles, e.g. the owner). */
  connect(database: string, branch: string, access: "admin" | "read", label: string, inherit?: ReadonlyArray<string>): Promise<Connection>
  /**
   * The copy's default `postgres` role, by resetting its password (rehearsal branches only: the
   * reset never touches the parent). A pscale role cannot inherit a non-builtin role, so this is
   * how a rehearsal reaches the owner role the copy restored from its parent.
   */
  connectDefault(database: string, branch: string): Promise<Connection>
  /**
   * The copy's own record of PlanetScale role `roleName` (restored with the parent), by resetting
   * its password on the copy (rehearsal branches only; the parent's role is never touched).
   * undefined when the copy has no such record.
   */
  connectRole(database: string, branch: string, roleName: string): Promise<Connection | undefined>
  /** Role names the branch lists (names only, for the rehearsal log). */
  roleNames(database: string, branch: string): Promise<Array<string>>
  /**
   * `parentUrl` (a login on the parent branch) rewritten for the copy `branch`: the copy restored the
   * parent's roles and passwords, so the same role logs in as <role>.<copy branch id>.
   */
  copyUrl(database: string, branch: string, parentUrl: string): Promise<string | undefined>
  /** The Postgres role of an existing PlanetScale role, if the branch has one with that name (its login user name without the `.<branch id>` routing suffix). */
  roleUser(database: string, branch: string, roleName: string): Promise<string | undefined>
  delete(database: string, name: string): Promise<void>
  exists(database: string, name: string): Promise<boolean>
}

/** Rehearsal branch names: rh-<tree>-<target>-<UTC yyyymmddhhmmss>-<4 hex>; nothing else is ever deleted. */
export const REHEARSAL_BRANCH = /^rh-(cmux-vm|backend)-(development|staging|production)-\d{14}-[0-9a-f]{4}$/

export const rehearsalBranchName = (tree: string, target: string, now = new Date(), random = Math.floor(Math.random() * 0x10000)) =>
  `rh-${tree}-${target}-${now.toISOString().replace(/[-:T]/g, "").slice(0, 14)}-${random.toString(16).padStart(4, "0")}`

const ORG = "cmux"

interface Run {
  readonly code: number
  readonly stdout: string
  readonly stderr: string
}

/** Runs pscale with an argv array (no shell). stdout is returned to the caller only, never logged. */
const pscale = (args: ReadonlyArray<string>, bin = process.env.PSCALE_BIN || "pscale"): Promise<Run> =>
  new Promise((resolve, reject) => {
    const child = spawn(bin, [...args, "--org", ORG, "--format", "json"], { stdio: ["ignore", "pipe", "pipe"] })
    let stdout = ""
    let stderr = ""
    child.stdout.on("data", (d) => (stdout += d))
    child.stderr.on("data", (d) => (stderr += d))
    child.on("error", reject)
    child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }))
  })

/** pscale's error text without anything that looks like a credential. */
const errorText = (run: Run) => (run.stderr || run.stdout).replace(/pscale_[a-z]+_[A-Za-z0-9_.-]+/g, "<redacted>").replace(/"password"\s*:\s*"[^"]*"/g, '"password":"<redacted>"').trim().slice(0, 400)

const must = async (args: ReadonlyArray<string>): Promise<string> => {
  const run = await pscale(args)
  if (run.code !== 0) throw new Error(`pscale ${args.slice(0, 2).join(" ")} failed: ${errorText(run)}`)
  return run.stdout
}

interface RoleJson {
  readonly id?: string
  readonly name?: string
  readonly username?: string
  readonly password?: string
  readonly access_host_url?: string
  readonly database_name?: string
}

export const roleUrl = (role: RoleJson): string => {
  if (!role.username || !role.password || !role.access_host_url) throw new Error("pscale role create returned no credentials")
  const db = role.database_name || "postgres"
  return `postgresql://${encodeURIComponent(role.username)}:${encodeURIComponent(role.password)}@${role.access_host_url}:5432/${encodeURIComponent(db)}?sslmode=verify-full`
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

export const pscaleProvider = (): BranchProvider => ({
  // Rehearsal branches must be copies (schema, data, roles) of their parent; see create.
  async create(database, name, from) {
    if (!REHEARSAL_BRANCH.test(name)) throw new Error(`refusing to create ${name}: not a rehearsal branch name`)
    // A Postgres branch made with --from alone is an empty cluster (no schema, data or roles: the
    // 2026-10-09 live rehearsal). A point-in-time restore of the parent 6 min ago (PlanetScale needs 5+) is a real copy;
    // the rehearsal then checks the copy has exactly the parent's applied rows.
    const point = new Date(Date.now() - 6 * 60_000).toISOString().replace(/\.\d+Z$/, "Z")
    await must(["branch", "create", database, name, "--from", from, "--restore-point", point, "--replicas", "0", "--wait"])
    // --wait returns when the branch exists; poll `ready` too (Postgres branches restore data first).
    for (let i = 0; i < 120; i++) {
      const show = JSON.parse(await must(["branch", "show", database, name])) as { ready?: boolean; state?: string }
      if (show.ready === true) return
      await sleep(10_000)
    }
    throw new Error(`branch ${name} not ready after 20 minutes`)
  },
  async connect(database, branch, access, label, inherit = []) {
    const roleName = `${label}-${Date.now().toString(36)}`.slice(0, 60)
    const inherited = [access === "admin" ? "postgres" : "pg_read_all_data", ...inherit].join(",")
    const role = JSON.parse(await must(["role", "create", database, branch, roleName, "--inherited-roles", inherited, "--ttl", "2h"])) as RoleJson
    const url = roleUrl(role)
    return {
      url,
      release: async () => {
        if (!role.id) return
        const run = await pscale(["role", "delete", database, branch, role.id, "--force", "--successor", "postgres"])
        if (run.code !== 0) console.warn(`warning: could not delete role ${roleName} on ${database}/${branch} (it expires in 2 h): ${errorText(run)}`)
      },
    }
  },
  async connectDefault(database, branch) {
    if (!REHEARSAL_BRANCH.test(branch)) throw new Error(`refusing to reset the default role of ${branch}: rehearsal branches only`)
    const role = JSON.parse(await must(["role", "reset-default", database, branch, "--force"])) as RoleJson
    return { url: roleUrl(role), release: async () => {} }
  },
  async connectRole(database, branch, roleName) {
    if (!REHEARSAL_BRANCH.test(branch)) throw new Error(`refusing to reset role ${roleName} on ${branch}: rehearsal branches only`)
    const roles = JSON.parse(await must(["role", "list", database, branch])) as Array<RoleJson>
    const id = roles.find((r) => r.name === roleName)?.id
    if (!id) return undefined
    const role = JSON.parse(await must(["role", "reset", database, branch, id, "--force"])) as RoleJson
    return { url: roleUrl(role), release: async () => {} }
  },
  async copyUrl(database, branch, parentUrl) {
    if (!REHEARSAL_BRANCH.test(branch)) throw new Error(`refusing a copy URL for ${branch}: rehearsal branches only`)
    const id = (JSON.parse(await must(["branch", "show", database, branch])) as { id?: string }).id
    if (!id) return undefined
    const u = new URL(parentUrl)
    u.username = encodeURIComponent(`${decodeURIComponent(u.username).replace(/\.[a-z0-9]+$/, "")}.${id}`)
    u.port = "5432"
    return u.toString()
  },
  async roleNames(database, branch) {
    return (JSON.parse(await must(["role", "list", database, branch])) as Array<RoleJson>).flatMap((r) => (r.name ? [r.name] : []))
  },
  async roleUser(database, branch, roleName) {
    const roles = JSON.parse(await must(["role", "list", database, branch])) as Array<RoleJson>
    const user = roles.find((r) => r.name === roleName)?.username
    return user?.replace(/\.[a-z0-9]+$/, "")
  },
  async delete(database, name) {
    if (!REHEARSAL_BRANCH.test(name)) throw new Error(`refusing to delete ${name}: only rehearsal branches (rh-...) are deleted`)
    await must(["branch", "delete", database, name, "--force"])
  },
  async exists(database, name) {
    const branches = JSON.parse(await must(["branch", "list", database])) as Array<{ name: string }>
    return branches.some((b) => b.name === name)
  },
})
