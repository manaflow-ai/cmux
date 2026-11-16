/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// PR List: an example extension. One sidebar section (cmux.section/1) with your open pull
// requests and the ones waiting for your review, live from cmux.watch("github.pulls").
// The runtime does the reading: one read however many windows show the section, polling
// behind the signal (nothing pushes GitHub changes yet), the last value kept while it
// re-reads, backoff on errors, and nothing left running once the section is gone.

type Pull = CmuxSignalMap["github.pulls"]["value"][number]

// The public-search fallback login is a setting; params as a function follow it.
const params = () => {
  const login = String(cmux.app.settings().login ?? "").trim()
  return { roles: ["review-requested" as const, "author" as const], ...(login ? { login } : {}) }
}

const reviewing = (p: Pull) => p.roles.includes("review-requested")
// Waiting for your review first, then yours; newest first within each.
const order = (a: Pull, b: Pull) => Number(reviewing(b)) - Number(reviewing(a)) || b.updatedAt.localeCompare(a.updatedAt)

const symbolOf = (p: Pull) => (reviewing(p) ? "eye" : p.draft ? "circle.dashed" : "arrow.triangle.pull")
const toneOf = (p: Pull) => (reviewing(p) ? cmux.theme.warning : p.draft ? cmux.theme.text.secondary : cmux.theme.success)
const subtitleOf = (p: Pull) => `${p.repo} #${p.number}${p.draft ? " · Draft" : ""}`

const ago = (t: number | null) => {
  if (t === null) return ""
  const minutes = Math.round((Date.now() - t) / 60_000)
  return minutes < 1 ? "just now" : minutes < 60 ? `${minutes} min ago` : `${Math.round(minutes / 60)} h ago`
}

const problem = (e: CmuxError | undefined) =>
  e?.code === "integration.unavailable" || e?.code === "scope.missing" ? "Connect GitHub in Settings > Integrations, or set a GitHub login in this extension's settings." : (e?.message ?? "Unknown error")

const open = (p: Pull) => cmux.actions.run("openBrowser", { url: p.url })

/** The Refresh command (catalog.json `local.pr_list.refresh`, in the palette as "PR List: Refresh"). */
export async function refresh() {
  const s = await cmux.watch.refresh("github.pulls", params())
  return { count: s.value?.length ?? 0, status: s.status }
}

export function renderPullRequests() {
  const prs = cmux.watch("github.pulls", params)
  const rows = computed(() => (prs.value() ?? []).filter((p) => cmux.app.settings().showDrafts !== false || !p.draft).slice().sort(order))
  // Stale with an error: the last list stays, dimmed, under a row that says why and retries on click.
  const failing = () => prs.status() === "stale" && prs.error() !== undefined
  return VStack({ spacing: 2 }, [
    () =>
      failing()
        ? Row({ title: "Couldn't refresh", subtitle: () => `${problem(prs.error())} Updated ${ago(prs.updatedAt())}.`, symbol: "exclamationmark.triangle", tint: cmux.theme.warning })
            .help("Click to try again")
            .onTap(() => prs.refresh())
        : null,
    () => (prs.status() === "loading" ? Row({ title: "Loading pull requests…", symbol: "arrow.triangle.2.circlepath", tint: cmux.theme.text.secondary }) : null),
    ForEach({ items: rows, key: (p) => p.id }, (p) =>
      Row({
        title: () => p().title,
        subtitle: () => subtitleOf(p()),
        symbol: () => symbolOf(p()),
        tint: () => toneOf(p()),
        badge: () => (reviewing(p()) ? "Review" : null)
      })
        .opacity(() => (failing() ? 0.6 : 1))
        .help(() => `${p().title}\n${p().url}`)
        .onTap(() => open(p()))
        .contextMenu([Button("Open in Browser", () => open(p())), Divider(), Button("Refresh", () => prs.refresh())])
    ),
    () => (prs.status() === "error" ? EmptyState({ title: "Can't load pull requests", message: problem(prs.error()), symbol: "exclamationmark.triangle" }) : null),
    () => (prs.status() === "fresh" && rows().length === 0 ? EmptyState({ title: "Nothing open, nothing to review", symbol: "checkmark.circle" }) : null)
  ])
}
