/**
 * Rehearse-then-apply for cmux-next Cloud migrations (plans/cmux-next/release-rails.md).
 *
 *   bun db-release.ts plan     --tree T --target X [--url-env VAR]
 *   bun db-release.ts rehearse --tree T --target X [--url-env VAR] [--adopt-through NNNN] [--allow-contract F]... [--root DIR]
 *   bun db-release.ts apply    --tree T --target X --url-env VAR [--staging-url-env VAR] [--confirm-production] [--allow-contract F]...
 *   bun db-release.ts adopt    --tree cmux-vm --target X --url-env VAR --through NNNN [--confirm-production]
 *   bun db-release.ts gate     --tree T --target X --url-env VAR      (deploy ordering gate; read-only)
 *   bun db-release.ts cleanup  [--tree T]                              (delete stranded rehearsal branches by exact name)
 *   bun db-release.ts receipts [--tree T] [--target X]
 *
 * T: cmux-vm | backend. X: development | staging | production (PlanetScale org
 * cmux; databases and branches come from trees.ts, never from the caller).
 *
 * --url-env names an environment variable holding a connection URL; its user
 * name must belong to the target's PlanetScale branch (a URL for another branch
 * or database is refused). Without it, plan and rehearse read the target
 * through a 2 h read-only pscale role that is deleted afterwards. apply and
 * adopt need --url-env with the owner's credentials (objects keep their owner).
 *
 * rehearse: plans against the target, creates branch rh-<tree>-<target>-<time>-<hex>
 * from it, checks the copy has exactly the target's applied rows, applies the
 * pending files, runs the Worker schema check and a read smoke of every table,
 * deletes the branch by that exact name, and writes a receipt.
 * apply: takes the target's advisory lock first, checks the owner role (and, on
 * cmux-prod, that it has no power outside cmux_vm), plans, rehearses the exact
 * set on a throwaway copy in the same run, and only then applies. Production
 * also needs a clean checkout landed on feat-cmux-next, the cmux-old compat
 * receipts, and staging to have every pending file with the same checksum.
 * Idempotent: nothing pending is a no-op pass.
 */
import { execFileSync } from "node:child_process"
import { join } from "node:path"
import { pscaleProvider, REHEARSAL_BRANCH, type BranchProvider } from "./branches.ts"
import { broadPrivileges, productionCheckout, Refused, requireOwner } from "./guards.ts"
import { CONTRACT_PATH, lintTree, LOCK_PATH, readJson, readMigrations, rollbackSection, type Lock, type MigrationFile, type RoleContract } from "./lint.ts"
import { actor, receiptsDir, readReceipts, runIdOf, strandedBranches, summaryLine, withLocalLock, writeReceipt, type Receipt } from "./receipts.ts"
import { describePlan, rehearsalReceipt, rehearseOnCopy, type RehearsalContext } from "./rehearsal.ts"
import { adopt, applyPending, connectUrl, gate, planOf, planProblems, requirementsOf, schemaProblems, setHashOf, withLock, type Plan, type Sql } from "./runner.ts"
import { REPO_ROOT, targetOf, TREE_NAMES, TREES, treeOf, type Target, type Tree } from "./trees.ts"

export interface Deps {
  readonly provider: BranchProvider
  readonly connect: (url: string) => Promise<Sql>
  readonly env: Record<string, string | undefined>
  readonly root: string
  readonly now: () => Date
  readonly log: (line: string) => void
  readonly error: (line: string) => void
  /** Tests only: accept URLs that are not PlanetScale branch URLs. No CLI flag sets this. */
  readonly allowScratchUrls?: boolean
}

const defaultDeps = (): Deps => ({
  provider: pscaleProvider(),
  connect: connectUrl,
  env: process.env,
  root: REPO_ROOT,
  now: () => new Date(),
  log: (l) => console.log(l),
  error: (l) => console.error(process.env.GITHUB_ACTIONS ? `::error title=db-release::${l}` : `db-release: ${l}`),
})

const gitSha = (deps: Deps) => {
  if (deps.env.GITHUB_SHA) return deps.env.GITHUB_SHA
  try {
    return execFileSync("git", ["-C", deps.root, "rev-parse", "HEAD"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim()
  } catch {
    return undefined
  }
}

/** The URL in `varName`, refused unless its user belongs to the target's branch. */
const urlFrom = (deps: Deps, tree: Tree, target: Target, varName: string): string => {
  const url = deps.env[varName]
  if (!url) throw new Refused(`${varName} is empty`)
  if (!deps.allowScratchUrls) {
    let user: string
    try {
      user = decodeURIComponent(new URL(url).username)
    } catch {
      throw new Refused(`${varName} is not a URL`)
    }
    const want = tree.branchIds[target]
    if (!user.endsWith(`.${want}`)) throw new Refused(`${varName} is not for ${tree.database}/${tree.branches[target]} (branch ${user.split(".").pop() || "?"}, want ${want}); refusing`)
  }
  return url
}

interface Opened {
  readonly sql: Sql
  close(): Promise<void>
}

const open = async (deps: Deps, tree: Tree, target: Target, urlVar: string | undefined, access: "read" | "admin"): Promise<Opened> => {
  if (urlVar) {
    const sql = await deps.connect(urlFrom(deps, tree, target, urlVar))
    return { sql, close: () => sql.end() }
  }
  if (access === "admin") throw new Refused("this command needs --url-env with the owner's credentials for the target")
  // A new production credential needs the chief's go (lane rules, 2026-10-09): never mint one here.
  if (target === "production") throw new Refused("production reads need --url-env with an existing read credential; this tool creates no role on production")
  const conn = await deps.provider.connect(tree.database, tree.branches[target], "read", "rr-read")
  let sql: Sql
  try {
    sql = await deps.connect(conn.url)
  } catch (e) {
    await conn.release()
    throw e
  }
  return {
    sql,
    close: async () => {
      await sql.end()
      await conn.release()
    },
  }
}

/** The plan an untracked target would have after `adopt --through`: those files applied, the rest pending. */
const asAdopted = (plan: Plan, files: ReadonlyArray<MigrationFile>, through: string | undefined): Plan => {
  if (plan.tracking !== "untracked" || !through) return plan
  const applied = new Map(files.filter((f) => f.name.slice(0, 4) <= through).map((f) => [f.name, f.checksum]))
  return { tracking: "tracked", applied, pending: files.filter((f) => !applied.has(f.name)), unknown: [], mismatched: [] }
}

/** rehearse and apply refuse a tree the linter refuses (rules, numbering, lock; production also against the landed ref). */
const lintOrRefuse = async (deps: Deps, tree: Tree, base?: string) => {
  const report = await lintTree(tree, { root: deps.root, lock: readJson<Lock>(join(deps.root, LOCK_PATH)), contract: readJson<RoleContract>(join(deps.root, CONTRACT_PATH)), ...(base ? { base } : {}) })
  for (const n of report.notes) deps.log(`note: ${n}`)
  if (report.errors.length) throw new Refused(`migration lint refuses this tree:\n  ${report.errors.join("\n  ")}`)
}

/** Undo steps for an apply, newest first: the Worker code, then each file's own Rollback section. */
const rollbackOf = (tree: Tree, target: Target, pending: ReadonlyArray<MigrationFile>): Array<string> => {
  const worker = tree.workers[target]
  const steps = [
    worker
      ? `code first: \`wrangler rollback <version that served before the deploy needing these files> --name ${worker}\` (worker-release.ts printed it as "previous version")`
      : "code first: roll back the Worker build that needs these files",
  ]
  for (const f of [...pending].reverse()) steps.push(`${f.name}: ${rollbackSection(f.sql) ?? "no Rollback section; an expand migration stays in place after a code rollback"}`)
  return steps
}

const values = (argv: ReadonlyArray<string>, flag: string) => argv.flatMap((a, i) => (a === flag && argv[i + 1] ? [argv[i + 1]!] : []))

export const main = async (argv: ReadonlyArray<string>, initialDeps: Deps = defaultDeps()): Promise<number> => {
  let deps = initialDeps
  const [command, ...rest] = argv
  const value = (flag: string) => values(rest, flag)[0]
  const flag = (name: string) => rest.includes(name)
  const dir = receiptsDir(deps.env)
  const by = actor()
  const runId = runIdOf(deps.env)
  const at = () => deps.now().toISOString()
  const emit = (receipt: Receipt) => {
    const full = { ...receipt, runId }
    const file = writeReceipt(dir, full)
    deps.log(`bd-summary: ${summaryLine(full, file)}`)
    return file
  }
  try {
    if (command === "receipts") {
      for (const r of readReceipts(dir)) if ((!value("--tree") || r.tree === value("--tree")) && (!value("--target") || r.target === value("--target"))) deps.log(summaryLine(r, r.file))
      return 0
    }
    if (command === "cleanup") {
      return await withLocalLock(dir, "cleanup", async () => {
        let failed = 0
        for (const r of strandedBranches(dir)) {
          if (value("--tree") && r.tree !== value("--tree")) continue
          const tree = treeOf(r.tree)
          if (!r.branch || !REHEARSAL_BRANCH.test(r.branch)) continue
          try {
            if (await deps.provider.exists(tree.database, r.branch)) await deps.provider.delete(tree.database, r.branch)
            emit({ action: "branch-deleted", tree: r.tree, target: r.target, result: "pass", at: at(), branch: r.branch, by })
          } catch (e) {
            failed++
            deps.error(`could not delete ${tree.database}/${r.branch}: ${(e as Error).message}`)
          }
        }
        return failed ? 1 : 0
      })
    }

    const tree = treeOf(value("--tree"))
    const target = targetOf(value("--target"))
    if ((command === "apply" || command === "adopt") && target === "production" && !flag("--confirm-production")) throw new Refused(`${command} to production needs --confirm-production`)
    if (value("--root")) {
      // A candidate checkout: the lint, the lock and the files come from there. gate judges the
      // deploying commit and adopt has no files to choose; production applies only landed files.
      if (command === "adopt" || command === "gate") throw new Refused("--root is for plan, rehearse and apply only")
      if (command === "apply" && target === "production") throw new Refused("--root is refused for production: apply from a clean checkout landed on feat-cmux-next")
      deps = { ...deps, root: value("--root")! }
    }
    const files = readMigrations(deps.root, tree)
    const urlVar = value("--url-env")
    const allowContract = values(rest, "--allow-contract")
    const rehearsalOf = (wanted: Plan, setHash: string, adoptThrough?: string): RehearsalContext => ({
      provider: deps.provider,
      connect: deps.connect,
      root: deps.root,
      now: deps.now,
      log: deps.log,
      emit,
      tree,
      target,
      files,
      wanted,
      setHash,
      ...(adoptThrough ? { adoptThrough } : {}),
      allowContract,
      by,
    })

    switch (command) {
      case "plan": {
        const db = await open(deps, tree, target, urlVar, "read")
        try {
          const plan = await planOf(db.sql, tree, files)
          deps.log(`${tree.name}/${target}: ${describePlan(plan)} set=${(await setHashOf(tree, plan)).slice(0, 12)}`)
          for (const p of planProblems(plan, tree, target)) deps.error(p)
          return planProblems(plan, tree, target).length ? 1 : 0
        } finally {
          await db.close()
        }
      }

      case "gate": {
        if (!urlVar) throw new Refused("gate needs --url-env (the deploy's own database credentials)")
        const db = await open(deps, tree, target, urlVar, "read")
        try {
          const result = await gate(db.sql, tree, files, target, deps.root)
          for (const w of result.warnings) deps.log(`warning: ${w}`)
          for (const e of result.errors) deps.error(`deploy refused: ${e}`)
          if (result.ok) deps.log(`gate ok: ${tree.name}/${target} has every migration this commit needs (${files.length} files)`)
          return result.ok ? 0 : 1
        } finally {
          await db.close()
        }
      }

      case "rehearse":
        return await withLocalLock(dir, `rehearse-${tree.name}-${target}`, async () => {
          await lintOrRefuse(deps, tree)
          const adoptThrough = value("--adopt-through")
          const db = await open(deps, tree, target, urlVar, "read")
          let targetPlan: Plan
          try {
            targetPlan = await planOf(db.sql, tree, files)
          } finally {
            await db.close()
          }
          const wanted = asAdopted(targetPlan, files, adoptThrough)
          const problems = planProblems(wanted, tree, target)
          if (problems.length) throw new Refused(problems.join("; "))
          const setHash = await setHashOf(tree, wanted)
          deps.log(`${tree.name}/${target}: ${describePlan(wanted)} set=${setHash.slice(0, 12)}`)
          const context = rehearsalOf(wanted, setHash, adoptThrough)
          const outcome = await rehearseOnCopy(context)
          for (const w of outcome.warnings) deps.log(`warning: ${w}`)
          for (const e of outcome.errors) deps.error(`rehearsal: ${e}`)
          emit(rehearsalReceipt(context, outcome, gitSha(deps)))
          return outcome.errors.length ? 1 : 0
        })

      case "apply":
        return await withLocalLock(dir, `apply-${tree.name}-${target}`, async () => {
          const base = target === "production" ? productionCheckout(deps.root, tree, deps.env) : undefined
          await lintOrRefuse(deps, tree, base)
          if (!urlVar) throw new Refused("apply needs --url-env with the owner's credentials for the target")
          const db = await open(deps, tree, target, urlVar, "admin")
          try {
            // The lock comes first: the plan, the rehearsal and the apply all see one state.
            return await withLock(db.sql, tree, async () => {
              await requireOwner(deps.provider, tree, target, db.sql, deps.log)
              const warnings: Array<string> = []
              const broad = tree.name === "cmux-vm" ? await broadPrivileges(db.sql, tree.schema) : []
              if (broad.length) {
                const what = `the owner role ${broad.join(", ")} (cmux-old shares this database)`
                if (target === "production") throw new Refused(`${what}; never on production: use a cmux_vm-only owner role (plans/cmux-next/release-rails.md)`)
                if (!flag("--allow-broad-owner-on-staging")) throw new Refused(`${what}; refusing. Until the cmux_vm-only owner role exists, staging may pass --allow-broad-owner-on-staging (logged and recorded)`)
                const line = `WARNING: the owner role can write outside cmux_vm (${broad.join(", ")}); applying under --allow-broad-owner-on-staging`
                deps.log(line)
                warnings.push(line)
              }
              const plan = await planOf(db.sql, tree, files)
              const problems = planProblems(plan, tree, target)
              if (problems.length) throw new Refused(problems.join("; "))
              if (plan.pending.length === 0) {
                deps.log(`${tree.name}/${target}: up to date (${plan.applied.size} applied); nothing to do`)
                return 0
              }
              const setHash = await setHashOf(tree, plan)
              if (target === "production") {
                // cmux-old shares cmux-prod: production needs the compat receipts of this exact tree (compat.ts).
                const { changeKey, compatProblems } = await import("./compat.ts")
                const compat = compatProblems(dir, changeKey(deps.root, { kind: "migrations", tree }), "production", deps.now().getTime())
                if (compat.length) throw new Refused(compat.join("; "))
                const staging = await open(deps, tree, "staging", value("--staging-url-env"), "read")
                try {
                  const stagingPlan = await planOf(staging.sql, tree, files)
                  const missing = plan.pending.filter((f) => stagingPlan.applied.get(f.name) !== f.checksum).map((f) => f.name)
                  if (missing.length) throw new Refused(`staging does not have ${missing.join(", ")} (with the same checksum); apply to staging first`)
                } finally {
                  await staging.close()
                }
              }
              // Rehearse this exact set in this run (no receipt from elsewhere is trusted).
              const context = rehearsalOf(plan, setHash)
              const outcome = await rehearseOnCopy(context)
              for (const w of outcome.warnings) deps.log(`warning: ${w}`)
              emit(rehearsalReceipt(context, outcome, gitSha(deps)))
              if (outcome.errors.length) throw new Refused(`the rehearsal failed; nothing was applied:\n  ${outcome.errors.join("\n  ")}`)
              const sha = gitSha(deps)
              const result = await applyPending(db.sql, tree, files, { by, allowContract, target })
              const errors = (await schemaProblems(db.sql, await requirementsOf(tree, deps.root))).filter((p) => !p.includes(" privilege")).map((p) => `after apply: ${p}`)
              for (const e of errors) deps.error(e)
              const afterPlan = await planOf(db.sql, tree, files)
              emit({
                action: "apply",
                what: `apply ${result.applied.join(", ")} to ${tree.database}/${tree.branches[target]} from ${deps.root}${sha ? ` (HEAD ${sha.slice(0, 12)})` : ""} after rehearsal on ${outcome.branch}`,
                tree: tree.name,
                target,
                before: [...plan.applied.keys()].sort(),
                after: [...afterPlan.applied.keys()].sort(),
                rollback: rollbackOf(tree, target, plan.pending),
                result: errors.length ? "fail" : "pass",
                at: at(),
                setHash,
                pending: plan.pending.map((f) => ({ name: f.name, checksum: f.checksum })),
                applied: result.applied,
                ...(errors.length ? { errors } : {}),
                ...(warnings.length ? { warnings } : {}),
                ...(sha ? { gitSha: sha } : {}),
                by,
              })
              return errors.length ? 1 : 0
            })
          } finally {
            await db.close()
          }
        })

      case "adopt": {
        const through = value("--through")
        if (!through || !/^\d{4}$/.test(through)) throw new Refused("adopt needs --through NNNN")
        if (tree.name !== "cmux-vm") throw new Refused("only cmux-vm has untracked databases")
        const db = await open(deps, tree, target, urlVar, "admin")
        try {
          await requireOwner(deps.provider, tree, target, db.sql, deps.log)
          const adopted = await adopt(db.sql, tree, files, through, by, deps.root)
          emit({ action: "adopt", what: `record ${adopted.join(", ")} as applied (they were applied by hand)`, tree: tree.name, target, before: [], after: adopted, rollback: [`DELETE FROM ${tree.trackingTable} WHERE adopted (only the tracking rows; no schema change)`], result: "pass", at: at(), applied: adopted, by })
          return 0
        } finally {
          await db.close()
        }
      }

      default:
        deps.error(`unknown command ${JSON.stringify(command)}; see the header of scripts/cmux-next/release/db-release.ts`)
        return 2
    }
  } catch (e) {
    deps.error((e as Error).message)
    return 1
  }
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)))

export { TREES, TREE_NAMES }
