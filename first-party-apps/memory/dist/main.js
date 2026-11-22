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
    openMemory: () => openMemory,
    reload: () => reload,
    renderPane: () => renderPane,
    renderSection: () => renderSection
  });
  var MAX_CELLS = 4000000;
  var splitLines = (text) => text === "" ? [] : text.replace(/\n$/, "").split(`
`);
  function diffLines(before, after) {
    const a = splitLines(before), b = splitLines(after);
    const n = a.length, m = b.length;
    if (n * m > MAX_CELLS) {
      return [...a.map((text, i) => ({ kind: "del", text, oldLine: i + 1, newLine: null })), ...b.map((text, j) => ({ kind: "add", text, oldLine: null, newLine: j + 1 }))];
    }
    const lcs = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
    for (let i = n - 1;i >= 0; i--)
      for (let j = m - 1;j >= 0; j--)
        lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    const out = [];
    let i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && a[i] === b[j])
        out.push({ kind: "context", text: a[i], oldLine: ++i, newLine: ++j });
      else if (i < n && (j >= m || lcs[i + 1][j] >= lcs[i][j + 1]))
        out.push({ kind: "del", text: a[i], oldLine: ++i, newLine: null });
      else
        out.push({ kind: "add", text: b[j], oldLine: null, newLine: ++j });
    }
    return out;
  }
  var BULLET = /^\s*(?:[-*+]|\d+[.)])\s+/;
  var HEADING = /^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$/;
  var FENCE = /^\s*(```|~~~)/;
  function parseEntries(text) {
    const lines = text.replace(/\n$/, "").split(`
`);
    const out = [];
    let section = null;
    let cur = null;
    let inFence = false;
    let frontMatter = lines[0]?.trim() === "---";
    const close = (i) => {
      if (cur) {
        cur.end = i + 1;
        out.push(cur);
        cur = null;
      }
    };
    lines.forEach((line, idx) => {
      const n = idx + 1;
      if (frontMatter) {
        if (idx > 0 && line.trim() === "---")
          frontMatter = false;
        return;
      }
      if (FENCE.test(line)) {
        inFence = !inFence;
        if (!cur)
          cur = { start: n, end: n + 1, text: line, section, bullet: false };
        else
          cur.text += `
${line}`;
        return;
      }
      if (inFence) {
        if (cur)
          cur.text += `
${line}`;
        return;
      }
      const h = HEADING.exec(line);
      if (h) {
        close(n - 1);
        section = h[1];
        return;
      }
      if (line.trim() === "") {
        close(n - 1);
        return;
      }
      if (BULLET.test(line)) {
        close(n - 1);
        cur = { start: n, end: n + 1, text: line.replace(BULLET, ""), section, bullet: true };
        return;
      }
      if (cur) {
        cur.text += `
${line.trim()}`;
        cur.end = n + 1;
      } else
        cur = { start: n, end: n + 1, text: line.trim(), section, bullet: false };
    });
    close(lines.length);
    return out;
  }
  var clean = (s) => s.replace(/\s+/g, " ").trim();
  function applyIntent(text, intent) {
    const lines = splitLines(text);
    const trailing = text === "" || text.endsWith(`
`) ? `
` : "";
    const join = (ls) => ls.length ? ls.join(`
`) + trailing : "";
    switch (intent.op) {
      case "trash":
        return { ok: true, text: "" };
      case "append": {
        const body = clean(intent.text);
        if (!body)
          return { ok: false, reason: "empty" };
        const line = `- ${body}`;
        if (intent.section) {
          const entries = parseEntries(text).filter((e) => e.section === intent.section);
          const last = entries[entries.length - 1];
          if (last)
            return { ok: true, text: join([...lines.slice(0, last.end - 1), line, ...lines.slice(last.end - 1)]) };
        }
        const out = [...lines];
        while (out.length && out[out.length - 1].trim() === "")
          out.pop();
        const lastLine = out[out.length - 1] ?? "";
        if (out.length && !/^\s*(?:[-*+]|\d+[.)])\s+/.test(lastLine))
          out.push("");
        out.push(line);
        return { ok: true, text: out.join(`
`) + `
` };
      }
      case "remove":
      case "replace": {
        const target = clean(intent.entry);
        const e = parseEntries(text).find((x) => clean(x.text) === target);
        if (!e)
          return { ok: false, reason: "gone" };
        if (intent.op === "remove")
          return { ok: true, text: join([...lines.slice(0, e.start - 1), ...lines.slice(e.end - 1)]) };
        const body = clean(intent.text);
        if (!body)
          return { ok: false, reason: "empty" };
        const prefix = /^(\s*(?:[-*+]|\d+[.)])\s+)/.exec(lines[e.start - 1])?.[1] ?? "";
        return { ok: true, text: join([...lines.slice(0, e.start - 1), `${prefix}${body}`, ...lines.slice(e.end - 1)]) };
      }
    }
  }
  function toEdits(before, after) {
    const out = [];
    let cur = null;
    let oldNo = 1;
    for (const l of diffLines(before, after)) {
      if (l.kind === "context") {
        if (cur)
          out.push(cur);
        cur = null;
        oldNo++;
        continue;
      }
      cur ??= { start: oldNo, end: oldNo, lines: [] };
      if (l.kind === "del") {
        cur.end++;
        oldNo++;
      } else
        cur.lines.push(l.text);
    }
    if (cur)
      out.push(cur);
    return out;
  }
  // first-party-apps/memory/strings/en.json
  var en_default = {
    "action.cancel": "Cancel",
    "action.deleteLine": "Delete Line…",
    "action.dismiss": "Dismiss",
    "action.done": "Done",
    "action.edit": "Edit…",
    "action.moveToTrash": "Move to Trash",
    "action.openFile": "Show File",
    "action.openInDiffs": "Open in Diffs",
    "action.save": "Save",
    "action.trash": "Move to Trash…",
    "add.placeholder": "Add a line to this file…",
    "diffs.missing": "Opening in Diffs needs document.propose and ui.open, which this cmux does not have yet",
    "doc.changed": "An agent changed this file while you reviewed. Save checks your edit against the newest text.",
    "doc.empty": "This file is empty",
    "doc.more": "{n} more entries",
    "edit.placeholder": "Change this line",
    "empty.message": "CLAUDE.md, AGENTS.md and agent memory folders show up here.",
    "empty.title": "No agent memory files",
    "error.missingOp": "This cmux does not provide {op}.",
    "error.missingTitle": "Agent memory is not available yet",
    "error.open": "Cannot open this file",
    "error.roots": "Cannot find agent memory",
    "failed.empty": "Type some text first.",
    "failed.scope": "Allow this app to change memory files in Settings > Apps.",
    "failed.stale": "The file changed again while you reviewed. Look at it and try once more.",
    "failed.unsupported": "This cmux cannot write memory files yet.",
    "intent.append": "Add a line to {file}",
    "intent.remove": "Delete a line from {file}",
    "intent.replace": "Change a line in {file}",
    "intent.trash": "Move {file} to the Trash",
    "kind.instructions": "Instructions",
    "kind.local": "Personal, not shared",
    "kind.memoryIndex": "Memory index",
    "kind.memoryTopic": "Memory",
    "kind.override": "Override",
    "kind.rules": "Rules",
    loading: "Looking for agent memory…",
    "loading.file": "Opening…",
    "machine.this": "This Mac",
    "review.gone": "That line is no longer in the file; an agent changed it.",
    "review.more": "{n} more lines",
    "review.preparing": "Reading the file…",
    "review.rebased": "An agent changed this file after the first preview. This is your edit on the new text.",
    "review.saved": "Saved",
    "review.trashed": "Moved to the Trash",
    "root.project": "{project} · {machine}",
    "root.user": "{machine} · everywhere",
    "search.none": "No memory matches “{q}”",
    "search.placeholder": "Search memory",
    "search.where": "{file}, line {line}",
    "section.more": "{n} more",
    title: "Agent Memory"
  };
  // first-party-apps/memory/strings/ja.json
  var ja_default = {
    "action.cancel": "キャンセル",
    "action.deleteLine": "行を削除…",
    "action.dismiss": "閉じる",
    "action.done": "完了",
    "action.edit": "編集…",
    "action.moveToTrash": "ゴミ箱に入れる",
    "action.openFile": "ファイルを表示",
    "action.openInDiffs": "差分アプリで開く",
    "action.save": "保存",
    "action.trash": "ゴミ箱に入れる…",
    "add.placeholder": "このファイルに行を追加…",
    "diffs.missing": "差分アプリで開くにはdocument.proposeとui.openが必要ですが、このcmuxにはまだありません",
    "doc.changed": "確認中にエージェントがこのファイルを変更しました。保存時に最新の内容で編集を確認します。",
    "doc.empty": "このファイルは空です",
    "doc.more": "ほかに{n}件",
    "edit.placeholder": "この行を変更",
    "empty.message": "CLAUDE.md、AGENTS.md、エージェントのメモリフォルダがここに表示されます。",
    "empty.title": "エージェントのメモリファイルはありません",
    "error.missingOp": "このcmuxは{op}を提供していません。",
    "error.missingTitle": "エージェントメモリはまだ使えません",
    "error.open": "このファイルを開けません",
    "error.roots": "エージェントメモリが見つかりません",
    "failed.empty": "先にテキストを入力してください。",
    "failed.scope": "設定 > アプリでこのアプリにメモリファイルの変更を許可してください。",
    "failed.stale": "確認中にファイルがまた変更されました。内容を見てもう一度試してください。",
    "failed.unsupported": "このcmuxはまだメモリファイルに書き込めません。",
    "intent.append": "{file}に行を追加",
    "intent.remove": "{file}から行を削除",
    "intent.replace": "{file}の行を変更",
    "intent.trash": "{file}をゴミ箱に入れる",
    "kind.instructions": "指示",
    "kind.local": "個人用（共有しない）",
    "kind.memoryIndex": "メモリ索引",
    "kind.memoryTopic": "メモリ",
    "kind.override": "上書き",
    "kind.rules": "ルール",
    loading: "エージェントメモリを探しています…",
    "loading.file": "開いています…",
    "machine.this": "このMac",
    "review.gone": "その行はもうファイルにありません。エージェントが変更しました。",
    "review.more": "ほかに{n}行",
    "review.preparing": "ファイルを読み込み中…",
    "review.rebased": "最初のプレビューの後にエージェントがこのファイルを変更しました。これは新しい内容に対するあなたの編集です。",
    "review.saved": "保存しました",
    "review.trashed": "ゴミ箱に入れました",
    "root.project": "{project} · {machine}",
    "root.user": "{machine} · 全体",
    "search.none": "「{q}」に一致するメモリはありません",
    "search.placeholder": "メモリを検索",
    "search.where": "{file}、{line}行目",
    "section.more": "ほかに{n}件",
    title: "エージェントメモリ"
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
  var AGENTS_MD_READERS = ["codex", "opencode", "pi", "amp", "cursor"];
  var RULES = [
    { root: "user", pattern: /^\.claude\/CLAUDE\.md$/, agents: ["claude"], kind: "instructions" },
    { root: "user", pattern: /^\.claude\/projects\/[^/]+\/memory\/MEMORY\.md$/, agents: ["claude"], kind: "memoryIndex" },
    { root: "user", pattern: /^\.claude\/projects\/[^/]+\/memory\/[^/]+\.md$/, agents: ["claude"], kind: "memoryTopic" },
    { root: "user", pattern: /^\.codex\/AGENTS\.md$/, agents: ["codex"], kind: "instructions" },
    { root: "user", pattern: /^\.codex\/AGENTS\.override\.md$/, agents: ["codex"], kind: "override" },
    { root: "user", pattern: /^\.config\/opencode\/AGENTS\.md$/, agents: ["opencode"], kind: "instructions" },
    { root: "user", pattern: /^\.gemini\/GEMINI\.md$/, agents: ["gemini"], kind: "instructions" },
    { root: "user", pattern: /^\.pi\/agent\/AGENTS\.md$/, agents: ["pi"], kind: "instructions" },
    { root: "project", pattern: /^(?:.+\/)?CLAUDE\.md$/, agents: ["claude"], kind: "instructions" },
    { root: "project", pattern: /^\.claude\/CLAUDE\.md$/, agents: ["claude"], kind: "instructions" },
    { root: "project", pattern: /^(?:.+\/)?CLAUDE\.local\.md$/, agents: ["claude"], kind: "local" },
    { root: "project", pattern: /^(?:.+\/)?AGENTS\.override\.md$/, agents: ["codex"], kind: "override" },
    { root: "project", pattern: /^(?:.+\/)?AGENTS\.md$/, agents: AGENTS_MD_READERS, kind: "instructions" },
    { root: "project", pattern: /^(?:.+\/)?GEMINI\.md$/, agents: ["gemini"], kind: "instructions" },
    { root: "project", pattern: /^\.github\/copilot-instructions\.md$/, agents: ["copilot"], kind: "instructions" },
    { root: "project", pattern: /^\.cursor\/rules\/[^/]+\.mdc?$/, agents: ["cursor"], kind: "rules" }
  ];
  function classify(root, path) {
    if (path.split("/").some((p) => p === ".." || p === ""))
      return null;
    for (const r of RULES) {
      if (r.root !== root || !r.pattern.test(path))
        continue;
      const slug = /^\.claude\/projects\/([^/]+)\/memory\//.exec(path)?.[1];
      return { agents: r.agents, kind: r.kind, ...slug ? { slug } : {} };
    }
    return null;
  }
  var depthOf = (path) => path.split("/").length - 1;
  var AGENT_NAMES = {
    claude: "Claude Code",
    codex: "Codex",
    opencode: "OpenCode",
    pi: "Pi",
    amp: "Amp",
    cursor: "Cursor",
    gemini: "Gemini CLI",
    copilot: "Copilot"
  };
  var agentName = (id) => AGENT_NAMES[id] ?? id;
  function agentsLabel(agents, max = 2) {
    const names = agents.map(agentName);
    return names.length <= max ? names.join(", ") : `${names.slice(0, max).join(", ")} +${names.length - max}`;
  }
  function fileRank(root, path, c) {
    const kindRank = { instructions: 0, override: 1, local: 2, memoryIndex: 3, memoryTopic: 4, rules: 5 };
    return (root === "project" ? 0 : 100) + depthOf(path) * 10 + kindRank[c.kind];
  }
  var MAX_REBASES = 1;
  var base = (s) => ({ file: s.file, intent: s.intent, title: s.title });
  function reduceReview(s, ev) {
    switch (ev.type) {
      case "ask":
        return s.phase === "applying" ? s : { phase: "preparing", file: ev.file, intent: ev.intent, title: ev.title, rebases: 0 };
      case "prepared":
        return s.phase === "preparing" ? { ...base(s), ...ev.prepared, phase: "review", rebases: s.rebases, note: s.rebases > 0 ? "rebased" : null } : s;
      case "apply":
        return s.phase === "review" ? { ...base(s), doc: s.doc, revision: s.revision, before: s.before, after: s.after, phase: "applying", rebases: s.rebases } : s;
      case "applied":
        return s.phase === "applying" ? { ...base(s), phase: "applied" } : s;
      case "stale":
        if (s.phase !== "applying")
          return s;
        return s.rebases >= MAX_REBASES ? { ...base(s), phase: "failed", code: "document.stale", message: "" } : { ...base(s), phase: "preparing", rebases: s.rebases + 1 };
      case "gone":
        return s.phase === "preparing" ? { ...base(s), phase: "gone" } : s;
      case "error":
        return s.phase === "preparing" || s.phase === "applying" ? { ...base(s), phase: "failed", code: ev.code, message: ev.message } : s;
      case "cancel":
        return s.phase === "applying" ? s : { phase: "idle" };
    }
  }
  var [roots, setRoots] = signal([]);
  var [files, setFiles] = signal({});
  var [errors, setErrors] = signal({});
  var [rootsError, setRootsError] = signal(null);
  var [loaded, setLoaded] = signal(false);
  var [selected, setSelected] = signal(null);
  var [open, setOpen] = signal(null);
  var [openError, setOpenError] = signal(null);
  var [query, setQuery] = signal("");
  var [hits, setHits] = signal(null);
  var [review, setReview] = signal({ phase: "idle" });
  var [texts, setTexts] = signal({});
  var dispatchReview = (ev) => setReview((s) => reduceReview(s, ev));
  var fileKey = (root, path) => `${root}\x00${path}`;
  var allFiles = () => roots().flatMap((r) => files()[r.root] ?? []);
  var rootOf = (id) => roots().find((r) => r.root === id) ?? null;
  var started = false;
  function start() {
    if (started)
      return;
    started = true;
    load();
    cmux.events.on("memory.watch", (p) => {
      const root = p?.root;
      if (typeof root === "string")
        loadFiles(root);
    });
    cmux.events.on("document.watch", (p) => {
      const m = p;
      const cur = open();
      if (!cur || m?.doc !== cur.doc || m.revision === cur.revision)
        return;
      if (review().phase === "idle")
        select(cur.root, cur.path);
      else
        setOpen({ ...cur, changed: true });
    });
  }
  async function load() {
    const ms = await call("machine.list");
    const machines = ms.ok ? ms.value.filter((m) => m.status !== "stopped") : [{ id: "", name: "", status: "running" }];
    const all = [];
    let firstError = null;
    for (const m of machines) {
      const r = await call("memory.roots", m.id ? { machine: m.id } : {});
      if (r.ok)
        all.push(...(r.value.roots ?? []).map((x) => ({ ...x, machine: x.machine ?? m.id, machine_label: x.machine_label ?? (m.name || null) })));
      else
        firstError ??= r.error;
    }
    setRoots(all);
    setRootsError(all.length ? null : firstError);
    for (const r of all)
      await loadFiles(r.root);
    if (!selected()) {
      const first = allFiles()[0];
      if (first)
        await select(first.root, first.path);
    }
    setLoaded(true);
  }
  async function loadFiles(root) {
    const r = await call("memory.list", { root });
    const kind = rootOf(root)?.kind ?? "project";
    if (!r.ok) {
      setErrors((e) => ({ ...e, [root]: r.error }));
      return;
    }
    const list = (r.value.files ?? []).flatMap((f) => {
      const c = classify(kind, f.path);
      return c ? [{ ...f, root, c }] : [];
    });
    list.sort((a, b) => fileRank(kind, a.path, a.c) - fileRank(kind, b.path, b.c) || a.path.localeCompare(b.path));
    setFiles((all) => ({ ...all, [root]: list }));
    setErrors((e) => {
      const { [root]: _, ...rest } = e;
      return rest;
    });
  }
  async function readDoc(root, path) {
    const o = await call("document.open", { root, path });
    if (!o.ok)
      return o;
    const r = await call("document.read", { doc: o.value.doc });
    if (!r.ok)
      return r;
    return { ok: true, doc: { root, path, doc: o.value.doc, revision: r.value.revision ?? o.value.revision, text: r.value.text ?? "", changed: false } };
  }
  async function select(root, path) {
    setSelected({ root, path });
    const r = await readDoc(root, path);
    const sel = selected();
    if (!sel || sel.root !== root || sel.path !== path)
      return;
    if (r.ok) {
      setOpen(r.doc);
      setOpenError(null);
      setTexts((all) => ({ ...all, [fileKey(root, path)]: r.doc.text }));
    } else {
      setOpen(null);
      setOpenError(r.error);
    }
  }
  async function loadAllTexts(limit = 30) {
    for (const f of allFiles().slice(0, limit)) {
      if (texts()[fileKey(f.root, f.path)] !== undefined)
        continue;
      const r = await readDoc(f.root, f.path);
      if (r.ok)
        setTexts((all) => ({ ...all, [fileKey(f.root, f.path)]: r.doc.text }));
    }
  }
  function rememberText(root, path, text, revision) {
    setTexts((all) => ({ ...all, [fileKey(root, path)]: text }));
    const cur = open();
    if (cur && cur.root === root && cur.path === path)
      setOpen({ ...cur, text, revision, changed: false });
  }
  async function search(q) {
    setQuery(q);
    if (!q.trim()) {
      setHits(null);
      return;
    }
    const r = await call("memory.search", { roots: roots().map((x) => x.root), query: q.trim(), limit: 50 });
    if (r.ok)
      setHits(r.value.hits ?? []);
    else {
      const lower = q.toLowerCase();
      const local = [];
      for (const f of allFiles()) {
        if (f.path.toLowerCase().includes(lower))
          local.push({ root: f.root, path: f.path, line: 0, text: f.path });
        const text = texts()[fileKey(f.root, f.path)];
        text?.split(`
`).forEach((l, i) => {
          if (l.toLowerCase().includes(lower))
            local.push({ root: f.root, path: f.path, line: i + 1, text: l.trim() });
        });
      }
      setHits(local);
    }
  }
  async function current(file, fresh) {
    const doc = open();
    if (!fresh && doc && doc.root === file.root && doc.path === file.path && !doc.changed)
      return { ok: true, doc };
    return readDoc(file.root, file.path);
  }
  async function prepare(file, intent, fresh = false) {
    const r = await current(file, fresh);
    if (!r.ok)
      return dispatchReview({ type: "error", code: r.error.code, message: r.error.message });
    if (fresh)
      rememberText(file.root, file.path, r.doc.text, r.doc.revision);
    const next = applyIntent(r.doc.text, intent);
    if (!next.ok)
      return dispatchReview(next.reason === "gone" ? { type: "gone" } : { type: "error", code: "memory.empty", message: "" });
    dispatchReview({ type: "prepared", prepared: { doc: r.doc.doc, revision: r.doc.revision, before: r.doc.text, after: next.text } });
  }
  function propose(file, intent, title) {
    dispatchReview({ type: "ask", file, intent, title });
    return prepare(file, intent);
  }
  var appendTo = (file, text, section = null) => text.trim() ? propose(file, { op: "append", text, section }, t("intent.append", "Add a line to {file}", { file: file.label })) : Promise.resolve();
  var removeEntry = (file, entry) => propose(file, { op: "remove", entry }, t("intent.remove", "Delete a line from {file}", { file: file.label }));
  var replaceEntry = (file, entry, text) => propose(file, { op: "replace", entry, text }, t("intent.replace", "Change a line in {file}", { file: file.label }));
  var trashFile = (file) => propose(file, { op: "trash" }, t("intent.trash", "Move {file} to the Trash", { file: file.label }));
  async function apply() {
    const s = review();
    if (s.phase !== "review")
      return;
    const token = gesture();
    dispatchReview({ type: "apply" });
    if (s.intent.op === "trash") {
      const r = await call("fs.trash", { root: s.file.root, paths: [s.file.path], expected_revisions: { [s.file.path]: s.revision } }, withGesture(token));
      if (r.ok) {
        dispatchReview({ type: "applied" });
        await loadFiles(s.file.root);
        const sel = selected();
        const next = allFiles()[0];
        if (sel && sel.root === s.file.root && sel.path === s.file.path && next)
          await select(next.root, next.path);
      } else if (r.error.code === "document.stale")
        await rebase();
      else
        dispatchReview({ type: "error", code: r.error.code, message: r.error.message });
      return;
    }
    const r = await call("document.edit", { doc: s.doc, base_revision: s.revision, edits: toEdits(s.before, s.after) }, withGesture(token));
    if (r.ok) {
      dispatchReview({ type: "applied" });
      rememberText(s.file.root, s.file.path, s.after, r.value.revision);
      return;
    }
    if (r.error.code === "document.stale")
      await rebase();
    else
      dispatchReview({ type: "error", code: r.error.code, message: r.error.message });
  }
  async function rebase() {
    dispatchReview({ type: "stale" });
    const s = review();
    if (s.phase === "preparing")
      await prepare(s.file, s.intent, true);
  }
  function cancel() {
    const s = review();
    if (s.phase !== "applying")
      dispatchReview({ type: "cancel" });
  }
  async function openInDiffs() {
    const s = review();
    if (s.phase !== "review" || s.intent.op === "trash")
      return null;
    const token = gesture();
    const d = await call("document.propose", { doc: s.doc, base_revision: s.revision, edits: toEdits(s.before, s.after) }, withGesture(token));
    if (!d.ok)
      return d.error.missing ? t("diffs.missing", "Opening in Diffs needs document.propose and ui.open, which this cmux does not have yet") : d.error.message;
    const o = await call("ui.open", { interface: "cmux.diff.renderer/1", props: { diff: d.value.diff, layout: "unified" } }, withGesture(token));
    return o.ok ? null : o.error.message;
  }
  function openPane(token = gesture()) {
    return call("app.pane.open", { kind: "memoryHub" }, withGesture(token));
  }
  var VARIANTS = ["files", "entries", "split"];
  var DEFAULT_VARIANT = "files";
  var [override, setOverride] = signal(null);
  var setting = (key) => cmux.app.settings()[key];
  var variant = () => {
    const v = override() ?? setting("variant");
    return VARIANTS.includes(v) ? v : DEFAULT_VARIANT;
  };
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
  function kindText(k) {
    switch (k) {
      case "instructions":
        return t("kind.instructions", "Instructions");
      case "local":
        return t("kind.local", "Personal, not shared");
      case "override":
        return t("kind.override", "Override");
      case "memoryIndex":
        return t("kind.memoryIndex", "Memory index");
      case "memoryTopic":
        return t("kind.memoryTopic", "Memory");
      case "rules":
        return t("kind.rules", "Rules");
    }
  }
  var displayPath = (f) => rootOf(f.root)?.kind === "user" ? `~/${f.path}` : f.path;
  var fileSubtitle = (f) => [agentsLabel(f.c.agents), kindText(f.c.kind), f.c.slug ? f.project_label ?? f.c.slug : null].filter(Boolean).join(" · ");
  var refOf = (f) => ({ root: f.root, path: f.path, label: displayPath(f) });
  var isSelected = (f) => selected()?.root === f.root && selected()?.path === f.path;
  function fileSymbol(k) {
    return k === "memoryIndex" || k === "memoryTopic" ? "brain" : k === "rules" ? "list.bullet.rectangle" : "doc.text";
  }
  function fileRow(f) {
    return Row({
      title: () => displayPath(f()),
      subtitle: () => fileSubtitle(f()),
      symbol: () => fileSymbol(f().c.kind),
      selected: () => isSelected(f())
    }).onTap(() => void select(f().root, f().path));
  }
  var [editing, setEditing] = signal(null);
  function entryView(file, e) {
    if (editing() === e.text) {
      return TextField(e.text, {
        placeholder: t("edit.placeholder", "Change this line"),
        autofocus: true,
        onSubmit: (text) => {
          setEditing(null);
          replaceEntry(file, e.text, text);
        },
        onCancel: () => setEditing(null)
      });
    }
    const menu = () => [Button(t("action.edit", "Edit…"), () => setEditing(e.text)), Button(t("action.deleteLine", "Delete Line…"), () => void removeEntry(file, e.text)).destructive()];
    return HStack({ spacing: 6 }, [
      Text(e.bullet ? "•" : " ").font("callout").secondary(),
      Text(e.text).font("callout").lineLimit(4).frame({ maxWidth: "infinity" }).contextMenu(menu),
      Text(String(e.start)).font(10).monospaced().color("tertiary")
    ]).padding({ top: 2, leading: 0, bottom: 2, trailing: 0 });
  }
  function documentView(maxEntries = 60) {
    return () => {
      const err = openError();
      if (err)
        return errorState(err, t("error.open", "Cannot open this file"));
      const doc = open();
      if (!doc)
        return selected() ? Text(t("loading.file", "Opening…")).font("callout").secondary().padding(12) : null;
      const file = refOf(doc);
      const entries = parseEntries(doc.text);
      const out = [];
      let section;
      for (const e of entries.slice(0, maxEntries)) {
        if (e.section !== section) {
          section = e.section;
          if (section)
            out.push(Text(section).font("caption").weight("semibold").secondary().padding({ top: 6, leading: 0, bottom: 0, trailing: 0 }));
        }
        out.push(entryView(file, e));
      }
      return VStack({ spacing: 4 }, [
        HStack({ spacing: 8 }, [
          Text(file.label).font("headline").monospaced().lineLimit(1).truncation("head"),
          Spacer(),
          Button(t("action.trash", "Move to Trash…"), () => void trashFile(file)).font("caption")
        ]),
        doc.changed ? Text(t("doc.changed", "An agent changed this file while you reviewed. Save checks your edit against the newest text.")).font("caption").color("warning") : null,
        entries.length ? VStack({ spacing: 2 }, out) : Text(t("doc.empty", "This file is empty")).font("callout").secondary(),
        entries.length > maxEntries ? Text(t("doc.more", "{n} more entries", { n: entries.length - maxEntries })).font("caption").secondary() : null,
        TextField("", { placeholder: t("add.placeholder", "Add a line to this file…"), onSubmit: (text) => void appendTo(file, text) })
      ]).padding(12);
    };
  }
  var LINE_HEIGHT = 16;
  var CONTEXT = 2;
  var MAX_LINES = 40;
  function previewLines(before, after) {
    const lines = diffLines(before, after);
    const keep = new Set;
    lines.forEach((l, i) => {
      if (l.kind !== "context")
        for (let k = i - CONTEXT;k <= i + CONTEXT; k++)
          keep.add(k);
    });
    const out = [];
    let last = -1;
    lines.forEach((l, i) => {
      if (!keep.has(i))
        return;
      if (last >= 0 && i > last + 1)
        out.push(null);
      out.push(l);
      last = i;
    });
    return out;
  }
  function diffLine(l) {
    if (!l)
      return Text("…").font(11).monospaced().color("tertiary").padding({ top: 0, leading: 6, bottom: 0, trailing: 6 });
    const tone = l.kind === "add" ? "success" : l.kind === "del" ? "danger" : null;
    const row = HStack({ spacing: 6 }, [
      Text(String(l.newLine ?? l.oldLine ?? "").padStart(3, " ")).font(10).monospaced().color("tertiary"),
      Text(`${l.kind === "add" ? "+" : l.kind === "del" ? "-" : " "} ${l.text || " "}`).font(11).monospaced().lineLimit(1).truncation("tail")
    ]).padding({ top: 0, leading: 6, bottom: 0, trailing: 6 }).frame({ maxWidth: "infinity", height: LINE_HEIGHT });
    return tone ? ZStack([Rectangle().fill(tone).opacity(0.14).frame({ maxWidth: "infinity", height: LINE_HEIGHT }), row]) : row;
  }
  var [diffsNotice, setDiffsNotice] = signal(null);
  function failure(code, message) {
    if (code === "document.stale")
      return t("failed.stale", "The file changed again while you reviewed. Look at it and try once more.");
    if (code === "scope.missing")
      return t("failed.scope", "Allow this app to change memory files in Settings > Apps.");
    if (code === "operation.unsupported")
      return t("failed.unsupported", "This cmux cannot write memory files yet.");
    if (code === "memory.empty")
      return t("failed.empty", "Type some text first.");
    return message || code;
  }
  function reviewCard() {
    return () => {
      const s = review();
      if (s.phase === "idle")
        return null;
      let body;
      if (s.phase === "preparing")
        body = Text(t("review.preparing", "Reading the file…")).font("callout").secondary();
      else if (s.phase === "applied")
        body = HStack({ spacing: 8 }, [Icon("checkmark.circle.fill").color("success"), Text(s.intent.op === "trash" ? t("review.trashed", "Moved to the Trash") : t("review.saved", "Saved")).font("callout"), Spacer(), Button(t("action.done", "Done"), () => cancel()).font("caption")]);
      else if (s.phase === "gone")
        body = HStack({ spacing: 8 }, [Text(t("review.gone", "That line is no longer in the file; an agent changed it.")).font("callout").lineLimit(2), Spacer(), Button(t("action.dismiss", "Dismiss"), () => cancel()).font("caption")]);
      else if (s.phase === "failed")
        body = HStack({ spacing: 8 }, [Icon("exclamationmark.triangle.fill").color("warning"), Text(failure(s.code, s.message)).font("callout").lineLimit(3), Spacer(), Button(t("action.dismiss", "Dismiss"), () => cancel()).font("caption")]);
      else {
        const lines = previewLines(s.before, s.after);
        const applying = s.phase === "applying";
        body = VStack({ spacing: 6 }, [
          s.phase === "review" && s.note === "rebased" ? Text(t("review.rebased", "An agent changed this file after the first preview. This is your edit on the new text.")).font("caption").color("warning") : null,
          VStack({ spacing: 0 }, lines.slice(0, MAX_LINES).map(diffLine)).background("hover").cornerRadius(4),
          lines.length > MAX_LINES ? Text(t("review.more", "{n} more lines", { n: lines.length - MAX_LINES })).font("caption").secondary() : null,
          () => diffsNotice() ? Text(diffsNotice()).font("caption").color("warning").lineLimit(2) : null,
          HStack({ spacing: 10 }, [
            s.intent.op === "trash" ? null : Button(t("action.openInDiffs", "Open in Diffs"), async () => setDiffsNotice(await openInDiffs())).font("caption").disabled(applying),
            Spacer(),
            Button(t("action.cancel", "Cancel"), () => cancel()).font("caption").disabled(applying),
            applying ? ProgressView(null).frame({ width: 12, height: 12 }) : Button(s.intent.op === "trash" ? t("action.moveToTrash", "Move to Trash") : t("action.save", "Save"), () => void apply()).font("caption").weight("semibold")
          ])
        ]);
      }
      return VStack({ spacing: 6 }, [Text(s.title).font("headline").lineLimit(2), body]).padding(10).background("hover").cornerRadius(8).padding({ top: 8, leading: 12, bottom: 4, trailing: 12 });
    };
  }
  var searchField = () => TextField("", { placeholder: t("search.placeholder", "Search memory"), onSubmit: (q) => void search(q), onEdit: (q) => q === "" ? void search("") : undefined });
  function errorState(err, title) {
    if (err.missing)
      return EmptyState({ title: t("error.missingTitle", "Agent memory is not available yet"), message: t("error.missingOp", "This cmux does not provide {op}.", { op: err.op }), symbol: "puzzlepiece.extension" });
    return EmptyState({ title, message: err.message, symbol: "exclamationmark.triangle" });
  }
  var MAX_ROWS = 8;
  function memorySection() {
    return VStack({ spacing: 0 }, [
      () => {
        if (!loaded())
          return Text(t("loading", "Looking for agent memory…")).font("caption").secondary().padding(8);
        const err = rootsError();
        if (err)
          return errorState(err, t("error.roots", "Cannot find agent memory"));
        const machine = roots()[0]?.machine;
        const list = allFiles().filter((f) => roots().find((r) => r.root === f.root)?.machine === machine);
        if (!list.length)
          return EmptyState({ title: t("empty.title", "No agent memory files"), symbol: "brain" });
        return VStack({ spacing: 0 }, [
          ...list.slice(0, MAX_ROWS).map((f) => Row({ title: displayPath(f), subtitle: fileSubtitle(f), symbol: fileSymbol(f.c.kind) }).onTap(() => {
            select(f.root, f.path);
            openPane();
          })),
          list.length > MAX_ROWS ? Text(t("section.more", "{n} more", { n: list.length - MAX_ROWS })).font("caption").secondary().padding({ top: 4, leading: 10, bottom: 4, trailing: 10 }).onTap(() => void openPane()) : null
        ]);
      }
    ]);
  }
  function rootTitle(r) {
    const machine = r.machine_label || t("machine.this", "This Mac");
    return r.kind === "user" ? t("root.user", "{machine} · everywhere", { machine }) : t("root.project", "{project} · {machine}", { project: r.label, machine });
  }
  function gate() {
    if (!loaded())
      return Text(t("loading", "Looking for agent memory…")).font("callout").secondary().padding(16);
    const err = rootsError();
    if (err)
      return errorState(err, t("error.roots", "Cannot find agent memory"));
    if (!allFiles().length && !Object.keys(errors()).length)
      return EmptyState({ title: t("empty.title", "No agent memory files"), message: t("empty.message", "CLAUDE.md, AGENTS.md and agent memory folders show up here."), symbol: "brain" });
    return null;
  }
  function hitList() {
    const h = hits() ?? [];
    if (!h.length)
      return Text(t("search.none", "No memory matches “{q}”", { q: query() })).font("callout").secondary().padding(12);
    return VStack({ spacing: 0 }, h.slice(0, 30).map((x) => Row({ title: x.text || x.path, subtitle: x.line ? t("search.where", "{file}, line {line}", { file: displayPath(x), line: x.line }) : displayPath(x), symbol: "magnifyingglass" }).onTap(() => void select(x.root, x.path))));
  }
  function rootGroups() {
    return VStack({ spacing: 0 }, [
      ForEach({ items: roots, key: (r) => r.root }, (r) => VStack({ spacing: 0 }, [
        Text(() => rootTitle(r())).font("caption").weight("semibold").secondary().padding({ top: 8, leading: 12, bottom: 2, trailing: 12 }),
        () => {
          const err = errors()[r().root];
          return err ? Text(err.missing ? t("error.missingOp", "This cmux does not provide {op}.", { op: err.op }) : err.message).font("caption").color("danger").padding({ top: 0, leading: 12, bottom: 4, trailing: 12 }) : null;
        },
        ForEach({ items: () => allFiles().filter((f) => f.root === r().root), key: (f) => f.path }, (f) => fileRow(f))
      ]))
    ]);
  }
  var header = () => VStack({ spacing: 6 }, [Text(t("title", "Agent Memory")).font("headline"), searchField()]).padding({ top: 8, leading: 12, bottom: 6, trailing: 12 });
  function filesView() {
    return VStack({ spacing: 0 }, [header(), reviewCard(), Divider(), () => gate() ?? VStack({ spacing: 0 }, [() => hits() !== null ? hitList() : rootGroups(), Divider(), documentView()])]);
  }
  function entryRow(f, e) {
    const menu = () => [Button(t("action.openFile", "Show File"), () => void select(f.root, f.path)), Button(t("action.deleteLine", "Delete Line…"), () => void removeEntry(refOf(f), e.text)).destructive()];
    return HStack({ spacing: 6 }, [Text("•").font("callout").secondary(), Text(e.text).font("callout").lineLimit(3).frame({ maxWidth: "infinity" }).contextMenu(menu)]).padding({ top: 3, leading: 12, bottom: 3, trailing: 12 }).hoverBackground("hover");
  }
  var [requested, setRequested] = signal(false);
  function entriesView() {
    return VStack({ spacing: 0 }, [
      header(),
      reviewCard(),
      Divider(),
      () => {
        const g = gate();
        if (g)
          return g;
        if (!requested()) {
          setRequested(true);
          loadAllTexts();
        }
        const q = query().trim().toLowerCase();
        const blocks = allFiles().map((f) => {
          const text = texts()[fileKey(f.root, f.path)];
          const entries = text === undefined ? [] : parseEntries(text).filter((e) => !q || e.text.toLowerCase().includes(q));
          return { f, loaded: text !== undefined, entries };
        });
        const shown = blocks.filter((b) => b.entries.length || !q && !b.loaded);
        if (!shown.length)
          return Text(q ? t("search.none", "No memory matches “{q}”", { q: query() }) : t("doc.empty", "This file is empty")).font("callout").secondary().padding(12);
        return VStack({ spacing: 0 }, shown.flatMap((b) => [
          HStack({ spacing: 6 }, [
            Text(displayPath(b.f)).font("caption").weight("semibold").monospaced().lineLimit(1).truncation("head").layoutPriority(1),
            Text(`${fileSubtitle(b.f)} · ${rootTitle(rootOf(b.f.root))}`).font("caption").secondary().lineLimit(1),
            Spacer()
          ]).padding({ top: 8, leading: 12, bottom: 2, trailing: 12 }),
          ...b.loaded ? b.entries.slice(0, 12).map((e) => entryRow(b.f, e)) : [Text(t("loading.file", "Opening…")).font("caption").secondary().padding({ top: 0, leading: 12, bottom: 0, trailing: 12 })],
          b.entries.length > 12 ? Text(t("doc.more", "{n} more entries", { n: b.entries.length - 12 })).font("caption").secondary().padding({ top: 0, leading: 12, bottom: 4, trailing: 12 }).onTap(() => void select(b.f.root, b.f.path)) : null
        ]));
      }
    ]);
  }
  function splitView() {
    return VStack({ spacing: 0 }, [
      HStack({ spacing: 8 }, [Text(t("title", "Agent Memory")).font("headline"), Spacer()]).padding({ top: 8, leading: 12, bottom: 6, trailing: 12 }),
      Divider(),
      () => gate() ?? HStack({ spacing: 0 }, [
        VStack({ spacing: 0 }, [VStack({ spacing: 0 }, [searchField()]).padding(8), () => hits() !== null ? hitList() : rootGroups(), Spacer()]).frame({ width: 260, maxHeight: "infinity" }),
        Rectangle().fill("separator").frame({ width: 1, maxHeight: "infinity" }),
        VStack({ spacing: 0 }, [reviewCard(), documentView(), Spacer()]).frame({ maxWidth: "infinity", maxHeight: "infinity" })
      ])
    ]);
  }
  function renderSection(ctx = {}) {
    setLanguage(detectLanguage(ctx));
    start();
    return memorySection();
  }
  function renderPane(ctx = {}) {
    setLanguage(detectLanguage(ctx));
    start();
    return VStack({ spacing: 0 }, [
      () => {
        switch (variant()) {
          case "entries":
            return entriesView();
          case "split":
            return splitView();
          default:
            return filesView();
        }
      }
    ]);
  }
  async function openMemory(_args = {}, ctx) {
    await openPane(ctx?.gesture ?? null);
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
