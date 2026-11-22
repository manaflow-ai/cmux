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
    checkForUpdates: () => checkForUpdates,
    cycleVariant: () => cycleVariant2,
    openAgents: () => openAgents,
    renderPane: () => renderPane,
    renderSection: () => renderSection
  });
  var PROVIDERS = [
    {
      id: "claude",
      name: "Claude Code",
      short: "Claude",
      binaries: ["claude"],
      hints: [
        { method: "native", command: "curl -fsSL https://claude.ai/install.sh | bash" },
        { method: "npm", command: "npm install -g @anthropic-ai/claude-code" }
      ],
      accountsProvider: "claude",
      signIn: "cli"
    },
    {
      id: "codex",
      name: "Codex",
      short: "Codex",
      binaries: ["codex"],
      hints: [
        { method: "npm", command: "npm install -g @openai/codex" },
        { method: "brew", command: "brew install --cask codex", platforms: ["darwin"] }
      ],
      accountsProvider: "codex",
      signIn: "cli"
    },
    {
      id: "opencode",
      name: "OpenCode",
      short: "OpenCode",
      binaries: ["opencode"],
      hints: [
        { method: "npm", command: "npm install -g opencode-ai" },
        { method: "brew", command: "brew install sst/tap/opencode", platforms: ["darwin"] }
      ],
      accountsProvider: null,
      signIn: "cli"
    },
    { id: "pi", name: "Pi", short: "Pi", binaries: ["pi"], hints: [{ method: "npm", command: "npm install -g @earendil-works/pi-coding-agent" }], accountsProvider: null, signIn: "cli" },
    { id: "chief", name: "Chief", short: "Chief", binaries: ["chief"], hints: [{ method: "cmux", command: "cmux" }], accountsProvider: null, signIn: "cmux" },
    {
      id: "gemini",
      name: "Gemini CLI",
      short: "Gemini",
      binaries: ["gemini"],
      hints: [
        { method: "npm", command: "npm install -g @google/gemini-cli" },
        { method: "brew", command: "brew install gemini-cli", platforms: ["darwin"] }
      ],
      accountsProvider: "gemini",
      signIn: "cli"
    },
    { id: "amp", name: "Amp", short: "Amp", binaries: ["amp"], hints: [{ method: "npm", command: "npm install -g @sourcegraph/amp" }], accountsProvider: null, signIn: "cli" },
    { id: "copilot", name: "Copilot CLI", short: "Copilot", binaries: ["copilot"], hints: [{ method: "npm", command: "npm install -g @github/copilot" }], accountsProvider: "copilot", signIn: "cli" },
    {
      id: "cursor",
      name: "Cursor Agent",
      short: "Cursor",
      binaries: ["cursor-agent"],
      hints: [{ method: "native", command: "curl https://cursor.com/install -fsS | bash" }],
      accountsProvider: null,
      signIn: "cli"
    }
  ];
  var BY_ID = new Map(PROVIDERS.map((p) => [p.id, p]));
  var providerFor = (id) => BY_ID.get(id) ?? null;
  function providerRank(id) {
    const i = PROVIDERS.findIndex((p) => p.id === id);
    return i < 0 ? PROVIDERS.length : i;
  }
  var signsInItself = (id) => (providerFor(id)?.signIn ?? "cli") === "cli";
  var displayName = (id, ownerName) => providerFor(id)?.name ?? ownerName ?? id;
  function hintsFor(id, platform) {
    return (providerFor(id)?.hints ?? []).filter((h) => !h.platforms || h.platforms.includes(platform));
  }
  var platformOf = (os) => String(os ?? "").toLowerCase().startsWith("linux") ? "linux" : "darwin";
  var MISSING = new Set(["operation.unsupported", "scope.missing"]);
  function toOpError(e, op) {
    const err = e;
    const code = typeof err?.code === "string" ? err.code : "internal";
    const message = typeof err?.message === "string" ? err.message : String(e);
    return { code, message, missing: MISSING.has(code), op };
  }
  async function call(name, params = {}, options = {}) {
    try {
      return { ok: true, value: await cmux.call(name, params, options) };
    } catch (e) {
      return { ok: false, error: toOpError(e, name) };
    }
  }
  function gesture() {
    const g = cmux.gesture;
    return typeof g === "function" ? g.call(cmux) : null;
  }
  var withGesture = (token) => token ? { gesture: token } : {};
  var PATTERN = /(?:^|[^0-9A-Za-z.])v?(\d+(?:\.\d+)+)(?:-([0-9A-Za-z.-]+))?/;
  function parseVersion(raw) {
    if (!raw)
      return null;
    const m = PATTERN.exec(` ${raw.trim()}`);
    if (!m)
      return null;
    const nums = m[1].split(".").map((s) => Number.parseInt(s, 10));
    if (nums.some((n) => !Number.isFinite(n)))
      return null;
    const pre = m[2] ? m[2].split(".").filter(Boolean) : [];
    return { nums, pre, text: m[2] ? `${m[1]}-${m[2]}` : m[1] };
  }
  function comparePre(a, b) {
    if (!a.length || !b.length)
      return a.length === b.length ? 0 : a.length ? -1 : 1;
    for (let i = 0;i < Math.max(a.length, b.length); i++) {
      const x = a[i], y = b[i];
      if (x === undefined)
        return -1;
      if (y === undefined)
        return 1;
      const nx = /^\d+$/.test(x), ny = /^\d+$/.test(y);
      if (nx && ny) {
        const d = Number(x) - Number(y);
        if (d)
          return Math.sign(d);
      } else if (nx !== ny)
        return nx ? -1 : 1;
      else if (x !== y)
        return x < y ? -1 : 1;
    }
    return 0;
  }
  function compareVersions(a, b) {
    const x = parseVersion(a), y = parseVersion(b);
    if (!x || !y)
      return null;
    for (let i = 0;i < Math.max(x.nums.length, y.nums.length); i++) {
      const d = (x.nums[i] ?? 0) - (y.nums[i] ?? 0);
      if (d)
        return d < 0 ? -1 : 1;
    }
    return comparePre(x.pre, y.pre);
  }
  function updateLevel(current, latest) {
    const c = compareVersions(current, latest);
    if (c === null)
      return "unknown";
    if (c === 0)
      return "none";
    if (c > 0)
      return "newer";
    const x = parseVersion(current), y = parseVersion(latest);
    if ((x.nums[0] ?? 0) !== (y.nums[0] ?? 0))
      return "major";
    if ((x.nums[1] ?? 0) !== (y.nums[1] ?? 0))
      return "minor";
    return "patch";
  }
  var shortVersion = (raw) => parseVersion(raw)?.text ?? (raw ?? "").trim();
  function statusOf(e) {
    if (!e.installed)
      return "missing";
    const level = updateLevel(e.version, e.latest?.version);
    if (level === "none")
      return "current";
    if (level === "newer")
      return "ahead";
    if (level === "unknown")
      return "unknown";
    return "update";
  }
  var levelOf = (e) => updateLevel(e.version, e.latest?.version);
  var LEVEL_ORDER = ["major", "minor", "patch"];
  function highestLevel(list) {
    let best = null;
    for (const e of list) {
      if (!e || statusOf(e) !== "update")
        continue;
      const l = levelOf(e);
      if (best === null || LEVEL_ORDER.indexOf(l) < LEVEL_ORDER.indexOf(best))
        best = l;
    }
    return best;
  }
  function sortEntries(list) {
    return [...list].sort((a, b) => {
      if (a.installed !== b.installed)
        return a.installed ? -1 : 1;
      const r = providerRank(a.cli) - providerRank(b.cli);
      return r || a.cli.localeCompare(b.cli);
    });
  }
  function withMissing(list) {
    const seen = new Set(list.map((e) => e.cli));
    const missing = PROVIDERS.filter((p) => !seen.has(p.id)).map((p) => ({ cli: p.id, installed: false, version: null, latest: null, install_method: null, updatable: false, accounts: [] }));
    return sortEntries([...list, ...missing]);
  }
  function needsSignIn(e) {
    if (!e.installed)
      return false;
    if (e.accounts.some((a) => a.status === "expired" || a.status === "missing"))
      return true;
    return e.accounts.length === 0 && signsInItself(e.cli) && providerFor(e.cli) !== null;
  }
  var showsAccounts = (e) => e.installed && (e.accounts.length > 0 || signsInItself(e.cli) && providerFor(e.cli) !== null);
  var EMAIL = /[^\s@]+@[^\s@]+\.[^\s@]+/g;
  var TOKENISH = /\b[A-Za-z0-9_-]{32,}\b/g;
  function safeLabel(label) {
    return String(label ?? "").replace(EMAIL, (m) => `${m[0]}…@…`).replace(TOKENISH, "…").trim();
  }
  function applyWatch(list, ev) {
    if (ev.removed)
      return withMissing(list.filter((e) => e.cli !== ev.cli));
    if (!ev.entry)
      return [...list];
    const next = list.some((e) => e.cli === ev.cli) ? list.map((e) => e.cli === ev.cli ? ev.entry : e) : [...list, ev.entry];
    return sortEntries(next);
  }
  function summarize(lists) {
    let updates = 0, missingSignIns = 0, installed = 0;
    for (const list of lists)
      for (const e of list) {
        if (!e.installed)
          continue;
        installed++;
        if (statusOf(e) === "update")
          updates++;
        if (needsSignIn(e))
          missingSignIns++;
      }
    return { updates, missingSignIns, installed };
  }
  var jobKey = (machine, cli) => `${machine}/${cli}`;
  var busy = (j) => !!j && (j.phase === "requested" || j.phase === "running");
  function reduceJob(j, ev) {
    switch (ev.type) {
      case "request":
        if (busy(j))
          return j;
        return { kind: ev.kind, phase: "requested", job: null, terminal: null, error: null, exitCode: null };
      case "started":
        if (!j || j.phase !== "requested")
          return j;
        return { ...j, phase: "running", job: ev.job, terminal: ev.terminal };
      case "refused":
        if (!j || j.phase !== "requested")
          return j;
        return { ...j, phase: "refused", error: ev.error };
      case "finished":
        if (!j || j.job !== ev.job || j.phase !== "running")
          return j;
        return { ...j, phase: ev.ok ? "succeeded" : "failed", exitCode: ev.exitCode ?? null, error: ev.error ?? null };
      case "clear":
        return busy(j) ? j : null;
    }
  }
  var [machines, setMachines] = signal([]);
  var [byMachine, setByMachine] = signal({});
  var [machinesError, setMachinesError] = signal(null);
  var [jobs, setJobs] = signal({});
  var [loaded, setLoaded] = signal(false);
  var [selected, setSelected] = signal(null);
  var LOCAL = { id: "", name: "", origin: "local", status: "running" };
  var stateOf = (machine) => byMachine()[machine] ?? { entries: [], error: null, loading: true };
  var jobOf = (machine, cli) => jobs()[jobKey(machine, cli)] ?? null;
  var localMachine = () => machines().find((m) => m.origin === "local") ?? machines()[0] ?? LOCAL;
  var started = false;
  function start() {
    if (started)
      return;
    started = true;
    load(false);
    cmux.events.on("agent_cli.watch", (p) => onWatch(p));
  }
  async function load(checkLatest) {
    const m = await call("machine.list");
    if (m.ok) {
      setMachines(m.value.filter((x) => x.status !== "stopped"));
      setMachinesError(null);
    } else {
      setMachines([LOCAL]);
      setMachinesError(m.error.missing ? null : m.error);
    }
    await Promise.all(machines().map((x) => loadMachine(x.id, checkLatest)));
    setLoaded(true);
  }
  async function loadMachine(machine, checkLatest) {
    setByMachine((all) => ({ ...all, [machine]: { ...all[machine] ?? { entries: [], error: null }, loading: true } }));
    const params = machine ? { machine } : {};
    if (checkLatest)
      params.check_latest = true;
    const r = await call("agent_cli.list", params);
    const key = machine && r.ok && typeof r.value.machine === "string" && machines().some((m) => m.id === r.value.machine) ? r.value.machine : machine;
    setByMachine((all) => ({
      ...all,
      [key]: r.ok ? { entries: withMissing(r.value.clis ?? []), error: null, loading: false } : { entries: all[key]?.entries ?? [], error: r.error, loading: false }
    }));
    if (r.ok)
      for (const e of r.value.clis ?? [])
        dispatchJob(key, e.cli, { type: "clear" });
  }
  function dispatchJob(machine, cli, ev) {
    const key = jobKey(machine, cli);
    setJobs((all) => {
      const next = reduceJob(all[key] ?? null, ev);
      if (next === (all[key] ?? null))
        return all;
      const copy = { ...all };
      if (next)
        copy[key] = next;
      else
        delete copy[key];
      return copy;
    });
  }
  function onWatch(ev) {
    if (!ev || typeof ev.cli !== "string")
      return;
    const machine = typeof ev.machine === "string" ? ev.machine : "";
    if (ev.job)
      dispatchJob(machine, ev.cli, { type: "finished", job: ev.job.job, ok: ev.job.ok, exitCode: ev.job.exit_code, error: ev.job.error });
    if (ev.entry || ev.removed) {
      setByMachine((all) => {
        const cur = all[machine] ?? { entries: [], error: null, loading: false };
        return { ...all, [machine]: { ...cur, entries: applyWatch(cur.entries, ev) } };
      });
    }
  }
  async function run(kind, machine, cli, op, params, token) {
    dispatchJob(machine, cli, { type: "request", kind });
    const r = await call(op, { ...machine ? { machine } : {}, cli, ...params }, withGesture(token));
    if (r.ok)
      dispatchJob(machine, cli, { type: "started", job: r.value.job, terminal: r.value.terminal ?? null });
    else
      dispatchJob(machine, cli, { type: "refused", error: r.error.code });
    return r;
  }
  function update(machine, cli) {
    return run("update", machine, cli, "agent_cli.update", {}, gesture());
  }
  function install(machine, cli, method) {
    return run("install", machine, cli, "agent_cli.install", { method }, gesture());
  }
  async function signIn(machine, cli) {
    const token = gesture();
    const r = await run("sign_in", machine, cli, "agent_cli.sign_in", {}, token);
    const provider = providerFor(cli)?.accountsProvider;
    const isLocal = !machine || machine === localMachine().id;
    if (!r.ok && r.error.code === "operation.unsupported" && provider && isLocal) {
      dispatchJob(machine, cli, { type: "clear" });
      dispatchJob(machine, cli, { type: "request", kind: "sign_in" });
      const a = await call("action.run", { id: "accounts.reauthenticate", args: { provider } }, withGesture(token));
      dispatchJob(machine, cli, a.ok ? { type: "started", job: "accounts.reauthenticate", terminal: null } : { type: "refused", error: a.error.code });
    }
  }
  function refresh() {
    return load(true);
  }
  function openPane(token = gesture()) {
    return call("app.pane.open", { kind: "agentHub" }, withGesture(token));
  }
  // first-party-apps/agents/strings/en.json
  var en_default = {
    "account.expired": "Sign-in expired",
    "account.missing": "Signed out",
    "account.signedIn": "Signed in",
    "account.unknown": "Sign-in unknown",
    "action.install": "Install…",
    "action.open": "Open Agent CLIs",
    "action.refresh": "Check for Updates",
    "action.retry": "Try Again",
    "action.signIn": "Sign In…",
    "action.update": "Update",
    "badge.signIn": "Sign In",
    "badge.update": "Update",
    "detail.method": "Installed with {method}",
    "detail.title": "{cli} on {machine}",
    "empty.message": "Open Agent CLIs to install one.",
    "empty.none": "No agent CLIs reported",
    "empty.title": "No agent CLIs on this machine",
    "error.load": "Cannot list agent CLIs",
    "error.missingOp": "This cmux does not provide {op}.",
    "error.missingTitle": "Agent CLI detection is not available yet",
    "folded.missing": "Not installed ({n})",
    "hint.cmux": "Comes with cmux",
    "hint.none": "No install hint for this CLI",
    "job.done": "Done",
    "job.failed": "Failed",
    "job.failedCode": "Failed (exit {code})",
    "job.installing": "Installing in a terminal…",
    "job.requested": "Asking cmux…",
    "job.signingIn": "Signing in in a terminal…",
    "job.updating": "Updating in a terminal…",
    "level.major": "Major",
    "level.minor": "Minor",
    "level.patch": "Patch",
    loading: "Looking for agent CLIs…",
    "machine.error": "{machine}: {message}",
    "machine.this": "This Mac",
    missingOn: "Not on {machines}",
    "refused.other": "cmux did not run it ({code})",
    "refused.scope": "Allow this app to run commands in Settings > Apps",
    "refused.unsupported": "This cmux cannot run it yet",
    "section.more": "{n} more you can install",
    "summary.current": "All up to date",
    "summary.none": "No agent CLIs found",
    "summary.signIn": "{n} need sign-in",
    "summary.update1": "1 update",
    "summary.updates": "{n} updates",
    title: "Agent CLIs",
    "update.manual": "Update it the way you installed it",
    "version.ahead": "{version}, newer than the release",
    "version.current": "{version}, up to date",
    "version.missing": "Not installed",
    "version.unknown": "Unknown version",
    "version.update": "{current} → {latest}"
  };
  // first-party-apps/agents/strings/ja.json
  var ja_default = {
    "account.expired": "サインインの期限切れ",
    "account.missing": "サインアウト済み",
    "account.signedIn": "サインイン済み",
    "account.unknown": "サインイン状態不明",
    "action.install": "インストール…",
    "action.open": "エージェントCLIを開く",
    "action.refresh": "アップデートを確認",
    "action.retry": "再試行",
    "action.signIn": "サインイン…",
    "action.update": "アップデート",
    "badge.signIn": "サインイン",
    "badge.update": "アップデート",
    "detail.method": "{method}でインストール済み",
    "detail.title": "{machine}の{cli}",
    "empty.message": "エージェントCLIを開いてインストールしてください。",
    "empty.none": "エージェントCLIの報告がありません",
    "empty.title": "このマシンにエージェントCLIはありません",
    "error.load": "エージェントCLIを一覧できません",
    "error.missingOp": "このcmuxは{op}を提供していません。",
    "error.missingTitle": "エージェントCLIの検出はまだ使えません",
    "folded.missing": "未インストール（{n}）",
    "hint.cmux": "cmuxに付属",
    "hint.none": "このCLIのインストール方法はありません",
    "job.done": "完了",
    "job.failed": "失敗",
    "job.failedCode": "失敗（終了コード {code}）",
    "job.installing": "ターミナルでインストール中…",
    "job.requested": "cmuxに依頼中…",
    "job.signingIn": "ターミナルでサインイン中…",
    "job.updating": "ターミナルでアップデート中…",
    "level.major": "メジャー",
    "level.minor": "マイナー",
    "level.patch": "パッチ",
    loading: "エージェントCLIを探しています…",
    "machine.error": "{machine}: {message}",
    "machine.this": "このMac",
    missingOn: "{machines}にはありません",
    "refused.other": "cmuxは実行しませんでした（{code}）",
    "refused.scope": "設定 > アプリでこのアプリにコマンドの実行を許可してください",
    "refused.unsupported": "このcmuxではまだ実行できません",
    "section.more": "ほかに{n}個インストールできます",
    "summary.current": "すべて最新",
    "summary.none": "エージェントCLIが見つかりません",
    "summary.signIn": "{n}個がサインイン必要",
    "summary.update1": "アップデート1件",
    "summary.updates": "アップデート{n}件",
    title: "エージェントCLI",
    "update.manual": "インストールした方法でアップデートしてください",
    "version.ahead": "{version}（リリースより新しい）",
    "version.current": "{version}（最新）",
    "version.missing": "未インストール",
    "version.unknown": "バージョン不明",
    "version.update": "{current} → {latest}"
  };
  var tables = { en: en_default, ja: ja_default };
  var language = "en";
  function setLanguage(tag) {
    const base = String(tag ?? "en").toLowerCase().split(/[-_]/)[0] ?? "en";
    language = tables[base] ? base : "en";
  }
  function detectLanguage(ctx) {
    if (ctx && typeof ctx.locale === "string")
      return ctx.locale;
    try {
      return typeof cmux !== "undefined" && cmux.app?.locale ? cmux.app.locale : "en";
    } catch {
      return "en";
    }
  }
  function t(key, english, vars = {}) {
    const template = tables[language]?.[key] ?? english;
    return template.replace(/\{(\w+)\}/g, (whole, name) => (name in vars) ? String(vars[name]) : whole);
  }
  var VARIANTS = ["byCli", "byMachine", "matrix"];
  var DEFAULT_VARIANT = "byCli";
  var [override, setOverride] = signal(null);
  var setting = (key) => cmux.app.settings()[key];
  var variant = () => {
    const v = override() ?? setting("variant");
    return VARIANTS.includes(v) ? v : DEFAULT_VARIANT;
  };
  var showMissing = () => setting("showMissing") !== false;
  var nextVariant = (v) => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length];
  async function cycleVariant() {
    const next = nextVariant(variant());
    setOverride(next);
    try {
      await cmux.app.settings.set({ variant: next });
      return { variant: next, persisted: true };
    } catch {
      return { variant: next, persisted: false };
    }
  }
  var nameOf = (e) => displayName(e.cli, e.name);
  function machineName(m) {
    if (!m.id)
      return t("machine.this", "This Mac");
    return m.name || m.id;
  }
  function statusSymbol(s) {
    switch (s) {
      case "current":
        return "checkmark.circle.fill";
      case "update":
        return "arrow.up.circle.fill";
      case "missing":
        return "circle.dashed";
      case "ahead":
        return "hammer.circle";
      default:
        return "questionmark.circle";
    }
  }
  function statusTone(s) {
    return s === "current" ? "success" : s === "update" ? "warning" : "tertiary";
  }
  function versionLine(e) {
    const s = statusOf(e);
    if (s === "missing")
      return t("version.missing", "Not installed");
    const v = shortVersion(e.version) || t("version.unknown", "Unknown version");
    if (s === "update")
      return t("version.update", "{current} → {latest}", { current: v, latest: shortVersion(e.latest.version) });
    if (s === "current")
      return t("version.current", "{version}, up to date", { version: v });
    if (s === "ahead")
      return t("version.ahead", "{version}, newer than the release", { version: v });
    return v;
  }
  function levelBadge(e) {
    return statusOf(e) === "update" ? badgeFor(levelOf(e)) : null;
  }
  function badgeFor(level) {
    if (!level || level === "none" || level === "newer" || level === "unknown")
      return null;
    const text = level === "major" ? t("level.major", "Major") : level === "minor" ? t("level.minor", "Minor") : t("level.patch", "Patch");
    return Badge(text, level === "major" ? "danger" : "warning").fixedSize();
  }
  function jobText(j) {
    switch (j.phase) {
      case "requested":
        return t("job.requested", "Asking cmux…");
      case "running":
        return j.kind === "update" ? t("job.updating", "Updating in a terminal…") : j.kind === "install" ? t("job.installing", "Installing in a terminal…") : t("job.signingIn", "Signing in in a terminal…");
      case "succeeded":
        return t("job.done", "Done");
      case "failed":
        return j.exitCode !== null ? t("job.failedCode", "Failed (exit {code})", { code: j.exitCode }) : t("job.failed", "Failed");
      case "refused":
        return refusalText(j.error);
    }
  }
  function refusalText(code) {
    if (code === "scope.missing")
      return t("refused.scope", "Allow this app to run commands in Settings > Apps");
    if (code === "operation.unsupported")
      return t("refused.unsupported", "This cmux cannot run it yet");
    return t("refused.other", "cmux did not run it ({code})", { code: code ?? "" });
  }
  function primaryAction(machine, e) {
    return () => {
      const entry = e();
      const j = jobOf(machine, entry.cli);
      if (j && (busy(j) || j.phase === "failed" || j.phase === "refused")) {
        const retry = !busy(j);
        return HStack({ spacing: 6 }, [
          busy(j) ? ProgressView(null).frame({ width: 12, height: 12 }) : Icon("exclamationmark.triangle.fill").font("caption").color("warning"),
          Text(jobText(j)).font("caption").secondary().lineLimit(2),
          retry ? Button(t("action.retry", "Try Again"), () => void again(machine, entry, j)).font("caption") : null
        ]);
      }
      const s = statusOf(entry);
      if (s === "update") {
        if (!entry.updatable)
          return Text(t("update.manual", "Update it the way you installed it")).font("caption").secondary().lineLimit(2);
        return Button(t("action.update", "Update"), () => void update(machine, entry.cli)).font("caption");
      }
      if (s === "missing") {
        const hint = firstHint(machine, entry.cli);
        if (!hint || hint.method === "cmux")
          return null;
        return Button(t("action.install", "Install…"), () => void install(machine, entry.cli, hint.method)).font("caption");
      }
      return null;
    };
  }
  function again(machine, entry, j) {
    if (j.kind === "update")
      return update(machine, entry.cli);
    if (j.kind === "sign_in")
      return signIn(machine, entry.cli);
    const hint = firstHint(machine, entry.cli);
    return hint ? install(machine, entry.cli, hint.method) : undefined;
  }
  var platformFor = (machine) => platformOf(machines().find((m) => m.id === machine)?.os);
  var firstHint = (machine, cli) => hintsFor(cli, platformFor(machine))[0] ?? null;
  function accountStatusText(a) {
    switch (a.status) {
      case "signed_in":
        return t("account.signedIn", "Signed in");
      case "expired":
        return t("account.expired", "Sign-in expired");
      case "missing":
        return t("account.missing", "Signed out");
      default:
        return t("account.unknown", "Sign-in unknown");
    }
  }
  function accountLines(machine, e) {
    return () => {
      const entry = e();
      if (!showsAccounts(entry))
        return null;
      const list = entry.accounts.length ? entry.accounts : [{ account: "", label: "", status: "missing" }];
      return VStack({ spacing: 3 }, list.map((a) => accountLine(machine, entry, a)));
    };
  }
  function accountLine(machine, entry, a) {
    const label = [safeLabel(a.label), a.plan ? safeLabel(a.plan) : null].filter(Boolean).join(" · ");
    const bad = a.status === "expired" || a.status === "missing";
    return HStack({ spacing: 6 }, [
      Icon(bad ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle").font("caption").color(bad ? "warning" : "secondary"),
      Text(label ? `${label} · ${accountStatusText(a)}` : accountStatusText(a)).font("caption").secondary().lineLimit(1).truncation("tail"),
      Spacer(),
      bad && !busy(jobOf(machine, entry.cli)) ? Button(t("action.signIn", "Sign In…"), () => void signIn(machine, entry.cli)).font("caption") : null
    ]);
  }
  function hintLines(machine, cli) {
    const hints = hintsFor(cli, platformFor(machine));
    if (!hints.length)
      return Text(t("hint.none", "No install hint for this CLI")).font("caption").secondary();
    return VStack({ spacing: 2 }, hints.map((h) => h.method === "cmux" ? Text(t("hint.cmux", "Comes with cmux")).font("caption").secondary() : Text(h.command).font(11).monospaced().secondary().lineLimit(1).truncation("middle")));
  }
  function errorState(err) {
    if (err.missing) {
      return EmptyState({
        title: t("error.missingTitle", "Agent CLI detection is not available yet"),
        message: t("error.missingOp", "This cmux does not provide {op}.", { op: err.op }),
        symbol: "puzzlepiece.extension"
      });
    }
    return EmptyState({ title: t("error.load", "Cannot list agent CLIs"), message: err.message, symbol: "exclamationmark.triangle" });
  }
  function toolbar(summary) {
    return HStack({ spacing: 8 }, [
      VStack({ spacing: 1 }, [Text(t("title", "Agent CLIs")).font("headline"), Text(summary).font("caption").secondary().lineLimit(1)]),
      Spacer(),
      Button(Icon("arrow.clockwise"), () => void refresh()).help(t("action.refresh", "Check for Updates"))
    ]).padding({ top: 8, leading: 12, bottom: 6, trailing: 12 });
  }
  var allLists = () => machines().map((m) => byMachine()[m.id]?.entries ?? []);
  function summaryText(lists) {
    const s = summarize(lists);
    if (!s.installed)
      return t("summary.none", "No agent CLIs found");
    const parts = [];
    if (s.updates)
      parts.push(s.updates === 1 ? t("summary.update1", "1 update") : t("summary.updates", "{n} updates", { n: s.updates }));
    if (s.missingSignIns)
      parts.push(t("summary.signIn", "{n} need sign-in", { n: s.missingSignIns }));
    return parts.length ? parts.join(" · ") : t("summary.current", "All up to date");
  }
  function row(machine, e) {
    return Row({
      title: () => nameOf(e()),
      subtitle: () => versionLine(e()),
      symbol: () => statusSymbol(statusOf(e())),
      tint: () => statusTone(statusOf(e())),
      badge: () => statusOf(e()) === "update" ? t("badge.update", "Update") : needsSignIn(e()) ? t("badge.signIn", "Sign In") : null
    }).onTap(() => {
      setSelected({ machine, cli: e().cli });
      openPane();
    }).contextMenu(() => [
      Button(t("action.update", "Update"), () => void update(machine, e().cli)).disabled(statusOf(e()) !== "update" || !e().updatable),
      Button(t("action.signIn", "Sign In…"), () => void signIn(machine, e().cli)).disabled(!e().installed),
      Button(t("action.open", "Open Agent CLIs"), () => void openPane())
    ]);
  }
  function agentsSection() {
    return VStack({ spacing: 2 }, [
      () => {
        const m = localMachine();
        const st = stateOf(m.id);
        if (!loaded() && st.loading)
          return Text(t("loading", "Looking for agent CLIs…")).font("caption").secondary().padding(8);
        if (st.error && !st.entries.length)
          return errorState(st.error);
        const installed = st.entries.filter((e) => e.installed);
        const missing = st.entries.length - installed.length;
        if (!installed.length) {
          return EmptyState({ title: t("empty.title", "No agent CLIs on this machine"), message: t("empty.message", "Open Agent CLIs to install one."), symbol: "terminal" }).onTap(() => void openPane());
        }
        return VStack({ spacing: 0 }, [
          ForEach({ items: () => stateOf(m.id).entries.filter((e) => e.installed), key: (e) => e.cli }, (e) => row(m.id, e)),
          missing ? Text(t("section.more", "{n} more you can install", { n: missing })).font("caption").secondary().padding({ top: 4, leading: 10, bottom: 4, trailing: 10 }).onTap(() => void openPane()) : null
        ]);
      }
    ]);
  }
  function groups() {
    const ms = machines();
    const all = byMachine();
    const ids = new Set;
    for (const m of ms)
      for (const e of all[m.id]?.entries ?? [])
        ids.add(e.cli);
    const out = [...ids].map((cli) => {
      const cells = ms.map((m) => ({ machine: m, entry: all[m.id]?.entries.find((e) => e.cli === cli) ?? null }));
      const any = cells.find((c) => c.entry)?.entry;
      return { cli, name: displayName(cli, any?.name), cells, installedAnywhere: cells.some((c) => c.entry?.installed) };
    });
    return out.sort((a, b) => Number(b.installedAnywhere) - Number(a.installedAnywhere) || providerRank(a.cli) - providerRank(b.cli) || a.cli.localeCompare(b.cli));
  }
  function gate() {
    const err = machinesError();
    if (err)
      return errorState(err);
    const ms = machines();
    if (!loaded())
      return Text(t("loading", "Looking for agent CLIs…")).font("callout").secondary().padding(16);
    const errors = ms.map((m) => stateOf(m.id).error);
    if (ms.length && errors.every(Boolean))
      return errorState(errors[0]);
    if (allLists().every((l) => l.length === 0))
      return EmptyState({ title: t("empty.none", "No agent CLIs reported"), symbol: "terminal" });
    return null;
  }
  var frame = (body) => VStack({ spacing: 0 }, [toolbar(() => summaryText(allLists())), Divider(), () => gate() ?? body()]);
  var machineError = (m) => {
    const err = stateOf(m.id).error;
    return err ? Text(t("machine.error", "{machine}: {message}", { machine: machineName(m), message: err.message })).font("caption").color("danger").lineLimit(2) : null;
  };
  function cliLine(c) {
    const entry = () => c.entry;
    return VStack({ spacing: 3 }, [
      HStack({ spacing: 8 }, [
        Icon(statusSymbol(statusOf(c.entry))).font("caption").color(statusTone(statusOf(c.entry))),
        Text(machineName(c.machine)).font("callout").frame({ width: 110 }).lineLimit(1).truncation("tail"),
        Text(() => versionLine(entry())).font("callout").monospaced().secondary().lineLimit(1),
        Spacer(),
        primaryAction(c.machine.id, entry)
      ]),
      HStack({ spacing: 0 }, [Spacer().frame({ width: 26 }), accountLines(c.machine.id, entry)])
    ]);
  }
  function cliBlock(g) {
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 8 }, [
        Text(() => g().name).font("headline"),
        () => badgeFor(highestLevel(g().cells.map((c) => c.entry))),
        Spacer()
      ]),
      () => VStack({ spacing: 6 }, g().cells.filter((c) => c.entry?.installed).map(cliLine)),
      () => {
        const missingOn = g().cells.filter((c) => !c.entry?.installed);
        if (!missingOn.length || !showMissing() && g().installedAnywhere)
          return null;
        const local = missingOn[0];
        return VStack({ spacing: 3 }, [
          HStack({ spacing: 8 }, [
            Text(t("missingOn", "Not on {machines}", { machines: missingOn.map((c) => machineName(c.machine)).join(", ") })).font("caption").secondary().lineLimit(1),
            Spacer(),
            primaryAction(local.machine.id, () => local.entry ?? { cli: g().cli, installed: false, version: null, latest: null, install_method: null, updatable: false, accounts: [] })
          ]),
          hintLines(local.machine.id, g().cli)
        ]);
      }
    ]).padding({ top: 10, leading: 12, bottom: 10, trailing: 12 });
  }
  function byCliView() {
    return frame(() => VStack({ spacing: 0 }, [
      VStack({ spacing: 2 }, machines().map(machineError)).padding({ top: 0, leading: 12, bottom: 0, trailing: 12 }),
      ForEach({ items: () => groups().filter((g) => g.installedAnywhere || showMissing()), key: (g) => g.cli }, (g) => VStack({ spacing: 0 }, [cliBlock(g), Divider()]))
    ]));
  }
  var [unfolded, setUnfolded] = signal({});
  function machineRow(machine, e) {
    return HStack({ spacing: 10 }, [
      Icon(() => statusSymbol(statusOf(e()))).color(() => statusTone(statusOf(e()))),
      VStack({ spacing: 2 }, [
        HStack({ spacing: 6 }, [Text(() => nameOf(e())).font("body").weight("medium"), () => levelBadge(e())]),
        Text(() => versionLine(e())).font("caption").monospaced().secondary(),
        accountLines(machine, e),
        () => e().installed ? null : hintLines(machine, e().cli)
      ]).frame({ maxWidth: "infinity" }),
      primaryAction(machine, e)
    ]).padding({ top: 6, leading: 12, bottom: 6, trailing: 12 });
  }
  function machineSection(m) {
    const id = () => m().id;
    return VStack({ spacing: 0 }, [
      HStack({ spacing: 6 }, [
        Icon(() => m().origin === "local" ? "laptopcomputer" : "server.rack").secondary(),
        Text(() => machineName(m())).font("headline"),
        Text(() => m().status === "running" ? "" : m().status).font("caption").secondary(),
        Spacer()
      ]).padding({ top: 10, leading: 12, bottom: 4, trailing: 12 }),
      () => machineError(m()),
      ForEach({ items: () => stateOf(id()).entries.filter((e) => e.installed), key: (e) => e.cli }, (e) => machineRow(id(), e)),
      () => {
        const missing = stateOf(id()).entries.filter((e) => !e.installed);
        if (!missing.length || !showMissing())
          return null;
        const open = !!unfolded()[id()];
        return VStack({ spacing: 0 }, [
          HStack({ spacing: 6 }, [
            Icon(open ? "chevron.down" : "chevron.right").font("caption").secondary(),
            Text(t("folded.missing", "Not installed ({n})", { n: missing.length })).font("callout").secondary(),
            Spacer()
          ]).padding({ top: 6, leading: 12, bottom: 6, trailing: 12 }).onTap(() => setUnfolded((u) => ({ ...u, [id()]: !open }))),
          open ? VStack({ spacing: 0 }, missing.map((e) => machineRow(id(), () => e))) : null
        ]);
      },
      Divider()
    ]);
  }
  function byMachineView() {
    return frame(() => ForEach({ items: machines, key: (m) => m.id || "local" }, (m) => machineSection(m)));
  }
  var NAME_W = 120;
  var CELL_W = 96;
  function cellView(g, c) {
    const e = c.entry;
    const s = e ? statusOf(e) : "missing";
    const job = e ? jobOf(c.machine.id, e.cli) : null;
    const text = job ? "…" : s === "missing" ? "—" : shortVersion(e.version) || "?";
    const isSel = () => selected()?.machine === c.machine.id && selected()?.cli === g.cli;
    return HStack({ spacing: 4 }, [Icon(statusSymbol(s)).font("caption").color(statusTone(s)), Text(text).font(11).monospaced().lineLimit(1)]).padding({ top: 4, leading: 6, bottom: 4, trailing: 6 }).frame({ width: CELL_W }).background(() => isSel() ? "selected" : null).hoverBackground("hover").cornerRadius(5).onTap(() => setSelected({ machine: c.machine.id, cli: g.cli }));
  }
  function detail() {
    return () => {
      const sel = selected();
      const g = sel ? groups().find((x) => x.cli === sel.cli) : groups()[0];
      if (!g)
        return null;
      const c = g.cells.find((x) => x.machine.id === (sel?.machine ?? g.cells[0]?.machine.id)) ?? g.cells[0];
      if (!c)
        return null;
      const entry = () => groups().find((x) => x.cli === g.cli)?.cells.find((x) => x.machine.id === c.machine.id)?.entry ?? { cli: g.cli, installed: false, version: null, latest: null, install_method: null, updatable: false, accounts: [] };
      const e = entry();
      const job = jobOf(c.machine.id, g.cli);
      return VStack({ spacing: 6 }, [
        HStack({ spacing: 8 }, [Text(t("detail.title", "{cli} on {machine}", { cli: g.name, machine: machineName(c.machine) })).font("headline"), levelBadge(e), Spacer(), primaryAction(c.machine.id, entry)]),
        Text(versionLine(e)).font("callout").monospaced().secondary(),
        e.path_label ? Text(e.path_label).font("caption").monospaced().secondary().lineLimit(1).truncation("middle") : null,
        e.install_method && e.installed ? Text(t("detail.method", "Installed with {method}", { method: e.install_method })).font("caption").secondary() : null,
        job && job.phase === "succeeded" ? Text(jobText(job)).font("caption").color("success") : null,
        accountLines(c.machine.id, entry),
        e.installed ? null : hintLines(c.machine.id, g.cli)
      ]).padding(12);
    };
  }
  function matrixView() {
    return frame(() => VStack({ spacing: 0 }, [
      HStack({ spacing: 0 }, [
        Text("").frame({ width: NAME_W }),
        ...machines().map((m) => Text(machineName(m)).font("caption").weight("semibold").secondary().lineLimit(1).truncation("tail").frame({ width: CELL_W }).padding({ top: 0, leading: 6, bottom: 0, trailing: 0 })),
        Spacer()
      ]).padding({ top: 8, leading: 12, bottom: 4, trailing: 12 }),
      ForEach({ items: () => groups().filter((g) => g.installedAnywhere || showMissing()), key: (g) => g.cli }, (g) => HStack({ spacing: 0 }, [
        Text(() => g().name).font("callout").lineLimit(1).truncation("tail").frame({ width: NAME_W }),
        () => HStack({ spacing: 0 }, g().cells.map((c) => cellView(g(), c))),
        Spacer()
      ]).padding({ top: 1, leading: 12, bottom: 1, trailing: 12 })),
      Divider().padding({ top: 6, leading: 0, bottom: 0, trailing: 0 }),
      detail()
    ]));
  }
  function renderSection(ctx = {}) {
    setLanguage(detectLanguage(ctx));
    start();
    return agentsSection();
  }
  function renderPane(ctx = {}) {
    setLanguage(detectLanguage(ctx));
    start();
    return VStack({ spacing: 0 }, [
      () => {
        switch (variant()) {
          case "byMachine":
            return byMachineView();
          case "matrix":
            return matrixView();
          default:
            return byCliView();
        }
      }
    ]);
  }
  async function openAgents(_args = {}, ctx) {
    await openPane(ctx?.gesture ?? null);
    return {};
  }
  async function checkForUpdates() {
    start();
    await refresh();
    return {};
  }
  var cycleVariant2 = cycleVariant;
  globalThis.__cmuxAppExports = { ...exports_main };
})();
