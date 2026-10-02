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
    exportNotes: () => exportNotes2,
    list: () => list2,
    newNote: () => newNote2,
    open: () => open2,
    pin: () => pin2,
    read: () => read2,
    renderNotes: () => renderNotes,
    renderNotesPane: () => renderNotesPane,
    search: () => search2
  });
  var appError = (code, message) => new CmuxError(code, message);
  var ja = {
    "section.title": "メモ",
    "search.placeholder": "メモを検索",
    "append.placeholder": "行を追加",
    "scratchpad.placeholder": "このワークスペースにメモ",
    "title.placeholder": "タイトル",
    "line.placeholder": "行を編集",
    "note.untitled": "無題",
    "note.empty": "空のメモ",
    "list.pinned": "ピン留め",
    "list.workspace": "このワークスペース",
    "list.recent": "最近",
    "list.other": "ほかのメモ",
    "empty.title": "メモはありません",
    "empty.message": "「新規メモ」で作成するか、エージェントにメモを頼んでください。",
    "empty.search": "一致するメモはありません",
    "empty.select": "メモを選択してください",
    "scratchpad.title": "スクラッチパッド",
    "scratchpad.none": "ワークスペースを選んでいません",
    "scratchpad.closed": "{name}(閉じています)",
    "error.load": "メモを読み込めません",
    "error.save": "メモを保存できません",
    "error.storage": "ストレージを使えません",
    "action.new": "新規メモ",
    "action.pin": "ピン留め",
    "action.unpin": "ピン留めを外す",
    "action.delete": "削除",
    "action.back": "戻る",
    "action.showMore": "あと{n}行を表示",
    "action.showLess": "折りたたむ",
    "action.editLine": "行を編集",
    "action.deleteLine": "行を削除",
    "action.attach": "このワークスペースに付ける",
    "action.detach": "ワークスペースから外す",
    "action.copyId": "IDをコピー",
    "edited.agent": "エージェントが編集",
    "time.now": "今",
    "time.minutes": "{n}分",
    "time.hours": "{n}時間",
    "time.days": "{n}日",
    "backend.local": "このMacのみ",
    "error.tooLarge": "メモが大きすぎます",
    "error.notFound": "メモが見つかりません",
    "error.invalid": "引数が正しくありません",
    "limit.lines": "長いメモです。表示は先頭の{n}行までです。"
  };
  var tables = { ja };
  var language = "en";
  function setLanguage(tag) {
    const base = String(tag ?? "en").toLowerCase().split(/[-_]/)[0] ?? "en";
    language = tables[base] ? base : "en";
  }
  function detectLanguage(ctx) {
    if (ctx && typeof ctx.locale === "string")
      return ctx.locale;
    try {
      const intl = globalThis.Intl;
      if (intl)
        return intl.DateTimeFormat().resolvedOptions().locale;
    } catch {}
    return "en";
  }
  function t(key, english, vars = {}) {
    const template = tables[language]?.[key] ?? english;
    return template.replace(/\{(\w+)\}/g, (whole, name) => (name in vars) ? String(vars[name]) : whole);
  }
  var LIMITS = {
    titleChars: 200,
    bodyChars: 200000,
    notes: 2000,
    appendChars: 50000,
    previewChars: 120
  };

  class NoteError extends Error {
    code;
    constructor(code, message) {
      super(message);
      this.code = code;
      this.name = "NoteError";
    }
  }
  var normalizeNewlines = (s) => s.replace(/\r\n?/g, `
`);
  var clampTitle = (s) => normalizeNewlines(s).replace(/\n+/g, " ").trim().slice(0, LIMITS.titleChars).trim();
  function checkBody(body) {
    const b = normalizeNewlines(body);
    if (b.length > LIMITS.bodyChars)
      throw new NoteError("note.too_large", `a note holds at most ${LIMITS.bodyChars} characters`);
    return b;
  }
  function appendText(body, text) {
    const add = normalizeNewlines(text).replace(/\s+$/, "");
    if (!add)
      return body;
    if (!body)
      return add;
    return body.endsWith(`
`) ? body + add : `${body}
${add}`;
  }
  var emptyNote = (id, now) => ({
    id,
    title: "",
    body: "",
    pinned: false,
    scratchpad: false,
    workspace: null,
    createdAt: now,
    updatedAt: now,
    revision: 1,
    lastEdit: { via: "ui" }
  });
  var scratchpadOf = (notes, workspaceId) => notes.find((n) => n.scratchpad && n.workspace?.id === workspaceId) ?? null;
  function edit(lines, index, fn) {
    if (!Number.isInteger(index) || index < 0 || index >= lines.length)
      throw new NoteError("note.invalid", `line ${index} does not exist`);
    const copy = lines.slice();
    fn(copy);
    return copy.join(`
`);
  }
  function applyOp(notes, op, stamp) {
    const lastEdit = stamp.actor ? { via: stamp.via, actor: stamp.actor } : { via: stamp.via };
    if (op.kind === "create") {
      if (op.scratchpad && op.workspace) {
        const existing = scratchpadOf(notes, op.workspace.id);
        if (existing)
          return { notes: notes.slice(), note: existing, changed: false };
      }
      if (notes.some((n) => n.id === op.id))
        throw new NoteError("note.invalid", `note ${op.id} already exists`);
      if (notes.length >= LIMITS.notes)
        throw new NoteError("notes.full", `at most ${LIMITS.notes} notes`);
      const note = {
        ...emptyNote(op.id, stamp.now),
        title: clampTitle(op.title ?? ""),
        body: checkBody(op.body ?? ""),
        pinned: op.pinned === true,
        scratchpad: op.scratchpad === true && !!op.workspace,
        workspace: op.workspace ?? null,
        lastEdit
      };
      return { notes: [...notes, note], note, changed: true };
    }
    const index = notes.findIndex((n) => n.id === op.id);
    if (index < 0)
      throw new NoteError("note.not_found", `no note ${op.id}`);
    const before = notes[index];
    if (op.kind === "delete")
      return { notes: notes.filter((n) => n.id !== op.id), note: null, changed: true };
    let next = before;
    const lines = () => before.body.split(`
`);
    switch (op.kind) {
      case "append":
        if (normalizeNewlines(op.text).length > LIMITS.appendChars)
          throw new NoteError("note.too_large", `append at most ${LIMITS.appendChars} characters at once`);
        next = { ...before, body: checkBody(appendText(before.body, op.text)) };
        break;
      case "setTitle":
        next = { ...before, title: clampTitle(op.title) };
        break;
      case "setBody":
        next = { ...before, body: checkBody(op.body) };
        break;
      case "replaceLine":
        next = { ...before, body: checkBody(edit(lines(), op.index, (l) => l.splice(op.index, 1, ...normalizeNewlines(op.text).split(`
`)))) };
        break;
      case "deleteLine":
        next = { ...before, body: edit(lines(), op.index, (l) => l.splice(op.index, 1)) };
        break;
      case "toggleCheck":
        next = { ...before, body: edit(lines(), op.index, (l) => l[op.index] = toggleCheckLine(l[op.index])) };
        break;
      case "setPinned":
        next = { ...before, pinned: op.pinned };
        break;
      case "setWorkspace":
        next = { ...before, workspace: op.workspace, scratchpad: before.scratchpad && op.workspace?.id === before.workspace?.id };
        break;
    }
    const same = next.title === before.title && next.body === before.body && next.pinned === before.pinned && next.scratchpad === before.scratchpad && JSON.stringify(next.workspace) === JSON.stringify(before.workspace);
    if (same)
      return { notes: notes.slice(), note: before, changed: false };
    const content = next.title !== before.title || next.body !== before.body;
    next = { ...next, revision: before.revision + 1, updatedAt: content ? stamp.now : before.updatedAt, lastEdit };
    const out = notes.slice();
    out[index] = next;
    return { notes: out, note: next, changed: true };
  }
  var CHECK = /^(\s*[-*+]\s+\[)([ xX])(\]\s?)/;
  function toggleCheckLine(line) {
    const m = line.match(CHECK);
    if (!m)
      return line;
    return `${m[1]}${m[2] === " " ? "x" : " "}${m[3]}${line.slice(m[0].length)}`;
  }
  function unwrapMarkdown(s) {
    return s.replace(/!\[[^\]]*\]\([^)]*\)/g, "").replace(/\[([^\]]+)\]\([^)]*\)/g, "$1").replace(/[*_`~]+/g, "").trim();
  }
  var stripListMarker = (s) => s.replace(/^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s*)?/, "").replace(/^>\s?/, "");
  var FENCE = /^\s*(```|~~~)/;
  var HEADING = /^\s{0,3}#{1,6}\s+(.*)$/;
  function deriveTitle(body) {
    const lines = body.split(`
`);
    let inFence = false;
    for (const line of lines) {
      if (FENCE.test(line)) {
        inFence = !inFence;
        continue;
      }
      if (inFence)
        continue;
      const h = line.match(HEADING);
      if (h) {
        const title = unwrapMarkdown(h[1]);
        if (title)
          return title.slice(0, LIMITS.titleChars);
      }
    }
    inFence = false;
    for (const line of lines) {
      if (FENCE.test(line)) {
        inFence = !inFence;
        continue;
      }
      if (inFence)
        continue;
      const trimmed = line.trim();
      if (!trimmed || /^(-{3,}|\*{3,})$/.test(trimmed))
        continue;
      const title = unwrapMarkdown(stripListMarker(trimmed));
      if (title)
        return title.slice(0, LIMITS.titleChars);
    }
    return "";
  }
  var titleOf = (note) => note.title.trim() || deriveTitle(note.body);
  function previewOf(note, max = LIMITS.previewChars, skipTitleLine = true) {
    const title = titleOf(note);
    const parts = [];
    let inFence = false;
    let skippedTitle = false;
    for (const line of note.body.split(`
`)) {
      if (FENCE.test(line)) {
        inFence = !inFence;
        continue;
      }
      if (inFence || HEADING.test(line))
        continue;
      const trimmed = line.trim();
      if (!trimmed || /^(-{3,}|\*{3,})$/.test(trimmed))
        continue;
      const text = unwrapMarkdown(stripListMarker(trimmed));
      if (!text)
        continue;
      if (skipTitleLine && !skippedTitle && !note.title.trim() && text === title) {
        skippedTitle = true;
        continue;
      }
      parts.push(text);
      if (parts.join(" · ").length >= max)
        break;
    }
    const preview = parts.join(" · ");
    return preview.length > max ? `${preview.slice(0, max - 1)}…` : preview;
  }
  function sortNotes(notes, order = "updated") {
    const by = {
      updated: (a, b) => b.updatedAt - a.updatedAt,
      created: (a, b) => b.createdAt - a.createdAt,
      title: (a, b) => titleOf(a).localeCompare(titleOf(b))
    };
    return notes.slice().sort((a, b) => Number(b.pinned) - Number(a.pinned) || by[order](a, b) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  }
  var tokens = (query) => query.toLowerCase().split(/\s+/).map((s) => s.replace(/^#/, "")).filter(Boolean);
  function snippetAround(body, needle, width = 80) {
    const line = body.split(`
`).find((l) => l.toLowerCase().includes(needle));
    if (!line)
      return "";
    const text = unwrapMarkdown(stripListMarker(line.trim()));
    const at = text.toLowerCase().indexOf(needle);
    if (text.length <= width || at < 0)
      return text.length <= width ? text : `${text.slice(0, width - 1)}…`;
    const start = Math.max(0, Math.min(at - Math.floor(width / 3), text.length - width));
    return `${start > 0 ? "…" : ""}${text.slice(start, start + width - 2).trim()}${start + width - 2 < text.length ? "…" : ""}`;
  }
  function searchNotes(notes, query, limit = 50) {
    const words = tokens(query);
    if (!words.length)
      return sortNotes(notes).slice(0, limit).map((note) => ({ note, score: 0, snippet: "" }));
    const hits = [];
    for (const note of notes) {
      const title = titleOf(note).toLowerCase();
      const body = note.body.toLowerCase();
      const place = (note.workspace?.name ?? "").toLowerCase();
      let score = 0;
      let all = true;
      for (const w of words) {
        const inTitle = title.includes(w);
        const inBody = body.includes(w);
        if (!inTitle && !inBody && !place.includes(w)) {
          all = false;
          break;
        }
        score += (inTitle ? 10 : 0) + (inBody ? 3 : 0) + (inTitle || inBody ? 0 : 1);
      }
      if (!all)
        continue;
      if (title.startsWith(words.join(" ")))
        score += 20;
      if (note.pinned)
        score += 1;
      const bodyWord = words.find((w) => body.includes(w));
      hits.push({ note, score, snippet: bodyWord ? snippetAround(note.body, bodyWord) : "" });
    }
    return hits.sort((a, b) => b.score - a.score || b.note.updatedAt - a.note.updatedAt || (a.note.id < b.note.id ? -1 : 1)).slice(0, limit);
  }
  function summaryOf(note) {
    return {
      id: note.id,
      title: titleOf(note),
      preview: previewOf(note),
      pinned: note.pinned,
      scratchpad: note.scratchpad,
      workspace: note.workspace,
      lines: note.body ? note.body.split(`
`).length : 0,
      updated_at: note.updatedAt,
      revision: note.revision
    };
  }
  function fileNameOf(note, fallback = "note") {
    const slug = titleOf(note).toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-+|-+$/g, "").slice(0, 48).replace(/-+$/, "");
    return `${slug || fallback}.md`;
  }
  function toMarkdown(note) {
    const title = note.title.trim();
    const body = note.body.replace(/\s+$/, "");
    if (!title)
      return `${body}
`;
    const first = body.split(`
`, 1)[0] ?? "";
    const heading = first.match(HEADING);
    if (heading && unwrapMarkdown(heading[1]) === title)
      return `${body}
`;
    return body ? `# ${title}

${body}
` : `# ${title}
`;
  }
  function age(ms, now) {
    const minutes = Math.max(0, Math.floor((now - ms) / 60000));
    if (minutes < 1)
      return { unit: "now", n: 0 };
    if (minutes < 60)
      return { unit: "minutes", n: minutes };
    const hours = Math.floor(minutes / 60);
    if (hours < 24)
      return { unit: "hours", n: hours };
    return { unit: "days", n: Math.floor(hours / 24) };
  }
  function parseDocument(value) {
    const list = value && typeof value === "object" && Array.isArray(value.notes) ? value.notes : [];
    const out = [];
    const seen = new Set;
    for (const raw of list) {
      if (!raw || typeof raw !== "object")
        continue;
      const n = raw;
      if (typeof n.id !== "string" || !n.id || seen.has(n.id))
        continue;
      seen.add(n.id);
      const ws = n.workspace;
      out.push({
        id: n.id,
        title: typeof n.title === "string" ? n.title : "",
        body: typeof n.body === "string" ? normalizeNewlines(n.body) : "",
        pinned: n.pinned === true,
        scratchpad: n.scratchpad === true && !!ws,
        workspace: ws && typeof ws.id === "string" ? { id: ws.id, name: typeof ws.name === "string" ? ws.name : "" } : null,
        createdAt: Number(n.createdAt) || 0,
        updatedAt: Number(n.updatedAt) || 0,
        revision: Number(n.revision) || 1,
        lastEdit: n.lastEdit ?? { via: "ui" }
      });
    }
    return out;
  }
  var DOCUMENT_VERSION = 1;
  var serializeDocument = (notes) => ({ version: DOCUMENT_VERSION, notes });
  var STORAGE_KEY = "notes.v1";
  var COLLECTION = "notes";
  var LOCAL_BUDGET_BYTES = 4500000;
  var [notes, setNotes] = signal([]);
  var [ready, setReady] = signal(false);
  var [loadError, setLoadError] = signal(null);
  var [saveError, setSaveError] = signal(null);
  var [backendSignal, setBackend] = signal(null);
  var backend = backendSignal;
  var loading = null;
  var errorCode = (e) => e && typeof e === "object" && ("code" in e) ? String(e.code) : "";
  var unavailable = (e) => ["operation.unsupported", "scope.missing", "operation.forbidden"].includes(errorCode(e));
  var message = (e) => e instanceof Error ? e.message : String(e);
  var known = new Map;
  var fromRecord = (r) => {
    const note = parseDocument({ notes: [{ ...r.data, id: r.id, revision: Number(r.revision) }] })[0];
    if (note)
      known.set(note.id, Number(r.revision));
    return note;
  };
  var toData = (n) => {
    const { id: _id, revision: _rev, ...data } = n;
    return data;
  };
  async function loadOnce() {
    try {
      const r = await cmux.call("document.list", { collection: COLLECTION });
      setNotes(r.documents.map(fromRecord).filter((n) => !!n));
      setBackend("documents");
      cmux.events.on("document.changed", (payload) => void onRemoteChange(payload), { collection: COLLECTION });
    } catch (e) {
      if (!unavailable(e))
        throw e;
      const value = await cmux.storage.get(STORAGE_KEY);
      setNotes(parseDocument(value));
      setBackend("local");
    }
  }
  function ensureLoaded() {
    if (!loading) {
      loading = loadOnce().then(() => {
        setLoadError(null);
        setReady(true);
      }, (e) => {
        loading = null;
        setLoadError(message(e));
        throw e;
      });
    }
    return loading;
  }
  var findNote = (id) => notes().find((n) => n.id === id) ?? null;
  var chain = Promise.resolve();
  var generation = 0;
  var savedGeneration = 0;
  var enqueue = (work) => {
    const next = chain.then(work, work);
    chain = next.catch(() => {
      return;
    });
    return next;
  };
  function persistLocal(target) {
    return enqueue(async () => {
      if (savedGeneration >= target)
        return;
      const at = generation;
      await cmux.storage.set(STORAGE_KEY, serializeDocument(notes()));
      savedGeneration = Math.max(savedGeneration, at);
    });
  }
  function persistDocument(op, stamp) {
    return enqueue(async () => {
      for (let attempt = 0;attempt < 3; attempt++) {
        const local = findNote(op.id);
        try {
          if (op.kind === "delete") {
            await cmux.call("document.delete", { collection: COLLECTION, id: op.id, base_revision: String(known.get(op.id) ?? 0) });
            known.delete(op.id);
            return;
          }
          if (!local)
            return;
          const r = await cmux.call("document.put", { collection: COLLECTION, id: local.id, data: toData(local), base_revision: String(known.get(local.id) ?? 0) });
          const revision = Number(r.revision);
          known.set(local.id, revision);
          const latest = findNote(local.id);
          if (latest && latest.revision < revision)
            replaceNote({ ...latest, revision });
          return;
        } catch (e) {
          if (errorCode(e) !== "revision.conflict")
            throw e;
          const current = await cmux.call("document.get", { collection: COLLECTION, id: op.id });
          const theirs = current ? fromRecord(current) : undefined;
          if (!theirs) {
            removeNote(op.id);
            return;
          }
          replaceNote(theirs);
          if (op.kind === "create")
            return;
          const replay = applyOp(notes(), op, stamp);
          setNotes(replay.notes);
          if (!replay.changed)
            return;
        }
      }
      throw new NoteError("note.invalid", "the note kept changing while saving; try again");
    });
  }
  var replaceNote = (note) => setNotes((list) => list.some((n) => n.id === note.id) ? list.map((n) => n.id === note.id ? note : n) : [...list, note]);
  var removeNote = (id) => setNotes((list) => list.filter((n) => n.id !== id));
  async function onRemoteChange(e) {
    if (!e || e.collection !== COLLECTION || !e.id)
      return;
    if (e.deleted) {
      known.delete(e.id);
      return removeNote(e.id);
    }
    if (e.revision !== undefined && Number(e.revision) <= (known.get(e.id) ?? 0))
      return;
    const r = await cmux.call("document.get", { collection: COLLECTION, id: e.id });
    const note = r ? fromRecord(r) : undefined;
    if (note)
      replaceNote(note);
    else
      removeNote(e.id);
  }
  var sizeOf = (list) => JSON.stringify(serializeDocument(list)).length;
  async function commit(op, stamp) {
    await ensureLoaded();
    const result = applyOp(notes(), op, stamp);
    if (!result.changed)
      return result.note;
    if (backendSignal() === "local" && op.kind !== "delete" && sizeOf(result.notes) > LOCAL_BUDGET_BYTES) {
      throw new NoteError("notes.full", `notes use more than ${Math.round(LOCAL_BUDGET_BYTES / 1e6)} MB of local storage`);
    }
    setNotes(result.notes);
    generation++;
    try {
      if (backendSignal() === "documents")
        await persistDocument(op, stamp);
      else
        await persistLocal(generation);
      setSaveError(null);
    } catch (e) {
      setSaveError(message(e));
      throw e;
    }
    return op.kind === "delete" ? null : findNote(op.id);
  }
  function newNoteId() {
    let s = "";
    for (let i = 0;i < 16; i++)
      s += Math.floor(Math.random() * 36).toString(36);
    return `note_${s}`;
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
  var VARIANTS = ["scratchpad", "list", "split"];
  var DEFAULT_VARIANT = "scratchpad";
  var DEFAULT_BODY_LINES = 12;
  var MAX_RENDERED_LINES = 400;
  var [variantOverride, setVariantOverride] = signal(null);
  var setting = (key) => cmux.app.settings()[key];
  var variant = () => {
    const v = variantOverride() ?? setting("variant");
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
    setVariantOverride(next);
    try {
      await cmux.call("app.settings.set", { key: "variant", value: next });
      if (setting("variant") === next)
        setVariantOverride(null);
      return { variant: next, persisted: true };
    } catch {
      return { variant: next, persisted: false };
    }
  }
  function edit2(op) {
    return commit(op, { now: Date.now(), via: "ui" }).catch((e) => {
      cmux.log("notes: save failed", e instanceof Error ? e.message : String(e));
      return null;
    });
  }
  var displayTitle = (n, vs) => n.title.trim() || (n.scratchpad && n.workspace ? vs?.ws.liveName(n.workspace.id) ?? t("scratchpad.closed", "{name} (closed)", { name: n.workspace.name }) : titleOf(n) || t("note.untitled", "Untitled"));
  var isAgentEdit = (n) => n.lastEdit.via === "command" && (n.lastEdit.actor ?? "").startsWith("agent:");
  function symbolOf(n) {
    if (n.pinned)
      return "pin.fill";
    if (isAgentEdit(n))
      return "sparkles";
    if (n.scratchpad)
      return "square.and.pencil";
    return n.body.includes("- [ ]") ? "checklist" : "note.text";
  }
  function subtitleOf(n, vs, showWorkspace) {
    const preview = previewOf(n, 80, !n.scratchpad);
    const place = showWorkspace && n.workspace && !n.scratchpad ? vs.ws.liveName(n.workspace.id) ?? t("scratchpad.closed", "{name} (closed)", { name: n.workspace.name }) : "";
    if (place && preview)
      return `${place} · ${preview}`;
    return place || preview || t("note.empty", "Empty note");
  }
  function noteMenu(n, vs) {
    const here = vs.ws.current();
    const items = [Button(n.pinned ? t("action.unpin", "Unpin") : t("action.pin", "Pin"), () => edit2({ kind: "setPinned", id: n.id, pinned: !n.pinned }))];
    if (n.workspace)
      items.push(Button(t("action.detach", "Detach from Workspace"), () => edit2({ kind: "setWorkspace", id: n.id, workspace: null })));
    else if (here)
      items.push(Button(t("action.attach", "Attach to This Workspace"), () => edit2({ kind: "setWorkspace", id: n.id, workspace: here })));
    items.push(Divider(), Button(t("action.delete", "Delete"), () => edit2({ kind: "delete", id: n.id })).destructive());
    return items;
  }
  function noteRow(item, vs, opts) {
    return Row({
      title: () => displayTitle(item(), vs),
      subtitle: () => subtitleOf(item(), vs, opts.showWorkspace),
      symbol: () => symbolOf(item()),
      tint: () => item().pinned ? "accent" : "secondary",
      selected: () => vs.selected() === item().id
    }).onTap(() => vs.toggle(item().id)).contextMenu(() => noteMenu(item(), vs));
  }
  function freshField(placeholder, onSubmit, opts = {}) {
    const [generation, setGeneration] = signal(0);
    return Group([
      () => {
        generation();
        return TextField("", {
          placeholder,
          autofocus: opts.autofocus ?? false,
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
          TextField("", { placeholder: t("search.placeholder", "Search notes"), onEdit: (q) => vs.setQuery(q), onCancel: () => vs.clearSearch() }).font("callout")
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
        ]).padding(() => ({ top: 0, leading: indent(), bottom: 0, trailing: 0 })).cursor("pointer").onTap(() => edit2({ kind: "toggleCheck", id: noteId(), index: line().index }));
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
  function lineView(line, noteId, vs) {
    const kind = computed(() => line().kind);
    const editing = computed(() => {
      const e = vs.editingLine();
      return !!e && e.id === noteId() && e.index === line().index;
    });
    const raw = () => findNote(noteId())?.body.split(`
`)[line().index] ?? "";
    return Group([
      () => editing() ? TextField(raw(), {
        placeholder: t("line.placeholder", "Edit line"),
        autofocus: true,
        onSubmit: (text) => {
          vs.setEditingLine(null);
          return edit2({ kind: "replaceLine", id: noteId(), index: line().index, text });
        },
        onCancel: () => vs.setEditingLine(null)
      }).font("callout") : lineDisplay(line, kind(), noteId).contextMenu(() => [
        Button(t("action.editLine", "Edit Line"), () => vs.setEditingLine({ id: noteId(), index: line().index })),
        Button(t("action.deleteLine", "Delete Line"), () => edit2({ kind: "deleteLine", id: noteId(), index: line().index })).destructive()
      ])
    ]);
  }
  function noteBody(noteId, vs, opts = {}) {
    const lines = computed(() => parseLines(findNote(noteId())?.body ?? ""));
    const limit = () => vs.isExpanded(noteId()) ? MAX_RENDERED_LINES : (opts.maxLines ?? bodyLines)();
    const shown = computed(() => lines().slice(0, limit()));
    const hidden = computed(() => Math.max(0, lines().length - shown().length));
    const more = computed(() => {
      const expanded = vs.isExpanded(noteId());
      if (hidden() > 0)
        return expanded ? "capped" : "more";
      return expanded && lines().length > (opts.maxLines ?? bodyLines)() ? "less" : "none";
    });
    return VStack({ spacing: 3 }, [
      ForEach({ items: shown, key: (l) => l.index }, (line) => lineView(line, noteId, vs)),
      () => {
        const state = more();
        if (state === "more")
          return Button(() => t("action.showMore", "Show {n} more lines", { n: hidden() }), () => vs.setExpanded(noteId(), true)).font("caption");
        if (state === "capped")
          return Text(t("limit.lines", "Long note: showing the first {n} lines.", { n: MAX_RENDERED_LINES })).font("caption").secondary();
        if (state === "less")
          return Button(t("action.showLess", "Show Less"), () => vs.setExpanded(noteId(), false)).font("caption");
        return null;
      },
      freshField(opts.appendPlaceholder ?? t("append.placeholder", "Add a line"), (text) => edit2({ kind: "append", id: noteId(), text }))
    ]);
  }
  function statusRow() {
    return () => {
      const failed = loadError();
      if (failed)
        return EmptyState({ title: t("error.load", "Cannot load notes"), message: failed, symbol: "exclamationmark.triangle" });
      const unsaved = saveError();
      if (unsaved)
        return Row({ title: t("error.save", "Cannot save notes"), subtitle: unsaved, symbol: "exclamationmark.triangle", tint: "warning" });
      return null;
    };
  }
  async function newNoteHere(vs, workspace = null) {
    const id = newNoteId();
    const note = await edit2({ kind: "create", id, workspace });
    if (note) {
      vs.clearSearch();
      vs.select(note.id);
    }
  }
  function noteById(id) {
    let last = emptyNote(id(), 0);
    return () => {
      const n = findNote(id());
      if (n)
        last = n;
      return last;
    };
  }
  function listHeader(vs) {
    return HStack({ spacing: 6 }, [
      searchField(vs).layoutPriority(1),
      Button(Icon("square.and.pencil").secondary(), () => newNoteHere(vs)).help(t("action.new", "New Note"))
    ]);
  }
  function visibleNotes(vs, exclude) {
    return computed(() => {
      const skip = exclude?.() ?? null;
      const all = notes().filter((n) => n.id !== skip);
      const q = vs.query();
      return q.trim() ? searchNotes(all, q).map((h) => h.note) : sortNotes(all, sortOrder());
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
        return "search";
      return opts.quietWhenEmpty ? "none" : "empty";
    });
    return VStack({ spacing: 1 }, [
      ForEach({ items, key: (i) => i.key }, (item) => {
        const id = () => item().id;
        return item().detail ? VStack({ spacing: 0 }, [noteBody(id, vs)]).padding({ top: 2, leading: 30, bottom: 8, trailing: 6 }) : noteRow(noteById(id), vs, { showWorkspace: opts.showWorkspace });
      }),
      () => {
        const state = empty();
        if (state === "search")
          return EmptyState({ title: t("empty.search", "No matching notes"), symbol: "magnifyingglass" });
        if (state === "empty")
          return EmptyState({ title: t("empty.title", "No notes"), message: t("empty.message", "Create one with New Note, or ask an agent to keep notes for you."), symbol: "note.text" });
        return null;
      }
    ]);
  }
  async function appendToScratchpad(workspace, text, stamp) {
    const pad = await commit({ kind: "create", id: newNoteId(), workspace, scratchpad: true }, stamp);
    return commit({ kind: "append", id: pad.id, text }, stamp);
  }
  function renderScratchpad(vs) {
    const workspaceId = computed(() => vs.ws.current()?.id ?? null);
    const padId = computed(() => {
      const ws = workspaceId();
      return ws ? scratchpadOf(notes(), ws)?.id ?? null : null;
    });
    const placeholder = t("scratchpad.placeholder", "Note for this workspace");
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 6 }, [
        Icon("square.and.pencil").font("caption").secondary().help(t("scratchpad.title", "Scratchpad")),
        Text(() => vs.ws.current()?.name ?? t("scratchpad.none", "No workspace selected")).font("caption").weight("semibold").secondary().lineLimit(1),
        Spacer()
      ]),
      () => {
        const ws = workspaceId();
        if (!ws)
          return null;
        const id = padId();
        if (id)
          return noteBody(() => id, vs, { appendPlaceholder: placeholder });
        return freshField(placeholder, (text) => {
          const current = vs.ws.current();
          if (current)
            return appendToScratchpad(current, text, { now: Date.now(), via: "ui" }).catch((e) => cmux.log("notes: save failed", String(e)));
        });
      },
      Divider().padding({ top: 4, leading: 0, bottom: 4, trailing: 0 }),
      HStack({ spacing: 6 }, [
        searchField(vs).layoutPriority(1),
        Button(Icon("plus").secondary(), () => newNoteHere(vs)).help(t("action.new", "New Note"))
      ]),
      notesList(vs, { exclude: padId, inlineDetail: true, showWorkspace: true, quietWhenEmpty: true })
    ]);
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
    return {
      list,
      current,
      liveName: (id) => list().find((w) => w.id === id)?.name ?? null,
      loading: () => live.loading(),
      error: () => live.error()?.code ?? null
    };
  }
  async function resolveWorkspace(arg) {
    if (arg === undefined || arg === null || arg === "")
      return null;
    if (typeof arg !== "string")
      throw appError("invalid_params", 'workspace must be a string: an id, a name or "current"');
    const all = await cmux.workspace.list({});
    const hit = arg === "current" ? all.find((w) => w.focused) : all.find((w) => w.id === arg) ?? all.find((w) => w.name === arg);
    if (!hit)
      throw appError("workspace.not_found", `no workspace ${arg}`);
    return { id: hit.id, name: hit.name };
  }
  var [selectRequest, setSelectRequest] = signal(null);
  var seq = 0;
  function requestSelect(id) {
    setSelectRequest({ id, seq: ++seq });
  }
  function createViewState(ctx) {
    const [selected, select] = signal(null);
    const [query, setQuery] = signal("");
    const [editingLine, setEditingLine] = signal(null);
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
    return {
      selected,
      select: (id) => {
        select(id);
        setEditingLine(null);
      },
      toggle: (id) => {
        select((cur) => cur === id ? null : id);
        setEditingLine(null);
      },
      query,
      setQuery,
      editingLine,
      setEditingLine,
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
  var stampOf = (ctx) => ctx?.actor ? { now: Date.now(), via: "command", actor: ctx.actor } : { now: Date.now(), via: "command" };
  var fail = (code, message) => {
    throw appError(code, message);
  };
  function str(args, key, opts = {}) {
    const v = args[key];
    if (v === undefined || v === null)
      return opts.required ? fail("invalid_params", `${key} is required`) : undefined;
    if (typeof v !== "string")
      return fail("invalid_params", `${key} must be a string`);
    if (opts.required && !v.trim())
      return fail("invalid_params", `${key} must not be empty`);
    if (opts.max !== undefined && v.length > opts.max)
      return fail("note.too_large", `${key} is longer than ${opts.max} characters`);
    return v;
  }
  async function run(fn) {
    try {
      await ensureLoaded();
      return await fn();
    } catch (e) {
      if (e instanceof NoteError)
        throw appError(e.code, e.message);
      throw e;
    }
  }
  var noteOrFail = (id) => findNote(id) ?? fail("note.not_found", `no note ${id}`);
  var full = (n) => ({ ...summaryOf(n), body: n.body, created_at: n.createdAt, last_edit: n.lastEdit });
  var list = (args = {}) => run(async () => {
    const query = str(args, "query") ?? "";
    const ws = args.workspace === undefined ? null : await resolveWorkspace(args.workspace);
    const limit = Math.min(200, Math.max(1, Number(args.limit ?? 50) || 50));
    const pool = ws ? notes().filter((n) => n.workspace?.id === ws.id) : notes();
    const picked = query.trim() ? searchNotes(pool, query, limit).map((h) => h.note) : sortNotes(pool, sortOrder()).slice(0, limit);
    return { notes: picked.map(summaryOf), total: pool.length, storage: backend() };
  });
  var read = (args = {}) => run(async () => full(noteOrFail(str(args, "id", { required: true }))));
  var create = (args = {}, ctx) => run(async () => {
    const title = str(args, "title", { max: LIMITS.titleChars }) ?? "";
    const body = str(args, "body", { max: LIMITS.bodyChars }) ?? "";
    if (!title.trim() && !body.trim())
      fail("invalid_params", "give a title or a body");
    const workspace = await resolveWorkspace(args.workspace);
    const note = await commit({ kind: "create", id: newNoteId(), title, body, workspace, pinned: args.pinned === true }, stampOf(ctx));
    return summaryOf(note);
  });
  var capture = (args = {}, ctx) => run(async () => {
    const text = str(args, "text", { required: true, max: LIMITS.bodyChars });
    const workspace = await resolveWorkspace(args.workspace);
    const note = await commit({ kind: "create", id: newNoteId(), body: text.trim(), workspace }, stampOf(ctx));
    return summaryOf(note);
  });
  var append = (args = {}, ctx) => run(async () => {
    const text = str(args, "text", { required: true, max: LIMITS.appendChars });
    const id = str(args, "id");
    if (!!id === (args.workspace !== undefined))
      fail("invalid_params", "give exactly one of id or workspace");
    const stamp = stampOf(ctx);
    let note;
    if (id)
      note = await commit({ kind: "append", id, text }, stamp);
    else {
      const ws = await resolveWorkspace(args.workspace);
      note = await appendToScratchpad(ws, text, stamp);
    }
    return summaryOf(note);
  });
  var pin = (args = {}, ctx) => run(async () => {
    const id = str(args, "id", { required: true });
    noteOrFail(id);
    const note = await commit({ kind: "setPinned", id, pinned: args.pinned !== false }, stampOf(ctx));
    return summaryOf(note);
  });
  var search = (args = {}) => run(async () => {
    const query = str(args, "query", { required: true });
    const limit = Math.min(50, Math.max(1, Number(args.limit ?? 20) || 20));
    return {
      results: searchNotes(notes(), query, limit).map((h) => ({
        id: h.note.id,
        title: titleOf(h.note),
        subtitle: h.note.workspace?.name ?? null,
        snippet: h.snippet || previewOf(h.note, 80),
        score: h.score,
        symbol: h.note.pinned ? "pin.fill" : "note.text",
        updated_at: h.note.updatedAt,
        open: { command: "cmux/notes#open", args: { id: h.note.id } }
      }))
    };
  });
  var exportNotes = (args = {}) => run(async () => {
    const id = str(args, "id");
    const picked = id ? [noteOrFail(id)] : notes().slice().sort((a, b) => a.createdAt - b.createdAt || (a.id < b.id ? -1 : 1));
    const used = new Set;
    const files = picked.map((n) => {
      let name = fileNameOf(n);
      for (let i = 2;used.has(name); i++)
        name = fileNameOf(n).replace(/\.md$/, `-${i}.md`);
      used.add(name);
      return { id: n.id, name, text: toMarkdown(n) };
    });
    return { files };
  });
  var newNote = (_args = {}, ctx) => run(async () => {
    const note = await commit({ kind: "create", id: newNoteId() }, stampOf(ctx));
    requestSelect(note.id);
    return { id: note.id };
  });
  var open = (args = {}) => run(async () => {
    const id = str(args, "id", { required: true });
    noteOrFail(id);
    requestSelect(id);
    return { id };
  });
  var cycleVariant2 = () => cycleVariant();
  function ageText(n) {
    const a = age(n.updatedAt, Date.now());
    if (a.unit === "now")
      return t("time.now", "now");
    if (a.unit === "minutes")
      return t("time.minutes", "{n}m", { n: a.n });
    if (a.unit === "hours")
      return t("time.hours", "{n}h", { n: a.n });
    return t("time.days", "{n}d", { n: a.n });
  }
  function metaLine(n, vs) {
    const parts = [];
    if (n.workspace)
      parts.push(vs.ws.liveName(n.workspace.id) ?? t("scratchpad.closed", "{name} (closed)", { name: n.workspace.name }));
    parts.push(ageText(n));
    if (n.lastEdit.via === "command" && (n.lastEdit.actor ?? "").startsWith("agent:"))
      parts.push(t("edited.agent", "Edited by an agent"));
    return parts.join(" · ");
  }
  function editor(id, vs, opts) {
    const note = noteById(id);
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 6 }, [
        opts.back ? Button(Icon("chevron.left").secondary(), () => vs.select(null)).help(t("action.back", "Back")) : null,
        TextField(() => note().title, {
          placeholder: deriveTitle(note().body) || t("title.placeholder", "Title"),
          onSubmit: (title) => edit2({ kind: "setTitle", id: id(), title })
        }).font("headline").layoutPriority(1),
        Button(Icon(() => note().pinned ? "pin.fill" : "pin").color(() => note().pinned ? "accent" : "secondary"), () => edit2({ kind: "setPinned", id: id(), pinned: !note().pinned })).help(() => note().pinned ? t("action.unpin", "Unpin") : t("action.pin", "Pin"))
      ]).contextMenu(() => noteMenu(note(), vs)),
      Text(() => metaLine(note(), vs)).font("caption").secondary().lineLimit(1),
      Divider(),
      noteBody(id, vs, { maxLines: () => 200 })
    ]);
  }
  function renderSplit(vs, opts) {
    const selectedId = computed(() => {
      const id = vs.selected();
      return id && findNote(id) ? id : null;
    });
    const list = VStack({ spacing: 6 }, [listHeader(vs), notesList(vs, { inlineDetail: false, showWorkspace: true })]);
    if (opts.wide) {
      return HStack({ spacing: 0 }, [
        VStack({ spacing: 0 }, [list, Spacer()]).frame({ width: 240, maxHeight: "infinity" }).padding(8),
        Divider(),
        VStack({ spacing: 0 }, [
          () => {
            const id = selectedId();
            return id ? editor(() => id, vs, { back: false }) : EmptyState({ title: t("empty.select", "Select a note"), symbol: "note.text" });
          },
          Spacer()
        ]).padding(12).frame({ maxWidth: "infinity", maxHeight: "infinity" })
      ]);
    }
    return Group([
      () => {
        const id = selectedId();
        return id ? editor(() => id, vs, { back: true }) : list;
      }
    ]);
  }
  function prepare(ctx) {
    setLanguage(detectLanguage(ctx));
    ensureLoaded().catch(() => {
      return;
    });
    return createViewState(ctx);
  }
  function renderNotes(ctx = {}) {
    const vs = prepare(ctx);
    const failed = computed(() => loadError() !== null);
    return VStack({ spacing: 6 }, [
      statusRow(),
      () => {
        if (failed())
          return null;
        switch (variant()) {
          case "list":
            return VStack({ spacing: 6 }, [listHeader(vs), notesList(vs, { inlineDetail: true, showWorkspace: true })]);
          case "split":
            return renderSplit(vs, { wide: false });
          default:
            return renderScratchpad(vs);
        }
      }
    ]);
  }
  function renderNotesPane(ctx = {}) {
    const vs = prepare(ctx);
    return VStack({ spacing: 0 }, [statusRow(), renderSplit(vs, { wide: true })]);
  }
  var list2 = list;
  var read2 = read;
  var create2 = create;
  var capture2 = capture;
  var append2 = append;
  var pin2 = pin;
  var search2 = search;
  var exportNotes2 = exportNotes;
  var newNote2 = newNote;
  var open2 = open;
  var cycleVariant3 = cycleVariant2;
  globalThis.__cmuxAppExports = { ...exports_main };
})();
