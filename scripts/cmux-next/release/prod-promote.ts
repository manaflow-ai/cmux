/**
 * Production promotion and staleness for the cmux-next API Worker (cx-w1ald,
 * plans/cmux-next/release-rails.md "Continuous delivery to production").
 *
 *   bun prod-promote.ts config --config backend/apps/api/wrangler.jsonc
 *       Production config gate (deploy-worker.sh runs it before every production deploy): every
 *       secret named in production-approvals.json `required_secrets` is set on cmux-api, and
 *       HOME_INVITES_SEND "on" needs HOME_INVITE_FROM. Names only, never values.
 *   bun prod-promote.ts gates [--candidate SHA] [--github-output FILE] [--runs-cache FILE]
 *       Picks the staging-proven candidate and runs G1-G7. Exit 0 = promote (writes
 *       candidate=<sha> to FILE); exit 3 = nothing to do or a gate holds (the reason is printed).
 *       --candidate (40 hex; the exact-SHA promote): G1 must prove exactly that commit (its own
 *       green staging deploy, soaked, no red one in its soak window) instead of the newest one.
 *   bun prod-promote.ts recheck --candidate SHA
 *       Right before the deploy: hold released, spacing, and production's changes are in SHA
 *       (strict ancestry or patch-equivalent cherry-picks; a re-run never downgrades). Exit 0 = deploy; 3 = hold.
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
 *       secret set after the target is undone. After a rollback, `gates` holds the rolled-back
 *       commit and anything not newer than it; a newer staging-proven commit promotes itself.
 *       After the off switch it holds every automatic promote; only an exact-SHA promote
 *       (--candidate) moves production forward.
 *   bun prod-promote.ts stale [--issue] [--runs-cache FILE]
 *       Exit 1 = stale (no source tag, a staging-proven commit older than STALE_HOURS missing, or
 *       more than STALE_COMMITS backend commits behind); 0 = current, proven by at least one green
 *       staging run that production has; 4 = unknown (no green evidence). Errors exit 2.
 *       --issue opens the `prod-stale` issue, comments once per state change, and closes it only
 *       on "current".
 *
 * --runs-cache FILE (gates, stale): what each finished staging run attempt proved, kept between steps and runs
 *   (backend.yml's promote-gates restores and saves it with actions/cache). Each run still lists backend.yml's
 *   runs (one call) but reads only the attempts the file lacks (one call each), not all 30 every time: the
 *   repository's GITHUB_TOKEN hour is shared by every workflow, and this read 403'd when it ran out. When it is spent
 *   anyway, the runs and their jobs come from one GraphQL read, whose hour is separate.
 *
 * Environment: CLOUDFLARE_API_TOKEN (read: scripts, versions, deployments, secret names),
 * GITHUB_TOKEN or GH_TOKEN and GITHUB_REPOSITORY (read: Actions runs; issues for --issue),
 * CMUX_NEXT_PRODUCTION_HOLD (G6: unset, empty or "released" releases every candidate, the default;
 * "released:<40 hex>" only that commit; any other value is a hold a person set on purpose). Runs from the repo root, except
 * `config`, which reads the approvals next to this file.
 */
import { execFileSync } from "node:child_process"
import { appendFileSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { stripJsonc } from "./worker-release.ts"

const ACCOUNT = "0c1675e0def6de1ab3a50a4e17dc5656"
const PRODUCTION = "cmux-api"
const STAGING = "cmux-api-staging"
const WRANGLER = "backend/apps/api/wrangler.jsonc"
/** Repo-relative (for `git show <sha>:`) and on disk next to this script (deploy-worker.sh runs from backend/apps/api). */
const APPROVALS = "scripts/cmux-next/release/production-approvals.json"
const APPROVALS_ON_DISK = join(import.meta.dir, "production-approvals.json")
/**
 * G6: the hold switch is off by default. Unset, empty or "released" releases every staging-proven
 * commit; a person sets any other value on purpose to hold, and nothing sets one automatically
 * (Leo, 2026-11-14: "y'all should've just set up an auto system").
 */
export const HOLD_RELEASED = "released"
/** The hold switch is off: production promotes itself. */
export const holdOff = (hold: string | undefined): boolean => hold === undefined || hold === "" || hold === HOLD_RELEASED
/** G6 for one commit: off releases every commit, "released:<sha>" only that one (one-shot exact-SHA release). */
export const holdReleases = (hold: string | undefined, sha: string | undefined): boolean =>
  holdOff(hold) || (sha !== undefined && /^[0-9a-f]{40}$/.test(sha) && hold === `${HOLD_RELEASED}:${sha}`)
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
/** G7: production vars whose change spends money, sends messages or opens a service-binding surface (PLATFORM_SURFACES: requests forwarded to cmux-platform); each new value needs an approval. */
export const GUARDED_VAR = /^(INFERENCE_|AUTOMATION_CAP_|HOME_INVITES_SEND$|HOME_INVITES_TEXT$|CHIEF_BRAIN_|CHIEF_CREDITS_|CHIEF_RUN_TOKEN_CAP_USD$|CLOUD_PLAN_ENTITLEMENTS$|PLATFORM_MACHINES$|PLATFORM_SURFACES$)/

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

/** Waits before each retry of a GitHub 5xx or network error (one 502 failed promote-gates before G1-G7 ran). 4xx never retries. */
export const GH_RETRY_DELAYS_MS: ReadonlyArray<number> = [2_000, 5_000, 10_000]

/**
 * The longest gh() waits for a spent token hour to reset before its one retry. The repository's GITHUB_TOKEN hour is
 * shared by every workflow and still ran out a few minutes before its reset (2026-11-21 14:49Z for 14:51Z); a
 * promote-gates read in those minutes failed the promote. Ten minutes leaves promote-gates (25) room to finish.
 */
export const GH_RATE_LIMIT_WAIT_MS = 10 * 60_000

/** The clock gh() waits on for a rate-limit reset; tests pass a fake one. */
export type GhLimits = { now: () => number; sleep: (ms: number) => Promise<void>; maxWaitMs?: number }
const realLimits: GhLimits = { now: () => Date.now(), sleep: (ms) => new Promise((done) => setTimeout(done, ms)) }
/** For reads with a GraphQL fallback: a spent hour falls back at once instead of waiting for the reset. */
const NO_WAIT: GhLimits = { ...realLimits, maxWaitMs: 0 }

/** GitHub refused a request because the token's REST hour is spent (a 403 or 429 with no requests left). */
export class GitHubHourSpent extends Error {}

const spent = (r: Response) => (r.status === 403 || r.status === 429) && r.headers.get("x-ratelimit-remaining") === "0"

/** How long until a rate-limit refusal's hour resets (plus a second), or null when it is no such refusal or the reset is too far away. */
const rateLimitWait = (r: Response, now: number, maxWaitMs = GH_RATE_LIMIT_WAIT_MS): number | null => {
  if (!spent(r)) return null
  const reset = Number(r.headers.get("x-ratelimit-reset"))
  if (!Number.isFinite(reset)) return null
  const ms = Math.max(0, reset * 1000 - now) + 1_000
  return ms <= maxWaitMs ? ms : null
}

export const gh = async (path: string, init: RequestInit = {}, delays: ReadonlyArray<number> = GH_RETRY_DELAYS_MS, limits: GhLimits = realLimits): Promise<any> => {
  const token = process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN
  const repo = process.env.GITHUB_REPOSITORY ?? "manaflow-ai/cmux"
  if (!token) throw new Error("GITHUB_TOKEN is not set")
  // A POST is not retried: a 5xx may still have created the issue or comment, and a retry would duplicate it.
  const retries = (init.method ?? "GET").toUpperCase() === "POST" ? [] : delays
  const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms))
  const url = `https://api.github.com/repos/${repo}${path}`
  const opts = { ...init, headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", ...(init.headers ?? {}) } }
  const fetchOnce = async (attempt: number): Promise<Response> => {
    try {
      const res = await fetch(url, opts)
      if (res.status < 500 || attempt >= retries.length) return res
      await res.body?.cancel().catch(() => {})
    } catch (e) {
      if (attempt >= retries.length) throw e
    }
    await sleep(retries[attempt]!)
    return fetchOnce(attempt + 1)
  }
  let r = await fetchOnce(0)
  // A refused request did nothing (a POST too), so one retry after the reset is safe; a second refusal throws.
  const wait = rateLimitWait(r, limits.now(), limits.maxWaitMs)
  if (wait !== null) {
    await r.body?.cancel().catch(() => {})
    console.error(`prod-promote: GitHub ${path}: the token's hour is spent; waiting ${Math.round(wait / 1000)} s for its reset, then retrying once`)
    await limits.sleep(wait)
    r = await fetchOnce(0)
  }
  // The body and the rate-limit headers say why (a 403 is a rate limit or a permission; the status alone hid which).
  if (!r.ok && spent(r)) throw new GitHubHourSpent(`GitHub ${path}: HTTP ${r.status} ${(await r.text().catch(() => "")).slice(0, 300)} [remaining 0, reset ${r.headers.get("x-ratelimit-reset")}]`)
  if (!r.ok) throw new Error(`GitHub ${path}: HTTP ${r.status} ${(await r.text().catch(() => "")).slice(0, 300)} [remaining ${r.headers.get("x-ratelimit-remaining")}, reset ${r.headers.get("x-ratelimit-reset")}, retry-after ${r.headers.get("retry-after")}]`)
  return r.status === 204 ? null : r.json()
}

export type GitRunner = (args: ReadonlyArray<string>, input?: string) => string

const runGit: GitRunner = (args, input) => execFileSync("git", args, { encoding: "utf8", ...(input === undefined ? {} : { input }) }).trim()
const git = (...args: Array<string>) => runGit(args)
const fileAt = (sha: string, path: string) => git("show", `${sha}:${path}`)

/** The Chief off switch's version message (deploy-worker.sh CMUX_DEPLOY_CHIEF_OFF: "source <sha> chief-off run <id>"). */
const CHIEF_OFF = / chief-off( |$)/

/**
 * The serving version of a Worker, its source commit (version tag, 12 hex) and when its code last
 * changed. A secret-only deployment (`wrangler secret put`) makes a new version of the same code
 * without the tag, so the tag comes from the newest code deployment.
 */
export const serving = async (script: string): Promise<{ version: string; sourceTag?: string; codeDeployedAt?: number; heldBack?: string; rolledBackTag?: string }> => {
  const deps = [...((await cf(`/workers/scripts/${script}/deployments`)) as { deployments: Array<any> }).deployments].sort((a, b) => Date.parse(b.created_on) - Date.parse(a.created_on))
  const top = deps[0]
  if (!top || top.versions.length !== 1 || top.versions[0].percentage !== 100) throw new Error(`${script}: no single version at 100%`)
  const version = top.versions[0].version_id as string
  const code = deps.find((d) => d.annotations?.["workers/triggered_by"] !== "secret")
  const codeVersion = code && code.versions.length === 1 ? (code.versions[0].version_id as string) : undefined
  const v = codeVersion ? await cf(`/workers/scripts/${script}/versions/${codeVersion}`) : undefined
  const tag = v?.annotations?.["workers/tag"] as string | undefined
  // Production was stepped back. The Chief off switch holds every automatic promote. A rollback holds the code
  // it removed (rolledBackTag: the code deployment it replaced), so only a newer commit promotes itself.
  const message = String(v?.annotations?.["workers/message"] ?? "")
  const rolledBack = code?.annotations?.["workers/triggered_by"] === "rollback"
  const heldBack = rolledBack ? "production serves a rollback" : CHIEF_OFF.test(message) ? "production serves the Chief off switch" : undefined
  let rolledBackTag: string | undefined
  if (rolledBack) {
    const replaced = deps.slice(deps.indexOf(code) + 1).find((d) => d.annotations?.["workers/triggered_by"] !== "secret")
    const replacedVersion = replaced && replaced.versions.length === 1 ? (replaced.versions[0].version_id as string) : undefined
    const t = replacedVersion ? ((await cf(`/workers/scripts/${script}/versions/${replacedVersion}`))?.annotations?.["workers/tag"] as string | undefined) : undefined
    if (t && /^[0-9a-f]{12}$/.test(t)) rolledBackTag = t
  }
  return { version, ...(tag && /^[0-9a-f]{12}$/.test(tag) ? { sourceTag: tag } : {}), ...(code ? { codeDeployedAt: Date.parse(code.created_on) } : {}), ...(heldBack ? { heldBack } : {}), ...(rolledBackTag ? { rolledBackTag } : {}) }
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

/**
 * What each finished staging run attempt proved, keyed `<run id>:<attempt>`: its StagingRun, or null when it proves
 * nothing (no deploy-staging, skipped, or source-fenced). A completed attempt's jobs never change, so a verdict is
 * read from GitHub once and reused (a re-run is a new attempt, read again); `sha` must match the listed run's head.
 */
export type RunVerdicts = Record<string, { sha: string; run: StagingRun | null }>

/** One run's verdict from its jobs (one GitHub call). */
const runVerdict = async (run: { id: number; head_sha: string }): Promise<StagingRun | null> => {
  const jobs = (await gh(`/actions/runs/${run.id}/jobs?per_page=100`, {}, GH_RETRY_DELAYS_MS, NO_WAIT)).jobs as Array<any>
  const job = jobs.find((j) => j.name === "deploy-staging")
  if (!job || job.conclusion === "skipped") return null
  // A source-fenced stale run made no staging mutation and contributes no soak evidence.
  if ((job.steps as Array<any>).some((s) => s.name === "Newer deployment inputs already queued; skip" && s.conclusion === "success")) return null
  const smoke = (job.steps as Array<any>).find((s) => String(s.name).startsWith("Smoke the API Worker"))
  // G1 proves the tests too: the run's test and migrations-push-guard jobs passed.
  const passed = (name: string) => jobs.some((j) => j.name === name && j.conclusion === "success")
  return { sha: run.head_sha, at: Date.parse(job.completed_at), green: job.conclusion === "success" && smoke?.conclusion === "success" && passed("test") && passed("migrations-push-guard") }
}

/**
 * One GitHub GraphQL query with the job's token. GraphQL has its own hour, apart from the REST hour every workflow spends.
 * A query reads only, so a 5xx, a network error or an answer with errors and no data is retried after DELAYS: on
 * 2026-11-24 14:27Z the REST hour was spent 25 minutes before its reset, and the fallback's one 502 (then an empty
 * error) failed promote-gates, so production waited for the next backend push instead of the next try.
 */
export const ghGraphql = async (query: string, variables: Record<string, unknown>, delays: ReadonlyArray<number> = GH_RETRY_DELAYS_MS): Promise<any> => {
  const token = process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN
  if (!token) throw new Error("GITHUB_TOKEN is not set")
  for (let attempt = 0; ; attempt++) {
    let failure: Error
    let retryable = true
    try {
      const r = await fetch("https://api.github.com/graphql", {
        method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify({ query, variables }),
      })
      const body = (await r.json().catch(() => null)) as { data?: any; errors?: Array<{ message?: string; type?: string }> } | null
      if (r.ok && body?.data && !body.errors?.length) return body.data
      failure = new Error(`GitHub GraphQL: HTTP ${r.status} ${(body?.errors ?? []).map((e) => (e.type ? `${e.type}: ${e.message}` : e.message)).join("; ").slice(0, 300)}`)
      // A 4xx other than a rate limit (a bad query, a permission) answers the same on every try.
      retryable = !(r.status >= 400 && r.status < 500 && r.status !== 403 && r.status !== 429)
    } catch (e) {
      failure = e instanceof Error ? e : new Error(String(e))
    }
    if (!retryable || attempt >= delays.length) throw failure
    console.error(`prod-promote: ${failure.message.trim()}; retrying in ${Math.round(delays[attempt]! / 1000)} s`)
    await new Promise((done) => setTimeout(done, delays[attempt]!))
  }
}

/** backend.yml's workflow node (GET /repos/manaflow-ai/cmux/actions/workflows/backend.yml .node_id; fixed while the file keeps its name). */
export const BACKEND_WORKFLOW_NODE = "W_kwDORDHQWM4WOJGc"

/** Pages of backend.yml runs GraphQL reads at most for 30 completed feat-cmux-next pushes (pull requests outnumber them). */
const GRAPHQL_RUN_PAGES = 5

const STAGING_RUNS_QUERY = `query($id: ID!, $after: String) {
  node(id: $id) { ... on Workflow { runs(first: 100, after: $after, orderBy: {field: CREATED_AT, direction: DESC}) {
    pageInfo { hasNextPage endCursor }
    nodes { databaseId event checkSuite { status branch { name } commit { oid }
      deploy: checkRuns(first: 1, filterBy: {checkName: "deploy-staging", checkType: LATEST}) { nodes { name conclusion completedAt steps(first: 100) { nodes { name conclusion } } } }
      test: checkRuns(first: 1, filterBy: {checkName: "test", checkType: LATEST}) { nodes { name conclusion } }
      guard: checkRuns(first: 1, filterBy: {checkName: "migrations-push-guard", checkType: LATEST}) { nodes { name conclusion } } } }
  } } }
}`

/** stagingRuns' answer from GraphQL: the same runs (completed feat-cmux-next pushes) and verdicts, each run's latest attempt. */
export const stagingRunsGraphql = async (limit = 30): Promise<Array<StagingRun>> => {
  const out: Array<StagingRun> = []
  let after: string | null = null
  let listed = 0
  for (let page = 0; page < GRAPHQL_RUN_PAGES && listed < limit; page++) {
    const runs = (await ghGraphql(STAGING_RUNS_QUERY, { id: BACKEND_WORKFLOW_NODE, after }))?.node?.runs
    if (!runs) throw new Error("GitHub GraphQL: backend.yml's runs are missing")
    for (const run of runs.nodes as Array<any>) {
      const suite = run?.checkSuite
      if (run?.event !== "push" || suite?.branch?.name !== "feat-cmux-next" || suite?.status !== "COMPLETED" || listed >= limit) continue
      listed++
      const sha = String(suite.commit?.oid ?? "")
      const job = suite.deploy?.nodes?.[0]
      if (!job || job.conclusion === "SKIPPED") continue
      const steps = (job.steps?.nodes ?? []) as Array<{ name: string; conclusion: string }>
      if (steps.some((s) => s.name === "Newer deployment inputs already queued; skip" && s.conclusion === "SUCCESS")) continue
      const smoke = steps.find((s) => String(s.name).startsWith("Smoke the API Worker"))
      const passed = (key: "test" | "guard") => suite[key]?.nodes?.[0]?.conclusion === "SUCCESS"
      out.push({ sha, at: Date.parse(job.completedAt), green: job.conclusion === "SUCCESS" && smoke?.conclusion === "SUCCESS" && passed("test") && passed("guard") })
    }
    if (!runs.pageInfo?.hasNextPage) break
    after = runs.pageInfo.endCursor
  }
  return out
}

/**
 * Staging deploys of feat-cmux-next pushes, newest first: green = deploy-staging and its smoke step passed.
 * One list call, plus one jobs call per run attempt `verdicts` does not already hold; when the REST hour is spent,
 * one GraphQL read instead (stagingRunsGraphql), with no wait for the reset. `verdicts` is updated in
 * place and keeps only the listed attempts, so a caller that saves it (--runs-cache) never reads a run twice.
 */
export const stagingRuns = async (limit = 30, verdicts: RunVerdicts = {}): Promise<Array<StagingRun>> => {
  try {
    return await stagingRunsRest(limit, verdicts)
  } catch (error) {
    if (!(error instanceof GitHubHourSpent)) throw error
    console.error(`prod-promote: ${error.message}; reading the staging runs over GraphQL instead`)
    return stagingRunsGraphql(limit)
  }
}

const stagingRunsRest = async (limit: number, verdicts: RunVerdicts): Promise<Array<StagingRun>> => {
  const runs = (await gh(`/actions/workflows/backend.yml/runs?branch=feat-cmux-next&event=push&status=completed&per_page=${limit}`, {}, GH_RETRY_DELAYS_MS, NO_WAIT)).workflow_runs as Array<any>
  const out: Array<StagingRun> = []
  const listed = new Set<string>()
  for (const run of runs) {
    const key = `${run.id}:${run.run_attempt ?? 1}`
    listed.add(key)
    const known = verdicts[key]
    const verdict = known && known.sha === run.head_sha && (known.run === null || known.run.sha === run.head_sha) ? known.run : await runVerdict(run)
    verdicts[key] = { sha: run.head_sha, run: verdict }
    if (verdict) out.push(verdict)
  }
  for (const key of Object.keys(verdicts)) if (!listed.has(key)) delete verdicts[key]
  return out
}

/** The verdicts a --runs-cache file holds; anything missing or malformed reads as none (every run is read again). */
export const loadVerdicts = (path: string | undefined): RunVerdicts => {
  if (!path) return {}
  try {
    const raw = JSON.parse(readFileSync(path, "utf8")) as unknown
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {}
    const out: RunVerdicts = {}
    for (const [key, value] of Object.entries(raw as Record<string, any>)) {
      if (!/^\d+:\d+$/.test(key) || typeof value?.sha !== "string") continue
      const run = value.run
      if (run === null) out[key] = { sha: value.sha, run: null }
      else if (typeof run?.sha === "string" && typeof run.at === "number" && typeof run.green === "boolean") out[key] = { sha: value.sha, run: { sha: run.sha, at: run.at, green: run.green } }
    }
    return out
  } catch {
    return {}
  }
}

/** stagingRuns() through a --runs-cache file: read it, list the runs, read only the attempts it lacks, write it back. */
const cachedStagingRuns = async (path: string | undefined): Promise<Array<StagingRun>> => {
  const verdicts = loadVerdicts(path)
  const runs = await stagingRuns(30, verdicts)
  if (path) writeFileSync(path, JSON.stringify(verdicts))
  return runs
}

/** G1: the newest green staging deploy at least SOAK_MINUTES old with no red staging deploy in its soak window. */
export const pickCandidate = (runs: ReadonlyArray<StagingRun>, now: number): StagingRun | undefined =>
  runs.find((r) => r.green && now - r.at >= SOAK_MINUTES * 60_000 && !runs.some((x) => !x.green && x.at > r.at && x.at <= r.at + SOAK_MINUTES * 60_000))

/** Exact SHA (--candidate or a one-shot hold): only that commit's green runs compete; every red run still counts against its soak window. */
export const candidateRuns = (runs: ReadonlyArray<StagingRun>, want: string | undefined): ReadonlyArray<StagingRun> => (want ? runs.filter((r) => !r.green || r.sha === want) : runs)

const isAncestor = (a: string, b: string, run: GitRunner = runGit) => {
  try {
    run(["merge-base", "--is-ancestor", a, b])
    return true
  } catch {
    return false
  }
}

const backendCommitsIn = (sha: string, run: GitRunner, exclude?: string): Array<string> => {
  const args = ["rev-list", "--no-merges", sha]
  if (exclude) args.push("--not", exclude)
  args.push("--", "backend/")
  return run(args).split("\n").filter(Boolean)
}

const patchId = (sha: string, run: GitRunner): string | undefined => {
  const patch = run(["show", "--format=", "--no-ext-diff", sha])
  if (!patch) return undefined
  const id = run(["patch-id", "--stable"], patch).split(/\s+/, 1)[0]
  return id || undefined
}

/**
 * Production must be an ancestor of the staging candidate, or every production-only backend
 * commit must be represented by the same patch in the candidate's history. The latter allows a
 * deployment assembled from cherry-picks while still holding any candidate with an unmatched
 * production change.
 */
export const isPromotableLineage = (productionSha: string, candidateSha: string, run: GitRunner = runGit): boolean => {
  if (productionSha === candidateSha || isAncestor(productionSha, candidateSha, run)) return true
  const productionOnly = backendCommitsIn(productionSha, run, candidateSha)
  if (!productionOnly.length) return false
  const candidatePatches = new Set(backendCommitsIn(candidateSha, run).map((sha) => patchId(sha, run)).filter((id): id is string => id !== undefined))
  return productionOnly.every((sha) => {
    const id = patchId(sha, run)
    return id !== undefined && candidatePatches.has(id)
  })
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
    // G6 first: a hold a person set stops everything, even the reads. A one-shot release names its one commit.
    if (!holdOff(holdValue) && !pinned) return hold("G6", `hold switch: ${holdText(holdValue)}`)
    if (pinned && asked !== undefined && asked !== pinned) return hold("G6", `the hold releases only ${pinned.slice(0, 12)}, not ${asked.slice(0, 12)}`)
    const want = asked ?? pinned
    const now = Date.now()
    const prod = await serving(PRODUCTION)
    if (!prod.sourceTag) return hold("source", `production version ${prod.version} has no source tag; the first promotion is the hand rail with Lawrence's go`)
    // After the off switch (or a rollback whose removed code is unknown) only an exact-SHA promote (--candidate)
    // moves production forward. After a rollback, a commit newer than the rolled-back one does (checked below).
    if (prod.heldBack && asked === undefined && !prod.rolledBackTag) return hold("rolled-back", `${prod.heldBack}; promote an exact fixed commit with --candidate (target=promote, candidate=<sha>)`)
    if (prod.codeDeployedAt && now - prod.codeDeployedAt < SPACING_HOURS * 3600_000) return hold("spacing", `production code changed less than ${SPACING_HOURS} h ago`)
    const prodSha = fullSha(prod.sourceTag)
    const runs = await cachedStagingRuns(opt("--runs-cache"))
    const cand = pickCandidate(candidateRuns(runs, want), now)
    if (!cand) return hold("G1", want ? `${want.slice(0, 12)} has no green staging deploy (tests, push guard, deploy and smoke) older than ${SOAK_MINUTES} min without a red one after it, among the last ${runs.length} staging runs` : `no green staging deploy older than ${SOAK_MINUTES} min without a red one after it`)
    if (cand.sha === prodSha || isAncestor(cand.sha, prodSha)) return hold("none", `production ${prodSha.slice(0, 12)} already has the staging-proven ${cand.sha.slice(0, 12)}`)
    if (prod.heldBack && asked === undefined && prod.rolledBackTag) {
      const bad = fullSha(prod.rolledBackTag)
      if (cand.sha === bad || !isAncestor(bad, cand.sha)) return hold("rolled-back", `${prod.heldBack} of ${bad.slice(0, 12)}; the staging-proven ${cand.sha.slice(0, 12)} is not newer than it (a newer one promotes itself; target=promote candidate=<sha> promotes one by hand)`)
    }
    if (!isPromotableLineage(prodSha, cand.sha)) return hold("lineage", `${cand.sha.slice(0, 12)} does not descend from production ${prodSha.slice(0, 12)}`)
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
    if (prodSha === cand || !isPromotableLineage(prodSha, cand)) return hold(`production ${prodSha.slice(0, 12)} is not a strict ancestor of ${cand.slice(0, 12)}`)
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
    const runs = await cachedStagingRuns(opt("--runs-cache"))
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
