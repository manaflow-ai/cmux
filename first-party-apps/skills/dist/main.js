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
    openSkills: () => openSkills,
    reload: () => reload,
    renderPane: () => renderPane,
    renderSection: () => renderSection
  });
  var MAX_REPLANS = 1;
  function reduceChange(s, ev) {
    switch (ev.type) {
      case "ask":
        return s.phase === "applying" ? s : { phase: "planning", intent: ev.intent, replans: 0 };
      case "planned":
        if (s.phase !== "planning")
          return s;
        return { phase: "review", intent: s.intent, plan: ev.plan, replans: s.replans, note: s.replans > 0 ? "stale" : null };
      case "apply":
        return s.phase === "review" ? { phase: "applying", intent: s.intent, plan: s.plan, replans: s.replans } : s;
      case "applied":
        return s.phase === "applying" ? { phase: "applied", intent: s.intent } : s;
      case "stale":
        if (s.phase !== "applying")
          return s;
        if (s.replans >= MAX_REPLANS)
          return { phase: "failed", intent: s.intent, code: "diff.stale", message: "" };
        return { phase: "planning", intent: s.intent, replans: s.replans + 1 };
      case "error":
        return s.phase === "planning" || s.phase === "applying" ? { phase: "failed", intent: s.intent, code: ev.code, message: ev.message } : s;
      case "cancel":
        return s.phase === "applying" ? s : { phase: "idle" };
    }
  }
  var busyChange = (s) => s.phase === "planning" || s.phase === "applying";
  var AGENTS = [
    {
      id: "claude",
      name: "Claude Code",
      skills: { user: "~/.claude/skills", project: ".claude/skills" },
      mcp: { format: "json", user: "~/.claude.json", project: ".mcp.json", key: "mcpServers", dialect: "mcpServers", disable: "park" }
    },
    {
      id: "codex",
      name: "Codex",
      skills: { user: "~/.codex/skills", project: ".codex/skills" },
      mcp: { format: "toml", user: "~/.codex/config.toml", project: ".codex/config.toml", key: "mcp_servers", dialect: "codex", disable: "flag" }
    },
    {
      id: "opencode",
      name: "OpenCode",
      skills: { user: "~/.config/opencode/skill", project: ".opencode/skill" },
      mcp: { format: "json", user: "~/.config/opencode/opencode.json", project: "opencode.json", key: "mcp", dialect: "opencode", disable: "flag" }
    },
    {
      id: "gemini",
      name: "Gemini CLI",
      skills: null,
      mcp: { format: "json", user: "~/.gemini/settings.json", project: ".gemini/settings.json", key: "mcpServers", dialect: "mcpServers", disable: "park" }
    }
  ];
  var BY_ID = new Map(AGENTS.map((a) => [a.id, a]));
  var agentInfo = (id) => BY_ID.get(id) ?? null;
  var agentName = (id) => agentInfo(id)?.name ?? id;
  var agentRank = (id) => {
    const i = AGENTS.findIndex((a) => a.id === id);
    return i < 0 ? AGENTS.length : i;
  };
  var SEGMENT = /^[A-Za-z0-9._-]+$/;
  function parseSource(raw) {
    const text = raw.trim();
    if (!text)
      return { ok: false, reason: "empty" };
    if (text.startsWith("store:")) {
      const id = text.slice(6);
      return /^[a-z0-9-]+\/[a-z0-9][a-z0-9-]*$/.test(id) ? { ok: true, source: { store: id }, label: id } : { ok: false, reason: "shape" };
    }
    let rest = text;
    let ref = null;
    const hash = rest.indexOf("#");
    if (hash >= 0) {
      ref = rest.slice(hash + 1) || null;
      rest = rest.slice(0, hash);
    }
    let path = null;
    const sub = rest.indexOf("//", rest.indexOf("://") >= 0 ? rest.indexOf("://") + 3 : 0);
    if (sub >= 0) {
      path = rest.slice(sub + 2).replace(/\/+$/, "") || null;
      rest = rest.slice(0, sub);
    }
    if (path && path.split("/").some((p) => p === ".." || !SEGMENT.test(p)))
      return { ok: false, reason: "shape" };
    if (ref && !/^[A-Za-z0-9._\/-]+$/.test(ref))
      return { ok: false, reason: "shape" };
    let git;
    if (/^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(rest))
      git = `https://github.com/${rest.replace(/\.git$/, "")}.git`;
    else if (/^https:\/\/[^\s/]+\/\S+$/.test(rest))
      git = rest;
    else if (/^git@[^\s:]+:\S+$/.test(rest) || /^ssh:\/\/\S+$/.test(rest))
      git = rest;
    else if (/^[a-z][a-z0-9+.-]*:/.test(rest))
      return { ok: false, reason: "scheme" };
    else
      return { ok: false, reason: "shape" };
    const name = git.replace(/\.git$/, "").split(/[/:]/).filter(Boolean).slice(-2).join("/");
    return { ok: true, source: { git, ref, path }, label: [name, path].filter(Boolean).join("/") + (ref ? `@${ref}` : "") };
  }
  function parseServerLine(raw) {
    const parts = raw.trim().split(/\s+/).filter(Boolean);
    if (parts.length < 2 || !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/.test(parts[0]))
      return null;
    const [name, first, ...rest] = parts;
    if (/^https:\/\//.test(first))
      return rest.length ? null : { name, transport: "http", url: first };
    if (/^[a-z]+:\/\//.test(first))
      return null;
    return { name, transport: "stdio", command: first, args: rest };
  }
  // first-party-apps/skills/strings/en.json
  var en_default = {
    "action.apply": "Apply",
    "action.cancel": "Cancel",
    "action.dismiss": "Dismiss",
    "action.done": "Done",
    "action.openInDiffs": "Open in Diffs",
    "action.remove": "Remove…",
    "action.turnOff": "Turn Off",
    "action.turnOn": "Turn On",
    "add.placeholder": "Add MCP server: name command… or name https://…",
    "add.shape": "Type a name, then a command or an https URL",
    "agent.none": "{agent} has no skills or MCP servers here",
    "badge.network": "Network or writes",
    "badge.off": "Off",
    "badge.runs": "Runs commands",
    "detail.env": "Secrets it reads: {keys}",
    "diffs.missing": "Opening the Diffs app needs ui.open, which this cmux does not have yet",
    "empty.message": "Install a skill from a git URL or add an MCP server above.",
    "empty.title": "No skills or MCP servers yet",
    "error.load": "Cannot load {op}: {message}",
    "error.missingBoth": "This cmux does not provide skill.list and mcp_server.list.",
    "error.missingOp": "{op} is not available in this cmux yet.",
    "error.missingTitle": "Skill and MCP management is not available yet",
    "error.title": "Cannot read agent configuration",
    "failed.scope": "Allow this app to change agent configuration in Settings > Apps.",
    "failed.stale": "The files changed again while you reviewed. Look at them and try once more.",
    "failed.unparseable": "The agent's config file has comments or errors; cmux does not rewrite it.",
    "failed.unsupported": "This cmux cannot plan this change yet.",
    "file.create": "new file",
    "file.delete": "deleted",
    "filter.all": "All",
    "filter.anyScope": "Everywhere and project",
    "filter.mcp": "MCP Servers",
    "filter.none": "Nothing matches these filters",
    "filter.off": "Off",
    "filter.skills": "Skills",
    "filter.user": "Everywhere",
    "install.placeholder": "Install skill: git URL, owner/repo or store:id",
    "install.scheme": "Only https and ssh git URLs can be installed",
    "install.shape": "Type a git URL, owner/repo or store:publisher/name",
    "intent.add": "Add {name} {scope}",
    "intent.disable": "Turn off {name} for {agent} {scope}",
    "intent.enable": "Turn on {name} for {agent} {scope}",
    "intent.install": "Install {name} {scope}",
    "intent.remove": "Remove {name} from {agent} {scope}",
    "kind.mcp": "MCP server",
    "kind.skill": "Skill",
    loading: "Reading agent configuration…",
    "menu.offFor": "Turn Off for {agent}",
    "menu.onFor": "Turn On for {agent}",
    "menu.removeFrom": "Remove from {agent}…",
    "review.applied": "Applied",
    "review.more": "{n} more lines: open in Diffs to see all",
    "review.planning": "Preparing the change…",
    "review.stale": "An agent changed these files after the first preview. This is the new diff.",
    "sandbox.complete": "Complete sandbox",
    "sandbox.contained": "Contained sandbox",
    "sandbox.none": "Not sandboxed",
    "sandbox.standard": "Standard sandbox",
    "scope.project": "in {project}",
    "scope.projectTitle": "This project: {project}",
    "scope.thisProject": "this project",
    "scope.user": "everywhere",
    "scope.userTitle": "Everywhere",
    "section.mcp": "MCP Servers",
    "section.pending": "1 change to review",
    "section.skills": "Skills",
    "section.unsandboxed": "Runs commands without a sandbox",
    "source.agent": "Added by {label}",
    "source.git": "From {label}",
    "source.local": "Local folder",
    "source.store": "From the store: {label}",
    title: "Skills and MCP Servers"
  };
  // first-party-apps/skills/strings/ja.json
  var ja_default = {
    "action.apply": "適用",
    "action.cancel": "キャンセル",
    "action.dismiss": "閉じる",
    "action.done": "完了",
    "action.openInDiffs": "差分アプリで開く",
    "action.remove": "削除…",
    "action.turnOff": "オフにする",
    "action.turnOn": "オンにする",
    "add.placeholder": "MCPサーバーを追加: 名前 コマンド… または 名前 https://…",
    "add.shape": "名前に続けてコマンドかhttpsのURLを入力してください",
    "agent.none": "{agent}にはここにスキルもMCPサーバーもありません",
    "badge.network": "ネットワークまたは書き込み",
    "badge.off": "オフ",
    "badge.runs": "コマンドを実行",
    "detail.env": "読み取るシークレット: {keys}",
    "diffs.missing": "差分アプリを開くにはui.openが必要ですが、このcmuxにはまだありません",
    "empty.message": "上でgitのURLからスキルをインストールするか、MCPサーバーを追加してください。",
    "empty.title": "スキルもMCPサーバーもまだありません",
    "error.load": "{op}を読み込めません: {message}",
    "error.missingBoth": "このcmuxはskill.listとmcp_server.listを提供していません。",
    "error.missingOp": "{op}はこのcmuxではまだ使えません。",
    "error.missingTitle": "スキルとMCPの管理はまだ使えません",
    "error.title": "エージェントの設定を読み込めません",
    "failed.scope": "設定 > アプリでこのアプリにエージェント設定の変更を許可してください。",
    "failed.stale": "確認中にファイルがまた変更されました。内容を見てもう一度試してください。",
    "failed.unparseable": "エージェントの設定ファイルにコメントかエラーがあります。cmuxは書き換えません。",
    "failed.unsupported": "このcmuxはこの変更をまだ準備できません。",
    "file.create": "新規ファイル",
    "file.delete": "削除",
    "filter.all": "すべて",
    "filter.anyScope": "全体とプロジェクト",
    "filter.mcp": "MCPサーバー",
    "filter.none": "このフィルタに一致するものはありません",
    "filter.off": "オフ",
    "filter.skills": "スキル",
    "filter.user": "全体",
    "install.placeholder": "スキルをインストール: gitのURL、owner/repo、store:id",
    "install.scheme": "インストールできるのはhttpsとsshのgit URLだけです",
    "install.shape": "gitのURL、owner/repo、store:publisher/nameを入力してください",
    "intent.add": "{name}を追加（{scope}）",
    "intent.disable": "{agent}の{name}をオフ（{scope}）",
    "intent.enable": "{agent}の{name}をオン（{scope}）",
    "intent.install": "{name}をインストール（{scope}）",
    "intent.remove": "{agent}から{name}を削除（{scope}）",
    "kind.mcp": "MCPサーバー",
    "kind.skill": "スキル",
    loading: "エージェントの設定を読み込み中…",
    "menu.offFor": "{agent}でオフにする",
    "menu.onFor": "{agent}でオンにする",
    "menu.removeFrom": "{agent}から削除…",
    "review.applied": "適用しました",
    "review.more": "ほかに{n}行: すべて見るには差分アプリで開いてください",
    "review.planning": "変更を準備中…",
    "review.stale": "最初のプレビューの後にエージェントがファイルを変更しました。これは新しい差分です。",
    "sandbox.complete": "完全サンドボックス",
    "sandbox.contained": "制限サンドボックス",
    "sandbox.none": "サンドボックスなし",
    "sandbox.standard": "標準サンドボックス",
    "scope.project": "{project}内",
    "scope.projectTitle": "このプロジェクト: {project}",
    "scope.thisProject": "このプロジェクト",
    "scope.user": "全体",
    "scope.userTitle": "全体",
    "section.mcp": "MCPサーバー",
    "section.pending": "確認待ちの変更1件",
    "section.skills": "スキル",
    "section.unsandboxed": "サンドボックスなしでコマンドを実行",
    "source.agent": "{label}が追加",
    "source.git": "{label}から",
    "source.local": "ローカルフォルダ",
    "source.store": "ストアから: {label}",
    title: "スキルとMCPサーバー"
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
  function groupByName(items) {
    const map = new Map;
    for (const i of items) {
      const key = `${i.kind}:${i.scope}:${i.root ?? ""}:${i.name}`;
      const g = map.get(key) ?? { key, kind: i.kind, name: i.name, scope: i.scope, root: i.root ?? null, items: [] };
      g.items.push(i);
      map.set(key, g);
    }
    for (const g of map.values())
      g.items.sort((a, b) => agentRank(a.agent) - agentRank(b.agent));
    return [...map.values()].sort((a, b) => (a.scope === b.scope ? 0 : a.scope === "project" ? -1 : 1) || (a.kind === b.kind ? 0 : a.kind === "skill" ? -1 : 1) || a.name.localeCompare(b.name));
  }
  var DEFAULT_FILTER = { kind: "all", agent: null, scope: "all", query: "" };
  function matches(i, f) {
    if (f.kind === "off" ? i.enabled : f.kind !== "all" && i.kind !== f.kind)
      return false;
    if (f.agent && i.agent !== f.agent)
      return false;
    if (f.scope !== "all" && i.scope !== f.scope)
      return false;
    const q = f.query.trim().toLowerCase();
    return !q || i.name.toLowerCase().includes(q) || i.kind === "skill" && i.description.toLowerCase().includes(q);
  }
  function requestTone(r) {
    if (/:(execute|external)\b/.test(r) || r.startsWith("process:"))
      return "danger";
    if (/:write\b/.test(r) || r.startsWith("net:"))
      return "warning";
    return "secondary";
  }
  function worstTone(requests) {
    const tones = requests.map(requestTone);
    return tones.includes("danger") ? "danger" : tones.includes("warning") ? "warning" : "secondary";
  }
  var needsAttention = (i) => i.enabled && i.sandbox === "none" && worstTone(i.requests) === "danger";
  var [items, setItems] = signal([]);
  var [projects, setProjects] = signal([]);
  var [currentRoot, setCurrentRoot] = signal(null);
  var [errors, setErrors] = signal({ skills: null, mcp: null });
  var [loaded, setLoaded] = signal(false);
  var [filter, setFilter] = signal(DEFAULT_FILTER);
  var [selected, setSelected] = signal(null);
  var [change, setChange] = signal({ phase: "idle" });
  var [notice, setNotice] = signal(null);
  var dispatchChange = (ev) => setChange((s) => reduceChange(s, ev));
  var projectLabel = (root) => projects().find((p) => p.root === root)?.label ?? null;
  var started = false;
  function start() {
    if (started)
      return;
    started = true;
    load();
    cmux.events.on("skill.watch", () => void loadItems());
    cmux.events.on("mcp_server.watch", () => void loadItems());
  }
  async function load() {
    const ws = await call("workspace.list");
    const focused = ws.ok ? ws.value.find((w) => w.focused) : null;
    const root = focused ? await call("workspace.root", { workspace: focused.id }) : null;
    const list = root?.ok && root.value.root ? [{ root: root.value.root, label: root.value.label || focused.name, workspace: focused.id }] : [];
    setProjects(list);
    setCurrentRoot(list[0]?.root ?? null);
    await loadItems();
    setLoaded(true);
  }
  async function loadItems() {
    const root = currentRoot();
    const params = root ? { roots: [root] } : {};
    const [s, m] = await Promise.all([call("skill.list", params), call("mcp_server.list", params)]);
    const next = [...s.ok ? (s.value.skills ?? []).map((x) => ({ ...x, kind: "skill" })) : [], ...m.ok ? (m.value.servers ?? []).map((x) => ({ ...x, kind: "mcp" })) : []];
    setItems(next);
    setErrors({ skills: s.ok ? null : s.error, mcp: m.ok ? null : m.error });
  }
  var target = (i) => ({ id: i.id, agent: i.agent, scope: i.scope, ...i.root ? { root: i.root } : {}, name: i.name });
  function scopeText(scope, root) {
    return scope === "user" ? t("scope.user", "everywhere") : t("scope.project", "in {project}", { project: projectLabel(root) ?? t("scope.thisProject", "this project") });
  }
  async function plan(intent) {
    dispatchChange({ type: "ask", intent });
    const r = await call(intent.op, { ...intent.params, dry_run: true });
    if (r.ok)
      dispatchChange({ type: "planned", plan: r.value });
    else
      dispatchChange({ type: "error", code: r.error.code, message: r.error.message });
  }
  function toggle(i) {
    const op = `${i.kind === "skill" ? "skill" : "mcp_server"}.${i.enabled ? "disable" : "enable"}`;
    const vars = { name: i.name, agent: agentName(i.agent), scope: scopeText(i.scope, i.root) };
    const title = i.enabled ? t("intent.disable", "Turn off {name} for {agent} {scope}", vars) : t("intent.enable", "Turn on {name} for {agent} {scope}", vars);
    return plan({ op, params: target(i), title });
  }
  function remove(i) {
    const op = `${i.kind === "skill" ? "skill" : "mcp_server"}.remove`;
    return plan({ op, params: target(i), title: t("intent.remove", "Remove {name} from {agent} {scope}", { name: i.name, agent: agentName(i.agent), scope: scopeText(i.scope, i.root) }) });
  }
  var installScope = () => {
    const f = filter();
    const root = currentRoot();
    return f.scope === "project" && root ? { scope: "project", root } : { scope: "user" };
  };
  function installSkill(text, only = null) {
    const parsed = parseSource(text);
    if (!parsed.ok) {
      setNotice(parsed.reason === "scheme" ? t("install.scheme", "Only https and ssh git URLs can be installed") : t("install.shape", "Type a git URL, owner/repo or store:publisher/name"));
      return false;
    }
    setNotice(null);
    const agents = only ?? (filter().agent ? [filter().agent] : AGENTS.filter((a) => a.skills).map((a) => a.id));
    const where = installScope();
    plan({ op: "skill.install", params: { source: parsed.source, agents, ...where }, title: t("intent.install", "Install {name} {scope}", { name: parsed.label, scope: scopeText(where.scope, where.root) }) });
    return true;
  }
  function addServer(text, only = null) {
    const parsed = parseServerLine(text);
    if (!parsed) {
      setNotice(t("add.shape", "Type a name, then a command or an https URL"));
      return false;
    }
    setNotice(null);
    const agents = only ?? (filter().agent ? [filter().agent] : AGENTS.map((a) => a.id));
    const where = installScope();
    const entry = parsed.transport === "http" ? { transport: "http", url: parsed.url, enabled: true } : { transport: "stdio", command: parsed.command, args: parsed.args, enabled: true };
    plan({ op: "mcp_server.add", params: { agents, ...where, name: parsed.name, entry }, title: t("intent.add", "Add {name} {scope}", { name: parsed.name, scope: scopeText(where.scope, where.root) }) });
    return true;
  }
  async function apply() {
    const s = change();
    if (s.phase !== "review")
      return;
    const token = gesture();
    dispatchChange({ type: "apply" });
    const r = await call("diff.decide", { diff: s.plan.diff, decisions: [{ decision: "accept" }] }, withGesture(token));
    if (r.ok) {
      dispatchChange({ type: "applied" });
      await loadItems();
      return;
    }
    if (r.error.code === "diff.stale") {
      dispatchChange({ type: "stale" });
      const again = change();
      if (again.phase === "planning") {
        const p = await call(again.intent.op, { ...again.intent.params, dry_run: true });
        dispatchChange(p.ok ? { type: "planned", plan: p.value } : { type: "error", code: p.error.code, message: p.error.message });
      }
      return;
    }
    dispatchChange({ type: "error", code: r.error.code, message: r.error.message });
  }
  function cancel() {
    if (!busyChange(change()))
      dispatchChange({ type: "cancel" });
  }
  async function openInDiffs() {
    const s = change();
    if (s.phase !== "review")
      return;
    const r = await call("ui.open", { interface: "cmux.diff.renderer/1", props: { diff: s.plan.diff, layout: "unified" } }, withGesture(gesture()));
    if (!r.ok)
      setNotice(r.error.missing ? t("diffs.missing", "Opening the Diffs app needs ui.open, which this cmux does not have yet") : r.error.message);
  }
  function openPane() {
    return call("app.pane.open", { kind: "skillsHub" }, withGesture(gesture()));
  }
  var VARIANTS = ["unified", "byAgent", "byScope"];
  var DEFAULT_VARIANT = "unified";
  var [override, setOverride] = signal(null);
  var setting = (key) => cmux.app.settings()[key];
  var variant = () => {
    const v = override() ?? setting("variant");
    return VARIANTS.includes(v) ? v : DEFAULT_VARIANT;
  };
  var reviewIn = () => setting("reviewIn") === "diffs" ? "diffs" : "inline";
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
  var kindSymbol = (i) => i.kind === "skill" ? "book.closed" : "point.3.connected.trianglepath.dotted";
  function sandboxText(s) {
    switch (s) {
      case "standard":
        return t("sandbox.standard", "Standard sandbox");
      case "contained":
        return t("sandbox.contained", "Contained sandbox");
      case "complete":
        return t("sandbox.complete", "Complete sandbox");
      default:
        return t("sandbox.none", "Not sandboxed");
    }
  }
  var sandboxLine = (s) => HStack({ spacing: 6 }, [Icon(s === "none" ? "shield.slash" : "shield.lefthalf.filled").font("caption").color(s === "none" ? "warning" : "secondary"), Text(sandboxText(s)).font("caption").secondary()]);
  function sourceText(i) {
    switch (i.source.kind) {
      case "git":
        return t("source.git", "From {label}", { label: i.source.label + (i.source.ref ? `@${i.source.ref}` : "") });
      case "store":
        return t("source.store", "From the store: {label}", { label: i.source.label });
      case "agent":
        return t("source.agent", "Added by {label}", { label: i.source.label });
      default:
        return t("source.local", "Local folder");
    }
  }
  var requestChips = (requests) => HStack({ spacing: 4 }, requests.slice(0, 4).map((r) => Badge(r, requestTone(r) === "secondary" ? "secondary" : requestTone(r))));
  function subtitleOf(i) {
    if (i.kind === "skill")
      return i.description;
    return i.transport === "http" ? i.url ?? "" : i.command_label ?? "";
  }
  function onOffButton(i) {
    return Button(() => i().enabled ? t("action.turnOff", "Turn Off") : t("action.turnOn", "Turn On"), () => void toggle(i())).font("caption");
  }
  var itemMenu = (i) => () => [
    Button(i().enabled ? t("action.turnOff", "Turn Off") : t("action.turnOn", "Turn On"), () => void toggle(i())),
    Divider(),
    Button(t("action.remove", "Remove…"), () => void remove(i())).destructive()
  ];
  function chip(label, active, onTap) {
    return Text(label).font("caption").padding({ top: 3, leading: 8, bottom: 3, trailing: 8 }).background(() => active() ? "selected" : null).hoverBackground("hover").cornerRadius(10).onTap(onTap);
  }
  var patch = (p) => setFilter((f) => ({ ...f, ...p }));
  function kindChips() {
    const kinds = [
      ["all", t("filter.all", "All")],
      ["skill", t("filter.skills", "Skills")],
      ["mcp", t("filter.mcp", "MCP Servers")],
      ["off", t("filter.off", "Off")]
    ];
    return HStack({ spacing: 4 }, kinds.map(([k, label]) => chip(label, () => filter().kind === k, () => patch({ kind: k }))));
  }
  function scopeChips() {
    return HStack({ spacing: 4 }, [
      chip(t("filter.anyScope", "Everywhere and project"), () => filter().scope === "all", () => patch({ scope: "all" })),
      chip(t("filter.user", "Everywhere"), () => filter().scope === "user", () => patch({ scope: "user" })),
      () => currentRoot() ? chip(projectLabel(currentRoot()) ?? t("scope.thisProject", "this project"), () => filter().scope === "project", () => patch({ scope: "project" })) : null
    ]);
  }
  function agentChips(current, select) {
    return HStack({ spacing: 4 }, AGENTS.map((a) => chip(a.name, () => current() === a.id, () => select(a.id))));
  }
  function addFields(only = () => null) {
    return VStack({ spacing: 4 }, [
      TextField("", { placeholder: t("install.placeholder", "Install skill: git URL, owner/repo or store:id"), onSubmit: (text) => void installSkill(text, only()) }),
      TextField("", { placeholder: t("add.placeholder", "Add MCP server: name command… or name https://…"), onSubmit: (text) => void addServer(text, only()) }),
      () => notice() ? Text(notice()).font("caption").color("warning").lineLimit(2) : null
    ]);
  }
  function loadErrors() {
    return () => {
      const e = errors();
      const lines = [e.skills, e.mcp].filter((x) => !!x);
      if (!lines.length)
        return null;
      return VStack({ spacing: 2 }, lines.map((err) => Text(err.missing ? t("error.missingOp", "{op} is not available in this cmux yet.", { op: err.op }) : t("error.load", "Cannot load {op}: {message}", { op: err.op, message: err.message })).font("caption").color(err.missing ? "secondary" : "danger").lineLimit(2))).padding({ top: 4, leading: 12, bottom: 4, trailing: 12 });
    };
  }
  var agentsLine = (items) => items.map((i) => agentName(i.agent)).join(", ");
  function skillsSection() {
    return VStack({ spacing: 0 }, [
      () => {
        if (!loaded())
          return Text(t("loading", "Reading agent configuration…")).font("caption").secondary().padding(8);
        const e = errors();
        if (e.skills && e.mcp && !items().length) {
          return EmptyState({ title: e.skills.missing ? t("error.missingTitle", "Skill and MCP management is not available yet") : t("error.title", "Cannot read agent configuration"), symbol: "puzzlepiece.extension" }).onTap(() => void openPane());
        }
        const all = items();
        const skills = all.filter((i) => i.kind === "skill").length;
        const servers = all.length - skills;
        const flagged = all.filter(needsAttention);
        const pending = change().phase === "review";
        return VStack({ spacing: 0 }, [
          Row({ title: t("section.skills", "Skills"), subtitle: null, symbol: "book.closed", badge: skills || null }).onTap(() => void openPane()),
          Row({ title: t("section.mcp", "MCP Servers"), subtitle: null, symbol: "point.3.connected.trianglepath.dotted", badge: servers || null }).onTap(() => void openPane()),
          ...flagged.slice(0, 3).map((i) => Row({ title: i.name, subtitle: t("section.unsandboxed", "Runs commands without a sandbox"), symbol: kindSymbol(i), tint: "warning" }).onTap(() => void openPane())),
          pending ? Row({ title: t("section.pending", "1 change to review"), subtitle: null, symbol: "doc.badge.ellipsis", tint: "warning" }).onTap(() => void openPane()) : null
        ]);
      }
    ]);
  }
  var strip = (p) => p.replace(/^[ab]\//, "");
  function parsePatch(text) {
    const files = [];
    let file = null;
    let hunk = null;
    let oldNo = 0, newNo = 0;
    for (const line of text.split(`
`)) {
      if (line.startsWith("--- ")) {
        const old = line.slice(4).trim();
        file = { path: "", oldPath: old === "/dev/null" ? null : strip(old), hunks: [], additions: 0, deletions: 0 };
        files.push(file);
        hunk = null;
      } else if (line.startsWith("+++ ") && file) {
        const p = line.slice(4).trim();
        file.path = p === "/dev/null" ? file.oldPath ?? "" : strip(p);
      } else if (line.startsWith("@@") && file) {
        const m = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
        oldNo = m ? Number(m[1]) : 0;
        newNo = m ? Number(m[2]) : 0;
        hunk = { header: line, lines: [] };
        file.hunks.push(hunk);
      } else if (hunk && file && line.length > 0 && "+- ".includes(line[0])) {
        const kind = line[0] === "+" ? "add" : line[0] === "-" ? "del" : "context";
        const text = line.slice(1);
        if (kind === "add") {
          hunk.lines.push({ kind, text, oldLine: null, newLine: newNo++ });
          file.additions++;
        } else if (kind === "del") {
          hunk.lines.push({ kind, text, oldLine: oldNo++, newLine: null });
          file.deletions++;
        } else
          hunk.lines.push({ kind, text, oldLine: oldNo++, newLine: newNo++ });
      }
    }
    return files.filter((f) => f.path || f.oldPath);
  }
  var MAX_LINES = 40;
  var LINE_HEIGHT = 16;
  function line(l) {
    const tone = l.kind === "add" ? "success" : l.kind === "del" ? "danger" : null;
    const mark = l.kind === "add" ? "+" : l.kind === "del" ? "-" : " ";
    const row = HStack({ spacing: 6 }, [
      Text(String(l.newLine ?? l.oldLine ?? "").padStart(3, " ")).font(10).monospaced().color("tertiary"),
      Text(`${mark} ${l.text.replace(/\t/g, "  ") || " "}`).font(11).monospaced().lineLimit(1).truncation("tail")
    ]).padding({ top: 0, leading: 6, bottom: 0, trailing: 6 }).frame({ maxWidth: "infinity", height: LINE_HEIGHT });
    return tone ? ZStack([Rectangle().fill(tone).opacity(0.14).frame({ maxWidth: "infinity", height: LINE_HEIGHT }), row]) : row;
  }
  function fileBlock(path, kind, patch, compact) {
    const files = parsePatch(patch);
    const lines = files.flatMap((f) => f.hunks.flatMap((h) => h.lines)).filter((l) => !compact || l.kind !== "context");
    const adds = files.reduce((n, f) => n + f.additions, 0), dels = files.reduce((n, f) => n + f.deletions, 0);
    const kindText = kind === "create" ? t("file.create", "new file") : kind === "delete" ? t("file.delete", "deleted") : "";
    return VStack({ spacing: 2 }, [
      HStack({ spacing: 6 }, [
        Icon(kind === "create" ? "doc.badge.plus" : kind === "delete" ? "trash" : "doc.text").font("caption").secondary(),
        Text(path).font("caption").monospaced().lineLimit(1).truncation("head"),
        kindText ? Text(kindText).font("caption").secondary() : null,
        Spacer(),
        Text(`+${adds} −${dels}`).font("caption").monospaced().secondary()
      ]),
      VStack({ spacing: 0 }, lines.slice(0, MAX_LINES).map(line)).background("hover").cornerRadius(4),
      lines.length > MAX_LINES ? Text(t("review.more", "{n} more lines: open in Diffs to see all", { n: lines.length - MAX_LINES })).font("caption").secondary() : null
    ]);
  }
  function summaryBlock(plan) {
    return VStack({ spacing: 2 }, plan.files.map((f) => {
      const p = parsePatch(f.patch);
      const adds = p.reduce((n, x) => n + x.additions, 0), dels = p.reduce((n, x) => n + x.deletions, 0);
      return HStack({ spacing: 6 }, [Icon("doc.text").font("caption").secondary(), Text(f.path_label).font("caption").monospaced().lineLimit(1).truncation("head"), Spacer(), Text(`+${adds} −${dels}`).font("caption").monospaced().secondary()]);
    }));
  }
  function failureText(s) {
    switch (s.code) {
      case "diff.stale":
        return t("failed.stale", "The files changed again while you reviewed. Look at them and try once more.");
      case "scope.missing":
        return t("failed.scope", "Allow this app to change agent configuration in Settings > Apps.");
      case "operation.unsupported":
        return t("failed.unsupported", "This cmux cannot plan this change yet.");
      case "config.unparseable":
        return t("failed.unparseable", "The agent's config file has comments or errors; cmux does not rewrite it.");
      default:
        return s.message || s.code;
    }
  }
  function reviewCard(mode) {
    return () => {
      const s = change();
      if (s.phase === "idle")
        return null;
      const header = (title, tone = null) => Text(title).font("headline").color(tone).lineLimit(2);
      let body;
      if (s.phase === "planning")
        body = HStack({ spacing: 8 }, [ProgressView(null).frame({ width: 12, height: 12 }), Text(t("review.planning", "Preparing the change…")).font("callout").secondary()]);
      else if (s.phase === "applied")
        body = HStack({ spacing: 8 }, [Icon("checkmark.circle.fill").color("success"), Text(t("review.applied", "Applied")).font("callout"), Spacer(), Button(t("action.done", "Done"), () => cancel()).font("caption")]);
      else if (s.phase === "failed")
        body = VStack({ spacing: 6 }, [HStack({ spacing: 6 }, [Icon("exclamationmark.triangle.fill").color("warning"), Text(failureText(s)).font("callout").lineLimit(3)]), HStack({ spacing: 8 }, [Spacer(), Button(t("action.dismiss", "Dismiss"), () => cancel()).font("caption")])]);
      else {
        const plan = s.plan;
        const applying = s.phase === "applying";
        body = VStack({ spacing: 8 }, [
          s.phase === "review" && s.note === "stale" ? Text(t("review.stale", "An agent changed these files after the first preview. This is the new diff.")).font("caption").color("warning") : null,
          mode === "summary" ? summaryBlock(plan) : VStack({ spacing: 8 }, plan.files.map((f) => fileBlock(f.path_label, f.kind, f.patch, mode === "compact"))),
          plan.requests?.length ? requestChips(plan.requests) : null,
          plan.sandbox ? sandboxLine(plan.sandbox) : null,
          HStack({ spacing: 10 }, [
            Button(t("action.openInDiffs", "Open in Diffs"), () => void openInDiffs()).font("caption").disabled(applying),
            Spacer(),
            Button(t("action.cancel", "Cancel"), () => cancel()).font("caption").disabled(applying),
            applying ? ProgressView(null).frame({ width: 12, height: 12 }) : Button(t("action.apply", "Apply"), () => void apply()).font("caption").weight("semibold")
          ])
        ]);
      }
      return VStack({ spacing: 6 }, [header(s.intent.title), body]).padding(10).background("hover").cornerRadius(8).padding({ top: 8, leading: 12, bottom: 4, trailing: 12 });
    };
  }
  var filtered = () => items().filter((i) => matches(i, filter()));
  function header(extra) {
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 8 }, [Text(t("title", "Skills and MCP Servers")).font("headline"), Spacer()]),
      ...extra
    ]).padding({ top: 8, leading: 12, bottom: 6, trailing: 12 });
  }
  function gate() {
    if (!loaded())
      return Text(t("loading", "Reading agent configuration…")).font("callout").secondary().padding(16);
    const e = errors();
    if (e.skills && e.mcp && !items().length) {
      const err = e.skills;
      return EmptyState({
        title: err.missing ? t("error.missingTitle", "Skill and MCP management is not available yet") : t("error.title", "Cannot read agent configuration"),
        message: err.missing ? t("error.missingBoth", "This cmux does not provide skill.list and mcp_server.list.") : err.message,
        symbol: err.missing ? "puzzlepiece.extension" : "exclamationmark.triangle"
      });
    }
    if (!items().length)
      return EmptyState({ title: t("empty.title", "No skills or MCP servers yet"), message: t("empty.message", "Install a skill from a git URL or add an MCP server above."), symbol: "shippingbox" });
    return null;
  }
  var reviewMode = (fallback) => reviewIn() === "diffs" ? "summary" : fallback;
  function groupRow(g) {
    const first = () => g().items[0];
    const anyOn = () => g().items.some((i) => i.enabled);
    return Row({
      title: () => g().name,
      subtitle: () => `${agentsLine(g().items)} · ${scopeText(g().scope, g().root)}`,
      symbol: () => kindSymbol(first()),
      tint: () => g().items.some(needsAttention) ? "warning" : anyOn() ? null : "tertiary",
      badge: () => anyOn() ? null : t("badge.off", "Off"),
      selected: () => selected() === g().key
    }).onTap(() => setSelected(g().key));
  }
  function agentLine(i) {
    return HStack({ spacing: 8 }, [
      Icon(i.enabled ? "checkmark.circle.fill" : "circle").font("caption").color(i.enabled ? "success" : "tertiary"),
      Text(agentName(i.agent)).font("callout").frame({ width: 110 }),
      Text(i.path_label).font("caption").monospaced().secondary().lineLimit(1).truncation("head"),
      Spacer(),
      onOffButton(() => i)
    ]).contextMenu(itemMenu(() => i));
  }
  function detail() {
    return () => {
      const groups = groupByName(filtered());
      const g = groups.find((x) => x.key === selected()) ?? groups[0];
      if (!g)
        return null;
      const first = g.items[0];
      const requests = [...new Set(g.items.flatMap((i) => i.requests))];
      return VStack({ spacing: 6 }, [
        HStack({ spacing: 6 }, [Icon(kindSymbol(first)).secondary(), Text(g.name).font("headline"), Text(first.kind === "skill" ? t("kind.skill", "Skill") : t("kind.mcp", "MCP server")).font("caption").secondary()]),
        Text(subtitleOf(first)).font("callout").secondary().lineLimit(3),
        Text(sourceText(first)).font("caption").secondary(),
        requests.length ? requestChips(requests) : null,
        sandboxLine(first.sandbox),
        first.kind === "mcp" && first.env_keys.length ? Text(t("detail.env", "Secrets it reads: {keys}", { keys: first.env_keys.join(", ") })).font("caption").secondary().lineLimit(2) : null,
        Divider(),
        VStack({ spacing: 4 }, g.items.map(agentLine))
      ]).padding(12);
    };
  }
  function unifiedView() {
    return VStack({ spacing: 0 }, [
      header([kindChips(), scopeChips(), addFields()]),
      reviewCard(reviewMode("full")),
      loadErrors(),
      Divider(),
      () => gate() ?? VStack({ spacing: 0 }, [
        ForEach({ items: () => groupByName(filtered()), key: (g) => g.key }, (g) => groupRow(g)),
        () => groupByName(filtered()).length ? null : Text(t("filter.none", "Nothing matches these filters")).font("callout").secondary().padding(12),
        Divider(),
        detail()
      ])
    ]);
  }
  function agentItemRow(i) {
    return HStack({ spacing: 10 }, [
      Icon(() => kindSymbol(i())).color(() => i().enabled ? needsAttention(i()) ? "warning" : "secondary" : "tertiary"),
      VStack({ spacing: 2 }, [
        HStack({ spacing: 6 }, [Text(() => i().name).font("body").weight("medium").color(() => i().enabled ? null : "secondary"), Text(() => scopeText(i().scope, i().root)).font("caption").secondary()]),
        Text(() => subtitleOf(i())).font("caption").secondary().lineLimit(1).truncation("tail"),
        HStack({ spacing: 6 }, [Text(() => sourceText(i())).font("caption").color("tertiary"), Text("·").font("caption").color("tertiary"), Text(() => sandboxLabel(i())).font("caption").color(() => i().sandbox === "none" ? "warning" : "tertiary")])
      ]).frame({ maxWidth: "infinity" }),
      onOffButton(i)
    ]).padding({ top: 6, leading: 12, bottom: 6, trailing: 12 }).contextMenu(itemMenu(i));
  }
  var sandboxLabel = (i) => sandboxText(i.sandbox);
  function section(title, list) {
    return () => {
      if (!list().length)
        return null;
      return VStack({ spacing: 0 }, [
        Text(title).font("caption").weight("semibold").secondary().padding({ top: 8, leading: 12, bottom: 2, trailing: 12 }),
        ForEach({ items: list, key: (i) => i.id }, (i) => agentItemRow(i))
      ]);
    };
  }
  var [shownAgent, setShownAgent] = signal(AGENTS[0].id);
  function byAgentView() {
    const agentItems = () => items().filter((i) => matches(i, { ...filter(), agent: shownAgent(), kind: "all" }));
    return VStack({ spacing: 0 }, [
      header([agentChips(shownAgent, setShownAgent), addFields(() => [shownAgent()])]),
      reviewCard(reviewMode("summary")),
      loadErrors(),
      Divider(),
      () => gate() ?? VStack({ spacing: 0 }, [
        section(t("section.skills", "Skills"), () => agentItems().filter((i) => i.kind === "skill")),
        section(t("section.mcp", "MCP Servers"), () => agentItems().filter((i) => i.kind === "mcp")),
        () => agentItems().length ? null : Text(t("agent.none", "{agent} has no skills or MCP servers here", { agent: agentName(shownAgent()) })).font("callout").secondary().padding(12)
      ])
    ]);
  }
  function scopeRow(g) {
    const tone = () => worstTone(g().items.flatMap((i) => i.requests));
    return HStack({ spacing: 10 }, [
      Icon(() => kindSymbol(g())).secondary(),
      VStack({ spacing: 2 }, [
        Text(() => g().name).font("body").weight("medium"),
        Text(() => g().items.map((i) => `${agentName(i.agent)}${i.enabled ? "" : ` (${t("badge.off", "Off")})`}`).join(", ")).font("caption").secondary().lineLimit(1)
      ]).frame({ maxWidth: "infinity" }),
      () => tone() === "secondary" ? null : Badge(tone() === "danger" ? t("badge.runs", "Runs commands") : t("badge.network", "Network or writes"), tone())
    ]).padding({ top: 6, leading: 12, bottom: 6, trailing: 12 }).contextMenu(() => [
      ...g().items.map((i) => Button(i.enabled ? t("menu.offFor", "Turn Off for {agent}", { agent: agentName(i.agent) }) : t("menu.onFor", "Turn On for {agent}", { agent: agentName(i.agent) }), () => void toggle(i))),
      Divider(),
      ...g().items.map((i) => Button(t("menu.removeFrom", "Remove from {agent}…", { agent: agentName(i.agent) }), () => void remove(i)).destructive())
    ]);
  }
  function scopeSection(title, scope) {
    const groups = () => groupByName(filtered().filter((i) => i.scope === scope));
    return () => {
      if (!groups().length)
        return null;
      return VStack({ spacing: 0 }, [
        HStack({ spacing: 6 }, [Icon(scope === "user" ? "person.crop.circle" : "folder").font("caption").secondary(), Text(title).font("callout").weight("semibold"), Spacer(), Text(String(groups().length)).font("caption").secondary()]).padding({
          top: 10,
          leading: 12,
          bottom: 4,
          trailing: 12
        }),
        ForEach({ items: groups, key: (g) => g.key }, (g) => scopeRow(g))
      ]);
    };
  }
  function byScopeView() {
    return VStack({ spacing: 0 }, [
      header([kindChips(), addFields()]),
      reviewCard(reviewMode("compact")),
      loadErrors(),
      Divider(),
      () => gate() ?? VStack({ spacing: 0 }, [
        scopeSection(() => t("scope.userTitle", "Everywhere"), "user"),
        Divider(),
        scopeSection(() => t("scope.projectTitle", "This project: {project}", { project: projectLabel(currentRoot()) ?? "" }), "project")
      ])
    ]);
  }
  function renderSection(ctx = {}) {
    setLanguage(detectLanguage(ctx));
    start();
    return skillsSection();
  }
  function renderPane(ctx = {}) {
    setLanguage(detectLanguage(ctx));
    start();
    return VStack({ spacing: 0 }, [
      () => {
        switch (variant()) {
          case "byAgent":
            return byAgentView();
          case "byScope":
            return byScopeView();
          default:
            return unifiedView();
        }
      }
    ]);
  }
  async function openSkills() {
    await openPane();
    return {};
  }
  async function reload() {
    start();
    await load();
    return {};
  }
  var cycleVariant2 = cycleVariant;
  globalThis.__cmuxAppExports = { ...exports_main };
})();
