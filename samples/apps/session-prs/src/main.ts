/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Session PRs: a Session Info section listing the pull requests whose head branch is the chat's
// branch. The host passes the mount context to the render export: {session_id, cwd, branch?, harness?}.
// A script cannot read the git remote, so the branch name is searched across GitHub (`head:<branch>`).

interface SessionContext { session_id?: string; cwd?: string; branch?: string; harness?: string }
interface PR { id: number; number: number; title: string; html_url: string; repo: string; open: boolean; merged: boolean; draft: boolean; updated_at: string }

const repoOf = (url: string) => url.replace("https://api.github.com/repos/", "")

async function search(query: string): Promise<Array<Record<string, any>>> {
  const path = `/search/issues?q=${encodeURIComponent(query)}&per_page=30`
  try {
    const r = (await cmux.integrations.github.request({ method: "GET", path })) as { items: Array<Record<string, any>> }
    return r.items
  } catch (e) {
    // The public API answers the same search for public repositories without a token.
    const r = await cmux.net.fetch(`https://api.github.com${path}`, { headers: { Accept: "application/vnd.github+json" } })
    if (!r.ok) throw new Error(`GitHub answered ${r.status}`)
    return r.json<{ items: Array<Record<string, any>> }>().items
  }
}

export function renderSessionPRs(context: SessionContext = {}) {
  const branch = String(context.branch ?? "").trim()
  if (!branch) return EmptyState({ title: "No branch for this chat", symbol: "arrow.triangle.branch" })
  // Each mount (one per chat) keeps its own rows.
  const [prs, setPRs] = signal<PR[] | null>(null)
  const [error, setError] = signal<string | null>(null)
  const load = async () => {
    try {
      const items = await search(`is:pr head:${branch}`)
      setPRs(
        items
          .map((i) => ({ id: i.id, number: i.number, title: i.title, html_url: i.html_url, repo: repoOf(i.repository_url), open: i.state === "open", merged: !!i.pull_request?.merged_at, draft: !!i.draft, updated_at: i.updated_at }))
          .sort((a, b) => b.updated_at.localeCompare(a.updated_at))
      )
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }
  load()
  cmux.timer.every(5 * 60_000, load)
  const visible = computed(() => prs() ?? [])
  return VStack({ spacing: 2 }, [
    ForEach({ items: visible, key: (p) => p.id }, (p) =>
      Row({
        title: () => p().title,
        subtitle: () => `${p().repo} #${p().number} · ${p().merged ? "Merged" : p().open ? (p().draft ? "Draft" : "Open") : "Closed"}`,
        symbol: () => (p().merged ? "checkmark.circle" : p().open ? "arrow.triangle.pull" : "xmark.circle"),
        tint: () => (p().merged ? "accent" : p().open && !p().draft ? "success" : "secondary")
      })
        .help(() => p().html_url)
        .onTap(() => cmux.actions.run("openBrowser", { url: p().html_url }))
    ),
    () => (error() ? EmptyState({ title: "Cannot load pull requests", message: error()!, symbol: "exclamationmark.triangle" }) : null),
    () => (!error() && prs() && visible().length === 0 ? EmptyState({ title: `No pull requests for ${branch}`, symbol: "checkmark.circle" }) : null)
  ])
}
