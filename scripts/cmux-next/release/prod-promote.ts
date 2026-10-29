/**
 * Production promotion and staleness for the cmux-next API Worker (cx-w1ald,
 * plans/cmux-next/release-rails.md "Continuous delivery to production").
 *
 *   bun prod-promote.ts config --config backend/apps/api/wrangler.jsonc
 *       Production config gate (deploy-worker.sh runs it before every production deploy): every
 *       secret named in production-approvals.json `required_secrets` is set on cmux-api, and
 *       HOME_INVITES_SEND "on" needs HOME_INVITE_FROM. Names only, never values.
 *   bun prod-promote.ts gates [--candidate SHA] [--github-output FILE]
 *       Picks the staging-proven candidate and runs G1-G7. Exit 0 = promote (writes
 *       candidate=<sha> to FILE); exit 3 = nothing to do or a gate holds (the reason is printed).
 *       --candidate (40 hex; the exact-SHA promote): G1 must prove exactly that commit (its own
 *       green staging deploy, soaked, no red one in its soak window) instead of the newest one.
 *   bun prod-promote.ts recheck --candidate SHA
 *       Right before the deploy: hold released, spacing, and production's commit a strict ancestor
 *       of SHA (a re-run never downgrades). Exit 0 = deploy; 3 = hold.
 *   bun prod-promote.ts serving
 *       Prints the full source commit of the code production serves (from its version tag).
 *   bun prod-promote.ts rollback [--execute] [--force] [--wrangler BIN]
 *       The one-command rollback: production back to the version served before its current code
 *       deployment (`wrangler rollback`). Refuses (exit 3) across a Durable Object lifecycle change
 *       (env.production.migrations differ between the two source commits): Cloudflare cannot roll
 *       back across one, so that is fix forward, and for the Chief brain the off switch
 *       (backend.yml target=chief-off). Without --execute it prints the command and changes nothing.
 *       Refuses when production already serves a rollback (a re-run would redeploy what the first
 *       one removed) unless --force. From the Chief off switch it steps back past every off-switch
 *       deployment (re-runs stack), so the brain comes back on; it refuses unless that lands on the
 *       same source commit. `wrangler rollback` restores the target version's secrets too, so a
 *       secret set after the target is undone. After a rollback or the off switch,
 *       `gates` holds every automatic promote; only an exact-SHA promote (--candidate) moves
 *       production forward.
 *   bun prod-promote.ts stale [--issue]
 *       Exit 1 = stale (no source tag, a staging-proven commit older than STALE_HOURS missing, or
 *       more than STALE_COMMITS backend commits behind); 0 = current, proven by at least one green
 *       staging run that production has; 4 = unknown (no green evidence). Errors exit 2.
 *       --issue opens the `prod-stale` issue, comments once per state change, and closes it only
 *       on "current".
 *
 * Environment: CLOUDFLARE_API_TOKEN (read: scripts, versions, deployments, secret names),
 * GITHUB_TOKEN or GH_TOKEN and GITHUB_REPOSITORY (read: Actions runs; issues for --issue),
 * CMUX_NEXT_PRODUCTION_HOLD (G6: "released" releases every candidate, "released:<40 hex>" only that
 * commit, the one-shot release of an exact-SHA promote; anything else holds). Runs from the repo root, except
 * `config`, which reads the approvals next to this file.
 */
import { execFileSync } from "node:child_process"
import { appendFileSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { stripJsonc } from "./worker-release.ts"

const ACCOUNT = "0c1675e0def6de1ab3a50a4e17dc5656"
const PRODUCTION = "cmux-api"
const STAGING = "cmux-api-staging"
const WRANGLER = "backend/apps/api/wrangler.jsonc"
/** Repo-relative (for `git show <sha>:`) and on disk next to this script (deploy-worker.sh runs from backend/apps/api). */
const APPROVALS = "scripts/cmux-next/release/production-approvals.json"
const APPROVALS_ON_DISK = join(import.meta.dir, "production-approvals.json")
/** G6: the hold releases only on exactly this value; empty, missing or anything else holds (lead, 2026-10-13). */
export const HOLD_RELEASED = "released"
/** G6 for one commit: "released" releases every commit, "released:<sha>" only that one (one-shot exact-SHA release). */
export const holdReleases = (hold: string | undefined, sha: string | undefined): boolean =>
  hold === HOLD_RELEASED || (sha !== undefined && /^[0-9a-f]{40}$/.test(sha) && hold === `${HOLD_RELEASED}:${sha}`)
/** The commit a one-shot hold value releases, or undefined. */
export const holdPinned = (hold: string | undefined): string | undefined => /^released:([0-9a-f]{40})$/.exec(hold ?? "")?.[1]
/** A hold value as safe log text: no workflow commands, no newlines. */
export const holdText = (v: string | undefined) => (v ?? "<unset>").replace(/[^A-Za-z0-9 ._()'-]/g, "?").slice(0, 120)
/** G1: a candidate's staging deploy must be this old, with no red staging deploy after it in that window. */
export const SOAK_MINUTES = 60
/** At most one promotion per this many hours. */
export const SPACING_HOURS = 6
export const STALE_HOURS = 24
export const STALE_COMMITS = 20
/** G7: production vars whose change spends money, sends messages or opens a service-binding surface; each new value needs an approval. */
export const GUARDED_VAR = /^(INFERENCE_|AUTOMATION_CAP_|HOME_INVITES_SEND$|HOME_INVITES_TEXT$|CHIEF_BRAIN_|CHIEF_CREDITS_|CHIEF_RUN_TOKEN_CAP_USD$|CLOUD_PLAN_ENTITLEMENTS$|PLATFORM_MACHINES$)/

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
  // Paid Cloud entitlements sell machines: the provider key of the configured transport must exist (cloud-driver.ts cloudConfig).
  // Same transport split as cloudConfig: unset or "direct" is Freestyle, "vm-api" is the VM API, anything else has no provider.
  if (env.vars.CLOUD_PLAN_ENTITLEMENTS === "on") {
    const t = env.vars.CLOUD_VM_TRANSPORT
    need.add(t === undefined || t === "direct" ? "CLOUD_FREESTYLE_API_KEY" : t === "vm-api" ? "CLOUD_VM_API_SERVICE_KEY" : `CLOUD_VM_TRANSPORT=${t} (no Cloud provider)`)
  }
  return [...need].map((n) => (env.vars[n] !== undefined ? `${n} (a plain var shadows the secret)` : !have.has(n) ? n : "")).filter(Boolean).sort()
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
  // The body and the rate-limit headers say why (a 403 is a rate limit or a permission; the status alone hid which).
  if (!r.ok) throw new Error(`GitHub ${path}: HTTP ${r.status} ${(await r.text().catch(() => "")).slice(0, 300)} [remaining ${r.headers.get("x-ratelimit-remaining")}, reset ${r.headers.get("x-ratelimit-reset")}, retry-after ${r.headers.get("retry-after")}]`)
  return r.status === 204 ? null : r.json()
}

const git = (...args: Array<string>) => execFileSync("git", args, { encoding: "utf8" }).trim()
const fileAt = (sha: string, path: string) => git("show", `${sha}:${path}`)

/** The Chief off switch's version message (deploy-worker.sh CMUX_DEPLOY_CHIEF_OFF: "source <sha> chief-off run <id>"). */
const CHIEF_OFF = / chief-off( |$)/

/**
 * The serving version of a Worker, its source commit (version tag, 12 hex) and when its code last
 * changed. A secret-only deployment (`wrangler secret put`) makes a new version of the same code
 * without the tag, so the tag comes from the newest code deployment.
 */
export const serving = async (script: string): Promise<{ version: string; sourceTag?: string; codeDeployedAt?: number; heldBack?: string }> => {
  const deps = [...((await cf(`/workers/scripts/${script}/deployments`)) as { deployments: Array<any> }).deployments].sort((a, b) => Date.parse(b.created_on) - Date.parse(a.created_on))
  const top = deps[0]
  if (!top || top.versions.length !== 1 || top.versions[0].percentage !== 100) throw new Error(`${script}: no single version at 100%`)
  const version = top.versions[0].version_id as string
  const code = deps.find((d) => d.annotations?.["workers/triggered_by"] !== "secret")
  const codeVersion = code && code.versions.length === 1 ? (code.versions[0].version_id as string) : undefined
  const v = codeVersion ? await cf(`/workers/scripts/${script}/versions/${codeVersion}`) : undefined
  const tag = v?.annotations?.["workers/tag"] as string | undefined
  // An operator stepped production back (a rollback, or the Chief off switch): no automatic promote undoes it.
  const message = String(v?.annotations?.["workers/message"] ?? "")
  const heldBack = code?.annotations?.["workers/triggered_by"] === "rollback" ? "production serves a rollback" : CHIEF_OFF.test(message) ? "production serves the Chief off switch" : undefined
  return { version, ...(tag && /^[0-9a-f]{12}$/.test(tag) ? { sourceTag: tag } : {}), ...(code ? { codeDeployedAt: Date.parse(code.created_on) } : {}), ...(heldBack ? { heldBack } : {}) }
}

/**
 * The rollback target: the version that served before production's current code deployment (a later
 * secret-only deployment of the same code does not count as new code), with both source commits.
 */
export const rollbackPlan = async (script: string, force = false): Promise<{ fromVersion: string; fromSha?: string; toVersion: string; toSha?: string } | { refused: string }> => {
  const deps = [...((await cf(`/workers/scripts/${script}/deployments`)) as { deployments: Array<any> }).deployments].sort((a, b) => Date.parse(b.created_on) - Date.parse(a.created_on))
  const single = (d: any): string | undefined => (d && d.versions.length === 1 && d.versions[0].percentage === 100 ? (d.versions[0].version_id as string) : undefined)
  const fromVersion = single(deps[0])
  if (!fromVersion) return { refused: `${script}: no single version at 100%` }
  const codeAt = deps.findIndex((d) => d.annotations?.["workers/triggered_by"] !== "secret")
  // A second rollback would step onto the version the first one left (a re-run must not redeploy the bad code).
  if (!force && deps[codeAt]?.annotations?.["workers/triggered_by"] === "rollback") return { refused: `${script} already serves a rollback; roll forward with an exact-SHA promote, or pass --force to roll back onto the deployment that rollback replaced` }
  if (codeAt < 0 || codeAt + 1 >= deps.length) return { refused: `${script}: no deployment before the current code` }
  const versionOf = (version: string) => cf(`/workers/scripts/${script}/versions/${version}`)
  const chiefOff = async (d: any): Promise<boolean> => {
    const v = single(d)
    return v !== undefined && CHIEF_OFF.test(String((await versionOf(v))?.annotations?.["workers/message"] ?? ""))
  }
  const codeFrom = (i: number) => deps.findIndex((d, j) => j >= i && d.annotations?.["workers/triggered_by"] !== "secret")
  let target = codeAt + 1
  // From the off switch, step back past every off-switch deployment (a re-run of target=chief-off stacks
  // another one), so the brain comes back on: the contract of target=rollback after target=chief-off.
  const fromOff = await chiefOff(deps[codeAt])
  if (fromOff) {
    for (let c = codeFrom(target); c >= 0 && (await chiefOff(deps[c])); c = codeFrom(target)) target = c + 1
    if (target >= deps.length) return { refused: `${script}: no deployment before the current code` }
  }
  const toVersion = single(deps[target])
  if (!toVersion) return { refused: `${script}: the deployment before the current code is not a single version at 100%` }
  const tagOf = async (version: string | undefined): Promise<string | undefined> => {
    if (!version) return undefined
    const tag = (await versionOf(version))?.annotations?.["workers/tag"] as string | undefined
    return tag && /^[0-9a-f]{12}$/.test(tag) ? fullSha(tag) : undefined
  }
  // The target's code is the newest code deployment at or before it (it may be a secret-only deployment).
  const toCode = deps[codeFrom(target)]
  const fromSha = await tagOf(single(deps[codeAt]))
  const toSha = await tagOf(single(toCode))
  // The off switch redeploys the serving commit, so undoing it is the same code with the brain on. Anything
  // else (the walk crossed a rollback onto code that was rolled back) is refused.
  if (fromOff && (!fromSha || toSha !== fromSha))
    return { refused: `${script}: the version before the off switch (${toVersion}, ${toSha?.slice(0, 12) ?? "untagged"}) is not the code the off switch serves (${fromSha?.slice(0, 12) ?? "untagged"}); do not roll back onto it. Turn the brain on with an exact-SHA promote of a newer staging-proven commit (target=promote, candidate=<sha>), or by hand: wrangler rollback <a version of ${fromSha?.slice(0, 12) ?? "the serving commit"} with the brain on> --name ${script}` }
  return { fromVersion, toVersion, ...(fromSha ? { fromSha } : {}), ...(toSha ? { toSha } : {}) }
}

export interface StagingRun { sha: string; at: number; green: boolean }

/** Staging deploys of feat-cmux-next pushes, newest first: green = deploy-staging and its smoke step passed. */
export const stagingRuns = async (limit = 30): Promise<Array<StagingRun>> => {
  const runs = (await gh(`/actions/workflows/backend.yml/runs?branch=feat-cmux-next&event=push&status=completed&per_page=${limit}`)).workflow_runs as Array<any>
  const out: Array<StagingRun> = []
  for (const run of runs) {
    const jobs = (await gh(`/actions/runs/${run.id}/jobs?per_page=100`)).jobs as Array<any>
    const job = jobs.find((j) => j.name === "deploy-staging")
    if (!job || job.conclusion === "skipped") continue
    const smoke = (job.steps as Array<any>).find((s) => String(s.name).startsWith("Smoke the API Worker"))
    // G1 proves the tests too: the run's test and migrations-push-guard jobs passed.
    const passed = (name: string) => jobs.some((j) => j.name === name && j.conclusion === "success")
    out.push({ sha: run.head_sha, at: Date.parse(job.completed_at), green: job.conclusion === "success" && smoke?.conclusion === "success" && passed("test") && passed("migrations-push-guard") })
  }
  return out
}

/** G1: the newest green staging deploy at least SOAK_MINUTES old with no red staging deploy in its soak window. */
export const pickCandidate = (runs: ReadonlyArray<StagingRun>, now: number): StagingRun | undefined =>
  runs.find((r) => r.green && now - r.at >= SOAK_MINUTES * 60_000 && !runs.some((x) => !x.green && x.at > r.at && x.at <= r.at + SOAK_MINUTES * 60_000))

/** Exact SHA (--candidate or a one-shot hold): only that commit's green runs compete; every red run still counts against its soak window. */
export const candidateRuns = (runs: ReadonlyArray<StagingRun>, want: string | undefined): ReadonlyArray<StagingRun> => (want ? runs.filter((r) => !r.green || r.sha === want) : runs)

const isAncestor = (a: string, b: string) => {
  try {
    execFileSync("git", ["merge-base", "--is-ancestor", a, b])
    return true
  } catch {
    return false
  }
}

const backendCommits = (from: string, to: string) => Number(git("rev-list", "--count", `${from}..${to}`, "--", "backend/"))

const loadApprovals = (sha?: string): Approvals => JSON.parse(sha ? fileAt(sha, APPROVALS) : readFileSync(APPROVALS_ON_DISK, "utf8")) as Approvals

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
    const holdValue = process.env.CMUX_NEXT_PRODUCTION_HOLD
    const asked = opt("--candidate") || undefined
    if (asked !== undefined && !/^[0-9a-f]{40}$/.test(asked)) {
      console.error("prod-promote: --candidate must be exactly 40 lowercase hex")
      return 2
    }
    const pinned = holdPinned(holdValue)
    // G6 first: a hold switch stops everything, even the reads. A one-shot release names its one commit.
    if (holdValue !== HOLD_RELEASED && !pinned) return hold("G6", `hold switch: ${holdText(holdValue)}`)
    if (pinned && asked !== undefined && asked !== pinned) return hold("G6", `the hold releases only ${pinned.slice(0, 12)}, not ${asked.slice(0, 12)}`)
    const want = asked ?? pinned
    const now = Date.now()
    const prod = await serving(PRODUCTION)
    if (!prod.sourceTag) return hold("source", `production version ${prod.version} has no source tag; the first promotion is the hand rail with Lawrence's go`)
    // After a rollback or the off switch only an operator's exact-SHA promote (--candidate) moves production forward.
    if (prod.heldBack && asked === undefined) return hold("rolled-back", `${prod.heldBack}; promote an exact fixed commit with --candidate (target=promote, candidate=<sha>)`)
    if (prod.codeDeployedAt && now - prod.codeDeployedAt < SPACING_HOURS * 3600_000) return hold("spacing", `production code changed less than ${SPACING_HOURS} h ago`)
    const prodSha = fullSha(prod.sourceTag)
    const runs = await stagingRuns()
    const cand = pickCandidate(candidateRuns(runs, want), now)
    if (!cand) return hold("G1", want ? `${want.slice(0, 12)} has no green staging deploy (tests, push guard, deploy and smoke) older than ${SOAK_MINUTES} min without a red one after it, among the last ${runs.length} staging runs` : `no green staging deploy older than ${SOAK_MINUTES} min without a red one after it`)
    if (cand.sha === prodSha || isAncestor(cand.sha, prodSha)) return hold("none", `production ${prodSha.slice(0, 12)} already has the staging-proven ${cand.sha.slice(0, 12)}`)
    if (!isAncestor(prodSha, cand.sha)) return hold("lineage", `${cand.sha.slice(0, 12)} does not descend from production ${prodSha.slice(0, 12)}`)
    // G2: an open regression issue (P0/P1) blocks; the chief applies the label or the hold.
    const blocking: Array<{ number: number }> = []
    for (const p of ["P0", "P1"]) {
      const found = (await gh(`/issues?state=open&labels=cmux-next-regression,${p}&per_page=50`)) as Array<{ number: number; pull_request?: unknown }>
      blocking.push(...found.filter((i) => !i.pull_request))
    }
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
    if (out && /^[0-9a-f]{40}$/.test(cand.sha)) appendFileSync(out, `candidate=${cand.sha}\n`)
    return 0
  }
  if (cmd === "recheck") {
    const hold = (why: string) => (console.log(`prod-promote recheck: HOLD ${why}`), 3)
    const cand = opt("--candidate")
    if (!holdReleases(process.env.CMUX_NEXT_PRODUCTION_HOLD, cand)) return hold(`hold switch: ${holdText(process.env.CMUX_NEXT_PRODUCTION_HOLD)}`)
    // Exactly 40 lowercase hex, nothing else (the value came through a workflow output).
    if (cand === undefined || !/^[0-9a-f]{40}$/.test(cand)) return hold("--candidate must be exactly 40 lowercase hex")
    const prod = await serving(PRODUCTION)
    if (!prod.sourceTag) return hold(`production version ${prod.version} has no source tag`)
    if (prod.codeDeployedAt && Date.now() - prod.codeDeployedAt < SPACING_HOURS * 3600_000) return hold(`production code changed less than ${SPACING_HOURS} h ago`)
    const prodSha = fullSha(prod.sourceTag)
    // Strict ancestor: equal or older candidates (a re-run, a stale job) never deploy.
    if (prodSha === cand || !isAncestor(prodSha, cand)) return hold(`production ${prodSha.slice(0, 12)} is not a strict ancestor of ${cand.slice(0, 12)}`)
    console.log(`prod-promote recheck: ok, ${prodSha.slice(0, 12)} -> ${cand.slice(0, 12)}`)
    return 0
  }
  if (cmd === "serving") {
    const prod = await serving(PRODUCTION)
    if (!prod.sourceTag) {
      console.error(`prod-promote serving: production version ${prod.version} has no source tag`)
      return 1
    }
    console.log(fullSha(prod.sourceTag))
    return 0
  }
  if (cmd === "rollback") {
    const refuse = (why: string) => (console.log(`prod-promote rollback: REFUSED ${why}`), 3)
    const plan = await rollbackPlan(PRODUCTION, rest.includes("--force"))
    if ("refused" in plan) return refuse(plan.refused)
    const label = `${plan.toSha ? plan.toSha.slice(0, 12) : "untagged"}`
    // A DO lifecycle change between the two versions: Cloudflare refuses the rollback, and old code would meet new classes.
    if (plan.fromSha && plan.toSha) {
      const from = productionEnv(fileAt(plan.fromSha, WRANGLER)).migrations
      const to = productionEnv(fileAt(plan.toSha, WRANGLER)).migrations
      if (JSON.stringify(from) !== JSON.stringify(to)) {
        const tags = from.filter((m) => !to.some((t) => JSON.stringify(t) === JSON.stringify(m))).map((m) => m.tag)
        return refuse(`${plan.fromSha.slice(0, 12)} -> ${label} crosses a Durable Object lifecycle change (${tags.join(", ") || "migrations differ"}); Cloudflare cannot roll back across it. Fix forward; to turn the Chief brain off on the serving code: gh workflow run backend.yml --repo manaflow-ai/cmux --ref feat-cmux-next -f target=chief-off`)
      }
    } else return refuse(`cannot read both source commits (serving ${plan.fromSha ?? "untagged"}, target ${label}); roll back by hand: wrangler rollback ${plan.toVersion} --name ${PRODUCTION}`)
    const args = ["rollback", plan.toVersion, "--name", PRODUCTION, "-y", "--message", `rollback ${plan.fromSha.slice(0, 12)} -> ${label} (prod-promote)`]
    const wrangler = opt("--wrangler") ?? "wrangler"
    console.log(`prod-promote rollback: ${plan.fromVersion} (${plan.fromSha.slice(0, 12)}) -> ${plan.toVersion} (${label})`)
    if (!rest.includes("--execute")) {
      console.log(`dry run; run with --execute, or: ${wrangler} ${args.join(" ")}`)
      return 0
    }
    execFileSync(wrangler, args, { stdio: "inherit" })
    const after = await serving(PRODUCTION)
    console.log(`prod-promote rollback: production serves ${after.version}${after.sourceTag ? ` (${after.sourceTag})` : ""}`)
    return after.version === plan.toVersion ? 0 : 1
  }
  if (cmd === "stale") {
    const now = Date.now()
    const prod = await serving(PRODUCTION)
    const runs = await stagingRuns()
    // state: a stable key per situation (one comment per change); reason: the text.
    let state: "current" | "unknown" | string
    let reason: string
    if (!prod.sourceTag) [state, reason] = [`no-tag:${prod.version}`, `production version ${prod.version} has no source tag (unknown code)`]
    else {
      const prodSha = fullSha(prod.sourceTag)
      const missing = runs.filter((r) => r.green && !isAncestor(r.sha, prodSha))
      const proven = runs.some((r) => r.green && isAncestor(r.sha, prodSha))
      const oldest = missing.at(-1)
      const newest = missing[0]
      const behind = newest ? backendCommits(prodSha, newest.sha) : 0
      if (oldest && now - oldest.at > STALE_HOURS * 3600_000) [state, reason] = [`age:${prodSha.slice(0, 12)}`, `production ${prodSha.slice(0, 12)} lacks a commit staging proved ${Math.round((now - oldest.at) / 3600_000)} h ago`]
      else if (behind > STALE_COMMITS) [state, reason] = [`behind:${prodSha.slice(0, 12)}`, `production ${prodSha.slice(0, 12)} is ${behind} backend commits behind staging-proven ${newest!.sha.slice(0, 12)}`]
      else if (proven || missing.length) [state, reason] = ["current", `production ${prodSha.slice(0, 12)} is current`]
      else [state, reason] = ["unknown", "no green staging run in the window to compare with"]
    }
    const stale = state !== "current" && state !== "unknown"
    console.log(`prod-promote: ${stale ? "STALE" : state.toUpperCase()} ${reason}`)
    if (rest.includes("--issue")) {
      const marker = `<!-- prod-stale state: ${state} -->`
      const open = ((await gh(`/issues?state=open&labels=prod-stale&per_page=5`)) as Array<{ number: number; body?: string; pull_request?: unknown }>).filter((i) => !i.pull_request)[0]
      const body = `${reason}\n\nChecked ${new Date(now).toISOString()} by backend.yml promote-gates (scripts/cmux-next/release/prod-promote.ts). Fix: promote the staging-proven commit or release the hold.\n${marker}`
      if (stale && !open) await gh(`/issues`, { method: "POST", body: JSON.stringify({ title: "cmux-api production is stale", body, labels: ["prod-stale"] }) })
      else if (stale && open) {
        const comments = (await gh(`/issues/${open.number}/comments?per_page=100`)) as Array<{ body: string }>
        const last = [open.body ?? "", ...comments.map((c) => c.body)].reverse().find((b) => b.includes("<!-- prod-stale state:")) ?? ""
        if (!last.includes(marker)) await gh(`/issues/${open.number}/comments`, { method: "POST", body: JSON.stringify({ body }) })
      } else if (state === "current" && open) {
        await gh(`/issues/${open.number}/comments`, { method: "POST", body: JSON.stringify({ body }) })
        await gh(`/issues/${open.number}`, { method: "PATCH", body: JSON.stringify({ state: "closed", state_reason: "completed" }) })
      }
      // unknown: no change to the issue.
    }
    return stale ? 1 : state === "unknown" ? 4 : 0
  }
  console.error("usage: prod-promote.ts config|gates|recheck|serving|rollback|stale (see the header)")
  return 2
}

if (import.meta.main) {
  let code: number
  try {
    code = await main(process.argv.slice(2))
  } catch (e) {
    console.error(`prod-promote: error: ${e instanceof Error ? e.message : String(e)}`)
    code = 2
  }
  process.exit(code)
}
