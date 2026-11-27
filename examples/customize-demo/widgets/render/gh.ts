// GitHub REST answers for the fixture PRs, shaped as github.changes reads them.
export function gh(path: string): unknown {
  const pulls: Record<number, any> = {
    46900: { id: 1, number: 46900, title: "Widgets: clock, agents, usage and PR cards", html_url: "https://github.com/o/cmux/pull/46900", state: "open", user: { login: "me" }, head: { ref: "lane/widgets", sha: "aaa" }, additions: 420, deletions: 12, updated_at: "2026-11-19T10:00:00Z", requested_reviewers: [{}] },
    46880: { id: 2, number: 46880, title: "Glass sidebar cards", html_url: "https://github.com/o/cmux/pull/46880", state: "open", user: { login: "me" }, head: { ref: "lane/glass", sha: "bbb" }, additions: 88, deletions: 40, updated_at: "2026-11-19T09:00:00Z" },
    46861: { id: 3, number: 46861, title: "Studio theme pack", html_url: "https://github.com/o/cmux/pull/46861", state: "open", user: { login: "me" }, head: { ref: "lane/studio", sha: "ccc" }, additions: 210, deletions: 3, updated_at: "2026-11-19T08:00:00Z" }
  }
  if (path.startsWith("/search/issues")) {
    const q = decodeURIComponent(path)
    const nums = q.includes("head:lane/widgets") ? [46900] : [46900, 46880, 46861]
    return { items: nums.map((n) => ({ number: n, state: "open", repository_url: "https://api.github.com/repos/o/cmux" })) }
  }
  const m = /\/repos\/o\/cmux\/pulls\/(\d+)(\/reviews)?/.exec(path)
  if (m && m[2]) return Number(m[1]) === 46880 ? [{ user: { login: "r" }, state: "CHANGES_REQUESTED" }] : Number(m[1]) === 46861 ? [{ user: { login: "r" }, state: "APPROVED" }] : []
  if (m) return pulls[Number(m[1])]
  const runs = (pass: number, fail: number, pend: number) => ({ check_runs: [...Array(pass).fill({ status: "completed", conclusion: "success" }), ...Array(fail).fill({ status: "completed", conclusion: "failure" }), ...Array(pend).fill({ status: "in_progress" })] })
  if (path.includes("/commits/aaa/check-runs")) return runs(17, 0, 3)
  if (path.includes("/commits/bbb/check-runs")) return runs(22, 1, 0)
  if (path.includes("/commits/ccc/check-runs")) return runs(24, 0, 0)
  if (path.includes("/status")) return { statuses: [] }
  return null
}
