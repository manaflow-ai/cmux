/**
 * A backend.yml job that checks out only some folders (a cone-mode `sparse-checkout`) and runs
 * `bun install --frozen-lockfile` in a folder must also check out every workspace that folder's
 * package.json lists, or bun stops with "listed in bun.lock but not on disk".
 *
 * Run 44764045780: journey-production's "Roll back the promote that turned the journey red" ran
 * `cd backend && bun install`; the job checked out backend but not ../workers/cmux-vm/sdk or
 * ../clients/ts, so the rollback failed and the promote it was meant to undo stayed live.
 */
import { describe, expect, it } from "bun:test"
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs"
import { join, normalize, relative } from "node:path"

const root = normalize(join(import.meta.dir, "../../../.."))
const workflow = Bun.YAML.parse(readFileSync(join(root, ".github/workflows/backend.yml"), "utf8")) as any

/** The repo-relative folders `dir`'s package.json names as workspaces, with `*` expanded. */
function workspaceDirs(dir: string): string[] {
  const pkg = JSON.parse(readFileSync(join(root, dir, "package.json"), "utf8")) as { workspaces?: string[] | { packages?: string[] } }
  const globs = Array.isArray(pkg.workspaces) ? pkg.workspaces : pkg.workspaces?.packages ?? []
  return globs.flatMap((glob) => {
    if (!glob.endsWith("/*")) return [relative(root, join(root, dir, glob))]
    const parent = join(root, dir, glob.slice(0, -2))
    if (!existsSync(parent)) return []
    return readdirSync(parent)
      .filter((name) => existsSync(join(parent, name, "package.json")) && statSync(join(parent, name)).isDirectory())
      .map((name) => relative(root, join(parent, name)))
  })
}

/** The folders `bun install` runs in, for each step of a job (a `cd X && bun install`, or the step's or job's working-directory). */
function installDirs(job: any, step: any): string[] {
  const run = typeof step.run === "string" ? step.run : ""
  if (!run.includes("bun install")) return []
  const dirs = [...run.matchAll(/cd\s+([\w./-]+)\s*&&\s*bun install/g)].map((m) => m[1]!)
  if (dirs.length) return dirs
  const cwd = step["working-directory"] ?? job.defaults?.run?.["working-directory"] ?? "."
  return [cwd === "${{ github.workspace }}" ? "." : cwd]
}

const covered = (paths: string[], dir: string) => paths.some((p) => dir === p || dir.startsWith(`${p}/`))

describe("backend.yml sparse checkouts", () => {
  const jobs = Object.entries(workflow.jobs as Record<string, any>)
  const sparse = jobs.flatMap(([name, job]) => {
    const checkout = (job.steps ?? []).find((s: any) => String(s.uses ?? "").startsWith("actions/checkout@"))
    const w = checkout?.with ?? {}
    if (typeof w["sparse-checkout"] !== "string" || w["sparse-checkout-cone-mode"] === false) return []
    const paths = w["sparse-checkout"].split("\n").map((l: string) => l.trim()).filter(Boolean)
    return [{ name, job, paths }]
  })

  it("finds the cone-mode jobs (journey-production among them)", () => {
    expect(sparse.map((s) => s.name)).toContain("journey-production")
  })

  for (const { name, job, paths } of sparse) {
    it(`${name}: every folder it runs bun install in, and its workspaces, are checked out`, () => {
      const missing: string[] = []
      for (const step of job.steps ?? []) {
        for (const dir of installDirs(job, step)) {
          if (!covered(paths, dir)) missing.push(`${step.name ?? "a step"}: ${dir}`)
          for (const ws of workspaceDirs(dir)) if (!covered(paths, ws)) missing.push(`${step.name ?? "a step"}: ${dir} needs ${ws}`)
        }
      }
      expect(missing).toEqual([])
    })
  }
})

/**
 * The after-promote real-model journey proves a promote only when its Claude login has quota. The repository's
 * CLAUDE_CODE_OAUTH_TOKEN is one login that claude.yml, cloud-chat-proof and every journey share, and run 44764045780's
 * reply hit its weekly limit. journey-production takes its own login first (CMUX_JOURNEY_CLAUDE_CODE_OAUTH_TOKEN,
 * a secret of the cmux-next-cloud-journey environment) and falls back to the shared one while that is not set.
 */
describe("journey-production's Claude login", () => {
  it("prefers the journey's own login, then the shared one", () => {
    const steps = workflow.jobs["journey-production"].steps as any[]
    const real = steps.find((s) => s.name === "Cloud journey (prod)")
    expect(real.env.CLAUDE_CODE_OAUTH_TOKEN).toBe("${{ secrets.CMUX_JOURNEY_CLAUDE_CODE_OAUTH_TOKEN || secrets.CLAUDE_CODE_OAUTH_TOKEN }}")
  })
})

/**
 * The six-hourly real-model journey (cloud-journey-prod.yml, also in the cmux-next-cloud-journey environment) feeds
 * the cloud-journey-first-text-production probe; on the shared login its runs became quota skips (run 44649399953),
 * so it takes the same journey login first. The stub leg still gets no Claude login.
 */
describe("cloud-journey-prod's Claude login", () => {
  it("prefers the journey's own login on the real leg only", () => {
    const prod = Bun.YAML.parse(readFileSync(join(root, ".github/workflows/cloud-journey-prod.yml"), "utf8")) as any
    const step = (prod.jobs.journey.steps as any[]).find((s) => s.id === "journey")
    expect(step.env.CLAUDE_CODE_OAUTH_TOKEN).toBe(
      "${{ matrix.model == 'real' && (secrets.CMUX_JOURNEY_CLAUDE_CODE_OAUTH_TOKEN || secrets.CLAUDE_CODE_OAUTH_TOKEN) || '' }}",
    )
  })
})
