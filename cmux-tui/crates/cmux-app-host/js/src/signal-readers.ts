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

export const READERS: Record<string, Reader> = { "github.pulls": githubPulls }
