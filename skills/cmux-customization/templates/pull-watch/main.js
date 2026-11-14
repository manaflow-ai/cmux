// GitHub stays connected through cmux; no token belongs in this file.
function renderPulls() {
  const pulls = cmux.watch("github.pulls", { roles: ["author"] })
  const open = (pull) => cmux.actions.run("openBrowser", { url: pull.url }).catch((error) =>
    cmux.toast({ title: "Cannot open pull request", message: String(error), tone: "warning" })
  )
  return VStack([
    ForEach({ items: computed(() => pulls.value() || []), key: (pull) => pull.id }, (pull) =>
      Row({
        title: () => pull().title,
        subtitle: () => `${pull().repo} · PR ${pull().number}`,
        symbol: "arrow.triangle.pull",
        badge: () => pull().draft ? "Draft" : "Open"
      }).help(() => pull().url).onTap(() => open(pull()))
    ),
    () => pulls.status() === "loading" ? EmptyState({ title: "Reading pull requests…" }) : null,
    () => pulls.error() ? EmptyState({ title: "Cannot refresh pull requests", message: pulls.error().message }) : null,
    () => pulls.status() === "fresh" && !pulls.value()?.length ? EmptyState({ title: "No open pull requests", symbol: "checkmark.circle" }) : null,
    Button("Refresh", () => pulls.refresh())
  ])
}

globalThis.__cmuxAppExports = { renderPulls }
