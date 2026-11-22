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
    addFolder: () => addFolder2,
    connectHost: () => connectHost,
    cycleVariant: () => cycleVariant2,
    openFinder: () => openFinder,
    renderFiles: () => renderFiles,
    renderFinder: () => renderFinder
  });
  var MISSING = new Set(["operation.unsupported", "scope.missing"]);
  function toOpError(e, op = "") {
    const err = e;
    const code = typeof err?.code === "string" ? err.code : "internal";
    const message = typeof err?.message === "string" ? err.message : String(e);
    return { code, message, missing: MISSING.has(code), retryable: err?.retryable === true, op };
  }
  async function call(name, params = {}, options = {}) {
    try {
      return { ok: true, value: await cmux.call(name, params, options) };
    } catch (e) {
      return { ok: false, error: toOpError(e, name) };
    }
  }
  var ops = {
    hosts: () => call("host.list"),
    connect: (gesture, conn) => call("host.connect", conn ? { conn } : {}, { gesture: gesture ?? undefined }),
    disconnect: (conn) => call("host.disconnect", { conn }),
    roots: () => call("fs.roots.list"),
    pickRoot: (gesture, conn) => call("fs.root.pick", { mode: "folder", ...conn ? { conn } : {} }, { gesture: gesture ?? undefined }),
    list: (w, sort, filter, limit, cursor, listing) => call("fs.list", {
      ...w,
      sort: { key: sort.key, dir: sort.dir, dirs_first: sort.dirsFirst },
      filter: { query: filter.query || undefined, hidden: filter.hidden },
      limit,
      ...cursor ? { cursor, listing } : {}
    }),
    read: (w, maxBytes) => call("fs.read", { ...w, max_bytes: maxBytes }),
    thumbnail: (w, size) => call("fs.thumbnail", { ...w, size }),
    mkdir: (w, name, gesture) => call("fs.mkdir", { ...w, name }, { gesture: gesture ?? undefined }),
    rename: (w, name, gesture) => call("fs.rename", { ...w, name }, { gesture: gesture ?? undefined }),
    transfer: (op, from, to, gesture) => call(`fs.${op}`, { from, to, conflict: "ask" }, { gesture: gesture ?? undefined }),
    trash: (w, gesture) => call("fs.trash", w, { gesture: gesture ?? undefined }),
    jobs: () => call("fs.job.list"),
    cancelJob: (job) => call("fs.job.cancel", { job }),
    resolveJob: (job, choice, applyToAll, gesture) => call("fs.job.resolve", { job, choice, apply_to_all: applyToAll }, { gesture: gesture ?? undefined }),
    undo: (undo, gesture) => call("fs.undo", { undo }, { gesture: gesture ?? undefined }),
    openDocument: (w, gesture) => call("document.open", { ...w, show: true }, { gesture: gesture ?? undefined }),
    dropOnTerminal: (items, gesture) => call("terminal.drop", { items }, { gesture: gesture ?? undefined }),
    attachToAgent: (items, gesture) => call("agent.attach", { items }, { gesture: gesture ?? undefined }),
    openPane: (gesture) => call("app.pane.open", { kind: "browser" }, { gesture: gesture ?? undefined })
  };

  // first-party-apps/finder/strings/en.json
  var en_default = {
    "action.retry": "Try Again",
    "action.up": "Enclosing Folder",
    "column.kind": "Kind",
    "column.modified": "Date Modified",
    "column.name": "Name",
    "column.size": "Size",
    "conflict.applyAll": "Apply to all",
    "conflict.compare": "Existing {existing}, new {incoming}",
    "conflict.keepBoth": "Keep Both",
    "conflict.replace": "Replace",
    "conflict.skip": "Skip",
    "conflict.title": "“{name}” already exists in {destination}",
    "conn.connecting": "Connecting to {name}…",
    "conn.disconnected": "{name} is not connected",
    "conn.needsAuth": "{name} needs you to sign in",
    "conn.unreachable": "{name} is unreachable",
    "conn.verifying": "Waiting for host key confirmation for {name}",
    "date.today": "Today {time}",
    "dual.copyLeft": "← Copy",
    "dual.copyRight": "Copy →",
    "dual.moveLeft": "← Move",
    "dual.moveRight": "Move →",
    "duration.hours": "{n} h left",
    "duration.minutes": "{n} min left",
    "duration.seconds": "{n} s left",
    "error.denied": "You do not have permission to see this folder",
    "error.load": "Cannot open this folder",
    "error.missingHint": "This cmux does not provide {op} yet.",
    "error.missingOp": "{op} is not available in this version of cmux.",
    "error.missingTitle": "File access is not available yet",
    "favorites.missing": "Adding folders needs a newer cmux.",
    "hosts.disconnect": "Disconnect",
    "hosts.missing": "Connecting to hosts needs a newer cmux.",
    "job.bytes": "{done} of {total}",
    "job.cancel": "Stop",
    "job.cancelled": "Stopped",
    "job.cancelling": "Stopping…",
    "job.copied": "Copied {subject} to {destination}",
    "job.copying": "Copying {subject} to {destination}",
    "job.crossHost": "between hosts",
    "job.deleted": "Deleted {subject}",
    "job.deleting": "Deleting {subject}",
    "job.dismiss": "Dismiss",
    "job.failed": "Failed",
    "job.items": "{done} of {total} items",
    "job.more": "{n} more operations",
    "job.moved": "Moved {subject} to {destination}",
    "job.moving": "Moving {subject} to {destination}",
    "job.preparing": "Preparing…",
    "job.queued": "Waiting",
    "job.trashed": "Moved {subject} to the Trash",
    "job.trashing": "Moving {subject} to the Trash",
    "job.undo": "Undo",
    "kind.archive": "Archive",
    "kind.code": "Source code",
    "kind.folder": "Folder",
    "kind.image": "Image",
    "kind.markdown": "Markdown",
    "kind.media": "Media",
    "kind.other": "Document",
    "kind.pdf": "PDF document",
    "kind.text": "Text",
    "list.next": "Next page",
    "list.prev": "Previous page",
    "list.range": "{from}–{to} of {total}",
    "menu.attachAgent": "Attach to Agent",
    "menu.copy": "Copy",
    "menu.cut": "Cut",
    "menu.insertPath": "Insert Path in Terminal",
    "menu.open": "Open",
    "menu.rename": "Rename",
    "menu.trash": "Move to Trash",
    "pathbar.none": "No folder",
    "pathbar.root": "Root",
    "preview.binary": "No text preview for this file.",
    "preview.dimensions": "{w} × {h}",
    "preview.missing": "Previews need a newer cmux.",
    "preview.modified": "Modified",
    "preview.noViewer": "No viewer app for this kind of file.",
    "preview.none": "No selection",
    "preview.pages": "{w} × {h} · {n} pages",
    "preview.size": "Size",
    "preview.tooLarge": "Too large to preview.",
    "preview.truncated": "Preview shows the start of the file.",
    "refuse.intoItself": "A folder cannot go inside itself.",
    "refuse.other": "This drop is not possible.",
    "refuse.readOnly": "This folder is read-only.",
    "refuse.samePlace": "The items are already here.",
    "rename.placeholder": "New name",
    "sidebar.addFolder": "Add Folder…",
    "sidebar.connect": "Connect to Host…",
    "sidebar.favorites": "Favorites",
    "sidebar.hosts": "Hosts",
    "sidebar.missing": "Files needs a newer cmux",
    "sidebar.missingHint": "This cmux cannot list folders or hosts for apps yet.",
    "sidebar.recent": "Recent",
    "size.bytes": "{n} bytes",
    "state.empty": "Folder is empty",
    "state.loading": "Loading…",
    "state.noFolder": "No folder open",
    "state.noFolderHint": "Pick a place in the sidebar or add a folder.",
    "state.noMatches": "No matches",
    "status.items": "{n} items",
    "status.refreshing": "refreshing",
    "status.selected": "{n} selected",
    "toolbar.filter": "Filter",
    "toolbar.hidden": "Show Hidden Files",
    "toolbar.newFolder": "New Folder",
    "toolbar.newFolderName": "Folder name",
    "toolbar.paste": "Paste",
    "toolbar.trash": "Move to Trash"
  };

  // first-party-apps/finder/strings/ja.json
  var ja_default = {
    "action.retry": "再試行",
    "action.up": "親フォルダ",
    "column.kind": "種類",
    "column.modified": "変更日",
    "column.name": "名前",
    "column.size": "サイズ",
    "conflict.applyAll": "すべてに適用",
    "conflict.compare": "既存 {existing}、新規 {incoming}",
    "conflict.keepBoth": "両方を残す",
    "conflict.replace": "置き換える",
    "conflict.skip": "スキップ",
    "conflict.title": "「{name}」は{destination}にすでにあります",
    "conn.connecting": "{name}に接続中…",
    "conn.disconnected": "{name}は接続されていません",
    "conn.needsAuth": "{name}にサインインが必要です",
    "conn.unreachable": "{name}に到達できません",
    "conn.verifying": "{name}のホスト鍵の確認を待っています",
    "date.today": "今日 {time}",
    "dual.copyLeft": "← コピー",
    "dual.copyRight": "コピー →",
    "dual.moveLeft": "← 移動",
    "dual.moveRight": "移動 →",
    "duration.hours": "残り{n}時間",
    "duration.minutes": "残り{n}分",
    "duration.seconds": "残り{n}秒",
    "error.denied": "このフォルダを表示する権限がありません",
    "error.load": "このフォルダを開けません",
    "error.missingHint": "このcmuxはまだ{op}を提供していません。",
    "error.missingOp": "このバージョンのcmuxでは{op}を使用できません。",
    "error.missingTitle": "ファイルアクセスはまだ使用できません",
    "favorites.missing": "フォルダの追加には新しいcmuxが必要です。",
    "hosts.disconnect": "切断",
    "hosts.missing": "ホストへの接続には新しいcmuxが必要です。",
    "job.bytes": "{done} / {total}",
    "job.cancel": "停止",
    "job.cancelled": "停止しました",
    "job.cancelling": "停止中…",
    "job.copied": "{subject}を{destination}にコピーしました",
    "job.copying": "{subject}を{destination}にコピー中",
    "job.crossHost": "ホスト間",
    "job.deleted": "{subject}を削除しました",
    "job.deleting": "{subject}を削除中",
    "job.dismiss": "閉じる",
    "job.failed": "失敗しました",
    "job.items": "{done} / {total} 項目",
    "job.more": "ほか{n}件の操作",
    "job.moved": "{subject}を{destination}に移動しました",
    "job.moving": "{subject}を{destination}に移動中",
    "job.preparing": "準備中…",
    "job.queued": "待機中",
    "job.trashed": "{subject}をゴミ箱に入れました",
    "job.trashing": "{subject}をゴミ箱に入れています",
    "job.undo": "取り消す",
    "kind.archive": "アーカイブ",
    "kind.code": "ソースコード",
    "kind.folder": "フォルダ",
    "kind.image": "イメージ",
    "kind.markdown": "Markdown",
    "kind.media": "メディア",
    "kind.other": "書類",
    "kind.pdf": "PDF書類",
    "kind.text": "テキスト",
    "list.next": "次のページ",
    "list.prev": "前のページ",
    "list.range": "{total}件中 {from}–{to}",
    "menu.attachAgent": "エージェントに添付",
    "menu.copy": "コピー",
    "menu.cut": "カット",
    "menu.insertPath": "ターミナルにパスを挿入",
    "menu.open": "開く",
    "menu.rename": "名前を変更",
    "menu.trash": "ゴミ箱に入れる",
    "pathbar.none": "フォルダなし",
    "pathbar.root": "ルート",
    "preview.binary": "このファイルのテキストプレビューはありません。",
    "preview.dimensions": "{w} × {h}",
    "preview.missing": "プレビューには新しいcmuxが必要です。",
    "preview.modified": "変更日",
    "preview.noViewer": "この種類のファイルのビューアアプリがありません。",
    "preview.none": "選択なし",
    "preview.pages": "{w} × {h} · {n}ページ",
    "preview.size": "サイズ",
    "preview.tooLarge": "大きすぎてプレビューできません。",
    "preview.truncated": "プレビューはファイルの先頭のみです。",
    "refuse.intoItself": "フォルダをそれ自身の中に入れることはできません。",
    "refuse.other": "ここにはドロップできません。",
    "refuse.readOnly": "このフォルダは読み取り専用です。",
    "refuse.samePlace": "項目はすでにここにあります。",
    "rename.placeholder": "新しい名前",
    "sidebar.addFolder": "フォルダを追加…",
    "sidebar.connect": "ホストに接続…",
    "sidebar.favorites": "よく使う項目",
    "sidebar.hosts": "ホスト",
    "sidebar.missing": "ファイルには新しいcmuxが必要です",
    "sidebar.missingHint": "このcmuxはまだアプリにフォルダやホストを一覧表示できません。",
    "sidebar.recent": "最近使った項目",
    "size.bytes": "{n}バイト",
    "state.empty": "フォルダは空です",
    "state.loading": "読み込み中…",
    "state.noFolder": "開いているフォルダはありません",
    "state.noFolderHint": "サイドバーで場所を選ぶか、フォルダを追加してください。",
    "state.noMatches": "一致する項目はありません",
    "status.items": "{n}項目",
    "status.refreshing": "更新中",
    "status.selected": "{n}項目を選択",
    "toolbar.filter": "絞り込み",
    "toolbar.hidden": "隠しファイルを表示",
    "toolbar.newFolder": "新規フォルダ",
    "toolbar.newFolderName": "フォルダ名",
    "toolbar.paste": "ペースト",
    "toolbar.trash": "ゴミ箱に入れる"
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
  var VARIANTS = ["listPreview", "columns", "dualPane"];
  var DEFAULT_VARIANT = "listPreview";
  var [variantOverride, setVariantOverride] = signal(null);
  var setting = (key) => cmux.app.settings()[key];
  var variant = () => {
    const v = variantOverride() ?? setting("variant");
    return VARIANTS.includes(v) ? v : DEFAULT_VARIANT;
  };
  var showPreview = () => setting("showPreview") !== false;
  var nextVariant = (v) => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length];
  async function cycleVariant() {
    const next = nextVariant(variant());
    setVariantOverride(next);
    let persisted = false;
    try {
      await cmux.app.settings.set({ variant: next });
      persisted = true;
    } catch {
      persisted = false;
    }
    return { variant: next, persisted };
  }
  class PathError extends Error {
    code;
    constructor(code, message) {
      super(message);
      this.code = code;
    }
  }
  function validName(name) {
    return name.length > 0 && name.length <= 255 && name !== "." && name !== ".." && !/[/\u0000]/.test(name);
  }
  function normalizeRel(path) {
    const out = [];
    for (const seg of path.split("/")) {
      if (seg === "" || seg === ".")
        continue;
      if (seg === "..")
        throw new PathError("path.escapes_root", "a relative path may not contain ..");
      if (seg.includes("\x00"))
        throw new PathError("path.invalid_name", "a path may not contain NUL");
      out.push(seg);
    }
    return out.join("/");
  }
  function join(path, name) {
    if (!validName(name))
      throw new PathError("path.invalid_name", `invalid name: ${JSON.stringify(name)}`);
    const base = normalizeRel(path);
    return base === "" ? name : `${base}/${name}`;
  }
  function parent(path) {
    const p = normalizeRel(path);
    if (p === "")
      return null;
    const i = p.lastIndexOf("/");
    return i < 0 ? "" : p.slice(0, i);
  }
  function extension(name) {
    const i = name.lastIndexOf(".");
    return i <= 0 ? "" : name.slice(i + 1).toLowerCase();
  }
  function crumbs(rootLabel, path) {
    const out = [{ label: rootLabel, path: "" }];
    let acc = "";
    for (const seg of normalizeRel(path).split("/").filter(Boolean)) {
      acc = acc === "" ? seg : `${acc}/${seg}`;
      out.push({ label: seg, path: acc });
    }
    return out;
  }
  function collapseCrumbs(list, keep = 3) {
    if (list.length <= keep + 1)
      return list;
    return [list[0], null, ...list.slice(list.length - keep)];
  }
  function displayPath(rootDisplay, path) {
    const rel = normalizeRel(path);
    if (rel === "")
      return rootDisplay;
    return rootDisplay.endsWith("/") ? `${rootDisplay}${rel}` : `${rootDisplay}/${rel}`;
  }
  var sameLocation = (a, b) => !!a && !!b && a.conn === b.conn && a.root === b.root && normalizeRel(a.path) === normalizeRel(b.path);
  var locationKey = (l) => `${l.conn}|${l.root}|${normalizeRel(l.path)}`;
  var TERMINAL = ["done", "failed", "cancelled"];
  var isTerminal = (j) => TERMINAL.includes(j.phase);
  function newJob(init) {
    return {
      ...init,
      phase: "queued",
      seq: 0,
      bytes: { done: 0, total: null },
      items: { done: 0, total: null },
      current: null,
      eta: null,
      conflict: null,
      pending: null,
      error: null,
      undo: null,
      startedAt: init.at,
      updatedAt: init.at
    };
  }
  var ALLOWED = {
    preparing: ["queued"],
    progress: ["queued", "preparing", "running", "conflict"],
    conflict: ["preparing", "running"],
    resolved: ["conflict"],
    cancelling: ["queued", "preparing", "running", "conflict"],
    done: ["queued", "preparing", "running", "cancelling"],
    failed: ["queued", "preparing", "running", "conflict", "cancelling"],
    cancelled: ["queued", "preparing", "running", "conflict", "cancelling"]
  };
  function reduceJob(j, a) {
    switch (a.type) {
      case "requestCancel":
        return isTerminal(j) || j.phase === "cancelling" ? j : { ...j, pending: "cancel" };
      case "requestResolve":
        return j.phase === "conflict" ? { ...j, pending: "resolve" } : j;
      case "requestFailed":
        return { ...j, pending: null, error: a.error };
    }
    const ev = a.event;
    if (ev.seq <= j.seq || isTerminal(j) || !ALLOWED[ev.kind].includes(j.phase))
      return j;
    const base = { ...j, seq: ev.seq, updatedAt: a.at };
    switch (ev.kind) {
      case "preparing":
        return { ...base, phase: "preparing", items: { done: 0, total: ev.items_total ?? null }, bytes: { done: 0, total: ev.bytes_total ?? null } };
      case "progress":
        return {
          ...base,
          phase: j.phase === "conflict" ? "conflict" : "running",
          bytes: { done: Math.max(j.bytes.done, ev.bytes_done), total: ev.bytes_total ?? j.bytes.total },
          items: { done: Math.max(j.items.done, ev.items_done), total: ev.items_total ?? j.items.total },
          current: ev.current ?? j.current,
          eta: ev.eta_s ?? null
        };
      case "conflict":
        return { ...base, phase: "conflict", conflict: ev.conflict, pending: null };
      case "resolved":
        return { ...base, phase: "running", conflict: null, pending: null };
      case "cancelling":
        return { ...base, phase: "cancelling", pending: null };
      case "done":
        return {
          ...base,
          phase: "done",
          pending: null,
          conflict: null,
          current: null,
          undo: ev.undo ?? null,
          items: { done: ev.items_done ?? j.items.total ?? j.items.done, total: j.items.total },
          bytes: { done: ev.bytes_done ?? j.bytes.total ?? j.bytes.done, total: j.bytes.total }
        };
      case "failed":
        return { ...base, phase: "failed", pending: null, error: ev.error, current: null };
      case "cancelled":
        return { ...base, phase: "cancelled", pending: null, conflict: null, current: null };
    }
  }
  function fraction(j) {
    if (j.phase === "done")
      return 1;
    if (j.bytes.total && j.bytes.total > 0)
      return Math.min(1, j.bytes.done / j.bytes.total);
    if (j.items.total && j.items.total > 0)
      return Math.min(1, j.items.done / j.items.total);
    return null;
  }
  function secondsLeft(j, now) {
    if (j.phase !== "running")
      return null;
    if (j.eta !== null)
      return j.eta;
    if (!j.bytes.total || j.bytes.done <= 0)
      return null;
    const elapsed = (now - j.startedAt) / 1000;
    if (elapsed < 1)
      return null;
    const rate = j.bytes.done / elapsed;
    return rate > 0 ? Math.ceil((j.bytes.total - j.bytes.done) / rate) : null;
  }
  var canCancel = (j) => !isTerminal(j) && j.phase !== "cancelling" && j.pending !== "cancel";
  var canUndo = (j) => j.phase === "done" && !!j.undo;
  var [conns, setConns] = signal([]);
  var [roots, setRoots] = signal([]);
  var [recent, setRecent] = signal([]);
  var [jobs, setJobs] = signal({});
  var [sidebarError, setSidebarError] = signal(null);
  var [loaded, setLoaded] = signal(false);
  var [request, setRequest] = signal(null);
  var [notice, setNotice] = signal(null);
  var connById = (id) => conns().find((c) => c.conn === id) ?? null;
  var rootById = (id) => roots().find((r) => r.root === id) ?? null;
  var started = false;
  var seq = 0;
  function start() {
    if (started)
      return;
    started = true;
    refreshSidebar();
    cmux.events.on("host.watch", (p) => {
      const c = p?.conn;
      if (c && typeof c.conn === "string")
        upsertConn(c);
    });
    cmux.events.on("fs.roots.watch", () => void refreshRoots());
    cmux.events.on("fs.job", (p) => {
      const m = p;
      if (m?.job && m.event)
        dispatchJob(m.job, { type: "event", event: m.event, at: Date.now() });
    });
  }
  async function refreshSidebar() {
    const [h, r, j] = await Promise.all([ops.hosts(), ops.roots(), ops.jobs()]);
    if (h.ok)
      setConns(h.value.conns ?? []);
    if (r.ok)
      setRoots(r.value.roots ?? []);
    if (j.ok)
      setJobs(Object.fromEntries((j.value.jobs ?? []).map((s) => [s.job, fromSnapshot(s)])));
    setSidebarError(!h.ok ? h.error : !r.ok ? r.error : null);
    try {
      const stored = await cmux.storage.get("recent");
      if (Array.isArray(stored))
        setRecent(stored.slice(0, 8));
    } catch {}
    setLoaded(true);
  }
  async function refreshRoots() {
    const r = await ops.roots();
    if (r.ok)
      setRoots(r.value.roots ?? []);
  }
  function upsertConn(c) {
    setConns((list) => list.some((x) => x.conn === c.conn) ? list.map((x) => x.conn === c.conn ? c : x) : [...list, c]);
  }
  function addRoot(r) {
    setRoots((list) => list.some((x) => x.root === r.root) ? list : [...list, r]);
  }
  function navigate(location) {
    setRequest({ location, seq: ++seq });
  }
  function remember(location, label) {
    const next = [{ ...location, label }, ...recent().filter((r) => !sameLocation(r, location))].slice(0, 8);
    setRecent(next);
    cmux.storage.set("recent", next).catch(() => {
      return;
    });
  }
  function flash(message) {
    setNotice(message);
  }
  function fromSnapshot(s) {
    const j = newJob({ id: s.job, op: s.op, subject: s.subject, destination: s.destination, crossHost: s.cross_host, at: s.started_at });
    return {
      ...j,
      phase: s.phase,
      seq: s.seq,
      bytes: { done: s.bytes_done, total: s.bytes_total },
      items: { done: s.items_done, total: s.items_total },
      current: s.current,
      eta: s.eta_s ?? null,
      conflict: s.conflict,
      undo: s.undo
    };
  }
  function trackJob(job) {
    setJobs((all) => all[job.id] ? all : { ...all, [job.id]: job });
  }
  function dispatchJob(id, action) {
    setJobs((all) => all[id] ? { ...all, [id]: reduceJob(all[id], action) } : all);
  }
  function dismissJob(id) {
    setJobs((all) => {
      const { [id]: _gone, ...rest } = all;
      return rest;
    });
  }
  var jobList = () => Object.values(jobs()).sort((a, b) => a.startedAt - b.startedAt);
  var MAX_DRAG_ITEMS = 1000;
  function buildDragPayload(location, rootDisplay, names, entries, rootRights) {
    const byName = new Map(entries.map((e) => [e.name, e]));
    const picked = names.filter((n) => byName.has(n));
    const items = picked.slice(0, MAX_DRAG_ITEMS).map((name) => {
      const e = byName.get(name);
      const path = normalizeRel(location.path === "" ? name : `${location.path}/${name}`);
      return {
        kind: "file",
        ref: { conn: location.conn, root: location.root, path },
        display: displayPath(rootDisplay, path),
        name,
        dir: e.kind === "dir" || e.kind === "symlink" && e.target_kind === "dir"
      };
    });
    return { kinds: ["file"], items, operations: rootRights === "read_write" ? ["copy", "move", "reference"] : ["copy", "reference"], truncated: picked.length > items.length };
  }
  var within = (child, parentPath) => parentPath === "" || child === parentPath || child.startsWith(`${parentPath}/`);
  var parentOf = (path) => path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
  var intersect = (a, b) => a === "read_write" && b === "read_write" ? "read_write" : "read";
  function planDrop(payload, target, sourceRights) {
    if (payload.items.length === 0)
      return { action: "refuse", reason: "empty" };
    const refs = payload.items.map((i) => i.ref);
    switch (target.kind) {
      case "folder": {
        if (!target.writable)
          return { action: "refuse", reason: "read_only" };
        const to = { ...target.location, path: normalizeRel(target.location.path) };
        const sameRoot = refs.every((r) => r.conn === to.conn && r.root === to.root);
        if (sameRoot && refs.some((r) => r.path !== "" && within(to.path, r.path)))
          return { action: "refuse", reason: "into_itself" };
        if (sameRoot && refs.every((r) => parentOf(r.path) === to.path))
          return { action: "refuse", reason: "same_place" };
        const crossHost = refs.some((r) => r.conn !== to.conn);
        const canMove = payload.operations.includes("move");
        const action = !crossHost && canMove ? "move" : "copy";
        const alternatives = canMove ? ["copy", "move"] : ["copy"];
        return { action, to, crossHost, alternatives };
      }
      case "terminal":
        return refs.every((r) => r.conn === target.conn) ? { action: "insert_path", refs } : { action: "copy_then_insert", refs, to: "terminal_drop_folder" };
      case "agent":
        if (!target.accepts.includes("file"))
          return { action: "refuse", reason: "kind_not_accepted" };
        if (!target.grant)
          return { action: "refuse", reason: "no_file_access" };
        return { action: "attach", refs, rights: intersect(sourceRights, target.grant) };
    }
  }
  var [clip, setClip] = signal(null);
  var fail = (e) => {
    flash(e.missing ? t("error.missingOp", "{op} is not available in this version of cmux.", { op: e.op }) : e.message);
    return false;
  };
  function refuseMessage(reason) {
    switch (reason) {
      case "read_only":
        return t("refuse.readOnly", "This folder is read-only.");
      case "into_itself":
        return t("refuse.intoItself", "A folder cannot go inside itself.");
      case "same_place":
        return t("refuse.samePlace", "The items are already here.");
      default:
        return t("refuse.other", "This drop is not possible.");
    }
  }
  function payloadFor(b, names = b.selection()) {
    const loc = b.location();
    const root = b.root();
    if (!loc || !root)
      return null;
    return buildDragPayload(loc, root.display, names, b.allRows(), root.rights);
  }
  async function openEntry(b, name, gesture) {
    const e = b.allRows().find((x) => x.name === name);
    const loc = b.location();
    if (!e || !loc)
      return false;
    if (e.kind === "dir" || e.kind === "symlink" && e.target_kind === "dir") {
      b.into(name);
      remember({ ...loc, path: join(loc.path, name) }, name);
      return true;
    }
    const r = await ops.openDocument({ ...loc, path: join(loc.path, name) }, gesture);
    return r.ok ? true : fail(r.error);
  }
  async function transferPayload(op, payload, rights, to, toWritable, gesture) {
    const plan = planDrop(payload, { kind: "folder", location: to, writable: toWritable }, rights);
    if (plan.action === "refuse" && !(plan.reason === "same_place" && op === "copy")) {
      flash(refuseMessage(plan.reason));
      return false;
    }
    const first = payload.items[0].ref;
    const from = { conn: first.conn, root: first.root, paths: payload.items.map((i) => i.ref.path) };
    const r = await ops.transfer(op, from, to, gesture);
    if (!r.ok)
      return fail(r.error);
    trackJob(newJob({ id: r.value.job, op, subject: r.value.subject, destination: r.value.destination, crossHost: r.value.cross_host, at: Date.now() }));
    return true;
  }
  async function transfer(op, from, names, to, toWritable, gesture) {
    const payload = payloadFor(from, names);
    return payload ? transferPayload(op, payload, from.root()?.rights ?? "read", to, toWritable, gesture) : false;
  }
  function copySelection(b, op) {
    const payload = payloadFor(b);
    if (payload && payload.items.length > 0)
      setClip({ op, payload, rights: b.root()?.rights ?? "read" });
  }
  async function paste(into, gesture) {
    const c = clip();
    const to = into.location();
    if (!c || !to)
      return false;
    const ok = await transferPayload(c.op, c.payload, c.rights, to, into.root()?.rights === "read_write", gesture);
    if (ok && c.op === "move")
      setClip(null);
    return ok;
  }
  async function trash(b, gesture) {
    const loc = b.location();
    const names = b.selection();
    if (!loc || names.length === 0)
      return false;
    const r = await ops.trash({ conn: loc.conn, root: loc.root, paths: names.map((n) => join(loc.path, n)) }, gesture);
    if (!r.ok)
      return fail(r.error);
    trackJob(newJob({ id: r.value.job, op: "trash", subject: r.value.subject, destination: r.value.destination, crossHost: false, at: Date.now() }));
    b.select(null);
    return true;
  }
  async function newFolder(b, name, gesture) {
    const loc = b.location();
    if (!loc || !name.trim())
      return false;
    const r = await ops.mkdir(loc, name.trim(), gesture);
    if (!r.ok)
      return fail(r.error);
    b.select(r.value.entry.name);
    return true;
  }
  async function rename(b, from, to, gesture) {
    const loc = b.location();
    if (!loc || !to.trim() || to === from)
      return false;
    const r = await ops.rename({ ...loc, path: join(loc.path, from) }, to.trim(), gesture);
    if (!r.ok)
      return fail(r.error);
    b.select(r.value.entry.name);
    return true;
  }
  async function sendToTerminal(b, gesture) {
    const p = payloadFor(b);
    if (!p || p.items.length === 0)
      return false;
    const r = await ops.dropOnTerminal(p.items, gesture);
    return r.ok ? true : fail(r.error);
  }
  async function sendToAgent(b, gesture) {
    const p = payloadFor(b);
    if (!p || p.items.length === 0)
      return false;
    const r = await ops.attachToAgent(p.items, gesture);
    return r.ok ? true : fail(r.error);
  }
  async function cancelJob(id) {
    dispatchJob(id, { type: "requestCancel" });
    const r = await ops.cancelJob(id);
    if (!r.ok)
      dispatchJob(id, { type: "requestFailed", error: r.error });
  }
  async function resolveConflict(id, choice, applyToAll, gesture) {
    dispatchJob(id, { type: "requestResolve" });
    const r = await ops.resolveJob(id, choice, applyToAll, gesture);
    if (!r.ok)
      dispatchJob(id, { type: "requestFailed", error: r.error });
  }
  async function undoJob(undo, gesture) {
    const r = await ops.undo(undo, gesture);
    return r.ok ? true : fail(r.error);
  }
  var DEFAULT_SORT = { key: "name", dir: "asc", dirsFirst: true };
  var DEFAULT_FILTER = { query: "", hidden: false };
  function naturalCompare(a, b) {
    const ax = a.toLowerCase().match(/\d+|\D+/g) ?? [];
    const bx = b.toLowerCase().match(/\d+|\D+/g) ?? [];
    for (let i = 0;i < Math.min(ax.length, bx.length); i++) {
      const x = ax[i];
      const y = bx[i];
      if (x === y)
        continue;
      const xn = /^\d/.test(x);
      const yn = /^\d/.test(y);
      if (xn && yn) {
        const d = Number(x) - Number(y);
        if (d !== 0)
          return d < 0 ? -1 : 1;
        if (x.length !== y.length)
          return x.length < y.length ? -1 : 1;
        continue;
      }
      return x < y ? -1 : 1;
    }
    if (ax.length !== bx.length)
      return ax.length < bx.length ? -1 : 1;
    return a < b ? -1 : a > b ? 1 : 0;
  }
  var isDir = (e) => e.kind === "dir" || e.kind === "symlink" && e.target_kind === "dir";
  var BY_EXT = {
    md: "markdown",
    markdown: "markdown",
    txt: "text",
    log: "text",
    csv: "text",
    json: "code",
    yaml: "code",
    yml: "code",
    toml: "code",
    ts: "code",
    tsx: "code",
    js: "code",
    swift: "code",
    rs: "code",
    go: "code",
    py: "code",
    sh: "code",
    c: "code",
    h: "code",
    zig: "code",
    png: "image",
    jpg: "image",
    jpeg: "image",
    gif: "image",
    webp: "image",
    heic: "image",
    svg: "image",
    pdf: "pdf",
    zip: "archive",
    gz: "archive",
    tgz: "archive",
    tar: "archive",
    xz: "archive",
    zst: "archive",
    mp4: "media",
    mov: "media",
    mp3: "media",
    wav: "media"
  };
  function kindGroup(e) {
    if (isDir(e))
      return "folder";
    return BY_EXT[extension(e.name)] ?? "other";
  }
  function compareEntries(sort) {
    const sign = sort.dir === "asc" ? 1 : -1;
    return (a, b) => {
      if (sort.dirsFirst) {
        const d = Number(isDir(b)) - Number(isDir(a));
        if (d !== 0)
          return d;
      }
      let c = 0;
      switch (sort.key) {
        case "modified":
          c = (a.mtime ?? 0) - (b.mtime ?? 0);
          break;
        case "size":
          c = (a.size ?? -1) - (b.size ?? -1);
          break;
        case "kind":
          c = naturalCompare(kindGroup(a), kindGroup(b)) || naturalCompare(extension(a.name), extension(b.name));
          break;
        default:
          c = 0;
      }
      if (c !== 0)
        return c < 0 ? -sign : sign;
      return sign * naturalCompare(a.name, b.name);
    };
  }
  function matchesFilter(e, f) {
    if (!f.hidden && (e.hidden || e.name.startsWith(".")))
      return false;
    if (f.query && !e.name.toLowerCase().includes(f.query.toLowerCase()))
      return false;
    return true;
  }
  function insertionIndex(sorted, e, cmp) {
    let lo = 0;
    let hi = sorted.length;
    while (lo < hi) {
      const mid = lo + hi >> 1;
      if (cmp(sorted[mid], e) <= 0)
        lo = mid + 1;
      else
        hi = mid;
    }
    return lo;
  }
  function formatBytes(n) {
    if (n === null || n === undefined)
      return "—";
    if (n < 1000)
      return t("size.bytes", "{n} bytes", { n });
    const units = ["KB", "MB", "GB", "TB"];
    let v = n / 1000;
    let i = 0;
    while (v >= 1000 && i < units.length - 1) {
      v /= 1000;
      i++;
    }
    return `${v >= 100 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
  }
  function formatCount(n) {
    return String(Math.trunc(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  }
  var pad = (n) => String(n).padStart(2, "0");
  function formatDate(ms, now = Date.now()) {
    if (ms === null || ms === undefined)
      return "—";
    const d = new Date(ms);
    const n = new Date(now);
    const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    if (d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate())
      return t("date.today", "Today {time}", { time });
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${time}`;
  }
  function formatDuration(seconds) {
    if (seconds < 60)
      return t("duration.seconds", "{n} s left", { n: seconds });
    const m = Math.ceil(seconds / 60);
    return m < 60 ? t("duration.minutes", "{n} min left", { n: m }) : t("duration.hours", "{n} h left", { n: Math.ceil(m / 60) });
  }
  function kindLabel(group) {
    switch (group) {
      case "folder":
        return t("kind.folder", "Folder");
      case "text":
        return t("kind.text", "Text");
      case "markdown":
        return t("kind.markdown", "Markdown");
      case "code":
        return t("kind.code", "Source code");
      case "image":
        return t("kind.image", "Image");
      case "pdf":
        return t("kind.pdf", "PDF document");
      case "archive":
        return t("kind.archive", "Archive");
      case "media":
        return t("kind.media", "Media");
      default:
        return t("kind.other", "Document");
    }
  }
  function symbolFor(e) {
    if (e.kind === "symlink")
      return e.target_kind === "dir" ? "folder.badge.questionmark" : "arrow.up.right.square";
    switch (kindGroup(e)) {
      case "folder":
        return "folder";
      case "markdown":
      case "text":
        return "doc.text";
      case "code":
        return "chevron.left.forwardslash.chevron.right";
      case "image":
        return "photo";
      case "pdf":
        return "doc.richtext";
      case "archive":
        return "archivebox";
      case "media":
        return "play.rectangle";
      default:
        return "doc";
    }
  }
  var initialListing = (sort = DEFAULT_SORT, filter = DEFAULT_FILTER) => ({
    key: null,
    status: "idle",
    listing: null,
    revision: null,
    base: [],
    overlay: {},
    delta: 0,
    cursor: null,
    total: null,
    error: null,
    sort,
    filter,
    lastWatch: null,
    early: []
  });
  function revisionCompare(a, b) {
    const x = a.replace(/^0+/, "");
    const y = b.replace(/^0+/, "");
    if (x.length !== y.length)
      return x.length < y.length ? -1 : 1;
    return x < y ? -1 : x > y ? 1 : 0;
  }
  function mergeSorted(base, add, sort) {
    const cmp = compareEntries(sort);
    const names = new Set(base.map((e) => e.name));
    const out = base.slice();
    for (const e of add) {
      if (names.has(e.name))
        continue;
      names.add(e.name);
      out.splice(insertionIndex(out, e, cmp), 0, e);
    }
    return out;
  }
  function fold(s) {
    const names = Object.keys(s.overlay);
    if (names.length === 0)
      return s;
    const kept = s.base.filter((e) => !(e.name in s.overlay));
    const added = names.map((n) => s.overlay[n]).filter((e) => !!e);
    return { ...s, base: mergeSorted(kept, added, s.sort), overlay: {}, total: s.total === null ? null : s.total + s.delta, delta: 0 };
  }
  function applyEvent(s, ev) {
    if (ev.kind === "overflow" || ev.kind === "reset")
      return { ...s, status: "stale", lastWatch: ev.revision };
    const overlay = { ...s.overlay };
    let delta = s.delta;
    switch (ev.kind) {
      case "created":
        if (!overlay[ev.entry.name])
          delta += 1;
        overlay[ev.entry.name] = ev.entry;
        break;
      case "modified":
        overlay[ev.entry.name] = ev.entry;
        break;
      case "deleted":
        if (overlay[ev.name] !== null || !(ev.name in overlay))
          delta -= 1;
        overlay[ev.name] = null;
        break;
      case "renamed":
        overlay[ev.from] = null;
        overlay[ev.entry.name] = ev.entry;
        break;
    }
    const next = { ...s, overlay, delta, lastWatch: ev.revision };
    return next.status === "complete" ? fold(next) : next;
  }
  function reduceListing(s, a) {
    switch (a.type) {
      case "open": {
        const sort = a.sort ?? s.sort;
        const filter = a.filter ?? s.filter;
        if (a.keepRows && s.key === a.key)
          return { ...s, status: "loading", listing: null, cursor: null, error: null, sort, filter, early: [] };
        return { ...initialListing(sort, filter), key: a.key, status: "loading" };
      }
      case "batch": {
        if (a.key !== s.key || s.status === "idle")
          return s;
        const b = a.batch;
        const first = s.listing === null;
        if (!first && b.listing !== s.listing)
          return s;
        let next = first ? { ...s, listing: b.listing, revision: b.revision, base: mergeSorted([], b.entries, s.sort), overlay: {}, delta: 0, lastWatch: null, error: null } : { ...s, base: mergeSorted(s.base, b.entries, s.sort) };
        next = { ...next, cursor: b.cursor, total: b.total, status: b.cursor ? "partial" : "complete" };
        if (first) {
          const early = s.early;
          next = { ...next, early: [] };
          for (const ev of early)
            if (revisionCompare(ev.revision, b.revision) > 0)
              next = applyEvent(next, ev);
        }
        return next.status === "complete" ? fold(next) : next;
      }
      case "watch": {
        if (a.key !== s.key || s.status === "idle" || s.status === "error")
          return s;
        if (s.revision === null)
          return { ...s, early: [...s.early, a.event] };
        if (revisionCompare(a.event.revision, s.revision) <= 0)
          return s;
        if (s.lastWatch !== null && revisionCompare(a.event.revision, s.lastWatch) <= 0)
          return s;
        return applyEvent(s, a.event);
      }
      case "error":
        if (a.key !== s.key)
          return s;
        if (a.error.code === "cursor.expired")
          return { ...s, status: "stale" };
        return { ...s, status: "error", error: a.error };
      case "sort":
      case "filter": {
        const next = a.type === "sort" ? { ...s, sort: a.sort } : { ...s, filter: a.filter };
        if (s.status === "complete")
          return { ...next, base: mergeSorted([], s.base, next.sort) };
        return s.status === "idle" ? next : { ...next, status: "stale" };
      }
    }
  }
  function visibleEntries(s) {
    const cmp = compareEntries(s.sort);
    const kept = s.base.filter((e) => !(e.name in s.overlay));
    const last = s.base[s.base.length - 1];
    const added = Object.values(s.overlay).filter((e) => !!e && (s.status === "complete" || s.cursor === null || !last || cmp(e, last) <= 0));
    return mergeSorted(kept, added, s.sort).filter((e) => matchesFilter(e, s.filter));
  }
  var displayTotal = (s) => s.total === null ? null : s.total + s.delta;
  var canLoadMore = (s) => s.status === "partial" && s.cursor !== null;
  function gesture() {
    const g = cmux.gesture;
    return typeof g === "function" ? g.call(cmux) : null;
  }
  function cleanup(fn) {
    const f = globalThis.onCleanup;
    if (typeof f === "function")
      f(fn);
  }
  var [editing, setEditing] = signal(null);
  var isEditing = (b, name) => {
    const e = editing();
    const l = b.location();
    return !!e && !!l && e.key === locationKey(l) && e.name === name;
  };
  function startEdit(b, name) {
    const l = b.location();
    if (l)
      setEditing({ key: locationKey(l), name });
  }
  var stopEdit = () => setEditing(null);
  function entryMenu(b, name) {
    const ensure = () => {
      if (!b.selection().includes(name))
        b.select(name);
    };
    const writable = b.root()?.rights === "read_write";
    return [
      Button(t("menu.open", "Open"), () => {
        const g = gesture();
        ensure();
        openEntry(b, name, g);
      }),
      Divider(),
      Button(t("menu.copy", "Copy"), () => {
        ensure();
        copySelection(b, "copy");
      }),
      Button(t("menu.cut", "Cut"), () => {
        ensure();
        copySelection(b, "move");
      }).disabled(!writable),
      Button(t("menu.rename", "Rename"), () => startEdit(b, name)).disabled(!writable),
      Divider(),
      Button(t("menu.insertPath", "Insert Path in Terminal"), () => {
        const g = gesture();
        ensure();
        sendToTerminal(b, g);
      }),
      Button(t("menu.attachAgent", "Attach to Agent"), () => {
        const g = gesture();
        ensure();
        sendToAgent(b, g);
      }),
      Divider(),
      Button(t("menu.trash", "Move to Trash"), () => {
        const g = gesture();
        ensure();
        trash(b, g);
      }).destructive().disabled(!writable)
    ];
  }
  var COLUMN_WIDTHS = { modified: 118, size: 64, kind: 88 };
  function pathBar(b, trailing = []) {
    return HStack({ spacing: 4 }, [
      Button(Icon("chevron.up").size(11), () => b.up()).disabled(() => (b.location()?.path ?? "") === "").help(t("action.up", "Enclosing Folder")),
      () => {
        const loc = b.location();
        const root = b.root();
        if (!loc)
          return Text(t("pathbar.none", "No folder")).color("secondary");
        const conn = b.conn();
        const parts = collapseCrumbs(crumbs(root?.label ?? t("pathbar.root", "Root"), loc.path));
        return HStack({ spacing: 2 }, [
          conn && conn.kind !== "local" ? Badge(conn.label, "secondary") : null,
          ...parts.flatMap((c, i) => [
            i > 0 ? Icon("chevron.right").size(8).color("tertiary") : null,
            c === null ? Text("…").color("tertiary") : Button(Text(c.label).font("callout").weight(i === parts.length - 1 ? "semibold" : "regular").lineLimit(1), () => b.open({ ...loc, path: c.path }))
          ])
        ]);
      },
      Spacer(),
      ...trailing
    ]).padding({ top: 6, leading: 8, bottom: 6, trailing: 8 });
  }
  function headerCell(b, key, label, width) {
    return Button(HStack({ spacing: 3 }, [
      Text(label).font("caption").weight(() => b.state().sort.key === key ? "semibold" : "regular").color("secondary"),
      () => b.state().sort.key === key ? Icon(b.state().sort.dir === "asc" ? "chevron.up" : "chevron.down").size(8).color("secondary") : null,
      width ? null : Spacer()
    ]), () => b.setSort(key)).frame(width ? { width } : { maxWidth: "infinity" });
  }
  function listHeader(b, compact = false) {
    return HStack({ spacing: 8 }, [
      Spacer().frame({ width: 16 }),
      headerCell(b, "name", t("column.name", "Name")),
      compact ? null : headerCell(b, "modified", t("column.modified", "Date Modified"), COLUMN_WIDTHS.modified),
      headerCell(b, "size", t("column.size", "Size"), COLUMN_WIDTHS.size),
      compact ? null : headerCell(b, "kind", t("column.kind", "Kind"), COLUMN_WIDTHS.kind)
    ]).padding({ top: 4, leading: 10, bottom: 4, trailing: 10 });
  }
  function entryRow(b, entry, compact = false) {
    const selected = () => b.selection().includes(entry().name);
    const dim = () => entry().hidden || entry().name.startsWith(".") ? 0.55 : 1;
    return HStack({ spacing: 8 }, [
      Icon(() => symbolFor(entry())).color(() => kindGroup(entry()) === "folder" ? "accent" : "secondary").frame({ width: 16 }),
      () => isEditing(b, entry().name) ? TextField(entry().name, {
        placeholder: t("rename.placeholder", "New name"),
        autofocus: true,
        onSubmit: (text) => {
          const g = gesture();
          const from = entry().name;
          stopEdit();
          rename(b, from, text, g);
        },
        onCancel: stopEdit
      }).frame({ maxWidth: "infinity" }) : Text(() => entry().name).lineLimit(1).truncation("middle").frame({ maxWidth: "infinity" }),
      compact ? null : Text(() => formatDate(entry().mtime)).font("caption").color("secondary").lineLimit(1).frame({ width: COLUMN_WIDTHS.modified }),
      Text(() => kindGroup(entry()) === "folder" ? "—" : formatBytes(entry().size)).font("caption").color("secondary").lineLimit(1).frame({ width: COLUMN_WIDTHS.size }),
      compact ? null : Text(() => kindLabel(kindGroup(entry()))).font("caption").color("secondary").lineLimit(1).frame({ width: COLUMN_WIDTHS.kind })
    ]).padding({ top: 3, leading: 10, bottom: 3, trailing: 10 }).background(() => selected() ? "selected" : null).hoverBackground("hover").cornerRadius(5).opacity(dim).contextMenu(() => entryMenu(b, entry().name)).onTap(() => {
      const g = gesture();
      const name = entry().name;
      if (selected() && b.selection().length === 1)
        openEntry(b, name, g);
      else
        b.select(name);
    });
  }
  function pagerText(b) {
    const loaded = b.allRows().length;
    const total = displayTotal(b.state());
    const from = loaded === 0 ? 0 : b.offset() + 1;
    const to = Math.min(loaded, b.offset() + b.pageRows);
    return t("list.range", "{from}–{to} of {total}", { from: formatCount(from), to: formatCount(to), total: formatCount(total ?? loaded) });
  }
  function pager(b) {
    const shown = computed(() => b.hasPrev() || b.hasNext());
    return () => shown() ? HStack({ spacing: 6 }, [
      Button(Icon("chevron.left").size(11), () => b.prev()).disabled(() => !b.hasPrev()).help(t("list.prev", "Previous page")),
      Text(() => pagerText(b)).font("caption").color("secondary"),
      Button(Icon("chevron.right").size(11), () => void b.next()).disabled(() => !b.hasNext()).help(t("list.next", "Next page")),
      Spacer()
    ]).padding({ top: 4, leading: 10, bottom: 2, trailing: 10 }) : null;
  }
  function listMode(b) {
    if (!b.location())
      return isMissing(sidebarError()?.code) ? "missing" : "none";
    const conn = b.conn();
    if (conn && conn.state !== "connected")
      return "conn";
    const s = b.state();
    if (s.status === "error" && s.error)
      return "error";
    if (s.status === "loading" && s.base.length === 0)
      return "loading";
    if (b.allRows().length === 0 && (s.status === "complete" || s.status === "partial"))
      return "empty";
    return "rows";
  }
  function listState(b, body) {
    const mode = computed(() => listMode(b));
    return () => {
      switch (mode()) {
        case "none":
          return EmptyState({ title: t("state.noFolder", "No folder open"), message: t("state.noFolderHint", "Pick a place in the sidebar or add a folder."), symbol: "folder" });
        case "missing":
          return EmptyState({ title: t("error.missingTitle", "File access is not available yet"), message: t("error.missingHint", "This cmux does not provide {op} yet.", { op: "fs.roots.list" }), symbol: "puzzlepiece.extension" });
        case "conn":
          return connectionState(b);
        case "error":
          return errorState(b);
        case "loading":
          return VStack({ spacing: 8, alignment: "center" }, [ProgressView(), Text(t("state.loading", "Loading…")).font("caption").color("secondary")]).padding(24).frame({ maxWidth: "infinity" });
        case "empty":
          return EmptyState({ title: () => b.state().filter.query ? t("state.noMatches", "No matches") : t("state.empty", "Folder is empty"), symbol: "folder" });
        default:
          return body();
      }
    };
  }
  function connectionTitle(label, state) {
    switch (state) {
      case "connecting":
        return t("conn.connecting", "Connecting to {name}…", { name: label });
      case "verifying":
        return t("conn.verifying", "Waiting for host key confirmation for {name}", { name: label });
      case "needs_auth":
        return t("conn.needsAuth", "{name} needs you to sign in", { name: label });
      case "unreachable":
        return t("conn.unreachable", "{name} is unreachable", { name: label });
      default:
        return t("conn.disconnected", "{name} is not connected", { name: label });
    }
  }
  function connectionState(b) {
    const state = () => b.conn()?.state ?? "disconnected";
    const busy = computed(() => state() === "connecting" || state() === "verifying");
    return VStack({ spacing: 10, alignment: "center" }, [
      () => busy() ? ProgressView() : Icon(() => state() === "unreachable" ? "bolt.horizontal.circle" : "network.slash").size(26).color("tertiary"),
      Text(() => connectionTitle(b.conn()?.label ?? "", state())).font("headline"),
      Text(() => b.conn()?.detail ?? "").font("caption").color("secondary")
    ]).padding(28).frame({ maxWidth: "infinity" });
  }
  var isMissing = (code) => code === "operation.unsupported" || code === "scope.missing";
  function errorState(b) {
    const err = () => b.state().error;
    const missing = computed(() => isMissing(err()?.code));
    return VStack({ spacing: 10, alignment: "center" }, [
      EmptyState({
        title: () => missing() ? t("error.missingTitle", "File access is not available yet") : err()?.code === "fs.permission_denied" ? t("error.denied", "You do not have permission to see this folder") : t("error.load", "Cannot open this folder"),
        message: () => missing() ? t("error.missingHint", "This cmux does not provide {op} yet.", { op: "fs.list" }) : err()?.message ?? "",
        symbol: () => missing() ? "puzzlepiece.extension" : "exclamationmark.triangle"
      }),
      () => missing() ? null : Button(t("action.retry", "Try Again"), () => b.relist())
    ]);
  }
  function noticeRow() {
    const shown = computed(() => notice() !== null);
    return () => shown() ? Text(() => notice() ?? "").font("caption").color("warning").padding({ top: 4, leading: 10, bottom: 4, trailing: 10 }) : null;
  }
  function statusText(b) {
    const s = b.state();
    const total = displayTotal(s);
    const sel = b.selection().length;
    const parts = [t("status.items", "{n} items", { n: formatCount(total ?? b.allRows().length) })];
    if (sel > 0)
      parts.push(t("status.selected", "{n} selected", { n: sel }));
    if (s.status === "stale")
      parts.push(t("status.refreshing", "refreshing"));
    return parts.join(" · ");
  }
  var statusLine = (b) => Text(() => statusText(b)).font("caption2").color("tertiary").padding({ top: 4, leading: 10, bottom: 6, trailing: 10 });
  var groupTitle = (text) => Text(text).font("caption").weight("semibold").color("tertiary").padding({ top: 8, leading: 6, bottom: 2 });
  function connSubtitle(c) {
    if (c.state === "connected")
      return c.path ?? null;
    return connectionTitle(c.label, c.state);
  }
  function connSymbol(c) {
    switch (c.kind) {
      case "local":
        return "laptopcomputer";
      case "server":
        return "server.rack";
      case "team_vm":
        return "person.2";
      case "cloud_vm":
        return "cloud";
      default:
        return "terminal";
    }
  }
  function openRoot(r) {
    const g = gesture();
    navigate({ conn: r.conn, root: r.root, path: "" });
    ops.openPane(g);
  }
  async function connect(conn) {
    const g = gesture();
    const r = await ops.connect(g, conn);
    if (!r.ok) {
      if (r.error.code !== "user.cancelled")
        flash(isMissing(r.error.code) ? t("hosts.missing", "Connecting to hosts needs a newer cmux.") : r.error.message);
      return;
    }
    upsertConn(r.value.conn);
  }
  async function addFolder() {
    const g = gesture();
    const r = await ops.pickRoot(g);
    if (!r.ok) {
      if (r.error.code !== "user.cancelled")
        flash(isMissing(r.error.code) ? t("favorites.missing", "Adding folders needs a newer cmux.") : r.error.message);
      return;
    }
    addRoot(r.value.root);
    openRoot(r.value.root);
  }
  function hostRow(c) {
    return Row({
      title: () => c().label,
      subtitle: () => connSubtitle(c()),
      symbol: () => connSymbol(c()),
      tint: () => c().state === "connected" ? null : c().state === "unreachable" ? "danger" : "tertiary",
      accessory: () => c().state === "connecting" || c().state === "verifying" ? "ellipsis" : null
    }).onTap(() => {
      const conn = c();
      if (conn.state !== "connected")
        return void connect(conn.conn);
      const home = roots().find((r) => r.conn === conn.conn);
      if (home)
        openRoot(home);
    }).contextMenu(() => [
      Button(t("hosts.disconnect", "Disconnect"), () => void ops.disconnect(c().conn).then((r) => r.ok && upsertConn(r.value.conn))).disabled(c().state !== "connected" || c().kind === "local")
    ]);
  }
  function filesSection() {
    const favorites = () => roots().filter((r) => r.pinned !== false && conns().find((c) => c.conn === r.conn)?.kind !== "ssh");
    const missing = computed(() => isMissing(sidebarError()?.code));
    return VStack({ spacing: 0 }, [
      () => missing() ? EmptyState({ title: t("sidebar.missing", "Files needs a newer cmux"), message: t("sidebar.missingHint", "This cmux cannot list folders or hosts for apps yet."), symbol: "puzzlepiece.extension" }) : VStack({ spacing: 0 }, [
        groupTitle(t("sidebar.favorites", "Favorites")),
        ForEach({ items: favorites, key: (r) => r.root }, (r) => Row({ title: () => r().label, subtitle: () => r().display, symbol: () => r().kind === "home" ? "house" : r().kind === "workspace" ? "square.stack" : "folder" }).onTap(() => openRoot(r()))),
        Row({ title: t("sidebar.addFolder", "Add Folder…"), symbol: "plus" }).onTap(() => void addFolder()),
        groupTitle(t("sidebar.hosts", "Hosts")),
        ForEach({ items: conns, key: (c) => c.conn }, (c) => hostRow(c)),
        Row({ title: t("sidebar.connect", "Connect to Host…"), symbol: "plus" }).onTap(() => void connect()),
        () => recent().length === 0 ? null : VStack({ spacing: 0 }, [
          groupTitle(t("sidebar.recent", "Recent")),
          ForEach({ items: () => recent().slice(0, 5), key: (r) => `${r.conn}|${r.root}|${r.path}` }, (r) => Row({ title: () => r().label, symbol: "clock" }).onTap(() => {
            const g = gesture();
            navigate(r());
            ops.openPane(g);
          }))
        ])
      ]),
      () => loaded() ? null : HStack([ProgressView(), Spacer()]).padding(8)
    ]);
  }
  var PAGE = 200;
  function createBrowser(opts = {}) {
    const pageRows = opts.pageRows ?? 24;
    const [location, setLocation] = signal(null);
    const [state, setState] = signal(initialListing());
    const [selection, setSelection] = signal([]);
    const [offset, setOffset] = signal(0);
    let current = initialListing();
    let unwatch = null;
    let lastConnState = null;
    const apply = (a) => {
      current = reduceListing(current, a);
      setState(current);
    };
    const conn = () => {
      const l = location();
      return l ? connById(l.conn) : null;
    };
    const root = () => {
      const l = location();
      return l ? rootById(l.root) : null;
    };
    const connected = () => (conn()?.state ?? "connected") === "connected";
    async function fetchPage(loc, key, cursor) {
      const s = current;
      const r = await ops.list(loc, s.sort, s.filter, PAGE, cursor, s.listing);
      if (r.ok)
        apply({ type: "batch", key, batch: r.value });
      else
        apply({ type: "error", key, error: r.error });
    }
    function watch(loc, key) {
      unwatch?.();
      unwatch = cmux.events.on("fs.watch", (p) => {
        const m = p;
        if (!m?.event)
          return;
        if (m.conn !== undefined && locationKey({ conn: m.conn, root: m.root ?? "", path: m.path ?? "" }) !== key)
          return;
        apply({ type: "watch", key, event: m.event });
        if (current.status === "stale")
          relist();
      }, { conn: loc.conn, root: loc.root, path: loc.path });
    }
    async function load(keepRows = false) {
      const loc = location();
      if (!loc)
        return;
      const key = locationKey(loc);
      apply({ type: "open", key, keepRows });
      if (!connected())
        return;
      watch(loc, key);
      await fetchPage(loc, key, null);
    }
    function open(loc) {
      setLocation(loc);
      setSelection([]);
      setOffset(0);
      lastConnState = connById(loc.conn)?.state ?? "connected";
      load();
    }
    const relist = () => load(true);
    effect(() => {
      const l = location();
      const st = l ? connById(l.conn)?.state ?? "connected" : null;
      if (st === "connected" && lastConnState !== null && lastConnState !== "connected")
        load(current.status !== "idle");
      lastConnState = st;
    });
    cleanup(() => unwatch?.());
    const allRows = () => visibleEntries(state());
    const rows = () => allRows().slice(offset(), offset() + pageRows);
    return {
      location,
      state,
      selection,
      conn,
      root,
      connected,
      rows,
      allRows,
      offset,
      pageRows,
      open,
      relist,
      up() {
        const l = location();
        const p = l ? parent(l.path) : null;
        if (l && p !== null)
          open({ ...l, path: p });
      },
      into(name) {
        const l = location();
        if (l)
          open({ ...l, path: join(l.path, name) });
      },
      select(name) {
        setSelection(name ? [name] : []);
      },
      selectAll() {
        setSelection(allRows().map((e) => e.name));
      },
      selected: () => {
        const names = selection();
        if (names.length !== 1)
          return null;
        return allRows().find((e) => e.name === names[0]) ?? null;
      },
      hasPrev: () => offset() > 0,
      hasNext: () => offset() + pageRows < allRows().length || canLoadMore(state()),
      prev() {
        setOffset((o) => Math.max(0, o - pageRows));
      },
      async next() {
        const l = location();
        const target = offset() + pageRows;
        if (l && canLoadMore(current) && allRows().length < target + pageRows)
          await fetchPage(l, locationKey(l), current.cursor);
        if (target < allRows().length)
          setOffset(target);
      },
      setSort(key) {
        const s = current.sort;
        const sort = s.key === key ? { ...s, dir: s.dir === "asc" ? "desc" : "asc" } : { ...s, key, dir: key === "name" || key === "kind" ? "asc" : "desc" };
        apply({ type: "sort", sort });
        if (current.status === "stale")
          relist();
      },
      toggleHidden() {
        apply({ type: "filter", filter: { ...current.filter, hidden: !current.filter.hidden } });
        if (current.status === "stale")
          relist();
      },
      setQuery(query) {
        apply({ type: "filter", filter: { ...current.filter, query } });
        if (current.status === "stale")
          relist();
      },
      reset() {
        unwatch?.();
        unwatch = null;
        lastConnState = null;
        setLocation(null);
        setSelection([]);
        current = initialListing(DEFAULT_SORT, DEFAULT_FILTER);
        setState(current);
      }
    };
  }
  var TEXT_PREVIEW_BYTES = 32 * 1024;
  var TEXT_PREVIEW_LINES = 28;
  var MAX_TEXT_FILE = 8 * 1000 * 1000;
  function previewLines(text, maxLines = TEXT_PREVIEW_LINES, maxCols = 160) {
    return text.split(/\r?\n/).slice(0, maxLines).map((l) => (l.length > maxCols ? `${l.slice(0, maxCols)}…` : l).replace(/\t/g, "  "));
  }
  function createPreview(b) {
    const [state, setState] = signal({ status: "none" });
    let token = 0;
    let last = { key: "", entry: null, loc: null };
    const target = computed(() => {
      const entry = b.selected();
      const loc = b.location();
      const key = entry && loc ? `${locationKey(loc)}|${entry.name}|${entry.mtime}|${entry.size}` : "";
      if (key !== last.key)
        last = { key, entry, loc };
      return last;
    });
    effect(() => {
      const { entry, loc } = target();
      const my = ++token;
      if (!entry || !loc) {
        setState({ status: "none" });
        return;
      }
      const group = kindGroup(entry);
      if (group === "folder")
        return setState({ status: "meta", entry, group, reason: "folder" });
      const where = { ...loc, path: join(loc.path, entry.name) };
      if (group === "text" || group === "markdown" || group === "code") {
        if ((entry.size ?? 0) > MAX_TEXT_FILE)
          return setState({ status: "meta", entry, group, reason: "too_large" });
        setState({ status: "loading", entry, group });
        ops.read(where, TEXT_PREVIEW_BYTES).then((r) => {
          if (my !== token)
            return;
          if (!r.ok)
            return setState({ status: "error", entry, group, error: r.error });
          if (r.value.text === null)
            return setState({ status: "meta", entry, group, reason: "binary" });
          setState({ status: "text", entry, group, lines: previewLines(r.value.text), truncated: r.value.truncated });
        });
        return;
      }
      if (group === "image" || group === "pdf") {
        setState({ status: "loading", entry, group });
        ops.thumbnail(where, 512).then((r) => {
          if (my !== token)
            return;
          if (!r.ok)
            return setState({ status: "error", entry, group, error: r.error });
          setState({ status: "image", entry, group, image: r.value.image, width: r.value.width, height: r.value.height, pages: r.value.pages ?? null });
        });
        return;
      }
      setState({ status: "meta", entry, group, reason: "no_viewer" });
    });
    return state;
  }
  var [applyAll, setApplyAll] = signal(false);
  function jobTitle(j) {
    const vars = { subject: j.subject, destination: j.destination };
    const doneish = j.phase === "done";
    switch (j.op) {
      case "copy":
        return doneish ? t("job.copied", "Copied {subject} to {destination}", vars) : t("job.copying", "Copying {subject} to {destination}", vars);
      case "move":
        return doneish ? t("job.moved", "Moved {subject} to {destination}", vars) : t("job.moving", "Moving {subject} to {destination}", vars);
      case "trash":
        return doneish ? t("job.trashed", "Moved {subject} to the Trash", vars) : t("job.trashing", "Moving {subject} to the Trash", vars);
      default:
        return doneish ? t("job.deleted", "Deleted {subject}", vars) : t("job.deleting", "Deleting {subject}", vars);
    }
  }
  function jobDetail(j, now) {
    switch (j.phase) {
      case "queued":
        return t("job.queued", "Waiting");
      case "preparing":
        return t("job.preparing", "Preparing…");
      case "cancelling":
        return t("job.cancelling", "Stopping…");
      case "cancelled":
        return t("job.cancelled", "Stopped");
      case "failed":
        return j.error?.message ?? t("job.failed", "Failed");
      case "done":
      case "conflict":
        return "";
      default: {
        const parts = [];
        if (j.bytes.total)
          parts.push(t("job.bytes", "{done} of {total}", { done: formatBytes(j.bytes.done), total: formatBytes(j.bytes.total) }));
        else if (j.items.total)
          parts.push(t("job.items", "{done} of {total} items", { done: j.items.done, total: j.items.total }));
        const left = secondsLeft(j, now);
        if (left !== null)
          parts.push(formatDuration(left));
        if (j.crossHost)
          parts.push(t("job.crossHost", "between hosts"));
        return parts.join(" · ");
      }
    }
  }
  function conflictRow(j) {
    const c = j.conflict;
    const choose = (choice) => () => void resolveConflict(j.id, choice, applyAll(), gesture());
    return VStack({ spacing: 6 }, [
      Text(t("conflict.title", "“{name}” already exists in {destination}", { name: c.item, destination: j.destination })).font("callout").weight("semibold").lineLimit(2),
      Text(t("conflict.compare", "Existing {existing}, new {incoming}", { existing: formatBytes(c.existing.size), incoming: formatBytes(c.incoming.size) })).font("caption").color("secondary"),
      HStack({ spacing: 6 }, [
        Button(t("conflict.replace", "Replace"), choose("replace")).disabled(() => j.pending === "resolve"),
        Button(t("conflict.skip", "Skip"), choose("skip")).disabled(() => j.pending === "resolve"),
        Button(t("conflict.keepBoth", "Keep Both"), choose("keep_both")).disabled(() => j.pending === "resolve"),
        Spacer(),
        Button(HStack({ spacing: 4 }, [Icon(() => applyAll() ? "checkmark.square" : "square").size(11), Text(t("conflict.applyAll", "Apply to all")).font("caption")]), () => setApplyAll((v) => !v))
      ])
    ]);
  }
  function jobRow(job) {
    const phase = computed(() => job().phase);
    const active = computed(() => ["running", "preparing", "queued", "conflict"].includes(phase()));
    const undoable = computed(() => canUndo(job()));
    const cancellable = computed(() => canCancel(job()));
    const conflicted = computed(() => phase() === "conflict" ? job().conflict : null);
    return VStack({ spacing: 4 }, [
      HStack({ spacing: 8 }, [
        Icon(() => phase() === "failed" ? "exclamationmark.triangle" : phase() === "done" ? "checkmark.circle" : job().op === "trash" ? "trash" : "doc.on.doc").color(() => phase() === "failed" ? "danger" : phase() === "done" ? "success" : "secondary").size(12),
        Text(() => jobTitle(job())).font("callout").lineLimit(1).truncation("middle").frame({ maxWidth: "infinity" }),
        () => undoable() ? Button(t("job.undo", "Undo"), () => void undoJob(job().undo, gesture()).then((ok) => ok && dismissJob(job().id))) : null,
        () => cancellable() ? Button(Icon("xmark.circle.fill").size(12).color("tertiary"), () => void cancelJob(job().id)).help(t("job.cancel", "Stop")) : null,
        () => active() || phase() === "cancelling" ? null : Button(Icon("xmark").size(10).color("tertiary"), () => dismissJob(job().id)).help(t("job.dismiss", "Dismiss"))
      ]),
      () => active() ? ProgressView(() => fraction(job())) : null,
      () => conflicted() ? conflictRow(job()) : null,
      Text(() => jobDetail(job(), Date.now())).font("caption").color(() => phase() === "failed" ? "danger" : "secondary").lineLimit(1)
    ]).padding({ top: 8, leading: 10, bottom: 8, trailing: 10 });
  }
  var VISIBLE_JOBS = 3;
  function jobsStrip() {
    const shown = () => jobList().slice(-VISIBLE_JOBS);
    const any = computed(() => jobList().length > 0);
    const overflow = computed(() => Math.max(0, jobList().length - VISIBLE_JOBS));
    return () => any() ? VStack({ spacing: 0 }, [
      Divider(),
      ForEach({ items: shown, key: (j) => j.id }, (j) => jobRow(j)),
      () => overflow() > 0 ? Text(() => t("job.more", "{n} more operations", { n: overflow() })).font("caption2").color("tertiary").padding(6) : null
    ]) : null;
  }
  function header(s) {
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 8 }, [
        Icon(symbolFor(s.entry)).size(22).color(s.group === "folder" ? "accent" : "secondary"),
        VStack({ spacing: 1 }, [Text(s.entry.name).font("headline").lineLimit(2).truncation("middle"), Text(kindLabel(s.group)).font("caption").color("secondary")])
      ]),
      HStack({ spacing: 12 }, [
        s.group === "folder" ? null : meta(t("preview.size", "Size"), formatBytes(s.entry.size)),
        meta(t("preview.modified", "Modified"), formatDate(s.entry.mtime))
      ])
    ]).padding({ top: 10, leading: 12, bottom: 8, trailing: 12 });
  }
  var meta = (label, value) => VStack({ spacing: 1 }, [Text(label).font("caption2").color("tertiary"), Text(value).font("caption").color("secondary").lineLimit(1)]);
  function body(s) {
    switch (s.status) {
      case "loading":
        return HStack([ProgressView(), Spacer()]).padding(12);
      case "text":
        return VStack({ spacing: 0 }, [
          VStack({ spacing: 1 }, s.lines.map((line, i) => s.group === "markdown" ? markdownLine(line, i) : Text(line === "" ? " " : line).font(11).monospaced().lineLimit(1).color("secondary"))).padding(10).frame({ maxWidth: "infinity" }).background("hover").cornerRadius(6),
          s.truncated ? Text(t("preview.truncated", "Preview shows the start of the file.")).font("caption2").color("tertiary").padding({ top: 4 }) : null
        ]).padding({ leading: 12, trailing: 12, bottom: 10 });
      case "image":
        return VStack({ spacing: 4, alignment: "center" }, [
          ZStack([RoundedRectangle({ fill: "hover", cornerRadius: 6 }).frame({ maxWidth: "infinity", height: 150 }), Icon(s.group === "pdf" ? "doc.richtext" : "photo").size(30).color("tertiary")]),
          Text(s.pages ? t("preview.pages", "{w} × {h} · {n} pages", { w: s.width, h: s.height, n: s.pages }) : t("preview.dimensions", "{w} × {h}", { w: s.width, h: s.height })).font("caption").color("secondary")
        ]).padding({ leading: 12, trailing: 12, bottom: 10 });
      case "error":
        return Text(s.error.missing ? t("preview.missing", "Previews need a newer cmux.") : s.error.message).font("caption").color("secondary").padding(12);
      case "meta":
        return s.reason === "folder" ? null : Text(s.reason === "too_large" ? t("preview.tooLarge", "Too large to preview.") : s.reason === "binary" ? t("preview.binary", "No text preview for this file.") : t("preview.noViewer", "No viewer app for this kind of file.")).font("caption").color("tertiary").padding(12);
    }
  }
  function markdownLine(line, i) {
    const h = /^(#{1,3})\s+(.*)$/.exec(line);
    if (h)
      return Text(h[2]).font(h[1].length === 1 ? "headline" : "subheadline").weight("semibold").lineLimit(1).padding({ top: i === 0 ? 0 : 4 });
    const bullet = /^\s*[-*]\s+(.*)$/.exec(line);
    if (bullet)
      return Text(`• ${bullet[1]}`).font("caption").lineLimit(1);
    return Text(line === "" ? " " : line.replace(/[*_`]/g, "")).font("caption").color("secondary").lineLimit(1);
  }
  function previewPane(state) {
    return () => {
      const s = state();
      if (s.status === "none")
        return EmptyState({ title: t("preview.none", "No selection"), symbol: "eye" });
      return VStack({ spacing: 0 }, [header(s), Divider(), body(s), Spacer()]);
    };
  }
  var iconButton = (symbol, help, run) => Button(Icon(symbol).size(12), run).help(help);
  function toolbar(b, opts = {}) {
    const writable = () => b.root()?.rights === "read_write";
    return [
      opts.filter === false ? null : TextField(() => b.state().filter.query, { placeholder: t("toolbar.filter", "Filter"), onEdit: (q) => b.setQuery(q), onCancel: () => b.setQuery("") }).frame({ width: 130 }),
      iconButton("folder.badge.plus", t("toolbar.newFolder", "New Folder"), () => startEdit(b, "")).disabled(() => !writable()),
      iconButton("doc.on.clipboard", t("toolbar.paste", "Paste"), () => void paste(b, gesture())).disabled(() => !clip() || !writable()),
      iconButton("trash", t("toolbar.trash", "Move to Trash"), () => void trash(b, gesture())).disabled(() => b.selection().length === 0 || !writable()),
      iconButton(() => b.state().filter.hidden ? "eye" : "eye.slash", t("toolbar.hidden", "Show Hidden Files"), () => b.toggleHidden())
    ].filter((v) => !!v);
  }
  function newFolderRow(b) {
    const shown = computed(() => isEditing(b, ""));
    return () => shown() ? HStack({ spacing: 8 }, [
      Icon("folder.badge.plus").color("accent").frame({ width: 16 }),
      TextField("", {
        placeholder: t("toolbar.newFolderName", "Folder name"),
        autofocus: true,
        onSubmit: (name) => {
          const g = gesture();
          stopEdit();
          newFolder(b, name, g);
        },
        onCancel: stopEdit
      }).frame({ maxWidth: "infinity" })
    ]).padding({ top: 3, leading: 10, bottom: 3, trailing: 10 }) : null;
  }
  var isDir2 = (e) => kindGroup(e) === "folder";
  function follow(b, o = {}) {
    const onOpen = o.onOpen ?? ((l) => b.open(l));
    const pick = o.pick ?? firstRoot;
    let seen = 0;
    if (o.requests !== false) {
      effect(() => {
        const r = request();
        if (r && r.seq !== seen) {
          seen = r.seq;
          onOpen(r.location);
        }
      });
    }
    let opened = false;
    effect(() => {
      const rs = roots();
      if (opened || b.location() || o.requests !== false && request())
        return;
      const l = pick(rs);
      if (l) {
        opened = true;
        onOpen(l);
      }
    });
  }
  var firstRoot = (rs) => {
    const r = rs.find((x) => x.kind === "home") ?? rs[0];
    return r ? { conn: r.conn, root: r.root, path: "" } : null;
  };
  function listBody(b, compact = false) {
    return VStack({ spacing: 0 }, [newFolderRow(b), ForEach({ items: b.rows, key: (e) => e.name }, (e) => entryRow(b, e, compact)), pager(b)]);
  }
  function listColumn(b, compact = false) {
    return VStack({ spacing: 0 }, [listHeader(b, compact), Divider(), listState(b, () => listBody(b, compact)), Spacer(), statusLine(b)]).frame({ maxWidth: "infinity", maxHeight: "infinity" });
  }
  function listPreviewView(showPreview) {
    const b = createBrowser({ pageRows: 22 });
    const preview = createPreview(b);
    follow(b);
    return VStack({ spacing: 0 }, [
      pathBar(b, toolbar(b)),
      Divider(),
      noticeRow(),
      HStack({ spacing: 0 }, [
        listColumn(b),
        () => showPreview() ? HStack({ spacing: 0 }, [Divider(), VStack({ spacing: 0 }, [previewPane(preview), Spacer()]).frame({ width: 260, maxHeight: "infinity" })]) : null
      ]).frame({ maxHeight: "infinity" }),
      jobsStrip()
    ]);
  }
  var MAX_COLUMNS = 6;
  var VISIBLE_COLUMNS = 3;
  function columnRow(b, e, openNext) {
    return Row({
      title: () => e().name,
      symbol: () => isDir2(e()) ? "folder" : "doc",
      selected: () => b.selection().includes(e().name),
      accessory: () => isDir2(e()) ? "chevron.right" : null
    }).onTap(() => {
      const name = e().name;
      b.select(name);
      if (isDir2(e()))
        openNext(name);
    });
  }
  function columnsView() {
    const cols = Array.from({ length: MAX_COLUMNS }, () => createBrowser({ pageRows: 22 }));
    const [depth, setDepth] = signal(1);
    const last = () => cols[depth() - 1];
    const preview = createPreview({ selected: () => last().selected(), location: () => last().location() });
    const openAt = (i, l) => {
      cols[i].open(l);
      for (let k = i + 1;k < MAX_COLUMNS; k++)
        cols[k].reset();
      setDepth(i + 1);
    };
    const openNext = (i) => (name) => {
      const l = cols[i].location();
      if (l && i + 1 < MAX_COLUMNS)
        openAt(i + 1, { ...l, path: join(l.path, name) });
    };
    follow(cols[0], { onOpen: (l) => openAt(0, l) });
    const column = (i) => {
      const visible = computed(() => i < depth() && i >= depth() - VISIBLE_COLUMNS);
      return () => visible() ? HStack({ spacing: 0 }, [
        VStack({ spacing: 0 }, [listState(cols[i], () => VStack({ spacing: 0 }, [ForEach({ items: cols[i].rows, key: (e) => e.name }, (e) => columnRow(cols[i], e, openNext(i))), pager(cols[i])])), Spacer()]).padding(4).frame({ width: 210, maxHeight: "infinity" }),
        Divider()
      ]) : null;
    };
    return VStack({ spacing: 0 }, [
      () => pathBar(last(), []),
      Divider(),
      noticeRow(),
      HStack({ spacing: 0 }, [...cols.map((_, i) => column(i)), VStack({ spacing: 0 }, [previewPane(preview), Spacer()]).frame({ maxWidth: "infinity", maxHeight: "infinity" })]).frame({ maxHeight: "infinity" }),
      jobsStrip()
    ]);
  }
  function dualPaneView() {
    const left = createBrowser({ pageRows: 22 });
    const right = createBrowser({ pageRows: 22 });
    follow(left);
    follow(right, {
      requests: false,
      pick: (rs) => {
        const leftConn = left.location()?.conn ?? rs[0]?.conn;
        const other = rs.find((r) => r.conn !== leftConn && conns().some((c) => c.conn === r.conn && c.state === "connected")) ?? rs[0];
        return other ? { conn: other.conn, root: other.root, path: "" } : null;
      }
    });
    const side = (b) => VStack({ spacing: 0 }, [pathBar(b, toolbar(b, { filter: false })), Divider(), listColumn(b, true)]).frame({ maxWidth: "infinity", maxHeight: "infinity" });
    const send = (op, from, to) => () => {
      const g = gesture();
      const l = to.location();
      if (l)
        transfer(op, from, from.selection(), l, to.root()?.rights === "read_write", g);
    };
    const none = (b) => () => b.selection().length === 0 || !b.location();
    return VStack({ spacing: 0 }, [
      HStack({ spacing: 6 }, [
        Spacer(),
        Button(t("dual.copyRight", "Copy →"), send("copy", left, right)).disabled(none(left)),
        Button(t("dual.moveRight", "Move →"), send("move", left, right)).disabled(none(left)),
        Divider().frame({ height: 14 }),
        Button(t("dual.copyLeft", "← Copy"), send("copy", right, left)).disabled(none(right)),
        Button(t("dual.moveLeft", "← Move"), send("move", right, left)).disabled(none(right)),
        Spacer()
      ]).padding({ top: 6, bottom: 6 }),
      Divider(),
      noticeRow(),
      HStack({ spacing: 0 }, [side(left), Divider(), side(right)]).frame({ maxHeight: "infinity" }),
      jobsStrip()
    ]);
  }
  function renderFiles(ctx = {}) {
    setLanguage(detectLanguage(ctx));
    start();
    return filesSection();
  }
  function renderFinder(ctx = {}) {
    setLanguage(detectLanguage(ctx));
    start();
    return VStack({ spacing: 0 }, [
      () => {
        switch (variant()) {
          case "columns":
            return columnsView();
          case "dualPane":
            return dualPaneView();
          default:
            return listPreviewView(showPreview);
        }
      }
    ]);
  }
  async function openFinder(_args = {}, ctx) {
    return ops.openPane(ctx?.gesture ?? null);
  }
  async function addFolder2() {
    await addFolder();
    return {};
  }
  async function connectHost() {
    await connect();
    return {};
  }
  var cycleVariant2 = cycleVariant;
  globalThis.__cmuxAppExports = { ...exports_main };
})();
