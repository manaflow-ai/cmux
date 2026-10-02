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
    cycleVariant: () => cycleVariant2,
    list: () => list,
    markAllSeen: () => markAllSeen2,
    markDone: () => markDone2,
    nextItem: () => nextItem,
    openInbox: () => openInbox,
    openItem: () => openItem2,
    previousItem: () => previousItem,
    refresh: () => refresh,
    renderInbox: () => renderInbox,
    renderPane: () => renderPane,
    renderStatus: () => renderStatus,
    snooze: () => snooze
  });
  var FEED_CHANGED = "feed.changed";
  var feed = {
    list: (params) => cmux.call("feed.list", params),
    get: (item) => cmux.call("feed.get", { item }),
    counts: () => cmux.call("feed.counts", {}),
    mark: (items, state) => cmux.call("feed.mark", { items, state }),
    markMatching: (filter, state) => cmux.call("feed.mark", { filter, state }),
    snooze: (item, until) => cmux.call("feed.snooze", { item, until }),
    respond: (item, value) => cmux.call("feed.respond", { item, value })
  };
  var ja = {
    "app.title": "受信トレイ",
    "action.done": "完了にする",
    "action.doneShort": "完了",
    "action.markAllDone": "すべて完了にする",
    "action.markAllSeen": "すべて既読にする",
    "action.markSeen": "既読にする",
    "action.more": "その他",
    "action.open": "開く",
    "action.respond": "回答",
    "action.skip": "スキップ",
    "action.snooze": "スヌーズ",
    "action.unsnooze": "スヌーズを解除",
    "ago.now": "今",
    "ago.m": "{n}分",
    "ago.h": "{n}時間",
    "ago.d": "{n}日",
    "ago.w": "{n}週",
    "day.0": "日",
    "day.1": "月",
    "day.2": "火",
    "day.3": "水",
    "day.4": "木",
    "day.5": "金",
    "day.6": "土",
    "time.tomorrow": "明日 {time}",
    "time.weekday": "{day} {time}",
    "snooze.30m": "30分後 ({time})",
    "snooze.2h": "2時間後 ({time})",
    "snooze.tomorrow": "明日 ({time})",
    "snooze.nextWeek": "来週 ({time})",
    "snooze.until": "{time} までスヌーズ",
    "snoozed.count": "スヌーズ中 {n} 件",
    "snoozed.hide": "スヌーズ中を隠す",
    "snoozed.show": "スヌーズ中を表示",
    "snoozed.title": "スヌーズ中",
    "card.position": "{index} / {total}",
    "detail.none": "項目を選んでください",
    "empty.filtered": "このフィルターに一致する項目はありません",
    "empty.message": "エージェント、アプリ、連携はすべて片付いています。",
    "empty.title": "対応が必要なものはありません",
    "feed.error": "フィードを読み込めません",
    "feed.notGranted": "フィードへのアクセスが許可されていません",
    "feed.notGrantedHelp": "設定 > アプリ > 受信トレイ で許可してください。",
    "feed.unavailable": "フィードはまだ利用できません",
    "feed.unavailableHelp": "このバージョンの cmux にはフィードの管理元がありません。",
    "error.feed": "フィードが受け付けませんでした: {reason}",
    "error.open": "開けませんでした: {reason}",
    "filter.all": "すべて",
    "filter.everything": "すべて表示",
    "filter.needsResponse": "回答が必要なものだけ表示",
    "filter.needsResponseShort": "要対応",
    "filter.other": "アプリと実行",
    "filter.showSeen": "既読も表示",
    "filter.unseenOnly": "未読のみ表示",
    "filter.unseenShort": "未読",
    "group.source": "ソース別にまとめる",
    "group.thread": "スレッド別にまとめる",
    "group.workspace": "ワークスペース別にまとめる",
    "item.noneSelected": "受信トレイの項目が選択されていません",
    "item.notFound": "受信トレイに {id} はありません",
    "kind.watch": "進行中",
    loading: "読み込み中…",
    "pane.unsupported": "このバージョンの cmux はアプリのペインをまだ開けません。サイドバーのセクションを使ってください。",
    "reason.scope": "許可されていません",
    "reason.unsupported": "このバージョンの cmux では使えません",
    "request.approve": "承認",
    "request.choice": "選択",
    "request.confirm": "確認",
    "request.file": "ファイル",
    "request.handoff": "引き継ぎ",
    "request.input": "入力",
    "request.passkey": "パスキー",
    "request.question": "質問",
    "request.review": "レビュー",
    "request.sign-in": "サインイン",
    "respond.approve": "承認",
    "respond.cancel": "キャンセル",
    "respond.confirm": "確認",
    "respond.continueInBrowser": "ブラウザで続ける",
    "respond.deny": "拒否",
    "respond.externalHelp": "隣に開くブラウザタブで完了してください。エージェントはその後に再開し、認証情報を見ることはありません。",
    "respond.placeholder": "回答…",
    "source.agent": "エージェント",
    "source.app": "アプリ",
    "source.integration": "連携",
    "source.run": "実行",
    "source.user": "ユーザー",
    "status.none": "対応が必要なものはありません",
    "status.summary": "未読 {unseen} 件、回答が必要 {needs} 件"
  };
  var tables = { ja };
  var detect = () => {
    try {
      const intl = globalThis.Intl;
      const locale = intl?.DateTimeFormat?.().resolvedOptions?.().locale;
      if (typeof locale === "string" && locale)
        return locale.toLowerCase();
    } catch {}
    return "en";
  };
  var language = detect().split("-")[0] ?? "en";
  function t(key, english, vars = {}) {
    const template = tables[language]?.[key] ?? english;
    return template.replace(/\{(\w+)\}/g, (whole, name) => (name in vars) ? String(vars[name]) : whole);
  }
  var VARIANTS = ["grouped", "focus", "card"];
  var DEFAULT_VARIANT = "grouped";
  var asVariant = (v) => VARIANTS.includes(v) ? v : DEFAULT_VARIANT;
  var asGroupBy = (v) => v === "workspace" || v === "thread" ? v : "source";
  var readSettings = (raw) => ({ variant: asVariant(raw.variant), groupBy: asGroupBy(raw.groupBy) });
  var settings = () => readSettings(cmux.app.settings());
  function describe(e) {
    const code = e && typeof e === "object" && "code" in e ? String(e.code) : "";
    if (code === "scope.missing")
      return t("reason.scope", "permission not granted");
    if (code === "operation.unsupported")
      return t("reason.unsupported", "not supported by this version of cmux");
    return e instanceof Error ? e.message : String(e);
  }
  var codeOf = (e) => e && typeof e === "object" && ("code" in e) ? String(e.code) : "";
  var DEFAULT_FILTERS = { source: "all", unseenOnly: false, needsResponseOnly: false, showSnoozed: false };
  var SOURCE_KINDS = { agent: ["agent"], integration: ["integration"], other: ["app", "run", "user"] };
  function toFeedFilter(f) {
    const filter = { status: [f.showSnoozed ? "snoozed" : "open"] };
    if (f.source !== "all")
      filter.sources = SOURCE_KINDS[f.source];
    if (f.unseenOnly)
      filter.unseen = true;
    if (f.needsResponseOnly)
      filter.needsResponse = true;
    return filter;
  }
  var LIST_LIMIT = 100;
  var [filters, setFiltersSignal] = signal(DEFAULT_FILTERS);
  var [groupOverride, setGroupOverride] = signal(null);
  var groupBy = computed(() => groupOverride() ?? settings().groupBy);
  var [selected, setSelected] = signal(null);
  var [notice, setNotice] = signal(null);
  var [variantOverride, setVariantOverride] = signal(null);
  var variant = computed(() => {
    const base = settings().variant;
    const o = variantOverride();
    return o && o.base === base ? o.variant : base;
  });
  var [result, setResult] = signal(null);
  var [counts, setCounts] = signal(null);
  var [feedError, setFeedError] = signal(null);
  var items = computed(() => result()?.items ?? []);
  var current = computed(() => items().find((i) => i.id === selected()) ?? items()[0] ?? null);
  var loaded = computed(() => result() !== null || feedError() !== null);
  var groups = computed(() => {
    const r = result();
    if (!r?.groups)
      return [{ key: "all", label: "", sourceKind: undefined, items: r?.items ?? [] }];
    const byId = new Map(r.items.map((i) => [i.id, i]));
    return r.groups.map((g) => ({ key: g.key, label: g.label, sourceKind: g.sourceKind, items: g.itemIds.map((id) => byId.get(id)).filter((i) => !!i) })).filter((g) => g.items.length > 0);
  });
  var viewLoading = null;
  var persist = (key, value) => cmux.storage.set(key, value).catch((e) => cmux.log(`storage ${key}: ${describe(e)}`));
  function ensureView() {
    viewLoading ??= Promise.all([
      cmux.storage.get("view").catch(() => null),
      cmux.storage.get("variantOverride").catch(() => null)
    ]).then(([view, override]) => {
      if (view?.filters)
        setFiltersSignal({ ...DEFAULT_FILTERS, ...view.filters, showSnoozed: false });
      if (view?.groupBy)
        setGroupOverride(asGroupBy(view.groupBy));
      if (override?.variant)
        setVariantOverride({ variant: asVariant(override.variant), base: asVariant(override.base) });
    });
    return viewLoading;
  }
  function setFilters(change) {
    const next = { ...filters(), ...change };
    setFiltersSignal(next);
    persist("view", { filters: { ...next, showSnoozed: false }, groupBy: groupOverride() });
  }
  function setGrouping(by) {
    setGroupOverride(by);
    persist("view", { filters: { ...filters(), showSnoozed: false }, groupBy: by });
  }
  var listParams = (grouped) => ({ filter: toFeedFilter(filters()), ...grouped ? { groupBy: groupBy() } : {}, limit: LIST_LIMIT });
  var [reloadTick, setReloadTick] = signal(0);
  function attachList(grouped) {
    ensureView();
    let seq = 0;
    const load = () => {
      const params = listParams(grouped);
      const mine = ++seq;
      feed.list(params).then((r) => {
        if (mine !== seq)
          return;
        setResult(r);
        setCounts(r.counts);
        setFeedError(null);
      }).catch((e) => {
        if (mine === seq)
          setFeedError({ code: codeOf(e), message: describe(e) });
      });
    };
    effect(() => {
      filters();
      groupBy();
      reloadTick();
      load();
    });
    cmux.events.on(FEED_CHANGED, (payload) => {
      const p = payload;
      if (p?.counts)
        setCounts(p.counts);
      load();
    });
  }
  function attachCounts() {
    feed.counts().then(setCounts).catch((e) => setFeedError({ code: codeOf(e), message: describe(e) }));
    cmux.events.on(FEED_CHANGED, (payload) => {
      const p = payload;
      if (p?.counts)
        setCounts(p.counts);
    });
  }
  function noteRevision(revision) {
    if (!revision || result()?.revision === revision)
      return;
    setReloadTick((n) => n + 1);
  }
  async function listNow(params = listParams(false)) {
    await ensureView();
    const r = await feed.list(params);
    setResult(r);
    setCounts(r.counts);
    return r;
  }
  async function cycleVariant() {
    const next = VARIANTS[(VARIANTS.indexOf(variant()) + 1) % VARIANTS.length];
    const base = settings().variant;
    setVariantOverride({ variant: next, base });
    try {
      await cmux.call("app.settings.set", { key: "variant", value: next });
    } catch {
      await persist("variantOverride", { variant: next, base });
    }
    return next;
  }
  function noticeFor(message) {
    setNotice(message);
    cmux.timer.after(6000, () => setNotice(null));
  }
  var fail = (key, english) => (e) => {
    noticeFor(t(key, english, { reason: describe(e) }));
    return;
  };
  var settle = (p) => p.then((m) => noteRevision(m?.revision)).catch(fail("error.feed", "The feed did not accept that: {reason}"));
  var run = (target) => cmux.actions.run(target.action, target.args);
  async function openItem(item) {
    setSelected(item.id);
    const opening = item.open ? run(item.open).catch(fail("error.open", "Could not open: {reason}")) : null;
    if (item.seenAt === null)
      await settle(feed.mark([item.id], "seen"));
    await opening;
  }
  var markSeen = (list) => list.length ? settle(feed.mark(list.map((i) => i.id), "seen")) : Promise.resolve();
  async function markDone(list) {
    moveSelectionOff(list.map((i) => i.id));
    if (list.length)
      await settle(feed.mark(list.map((i) => i.id), "done"));
  }
  async function snoozeItems(list, until) {
    moveSelectionOff(list.map((i) => i.id));
    const at = new Date(until).toISOString();
    for (const item of list)
      await settle(feed.snooze(item.id, at));
  }
  var reopen = (list) => settle(feed.mark(list.map((i) => i.id), "open"));
  function respond(item, value) {
    const sending = feed.respond(item.id, value);
    moveSelectionOff([item.id]);
    return settle(sending);
  }
  function runAction(item, action) {
    switch (action.kind) {
      case "open":
        return openItem(item);
      case "respond":
        return respond(item, action.value);
      case "done":
        return markDone([item]);
      case "snooze":
        return snoozeItems([item], Date.now() + 3600000);
      case "custom":
        return action.target ? run(action.target).catch(fail("error.open", "Could not open: {reason}")) : Promise.resolve();
    }
  }
  async function markAllSeen() {
    const m = await feed.markMatching({ ...toFeedFilter(filters()), unseen: true }, "seen");
    noteRevision(m?.revision);
    return m?.changed ?? 0;
  }
  function moveSelectionOff(ids) {
    const sel = selected();
    if (!sel || !ids.includes(sel))
      return;
    const list = items();
    const index = list.findIndex((i) => i.id === sel);
    const next = list.slice(index + 1).find((i) => !ids.includes(i.id)) ?? list.slice(0, index).reverse().find((i) => !ids.includes(i.id));
    setSelected(next?.id ?? null);
  }
  function step(direction, from = selected()) {
    const list = items();
    if (list.length === 0)
      return null;
    const index = from ? list.findIndex((i) => i.id === from) : -1;
    const next = index < 0 ? list[direction === 1 ? 0 : list.length - 1] : list[(index + direction + list.length) % list.length];
    setSelected(next.id);
    return next;
  }
  function ago(at, now) {
    const minutes = Math.floor(Math.max(0, now - at) / 60000);
    if (minutes < 1)
      return t("ago.now", "now");
    if (minutes < 60)
      return t("ago.m", "{n}m", { n: minutes });
    const hours = Math.floor(minutes / 60);
    if (hours < 24)
      return t("ago.h", "{n}h", { n: hours });
    const days = Math.floor(hours / 24);
    if (days < 7)
      return t("ago.d", "{n}d", { n: days });
    return t("ago.w", "{n}w", { n: Math.floor(days / 7) });
  }
  var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  var hhmm = (d) => `${d.getHours()}:${String(d.getMinutes()).padStart(2, "0")}`;
  var sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  function clock(until, now) {
    const d = new Date(until);
    const n = new Date(now);
    if (sameDay(d, n))
      return hhmm(d);
    const tomorrow = new Date(n.getFullYear(), n.getMonth(), n.getDate() + 1);
    if (sameDay(d, tomorrow))
      return t("time.tomorrow", "Tomorrow {time}", { time: hhmm(d) });
    const day = d.getDay();
    return t("time.weekday", "{day} {time}", { day: t(`day.${day}`, DAYS[day]), time: hhmm(d) });
  }
  var MORNING_HOUR = 9;
  function snoozePresets(now) {
    const n = new Date(now);
    const tomorrow = new Date(n.getFullYear(), n.getMonth(), n.getDate() + 1, MORNING_HOUR).getTime();
    const daysToMonday = (8 - n.getDay()) % 7 || 7;
    const nextWeek = new Date(n.getFullYear(), n.getMonth(), n.getDate() + daysToMonday, MORNING_HOUR).getTime();
    const presets = [
      ["30m", now + 30 * 60000, "In 30 minutes ({time})"],
      ["2h", now + 2 * 3600000, "In 2 hours ({time})"],
      ["tomorrow", tomorrow, "Tomorrow ({time})"],
      ["nextWeek", nextWeek, "Next week ({time})"]
    ];
    return presets.map(([id, until, english]) => ({ id, until, label: t(`snooze.${id}`, english, { time: id === "tomorrow" ? hhmm(new Date(until)) : clock(until, now) }) }));
  }
  var REQUEST_LABELS = {
    question: ["request.question", "Question"],
    choice: ["request.choice", "Choose"],
    approve: ["request.approve", "Approval"],
    confirm: ["request.confirm", "Confirm"],
    "sign-in": ["request.sign-in", "Sign-in"],
    passkey: ["request.passkey", "Passkey"],
    review: ["request.review", "Review"],
    input: ["request.input", "Input"],
    file: ["request.file", "File"],
    handoff: ["request.handoff", "Handoff"]
  };
  var SOURCE_LABELS = {
    agent: ["source.agent", "Agents"],
    app: ["source.app", "Apps"],
    run: ["source.run", "Runs"],
    integration: ["source.integration", "Integrations"],
    user: ["source.user", "People"]
  };
  var FILTER_LABELS = {
    all: ["filter.all", "All"],
    agent: ["source.agent", "Agents"],
    integration: ["source.integration", "Integrations"],
    other: ["filter.other", "Apps and Runs"]
  };
  var sourceKindLabel = (k) => t(...SOURCE_LABELS[k]);
  var filterLabel = (f) => t(...FILTER_LABELS[f]);
  function kindLabel(i) {
    if (i.kind === "request" && i.requestKind)
      return t(...REQUEST_LABELS[i.requestKind]);
    if (i.kind === "watch")
      return t("kind.watch", "In progress");
    return "";
  }
  var REQUEST_SYMBOLS = {
    question: "questionmark.bubble",
    choice: "list.bullet",
    approve: "checkmark.shield",
    confirm: "exclamationmark.bubble",
    "sign-in": "person.badge.key",
    passkey: "key",
    review: "eye",
    input: "text.cursor",
    file: "doc",
    handoff: "arrow.triangle.branch"
  };
  var SOURCE_SYMBOLS = { agent: "sparkles", app: "app", run: "play.circle", integration: "link", user: "person" };
  function itemSymbol(i) {
    if (i.kind === "request" && i.requestKind)
      return REQUEST_SYMBOLS[i.requestKind];
    if (i.kind === "watch")
      return "hourglass";
    if (i.urgency === "critical" || i.urgency === "high")
      return "exclamationmark.triangle";
    return SOURCE_SYMBOLS[i.source.kind];
  }
  function itemTint(i) {
    if (i.urgency === "critical")
      return "danger";
    if (i.needsResponse || i.urgency === "high")
      return "warning";
    if (i.kind === "watch")
      return "accent";
    return i.urgency === "low" ? "tertiary" : "secondary";
  }
  function subtitleOf(i, now) {
    const when = i.snoozedUntil ? t("snooze.until", "Snoozed until {time}", { time: clock(Date.parse(i.snoozedUntil), now) }) : ago(Date.parse(i.updatedAt), now);
    const place = i.subject.workspaceName ?? "";
    return [kindLabel(i), when, i.source.name, place].filter(Boolean).join(" · ");
  }
  function snoozeMenu(list) {
    return Menu(t("action.snooze", "Snooze"), snoozePresets(Date.now()).map((p) => Button(p.label, () => snoozeItems(list(), p.until))));
  }
  function respondMenu(i) {
    const r = i.response;
    if (!i.needsResponse || !r)
      return null;
    const entries = r.type === "choice" ? r.options.map((o) => Button(o.label, () => respond(i, { choice: o.value }))) : r.type === "approve" ? [Button(t("respond.approve", "Approve"), () => respond(i, { approved: true })), Button(t("respond.deny", "Deny"), () => respond(i, { approved: false }))] : r.type === "confirm" ? [Button(t("respond.confirm", "Confirm"), () => respond(i, { confirmed: true })), Button(t("respond.cancel", "Cancel"), () => respond(i, { confirmed: false }))] : [];
    return entries.length ? Menu(t("action.respond", "Respond"), entries) : null;
  }
  function itemMenu(i) {
    const views = [];
    if (i.open)
      views.push(Button(t("action.open", "Open"), () => openItem(i)));
    const answer = respondMenu(i);
    if (answer)
      views.push(answer);
    views.push(Button(t("action.done", "Mark as Done"), () => markDone([i])));
    views.push(i.snoozedUntil ? Button(t("action.unsnooze", "Unsnooze"), () => reopen([i])) : snoozeMenu(() => [i]));
    if (i.seenAt === null)
      views.push(Button(t("action.markSeen", "Mark as Seen"), () => markSeen([i])));
    return views;
  }
  function ItemRow(item, options) {
    return Row({
      title: () => item().title,
      subtitle: () => subtitleOf(item(), Date.now()),
      symbol: () => itemSymbol(item()),
      tint: () => itemTint(item()),
      unread: () => item().seenAt === null,
      selected: () => options.selectedId ? options.selectedId() === item().id : false
    }).help(() => [kindLabel(item()), item().title, item().body ?? ""].filter(Boolean).join(`
`)).onTap(() => options.tapOpens || !options.onSelect ? openItem(item()) : options.onSelect(item().id)).contextMenu(() => itemMenu(item()));
  }
  function filterSummary() {
    const f = filters();
    const label = f.showSnoozed ? t("snoozed.title", "Snoozed") : filterLabel(f.source);
    const parts = [label];
    if (f.needsResponseOnly)
      parts.push(t("filter.needsResponseShort", "Needs you"));
    if (f.unseenOnly)
      parts.push(t("filter.unseenShort", "Unseen"));
    return parts.join(" · ");
  }
  function FilterMenu() {
    return Menu(filterSummary, []).contextMenu(() => filterChoices());
  }
  function filterChoices() {
    const f = filters();
    const sources = ["all", "agent", "integration", "other"];
    const g = groupBy();
    return [
      ...sources.map((s) => Button(filterLabel(s), () => setFilters({ source: s, showSnoozed: false })).disabled(f.source === s && !f.showSnoozed)),
      Divider(),
      Button(f.needsResponseOnly ? t("filter.everything", "Show Everything") : t("filter.needsResponse", "Show Only What Needs a Response"), () => setFilters({ needsResponseOnly: !f.needsResponseOnly })),
      Button(f.unseenOnly ? t("filter.showSeen", "Show Seen Items") : t("filter.unseenOnly", "Show Unseen Only"), () => setFilters({ unseenOnly: !f.unseenOnly })),
      Button(f.showSnoozed ? t("snoozed.hide", "Hide Snoozed") : t("snoozed.show", "Show Snoozed"), () => setFilters({ showSnoozed: !f.showSnoozed })),
      Divider(),
      Button(t("group.source", "Group by Source"), () => setGrouping("source")).disabled(g === "source"),
      Button(t("group.workspace", "Group by Workspace"), () => setGrouping("workspace")).disabled(g === "workspace"),
      Button(t("group.thread", "Group by Thread"), () => setGrouping("thread")).disabled(g === "thread"),
      Divider(),
      Button(t("action.markAllSeen", "Mark All as Seen"), () => markAllSeen()),
      Button(t("action.markAllDone", "Mark All as Done"), () => markDone(items()))
    ];
  }
  function Notices() {
    return Group([
      () => notice() ? HStack({ spacing: 6 }, [Icon("exclamationmark.triangle").color("secondary").font("caption"), Text(notice()).font("caption").color("secondary").lineLimit(2)]).paddingHorizontal(14).paddingVertical(2) : null
    ]);
  }
  function Empty() {
    return Group([
      () => {
        const err = feedError();
        if (err && items().length === 0) {
          if (err.code === "operation.unsupported")
            return EmptyState({ title: t("feed.unavailable", "The feed is not available yet"), message: t("feed.unavailableHelp", "This version of cmux has no feed owner."), symbol: "tray" });
          if (err.code === "scope.missing")
            return EmptyState({ title: t("feed.notGranted", "Feed access not granted"), message: t("feed.notGrantedHelp", "Allow it in Settings > Apps > Inbox."), symbol: "lock" });
          return EmptyState({ title: t("feed.error", "Could not load the feed"), message: err.message, symbol: "exclamationmark.triangle" });
        }
        if (items().length > 0)
          return null;
        if (!loaded())
          return Text(t("loading", "Loading…")).font("caption").color("tertiary").paddingHorizontal(14).paddingVertical(6);
        const f = filters();
        if (f.source !== "all" || f.unseenOnly || f.needsResponseOnly || f.showSnoozed)
          return EmptyState({ title: t("empty.filtered", "Nothing matches these filters"), symbol: "line.3.horizontal.decrease.circle" });
        return EmptyState({ title: t("empty.title", "Nothing needs you"), message: t("empty.message", "Agents, apps and integrations are all clear."), symbol: "checkmark.circle" });
      }
    ]);
  }
  function SnoozedFooter() {
    return Group([
      () => {
        const n = counts()?.snoozed ?? 0;
        const showing = filters().showSnoozed;
        if (n === 0 && !showing)
          return null;
        const title = showing ? t("snoozed.hide", "Hide Snoozed") : t("snoozed.count", "{n} snoozed", { n });
        return HStack([Icon(showing ? "chevron.left" : "moon.zzz").font("caption").color("tertiary"), Text(title).font("caption").color("secondary"), Spacer()]).paddingHorizontal(14).paddingVertical(4).cursor("pointer").onTap(() => setFilters({ showSnoozed: !showing }));
      }
    ]);
  }
  var hasUnseen = computed(() => (counts()?.unseen ?? 0) > 0);
  function UnseenBadge() {
    return Group([() => hasUnseen() ? Badge(() => counts()?.unseen ?? 0, () => (counts()?.needsResponse ?? 0) > 0 ? "warning" : "secondary") : null]);
  }
  var MENU_ITEMS = 8;
  var [menuItems, setMenuItems] = signal([]);
  function loadTop() {
    feed.list({ filter: { status: ["open"] }, limit: MENU_ITEMS }).then((r) => setMenuItems(r.items)).catch(() => setMenuItems([]));
  }
  function StatusItem() {
    attachCounts();
    effect(() => {
      counts();
      loadTop();
    });
    const needs = () => (counts()?.needsResponse ?? 0) > 0;
    return HStack({ spacing: 4 }, [Icon(() => (counts()?.open ?? 0) > 0 ? "tray.full" : "tray").color(() => needs() ? "warning" : "secondary"), UnseenBadge()]).paddingHorizontal(6).cornerRadius(6).hoverBackground("hover").help(() => {
      const c = counts();
      if (!c || c.open === 0)
        return t("status.none", "Nothing needs you");
      return t("status.summary", "{unseen} unseen, {needs} need a response", { unseen: c.unseen, needs: c.needsResponse });
    }).onTap(() => {
      const list = menuItems();
      const next = list.find((i) => i.seenAt === null) ?? list[0];
      return next ? openItem(next) : undefined;
    }).contextMenu(() => {
      const list = menuItems();
      return [
        ...list.length ? list.map((i) => Button([kindLabel(i), i.title].filter(Boolean).join(": "), () => openItem(i))) : [Button(t("status.none", "Nothing needs you")).disabled()],
        Divider(),
        Button(t("action.markAllSeen", "Mark All as Seen"), () => markAllSeen().catch((e) => noticeFor(describe(e))))
      ];
    });
  }
  var formKey = (i) => i ? `${i.id}:${i.needsResponse ? i.response?.type ?? "none" : "none"}` : "";
  function detailState() {
    let latest = null;
    effect(() => {
      latest = current();
    });
    const id = computed(() => current()?.id ?? null);
    const has = computed(() => id() !== null);
    const form = computed(() => formKey(current()));
    const hasBody = computed(() => !!current()?.body);
    const [draft, setDraft] = signal("");
    return { item: current, peek: () => latest, id, has, form, hasBody, draft, setDraft };
  }
  var BLANK = {
    id: "",
    kind: "notify",
    title: "",
    urgency: "normal",
    needsResponse: false,
    source: { kind: "app", id: "", name: "" },
    subject: {},
    status: "open",
    snoozedUntil: null,
    seenAt: null,
    createdAt: "",
    updatedAt: "",
    revision: "",
    expiresAt: null,
    actions: []
  };
  var get = (s) => s.item() ?? BLANK;
  var act = (s, fn) => () => {
    const i = s.item();
    return i ? fn(i) : undefined;
  };
  function responseControls(s, schema) {
    const answer = (value) => act(s, (i) => respond(i, value));
    switch (schema.type) {
      case "choice":
        return VStack({ spacing: 4 }, schema.options.map((o) => {
          const b = Button(o.label, answer({ choice: o.value }));
          return o.destructive ? b.destructive() : b;
        }));
      case "approve":
        return HStack({ spacing: 8 }, [Button(t("respond.approve", "Approve"), answer({ approved: true })), Button(t("respond.deny", "Deny"), answer({ approved: false })).destructive(), Spacer()]);
      case "confirm":
        return HStack({ spacing: 8 }, [Button(t("respond.confirm", "Confirm"), answer({ confirmed: true })), Button(t("respond.cancel", "Cancel"), answer({ confirmed: false })), Spacer()]);
      case "text":
        return TextField(s.draft, {
          placeholder: schema.placeholder ?? t("respond.placeholder", "Answer…"),
          onEdit: (text) => s.setDraft(text),
          onSubmit: (text) => act(s, (i) => {
            if (!text.trim())
              return;
            s.setDraft("");
            return respond(i, { text: text.trim() });
          })()
        });
      case "external":
        return VStack({ spacing: 6 }, [
          Button(t("respond.continueInBrowser", "Continue in Browser"), act(s, openItem)),
          Text(t("respond.externalHelp", "Finish it in the browser tab that opens next to this one. The agent continues after; it never sees the credential.")).font("caption").color("tertiary").lineLimit(3)
        ]);
    }
  }
  function ResponseForm(s) {
    return Group([
      () => {
        s.form();
        const i = s.peek();
        return i?.needsResponse && i.response ? responseControls(s, i.response) : null;
      }
    ]);
  }
  function Actions(s, withSkip) {
    return HStack({ spacing: 8 }, [
      Group([() => s.form() && s.peek()?.open && s.peek()?.response?.type !== "external" ? Button(t("action.open", "Open"), act(s, openItem)) : null]),
      Button(t("action.doneShort", "Done"), act(s, (i) => markDone([i]))),
      snoozeMenu(() => s.item() ? [s.item()] : []),
      Group([
        () => {
          s.form();
          const custom = (s.peek()?.actions ?? []).filter((a) => a.kind === "custom");
          return custom.length ? Menu(t("action.more", "More"), custom.map((a) => Button(a.title, act(s, (i) => runAction(i, a))))) : null;
        }
      ]),
      Spacer(),
      withSkip ? Button(t("action.skip", "Skip"), () => step(1, s.id())) : null
    ]);
  }
  function Summary(s, titleFont) {
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 6 }, [
        Icon(() => itemSymbol(get(s))).color(() => itemTint(get(s))).font("caption"),
        Text(() => [kindLabel(get(s)), get(s).source.name, get(s).subject.workspaceName].filter(Boolean).join(" · ")).font("caption").color("secondary").lineLimit(1),
        Spacer(),
        Text(() => get(s).updatedAt ? ago(Date.parse(get(s).updatedAt), Date.now()) : "").font("caption").color("tertiary")
      ]),
      Text(() => get(s).title).font(titleFont).lineLimit(4),
      () => s.hasBody() ? Text(() => get(s).body ?? "").font("callout").color("secondary").lineLimit(10).padding(8).frame({ maxWidth: "infinity" }).background("hover").cornerRadius(6) : null
    ]);
  }
  function Detail(s) {
    return Group([
      () => s.has() ? VStack({ spacing: 12 }, [Summary(s, "headline"), ResponseForm(s), Actions(s, false)]) : Text(t("detail.none", "Select an item")).font("callout").color("tertiary").padding(12)
    ]);
  }
  function Toolbar() {
    return HStack({ spacing: 6 }, [
      FilterMenu(),
      Spacer(),
      UnseenBadge(),
      Button(Icon("checkmark.circle").color("secondary"), () => markAllSeen()).help(t("action.markAllSeen", "Mark All as Seen"))
    ]).paddingHorizontal(12).paddingVertical(2);
  }
  function renderGrouped(wide) {
    attachList(true);
    const root = VStack({ spacing: 2 }, [
      Toolbar(),
      Notices(),
      ForEach({ items: groups, key: (g) => g.key }, (g) => VStack({ spacing: 0 }, [
        Group([
          () => g().label || g().sourceKind ? HStack({ spacing: 4 }, [
            Text(() => g().sourceKind && g().key === g().sourceKind ? sourceKindLabel(g().sourceKind) : g().label).font("caption").weight("semibold").color("secondary").lineLimit(1),
            Spacer(),
            Text(() => String(g().items.length)).font("caption").color("tertiary")
          ]).padding({ top: 6, bottom: 2, leading: 14, trailing: 14 }) : null
        ]),
        ForEach({ items: () => g().items, key: (i) => i.id }, (i) => ItemRow(i, { tapOpens: true }))
      ])),
      Empty(),
      SnoozedFooter()
    ]);
    return wide ? root.frame({ maxWidth: 720 }) : root;
  }
  function Chip(symbol, label, active, action) {
    return Button(Icon(symbol).font("caption").color(() => active() ? "primary" : "secondary"), action).padding(5).background(() => active() ? "selected" : null).hoverBackground("hover").cornerRadius(6).help(label);
  }
  var CHIP_SYMBOLS = { all: "tray", agent: "sparkles", integration: "link", other: "square.grid.2x2" };
  function ChipBar() {
    const sources = ["all", "agent", "integration", "other"];
    return HStack({ spacing: 2 }, [
      ...sources.map((s) => Chip(CHIP_SYMBOLS[s], filterLabel(s), () => filters().source === s && !filters().showSnoozed, () => setFilters({ source: s, showSnoozed: false }))),
      Spacer(),
      Chip("hand.raised", t("filter.needsResponse", "Show Only What Needs a Response"), () => filters().needsResponseOnly, () => setFilters({ needsResponseOnly: !filters().needsResponseOnly })),
      Chip("envelope.badge", t("filter.unseenOnly", "Show Unseen Only"), () => filters().unseenOnly, () => setFilters({ unseenOnly: !filters().unseenOnly })),
      Chip("checkmark.circle", t("action.markAllSeen", "Mark All as Seen"), () => false, () => markAllSeen())
    ]).paddingHorizontal(10);
  }
  function renderFocus(wide) {
    attachList(false);
    const detail = detailState();
    const list = VStack({ spacing: 2 }, [
      ChipBar(),
      Notices(),
      ForEach({ items, key: (i) => i.id }, (i) => ItemRow(i, { tapOpens: false, selectedId: () => current()?.id ?? null, onSelect: setSelected })),
      Empty(),
      SnoozedFooter()
    ]);
    if (wide)
      return HStack({ spacing: 0 }, [VStack([list, Spacer()]).frame({ width: 320, maxHeight: "infinity" }), Divider(), VStack([Detail(detail), Spacer()]).padding(16).frame({ maxWidth: "infinity", maxHeight: "infinity" })]);
    return VStack({ spacing: 8 }, [list, Divider(), Detail(detail).paddingHorizontal(12)]);
  }
  function renderCard(wide) {
    attachList(false);
    const detail = detailState();
    const position = computed(() => {
      const list = items();
      const index = list.findIndex((i) => i.id === (selected() ?? list[0]?.id));
      return list.length ? t("card.position", "{index} of {total}", { index: Math.max(0, index) + 1, total: list.length }) : "";
    });
    const card = VStack({ spacing: 12 }, [Summary(detail, "title3"), ResponseForm(detail), Actions(detail, true)]).padding(14).background("hover").borderColor("separator").borderWidth(1).cornerRadius(10);
    const root = VStack({ spacing: 8 }, [
      HStack({ spacing: 6 }, [FilterMenu(), Spacer(), Text(position).font("caption").color("tertiary")]).paddingHorizontal(12),
      Notices(),
      Group([() => detail.has() ? card : null]).paddingHorizontal(10),
      Empty(),
      SnoozedFooter()
    ]);
    return wide ? root.frame({ maxWidth: 560 }) : root;
  }
  var RENDERERS = { grouped: renderGrouped, focus: renderFocus, card: renderCard };
  var surface = (wide) => VStack([ForEach({ items: () => [variant()], key: (v) => v }, (v) => RENDERERS[v()](wide))]);
  function renderInbox(ctx = {}) {
    return surface(ctx.surface === "pane");
  }
  function renderPane() {
    return surface(true);
  }
  function renderStatus() {
    return StatusItem();
  }
  function commandError(code, message) {
    const E = CmuxError;
    return new E(code, message);
  }
  async function findItem(id) {
    if (typeof id === "string" && id) {
      try {
        return await feed.get(id);
      } catch {
        throw commandError("item.not_found", t("item.notFound", "No inbox item {id}", { id }));
      }
    }
    if (items().length === 0)
      await listNow();
    const item = current();
    if (!item)
      throw commandError("item.not_found", t("item.noneSelected", "No inbox item is selected"));
    return item;
  }
  async function openInbox() {
    try {
      await cmux.call("app.pane.open", { contribution: `${cmux.app.id}#pane` });
      return { opened: true };
    } catch (e) {
      throw commandError(e.code ?? "operation.failed", t("pane.unsupported", "This cmux cannot open app panes yet; use the Inbox sidebar section."));
    }
  }
  async function markAllSeen2() {
    return { marked: await markAllSeen() };
  }
  async function move(direction, args) {
    if (items().length === 0)
      await listNow();
    const item = step(direction);
    if (item && args.open !== false)
      await openItem(item);
    return { id: item?.id ?? null };
  }
  var nextItem = (args = {}) => move(1, args);
  var previousItem = (args = {}) => move(-1, args);
  async function openItem2(args = {}) {
    const item = await findItem(args.id);
    setSelected(item.id);
    await openItem(item);
    return { id: item.id };
  }
  async function markDone2(args = {}) {
    const item = await findItem(args.id);
    await markDone([item]);
    return { id: item.id, done: true };
  }
  async function snooze(args = {}) {
    const item = await findItem(args.id);
    const minutes = typeof args.minutes === "number" && args.minutes > 0 ? Math.min(args.minutes, 60 * 24 * 30) : 60;
    const until = Date.now() + minutes * 60000;
    await snoozeItems([item], until);
    return { id: item.id, until: new Date(until).toISOString() };
  }
  async function list(args = {}) {
    const base = listParams(false);
    const r = await feed.list({
      filter: {
        status: args.includeSnoozed ? ["open", "snoozed"] : ["open"],
        ...args.source ? { sources: [args.source] } : {},
        ...args.needsResponse ? { needsResponse: true } : {},
        ...args.unseen ? { unseen: true } : {}
      },
      limit: typeof args.limit === "number" ? Math.max(1, Math.min(args.limit, 200)) : base.limit
    });
    return {
      items: r.items.map((i) => ({
        id: i.id,
        kind: i.kind,
        request_kind: i.requestKind ?? null,
        title: i.title,
        body: i.body ?? null,
        urgency: i.urgency,
        needs_response: i.needsResponse,
        source: i.source,
        subject: i.subject,
        status: i.status,
        seen: i.seenAt !== null,
        snoozed_until: i.snoozedUntil,
        updated_at: i.updatedAt
      })),
      counts: r.counts,
      revision: r.revision
    };
  }
  async function refresh() {
    const r = await listNow();
    return { items: r.items.length, revision: r.revision };
  }
  async function cycleVariant2() {
    return { variant: await cycleVariant() };
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
