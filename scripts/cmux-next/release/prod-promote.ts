/**
 * Production promotion and staleness for the cmux-next API Worker (cx-w1ald,
 * plans/cmux-next/release-rails.md "Continuous delivery to production").
 *
 *   bun prod-promote.ts config --config backend/apps/api/wrangler.jsonc
 *       Production config gate (deploy-worker.sh runs it before every production deploy): every
 *       secret named in production-approvals.json `required_secrets` is set on cmux-api, and
 *       HOME_INVITES_SEND "on" needs HOME_INVITE_FROM. Names only, never values.
 *   bun prod-promote.ts gates [--github-output FILE]
 *       Picks the staging-proven candidate and runs G1-G7. Exit 0 = promote (writes
 *       candidate=<sha> to FILE); exit 3 = nothing to do or a gate holds (the reason is printed).
 *   bun prod-promote.ts stale [--issue]
 *       Exit 1 when production is stale (no source tag, more than STALE_HOURS behind the oldest
 *       staging-proven commit it lacks, or more than STALE_COMMITS backend commits behind).
 *       --issue opens, updates or closes the GitHub issue labeled `prod-stale`.
 *
 * Environment: CLOUDFLARE_API_TOKEN (read: scripts, versions, deployments, secret names),
 * GITHUB_TOKEN or GH_TOKEN and GITHUB_REPOSITORY (read: Actions runs; issues for --issue),
 * CMUX_NEXT_PRODUCTION_HOLD (G6; non-empty = hold). Runs from the repo root.
 */
import { execFileSync } from "node:child_process"
import { appendFileSync, readFileSync } from "node:fs"
import { stripJsonc } from "./worker-release.ts"

const ACCOUNT = "0c1675e0def6de1ab3a50a4e17dc5656"
const PRODUCTION = "cmux-api"
const STAGING = "cmux-api-staging"
const WRANGLER = "backend/apps/api/wrangler.jsonc"
const APPROVALS = "scripts/cmux-next/release/production-approvals.json"
/** G1: a candidate's staging deploy must be this old, with no red staging deploy after it in that window. */
export const SOAK_MINUTES = 60
/** At most one promotion per this many hours. */
export const SPACING_HOURS = 6
export const STALE_HOURS = 24
export const STALE_COMMITS = 20
/** G7: production vars whose change spends money or sends messages; each new value needs an approval. */
export const GUARDED_VAR = /^(INFERENCE_|AUTOMATION_CAP_|HOME_INVITES_SEND$)/

export interface Approvals {
  /** Secrets production must have before any deploy (names). */
  readonly required_secrets: ReadonlyArray<string>
  /** DO migration tags reviewed for production: tag -> {reviewer, lawrence?} (rename/delete/transfer needs lawrence: true). */
  readonly do_tags: Readonly<Record<string, { readonly reviewer: string; readonly lawrence?: boolean }>>
  /** Guarded var values approved for production: "NAME=value" -> who and when. */
  readonly guarded_vars: Readonly<Record<string, string>>
}

type Migration = { tag: string; new_sqlite_classes?: Array<string>; renamed_classes?: unknown; deleted_classes?: unknown; transferred_classes?: unknown }
type ProdEnv = { vars: Record<string, string>; migrations: Array<Migration> }

export const productionEnv = (jsonc: string): ProdEnv => {
  const doc = JSON.parse(stripJsonc(jsonc)) as { env?: { production?: { vars?: Record<string, string>; migrations?: Array<Migration> } } }
  const p = doc.env?.production
  if (!p) throw new Error("wrangler.jsonc has no env.production")
  return { vars: p.vars ?? {}, migrations: p.migrations ?? [] }
}

/** G3: migration tags the candidate adds over production, and the ones not approved. */
export const doMigrationGate = (prod: ProdEnv, cand: ProdEnv, approvals: Approvals): { added: Array<string>; refused: Array<string> } => {
  const have = new Set(prod.migrations.map((m) => m.tag))
  const added = cand.migrations.filter((m) => !have.has(m.tag))
  const refused: Array<string> = []
  for (const m of added) {
    const a = approvals.do_tags[m.tag]
    const destructive = m.renamed_classes !== undefined || m.deleted_classes !== undefined || m.transferred_classes !== undefined
    if (!a) refused.push(`${m.tag}: no reviewed approval in ${APPROVALS}`)
    else if (destructive && a.lawrence !== true) refused.push(`${m.tag}: renames, deletes or transfers a class and needs lawrence: true`)
  }
  // A tag that production has and the candidate lost or changed is never promoted.
  for (const m of prod.migrations) {
    const c = cand.migrations.find((x) => x.tag === m.tag)
    if (!c || JSON.stringify(c) !== JSON.stringify(m)) refused.push(`${m.tag}: production has it, the candidate changes or drops it`)
  }
  return { added: added.map((m) => m.tag), refused }
}

/** G7: guarded vars the candidate changes, and the new values without an approval. */
export const guardedVarGate = (prod: ProdEnv, cand: ProdEnv, approvals: Approvals): Array<string> => {
  const names = new Set([...Object.keys(prod.vars), ...Object.keys(cand.vars)].filter((n) => GUARDED_VAR.test(n)))
  const refused: Array<string> = []
  for (const n of names) {
    if (prod.vars[n] === cand.vars[n]) continue
    const key = cand.vars[n] === undefined ? `${n}=<unset>` : `${n}=${cand.vars[n]}`
    if (!approvals.guarded_vars[key]) refused.push(`${key}: not in ${APPROVALS} guarded_vars`)
  }
  return refused
}

/** Config gate: missing secret names (G5 and the deploy-worker.sh check). */
export const missingSecrets = (env: ProdEnv, approvals: Approvals, have: ReadonlySet<string>): Array<string> => {
  const need = new Set(approvals.required_secrets)
  if (env.vars.HOME_INVITES_SEND === "on") need.add("HOME_INVITE_FROM")
  return [...need].filter((n) => !have.has(n) && env.vars[n] === undefined).sort()
}

// ---- I/O ----

const cf = async (path: string): Promise<any> => {
  const token = process.env.CLOUDFLARE_API_TOKEN
  if (!token) throw new Error("CLOUDFLARE_API_TOKEN is not set")
  const r = await fetch(`https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}${path}`, { headers: { authorization: `Bearer ${token}` } })
  if (!r.ok) throw new Error(`Cloudflare ${path}: HTTP ${r.status}`)
  return ((await r.json()) as { result: unknown }).result
}

const gh = async (path: string, init: RequestInit = {}): Promise<any> => {
  const token = process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN
  const repo = process.env.GITHUB_REPOSITORY ?? "manaflow-ai/cmux"
  if (!token) throw new Error("GITHUB_TOKEN is not set")
  const r = await fetch(`https://api.github.com/repos/${repo}${path}`, { ...init, headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", ...(init.headers ?? {}) } })
  if (!r.ok) throw new Error(`GitHub ${path}: HTTP ${r.status}`)
  return r.status === 204 ? null : r.json()
}

const git = (...args: Array<string>) => execFileSync("git", args, { encoding: "utf8" }).trim()
const fileAt = (sha: string, path: string) => git("show", `${sha}:${path}`)

/** The serving version of a Worker: its id, the source commit from the version tag (12 hex), and when code last changed. */
export const serving = async (script: string): Promise<{ version: string; sourceTag?: string; codeDeployedAt?: number }> => {
  const deps = ((await cf(`/workers/scripts/${script}/deployments`)) as { deployments: Array<any> }).deployments
  const top = deps[0]
  if (!top || top.versions.length !== 1 || top.versions[0].percentage !== 100) throw new Error(`${script}: no single version at 100%`)
  const version = top.versions[0].version_id as string
  const v = await cf(`/workers/scripts/${script}/versions/${version}`)
  const tag = v?.annotations?.["workers/tag"] as string | undefined
  const code = deps.find((d) => d.annotations?.["workers/triggered_by"] !== "secret")
  return { version, ...(tag && /^[0-9a-f]{12}$/.test(tag) ? { sourceTag: tag } : {}), ...(code ? { codeDeployedAt: Date.parse(code.created_on) } : {}) }
}

interface StagingRun { sha: string; at: number; green: boolean }

/** Staging deploys of feat-cmux-next pushes, newest first: green = deploy-staging and its smoke step passed. */
export const stagingRuns = async (limit = 30): Promise<Array<StagingRun>> => {
  const runs = (await gh(`/actions/workflows/backend.yml/runs?branch=feat-cmux-next&event=push&status=completed&per_page=${limit}`)).workflow_runs as Array<any>
  const out: Array<StagingRun> = []
  for (const run of runs) {
    const jobs = (await gh(`/actions/runs/${run.id}/jobs?per_page=100`)).jobs as Array<any>
    const job = jobs.find((j) => j.name === "deploy-staging")
    if (!job || job.conclusion === "skipped") continue
    const smoke = (job.steps as Array<any>).find((s) => String(s.name).startsWith("Smoke the API Worker"))
    out.push({ sha: run.head_sha, at: Date.parse(job.completed_at), green: job.conclusion === "success" && smoke?.conclusion === "success" })
  }
  return out
}

/** G1: the newest green staging deploy at least SOAK_MINUTES old with no red staging deploy in its soak window. */
export const pickCandidate = (runs: ReadonlyArray<StagingRun>, now: number): StagingRun | undefined =>
  runs.find((r) => r.green && now - r.at >= SOAK_MINUTES * 60_000 && !runs.some((x) => !x.green && x.at > r.at && x.at <= r.at + SOAK_MINUTES * 60_000))

const isAncestor = (a: string, b: string) => {
  try {
    execFileSync("git", ["merge-base", "--is-ancestor", a, b])
    return true
  } catch {
    return false
  }
}

const backendCommits = (from: string, to: string) => Number(git("rev-list", "--count", `${from}..${to}`, "--", "backend/"))

const loadApprovals = (sha?: string): Approvals => JSON.parse(sha ? fileAt(sha, APPROVALS) : readFileSync(APPROVALS, "utf8")) as Approvals

const secretNames = async (script: string) => new Set(((await cf(`/workers/scripts/${script}/secrets`)) as Array<{ name: string }>).map((s) => s.name))

const fullSha = (tag: string) => git("rev-parse", `${tag}^{commit}`)

export const main = async (argv: ReadonlyArray<string>): Promise<number> => {
  const [cmd, ...rest] = argv
  const opt = (name: string) => {
    const i = rest.indexOf(name)
    return i >= 0 ? rest[i + 1] : undefined
  }
  if (cmd === "config") {
    const env = productionEnv(readFileSync(opt("--config") ?? WRANGLER, "utf8"))
    const missing = missingSecrets(env, loadApprovals(), await secretNames(PRODUCTION))
    if (missing.length) {
      console.error(`prod-promote config: refused, ${PRODUCTION} lacks secrets: ${missing.join(", ")}`)
      return 1
    }
    console.log(`prod-promote config: ok, every required secret is set on ${PRODUCTION}`)
    return 0
  }
  if (cmd === "gates") {
    const hold = (n: string, why: string) => (console.log(`prod-promote: HOLD (${n}) ${why}`), 3)
    // G6 first: a hold switch stops everything, even the reads.
    if (process.env.CMUX_NEXT_PRODUCTION_HOLD) return hold("G6", `hold switch is set: ${process.env.CMUX_NEXT_PRODUCTION_HOLD}`)
    const now = Date.now()
    const prod = await serving(PRODUCTION)
    if (!prod.sourceTag) return hold("source", `production version ${prod.version} has no source tag; the first promotion is the hand rail with Lawrence's go`)
    if (prod.codeDeployedAt && now - prod.codeDeployedAt < SPACING_HOURS * 3600_000) return hold("spacing", `production code changed less than ${SPACING_HOURS} h ago`)
    const prodSha = fullSha(prod.sourceTag)
    const cand = pickCandidate(await stagingRuns(), now)
    if (!cand) return hold("G1", `no green staging deploy older than ${SOAK_MINUTES} min without a red one after it`)
    if (cand.sha === prodSha || isAncestor(cand.sha, prodSha)) return hold("none", `production ${prodSha.slice(0, 12)} already has the staging-proven ${cand.sha.slice(0, 12)}`)
    if (!isAncestor(prodSha, cand.sha)) return hold("lineage", `${cand.sha.slice(0, 12)} does not descend from production ${prodSha.slice(0, 12)}`)
    // G2: an open regression issue (P0/P1) blocks; the chief applies the label or the hold.
    const issues = (await gh(`/issues?state=open&labels=cmux-next-regression&per_page=20`)) as Array<{ number: number; labels: Array<{ name: string }> }>
    const blocking = issues.filter((i) => i.labels.some((l) => l.name === "P0" || l.name === "P1"))
    if (blocking.length) return hold("G2", `open P0/P1 regression issues: ${blocking.map((i) => `#${i.number}`).join(", ")}`)
    const approvals = loadApprovals(cand.sha)
    const prodEnv = productionEnv(fileAt(prodSha, WRANGLER))
    const candEnv = productionEnv(fileAt(cand.sha, WRANGLER))
    const g3 = doMigrationGate(prodEnv, candEnv, approvals)
    if (g3.refused.length) return hold("G3", g3.refused.join("; "))
    const missing = missingSecrets(candEnv, approvals, await secretNames(PRODUCTION))
    if (missing.length) return hold("G5", `production lacks secrets: ${missing.join(", ")}`)
    const g7 = guardedVarGate(prodEnv, candEnv, approvals)
    if (g7.length) return hold("G7", g7.join("; "))
    // G4 (Postgres) runs inside deploy-worker.sh (migrate.ts --verify), before the deploy.
    console.log(`prod-promote: PROMOTE ${cand.sha} (staging green at ${new Date(cand.at).toISOString()}; ${backendCommits(prodSha, cand.sha)} backend commits after production ${prodSha.slice(0, 12)}; new DO tags: ${g3.added.join(", ") || "none"})`)
    const out = opt("--github-output")
    if (out) appendFileSync(out, `candidate=${cand.sha}\n`)
    return 0
  }
  if (cmd === "stale") {
    const now = Date.now()
    const prod = await serving(PRODUCTION)
    const runs = await stagingRuns()
    let reason: string | undefined
    if (!prod.sourceTag) reason = `production version ${prod.version} has no source tag (unknown code)`
    else {
      const prodSha = fullSha(prod.sourceTag)
      const missing = runs.filter((r) => r.green && !isAncestor(r.sha, prodSha))
      const oldest = missing.at(-1)
      const newest = missing[0]
      const behind = newest ? backendCommits(prodSha, newest.sha) : 0
      if (oldest && now - oldest.at > STALE_HOURS * 3600_000) reason = `production ${prodSha.slice(0, 12)} lacks a commit staging proved ${Math.round((now - oldest.at) / 3600_000)} h ago`
      else if (behind > STALE_COMMITS) reason = `production ${prodSha.slice(0, 12)} is ${behind} backend commits behind staging-proven ${newest!.sha.slice(0, 12)}`
    }
    console.log(reason ? `prod-promote: STALE ${reason}` : "prod-promote: production is current")
    if (rest.includes("--issue")) {
      const open = ((await gh(`/issues?state=open&labels=prod-stale&per_page=5`)) as Array<{ number: number }>)[0]
      const body = `${reason ?? "current"}\n\nChecked ${new Date(now).toISOString()} by backend.yml prod-stale (scripts/cmux-next/release/prod-promote.ts). Fix: promote the staging-proven commit (backend.yml promote-production) or clear the hold.`
      if (reason && open) await gh(`/issues/${open.number}/comments`, { method: "POST", body: JSON.stringify({ body }) })
      else if (reason) await gh(`/issues`, { method: "POST", body: JSON.stringify({ title: "cmux-api production is stale", body, labels: ["prod-stale"] }) })
      else if (open) await gh(`/issues/${open.number}`, { method: "PATCH", body: JSON.stringify({ state: "closed", state_reason: "completed" }) })
    }
    return reason ? 1 : 0
  }
  console.error("usage: prod-promote.ts config|gates|stale (see the header)")
  return 2
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)))
