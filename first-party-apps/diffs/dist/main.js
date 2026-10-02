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
    cycleVariant: () => cycleVariant3,
    openChanges: () => openChanges2,
    openDiff: () => openDiff2,
    renderChanges: () => renderChanges,
    renderDiffPane: () => renderDiffPane,
    review: () => review2,
    reviewLatest: () => reviewLatest2,
    toggleLayout: () => toggleLayout3
  });
  var VARIANTS = ["split", "stream", "review"];
  var DEFAULT_VARIANT = "split";
  var [variantOverride, setVariantOverride] = signal(null);
  var [layoutOverride, setLayoutOverride] = signal(null);
  var setting = (key) => cmux.app.settings()[key];
  var variant = () => {
    const v = variantOverride() ?? setting("variant");
    return VARIANTS.includes(v) ? v : DEFAULT_VARIANT;
  };
  var layout = () => {
    const v = layoutOverride() ?? setting("layout");
    return v === "sideBySide" ? "sideBySide" : "inline";
  };
  var editorApp = () => {
    const v = setting("editorApp");
    return typeof v === "string" && /^[a-z0-9-]+\/[a-z0-9-]+$/.test(v) ? v : "cmux/codemirror";
  };
  var fallbackLines = () => {
    const v = Number(setting("fallbackLines"));
    return Number.isInteger(v) && v >= 20 && v <= 600 ? v : 160;
  };
  var nextVariant = (v) => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length];
  async function persist(key, value) {
    try {
      await cmux.call("app.settings.set", { key, value });
      return true;
    } catch {
      return false;
    }
  }
  async function cycleVariant() {
    const next = nextVariant(variant());
    setVariantOverride(next);
    const persisted = await persist("variant", next);
    if (persisted && setting("variant") === next)
      setVariantOverride(null);
    return { variant: next, persisted };
  }
  async function toggleLayout() {
    const next = layout() === "inline" ? "sideBySide" : "inline";
    setLayoutOverride(next);
    const persisted = await persist("layout", next);
    if (persisted && setting("layout") === next)
      setLayoutOverride(null);
    return { layout: next, persisted };
  }
  function setVariantForSession(v) {
    setVariantOverride(v);
  }
  var [defaultInput, setDefaultInput] = signal({ kind: "worktree" });
  var [focusRequest, setFocusRequest] = signal(null);
  var focusSeq = 0;
  var invalid = (message) => new CmuxError("invalid_params", message);
  var codeOf = (e) => e && typeof e === "object" && ("code" in e) ? String(e.code) : "error";
  async function openPane(input, focusPath) {
    setDefaultInput(input);
    if (focusPath)
      setFocusRequest({ path: focusPath, seq: ++focusSeq });
    try {
      await cmux.call("app.pane.open", { kind: "diff", input, focus_path: focusPath });
      return { opened: true };
    } catch (e) {
      return { opened: false, reason: codeOf(e) };
    }
  }
  var str = (v) => typeof v === "string" && v.trim() ? v.trim() : undefined;
  async function openChanges(args = {}) {
    return openPane({ kind: "worktree", staged: !!args.staged }, str(args.path));
  }
  async function openDiff(args = {}) {
    const base = str(args.base);
    const head = str(args.head);
    const repo = str(args.repo);
    if (!base || !head || !repo)
      throw invalid("repo, base and head are required");
    return openPane({ kind: "refs", repo, base, head });
  }
  async function review(args = {}) {
    const item = str(args.item);
    const diff = str(args.diff);
    const run = str(args.run);
    const input = item ? { kind: "feedItem", item } : diff ? { kind: "resource", diff } : run ? { kind: "run", run } : null;
    if (!input)
      throw invalid("give item, diff or run");
    if (item)
      setVariantForSession("review");
    return openPane(input);
  }
  async function reviewLatest() {
    const items = await cmux.call("feed.list", { kind: "review", state: "open", limit: 20 });
    const item = items.find((i) => i.prompt?.subject === "diff");
    if (!item)
      return { opened: false, reason: "none" };
    return review({ item: item.id });
  }
  async function toggleLayout2() {
    return toggleLayout();
  }
  async function cycleVariant2() {
    return cycleVariant();
  }
  // first-party-apps/diffs/strings/ja.json
  var ja_default = {
    "action.accept": "承認",
    "action.acceptAll": "すべて承認",
    "action.apply": "適用",
    "action.deleteComment": "コメントを削除",
    "action.discard": "破棄",
    "action.drop": "取り消す",
    "action.openFile": "ファイルを開く",
    "action.refresh": "更新",
    "action.reject": "却下",
    "action.rejectAll": "すべて却下",
    "action.showMore": "あと{n}行を表示",
    "action.stage": "ステージ",
    "action.submit": "レビューを送信",
    "action.undo": "元に戻す",
    "changes.empty": "変更はありません",
    "changes.more": "ほか{n}件",
    "changes.noRepo": "Gitリポジトリではありません",
    "changes.staged": "ステージ済み",
    "changes.unstaged": "未ステージ",
    "comment.placeholder": "コメントを追加",
    "error.load": "差分を読み込めません",
    "error.missing": "{op} はまだ使えません。",
    "file.binary": "バイナリファイル",
    "file.decision.accept": "承認済み",
    "file.decision.partial": "一部決定",
    "file.decision.reject": "却下済み",
    "file.renamed": "{path} から名前を変更",
    "files.count": "{n}ファイル",
    "footer.builtin": "内蔵の差分表示",
    "footer.embed": "{app} で表示",
    "layout.inline": "インライン",
    "layout.sideBySide": "左右に並べる",
    "pane.empty": "差分はありません",
    "pane.loading": "差分を読み込み中",
    "pane.selectFile": "ファイルを選択してください",
    "producer.agent": "{name} の提案",
    "producer.git": "作業ツリー",
    "producer.run": "実行 {name} の差分",
    "producer.user": "差分",
    "review.counts": "承認 {accepted} · 却下 {rejected} · 残り {pending}",
    "review.sent": "レビューを送信しました",
    "review.verdict.approve": "承認",
    "review.verdict.comment": "コメント",
    "review.verdict.request_changes": "変更を依頼",
    stat: "+{a} −{d}",
    "status.added": "追加",
    "status.binary": "バイナリ",
    "status.copied": "コピー",
    "status.deleted": "削除",
    "status.modified": "変更",
    "status.renamed": "名前変更",
    "status.untracked": "未追跡"
  };
  var tables = { ja: ja_default };
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
  var emptyReview = () => ({ hunks: {}, confirmed: {}, comments: [] });
  function decideHunk(state, hunk, decision) {
    const hunks = { ...state.hunks };
    if (decision === null || hunks[hunk] === decision)
      delete hunks[hunk];
    else
      hunks[hunk] = decision;
    return { ...state, hunks };
  }
  function decideFile(state, file, decision) {
    const hunks = { ...state.hunks };
    for (const h of file.hunks) {
      if (decision === null)
        delete hunks[h.id];
      else
        hunks[h.id] = decision;
    }
    return { ...state, hunks };
  }
  function fileDecision(state, file) {
    if (!file.hunks.length)
      return "pending";
    const ds = file.hunks.map((h) => state.hunks[h.id]);
    if (ds.every((d) => d === "accept"))
      return "accept";
    if (ds.every((d) => d === "reject"))
      return "reject";
    return ds.some((d) => d) ? "partial" : "pending";
  }
  function counts(state, files) {
    const all = files.flatMap((f) => f.hunks);
    const accepted = all.filter((h) => state.hunks[h.id] === "accept").length;
    const rejected = all.filter((h) => state.hunks[h.id] === "reject").length;
    return { files: files.length, hunks: all.length, accepted, rejected, pending: all.length - accepted - rejected };
  }
  function unsentDecisions(state, files) {
    const out = [];
    for (const f of files) {
      const fd = fileDecision(state, f);
      const allUnsent = f.hunks.every((h) => state.confirmed[h.id] !== state.hunks[h.id]);
      if ((fd === "accept" || fd === "reject") && allUnsent) {
        out.push({ path: f.path, decision: fd });
        continue;
      }
      for (const h of f.hunks) {
        const d = state.hunks[h.id];
        if (d && state.confirmed[h.id] !== d)
          out.push({ path: f.path, hunk: h.id, decision: d });
      }
    }
    return out;
  }
  function confirm(state, files, sent) {
    const confirmed = { ...state.confirmed };
    for (const d of sent) {
      const file = files.find((f) => f.path === d.path);
      if (!file)
        continue;
      for (const h of file.hunks)
        if (!d.hunk || d.hunk === h.id)
          confirmed[h.id] = d.decision;
    }
    return { ...state, confirmed };
  }
  function fromOwner(files, decisions) {
    let state = emptyReview();
    for (const d of decisions ?? []) {
      const file = files.find((f) => f.path === d.path);
      if (!file)
        continue;
      state = d.hunk ? decideHunk(state, d.hunk, d.decision) : decideFile(state, file, d.decision);
    }
    return { ...state, confirmed: { ...state.hunks } };
  }
  function addComment(state, c, id) {
    const body = c.body.trim();
    if (!body)
      return state;
    return { ...state, comments: [...state.comments, { ...c, body, id }] };
  }
  var removeComment = (state, id) => ({ ...state, comments: state.comments.filter((c) => c.id !== id) });
  var commentsAt = (state, path, line) => state.comments.filter((c) => c.path === path && (c.side === "new" && c.line === line.newLine || c.side === "old" && line.newLine === null && c.line === line.oldLine));
  function verdict(state, files) {
    const c = counts(state, files);
    if (c.rejected > 0)
      return "request_changes";
    if (c.pending === 0 && c.hunks > 0)
      return "approve";
    return "comment";
  }
  function sideBySide(hunk) {
    const rows = [];
    const lines = hunk.lines;
    let i = 0;
    while (i < lines.length) {
      const l = lines[i];
      if (l.kind === "context") {
        rows.push({ left: l, right: l });
        i++;
        continue;
      }
      const dels = [];
      const adds = [];
      while (i < lines.length && lines[i].kind === "del")
        dels.push(lines[i++]);
      while (i < lines.length && lines[i].kind === "add")
        adds.push(lines[i++]);
      for (let k = 0;k < Math.max(dels.length, adds.length); k++)
        rows.push({ left: dels[k] ?? null, right: adds[k] ?? null });
    }
    return rows;
  }
  var HUNK_HEADER = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$/;
  function fnv1a(text) {
    let h = 2166136261;
    for (let i = 0;i < text.length; i++) {
      h ^= text.charCodeAt(i);
      h = Math.imul(h, 16777619) >>> 0;
    }
    return h.toString(16).padStart(8, "0");
  }
  var hunkId = (path, h) => `${path}@${h.oldStart},${h.newStart}#${fnv1a(h.lines.map((l) => (l.kind === "add" ? "+" : l.kind === "del" ? "-" : " ") + l.text).join(`
`))}`;
  function cleanPath(raw) {
    let p = raw.trim();
    if (p === "/dev/null")
      return null;
    if (p.startsWith('"') && p.endsWith('"')) {
      p = p.slice(1, -1).replace(/\\(["\\])/g, "$1").replace(/\\t/g, "\t").replace(/\\n/g, `
`);
    }
    const tab = p.indexOf("\t");
    if (tab >= 0)
      p = p.slice(0, tab);
    return p.replace(/^[ab]\//, "");
  }
  function pathsFromGitHeader(rest) {
    const quoted = rest.match(/^"((?:[^"\\]|\\.)*)" "((?:[^"\\]|\\.)*)"$/);
    if (quoted)
      return [cleanPath(`"${quoted[1]}"`) ?? "", cleanPath(`"${quoted[2]}"`) ?? ""];
    const m = rest.match(/^a\/(.*) b\/(.*)$/);
    return m ? [m[1], m[2]] : null;
  }
  function newFile(path) {
    return { path, status: "modified", binary: false, hunks: [], additions: 0, deletions: 0 };
  }
  function parseUnifiedDiff(text) {
    const files = [];
    const lines = text.replace(/\r\n/g, `
`).split(`
`);
    let file = null;
    let hunk = null;
    let oldNo = 0;
    let newNo = 0;
    let oldLeft = 0;
    let newLeft = 0;
    const finishHunk = () => {
      if (file && hunk) {
        hunk.id = hunkId(file.path, hunk);
        file.hunks.push(hunk);
      }
      hunk = null;
    };
    const finishFile = () => {
      finishHunk();
      if (file)
        files.push(file);
      file = null;
    };
    for (const line of lines) {
      if (hunk && (oldLeft > 0 || newLeft > 0)) {
        const c = line[0];
        if (c === " " || c === undefined && line === "") {
          hunk.lines.push({ kind: "context", text: line.slice(1), oldLine: oldNo++, newLine: newNo++ });
          oldLeft--;
          newLeft--;
          continue;
        }
        if (c === "-") {
          hunk.lines.push({ kind: "del", text: line.slice(1), oldLine: oldNo++, newLine: null });
          file.deletions++;
          oldLeft--;
          continue;
        }
        if (c === "+") {
          hunk.lines.push({ kind: "add", text: line.slice(1), oldLine: null, newLine: newNo++ });
          file.additions++;
          newLeft--;
          continue;
        }
      }
      if (line.startsWith("\\ ")) {
        const last = hunk?.lines.at(-1);
        if (last)
          last.noNewline = true;
        continue;
      }
      if (line.startsWith("diff --git ")) {
        finishFile();
        const paths = pathsFromGitHeader(line.slice("diff --git ".length));
        file = newFile(paths?.[1] ?? "");
        if (paths && paths[0] !== paths[1])
          file.oldPath = paths[0];
        continue;
      }
      const h = line.match(HUNK_HEADER);
      if (h) {
        if (!file)
          file = newFile("");
        finishHunk();
        hunk = {
          id: "",
          oldStart: Number(h[1]),
          oldLines: h[2] === undefined ? 1 : Number(h[2]),
          newStart: Number(h[3]),
          newLines: h[4] === undefined ? 1 : Number(h[4]),
          section: h[5] ?? "",
          lines: []
        };
        oldNo = hunk.oldStart;
        newNo = hunk.newStart;
        oldLeft = hunk.oldLines;
        newLeft = hunk.newLines;
        continue;
      }
      if (line.startsWith("--- ")) {
        if (!file || (file.hunks.length > 0 || hunk)) {
          finishFile();
          file = newFile("");
        }
        const old = cleanPath(line.slice(4));
        if (old === null)
          file.status = "added";
        else if (!file.path)
          file.path = old;
        if (old && old !== file.path)
          file.oldPath = old;
        continue;
      }
      if (line.startsWith("+++ ") && file) {
        const next = cleanPath(line.slice(4));
        if (next === null)
          file.status = "deleted";
        else {
          if (file.oldPath === undefined && file.path && file.path !== next)
            file.oldPath = file.path;
          file.path = next;
          if (file.oldPath === next)
            delete file.oldPath;
        }
        continue;
      }
      if (!file)
        continue;
      if (line.startsWith("new file mode"))
        file.status = "added";
      else if (line.startsWith("deleted file mode"))
        file.status = "deleted";
      else if (line.startsWith("rename from ")) {
        file.oldPath = line.slice("rename from ".length);
        file.status = "renamed";
      } else if (line.startsWith("rename to ")) {
        file.path = line.slice("rename to ".length);
        file.status = "renamed";
      } else if (line.startsWith("copy from ")) {
        file.oldPath = line.slice("copy from ".length);
        file.status = "copied";
      } else if (line.startsWith("Binary files ") || line === "GIT binary patch") {
        file.binary = true;
        if (file.status === "modified")
          file.status = "binary";
      }
    }
    finishFile();
    return files.filter((f) => f.path || f.oldPath).map((f) => f.path ? f : { ...f, path: f.oldPath });
  }
  function diffLines(a, b, maxCost = 4000) {
    const n = a.length;
    const m = b.length;
    const max = n + m;
    const offset = max + 1;
    const v = new Int32Array(2 * max + 3);
    const trace = [];
    let found = false;
    for (let d = 0;d <= Math.min(max, maxCost); d++) {
      trace.push(v.slice());
      for (let k = -d;k <= d; k += 2) {
        let x = k === -d || k !== d && v[offset + k - 1] < v[offset + k + 1] ? v[offset + k + 1] : v[offset + k - 1] + 1;
        let y = x - k;
        while (x < n && y < m && a[x] === b[y]) {
          x++;
          y++;
        }
        v[offset + k] = x;
        if (x >= n && y >= m) {
          found = true;
          break;
        }
      }
      if (found)
        break;
    }
    if (!found) {
      return [
        ...a.map((_, i) => ({ kind: "del", oldIndex: i, newIndex: -1 })),
        ...b.map((_, j) => ({ kind: "add", oldIndex: -1, newIndex: j }))
      ];
    }
    const ops = [];
    let x = n;
    let y = m;
    for (let d = trace.length - 1;d >= 0; d--) {
      const vd = trace[d];
      const k = x - y;
      const prevK = k === -d || k !== d && vd[offset + k - 1] < vd[offset + k + 1] ? k + 1 : k - 1;
      const prevX = d === 0 ? 0 : vd[offset + prevK];
      const prevY = prevX - prevK;
      while (x > prevX && y > prevY) {
        x--;
        y--;
        ops.push({ kind: "context", oldIndex: x, newIndex: y });
      }
      if (d > 0) {
        if (x === prevX)
          ops.push({ kind: "add", oldIndex: -1, newIndex: prevY });
        else
          ops.push({ kind: "del", oldIndex: prevX, newIndex: -1 });
      }
      x = prevX;
      y = prevY;
    }
    return ops.reverse();
  }
  var splitLines = (text) => {
    if (text === "")
      return [];
    const lines = text.replace(/\r\n/g, `
`).split(`
`);
    if (lines.at(-1) === "")
      lines.pop();
    return lines;
  };
  function toHunks(path, a, b, ops, context = 3) {
    const changeAt = ops.map((o, i) => o.kind === "context" ? -1 : i).filter((i) => i >= 0);
    if (!changeAt.length)
      return [];
    const ranges = [];
    for (const i of changeAt) {
      const from = Math.max(0, i - context);
      const to = Math.min(ops.length - 1, i + context);
      const last = ranges.at(-1);
      if (last && from <= last[1] + 1)
        last[1] = Math.max(last[1], to);
      else
        ranges.push([from, to]);
    }
    return ranges.map(([from, to]) => {
      const lines = [];
      let oldNo = 0;
      let newNo = 0;
      for (let i = 0;i < from; i++) {
        if (ops[i].kind !== "add")
          oldNo++;
        if (ops[i].kind !== "del")
          newNo++;
      }
      const oldStart = oldNo + 1;
      const newStart = newNo + 1;
      for (let i = from;i <= to; i++) {
        const o = ops[i];
        if (o.kind === "context")
          lines.push({ kind: "context", text: a[o.oldIndex], oldLine: ++oldNo, newLine: ++newNo });
        else if (o.kind === "del")
          lines.push({ kind: "del", text: a[o.oldIndex], oldLine: ++oldNo, newLine: null });
        else
          lines.push({ kind: "add", text: b[o.newIndex], oldLine: null, newLine: ++newNo });
      }
      const oldLines = lines.filter((l) => l.kind !== "add").length;
      const newLines = lines.filter((l) => l.kind !== "del").length;
      const hunk = { id: "", oldStart: oldLines ? oldStart : oldStart - 1, oldLines, newStart: newLines ? newStart : newStart - 1, newLines, section: "", lines };
      hunk.id = hunkId(path, hunk);
      return hunk;
    });
  }
  function diffTexts(path, before, after, context = 3) {
    const a = splitLines(before);
    const b = splitLines(after);
    const hunks = toHunks(path, a, b, diffLines(a, b), context);
    const additions = hunks.reduce((s, h) => s + h.lines.filter((l) => l.kind === "add").length, 0);
    const deletions = hunks.reduce((s, h) => s + h.lines.filter((l) => l.kind === "del").length, 0);
    return { path, status: before === "" && after !== "" ? "added" : after === "" && before !== "" ? "deleted" : "modified", binary: false, hunks, additions, deletions };
  }
  class SourceError extends Error {
    code;
    op;
    constructor(code, message, op) {
      super(message);
      this.code = code;
      this.op = op;
    }
  }
  var codeOf2 = (e) => e && typeof e === "object" && ("code" in e) ? String(e.code) : "error";
  async function call(op, params) {
    try {
      return await cmux.call(op, params);
    } catch (e) {
      throw new SourceError(codeOf2(e), e instanceof Error ? e.message : String(e), op);
    }
  }
  function filesOf(resource) {
    const parsed = resource.patch ? parseUnifiedDiff(resource.patch) : [];
    const byPath = new Map(parsed.map((f) => [f.path, f]));
    const ordered = resource.files.map((s) => {
      const f = byPath.get(s.path);
      byPath.delete(s.path);
      if (f)
        return { ...f, status: s.status, oldPath: s.oldPath ?? f.oldPath };
      return { path: s.path, oldPath: s.oldPath, status: s.status, binary: !!s.binary || s.status === "binary", hunks: [], additions: s.additions, deletions: s.deletions };
    });
    return [...ordered, ...byPath.values()];
  }
  async function currentWorkspace() {
    try {
      const list = await cmux.workspace.list();
      return list.find((w) => w.focused)?.id;
    } catch {
      return;
    }
  }
  async function resolveRepo(input) {
    const workspace = input.workspace ?? (input.repo ? undefined : await currentWorkspace());
    return call("git.status", input.repo ? { repo: input.repo } : { workspace });
  }
  async function byHandle(diff, feedItem = null) {
    const resource = await call("diff.get", { diff, include_patch: true });
    return { resource, files: filesOf(resource), feedItem };
  }
  async function load(input) {
    switch (input.kind) {
      case "worktree": {
        const status = await resolveRepo(input);
        if (!status.repo)
          throw new SourceError("git.not_a_repository", "not a repository");
        const resource = await call("git.diff", { repo: status.repo.repo, head: input.staged ? ":index" : undefined, include_patch: true });
        return { resource, files: filesOf(resource), feedItem: null };
      }
      case "refs": {
        const resource = await call("git.diff", { repo: input.repo, base: input.base, head: input.head, include_patch: true });
        return { resource, files: filesOf(resource), feedItem: null };
      }
      case "resource":
        return byHandle(input.diff);
      case "feedItem": {
        const item = await call("feed.get", { item: input.item });
        if (item.prompt?.subject !== "diff")
          throw new SourceError("feed.not_a_diff", "the review request has no diff");
        return byHandle(item.prompt.ref, item);
      }
      case "run": {
        const run = await call("automation.run.get", { run: input.run });
        if (!run.diff)
          throw new SourceError("run.no_diff", "the run published no diff");
        return byHandle(run.diff);
      }
      case "documents": {
        const [a, b] = await Promise.all([
          call("document.read", { doc: input.base.doc, revision: input.base.revision }),
          call("document.read", { doc: input.head.doc, revision: input.head.revision })
        ]);
        const path = input.title ?? "document";
        const file = diffTexts(path, a.text, b.text);
        const resource = {
          diff: "",
          title: path,
          producer: "user",
          base: { kind: "document", ...input.base },
          head: { kind: "document", ...input.head },
          files: [{ path, status: file.status, additions: file.additions, deletions: file.deletions }]
        };
        return { resource, files: [file], feedItem: null };
      }
    }
  }
  var toError = (e) => e instanceof SourceError ? { code: e.code, message: e.message, op: e.op } : { code: e?.code ?? "error", message: e instanceof Error ? e.message : String(e) };
  var commentSeq = 0;
  function createSession(input) {
    const [loaded, setLoaded] = signal(null);
    const [loading, setLoading] = signal(false);
    const [error, setError] = signal(null);
    const [actionError, setActionError] = signal(null);
    const [selected, setSelected] = signal(null);
    const [state, setState] = signal(emptyReview());
    const [collapsedSet, setCollapsed] = signal({});
    const [shown, setShown] = signal({});
    const [submitted, setSubmitted] = signal(null);
    let generation = 0;
    const files = () => loaded()?.files ?? [];
    async function reload() {
      const gen = ++generation;
      setLoading(true);
      try {
        const next = await load(input());
        if (gen !== generation)
          return;
        setLoaded(next);
        setState(fromOwner(next.files, next.resource.decisions));
        setError(null);
        const sel = selected();
        if (!sel || !next.files.some((f) => f.path === sel))
          setSelected(next.files[0]?.path ?? null);
      } catch (e) {
        if (gen === generation)
          setError(toError(e));
      } finally {
        if (gen === generation)
          setLoading(false);
      }
    }
    async function send(next) {
      setState(next);
      const l = loaded();
      if (!l?.resource.diff)
        return;
      const decisions = unsentDecisions(next, l.files);
      if (!decisions.length)
        return;
      try {
        await cmux.call("diff.decide", { diff: l.resource.diff, decisions });
        setState((s) => confirm(s, l.files, decisions));
        setActionError(null);
      } catch (e) {
        setActionError({ ...toError(e), op: "diff.decide" });
      }
    }
    return {
      input,
      loaded,
      files,
      loading,
      error,
      actionError,
      selected,
      select: (path) => setSelected(path),
      review: state,
      collapsed: (path) => !!collapsedSet()[path],
      toggleCollapsed: (path) => setCollapsed((c) => ({ ...c, [path]: !c[path] })),
      shownLines: (path) => shown()[path] ?? null,
      showMore: (path, by) => setShown((s) => ({ ...s, [path]: (s[path] ?? 0) + by })),
      reload,
      decideHunk: (_file, hunk, decision) => send(decideHunk(state(), hunk, decision)),
      decideFile: (file, decision) => send(decideFile(state(), file, decision)),
      decideAll: async (decision) => {
        let next = state();
        for (const f of files())
          next = decideFile(next, f, decision);
        await send(next);
      },
      async comment(path, line, side, body) {
        const next = addComment(state(), { path, line, side, body }, `c${++commentSeq}`);
        setState(next);
        const l = loaded();
        if (!l?.resource.diff || l.feedItem)
          return;
        try {
          await cmux.call("diff.comment.add", { diff: l.resource.diff, path, line, side, body });
        } catch (e) {
          setActionError({ ...toError(e), op: "diff.comment.add" });
        }
      },
      removeComment: (id) => setState(removeComment(state(), id)),
      submitted,
      async submitReview() {
        const l = loaded();
        if (!l?.feedItem)
          return;
        const s = state();
        const verdict2 = verdict(s, l.files);
        const value = { verdict: verdict2, notes: s.comments.map((c) => ({ path: c.path, line: c.line, text: c.body })) };
        try {
          await cmux.call("feed.answer", { item: l.feedItem.id, value });
          setSubmitted(verdict2);
          setActionError(null);
        } catch (e) {
          setActionError({ ...toError(e), op: "feed.answer" });
        }
      }
    };
  }
  var basename = (path) => path.slice(path.lastIndexOf("/") + 1) || path;
  var dirname = (path) => path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
  function statusSymbol(s) {
    switch (s) {
      case "added":
      case "untracked":
        return "plus.circle";
      case "deleted":
        return "minus.circle";
      case "renamed":
      case "copied":
        return "arrow.right.circle";
      case "binary":
        return "doc.circle";
      default:
        return "circle.fill";
    }
  }
  function statusTint(s) {
    switch (s) {
      case "added":
        return "success";
      case "deleted":
        return "danger";
      case "untracked":
        return "tertiary";
      default:
        return "warning";
    }
  }
  var stat = (a, d) => t("stat", "+{a} −{d}", { a, d });
  function decisionBadge(d) {
    if (d === "pending")
      return null;
    const tone = d === "accept" ? "success" : d === "reject" ? "danger" : "secondary";
    const english = d === "accept" ? "Accepted" : d === "reject" ? "Rejected" : "Partly decided";
    return Badge(t(`file.decision.${d}`, english), tone);
  }
  function producerLine(r) {
    switch (r.producer) {
      case "git":
        return t("producer.git", "Working tree");
      case "agent":
        return t("producer.agent", "Proposed by {name}", { name: r.producerLabel ?? "agent" });
      case "automation":
        return t("producer.run", "Diff from run {name}", { name: r.producerLabel ?? "" });
      default:
        return t("producer.user", "Diff");
    }
  }
  var MISSING_HINTS = {
    "git.status": "Showing changes needs git status from the session host.",
    "git.diff": "Showing a diff needs git diff from the session host.",
    "diff.get": "Opening a diff needs diff resources.",
    "feed.get": "Reviewing a proposal needs feed items.",
    "document.read": "Comparing documents needs the document host."
  };
  function errorState(err) {
    if (err.code === "operation.unsupported" || err.code === "scope.missing") {
      const op = err.op ?? "operation";
      return EmptyState({ title: t("error.missing", "{op} is not available yet.", { op }), message: MISSING_HINTS[op] ?? err.message, symbol: "puzzlepiece.extension" });
    }
    if (err.code === "git.not_a_repository")
      return EmptyState({ title: t("changes.noRepo", "Not a git repository"), symbol: "folder" });
    return EmptyState({ title: t("error.load", "Cannot load the diff"), message: err.message, symbol: "exclamationmark.triangle" });
  }
  function toolbar(session, extra = []) {
    const res = () => session.loaded()?.resource;
    const totals = () => session.files().reduce((s, f) => [s[0] + f.additions, s[1] + f.deletions], [0, 0]);
    return HStack({ spacing: 8 }, [
      VStack({ spacing: 1 }, [
        Text(() => res()?.title ?? "").font("headline").lineLimit(1).truncation("middle"),
        Text(() => {
          const r = res();
          if (!r)
            return "";
          const [a, d] = totals();
          return `${producerLine(r)} · ${t("files.count", "{n} files", { n: session.files().length })} · ${stat(a, d)}`;
        }).font("caption").secondary().lineLimit(1)
      ]),
      Spacer(),
      ...extra,
      Button(() => layout() === "inline" ? t("layout.sideBySide", "Side by Side") : t("layout.inline", "Inline"), () => toggleLayout()).font("caption"),
      Button(Icon("arrow.clockwise"), () => session.reload()).help(t("action.refresh", "Refresh"))
    ]).padding({ top: 6, leading: 10, bottom: 6, trailing: 10 });
  }
  function fileHeader(session, file, opts) {
    return HStack({ spacing: 6 }, [
      () => opts.collapsible ? Icon(() => session.collapsed(file().path) ? "chevron.right" : "chevron.down").font("caption").secondary() : null,
      Icon(() => statusSymbol(file().status)).font("caption").color(() => statusTint(file().status)),
      Text(() => file().path).font("callout").weight("medium").monospaced().lineLimit(1).truncation("head"),
      () => file().oldPath ? Text(t("file.renamed", "Renamed from {path}", { path: file().oldPath })).font("caption").secondary().lineLimit(1) : null,
      Spacer(),
      Text(() => file().binary ? "" : stat(file().additions, file().deletions)).font("caption").monospaced().secondary(),
      opts.controls ?? null
    ]).padding({ top: 5, leading: 10, bottom: 5, trailing: 10 }).background("hover").cursor(opts.collapsible ? "pointer" : "default").onTap(() => opts.collapsible ? session.toggleCollapsed(file().path) : undefined);
  }
  function guarded(session, body) {
    return () => {
      const err = session.error();
      if (err)
        return errorState(err);
      if (!session.loaded())
        return session.loading() ? EmptyState({ title: t("pane.loading", "Loading diff"), symbol: "hourglass" }) : null;
      if (!session.files().length)
        return EmptyState({ title: t("pane.empty", "No differences"), symbol: "checkmark.circle" });
      return body();
    };
  }
  function actionErrorRow(session) {
    return () => {
      const e = session.actionError();
      if (!e)
        return null;
      const op = e.op ?? (e.code === "operation.unsupported" ? "diff.decide" : "");
      return HStack({ spacing: 6 }, [
        Icon("exclamationmark.triangle").font("caption").color("warning"),
        Text(e.code === "operation.unsupported" ? t("error.missing", "{op} is not available yet.", { op: op || e.message }) : e.message).font("caption").lineLimit(2)
      ]).padding({ top: 4, leading: 10, bottom: 4, trailing: 10 });
    };
  }
  var MAX_ROWS = 12;
  function changesSection(deps) {
    const [status, setStatus] = signal(null);
    const [error, setError] = signal(null);
    let generation = 0;
    async function load() {
      const gen = ++generation;
      try {
        const r = await resolveRepo({});
        if (gen !== generation)
          return;
        setStatus(r);
        setError(null);
      } catch (e) {
        if (gen !== generation)
          return;
        setError(e instanceof SourceError ? { code: e.code, message: e.message, op: e.op } : { code: "error", message: String(e) });
      }
    }
    load();
    cmux.events.on("git.changed", (p) => {
      const repo = p?.repo;
      if (!repo || repo === status()?.repo?.repo)
        load();
    });
    cmux.events.on("workspace.changed", () => load());
    const row = (f) => Row({
      title: () => basename(f().path),
      subtitle: () => dirname(f().path) || null,
      symbol: () => statusSymbol(f().status),
      tint: () => statusTint(f().status),
      badge: () => f().status === "untracked" || f().binary ? null : stat(f().additions, f().deletions)
    }).help(() => f().path).onTap(() => deps.open(f().path, f().staged)).contextMenu(() => [Button(t("action.openFile", "Open File"), () => cmux.call("ui.open", { interface: "cmux.editor/1", target: { repo: status()?.repo?.repo, path: f().path } }))]);
    const group = (title, files) => VStack({ spacing: 2 }, [
      title ? Text(title).font("caption").weight("semibold").secondary().padding({ top: 4, leading: 6, bottom: 0, trailing: 6 }) : null,
      ForEach({ items: () => files().slice(0, MAX_ROWS), key: (f) => `${f.staged ? "s" : "w"}:${f.path}` }, row),
      () => files().length > MAX_ROWS ? Text(t("changes.more", "{n} more", { n: files().length - MAX_ROWS })).font("caption").secondary().padding({ top: 0, leading: 8, bottom: 0, trailing: 6 }) : null
    ]);
    return VStack({ spacing: 4 }, [
      () => {
        const err = error();
        if (err)
          return errorState(err);
        const s = status();
        if (!s)
          return null;
        if (!s.repo)
          return EmptyState({ title: t("changes.noRepo", "Not a git repository"), symbol: "folder" });
        if (!s.files.length)
          return EmptyState({ title: t("changes.empty", "No changes"), symbol: "checkmark.circle" });
        const staged = () => (status()?.files ?? []).filter((f) => f.staged);
        const unstaged = () => (status()?.files ?? []).filter((f) => !f.staged);
        const both = staged().length > 0 && unstaged().length > 0;
        return VStack({ spacing: 4 }, [
          HStack({ spacing: 6 }, [
            Icon("arrow.triangle.branch").font("caption").secondary(),
            Text(() => status()?.repo?.branch ?? "HEAD").font("caption").monospaced().secondary().lineLimit(1),
            Spacer(),
            Text(() => t("files.count", "{n} files", { n: status()?.files.length ?? 0 })).font("caption").color("tertiary")
          ]).padding({ top: 0, leading: 6, bottom: 2, trailing: 6 }),
          staged().length ? group(both ? t("changes.staged", "Staged") : null, staged) : null,
          unstaged().length ? group(both ? t("changes.unstaged", "Changes") : null, unstaged) : null
        ]);
      }
    ]);
  }
  function createPaneView(session) {
    const [target, setTarget] = signal(null);
    const [armed, setArmed] = signal(null);
    const [embedApp, setEmbedApp] = signal(null);
    return {
      session,
      target,
      setTarget: (next) => setTarget(next),
      isTarget: (path, line, side) => {
        const tg = target();
        return !!tg && tg.path === path && tg.line === line && tg.side === side;
      },
      armed,
      setArmed: (id) => setArmed(id),
      embedApp,
      noteEmbed: (r) => setEmbedApp(r.app)
    };
  }
  function verbsOf(pv) {
    const r = pv.session.loaded()?.resource;
    const accept = r?.acceptVerb === "stage" ? t("action.stage", "Stage") : r?.acceptVerb === "apply" ? t("action.apply", "Apply") : t("action.accept", "Accept");
    const reject = r?.rejectVerb === "discard" ? t("action.discard", "Discard") : r?.rejectVerb === "drop" ? t("action.drop", "Drop") : t("action.reject", "Reject");
    return { accept, reject, destructiveReject: r?.rejectVerb === "discard" };
  }
  var decidable = (pv) => !!pv.session.loaded()?.resource.diff;
  function rejectButton(pv, id, verbs, send) {
    if (!verbs.destructiveReject)
      return Button(verbs.reject, send).font("caption");
    return Button(() => pv.armed() === id ? `${verbs.reject}?` : verbs.reject, () => {
      if (pv.armed() !== id)
        return pv.setArmed(id);
      pv.setArmed(null);
      return send();
    }).font("caption").destructive();
  }
  function decidedControls(pv, decision, confirmed, undo) {
    return HStack({ spacing: 6 }, [
      Badge(decision === "accept" ? t("file.decision.accept", "Accepted") : t("file.decision.reject", "Rejected"), decision === "accept" ? "success" : "danger"),
      confirmed ? null : Button(t("action.undo", "Undo"), undo).font("caption")
    ]);
  }
  function hunkControls(pv, file, h) {
    return () => {
      if (!decidable(pv))
        return null;
      const state = pv.session.review();
      const d = state.hunks[h.id];
      if (d)
        return decidedControls(pv, d, state.confirmed[h.id] === d, () => pv.session.decideHunk(file, h.id, d));
      const verbs = verbsOf(pv);
      return HStack({ spacing: 6 }, [
        Button(verbs.accept, () => pv.session.decideHunk(file, h.id, "accept")).font("caption"),
        rejectButton(pv, h.id, verbs, () => pv.session.decideHunk(file, h.id, "reject"))
      ]);
    };
  }
  function fileControls(pv, file) {
    return () => {
      if (!decidable(pv) || !file().hunks.length)
        return null;
      const d = fileDecision(pv.session.review(), file());
      if (d === "accept" || d === "reject")
        return decisionBadge(d);
      const verbs = verbsOf(pv);
      const id = `file:${file().path}`;
      return HStack({ spacing: 6 }, [
        d === "partial" ? decisionBadge(d) : null,
        Button(verbs.accept, () => pv.session.decideFile(file(), "accept")).font("caption"),
        rejectButton(pv, id, verbs, () => pv.session.decideFile(file(), "reject"))
      ]);
    };
  }
  var EDITOR_INTERFACE = "cmux.editor/1";
  var pad = (n, w = 4) => (n === null ? "" : String(n)).padStart(w, " ");
  var shown = (text) => text.replace(/\t/g, "    ") || " ";
  var toneOf = (l) => l?.kind === "add" ? "success" : l?.kind === "del" ? "danger" : null;
  var embedBuilder = () => {
    const e = globalThis.Embed;
    return typeof e === "function" ? e : null;
  };
  var LINE_HEIGHT = 17;
  function tinted(tone, content) {
    if (!tone)
      return content;
    return ZStack([Rectangle().fill(tone).opacity(0.14).frame({ maxWidth: "infinity", height: LINE_HEIGHT }), content]);
  }
  function lineRow(pv, path, l) {
    const side = l.newLine === null ? "old" : "new";
    const line = l.newLine ?? l.oldLine;
    const marker = l.kind === "add" ? "+" : l.kind === "del" ? "-" : " ";
    const row = HStack({ spacing: 6 }, [
      Text(`${pad(l.oldLine)} ${pad(l.newLine)}`).font(11).monospaced().color("tertiary"),
      Text(`${marker} ${shown(l.text)}`).font(12).monospaced().lineLimit(1).truncation("tail")
    ]).padding({ top: 0, leading: 6, bottom: 0, trailing: 6 }).frame({ maxWidth: "infinity", height: LINE_HEIGHT }).background(() => pv.isTarget(path, line, side) ? "selected" : null).onTap(() => pv.setTarget({ path, line, side }));
    return tinted(toneOf(l), row);
  }
  function cell(pv, path, l, side) {
    if (!l)
      return Text(" ").font(12).monospaced().frame({ maxWidth: "infinity", height: LINE_HEIGHT }).background("hover");
    const no = side === "old" ? l.oldLine : l.newLine;
    const content = HStack({ spacing: 6 }, [Text(pad(no)).font(11).monospaced().color("tertiary"), Text(shown(l.text)).font(12).monospaced().lineLimit(1).truncation("tail")]).padding({ top: 0, leading: 4, bottom: 0, trailing: 4 }).frame({ maxWidth: "infinity", height: LINE_HEIGHT }).background(() => no !== null && pv.isTarget(path, no, side) ? "selected" : null).onTap(() => no !== null ? pv.setTarget({ path, line: no, side }) : undefined);
    return tinted(l.kind === "context" ? null : toneOf(l), content);
  }
  function sideRow(pv, path, row) {
    return HStack({ spacing: 0 }, [cell(pv, path, row.left, "old"), Rectangle().fill("separator").frame({ width: 1, height: LINE_HEIGHT }), cell(pv, path, row.right, "new")]);
  }
  function hunkHeader(pv, file, h) {
    return HStack({ spacing: 6 }, [
      Text(`@@ -${h.oldStart},${h.oldLines} +${h.newStart},${h.newLines} @@ ${h.section}`.trim()).font(11).monospaced().secondary().lineLimit(1).truncation("tail"),
      Spacer(),
      hunkControls(pv, file, h)
    ]).padding({ top: 3, leading: 8, bottom: 3, trailing: 8 });
  }
  function hunkComments(pv, file, h) {
    return () => {
      const state = pv.session.review();
      const notes = h.lines.flatMap((l) => commentsAt(state, file.path, l));
      const target = pv.target();
      const here = target && target.path === file.path && h.lines.some((l) => target.side === "new" ? l.newLine === target.line : l.newLine === null && l.oldLine === target.line);
      if (!notes.length && !here)
        return null;
      return VStack({ spacing: 4 }, [
        ...notes.map((c) => HStack({ spacing: 6 }, [
          Icon("text.bubble").font("caption").secondary(),
          Text(`${c.side === "old" ? "−" : ""}${c.line}  ${c.body}`).font("callout").lineLimit(4),
          Spacer(),
          Button(Icon("xmark"), () => pv.session.removeComment(c.id)).help(t("action.deleteComment", "Delete Comment"))
        ])),
        here ? TextField("", {
          placeholder: t("comment.placeholder", "Add a comment"),
          autofocus: true,
          onSubmit: (text) => {
            pv.setTarget(null);
            return pv.session.comment(target.path, target.line, target.side, text);
          },
          onCancel: () => pv.setTarget(null)
        }).font("callout").padding({ top: 4, leading: 8, bottom: 4, trailing: 8 }).background("hover").cornerRadius(6) : null
      ]).padding({ top: 4, leading: 12, bottom: 6, trailing: 10 });
    };
  }
  function budgeted(pv, file) {
    const budget = fallbackLines() + (pv.session.shownLines(file.path) ?? 0);
    const out = [];
    let used = 0;
    for (const h of file.hunks) {
      if (used > 0 && used + h.lines.length > budget)
        break;
      out.push(h);
      used += h.lines.length;
    }
    const total = file.hunks.reduce((s, h) => s + h.lines.length, 0);
    return { hunks: out, hidden: total - used };
  }
  function sceneDiff(pv, file) {
    if (file.binary)
      return Text(t("file.binary", "Binary file")).font("callout").secondary().padding(10);
    return Group([
      () => {
        const side = layout() === "sideBySide";
        const { hunks, hidden } = budgeted(pv, file);
        return VStack({ spacing: 0 }, [
          ...hunks.flatMap((h) => [
            hunkHeader(pv, file, h),
            VStack({ spacing: 0 }, side ? sideBySide(h).map((r) => sideRow(pv, file.path, r)) : h.lines.map((l) => lineRow(pv, file.path, l))),
            hunkComments(pv, file, h)
          ]),
          hidden > 0 ? Button(t("action.showMore", "Show {n} more lines", { n: hidden }), () => pv.session.showMore(file.path, fallbackLines())).font("caption").padding(8) : null
        ]);
      }
    ]);
  }
  function editorDiffProps(diff, file, mode) {
    return {
      readOnly: true,
      chrome: "none",
      diff: {
        original: { diff, path: file.oldPath ?? file.path, side: "base" },
        modified: { diff, path: file.path, side: "head" },
        layout: mode,
        path: file.path
      }
    };
  }
  function fileBody(pv, file) {
    const build = embedBuilder();
    const diff = pv.session.loaded()?.resource.diff;
    if (!build || !diff || file.binary)
      return sceneDiff(pv, file);
    const [embed, setEmbed] = signal(null);
    const [failed, setFailed] = signal(false);
    cmux.call("ui.embed.create", { interface: EDITOR_INTERFACE, props: editorDiffProps(diff, file, layout()), prefer: editorApp(), minHeight: 120 }).then((r) => {
      setEmbed(r);
      pv.noteEmbed(r);
    }).catch(() => setFailed(true));
    let sentMode = layout();
    effect(() => {
      const mode = layout();
      const e = embed();
      if (!e || mode === sentMode)
        return;
      sentMode = mode;
      cmux.call("ui.embed.update", { embed: e.embed, props: editorDiffProps(diff, file, mode) }).catch(() => setFailed(true));
    });
    return Group([
      () => {
        if (failed())
          return sceneDiff(pv, file);
        const e = embed();
        return e ? build({ embed: e.embed, minHeight: 120 }) : ProgressView();
      }
    ]);
  }
  function footer(pv) {
    return Text(() => {
      const app = pv.embedApp();
      return app ? t("footer.embed", "Shown with {app}", { app }) : t("footer.builtin", "Built-in diff view");
    }).font("caption2").color("tertiary").padding({ top: 6, leading: 10, bottom: 8, trailing: 10 });
  }
  function fileListRow(pv, file) {
    return Row({
      title: () => basename(file().path),
      subtitle: () => dirname(file().path) || null,
      symbol: () => statusSymbol(file().status),
      tint: () => statusTint(file().status),
      badge: () => file().binary ? null : stat(file().additions, file().deletions),
      selected: () => pv.session.selected() === file().path
    }).onTap(() => pv.session.select(file().path));
  }
  function selectedBody(pv) {
    return () => {
      const path = pv.session.selected();
      const file = pv.session.files().find((f) => f.path === path);
      if (!file)
        return EmptyState({ title: t("pane.selectFile", "Select a file"), symbol: "doc.text" });
      return VStack({ spacing: 0 }, [
        fileHeader(pv.session, () => file, { collapsible: false, controls: fileControls(pv, () => file) }),
        fileBody(pv, file)
      ]);
    };
  }
  function splitView(pv) {
    return VStack({ spacing: 0 }, [
      toolbar(pv.session),
      Divider(),
      actionErrorRow(pv.session),
      guarded(pv.session, () => HStack({ spacing: 0 }, [
        VStack({ spacing: 2 }, [ForEach({ items: pv.session.files, key: (f) => f.path }, (f) => fileListRow(pv, f)), Spacer()]).padding(6).frame({ width: 230, maxHeight: "infinity" }),
        Divider(),
        VStack({ spacing: 0 }, [selectedBody(pv), Spacer()]).frame({ maxWidth: "infinity", maxHeight: "infinity" })
      ])),
      footer(pv)
    ]);
  }
  function streamFile(pv, file) {
    return VStack({ spacing: 0 }, [
      fileHeader(pv.session, file, { collapsible: true, controls: fileControls(pv, file) }),
      () => pv.session.collapsed(file().path) ? null : fileBody(pv, file())
    ]).borderColor("separator").cornerRadius(6);
  }
  function streamView(pv) {
    return VStack({ spacing: 0 }, [
      toolbar(pv.session),
      Divider(),
      actionErrorRow(pv.session),
      guarded(pv.session, () => VStack({ spacing: 10 }, [ForEach({ items: pv.session.files, key: (f) => f.path }, (f) => streamFile(pv, f))]).padding(10)),
      footer(pv)
    ]);
  }
  function reviewSummary(pv) {
    const s = pv.session;
    return VStack({ spacing: 6 }, [
      () => {
        const checklist = s.loaded()?.feedItem?.prompt.checklist ?? [];
        return checklist.length ? VStack({ spacing: 2 }, checklist.map((c) => HStack({ spacing: 6 }, [Icon("checklist").font("caption").secondary(), Text(c).font("callout")]))) : null;
      },
      HStack({ spacing: 8 }, [
        Text(() => {
          const c = counts(s.review(), s.files());
          return t("review.counts", "{accepted} accepted · {rejected} rejected · {pending} left", { accepted: c.accepted, rejected: c.rejected, pending: c.pending });
        }).font("caption").secondary(),
        Spacer(),
        Button(t("action.acceptAll", "Accept All"), () => s.decideAll("accept")).font("caption"),
        Button(t("action.rejectAll", "Reject All"), () => s.decideAll("reject")).font("caption"),
        () => {
          if (!s.loaded()?.feedItem)
            return null;
          if (s.submitted())
            return Badge(t("review.sent", "Review sent"), "success");
          const v = verdict(s.review(), s.files());
          const label = t(`review.verdict.${v}`, v === "approve" ? "Approve" : v === "request_changes" ? "Request Changes" : "Comment");
          return Button(`${t("action.submit", "Submit Review")}: ${label}`, () => s.submitReview()).font("caption").weight("semibold");
        }
      ])
    ]).padding({ top: 6, leading: 10, bottom: 6, trailing: 10 });
  }
  function reviewView(pv) {
    return VStack({ spacing: 0 }, [
      toolbar(pv.session),
      reviewSummary(pv),
      Divider(),
      actionErrorRow(pv.session),
      guarded(pv.session, () => VStack({ spacing: 10 }, [ForEach({ items: pv.session.files, key: (f) => f.path }, (f) => streamFile(pv, f))]).padding(10)),
      footer(pv)
    ]);
  }
  var isInput = (v) => !!v && typeof v === "object" && typeof v.kind === "string";
  function renderChanges(ctx = {}) {
    setLanguage(detectLanguage(ctx));
    return changesSection({ open: (path, staged) => openChanges({ path, staged }) });
  }
  function renderDiffPane(ctx = {}) {
    setLanguage(detectLanguage(ctx));
    const own = isInput(ctx.input) ? ctx.input : null;
    const session = createSession(() => own ?? defaultInput());
    const pv = createPaneView(session);
    if (typeof ctx.focusPath === "string")
      session.select(ctx.focusPath);
    effect(() => {
      session.input();
      session.reload();
    });
    effect(() => {
      const req = focusRequest();
      if (req)
        session.select(req.path);
    });
    cmux.events.on("git.changed", () => {
      if (["worktree", "refs"].includes(session.input().kind))
        session.reload();
    });
    cmux.events.on("diff.changed", (p) => {
      const diff = p?.diff;
      if (diff && diff === session.loaded()?.resource.diff)
        session.reload();
    });
    return VStack({ spacing: 0 }, [
      () => {
        switch (variant()) {
          case "stream":
            return streamView(pv);
          case "review":
            return reviewView(pv);
          default:
            return splitView(pv);
        }
      }
    ]);
  }
  var openChanges2 = openChanges;
  var openDiff2 = openDiff;
  var review2 = review;
  var reviewLatest2 = reviewLatest;
  var toggleLayout3 = toggleLayout2;
  var cycleVariant3 = cycleVariant2;
  globalThis.__cmuxAppExports = { ...exports_main };
})();
