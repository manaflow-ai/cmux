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
    renderSection: () => renderSection,
    renderStatus: () => renderStatus,
    show: () => show,
    status: () => status
  });
  var ja = {
    "window.session.hours": "{hours}時間",
    "window.session": "セッション",
    "window.weekly": "週間",
    "window.weekly.scoped": "{scope} 週間",
    "window.monthly": "月間",
    "window.daily": "日次",
    "window.budget": "予算",
    "window.credits": "クレジット",
    "duration.lessThanMinute": "1分未満",
    "duration.minutes": "{m}分",
    "duration.hoursMinutes": "{h}時間{m}分",
    "duration.daysHours": "{d}日{h}時間",
    "reset.in": "{duration}後にリセット",
    "reset.now": "まもなくリセット",
    "pace.runsOut": "{duration}後に上限に達する見込み",
    "pace.over": "想定より{delta}%多い",
    "stale.ago": "古いデータ · {duration}前に更新",
    stale: "古いデータ",
    "spend.ofLimit": "{used} / {limit}",
    "unavailable.title": "使用量サービスがありません",
    "unavailable.message": "このビルドには使用量サービス ({op}) がまだありません。",
    "scope.title": "使用量を読む権限がありません",
    "scope.message": "設定 > アプリ > 使用量 で {scope} を許可してください。",
    "error.title": "使用量を読み込めません",
    "empty.title": "プランが見つかりません",
    "empty.message": "ターミナルで Claude Code か Codex にサインインすると、cmux がその使用量を表示します。",
    loading: "読み込み中…",
    "menu.refresh": "今すぐ更新",
    "menu.show": "使用量を表示",
    "menu.noData": "使用量データがありません",
    "status.help": "{provider} · {window} · {percent}",
    "alert.title": "{provider} の{window}上限が {percent} に達しました",
    "alert.body": "{reset}。{pace}",
    "alert.bodyNoPace": "{reset}。",
    pool: "プール"
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
  var percentText = (p) => p === null ? "—" : `${Math.round(p)}%`;
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
  function windowLabel(w) {
    switch (w.kind) {
      case "session":
        return w.windowSeconds && w.windowSeconds % 3600 === 0 ? t("window.session.hours", "{hours}-hour", { hours: w.windowSeconds / 3600 }) : t("window.session", "Session");
      case "weekly":
        return w.scope ? t("window.weekly.scoped", "{scope} weekly", { scope: w.scope }) : t("window.weekly", "Weekly");
      case "monthly":
        return t("window.monthly", "Monthly");
      case "daily":
        return t("window.daily", "Daily");
      case "budget":
        return t("window.budget", "Budget");
      case "credits":
        return t("window.credits", "Credits");
      default:
        return w.label ?? w.id;
    }
  }
  function resetText(w, now) {
    if (w.resetsAt === null)
      return null;
    const left = w.resetsAt - now;
    return left <= 0 ? t("reset.now", "resets soon") : t("reset.in", "resets in {duration}", { duration: durationText(left) });
  }
  function amountText(w) {
    if (w.used === null || w.limit === null)
      return null;
    const fmt = (n) => w.unit === "usd" ? `$${n >= 100 ? Math.round(n) : n.toFixed(2)}` : `${Math.round(n)}`;
    return t("spend.ofLimit", "{used} / {limit}", { used: fmt(w.used), limit: fmt(w.limit) });
  }
  function paceText(p, now) {
    if (!p)
      return null;
    if (p.runsOutAt !== null)
      return t("pace.runsOut", "runs out in {duration}", { duration: durationText(Math.max(0, p.runsOutAt - now)) });
    if (p.stage === "over")
      return t("pace.over", "{delta}% ahead of pace", { delta: Math.round(p.deltaPercent) });
    return null;
  }
  var isStale = (a, now, staleMs) => a.stale || a.fetchedAt !== null && now - a.fetchedAt > staleMs;
  function staleText(a, now) {
    return a.fetchedAt === null ? t("stale", "Stale") : t("stale.ago", "Stale · updated {duration} ago", { duration: durationText(Math.max(0, now - a.fetchedAt)) });
  }
  function nextTextChange(now, input) {
    let next = Infinity;
    for (const target of input.countdownsTo) {
      const left = target - now;
      if (left <= 0)
        continue;
      const unit = unitFor(left);
      const step = left % unit || unit;
      next = Math.min(next, now + step);
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
  var KINDS = ["session", "weekly", "monthly", "daily", "budget", "credits", "other"];
  var UNITS = ["usd", "tokens", "requests", "credits"];
  var obj = (v) => v && typeof v === "object" && !Array.isArray(v) ? v : {};
  var str = (v) => typeof v === "string" && v.length > 0 ? v : null;
  var num = (v) => {
    const n = typeof v === "string" && v.trim() !== "" ? Number(v) : v;
    return typeof n === "number" && Number.isFinite(n) ? n : null;
  };
  function percentOf(w) {
    if (w.usedPercent !== null)
      return Math.max(0, w.usedPercent);
    if (w.used !== null && w.limit !== null && w.limit > 0)
      return Math.max(0, w.used / w.limit * 100);
    return null;
  }
  function normalizeWindow(raw, index) {
    const r = obj(raw);
    const kind = KINDS.includes(r.kind) ? r.kind : "other";
    const unit = UNITS.includes(r.unit) ? r.unit : null;
    return {
      id: str(r.id) ?? `${kind}-${index}`,
      kind,
      label: str(r.label),
      scope: str(r.scope),
      usedPercent: num(r.used_percent),
      used: num(r.used),
      limit: num(r.limit),
      unit,
      windowSeconds: num(r.window_seconds),
      resetsAt: num(r.resets_at_ms)
    };
  }
  function normalizeError(raw) {
    if (!raw)
      return null;
    const r = obj(raw);
    return { code: str(r.code) ?? "usage.failed", message: str(r.message) ?? "", retryable: r.retryable === true };
  }
  var KIND_ORDER = { session: 0, daily: 1, weekly: 2, monthly: 3, budget: 4, credits: 5, other: 6 };
  function sortWindows(windows) {
    return [...windows].sort((a, b) => KIND_ORDER[a.kind] - KIND_ORDER[b.kind] || Number(a.scope !== null) - Number(b.scope !== null));
  }
  function normalizeAccount(raw, fallbackKind = "plan") {
    const r = obj(raw);
    const id = str(r.id);
    const provider = str(r.provider);
    if (!id || !provider)
      return null;
    const kind = r.kind === "plan" || r.kind === "api" || r.kind === "pool" ? r.kind : fallbackKind;
    const windows = Array.isArray(r.windows) ? r.windows.map(normalizeWindow) : [];
    return {
      id,
      provider,
      providerTitle: str(r.provider_title) ?? provider,
      kind,
      upstream: str(r.upstream),
      label: str(r.label),
      plan: str(r.plan),
      windows: sortWindows(windows),
      source: str(r.source),
      fetchedAt: num(r.fetched_at_ms),
      stale: r.stale === true,
      error: normalizeError(r.error)
    };
  }
  function normalizeUsage(value) {
    const list = obj(value).accounts;
    return Array.isArray(list) ? list.map((a) => normalizeAccount(a)).filter((a) => a !== null) : [];
  }
  function normalizePools(value, poolWord) {
    const pools = obj(value).pools;
    if (!Array.isArray(pools))
      return [];
    const out = [];
    for (const p of pools) {
      const pool = obj(p);
      const name = str(pool.name) ?? str(pool.id) ?? poolWord;
      for (const raw of Array.isArray(pool.accounts) ? pool.accounts : []) {
        const r = obj(raw);
        const a = normalizeAccount({ ...r, provider: "coderouter", upstream: str(r.provider), kind: "pool" }, "pool");
        if (a)
          out.push({ ...a, id: `${str(pool.id) ?? name}/${a.id}`, providerTitle: "CodeRouter", label: [name, a.label].filter(Boolean).join(" · ") });
      }
    }
    return out;
  }
  function severityOf(percent, thresholds) {
    if (percent === null || thresholds.length === 0)
      return "normal";
    const sorted = [...thresholds].sort((a, b) => a - b);
    if (percent >= sorted[sorted.length - 1])
      return "danger";
    if (percent >= sorted[0])
      return "warning";
    return "normal";
  }
  function tightest(accounts) {
    let best = null;
    for (const account of accounts) {
      if (account.error)
        continue;
      for (const window of account.windows) {
        const percent = percentOf(window);
        if (percent === null)
          continue;
        const earlier = best && percent === best.percent && (window.resetsAt ?? Infinity) < (best.window.resetsAt ?? Infinity);
        if (!best || percent > best.percent || earlier)
          best = { account, window, percent };
      }
    }
    return best;
  }
  function sessionAndWeek(account) {
    const main = account.windows.filter((w) => w.scope === null);
    return { session: main.find((w) => w.kind === "session") ?? null, week: main.find((w) => w.kind === "weekly") ?? null };
  }
  var MIN_ELAPSED_SHARE = 0.05;
  var ON_TRACK_POINTS = 5;
  function paceOf(window, now) {
    const used = percentOf(window);
    if (used === null || window.windowSeconds === null || window.resetsAt === null)
      return null;
    const length = window.windowSeconds * 1000;
    const left = window.resetsAt - now;
    if (length <= 0 || left <= 0 || left > length)
      return null;
    const elapsed = length - left;
    const expected = elapsed / length * 100;
    const delta = used - expected;
    const stage = Math.abs(delta) <= ON_TRACK_POINTS ? "onTrack" : delta > 0 ? "over" : "under";
    let runsOutAt = null;
    let lastsToReset = true;
    if (used >= 100) {
      runsOutAt = now;
      lastsToReset = false;
    } else if (used > 0 && elapsed >= length * MIN_ELAPSED_SHARE) {
      const msToLimit = (100 - used) / used * elapsed;
      if (msToLimit < left) {
        runsOutAt = now + msToLimit;
        lastsToReset = false;
      }
    }
    return { expectedPercent: expected, deltaPercent: delta, runsOutAt, lastsToReset, stage };
  }
  var round1 = (n) => Math.round(n * 10) / 10;
  function statusJSON(accounts, options) {
    const { now } = options;
    const list = options.provider ? accounts.filter((a) => a.provider === options.provider) : accounts;
    const top = tightest(list);
    return {
      generated_at_ms: now,
      state: options.state,
      problem: options.problem,
      tightest: top ? { account: top.account.id, provider: top.account.provider, window: top.window.id, used_percent: round1(top.percent), resets_at_ms: top.window.resetsAt } : null,
      accounts: list.map((a) => ({
        id: a.id,
        provider: a.provider,
        provider_title: a.providerTitle,
        kind: a.kind,
        upstream: a.upstream,
        label: a.label,
        plan: a.plan,
        source: a.source,
        fetched_at_ms: a.fetchedAt,
        stale: isStale(a, now, options.staleMs),
        error: a.error,
        windows: a.windows.map((w) => {
          const percent = percentOf(w);
          const pace = paceOf(w, now);
          return {
            id: w.id,
            kind: w.kind,
            scope: w.scope,
            used_percent: percent === null ? null : round1(percent),
            used: w.used,
            limit: w.limit,
            unit: w.unit,
            window_seconds: w.windowSeconds,
            resets_at_ms: w.resetsAt,
            resets_in_seconds: w.resetsAt === null ? null : Math.max(0, Math.round((w.resetsAt - now) / 1000)),
            severity: severityOf(percent, options.thresholds),
            pace: pace ? { expected_percent: round1(pace.expectedPercent), delta_percent: round1(pace.deltaPercent), runs_out_at_ms: pace.runsOutAt === null ? null : Math.round(pace.runsOutAt), lasts_to_reset: pace.lastsToReset } : null
          };
        })
      }))
    };
  }
  var DEFAULT_THRESHOLDS = [80, 95];
  var alertKey = (account, window) => `${account.id}|${window.id}`;
  function cleanThresholds(raw) {
    const list = Array.isArray(raw) ? raw : DEFAULT_THRESHOLDS;
    const nums = list.map(Number).filter((n) => Number.isInteger(n) && n >= 1 && n <= 100);
    return [...new Set(nums)].sort((a, b) => a - b);
  }
  function planAlerts(accounts, thresholds, fired, now, staleMs) {
    const next = {};
    const alerts = [];
    const lowest = thresholds[0];
    const live = new Set;
    for (const account of accounts) {
      const unusable = account.error !== null || account.stale || account.fetchedAt !== null && now - account.fetchedAt > staleMs;
      for (const window of account.windows) {
        const key = alertKey(account, window);
        live.add(key);
        const previous = fired[key];
        if (unusable) {
          if (previous)
            next[key] = previous;
          continue;
        }
        const percent = percentOf(window);
        const rearm = !previous || previous.resetsAt !== null && previous.resetsAt <= now || percent !== null && lowest !== undefined && percent < lowest;
        const already = rearm ? 0 : previous.level;
        const crossed = percent === null ? 0 : Math.max(0, ...thresholds.filter((th) => percent >= th));
        if (crossed > already) {
          alerts.push({ key, level: crossed, top: crossed === thresholds[thresholds.length - 1], percent, account, window });
          next[key] = { level: crossed, resetsAt: window.resetsAt };
        } else if (already > 0) {
          next[key] = { level: already, resetsAt: window.resetsAt ?? previous.resetsAt };
        }
      }
    }
    for (const [key, entry] of Object.entries(fired)) {
      if (!live.has(key) && entry.resetsAt !== null && entry.resetsAt > now)
        next[key] = entry;
    }
    return { alerts, fired: next };
  }
  function alertMessage(alert, now) {
    const { account, window } = alert;
    const title = t("alert.title", "{provider} {window} limit at {percent}", {
      provider: account.providerTitle,
      window: windowLabel(window),
      percent: percentText(alert.percent)
    });
    const reset = resetText(window, now) ?? "";
    const pace = paceText(paceOf(window, now), now);
    const capitalized = reset.charAt(0).toUpperCase() + reset.slice(1);
    const body = !reset ? pace ?? "" : pace ? t("alert.body", "{reset}. At this pace it {pace}.", { reset: capitalized, pace }) : t("alert.bodyNoPace", "{reset}.", { reset: capitalized });
    return { title, body, level: alert.top ? "error" : "warning" };
  }
  async function notifyAlerts(alerts, now) {
    for (const alert of alerts) {
      const m = alertMessage(alert, now);
      const subtitle = alert.account.label ?? alert.account.plan ?? undefined;
      try {
        await cmux.notification.create({ title: m.title, subtitle, body: m.body, level: m.level });
      } catch (e) {
        cmux.log("usage warning not sent:", String(e));
      }
    }
  }
  var USAGE_GET = "usage.get";
  var POOLS_GET = "coderouter.usage.get";
  var [accounts, setAccounts] = signal([]);
  var [pools, setPools] = signal([]);
  var [state, setState] = signal("loading");
  var [problem, setProblem] = signal(null);
  var [now, setNow] = signal(Date.now());
  var allAccounts = () => [...accounts(), ...pools()];
  var settings = () => cmux.app.settings();
  var thresholds = () => cleanThresholds(settings().warnAt);
  var staleMs = () => Math.max(1, Number(settings().staleMinutes ?? 30)) * 60000;
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
    const [usage, pool] = await Promise.allSettled([cmux.call(USAGE_GET, {}), cmux.call(POOLS_GET, {})]);
    setNow(Date.now());
    setPools(pool.status === "fulfilled" ? normalizePools(pool.value, t("pool", "pool")) : []);
    if (usage.status === "fulfilled") {
      setAccounts(normalizeUsage(usage.value));
      setProblem(null);
      setState("ready");
      queueAlerts();
    } else {
      const e = usage.reason;
      const code = e?.code ?? "operation.failed";
      setProblem({ code, message: e?.message ?? String(usage.reason), scope: e?.details?.scope });
      setState(code === "operation.unsupported" ? "unavailable" : code === "scope.missing" ? "denied" : accounts().length ? "ready" : "error");
      if (code !== "operation.unsupported" && code !== "scope.missing")
        cmux.log("usage read failed:", code);
    }
  }
  var clockTimer = null;
  var armQueued = false;
  function clockTargets(at) {
    const countdownsTo = [];
    const agesFrom = [];
    const staleAt = [];
    for (const a of allAccounts()) {
      if (a.fetchedAt !== null) {
        if (isStale(a, at, staleMs()))
          agesFrom.push(a.fetchedAt);
        else
          staleAt.push(a.fetchedAt + staleMs());
      }
      for (const w of a.windows) {
        if (w.resetsAt !== null)
          countdownsTo.push(w.resetsAt);
        const pace = paceOf(w, at);
        if (pace?.runsOutAt)
          countdownsTo.push(pace.runsOutAt);
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
    cmux.events.on("usage.changed", () => void load(), { demand });
    cmux.events.on("coderouter.usage.changed", () => void load(), { demand });
    effect(() => {
      now();
      allAccounts();
      staleMs();
      requestClock();
    });
    if (state() === "loading" && !inFlight)
      load();
  }
  async function refreshNow(params = {}) {
    let requested = true;
    try {
      await cmux.call("usage.refresh", params);
    } catch {
      requested = false;
    }
    await load();
    return { requested };
  }
  var ALERTS_KEY = "alerts.v1";
  var alertChain = Promise.resolve();
  var fired = null;
  function queueAlerts() {
    if (settings().notifications === false)
      return;
    const snapshot = allAccounts();
    alertChain = alertChain.then(async () => {
      fired ??= await cmux.storage.get(ALERTS_KEY).catch(() => null) ?? {};
      const plan = planAlerts(snapshot, thresholds(), fired, Date.now(), staleMs());
      fired = plan.fired;
      await cmux.storage.set(ALERTS_KEY, plan.fired).catch((e) => cmux.log("usage alerts not persisted:", String(e)));
      await notifyAlerts(plan.alerts, Date.now());
    }).catch((e) => cmux.log("usage alerts failed:", String(e)));
  }
  var VARIANTS = ["menuPercent", "menuMeters", "sidebarOnly"];
  var DEFAULT_VARIANT = "menuPercent";
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
  var toneOf = (s) => s === "danger" ? "danger" : s === "warning" ? "warning" : "secondary";
  var textTone = (s) => s === "normal" ? "primary" : toneOf(s);
  var severity = (w, _at) => severityOf(percentOf(w), thresholds());
  var accountStale = (a) => isStale(a, now(), staleMs());
  var accountTitle = (a) => [a.providerTitle, a.label, a.plan].filter(Boolean).join(" · ");
  var accountNote = (a) => a.error ? a.error.message : accountStale(a) ? staleText(a, now()) : "";
  function NoteLine(a, font) {
    const has = computed(() => accountNote(a()) !== "");
    return () => has() ? Text(() => accountNote(a())).font(font).color(() => a().error ? "warning" : "tertiary").lineLimit(2) : null;
  }
  function windowDetail(w, at) {
    const parts = [amountText(w), resetText(w, at), paceText(paceOf(w, at), at)].filter((p) => !!p);
    return parts.join(" · ");
  }
  var top = () => tightest(allAccounts());
  function Meter(window, width, height, withPace) {
    const used = () => {
      const w = window();
      const p = w ? percentOf(w) : null;
      return p === null ? 0 : Math.min(100, p) / 100;
    };
    const tick = () => {
      const w = window();
      if (!withPace || !w)
        return null;
      const p = paceOf(w, now());
      return p ? Math.min(1, Math.max(0, p.expectedPercent / 100)) : null;
    };
    const tone = () => {
      const w = window();
      return w ? toneOf(severity(w, now())) : "tertiary";
    };
    const seg = (fn) => () => ({ width: Math.max(0, Math.round(fn() * 10) / 10), height });
    const usable = width - 1;
    const u = () => used() * usable;
    const k = () => tick() === null ? null : tick() * usable;
    const fillBefore = () => k() === null ? u() : Math.min(u(), k());
    const trackBefore = () => k() === null ? 0 : Math.max(0, k() - u());
    const fillAfter = () => k() === null ? 0 : Math.max(0, u() - k());
    const tickW = () => k() === null ? 0 : 1;
    const rest = () => width - fillBefore() - trackBefore() - tickW() - fillAfter();
    return HStack({ spacing: 0 }, [
      Rectangle().fill(tone).frame(seg(fillBefore)),
      Rectangle().fill("separator").frame(seg(trackBefore)),
      Rectangle().fill("primary").frame(seg(tickW)),
      Rectangle().fill(tone).frame(seg(fillAfter)),
      Rectangle().fill("separator").frame(seg(rest))
    ]).frame({ width, height }).cornerRadius(height / 2);
  }
  function menuItems(actions) {
    const at = now();
    const items = [];
    const accounts = allAccounts();
    if (state() !== "ready" || accounts.length === 0)
      items.push(Button(problemTitle()).disabled());
    for (const a of accounts) {
      if (items.length)
        items.push(Divider());
      items.push(Button(accountStale(a) ? `${accountTitle(a)} · ${staleText(a, at)}` : accountTitle(a)).disabled());
      if (a.error)
        items.push(Button(a.error.message).disabled());
      for (const w of a.windows) {
        const detail = windowDetail(w, at);
        items.push(Button(`${windowLabel(w)}  ${percentText(percentOf(w))}${detail ? `  ${detail}` : ""}`).disabled());
      }
    }
    items.push(Divider(), Button(t("menu.refresh", "Refresh Now"), actions.refresh), Button(t("menu.show", "Show Usage"), actions.show));
    return items;
  }
  function problemTitle() {
    switch (state()) {
      case "loading":
        return t("loading", "Loading…");
      case "unavailable":
        return t("unavailable.title", "Usage service not available");
      case "denied":
        return t("scope.title", "No permission to read usage");
      case "error":
        return t("error.title", "Cannot read usage");
      default:
        return allAccounts().length ? "" : t("empty.title", "No plans found");
    }
  }
  var problemSpec = computed(() => {
    const s = state();
    let spec = null;
    if (s === "loading")
      spec = { loading: true };
    else if (!(s === "ready" && allAccounts().length > 0)) {
      const p = problem();
      const message = s === "unavailable" ? t("unavailable.message", "This build has no usage service ({op}) yet.", { op: "usage.get" }) : s === "denied" ? t("scope.message", "Allow {scope} in Settings > Apps > Usage.", { scope: p?.scope ?? "usage:read" }) : s === "error" ? p?.message ?? "" : t("empty.message", "Sign in to Claude Code or Codex in a terminal and cmux shows their usage here.");
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
  var percentLabel = (w) => percentText(percentOf(w));
  var SYMBOLS = {
    session: "timer",
    daily: "sun.max",
    weekly: "calendar",
    monthly: "calendar",
    budget: "dollarsign.circle",
    credits: "creditcard",
    other: "gauge.with.dots.needle.50percent"
  };
  function statusHelp() {
    const tt = top();
    if (!tt)
      return t("menu.noData", "No usage data");
    return t("status.help", "{provider} · {window} · {percent}", { provider: accountTitle(tt.account), window: windowLabel(tt.window), percent: percentText(tt.percent) });
  }
  var topStale = () => {
    const tt = top();
    return tt ? accountStale(tt.account) : false;
  };
  function percentStatus(actions) {
    const tone = () => {
      const tt = top();
      return tt ? toneOf(severity(tt.window, now())) : "tertiary";
    };
    return HStack({ spacing: 3 }, [
      Icon(() => tone() === "danger" ? "gauge.with.needle.fill" : "gauge.with.needle").color(tone).size(11),
      Menu(() => top() ? percentText(top().percent) : "—", []).contextMenu(() => menuItems(actions))
    ]).opacity(() => topStale() || state() !== "ready" ? 0.55 : 1).help(statusHelp);
  }
  function windowRow(account, w) {
    return Row({
      title: () => windowLabel(w()),
      subtitle: () => windowDetail(w(), now()) || null,
      badge: () => percentLabel(w()),
      tint: () => accountStale(account()) ? "tertiary" : toneOf(severity(w(), now())),
      symbol: () => SYMBOLS[w().kind] ?? SYMBOLS.other
    });
  }
  function accountBlock(a) {
    return VStack({ spacing: 0 }, [
      VStack({ spacing: 1 }, [
        Text(() => accountTitle(a())).font("caption").secondary().lineLimit(1),
        NoteLine(a, "caption2")
      ]).padding({ top: 6, leading: 12, bottom: 2, trailing: 12 }),
      ForEach({ items: () => a().windows, key: (w) => w.id }, (w) => windowRow(a, w))
    ]).opacity(() => accountStale(a()) ? 0.7 : 1);
  }
  function percentDetail() {
    return VStack({ spacing: 2 }, [() => ProblemView(), ForEach({ items: allAccounts, key: (a) => a.id }, (a) => accountBlock(a))]);
  }
  var CARD_METER_WIDTH = 240;
  function metersStatus(actions) {
    const pair = () => {
      const tt = top();
      return tt ? sessionAndWeek(tt.account) : { session: null, week: null };
    };
    return VStack({ spacing: 2 }, [Meter(() => pair().session ?? top()?.window ?? null, 22, 4, false), Meter(() => pair().week, 22, 4, false)]).paddingVertical(3).paddingHorizontal(3).opacity(() => topStale() || state() !== "ready" ? 0.55 : 1).help(statusHelp).onTap(() => actions.show()).contextMenu(() => menuItems(actions));
  }
  function windowCard(account, w) {
    return VStack({ spacing: 3 }, [
      HStack({ spacing: 4 }, [
        Text(() => windowLabel(w())).font("caption"),
        Spacer(),
        Text(() => percentText(percentOf(w()))).font("caption").monospaced().weight("semibold").color(() => accountStale(account()) ? "tertiary" : textTone(severity(w(), now())))
      ]),
      Meter(w, CARD_METER_WIDTH, 5, true),
      Text(() => windowDetail(w(), now())).font("caption2").secondary().lineLimit(1)
    ]);
  }
  function accountCard(a) {
    return VStack({ spacing: 8 }, [
      VStack({ spacing: 1 }, [
        HStack({ spacing: 4 }, [
          Text(() => a().providerTitle).font("headline").lineLimit(1),
          Spacer(),
          Text(() => a().plan ?? "").font("caption").secondary().lineLimit(1)
        ]),
        Text(() => a().label ?? "").font("caption").secondary().lineLimit(1),
        NoteLine(a, "caption")
      ]),
      ForEach({ items: () => a().windows, key: (w) => w.id }, (w) => windowCard(a, w))
    ]).padding(10).background("hover").cornerRadius(8).opacity(() => accountStale(a()) ? 0.75 : 1);
  }
  function metersDetail() {
    return VStack({ spacing: 8 }, [() => ProblemView(), ForEach({ items: allAccounts, key: (a) => a.id }, (a) => accountCard(a))]).padding({ top: 4, leading: 12, bottom: 8, trailing: 12 });
  }
  var hot = computed(() => {
    const tt = top();
    if (!tt || accountStale(tt.account))
      return null;
    return severity(tt.window, now()) === "normal" ? null : JSON.stringify({ percent: tt.percent, tone: toneOf(severity(tt.window, now())) });
  });
  function quietStatus(actions) {
    return HStack({ spacing: 0 }, [
      () => {
        const h = hot();
        if (!h)
          return null;
        const { percent, tone } = JSON.parse(h);
        return HStack({ spacing: 3 }, [Icon("exclamationmark.triangle.fill").color(tone).size(11), Text(percentText(percent)).font("caption").monospaced().color(tone)]).help(statusHelp).onTap(() => actions.show()).contextMenu(() => menuItems(actions));
      }
    ]);
  }
  function shortTail(w, at) {
    const p = paceOf(w, at);
    if (p?.runsOutAt)
      return `↓ ${durationText(Math.max(0, p.runsOutAt - at))}`;
    if (w.resetsAt !== null)
      return durationText(Math.max(0, w.resetsAt - at));
    return "";
  }
  function windowLine(account, w) {
    return HStack({ spacing: 6 }, [
      Text(() => windowLabel(w())).font("caption").lineLimit(1).frame({ width: 72 }),
      ProgressView(() => Math.min(1, (percentOf(w()) ?? 0) / 100)).frame({ maxWidth: "infinity" }),
      Text(() => percentText(percentOf(w()))).font("caption").monospaced().color(() => accountStale(account()) ? "tertiary" : textTone(severity(w(), now()))).frame({ width: 34 }),
      Text(() => shortTail(w(), now())).font("caption2").color(() => paceOf(w(), now())?.runsOutAt ? "warning" : "secondary").lineLimit(1).frame({ width: 58 })
    ]).padding({ top: 1, leading: 12, bottom: 1, trailing: 12 }).help(() => windowDetail(w(), now()));
  }
  function accountLines(a) {
    return VStack({ spacing: 2 }, [
      VStack({ spacing: 1 }, [
        Text(() => accountTitle(a())).font("caption2").secondary().lineLimit(1),
        NoteLine(a, "caption2")
      ]).padding({ top: 6, leading: 12, bottom: 0, trailing: 12 }),
      ForEach({ items: () => a().windows, key: (w) => w.id }, (w) => windowLine(a, w))
    ]).opacity(() => accountStale(a()) ? 0.7 : 1);
  }
  function quietDetail() {
    return VStack({ spacing: 2 }, [() => ProblemView(), ForEach({ items: allAccounts, key: (a) => a.id }, (a) => accountLines(a))]).padding({ top: 0, leading: 0, bottom: 6, trailing: 0 });
  }
  var SECTION = "cmux/usage#usage";
  async function show() {
    try {
      await cmux.actions.run("sidebar.section.reveal", { contribution: SECTION });
      return { shown: true };
    } catch (e) {
      return { shown: false, reason: e.code ?? String(e) };
    }
  }
  async function refresh() {
    const r = await refreshNow();
    return { ...r, accounts: allAccounts().length };
  }
  var cycleVariant2 = () => cycleVariant();
  async function status(args = {}) {
    if (args.refresh)
      await refreshNow(args.provider ? { provider: args.provider } : {});
    else
      await load();
    return statusJSON(allAccounts(), { now: Date.now(), staleMs: staleMs(), thresholds: thresholds(), state: state(), problem: problem(), provider: args.provider });
  }
  var actions = { refresh: () => refresh(), show: () => show() };
  function renderStatus() {
    loadVariantOverride();
    attach("glance");
    return HStack({ spacing: 0 }, [
      () => {
        switch (variant()) {
          case "menuMeters":
            return metersStatus(actions);
          case "sidebarOnly":
            return quietStatus(actions);
          default:
            return percentStatus(actions);
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
          case "menuMeters":
            return metersDetail();
          case "sidebarOnly":
            return quietDetail();
          default:
            return percentDetail();
        }
      }
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
