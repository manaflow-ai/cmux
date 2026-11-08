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
    renderPRs: () => renderPRs,
    renderRecentPRs: () => renderRecentPRs
  });
  var [prs, setPRs] = signal(null);
  var [error, setError] = signal(null);
  var [loading, setLoading] = signal(false);
  var [recent, setRecent] = signal(null);
  var [recentError, setRecentError] = signal(null);
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
  async function search(query) {
    const login = String(cmux.app.settings().login ?? "").trim();
    try {
      const r = await cmux.integrations.github.request({ method: "GET", path: `/search/issues?q=${encodeURIComponent(query("@me"))}&per_page=50` });
      return r.items;
    } catch (e) {
      if (!login)
        throw new Error("Set your GitHub login in Settings > Apps > GitHub PRs, or connect GitHub.");
      const r = await cmux.net.fetch(`https://api.github.com/search/issues?q=${encodeURIComponent(query(login))}&per_page=50`, { headers: { Accept: "application/vnd.github+json" } });
      if (!r.ok)
        throw new Error(`GitHub answered ${r.status}`);
      return r.json().items;
    }
  }
  async function loadRecent() {
    const since = new Date(Date.now() - 24 * 60 * 60000).toISOString().slice(0, 19) + "Z";
    try {
      const batches = await Promise.all(["author", "review-requested", "assignee"].map((role) => search((who) => `is:pr ${role}:${who} updated:>=${since}`)));
      const byId = new Map;
      for (const i of batches.flat()) {
        const merged = !!i.pull_request?.merged_at;
        if (i.state !== "open" && !merged)
          continue;
        byId.set(i.id, { id: i.id, number: i.number, title: i.title, html_url: i.html_url, draft: !!i.draft, repo: repoOf(i.repository_url), updated_at: i.updated_at, merged, open: i.state === "open" });
      }
      setRecent([...byId.values()].sort((a, b) => b.updated_at.localeCompare(a.updated_at)));
      setRecentError(null);
    } catch (e) {
      setRecentError(e instanceof Error ? e.message : String(e));
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
  function renderRecentPRs() {
    loadRecent();
    cmux.timer.every(5 * 60000, loadRecent);
    const visible = computed(() => recent() ?? []);
    return VStack({ spacing: 2 }, [
      ForEach({ items: visible, key: (p) => p.id }, (p) => Row({
        title: () => p().title,
        subtitle: () => `${p().repo} #${p().number}${p().merged ? " · Merged" : ""}`,
        symbol: () => p().merged ? "checkmark.circle" : p().draft ? "circle.dashed" : "arrow.triangle.pull",
        tint: () => p().merged ? "accent" : p().draft ? "secondary" : "success"
      }).help(() => p().html_url).onTap(() => cmux.actions.run("openBrowser", { url: p().html_url }))),
      () => recentError() ? EmptyState({ title: "Cannot load pull requests", message: recentError(), symbol: "exclamationmark.triangle" }) : null,
      () => !recentError() && recent() && visible().length === 0 ? EmptyState({ title: "No pull requests in the last 24 hours", symbol: "clock" }) : null
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
