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
 * apply: refuses unless a passing rehearsal of the same set (applied rows +
 * pending files, by hash) against that target is younger than 24 h; for
 * production also unless staging already has every pending file with the same
 * checksum (read from staging). One run at a time (advisory lock + local lock).
 * Idempotent: nothing pending is a no-op pass.
 */
import { execFileSync } from "node:child_process"
import { pscaleProvider, rehearsalBranchName, REHEARSAL_BRANCH, type BranchProvider } from "./branches.ts"
import { join } from "node:path"
import { CONTRACT_PATH, lintTree, LOCK_PATH, readJson, readMigrations, rollbackSection, type Lock, type MigrationFile, type RoleContract } from "./lint.ts"
import { actor, findRehearsal, receiptsDir, readReceipts, runIdOf, strandedBranches, summaryLine, withLocalLock, writeReceipt, type Receipt } from "./receipts.ts"
import { adopt, applyPending, connectUrl, gate, planOf, planProblems, requirementsOf, schemaProblems, setHashOf, smokeProblems, type Plan, type Sql } from "./runner.ts"
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

class Refused extends Error {}

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
  const sql = await deps.connect(conn.url)
  return {
    sql,
    close: async () => {
      await sql.end()
      await conn.release()
    },
  }
}

const describe = (plan: Plan) =>
  `tracking=${plan.tracking} applied=${plan.applied.size} pending=${plan.pending.map((f) => f.name).join(",") || "none"}${plan.unknown.length ? ` unknown=${plan.unknown.join(",")}` : ""}${plan.mismatched.length ? ` mismatched=${plan.mismatched.join(",")}` : ""}`

/** The plan an untracked target would have after `adopt --through`: those files applied, the rest pending. */
const asAdopted = (plan: Plan, files: ReadonlyArray<MigrationFile>, through: string | undefined): Plan => {
  if (plan.tracking !== "untracked" || !through) return plan
  const applied = new Map(files.filter((f) => f.name.slice(0, 4) <= through).map((f) => [f.name, f.checksum]))
  return { tracking: "tracked", applied, pending: files.filter((f) => !applied.has(f.name)), unknown: [], mismatched: [] }
}

/**
 * apply and adopt write as the target's owner role (objects and the tracking table keep that
 * owner). Refuses another role; skipped with a warning when pscale cannot name the owner (CI).
 */
const requireOwner = async (deps: Deps, tree: Tree, target: Target, sql: Sql) => {
  const current = (await sql.query<{ u: string }>("SELECT current_user AS u"))[0]?.u
  let owner: string | undefined
  try {
    owner = await deps.provider.roleUser(tree.database, tree.branches[target], tree.ownerRole)
  } catch (e) {
    deps.log(`warning: could not look up ${tree.ownerRole} on ${tree.database}/${tree.branches[target]} (${(e as Error).message.slice(0, 120)}); not checking the owner`)
    return
  }
  deps.log(`connected as ${current}${owner ? ` (owner ${tree.ownerRole} is ${owner})` : ""}`)
  if (owner && current !== owner) throw new Refused(`--url-env connects as ${current}, not the owner ${tree.ownerRole} (${owner}); objects and ${tree.trackingTable} must belong to the owner`)
}

/** rehearse and apply refuse a tree the linter refuses (rules, numbering, lock). */
const lintOrRefuse = async (deps: Deps, tree: Tree) => {
  const report = await lintTree(tree, { root: deps.root, lock: readJson<Lock>(join(deps.root, LOCK_PATH)), contract: readJson<RoleContract>(join(deps.root, CONTRACT_PATH)) })
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
    }

    const tree = treeOf(value("--tree"))
    const target = targetOf(value("--target"))
    if (value("--root")) {
      // A candidate checkout (for example a lane branch's worktree): the lint, the lock and the files come from there.
      // gate must judge the deploying commit; adopt has no files to choose. apply may use a candidate
      // root: the lint, the lock, the rehearsed set hash and the owner check still hold, and the database
      // records each file's checksum, so a landed file that differs is refused by the lint and the gate.
      if (command === "adopt" || command === "gate") throw new Refused("--root is for plan, rehearse and apply only")
      deps = { ...deps, root: value("--root")! }
    }
    const files = readMigrations(deps.root, tree)
    const urlVar = value("--url-env")
    const allowContract = values(rest, "--allow-contract")
    if ((command === "apply" || command === "adopt") && target === "production" && !flag("--confirm-production")) throw new Refused(`${command} to production needs --confirm-production`)

    switch (command) {
      case "plan": {
        const db = await open(deps, tree, target, urlVar, "read")
        try {
          const plan = await planOf(db.sql, tree, files)
          deps.log(`${tree.name}/${target}: ${describe(plan)} set=${(await setHashOf(tree, plan)).slice(0, 12)}`)
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
          const result = await gate(db.sql, tree, files, target)
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
          const problems = planProblems(asAdopted(targetPlan, files, adoptThrough), tree, target)
          if (problems.length) throw new Refused(problems.join("; "))
          const wanted = asAdopted(targetPlan, files, adoptThrough)
          const setHash = await setHashOf(tree, wanted)
          deps.log(`${tree.name}/${target}: ${describe(wanted)} set=${setHash.slice(0, 12)}`)
          const name = rehearsalBranchName(tree.name, target, deps.now())
          const errors: Array<string> = []
          const warnings: Array<string> = []
          let deleted = false
          // Recorded before the create, so `cleanup` finds the branch even if this run dies mid-create.
          emit({ action: "branch-created", tree: tree.name, target, result: "pass", at: at(), branch: name, by })
          try {
            await deps.provider.create(tree.database, name, tree.branches[target])
            // Act as the target's owner role (the copy has the same roles), so the rehearsal meets the
            // same ownership and privileges as the real apply; an admin role alone cannot read cmux_vm.
            const owner = await deps.provider.roleUser(tree.database, tree.branches[target], tree.ownerRole)
            deps.log(`copy ${name} lists roles: ${(await deps.provider.roleNames(tree.database, name)).join(", ") || "none"}`)
            const asOwner = await deps.provider.connectRole(tree.database, name, tree.ownerRole)
            const conn = asOwner ?? (await deps.provider.connectDefault(tree.database, name))
            const sql = await deps.connect(conn.url)
            try {
              if (owner && !asOwner) {
                const role = `"${owner.replace(/"/g, '""')}"`
                try {
                  await sql.query(`SET ROLE ${role}`)
                } catch {
                  try {
                    // The copy's admin role may grant itself the owner (the copy is deleted afterwards).
                    await sql.query(`GRANT ${role} TO CURRENT_USER`)
                    await sql.query(`SET ROLE ${role}`)
                  } catch (e) {
                    warnings.push(`could not act as ${tree.ownerRole} (${owner}) on the copy (${(e as Error).message}); rehearsed as an admin role, so ownership errors may differ`)
                  }
                }
              }
              deps.log(`rehearsal acts as: ${(await sql.query<{ u: string }>("SELECT current_user AS u"))[0]?.u}`)
              let copyPlan = await planOf(sql, tree, files)
              if (copyPlan.tracking === "untracked" && adoptThrough) {
                await adopt(sql, tree, files, adoptThrough, by)
                copyPlan = await planOf(sql, tree, files)
              }
              if ((await setHashOf(tree, copyPlan)) !== setHash) {
                errors.push(`the branch copy (${describe(copyPlan)}) differs from ${target}; its backup may predate a recent apply: retry later`)
              } else {
                const result = await applyPending(sql, tree, files, { by, allowContract, target })
                deps.log(`rehearsal applied: ${result.applied.join(", ") || "nothing pending"}`)
                const after = await planOf(sql, tree, files)
                if (after.pending.length) errors.push(`still pending after apply: ${after.pending.map((f) => f.name).join(", ")}`)
                const requirements = requirementsOf(tree)
                for (const p of await schemaProblems(sql, requirements)) if (!p.includes(" privilege")) errors.push(`schema check: ${p}`)
                const worker = await deps.provider.roleUser(tree.database, tree.branches[target], tree.workerRole)
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
              if (await deps.provider.exists(tree.database, name)) await deps.provider.delete(tree.database, name)
              deleted = !(await deps.provider.exists(tree.database, name))
              if (!deleted) errors.push(`branch ${name} still exists after delete`)
            } catch (e) {
              errors.push(`could not delete ${name}: ${(e as Error).message}; run db-release.ts cleanup`)
            }
            if (deleted) emit({ action: "branch-deleted", tree: tree.name, target, result: "pass", at: at(), branch: name, by })
          }
          for (const w of warnings) deps.log(`warning: ${w}`)
          for (const e of errors) deps.error(`rehearsal: ${e}`)
          const sha = gitSha(deps)
          emit({
            action: "rehearse",
            what: `rehearse ${wanted.pending.map((f) => f.name).join(", ") || "nothing pending"} on throwaway branch ${tree.database}/${name} copied from ${tree.branches[target]}`,
            tree: tree.name,
            target,
            before: [...wanted.applied.keys()].sort(),
            after: [...wanted.applied.keys(), ...wanted.pending.map((f) => f.name)].sort(),
            rollback: [`nothing to undo: branch ${name} was ${deleted ? "deleted" : "NOT deleted (run db-release.ts cleanup)"}`],
            result: errors.length ? "fail" : "pass",
            at: at(),
            setHash,
            pending: wanted.pending.map((f) => ({ name: f.name, checksum: f.checksum })),
            branch: name,
            branchDeleted: deleted,
            ...(errors.length ? { errors } : {}),
            ...(warnings.length ? { warnings } : {}),
            ...(sha ? { gitSha: sha } : {}),
            by,
          })
          return errors.length ? 1 : 0
        })

      case "apply":
        return await withLocalLock(dir, `apply-${tree.name}-${target}`, async () => {
          await lintOrRefuse(deps, tree)
          if (!urlVar) throw new Refused("apply needs --url-env with the owner's credentials for the target")
          const db = await open(deps, tree, target, urlVar, "admin")
          try {
            await requireOwner(deps, tree, target, db.sql)
            const plan = await planOf(db.sql, tree, files)
            const problems = planProblems(plan, tree, target)
            if (problems.length) throw new Refused(problems.join("; "))
            if (plan.pending.length === 0) {
              deps.log(`${tree.name}/${target}: up to date (${plan.applied.size} applied); nothing to do`)
              return 0
            }
            const setHash = await setHashOf(tree, plan)
            const rehearsal = findRehearsal(dir, tree.name, target, setHash, deps.now().getTime())
            if (!rehearsal)
              throw new Refused(`no passing rehearsal of set ${setHash.slice(0, 12)} (pending ${plan.pending.map((f) => f.name).join(", ")}) against ${target} in the last 24 h; run: bun scripts/cmux-next/release/db-release.ts rehearse --tree ${tree.name} --target ${target}`)
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
            const sha = gitSha(deps)
            const result = await applyPending(db.sql, tree, files, { by, allowContract, target })
            const errors = (await schemaProblems(db.sql, requirementsOf(tree))).filter((p) => !p.includes(" privilege")).map((p) => `after apply: ${p}`)
            for (const e of errors) deps.error(e)
            const afterPlan = await planOf(db.sql, tree, files)
            emit({
              action: "apply",
              what: `apply ${result.applied.join(", ")} to ${tree.database}/${tree.branches[target]} from ${deps.root}${sha ? ` (HEAD ${sha.slice(0, 12)})` : ""} (rehearsal ${rehearsal.file})`,
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
              ...(sha ? { gitSha: sha } : {}),
              by,
            })
            deps.log(`rehearsal used: ${rehearsal.file}`)
            return errors.length ? 1 : 0
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
          await requireOwner(deps, tree, target, db.sql)
          const adopted = await adopt(db.sql, tree, files, through, by)
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
