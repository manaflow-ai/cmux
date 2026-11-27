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
    renderPriority: () => renderPriority,
    tier: () => tier
  });
  var TIERS = [
    { title: "Needs you", symbol: "exclamationmark.bubble", tone: "warning" },
    { title: "Finished", symbol: "checkmark.circle", tone: "success" },
    { title: "Failed", symbol: "exclamationmark.triangle", tone: "danger" },
    { title: "CI failing", symbol: "xmark.octagon", tone: "danger" },
    { title: "Working", symbol: "circle.dotted", tone: "accent" },
    { title: "Idle", symbol: "moon", tone: "secondary" }
  ];
  var NEEDS_YOU = 0;
  var FINISHED = 1;
  var FAILED = 2;
  var CI_FAILING = 3;
  var WORKING = 4;
  var IDLE = 5;
  var IDLE_HORIZON_MS = 24 * 60 * 60 * 1000;
  function tier(c) {
    const turn = c.state === "input" ? NEEDS_YOU : c.state === "working" ? WORKING : c.state === "failed" || c.state === "lost" ? FAILED : c.unread ? FINISHED : IDLE;
    return c.ci_failing === true && CI_FAILING < turn ? CI_FAILING : turn;
  }
  var since = (c) => Number(c.since_ms ?? c.updated_ms ?? 0);
  function rank(chats, showIdle, now = Date.now()) {
    return chats.filter((c) => {
      if (tier(c) !== IDLE || c.pinned)
        return true;
      return showIdle && now - since(c) <= IDLE_HORIZON_MS;
    }).slice().sort((a, b) => tier(a) - tier(b) || Number(b.pinned) - Number(a.pinned) || since(b) - since(a) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  }
  var subtitle = (c) => {
    const t = TIERS[tier(c)].title;
    const where = [c.project, c.machine].filter(Boolean).join(" · ");
    return where ? `${t} · ${where}` : t;
  };
  async function open(c) {
    const gesture = cmux.gesture() ?? undefined;
    if (c.workspace)
      await cmux.workspace.focus({ workspace: c.workspace }, { gesture });
    if (c.unread)
      await cmux.chat.mark_read({ chat: c.id }, { gesture });
  }
  async function pin(c) {
    await cmux.chat.pin({ chat: c.id, pinned: !c.pinned }, { gesture: cmux.gesture() ?? undefined });
  }
  async function markRead(c) {
    await cmux.chat.mark_read({ chat: c.id }, { gesture: cmux.gesture() ?? undefined });
  }
  function renderPriority() {
    const chats = cmux.live("chat.list", {});
    const ranked = computed(() => rank(chats() ?? [], cmux.app.settings().showIdle === true));
    const style = (c) => TIERS[tier(c)];
    return VStack({ spacing: 2 }, [
      ForEach({ items: ranked, key: (c) => c.id }, (c) => Row({
        title: () => c().title,
        subtitle: () => subtitle(c()),
        symbol: () => c().pinned ? "pin.fill" : style(c()).symbol,
        tint: () => style(c()).tone,
        unread: () => c().unread
      }).onTap(() => open(c())).contextMenu(() => [
        Button(c().pinned ? "Unpin" : "Pin", () => pin(c())),
        Button("Mark as Read", () => markRead(c())).disabled(() => !c().unread)
      ])),
      () => chats.loading() || ranked().length ? null : EmptyState({ title: "Nothing needs you", symbol: "bell" })
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
