const login = () => {
  const l = String(cmux.app.settings().login ?? "").trim()
  return l ? { login: l } : {}
}
const mine = () => ({ roles: ["author" as const], ...login() })
const recent = () => ({ roles: ["author" as const, "review-requested" as const, "assignee" as const], include: "open-and-merged" as const, updatedWithinHours: 24, limit: 50, ...login() })
const failure = (e: CmuxError | undefined) =>
  e?.code === "integration.unavailable" || e?.code === "scope.missing" ? "Set your GitHub login in Settings > Apps > GitHub PRs, or connect GitHub." : (e?.message ?? "")
export async function refresh() {
  const s = await cmux.watch.refresh("github.pulls", mine())
  return { count: s.value?.length ?? 0 }
}
export function renderPRs() {
  const prs = cmux.watch("github.pulls", mine)
  const visible = computed(() => (prs.value() ?? []).filter((p) => cmux.app.settings().showDrafts !== false || !p.draft))
  return VStack({ spacing: 2 }, [
    ForEach({ items: visible, key: (p) => p.id }, (p) =>
      Row({
        title: () => p().title,
        subtitle: () => `${p().repo} #${p().number}`,
        symbol: () => (p().draft ? "circle.dashed" : "arrow.triangle.pull"),
        tint: () => (p().draft ? "secondary" : "success")
      })
        .help(() => p().url)
        .onTap(() => cmux.actions.run("openBrowser", { url: p().url }))
        .contextMenu([Button("Open in Browser", () => cmux.actions.run("openBrowser", { url: p().url })), Divider(), Button("Refresh", () => prs.refresh())])
    ),
    () => (prs.status() === "error" ? EmptyState({ title: "Cannot load pull requests", message: failure(prs.error()), symbol: "exclamationmark.triangle" }) : null),
    () => (prs.status() === "fresh" && visible().length === 0 ? EmptyState({ title: "No open pull requests", symbol: "checkmark.circle" }) : null)
  ])
}
export function renderRecentPRs() {
  const prs = cmux.watch("github.pulls", recent)
  return VStack({ spacing: 2 }, [
    ForEach({ items: () => prs.value() ?? [], key: (p) => p.id }, (p) =>
      Row({
        title: () => p().title,
        subtitle: () => `${p().repo} #${p().number}${p().state === "merged" ? " · Merged" : ""}`,
        symbol: () => (p().state === "merged" ? "checkmark.circle" : p().draft ? "circle.dashed" : "arrow.triangle.pull"),
        tint: () => (p().state === "merged" ? "accent" : p().draft ? "secondary" : "success")
      })
        .help(() => p().url)
        .onTap(() => cmux.actions.run("openBrowser", { url: p().url }))
    ),
    () => (prs.status() === "error" ? EmptyState({ title: "Cannot load pull requests", message: failure(prs.error()), symbol: "exclamationmark.triangle" }) : null),
    () => (prs.status() === "fresh" && (prs.value() ?? []).length === 0 ? EmptyState({ title: "No pull requests in the last 24 hours", symbol: "clock" }) : null)
  ])
}
