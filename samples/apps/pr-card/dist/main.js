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
    renderPRCard: () => renderPRCard
  });
  var PAGE = 5;
  async function github(path) {
    try {
      return await cmux.integrations.github.request({ method: "GET", path });
    } catch {
      const r = await cmux.net.fetch(`https://api.github.com${path}`, { headers: { Accept: "application/vnd.github+json" } });
      if (!r.ok)
        throw new Error(`GitHub answered ${r.status}`);
      return r.json();
    }
  }
  function rank(c) {
    if (c.status !== "completed")
      return 1;
    return ["failure", "timed_out", "cancelled", "action_required"].includes(c.conclusion ?? "") ? 0 : 2;
  }
  function checkLook(c) {
    if (c.status !== "completed")
      return { label: "Running", symbol: "clock", tint: "warning" };
    switch (c.conclusion) {
      case "success":
        return { label: "Passed", symbol: "checkmark.circle", tint: "success" };
      case "skipped":
      case "neutral":
        return { label: "Skipped", symbol: "minus.circle", tint: "secondary" };
      default:
        return { label: "Failed", symbol: "xmark.circle", tint: "danger" };
    }
  }
  function renderPRCard(context = {}) {
    const repo = String(context.props?.repo ?? "").trim();
    const number = Number(context.props?.number);
    if (!/^[\w.-]+\/[\w.-]+$/.test(repo) || !Number.isInteger(number) || number <= 0) {
      return EmptyState({ title: "No pull request", message: "This card needs props {repo, number}.", symbol: "exclamationmark.triangle" });
    }
    const pageKey = `page:${context.widget?.key ?? `${repo}#${number}`}`;
    const [pr, setPR] = signal(null);
    const [checks, setChecks] = signal([]);
    const [error, setError] = signal(null);
    const [page, setPage] = signal(0);
    cmux.storage.get(pageKey).then((saved) => {
      if (typeof saved === "number" && saved > 0)
        setPage(saved);
    });
    const turn = (by) => {
      const next = Math.max(0, Math.min(pages() - 1, page() + by));
      setPage(next);
      cmux.storage.set(pageKey, next);
    };
    let timer = null;
    const load = async () => {
      try {
        const p = await github(`/repos/${repo}/pulls/${number}`);
        const head = String(p.head?.sha ?? "");
        setPR({ title: p.title, state: p.state, merged: !!p.merged_at, draft: !!p.draft, author: p.user?.login ?? "", url: p.html_url, sha: head });
        const runs = head ? await github(`/repos/${repo}/commits/${head}/check-runs?per_page=100`) : { check_runs: [] };
        const list = runs.check_runs.map((c) => ({ id: c.id, name: c.name, status: c.status, conclusion: c.conclusion, url: c.html_url }));
        setChecks(list.sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name)));
        setError(null);
        const running = list.some((c) => c.status !== "completed");
        if (timer !== null)
          cmux.timer.clear(timer);
        timer = cmux.timer.every(running ? 30000 : 300000, load);
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      }
    };
    load();
    const pages = computed(() => Math.max(1, Math.ceil(checks().length / PAGE)));
    const shown = computed(() => {
      const at = Math.min(page(), pages() - 1);
      return checks().slice(at * PAGE, at * PAGE + PAGE);
    });
    const summary = computed(() => {
      const list = checks();
      const failed = list.filter((c) => rank(c) === 0).length;
      const running = list.filter((c) => rank(c) === 1).length;
      const passed = list.length - failed - running;
      if (!list.length)
        return { text: "No checks", tone: "secondary" };
      const parts = [failed && `${failed} failed`, running && `${running} running`, passed && `${passed} passed`].filter(Boolean);
      return { text: parts.join(" · "), tone: failed ? "danger" : running ? "warning" : "success" };
    });
    const stateText = () => {
      const p = pr();
      if (!p)
        return "Loading";
      return p.merged ? "Merged" : p.state === "closed" ? "Closed" : p.draft ? "Draft" : "Open";
    };
    return VStack({ spacing: 4 }, [
      Text(() => pr()?.title ?? `${repo} #${number}`).font("headline"),
      Row({
        title: `${repo} #${number}`,
        subtitle: () => [stateText(), pr()?.author].filter(Boolean).join(" · "),
        symbol: () => pr()?.merged ? "checkmark.circle" : "arrow.triangle.pull",
        tint: () => pr()?.merged ? "accent" : pr()?.state === "closed" ? "secondary" : "success"
      }).onTap(() => {
        const p = pr();
        if (p)
          cmux.actions.run("openBrowser", { url: p.url });
      }),
      () => error() ? EmptyState({ title: "Cannot load the pull request", message: error(), symbol: "exclamationmark.triangle" }) : null,
      () => pr() && !error() ? Badge(() => summary().text, () => summary().tone) : null,
      () => checks().length ? Divider() : null,
      ForEach({ items: shown, key: (c) => c.id }, (c) => Row({ title: () => c().name, subtitle: () => checkLook(c()).label, symbol: () => checkLook(c()).symbol, tint: () => checkLook(c()).tint }).onTap(() => cmux.actions.run("openBrowser", { url: c().url }))),
      () => pages() > 1 ? Text(() => `Page ${Math.min(page(), pages() - 1) + 1} of ${pages()}`).font("caption").color("secondary") : null,
      () => pages() > 1 ? HStack([
        Button("Previous", () => turn(-1)).disabled(() => page() <= 0),
        Button("Next", () => turn(1)).disabled(() => page() >= pages() - 1).background("accent")
      ]) : null
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
