/**
 * Production cmux_vm migrations from CI (cmux-vm.yml action migrate-production;
 * plans/cmux-next/release-rails.md, "Production migrations from CI").
 *
 *   bun prod-owner.ts inspect          read-only: PlanetScale roles on cmux-prod/main, the owners of every
 *                                      object in schema cmux_vm, and whether the tracking table exists
 *   bun prod-owner.ts dry-run          inspect, then db-release.ts plan and rehearse (a throwaway branch copy)
 *   bun prod-owner.ts migrate          inspect, make sure the PlanetScale role cmux-vm-owner owns cmux_vm,
 *                                      adopt 0001-NNNN when the database is untracked, then db-release.ts apply
 *
 * Reads come from the Worker's own login (CMUX_VM_DATABASE_URL), and only from the catalogs (pg_class,
 * pg_proc, pg_type, pg_namespace, pg_roles) and to_regclass: never a row of any table, and never
 * anything of schema public. pscale authenticates from PLANETSCALE_SERVICE_TOKEN_ID and
 * PLANETSCALE_SERVICE_TOKEN. The owner's password exists only in this process's memory (masked in the
 * Actions log first): db-release.ts runs in-process and gets it as CMUX_VM_OWNER_URL in its own deps.env,
 * never in process.env, so no child process (pscale, git, gh, vercel) inherits it.
 *
 * migrate changes, in database cmux-prod branch main, only: the PlanetScale role cmux-vm-owner (created
 * with no inherited roles, or its password reset), the ownership of cmux_vm's objects (only when one
 * other role owns all of them and nothing outside cmux_vm), and schema cmux_vm through db-release.ts.
 */
import { must, roleUrl, type RoleJson } from "./branches.ts"
import { contractReason, readMigrations } from "./lint.ts"
import { connectUrl, requirementsOf, schemaProblems, trackingState, withLock, type Sql } from "./runner.ts"
import type { Requirement } from "../../../workers/cmux-vm/src/db/schema-requirements.ts"
import { REPO_ROOT, TREES } from "./trees.ts"

const tree = TREES["cmux-vm"]
const DB = tree.database
const BRANCH = tree.branches.production
const OWNER_URL_ENV = "CMUX_VM_OWNER_URL"
const WORKER_URL_ENV = "CMUX_VM_DATABASE_URL"
/** A rehearsal copy is a restore of main 6 minutes back; a role or ownership change younger than that is not on it. */
export const PITR_WAIT_MS = 7 * 60_000

export class Refusal extends Error {}

export interface PsRole {
  readonly id: string
  readonly name: string
  /** The Postgres role (the login user name without its `.<branch id>` suffix). */
  readonly pgUser: string
}

export interface Ownership {
  /** kind (schema, relation:<relkind>, function, type) and owner, with a count. */
  readonly objects: ReadonlyArray<{ readonly kind: string; readonly owner: string; readonly n: number }>
  readonly trackingTable: boolean
}

export const ownersOf = (o: Ownership): Array<string> => [...new Set(o.objects.map((r) => r.owner))].sort()

const pgUserOf = (username: string | undefined) => (username ?? "").replace(/\.[a-z0-9]+$/, "")

export type OwnerDecision =
  | { readonly kind: "ok" }
  | { readonly kind: "reassign"; readonly from: PsRole }
  | { readonly kind: "refuse"; readonly why: string }

/**
 * What to do about ownership, decided before anything is written. `owner` is the PlanetScale role
 * cmux-vm-owner if it exists; `outside` counts what each candidate owns outside cmux_vm.
 */
export const decideOwner = (input: { readonly owner: PsRole | undefined; readonly owners: ReadonlyArray<string>; readonly roles: ReadonlyArray<PsRole>; readonly outside: (pgRole: string) => number }): OwnerDecision => {
  const { owner, owners, roles } = input
  if (owners.length === 0) return { kind: "refuse", why: `schema ${tree.schema} has no objects on ${DB}/${BRANCH}: a bootstrap (database CREATE for the owner) is the manual procedure in release-rails.md, not this action` }
  if (owner && owners.length === 1 && owners[0] === owner.pgUser) return { kind: "ok" }
  if (owners.length > 1) return { kind: "refuse", why: `the objects of ${tree.schema} belong to ${owners.length} roles (${owners.join(", ")}); move them to one owner by hand first (release-rails.md, "cmux_vm-only owner role")` }
  const from = owners[0]!
  if (from === "postgres" || from === "pscale_admin" || from.startsWith("pg_")) return { kind: "refuse", why: `the objects of ${tree.schema} belong to ${from}, which owns the rest of the database; never reassign it (release-rails.md: never --successor postgres, and never move postgres's objects)` }
  const ps = roles.find((r) => r.pgUser === from)
  if (!ps) return { kind: "refuse", why: `the objects of ${tree.schema} belong to ${from}, a SQL role with no PlanetScale record; move them with ALTER ... OWNER TO, object by object, as staging did (release-rails.md)` }
  if (ps.name === tree.ownerRole) return { kind: "ok" }
  const outside = input.outside(from)
  if (outside > 0) return { kind: "refuse", why: `${from} (PlanetScale role ${ps.name}) also owns ${outside} object(s) outside ${tree.schema}; a reassign would move those too` }
  return { kind: "reassign", from: ps }
}

export const OWNERSHIP_SQL = `WITH s AS (SELECT oid, nspowner FROM pg_catalog.pg_namespace WHERE nspname = $1)
SELECT kind, owner, count(*)::int AS n FROM (
  SELECT 'schema'::text AS kind, pg_catalog.pg_get_userbyid(nspowner)::text AS owner FROM s
  UNION ALL SELECT 'relation:' || c.relkind::text, pg_catalog.pg_get_userbyid(c.relowner) FROM pg_catalog.pg_class c JOIN s ON c.relnamespace = s.oid
  UNION ALL SELECT 'function', pg_catalog.pg_get_userbyid(p.proowner) FROM pg_catalog.pg_proc p JOIN s ON p.pronamespace = s.oid
  UNION ALL SELECT 'type', pg_catalog.pg_get_userbyid(t.typowner) FROM pg_catalog.pg_type t JOIN s ON t.typnamespace = s.oid
) x GROUP BY kind, owner ORDER BY owner, kind`

/** Objects `role` owns outside cmux_vm (TOAST follows its table; temp schemas are skipped): catalog counts only. */
export const OUTSIDE_SQL = `SELECT (
    (SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname <> $1 AND n.nspname <> 'pg_toast' AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast_temp%' AND c.relowner = r.oid)
  + (SELECT count(*) FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname <> $1 AND p.proowner = r.oid)
  + (SELECT count(*) FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname <> $1 AND n.nspname <> 'pg_toast' AND t.typowner = r.oid)
  + (SELECT count(*) FROM pg_catalog.pg_namespace n WHERE n.nspname <> $1 AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast_temp%' AND n.nspowner = r.oid)
  + (SELECT count(*) FROM pg_catalog.pg_database d WHERE d.datdba = r.oid)
)::int AS n FROM pg_catalog.pg_roles r WHERE r.rolname = $2`

/**
 * Everything `REASSIGN OWNED BY role` would move (pg_shdepend owner entries in this database, plus shared
 * objects), minus the relations, functions, types and the schema inside cmux_vm. Any other class (large
 * objects, default ACLs, extensions, event triggers, publications, ...) counts as outside: refused.
 */
export const SHDEPEND_OUTSIDE_SQL = `SELECT count(*)::int AS n FROM pg_catalog.pg_shdepend d JOIN pg_catalog.pg_roles r ON r.oid = d.refobjid
WHERE r.rolname = $2 AND d.refclassid = 'pg_catalog.pg_authid'::regclass AND d.deptype = 'o'
  AND (d.dbid = 0 OR d.dbid = (SELECT oid FROM pg_catalog.pg_database WHERE datname = pg_catalog.current_database()))
  AND NOT (
       (d.classid = 'pg_catalog.pg_class'::regclass AND EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = d.objid AND n.nspname = $1))
    OR (d.classid = 'pg_catalog.pg_proc'::regclass AND EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE p.oid = d.objid AND n.nspname = $1))
    OR (d.classid = 'pg_catalog.pg_type'::regclass AND EXISTS (SELECT 1 FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace WHERE t.oid = d.objid AND n.nspname = $1))
    OR (d.classid = 'pg_catalog.pg_namespace'::regclass AND EXISTS (SELECT 1 FROM pg_catalog.pg_namespace n WHERE n.oid = d.objid AND n.nspname = $1)))`

export const readOwnership = async (sql: Sql): Promise<Ownership> => {
  const objects = await sql.query<{ kind: string; owner: string; n: number }>(OWNERSHIP_SQL, [tree.schema])
  const { tracking } = await trackingState(sql, tree)
  return { objects, trackingTable: tracking === "tracked" || tracking === "unreadable" }
}

const outsideCounts = async (sql: Sql, roles: ReadonlyArray<string>): Promise<Map<string, number>> => {
  const out = new Map<string, number>()
  for (const r of roles) {
    const byCatalog = Number((await sql.query<{ n: number }>(OUTSIDE_SQL, [tree.schema, r]))[0]?.n ?? 0)
    const byShdepend = Number((await sql.query<{ n: number }>(SHDEPEND_OUTSIDE_SQL, [tree.schema, r]))[0]?.n ?? 0)
    out.set(r, Math.max(byCatalog, byShdepend))
  }
  return out
}

const listRoles = async (): Promise<Array<PsRole>> =>
  (JSON.parse(await must(["role", "list", DB, BRANCH])) as Array<RoleJson>).flatMap((r) => (r.id && r.name ? [{ id: r.id, name: r.name, pgUser: pgUserOf(r.username) }] : []))

const mask = (value: string) => {
  if (process.env.GITHUB_ACTIONS && value) console.log(`::add-mask::${value}`)
}

/** The owner's credentials from a pscale role create/reset answer: masked, then only a URL in memory. */
const ownerUrlFrom = (stdout: string): { url: string; pgUser: string } => {
  const role = JSON.parse(stdout) as RoleJson
  if (role.password) mask(role.password)
  const url = roleUrl(role)
  mask(url)
  mask(encodeURIComponent(role.password ?? ""))
  return { url, pgUser: pgUserOf(role.username) }
}

interface Inspection {
  readonly roles: Array<PsRole>
  readonly ownership: Ownership
  readonly outside: Map<string, number>
}

/** `url` if its user belongs to cmux-prod main (`<role>.<main's branch id>`), as db-release.ts requires; else refused before any read. */
export const productionUrl = (url: string | undefined, name: string): string => {
  if (!url) throw new Refusal(`${name} is empty`)
  let user: string
  try {
    user = decodeURIComponent(new URL(url).username)
  } catch {
    throw new Refusal(`${name} is not a URL`)
  }
  const want = tree.branchIds.production
  if (!user.endsWith(`.${want}`)) throw new Refusal(`${name} is not for ${DB}/${BRANCH} (branch ${user.split(".").pop() || "?"}, want ${want}); refusing before any read or role change`)
  return url
}

/** `url` on PlanetScale's direct Postgres port 5432 (the same host serves PgBouncer on 6432). */
export const directUrl = (url: string): string => {
  const u = new URL(url)
  u.port = "5432"
  return u.toString()
}

/**
 * The Worker's grants (workers/cmux-vm/src/db/schema-requirements.ts): migrations carry no GRANT, so the owner
 * issues USAGE on cmux_vm and each required table privilege to the Worker's role, then the Worker's own schema
 * check must find no missing privilege. Only tables in cmux_vm; GRANT is idempotent.
 */
export const grantStatements = (requirements: ReadonlyArray<Requirement>, workerRole: string): Array<string> => {
  const role = `"${workerRole.replace(/"/g, '""')}"`
  const out = [`GRANT USAGE ON SCHEMA ${tree.schema} TO ${role}`]
  for (const r of requirements) {
    if (!r.privileges?.length) continue
    const [schema, table] = r.table.split(".")
    if (schema !== tree.schema || !table || !/^[a-z_][a-z0-9_]*$/.test(table)) throw new Refusal(`requirement ${r.table} is not a plain table in ${tree.schema}; refusing to grant on it`)
    for (const p of r.privileges) if (!["SELECT", "INSERT", "UPDATE", "DELETE"].includes(p)) throw new Refusal(`requirement ${r.table} asks for ${p}; only SELECT, INSERT, UPDATE and DELETE are granted here`)
    out.push(`GRANT ${r.privileges.join(", ")} ON TABLE ${tree.schema}.${table} TO ${role}`)
  }
  return out
}

const grantWorker = async (ownerUrl: string, log: (l: string) => void): Promise<void> => {
  const worker = (await listRoles()).find((r) => r.name === tree.workerRole)
  if (!worker) throw new Refusal(`${DB}/${BRANCH} has no PlanetScale role ${tree.workerRole}; the Worker grants were not issued`)
  const requirements = await requirementsOf(tree, REPO_ROOT)
  const owner = await connectUrl(ownerUrl)
  try {
    const statements = grantStatements(requirements, worker.pgUser)
    for (const statement of statements) {
      await owner.query(statement)
      // Each executed grant is logged (the rollback is the matching REVOKE).
      log(`  ${statement}`)
    }
    log(`granted the Worker role ${tree.workerRole} (${worker.pgUser}) USAGE on ${tree.schema} and ${statements.length - 1} table privilege set(s)`)
    const missing = (await schemaProblems(owner, requirements, worker.pgUser)).filter((p) => p.includes(" privilege"))
    if (missing.length) throw new Refusal(`after the grants, the Worker still lacks: ${missing.join("; ")}`)
    log(`Worker schema check: no missing privilege for ${worker.pgUser}`)
  } finally {
    await owner.end()
  }
}

/** Read-only, on `sql` (the Worker's login): roles, cmux_vm's owners and what they own elsewhere, the tracking table. */
const inspect = async (sql: Sql, log: (l: string) => void): Promise<Inspection> => {
  const roles = await listRoles()
  log(`PlanetScale roles on ${DB}/${BRANCH} (${roles.length}):`)
  for (const r of roles) log(`  ${r.name}  id=${r.id}  pg=${r.pgUser}`)
  const who = (await sql.query<{ u: string }>("SELECT current_user AS u"))[0]?.u
  log(`catalog reads as the Worker role ${who}`)
  const ownership = await readOwnership(sql)
  log(`owners of the objects in schema ${tree.schema}:`)
  if (!ownership.objects.length) log("  (none: the schema is absent or empty)")
  for (const o of ownership.objects) log(`  ${o.owner}  ${o.kind}  ${o.n}`)
  log(`${tree.trackingTable}: ${ownership.trackingTable ? "exists" : "absent"}`)
  const outside = await outsideCounts(sql, ownersOf(ownership))
  for (const [r, n] of outside) log(`  ${r} owns ${n} object(s) outside ${tree.schema}`)
  return { roles, ownership, outside }
}

const describeDecision = (decision: OwnerDecision, ownerRecord: PsRole | undefined) =>
  `owner: ${decision.kind === "ok" ? `${tree.ownerRole} already owns ${tree.schema}` : decision.kind === "reassign" ? `would move ${tree.schema}'s objects from ${decision.from.name} (${decision.from.pgUser}) to ${tree.ownerRole}` : `refused: ${decision.why}`}${ownerRecord ? "" : `; ${tree.ownerRole} does not exist yet and would be created with no inherited roles`}`

const decide = (seen: Inspection) => {
  const ownerRecord = seen.roles.find((r) => r.name === tree.ownerRole)
  return { ownerRecord, decision: decideOwner({ owner: ownerRecord, owners: ownersOf(seen.ownership), roles: seen.roles, outside: (r) => seen.outside.get(r) ?? 0 }) }
}

/** The contract migrations (`-- contract:` header) of the landed tree, for --allow-contract. */
const contractFiles = () => readMigrations(REPO_ROOT, tree).filter((f) => contractReason(f.sql) !== undefined).map((f) => f.name)

const adoptThrough = (trackingTable: boolean): string | undefined => (trackingTable ? undefined : process.env.CMUX_VM_ADOPT_THROUGH || "0009")

const releaseMain = async (argv: Array<string>, log: (l: string) => void, ownerUrl?: string): Promise<void> => {
  const { defaultDeps, main } = await import("./db-release.ts")
  log(`$ db-release.ts ${argv.join(" ")}`)
  const base = defaultDeps()
  // No cmux-old compat gate here: these migrations change only schema cmux_vm (lint.ts refuses anything
  // else), and only cmux-next uses that schema. Leo, 2026-11-04: "LITERALLY NOBDY IS USING CMUX-NEXT CLOUD
  // \"PROD\" OTHER THAN US". The gate's replay needed a staging test login this environment does not hold.
  const deps = { ...base, compat: async () => { log("cmux-old compat gate skipped: the change is confined to schema cmux_vm"); return [] } }
  const code = await main(argv, ownerUrl ? { ...deps, env: { ...deps.env, [OWNER_URL_ENV]: ownerUrl } } : deps)
  if (code !== 0) throw new Refusal(`db-release.ts ${argv[0]} exited ${code}`)
}

const base = ["--tree", "cmux-vm", "--target", "production"]

export const run = async (command: string | undefined, log = (l: string) => console.log(l), sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))): Promise<number> => {
  const err = (l: string) => console.error(process.env.GITHUB_ACTIONS ? `::error title=prod-owner::${l}` : `prod-owner: ${l}`)
  let sql: Sql | undefined
  try {
    if (command !== "inspect" && command !== "dry-run" && command !== "migrate") throw new Refusal("usage: prod-owner.ts inspect|dry-run|migrate")
    // The direct port: the release lock is a session advisory lock, which a transaction pooler (6432) would not keep.
    sql = await connectUrl(directUrl(productionUrl(process.env[WORKER_URL_ENV], WORKER_URL_ENV)))
    const allow = contractFiles().flatMap((f) => ["--allow-contract", f])
    // skip_rehearsal (workflow input): apply without the point-in-time rehearsal copy, so the PITR waits go too.
    const skipRehearsal = command === "migrate" && process.env.CMUX_VM_SKIP_REHEARSAL === "true"

    if (command !== "migrate") {
      const seen = await inspect(sql, log)
      if (command === "inspect") return 0
      const { ownerRecord, decision } = decide(seen)
      log(describeDecision(decision, ownerRecord))
      const through = adoptThrough(seen.ownership.trackingTable)
      // Read-only on main: plan through the Worker's login (catalogs and, if readable, the tracking rows),
      // then rehearse on a throwaway branch copy (deleted by exact name).
      await releaseMain(["plan", ...base, "--url-env", WORKER_URL_ENV], log).catch((e: Error) => log(`plan: ${e.message} (untracked is expected before the first adopt)`))
      await releaseMain(["rehearse", ...base, "--url-env", WORKER_URL_ENV, ...(through ? ["--adopt-through", through] : []), ...allow], log)
      if (decision.kind === "refuse") throw new Refusal(decision.why)
      log("dry run done: nothing on main was changed")
      return 0
    }

    // migrate: the release lock (the advisory lock db-release.ts apply and adopt take) is held from the
    // inspection through the owner change, so no other migration run sees or changes cmux_vm in between.
    // adopt and apply take it again themselves (it is a try-lock) and re-check the owner and the plan.
    const owned = await withLock(sql, tree, async () => {
      const seen = await inspect(sql!, log)
      const { ownerRecord, decision } = decide(seen)
      log(describeDecision(decision, ownerRecord))
      if (decision.kind === "refuse") throw new Refusal(decision.why)
      // 1. The owner role: created with no inherited roles, or its password reset (the only way to get a login for an existing role).
      const login = ownerUrlFrom(await must(ownerRecord ? ["role", "reset", DB, BRANCH, ownerRecord.id, "--force"] : ["role", "create", DB, BRANCH, tree.ownerRole]))
      log(ownerRecord ? `reset the password of ${tree.ownerRole} (${login.pgUser})` : `created ${tree.ownerRole} (${login.pgUser}) with no inherited roles`)
      // 2. Ownership: one other role that owns nothing outside cmux_vm hands its objects over (REASSIGN OWNED by pscale_admin).
      if (decision.kind === "reassign") {
        await must(["role", "reassign", DB, BRANCH, decision.from.id, "--successor", login.pgUser, "--force"])
        log(`reassigned the objects of ${decision.from.name} (${decision.from.pgUser}) to ${login.pgUser}`)
      }
      const after = ownersOf(await readOwnership(sql!))
      if (after.length !== 1 || after[0] !== login.pgUser) throw new Refusal(`after the owner step, ${tree.schema}'s objects belong to ${after.join(", ") || "nobody"}, not ${login.pgUser}; nothing was migrated`)
      return { login, changed: !ownerRecord || decision.kind === "reassign", through: adoptThrough(seen.ownership.trackingTable) }
    })
    await sql.end()
    sql = undefined
    if (owned.changed && !skipRehearsal) {
      log(`waiting ${PITR_WAIT_MS / 60_000} min so the rehearsal's point-in-time copy has the owner change (release-rails.md, "PITR lag")`)
      await sleep(PITR_WAIT_MS)
    }
    // 3. Track the hand-applied files, then apply the rest (the apply rehearses this exact set on a copy first).
    if (owned.through) {
      await releaseMain(["adopt", ...base, "--url-env", OWNER_URL_ENV, "--through", owned.through, "--confirm-production"], log, owned.login.url)
      // The apply's rehearsal copies main 6 minutes back: it must see the adopted tracking rows.
      if (!skipRehearsal) {
        log(`waiting ${PITR_WAIT_MS / 60_000} min so the rehearsal's point-in-time copy has the adopted rows`)
        await sleep(PITR_WAIT_MS)
      }
    }
    await releaseMain(["apply", ...base, "--url-env", OWNER_URL_ENV, "--confirm-production", ...allow, ...(skipRehearsal ? ["--skip-rehearsal"] : [])], log, owned.login.url)
    // 4. The Worker's privileges on what the apply added (the deploy gate refuses without them).
    await grantWorker(owned.login.url, log)
    return 0
  } catch (e) {
    err((e as Error).message)
    return 1
  } finally {
    await sql?.end().catch(() => {})
  }
}

if (import.meta.main) process.exit(await run(process.argv[2]))
