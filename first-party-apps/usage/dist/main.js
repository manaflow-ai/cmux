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
    refresh: () => refresh,
    renderPane: () => renderPane,
    renderSection: () => renderSection,
    renderStatus: () => renderStatus,
    show: () => show,
    status: () => status
  });
  var ja = {
    "advice.over": "負荷を下げる",
    "advice.under": "負荷を上げる",
    "alert.body": "{total} 個のアカウントがすべて使い切り、冷却中、またはエラーです。",
    "alert.title": "使える {provider} アカウントがありません",
    "column.account": "アカウント",
    "column.pace": "ペース",
    "column.session": "5時間",
    "column.state": "状態",
    "column.weekly": "週",
    "duration.daysHours": "{d}日{h}時間",
    "duration.hoursMinutes": "{h}時間{m}分",
    "duration.lessThanMinute": "1分未満",
    "duration.minutes": "{m}分",
    "empty.message": "ルーターにアカウントを追加すると (sr add)、cmux がここに使用量を表示します。",
    "empty.title": "アカウントが見つかりません",
    "error.title": "使用量を読み込めません",
    extra: "追加 ${usd}",
    loading: "読み込み中…",
    "menu.noData": "使用量データがありません",
    "menu.refresh": "今すぐ更新",
    "menu.show": "使用量を表示",
    "pace.account": "ペース {ratio}",
    "scope.message": "設定 > アプリ > 使用量 で {scope} を許可してください。",
    "scope.title": "使用量を読む権限がありません",
    "stale.ago": "古いデータ · {duration}前に更新",
    stale: "古いデータ",
    "state.active": "使用中",
    "state.cooked": "使い切り",
    "state.error": "エラー",
    "state.protected": "保留",
    "state.ready": "待機",
    "state.rec": "次候補",
    "state.temp": "冷却中",
    "state.unknown": "不明",
    "summary.burn": "{actual}%/時 (理想 {ideal}%/時)",
    "summary.ideal": "理想 {ideal}%/時",
    "summary.left": "残り {left}",
    "summary.usable": "{total} 中 {usable} 個が使用可能",
    "unavailable.message": "このビルドには使用量サーバー ({op}) がまだありません。",
    "unavailable.title": "使用量サーバーがありません",
    usableBadge: "{usable}/{total}",
    "verdict.none": "残りなし",
    "verdict.onPace": "ペース通り",
    "verdict.over": "ペース超過",
    "verdict.pending": "30分後にペース",
    "verdict.under": "ペース不足",
    "verdict.unmetered": "週間上限なし",
    "window.leftReset": "{left} · {reset}",
    "window.session": "5時間 {text}",
    "window.weekly": "週 {text}"
  };
  var tables = { ja };
  var locale = detectLocale();
  function detectLocale() {
    try {
      return new Intl.DateTimeFormat().resolvedOptions().locale || "en";
    } catch {
      return "en";
    }
  }
  function currentLanguage() {
    return locale.split(/[-_]/)[0].toLowerCase();
  }
  function t(key, english, vars = {}) {
    const template = tables[currentLanguage()]?.[key] ?? english;
    return template.replace(/\{(\w+)\}/g, (whole, name) => (name in vars) ? String(vars[name]) : whole);
  }
  var MINUTE = 60000;
  var HOUR = 60 * MINUTE;
  var DAY = 24 * HOUR;
  var pctText = (p) => p === null || p === undefined ? "—" : `${Math.round(p)}%`;
  function durationText(ms) {
    if (ms < MINUTE)
      return t("duration.lessThanMinute", "<1m");
    if (ms < HOUR)
      return t("duration.minutes", "{m}m", { m: Math.floor(ms / MINUTE) });
    if (ms < DAY)
      return t("duration.hoursMinutes", "{h}h {m}m", { h: Math.floor(ms / HOUR), m: Math.floor(ms % HOUR / MINUTE) });
    return t("duration.daysHours", "{d}d {h}h", { d: Math.floor(ms / DAY), h: Math.floor(ms % DAY / HOUR) });
  }
  var unitFor = (ms) => ms < DAY ? MINUTE : HOUR;
  var TITLES = { claude: "Claude", codex: "Codex" };
  var providerTitle = (id) => TITLES[id] ?? id.charAt(0).toUpperCase() + id.slice(1);
  var SHORT = { claude: "Cl", codex: "Cx" };
  var providerInitial = (id) => SHORT[id] ?? providerTitle(id).slice(0, 2);
  function stateText(s) {
    switch (s) {
      case "active":
        return t("state.active", "in use");
      case "rec":
        return t("state.rec", "next");
      case "ready":
        return t("state.ready", "ready");
      case "protected":
        return t("state.protected", "held");
      case "temp":
        return t("state.temp", "cooling");
      case "cooked":
        return t("state.cooked", "used up");
      case "error":
        return t("state.error", "error");
      default:
        return t("state.unknown", "unknown");
    }
  }
  function windowText(w, now) {
    if (!w)
      return null;
    const reset = w.resetAt === null ? null : durationText(Math.max(0, w.resetAt - now));
    return reset ? t("window.leftReset", "{left} · {reset}", { left: pctText(w.leftPct), reset }) : pctText(w.leftPct);
  }
  var ratioText = (r) => `×${r < 10 ? r.toFixed(2) : Math.round(r)}`;
  function verdictText(v, metered = true) {
    switch (v) {
      case "under":
        return t("verdict.under", "under pace");
      case "over":
        return t("verdict.over", "over pace");
      case "onPace":
        return t("verdict.onPace", "on pace");
      case "none":
        return metered ? t("verdict.none", "no headroom") : t("verdict.unmetered", "no weekly limit");
      default:
        return t("verdict.pending", "pace in 30m");
    }
  }
  function adviceText(v) {
    if (v === "under")
      return t("advice.under", "raise load");
    if (v === "over")
      return t("advice.over", "lower load");
    return null;
  }
  var rate = (n) => n < 10 ? n.toFixed(1) : String(Math.round(n));
  function summaryText(p, withVerdict = true) {
    if (!p.metered)
      return t("summary.usable", "{usable} of {total} usable", { usable: p.usable, total: p.total });
    const head = [withVerdict ? verdictText(p.verdict) : null, p.ratio !== null ? ratioText(p.ratio) : null].filter((x) => x !== null).join(" ");
    const parts = head ? [head] : [];
    const advice = adviceText(p.verdict);
    if (advice)
      parts.push(advice);
    if (p.actualPerHour !== null)
      parts.push(t("summary.burn", "{actual}%/h of {ideal}%/h", { actual: rate(Math.max(0, p.actualPerHour)), ideal: rate(p.idealPerHour) }));
    else if (p.idealPerHour > 0)
      parts.push(t("summary.ideal", "ideal {ideal}%/h", { ideal: rate(p.idealPerHour) }));
    parts.push(t("summary.usable", "{usable} of {total} usable", { usable: p.usable, total: p.total }));
    return parts.join(" · ");
  }
  var accountPaceText = (p) => p ? t("pace.account", "pace {ratio}", { ratio: ratioText(p.ratio) }) : null;
  var isStale = (u, now, staleMs) => u.stale || u.fetchedAt !== null && now - u.fetchedAt > staleMs;
  function staleText(u, now) {
    return u.fetchedAt === null ? t("stale", "Stale") : t("stale.ago", "Stale · updated {duration} ago", { duration: durationText(Math.max(0, now - u.fetchedAt)) });
  }
  function nextTextChange(now, input) {
    let next = Infinity;
    for (const target of input.countdownsTo) {
      const left = target - now;
      if (left <= 0)
        continue;
      const unit = unitFor(left);
      next = Math.min(next, now + (left % unit || unit));
    }
    for (const since of input.agesFrom) {
      const age = Math.max(0, now - since);
      const unit = unitFor(age);
      next = Math.min(next, now + (unit - age % unit));
    }
    for (const at of input.staleAt)
      if (at > now)
        next = Math.min(next, at);
    return Number.isFinite(next) ? next : null;
  }
  var STATES = ["error", "cooked", "temp", "active", "rec", "protected", "ready"];
  var obj = (v) => v && typeof v === "object" && !Array.isArray(v) ? v : {};
  var str = (v) => typeof v === "string" && v.length > 0 ? v : null;
  var num = (v) => {
    const n = typeof v === "string" && v.trim() !== "" ? Number(v) : v;
    return typeof n === "number" && Number.isFinite(n) ? n : null;
  };
  function time(v) {
    if (typeof v === "string" && /^\d{4}-\d\d-\d\dT/.test(v)) {
      const ms = Date.parse(v);
      return Number.isFinite(ms) ? ms : null;
    }
    return num(v);
  }
  var pct = (v) => {
    const n = num(v);
    return n === null ? null : Math.min(100, Math.max(0, n));
  };
  var stateOf = (v) => STATES.includes(v) ? v : "unknown";
  var isUsable = (s) => s !== "cooked" && s !== "temp" && s !== "error";
  function window(left, reset) {
    const leftPct = pct(left);
    return leftPct === null ? null : { leftPct, resetAt: time(reset) };
  }
  function normalizeAccount(raw, provider) {
    const r = obj(raw);
    const id = str(r.id);
    if (!id)
      return null;
    return {
      id,
      label: str(r.label) ?? id,
      provider: str(r.provider) ?? provider,
      plan: str(r.plan),
      state: stateOf(r.state),
      session: window(r.session_left_pct, r.session_reset_at),
      weekly: window(r.weekly_left_pct, r.weekly_reset_at),
      extraUsd: num(r.extra_usage_usd),
      source: str(r.source)
    };
  }
  var DISPLAY_RANK = { active: 0, rec: 1, ready: 2, protected: 3, temp: 4, cooked: 5, error: 6, unknown: 7 };
  function sortAccounts(accounts) {
    return [...accounts].sort((a, b) => DISPLAY_RANK[a.state] - DISPLAY_RANK[b.state] || (a.weekly?.resetAt ?? Infinity) - (b.weekly?.resetAt ?? Infinity) || a.label.localeCompare(b.label));
  }
  function summarize(accounts) {
    const usable = accounts.filter((a) => isUsable(a.state));
    return { usable: usable.length, total: accounts.length, weeklyLeftSumPct: usable.reduce((sum, a) => sum + (a.weekly?.leftPct ?? 0), 0) };
  }
  var PROVIDER_ORDER = ["claude", "codex"];
  var providerRank = (id) => {
    const i = PROVIDER_ORDER.indexOf(id);
    return i < 0 ? PROVIDER_ORDER.length : i;
  };
  function normalizeProviders(raw) {
    const out = [];
    for (const [id, value] of Object.entries(obj(raw))) {
      const p = obj(value);
      const accounts = (Array.isArray(p.accounts) ? p.accounts : []).map((a) => normalizeAccount(a, id)).filter((a) => a !== null);
      const s = obj(p.summary);
      const usable = num(s.usable);
      const total = num(s.total);
      const left = num(s.weekly_left_sum_pct);
      const summary = usable !== null && total !== null && left !== null ? { usable, total, weeklyLeftSumPct: left } : summarize(accounts);
      out.push({ id, accounts: sortAccounts(accounts), summary });
    }
    return out.sort((a, b) => providerRank(a.id) - providerRank(b.id) || a.id.localeCompare(b.id));
  }
  function normalizeError(raw) {
    if (!raw)
      return null;
    const r = obj(raw);
    return { code: str(r.code) ?? "usage.failed", message: str(r.message) ?? "" };
  }
  function normalizeUsage(value) {
    const r = obj(value);
    const sources = (Array.isArray(r.sources) ? r.sources : []).map((s) => {
      const o = obj(s);
      const error = normalizeError(o.error);
      return { id: str(o.id) ?? "router", ok: o.ok !== false && error === null, error };
    });
    return {
      fetchedAt: time(r.fetched_at_ms) ?? time(r.generated_at),
      stale: r.stale === true,
      error: normalizeError(r.error),
      sources,
      providers: normalizeProviders(r.providers)
    };
  }
  function normalizeHistory(value) {
    const list = obj(value).snapshots;
    if (!Array.isArray(list))
      return [];
    const out = [];
    for (const raw of list) {
      const r = obj(raw);
      const at = time(r.taken_at_ms);
      if (at === null)
        continue;
      const accounts = new Map;
      for (const a of Array.isArray(r.accounts) ? r.accounts : []) {
        const o = obj(a);
        const id = str(o.id);
        const provider = str(o.provider);
        if (!id || !provider)
          continue;
        accounts.set(`${provider}/${id}`, { provider, state: stateOf(o.state), weeklyLeftPct: pct(o.weekly_left_pct), weeklyResetAt: time(o.weekly_reset_at) });
      }
      out.push({ at, accounts });
    }
    return out.sort((a, b) => a.at - b.at);
  }
  function snapshotOf(usage, at) {
    const accounts = new Map;
    for (const p of usage.providers) {
      for (const a of p.accounts) {
        accounts.set(`${p.id}/${a.id}`, { provider: p.id, state: a.state, weeklyLeftPct: a.weekly?.leftPct ?? null, weeklyResetAt: a.weekly?.resetAt ?? null });
      }
    }
    return { at, accounts };
  }
  var HOUR2 = 3600000;
  var MIN_BASELINE_MS = 30 * 60000;
  var UNDER_BELOW = 0.8;
  var OVER_ABOVE = 1.2;
  var SESSION_MS = 5 * HOUR2;
  var WEEK_MS = 7 * 24 * HOUR2;
  var MIN_ELAPSED_SHARE = 0.05;
  var RESET_MOVED_MS = HOUR2;
  var verdictOf = (ratio) => ratio < UNDER_BELOW ? "under" : ratio > OVER_ABOVE ? "over" : "onPace";
  var counted = (accounts) => accounts.filter((a) => a.state !== "error");
  function idealPerHour(accounts, now) {
    let ideal = 0;
    for (const a of counted(accounts)) {
      const r = a.weekly?.resetAt ?? null;
      if (a.weekly && r !== null && r > now)
        ideal += a.weekly.leftPct / ((r - now) / HOUR2);
    }
    return ideal;
  }
  function pickBaseline(history, now) {
    let best = null;
    for (const s of history)
      if (now - s.at >= MIN_BASELINE_MS && (!best || s.at > best.at))
        best = s;
    return best;
  }
  function actualPerHour(provider, baseline, current) {
    const hours = (current.at - baseline.at) / HOUR2;
    if (hours <= 0)
      return null;
    let drop = 0;
    let matched = 0;
    for (const [key, now] of current.accounts) {
      if (now.provider !== provider || now.state === "error" || now.weeklyLeftPct === null)
        continue;
      const before = baseline.accounts.get(key);
      if (!before || before.weeklyLeftPct === null)
        continue;
      const moved = before.weeklyResetAt !== null && now.weeklyResetAt !== null && Math.abs(now.weeklyResetAt - before.weeklyResetAt) > RESET_MOVED_MS;
      const passed = before.weeklyResetAt !== null && before.weeklyResetAt <= current.at;
      if (moved || passed)
        continue;
      drop += before.weeklyLeftPct - now.weeklyLeftPct;
      matched++;
    }
    return matched === 0 ? null : drop / hours;
  }
  function providerPace(provider, current, baseline) {
    const accounts = counted(provider.accounts);
    const ideal = idealPerHour(provider.accounts, current.at);
    const actual = baseline ? actualPerHour(provider.id, baseline, current) : null;
    const ratio = actual !== null && ideal > 0 ? actual / ideal : null;
    return {
      provider: provider.id,
      total: provider.accounts.length,
      counted: accounts.length,
      usable: accounts.filter((a) => isUsable(a.state)).length,
      metered: accounts.some((a) => a.weekly !== null),
      leftSumPct: accounts.reduce((sum, a) => sum + (a.weekly?.leftPct ?? 0), 0),
      idealPerHour: ideal,
      actualPerHour: actual,
      ratio,
      verdict: ideal <= 0 ? "none" : ratio === null ? "pending" : verdictOf(ratio),
      baselineAt: actual === null ? null : baseline?.at ?? null
    };
  }
  function windowPace(w, lengthMs, now) {
    if (!w || w.resetAt === null)
      return null;
    const left = w.resetAt - now;
    if (left <= 0 || left > lengthMs)
      return null;
    const elapsedShare = 1 - left / lengthMs;
    if (elapsedShare < MIN_ELAPSED_SHARE)
      return null;
    const ratio = (100 - w.leftPct) / 100 / elapsedShare;
    return { ratio, verdict: verdictOf(ratio), expectedLeftPct: left / lengthMs * 100 };
  }
  var weeklyPace = (a, now) => windowPace(a.weekly, WEEK_MS, now);
  var sessionPace = (a, now) => windowPace(a.session, SESSION_MS, now);
  var r2 = (n) => n === null ? null : Math.round(n * 100) / 100;
  var iso = (ms) => ms === null ? null : new Date(ms).toISOString();
  function statusJSON(usage, paces, options) {
    const at = usage?.fetchedAt ?? options.now;
    const list = (usage?.providers ?? []).filter((p) => !options.provider || p.id === options.provider);
    return {
      state: options.state,
      problem: options.problem,
      fetched_at: iso(usage?.fetchedAt ?? null),
      stale: usage ? isStale(usage, options.now, options.staleMs) : false,
      providers: list.map((p) => {
        const pace = paces.find((x) => x.provider === p.id) ?? null;
        return {
          id: p.id,
          summary: { usable: p.summary.usable, total: p.summary.total, weekly_left_sum_pct: p.summary.weeklyLeftSumPct },
          pace: pace && {
            verdict: pace.verdict,
            ratio: r2(pace.ratio),
            actual_pct_per_hour: r2(pace.actualPerHour),
            ideal_pct_per_hour: r2(pace.idealPerHour),
            left_sum_pct: pace.leftSumPct,
            counted: pace.counted,
            usable: pace.usable,
            baseline_at: iso(pace.baselineAt)
          },
          ...options.accounts ? {
            accounts: p.accounts.map((a) => ({
              id: a.id,
              label: a.label,
              plan: a.plan,
              state: a.state,
              session_left_pct: a.session?.leftPct ?? null,
              session_reset_at: iso(a.session?.resetAt ?? null),
              weekly_left_pct: a.weekly?.leftPct ?? null,
              weekly_reset_at: iso(a.weekly?.resetAt ?? null),
              extra_usage_usd: a.extraUsd,
              weekly_pace: r2(weeklyPace(a, at)?.ratio ?? null),
              session_pace: r2(sessionPace(a, at)?.ratio ?? null)
            }))
          } : {}
        };
      })
    };
  }
  function planAlerts(providers, fired) {
    const next = {};
    const alerts = [];
    const seen = new Set;
    for (const p of providers) {
      seen.add(p.id);
      const out = p.summary.total > 0 && p.summary.usable === 0;
      if (!out)
        continue;
      next[p.id] = true;
      if (!fired[p.id])
        alerts.push({ provider: p.id, total: p.summary.total });
    }
    for (const id of Object.keys(fired))
      if (!seen.has(id))
        next[id] = true;
    return { alerts, fired: next };
  }
  function alertMessage(alert) {
    return {
      title: t("alert.title", "No usable {provider} account", { provider: providerTitle(alert.provider) }),
      body: t("alert.body", "All {total} accounts are used up, cooling or failing.", { total: alert.total }),
      level: "error"
    };
  }
  async function notifyAlerts(alerts) {
    for (const alert of alerts) {
      const m = alertMessage(alert);
      try {
        await cmux.notification.create({ title: m.title, body: m.body, level: m.level });
      } catch (e) {
        cmux.log("usage warning not sent:", String(e));
      }
    }
  }
  var ACCOUNT_LIST = "account.list";
  var ACCOUNT_USAGE = "account.usage";
  var ACCOUNT_REFRESH = "account.refresh";
  var [usage, setUsage] = signal(null);
  var [baseline, setBaseline] = signal(null);
  var [state, setState] = signal("loading");
  var [problem, setProblem] = signal(null);
  var [now, setNow] = signal(Date.now());
  var settings = () => cmux.app.settings();
  var staleMs = () => Math.max(1, Number(settings().staleMinutes ?? 30)) * 60000;
  var providers = () => usage()?.providers ?? [];
  var readingAt = () => usage()?.fetchedAt ?? now();
  var stale = () => {
    const u = usage();
    return u ? isStale(u, now(), staleMs()) : false;
  };
  var paces = computed(() => {
    const u = usage();
    if (!u)
      return [];
    const current = snapshotOf(u, u.fetchedAt ?? now());
    const base = baseline();
    return u.providers.map((p) => providerPace(p, current, base));
  });
  var paceOf = (provider) => paces().find((p) => p.provider === provider) ?? null;
  var inFlight = null;
  var again = false;
  function load() {
    if (inFlight) {
      again = true;
      return inFlight;
    }
    inFlight = readAll().finally(() => {
      inFlight = null;
      if (again) {
        again = false;
        load();
      }
    });
    return inFlight;
  }
  async function readAll() {
    let next;
    try {
      next = normalizeUsage(await cmux.call(ACCOUNT_LIST, {}));
    } catch (err) {
      const e = err;
      const code = e?.code ?? "operation.failed";
      setProblem({ code, message: e?.message ?? String(err), scope: e?.details?.scope });
      setState(code === "operation.unsupported" ? "unavailable" : code === "scope.missing" ? "denied" : usage() ? "ready" : "error");
      if (code !== "operation.unsupported" && code !== "scope.missing")
        cmux.log("usage read failed:", code);
      setNow(Date.now());
      return;
    }
    const at = next.fetchedAt ?? Date.now();
    const history = await cmux.call(ACCOUNT_USAGE, { before_ms: String(at - MIN_BASELINE_MS), limit: 1 }).catch(() => null);
    setNow(Date.now());
    setBaseline(history === null ? null : pickBaseline(normalizeHistory(history), at));
    setUsage(next);
    setProblem(next.error);
    setState("ready");
    queueAlerts();
  }
  var clockTimer = null;
  var armQueued = false;
  function clockTargets(at) {
    const countdownsTo = [];
    const agesFrom = [];
    const staleAt = [];
    const u = usage();
    if (u?.fetchedAt != null) {
      if (isStale(u, at, staleMs()))
        agesFrom.push(u.fetchedAt);
      else
        staleAt.push(u.fetchedAt + staleMs());
    }
    for (const p of u?.providers ?? []) {
      for (const a of p.accounts) {
        if (a.session?.resetAt != null)
          countdownsTo.push(a.session.resetAt);
        if (a.weekly?.resetAt != null)
          countdownsTo.push(a.weekly.resetAt);
      }
    }
    return { countdownsTo, agesFrom, staleAt };
  }
  function requestClock() {
    if (armQueued)
      return;
    armQueued = true;
    Promise.resolve().then(() => {
      armQueued = false;
      if (clockTimer !== null)
        cmux.timer.clear(clockTimer);
      clockTimer = null;
      const at = Date.now();
      const next = nextTextChange(at, clockTargets(at));
      if (next === null)
        return;
      clockTimer = cmux.timer.after(next - at + 5, () => {
        clockTimer = null;
        setNow(Date.now());
      });
    });
  }
  function attach(demand) {
    setNow(Date.now());
    cmux.events.on("account.watch", () => void load(), { demand });
    effect(() => {
      now();
      usage();
      staleMs();
      requestClock();
    });
    if (state() === "loading" && !inFlight)
      load();
  }
  async function refreshNow() {
    let requested = true;
    try {
      await cmux.call(ACCOUNT_REFRESH, {});
    } catch {
      requested = false;
    }
    await load();
    return { requested };
  }
  var ALERTS_KEY = "alerts.v2";
  var alertChain = Promise.resolve();
  var fired = null;
  function queueAlerts() {
    if (settings().notifications === false || stale())
      return;
    const snapshot = providers();
    alertChain = alertChain.then(async () => {
      fired ??= await cmux.storage.get(ALERTS_KEY).catch(() => null) ?? {};
      const plan = planAlerts(snapshot, fired);
      fired = plan.fired;
      await cmux.storage.set(ALERTS_KEY, plan.fired).catch((e) => cmux.log("usage alerts not persisted:", String(e)));
      await notifyAlerts(plan.alerts);
    }).catch((e) => cmux.log("usage alerts failed:", String(e)));
  }
  var VARIANTS = ["rows", "meters", "quiet"];
  var DEFAULT_VARIANT = "rows";
  var OVERRIDE_KEY = "variantOverride";
  var [override, setOverride] = signal(null);
  var loaded = false;
  var isVariant = (v) => typeof v === "string" && VARIANTS.includes(v);
  var settingValue = () => {
    const v = cmux.app.settings().variant;
    return typeof v === "string" ? v : null;
  };
  var variant = computed(() => {
    const setting = settingValue();
    const o = override();
    if (o && o.base === setting)
      return o.value;
    return isVariant(setting) ? setting : DEFAULT_VARIANT;
  });
  function loadVariantOverride() {
    if (loaded)
      return;
    loaded = true;
    cmux.storage.get(OVERRIDE_KEY).then((o) => {
      if (o && isVariant(o.value))
        setOverride(o);
    }).catch(() => {});
  }
  var nextVariant = (current) => VARIANTS[(VARIANTS.indexOf(current) + 1) % VARIANTS.length];
  async function cycleVariant() {
    const next = nextVariant(variant());
    try {
      await cmux.call("app.settings.set", { key: "variant", value: next });
      setOverride(null);
      await cmux.storage.delete(OVERRIDE_KEY).catch(() => null);
      return { variant: next, persisted: "setting" };
    } catch {
      const o = { value: next, base: settingValue() };
      setOverride(o);
      await cmux.storage.set(OVERRIDE_KEY, o).catch(() => null);
      return { variant: next, persisted: "storage" };
    }
  }
  var paceTone = (p) => p && p.metered ? verdictTone(p.verdict) : "tertiary";
  var verdictTone = (v) => {
    switch (v) {
      case "over":
        return "warning";
      case "none":
        return "danger";
      case "under":
        return "accent";
      case "onPace":
        return "success";
      default:
        return "tertiary";
    }
  };
  var stateTone = (s) => {
    switch (s) {
      case "active":
        return "success";
      case "rec":
        return "accent";
      case "temp":
        return "warning";
      case "error":
        return "danger";
      case "cooked":
      case "unknown":
        return "tertiary";
      default:
        return "secondary";
    }
  };
  var STATE_SYMBOL = {
    active: "bolt.fill",
    rec: "arrow.right.circle",
    ready: "circle",
    protected: "lock",
    temp: "hourglass",
    cooked: "flame",
    error: "exclamationmark.triangle",
    unknown: "questionmark.circle"
  };
  function worstVerdict() {
    const order = ["none", "over", "under", "onPace", "pending"];
    const list = paces().filter((p) => p.metered);
    for (const v of order)
      if (list.some((p) => p.verdict === v))
        return v;
    return null;
  }
  var meteredPaces = () => paces().filter((p) => p.metered);
  function paceToken(p) {
    const tail = p.ratio !== null ? ratioText(p.ratio) : p.verdict === "none" ? "0" : `${p.usable}/${p.total}`;
    return `${providerInitial(p.provider)} ${tail}`;
  }
  var providerLine = (p) => `${providerTitle(p.provider)} · ${summaryText(p)}`;
  function statusHelp() {
    const list = meteredPaces();
    return list.length ? list.map(providerLine).join(`
`) : t("menu.noData", "No usage data");
  }
  function accountDetail(a, at, readAt) {
    const parts = [];
    const session = windowText(a.session, at);
    const weekly = windowText(a.weekly, at);
    if (session)
      parts.push(t("window.session", "5h {text}", { text: session }));
    if (weekly)
      parts.push(t("window.weekly", "wk {text}", { text: weekly }));
    const pace = accountPaceText(weeklyPace(a, readAt));
    if (pace)
      parts.push(pace);
    if (a.extraUsd !== null)
      parts.push(t("extra", "+${usd} extra", { usd: a.extraUsd < 100 ? a.extraUsd.toFixed(2) : String(Math.round(a.extraUsd)) }));
    if (!session && !weekly && a.plan)
      parts.push(a.plan);
    return parts.join(" · ");
  }
  var accountBadge = (a) => a.weekly ? pctText(a.weekly.leftPct) : stateText(a.state);
  function accountTone(a, readAt) {
    if (a.state === "error" || a.state === "cooked" || a.state === "temp")
      return stateTone(a.state);
    const p = weeklyPace(a, readAt);
    return p?.verdict === "over" ? "warning" : "primary";
  }
  var sessionShare = (a) => a.session ? a.session.leftPct / 100 : null;
  var weeklyShare = (a) => a.weekly ? a.weekly.leftPct / 100 : null;
  var [collapsed, setCollapsed] = signal({});
  var isCollapsed = (id) => collapsed()[id] === true;
  var toggleCollapsed = (id) => setCollapsed((c) => ({ ...c, [id]: !c[id] }));
  var headroomShare = (p) => p && p.counted > 0 ? Math.min(1, p.leftSumPct / (p.counted * 100)) : 0;
  function Meter(value, width, height, tone) {
    const fill = () => ({ width: Math.round(Math.min(1, Math.max(0, value())) * width * 10) / 10, height });
    const rest = () => ({ width: Math.max(0, width - fill().width), height });
    return HStack({ spacing: 0 }, [Rectangle().fill(tone).frame(fill), Rectangle().fill("separator").frame(rest)]).frame({ width, height }).cornerRadius(height / 2);
  }
  function menuItems(actions) {
    const items = [];
    const list = paces();
    if (state() !== "ready" || list.length === 0)
      items.push(Button(problemTitle()).disabled());
    const u = usage();
    if (u && stale())
      items.push(Button(staleText(u, now())).disabled());
    for (const p of list)
      items.push(Button(providerLine(p)).disabled());
    items.push(Divider(), Button(t("menu.refresh", "Refresh Now"), actions.refresh), Button(t("menu.show", "Show Usage"), actions.show));
    return items;
  }
  function problemTitle() {
    switch (state()) {
      case "loading":
        return t("loading", "Loading…");
      case "unavailable":
        return t("unavailable.title", "Usage server not available");
      case "denied":
        return t("scope.title", "No permission to read usage");
      case "error":
        return t("error.title", "Cannot read usage");
      default:
        return providers().length ? "" : t("empty.title", "No accounts found");
    }
  }
  var problemSpec = computed(() => {
    const s = state();
    let spec = null;
    if (s === "loading")
      spec = { loading: true };
    else if (!(s === "ready" && providers().length > 0)) {
      const p = problem();
      const message = s === "unavailable" ? t("unavailable.message", "This build has no usage server ({op}) yet.", { op: "account.list" }) : s === "denied" ? t("scope.message", "Allow {scope} in Settings > Apps > Usage.", { scope: p?.scope ?? "account:read" }) : s === "error" ? p?.message ?? "" : t("empty.message", "Add accounts to your router (sr add) and cmux shows their usage here.");
      const symbol = s === "ready" ? "gauge.with.dots.needle.0percent" : s === "denied" ? "lock" : "exclamationmark.triangle";
      spec = { title: problemTitle(), message, symbol };
    }
    return JSON.stringify(spec);
  });
  function ProblemView() {
    const spec = JSON.parse(problemSpec());
    if (!spec)
      return null;
    if ("loading" in spec)
      return HStack({ spacing: 6 }, [ProgressView(), Text(t("loading", "Loading…")).secondary()]).padding(8);
    return EmptyState(spec);
  }
  function noticeText() {
    const u = usage();
    if (!u || state() !== "ready")
      return "";
    const parts = [];
    if (u.error)
      parts.push(u.error.message || u.error.code);
    for (const s of u.sources)
      if (s.error)
        parts.push(`${s.id}: ${s.error.message || s.error.code}`);
    if (stale())
      parts.push(staleText(u, now()));
    return parts.join(" · ");
  }
  function NoticeLine(font) {
    const has = computed(() => noticeText() !== "");
    return () => has() ? HStack({ spacing: 4 }, [
      Icon("exclamationmark.triangle").size(10).color("warning"),
      Text(noticeText).font(font).color("warning").lineLimit(2)
    ]).padding({ top: 4, leading: 12, bottom: 4, trailing: 12 }) : null;
  }
  var providerList = () => providers();
  var verdictLabel = (p) => p ? verdictText(p.verdict, p.metered) : "";
  var CARD_METER_WIDTH = 320;
  function metersStatus(actions) {
    return VStack({ spacing: 2 }, [
      ForEach({ items: () => meteredPaces().slice(0, 3), key: (p) => p.provider }, (p) => Meter(() => headroomShare(p()), 22, 4, () => verdictTone(p().verdict)))
    ]).paddingVertical(3).paddingHorizontal(3).opacity(() => stale() || state() !== "ready" ? 0.55 : 1).help(statusHelp).onTap(() => actions.show()).contextMenu(() => menuItems(actions));
  }
  function bar(share) {
    const has = computed(() => share() !== null);
    return () => has() ? ProgressView(() => share() ?? 0) : null;
  }
  function accountLine(a) {
    return HStack({ spacing: 8 }, [
      VStack({ spacing: 0 }, [
        Text(() => a().label).font("caption").lineLimit(1).truncation("middle"),
        Text(() => stateText(a().state)).font("caption2").color(() => stateTone(a().state))
      ]).frame({ width: 170, alignment: "leading" }),
      VStack({ spacing: 1 }, [bar(() => sessionShare(a())), Text(() => windowText(a().session, now()) ?? "").font("caption2").secondary()]).frame({ maxWidth: "infinity", alignment: "leading" }),
      VStack({ spacing: 1 }, [
        bar(() => weeklyShare(a())),
        Text(() => windowText(a().weekly, now()) ?? (a().plan ?? "")).font("caption2").color(() => accountTone(a(), readingAt()))
      ]).frame({ maxWidth: "infinity", alignment: "leading" })
    ]).padding({ top: 3, leading: 12, bottom: 3, trailing: 12 });
  }
  function providerCard(p) {
    const pace = () => paceOf(p().id);
    const open = computed(() => !isCollapsed(p().id));
    const metered = computed(() => pace()?.metered === true);
    return VStack({ spacing: 4 }, [
      VStack({ spacing: 4 }, [
        HStack({ spacing: 6 }, [
          Text(() => providerTitle(p().id)).font("headline"),
          Spacer(),
          Text(() => verdictLabel(pace())).font("caption").weight("semibold").color(() => paceTone(pace()))
        ]),
        Meter(() => headroomShare(pace()), CARD_METER_WIDTH, 6, () => paceTone(pace())).opacity(() => metered() ? 1 : 0),
        Text(() => {
          const x = pace();
          if (!x)
            return "";
          return x.metered ? `${summaryText(x, false)} · ${t("summary.left", "{left} left", { left: pctText(x.leftSumPct) })}` : summaryText(x);
        }).font("caption").secondary().lineLimit(2)
      ]).padding({ top: 10, leading: 12, bottom: 4, trailing: 12 }).cursor("pointer").onTap(() => toggleCollapsed(p().id)),
      () => open() ? ForEach({ items: () => p().accounts, key: (a) => a.id }, (a) => accountLine(a)) : null
    ]);
  }
  function metersPane() {
    return VStack({ spacing: 6 }, [NoticeLine("caption"), () => ProblemView(), ForEach({ items: providerList, key: (p) => p.id }, (p) => providerCard(p))]);
  }
  function metersSection(actions) {
    return VStack({ spacing: 6 }, [
      NoticeLine("caption2"),
      () => ProblemView(),
      ForEach({ items: providerList, key: (p) => p.id }, (p) => {
        const pace = () => paceOf(p().id);
        const metered = computed(() => pace()?.metered === true);
        return VStack({ spacing: 3 }, [
          HStack({ spacing: 4 }, [
            Text(() => providerTitle(p().id)).font("caption"),
            Spacer(),
            Text(() => `${p().summary.usable}/${p().summary.total}`).font("caption").monospaced().secondary()
          ]),
          () => metered() ? ProgressView(() => headroomShare(pace())) : null,
          Text(() => verdictLabel(pace())).font("caption2").color(() => paceTone(pace()))
        ]).padding({ top: 2, leading: 12, bottom: 2, trailing: 12 }).onTap(() => actions.show());
      })
    ]);
  }
  var alarming = (p) => p.metered && (p.verdict === "over" || p.verdict === "none" || p.usable === 0);
  var hot = computed(() => {
    const list = paces().filter(alarming);
    if (list.length === 0)
      return null;
    return list.map((p) => `${providerInitial(p.provider)} ${p.ratio !== null ? ratioText(p.ratio) : `${p.usable}/${p.total}`}`).join(" · ");
  });
  function quietStatus(actions) {
    return HStack({ spacing: 0 }, [
      () => {
        const h = hot();
        if (!h)
          return null;
        return HStack({ spacing: 3 }, [Icon("exclamationmark.triangle.fill").color("warning").size(11), Text(h).font("caption").monospaced().color("warning")]).help(statusHelp).onTap(() => actions.show()).contextMenu(() => menuItems(actions));
      }
    ]);
  }
  var cell = (s, width) => s.length > width ? `${s.slice(0, width - 1)}…` : s.padEnd(width);
  var short = (resetAt, at) => resetAt === null ? "" : durationText(Math.max(0, resetAt - at)).replace(" ", "");
  function accountTableLine(a, at, readAt) {
    const session = a.session ? `${pctText(a.session.leftPct).padStart(4)} ${short(a.session.resetAt, at)}` : "";
    const weekly = a.weekly ? `${pctText(a.weekly.leftPct).padStart(4)} ${short(a.weekly.resetAt, at)}` : a.plan ?? "";
    const pace = weeklyPace(a, readAt);
    return `${cell(a.label, 26)} ${cell(stateText(a.state), 9)} ${cell(session, 11)} ${cell(weekly, 11)} ${pace ? ratioText(pace.ratio) : ""}`.trimEnd();
  }
  function providerBlock(p) {
    const pace = () => paceOf(p().id);
    return VStack({ spacing: 1 }, [
      Text(() => {
        const x = pace();
        const verdict = x ? verdictText(x.verdict, x.metered) + (x.ratio !== null ? ` ${ratioText(x.ratio)}` : "") : "";
        return `${providerTitle(p().id)}  ${verdict}  ${p().summary.usable}/${p().summary.total}`;
      }).font("caption").weight("semibold").monospaced().color(() => paceTone(pace())).padding({ top: 8, leading: 12, bottom: 2, trailing: 12 }),
      ForEach({ items: () => p().accounts, key: (a) => a.id }, (a) => Text(() => accountTableLine(a(), now(), readingAt())).font("caption2").monospaced().lineLimit(1).color(() => a().state === "cooked" || a().state === "error" || a().state === "temp" ? stateTone(a().state) : "primary").padding({ top: 0, leading: 12, bottom: 0, trailing: 12 }))
    ]);
  }
  var tableHeader = () => `${cell(t("column.account", "account"), 26)} ${cell(t("column.state", "state"), 9)} ${cell(t("column.session", "5h"), 11)} ${cell(t("column.weekly", "week"), 11)} ${t("column.pace", "pace")}`;
  function quietPane() {
    return VStack({ spacing: 0 }, [
      NoticeLine("caption"),
      () => ProblemView(),
      Text(tableHeader).font("caption2").monospaced().color("tertiary").padding({ top: 8, leading: 12, bottom: 0, trailing: 12 }),
      ForEach({ items: providerList, key: (p) => p.id }, (p) => providerBlock(p))
    ]);
  }
  function quietSection(actions) {
    return VStack({ spacing: 1 }, [
      NoticeLine("caption2"),
      () => ProblemView(),
      ForEach({ items: providerList, key: (p) => p.id }, (p) => {
        const pace = () => paceOf(p().id);
        return Text(() => {
          const x = pace();
          const tail = x && x.metered ? x.ratio !== null ? ratioText(x.ratio) : verdictText(x.verdict) : "";
          return `${cell(providerTitle(p().id), 8)} ${cell(`${p().summary.usable}/${p().summary.total}`, 7)} ${tail}`.trimEnd();
        }).font("caption").monospaced().color(() => paceTone(pace())).padding({ top: 1, leading: 12, bottom: 1, trailing: 12 }).onTap(() => actions.show());
      })
    ]);
  }
  function rowsStatus(actions) {
    const title = () => meteredPaces().map(paceToken).join(" · ") || "—";
    return HStack({ spacing: 3 }, [
      Icon(() => worstVerdict() === "over" || worstVerdict() === "none" ? "gauge.with.needle.fill" : "gauge.with.needle").color(() => verdictTone(worstVerdict())).size(11),
      Menu(title, []).contextMenu(() => menuItems(actions))
    ]).opacity(() => stale() || state() !== "ready" ? 0.55 : 1).help(statusHelp);
  }
  function accountRow(a) {
    return Row({
      title: () => a().label,
      subtitle: () => [stateText(a().state), accountDetail(a(), now(), readingAt())].filter(Boolean).join(" · "),
      badge: () => accountBadge(a()),
      tint: () => stateTone(a().state),
      symbol: () => STATE_SYMBOL[a().state]
    });
  }
  function providerHeader(p) {
    const pace = () => paceOf(p().id);
    return VStack({ spacing: 2 }, [
      HStack({ spacing: 6 }, [
        Icon(() => isCollapsed(p().id) ? "chevron.right" : "chevron.down").size(9).color("tertiary"),
        Text(() => providerTitle(p().id)).font("headline"),
        Spacer(),
        Badge(() => verdictLabel(pace()), () => paceTone(pace()))
      ]),
      Text(() => {
        const x = pace();
        return x ? summaryText(x, false) : "";
      }).font("caption").secondary().lineLimit(2)
    ]).padding({ top: 10, leading: 12, bottom: 4, trailing: 12 }).cursor("pointer").onTap(() => toggleCollapsed(p().id));
  }
  function providerGroup(p) {
    const open = computed(() => !isCollapsed(p().id));
    return VStack({ spacing: 0 }, [
      providerHeader(p),
      () => open() ? ForEach({ items: () => p().accounts, key: (a) => a.id }, (a) => accountRow(a)) : null
    ]);
  }
  function rowsPane() {
    return VStack({ spacing: 0 }, [NoticeLine("caption"), () => ProblemView(), ForEach({ items: providerList, key: (p) => p.id }, (p) => providerGroup(p))]);
  }
  function rowsSection(actions) {
    return VStack({ spacing: 0 }, [
      NoticeLine("caption2"),
      () => ProblemView(),
      ForEach({ items: providerList, key: (p) => p.id }, (p) => {
        const pace = () => paceOf(p().id);
        return Row({
          title: () => providerTitle(p().id),
          subtitle: () => {
            const x = pace();
            return x && x.ratio !== null ? `${verdictLabel(x)} ${ratioText(x.ratio)}` : verdictLabel(x);
          },
          badge: () => t("usableBadge", "{usable}/{total}", { usable: p().summary.usable, total: p().summary.total }),
          tint: () => paceTone(pace()),
          symbol: "gauge.with.needle"
        }).onTap(() => actions.show());
      })
    ]);
  }
  var PANE = "cmux/usage#usagePane";
  async function show() {
    try {
      await cmux.actions.run("app.pane.open", { kind: PANE });
      return { shown: true };
    } catch (e) {
      return { shown: false, reason: e.code ?? String(e) };
    }
  }
  async function refresh() {
    const r = await refreshNow();
    return { ...r, providers: usage()?.providers.length ?? 0 };
  }
  var cycleVariant2 = () => cycleVariant();
  async function status(args = {}) {
    if (args.refresh)
      await refreshNow();
    else
      await load();
    return statusJSON(usage(), paces(), { now: Date.now(), staleMs: staleMs(), state: state(), problem: problem(), provider: args.provider, accounts: args.accounts === true });
  }
  var actions = { refresh: () => refresh(), show: () => show() };
  function renderStatus() {
    loadVariantOverride();
    attach("glance");
    return HStack({ spacing: 0 }, [
      () => {
        switch (variant()) {
          case "meters":
            return metersStatus(actions);
          case "quiet":
            return quietStatus(actions);
          default:
            return rowsStatus(actions);
        }
      }
    ]);
  }
  function renderSection() {
    loadVariantOverride();
    attach("detail");
    return VStack({ spacing: 0 }, [
      () => {
        switch (variant()) {
          case "meters":
            return metersSection(actions);
          case "quiet":
            return quietSection(actions);
          default:
            return rowsSection(actions);
        }
      }
    ]);
  }
  function renderPane() {
    loadVariantOverride();
    attach("detail");
    return VStack({ spacing: 0 }, [
      () => {
        switch (variant()) {
          case "meters":
            return metersPane();
          case "quiet":
            return quietPane();
          default:
            return rowsPane();
        }
      }
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
