/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Pull request card: a chat widget (cmux.chat.widget/1, plans/cmux-next/chat-widgets-DESIGN.md).
// An agent sends {type: "widget", app: "cmux/pr-card", props: {repo, number}, fallback}; cmux
// mounts this export with ctx.props and ctx.widget.key and draws the returned view natively in
// the chat bubble. The checks list pages 5 at a time; the page is kept in cmux.storage under the
// widget's key, so it survives scrolling away, a relaunch and a reload. While a check runs the
// card refreshes every 30 s, then every 5 minutes.

interface WidgetContext { props?: { repo?: string; number?: number | string }; widget?: { key?: string } }
interface PR { title: string; state: string; merged: boolean; draft: boolean; author: string; url: string; sha: string }
interface Check { id: number; name: string; status: string; conclusion: string | null; url: string }

const PAGE = 5

async function github<T>(path: string): Promise<T> {
  try {
    return (await cmux.integrations.github.request({ method: "GET", path })) as T
  } catch {
    // The public API answers public repositories without a token.
    const r = await cmux.net.fetch(`https://api.github.com${path}`, { headers: { Accept: "application/vnd.github+json" } })
    if (!r.ok) throw new Error(`GitHub answered ${r.status}`)
    return r.json<T>()
  }
}

/** Failures first, then running, then the rest; by name inside each. */
function rank(c: Check): number {
  if (c.status !== "completed") return 1
  return ["failure", "timed_out", "cancelled", "action_required"].includes(c.conclusion ?? "") ? 0 : 2
}

function checkLook(c: Check): { label: string; symbol: string; tint: string } {
  if (c.status !== "completed") return { label: "Running", symbol: "clock", tint: "warning" }
  switch (c.conclusion) {
    case "success": return { label: "Passed", symbol: "checkmark.circle", tint: "success" }
    case "skipped": case "neutral": return { label: "Skipped", symbol: "minus.circle", tint: "secondary" }
    default: return { label: "Failed", symbol: "xmark.circle", tint: "danger" }
  }
}

export function renderPRCard(context: WidgetContext = {}) {
  const repo = String(context.props?.repo ?? "").trim()
  const number = Number(context.props?.number)
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo) || !Number.isInteger(number) || number <= 0) {
    return EmptyState({ title: "No pull request", message: "This card needs props {repo, number}.", symbol: "exclamationmark.triangle" })
  }
  const pageKey = `page:${context.widget?.key ?? `${repo}#${number}`}`
  const [pr, setPR] = signal<PR | null>(null)
  const [checks, setChecks] = signal<Check[]>([])
  const [error, setError] = signal<string | null>(null)
  const [page, setPage] = signal(0)
  cmux.storage.get<number>(pageKey).then((saved) => { if (typeof saved === "number" && saved > 0) setPage(saved) })
  const turn = (by: number) => {
    const next = Math.max(0, Math.min(pages() - 1, page() + by))
    setPage(next)
    cmux.storage.set(pageKey, next)
  }

  let timer: number | null = null
  const load = async () => {
    try {
      const p = await github<Record<string, any>>(`/repos/${repo}/pulls/${number}`)
      const head = String(p.head?.sha ?? "")
      setPR({ title: p.title, state: p.state, merged: !!p.merged_at, draft: !!p.draft, author: p.user?.login ?? "", url: p.html_url, sha: head })
      const runs = head ? await github<{ check_runs: Array<Record<string, any>> }>(`/repos/${repo}/commits/${head}/check-runs?per_page=100`) : { check_runs: [] }
      const list = runs.check_runs.map((c) => ({ id: c.id, name: c.name, status: c.status, conclusion: c.conclusion, url: c.html_url }))
      setChecks(list.sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name)))
      setError(null)
      // Live while something runs, quiet after (a timer per mount, gone with it).
      const running = list.some((c) => c.status !== "completed")
      if (timer !== null) cmux.timer.clear(timer)
      timer = cmux.timer.every(running ? 30_000 : 300_000, load)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }
  load()

  const pages = computed(() => Math.max(1, Math.ceil(checks().length / PAGE)))
  const shown = computed(() => {
    const at = Math.min(page(), pages() - 1)
    return checks().slice(at * PAGE, at * PAGE + PAGE)
  })
  const summary = computed(() => {
    const list = checks()
    const failed = list.filter((c) => rank(c) === 0).length
    const running = list.filter((c) => rank(c) === 1).length
    const passed = list.length - failed - running
    if (!list.length) return { text: "No checks", tone: "secondary" }
    const parts = [failed && `${failed} failed`, running && `${running} running`, passed && `${passed} passed`].filter(Boolean)
    return { text: parts.join(" · "), tone: failed ? "danger" : running ? "warning" : "success" }
  })
  const stateText = () => {
    const p = pr()
    if (!p) return "Loading"
    return p.merged ? "Merged" : p.state === "closed" ? "Closed" : p.draft ? "Draft" : "Open"
  }

  return VStack({ spacing: 4 }, [
    Text(() => pr()?.title ?? `${repo} #${number}`).font("headline"),
    Row({
      title: `${repo} #${number}`,
      subtitle: () => [stateText(), pr()?.author].filter(Boolean).join(" · "),
      symbol: () => (pr()?.merged ? "checkmark.circle" : "arrow.triangle.pull"),
      tint: () => (pr()?.merged ? "accent" : pr()?.state === "closed" ? "secondary" : "success")
    }).onTap(() => { const p = pr(); if (p) cmux.actions.run("openBrowser", { url: p.url }) }),
    () => (error() ? EmptyState({ title: "Cannot load the pull request", message: error()!, symbol: "exclamationmark.triangle" }) : null),
    () => (pr() && !error() ? Badge(() => summary().text, () => summary().tone) : null),
    () => (checks().length ? Divider() : null),
    ForEach({ items: shown, key: (c) => c.id }, (c) =>
      Row({ title: () => c().name, subtitle: () => checkLook(c()).label, symbol: () => checkLook(c()).symbol, tint: () => checkLook(c()).tint })
        .onTap(() => cmux.actions.run("openBrowser", { url: c().url }))
    ),
    () => (pages() > 1 ? Text(() => `Page ${Math.min(page(), pages() - 1) + 1} of ${pages()}`).font("caption").color("secondary") : null),
    () => (pages() > 1
      ? HStack([
          Button("Previous", () => turn(-1)).disabled(() => page() <= 0),
          Button("Next", () => turn(1)).disabled(() => page() >= pages() - 1).background("accent")
        ])
      : null)
  ])
}
