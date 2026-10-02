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
    keepAwake: () => keepAwake,
    keepAwakeHour: () => keepAwakeHour,
    list: () => list,
    renderPane: () => renderPane,
    renderStatus: () => renderStatus,
    show: () => show,
    start: () => start,
    stop: () => stop,
    stopAll: () => stopAll2
  });
  // first-party-apps/caffeinate/strings/en.json
  var en_default = {
    "action.dismiss": "Dismiss",
    "action.start": "Keep Awake",
    "action.stop": "Stop",
    "action.stop.help": "Let the Mac sleep as usual again",
    "action.stopAll": "Stop All",
    "choice.custom": "Other",
    "choice.custom.help": "Set minutes (-t)",
    "choice.untilStopped": "Until stopped",
    "denied.message": "Allow {scope} in Settings > Apps > Caffeinate.",
    "denied.title": "No permission to keep the Mac awake",
    "detail.byAgent": "by an agent",
    "detail.byApp": "by {app}",
    "detail.inactive": "{kinds} paused on battery",
    "end.command": "Command ends",
    "end.process": "Process exits",
    "end.process.help": "Enter a process ID (-w)",
    "end.time": "Never",
    "error.longDuration": "Choose at most 24 hours, or Until Stopped.",
    "error.noDuration": "Enter a number of minutes.",
    "error.noHandle": "Choose the terminal whose command keeps the Mac awake.",
    "error.noKinds": "Choose at least one thing to keep awake.",
    "error.shortDuration": "Choose at least 1 minute.",
    "error.title": "Cannot read power assertions",
    "field.minutes": "Minutes",
    "field.pid": "Process ID",
    "glance.off": "Off",
    "glance.on": "On",
    "kind.disk": "Disks",
    "kind.disk.explain": "Disks do not sleep when idle.",
    "kind.display": "Display",
    "kind.display.explain": "The display stays on.",
    "kind.idle": "Mac",
    "kind.idle.explain": "The Mac does not sleep when idle. The display can still turn off.",
    "kind.system": "Mac on AC power",
    "kind.system.explain": "The Mac does not sleep at all while on power. On battery this does nothing.",
    "kind.user": "Wake display",
    "kind.user.explain": "Tells the Mac you are active: the display wakes. Lasts 5 seconds unless you set a time.",
    "list.separator": ", ",
    loading: "Loading…",
    "menu.commandSubmenu": "Keep Awake While a Command Runs",
    "menu.for": "For {duration}",
    "menu.forSubmenu": "Keep Awake For",
    "menu.header.off": "The Mac sleeps as usual",
    "menu.header.on": "Keeping the Mac awake ({n})",
    "menu.open": "Open Caffeinate",
    "menu.show": "Show Caffeinate",
    "menu.stop": "Stop: {title}",
    "menu.stopTimed": "Stop: {title} ({left} left)",
    "pane.off": "The Mac sleeps as usual",
    "pane.on": "Keeping the Mac awake",
    "pane.start": "Keep awake",
    "platform.message": "This computer cannot hold Mac power assertions.",
    "platform.title": "Only on a Mac",
    "policy.agentBound": "Agents can keep the Mac awake only while their own terminal's command runs.",
    "policy.agentMaxTime": "Agents can set at most 4 hours.",
    "policy.agentOwnTerminal": "Agents can bind only to their own terminal.",
    "policy.othersNeedUser": "Only you can stop what someone else started.",
    "preset.command.short": "While a command runs",
    "preset.hour": "Keep Awake for 1 Hour",
    "preset.hour.short": "For 1 hour",
    "preset.untilStopped": "Keep Awake Until Stopped",
    "preset.untilStopped.short": "Until I stop it",
    "reason.default": "cmux Caffeinate: {title}",
    "release.other": "Stopped: {title}",
    "release.owner": "Stopped because its app was turned off: {title}",
    "release.restart": "Stopped when cmux restarted: {title}",
    "release.timeout": "Time is up: {title}",
    "release.until": "Finished: {title}",
    "section.end": "End early when",
    "section.howLong": "For how long",
    "section.running": "Running",
    "section.what": "Keep awake",
    "status.help.off": "Caffeinate: the Mac sleeps as usual",
    "status.help.on": "Keeping the Mac awake",
    "terminal.label": "{program} · {title}",
    "terminals.denied": "Allow terminal:read to pick a terminal",
    "terminals.none": "No command is running",
    "terminals.refresh": "Refresh List",
    "terminals.unavailable": "Terminals are not available",
    "time.hours": "{h}h",
    "time.hoursMinutes": "{h}h {m}m",
    "time.left": "{time} left",
    "time.minutes": "{m}m",
    "time.seconds": "{s}s",
    "title.for": "For {duration}",
    "title.untilStopped": "Until stopped",
    "title.while": "While {what} runs",
    "unavailable.message": "This cmux build cannot hold power assertions yet ({op}).",
    "unavailable.title": "Keeping awake is not available",
    "until.pid": "process {pid}",
    "until.task": "the task",
    "until.terminal": "the command",
    "words.hour": "1 hour",
    "words.hours": "{h} hours",
    "words.hoursMinutes": "{hours} {minutes}",
    "words.minute": "1 minute",
    "words.minutes": "{m} minutes"
  };
  // first-party-apps/caffeinate/strings/ja.json
  var ja_default = {
    "action.dismiss": "閉じる",
    "action.start": "スリープさせない",
    "action.stop": "停止",
    "action.stop.help": "Mac をいつも通りスリープできるように戻します",
    "action.stopAll": "すべて停止",
    "choice.custom": "その他",
    "choice.custom.help": "分数を指定 (-t)",
    "choice.untilStopped": "止めるまで",
    "denied.message": "設定 > アプリ > カフェイネート で {scope} を許可してください。",
    "denied.title": "Mac のスリープを止める権限がありません",
    "detail.byAgent": "エージェントが開始",
    "detail.byApp": "{app} が開始",
    "detail.inactive": "{kinds} はバッテリー中は停止",
    "end.command": "コマンド終了",
    "end.process": "プロセス終了",
    "end.process.help": "プロセス ID を入力 (-w)",
    "end.time": "なし",
    "error.longDuration": "24時間以内を選ぶか、「止めるまで」を選んでください。",
    "error.noDuration": "分数を入力してください。",
    "error.noHandle": "コマンドが動いている間 Mac を起こしておくターミナルを選んでください。",
    "error.noKinds": "スリープさせないものを1つ以上選んでください。",
    "error.shortDuration": "1分以上を選んでください。",
    "error.title": "電源アサーションを読み込めません",
    "field.minutes": "分",
    "field.pid": "プロセス ID",
    "glance.off": "オフ",
    "glance.on": "オン",
    "kind.disk": "ディスク",
    "kind.disk.explain": "アイドル時もディスクをスリープさせません。",
    "kind.display": "ディスプレイ",
    "kind.display.explain": "ディスプレイをつけたままにします。",
    "kind.idle": "Mac",
    "kind.idle.explain": "アイドル時も Mac をスリープさせません。ディスプレイは消えることがあります。",
    "kind.system": "AC 電源時の Mac",
    "kind.system.explain": "電源接続中は Mac を一切スリープさせません。バッテリー中は効果がありません。",
    "kind.user": "ディスプレイを起こす",
    "kind.user.explain": "操作中であることを Mac に伝え、ディスプレイを起こします。時間を指定しなければ5秒で終わります。",
    "list.separator": "、",
    loading: "読み込み中…",
    "menu.commandSubmenu": "コマンドの実行中はスリープさせない",
    "menu.for": "{duration}",
    "menu.forSubmenu": "指定時間スリープさせない",
    "menu.header.off": "Mac はいつも通りスリープします",
    "menu.header.on": "Mac をスリープさせていません ({n})",
    "menu.open": "カフェイネートを開く",
    "menu.show": "カフェイネートを表示",
    "menu.stop": "停止: {title}",
    "menu.stopTimed": "停止: {title} (残り {left})",
    "pane.off": "Mac はいつも通りスリープします",
    "pane.on": "Mac をスリープさせていません",
    "pane.start": "スリープさせない",
    "platform.message": "このコンピュータは Mac の電源アサーションを保持できません。",
    "platform.title": "Mac 専用です",
    "policy.agentBound": "エージェントは自分のターミナルのコマンドが動いている間だけ Mac をスリープさせないようにできます。",
    "policy.agentMaxTime": "エージェントが指定できるのは最大4時間です。",
    "policy.agentOwnTerminal": "エージェントは自分のターミナルにだけ結びつけられます。",
    "policy.othersNeedUser": "他の人が開始したものを止められるのはあなただけです。",
    "preset.command.short": "コマンドの実行中",
    "preset.hour": "1時間スリープさせない",
    "preset.hour.short": "1時間",
    "preset.untilStopped": "止めるまでスリープさせない",
    "preset.untilStopped.short": "止めるまで",
    "reason.default": "cmux カフェイネート: {title}",
    "release.other": "停止しました: {title}",
    "release.owner": "アプリがオフになったため停止しました: {title}",
    "release.restart": "cmux の再起動で停止しました: {title}",
    "release.timeout": "時間になりました: {title}",
    "release.until": "終了しました: {title}",
    "section.end": "早めに終わる条件",
    "section.howLong": "期間",
    "section.running": "実行中",
    "section.what": "スリープさせないもの",
    "status.help.off": "カフェイネート: Mac はいつも通りスリープします",
    "status.help.on": "Mac をスリープさせていません",
    "terminal.label": "{program} · {title}",
    "terminals.denied": "ターミナルを選ぶには terminal:read を許可してください",
    "terminals.none": "実行中のコマンドはありません",
    "terminals.refresh": "一覧を更新",
    "terminals.unavailable": "ターミナルを利用できません",
    "time.hours": "{h}時間",
    "time.hoursMinutes": "{h}時間{m}分",
    "time.left": "残り {time}",
    "time.minutes": "{m}分",
    "time.seconds": "{s}秒",
    "title.for": "{duration}",
    "title.untilStopped": "止めるまで",
    "title.while": "{what} の実行中",
    "unavailable.message": "この cmux ビルドはまだ電源アサーションを保持できません ({op})。",
    "unavailable.title": "スリープの抑止は利用できません",
    "until.pid": "プロセス {pid}",
    "until.task": "タスク",
    "until.terminal": "コマンド",
    "words.hour": "1時間",
    "words.hours": "{h}時間",
    "words.hoursMinutes": "{hours}{minutes}",
    "words.minute": "1分",
    "words.minutes": "{m}分"
  };
  var tables = { en: en_default, ja: ja_default };
  var MISSING = "\x00";
  var language = null;
  function detect() {
    try {
      const host = cmux.app.locale;
      if (typeof host === "string" && host && host !== "en")
        return host;
    } catch {}
    try {
      return new Intl.DateTimeFormat().resolvedOptions().locale || "en";
    } catch {
      return "en";
    }
  }
  function setLanguage(tag) {
    const base = String(tag ?? "en").toLowerCase().split(/[-_]/)[0] ?? "en";
    language = tables[base] ? base : "en";
  }
  function currentLanguage() {
    if (language === null)
      setLanguage(detect());
    return language;
  }
  var fill = (template, vars) => template.replace(/\{(\w+)\}/g, (whole, name) => (name in vars) ? String(vars[name]) : whole);
  function t(key, english, vars = {}) {
    let hosted = null;
    try {
      const v = cmux.t(key, MISSING);
      if (v !== MISSING)
        hosted = v;
    } catch {}
    return fill(hosted ?? tables[currentLanguage()]?.[key] ?? english, vars);
  }
  var KINDS = ["display", "idle", "disk", "system", "user"];
  var FLAG = { display: "-d", idle: "-i", disk: "-m", system: "-s", user: "-u" };
  var USER_ACTIVITY_DEFAULT_S = 5;
  function kindTitle(kind) {
    switch (kind) {
      case "display":
        return t("kind.display", "Display");
      case "idle":
        return t("kind.idle", "Mac");
      case "disk":
        return t("kind.disk", "Disks");
      case "system":
        return t("kind.system", "Mac on AC power");
      case "user":
        return t("kind.user", "Wake display");
    }
  }
  function kindExplanation(kind) {
    switch (kind) {
      case "display":
        return t("kind.display.explain", "The display stays on.");
      case "idle":
        return t("kind.idle.explain", "The Mac does not sleep when idle. The display can still turn off.");
      case "disk":
        return t("kind.disk.explain", "Disks do not sleep when idle.");
      case "system":
        return t("kind.system.explain", "The Mac does not sleep at all while on power. On battery this does nothing.");
      case "user":
        return t("kind.user.explain", "Tells the Mac you are active: the display wakes. Lasts 5 seconds unless you set a time.");
    }
  }
  function kindsText(kinds) {
    return KINDS.filter((k) => kinds.includes(k)).map(kindTitle).join(t("list.separator", ", "));
  }
  function normalizeKinds(raw) {
    const list = Array.isArray(raw) ? raw : [];
    return KINDS.filter((k) => list.includes(k));
  }
  var SECOND = 1000;
  var MINUTE = 60 * SECOND;
  var HOUR = 60 * MINUTE;
  function timeLeftText(ms) {
    if (ms <= 0)
      return t("time.seconds", "{s}s", { s: 0 });
    if (ms <= MINUTE)
      return t("time.seconds", "{s}s", { s: Math.ceil(ms / SECOND) });
    const minutes = Math.ceil(ms / MINUTE);
    if (minutes < 60)
      return t("time.minutes", "{m}m", { m: minutes });
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    return m === 0 ? t("time.hours", "{h}h", { h }) : t("time.hoursMinutes", "{h}h {m}m", { h, m });
  }
  function nextChangeFor(end, now) {
    const ms = end - now;
    if (ms <= 0)
      return null;
    if (ms <= MINUTE) {
      const s = Math.ceil(ms / SECOND);
      return end - (s - 1) * SECOND;
    }
    const minutes = Math.ceil(ms / MINUTE);
    return end - (minutes - 1) * MINUTE;
  }
  function nextTextChange(ends, now) {
    let best = null;
    for (const end of ends) {
      const at = nextChangeFor(end, now);
      if (at !== null && (best === null || at < best))
        best = at;
    }
    return best;
  }
  function durationWords(totalMinutes) {
    const h = Math.floor(totalMinutes / 60);
    const m = totalMinutes % 60;
    if (h === 0)
      return m === 1 ? t("words.minute", "1 minute") : t("words.minutes", "{m} minutes", { m });
    const hours = h === 1 ? t("words.hour", "1 hour") : t("words.hours", "{h} hours", { h });
    if (m === 0)
      return hours;
    return t("words.hoursMinutes", "{hours} {minutes}", { hours, minutes: m === 1 ? t("words.minute", "1 minute") : t("words.minutes", "{m} minutes", { m }) });
  }
  function assertionTitle(a) {
    if (a.until) {
      const what = a.untilLabel ?? (a.until.pid ? t("until.pid", "process {pid}", { pid: a.until.pid }) : a.until.task ? t("until.task", "the task") : t("until.terminal", "the command"));
      return t("title.while", "While {what} runs", { what });
    }
    if (a.expiresAt !== null) {
      const minutes = Math.max(1, Math.round((a.expiresAt - a.createdAt) / MINUTE));
      return t("title.for", "For {duration}", { duration: durationWords(minutes) });
    }
    return t("title.untilStopped", "Until stopped");
  }
  function assertionDetail(a, now, withTime = true) {
    const parts = [kindsText(a.kinds)];
    if (withTime && a.expiresAt !== null)
      parts.push(t("time.left", "{time} left", { time: timeLeftText(a.expiresAt - now) }));
    if (a.inactive.length)
      parts.push(t("detail.inactive", "{kinds} paused on battery", { kinds: kindsText(a.inactive) }));
    if (a.owner.app && a.owner.app !== "cmux/caffeinate")
      parts.push(t("detail.byApp", "by {app}", { app: a.owner.app }));
    else if (a.owner.origin === "agent")
      parts.push(t("detail.byAgent", "by an agent"));
    return parts.join(" · ");
  }
  function releaseText(cause, title) {
    switch (cause) {
      case "timeout":
        return t("release.timeout", "Time is up: {title}", { title });
      case "until":
        return t("release.until", "Finished: {title}", { title });
      case "owner_disabled":
      case "owner_uninstalled":
        return t("release.owner", "Stopped because its app was turned off: {title}", { title });
      case "host_restart":
        return t("release.restart", "Stopped when cmux restarted: {title}", { title });
      default:
        return t("release.other", "Stopped: {title}", { title });
    }
  }
  var refuse = (message) => ({ code: "power.not_permitted", message });
  var AGENT_MAX_TIMEOUT_S = 4 * 3600;
  function checkCreate(invoker, params) {
    if (!invoker || invoker.origin === "user")
      return null;
    const until = params.until;
    if (!until || !("terminal" in until))
      return refuse(t("policy.agentBound", "Agents can keep the Mac awake only while their own terminal's command runs."));
    if (!invoker.terminal || until.terminal !== invoker.terminal)
      return refuse(t("policy.agentOwnTerminal", "Agents can bind only to their own terminal."));
    if (params.timeout_s !== undefined && params.timeout_s > AGENT_MAX_TIMEOUT_S)
      return refuse(t("policy.agentMaxTime", "Agents can set at most 4 hours."));
    return null;
  }
  function checkRelease(invoker, assertion) {
    if (!invoker || invoker.origin === "user")
      return null;
    if (assertion.owner.actor && assertion.owner.actor === invoker.actor)
      return null;
    return refuse(t("policy.othersNeedUser", "Only you can stop what someone else started."));
  }
  function invokerOf(ctx) {
    const inv = ctx?.invoker;
    if (!inv || typeof inv.actor !== "string")
      return null;
    const origin = inv.origin === "user" || inv.origin === "agent" ? inv.origin : "script";
    return { actor: inv.actor, origin, terminal: typeof inv.terminal === "string" ? inv.terminal : null };
  }
  var PRESETS = ["command", "untilStopped", "hour", "duration"];
  var isPreset = (v) => typeof v === "string" && PRESETS.includes(v);
  var DURATIONS = [15, 30, 60, 120, 240, 480];
  var MAX_MINUTES = 24 * 60;
  var DEFAULT_KINDS = {
    command: ["idle"],
    untilStopped: ["display", "idle"],
    hour: ["display", "idle"],
    duration: ["display", "idle"]
  };
  var fail = (code, message) => ({ ok: false, code, message });
  var handle = (v, prefix) => typeof v === "string" && v.startsWith(prefix) && v.length > prefix.length ? v : null;
  function minutesOf(v) {
    const n = typeof v === "string" && v.trim() ? Number(v.trim()) : v;
    return typeof n === "number" && Number.isFinite(n) ? Math.round(n) : null;
  }
  function presetRequest(preset, options = {}) {
    const kinds = options.kinds === undefined ? DEFAULT_KINDS[preset] : normalizeKinds(options.kinds);
    if (!kinds.length)
      return fail("caffeinate.no_kinds", t("error.noKinds", "Choose at least one thing to keep awake."));
    const params = { kinds, reason: "" };
    let title;
    switch (preset) {
      case "command": {
        const terminal = handle(options.terminal, "terminal_");
        const task = handle(options.task, "task_");
        const pid = minutesOf(options.pid);
        if (terminal)
          params.until = { terminal, end: "command" };
        else if (task)
          params.until = { task };
        else if (pid !== null && pid > 0)
          params.until = { pid };
        else
          return fail("caffeinate.no_handle", t("error.noHandle", "Choose the terminal whose command keeps the Mac awake."));
        if (typeof options.label === "string" && options.label)
          params.until_label = options.label;
        title = t("title.while", "While {what} runs", { what: params.until_label ?? ("pid" in params.until ? t("until.pid", "process {pid}", { pid: params.until.pid }) : t("until.terminal", "the command")) });
        const minutes = minutesOf(options.minutes);
        if (minutes !== null) {
          const err = checkMinutes(minutes);
          if (err)
            return err;
          params.timeout_s = minutes * 60;
        }
        break;
      }
      case "untilStopped":
        title = t("title.untilStopped", "Until stopped");
        break;
      case "hour":
        params.timeout_s = 3600;
        title = t("title.for", "For {duration}", { duration: durationWords(60) });
        break;
      case "duration": {
        const minutes = minutesOf(options.minutes);
        if (minutes === null)
          return fail("caffeinate.no_duration", t("error.noDuration", "Enter a number of minutes."));
        const err = checkMinutes(minutes);
        if (err)
          return err;
        params.timeout_s = minutes * 60;
        title = t("title.for", "For {duration}", { duration: durationWords(minutes) });
        break;
      }
    }
    if (params.timeout_s === undefined && !params.until && kinds.length === 1 && kinds[0] === "user")
      params.timeout_s = USER_ACTIVITY_DEFAULT_S;
    params.reason = typeof options.reason === "string" && options.reason.trim() ? options.reason.trim().slice(0, 120) : t("reason.default", "cmux Caffeinate: {title}", { title });
    return { ok: true, params };
  }
  function checkMinutes(minutes) {
    if (minutes < 1)
      return fail("caffeinate.bad_duration", t("error.shortDuration", "Choose at least 1 minute."));
    if (minutes > MAX_MINUTES)
      return fail("caffeinate.bad_duration", t("error.longDuration", "Choose at most 24 hours, or Until Stopped."));
    return null;
  }
  var emptyState = () => ({ revision: -1n, available: true, unavailableReason: null, powerSource: "unknown", assertions: [], lastRelease: null });
  var time = (v) => {
    if (typeof v === "number" && Number.isFinite(v))
      return v;
    if (typeof v === "string" && v) {
      const n = /^\d+$/.test(v) ? Number(v) : Date.parse(v);
      return Number.isFinite(n) ? n : null;
    }
    return null;
  };
  var revisionOf = (v) => {
    if (typeof v === "string" && /^\d+$/.test(v))
      return BigInt(v);
    if (typeof v === "number" && Number.isInteger(v) && v >= 0)
      return BigInt(v);
    return null;
  };
  function normalizeUntil(raw) {
    if (!raw || typeof raw !== "object")
      return null;
    const r = raw;
    const out = {};
    if (typeof r.terminal === "string")
      out.terminal = r.terminal;
    if (typeof r.task === "string")
      out.task = r.task;
    if (typeof r.pid === "number" && Number.isInteger(r.pid) && r.pid > 0)
      out.pid = r.pid;
    if (r.end === "command" || r.end === "close")
      out.end = r.end;
    return out.terminal || out.task || out.pid ? out : null;
  }
  var ORIGINS = ["user", "script", "agent"];
  function normalizeAssertion(raw) {
    if (!raw || typeof raw !== "object")
      return null;
    const r = raw;
    const id = typeof r.assertion === "string" ? r.assertion : typeof r.id === "string" ? r.id : null;
    if (!id)
      return null;
    const kinds = normalizeKinds(r.kinds);
    if (!kinds.length)
      return null;
    const owner = r.owner ?? {};
    return {
      id,
      kinds,
      reason: typeof r.reason === "string" ? r.reason : "",
      createdAt: time(r.created_at) ?? 0,
      expiresAt: time(r.expires_at),
      until: normalizeUntil(r.until),
      untilLabel: typeof r.until_label === "string" && r.until_label ? r.until_label : null,
      owner: {
        actor: typeof owner.actor === "string" ? owner.actor : "",
        origin: ORIGINS.includes(owner.origin) ? owner.origin : "script",
        app: typeof owner.app === "string" ? owner.app : null
      },
      inactive: normalizeKinds(r.inactive_kinds)
    };
  }
  var sortAssertions = (list) => list.slice().sort((a, b) => (a.expiresAt ?? Infinity) - (b.expiresAt ?? Infinity) || b.createdAt - a.createdAt || a.id.localeCompare(b.id));
  var POWER_SOURCES = ["ac", "battery", "unknown"];
  function fromList(raw, previous = emptyState()) {
    const r = raw ?? {};
    const list = Array.isArray(r.assertions) ? r.assertions : [];
    return {
      revision: revisionOf(r.revision) ?? previous.revision,
      available: r.available !== false,
      unavailableReason: r.available === false && typeof r.unavailable_reason === "string" ? r.unavailable_reason : null,
      powerSource: POWER_SOURCES.includes(r.power_source) ? r.power_source : "unknown",
      assertions: sortAssertions(list.map(normalizeAssertion).filter((a) => a !== null)),
      lastRelease: previous.lastRelease
    };
  }
  function applyEvent(state, raw, title = (a) => a.id) {
    if (!raw || typeof raw !== "object")
      return state;
    const e = raw;
    const revision = revisionOf(e.revision);
    if (revision === null || revision <= state.revision)
      return state;
    switch (e.type) {
      case "reset":
        return { ...fromList(e, state), revision };
      case "created":
      case "updated": {
        const a = normalizeAssertion(e.assertion);
        if (!a)
          return { ...state, revision };
        return { ...state, revision, assertions: sortAssertions([...state.assertions.filter((x) => x.id !== a.id), a]) };
      }
      case "released": {
        const id = typeof e.assertion === "string" ? e.assertion : null;
        const gone = state.assertions.find((x) => x.id === id);
        const cause = typeof e.cause === "string" ? e.cause : "user";
        return {
          ...state,
          revision,
          assertions: state.assertions.filter((x) => x.id !== id),
          lastRelease: gone && cause !== "user" ? { id: gone.id, cause, title: title(gone) } : state.lastRelease
        };
      }
      case "power":
        return {
          ...state,
          revision,
          powerSource: POWER_SOURCES.includes(e.power_source) ? e.power_source : state.powerSource,
          available: typeof e.available === "boolean" ? e.available : state.available,
          assertions: Array.isArray(e.inactive) ? state.assertions.map((a) => ({ ...a, inactive: normalizeKinds(e.inactive.find((x) => x?.assertion === a.id)?.kinds) })) : state.assertions
        };
      default:
        return { ...state, revision };
    }
  }
  var running = (state, now) => state.assertions.filter((a) => a.expiresAt === null || a.expiresAt > now);
  var soonestEnd = (list) => list.reduce((m, a) => a.expiresAt === null ? m : m === null ? a.expiresAt : Math.min(m, a.expiresAt), null);
  var LIST = "power.assertion.list";
  var CREATE = "power.assertion.create";
  var RELEASE = "power.assertion.release";
  var WATCH = "power.assertion.watch";
  var [power, setPower] = signal(emptyState());
  var [status, setStatus] = signal("loading");
  var [problem, setProblem] = signal(null);
  var [now, setNow] = signal(Date.now());
  var [actionError, setActionError] = signal(null);
  var active = computed(() => running(power(), now()));
  var errorOf = (err) => {
    const e = err;
    return { code: e?.code ?? "operation.failed", message: e?.message ?? String(err), scope: e?.details?.scope };
  };
  var inFlight = null;
  var again = false;
  function load() {
    if (inFlight) {
      again = true;
      return inFlight;
    }
    inFlight = readList().finally(() => {
      inFlight = null;
      if (again) {
        again = false;
        load();
      }
    });
    return inFlight;
  }
  async function readList() {
    try {
      const raw = await cmux.call(LIST, {});
      const next = fromList(raw, power());
      if (next.revision >= power().revision)
        setPower(next);
      setProblem(next.available ? null : { code: next.unavailableReason ?? "power.unavailable", message: "" });
      setStatus(next.available ? "ready" : "unavailable");
    } catch (err) {
      const p = errorOf(err);
      setProblem(p);
      setStatus(p.code === "operation.unsupported" ? "unavailable" : p.code === "scope.missing" ? "denied" : "error");
      if (p.code !== "operation.unsupported" && p.code !== "scope.missing")
        cmux.log("power list failed:", p.code);
    }
    setNow(Date.now());
  }
  function onWatch(event) {
    const before = power();
    const after = applyEvent(before, event, assertionTitle);
    if (after === before)
      return;
    setPower(after);
    setNow(Date.now());
    if (status() !== "ready" && after.available) {
      setStatus("ready");
      setProblem(null);
    }
  }
  var clockTimer = null;
  var armQueued = false;
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
      const ends = power().assertions.flatMap((a) => a.expiresAt === null ? [] : [a.expiresAt]);
      const next = nextTextChange(ends, at);
      if (next === null)
        return;
      clockTimer = cmux.timer.after(Math.max(0, next - at) + 5, () => {
        clockTimer = null;
        setNow(Date.now());
      });
    });
  }
  function attach() {
    setNow(Date.now());
    cmux.events.on(WATCH, onWatch);
    effect(() => {
      now();
      power();
      requestClock();
    });
    if (status() === "loading" && !inFlight)
      load();
  }
  async function create(params, options = {}) {
    setActionError(null);
    try {
      const r = await cmux.call(CREATE, params, { gesture: options.gesture ?? undefined, idempotencyKey: options.idempotencyKey });
      if (!power().assertions.some((a) => a.id === r?.assertion))
        await load();
      return { started: true, assertion: String(r?.assertion ?? ""), expires_at: r?.expires_at ?? null };
    } catch (err) {
      const p = errorOf(err);
      setActionError(p.message || p.code);
      if (p.code === "operation.unsupported" || p.code === "scope.missing")
        await load();
      return { started: false, code: p.code, message: p.message };
    }
  }
  async function release(id, options = {}) {
    setActionError(null);
    try {
      await cmux.call(RELEASE, { assertion: id }, { gesture: options.gesture ?? undefined, idempotencyKey: `release:${id}` });
      if (power().assertions.some((a) => a.id === id))
        await load();
      return { released: true };
    } catch (err) {
      const p = errorOf(err);
      if (p.code === "power.not_found") {
        await load();
        return { released: true };
      }
      setActionError(p.message || p.code);
      return { released: false, code: p.code };
    }
  }
  async function releaseAll(options = {}) {
    setActionError(null);
    try {
      const r = await cmux.call(RELEASE, { all: true }, { gesture: options.gesture ?? undefined });
      await load();
      return { released: Array.isArray(r?.released) ? r.released : [] };
    } catch (err) {
      const p = errorOf(err);
      setActionError(p.message || p.code);
      return { released: [], code: p.code };
    }
  }
  var dismissRelease = () => setPower({ ...power(), lastRelease: null });
  var SHELLS = new Set(["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "login"]);
  var base = (path) => path.split("/").pop().replace(/^-/, "");
  function busyLabel(foreground, title) {
    if (!foreground)
      return null;
    const program = base(foreground);
    if (!program || SHELLS.has(program))
      return null;
    const name = title.trim();
    return name && name !== program ? t("terminal.label", "{program} · {title}", { program, title: name.slice(0, 40) }) : program;
  }
  var [busy, setBusy] = signal([]);
  var [terminalsState, setTerminalsState] = signal("idle");
  var inFlight2 = null;
  function loadTerminals() {
    if (inFlight2)
      return inFlight2;
    setTerminalsState("loading");
    inFlight2 = read().finally(() => {
      inFlight2 = null;
    });
    return inFlight2;
  }
  async function read() {
    let list;
    try {
      list = await cmux.call("terminal.list", {});
    } catch (err) {
      const code = err?.code;
      setBusy([]);
      setTerminalsState(code === "scope.missing" ? "denied" : "unavailable");
      return;
    }
    const live = (Array.isArray(list) ? list : []).filter((x) => x && typeof x.id === "string" && x.running !== false);
    const rows = await Promise.all(live.map(async (term) => {
      try {
        const p = await cmux.call("terminal.process.get", { terminal: term.id });
        const label = busyLabel(p?.foreground_executable, String(term.title ?? ""));
        return label ? { terminal: term.id, label } : null;
      } catch {
        return null;
      }
    }));
    setBusy(rows.filter((r) => r !== null));
    setTerminalsState("ready");
  }
  var loadedOnce = false;
  function ensureTerminals() {
    if (loadedOnce)
      return;
    loadedOnce = true;
    loadTerminals();
  }
  var VARIANTS = ["menu", "pane"];
  var DEFAULT_VARIANT = "menu";
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
      await cmux.app.settings.set({ variant: next });
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
  function startPreset(preset, options = {}) {
    const gesture = cmux.gesture();
    const r = presetRequest(preset, options);
    if (!r.ok) {
      setActionError(r.message);
      return;
    }
    create(r.params, { gesture });
  }
  function stopOne(id) {
    release(id, { gesture: cmux.gesture() });
  }
  function stopAll() {
    releaseAll({ gesture: cmux.gesture() });
  }
  var isOn = () => active().length > 0;
  var CUP = () => isOn() ? "cup.and.saucer.fill" : "cup.and.saucer";
  function soonestText() {
    const end = soonestEnd(active());
    return end === null ? null : timeLeftText(end - now());
  }
  var UNTIL_SYMBOL = (a) => a.until ? "terminal" : a.expiresAt !== null ? "timer" : "infinity";
  function activeRow(a) {
    return HStack({ spacing: 0 }, [
      Row({
        title: () => assertionTitle(a()),
        subtitle: () => assertionDetail(a(), now(), false),
        symbol: () => UNTIL_SYMBOL(a()),
        badge: () => a().expiresAt === null ? null : timeLeftText(a().expiresAt - now())
      }).layoutPriority(1),
      Button(t("action.stop", "Stop"), () => stopOne(a().id)).font("callout").help(t("action.stop.help", "Let the Mac sleep as usual again")).padding({ trailing: 10 })
    ]).contextMenu(() => [Button(t("action.stop", "Stop"), () => stopOne(a().id))]);
  }
  function ActiveList() {
    return VStack({ spacing: 2 }, [ForEach({ items: active, key: (a) => a.id }, (a) => activeRow(a))]);
  }
  function NoticeLine() {
    return VStack({ spacing: 0 }, [
      () => {
        const r = power().lastRelease;
        if (!r)
          return null;
        return HStack({ spacing: 6 }, [
          Icon("checkmark.circle").size(11).color("secondary"),
          Text(releaseText(r.cause, r.title)).font("caption").secondary().lineLimit(2),
          Spacer(),
          Button(t("action.dismiss", "Dismiss"), dismissRelease).font("caption")
        ]).padding({ top: 4, leading: 14, bottom: 4, trailing: 12 });
      }
    ]);
  }
  function ErrorLine() {
    return VStack({ spacing: 0 }, [
      () => {
        const e = actionError();
        if (!e)
          return null;
        return HStack({ spacing: 6 }, [Icon("exclamationmark.triangle").size(11).color("warning"), Text(e).font("caption").color("warning").lineLimit(3)]).padding({ top: 4, leading: 14, bottom: 4, trailing: 12 });
      }
    ]);
  }
  function problemSpec() {
    const s = status();
    const p = problem();
    if (s === "ready" || s === "loading")
      return null;
    if (s === "denied")
      return { title: t("denied.title", "No permission to keep the Mac awake"), message: t("denied.message", "Allow {scope} in Settings > Apps > Caffeinate.", { scope: p?.scope ?? "power:write" }), symbol: "lock" };
    if (s === "unavailable") {
      if (p?.code === "power.unsupported_platform")
        return { title: t("platform.title", "Only on a Mac"), message: t("platform.message", "This computer cannot hold Mac power assertions."), symbol: "desktopcomputer" };
      return { title: t("unavailable.title", "Keeping awake is not available"), message: t("unavailable.message", "This cmux build cannot hold power assertions yet ({op}).", { op: "power.assertion.create" }), symbol: "cup.and.saucer" };
    }
    return { title: t("error.title", "Cannot read power assertions"), message: p?.message || p?.code || "", symbol: "exclamationmark.triangle" };
  }
  var specKey = computed(() => JSON.stringify(problemSpec()));
  function ProblemView() {
    return VStack({ spacing: 0 }, [
      () => {
        const spec = JSON.parse(specKey());
        return spec ? EmptyState(spec) : null;
      }
    ]);
  }
  var hasProblem = computed(() => problemSpec() !== null);
  function commandMenuItems() {
    const s = terminalsState();
    const items = [];
    if (s === "denied")
      items.push(Button(t("terminals.denied", "Allow terminal:read to pick a terminal")).disabled());
    else if (s === "unavailable")
      items.push(Button(t("terminals.unavailable", "Terminals are not available")).disabled());
    else if (s === "loading" && busy().length === 0)
      items.push(Button(t("loading", "Loading…")).disabled());
    else if (busy().length === 0)
      items.push(Button(t("terminals.none", "No command is running")).disabled());
    for (const b of busy())
      items.push(Button(b.label, () => startPreset("command", { terminal: b.terminal, label: b.label })));
    items.push(Divider(), Button(t("terminals.refresh", "Refresh List"), () => void loadTerminals()));
    return items;
  }
  var durationLabel = (minutes) => t("menu.for", "For {duration}", { duration: durationWords(minutes) });
  var glance = () => hasProblem() ? "—" : isOn() ? soonestText() ?? t("glance.on", "On") : t("glance.off", "Off");
  function menuItems(actions) {
    const items = [];
    const spec = problemSpec();
    const list = active();
    if (spec)
      items.push(Button(spec.title).disabled());
    else
      items.push(Button(list.length ? t("menu.header.on", "Keeping the Mac awake ({n})", { n: list.length }) : t("menu.header.off", "The Mac sleeps as usual")).disabled());
    items.push(Divider(), Button(t("preset.untilStopped", "Keep Awake Until Stopped"), () => startPreset("untilStopped")).disabled(!!spec), Button(t("preset.hour", "Keep Awake for 1 Hour"), () => startPreset("hour")).disabled(!!spec), Menu(t("menu.forSubmenu", "Keep Awake For"), DURATIONS.filter((m) => m !== 60).map((m) => Button(durationLabel(m), () => startPreset("duration", { minutes: m })))).disabled(!!spec), Menu(t("menu.commandSubmenu", "Keep Awake While a Command Runs"), commandMenuItems()).disabled(!!spec));
    if (list.length) {
      items.push(Divider());
      for (const a of list) {
        const left = a.expiresAt === null ? null : timeLeftText(a.expiresAt - now());
        const title = assertionTitle(a);
        items.push(Button(left ? t("menu.stopTimed", "Stop: {title} ({left} left)", { title, left }) : t("menu.stop", "Stop: {title}", { title }), () => stopOne(a.id)));
      }
      if (list.length > 1)
        items.push(Button(t("action.stopAll", "Stop All"), stopAll).destructive());
    }
    items.push(Divider(), Button(t("menu.show", "Show Caffeinate"), actions.show));
    return items;
  }
  function menuStatus(actions) {
    return HStack({ spacing: 3 }, [
      Icon(CUP).size(12).color(() => isOn() ? "accent" : "secondary"),
      Menu(glance, []).contextMenu(() => menuItems(actions))
    ]).help(() => isOn() ? t("status.help.on", "Keeping the Mac awake") : t("status.help.off", "Caffeinate: the Mac sleeps as usual"));
  }
  var [commandsOpen, setCommandsOpen] = signal(false);
  function presetRow(title, subtitle, symbol, run) {
    return Row({ title, subtitle, symbol }).cursor("pointer").onTap(run);
  }
  function commandRows() {
    return VStack({ spacing: 0 }, [
      () => {
        if (!commandsOpen())
          return null;
        const s = terminalsState();
        const rows = busy().map((b) => Row({ title: b.label, symbol: "terminal", accessory: "play.fill" }).cursor("pointer").onTap(() => startPreset("command", { terminal: b.terminal, label: b.label })));
        const empty = s === "denied" ? t("terminals.denied", "Allow terminal:read to pick a terminal") : s === "loading" ? t("loading", "Loading…") : t("terminals.none", "No command is running");
        return VStack({ spacing: 0 }, [
          ...rows.length ? rows : [Text(empty).font("caption").secondary().padding({ top: 2, leading: 34, bottom: 4, trailing: 12 })],
          HStack({ spacing: 0 }, [Spacer(), Button(t("terminals.refresh", "Refresh List"), () => void loadTerminals()).font("caption")]).padding({ trailing: 12, bottom: 4 })
        ]);
      }
    ]);
  }
  function startList() {
    return VStack({ spacing: 0 }, [
      Text(t("pane.start", "Keep awake")).font("caption").weight("semibold").secondary().padding({ top: 10, leading: 14, bottom: 4, trailing: 12 }),
      presetRow(t("preset.untilStopped.short", "Until I stop it"), kindsText(DEFAULT_KINDS.untilStopped), "infinity", () => startPreset("untilStopped")),
      presetRow(t("preset.hour.short", "For 1 hour"), kindsText(DEFAULT_KINDS.hour), "timer", () => startPreset("hour")),
      HStack({ spacing: 6 }, [
        ...DURATIONS.filter((m) => m !== 60).map((m) => Text(timeLeftText(m * 60000)).font("callout").paddingHorizontal(8).paddingVertical(3).background("hover").cornerRadius(6).cursor("pointer").help(durationLabel(m)).onTap(() => startPreset("duration", { minutes: m }))),
        Spacer()
      ]).padding({ top: 2, leading: 40, bottom: 6, trailing: 12 }),
      Row({ title: t("preset.command.short", "While a command runs"), subtitle: kindsText(DEFAULT_KINDS.command), symbol: "terminal", accessory: () => commandsOpen() ? "chevron.down" : "chevron.right" }).cursor("pointer").onTap(() => {
        const open = !commandsOpen();
        setCommandsOpen(open);
        if (open)
          loadTerminals();
      }),
      commandRows()
    ]);
  }
  function menuPane() {
    return VStack({ spacing: 0 }, [
      () => hasProblem() ? ProblemView() : VStack({ spacing: 0 }, [
        HStack({ spacing: 8 }, [
          Icon(CUP).size(16).color(() => isOn() ? "accent" : "secondary"),
          Text(() => isOn() ? t("pane.on", "Keeping the Mac awake") : t("pane.off", "The Mac sleeps as usual")).font("headline").lineLimit(2).layoutPriority(1),
          Spacer(),
          () => active().length > 1 ? Button(t("action.stopAll", "Stop All"), stopAll).font("callout") : null
        ]).padding({ top: 12, leading: 14, bottom: 6, trailing: 12 }),
        ActiveList(),
        NoticeLine(),
        ErrorLine(),
        Divider().padding({ top: 6, bottom: 2 }),
        startList()
      ])
    ]);
  }
  var [kinds, setKinds] = signal(["display", "idle"]);
  var [duration, setDuration] = signal(60);
  var [customMinutes, setCustomMinutes] = signal("");
  var [end, setEnd] = signal("time");
  var [terminal, setTerminal] = signal(null);
  var [pid, setPid] = signal("");
  var toggleKind = (k) => setKinds((list) => list.includes(k) ? list.filter((x) => x !== k) : KINDS.filter((x) => x === k || list.includes(x)));
  function choiceRequest() {
    const d = duration();
    const minutes = d === "custom" ? customMinutes() : d === "untilStopped" ? undefined : d;
    const options = { kinds: kinds() };
    if (end() === "command") {
      const term = terminal();
      const label = busy().find((b) => b.terminal === term)?.label;
      return { preset: "command", options: { ...options, terminal: term ?? undefined, label, minutes } };
    }
    if (end() === "process")
      return { preset: "command", options: { ...options, pid: pid(), minutes } };
    return d === "untilStopped" ? { preset: "untilStopped", options } : { preset: "duration", options: { ...options, minutes } };
  }
  var canStart = computed(() => {
    const c = choiceRequest();
    return presetRequest(c.preset, c.options).ok;
  });
  function header(text) {
    return Text(text).font("caption").weight("semibold").secondary().padding({ top: 12, leading: 14, bottom: 4, trailing: 12 });
  }
  function chip(label, selected, onTap, help) {
    const v = Text(label).font("callout").lineLimit(1).fixedSize("horizontal").paddingHorizontal(9).paddingVertical(3).background(() => selected() ? "selected" : null).hoverBackground("hover").borderColor("separator").borderWidth(1).cornerRadius(7).cursor("pointer").onTap(onTap);
    return help ? v.help(help) : v;
  }
  function kindOption(k) {
    const on = () => kinds().includes(k);
    return HStack({ spacing: 10 }, [
      Icon(() => on() ? "checkmark.circle.fill" : "circle").size(14).color(() => on() ? "accent" : "tertiary"),
      VStack({ spacing: 1 }, [Text(kindTitle(k)).font("body"), Text(kindExplanation(k)).font("caption").secondary().lineLimit(4)]).frame({ maxWidth: "infinity" }).layoutPriority(1),
      Text(FLAG[k]).font("caption").monospaced().color("tertiary")
    ]).padding({ top: 5, leading: 14, bottom: 5, trailing: 12 }).background(() => on() ? "selected" : null).hoverBackground("hover").cornerRadius(8).paddingHorizontal(6).cursor("pointer").onTap(() => toggleKind(k));
  }
  function durationChoices() {
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 6 }, [
        chip(t("choice.untilStopped", "Until stopped"), () => duration() === "untilStopped", () => setDuration("untilStopped")),
        chip(timeLeftText(15 * 60000), () => duration() === 15, () => setDuration(15)),
        chip(timeLeftText(60 * 60000), () => duration() === 60, () => setDuration(60)),
        chip(timeLeftText(120 * 60000), () => duration() === 120, () => setDuration(120)),
        chip(t("choice.custom", "Other"), () => duration() === "custom", () => setDuration("custom"), t("choice.custom.help", "Set minutes (-t)")),
        Spacer()
      ]),
      () => duration() === "custom" ? TextField(customMinutes, { placeholder: t("field.minutes", "Minutes"), onEdit: setCustomMinutes, onSubmit: setCustomMinutes }).frame({ maxWidth: 140 }) : null
    ]).padding({ leading: 14, trailing: 12, bottom: 2 });
  }
  function terminalChoices() {
    return VStack({ spacing: 0 }, [
      () => {
        const s = terminalsState();
        const list = busy();
        if (!list.length) {
          const text = s === "denied" ? t("terminals.denied", "Allow terminal:read to pick a terminal") : s === "loading" ? t("loading", "Loading…") : t("terminals.none", "No command is running");
          return Text(text).font("caption").secondary().padding({ top: 4, leading: 20, bottom: 2, trailing: 12 });
        }
        return VStack({ spacing: 0 }, list.map((b) => Row({ title: b.label, symbol: "terminal", selected: () => terminal() === b.terminal, accessory: () => terminal() === b.terminal ? "checkmark" : null }).cursor("pointer").onTap(() => setTerminal(b.terminal))));
      },
      HStack({ spacing: 0 }, [Spacer(), Button(t("terminals.refresh", "Refresh List"), () => void loadTerminals()).font("caption")]).padding({ trailing: 12, top: 2 })
    ]);
  }
  function endChoices() {
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 6 }, [
        chip(t("end.time", "Never"), () => end() === "time", () => setEnd("time")),
        chip(t("end.command", "Command ends"), () => end() === "command", () => {
          setEnd("command");
          loadTerminals();
        }),
        chip(t("end.process", "Process exits"), () => end() === "process", () => setEnd("process"), t("end.process.help", "Enter a process ID (-w)")),
        Spacer()
      ]).padding({ leading: 14, trailing: 12 }),
      () => end() === "command" ? terminalChoices() : null,
      () => end() === "process" ? TextField(pid, { placeholder: t("field.pid", "Process ID"), onEdit: setPid, onSubmit: setPid }).frame({ maxWidth: 160 }).padding({ leading: 14 }) : null
    ]);
  }
  function startButton() {
    return HStack({ spacing: 8 }, [
      Spacer(),
      Button(t("action.start", "Keep Awake"), () => {
        const c = choiceRequest();
        startPreset(c.preset, c.options);
      }).disabled(() => !canStart()).font("body")
    ]).padding({ top: 10, leading: 14, bottom: 4, trailing: 14 });
  }
  function paneStatus(actions) {
    return HStack({ spacing: 3 }, [
      Icon(CUP).size(12).color(() => isOn() ? "accent" : "secondary"),
      Text(() => isOn() ? soonestText() ?? "" : "").font("caption").monospaced()
    ]).cursor("pointer").help(() => isOn() ? t("status.help.on", "Keeping the Mac awake") : t("status.help.off", "Caffeinate: the Mac sleeps as usual")).onTap(actions.show).contextMenu(() => {
      const items = active().map((a) => {
        const left = a.expiresAt === null ? null : timeLeftText(a.expiresAt - now());
        const title = assertionTitle(a);
        return Button(left ? t("menu.stopTimed", "Stop: {title} ({left} left)", { title, left }) : t("menu.stop", "Stop: {title}", { title }), () => stopOne(a.id));
      });
      if (items.length > 1)
        items.push(Button(t("action.stopAll", "Stop All"), stopAll).destructive());
      if (!items.length)
        items.push(Button(t("preset.untilStopped", "Keep Awake Until Stopped"), () => startPreset("untilStopped")));
      items.push(Divider(), Button(t("menu.open", "Open Caffeinate"), actions.show));
      return items;
    });
  }
  function panePane() {
    return VStack({ spacing: 0 }, [
      () => hasProblem() ? ProblemView() : VStack({ spacing: 0 }, [
        header(t("section.what", "Keep awake")),
        VStack({ spacing: 2 }, KINDS.map(kindOption)),
        header(t("section.howLong", "For how long")),
        durationChoices(),
        header(t("section.end", "End early when")),
        endChoices(),
        startButton(),
        ErrorLine(),
        NoticeLine(),
        Divider().padding({ top: 8 }),
        header(t("section.running", "Running")),
        () => power().assertions.length === 0 || active().length === 0 ? Text(t("pane.off", "The Mac sleeps as usual")).font("caption").secondary().padding({ leading: 14, bottom: 10 }) : null,
        ActiveList(),
        () => active().length > 1 ? HStack({ spacing: 0 }, [Spacer(), Button(t("action.stopAll", "Stop All"), stopAll).font("callout")]).padding({ top: 4, trailing: 14, bottom: 8 }) : null
      ])
    ]);
  }
  var PANE = "cmux/caffeinate#caffeinatePane";
  async function show() {
    try {
      await cmux.actions.run("app.pane.open", { kind: PANE, gesture: cmux.gesture() ?? undefined });
      return { shown: true };
    } catch (e) {
      return { shown: false, reason: e.code ?? String(e) };
    }
  }
  var actions = { show: () => void show() };
  var presetOf = (args) => {
    if (isPreset(args.preset))
      return args.preset;
    if (args.terminal || args.task || args.pid)
      return "command";
    return args.minutes === undefined ? "untilStopped" : "duration";
  };
  async function start(args = {}, ctx) {
    const r = presetRequest(presetOf(args), args);
    if (!r.ok)
      return { started: false, code: r.code, message: r.message };
    const refusal = checkCreate(invokerOf(ctx), r.params);
    if (refusal)
      return { started: false, ...refusal };
    return create(r.params, { gesture: ctx?.gesture, idempotencyKey: typeof args.request_id === "string" ? `start:${args.request_id}` : undefined });
  }
  var keepAwake = (_args, ctx) => start({ preset: "untilStopped" }, ctx);
  var keepAwakeHour = (_args, ctx) => start({ preset: "hour" }, ctx);
  async function stop(args = {}, ctx) {
    if (typeof args.assertion !== "string")
      return { released: false, code: "caffeinate.no_assertion" };
    if (status() === "loading")
      await load();
    const target = power().assertions.find((a) => a.id === args.assertion);
    const refusal = target ? checkRelease(invokerOf(ctx), target) : null;
    if (refusal)
      return { released: false, ...refusal };
    return release(args.assertion, { gesture: ctx?.gesture });
  }
  var stopAll2 = (_args, ctx) => releaseAll({ gesture: ctx?.gesture });
  async function list() {
    await load();
    const at = Date.now();
    const s = power();
    return {
      available: status() === "ready",
      state: status(),
      power_source: s.powerSource,
      assertions: active().map((a) => ({
        assertion: a.id,
        title: assertionTitle(a),
        kinds: a.kinds,
        flags: a.kinds.map((k) => FLAG[k]).join(" "),
        expires_at: a.expiresAt === null ? null : new Date(a.expiresAt).toISOString(),
        time_left: a.expiresAt === null ? null : timeLeftText(a.expiresAt - at),
        until: a.until,
        until_label: a.untilLabel,
        owner: a.owner
      }))
    };
  }
  var cycleVariant2 = () => cycleVariant();
  function renderStatus() {
    loadVariantOverride();
    attach();
    return HStack({ spacing: 0 }, [
      () => {
        if (variant() === "pane")
          return paneStatus(actions);
        ensureTerminals();
        return menuStatus(actions);
      }
    ]);
  }
  function renderPane() {
    loadVariantOverride();
    attach();
    return VStack({ spacing: 0 }, [() => variant() === "pane" ? panePane() : menuPane()]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
