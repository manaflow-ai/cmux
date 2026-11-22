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
    renderPRs: () => renderPRs
  });
  var [prs, setPRs] = signal(null);
  var [error, setError] = signal(null);
  var [loading, setLoading] = signal(false);
  var repoOf = (url) => url.replace("https://api.github.com/repos/", "");
  async function load() {
    const login = String(cmux.app.settings().login ?? "").trim();
    setLoading(true);
    try {
      let items;
      try {
        const r = await cmux.integrations.github.request({ method: "GET", path: "/search/issues?q=is:pr+is:open+author:@me&per_page=30" });
        items = r.items;
      } catch (e) {
        if (!login)
          throw new Error("Set your GitHub login in Settings > Apps > GitHub PRs, or connect GitHub.");
        const r = await cmux.net.fetch(`https://api.github.com/search/issues?q=is:pr+is:open+author:${encodeURIComponent(login)}&per_page=30`, { headers: { Accept: "application/vnd.github+json" } });
        if (!r.ok)
          throw new Error(`GitHub answered ${r.status}`);
        items = r.json().items;
      }
      const list = items.map((i) => ({ id: i.id, number: i.number, title: i.title, html_url: i.html_url, draft: !!i.draft, repo: repoOf(i.repository_url), updated_at: i.updated_at }));
      setPRs(list);
      setError(null);
      return list.length;
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      return 0;
    } finally {
      setLoading(false);
    }
  }
  async function refresh() {
    return { count: await load() };
  }
  function renderPRs() {
    load();
    cmux.timer.every(5 * 60000, load);
    const visible = computed(() => (prs() ?? []).filter((p) => cmux.app.settings().showDrafts !== false || !p.draft));
    return VStack({ spacing: 2 }, [
      ForEach({ items: visible, key: (p) => p.id }, (p) => Row({
        title: () => p().title,
        subtitle: () => `${p().repo} #${p().number}`,
        symbol: () => p().draft ? "circle.dashed" : "arrow.triangle.pull",
        tint: () => p().draft ? "secondary" : "success"
      }).help(() => p().html_url).onTap(() => cmux.actions.run("openBrowser", { url: p().html_url })).contextMenu([Button("Open in Browser", () => cmux.actions.run("openBrowser", { url: p().html_url })), Divider(), Button("Refresh", () => load())])),
      () => error() ? EmptyState({ title: "Cannot load pull requests", message: error(), symbol: "exclamationmark.triangle" }) : null,
      () => !error() && !loading() && prs() && visible().length === 0 ? EmptyState({ title: "No open pull requests", symbol: "checkmark.circle" }) : null
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
