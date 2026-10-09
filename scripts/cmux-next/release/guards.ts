/** Who may apply, and from which checkout (db-release.ts apply and adopt). */
import { spawnSync } from "node:child_process"
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
export const requireOwner = async (provider: BranchProvider, tree: Tree, target: Target, sql: Sql, log: (l: string) => void) => {
  const current = (await sql.query<{ u: string }>("SELECT current_user AS u"))[0]?.u
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

/** What the connected role may do outside the tree's schema in a shared database (cmux-vm on cmux-prod). Empty: nothing. */
export const broadPrivileges = async (sql: Sql, schema: string): Promise<Array<string>> =>
  (
    await sql.query<{ p: string }>(
      `SELECT 'is a superuser' AS p WHERE (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user)
       UNION ALL SELECT 'is a member of postgres' WHERE current_user <> 'postgres' AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'postgres') AND pg_has_role(current_user, 'postgres', 'MEMBER')
       UNION ALL SELECT 'has CREATE on schema public' WHERE has_schema_privilege(current_user, 'public', 'CREATE')
       UNION ALL (SELECT 'can write ' || n.nspname || '.' || c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname NOT IN ($1, 'pg_catalog', 'information_schema', 'pg_toast') AND c.relkind IN ('r', 'p')
                     AND has_table_privilege(current_user, c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE') ORDER BY 1 LIMIT 5)
       UNION ALL SELECT 'owns objects outside ' || $1 WHERE EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname NOT IN ($1, 'pg_catalog', 'information_schema', 'pg_toast') AND pg_has_role(current_user, c.relowner, 'USAGE'))`,
      [schema],
    )
  ).map((r) => r.p)

const git = (root: string, args: ReadonlyArray<string>) => spawnSync("git", ["-C", root, ...args], { encoding: "utf8" })

/**
 * A production apply reads only landed files: a clean git checkout whose HEAD is on the landed
 * branch (CMUX_RELEASE_LANDED_REF, default origin/feat-cmux-next, fetched first). Returns that ref
 * for the lint's --base comparison.
 */
export const productionCheckout = (root: string, tree: Tree, env: Record<string, string | undefined>): string => {
  if (git(root, ["rev-parse", "--is-inside-work-tree"]).stdout.trim() !== "true") throw new Refused(`${root} is not a git checkout; a production apply reads only landed files`)
  const dirty = git(root, ["status", "--porcelain", "--", tree.dir, LOCK_PATH, "workers/cmux-vm/src/db/schema-requirements.ts"]).stdout.trim()
  if (dirty) throw new Refused(`uncommitted migration changes in ${root}:\n${dirty}\na production apply reads only landed files`)
  const ref = env.CMUX_RELEASE_LANDED_REF || "origin/feat-cmux-next"
  if (ref.startsWith("origin/")) git(root, ["fetch", "--quiet", "--no-tags", "origin", ref.slice("origin/".length)])
  const head = git(root, ["rev-parse", "HEAD"]).stdout.trim()
  if (git(root, ["merge-base", "--is-ancestor", "HEAD", ref]).status !== 0) throw new Refused(`HEAD ${head.slice(0, 12)} is not on ${ref}; a production apply runs only files that landed there`)
  return ref
}
