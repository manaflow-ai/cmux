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
    rank: () => rank,
    renderPriority: () => renderPriority
  });
  var TIERS = [
    { state: "blocked", title: "Needs you", symbol: "exclamationmark.bubble", tone: "warning" },
    { state: "done", title: "Finished", symbol: "checkmark.circle", tone: "success" },
    { state: "working", title: "Working", symbol: "circle.dotted", tone: "accent" },
    { state: "idle", title: "Idle", symbol: "moon", tone: "secondary" }
  ];
  var tier = (state) => {
    const index = TIERS.findIndex((t) => t.state === state);
    return index < 0 ? TIERS.length : index;
  };
  var label = (a) => {
    const extra = a.extra ?? {};
    return String(extra.name ?? extra.title ?? a.source_session ?? a.source);
  };
  function rank(agents, showIdle) {
    return agents.filter((a) => showIdle || a.state !== "idle").slice().sort((a, b) => tier(a.state) - tier(b.state) || Number(b.updated_at_ms) - Number(a.updated_at_ms));
  }
  async function focusTerminal(terminal) {
    const gesture = cmux.gesture() ?? undefined;
    const t = await cmux.terminal.get({ terminal });
    if (t.tab_id)
      await cmux.tab.focus({ tab: t.tab_id }, { gesture });
  }
  function renderPriority() {
    const agents = cmux.live("agent.list", {});
    const ranked = computed(() => rank(agents() ?? [], cmux.app.settings().showIdle === true));
    const style = (a) => TIERS[tier(a.state)] ?? TIERS[TIERS.length - 1];
    return VStack({ spacing: 2 }, [
      ForEach({ items: ranked, key: (a) => a.id }, (a) => Row({
        title: () => label(a()),
        subtitle: () => style(a()).title,
        symbol: () => style(a()).symbol,
        tint: () => style(a()).tone,
        unread: () => a().state === "blocked" || a().state === "done"
      }).onTap(() => focusTerminal(a().terminal_id))),
      () => agents.loading() || ranked().length ? null : EmptyState({ title: "Nothing needs you", symbol: "bell" })
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
