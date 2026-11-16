// Named readers for signal sources whose read is more than one op call (schema/v2/signals.json
// `read.reader`). A reader calls only the ops its entry lists; the host checks every call.

import { CmuxError } from "./cmux.ts"

export type Caller = <T = unknown>(op: string, params: unknown) => Promise<T>
export type Reader = (params: Record<string, any>, call: Caller) => Promise<unknown>

type Role = "author" | "review-requested" | "assignee"
interface Pull {
  id: number
  number: number
  title: string
  url: string
  repo: string
  draft: boolean
  state: "open" | "merged" | "closed"
  roles: Role[]
  author: string
  updatedAt: string
}

const repoOf = (url: string) => String(url ?? "").replace("https://api.github.com/repos/", "")
const codeOf = (e: unknown) => (e instanceof CmuxError ? e.code : "operation.failed")

/**
 * `github.pulls`: one search per role through the integration gateway, else (when the gateway refuses
 * and a login is set) the public search API. The route is chosen once per read: the first search that
 * the gateway refuses moves every search of that read to the fallback.
 */
async function githubPulls(params: Record<string, any>, call: Caller): Promise<Pull[]> {
  const roles: Role[] = Array.isArray(params.roles) && params.roles.length ? params.roles : ["author", "review-requested"]
  const merged = params.include === "open-and-merged"
  const limit = typeof params.limit === "number" ? params.limit : 30
  const login = typeof params.login === "string" ? params.login.trim() : ""
  const since = typeof params.updatedWithinHours === "number" ? new Date(Date.now() - params.updatedWithinHours * 3_600_000).toISOString().slice(0, 19) + "Z" : ""
  const query = (role: Role, who: string) => `is:pr ${merged ? "" : "is:open "}${role}:${who}${since ? ` updated:>=${since}` : ""}`
  let viaGateway = true
  let gatewayError: unknown = null
  const search = async (role: Role): Promise<Array<Record<string, any>>> => {
    if (viaGateway) {
      try {
        const r = await call<{ items?: Array<Record<string, any>> }>("integration.request", { provider: "github", method: "GET", path: `/search/issues?q=${encodeURIComponent(query(role, "@me"))}&per_page=${limit}` })
        return r?.items ?? []
      } catch (e) {
        viaGateway = false
        gatewayError = e
      }
    }
    if (!login) {
      // A transient gateway error (retryable) is itself the answer; a refusal means no usable connection.
      if (gatewayError instanceof CmuxError && gatewayError.retryable) throw gatewayError
      const code = codeOf(gatewayError)
      throw new CmuxError(
        code === "scope.missing" ? "scope.missing" : "integration.unavailable",
        "Connect GitHub, or set a GitHub login for the public search.",
        { signal: "github.pulls", gateway: code },
        code !== "scope.missing"
      )
    }
    const r = await call<{ status: number; body?: string }>("net.fetch", {
      url: `https://api.github.com/search/issues?q=${encodeURIComponent(query(role, login))}&per_page=${limit}`,
      method: "GET",
      headers: { Accept: "application/vnd.github+json" },
      body: null
    })
    if (r.status < 200 || r.status >= 300) throw new CmuxError("upstream.failed", `GitHub answered ${r.status}`, { status: r.status }, r.status === 403 || r.status === 429 || r.status >= 500)
    return (JSON.parse(r.body || "{}") as { items?: Array<Record<string, any>> }).items ?? []
  }
  const byId = new Map<number, Pull>()
  // Sequential on purpose: the first refusal picks the route for the rest of the read.
  for (const role of roles) {
    for (const i of await search(role)) {
      const state = i.pull_request?.merged_at ? "merged" : i.state === "closed" ? "closed" : "open"
      if (state === "closed") continue
      const known = byId.get(i.id)
      if (known) {
        if (!known.roles.includes(role)) known.roles.push(role)
        continue
      }
      byId.set(i.id, { id: i.id, number: i.number, title: String(i.title ?? ""), url: String(i.html_url ?? ""), repo: repoOf(i.repository_url), draft: !!i.draft, state, roles: [role], author: String(i.user?.login ?? ""), updatedAt: String(i.updated_at ?? "") })
    }
  }
  return [...byId.values()].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
}

type Show = "branch" | "mine" | "mentions" | "review-requested" | "search"
type CheckState = "failing" | "pending" | "passing" | "none"
type Review = "approved" | "changes-requested" | "review-required" | "commented" | "none"
export interface Change {
  id: number
  number: number
  title: string
  url: string
  repo: string
  author: string
  draft: boolean
  state: "open" | "merged" | "closed"
  headRef: string
  headSha: string
  additions: number
  deletions: number
  checks: { state: CheckState; failing: number; pending: number; passing: number }
  review: Review
  updatedAt: string
}

/**
 * The public route's conditional requests: path -> the last 200's ETag and body. Bounded (oldest
 * out first), so its cost stays flat however many pull requests pass through. The gateway keeps
 * its own cache; this one is only for net.fetch.
 */
const ETAGS = new Map<string, { etag: string; body: unknown }>()
const ETAG_CAP = 256
export const etagCacheSize = () => ETAGS.size

function keep(path: string, etag: string, body: unknown) {
  ETAGS.delete(path)
  ETAGS.set(path, { etag, body })
  while (ETAGS.size > ETAG_CAP) ETAGS.delete(ETAGS.keys().next().value as string)
}

/**
 * One GitHub GET for a read: the gateway first; once it refuses, the public API with If-None-Match
 * for the rest of that read. `needsPerson` marks a path that names @me, which the public route
 * cannot answer without a login.
 */
function githubGetter(call: Caller, signalName: string) {
  let viaGateway = true
  let gatewayError: unknown = null
  const refused = () => {
    if (gatewayError instanceof CmuxError && gatewayError.retryable) return gatewayError
    const code = codeOf(gatewayError)
    return new CmuxError(
      code === "scope.missing" ? "scope.missing" : "integration.unavailable",
      "Sign in to GitHub (gh auth login), or set a GitHub login for public repositories.",
      { signal: signalName, gateway: code },
      code !== "scope.missing"
    )
  }
  const get = async <T>(path: string): Promise<T> => {
    if (viaGateway) {
      try {
        return await call<T>("integration.request", { provider: "github", method: "GET", path })
      } catch (e) {
        // A path the gateway refuses is a bug here, not a reason to change route.
        if (e instanceof CmuxError && e.code === "validation.invalid") throw e
        viaGateway = false
        gatewayError = e
      }
    }
    if (path.includes("%40me")) throw refused()
    const known = ETAGS.get(path)
    let r: { status: number; headers?: Record<string, string>; body?: string }
    try {
      r = await call("net.fetch", {
        url: `https://api.github.com${path}`,
        method: "GET",
        headers: { Accept: "application/vnd.github+json", ...(known ? { "If-None-Match": known.etag } : {}) },
        body: null
      })
    } catch (e) {
      // No net:api.github.com either: say what would make it work.
      if (e instanceof CmuxError && e.code === "scope.missing") throw refused()
      throw e
    }
    if (r.status === 304 && known) {
      keep(path, known.etag, known.body)
      return known.body as T
    }
    if (r.status < 200 || r.status >= 300) throw new CmuxError("upstream.failed", `GitHub answered ${r.status}`, { status: r.status }, r.status === 403 || r.status === 429 || r.status >= 500)
    const body = JSON.parse(r.body || "null") as T
    const etag = Object.entries(r.headers ?? {}).find(([k]) => k.toLowerCase() === "etag")?.[1]
    if (etag) keep(path, etag, body)
    return body
  }
  return { get, onGateway: () => viaGateway }
}

/** At most `n` of `jobs` at once, results in order (the gateway takes 8 reads at once across apps). */
async function pool<T, R>(items: readonly T[], n: number, job: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length)
  let next = 0
  const worker = async () => {
    while (next < items.length) {
      const i = next++
      out[i] = await job(items[i] as T)
    }
  }
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, worker))
  return out
}

const FAILED = new Set(["failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"])

/** The rollup of a head's check runs and commit statuses. */
export function rollup(runs: Array<Record<string, any>>, statuses: Array<Record<string, any>>): Change["checks"] {
  let failing = 0
  let pending = 0
  let passing = 0
  for (const r of runs) {
    if (r.status !== "completed") pending++
    else if (FAILED.has(String(r.conclusion))) failing++
    else passing++
  }
  for (const s of statuses) {
    if (s.state === "failure" || s.state === "error") failing++
    else if (s.state === "pending") pending++
    else if (s.state === "success") passing++
  }
  const state: CheckState = failing ? "failing" : pending ? "pending" : passing ? "passing" : "none"
  return { state, failing, pending, passing }
}

/** The review decision from each reviewer's latest review (a dismissal clears theirs): changes requested, then approved, then review required while one is asked for. */
export function decision(reviews: Array<Record<string, any>>, requested: number): Review {
  const latest = new Map<string, string>()
  let commented = false
  for (const r of reviews) {
    const who = String(r.user?.login ?? "")
    const s = String(r.state ?? "")
    if (s === "COMMENTED") commented = true
    else if (s === "DISMISSED") latest.delete(who)
    else if (s === "APPROVED" || s === "CHANGES_REQUESTED") latest.set(who, s)
  }
  const states = [...latest.values()]
  if (states.includes("CHANGES_REQUESTED")) return "changes-requested"
  if (states.includes("APPROVED")) return "approved"
  if (requested > 0) return "review-required"
  return commented ? "commented" : "none"
}

/** The search for every `show` but branch, with is:pr, the repo and the open filter. */
function searchQuery(params: Record<string, any>, who: string): string {
  const show = (params.show ?? "mine") as Show
  const parts = ["is:pr"]
  if (params.include !== "open-and-merged") parts.push("is:open")
  if (params.repo) parts.push(`repo:${params.repo}`)
  if (show === "mine") parts.push(`author:${who}`)
  else if (show === "mentions") parts.push(`mentions:${who}`)
  else if (show === "review-requested") parts.push(`review-requested:${who}`)
  else if (show === "search") parts.push(String(params.query ?? "").replace(/\bis:pr\b/g, "").trim())
  return parts.filter(Boolean).join(" ")
}

/**
 * `github.changes`: one list read (a search, or the repository's pulls for a branch), then four
 * reads per pull request: the pull request (lines, head), its reviews, its head's check runs and
 * its head's commit status. Every read is conditional, so a list where nothing moved is answered
 * from ETags. Merged and closed pull requests skip the checks and reviews.
 */
async function githubChanges(params: Record<string, any>, call: Caller): Promise<Change[]> {
  const show = (params.show ?? "mine") as Show
  const limit = typeof params.limit === "number" ? params.limit : 10
  const login = typeof params.login === "string" ? params.login.trim() : ""
  const gh = githubGetter(call, "github.changes")
  let refs: Array<{ repo: string; number: number }>
  if (show === "branch") {
    if (!params.repo || !params.branch) throw new CmuxError("signal.params", "github.changes: show: branch needs repo and branch", { signal: "github.changes" })
    const owner = String(params.repo).split("/")[0]
    const state = params.include === "open-and-merged" ? "all" : "open"
    const head = encodeURIComponent(`${owner}:${params.branch}`)
    const pulls = await gh.get<Array<Record<string, any>>>(`/repos/${params.repo}/pulls?head=${head}&state=${state}&per_page=${limit}`)
    refs = (pulls ?? []).map((p) => ({ repo: String(params.repo), number: Number(p.number) }))
  } else {
    if (show === "search" && !String(params.query ?? "").trim()) throw new CmuxError("signal.params", "github.changes: show: search needs query", { signal: "github.changes" })
    // Tried as the signed-in person first; the public route needs a login to stand for @me.
    const path = (who: string) => `/search/issues?q=${encodeURIComponent(searchQuery(params, who))}&sort=updated&order=desc&per_page=${limit}`
    let found: { items?: Array<Record<string, any>> }
    try {
      found = await gh.get(path("@me"))
    } catch (e) {
      if (gh.onGateway() || !login) throw e
      found = await gh.get(path(login || "@me"))
    }
    refs = (found?.items ?? []).map((i) => ({ repo: repoOf(i.repository_url), number: Number(i.number) }))
  }
  const rows = await pool(refs.slice(0, limit), 4, async ({ repo, number }): Promise<Change> => {
    const p = await gh.get<Record<string, any>>(`/repos/${repo}/pulls/${number}`)
    const state = p.merged_at ? "merged" : p.state === "closed" ? "closed" : "open"
    const sha = String(p.head?.sha ?? "")
    let checks: Change["checks"] = { state: "none", failing: 0, pending: 0, passing: 0 }
    let review: Review = "none"
    if (state === "open" && sha) {
      const [runs, status, reviews] = await Promise.all([
        gh.get<{ check_runs?: Array<Record<string, any>> }>(`/repos/${repo}/commits/${sha}/check-runs?filter=latest&per_page=100`),
        gh.get<{ statuses?: Array<Record<string, any>> }>(`/repos/${repo}/commits/${sha}/status`),
        gh.get<Array<Record<string, any>>>(`/repos/${repo}/pulls/${number}/reviews?per_page=100`)
      ])
      checks = rollup(runs?.check_runs ?? [], status?.statuses ?? [])
      review = decision(reviews ?? [], (p.requested_reviewers?.length ?? 0) + (p.requested_teams?.length ?? 0))
    }
    return {
      id: Number(p.id),
      number,
      title: String(p.title ?? ""),
      url: String(p.html_url ?? ""),
      repo,
      author: String(p.user?.login ?? ""),
      draft: !!p.draft,
      state,
      headRef: String(p.head?.ref ?? ""),
      headSha: sha,
      additions: Number(p.additions ?? 0),
      deletions: Number(p.deletions ?? 0),
      checks,
      review,
      updatedAt: String(p.updated_at ?? "")
    }
  })
  const merged = params.include === "open-and-merged"
  return rows.filter((r) => r.state === "open" || (merged && r.state === "merged")).sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
}

export const READERS: Record<string, Reader> = { "github.pulls": githubPulls, "github.changes": githubChanges }
