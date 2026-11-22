// Recent PRs: the pull requests you touched lately, open and merged, newest first, in a sidebar
// section. It imports nothing but the public SDK.
// - cmux.watch("github.pulls") does the reading: through your connected GitHub account, one read
//   however many windows show the section, re-read in the background, the last list kept while
//   it does. Nothing here polls.
// - How far back it looks is a setting (Settings > Apps > Recent PRs), as is a GitHub login for
//   the public fallback when no account is connected.
// - A click opens the pull request in a cmux browser tab.

import { Button, cmux, computed, EmptyState, ForEach, Row, VStack, type View } from "cmux-extension-sdk"

type Pull = CmuxSignalMap["github.pulls"]["value"][number]

export function params() {
  const s = cmux.app.settings()
  const hours = Number(s.hours)
  const login = String(s.login ?? "").trim()
  return {
    roles: ["author" as const, "review-requested" as const, "assignee" as const],
    include: "open-and-merged" as const,
    updatedWithinHours: Number.isFinite(hours) && hours > 0 ? hours : 72,
    limit: 20,
    ...(login ? { login } : {})
  }
}

export function ago(iso: string, now = Date.now()): string {
  const minutes = Math.max(0, Math.round((now - Date.parse(iso)) / 60_000))
  if (minutes < 1) return "just now"
  if (minutes < 60) return `${minutes} min ago`
  const hours = Math.round(minutes / 60)
  return hours < 48 ? `${hours} h ago` : `${Math.round(hours / 24)} d ago`
}

const state = (p: Pull) => (p.state === "merged" ? "Merged" : p.draft ? "Draft" : p.roles.includes("review-requested") ? "Review" : "Open")
const symbolOf = (p: Pull) => (p.state === "merged" ? "arrow.triangle.merge" : p.draft ? "circle.dashed" : p.roles.includes("review-requested") ? "eye" : "arrow.triangle.pull")
const toneOf = (p: Pull) => (p.state === "merged" ? cmux.theme.accent : p.draft ? cmux.theme.text.secondary : p.roles.includes("review-requested") ? cmux.theme.warning : cmux.theme.success)

function problem(e: CmuxError | undefined): string {
  if (e?.code === "integration.not_connected" || e?.code === "integration.unavailable" || e?.code === "scope.missing") {
    return "Connect GitHub in Settings > Integrations, or set a GitHub login in this extension's settings."
  }
  return e?.message ?? "Unknown error"
}

function open(p: Pull) {
  cmux.actions.run("openBrowser", { url: p.url }).catch((e: unknown) => cmux.toast({ title: "Couldn't open the pull request", message: e instanceof Error ? e.message : String(e), tone: "warning" }))
}

export function renderRecentPRs(): View {
  const prs = cmux.watch("github.pulls", params)
  // One row per pull request (a PR can be yours and assigned to you), newest change first.
  const rows = computed(() => {
    const seen = new Map<number, Pull>()
    for (const p of prs.value() ?? []) if (!seen.has(p.id)) seen.set(p.id, p)
    return [...seen.values()].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
  })
  const failing = () => prs.status() === "stale" && prs.error() !== undefined
  return VStack({ spacing: 2 }, [
    () => (failing() ? Row({ title: "Couldn't refresh", subtitle: problem(prs.error()), symbol: "exclamationmark.triangle", tint: cmux.theme.warning }).onTap(() => prs.refresh()) : null),
    ForEach({ items: rows, key: (p) => p.id }, (p) =>
      Row({
        title: () => p().title,
        subtitle: () => `${p().repo} #${p().number} · ${state(p())} · ${ago(p().updatedAt)}`,
        symbol: () => symbolOf(p()),
        tint: () => toneOf(p())
      })
        .opacity(() => (failing() ? 0.6 : 1))
        .help(() => `${p().title}\n${p().url}`)
        .onTap(() => open(p()))
        .contextMenu([Button("Open in Browser", () => open(p())), Button("Refresh", () => prs.refresh())])
    ),
    () => (prs.status() === "loading" ? EmptyState({ title: "Reading your pull requests…", symbol: "arrow.triangle.pull" }) : null),
    () => (prs.status() === "error" ? EmptyState({ title: "Can't read pull requests", message: problem(prs.error()), symbol: "exclamationmark.triangle" }) : null),
    () => (prs.status() === "fresh" && rows().length === 0 ? EmptyState({ title: "No pull requests lately", message: `Nothing changed in the last ${params().updatedWithinHours} hours.`, symbol: "checkmark.circle" }) : null)
  ])
}
