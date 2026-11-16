/**
 * Staging cmux_vm migrations from CI (cmux-vm.yml job migrate-staging; plans/cmux-next/release-rails.md,
 * "Staging migrations from CI"), so staging never waits for the one person holding the owner's login.
 *
 *   bun staging-owner.ts plan       read-only: db-release.ts plan against cmux-prod/staging (a 2 h read role)
 *   bun staging-owner.ts migrate    apply the pending cmux_vm files to cmux-prod/staging as cmux_vm_migrator
 *
 * migrate never learns or changes the owner's password (cmux_vm_migrator is a SQL role; its login stays
 * where it is). Instead, with the PlanetScale service token (PLANETSCALE_SERVICE_TOKEN_ID and
 * PLANETSCALE_SERVICE_TOKEN), it:
 *   1. creates a short-lived admin role on cmux-prod/staging (inherits postgres, 2 h TTL);
 *   2. as that role, GRANT cmux_vm_migrator TO itself;
 *   3. runs db-release.ts apply --set-role --skip-rehearsal: the session runs SET ROLE cmux_vm_migrator, so
 *      every object and tracking row belongs to the owner (the owner, lint and lock checks all still run);
 *   4. as the owner, grants the Worker role (cmux-vm-worker) what schema-requirements.ts names (migrations
 *      carry no GRANT), then requires the Worker's schema check to find no missing privilege;
 *   5. always: REVOKE cmux_vm_migrator from the temporary role, then deletes it by exact id.
 * The temporary role's password lives only in this process (masked in the Actions log first). Only branch
 * staging of cmux-prod is ever touched: the branch comes from trees.ts and the URL is checked against its id.
 */
import { pscaleProvider, must, type Connection, type RoleJson } from "./branches.ts"
import { contractReason, readMigrations } from "./lint.ts"
import { grantStatements, Refusal } from "./prod-owner.ts"
import { connectUrl, requirementsOf, schemaProblems, type Sql } from "./runner.ts"
import { ownerPgRoleOf, REPO_ROOT, TREES } from "./trees.ts"

const tree = TREES["cmux-vm"]
const DB = tree.database
const TARGET = "staging" as const
const BRANCH = tree.branches[TARGET]
const ADMIN_URL_ENV = "CMUX_VM_STAGING_ADMIN_URL"

export const quoteIdent = (name: string) => `"${name.replace(/"/g, '""')}"`

/** `url`'s user must be on cmux-prod/staging (`<role>.<staging branch id>`); anything else is refused before any write. */
export const stagingUser = (url: string): string => {
  const user = decodeURIComponent(new URL(url).username)
  const want = tree.branchIds[TARGET]
  if (!user.endsWith(`.${want}`)) throw new Refusal(`the temporary role is not on ${DB}/${BRANCH} (branch ${user.split(".").pop() || "?"}, want ${want})`)
  return user.slice(0, -(want.length + 1))
}

const mask = (value: string) => {
  if (process.env.GITHUB_ACTIONS && value) console.log(`::add-mask::${value}`)
}

const maskUrl = (url: string) => {
  const u = new URL(url)
  mask(decodeURIComponent(u.password))
  mask(u.password)
  mask(url)
}

const contractFiles = () => readMigrations(REPO_ROOT, tree).filter((f) => contractReason(f.sql) !== undefined).map((f) => f.name)

const releaseMain = async (argv: Array<string>, log: (l: string) => void, adminUrl?: string): Promise<void> => {
  const { defaultDeps, main } = await import("./db-release.ts")
  log(`$ db-release.ts ${argv.join(" ")}`)
  const deps = defaultDeps()
  const code = await main(argv, adminUrl ? { ...deps, env: { ...deps.env, [ADMIN_URL_ENV]: adminUrl } } : deps)
  if (code !== 0) throw new Refusal(`db-release.ts ${argv[0]} exited ${code}`)
}

const workerPgUser = async (): Promise<string> => {
  const roles = JSON.parse(await must(["role", "list", DB, BRANCH])) as Array<RoleJson>
  const user = roles.find((r) => r.name === tree.workerRole)?.username
  if (!user) throw new Refusal(`${DB}/${BRANCH} has no PlanetScale role ${tree.workerRole}; the Worker grants were not issued`)
  return user.replace(/\.[a-z0-9]+$/, "")
}

/** As the owner (SET ROLE on the temporary login): the Worker's grants, then its schema check. */
const grantWorker = async (sql: Sql, owner: string, log: (l: string) => void): Promise<void> => {
  const worker = await workerPgUser()
  const requirements = await requirementsOf(tree, REPO_ROOT)
  await sql.query(`SET ROLE ${quoteIdent(owner)}`)
  try {
    const statements = grantStatements(requirements, worker)
    for (const statement of statements) {
      await sql.query(statement)
      log(`  ${statement}`)
    }
    log(`granted the Worker role ${tree.workerRole} (${worker}) USAGE on ${tree.schema} and ${statements.length - 1} table privilege set(s), as ${owner}`)
    const missing = (await schemaProblems(sql, requirements, worker)).filter((p) => p.includes(" privilege"))
    if (missing.length) throw new Refusal(`after the grants, the Worker still lacks: ${missing.join("; ")}`)
    log(`Worker schema check: no missing privilege for ${worker}`)
  } finally {
    await sql.query("RESET ROLE")
  }
}

export const run = async (command: string | undefined, log = (l: string) => console.log(l)): Promise<number> => {
  const err = (l: string) => console.error(process.env.GITHUB_ACTIONS ? `::error title=staging-owner::${l}` : `staging-owner: ${l}`)
  const owner = ownerPgRoleOf(tree, TARGET)
  let conn: Connection | undefined
  let sql: Sql | undefined
  let granted: string | undefined
  try {
    if (command !== "plan" && command !== "migrate") throw new Refusal("usage: staging-owner.ts plan|migrate")
    if (!owner) throw new Refusal(`trees.ts names no SQL owner role for ${tree.name}/${TARGET}`)
    if (command === "plan") {
      await releaseMain(["plan", "--tree", tree.name, "--target", TARGET], log)
      return 0
    }
    conn = await pscaleProvider().connect(DB, BRANCH, "admin", "cmux-vm-stg-migrate")
    maskUrl(conn.url)
    const temp = stagingUser(conn.url)
    log(`created the short-lived admin role ${temp} on ${DB}/${BRANCH} (2 h TTL; deleted at the end)`)
    sql = await connectUrl(conn.url)
    await sql.query(`GRANT ${quoteIdent(owner)} TO ${quoteIdent(temp)}`)
    granted = temp
    log(`GRANT ${owner} TO ${temp}`)
    const allow = contractFiles().flatMap((f) => ["--allow-contract", f])
    await releaseMain(["apply", "--tree", tree.name, "--target", TARGET, "--url-env", ADMIN_URL_ENV, "--set-role", "--skip-rehearsal", ...allow], log, conn.url)
    await grantWorker(sql, owner, log)
    return 0
  } catch (e) {
    err((e as Error).message)
    return 1
  } finally {
    if (sql && granted && owner) {
      try {
        await sql.query("RESET ROLE")
        await sql.query(`REVOKE ${quoteIdent(owner)} FROM ${quoteIdent(granted)}`)
        log(`REVOKE ${owner} FROM ${granted}`)
      } catch (e) {
        err(`could not revoke ${owner} from ${granted} (the role is deleted next and expires in 2 h): ${(e as Error).message}`)
      }
    }
    await sql?.end().catch(() => {})
    if (conn) {
      await conn.release()
      log("deleted the short-lived admin role")
    }
  }
}

if (import.meta.main) process.exit(await run(process.argv[2]))
