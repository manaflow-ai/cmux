/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// GitHub PRs: the signed-in user's open pull requests, and the PRs that involve
// them from the last 24 hours, as sidebar sections.
// Credentialed path: cmux.integrations.github (the token stays in the gateway).
// Fallback: the public search API for the login in the app's settings.

interface PR { id: number; number: number; title: string; html_url: string; draft: boolean; repo: string; updated_at: string }

const [prs, setPRs] = signal<PR[] | null>(null)
const [error, setError] = signal<string | null>(null)
const [loading, setLoading] = signal(false)
const [recent, setRecent] = signal<Array<PR & { merged: boolean; open: boolean }> | null>(null)
const [recentError, setRecentError] = signal<string | null>(null)

const repoOf = (url: string) => url.replace("https://api.github.com/repos/", "")

async function load(): Promise<number> {
  const login = String(cmux.app.settings().login ?? "").trim()
  setLoading(true)
  try {
    let items: Array<Record<string, any>>
    try {
      const r = (await cmux.integrations.github.request({ method: "GET", path: "/search/issues?q=is:pr+is:open+author:@me&per_page=30" })) as { items: Array<Record<string, any>> }
      items = r.items
    } catch (e) {
      if (!login) throw new Error("Set your GitHub login in Settings > Apps > GitHub PRs, or connect GitHub.")
      const r = await cmux.net.fetch(`https://api.github.com/search/issues?q=is:pr+is:open+author:${encodeURIComponent(login)}&per_page=30`, { headers: { Accept: "application/vnd.github+json" } })
      if (!r.ok) throw new Error(`GitHub answered ${r.status}`)
      items = r.json<{ items: Array<Record<string, any>> }>().items
    }
    const list = items.map((i) => ({ id: i.id, number: i.number, title: i.title, html_url: i.html_url, draft: !!i.draft, repo: repoOf(i.repository_url), updated_at: i.updated_at }))
    setPRs(list)
    setError(null)
    return list.length
  } catch (e) {
    setError(e instanceof Error ? e.message : String(e))
    return 0
  } finally {
    setLoading(false)
  }
}

// One search, `who` filled in: "@me" through the integration, else the login setting.
async function search(query: (who: string) => string): Promise<Array<Record<string, any>>> {
  const login = String(cmux.app.settings().login ?? "").trim()
  try {
    const r = (await cmux.integrations.github.request({ method: "GET", path: `/search/issues?q=${encodeURIComponent(query("@me"))}&per_page=50` })) as { items: Array<Record<string, any>> }
    return r.items
  } catch (e) {
    if (!login) throw new Error("Set your GitHub login in Settings > Apps > GitHub PRs, or connect GitHub.")
    const r = await cmux.net.fetch(`https://api.github.com/search/issues?q=${encodeURIComponent(query(login))}&per_page=50`, { headers: { Accept: "application/vnd.github+json" } })
    if (!r.ok) throw new Error(`GitHub answered ${r.status}`)
    return r.json<{ items: Array<Record<string, any>> }>().items
  }
}

// PRs created or updated in the last 24 hours where the person is the author, a requested
// reviewer or an assignee; open and merged (closed unmerged ones are left out), newest first.
// The search API has no OR across these qualifiers, so it is three searches merged by id.
async function loadRecent() {
  const since = new Date(Date.now() - 24 * 60 * 60_000).toISOString().slice(0, 19) + "Z"
  try {
    const batches = await Promise.all(
      ["author", "review-requested", "assignee"].map((role) => search((who) => `is:pr ${role}:${who} updated:>=${since}`))
    )
    const byId = new Map<number, PR & { merged: boolean; open: boolean }>()
    for (const i of batches.flat()) {
      const merged = !!i.pull_request?.merged_at
      if (i.state !== "open" && !merged) continue
      byId.set(i.id, { id: i.id, number: i.number, title: i.title, html_url: i.html_url, draft: !!i.draft, repo: repoOf(i.repository_url), updated_at: i.updated_at, merged, open: i.state === "open" })
    }
    setRecent([...byId.values()].sort((a, b) => b.updated_at.localeCompare(a.updated_at)))
    setRecentError(null)
  } catch (e) {
    setRecentError(e instanceof Error ? e.message : String(e))
  }
}

export async function refresh() {
  return { count: await load() }
}

export function renderPRs() {
  load()
  cmux.timer.every(5 * 60_000, load)
  const visible = computed(() => (prs() ?? []).filter((p) => cmux.app.settings().showDrafts !== false || !p.draft))
  return VStack({ spacing: 2 }, [
    ForEach({ items: visible, key: (p) => p.id }, (p) =>
      Row({
        title: () => p().title,
        subtitle: () => `${p().repo} #${p().number}`,
        symbol: () => (p().draft ? "circle.dashed" : "arrow.triangle.pull"),
        tint: () => (p().draft ? "secondary" : "success")
      })
        .help(() => p().html_url)
        .onTap(() => cmux.actions.run("openBrowser", { url: p().html_url }))
        .contextMenu([Button("Open in Browser", () => cmux.actions.run("openBrowser", { url: p().html_url })), Divider(), Button("Refresh", () => load())])
    ),
    () => (error() ? EmptyState({ title: "Cannot load pull requests", message: error()!, symbol: "exclamationmark.triangle" }) : null),
    () => (!error() && !loading() && prs() && visible().length === 0 ? EmptyState({ title: "No open pull requests", symbol: "checkmark.circle" }) : null)
  ])
}

export function renderRecentPRs() {
  loadRecent()
  cmux.timer.every(5 * 60_000, loadRecent)
  const visible = computed(() => recent() ?? [])
  return VStack({ spacing: 2 }, [
    ForEach({ items: visible, key: (p) => p.id }, (p) =>
      Row({
        title: () => p().title,
        subtitle: () => `${p().repo} #${p().number}${p().merged ? " · Merged" : ""}`,
        symbol: () => (p().merged ? "checkmark.circle" : p().draft ? "circle.dashed" : "arrow.triangle.pull"),
        tint: () => (p().merged ? "accent" : p().draft ? "secondary" : "success")
      })
        .help(() => p().html_url)
        .onTap(() => cmux.actions.run("openBrowser", { url: p().html_url }))
    ),
    () => (recentError() ? EmptyState({ title: "Cannot load pull requests", message: recentError()!, symbol: "exclamationmark.triangle" }) : null),
    () => (!recentError() && recent() && visible().length === 0 ? EmptyState({ title: "No pull requests in the last 24 hours", symbol: "clock" }) : null)
  ])
}
