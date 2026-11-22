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
    renderAgents: () => renderAgents
  });
  async function focusTerminal(terminal) {
    const gesture = cmux.gesture() ?? undefined;
    const t = await cmux.terminal.get({ terminal });
    if (t.tab_id)
      await cmux.tab.focus({ tab: t.tab_id }, { gesture });
  }
  var GROUPS = [
    { state: "blocked", title: "Waiting for you", symbol: "exclamationmark.bubble", tone: "warning" },
    { state: "working", title: "Working", symbol: "circle.dotted", tone: "accent" },
    { state: "idle", title: "Idle", symbol: "moon", tone: "secondary" },
    { state: "done", title: "Done", symbol: "checkmark.circle", tone: "success" }
  ];
  var label = (a) => {
    const extra = a.extra ?? {};
    return String(extra.name ?? extra.title ?? a.source_session ?? a.source);
  };
  var since = (ms) => {
    const minutes = Math.max(0, Math.round((Date.now() - Number(ms)) / 60000));
    return minutes < 1 ? "now" : minutes < 60 ? `${minutes}m` : `${Math.round(minutes / 60)}h`;
  };
  function renderAgents() {
    const agents = cmux.live("agent.list", {});
    const visible = computed(() => {
      const showIdle = cmux.app.settings().showIdle !== false;
      return (agents() ?? []).filter((a) => showIdle || a.state !== "idle" && a.state !== "done");
    });
    const rows = computed(() => {
      const out = [];
      for (const g of GROUPS) {
        const members = visible().filter((a) => a.state === g.state);
        if (!members.length)
          continue;
        out.push({ key: `h:${g.state}`, header: g, count: members.length });
        for (const a of members)
          out.push({ key: a.id, agent: a });
      }
      return out;
    });
    return VStack({ spacing: 2 }, [
      ForEach({ items: rows, key: (r) => r.key }, (r) => r().header ? HStack({ spacing: 6 }, [
        Text(() => r().header.title).font("caption").secondary(),
        Spacer(),
        Badge(() => r().count ?? 0, () => r().header.tone)
      ]).paddingHorizontal(8).paddingVertical(2) : Row({
        title: () => label(r().agent),
        subtitle: () => `${r().agent.state} · ${since(r().agent.updated_at_ms)}`,
        symbol: () => GROUPS.find((g) => g.state === r().agent.state)?.symbol ?? "circle",
        tint: () => GROUPS.find((g) => g.state === r().agent.state)?.tone ?? "secondary",
        unread: () => r().agent.state === "blocked"
      }).onTap(() => focusTerminal(r().agent.terminal_id)).contextMenu([Button("Focus Terminal", () => focusTerminal(r().agent.terminal_id))])),
      () => agents.loading() || visible().length ? null : EmptyState({ title: "No agents running", symbol: "sparkles" })
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
