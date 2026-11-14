// Pull requests waiting for your review, live through cmux.watch.
function params() {
  const login = String(cmux.app.settings().login || "").trim()
  return { roles: ["review-requested"], ...(login ? { login } : {}) }
}
function renderReviewRequests() {
  const prs = cmux.watch("github.pulls", params)
  const rows = computed(() => prs.value() || [])
  const open = (pr) => cmux.actions.run("openBrowser", { url: pr.url }).catch((e) => cmux.toast({ title: "Cannot open pull request", message: e instanceof Error ? e.message : String(e), tone: "warning" }))
  return VStack({ spacing: 2 }, [
    ForEach({ items: rows, key: (pr) => pr.id }, (pr) => Row({
      title: () => pr().title, subtitle: () => `${pr().repo} #${pr().number}`, symbol: "eye", tint: "warning"
    }).onTap(() => open(pr()))),
    () => prs.error() ? EmptyState({ title: "Cannot load reviews", message: prs.error().message, symbol: "exclamationmark.triangle" }) : null,
    () => prs.status() === "fresh" && !rows().length ? EmptyState({ title: "No reviews waiting", symbol: "checkmark.circle" }) : null
  ])
}
globalThis.__cmuxAppExports = { renderReviewRequests }
