// In Session Info, use that chat's folder. In the sidebar, follow the focused tab.
function renderBranch(context) {
  const params = context?.cwd ? { path: context.cwd } : {}
  const branch = cmux.live("git.status", params, { events: ["git.changed", "workspace.changed", "tab.changed"] })
  return VStack([
    () => branch() ? Row({
      title: () => branch().branch || "Detached HEAD",
      subtitle: () => `${branch().ahead} ahead · ${branch().behind} behind`,
      symbol: "arrow.triangle.branch"
    }).help(() => branch().root) : null,
    () => branch.loading() && !branch() ? EmptyState({ title: "Reading branch…" }) : null,
    () => branch.error() ? EmptyState({ title: "Cannot read this repository", message: branch.error().message }) : null,
    Button("Refresh", () => branch.refresh())
  ])
}

globalThis.__cmuxAppExports = { renderBranch }
