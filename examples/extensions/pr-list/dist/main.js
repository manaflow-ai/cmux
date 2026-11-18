// Built by cmux app pack from src/main.ts. Do not edit.
(() => {
  var __defProp = Object.defineProperty;
  var __returnValue = (v) => v;
  function __exportSetter(name, newValue) {
    this[name] = __returnValue.bind(null, newValue);
  }
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, {
        get: all[name],
        enumerable: true,
        configurable: true,
        set: __exportSetter.bind(all, name)
      });
  };
  var exports_main = {};
  __export(exports_main, {
    refresh: () => refresh,
    renderPullRequests: () => renderPullRequests
  });
  var params = () => {
    const login = String(cmux.app.settings().login ?? "").trim();
    return { roles: ["review-requested", "author"], ...login ? { login } : {} };
  };
  var reviewing = (p) => p.roles.includes("review-requested");
  var order = (a, b) => Number(reviewing(b)) - Number(reviewing(a)) || b.updatedAt.localeCompare(a.updatedAt);
  var symbolOf = (p) => reviewing(p) ? "eye" : p.draft ? "circle.dashed" : "arrow.triangle.pull";
  var toneOf = (p) => reviewing(p) ? cmux.theme.warning : p.draft ? cmux.theme.text.secondary : cmux.theme.success;
  var subtitleOf = (p) => `${p.repo} #${p.number}${p.draft ? " · Draft" : ""}`;
  var ago = (t) => {
    if (t === null)
      return "";
    const minutes = Math.round((Date.now() - t) / 60000);
    return minutes < 1 ? "just now" : minutes < 60 ? `${minutes} min ago` : `${Math.round(minutes / 60)} h ago`;
  };
  var problem = (e) => e?.code === "integration.unavailable" || e?.code === "scope.missing" ? "Connect GitHub in Settings > Integrations, or set a GitHub login in this extension's settings." : e?.message ?? "Unknown error";
  var open = (p) => cmux.actions.run("openBrowser", { url: p.url });
  async function refresh() {
    const s = await cmux.watch.refresh("github.pulls", params());
    return { count: s.value?.length ?? 0, status: s.status };
  }
  function renderPullRequests() {
    const prs = cmux.watch("github.pulls", params);
    const rows = computed(() => (prs.value() ?? []).filter((p) => cmux.app.settings().showDrafts !== false || !p.draft).slice().sort(order));
    const failing = () => prs.status() === "stale" && prs.error() !== undefined;
    return VStack({ spacing: 2 }, [
      () => failing() ? Row({ title: "Couldn't refresh", subtitle: () => `${problem(prs.error())} Updated ${ago(prs.updatedAt())}.`, symbol: "exclamationmark.triangle", tint: cmux.theme.warning }).help("Click to try again").onTap(() => prs.refresh()) : null,
      () => prs.status() === "loading" ? Row({ title: "Loading pull requests…", symbol: "arrow.triangle.2.circlepath", tint: cmux.theme.text.secondary }) : null,
      ForEach({ items: rows, key: (p) => p.id }, (p) => Row({
        title: () => p().title,
        subtitle: () => subtitleOf(p()),
        symbol: () => symbolOf(p()),
        tint: () => toneOf(p()),
        badge: () => reviewing(p()) ? "Review" : null
      }).opacity(() => failing() ? 0.6 : 1).help(() => `${p().title}
${p().url}`).onTap(() => open(p())).contextMenu([Button("Open in Browser", () => open(p())), Divider(), Button("Refresh", () => prs.refresh())])),
      () => prs.status() === "error" ? EmptyState({ title: "Can't load pull requests", message: problem(prs.error()), symbol: "exclamationmark.triangle" }) : null,
      () => prs.status() === "fresh" && rows().length === 0 ? EmptyState({ title: "Nothing open, nothing to review", symbol: "checkmark.circle" }) : null
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
