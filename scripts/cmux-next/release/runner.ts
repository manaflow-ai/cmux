/**
 * The migration runner core shared by `db-release.ts` (plan, rehearse, apply,
 * adopt, gate). One connection, one tree. Same tracking rows as
 * backend/db/migrate.ts: `version` = file name, `checksum` = sha256 of the file.
 */
import { REQUIRED_SCHEMA, SCHEMA_CHECK_SQL, schemaCheckParams, requiredMigration, type Requirement } from "../../../workers/cmux-vm/src/db/schema-requirements.ts"
import { parseSql, requirementsModuleAt, type MigrationFile } from "./lint.ts"
import type { Tree } from "./trees.ts"

/** The few things the runner needs from a Postgres connection (pg.Client in production, a scratch database in tests). */
export interface Sql {
  query<T = Record<string, unknown>>(text: string, params?: ReadonlyArray<unknown>): Promise<Array<T>>
  end(): Promise<void>
}

export const connectUrl = async (url: string): Promise<Sql> => {
  const { default: pg } = await import("pg")
  const client = new pg.Client({ connectionString: url, application_name: "cmux-db-release" })
  // An idle connection the server ends (for example a dropped rehearsal branch) must not crash the
  // process; the next query on it still fails.
  client.on("error", () => {})
  await client.connect()
  return {
    query: async <T>(text: string, params?: ReadonlyArray<unknown>) => (await client.query(text, params as Array<unknown> | undefined)).rows as Array<T>,
    end: () => client.end(),
  }
}

const quoteIdent = (name: string) => `"${name.replace(/"/g, '""')}"`
const qualified = (name: string) => name.split(".").map(quoteIdent).join(".")

/**
 * fresh: no tracking table and no objects (apply creates the table);
 * tracked: the tracking table exists;
 * untracked: objects exist without a tracking table (applied by hand): `adopt` first;
 * unreadable: the role cannot read the tracking table (the deploy gate falls back to the catalog check).
 */
export type Tracking = "fresh" | "tracked" | "untracked" | "unreadable"

export interface Plan {
  readonly tracking: Tracking
  readonly applied: ReadonlyMap<string, string>
  readonly pending: ReadonlyArray<MigrationFile>
  /** Rows the tree lacks. */
  readonly unknown: ReadonlyArray<string>
  /** Applied files whose checksum differs from the tree. */
  readonly mismatched: ReadonlyArray<string>
}

export const trackingState = async (sql: Sql, tree: Tree): Promise<{ tracking: Tracking; applied: Map<string, string> }> => {
  const exists = (await sql.query<{ t: string | null }>("SELECT to_regclass($1)::text AS t", [tree.trackingTable]))[0]?.t != null
  if (!exists) {
    const objects = await sql.query<{ n: string }>(
      "SELECT count(*)::text AS n FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relkind IN ('r', 'p')",
      [tree.schema],
    )
    return { tracking: Number(objects[0]?.n ?? 0) > 0 ? "untracked" : "fresh", applied: new Map() }
  }
  try {
    const rows = await sql.query<{ version: string; checksum: string }>(`SELECT version, checksum FROM ${qualified(tree.trackingTable)}`)
    return { tracking: "tracked", applied: new Map(rows.map((r) => [r.version, r.checksum])) }
  } catch (e) {
    if (/permission denied/i.test((e as Error).message)) return { tracking: "unreadable", applied: new Map() }
    throw e
  }
}

export const planOf = async (sql: Sql, tree: Tree, files: ReadonlyArray<MigrationFile>): Promise<Plan> => {
  const { tracking, applied } = await trackingState(sql, tree)
  const names = new Set(files.map((f) => f.name))
  const unknown = [...applied.keys()].filter((v) => !names.has(v)).sort()
  const mismatched = files.filter((f) => applied.has(f.name) && applied.get(f.name) !== f.checksum).map((f) => f.name)
  const pending = tracking === "tracked" || tracking === "fresh" ? files.filter((f) => !applied.has(f.name)) : []
  return { tracking, applied, pending, unknown, mismatched }
}

/** Problems that stop any write: a changed applied file, or (when the tree does not allow it) rows the tree lacks. */
export const planProblems = (plan: Plan, tree: Tree, target: string): Array<string> => {
  const problems: Array<string> = []
  if (plan.mismatched.length) problems.push(`${plan.mismatched.join(", ")} changed after being applied to ${tree.name}/${target}; add a new migration instead`)
  if (plan.unknown.length && !tree.allowDatabaseAhead && target !== "development")
    problems.push(`${tree.name}/${target} has migrations this tree lacks: ${plan.unknown.join(", ")}; merge the base branch first`)
  if (plan.tracking === "untracked") problems.push(`${tree.name}/${target} has objects in schema ${tree.schema} but no ${tree.trackingTable}: run \`db-release.ts adopt\` first`)
  return problems
}

/** A stable hash of what an apply would do: the applied rows it starts from and the pending files it runs. */
export const setHashOf = async (tree: Tree, plan: Plan): Promise<string> => {
  const { sha256 } = await import("./lint.ts")
  const base = [...plan.applied.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([v, c]) => `${v}:${c}`)
  const pending = plan.pending.map((f) => `${f.name}:${f.checksum}`)
  return sha256(JSON.stringify({ tree: tree.name, base, pending }))
}

const ensureTrackingTable = async (sql: Sql, tree: Tree) => {
  await sql.query(`CREATE SCHEMA IF NOT EXISTS ${quoteIdent(tree.schema)}`)
  const extra = tree.richTracking ? ", applied_by text, adopted boolean NOT NULL DEFAULT false" : ""
  await sql.query(`CREATE TABLE IF NOT EXISTS ${qualified(tree.trackingTable)} (version text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now()${extra})`)
}

const record = async (sql: Sql, tree: Tree, f: MigrationFile, by: string, adopted = false) => {
  if (tree.richTracking) await sql.query(`INSERT INTO ${qualified(tree.trackingTable)} (version, checksum, applied_by, adopted) VALUES ($1, $2, $3, $4)`, [f.name, f.checksum, by, adopted])
  else await sql.query(`INSERT INTO ${qualified(tree.trackingTable)} (version, checksum) VALUES ($1, $2)`, [f.name, f.checksum])
}

/** One run at a time per database: refuses (never waits) while another runner holds the tree's advisory lock. */
export const withLock = async <T>(sql: Sql, tree: Tree, body: () => Promise<T>): Promise<T> => {
  const got = (await sql.query<{ ok: boolean }>("SELECT pg_try_advisory_lock($1) AS ok", [tree.lockKey]))[0]?.ok
  if (!got) throw new Error(`another migration run holds the ${tree.name} lock on this database; wait for it and retry`)
  try {
    return await body()
  } finally {
    await sql.query("SELECT pg_advisory_unlock($1)", [tree.lockKey])
  }
}

/** Per-file limits: a migration waiting for a lock fails fast instead of queueing every query behind it. */
export const LOCK_TIMEOUT = process.env.CMUX_RELEASE_LOCK_TIMEOUT || "3s"
export const STATEMENT_TIMEOUT = process.env.CMUX_RELEASE_STATEMENT_TIMEOUT || "10min"

const sessionSettings = (tree: Tree, scope: "LOCAL" | "SESSION") => {
  const set = scope === "LOCAL" ? "SET LOCAL" : "SET"
  const statements = [`${set} lock_timeout = '${LOCK_TIMEOUT}'`, `${set} statement_timeout = '${STATEMENT_TIMEOUT}'`]
  // cmux-vm shares cmux-prod with cmux-old: an unqualified name must never resolve into public.
  if (tree.name === "cmux-vm") statements.push(`${set} search_path = ${quoteIdent(tree.schema)}, pg_catalog`)
  return statements
}

/**
 * Rows or catalog entries this transaction wrote outside `schema` (pg_toast holds the new tables'
 * TOAST storage). Run just before COMMIT; any finding rolls the file back. Catalog rows written by
 * this transaction carry its xid in xmin, so DDL, TRUNCATE (new relfilenode), GRANT (relacl), a
 * foreign key into another schema (triggers on the referenced table) and a new schema all show up.
 */
/** Row-write counters of tables outside `schema`. They include writes of this session not flushed yet, so the guard compares a snapshot taken before the file. */
const WRITES_SQL = `SELECT relid::text AS relid, schemaname || '.' || relname AS name, (n_tup_ins + n_tup_upd + n_tup_del)::text AS n FROM pg_catalog.pg_stat_xact_user_tables WHERE schemaname NOT IN ($1, 'pg_toast')`
const writesOutside = async (sql: Sql, schema: string) => new Map((await sql.query<{ relid: string; name: string; n: string }>(WRITES_SQL, [schema])).map((r) => [r.relid, { name: r.name, n: Number(r.n) }]))

const OUTSIDE_SQL = `WITH me AS (SELECT (txid_current() % 4294967296)::text AS xid), allowed AS (SELECT unnest(ARRAY[$1::text, 'pg_toast']) AS nspname)
  SELECT 'catalog: relation ' || n.nspname || '.' || c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace, me
   WHERE c.xmin::text = me.xid AND n.nspname NOT IN (SELECT nspname FROM allowed)
  UNION ALL SELECT 'catalog: column of ' || n.nspname || '.' || c.relname FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON c.oid = a.attrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace, me
   WHERE a.xmin::text = me.xid AND n.nspname NOT IN (SELECT nspname FROM allowed)
  UNION ALL SELECT 'catalog: default of ' || n.nspname || '.' || c.relname FROM pg_catalog.pg_attrdef d JOIN pg_catalog.pg_class c ON c.oid = d.adrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace, me
   WHERE d.xmin::text = me.xid AND n.nspname NOT IN (SELECT nspname FROM allowed)
  UNION ALL SELECT 'catalog: constraint ' || n.nspname || '.' || co.conname FROM pg_catalog.pg_constraint co JOIN pg_catalog.pg_namespace n ON n.oid = co.connamespace, me
   WHERE co.xmin::text = me.xid AND n.nspname NOT IN (SELECT nspname FROM allowed)
  UNION ALL SELECT 'catalog: index on ' || n.nspname || '.' || c.relname FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid = i.indrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace, me
   WHERE i.xmin::text = me.xid AND n.nspname NOT IN (SELECT nspname FROM allowed)
  UNION ALL SELECT 'catalog: trigger on ' || n.nspname || '.' || c.relname FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace, me
   WHERE t.xmin::text = me.xid AND n.nspname NOT IN (SELECT nspname FROM allowed)
  UNION ALL SELECT 'catalog: policy on ' || n.nspname || '.' || c.relname FROM pg_catalog.pg_policy p JOIN pg_catalog.pg_class c ON c.oid = p.polrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace, me
   WHERE p.xmin::text = me.xid AND n.nspname NOT IN (SELECT nspname FROM allowed)
  UNION ALL SELECT 'catalog: rule on ' || n.nspname || '.' || c.relname FROM pg_catalog.pg_rewrite r JOIN pg_catalog.pg_class c ON c.oid = r.ev_class JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace, me
   WHERE r.xmin::text = me.xid AND n.nspname NOT IN (SELECT nspname FROM allowed)
  UNION ALL SELECT 'catalog: function ' || n.nspname || '.' || p.proname FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace, me
   WHERE p.xmin::text = me.xid AND n.nspname NOT IN (SELECT nspname FROM allowed)
  UNION ALL SELECT 'catalog: type ' || n.nspname || '.' || t.typname FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace, me
   WHERE t.xmin::text = me.xid AND n.nspname NOT IN (SELECT nspname FROM allowed)
  UNION ALL SELECT 'catalog: schema ' || n.nspname FROM pg_catalog.pg_namespace n, me
   WHERE n.xmin::text = me.xid AND n.nspname NOT IN (SELECT nspname FROM allowed)`

export const outsideProblems = async (sql: Sql, schema: string, writesBefore: Map<string, { name: string; n: number }>): Promise<Array<string>> => {
  const problems = (await sql.query<{ problem: string }>(OUTSIDE_SQL, [schema])).map((r) => r.problem)
  for (const [relid, after] of await writesOutside(sql, schema)) if (after.n > (writesBefore.get(relid)?.n ?? 0)) problems.push(`rows written in ${after.name}`)
  return [...new Set(problems)]
}

const indexNameOf = async (f: MigrationFile): Promise<string | undefined> => {
  const [stmt] = await parseSql(f.sql)
  if (stmt?.kind !== "IndexStmt" || !stmt.node.concurrent || !stmt.node.idxname) return undefined
  const schema = stmt.node.relation?.schemaname
  return schema ? `${schema}.${stmt.node.idxname}` : String(stmt.node.idxname)
}

export interface ApplyResult {
  readonly applied: ReadonlyArray<string>
}

/**
 * Applies `plan.pending` in order. Each file runs in its own transaction with
 * its tracking row; a CREATE INDEX CONCURRENTLY file (alone in its file, by the
 * lint) runs outside a transaction and must leave a valid index. Refuses
 * contract files unless `allowContract` names each of them.
 */
export const applyPending = async (
  sql: Sql,
  tree: Tree,
  files: ReadonlyArray<MigrationFile>,
  options: { readonly by: string; readonly allowContract?: ReadonlyArray<string>; readonly target: string },
): Promise<ApplyResult> =>
  withLock(sql, tree, async () => {
    const plan = await planOf(sql, tree, files)
    const problems = planProblems(plan, tree, options.target)
    if (plan.tracking === "unreadable") problems.push(`this role cannot read ${tree.trackingTable}; use the owner credentials`)
    if (problems.length) throw new Error(problems.join("; "))
    const { contractReason } = await import("./lint.ts")
    const refused = plan.pending.filter((f) => contractReason(f.sql) !== undefined && !(options.allowContract ?? []).includes(f.name))
    if (refused.length) throw new Error(`contract migration(s) ${refused.map((f) => f.name).join(", ")} need --allow-contract <file> each, after the code that stopped using the old shape is deployed`)
    if (plan.tracking === "fresh") await ensureTrackingTable(sql, tree)
    const applied: Array<string> = []
    for (const f of plan.pending) {
      const index = await indexNameOf(f)
      if (index) {
        if (tree.name === "cmux-vm" && !index.startsWith(`${tree.schema}.`)) throw new Error(`${f.name}: CREATE INDEX CONCURRENTLY on a table outside schema ${tree.schema}; refused before it ran`)
        for (const q of sessionSettings(tree, "SESSION")) await sql.query(q)
        try {
          await sql.query(f.sql)
        } finally {
          await sql.query("RESET lock_timeout; RESET statement_timeout; RESET search_path")
        }
        const valid = (await sql.query<{ v: boolean | null }>("SELECT (SELECT indisvalid FROM pg_catalog.pg_index WHERE indexrelid = to_regclass($1)) AS v", [index]))[0]?.v
        if (valid !== true) throw new Error(`${f.name}: index ${index} is not valid after CREATE INDEX CONCURRENTLY; drop it (DROP INDEX CONCURRENTLY) in a new migration and retry`)
        await record(sql, tree, f, options.by)
      } else {
        await sql.query("BEGIN")
        try {
          for (const q of sessionSettings(tree, "LOCAL")) await sql.query(q)
          const writesBefore = tree.name === "cmux-vm" ? await writesOutside(sql, tree.schema) : new Map()
          await sql.query(f.sql)
          if (tree.name === "cmux-vm") {
            const outside = await outsideProblems(sql, tree.schema, writesBefore)
            if (outside.length) throw new Error(`wrote outside schema ${tree.schema} (cmux-old shares this database): ${outside.join("; ")}; rolled back`)
          }
          await record(sql, tree, f, options.by)
          await sql.query("COMMIT")
        } catch (e) {
          await sql.query("ROLLBACK")
          throw new Error(`${f.name}: ${(e as Error).message}`)
        }
      }
      applied.push(f.name)
    }
    return { applied }
  })

/** The requirements of `root`'s Worker build (cmux-vm only; backend checks the exact applied set instead). */
export const requirementsOf = async (tree: Tree, root?: string): Promise<ReadonlyArray<Requirement>> => {
  if (tree.name !== "cmux-vm") return []
  return (root ? (await requirementsModuleAt(root))?.REQUIRED_SCHEMA : undefined) ?? REQUIRED_SCHEMA
}

/** The Worker's own schema check: missing tables, columns or privileges (for `role`, '' = the connected role). */
export const schemaProblems = async (sql: Sql, requirements: ReadonlyArray<Requirement>, role = ""): Promise<Array<string>> => {
  if (requirements.length === 0) return []
  const rows = await sql.query<{ problem: string | null }>(SCHEMA_CHECK_SQL, schemaCheckParams(requirements, role))
  return [...new Set(rows.flatMap((r) => (r.problem === null ? [] : [r.problem])))]
}

/** Read-only smoke: every table of the tree's schema answers a one-row SELECT. */
export const smokeProblems = async (sql: Sql, tree: Tree): Promise<Array<string>> => {
  const tables = await sql.query<{ name: string }>(
    "SELECT n.nspname || '.' || c.relname AS name FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relkind IN ('r', 'p') AND NOT c.relispartition ORDER BY 1",
    [tree.schema],
  )
  const problems: Array<string> = []
  for (const { name } of tables) {
    try {
      await sql.query(`SELECT 1 FROM ${qualified(name)} LIMIT 1`)
    } catch (e) {
      problems.push(`${name}: ${(e as Error).message}`)
    }
  }
  return problems
}

/**
 * Records files that were applied by hand before tracking existed (cmux-vm
 * 0001-0008). Refuses unless the tracking table is absent or empty and the
 * Worker's schema check passes for every requirement up to `through`.
 */
export const adopt = async (sql: Sql, tree: Tree, files: ReadonlyArray<MigrationFile>, through: string, by: string, root?: string): Promise<Array<string>> =>
  withLock(sql, tree, async () => {
    const { tracking, applied } = await trackingState(sql, tree)
    if (tracking === "unreadable") throw new Error(`this role cannot read ${tree.trackingTable}; use the owner credentials`)
    if (applied.size > 0) throw new Error(`${tree.trackingTable} already has ${applied.size} rows; adopt only records a database that was never tracked`)
    const chosen = files.filter((f) => f.name.slice(0, 4) <= through)
    if (chosen.length === 0) throw new Error(`no migration up to ${through}`)
    const requirements = (await requirementsOf(tree, root)).filter((r) => r.migration <= through)
    const missing = (await schemaProblems(sql, requirements)).filter((p) => !p.includes(" privilege"))
    if (missing.length) throw new Error(`the database lacks what migrations up to ${through} add: ${missing.join(", ")}; apply them instead of adopting`)
    await ensureTrackingTable(sql, tree)
    for (const f of chosen) await record(sql, tree, f, by, true)
    return chosen.map((f) => f.name)
  })

export interface GateResult {
  readonly ok: boolean
  readonly errors: ReadonlyArray<string>
  readonly warnings: ReadonlyArray<string>
}

/**
 * The deploy ordering gate: may this tree's code (files = the deploying
 * commit's migrations) run on this database? Reads the database, never a file
 * about it. Refuses when a file of the commit is not applied (or applied with
 * another checksum), or when the Worker's schema check finds anything missing
 * for the connected role (privileges included).
 */
export const gate = async (sql: Sql, tree: Tree, files: ReadonlyArray<MigrationFile>, target: string, root?: string): Promise<GateResult> => {
  const errors: Array<string> = []
  const warnings: Array<string> = []
  const plan = await planOf(sql, tree, files)
  if (plan.tracking === "tracked") {
    const notApplied = files.filter((f) => !plan.applied.has(f.name)).map((f) => f.name)
    if (notApplied.length) errors.push(`${tree.name}/${target} lacks migration(s) this commit ships: ${notApplied.join(", ")}; rehearse and apply them first (db-release.ts rehearse, then apply)`)
    if (plan.mismatched.length) errors.push(`${tree.name}/${target} applied ${plan.mismatched.join(", ")} with another checksum`)
    if (plan.unknown.length) {
      if (tree.allowDatabaseAhead) warnings.push(`${tree.name}/${target} also has ${plan.unknown.join(", ")} (applied ahead of this commit)`)
      else errors.push(`${tree.name}/${target} has migrations this commit lacks: ${plan.unknown.join(", ")}`)
    }
  } else {
    const why = plan.tracking === "unreadable" ? `the deploy role cannot read ${tree.trackingTable}` : `${tree.trackingTable} does not exist (${plan.tracking})`
    if (tree.name === "cmux-vm") warnings.push(`${why}: the Worker schema check alone decides; run db-release.ts adopt to track this database`)
    else errors.push(`${why}: backend databases are always tracked`)
  }
  const requirements = await requirementsOf(tree, root)
  const latest = files.length ? files[files.length - 1]!.name.slice(0, 4) : "0000"
  if (tree.name === "cmux-vm" && requiredMigration(requirements) > latest) errors.push(`the Worker requires migration ${requiredMigration(requirements)} but this commit's newest is ${latest}`)
  for (const p of await schemaProblems(sql, requirements)) errors.push(`${tree.name}/${target}: ${p} (the Worker would answer 503)`)
  return { ok: errors.length === 0, errors, warnings }
}
