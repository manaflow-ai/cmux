/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// GitHub PRs: the signed-in user's open pull requests, and the PRs that involve
// them from the last 24 hours, as sidebar sections.
// Both read the `github.pulls` signal (cmux.watch): the runtime reads it through
// cmux.integrations.github (the token stays in the gateway), else the public search
// API for the login in the app's settings, shares one read per section's params,
// polls behind it, and stops when the section is gone. No timers here.

// The fallback login is a setting; passing params as a function moves the watch when it changes.
const login = () => {
  const l = String(cmux.app.settings().login ?? "").trim()
  return l ? { login: l } : {}
}
const mine = () => ({ roles: ["author" as const], ...login() })
// PRs created or updated in the last 24 hours where the person is the author, a requested
// reviewer or an assignee; open and merged (closed unmerged ones are left out), newest first.
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
