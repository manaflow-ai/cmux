/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// GitHub work items through the integration gateway (`integration:github:read`).
// The token never enters the app: every request is a GET the gateway signs.
// Three search queries, each one call; check details load only for the
// selected pull request.

import { priority, type Item, type Kind } from "./model.ts"

export interface GithubOptions {
  reviewRequests: boolean
  failingChecks: boolean
  mentions: boolean
  /** Mentions older than this are not fetched. */
  mentionDays: number
}

export type GithubStatus = "idle" | "ok" | "partial" | "notGranted" | "unavailable" | "error"

export interface GithubResult {
  status: GithubStatus
  items: Item[]
  /** One message per failed query. */
  errors: string[]
}

const day = (ms: number) => new Date(ms).toISOString().slice(0, 10)

/** The search query per kind; `status:failure` matches pull requests whose latest commit has a failed check or status. */
export function githubQueries(options: GithubOptions, now: number): Array<{ kind: Kind; query: string }> {
  const out: Array<{ kind: Kind; query: string }> = []
  if (options.reviewRequests) out.push({ kind: "reviewRequested", query: "is:open is:pr review-requested:@me archived:false" })
  if (options.failingChecks) out.push({ kind: "checksFailing", query: "is:open is:pr author:@me status:failure archived:false" })
  if (options.mentions) out.push({ kind: "mention", query: `is:open mentions:@me archived:false updated:>=${day(now - options.mentionDays * 86_400_000)}` })
  return out
}

export const searchPath = (query: string) => `/search/issues?q=${encodeURIComponent(query)}&sort=updated&order=desc&per_page=30`

interface SearchItem {
  number?: number
  title?: string
  html_url?: string
  repository_url?: string
  updated_at?: string
  draft?: boolean
  user?: { login?: string } | null
  pull_request?: unknown
}

const repoOf = (item: SearchItem) => {
  const fromApi = item.repository_url?.match(/\/repos\/([^/]+\/[^/]+)$/)?.[1]
  return fromApi ?? item.html_url?.match(/github\.com\/([^/]+\/[^/]+)\//)?.[1] ?? ""
}

/** Turns one search response into items of `kind`. */
export function parseSearch(kind: Kind, body: unknown): Item[] {
  const items = (body as { items?: SearchItem[] } | null)?.items
  if (!Array.isArray(items)) return []
  const out: Item[] = []
  for (const s of items) {
    const repo = repoOf(s)
    if (!repo || typeof s.number !== "number" || !s.html_url) continue
    out.push({
      id: `github:${repo}#${s.number}`,
      source: "github",
      kind,
      title: s.title ?? `#${s.number}`,
      detail: `${repo.split("/")[1]} #${s.number}`,
      at: Date.parse(s.updated_at ?? "") || 0,
      unreadHint: true,
      mine: kind === "checksFailing",
      notifications: [],
      url: s.html_url,
      repo,
      number: s.number,
      author: s.user?.login ?? undefined
    })
  }
  return out
}

/** One item per pull request or issue; the more urgent reason wins. */
export function mergeGithub(lists: readonly Item[][]): Item[] {
  const byId = new Map<string, Item>()
  for (const item of lists.flat()) {
    const current = byId.get(item.id)
    if (!current || priority(item) < priority(current)) byId.set(item.id, item)
  }
  return [...byId.values()]
}

const codeOf = (e: unknown) => (e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : "")
const messageOf = (e: unknown) => (e instanceof Error ? e.message : String(e))

/** Runs every enabled query through the gateway. Missing scope or a missing gateway is a status, not an error. */
export async function fetchGithub(request: (path: string) => Promise<unknown>, options: GithubOptions, now: number): Promise<GithubResult> {
  const queries = githubQueries(options, now)
  if (queries.length === 0) return { status: "ok", items: [], errors: [] }
  const settled = await Promise.allSettled(queries.map((q) => request(searchPath(q.query)).then((body) => parseSearch(q.kind, body))))
  const lists: Item[][] = []
  const failures: unknown[] = []
  for (const s of settled) {
    if (s.status === "fulfilled") lists.push(s.value)
    else failures.push(s.reason)
  }
  if (lists.length === 0) {
    const codes = failures.map(codeOf)
    if (codes.every((c) => c === "scope.missing")) return { status: "notGranted", items: [], errors: [] }
    if (codes.every((c) => c === "operation.unsupported")) return { status: "unavailable", items: [], errors: [] }
    return { status: "error", items: [], errors: failures.map(messageOf) }
  }
  return { status: failures.length ? "partial" : "ok", items: mergeGithub(lists), errors: failures.map(messageOf) }
}

// Check details for one pull request.

export type CheckState = "fail" | "pending" | "pass" | "neutral"

export interface CheckSummary {
  state: CheckState
  failed: string[]
  counts: Record<"fail" | "pending" | "pass" | "cancel" | "skip", number>
}

interface CheckRun {
  name?: string
  status?: string
  conclusion?: string | null
}

const outcome = (run: CheckRun): keyof CheckSummary["counts"] => {
  if (run.status !== "completed") return "pending"
  switch (run.conclusion) {
    case "success":
      return "pass"
    case "failure":
    case "timed_out":
    case "action_required":
    case "startup_failure":
      return "fail"
    case "cancelled":
    case "stale":
      return "cancel"
    default:
      return "skip"
  }
}

/** Failure outranks pending, pending outranks cancel; passing needs at least one pass. */
export function summarizeChecks(runs: readonly CheckRun[]): CheckSummary {
  const counts = { fail: 0, pending: 0, pass: 0, cancel: 0, skip: 0 }
  const failed: string[] = []
  for (const run of runs) {
    const o = outcome(run)
    counts[o]++
    if (o === "fail" && run.name) failed.push(run.name)
  }
  const state: CheckState = counts.fail ? "fail" : counts.pending ? "pending" : counts.cancel ? "neutral" : counts.pass ? "pass" : "neutral"
  return { state, failed, counts }
}

/** Head commit, then its check runs: two GETs, only for the selected pull request. */
export async function loadChecks(request: (path: string) => Promise<unknown>, repo: string, number: number): Promise<CheckSummary> {
  const pull = (await request(`/repos/${repo}/pulls/${number}`)) as { head?: { sha?: string } }
  const sha = pull?.head?.sha
  if (!sha) return summarizeChecks([])
  const runs = (await request(`/repos/${repo}/commits/${sha}/check-runs?per_page=100`)) as { check_runs?: CheckRun[] }
  return summarizeChecks(runs?.check_runs ?? [])
}
