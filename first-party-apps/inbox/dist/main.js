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
    markAllRead: () => markAllRead2,
    markDone: () => markDone2,
    nextItem: () => nextItem,
    openInbox: () => openInbox,
    openItem: () => openItem2,
    previousItem: () => previousItem,
    renderInbox: () => renderInbox,
    renderPane: () => renderPane,
    renderStatus: () => renderStatus,
    snooze: () => snooze
  });
  var FEED_STREAM = "feed";
  var isOpenRequest = (i) => i.type === "request" && i.state === "open";
  var feed = {
    list: (params) => cmux.call("feed.list", params),
    get: (item) => cmux.call("feed.get", { item }).then((r) => r.item),
    counts: () => cmux.call("feed.counts", {}),
    read: (selection) => cmux.call("feed.read", selection),
    archive: (selection) => cmux.call("feed.archive", selection),
    unarchive: (items) => cmux.call("feed.unarchive", { items }),
    snooze: (items, until) => cmux.call("feed.snooze", { items, until }),
    answer: (item, answer, gesture) => cmux.call("feed.answer", { item, answer }, { gesture }),
    decline: (item, gesture) => cmux.call("feed.cancel", { item, reason: "declined" }, { gesture })
  };
  // first-party-apps/inbox/strings/en.json
  var en_default = {
    "action.answer": "Answer",
    "action.decline": "Decline",
    "action.done": "Mark as Done",
    "action.doneShort": "Done",
    "action.markAllDone": "Mark All as Done",
    "action.markAllRead": "Mark All as Read",
    "action.markRead": "Mark as Read",
    "action.open": "Open",
    "action.skip": "Skip",
    "action.snooze": "Snooze",
    "action.unarchive": "Move Back to Inbox",
    "ago.d": "{n}d",
    "ago.h": "{n}h",
    "ago.m": "{n}m",
    "ago.now": "now",
    "ago.w": "{n}w",
    "answer.allow": "Allow",
    "answer.allowAlways": "Always Allow",
    "answer.allowSession": "Allow for Session",
    "answer.approveReview": "Approve",
    "answer.browserHelp": "Finish it in the copy of the agent's tab that opens next to it. The agent continues after; it never sees the credential.",
    "answer.comment": "Comment (optional)",
    "answer.confirm": "Confirm",
    "answer.continueInBrowser": "Continue in Browser",
    "answer.deny": "Deny",
    "answer.needsTap": "Answer from the inbox or the feed: only you answer requests.",
    "answer.other": "Other…",
    "answer.placeholder": "Answer…",
    "answer.reject": "No",
    "answer.requestChanges": "Request Changes",
    "answer.resume": "Let the Agent Resume",
    "answer.send": "Send",
    "answer.takeOver": "Take Over",
    "answer.unsupported": "Open this request to answer it.",
    "card.position": "{index} of {total}",
    "command.refused": "The feed did not accept that.",
    "day.0": "Sun",
    "day.1": "Mon",
    "day.2": "Tue",
    "day.3": "Wed",
    "day.4": "Thu",
    "day.5": "Fri",
    "day.6": "Sat",
    "detail.none": "Select an item",
    "done.empty": "Nothing is done yet",
    "done.hide": "Back to Inbox",
    "done.show": "Show Done",
    "done.title": "Done",
    "empty.filtered": "Nothing matches these filters",
    "empty.message": "Agents, apps and integrations are all clear.",
    "empty.title": "Nothing needs you",
    "error.feed": "The feed did not accept that: {reason}",
    "feed.error": "Could not load the feed",
    "feed.notGranted": "Feed access not granted",
    "feed.notGrantedHelp": "Allow it in Settings > Apps > Inbox.",
    "feed.unavailable": "The feed is not available yet",
    "feed.unavailableHelp": "This version of cmux has no feed owner.",
    "filter.everything": "Show Everything",
    "filter.needsResponse": "Show Only What Needs an Answer",
    "filter.needsResponseShort": "Needs you",
    "filter.showRead": "Show Read Items",
    "filter.unreadOnly": "Show Unread Only",
    "filter.unreadShort": "Unread",
    "group.none": "Other",
    "group.poster": "Group by Sender",
    "group.thread": "Group by Thread",
    "group.workspace": "Group by Workspace",
    "item.noneSelected": "No inbox item is selected",
    "item.notFound": "No inbox item {id}",
    "kind.approve": "Approval",
    "kind.choice": "Choose",
    "kind.confirm": "Confirm",
    "kind.custom": "Request",
    "kind.file": "File",
    "kind.handoff": "Handoff",
    "kind.input": "Input",
    "kind.passkey": "Passkey",
    "kind.question": "Question",
    "kind.review": "Review",
    "kind.sign-in": "Sign-in",
    loading: "Loading…",
    "open.unsupported": "This version of cmux cannot open feed items yet.",
    "pane.unsupported": "This cmux cannot open app panes yet; use the Inbox sidebar section.",
    "reason.closed": "it was already answered, declined or expired",
    "reason.scope": "permission not granted",
    "reason.unsupported": "not supported by this version of cmux",
    "request.cannotTriage": "Answer or decline an open request; it cannot be marked done or snoozed.",
    "snooze.2h": "In 2 hours ({time})",
    "snooze.30m": "In 30 minutes ({time})",
    "snooze.nextWeek": "Next week ({time})",
    "snooze.tomorrow": "Tomorrow ({time})",
    "snooze.until": "Snoozed until {time}",
    "source.agent": "Agents",
    "source.all": "All",
    "source.app": "Apps",
    "source.automation": "Automations",
    "source.harness": "Agents",
    "source.integration": "Integrations",
    "source.server": "Servers",
    "source.system": "cmux",
    "source.user": "People",
    "source.vm": "Cloud VMs",
    "state.answered": "Answered · {time}",
    "state.cancelled": "Withdrawn",
    "state.declined": "Declined",
    "state.expired": "Expired",
    "status.none": "Nothing needs you",
    "status.summary": "{unread} unread, {needs} waiting for you",
    "time.tomorrow": "Tomorrow {time}",
    "time.weekday": "{day} {time}"
  };
  // first-party-apps/inbox/strings/ja.json
  var ja_default = {
    "action.answer": "回答",
    "action.decline": "辞退",
    "action.done": "完了にする",
    "action.doneShort": "完了",
    "action.markAllDone": "すべて完了にする",
    "action.markAllRead": "すべて既読にする",
    "action.markRead": "既読にする",
    "action.open": "開く",
    "action.skip": "スキップ",
    "action.snooze": "スヌーズ",
    "action.unarchive": "受信トレイに戻す",
    "ago.d": "{n}日",
    "ago.h": "{n}時間",
    "ago.m": "{n}分",
    "ago.now": "今",
    "ago.w": "{n}週",
    "answer.allow": "許可",
    "answer.allowAlways": "常に許可",
    "answer.allowSession": "このセッションで許可",
    "answer.approveReview": "承認",
    "answer.browserHelp": "エージェントのタブの隣に開くコピーで完了してください。エージェントはその後に再開し、認証情報を見ることはありません。",
    "answer.comment": "コメント(任意)",
    "answer.confirm": "確認",
    "answer.continueInBrowser": "ブラウザで続ける",
    "answer.deny": "拒否",
    "answer.needsTap": "受信トレイかフィードから回答してください。リクエストに回答できるのはあなただけです。",
    "answer.other": "その他…",
    "answer.placeholder": "回答…",
    "answer.reject": "いいえ",
    "answer.requestChanges": "変更を依頼",
    "answer.resume": "エージェントに再開させる",
    "answer.send": "送信",
    "answer.takeOver": "引き継ぐ",
    "answer.unsupported": "回答するにはこのリクエストを開いてください。",
    "card.position": "{index} / {total}",
    "command.refused": "フィードが受け付けませんでした。",
    "day.0": "日",
    "day.1": "月",
    "day.2": "火",
    "day.3": "水",
    "day.4": "木",
    "day.5": "金",
    "day.6": "土",
    "detail.none": "項目を選んでください",
    "done.empty": "完了した項目はありません",
    "done.hide": "受信トレイに戻る",
    "done.show": "完了を表示",
    "done.title": "完了",
    "empty.filtered": "このフィルターに一致する項目はありません",
    "empty.message": "エージェント、アプリ、連携はすべて片付いています。",
    "empty.title": "対応が必要なものはありません",
    "error.feed": "フィードが受け付けませんでした: {reason}",
    "feed.error": "フィードを読み込めません",
    "feed.notGranted": "フィードへのアクセスが許可されていません",
    "feed.notGrantedHelp": "設定 > アプリ > 受信トレイ で許可してください。",
    "feed.unavailable": "フィードはまだ利用できません",
    "feed.unavailableHelp": "このバージョンの cmux にはフィードの管理元がありません。",
    "filter.everything": "すべて表示",
    "filter.needsResponse": "回答が必要なものだけ表示",
    "filter.needsResponseShort": "要対応",
    "filter.showRead": "既読も表示",
    "filter.unreadOnly": "未読のみ表示",
    "filter.unreadShort": "未読",
    "group.none": "その他",
    "group.poster": "送信元別にまとめる",
    "group.thread": "スレッド別にまとめる",
    "group.workspace": "ワークスペース別にまとめる",
    "item.noneSelected": "受信トレイの項目が選択されていません",
    "item.notFound": "受信トレイに {id} はありません",
    "kind.approve": "承認",
    "kind.choice": "選択",
    "kind.confirm": "確認",
    "kind.custom": "リクエスト",
    "kind.file": "ファイル",
    "kind.handoff": "引き継ぎ",
    "kind.input": "入力",
    "kind.passkey": "パスキー",
    "kind.question": "質問",
    "kind.review": "レビュー",
    "kind.sign-in": "サインイン",
    loading: "読み込み中…",
    "open.unsupported": "このバージョンの cmux はフィードの項目をまだ開けません。",
    "pane.unsupported": "このバージョンの cmux はアプリのペインをまだ開けません。サイドバーのセクションを使ってください。",
    "reason.closed": "すでに回答、辞退、または期限切れです",
    "reason.scope": "許可されていません",
    "reason.unsupported": "このバージョンの cmux では使えません",
    "request.cannotTriage": "未回答のリクエストは回答か辞退をしてください。完了やスヌーズにはできません。",
    "snooze.2h": "2時間後 ({time})",
    "snooze.30m": "30分後 ({time})",
    "snooze.nextWeek": "来週 ({time})",
    "snooze.tomorrow": "明日 ({time})",
    "snooze.until": "{time} までスヌーズ",
    "source.agent": "エージェント",
    "source.all": "すべて",
    "source.app": "アプリ",
    "source.automation": "オートメーション",
    "source.harness": "エージェント",
    "source.integration": "連携",
    "source.server": "サーバー",
    "source.system": "cmux",
    "source.user": "ユーザー",
    "source.vm": "クラウドVM",
    "state.answered": "回答済み · {time}",
    "state.cancelled": "取り下げ",
    "state.declined": "辞退済み",
    "state.expired": "期限切れ",
    "status.none": "対応が必要なものはありません",
    "status.summary": "未読 {unread} 件、回答待ち {needs} 件",
    "time.tomorrow": "明日 {time}",
    "time.weekday": "{day} {time}"
  };
  var TABLES = { en: en_default, ja: ja_default };
  var EN = en_default;
  var forced = null;
  var hostLocale = () => {
    try {
      return typeof cmux !== "undefined" && cmux.app.locale ? cmux.app.locale : "en";
    } catch {
      return "en";
    }
  };
  var language = () => (forced ?? hostLocale()).toLowerCase().split("-")[0] ?? "en";
  var fill = (s, params) => s.replace(/\{(\w+)\}/g, (whole, name) => (name in params) ? String(params[name]) : whole);
  function t(key, params = {}) {
    const fallback = TABLES[language()]?.[key] ?? EN[key] ?? key;
    if (forced === null && typeof cmux !== "undefined" && typeof cmux.t === "function")
      return cmux.t(key, fallback, params);
    return fill(fallback, params);
  }
  var PRIORITY_RANK = { urgent: 0, high: 1, normal: 2, low: 3 };
  var active = (i) => i.state === "open" && i.archived_at === null;
  function urgentCompare(a, b) {
    const tier = (i) => i.type === "request" && i.state === "open" ? 0 : active(i) && i.read_at === null ? 1 : 2;
    const ta = tier(a);
    const tb = tier(b);
    if (ta !== tb)
      return ta - tb;
    if (ta === 0)
      return (PRIORITY_RANK[a.priority] ?? 2) - (PRIORITY_RANK[b.priority] ?? 2) || a.order - b.order;
    return b.order - a.order;
  }
  var matchesFilter = (i, f) => (f.poster_kind === undefined || i.poster.kind === f.poster_kind) && (f.thread === undefined || i.thread === f.thread) && (f.workspace === undefined || i.context.workspace === f.workspace) && (f.kind === undefined || i.kind === f.kind);
  function inView(i, p, now) {
    const stateOk = p.state === undefined || p.state === "all" ? true : p.state === "open" ? i.state === "open" : i.state !== "open";
    return stateOk && (p.type === undefined || i.type === p.type) && matchesFilter(i, p) && (p.unread === undefined || i.read_at === null === p.unread) && (p.needs_response === undefined || (i.type === "request" && i.state === "open") === p.needs_response) && (p.archived === true ? i.archived_at !== null : i.archived_at === null) && (p.archived === true || i.snoozed_until === null || i.snoozed_until <= now);
  }
  var touch = (i, at, change) => ({ ...i, ...change, revision: i.revision + 1, updated_at: at });
  function ruleFor(ev) {
    const p = ev.params ?? {};
    const at = ev.at;
    const ids = Array.isArray(p.items) ? new Set(p.items) : null;
    const filter = p.filter && typeof p.filter === "object" ? p.filter : null;
    const selected = (i) => ids ? ids.has(i.id) : filter ? matchesFilter(i, filter) : p.all === true;
    const open = (i) => i.type === "request" && i.state === "open";
    switch (ev.op) {
      case "feed.answer":
        return (i) => i.id === p.item && open(i) ? touch(i, at, { state: "answered", answer: { value: p.answer, by: ev.actor.identity, device: typeof p.device === "string" ? p.device : null, at }, closed_at: at, read_at: i.read_at ?? at }) : null;
      case "feed.cancel":
        return (i) => i.id === p.item && i.state === "open" ? touch(i, at, { state: "cancelled", cancel: { reason: p.reason ?? "poster", by: ev.actor.identity, at, note: typeof p.note === "string" ? p.note : null }, closed_at: at }) : null;
      case "feed.read":
        return (i) => i.read_at === null && selected(i) ? touch(i, at, { read_at: at }) : null;
      case "feed.seen":
        return (i) => i.seen_at === null && selected(i) ? touch(i, at, { seen_at: at }) : null;
      case "feed.archive":
        return (i) => i.archived_at === null && selected(i) && !(filter && open(i)) ? touch(i, at, { archived_at: at, read_at: i.read_at ?? at, snoozed_until: null }) : null;
      case "feed.snooze":
        return (i) => selected(i) && i.snoozed_until !== p.until ? touch(i, at, { snoozed_until: Number(p.until) }) : null;
      case "feed.expire":
        return (i) => i.state === "open" && i.expires_at <= Number(p.at) ? touch(i, at, { state: "expired", closed_at: i.expires_at }) : null;
      case "feed.push_due":
      case "feed.prefs.set":
        return "none";
      default:
        return "relist";
    }
  }
  var ADDS_TO_DONE = new Set(["feed.archive"]);
  function applyEvent(page, ev, params, now) {
    const rule = ruleFor(ev);
    const recount = !["feed.seen", "feed.push_due", "feed.prefs.set"].includes(ev.op);
    if (rule === "none")
      return { page, relist: false, recount: false };
    if (rule === "relist")
      return { page, relist: true, recount };
    let changed = false;
    const patched = page.items.map((i) => {
      const next = rule(i);
      if (next)
        changed = true;
      return next ?? i;
    });
    const relist = params.archived === true && ADDS_TO_DONE.has(ev.op);
    if (!changed)
      return { page, relist, recount };
    const items = patched.filter((i) => inView(i, params, now)).sort(params.order === "recent" ? (a, b) => b.order - a.order : urgentCompare);
    const position = new Map(items.map((i, n) => [i.id, n]));
    const groups = page.groups?.map((g) => ({ ...g, items: g.items.filter((id) => position.has(id)).sort((a, b) => position.get(a) - position.get(b)) })).filter((g) => g.items.length > 0).sort((a, b) => position.get(a.items[0]) - position.get(b.items[0]));
    return { page: groups ? { items, groups } : { items }, relist, recount };
  }
  var VARIANTS = ["grouped", "focus", "card"];
  var DEFAULT_VARIANT = "grouped";
  var asVariant = (v) => VARIANTS.includes(v) ? v : DEFAULT_VARIANT;
  var asGroupBy = (v) => v === "workspace" || v === "thread" ? v : "poster";
  var readSettings = (raw) => ({ variant: asVariant(raw.variant), groupBy: asGroupBy(raw.groupBy) });
  var settings = () => readSettings(cmux.app.settings());
  var codeOf = (e) => e && typeof e === "object" && ("code" in e) ? String(e.code) : "";
  function describe(e) {
    const code = codeOf(e);
    if (code === "scope.missing")
      return t("reason.scope");
    if (code === "operation.unsupported")
      return t("reason.unsupported");
    if (code === "feed.closed")
      return t("reason.closed");
    return e instanceof Error ? e.message : String(e);
  }
  var SOURCES = ["all", "agent", "integration", "automation", "app", "system"];
  var DEFAULT_FILTERS = { source: "all", unreadOnly: false, needsResponseOnly: false, showDone: false };
  var LIST_LIMIT = 100;
  function listParamsFor(f, groupBy, limit = LIST_LIMIT) {
    const p = f.showDone ? { state: "all", archived: true, order: "recent" } : { state: "open", order: "urgent" };
    if (f.source !== "all")
      p.poster_kind = f.source;
    if (f.unreadOnly)
      p.unread = true;
    if (f.needsResponseOnly && !f.showDone)
      p.needs_response = true;
    if (groupBy)
      p.group_by = groupBy;
    p.limit = limit;
    return p;
  }
  var [filters, setFiltersSignal] = signal(DEFAULT_FILTERS);
  var [groupOverride, setGroupOverride] = signal(null);
  var groupBy = computed(() => groupOverride() ?? settings().groupBy);
  var variant = computed(() => settings().variant);
  var [selected, setSelected] = signal(null);
  var [notice, setNotice] = signal(null);
  var viewLoading = null;
  var persist = (key, value) => cmux.storage.set(key, value).catch((e) => cmux.log(`storage ${key}: ${describe(e)}`));
  function ensureView() {
    viewLoading ??= cmux.storage.get("view").catch(() => null).then((view) => {
      if (view?.filters)
        setFiltersSignal({ ...DEFAULT_FILTERS, ...view.filters, showDone: false });
      if (view?.groupBy)
        setGroupOverride(asGroupBy(view.groupBy));
    });
    return viewLoading;
  }
  var saveView = () => void persist("view", { filters: { ...filters(), showDone: false }, groupBy: groupOverride() });
  function setFilters(change) {
    setFiltersSignal({ ...filters(), ...change });
    saveView();
  }
  function setGrouping(by) {
    setGroupOverride(by);
    saveView();
  }
  var [counts, setCounts] = signal(null);
  var countsLoading = false;
  var countsAgain = false;
  function loadCounts() {
    if (countsLoading) {
      countsAgain = true;
      return;
    }
    countsLoading = true;
    feed.counts().then(setCounts).catch((e) => cmux.log(`feed.counts: ${describe(e)}`)).finally(() => {
      countsLoading = false;
      if (countsAgain) {
        countsAgain = false;
        loadCounts();
      }
    });
  }
  function createFeedView(params, options = {}) {
    const [page, setPageSignal] = signal(null);
    const [error, setError] = signal(null);
    const setPage = (p) => {
      setPageSignal(p);
      if (options.primary)
        setLatest(p.items);
    };
    let seq = 0;
    let lastSeq = 0;
    let queued = false;
    const reload = () => {
      const mine = ++seq;
      return feed.list(params()).then((r) => {
        const next = r.groups ? { items: r.items, groups: r.groups } : { items: r.items };
        if (mine === seq) {
          setPage(next);
          setError(null);
        }
        return next;
      }, (e) => {
        if (mine === seq)
          setError({ code: codeOf(e), message: describe(e) });
        throw e;
      });
    };
    const relistSoon = () => {
      if (queued)
        return;
      queued = true;
      Promise.resolve().then(() => {
        queued = false;
        reload().catch(() => {
          return;
        });
      });
    };
    cmux.events.on(FEED_STREAM, (payload) => {
      const ev = payload;
      if (!ev || typeof ev.op !== "string")
        return;
      if (typeof ev.seq === "number") {
        if (ev.seq <= lastSeq)
          return;
        lastSeq = ev.seq;
      }
      const current = page();
      if (current) {
        const patch = applyEvent(current, ev, params(), Date.now());
        if (patch.page !== current)
          setPage(patch.page);
        if (patch.relist)
          relistSoon();
      }
      if (!["feed.seen", "feed.push_due", "feed.prefs.set"].includes(ev.op))
        loadCounts();
    });
    if (counts() === null)
      loadCounts();
    effect(() => {
      params();
      reload().catch(() => {
        return;
      });
    });
    return {
      page,
      items: computed(() => page()?.items ?? []),
      error,
      loaded: computed(() => page() !== null || error() !== null),
      reload
    };
  }
  var mainParams = () => listParamsFor(filters(), variant() === "grouped" ? groupBy() : null);
  var [latest, setLatest] = signal([]);
  var items = latest;
  var current = computed(() => latest().find((i) => i.id === selected()) ?? latest()[0] ?? null);
  async function listNow() {
    await ensureView();
    const r = await feed.list(listParamsFor(filters(), null));
    setLatest(r.items);
    return r.items;
  }
  function groupsOf(view) {
    return computed(() => {
      const p = view.page();
      if (!p?.groups)
        return [{ key: "all", label: "", items: p?.items ?? [] }];
      const byId = new Map(p.items.map((i) => [i.id, i]));
      return p.groups.map((g) => ({ key: g.key, label: g.label, items: g.items.map((id) => byId.get(id)).filter((i) => !!i) })).filter((g) => g.items.length > 0);
    });
  }
  async function cycleVariant() {
    const next = VARIANTS[(VARIANTS.indexOf(variant()) + 1) % VARIANTS.length];
    await cmux.app.settings.set({ variant: next });
    return next;
  }
  function noticeFor(message) {
    setNotice(message);
    cmux.timer.after(6000, () => setNotice(null));
  }
  var quiet = (p) => p.then(() => true, (e) => {
    noticeFor(t("error.feed", { reason: describe(e) }));
    return false;
  });
  function openItem(item, api = cmux) {
    setSelected(item.id);
    return quiet(api.actions.run("feed.openItem", { item: item.id }).catch((e) => {
      throw codeOf(e) === "operation.unsupported" ? new Error(t("open.unsupported")) : e;
    }));
  }
  function userGesture(explicit) {
    const g = explicit ?? cmux.gesture();
    if (!g)
      noticeFor(t("answer.needsTap"));
    return g;
  }
  function answer(item, value, token) {
    const gesture = userGesture(token);
    if (!gesture)
      return Promise.resolve(false);
    moveSelectionOff([item.id]);
    return quiet(feed.answer(item.id, value, gesture));
  }
  function decline(item, token) {
    const gesture = userGesture(token);
    if (!gesture || !isOpenRequest(item))
      return Promise.resolve(false);
    moveSelectionOff([item.id]);
    return quiet(feed.decline(item.id, gesture));
  }
  var markRead = (list) => {
    const unread = list.filter((i) => i.read_at === null).map((i) => i.id);
    return unread.length ? quiet(feed.read({ items: unread })) : Promise.resolve(false);
  };
  function markDone(list) {
    const ids = list.filter((i) => !isOpenRequest(i)).map((i) => i.id);
    if (!ids.length)
      return Promise.resolve(false);
    moveSelectionOff(ids);
    return quiet(feed.archive({ items: ids }));
  }
  function snoozeItems(list, until) {
    const ids = list.filter((i) => !isOpenRequest(i)).map((i) => i.id);
    if (!ids.length)
      return Promise.resolve(false);
    moveSelectionOff(ids);
    return quiet(feed.snooze(ids, until));
  }
  var unarchive = (list) => quiet(feed.unarchive(list.map((i) => i.id)));
  var currentFilter = () => filters().source === "all" ? {} : { poster_kind: filters().source };
  var markAllRead = () => quiet(filters().source === "all" ? feed.read({ all: true }) : feed.read({ filter: currentFilter() }));
  var markAllDone = () => quiet(feed.archive({ filter: currentFilter() }));
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
  var obj = (v) => v && typeof v === "object" && !Array.isArray(v) ? v : {};
  var str = (v) => typeof v === "string" ? v : "";
  var strs = (v) => Array.isArray(v) ? v.filter((x) => typeof x === "string") : [];
  function fieldsOf(schema) {
    const s = obj(schema);
    if (s.type !== "object")
      return null;
    const required = new Set(strs(s.required));
    const out = [];
    for (const [key, raw] of Object.entries(obj(s.properties))) {
      const p = obj(raw);
      const title = str(p.title) || str(p.description) || key;
      const req = required.has(key);
      if (Array.isArray(p.enum))
        out.push({ key, title, type: "enum", options: strs(p.enum), multi: false, required: req });
      else if (p.type === "array" && Array.isArray(obj(p.items).enum))
        out.push({ key, title, type: "enum", options: strs(obj(p.items).enum), multi: true, required: req });
      else if (p.type === "string" || p.type === "number" || p.type === "integer" || p.type === "boolean")
        out.push({ key, title, type: p.type, required: req });
      else
        return null;
    }
    return out;
  }
  function formOf(item) {
    if (item.type !== "request" || item.state !== "open")
      return { kind: "none" };
    const p = obj(item.prompt);
    switch (item.kind) {
      case "question":
        return { kind: "question", question: str(p.question), suggestions: strs(p.suggestions) };
      case "choice": {
        const questions = (Array.isArray(p.questions) ? p.questions : []).map(obj).map((q) => ({
          id: str(q.id),
          question: str(q.question),
          header: str(q.header) || undefined,
          options: (Array.isArray(q.options) ? q.options : []).map(obj).map((o) => ({ id: str(o.id), label: str(o.label), description: str(o.description) || undefined })),
          multi: q.multi === true,
          allow_other: q.allow_other === true
        }));
        const only = questions[0];
        return { kind: "choice", questions, oneTap: questions.length === 1 && !!only && !only.multi && !only.allow_other };
      }
      case "approve": {
        const action = obj(p.action);
        const scopes = strs(p.scopes).filter((s) => s === "once" || s === "session" || s === "always");
        return { kind: "approve", summary: str(action.summary), command: str(action.command) || null, scopes: scopes.length ? scopes : ["once"] };
      }
      case "confirm":
        return { kind: "confirm", statement: str(p.statement), confirmLabel: str(p.confirm_label) || null, cancelLabel: str(p.cancel_label) || null, destructive: p.destructive === true };
      case "sign-in":
      case "passkey":
        return { kind: "browser", reason: str(p.reason), origin: str(p.origin) };
      case "review":
        return { kind: "review", subject: str(p.subject), ref: str(p.ref) };
      case "handoff":
        return { kind: "handoff", reason: str(p.reason) };
      case "input": {
        const fields = fieldsOf(p.schema);
        return fields ? { kind: "fields", fields } : { kind: "unsupported" };
      }
      case "file":
        return { kind: "unsupported" };
      default: {
        if (item.actions.some((a) => a.answer !== undefined))
          return { kind: "none" };
        const fields = item.kind.startsWith("x-") ? fieldsOf(item.answer_schema) : null;
        return fields ? { kind: "fields", fields } : { kind: "unsupported" };
      }
    }
  }
  var answerButtons = (item) => item.type === "request" && item.state === "open" ? item.actions.filter((a) => a.answer !== undefined) : [];
  var openButtons = (item) => item.actions.filter((a) => a.answer === undefined);
  var approveAnswer = (decision, scope) => decision === "allow" ? { decision, scope: scope ?? "once" } : { decision };
  function choiceAnswer(questions, selected, other = {}) {
    const answers = {};
    for (const q of questions) {
      const text = (other[q.id] ?? "").trim();
      answers[q.id] = text && q.allow_other ? { selected: selected[q.id] ?? [], other: text } : { selected: selected[q.id] ?? [] };
    }
    return { answers };
  }
  var choiceComplete = (questions, selected, other = {}) => questions.every((q) => (selected[q.id]?.length ?? 0) > 0 || q.allow_other && !!(other[q.id] ?? "").trim());
  function toggleOption(q, current, option) {
    if (!q.multi)
      return current[0] === option ? [] : [option];
    return current.includes(option) ? current.filter((o) => o !== option) : [...current, option];
  }
  function fieldsAnswer(fields, drafts) {
    const value = {};
    const missing = [];
    for (const f of fields) {
      const d = drafts[f.key];
      if (f.type === "boolean") {
        if (typeof d === "boolean")
          value[f.key] = d;
        else if (f.required)
          value[f.key] = false;
        continue;
      }
      if (f.type === "enum") {
        const picked = Array.isArray(d) ? d : typeof d === "string" ? [d] : [];
        if (picked.length)
          value[f.key] = f.multi ? picked : picked[0];
        else if (f.required)
          missing.push(f.key);
        continue;
      }
      const text = typeof d === "string" ? d.trim() : "";
      if (!text) {
        if (f.required)
          missing.push(f.key);
        continue;
      }
      if (f.type === "string")
        value[f.key] = text;
      else {
        const n = Number(text);
        if (!Number.isFinite(n) || f.type === "integer" && !Number.isInteger(n))
          missing.push(f.key);
        else
          value[f.key] = n;
      }
    }
    return { value, missing };
  }
  function ago(at, now) {
    const minutes = Math.floor(Math.max(0, now - at) / 60000);
    if (minutes < 1)
      return t("ago.now");
    if (minutes < 60)
      return t("ago.m", { n: minutes });
    const hours = Math.floor(minutes / 60);
    if (hours < 24)
      return t("ago.h", { n: hours });
    const days = Math.floor(hours / 24);
    if (days < 7)
      return t("ago.d", { n: days });
    return t("ago.w", { n: Math.floor(days / 7) });
  }
  var hhmm = (d) => `${d.getHours()}:${String(d.getMinutes()).padStart(2, "0")}`;
  var sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  function clock(until, now) {
    const d = new Date(until);
    const n = new Date(now);
    if (sameDay(d, n))
      return hhmm(d);
    const tomorrow = new Date(n.getFullYear(), n.getMonth(), n.getDate() + 1);
    if (sameDay(d, tomorrow))
      return t("time.tomorrow", { time: hhmm(d) });
    const day = d.getDay();
    return t("time.weekday", { day: t(`day.${day}`), time: hhmm(d) });
  }
  var MORNING_HOUR = 9;
  function snoozePresets(now) {
    const n = new Date(now);
    const tomorrow = new Date(n.getFullYear(), n.getMonth(), n.getDate() + 1, MORNING_HOUR).getTime();
    const daysToMonday = (8 - n.getDay()) % 7 || 7;
    const nextWeek = new Date(n.getFullYear(), n.getMonth(), n.getDate() + daysToMonday, MORNING_HOUR).getTime();
    const presets = [
      ["30m", now + 30 * 60000],
      ["2h", now + 2 * 3600000],
      ["tomorrow", tomorrow],
      ["nextWeek", nextWeek]
    ];
    return presets.map(([id, until]) => ({ id, until, label: t(`snooze.${id}`, { time: id === "tomorrow" ? hhmm(new Date(until)) : clock(until, now) }) }));
  }
  var BUILT_IN_KINDS = new Set(["question", "choice", "approve", "confirm", "sign-in", "passkey", "review", "input", "file", "handoff"]);
  function kindLabel(i) {
    if (i.type !== "request")
      return "";
    return BUILT_IN_KINDS.has(i.kind) ? t(`kind.${i.kind}`) : t("kind.custom");
  }
  var sourceLabel = (k) => t(`source.${k}`);
  var KIND_SYMBOLS = {
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
  var POSTER_SYMBOLS = { agent: "sparkles", harness: "sparkles", app: "app", server: "server.rack", vm: "cloud", automation: "play.circle", integration: "link", system: "gearshape", user: "person" };
  function itemSymbol(i) {
    if (i.type === "request")
      return KIND_SYMBOLS[i.kind] ?? "questionmark.bubble";
    if (i.priority === "urgent" || i.priority === "high")
      return "exclamationmark.triangle";
    return POSTER_SYMBOLS[i.poster.kind] ?? "bell";
  }
  function itemTint(i) {
    if (i.priority === "urgent")
      return "danger";
    if (isOpenRequest(i) || i.priority === "high")
      return "warning";
    return i.priority === "low" ? "tertiary" : "secondary";
  }
  function workspaceNames() {
    const live = cmux.live("workspace.list", {});
    const byId = computed(() => new Map((live() ?? []).map((w) => [w.id, w.name])));
    return (id) => id ? byId().get(id) ?? "" : "";
  }
  function subtitleOf(i, now, workspace) {
    let when = ago(i.updated_at, now);
    if (i.snoozed_until && i.snoozed_until > now)
      when = t("snooze.until", { time: clock(i.snoozed_until, now) });
    else if (i.state === "answered")
      when = t("state.answered", { time: ago(i.closed_at ?? i.updated_at, now) });
    else if (i.state === "cancelled")
      when = i.cancel?.reason === "declined" ? t("state.declined") : t("state.cancelled");
    else if (i.state === "expired")
      when = t("state.expired");
    return [kindLabel(i), when, i.poster.label, workspace(i.context.workspace)].filter(Boolean).join(" · ");
  }
  function snoozeMenu(list) {
    return Menu(t("action.snooze"), snoozePresets(Date.now()).map((p) => Button(p.label, () => snoozeItems(list(), p.until))));
  }
  function answerMenu(i) {
    if (!isOpenRequest(i))
      return null;
    const form = formOf(i);
    const entries = answerButtons(i).map((a) => Button(a.label, () => answer(i, a.answer)));
    if (form.kind === "approve") {
      entries.push(Button(t("answer.allow"), () => answer(i, approveAnswer("allow"))));
      if (form.scopes.includes("session"))
        entries.push(Button(t("answer.allowSession"), () => answer(i, approveAnswer("allow", "session"))));
      entries.push(Button(t("answer.deny"), () => answer(i, approveAnswer("deny"))));
    } else if (form.kind === "confirm") {
      entries.push(Button(form.confirmLabel ?? t("answer.confirm"), () => answer(i, { confirmed: true })));
      entries.push(Button(form.cancelLabel ?? t("answer.reject"), () => answer(i, { confirmed: false })));
    } else if (form.kind === "choice" && form.oneTap) {
      const q = form.questions[0];
      for (const o of q.options)
        entries.push(Button(o.label, () => answer(i, { answers: { [q.id]: { selected: [o.id] } } })));
    }
    return entries.length ? Menu(t("action.answer"), entries) : null;
  }
  function itemMenu(i) {
    const views = [Button(i.kind === "sign-in" || i.kind === "passkey" ? t("answer.continueInBrowser") : t("action.open"), () => openItem(i))];
    if (isOpenRequest(i)) {
      const answers = answerMenu(i);
      if (answers)
        views.push(answers);
      views.push(Button(t("action.decline"), () => decline(i)).destructive());
    } else if (i.archived_at !== null) {
      views.push(Button(t("action.unarchive"), () => unarchive([i])));
    } else {
      views.push(Button(t("action.done"), () => markDone([i])));
      views.push(snoozeMenu(() => [i]));
    }
    if (i.read_at === null)
      views.push(Button(t("action.markRead"), () => markRead([i])));
    return views;
  }
  function ItemRow(item, workspace, options) {
    return Row({
      title: () => item().title,
      subtitle: () => subtitleOf(item(), Date.now(), workspace),
      symbol: () => itemSymbol(item()),
      tint: () => itemTint(item()),
      unread: () => item().read_at === null,
      badge: () => item().count > 1 ? item().count : null,
      selected: () => options.selectedId ? options.selectedId() === item().id : false
    }).help(() => [kindLabel(item()), item().title, item().body].filter(Boolean).join(`
`)).onTap(() => options.tapOpens || !options.onSelect ? openItem(item()) : options.onSelect(item())).contextMenu(() => itemMenu(item()));
  }
  function filterSummary() {
    const f = filters();
    const parts = [f.showDone ? t("done.title") : sourceLabel(f.source)];
    if (f.needsResponseOnly && !f.showDone)
      parts.push(t("filter.needsResponseShort"));
    if (f.unreadOnly)
      parts.push(t("filter.unreadShort"));
    return parts.join(" · ");
  }
  function FilterMenu() {
    return Menu(filterSummary, []).contextMenu(() => filterChoices());
  }
  function filterChoices() {
    const f = filters();
    const g = groupBy();
    return [
      ...SOURCES.map((s) => Button(sourceLabel(s), () => setFilters({ source: s })).disabled(f.source === s)),
      Divider(),
      Button(f.needsResponseOnly ? t("filter.everything") : t("filter.needsResponse"), () => setFilters({ needsResponseOnly: !f.needsResponseOnly })).disabled(f.showDone),
      Button(f.unreadOnly ? t("filter.showRead") : t("filter.unreadOnly"), () => setFilters({ unreadOnly: !f.unreadOnly })),
      Button(f.showDone ? t("done.hide") : t("done.show"), () => setFilters({ showDone: !f.showDone })),
      Divider(),
      Button(t("group.poster"), () => setGrouping("poster")).disabled(g === "poster"),
      Button(t("group.workspace"), () => setGrouping("workspace")).disabled(g === "workspace"),
      Button(t("group.thread"), () => setGrouping("thread")).disabled(g === "thread"),
      Divider(),
      Button(t("action.markAllRead"), () => markAllRead()),
      Button(t("action.markAllDone"), () => markAllDone()).disabled(f.showDone)
    ];
  }
  function Notices() {
    return Group([
      () => notice() ? HStack({ spacing: 6 }, [Icon("exclamationmark.triangle").color("secondary").font("caption"), Text(notice()).font("caption").color("secondary").lineLimit(2)]).paddingHorizontal(14).paddingVertical(2) : null
    ]);
  }
  function Empty(view) {
    return Group([
      () => {
        const err = view.error();
        if (err && view.items().length === 0) {
          if (err.code === "operation.unsupported")
            return EmptyState({ title: t("feed.unavailable"), message: t("feed.unavailableHelp"), symbol: "tray" });
          if (err.code === "scope.missing")
            return EmptyState({ title: t("feed.notGranted"), message: t("feed.notGrantedHelp"), symbol: "lock" });
          return EmptyState({ title: t("feed.error"), message: err.message, symbol: "exclamationmark.triangle" });
        }
        if (view.items().length > 0)
          return null;
        if (!view.loaded())
          return Text(t("loading")).font("caption").color("tertiary").paddingHorizontal(14).paddingVertical(6);
        const f = filters();
        if (f.showDone)
          return EmptyState({ title: t("done.empty"), symbol: "checkmark.circle" });
        if (f.source !== "all" || f.unreadOnly || f.needsResponseOnly)
          return EmptyState({ title: t("empty.filtered"), symbol: "line.3.horizontal.decrease.circle" });
        return EmptyState({ title: t("empty.title"), message: t("empty.message"), symbol: "checkmark.circle" });
      }
    ]);
  }
  function DoneFooter() {
    return Group([
      () => {
        const showing = filters().showDone;
        return HStack([Icon(showing ? "chevron.left" : "archivebox").font("caption").color("tertiary"), Text(showing ? t("done.hide") : t("done.show")).font("caption").color("secondary"), Spacer()]).paddingHorizontal(14).paddingVertical(4).cursor("pointer").onTap(() => setFilters({ showDone: !showing }));
      }
    ]);
  }
  var badgeOf = (c) => !c ? null : c.open_requests > 0 ? { n: c.open_requests, tone: "warning" } : c.unread > 0 ? { n: c.unread, tone: "secondary" } : null;
  function CountBadge() {
    const badge = computed(() => badgeOf(counts()));
    const shown = computed(() => badge() !== null);
    return Group([() => shown() ? Badge(() => badge()?.n ?? 0, () => badge()?.tone ?? "secondary") : null]);
  }
  var MENU_ITEMS = 8;
  function StatusItem() {
    const top = createFeedView(() => ({ state: "open", order: "urgent", limit: MENU_ITEMS }));
    const waiting = () => (counts()?.open_requests ?? 0) > 0;
    return HStack({ spacing: 4 }, [Icon(() => top.items().length > 0 ? "tray.full" : "tray").color(() => waiting() ? "warning" : "secondary"), CountBadge()]).paddingHorizontal(6).cornerRadius(6).hoverBackground("hover").help(() => {
      const c = counts();
      if (!c || c.open_requests === 0 && c.unread === 0)
        return t("status.none");
      return t("status.summary", { unread: c.unread, needs: c.open_requests });
    }).onTap(() => {
      const next = top.items()[0];
      return next ? openItem(next) : undefined;
    }).contextMenu(() => {
      const list = top.items();
      return [
        ...list.length ? list.map((i) => Button([kindLabel(i), i.title].filter(Boolean).join(": "), () => openItem(i))) : [Button(t("status.none")).disabled()],
        Divider(),
        Button(t("action.markAllRead"), () => markAllRead())
      ];
    });
  }
  var formKey = (i) => i ? `${i.id}:${i.state}:${i.archived_at === null ? "active" : "done"}` : "";
  function detailState(current, workspace) {
    let latest = null;
    effect(() => {
      latest = current();
    });
    const id = computed(() => current()?.id ?? null);
    const form = computed(() => formKey(current()));
    const [drafts, setDrafts] = signal({});
    let draftsFor = "";
    effect(() => {
      const key = form();
      if (key !== draftsFor) {
        draftsFor = key;
        setDrafts({});
      }
    });
    return {
      item: current,
      peek: () => latest,
      id,
      has: computed(() => id() !== null),
      form,
      drafts,
      setDraft: (key, value) => setDrafts((d) => ({ ...d, [key]: value })),
      workspace
    };
  }
  var act = (s, fn) => () => {
    const i = s.peek();
    return i ? fn(i) : undefined;
  };
  var reply = (s, value) => act(s, (i) => answer(i, value));
  var caption = (text) => Text(text).font("caption").color("secondary").lineLimit(6);
  var option = (label, on, tap) => Button(label, tap).padding({ top: 3, bottom: 3, leading: 8, trailing: 8 }).background(() => on() ? "selected" : null).cornerRadius(6);
  function choiceControls(s, questions, oneTap) {
    if (oneTap) {
      const q = questions[0];
      return VStack({ spacing: 4 }, [caption(q.question), ...q.options.map((o) => Button(o.label, reply(s, { answers: { [q.id]: { selected: [o.id] } } })).help(o.description ?? o.label))]);
    }
    const selected = () => s.drafts().selected ?? {};
    const other = () => s.drafts().other ?? {};
    return VStack({ spacing: 8 }, [
      ...questions.map((q) => VStack({ spacing: 3 }, [
        caption(q.header ? `${q.header}: ${q.question}` : q.question),
        ...q.options.map((o) => option(o.label, () => (selected()[q.id] ?? []).includes(o.id), () => s.setDraft("selected", { ...selected(), [q.id]: toggleOption(q, selected()[q.id] ?? [], o.id) })).help(o.description ?? o.label)),
        q.allow_other ? TextField(() => other()[q.id] ?? "", { placeholder: t("answer.other"), onEdit: (text) => s.setDraft("other", { ...other(), [q.id]: text }) }) : null
      ])),
      HStack([Button(t("answer.send"), () => choiceComplete(questions, selected(), other()) ? reply(s, choiceAnswer(questions, selected(), other()))() : undefined).disabled(() => !choiceComplete(questions, selected(), other())), Spacer()])
    ]);
  }
  function fieldControl(s, f) {
    const value = () => s.drafts()[f.key];
    const label = f.required ? `${f.title} *` : f.title;
    if (f.type === "boolean")
      return option(label, () => value() === true, () => s.setDraft(f.key, value() !== true));
    if (f.type === "enum") {
      const picked = () => Array.isArray(value()) ? value() : [];
      const toggle = (o) => s.setDraft(f.key, f.multi ? picked().includes(o) ? picked().filter((x) => x !== o) : [...picked(), o] : picked()[0] === o ? [] : [o]);
      return VStack({ spacing: 3 }, [caption(label), HStack({ spacing: 4 }, [...f.options.map((o) => option(o, () => picked().includes(o), () => toggle(o))), Spacer()])]);
    }
    return TextField(() => typeof value() === "string" ? value() : "", { placeholder: label, onEdit: (text) => s.setDraft(f.key, text) });
  }
  function fieldsControls(s, fields) {
    const ready = () => fieldsAnswer(fields, s.drafts()).missing.length === 0;
    return VStack({ spacing: 6 }, [
      ...fields.map((f) => fieldControl(s, f)),
      HStack([Button(t("answer.send"), () => ready() ? reply(s, fieldsAnswer(fields, s.drafts()).value)() : undefined).disabled(() => !ready()), Spacer()])
    ]);
  }
  function formControls(s, form) {
    switch (form.kind) {
      case "question":
        return VStack({ spacing: 4 }, [
          caption(form.question),
          ...form.suggestions.map((text) => Button(text, reply(s, { text }))),
          TextField(() => String(s.drafts().text ?? ""), {
            placeholder: t("answer.placeholder"),
            onEdit: (text) => s.setDraft("text", text),
            onSubmit: (text) => text.trim() ? act(s, (i) => answer(i, { text: text.trim() }))() : undefined
          })
        ]);
      case "choice":
        return choiceControls(s, form.questions, form.oneTap);
      case "approve":
        return VStack({ spacing: 6 }, [
          caption(form.summary),
          form.command ? Text(form.command).font("caption").monospaced().lineLimit(4).padding(6).frame({ maxWidth: "infinity" }).background("hover").cornerRadius(6) : null,
          HStack({ spacing: 8 }, [
            Button(t("answer.allow"), reply(s, approveAnswer("allow"))),
            form.scopes.includes("session") ? Button(t("answer.allowSession"), reply(s, approveAnswer("allow", "session"))) : null,
            form.scopes.includes("always") ? Button(t("answer.allowAlways"), reply(s, approveAnswer("allow", "always"))) : null,
            Button(t("answer.deny"), reply(s, approveAnswer("deny"))).destructive(),
            Spacer()
          ])
        ]);
      case "confirm": {
        const yes = Button(form.confirmLabel ?? t("answer.confirm"), reply(s, { confirmed: true }));
        return VStack({ spacing: 6 }, [caption(form.statement), HStack({ spacing: 8 }, [form.destructive ? yes.destructive() : yes, Button(form.cancelLabel ?? t("answer.reject"), reply(s, { confirmed: false })), Spacer()])]);
      }
      case "browser":
        return VStack({ spacing: 6 }, [
          caption([form.origin, form.reason].filter(Boolean).join(" · ")),
          HStack([Button(t("answer.continueInBrowser"), act(s, openItem)), Spacer()]),
          Text(t("answer.browserHelp")).font("caption").color("tertiary").lineLimit(3)
        ]);
      case "review":
        return VStack({ spacing: 6 }, [
          caption(form.ref),
          TextField(() => String(s.drafts().comment ?? ""), { placeholder: t("answer.comment"), onEdit: (text) => s.setDraft("comment", text) }),
          HStack({ spacing: 8 }, [
            Button(t("answer.approveReview"), () => reply(s, withComment({ verdict: "approve" }, s))()),
            Button(t("answer.requestChanges"), () => reply(s, withComment({ verdict: "request_changes" }, s))()),
            Spacer()
          ])
        ]);
      case "handoff":
        return VStack({ spacing: 6 }, [caption(form.reason), HStack({ spacing: 8 }, [Button(t("answer.takeOver"), reply(s, { status: "taken_over" })), Button(t("answer.resume"), reply(s, { status: "resumed" })), Spacer()])]);
      case "fields":
        return fieldsControls(s, form.fields);
      case "unsupported":
        return caption(t("answer.unsupported"));
      case "none":
        return null;
    }
  }
  function withComment(value, s) {
    const comment = String(s.drafts().comment ?? "").trim();
    return comment ? { ...value, comment } : value;
  }
  function AnswerForm(s) {
    return Group([
      () => {
        s.form();
        const i = s.peek();
        if (!i)
          return null;
        const buttons = answerButtons(i);
        const controls = formControls(s, formOf(i));
        if (!buttons.length)
          return controls;
        return VStack({ spacing: 6 }, [
          controls,
          HStack({ spacing: 8 }, [
            ...buttons.map((a) => {
              const b = Button(a.label, reply(s, a.answer));
              return a.style === "destructive" ? b.destructive() : b;
            }),
            Spacer()
          ])
        ]);
      }
    ]);
  }
  function Actions(s, withSkip) {
    return Group([
      () => {
        s.form();
        const i = s.peek();
        if (!i)
          return null;
        const browser = i.kind === "sign-in" || i.kind === "passkey";
        const opens = openButtons(i).map((a) => Button(a.label, act(s, openItem)));
        const triage = isOpenRequest(i) ? [Button(t("action.decline"), act(s, decline)).destructive()] : i.archived_at !== null ? [Button(t("action.unarchive"), act(s, (x) => unarchive([x])))] : [Button(t("action.doneShort"), act(s, (x) => markDone([x]))), snoozeMenu(() => s.peek() ? [s.peek()] : [])];
        return HStack({ spacing: 8 }, [browser && isOpenRequest(i) ? null : Button(t("action.open"), act(s, openItem)), ...opens, ...triage, Spacer(), withSkip ? Button(t("action.skip"), () => step(1, s.id())) : null]);
      }
    ]);
  }
  function Summary(s, titleFont) {
    const get = () => s.item();
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 6 }, [
        Icon(() => get() ? itemSymbol(get()) : "tray").color(() => get() ? itemTint(get()) : "secondary").font("caption"),
        Text(() => {
          const i = get();
          return i ? [kindLabel(i), i.poster.label, s.workspace(i.context.workspace)].filter(Boolean).join(" · ") : "";
        }).font("caption").color("secondary").lineLimit(1),
        Spacer(),
        Text(() => get() ? ago(get().updated_at, Date.now()) : "").font("caption").color("tertiary")
      ]),
      Text(() => get()?.title ?? "").font(titleFont).lineLimit(4),
      Group([
        () => s.form() && s.peek()?.body ? Text(() => get()?.body ?? "").font("callout").color("secondary").lineLimit(10).padding(8).frame({ maxWidth: "infinity" }).background("hover").cornerRadius(6) : null
      ])
    ]);
  }
  function Detail(s) {
    return Group([() => s.has() ? VStack({ spacing: 12 }, [Summary(s, "headline"), AnswerForm(s), Actions(s, false)]) : Text(t("detail.none")).font("callout").color("tertiary").padding(12)]);
  }
  function Toolbar() {
    return HStack({ spacing: 6 }, [FilterMenu(), Spacer(), CountBadge(), Button(Icon("checkmark.circle").color("secondary"), () => markAllRead()).help(t("action.markAllRead"))]).paddingHorizontal(12).paddingVertical(2);
  }
  var currentOf = (view) => computed(() => view.items().find((i) => i.id === selected()) ?? view.items()[0] ?? null);
  var select = (i) => {
    setSelected(i.id);
    return markRead([i]);
  };
  function renderGrouped(wide) {
    const view = createFeedView(mainParams, { primary: true });
    const workspace = workspaceNames();
    const groups = groupsOf(view);
    const root = VStack({ spacing: 2 }, [
      Toolbar(),
      Notices(),
      ForEach({ items: groups, key: (g) => g.key }, (g) => VStack({ spacing: 0 }, [
        Group([
          () => g().key !== "all" ? HStack({ spacing: 4 }, [
            Text(() => workspace(g().label) || g().label || t("group.none")).font("caption").weight("semibold").color("secondary").lineLimit(1),
            Spacer(),
            Text(() => String(g().items.length)).font("caption").color("tertiary")
          ]).padding({ top: 6, bottom: 2, leading: 14, trailing: 14 }) : null
        ]),
        ForEach({ items: () => g().items, key: (i) => i.id }, (i) => ItemRow(i, workspace, { tapOpens: true }))
      ])),
      Empty(view),
      DoneFooter()
    ]);
    return wide ? root.frame({ maxWidth: 720 }) : root;
  }
  function Chip(symbol, label, active, action) {
    return Button(Icon(symbol).font("caption").color(() => active() ? "primary" : "secondary"), action).padding(5).background(() => active() ? "selected" : null).hoverBackground("hover").cornerRadius(6).help(label);
  }
  var CHIP_SYMBOLS = { all: "tray", agent: "sparkles", integration: "link", automation: "play.circle", app: "app", system: "gearshape" };
  function ChipBar() {
    return HStack({ spacing: 2 }, [
      ...SOURCES.map((s) => Chip(CHIP_SYMBOLS[s], sourceLabel(s), () => filters().source === s, () => setFilters({ source: s }))),
      Spacer(),
      Chip("hand.raised", t("filter.needsResponse"), () => filters().needsResponseOnly, () => setFilters({ needsResponseOnly: !filters().needsResponseOnly })),
      Chip("envelope.badge", t("filter.unreadOnly"), () => filters().unreadOnly, () => setFilters({ unreadOnly: !filters().unreadOnly })),
      Chip("checkmark.circle", t("action.markAllRead"), () => false, () => markAllRead())
    ]).paddingHorizontal(10);
  }
  function renderFocus(wide) {
    const view = createFeedView(mainParams, { primary: true });
    const workspace = workspaceNames();
    const current = currentOf(view);
    const detail = detailState(current, workspace);
    const list = VStack({ spacing: 2 }, [
      ChipBar(),
      Notices(),
      ForEach({ items: view.items, key: (i) => i.id }, (i) => ItemRow(i, workspace, { tapOpens: false, selectedId: () => current()?.id ?? null, onSelect: select })),
      Empty(view),
      DoneFooter()
    ]);
    if (wide)
      return HStack({ spacing: 0 }, [VStack([list, Spacer()]).frame({ width: 320, maxHeight: "infinity" }), Divider(), VStack([Detail(detail), Spacer()]).padding(16).frame({ maxWidth: "infinity", maxHeight: "infinity" })]);
    return VStack({ spacing: 8 }, [list, Divider(), Detail(detail).paddingHorizontal(12)]);
  }
  function renderCard(wide) {
    const view = createFeedView(mainParams, { primary: true });
    const workspace = workspaceNames();
    const current = currentOf(view);
    const detail = detailState(current, workspace);
    const position = computed(() => {
      const list = view.items();
      const index = list.findIndex((i) => i.id === current()?.id);
      return list.length ? t("card.position", { index: Math.max(0, index) + 1, total: list.length }) : "";
    });
    const card = VStack({ spacing: 12 }, [Summary(detail, "title3"), AnswerForm(detail), Actions(detail, true)]).padding(14).background("hover").borderColor("separator").borderWidth(1).cornerRadius(10);
    const root = VStack({ spacing: 8 }, [
      HStack({ spacing: 6 }, [FilterMenu(), Spacer(), Text(position).font("caption").color("tertiary")]).paddingHorizontal(12),
      Notices(),
      Group([() => detail.has() ? card : null]).paddingHorizontal(10),
      Empty(view),
      DoneFooter()
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
        throw commandError("item.not_found", t("item.notFound", { id }));
      }
    }
    if (items().length === 0)
      await listNow();
    const item = current();
    if (!item)
      throw commandError("item.not_found", t("item.noneSelected"));
    return item;
  }
  async function openInbox(_args = {}, ctx) {
    try {
      await (ctx?.cmux ?? cmux).call("app.pane.open", { contribution: `${cmux.app.id}#pane` });
      return { opened: true };
    } catch (e) {
      throw commandError(e.code ?? "operation.failed", t("pane.unsupported"));
    }
  }
  async function markAllRead2() {
    if (!await markAllRead())
      throw commandError("feed.refused", t("command.refused"));
    return { read: true };
  }
  async function move(direction, args, ctx) {
    if (items().length === 0)
      await listNow();
    const item = step(direction);
    if (item && args.open !== false)
      await openItem(item, ctx?.cmux);
    return { id: item?.id ?? null };
  }
  var nextItem = (args = {}, ctx) => move(1, args, ctx);
  var previousItem = (args = {}, ctx) => move(-1, args, ctx);
  async function openItem2(args = {}, ctx) {
    const item = await findItem(args.id);
    setSelected(item.id);
    await openItem(item, ctx?.cmux);
    return { id: item.id };
  }
  async function markDone2(args = {}) {
    const item = await findItem(args.id);
    if (isOpenRequest(item))
      throw commandError("feed.open_request", t("request.cannotTriage"));
    if (!await markDone([item]))
      throw commandError("feed.refused", t("command.refused"));
    return { id: item.id, done: true };
  }
  async function snooze(args = {}) {
    const item = await findItem(args.id);
    if (isOpenRequest(item))
      throw commandError("feed.open_request", t("request.cannotTriage"));
    const minutes = typeof args.minutes === "number" && args.minutes > 0 ? Math.min(args.minutes, 60 * 24 * 30) : 60;
    const until = Date.now() + minutes * 60000;
    if (!await snoozeItems([item], until))
      throw commandError("feed.refused", t("command.refused"));
    return { id: item.id, until };
  }
  async function cycleVariant2() {
    return { variant: await cycleVariant() };
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
