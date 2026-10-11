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
    append: () => append2,
    capture: () => capture2,
    create: () => create2,
    cycleVariant: () => cycleVariant3,
    exportNotes: () => exportNotes3,
    importNotes: () => importNotes3,
    list: () => list2,
    newNote: () => newNote2,
    open: () => open2,
    read: () => read2,
    renderNotes: () => renderNotes,
    search: () => search2
  });
  var appError = (code, message) => new CmuxError(code, message);
  var normalizeNewlines = (s) => s.replace(/\r\n?/g, `
`);
  function lineRange(body, index) {
    if (!Number.isInteger(index) || index < 0)
      return null;
    let start = 0;
    for (let i = 0;i < index; i++) {
      const nl = body.indexOf(`
`, start);
      if (nl < 0)
        return null;
      start = nl + 1;
    }
    const nl = body.indexOf(`
`, start);
    return { start, end: nl < 0 ? body.length : nl };
  }
  var CHECK = /^(\s*[-*+]\s+\[)([ xX])(\]\s?)/;
  function toggleEdit(body, index) {
    const r = lineRange(body, index);
    if (!r)
      return null;
    const m = body.slice(r.start, r.end).match(CHECK);
    if (!m)
      return null;
    const at = r.start + m[1].length;
    return { start: at, end: at + 1, text: m[2] === " " ? "x" : " " };
  }
  function rebaseLine(body, index, text) {
    const lines = body.split(`
`);
    if (lines[index] === text)
      return index;
    const hits = lines.flatMap((l, i) => l === text ? [i] : []);
    if (hits.length === 0)
      return null;
    const best = hits.sort((a, b) => Math.abs(a - index) - Math.abs(b - index));
    return best.length > 1 && Math.abs(best[0] - index) === Math.abs(best[1] - index) ? null : best[0];
  }
  function applyEdits(body, edits) {
    let out = body;
    for (const e of [...edits].sort((a, b) => b.start - a.start))
      out = out.slice(0, e.start) + e.text + out.slice(e.end);
    return out;
  }
  function fileNameOf(note, fallback = "note") {
    const slug = note.title.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-+|-+$/g, "").slice(0, 48).replace(/-+$/, "");
    return `${slug || fallback}.md`;
  }
  function uniqueFileNames(notes) {
    const used = new Set;
    return notes.map((n) => {
      const base = fileNameOf(n);
      let name = base;
      for (let i = 2;used.has(name); i++)
        name = base.replace(/\.md$/, `-${i}.md`);
      used.add(name);
      return name;
    });
  }
  var HEADING = /^\s{0,3}#\s+(.*?)\s*#*\s*$/;
  function toMarkdown(note) {
    const body = note.body.replace(/\s+$/, "");
    if (!note.title_explicit || !note.title.trim())
      return `${body}
`;
    const first = body.split(`
`, 1)[0] ?? "";
    if (first.match(HEADING)?.[1] === note.title.trim())
      return `${body}
`;
    return body ? `# ${note.title.trim()}

${body}
` : `# ${note.title.trim()}
`;
  }
  function fromMarkdown(text) {
    const lines = normalizeNewlines(text.replace(/^﻿/, "")).replace(/\s+$/, "").split(`
`);
    while (lines.length && !lines[0].trim())
      lines.shift();
    const heading = lines[0]?.match(HEADING);
    if (!heading?.[1])
      return { body: lines.join(`
`) };
    lines.shift();
    while (lines.length && !lines[0].trim())
      lines.shift();
    return { title: heading[1], body: lines.join(`
`) };
  }
  var NOTE_STREAM = "note.watch";
  var one = (p) => p.then((r) => r.note);
  var api = {
    list: (params = {}) => cmux.call("note.list", params),
    get: (note) => one(cmux.call("note.get", { note })),
    create: (params, key) => one(cmux.call("note.create", params, key ? { idempotencyKey: key } : undefined)),
    capture: (params) => one(cmux.call("note.capture", params)),
    append: (params) => one(cmux.call("note.append", params)),
    update: (note, change) => one(cmux.call("note.update", { note, ...change })),
    delete: (note) => cmux.call("note.delete", { note }),
    search: (query, limit) => cmux.call("note.search", { query, ...limit ? { limit } : {} }),
    edit: (doc, base_revision, edits) => cmux.call("document.edit", { doc, base_revision, edits })
  };
  var [summaries, setSummaries] = signal([]);
  var [bodies, setBodies] = signal(new Map);
  var [ready, setReady] = signal(false);
  var [loadError, setLoadError] = signal(null);
  var [saveError, setSaveError] = signal(null);
  var codeOf = (e) => e && typeof e === "object" && ("code" in e) ? String(e.code) : "";
  var messageOf = (e) => e instanceof Error ? e.message : String(e);
  var loading = null;
  var lastSeq = 0;
  async function loadOnce() {
    const r = await api.list({ limit: 2000 });
    setSummaries(r.notes);
  }
  function ensureLoaded() {
    if (!loading) {
      loading = loadOnce().then(() => {
        setLoadError(null);
        setReady(true);
      }, (e) => {
        loading = null;
        setLoadError({ code: codeOf(e), message: messageOf(e) });
        throw e;
      });
    }
    return loading;
  }
  function upsert(note) {
    const current = summaries().find((n) => n.id === note.id);
    if (current && current.revision > note.revision)
      return;
    const { body, ...summary } = note;
    setSummaries((list) => current ? list.map((n) => n.id === note.id ? summary : n) : [...list, summary]);
    if (typeof body === "string")
      setBodies((m) => new Map(m).set(note.id, { revision: note.revision, body }));
  }
  function remove(id) {
    setSummaries((list) => list.filter((n) => n.id !== id));
    setBodies((m) => {
      const next = new Map(m);
      next.delete(id);
      return next;
    });
  }
  function onEvent(payload) {
    const ev = payload;
    if (!ev || !ev.note || typeof ev.note.id !== "string")
      return;
    if (typeof ev.seq === "number") {
      if (ev.seq <= lastSeq)
        return;
      lastSeq = ev.seq;
    }
    if (ev.kind === "deleted")
      return remove(ev.note.id);
    upsert(ev.note);
  }
  function attach() {
    cmux.events.on(NOTE_STREAM, onEvent);
    ensureLoaded().catch(() => {
      return;
    });
  }
  var findSummary = (id) => summaries().find((n) => n.id === id) ?? null;
  var inflight = new Set;
  function bodyOf(id) {
    const summary = findSummary(id);
    const cached = bodies().get(id);
    if (summary && (!cached || cached.revision < summary.revision) && !inflight.has(id)) {
      inflight.add(id);
      api.get(id).then(upsert, (e) => setSaveError(messageOf(e))).finally(() => inflight.delete(id));
    }
    return cached?.body ?? null;
  }
  async function write(fn) {
    try {
      const note = await fn();
      upsert(note);
      setSaveError(null);
      return note;
    } catch (e) {
      setSaveError(messageOf(e));
      throw e;
    }
  }
  var appendTo = (target, text) => write(() => api.append({ ...target, text }));
  var createNote = (params, key) => write(() => api.create(params, key));
  var updateNote = (id, change) => write(() => api.update(id, change));
  async function deleteNote(id) {
    try {
      await api.delete(id);
      remove(id);
    } catch (e) {
      setSaveError(messageOf(e));
      throw e;
    }
  }
  async function toggleCheck(id, index) {
    const summary = findSummary(id);
    const cached = bodies().get(id);
    if (!summary || !cached)
      return false;
    let base = { revision: cached.revision, body: cached.body };
    let line = index;
    const lineText = base.body.split(`
`)[index] ?? "";
    for (let attempt = 0;attempt < 2; attempt++) {
      const edit = toggleEdit(base.body, line);
      if (!edit)
        return false;
      try {
        const r = await api.edit(summary.doc, base.revision, [edit]);
        const body = applyEdits(base.body, [edit]);
        setBodies((m) => new Map(m).set(id, { revision: r.revision, body }));
        return true;
      } catch (e) {
        if (codeOf(e) !== "revision.conflict") {
          setSaveError(messageOf(e));
          return false;
        }
        const current = await api.get(id);
        upsert(current);
        const moved = rebaseLine(current.body, line, lineText);
        if (moved === null)
          return false;
        base = { revision: current.revision, body: current.body };
        line = moved;
      }
    }
    return false;
  }
  function sorted(list, order) {
    const by = {
      updated: (a, b) => b.updated_at - a.updated_at,
      created: (a, b) => b.created_at - a.created_at,
      title: (a, b) => a.title.localeCompare(b.title)
    };
    return list.slice().sort((a, b) => Number(b.pinned) - Number(a.pinned) || by[order](a, b) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  }
  var scratchpadOf = (workspaceId) => summaries().find((n) => n.scratchpad && n.workspace?.id === workspaceId) ?? null;
  var CANCELLED = "fs.cancelled";
  var pick = (params, gesture) => cmux.call("fs.pick", params, gesture ? { gesture } : undefined);
  async function exportNotes(ids, gesture) {
    const folder = await pick({ mode: "folder", purpose: "export", create: true }, gesture);
    const chosen = ids ? ids : summaries().slice().sort((a, b) => a.created_at - b.created_at).map((n) => n.id);
    const notes = [];
    for (const id of chosen)
      notes.push(await api.get(id));
    const names = uniqueFileNames(notes);
    const files = [];
    for (const [i, note] of notes.entries()) {
      const r = await cmux.call("fs.write", { root: folder.root, path: names[i], text: toMarkdown(note), exists: "unique" }, { idempotencyKey: `export:${folder.root}:${note.id}:${note.revision}` });
      files.push(r.path);
    }
    return { folder: folder.name, files };
  }
  var MAX_IMPORT_BYTES = 1e6;
  async function importNotes(gesture) {
    const picked = await pick({ mode: "files", purpose: "import", accept: [".md", ".markdown", ".txt"], multiple: true }, gesture);
    const imported = [];
    const skipped = [];
    for (const entry of picked.entries) {
      if (entry.size > MAX_IMPORT_BYTES) {
        skipped.push(entry.name);
        continue;
      }
      const file = await cmux.call("fs.read", { root: picked.root, path: entry.path, max_bytes: MAX_IMPORT_BYTES });
      const note = await createNote(fromMarkdown(file.text), `import:${picked.root}:${entry.path}`);
      if (note)
        imported.push(note.id);
    }
    return { imported, skipped };
  }
  var VARIANTS = ["scratchpad", "list", "editor"];
  var DEFAULT_VARIANT = "scratchpad";
  var DEFAULT_BODY_LINES = 12;
  var MAX_RENDERED_LINES = 400;
  var setting = (key) => cmux.app.settings()[key];
  var variant = () => {
    const v = setting("variant");
    return VARIANTS.includes(v) ? v : DEFAULT_VARIANT;
  };
  var sortOrder = () => {
    const v = setting("sort");
    return v === "created" || v === "title" ? v : "updated";
  };
  var bodyLines = () => {
    const v = Number(setting("bodyLines"));
    return Number.isInteger(v) && v >= 1 && v <= MAX_RENDERED_LINES ? v : DEFAULT_BODY_LINES;
  };
  var nextVariant = (v) => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length];
  async function cycleVariant() {
    const next = nextVariant(variant());
    await cmux.app.settings.set({ variant: next });
    return { variant: next };
  }
  function watchWorkspaces(ctx) {
    const live = cmux.live("workspace.list", {});
    const list = computed(() => live() ?? []);
    const current = computed(() => {
      const all = list();
      const fromCtx = typeof ctx.workspace === "string" ? all.find((w) => w.id === ctx.workspace) : undefined;
      const focused = fromCtx ?? all.find((w) => w.focused);
      return focused ? { id: focused.id, name: focused.name } : null;
    });
    return { current, liveName: (id) => list().find((w) => w.id === id)?.name ?? null };
  }
  var [selectRequest, setSelectRequest] = signal(null);
  var seq = 0;
  function requestSelect(id) {
    setSelectRequest({ id, seq: ++seq });
  }
  var [notice, setNotice] = signal(null);
  function noticeFor(message) {
    setNotice(message);
    cmux.timer.after(6000, () => setNotice(null));
  }
  function createViewState(ctx) {
    const [selected, select] = signal(null);
    const [query, setQuery] = signal("");
    const [results, setResults] = signal(null);
    const [expanded, setExpandedSet] = signal(new Set);
    const [fieldGeneration, setFieldGeneration] = signal(0);
    let seen = selectRequest()?.seq ?? 0;
    effect(() => {
      const r = selectRequest();
      if (!r || r.seq === seen)
        return;
      seen = r.seq;
      select(r.id);
      setQuery("");
      setFieldGeneration((g) => g + 1);
    });
    let asked = 0;
    effect(() => {
      const q = query().trim();
      const mine = ++asked;
      if (!q)
        return setResults(null);
      api.list({ query: q, limit: 50 }).then((r) => mine === asked && setResults(r.notes), () => mine === asked && setResults([]));
    });
    return {
      selected,
      select,
      toggle: (id) => select((cur) => cur === id ? null : id),
      query,
      setQuery,
      results,
      isExpanded: (id) => expanded().has(id),
      setExpanded: (id, on) => setExpandedSet((set) => {
        const next = new Set(set);
        if (on)
          next.add(id);
        else
          next.delete(id);
        return next;
      }),
      ws: watchWorkspaces(ctx),
      searchGeneration: fieldGeneration,
      clearSearch: () => {
        setQuery("");
        setFieldGeneration((g) => g + 1);
      }
    };
  }
  var fail = (code, message) => {
    throw appError(code, message);
  };
  function str(args, key, required = false) {
    const v = args[key];
    if (v === undefined || v === null)
      return required ? fail("invalid_params", `${key} is required`) : undefined;
    if (typeof v !== "string")
      return fail("invalid_params", `${key} must be a string`);
    if (required && !v.trim())
      return fail("invalid_params", `${key} must not be empty`);
    return v;
  }
  async function run(fn) {
    try {
      return await fn();
    } catch (e) {
      if (e instanceof Error && codeOf(e))
        throw e;
      throw appError("command.failed", messageOf(e));
    }
  }
  var summary = (n) => {
    const { body: _body, ...rest } = n;
    return rest;
  };
  var list = (args = {}) => run(async () => {
    const query = str(args, "query");
    const workspace = str(args, "workspace");
    const limit = Math.min(200, Math.max(1, Number(args.limit ?? 50) || 50));
    const r = await api.list({ ...query ? { query } : {}, ...workspace ? { workspace } : {}, limit });
    return { notes: r.notes };
  });
  var read = (args = {}) => run(() => api.get(str(args, "id", true)));
  var create = (args = {}) => run(async () => {
    const title = str(args, "title") ?? "";
    const body = str(args, "body") ?? "";
    if (!title.trim() && !body.trim())
      fail("invalid_params", "give a title or a body");
    const workspace = str(args, "workspace") ?? null;
    return summary(await createNote({ title, body, workspace, pinned: args.pinned === true }));
  });
  var capture = (args = {}) => run(async () => {
    const text = str(args, "text", true);
    const workspace = str(args, "workspace") ?? null;
    return summary(await api.capture({ text, workspace }));
  });
  var append = (args = {}) => run(async () => {
    const text = str(args, "text", true);
    const id = str(args, "id");
    if (!!id === (args.workspace !== undefined))
      fail("invalid_params", "give exactly one of id or workspace");
    const target = id ? { note: id } : { workspace: str(args, "workspace", true) };
    return summary(await appendTo(target, text));
  });
  var search = (args = {}) => run(async () => {
    const limit = Math.min(50, Math.max(1, Number(args.limit ?? 20) || 20));
    return api.search(str(args, "query", true), limit);
  });
  var exportNotes2 = (args = {}, ctx) => run(async () => {
    const id = str(args, "id");
    try {
      return await exportNotes(id ? [id] : null, ctx?.gesture ?? null);
    } catch (e) {
      if (codeOf(e) === CANCELLED)
        return { folder: null, files: [] };
      throw e;
    }
  });
  var importNotes2 = (_args = {}, ctx) => run(async () => {
    try {
      return await importNotes(ctx?.gesture ?? null);
    } catch (e) {
      if (codeOf(e) === CANCELLED)
        return { imported: [], skipped: [] };
      throw e;
    }
  });
  var newNote = () => run(async () => {
    const note = await createNote({});
    requestSelect(note.id);
    return { id: note.id };
  });
  var open = (args = {}) => run(async () => {
    const id = str(args, "id", true);
    await ensureLoaded();
    if (!findSummary(id))
      fail("note.not_found", `no note ${id}`);
    requestSelect(id);
    return { id };
  });
  var cycleVariant2 = () => cycleVariant();

  // first-party-apps/notes/strings/en.json
  var en_default = {
    "action.attach": "Attach to This Workspace",
    "action.delete": "Delete",
    "action.detach": "Detach from Workspace",
    "action.exportAll": "Export All Notes as Markdown…",
    "action.exportOne": "Export as Markdown…",
    "action.importFiles": "Import Markdown Files…",
    "action.more": "More",
    "action.new": "New Note",
    "action.openEditor": "Open in Editor",
    "action.pin": "Pin",
    "action.showLess": "Show Less",
    "action.showMore": "Show {n} more lines",
    "action.unpin": "Unpin",
    "append.placeholder": "Add a line",
    "check.stale": "The note changed; that line is gone.",
    "editor.unsupported": "This version of cmux cannot open the notes editor yet.",
    "empty.message": "Create one with New Note, import Markdown files, or ask an agent to keep notes for you.",
    "empty.search": "No matching notes",
    "empty.title": "No notes",
    "error.generic": "Something went wrong: {reason}",
    "error.load": "Cannot load notes",
    "error.save": "Cannot save notes",
    "export.done": "Exported {n} notes to {folder}",
    "export.failed": "Export failed: {reason}",
    "files.unsupported": "this version of cmux cannot open files yet",
    "import.done": "Imported {n} notes",
    "import.doneSkipped": "Imported {n} notes; skipped {skipped} large files",
    "import.failed": "Import failed: {reason}",
    "limit.lines": "Long note: showing the first {n} lines.",
    "note.empty": "Empty note",
    "note.untitled": "Untitled",
    "scratchpad.closed": "{name} (closed)",
    "scratchpad.none": "No workspace selected",
    "scratchpad.placeholder": "Note for this workspace",
    "scratchpad.title": "Scratchpad",
    "search.placeholder": "Search notes",
    "server.unavailable": "Notes are not available yet",
    "server.unavailableHelp": "This version of cmux does not run the notes server."
  };

  // first-party-apps/notes/strings/ja.json
  var ja_default = {
    "action.attach": "このワークスペースに付ける",
    "action.delete": "削除",
    "action.detach": "ワークスペースから外す",
    "action.exportAll": "すべてのメモをMarkdownで書き出す…",
    "action.exportOne": "Markdownで書き出す…",
    "action.importFiles": "Markdownファイルを読み込む…",
    "action.more": "その他",
    "action.new": "新規メモ",
    "action.openEditor": "エディタで開く",
    "action.pin": "ピン留め",
    "action.showLess": "折りたたむ",
    "action.showMore": "あと{n}行を表示",
    "action.unpin": "ピン留めを外す",
    "append.placeholder": "行を追加",
    "check.stale": "メモが変更され、その行はなくなりました。",
    "editor.unsupported": "このバージョンの cmux はメモのエディタをまだ開けません。",
    "empty.message": "「新規メモ」で作成するか、Markdownファイルを読み込むか、エージェントにメモを頼んでください。",
    "empty.search": "一致するメモはありません",
    "empty.title": "メモはありません",
    "error.generic": "問題が発生しました: {reason}",
    "error.load": "メモを読み込めません",
    "error.save": "メモを保存できません",
    "export.done": "{n} 件のメモを {folder} に書き出しました",
    "export.failed": "書き出せませんでした: {reason}",
    "files.unsupported": "このバージョンの cmux はまだファイルを開けません",
    "import.done": "{n} 件のメモを読み込みました",
    "import.doneSkipped": "{n} 件のメモを読み込み、大きなファイル {skipped} 件をスキップしました",
    "import.failed": "読み込めませんでした: {reason}",
    "limit.lines": "長いメモです。表示は先頭の{n}行までです。",
    "note.empty": "空のメモ",
    "note.untitled": "無題",
    "scratchpad.closed": "{name}(閉じています)",
    "scratchpad.none": "ワークスペースを選んでいません",
    "scratchpad.placeholder": "このワークスペースにメモ",
    "scratchpad.title": "スクラッチパッド",
    "search.placeholder": "メモを検索",
    "server.unavailable": "メモはまだ利用できません",
    "server.unavailableHelp": "このバージョンの cmux はメモのサーバーを実行していません。"
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
  var leadingDepth = (s) => Math.min(4, Math.floor((s.match(/^\s*/)?.[0].replace(/\t/g, "  ").length ?? 0) / 2));
  function parseLines(body) {
    if (!body)
      return [];
    const out = [];
    let inFence = false;
    body.split(`
`).forEach((raw, index) => {
      const base = { index, level: 0, checked: false, marker: "" };
      if (/^\s*(```|~~~)/.test(raw)) {
        inFence = !inFence;
        out.push({ ...base, kind: "fence", text: raw.trim().replace(/^(```|~~~)/, "") });
        return;
      }
      if (inFence)
        return void out.push({ ...base, kind: "code", text: raw });
      if (!raw.trim())
        return void out.push({ ...base, kind: "blank", text: "" });
      let m;
      if (m = raw.match(/^\s{0,3}(#{1,6})\s+(.*)$/))
        return void out.push({ ...base, kind: "heading", level: m[1].length, text: m[2].trim() });
      if (/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(raw))
        return void out.push({ ...base, kind: "rule", text: "" });
      if (m = raw.match(/^(\s*)[-*+]\s+\[([ xX])\]\s?(.*)$/))
        return void out.push({ ...base, kind: "check", level: leadingDepth(m[1]), checked: m[2] !== " ", text: m[3] });
      if (m = raw.match(/^(\s*)[-*+]\s+(.*)$/))
        return void out.push({ ...base, kind: "bullet", level: leadingDepth(m[1]), text: m[2] });
      if (m = raw.match(/^(\s*)(\d+[.)])\s+(.*)$/))
        return void out.push({ ...base, kind: "number", level: leadingDepth(m[1]), marker: m[2], text: m[3] });
      if (m = raw.match(/^\s*>\s?(.*)$/))
        return void out.push({ ...base, kind: "quote", text: m[1] });
      out.push({ ...base, kind: "text", text: raw });
    });
    return out;
  }
  var inlineText = (s) => s.replace(/!\[([^\]]*)\]\([^)]*\)/g, "[$1]").replace(/\[([^\]]+)\]\(([^)]*)\)/g, "$1").replace(/(\*\*|__)(.+?)\1/g, "$2").replace(/(^|[^*\w])[*_]([^*_\s][^*_]*?)[*_](?=[^*\w]|$)/g, "$1$2").replace(/`([^`]+)`/g, "$1");
  var logged = (p) => p.catch((e) => cmux.log("notes: write failed", messageOf(e)));
  var displayTitle = (n, vs) => n.title_explicit && n.title ? n.title : n.scratchpad && n.workspace ? vs?.ws.liveName(n.workspace.id) ?? t("scratchpad.closed", { name: n.workspace.name }) : n.title || t("note.untitled");
  var byAgent = (n) => n.last_edit.actor_kind === "agent";
  function symbolOf(n) {
    if (n.pinned)
      return "pin.fill";
    if (byAgent(n))
      return "sparkles";
    return n.scratchpad ? "square.and.pencil" : "note.text";
  }
  function subtitleOf(n, vs, showWorkspace) {
    const place = showWorkspace && n.workspace && !n.scratchpad ? vs.ws.liveName(n.workspace.id) ?? t("scratchpad.closed", { name: n.workspace.name }) : "";
    if (place && n.preview)
      return `${place} · ${n.preview}`;
    return place || n.preview || t("note.empty");
  }
  function openInEditor(n) {
    return cmux.call("app.pane.open", { contribution: `${cmux.app.id}#editor`, input: { doc: n.doc }, placement: "right" }).catch((e) => {
      noticeFor(codeOf(e) === "operation.unsupported" ? t("editor.unsupported") : t("error.generic", { reason: messageOf(e) }));
    });
  }
  function runExport(ids) {
    const gesture = cmux.gesture();
    return exportNotes(ids, gesture).then((r) => noticeFor(t("export.done", { n: r.files.length, folder: r.folder })), (e) => codeOf(e) === CANCELLED ? undefined : noticeFor(t("export.failed", { reason: fsReason(e) })));
  }
  function runImport() {
    const gesture = cmux.gesture();
    return importNotes(gesture).then((r) => noticeFor(r.skipped.length ? t("import.doneSkipped", { n: r.imported.length, skipped: r.skipped.length }) : t("import.done", { n: r.imported.length })), (e) => codeOf(e) === CANCELLED ? undefined : noticeFor(t("import.failed", { reason: fsReason(e) })));
  }
  var fsReason = (e) => codeOf(e) === "operation.unsupported" ? t("files.unsupported") : messageOf(e);
  function noteMenu(n, vs) {
    const here = vs.ws.current();
    const items = [
      Button(t("action.openEditor"), () => openInEditor(n)),
      Button(n.pinned ? t("action.unpin") : t("action.pin"), () => logged(updateNote(n.id, { pinned: !n.pinned })))
    ];
    if (n.workspace)
      items.push(Button(t("action.detach"), () => logged(updateNote(n.id, { workspace: null }))));
    else if (here)
      items.push(Button(t("action.attach"), () => logged(updateNote(n.id, { workspace: here.id }))));
    items.push(Button(t("action.exportOne"), () => runExport([n.id])));
    items.push(Divider(), Button(t("action.delete"), () => logged(deleteNote(n.id))).destructive());
    return items;
  }
  function sectionMenu(vs) {
    return [Button(t("action.new"), () => newNoteHere(vs)), Divider(), Button(t("action.importFiles"), () => runImport()), Button(t("action.exportAll"), () => runExport(null))];
  }
  function noteRow(item, vs, opts) {
    return Row({
      title: () => displayTitle(item(), vs),
      subtitle: () => subtitleOf(item(), vs, opts.showWorkspace),
      symbol: () => symbolOf(item()),
      tint: () => item().pinned ? "accent" : "secondary",
      selected: () => vs.selected() === item().id
    }).onTap(() => opts.onTap ? opts.onTap(item()) : vs.toggle(item().id)).contextMenu(() => noteMenu(item(), vs));
  }
  function freshField(placeholder, onSubmit) {
    const [generation, setGeneration] = signal(0);
    return Group([
      () => {
        generation();
        return TextField("", {
          placeholder,
          onSubmit: (text) => {
            if (!text.trim())
              return;
            setGeneration((g) => g + 1);
            return onSubmit(text);
          }
        }).font("callout").padding({ top: 4, leading: 8, bottom: 4, trailing: 8 }).background("hover").cornerRadius(6);
      }
    ]);
  }
  function searchField(vs) {
    return Group([
      () => {
        vs.searchGeneration();
        return HStack({ spacing: 6 }, [
          Icon("magnifyingglass").font("caption").secondary(),
          TextField("", { placeholder: t("search.placeholder"), onEdit: (q) => vs.setQuery(q), onCancel: () => vs.clearSearch() }).font("callout")
        ]).padding({ top: 4, leading: 8, bottom: 4, trailing: 8 }).background("hover").cornerRadius(6);
      }
    ]);
  }
  function lineDisplay(line, kind, noteId) {
    const text = () => inlineText(line().text);
    const indent = () => line().level * 12;
    switch (kind) {
      case "heading":
        return Text(text).font(() => line().level <= 1 ? "title3" : line().level === 2 ? "headline" : "subheadline").weight("semibold").lineLimit(2);
      case "check":
        return HStack({ spacing: 6 }, [
          Icon(() => line().checked ? "checkmark.square.fill" : "square").font("callout").color(() => line().checked ? "success" : "secondary"),
          Text(text).font("callout").color(() => line().checked ? "secondary" : "primary")
        ]).padding(() => ({ top: 0, leading: indent(), bottom: 0, trailing: 0 })).cursor("pointer").onTap(() => toggleCheck(noteId(), line().index).then((ok) => ok ? undefined : noticeFor(t("check.stale"))));
      case "bullet":
      case "number":
        return HStack({ spacing: 6 }, [Text(() => kind === "number" ? line().marker : "•").font("callout").secondary(), Text(text).font("callout")]).padding(() => ({ top: 0, leading: indent(), bottom: 0, trailing: 0 }));
      case "quote":
        return HStack({ spacing: 6 }, [Rectangle({ fill: "separator" }).frame({ width: 2, height: 16 }), Text(text).font("callout").italic().secondary()]);
      case "code":
        return Text(() => line().text || " ").font("caption").monospaced().padding({ top: 0, leading: 8, bottom: 0, trailing: 4 }).frame({ maxWidth: "infinity" }).background("hover");
      case "fence":
        return Group([() => line().text ? Text(() => line().text).font("caption2").monospaced().secondary() : Rectangle({ fill: "hover" }).frame({ height: 3, maxWidth: "infinity" })]);
      case "rule":
        return Divider();
      case "blank":
        return Spacer().frame({ height: 4 });
      default:
        return Text(text).font("callout");
    }
  }
  function noteBody(note, vs, opts = {}) {
    const id = () => note().id;
    const lines = computed(() => parseLines(bodyOf(id()) ?? ""));
    const limit = () => vs.isExpanded(id()) ? MAX_RENDERED_LINES : bodyLines();
    const shown = computed(() => lines().slice(0, limit()));
    const hidden = computed(() => Math.max(0, lines().length - shown().length));
    const more = computed(() => {
      const expanded = vs.isExpanded(id());
      if (hidden() > 0)
        return expanded ? "capped" : "more";
      return expanded && lines().length > bodyLines() ? "less" : "none";
    });
    return VStack({ spacing: 3 }, [
      ForEach({ items: shown, key: (l) => l.index }, (line) => {
        const kind = computed(() => line().kind);
        return Group([() => lineDisplay(line, kind(), id)]);
      }),
      () => {
        const state = more();
        if (state === "more")
          return Button(() => t("action.showMore", { n: hidden() }), () => vs.setExpanded(id(), true)).font("caption");
        if (state === "capped")
          return Text(t("limit.lines", { n: MAX_RENDERED_LINES })).font("caption").secondary();
        if (state === "less")
          return Button(t("action.showLess"), () => vs.setExpanded(id(), false)).font("caption");
        return null;
      },
      HStack({ spacing: 6 }, [
        freshField(opts.appendPlaceholder ?? t("append.placeholder"), (text) => opts.append ? opts.append(text) : logged(appendTo({ note: id() }, text))).layoutPriority(1),
        Button(Icon("square.and.pencil").secondary(), () => openInEditor(note())).help(t("action.openEditor"))
      ])
    ]);
  }
  function statusRow() {
    return () => {
      const failed = loadError();
      if (failed) {
        if (failed.code === "operation.unsupported")
          return EmptyState({ title: t("server.unavailable"), message: t("server.unavailableHelp"), symbol: "note.text" });
        return EmptyState({ title: t("error.load"), message: failed.message, symbol: "exclamationmark.triangle" });
      }
      const unsaved = saveError();
      if (unsaved)
        return Row({ title: t("error.save"), subtitle: unsaved, symbol: "exclamationmark.triangle", tint: "warning" });
      const n = notice();
      return n ? HStack({ spacing: 6 }, [Icon("info.circle").font("caption").secondary(), Text(n).font("caption").secondary().lineLimit(2)]) : null;
    };
  }
  async function newNoteHere(vs) {
    const note = await createNote({}).catch(() => null);
    if (note) {
      vs.clearSearch();
      vs.select(note.id);
    }
  }
  var BLANK = {
    id: "",
    doc: "",
    title: "",
    title_explicit: false,
    preview: "",
    pinned: false,
    scratchpad: false,
    workspace: null,
    lines: 0,
    created_at: 0,
    updated_at: 0,
    revision: 0,
    last_edit: { actor_kind: "user", actor: "", at: 0 }
  };
  function noteById(id) {
    let last = BLANK;
    return () => {
      const n = findSummary(id());
      if (n)
        last = n;
      return last;
    };
  }
  var moreButton = (vs) => Button(Icon("ellipsis.circle").secondary()).help(t("action.more")).contextMenu(() => sectionMenu(vs));
  function listHeader(vs) {
    return HStack({ spacing: 6 }, [
      searchField(vs).layoutPriority(1),
      Button(Icon("square.and.pencil").secondary(), () => newNoteHere(vs)).help(t("action.new")),
      moreButton(vs)
    ]);
  }
  function visibleNotes(vs, exclude) {
    return computed(() => {
      const skip = exclude?.() ?? null;
      const found = vs.results();
      const pool = found ? found.map((n) => findSummary(n.id) ?? n) : sorted(summaries(), sortOrder());
      return pool.filter((n) => n.id !== skip);
    });
  }
  function notesList(vs, opts) {
    const visible = visibleNotes(vs, opts.exclude);
    const items = computed(() => {
      const out = [];
      const selected = vs.selected();
      for (const n of visible()) {
        out.push({ key: `row:${n.id}`, id: n.id, detail: false });
        if (opts.inlineDetail && n.id === selected)
          out.push({ key: `detail:${n.id}`, id: n.id, detail: true });
      }
      return out;
    });
    const empty = computed(() => {
      if (!ready() || visible().length)
        return "none";
      if (vs.query().trim())
        return vs.results() ? "search" : "none";
      return opts.quietWhenEmpty ? "none" : "empty";
    });
    return VStack({ spacing: 1 }, [
      ForEach({ items, key: (i) => i.key }, (item) => {
        const note = noteById(() => item().id);
        return item().detail ? VStack({ spacing: 0 }, [noteBody(note, vs)]).padding({ top: 2, leading: 30, bottom: 8, trailing: 6 }) : noteRow(note, vs, { showWorkspace: opts.showWorkspace, onTap: opts.onTap });
      }),
      () => {
        const state = empty();
        if (state === "search")
          return EmptyState({ title: t("empty.search"), symbol: "magnifyingglass" });
        if (state === "empty")
          return EmptyState({ title: t("empty.title"), message: t("empty.message"), symbol: "note.text" });
        return null;
      }
    ]);
  }
  function renderEditorList(vs) {
    return VStack({ spacing: 6 }, [
      listHeader(vs),
      notesList(vs, {
        inlineDetail: false,
        showWorkspace: true,
        onTap: (n) => {
          vs.select(n.id);
          return openInEditor(n);
        }
      })
    ]);
  }
  function renderScratchpad(vs) {
    const workspaceId = computed(() => vs.ws.current()?.id ?? null);
    const padId = computed(() => {
      const ws = workspaceId();
      return ws ? scratchpadOf(ws)?.id ?? null : null;
    });
    const placeholder = t("scratchpad.placeholder");
    const append = (text) => {
      const ws = vs.ws.current();
      return ws ? appendTo({ workspace: ws.id }, text).catch((e) => cmux.log("notes: append failed", messageOf(e))) : undefined;
    };
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 6 }, [
        Icon("square.and.pencil").font("caption").secondary().help(t("scratchpad.title")),
        Text(() => vs.ws.current()?.name ?? t("scratchpad.none")).font("caption").weight("semibold").secondary().lineLimit(1),
        Spacer()
      ]),
      () => {
        if (!workspaceId())
          return null;
        const id = padId();
        if (id)
          return noteBody(noteById(() => id), vs, { appendPlaceholder: placeholder, append });
        return freshField(placeholder, append);
      },
      Divider().padding({ top: 4, leading: 0, bottom: 4, trailing: 0 }),
      HStack({ spacing: 6 }, [searchField(vs).layoutPriority(1), Button(Icon("plus").secondary(), () => newNoteHere(vs)).help(t("action.new")), moreButton(vs)]),
      notesList(vs, { exclude: padId, inlineDetail: true, showWorkspace: true, quietWhenEmpty: true })
    ]);
  }
  function renderNotes(ctx = {}) {
    attach();
    const vs = createViewState(ctx);
    const failed = computed(() => loadError() !== null);
    return VStack({ spacing: 6 }, [
      statusRow(),
      () => {
        if (failed())
          return null;
        switch (variant()) {
          case "list":
            return VStack({ spacing: 6 }, [listHeader(vs), notesList(vs, { inlineDetail: true, showWorkspace: true })]);
          case "editor":
            return renderEditorList(vs);
          default:
            return renderScratchpad(vs);
        }
      }
    ]);
  }
  var list2 = list;
  var read2 = read;
  var create2 = create;
  var capture2 = capture;
  var append2 = append;
  var search2 = search;
  var exportNotes3 = exportNotes2;
  var importNotes3 = importNotes2;
  var newNote2 = newNote;
  var open2 = open;
  var cycleVariant3 = cycleVariant2;
  globalThis.__cmuxAppExports = { ...exports_main };
})();
