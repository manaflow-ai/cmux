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
    renderPriority: () => renderPriority,
    visible: () => visible
  });
  var STYLE = {
    needs_you: { title: "Needs you", symbol: "exclamationmark.bubble", tone: "warning" },
    done: { title: "Finished", symbol: "checkmark.circle", tone: "success" },
    failed: { title: "Failed", symbol: "xmark.octagon", tone: "danger" },
    lost: { title: "Lost", symbol: "bolt.slash", tone: "danger" },
    ci_failing: { title: "Red CI", symbol: "xmark.circle", tone: "danger" },
    working: { title: "Working", symbol: "circle.dotted", tone: "accent" },
    idle: { title: "Idle", symbol: "moon", tone: "secondary" }
  };
  function visible(chats, showIdle) {
    return chats.filter((c) => showIdle || c.pinned || c.state !== "idle");
  }
  var subtitle = (c) => [STYLE[c.state]?.title ?? c.state, c.project ?? c.machine].filter(Boolean).join(" · ");
  function renderPriority() {
    const list = cmux.live("chat.list", {});
    const rows = computed(() => visible(list()?.chats ?? [], cmux.app.settings().showIdle === true));
    const style = (c) => STYLE[c.state] ?? STYLE.idle;
    return VStack({ spacing: 2 }, [
      ForEach({ items: rows, key: (c) => c.id }, (c) => Row({
        title: () => c().title,
        subtitle: () => subtitle(c()),
        symbol: () => style(c()).symbol,
        tint: () => style(c()).tone,
        unread: () => c().unread
      })),
      () => list.loading() || rows().length ? null : EmptyState({ title: "Nothing needs you", symbol: "bell" })
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
