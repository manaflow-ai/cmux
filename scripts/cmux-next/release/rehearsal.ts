/**
 * One rehearsal on a throwaway PlanetScale branch (db-release.ts rehearse, and every apply in the
 * same run): copy the target, check the copy has exactly the rows the plan starts from, apply the
 * pending files as the owner role, run the Worker schema check and a read smoke, and delete the
 * branch by the exact name this run created.
 */
import { rehearsalBranchName, type BranchProvider } from "./branches.ts"
import type { MigrationFile } from "./lint.ts"
import type { Receipt } from "./receipts.ts"
import { adopt, applyPending, planOf, requirementsOf, schemaProblems, setHashOf, smokeProblems, type Plan, type Sql } from "./runner.ts"
import type { Target, Tree } from "./trees.ts"

export interface RehearsalContext {
  readonly provider: BranchProvider
  readonly connect: (url: string) => Promise<Sql>
  readonly root: string
  readonly now: () => Date
  readonly log: (l: string) => void
  readonly emit: (r: Receipt) => string
  readonly tree: Tree
  readonly target: Target
  readonly files: ReadonlyArray<MigrationFile>
  /** The plan the target starts from (after a planned adopt, if any). */
  readonly wanted: Plan
  readonly setHash: string
  readonly adoptThrough?: string
  readonly allowContract: ReadonlyArray<string>
  readonly by: string
  /** A login of the owner on the target; the copy restored the same role and password. */
  readonly ownerUrl?: string
  /** The owner's Postgres role when it is a SQL role (no PlanetScale record). */
  readonly ownerPgRole?: string
}

export interface RehearsalOutcome {
  readonly branch: string
  readonly deleted: boolean
  readonly errors: Array<string>
  readonly warnings: Array<string>
}

export const describePlan = (plan: Plan) =>
  `tracking=${plan.tracking} applied=${plan.applied.size} pending=${plan.pending.map((f) => f.name).join(",") || "none"}${plan.unknown.length ? ` unknown=${plan.unknown.join(",")}` : ""}${plan.mismatched.length ? ` mismatched=${plan.mismatched.join(",")}` : ""}`

export const rehearseOnCopy = async (c: RehearsalContext): Promise<RehearsalOutcome> => {
  const { tree, target } = c
  const name = rehearsalBranchName(tree.name, target, c.now())
  const errors: Array<string> = []
  const warnings: Array<string> = []
  const at = () => c.now().toISOString()
  let deleted = false
  // Recorded before the create, so `cleanup` finds the branch even if this run dies mid-create.
  c.emit({ action: "branch-created", tree: tree.name, target, result: "pass", at: at(), branch: name, by: c.by })
  try {
    await c.provider.create(tree.database, name, tree.branches[target])
    // Act as the copy's own owner-role record (the copy restored the parent's roles), so the
    // rehearsal meets the same ownership and privileges as the real apply.
    const owner = c.ownerPgRole ?? (await c.provider.roleUser(tree.database, tree.branches[target], tree.ownerRole))
    c.log(`copy ${name} lists roles: ${(await c.provider.roleNames(tree.database, name)).join(", ") || "none"}`)
    // In order: the owner's own login rewritten for the copy, the copy's own owner-role record, the copy's default role.
    const copyLogin = c.ownerUrl ? await c.provider.copyUrl(tree.database, name, c.ownerUrl) : undefined
    const asOwner = copyLogin ? { url: copyLogin, release: async () => {} } : await c.provider.connectRole(tree.database, name, tree.ownerRole)
    const conn = asOwner ?? (await c.provider.connectDefault(tree.database, name))
    const sql = await c.connect(conn.url)
    try {
      if (owner && !asOwner) {
        try {
          await sql.query(`SET ROLE "${owner.replace(/"/g, '""')}"`)
        } catch (e) {
          const why = `could not act as ${tree.ownerRole} (${owner}) on the copy (${(e as Error).message})`
          // Production must rehearse with the real ownership; elsewhere a warning.
          if (target === "production") throw new Error(`${why}; a production rehearsal must run as the owner`)
          warnings.push(`${why}; rehearsed as an admin role, so ownership errors may differ`)
        }
      }
      c.log(`rehearsal acts as: ${(await sql.query<{ u: string }>("SELECT current_user AS u"))[0]?.u}`)
      let copyPlan = await planOf(sql, tree, c.files)
      if (copyPlan.tracking === "untracked" && c.adoptThrough) {
        await adopt(sql, tree, c.files, c.adoptThrough, c.by, c.root)
        copyPlan = await planOf(sql, tree, c.files)
      }
      if ((await setHashOf(tree, copyPlan)) !== c.setHash) {
        errors.push(`the branch copy (${describePlan(copyPlan)}) differs from ${target}; its backup may predate a recent apply: retry later`)
      } else {
        const result = await applyPending(sql, tree, c.files, { by: c.by, allowContract: c.allowContract, target })
        c.log(`rehearsal applied: ${result.applied.join(", ") || "nothing pending"}`)
        const after = await planOf(sql, tree, c.files)
        if (after.pending.length) errors.push(`still pending after apply: ${after.pending.map((f) => f.name).join(", ")}`)
        const requirements = await requirementsOf(tree, c.root)
        for (const p of await schemaProblems(sql, requirements)) if (!p.includes(" privilege")) errors.push(`schema check: ${p}`)
        const worker = await c.provider.roleUser(tree.database, tree.branches[target], tree.workerRole)
        if (worker) {
          const exists = (await sql.query<{ n: string }>("SELECT count(*)::text AS n FROM pg_roles WHERE rolname = $1", [worker]))[0]?.n === "1"
          if (exists) for (const p of await schemaProblems(sql, requirements, worker)) if (p.includes(" privilege")) warnings.push(`${tree.workerRole}: ${p}; the deploy gate refuses until it is granted`)
        }
        for (const p of await smokeProblems(sql, tree)) errors.push(`smoke: ${p}`)
      }
    } finally {
      await sql.end()
      await conn.release()
    }
  } catch (e) {
    errors.push((e as Error).message)
  } finally {
    try {
      if (await c.provider.exists(tree.database, name)) await c.provider.delete(tree.database, name)
      deleted = !(await c.provider.exists(tree.database, name))
      if (!deleted) errors.push(`branch ${name} still exists after delete`)
    } catch (e) {
      errors.push(`could not delete ${name}: ${(e as Error).message}; run db-release.ts cleanup`)
    }
    if (deleted) c.emit({ action: "branch-deleted", tree: tree.name, target, result: "pass", at: at(), branch: name, by: c.by })
  }
  return { branch: name, deleted, errors, warnings }
}

/** The receipt of one rehearsal. */
export const rehearsalReceipt = (c: RehearsalContext, o: RehearsalOutcome, gitSha?: string): Receipt => ({
  action: "rehearse",
  what: `rehearse ${c.wanted.pending.map((f) => f.name).join(", ") || "nothing pending"} on throwaway branch ${c.tree.database}/${o.branch} copied from ${c.tree.branches[c.target]}`,
  tree: c.tree.name,
  target: c.target,
  before: [...c.wanted.applied.keys()].sort(),
  after: [...c.wanted.applied.keys(), ...c.wanted.pending.map((f) => f.name)].sort(),
  rollback: [`nothing to undo: branch ${o.branch} was ${o.deleted ? "deleted" : "NOT deleted (run db-release.ts cleanup)"}`],
  result: o.errors.length ? "fail" : "pass",
  at: c.now().toISOString(),
  setHash: c.setHash,
  pending: c.wanted.pending.map((f) => ({ name: f.name, checksum: f.checksum })),
  branch: o.branch,
  branchDeleted: o.deleted,
  ...(o.errors.length ? { errors: o.errors } : {}),
  ...(o.warnings.length ? { warnings: o.warnings } : {}),
  ...(gitSha ? { gitSha } : {}),
  by: c.by,
})
