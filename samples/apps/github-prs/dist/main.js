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
  var login = () => {
    const l = String(cmux.app.settings().login ?? "").trim();
    return l ? { login: l } : {};
  };
  var mine = () => ({ roles: ["author"], ...login() });
  var recent = () => ({ roles: ["author", "review-requested", "assignee"], include: "open-and-merged", updatedWithinHours: 24, limit: 50, ...login() });
  var failure = (e) => e?.code === "integration.unavailable" || e?.code === "scope.missing" ? "Set your GitHub login in Settings > Apps > GitHub PRs, or connect GitHub." : e?.message ?? "";
  async function refresh() {
    const s = await cmux.watch.refresh("github.pulls", mine());
    return { count: s.value?.length ?? 0 };
  }
  function renderPRs() {
    const prs = cmux.watch("github.pulls", mine);
    const visible = computed(() => (prs.value() ?? []).filter((p) => cmux.app.settings().showDrafts !== false || !p.draft));
    return VStack({ spacing: 2 }, [
      ForEach({ items: visible, key: (p) => p.id }, (p) => Row({
        title: () => p().title,
        subtitle: () => `${p().repo} #${p().number}`,
        symbol: () => p().draft ? "circle.dashed" : "arrow.triangle.pull",
        tint: () => p().draft ? "secondary" : "success"
      }).help(() => p().url).onTap(() => cmux.actions.run("openBrowser", { url: p().url })).contextMenu([Button("Open in Browser", () => cmux.actions.run("openBrowser", { url: p().url })), Divider(), Button("Refresh", () => prs.refresh())])),
      () => prs.status() === "error" ? EmptyState({ title: "Cannot load pull requests", message: failure(prs.error()), symbol: "exclamationmark.triangle" }) : null,
      () => prs.status() === "fresh" && visible().length === 0 ? EmptyState({ title: "No open pull requests", symbol: "checkmark.circle" }) : null
    ]);
  }
  function renderRecentPRs() {
    const prs = cmux.watch("github.pulls", recent);
    return VStack({ spacing: 2 }, [
      ForEach({ items: () => prs.value() ?? [], key: (p) => p.id }, (p) => Row({
        title: () => p().title,
        subtitle: () => `${p().repo} #${p().number}${p().state === "merged" ? " · Merged" : ""}`,
        symbol: () => p().state === "merged" ? "checkmark.circle" : p().draft ? "circle.dashed" : "arrow.triangle.pull",
        tint: () => p().state === "merged" ? "accent" : p().draft ? "secondary" : "success"
      }).help(() => p().url).onTap(() => cmux.actions.run("openBrowser", { url: p().url }))),
      () => prs.status() === "error" ? EmptyState({ title: "Cannot load pull requests", message: failure(prs.error()), symbol: "exclamationmark.triangle" }) : null,
      () => prs.status() === "fresh" && (prs.value() ?? []).length === 0 ? EmptyState({ title: "No pull requests in the last 24 hours", symbol: "clock" }) : null
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
