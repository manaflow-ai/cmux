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
    markAllRead: () => markAllRead2,
    markDone: () => markDone3,
    nextItem: () => nextItem,
    openInbox: () => openInbox,
    openItem: () => openItem2,
    previousItem: () => previousItem,
    refresh: () => refresh,
    renderInbox: () => renderInbox,
    renderPane: () => renderPane,
    renderStatus: () => renderStatus,
    snooze: () => snooze2
  });
  var ja = {
    "app.title": "受信トレイ",
    "kind.agentBlocked": "入力待ち",
    "kind.agentDone": "完了",
    "kind.agentIdle": "待機中",
    "kind.notification": "通知",
    "kind.reviewRequested": "レビュー依頼",
    "kind.checksFailing": "チェック失敗",
    "kind.mention": "メンション",
    "source.all": "すべて",
    "source.agent": "エージェント",
    "source.notification": "通知",
    "source.github": "GitHub",
    "group.other": "その他",
    "agent.fallback": "エージェント",
    "filter.unreadOnly": "未読のみ表示",
    "filter.showAll": "既読も表示",
    "filter.mineOnly": "自分の作業のみ",
    "filter.includeRequests": "依頼も表示",
    "filter.groupBySource": "ソース別にまとめる",
    "filter.groupByWorkspace": "ワークスペース別にまとめる",
    "filter.unreadSuffix": "{label}・未読",
    "action.open": "開く",
    "action.done": "完了にする",
    "action.doneShort": "完了",
    "action.snooze": "スヌーズ",
    "action.skip": "スキップ",
    "action.markRead": "既読にする",
    "action.markAllRead": "すべて既読にする",
    "action.markAllDone": "すべて完了にする",
    "action.unsnooze": "スヌーズを解除",
    "action.refresh": "更新",
    "action.reply": "返信…",
    "snooze.30m": "30分後 ({time})",
    "snooze.2h": "2時間後 ({time})",
    "snooze.tomorrow": "明日 ({time})",
    "snooze.nextWeek": "来週 ({time})",
    "snooze.until": "{time} までスヌーズ",
    "snoozed.count": "スヌーズ中 {n} 件",
    "snoozed.hide": "スヌーズ中を隠す",
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
    "card.position": "{index} / {total}",
    "badge.unread": "未読 {n} 件",
    "empty.title": "対応が必要なものはありません",
    "empty.message": "エージェント、通知、GitHub はすべて片付いています。",
    "empty.filtered": "このフィルターに一致する項目はありません",
    loading: "読み込み中…",
    "error.notification": "通知を読み込めません: {reason}",
    "error.agent": "エージェントを読み込めません: {reason}",
    "error.open": "開けませんでした: {reason}",
    "error.reply": "送信できませんでした: {reason}",
    "reason.scope": "許可されていません",
    "reason.unsupported": "このバージョンの cmux では使えません",
    "github.notGranted": "GitHub を接続",
    "github.notGrantedHelp": "設定 > アプリ > 受信トレイ で GitHub の読み取りを許可します",
    "github.unavailable": "GitHub 連携はまだ利用できません",
    "github.unavailableHelp": "cmux の連携ゲートウェイがこのホストにありません",
    "github.error": "GitHub を読み込めません",
    "github.checks.fail": "{n} 件失敗: {names}",
    "github.checks.pending": "チェック実行中",
    "github.checks.pass": "すべてのチェックに成功",
    "github.checks.neutral": "チェック結果なし",
    "github.by": "{author} が作成",
    "reply.needsScope": "クイック返信にはターミナルへの入力許可が必要です (設定 > アプリ > 受信トレイ)。",
    "reply.sent": "送信しました",
    "detail.none": "項目を選んでください",
    "status.none": "対応が必要なものはありません",
    "pane.unsupported": "このバージョンの cmux はアプリのペインをまだ開けません。サイドバーのセクションを使ってください。",
    "item.notFound": "受信トレイに {id} はありません",
    "variant.grouped": "グループ表示",
    "variant.focus": "リストと詳細",
    "variant.card": "1件ずつ"
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
  var emptyLedger = () => ({ v: 1, seen: {}, done: {}, snooze: {}, githubSeeded: false });
  var numberMap = (v) => {
    if (!v || typeof v !== "object" || Array.isArray(v))
      return {};
    const out = {};
    for (const [k, n] of Object.entries(v))
      if (typeof n === "number" && Number.isFinite(n))
        out[k] = n;
    return out;
  };
  function parseLedger(raw) {
    if (!raw || typeof raw !== "object")
      return emptyLedger();
    const r = raw;
    return { v: 1, seen: numberMap(r.seen), done: numberMap(r.done), snooze: numberMap(r.snooze), githubSeeded: r.githubSeeded === true };
  }
  var isSeen = (l, id, at) => (l.seen[id] ?? -1) >= at;
  var isDone = (l, id, at) => (l.done[id] ?? -1) >= at;
  var snoozedUntil = (l, id, now) => {
    const until = l.snooze[id];
    return until !== undefined && until > now ? until : null;
  };
  var stamp = (map, items) => {
    const next = { ...map };
    for (const i of items)
      next[i.id] = Math.max(next[i.id] ?? -1, i.at);
    return next;
  };
  var markSeen = (l, items) => ({ ...l, seen: stamp(l.seen, items) });
  function markDone(l, items) {
    const snooze = { ...l.snooze };
    for (const i of items)
      delete snooze[i.id];
    return { ...l, seen: stamp(l.seen, items), done: stamp(l.done, items), snooze };
  }
  function snooze(l, ids, until) {
    const next = { ...l.snooze };
    for (const id of ids)
      next[id] = until;
    return { ...l, snooze: next };
  }
  function unsnooze(l, ids) {
    const next = { ...l.snooze };
    for (const id of ids)
      delete next[id];
    return { ...l, snooze: next };
  }
  function wake(l, now) {
    const woke = Object.entries(l.snooze).filter(([, until]) => until <= now).map(([id]) => id);
    if (woke.length === 0)
      return { ledger: l, woke };
    const snoozeMap = { ...l.snooze };
    const seen = { ...l.seen };
    for (const id of woke) {
      delete snoozeMap[id];
      delete seen[id];
    }
    return { ledger: { ...l, snooze: snoozeMap, seen }, woke };
  }
  function nextWake(l, now) {
    let best = null;
    for (const until of Object.values(l.snooze))
      if (until > now && (best === null || until < best))
        best = until;
    return best;
  }
  var MAX_ENTRIES = 2000;
  var RETAIN_MS = 30 * 86400000;
  function prune(l, liveIds, now) {
    const keep = (map, stampIsTime) => {
      const entries = Object.entries(map).filter(([id, v]) => liveIds.has(id) || (stampIsTime ? v > now - RETAIN_MS : true));
      entries.sort((a, b) => b[1] - a[1]);
      return Object.fromEntries(entries.slice(0, MAX_ENTRIES));
    };
    return { ...l, seen: keep(l.seen, true), done: keep(l.done, true), snooze: keep(l.snooze, false) };
  }
  var str = (v) => typeof v === "string" && v.trim() ? v.trim() : null;
  var capitalized = (s) => s.charAt(0).toUpperCase() + s.slice(1);
  var firstLine = (s) => (s ?? "").split(`
`).map((l) => l.trim()).find(Boolean) ?? "";
  function agentName(a, fallback) {
    const extra = a.extra ?? {};
    const name = str(extra.name) ?? str(extra.title) ?? str(a.source_session);
    return name ? capitalized(name) : fallback;
  }
  var AGENT_KIND = { blocked: "agentBlocked", done: "agentDone", idle: "agentIdle" };
  function agentItems(agents, notifications, terminals, options, fallbackName) {
    const items = [];
    for (const a of agents) {
      const kind = AGENT_KIND[a.state];
      if (!kind || kind === "agentIdle" && !options.includeIdle || kind === "agentDone" && !options.includeDone)
        continue;
      const related = notifications.filter((n) => n.terminal_id === a.terminal_id).sort((x, y) => Number(y.created_at_ms) - Number(x.created_at_ms));
      const latest = related[0];
      const terminal = terminals.get(a.terminal_id);
      const terminalLabel = str(terminal?.title) ?? str(terminal?.cwd) ?? "";
      items.push({
        id: `agent:${a.id}`,
        source: "agent",
        kind,
        title: agentName(a, fallbackName),
        detail: latest ? str(latest.subtitle) ?? (firstLine(latest.body) || latest.title) : terminalLabel,
        body: latest ? [latest.title, latest.body].filter(Boolean).join(`
`) : undefined,
        at: Math.max(Number(a.updated_at_ms) || 0, ...related.map((n) => Number(n.created_at_ms) || 0)),
        unreadHint: true,
        mine: true,
        terminal: a.terminal_id,
        notifications: related.map((n) => n.id)
      });
    }
    return items;
  }
  function notificationItems(notifications, claimed, clientId) {
    return notifications.filter((n) => !claimed.has(n.id)).map((n) => ({
      id: `notification:${n.id}`,
      source: "notification",
      kind: "notification",
      title: n.title,
      detail: str(n.subtitle) ?? firstLine(n.body),
      body: n.body || undefined,
      at: Number(n.created_at_ms) || 0,
      unreadHint: n.unread && !n.read_by.includes(clientId),
      mine: true,
      level: n.level,
      terminal: n.terminal_id,
      notifications: [n.id]
    }));
  }
  function priority(item) {
    switch (item.kind) {
      case "agentBlocked":
        return 0;
      case "checksFailing":
        return 1;
      case "notification":
        return item.level === "error" ? 1 : item.level === "warning" ? 3 : 4;
      case "reviewRequested":
        return 2;
      case "agentDone":
        return 3;
      case "mention":
        return 4;
      case "agentIdle":
        return 5;
    }
  }
  var compareItems = (a, b) => priority(a) - priority(b) || b.at - a.at || a.id.localeCompare(b.id);
  function buildItems(sources, ledger, options, fallbackName) {
    const agents = agentItems(sources.agents, sources.notifications, sources.terminals, options, fallbackName);
    const claimed = new Set(agents.flatMap((a) => a.notifications));
    const oldest = options.now - options.maxAgeDays * 86400000;
    const all = [...agents, ...notificationItems(sources.notifications, claimed, options.clientId), ...sources.github];
    const out = [];
    for (const item of all) {
      if (item.source !== "agent" && options.maxAgeDays > 0 && item.at < oldest)
        continue;
      if (isDone(ledger, item.id, item.at))
        continue;
      const location = item.terminal ? sources.locations.get(item.terminal) : undefined;
      out.push({
        ...item,
        unread: item.unreadHint && !isSeen(ledger, item.id, item.at),
        snoozedUntil: snoozedUntil(ledger, item.id, options.now),
        workspace: location ? { id: location.workspaceId, name: location.workspaceName } : null
      });
    }
    return out.sort(compareItems);
  }
  var DEFAULT_FILTERS = { source: "all", unreadOnly: false, mineOnly: false, showSnoozed: false };
  function filterItems(items, f) {
    return items.filter((i) => (f.showSnoozed ? i.snoozedUntil !== null : i.snoozedUntil === null) && (f.source === "all" || i.source === f.source) && (!f.unreadOnly || i.unread) && (!f.mineOnly || i.mine));
  }
  var SOURCE_ORDER = ["agent", "notification", "github"];
  function groupItems(items, by, otherLabel) {
    if (by === "source") {
      return SOURCE_ORDER.map((source) => ({ key: source, label: source, source, items: items.filter((i) => i.source === source) })).filter((g) => g.items.length > 0);
    }
    const groups = new Map;
    for (const item of items) {
      const key = item.workspace ? `workspace:${item.workspace.id}` : item.repo ? `repo:${item.repo}` : "other";
      const label = item.workspace?.name ?? item.repo ?? otherLabel;
      let g = groups.get(key);
      if (!g)
        groups.set(key, g = { key, label, source: null, items: [] });
      g.items.push(item);
    }
    return [...groups.values()].sort((a, b) => a.key === "other" ? 1 : b.key === "other" ? -1 : compareItems(a.items[0], b.items[0]));
  }
  function countItems(items) {
    let unread = 0;
    let blocked = 0;
    let open = 0;
    let snoozed = 0;
    for (const i of items) {
      if (i.snoozedUntil !== null) {
        snoozed++;
        continue;
      }
      open++;
      if (i.unread)
        unread++;
      if (i.kind === "agentBlocked")
        blocked++;
    }
    return { unread, blocked, open, snoozed };
  }
  function locateTerminals(layout) {
    const workspaces = new Map(layout.workspaces.map((w) => [w.id, w]));
    const screens = new Map(layout.screens.map((s) => [s.id, s]));
    const panes = new Map(layout.panes.map((p) => [p.id, p]));
    const tabs = new Map(layout.tabs.map((t) => [t.id, t]));
    const out = new Map;
    for (const terminal of layout.terminals) {
      const tab = terminal.tab_id ? tabs.get(terminal.tab_id) : undefined;
      const screen = tab ? screens.get(panes.get(tab.pane_id)?.screen_id ?? "") : undefined;
      const workspace = screen ? workspaces.get(screen.workspace_id) : undefined;
      if (workspace)
        out.set(terminal.id, { workspaceId: workspace.id, workspaceName: workspace.name, tabId: tab?.id ?? null });
    }
    return out;
  }
  function neighbor(order, id, step) {
    if (order.length === 0)
      return null;
    const index = id ? order.findIndex((i) => i.id === id) : -1;
    if (index < 0)
      return order[step === 1 ? 0 : order.length - 1].id;
    return order[(index + step + order.length) % order.length].id;
  }
  function itemJSON(i) {
    return {
      id: i.id,
      source: i.source,
      kind: i.kind,
      title: i.title,
      detail: i.detail,
      unread: i.unread,
      updated_at: new Date(i.at).toISOString(),
      snoozed_until: i.snoozedUntil === null ? null : new Date(i.snoozedUntil).toISOString(),
      workspace: i.workspace?.name ?? null,
      terminal_id: i.terminal ?? null,
      url: i.url ?? null,
      repo: i.repo ?? null,
      number: i.number ?? null,
      level: i.level ?? null
    };
  }
  var day = (ms) => new Date(ms).toISOString().slice(0, 10);
  function githubQueries(options, now) {
    const out = [];
    if (options.reviewRequests)
      out.push({ kind: "reviewRequested", query: "is:open is:pr review-requested:@me archived:false" });
    if (options.failingChecks)
      out.push({ kind: "checksFailing", query: "is:open is:pr author:@me status:failure archived:false" });
    if (options.mentions)
      out.push({ kind: "mention", query: `is:open mentions:@me archived:false updated:>=${day(now - options.mentionDays * 86400000)}` });
    return out;
  }
  var searchPath = (query) => `/search/issues?q=${encodeURIComponent(query)}&sort=updated&order=desc&per_page=30`;
  var repoOf = (item) => {
    const fromApi = item.repository_url?.match(/\/repos\/([^/]+\/[^/]+)$/)?.[1];
    return fromApi ?? item.html_url?.match(/github\.com\/([^/]+\/[^/]+)\//)?.[1] ?? "";
  };
  function parseSearch(kind, body) {
    const items = body?.items;
    if (!Array.isArray(items))
      return [];
    const out = [];
    for (const s of items) {
      const repo = repoOf(s);
      if (!repo || typeof s.number !== "number" || !s.html_url)
        continue;
      out.push({
        id: `github:${repo}#${s.number}`,
        source: "github",
        kind,
        title: s.title ?? `#${s.number}`,
        detail: `${repo.split("/")[1]} #${s.number}`,
        at: Date.parse(s.updated_at ?? "") || 0,
        unreadHint: true,
        mine: kind === "checksFailing",
        notifications: [],
        url: s.html_url,
        repo,
        number: s.number,
        author: s.user?.login ?? undefined
      });
    }
    return out;
  }
  function mergeGithub(lists) {
    const byId = new Map;
    for (const item of lists.flat()) {
      const current = byId.get(item.id);
      if (!current || priority(item) < priority(current))
        byId.set(item.id, item);
    }
    return [...byId.values()];
  }
  var codeOf = (e) => e && typeof e === "object" && ("code" in e) ? String(e.code) : "";
  var messageOf = (e) => e instanceof Error ? e.message : String(e);
  async function fetchGithub(request, options, now) {
    const queries = githubQueries(options, now);
    if (queries.length === 0)
      return { status: "ok", items: [], errors: [] };
    const settled = await Promise.allSettled(queries.map((q) => request(searchPath(q.query)).then((body) => parseSearch(q.kind, body))));
    const lists = [];
    const failures = [];
    for (const s of settled) {
      if (s.status === "fulfilled")
        lists.push(s.value);
      else
        failures.push(s.reason);
    }
    if (lists.length === 0) {
      const codes = failures.map(codeOf);
      if (codes.every((c) => c === "scope.missing"))
        return { status: "notGranted", items: [], errors: [] };
      if (codes.every((c) => c === "operation.unsupported"))
        return { status: "unavailable", items: [], errors: [] };
      return { status: "error", items: [], errors: failures.map(messageOf) };
    }
    return { status: failures.length ? "partial" : "ok", items: mergeGithub(lists), errors: failures.map(messageOf) };
  }
  var outcome = (run) => {
    if (run.status !== "completed")
      return "pending";
    switch (run.conclusion) {
      case "success":
        return "pass";
      case "failure":
      case "timed_out":
      case "action_required":
      case "startup_failure":
        return "fail";
      case "cancelled":
      case "stale":
        return "cancel";
      default:
        return "skip";
    }
  };
  function summarizeChecks(runs) {
    const counts = { fail: 0, pending: 0, pass: 0, cancel: 0, skip: 0 };
    const failed = [];
    for (const run of runs) {
      const o = outcome(run);
      counts[o]++;
      if (o === "fail" && run.name)
        failed.push(run.name);
    }
    const state = counts.fail ? "fail" : counts.pending ? "pending" : counts.cancel ? "neutral" : counts.pass ? "pass" : "neutral";
    return { state, failed, counts };
  }
  async function loadChecks(request, repo, number) {
    const pull = await request(`/repos/${repo}/pulls/${number}`);
    const sha = pull?.head?.sha;
    if (!sha)
      return summarizeChecks([]);
    const runs = await request(`/repos/${repo}/commits/${sha}/check-runs?per_page=100`);
    return summarizeChecks(runs?.check_runs ?? []);
  }
  var VARIANTS = ["grouped", "focus", "card"];
  var DEFAULT_VARIANT = "grouped";
  var bool = (v, fallback) => typeof v === "boolean" ? v : fallback;
  var num = (v, fallback, min, max) => typeof v === "number" && Number.isFinite(v) ? Math.min(max, Math.max(min, v)) : fallback;
  var asVariant = (v) => VARIANTS.includes(v) ? v : DEFAULT_VARIANT;
  function readSettings(raw) {
    const reviewRequests = bool(raw.githubReviewRequests, true);
    const failingChecks = bool(raw.githubFailingChecks, true);
    const mentions = bool(raw.githubMentions, true);
    return {
      variant: asVariant(raw.variant),
      groupBy: raw.groupBy === "workspace" ? "workspace" : "source",
      includeIdleAgents: bool(raw.includeIdleAgents, false),
      includeDoneAgents: bool(raw.includeDoneAgents, true),
      maxAgeDays: num(raw.maxAgeDays, 7, 0, 365),
      github: {
        enabled: reviewRequests || failingChecks || mentions,
        reviewRequests,
        failingChecks,
        mentions,
        mentionDays: num(raw.maxAgeDays, 7, 1, 365),
        refreshMinutes: num(raw.githubRefreshMinutes, 10, 2, 240)
      }
    };
  }
  var settings = () => readSettings(cmux.app.settings());
  var clientId = () => `app:${cmux.app.id || "cmux/inbox"}`;
  function describe(e) {
    const code = e && typeof e === "object" && "code" in e ? String(e.code) : "";
    if (code === "scope.missing")
      return t("reason.scope", "permission not granted");
    if (code === "operation.unsupported")
      return t("reason.unsupported", "not supported by this version of cmux");
    return e instanceof Error ? e.message : String(e);
  }
  var [notifications, setNotifications] = signal(null);
  var [agents, setAgents] = signal(null);
  var [terminals, setTerminals] = signal([]);
  var [locations, setLocations] = signal(new Map);
  var [sourceErrors, setSourceErrors] = signal({ notification: null, agent: null });
  var [github, setGithubSignal] = signal({ status: "idle", items: [], errors: [], at: 0, loading: false });
  var githubValue = github();
  var setGithub = (next) => setGithubSignal(githubValue = next);
  var [ledger, setLedgerSignal] = signal(emptyLedger());
  var ledgerValue = ledger();
  var [filters, setFiltersSignal] = signal(DEFAULT_FILTERS);
  var [groupOverride, setGroupOverride] = signal(null);
  var [selected, setSelected] = signal(null);
  var [now, setNow] = signal(Date.now());
  var [notice, setNotice] = signal(null);
  var [replyBlocked, setReplyBlocked] = signal(false);
  var [variantOverride, setVariantOverride] = signal(null);
  var items = computed(() => {
    const s = settings();
    const terminalMap = new Map(terminals().map((x) => [x.id, x]));
    return buildItems({ agents: agents() ?? [], notifications: notifications() ?? [], terminals: terminalMap, github: github().items, locations: locations() }, ledger(), { clientId: clientId(), includeIdle: s.includeIdleAgents, includeDone: s.includeDoneAgents, maxAgeDays: s.maxAgeDays, now: now() }, t("agent.fallback", "Agent"));
  });
  var visible = computed(() => filterItems(items(), filters()));
  var counts = computed(() => countItems(items()));
  var groupBy = computed(() => groupOverride() ?? settings().groupBy);
  var groups = computed(() => groupItems(visible(), groupBy(), t("group.other", "Other")));
  var current = computed(() => visible().find((i) => i.id === selected()) ?? visible()[0] ?? null);
  var loaded = computed(() => notifications() !== null || agents() !== null || sourceErrors().notification !== null || sourceErrors().agent !== null);
  var variant = computed(() => {
    const base = settings().variant;
    const o = variantOverride();
    return o && o.base === base ? o.variant : base;
  });
  var loading = null;
  var persist = (key, value) => cmux.storage.set(key, value).catch((e) => cmux.log(`storage ${key}: ${describe(e)}`));
  function ensureLoaded() {
    loading ??= Promise.all([
      cmux.storage.get("ledger").catch(() => null),
      cmux.storage.get("view").catch(() => null),
      cmux.storage.get("variantOverride").catch(() => null)
    ]).then(([rawLedger, view, override]) => {
      setLedgerValue(wake(parseLedger(rawLedger), Date.now()).ledger);
      if (view?.filters)
        setFiltersSignal({ ...DEFAULT_FILTERS, ...view.filters, showSnoozed: false });
      if (view?.groupBy === "source" || view?.groupBy === "workspace")
        setGroupOverride(view.groupBy);
      if (override?.variant)
        setVariantOverride({ variant: asVariant(override.variant), base: asVariant(override.base) });
      armWake();
    });
    return loading;
  }
  function setLedgerValue(next) {
    ledgerValue = next;
    setLedgerSignal(next);
  }
  async function updateLedger(change) {
    await ensureLoaded();
    const live = new Set(items().map((i) => i.id));
    setLedgerValue(prune(change(ledgerValue), live, Date.now()));
    await persist("ledger", ledgerValue);
  }
  function setFilters(change) {
    const next = { ...filters(), ...change };
    setFiltersSignal(next);
    persist("view", { filters: { ...next, showSnoozed: false }, groupBy: groupBy() });
  }
  function setGrouping(by) {
    setGroupOverride(by);
    persist("view", { filters: { ...filters(), showSnoozed: false }, groupBy: by });
  }
  var MAX_DELAY = 2 ** 31 - 1;
  var wakeTimer = null;
  function armWake() {
    if (wakeTimer !== null)
      cmux.timer.clear(wakeTimer);
    wakeTimer = null;
    const next = nextWake(ledgerValue, Date.now());
    if (next === null)
      return;
    wakeTimer = cmux.timer.after(Math.min(MAX_DELAY, Math.max(0, next - Date.now())), () => {
      wakeTimer = null;
      const result = wake(ledgerValue, Date.now());
      if (result.woke.length) {
        setLedgerValue(result.ledger);
        persist("ledger", ledgerValue);
      }
      setNow(Date.now());
      armWake();
    });
  }
  function attach() {
    ensureLoaded();
    const n = cmux.live("notification.list", { limit: 256 });
    const a = cmux.live("agent.list", {});
    const term = cmux.live("terminal.list", {}, { events: ["terminal.changed", "workspace.changed"] });
    effect(() => {
      const v = n();
      if (v)
        setNotifications(v);
      setNow(Date.now());
    });
    effect(() => {
      const v = a();
      if (v)
        setAgents(v);
      setNow(Date.now());
    });
    effect(() => setTerminals(term() ?? []));
    effect(() => {
      const notification = n.error() ? describe(n.error()) : null;
      const agent = a.error() ? describe(a.error()) : null;
      setSourceErrors({ notification, agent });
    });
  }
  function attachLayout() {
    const ws = cmux.live("workspace.list", {});
    const screens = cmux.live("screen.list", {}, { events: ["screen.changed", "workspace.changed"] });
    const panes = cmux.live("pane.list", {}, { events: ["pane.changed", "workspace.changed"] });
    const tabs = cmux.live("tab.list", {}, { events: ["tab.changed", "workspace.changed"] });
    effect(() => setLocations(locateTerminals({ workspaces: ws() ?? [], screens: screens() ?? [], panes: panes() ?? [], tabs: tabs() ?? [], terminals: terminals() })));
  }
  async function ensureData() {
    await ensureLoaded();
    if (notifications() !== null && agents() !== null)
      return;
    const [n, a, term] = await Promise.allSettled([
      cmux.notification.list({ limit: 256 }),
      cmux.agent.list({}),
      cmux.terminal.list({})
    ]);
    setNotifications(n.status === "fulfilled" ? n.value : []);
    setAgents(a.status === "fulfilled" ? a.value : []);
    if (term.status === "fulfilled")
      setTerminals(term.value);
    setSourceErrors({ notification: n.status === "rejected" ? describe(n.reason) : null, agent: a.status === "rejected" ? describe(a.reason) : null });
    setNow(Date.now());
    await refreshGithub(false);
  }
  var githubInFlight = null;
  function unwrap(value) {
    const v = value;
    if (v && typeof v.status === "number" && typeof v.body === "string") {
      if (v.status >= 400)
        throw new Error(`GitHub ${v.status}`);
      return JSON.parse(v.body);
    }
    return value;
  }
  var githubRequest = (path) => cmux.integrations.github.request({ method: "GET", path }).then(unwrap);
  function refreshGithub(force) {
    const s = settings().github;
    if (!s.enabled) {
      setGithub({ status: "idle", items: [], errors: [], at: Date.now(), loading: false });
      return Promise.resolve();
    }
    const g = githubValue;
    const refused = g.status === "notGranted" || g.status === "unavailable";
    if (!force && (refused || Date.now() - g.at < s.refreshMinutes * 60000 / 2))
      return Promise.resolve();
    if (githubInFlight)
      return githubInFlight;
    setGithub({ ...g, loading: true });
    githubInFlight = fetchGithub(githubRequest, s, Date.now()).then(async (r) => {
      setGithub({ ...r, at: Date.now(), loading: false });
      setNow(Date.now());
      if ((r.status === "ok" || r.status === "partial") && !ledgerValue.githubSeeded) {
        await updateLedger((l) => ({ ...markSeen(l, r.items), githubSeeded: true }));
      }
    }).finally(() => {
      githubInFlight = null;
    });
    return githubInFlight;
  }
  function scheduleGithub() {
    refreshGithub(false);
    const id = cmux.timer.every(settings().github.refreshMinutes * 60000, () => {
      const status = githubValue.status;
      if (status === "notGranted" || status === "unavailable" || !settings().github.enabled)
        cmux.timer.clear(id);
      else
        refreshGithub(false);
    });
  }
  async function cycleVariant() {
    const order = ["grouped", "focus", "card"];
    const next = order[(order.indexOf(variant()) + 1) % order.length];
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
  var clearSnooze = (ids) => updateLedger((l) => unsnooze(l, ids)).then(armWake);
  var snoozeIds = (ids, until) => updateLedger((l) => snooze(l, ids, until)).then(armWake);
  var doneIds = (list) => updateLedger((l) => markDone(l, list)).then(armWake);
  var terminalTab = (terminal) => terminals().find((x) => x.id === terminal)?.tab_id ?? null;
  var ACK_BATCH = 256;
  async function ack(ids) {
    for (let i = 0;i < ids.length; i += ACK_BATCH) {
      try {
        await cmux.notification.ack({ client_id: clientId(), notifications: ids.slice(i, i + ACK_BATCH) });
      } catch (e) {
        cmux.log(`ack: ${describe(e)}`);
      }
    }
  }
  async function openItem(item) {
    setSelected(item.id);
    let opening = null;
    try {
      if (item.url)
        opening = cmux.actions.run("openBrowser", { url: item.url });
      else if (item.terminal) {
        const tab = terminalTab(item.terminal);
        opening = tab ? cmux.tab.focus({ tab }) : cmux.terminal.get({ terminal: item.terminal }).then((x) => x.tab_id ? cmux.tab.focus({ tab: x.tab_id }) : null);
      }
    } catch (e) {
      noticeFor(t("error.open", "Could not open: {reason}", { reason: describe(e) }));
    }
    await markRead([item]);
    if (opening)
      await opening.catch((e) => noticeFor(t("error.open", "Could not open: {reason}", { reason: describe(e) })));
  }
  async function markRead(list) {
    await updateLedger((l) => markSeen(l, list));
    await ack(list.flatMap((i) => i.notifications));
  }
  async function markDone2(list) {
    const gone = new Set(list.map((i) => i.id));
    const sel = selected();
    if (sel && gone.has(sel)) {
      const remaining = visible().filter((i) => !gone.has(i.id) || i.id === sel);
      const next = neighbor(remaining, sel, 1);
      setSelected(next && !gone.has(next) ? next : null);
    }
    await doneIds([...list]);
    await ack(list.flatMap((i) => i.notifications));
  }
  async function snoozeItems(list, until) {
    const ids = list.map((i) => i.id);
    const sel = selected();
    if (sel && ids.includes(sel))
      setSelected(neighbor(visible().filter((i) => !ids.includes(i.id) || i.id === sel), sel, 1));
    await snoozeIds(ids, until);
  }
  var unsnoozeItems = (list) => clearSnooze(list.map((i) => i.id));
  async function markAllRead() {
    const unread = visible().filter((i) => i.unread);
    await markRead(unread);
    return unread.length;
  }
  function step(direction, from = selected()) {
    const id = neighbor(visible(), from, direction);
    setSelected(id);
    return visible().find((i) => i.id === id) ?? null;
  }
  async function reply(item, text) {
    const message = text.trim();
    if (!item.terminal || !message)
      return false;
    try {
      await cmux.terminal.input.write({ terminal: item.terminal, text: `${message}\r` });
      await markRead([item]);
      noticeFor(t("reply.sent", "Sent"));
      return true;
    } catch (e) {
      if (e.code === "scope.missing")
        setReplyBlocked(true);
      else
        noticeFor(t("error.reply", "Could not send: {reason}", { reason: describe(e) }));
      return false;
    }
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
  var KIND_LABELS = {
    agentBlocked: ["kind.agentBlocked", "Needs input"],
    agentDone: ["kind.agentDone", "Finished"],
    agentIdle: ["kind.agentIdle", "Idle"],
    notification: ["kind.notification", "Notification"],
    reviewRequested: ["kind.reviewRequested", "Review requested"],
    checksFailing: ["kind.checksFailing", "Checks failing"],
    mention: ["kind.mention", "Mentioned"]
  };
  var kindLabel = (kind) => t(...KIND_LABELS[kind]);
  var SOURCE_LABELS = {
    all: ["source.all", "All"],
    agent: ["source.agent", "Agents"],
    notification: ["source.notification", "Notifications"],
    github: ["source.github", "GitHub"]
  };
  var sourceLabel = (s) => t(...SOURCE_LABELS[s]);
  var SOURCE_SYMBOLS = { all: "tray", agent: "sparkles", notification: "bell", github: "arrow.triangle.pull" };
  function kindSymbol(i) {
    switch (i.kind) {
      case "agentBlocked":
        return "exclamationmark.bubble";
      case "agentDone":
        return "checkmark.circle";
      case "agentIdle":
        return "moon";
      case "reviewRequested":
        return "eye";
      case "checksFailing":
        return "xmark.circle";
      case "mention":
        return "at";
      case "notification":
        return i.level === "error" ? "xmark.octagon" : i.level === "warning" ? "exclamationmark.triangle" : "bell";
    }
  }
  function kindTint(i) {
    switch (i.kind) {
      case "agentBlocked":
        return "warning";
      case "agentDone":
        return "success";
      case "checksFailing":
        return "danger";
      case "reviewRequested":
      case "mention":
        return "accent";
      case "notification":
        return i.level === "error" ? "danger" : i.level === "warning" ? "warning" : "secondary";
      case "agentIdle":
        return "secondary";
    }
  }
  function subtitleOf(i, at) {
    const when = i.snoozedUntil !== null ? t("snooze.until", "Snoozed until {time}", { time: clock(i.snoozedUntil, at) }) : ago(i.at, at);
    const parts = i.source === "notification" ? [when, i.detail] : [kindLabel(i.kind), when, i.detail];
    return parts.filter(Boolean).join(" · ");
  }
  function snoozeMenu(list) {
    return Menu(t("action.snooze", "Snooze"), snoozePresets(now()).map((p) => Button(p.label, () => snoozeItems(list(), p.until))));
  }
  function itemMenu(i) {
    const views = [
      Button(t("action.open", "Open"), () => openItem(i)),
      Button(t("action.done", "Mark as Done"), () => markDone2([i])),
      i.snoozedUntil !== null ? Button(t("action.unsnooze", "Unsnooze"), () => unsnoozeItems([i])) : snoozeMenu(() => [i])
    ];
    if (i.unread)
      views.push(Button(t("action.markRead", "Mark as Read"), () => markRead([i])));
    return views;
  }
  function ItemRow(item, options) {
    return Row({
      title: () => item().title,
      subtitle: () => subtitleOf(item(), now()),
      symbol: () => kindSymbol(item()),
      tint: () => kindTint(item()),
      unread: () => item().unread,
      selected: () => options.selectedId ? options.selectedId() === item().id : false
    }).help(() => [kindLabel(item().kind), item().title, item().detail].filter(Boolean).join(`
`)).onTap(() => options.tapOpens || !options.onSelect ? openItem(item()) : options.onSelect(item().id)).contextMenu(() => itemMenu(item()));
  }
  function filterSummary() {
    const f = filters();
    const label = f.showSnoozed ? t("snoozed.count", "{n} snoozed", { n: counts().snoozed }) : sourceLabel(f.source);
    return f.unreadOnly ? t("filter.unreadSuffix", "{label} · Unread", { label }) : label;
  }
  function FilterMenu() {
    return Menu(filterSummary, []).contextMenu(() => filterChoices());
  }
  function filterChoices() {
    const f = filters();
    const sources = ["all", "agent", "notification", "github"];
    return [
      ...sources.map((s) => Button(sourceLabel(s), () => setFilters({ source: s, showSnoozed: false })).disabled(f.source === s && !f.showSnoozed)),
      Divider(),
      Button(f.unreadOnly ? t("filter.showAll", "Show Read Items") : t("filter.unreadOnly", "Show Unread Only"), () => setFilters({ unreadOnly: !f.unreadOnly })),
      Button(f.mineOnly ? t("filter.includeRequests", "Include Requests from Others") : t("filter.mineOnly", "Show Only My Work"), () => setFilters({ mineOnly: !f.mineOnly })),
      Divider(),
      groupBy() === "source" ? Button(t("filter.groupByWorkspace", "Group by Workspace"), () => setGrouping("workspace")) : Button(t("filter.groupBySource", "Group by Source"), () => setGrouping("source")),
      Divider(),
      Button(t("action.markAllRead", "Mark All as Read"), () => markAllRead()),
      Button(t("action.markAllDone", "Mark All as Done"), () => markDone2(visible())),
      Button(t("action.refresh", "Refresh"), () => refreshGithub(true))
    ];
  }
  function LayoutProbe() {
    return ForEach({ items: () => groupBy() === "workspace" ? ["layout"] : [], key: (k) => k }, () => {
      attachLayout();
      return Group([]);
    });
  }
  function Notices() {
    const line = (text, tone) => HStack({ spacing: 6 }, [Icon("exclamationmark.triangle").color(tone).font("caption"), Text(text).font("caption").color("secondary").lineLimit(2)]).paddingHorizontal(14).paddingVertical(2);
    return Group([
      () => sourceErrors().notification ? line(t("error.notification", "Notifications unavailable: {reason}", { reason: sourceErrors().notification }), "warning") : null,
      () => sourceErrors().agent ? line(t("error.agent", "Agents unavailable: {reason}", { reason: sourceErrors().agent }), "warning") : null,
      () => notice() ? line(notice(), "secondary") : null
    ]);
  }
  function GithubStatusRow() {
    return Group([
      () => {
        const f = filters();
        if (f.showSnoozed || f.source !== "all" && f.source !== "github")
          return null;
        const g = github();
        if (g.status === "notGranted")
          return Row({ title: t("github.notGranted", "Connect GitHub"), subtitle: t("github.notGrantedHelp", "Allow GitHub read access in Settings > Apps > Inbox"), symbol: "link", tint: "secondary" }).onTap(() => refreshGithub(true));
        if (g.status === "unavailable")
          return Row({ title: t("github.unavailable", "GitHub through cmux is not available yet"), subtitle: t("github.unavailableHelp", "This cmux has no integration gateway"), symbol: "icloud.slash", tint: "tertiary" });
        if (g.status === "error" || g.status === "partial")
          return Row({ title: t("github.error", "Could not load GitHub"), subtitle: g.errors[0] ?? "", symbol: "exclamationmark.triangle", tint: "warning" }).onTap(() => refreshGithub(true));
        return null;
      }
    ]);
  }
  function Empty() {
    return Group([
      () => {
        if (visible().length > 0)
          return null;
        if (!loaded())
          return Text(t("loading", "Loading…")).font("caption").color("tertiary").paddingHorizontal(14).paddingVertical(6);
        if (items().length > 0)
          return EmptyState({ title: t("empty.filtered", "Nothing matches these filters"), symbol: "line.3.horizontal.decrease.circle" });
        return EmptyState({ title: t("empty.title", "Nothing needs you"), message: t("empty.message", "Agents, notifications and GitHub are all clear."), symbol: "checkmark.circle" });
      }
    ]);
  }
  function SnoozedFooter() {
    return Group([
      () => {
        const n = counts().snoozed;
        const showing = filters().showSnoozed;
        if (n === 0 && !showing)
          return null;
        const title = showing ? t("snoozed.hide", "Hide Snoozed") : t("snoozed.count", "{n} snoozed", { n });
        return HStack([Icon(showing ? "chevron.left" : "moon.zzz").font("caption").color("tertiary"), Text(title).font("caption").color("secondary"), Spacer()]).paddingHorizontal(14).paddingVertical(4).cursor("pointer").onTap(() => setFilters({ showSnoozed: !showing }));
      }
    ]);
  }
  var contextCache = new Map;
  var CONTEXT_CACHE_LIMIT = 64;
  var screenTail = (text, lines) => text.split(`
`).map((l) => l.replace(/\s+$/, "")).filter((l) => l.trim()).slice(-lines).join(`
`);
  function checkText(s) {
    if (s.state === "fail")
      return t("github.checks.fail", "{n} failed: {names}", { n: s.counts.fail, names: s.failed.slice(0, 4).join(", ") });
    if (s.state === "pending")
      return t("github.checks.pending", "Checks running");
    if (s.state === "pass")
      return t("github.checks.pass", "All checks passed");
    return t("github.checks.neutral", "No check results");
  }
  function itemContext(item) {
    const [text, setText] = signal(null);
    let key = "";
    const remember = (k, value) => {
      if (contextCache.size >= CONTEXT_CACHE_LIMIT)
        contextCache.delete(contextCache.keys().next().value);
      contextCache.set(k, value);
      if (key === k)
        setText(value);
    };
    effect(() => {
      const i = item();
      const k = i ? `${i.id}@${i.at}` : "";
      if (k === key)
        return;
      key = k;
      setText(contextCache.get(k) ?? i?.body ?? null);
      if (!i || contextCache.has(k))
        return;
      if (i.source === "agent" && i.terminal) {
        cmux.terminal.screen.read({ terminal: i.terminal }).then((r) => remember(k, screenTail(r.text, 8))).catch(() => {});
      } else if (i.kind === "checksFailing" && i.repo && i.number) {
        loadChecks(githubRequest, i.repo, i.number).then((s) => remember(k, checkText(s))).catch(() => {});
      } else if (i.source === "github" && i.author) {
        setText(t("github.by", "Opened by {author}", { author: i.author }));
      }
    });
    return text;
  }
  var hasUnread = computed(() => counts().unread > 0);
  function UnreadBadge() {
    return Group([() => hasUnread() ? Badge(() => counts().unread, () => counts().blocked > 0 ? "warning" : "secondary") : null]);
  }
  var MENU_ITEMS = 8;
  var open = () => items().filter((i) => i.snoozedUntil === null);
  function StatusItem() {
    return HStack({ spacing: 4 }, [
      Icon(() => counts().open > 0 ? "tray.full" : "tray").color(() => counts().blocked > 0 ? "warning" : "secondary"),
      UnreadBadge()
    ]).paddingHorizontal(6).cornerRadius(6).hoverBackground("hover").help(() => counts().unread > 0 ? t("badge.unread", "{n} unread", { n: counts().unread }) : t("status.none", "Nothing needs you")).onTap(() => {
      const next = open().find((i) => i.unread) ?? open()[0];
      return next ? openItem(next) : undefined;
    }).contextMenu(() => {
      const list = open().slice(0, MENU_ITEMS);
      return [
        ...list.length ? list.map((i) => Button(`${kindLabel(i.kind)}: ${i.title}`, () => openItem(i))) : [Button(t("status.none", "Nothing needs you")).disabled()],
        Divider(),
        Button(t("action.markAllRead", "Mark All as Read"), () => markAllRead()),
        Button(t("action.refresh", "Refresh"), () => refreshGithub(true))
      ];
    });
  }
  function detailState() {
    const id = computed(() => current()?.id ?? null);
    const has = computed(() => id() !== null);
    const isAgent = computed(() => current()?.source === "agent");
    const [draft, setDraft] = signal("");
    const context = itemContext(current);
    const hasContext = computed(() => !!context());
    return { item: current, id, has, isAgent, context, hasContext, draft, setDraft };
  }
  var BLANK = { id: "", source: "notification", kind: "notification", title: "", detail: "", at: 0, unreadHint: false, mine: false, notifications: [], unread: false, snoozedUntil: null, workspace: null };
  var get = (s) => s.item() ?? BLANK;
  var act = (s, fn) => () => {
    const i = s.item();
    return i ? fn(i) : undefined;
  };
  function Actions(s, withSkip) {
    return HStack({ spacing: 8 }, [
      Button(t("action.open", "Open"), act(s, openItem)),
      Button(t("action.doneShort", "Done"), act(s, (i) => markDone2([i]))),
      snoozeMenu(() => s.item() ? [s.item()] : []),
      Spacer(),
      withSkip ? Button(t("action.skip", "Skip"), () => step(1, s.id())) : null
    ]);
  }
  function ReplyField(s) {
    return Group([
      () => {
        if (!s.isAgent())
          return null;
        if (replyBlocked())
          return Text(t("reply.needsScope", "Quick reply needs permission to type into terminals (Settings > Apps > Inbox).")).font("caption").color("tertiary").lineLimit(3);
        return TextField(s.draft, {
          placeholder: t("action.reply", "Reply…"),
          onEdit: (text) => s.setDraft(text),
          onSubmit: (text) => act(s, (i) => reply(i, text).then((ok) => ok && s.setDraft("")))()
        });
      }
    ]);
  }
  function Summary(s, titleFont) {
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 6 }, [
        Icon(() => kindSymbol(get(s))).color(() => kindTint(get(s))).font("caption"),
        Text(() => kindLabel(get(s).kind)).font("caption").color("secondary"),
        Text(() => get(s).workspace?.name ?? "").font("caption").color("tertiary").lineLimit(1),
        Spacer(),
        Text(() => ago(get(s).at, now())).font("caption").color("tertiary")
      ]),
      Text(() => get(s).title).font(titleFont).lineLimit(4),
      Text(() => get(s).detail).font("callout").color("secondary").lineLimit(2),
      () => s.hasContext() ? Text(s.context).font("caption").monospaced().color("secondary").lineLimit(10).padding(8).frame({ maxWidth: "infinity" }).background("hover").cornerRadius(6) : null
    ]);
  }
  function Detail(s) {
    return Group([
      () => s.has() ? VStack({ spacing: 12 }, [Summary(s, "headline"), Actions(s, false), ReplyField(s)]) : Text(t("detail.none", "Select an item")).font("callout").color("tertiary").padding(12)
    ]);
  }
  var groupTitle = (g) => g.source ? sourceLabel(g.source) : g.label;
  function Toolbar() {
    return HStack({ spacing: 6 }, [
      FilterMenu(),
      Spacer(),
      UnreadBadge(),
      Button(Icon("checkmark.circle").color("secondary"), () => markAllRead()).help(t("action.markAllRead", "Mark All as Read"))
    ]).paddingHorizontal(12).paddingVertical(2);
  }
  function renderGrouped(wide) {
    const root = VStack({ spacing: 2 }, [
      Toolbar(),
      Notices(),
      LayoutProbe(),
      ForEach({ items: groups, key: (g) => g.key }, (g) => VStack({ spacing: 0 }, [
        HStack({ spacing: 4 }, [
          Text(() => groupTitle(g())).font("caption").weight("semibold").color("secondary").lineLimit(1),
          Spacer(),
          Text(() => String(g().items.length)).font("caption").color("tertiary")
        ]).paddingHorizontal(14).padding({ top: 6, bottom: 2, leading: 14, trailing: 14 }),
        ForEach({ items: () => g().items, key: (i) => i.id }, (i) => ItemRow(i, { tapOpens: true }))
      ])),
      GithubStatusRow(),
      Empty(),
      SnoozedFooter()
    ]);
    return wide ? root.frame({ maxWidth: 720 }) : root;
  }
  function Chip(symbol, label, active, action) {
    return Button(Icon(symbol).font("caption").color(() => active() ? "primary" : "secondary"), action).padding(5).background(() => active() ? "selected" : null).hoverBackground("hover").cornerRadius(6).help(label);
  }
  function ChipBar() {
    const sources = ["all", "agent", "notification", "github"];
    return HStack({ spacing: 2 }, [
      ...sources.map((s) => Chip(SOURCE_SYMBOLS[s], sourceLabel(s), () => filters().source === s && !filters().showSnoozed, () => setFilters({ source: s, showSnoozed: false }))),
      Spacer(),
      Chip("envelope.badge", t("filter.unreadOnly", "Show Unread Only"), () => filters().unreadOnly, () => setFilters({ unreadOnly: !filters().unreadOnly })),
      Chip("person", t("filter.mineOnly", "Show Only My Work"), () => filters().mineOnly, () => setFilters({ mineOnly: !filters().mineOnly })),
      Chip("checkmark.circle", t("action.markAllRead", "Mark All as Read"), () => false, () => markAllRead())
    ]).paddingHorizontal(10);
  }
  function renderFocus(wide) {
    const detail = detailState();
    const list = VStack({ spacing: 2 }, [
      ChipBar(),
      Notices(),
      ForEach({ items: visible, key: (i) => i.id }, (i) => ItemRow(i, { tapOpens: false, selectedId: () => current()?.id ?? null, onSelect: setSelected })),
      GithubStatusRow(),
      Empty(),
      SnoozedFooter()
    ]);
    if (wide)
      return HStack({ spacing: 0 }, [VStack([list, Spacer()]).frame({ width: 320, maxHeight: "infinity" }), Divider(), VStack([Detail(detail), Spacer()]).padding(16).frame({ maxWidth: "infinity", maxHeight: "infinity" })]);
    return VStack({ spacing: 8 }, [list, Divider(), Detail(detail).paddingHorizontal(12)]);
  }
  function renderCard(wide) {
    const detail = detailState();
    const position = computed(() => {
      const list = visible();
      const index = list.findIndex((i) => i.id === (selected() ?? list[0]?.id));
      return list.length ? t("card.position", "{index} of {total}", { index: Math.max(0, index) + 1, total: list.length }) : "";
    });
    const card = VStack({ spacing: 12 }, [Summary(detail, "title3"), Actions(detail, true), ReplyField(detail)]).padding(14).background("hover").borderColor("separator").borderWidth(1).cornerRadius(10);
    const root = VStack({ spacing: 8 }, [
      HStack({ spacing: 6 }, [FilterMenu(), Spacer(), Text(position).font("caption").color("tertiary")]).paddingHorizontal(12),
      Notices(),
      Group([() => detail.has() ? card : null]).paddingHorizontal(10),
      GithubStatusRow(),
      Empty(),
      SnoozedFooter()
    ]);
    return wide ? root.frame({ maxWidth: 560 }) : root;
  }
  var RENDERERS = { grouped: renderGrouped, focus: renderFocus, card: renderCard };
  function surface(wide) {
    attach();
    scheduleGithub();
    return VStack([ForEach({ items: () => [variant()], key: (v) => v }, (v) => RENDERERS[v()](wide))]);
  }
  function renderInbox(ctx = {}) {
    return surface(ctx.surface === "pane");
  }
  function renderPane() {
    return surface(true);
  }
  function renderStatus() {
    attach();
    scheduleGithub();
    return StatusItem();
  }
  function commandError(code, message) {
    const E = CmuxError;
    return new E(code, message);
  }
  async function findItem(id) {
    await ensureData();
    const item = typeof id === "string" && id ? items().find((i) => i.id === id) : current() ?? undefined;
    if (!item)
      throw commandError("item.not_found", t("item.notFound", "No inbox item {id}", { id: String(id ?? "") }));
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
  async function markAllRead2() {
    await ensureData();
    return { marked: await markAllRead() };
  }
  async function move(direction, args) {
    await ensureData();
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
  async function markDone3(args = {}) {
    const item = await findItem(args.id);
    await markDone2([item]);
    return { id: item.id, done: true };
  }
  async function snooze2(args = {}) {
    const item = await findItem(args.id);
    const minutes = typeof args.minutes === "number" && args.minutes > 0 ? Math.min(args.minutes, 60 * 24 * 30) : 60;
    const until = Date.now() + minutes * 60000;
    await snoozeItems([item], until);
    return { id: item.id, until: new Date(until).toISOString() };
  }
  async function list(args = {}) {
    await ensureData();
    const out = items().filter((i) => (args.includeSnoozed || i.snoozedUntil === null) && (!args.source || i.source === args.source) && (!args.unreadOnly || i.unread));
    return { items: out.map(itemJSON), visible: visible().length };
  }
  async function refresh() {
    await ensureData();
    await refreshGithub(true);
    return { items: items().length };
  }
  async function cycleVariant2() {
    return { variant: await cycleVariant() };
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
