/** Who may apply, and from which checkout (db-release.ts apply and adopt). */
import { spawnSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { LOCK_PATH } from "./lint.ts"
import type { BranchProvider } from "./branches.ts"
import type { Sql } from "./runner.ts"
import type { Target, Tree } from "./trees.ts"

export class Refused extends Error {}

/**
 * apply and adopt write as the target's owner role (objects and the tracking table keep that
 * owner). Refuses another role, and refuses when pscale cannot name the owner of a staging or
 * production branch (fail closed).
 */
export const requireOwner = async (provider: BranchProvider, tree: Tree, target: Target, sql: Sql, log: (l: string) => void, ownerPgRole?: string | null) => {
  const who = (await sql.query<{ u: string; s: string }>("SELECT current_user AS u, session_user::text AS s"))[0]
  const current = who?.u
  // A login that only acts as the owner (SET ROLE, options=-c role=...) keeps its own, wider rights.
  if (who && who.s !== who.u) throw new Refused(`the connection logs in as ${who.s} (session_user) and acts as ${who.u}; log in as the owner itself`)
  if (ownerPgRole) {
    // A SQL owner role (no PlanetScale record): named in trees.ts, checked directly.
    log(`connected as ${current} (owner ${ownerPgRole})`)
    if (current !== ownerPgRole) throw new Refused(`--url-env connects as ${current}, not the owner ${ownerPgRole}; objects and ${tree.trackingTable} must belong to the owner`)
    return
  }
  let owner: string | undefined
  try {
    owner = await provider.roleUser(tree.database, tree.branches[target], tree.ownerRole)
  } catch (e) {
    const why = `cannot confirm the owner role ${tree.ownerRole} on ${tree.database}/${tree.branches[target]} (${(e as Error).message.slice(0, 120)})`
    if (target !== "development") throw new Refused(`${why}; refusing (pscale auth check --org cmux)`)
    log(`warning: ${why}; development is not checked`)
    return
  }
  if (!owner && target !== "development") throw new Refused(`cannot confirm the owner role: ${tree.database}/${tree.branches[target]} has no PlanetScale role named ${tree.ownerRole}`)
  log(`connected as ${current}${owner ? ` (owner ${tree.ownerRole} is ${owner})` : ""}`)
  if (owner && current !== owner) throw new Refused(`--url-env connects as ${current}, not the owner ${tree.ownerRole} (${owner}); objects and ${tree.trackingTable} must belong to the owner`)
}

/**
 * What the connected role may do outside the tree's schema in a shared database (cmux-vm on
 * cmux-prod). Empty: nothing. Membership counts with or without INHERIT (pg_has_role MEMBER).
 * Database CREATE is judged by the caller (db-release apply): only a bootstrap needs it.
 */
export const broadPrivileges = async (sql: Sql, schema: string): Promise<Array<string>> =>
  (
    await sql.query<{ p: string }>(
      `WITH outside AS (SELECT c.oid, c.relkind, n.nspname || '.' || c.relname AS name, c.relowner FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                         WHERE n.nspname NOT IN ($1, 'pg_catalog', 'information_schema', 'pg_toast'))
       SELECT 'is a superuser' AS p WHERE (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user)
       UNION ALL SELECT 'is a member of postgres' WHERE current_user <> 'postgres' AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'postgres') AND pg_has_role(current_user, 'postgres', 'MEMBER')
       UNION ALL SELECT 'can create roles' WHERE (SELECT rolcreaterole FROM pg_catalog.pg_roles WHERE rolname = current_user)
       UNION ALL SELECT 'can create databases' WHERE (SELECT rolcreatedb FROM pg_catalog.pg_roles WHERE rolname = current_user)
       UNION ALL (SELECT 'has CREATE on schema ' || n.nspname FROM pg_catalog.pg_namespace n
                   WHERE n.nspname NOT IN ($1, 'public', 'pg_catalog', 'information_schema', 'pg_toast') AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast_temp%'
                     AND has_schema_privilege(current_user, n.oid, 'CREATE') ORDER BY 1 LIMIT 5)
       UNION ALL (SELECT 'has column privileges on ' || name FROM outside WHERE CASE WHEN relkind IN ('r', 'p', 'v', 'm', 'f') THEN has_any_column_privilege(current_user, oid, 'SELECT, INSERT, UPDATE, REFERENCES') AND NOT has_table_privilege(current_user, oid, 'SELECT') ELSE false END ORDER BY 1 LIMIT 5)
       UNION ALL SELECT 'bypasses row level security' WHERE (SELECT rolbypassrls FROM pg_catalog.pg_roles WHERE rolname = current_user)
       UNION ALL SELECT 'has REPLICATION' WHERE (SELECT rolreplication FROM pg_catalog.pg_roles WHERE rolname = current_user)
       UNION ALL (SELECT 'is a member of ' || r.rolname FROM pg_catalog.pg_roles r WHERE r.rolname LIKE 'pg\_%' AND pg_has_role(current_user, r.oid, 'MEMBER') ORDER BY 1)
       UNION ALL (SELECT 'can execute SECURITY DEFINER ' || n.nspname || '.' || p.proname FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
                   WHERE p.prosecdef AND n.nspname NOT IN ($1, 'pg_catalog', 'information_schema') AND has_function_privilege(current_user, p.oid, 'EXECUTE') ORDER BY 1 LIMIT 5)
       UNION ALL SELECT 'has CREATE on schema public' WHERE has_schema_privilege(current_user, 'public', 'CREATE')
       UNION ALL (SELECT 'can write ' || name FROM outside WHERE CASE WHEN relkind IN ('r', 'p', 'v', 'm', 'f') THEN has_table_privilege(current_user, oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER') ELSE false END ORDER BY 1 LIMIT 5)
       UNION ALL (SELECT 'can read ' || name FROM outside WHERE CASE WHEN relkind IN ('r', 'p', 'v', 'm', 'f') THEN has_table_privilege(current_user, oid, 'SELECT') ELSE false END ORDER BY 1 LIMIT 5)
       UNION ALL (SELECT 'can use or update sequence ' || name FROM outside WHERE CASE WHEN relkind = 'S' THEN has_sequence_privilege(current_user, oid, 'USAGE, SELECT, UPDATE') ELSE false END ORDER BY 1 LIMIT 5)
       UNION ALL SELECT 'owns objects outside ' || $1 WHERE
              EXISTS (SELECT 1 FROM outside WHERE pg_has_role(current_user, relowner, 'MEMBER'))
           OR EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname NOT IN ($1, 'pg_catalog', 'information_schema') AND pg_has_role(current_user, p.proowner, 'MEMBER'))
           OR EXISTS (SELECT 1 FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname NOT IN ($1, 'pg_catalog', 'information_schema', 'pg_toast') AND pg_has_role(current_user, t.typowner, 'MEMBER'))
           OR EXISTS (SELECT 1 FROM pg_catalog.pg_namespace n WHERE n.nspname NOT IN ($1, 'pg_catalog', 'information_schema', 'pg_toast') AND n.nspname NOT LIKE 'pg_temp%' AND n.nspname NOT LIKE 'pg_toast_temp%' AND pg_has_role(current_user, n.nspowner, 'MEMBER'))`,
      [schema],
    )
  ).map((r) => r.p)

const git = (root: string, args: ReadonlyArray<string>) => spawnSync("git", ["-C", root, ...args], { encoding: "utf8" })

/** The only landed source a production apply accepts: manaflow-ai/cmux, branch feat-cmux-next. */
export const LANDED_REMOTE = /^(https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)manaflow-ai\/cmux(\.git)?$/
const LANDED_BRANCH = "feat-cmux-next"

/**
 * A production apply reads only landed files: a clean git checkout (migrations, the release rails
 * and the Worker requirements) whose origin is manaflow-ai/cmux and whose HEAD is an ancestor of
 * that remote's feat-cmux-next as `git ls-remote` reports it now (fetched first; a failed fetch
 * refuses). Returns that commit for the lint's --base comparison. `remote` is for tests only.
 */
export const productionCheckout = (root: string, tree: Tree, remote: RegExp = LANDED_REMOTE): { remote: string; head: string } => {
  if (git(root, ["rev-parse", "--is-inside-work-tree"]).stdout.trim() !== "true") throw new Refused(`${root} is not a git checkout; a production apply reads only landed files`)
  const dirty = git(root, ["status", "--porcelain", "--", tree.dir, "scripts/cmux-next/release", LOCK_PATH, "workers/cmux-vm/src/db/schema-requirements.ts"]).stdout.trim()
  if (dirty) throw new Refused(`uncommitted migration changes in ${root}:\n${dirty}\na production apply reads only landed files`)
  const url = git(root, ["remote", "get-url", "origin"]).stdout.trim()
  if (!remote.test(url)) throw new Refused(`origin ${url || "(none)"} is not manaflow-ai/cmux; a production apply reads only files landed there`)
  const listed = git(root, ["ls-remote", "origin", `refs/heads/${LANDED_BRANCH}`])
  const remoteSha = listed.stdout.trim().split(/\s+/)[0] ?? ""
  if (listed.status !== 0 || !/^[0-9a-f]{40}$/.test(remoteSha)) throw new Refused(`cannot read origin ${LANDED_BRANCH} (git ls-remote: ${listed.stderr.trim().slice(0, 200)})`)
  const fetched = git(root, ["fetch", "--quiet", "--no-tags", "origin", LANDED_BRANCH])
  if (fetched.status !== 0) throw new Refused(`git fetch origin ${LANDED_BRANCH} failed: ${fetched.stderr.trim().slice(0, 200)}`)
  const head = git(root, ["rev-parse", "HEAD"]).stdout.trim()
  if (git(root, ["merge-base", "--is-ancestor", head, remoteSha]).status !== 0) throw new Refused(`HEAD ${head.slice(0, 12)} is not on origin/${LANDED_BRANCH} (${remoteSha.slice(0, 12)}); a production apply runs only files that landed there`)
  return { remote: remoteSha, head }
}

/** Refuses when the checkout's HEAD moved, or its migrations/rails/requirements changed, after productionCheckout (checked right before writing). */
export const stillAt = (root: string, tree: Tree, head: string) => {
  const now = git(root, ["rev-parse", "HEAD"]).stdout.trim()
  if (now !== head) throw new Refused(`HEAD moved from ${head.slice(0, 12)} to ${now.slice(0, 12)} during the run; refusing`)
  const dirty = git(root, ["status", "--porcelain", "--", tree.dir, "scripts/cmux-next/release", LOCK_PATH, "workers/cmux-vm/src/db/schema-requirements.ts"]).stdout.trim()
  if (dirty) throw new Refused(`uncommitted migration changes appeared during the run:\n${dirty}`)
}

/** Whether the connected role may create schemas in the database (needed only to bootstrap the tree's schema). */
export const hasDatabaseCreate = async (sql: Sql): Promise<boolean> => (await sql.query<{ c: boolean }>("SELECT has_database_privilege(current_database(), 'CREATE') AS c"))[0]?.c === true

/**
 * Code a production step must not let the runtime load besides this checkout (P3-2): preload or
 * option variables, and a bunfig.toml with a preload next to the rails or in the working directory.
 */
export const runtimeInjection = (
  env: Record<string, string | undefined>,
  dirs: ReadonlyArray<string>,
  execArgv: ReadonlyArray<string> = process.execArgv,
  paths: { readonly home?: string } = { home: env.HOME },
): Array<string> => {
  const problems: Array<string> = []
  const variables = ["NODE_OPTIONS", "BUN_OPTIONS", "NODE_PATH", "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"]
  for (const [k, v] of Object.entries(env)) if (v && (variables.includes(k) || k.startsWith("BUN_CONFIG_"))) problems.push(`${k} is set`)
  for (const a of execArgv) if (/^(--preload|-r|--require|--import|--loader)(=|$)/.test(a)) problems.push(`the runtime was started with ${a}`)
  const files = [...dirs.map((d) => `${d}/bunfig.toml`), ...(paths.home ? [`${paths.home}/.bunfig.toml`] : []), ...(env.XDG_CONFIG_HOME ? [`${env.XDG_CONFIG_HOME}/.bunfig.toml`] : [])]
  for (const file of files) if (existsSync(file) && /\bpreload\b/.test(readFileSync(file, "utf8"))) problems.push(`${file} has a preload`)
  return problems
}
