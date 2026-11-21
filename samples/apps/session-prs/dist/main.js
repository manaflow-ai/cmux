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
    renderSessionPRs: () => renderSessionPRs
  });
  var repoOf = (url) => url.replace("https://api.github.com/repos/", "");
  async function search(query) {
    const path = `/search/issues?q=${encodeURIComponent(query)}&per_page=30`;
    try {
      const r = await cmux.integrations.github.request({ method: "GET", path });
      return r.items;
    } catch (e) {
      const r = await cmux.net.fetch(`https://api.github.com${path}`, { headers: { Accept: "application/vnd.github+json" } });
      if (!r.ok)
        throw new Error(`GitHub answered ${r.status}`);
      return r.json().items;
    }
  }
  function renderSessionPRs(context = {}) {
    const branch = String(context.branch ?? "").trim();
    if (!branch)
      return EmptyState({ title: "No branch for this chat", symbol: "arrow.triangle.branch" });
    const [prs, setPRs] = signal(null);
    const [error, setError] = signal(null);
    const load = async () => {
      try {
        const items = await search(`is:pr head:${branch}`);
        setPRs(items.map((i) => ({ id: i.id, number: i.number, title: i.title, html_url: i.html_url, repo: repoOf(i.repository_url), open: i.state === "open", merged: !!i.pull_request?.merged_at, draft: !!i.draft, updated_at: i.updated_at })).sort((a, b) => b.updated_at.localeCompare(a.updated_at)));
        setError(null);
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      }
    };
    load();
    cmux.timer.every(5 * 60000, load);
    const visible = computed(() => prs() ?? []);
    return VStack({ spacing: 2 }, [
      ForEach({ items: visible, key: (p) => p.id }, (p) => Row({
        title: () => p().title,
        subtitle: () => `${p().repo} #${p().number} · ${p().merged ? "Merged" : p().open ? p().draft ? "Draft" : "Open" : "Closed"}`,
        symbol: () => p().merged ? "checkmark.circle" : p().open ? "arrow.triangle.pull" : "xmark.circle",
        tint: () => p().merged ? "accent" : p().open && !p().draft ? "success" : "secondary"
      }).help(() => p().html_url).onTap(() => cmux.actions.run("openBrowser", { url: p().html_url }))),
      () => error() ? EmptyState({ title: "Cannot load pull requests", message: error(), symbol: "exclamationmark.triangle" }) : null,
      () => !error() && prs() && visible().length === 0 ? EmptyState({ title: `No pull requests for ${branch}`, symbol: "checkmark.circle" }) : null
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
