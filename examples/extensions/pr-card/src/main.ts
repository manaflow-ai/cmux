// PR card: an example chat widget that imports nothing but the public SDK.
// - A chat widget (cmux.chat.widget/1): when an agent calls a GitHub pull request tool (the
//   manifest's options.tools), cmux draws this card under the call. It reads {owner, repo,
//   pullNumber} from the call's input, or {repo: "owner/name", number} from a widget part's props,
//   and shows the pull request's state and its checks, five a page. The page is kept in
//   cmux.storage under the widget's key, so it survives scrolling away, a reload and a relaunch.
// - A sidebar section (cmux.section/1): the pull requests the cards showed, newest first.
// cmux ships no widgets of its own; this is one you install (`cmux ext dev` in this folder).

import {
  Badge, Button, chatWidget, cmux, computed, Divider, EmptyState, ForEach, HStack, Row, section, signal, Text, VStack,
  type ChatWidgetContext
} from "cmux-extension-sdk"

interface PR { title: string; state: string; merged: boolean; draft: boolean; author: string; url: string; sha: string }
interface Check { id: number; name: string; status: string; conclusion: string | null; url: string }
interface Seen { repo: string; number: number; title: string; url: string }

const PAGE = 5
const SEEN_KEY = "seen"

/** The pull request a card is for: the call's input (GitHub's MCP tools) or the part's props. */
export function target(context: ChatWidgetContext): { repo: string; number: number } | null {
  const input = (context.tool?.input ?? {}) as Record<string, unknown>
  const props = (context.props ?? {}) as Record<string, unknown>
  const repo = input.owner && input.repo ? `${input.owner}/${input.repo}` : String(props.repo ?? "")
  const number = Number(input.pullNumber ?? input.pull_number ?? props.number)
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo) || !Number.isInteger(number) || number <= 0) return null
  return { repo, number }
}

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

/** Failures first, then running, then the rest. */
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

// The pull requests the cards showed: one list for every card and the section (one app host).
const [seen, setSeen] = signal<Seen[]>([])
let seenLoaded = false
function loadSeen() {
  if (seenLoaded) return
  seenLoaded = true
  cmux.storage.get<Seen[]>(SEEN_KEY).then((saved) => { if (Array.isArray(saved)) setSeen(saved) })
}
function remember(entry: Seen) {
  const next = [entry, ...seen().filter((s) => s.url !== entry.url)].slice(0, 20)
  setSeen(next)
  cmux.storage.set(SEEN_KEY, next)
}

export const renderCard = chatWidget((context) => {
  loadSeen()
  const at = target(context)
  if (!at) {
    return EmptyState({ title: "No pull request", message: "This card needs a pull request: {owner, repo, pullNumber}.", symbol: "exclamationmark.triangle" })
  }
  const { repo, number } = at
  const pageKey = `page:${context.widget.key}`
  const [pr, setPR] = signal<PR | null>(null)
  const [checks, setChecks] = signal<Check[]>([])
  const [error, setError] = signal<string | null>(null)
  const [page, setPage] = signal(0)
  cmux.storage.get<number>(pageKey).then((saved) => { if (typeof saved === "number" && saved > 0) setPage(saved) })
  const pages = computed(() => Math.max(1, Math.ceil(checks().length / PAGE)))
  const turn = (by: number) => {
    const next = Math.max(0, Math.min(pages() - 1, page() + by))
    setPage(next)
    cmux.storage.set(pageKey, next)
  }

  const load = async () => {
    try {
      const p = await github<Record<string, any>>(`/repos/${repo}/pulls/${number}`)
      const head = String(p.head?.sha ?? "")
      setPR({ title: p.title, state: p.state, merged: !!p.merged_at, draft: !!p.draft, author: p.user?.login ?? "", url: p.html_url, sha: head })
      remember({ repo, number, title: p.title, url: p.html_url })
      const runs = head ? await github<{ check_runs: Array<Record<string, any>> }>(`/repos/${repo}/commits/${head}/check-runs?per_page=100`) : { check_runs: [] }
      const list = runs.check_runs.map((c) => ({ id: c.id, name: c.name, status: c.status, conclusion: c.conclusion, url: c.html_url }))
      setChecks(list.sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name)))
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }
  load()

  const shown = computed(() => {
    const from = Math.min(page(), pages() - 1) * PAGE
    return checks().slice(from, from + PAGE)
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
    () => (error() ? EmptyState({ title: "Can't load the pull request", message: error()!, symbol: "exclamationmark.triangle" }) : null),
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
          Button("Next", () => turn(1)).disabled(() => page() >= pages() - 1)
        ])
      : null)
  ])
})

export const renderSection = section(() => {
  loadSeen()
  return VStack({ spacing: 2 }, [
    ForEach({ items: seen, key: (s) => s.url }, (s) =>
      Row({ title: () => s().title, subtitle: () => `${s().repo} #${s().number}`, symbol: "arrow.triangle.pull" })
        .onTap(() => cmux.actions.run("openBrowser", { url: s().url }))
    ),
    () => (seen().length ? null : EmptyState({ title: "No cards yet", message: "Pull requests an agent reads show here.", symbol: "arrow.triangle.pull" }))
  ])
})
