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
    clearRecent: () => clearRecent,
    cycleVariant: () => cycleVariant,
    renderPane: () => renderPane,
    renderSection: () => renderSection,
    search: () => search
  });
  var fold = (s, caseSensitive) => caseSensitive ? s : s.toLowerCase();
  var isWordChar = (c) => !!c && /[\p{L}\p{N}_]/u.test(c);
  function compile(query) {
    const text = query.text;
    const empty = !text || !!query.error;
    const re = query.regex && !empty ? new RegExp(text, query.caseSensitive ? "" : "i") : null;
    const needle = fold(text, query.caseSensitive);
    const words = needle.split(/\s+/).filter(Boolean);
    const find = (hay) => {
      if (empty || !hay)
        return null;
      if (re) {
        const m = re.exec(hay);
        return m && m[0].length > 0 ? { start: m.index, length: m[0].length } : null;
      }
      const at = fold(hay, query.caseSensitive).indexOf(needle);
      return at < 0 ? null : { start: at, length: text.length };
    };
    const name = (hay) => {
      if (empty || !hay)
        return null;
      if (re) {
        const r = find(hay);
        return r ? { quality: 65, range: r } : null;
      }
      const h = fold(hay, query.caseSensitive);
      if (h === needle)
        return { quality: 100, range: { start: 0, length: hay.length } };
      const at = h.indexOf(needle);
      if (at === 0)
        return { quality: 90, range: { start: 0, length: text.length } };
      if (at > 0)
        return { quality: isWordChar(h[at - 1]) ? 70 : 80, range: { start: at, length: text.length } };
      if (query.exact)
        return null;
      if (words.length > 1 && words.every((w) => h.includes(w)))
        return { quality: 60, range: { start: h.indexOf(words[0]), length: words[0].length } };
      return fuzzy(needle.replace(/\s+/g, ""), h);
    };
    return { query, find, name };
  }
  function fuzzy(needle, hay) {
    if (needle.length < 2)
      return null;
    let score = 0;
    let run = 0;
    let first = -1;
    let last = -1;
    let j = 0;
    for (let i = 0;i < hay.length && j < needle.length; i++) {
      if (hay[i] !== needle[j]) {
        run = 0;
        continue;
      }
      if (first < 0)
        first = i;
      run++;
      score += run > 1 ? 3 : 1;
      if (i === 0 || !isWordChar(hay[i - 1]))
        score += 2;
      last = i;
      j++;
    }
    if (j < needle.length)
      return null;
    const spread = last - first + 1 - needle.length;
    const quality = Math.max(20, Math.min(55, 20 + Math.round(score / (needle.length * 3) * 35) - Math.min(15, spread)));
    return { quality, range: null };
  }
  var squash = (s) => s.replace(/\s+/g, " ");
  function snippet(text, range, radius = 60) {
    if (!range) {
      const flat = squash(text).trim();
      return { before: flat.length > radius * 2 ? `${flat.slice(0, radius * 2)}…` : flat, match: "", after: "" };
    }
    const end = range.start + range.length;
    const from = Math.max(0, range.start - radius);
    const to = Math.min(text.length, end + radius);
    const before = squash(text.slice(from, range.start)).trimStart();
    const after = squash(text.slice(end, to)).trimEnd();
    return { before: (from > 0 ? "…" : "") + before, match: squash(text.slice(range.start, end)), after: after + (to < text.length ? "…" : "") };
  }
  var joinSegments = (s) => s.before + s.match + s.after;
  function nameSegments(text, range) {
    if (!range)
      return { before: text, match: "", after: "" };
    return { before: text.slice(0, range.start), match: text.slice(range.start, range.start + range.length), after: text.slice(range.start + range.length) };
  }
  var SOURCES = ["workspaces", "terminals", "browser", "apps", "files"];
  var PREFIXES = { w: "workspaces", t: "terminals", b: "browser", a: "apps", f: "files" };
  var PREFIX = /^([wtbaf]):\s*/i;
  var SCOPE_TOKEN = /(^|\s)in:(here|all)(?=\s|$)/i;
  var REGEX_LITERAL = /^\/(.+)\/([a-z]*)$/;
  function parseQuery(raw, options = {}) {
    let rest = raw.trim();
    let scope = null;
    const scopeMatch = SCOPE_TOKEN.exec(rest);
    if (scopeMatch) {
      scope = scopeMatch[2].toLowerCase() === "here" ? "workspace" : "all";
      rest = (rest.slice(0, scopeMatch.index) + rest.slice(scopeMatch.index + scopeMatch[0].length)).trim();
    }
    const sources = [];
    for (let m = PREFIX.exec(rest);m; m = PREFIX.exec(rest)) {
      const source = PREFIXES[m[1].toLowerCase()];
      if (!sources.includes(source))
        sources.push(source);
      rest = rest.slice(m[0].length);
    }
    let regex = options.regex === true;
    let exact = false;
    let flagsCaseInsensitive = false;
    const literal = REGEX_LITERAL.exec(rest);
    if (literal) {
      regex = true;
      rest = literal[1];
      flagsCaseInsensitive = literal[2].includes("i");
    } else if (!regex && rest.length >= 2 && rest.startsWith('"') && rest.endsWith('"')) {
      exact = true;
      rest = rest.slice(1, -1);
    }
    const caseSensitive = !flagsCaseInsensitive && /[A-Z]/.test(regex ? rest.replace(/\\[A-Za-z]/g, "") : rest);
    let error = null;
    if (regex && rest) {
      try {
        new RegExp(rest, caseSensitive ? "" : "i");
      } catch (e) {
        error = e instanceof Error ? e.message : String(e);
      }
    }
    return { raw, text: rest, sources: sources.length ? sources : null, regex, exact, caseSensitive, scope, error };
  }
  function effectiveSources(query, filter, enabled) {
    const wanted = query.sources ?? (filter ? [filter] : SOURCES);
    return SOURCES.filter((s) => wanted.includes(s) && enabled.includes(s));
  }
  var isSourceId = (v) => typeof v === "string" && SOURCES.includes(v);
  var DAY = 24 * 60 * 60 * 1000;
  function recencyBonus(ms, nowMs) {
    if (!ms || !Number.isFinite(ms) || ms <= 0)
      return 0;
    const age = Math.max(0, nowMs - ms);
    return Math.round(24 * (1 - Math.min(age, 7 * DAY) / (7 * DAY)));
  }
  function score(hit, ctx) {
    let s = hit.quality + recencyBonus(hit.updatedAtMs, ctx.nowMs);
    if (ctx.scope === "all" && ctx.currentWorkspace && hit.workspaceId === ctx.currentWorkspace)
      s += 8;
    const opened = ctx.opened[hit.id];
    if (opened)
      s += Math.round(16 * (1 - Math.min(Math.max(0, ctx.nowMs - opened), 30 * DAY) / (30 * DAY)));
    return s;
  }
  var byRank = (a, b) => b.score - a.score || (b.updatedAtMs ?? 0) - (a.updatedAtMs ?? 0) || a.title.localeCompare(b.title);
  function rank(lists, ctx) {
    const byId = new Map;
    for (const list of lists) {
      for (const raw of list) {
        const hit = { ...raw, score: score(raw, ctx) };
        const prev = byId.get(hit.id);
        if (!prev || hit.score > prev.score)
          byId.set(hit.id, hit);
      }
    }
    return [...byId.values()].sort(byRank);
  }
  function group(hits, limitPerGroup, truncatedSources = new Set) {
    const out = [];
    for (const source of SOURCES) {
      const members = hits.filter((h) => h.source === source);
      if (!members.length)
        continue;
      out.push({ source, hits: members.slice(0, limitPerGroup), total: members.length, truncated: truncatedSources.has(source) || members.length > limitPerGroup });
    }
    return out;
  }
  function activeHit(ranked, selectedId) {
    return (selectedId ? ranked.find((h) => h.id === selectedId) : undefined) ?? ranked[0] ?? null;
  }
  function groupLimit(density, sourceCount) {
    if (sourceCount === 1)
      return 40;
    return density === "compact" ? 4 : 8;
  }
  function places(snapshot) {
    const wsOfScreen = new Map(snapshot.screens.map((s) => [s.id, s.workspace_id]));
    const wsOfPane = new Map(snapshot.panes.map((p) => [p.id, wsOfScreen.get(p.screen_id) ?? null]));
    const wsOfTab = new Map(snapshot.tabs.map((t) => [t.id, wsOfPane.get(t.pane_id) ?? null]));
    const names = new Map(snapshot.workspaces.map((w) => [w.id, w.name]));
    const workspaceOfTab = (tabId) => tabId ? wsOfTab.get(tabId) ?? null : null;
    return {
      workspaceOfTab,
      workspaceName: (id) => id ? names.get(id) ?? "" : "",
      currentWorkspace: snapshot.workspaces.find((w) => w.focused)?.id ?? null,
      folders(workspaceId) {
        const out = [];
        for (const t of snapshot.terminals) {
          if (!t.cwd)
            continue;
          if (workspaceId && workspaceOfTab(t.tab_id) !== workspaceId)
            continue;
          out.push(t.cwd);
        }
        return distinctRoots(out);
      }
    };
  }
  function distinctRoots(paths, max = 8) {
    const clean = [...new Set(paths.map((p) => p.length > 1 ? p.replace(/\/+$/, "") : p))].sort((a, b) => a.length - b.length);
    const out = [];
    for (const p of clean) {
      if (out.some((root) => root === "/" || p === root || p.startsWith(`${root}/`)))
        continue;
      out.push(p);
      if (out.length >= max)
        break;
    }
    return out;
  }
  function best(primary, secondary) {
    const a = primary ? primary.quality : -1;
    const b = secondary ? Math.round(secondary.quality * 0.7) : -1;
    if (a < 0 && b < 0)
      return null;
    return a >= b ? { quality: a, primary: true, match: primary } : { quality: b, primary: false, match: secondary };
  }
  var lastPathPart = (p) => p.replace(/\/+$/, "").split("/").pop() || p;
  var home = (p) => p.replace(/^\/Users\/[^/]+/, "~").replace(/^\/home\/[^/]+/, "~");
  function searchSnapshot(snapshot, matcher, sources, at) {
    const hits = [];
    const base = { preview: null, updatedAtMs: null, score: 0 };
    if (sources.includes("workspaces")) {
      for (const w of snapshot.workspaces) {
        const m = matcher.name(w.name);
        if (!m)
          continue;
        hits.push({ ...base, id: `workspace:${w.id}`, source: "workspaces", kind: "workspace", title: w.name, location: "", symbol: "square.stack", titleRange: m.range, quality: m.quality, workspaceId: w.id, target: { op: "workspace.focus", params: { workspace: w.id } } });
      }
    }
    const tabName = new Map(snapshot.tabs.map((t) => [t.id, t.name]));
    if (sources.includes("terminals")) {
      for (const term of snapshot.terminals) {
        if (!term.tab_id)
          continue;
        const title = tabName.get(term.tab_id) || term.title || (term.cwd ? lastPathPart(term.cwd) : "");
        const m = best(matcher.name(title), term.cwd ? matcher.name(term.cwd) : null);
        if (!m)
          continue;
        const ws = at.workspaceOfTab(term.tab_id);
        const where = [at.workspaceName(ws), term.cwd ? home(term.cwd) : ""].filter(Boolean).join(" · ");
        hits.push({ ...base, id: `terminal:${term.id}`, source: "terminals", kind: "terminal", title, location: where, symbol: term.running ? "terminal" : "terminal.fill", titleRange: m.primary ? m.match.range : null, quality: m.quality, workspaceId: ws, target: { op: "tab.focus", params: ws ? { tab: term.tab_id, workspace: ws } : { tab: term.tab_id } } });
      }
    }
    if (sources.includes("browser")) {
      for (const b of snapshot.browsers) {
        const title = tabName.get(b.tab_id) || b.title || b.url;
        const m = best(matcher.name(title), matcher.name(b.url));
        if (!m)
          continue;
        const ws = at.workspaceOfTab(b.tab_id);
        const where = [at.workspaceName(ws), hostOf(b.url)].filter(Boolean).join(" · ");
        hits.push({ ...base, id: `browser:${b.id}`, source: "browser", kind: "browserTab", title, location: where, symbol: "globe", titleRange: m.primary ? m.match.range : null, quality: m.quality, workspaceId: ws, target: { op: "tab.focus", params: ws ? { tab: b.tab_id, workspace: ws } : { tab: b.tab_id } } });
      }
    }
    return hits;
  }
  function hostOf(url) {
    const m = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]+)/i.exec(url);
    return m ? m[1].replace(/^www\./, "") : url;
  }
  var ja = {
    "field.placeholder": "検索",
    "field.placeholder.long": "ワークスペース、ターミナル、ページ、ファイルを検索",
    "source.workspaces": "ワークスペース",
    "source.terminals": "ターミナル",
    "source.browser": "ブラウザ",
    "source.apps": "アプリ",
    "source.files": "ファイル",
    "filter.all": "すべて",
    "scope.workspace": "このワークスペース",
    "scope.all": "すべての場所",
    "regex.toggle": ".*",
    "regex.help": "正規表現",
    "recent.title": "最近の検索",
    "recent.clear": "最近の検索を消去",
    more: "さらに {count} 件",
    "more.unknown": "さらに結果があります",
    "empty.title": "すべてを検索",
    "empty.message": "t: ターミナル、f: ファイル、b: ブラウザ、w: ワークスペース、a: アプリ。/正規表現/ も使えます。",
    "none.title": "一致なし",
    "none.message": "「{query}」に一致する項目はありません",
    "none.here": "ここには一致なし。in:all を試してください。",
    "invalid.title": "正規表現が無効です",
    searching: "検索中…",
    open: "開く",
    "location.closed": "終了済み",
    screenOnly: "表示中の画面のみ",
    "missing.terminals": "ターミナルの履歴検索には terminal.search が必要です（表示中の画面のみ検索しました）",
    "missing.browser": "閲覧履歴の検索には browser.history.search が必要です",
    "missing.files": "ファイル検索には fs.search が必要です",
    "missing.files.noRoots": "検索するフォルダがありません（ターミナルの作業ディレクトリから決まります）",
    "missing.apps": "他のアプリの検索には search.providers.query が必要です",
    "missing.workspaces": "名前の検索には session.snapshot が必要です",
    "missing.scope": "{source}: アクセスが許可されていません",
    "missing.generic": "{source}: 検索できません（{code}）",
    "hint.palette": "↩ 開く  ⎋ 消去",
    "preview.none": "結果を選ぶとここに表示されます"
  };
  var tables = { ja };
  var locale = "en";
  function setLocale(tag) {
    const lang = (tag ?? "en").toLowerCase().split(/[-_]/)[0];
    locale = tables[lang] ? lang : "en";
  }
  function t(key, english, vars = {}) {
    const template = tables[locale]?.[key] ?? english;
    return template.replace(/\{(\w+)\}/g, (m, name) => (name in vars) ? String(vars[name]) : m);
  }
  var codeOf = (e) => e && typeof e === "object" && ("code" in e) ? String(e.code) : "operation.failed";
  var unavailable = (source, op, e) => ({ hits: [], truncated: false, unavailable: { source, op, code: codeOf(e) } });
  var base = { titleRange: null, score: 0 };
  async function terminalText(input) {
    const { call, matcher, scope, at } = input;
    const here = scope === "workspace" ? at.currentWorkspace : null;
    const inScope = input.terminals.filter((t) => !here || at.workspaceOfTab(t.tab_id) === here);
    const q = matcher.query;
    try {
      const r = await call("terminal.search", {
        query: q.text,
        regex: q.regex,
        case_sensitive: q.caseSensitive,
        ...here ? { terminals: inScope.map((t) => t.id) } : { include_closed: true },
        limit: input.limit,
        per_terminal: 3,
        context_chars: 80,
        search_id: input.searchId
      });
      const hits = r.matches.map((m) => {
        const ws = at.workspaceOfTab(m.tab);
        return {
          ...base,
          id: `terminalText:${m.terminal}:${m.row}`,
          source: "terminals",
          kind: "terminalText",
          title: m.title,
          location: [at.workspaceName(ws), m.closed ? t("location.closed", "closed") : ""].filter(Boolean).join(" · "),
          symbol: m.closed ? "clock.arrow.circlepath" : "text.magnifyingglass",
          preview: snippet(m.line_text, { start: m.match_start, length: m.match_length }),
          quality: 50,
          updatedAtMs: m.last_output_at_ms,
          workspaceId: ws,
          target: m.tab ? { op: "tab.focus", params: ws ? { tab: m.tab, workspace: ws } : { tab: m.tab }, reveal: { terminal: m.terminal, row: m.row } } : { op: "action.run", params: { id: "history.reopen", args: { terminal: m.terminal } } }
        };
      });
      return { hits, truncated: r.truncated, unavailable: null };
    } catch (e) {
      if (codeOf(e) !== "operation.unsupported")
        return unavailable("terminals", "terminal.search", e);
      return screens(input, inScope);
    }
  }
  async function screens(input, terminals) {
    const { call, matcher, at } = input;
    const running = terminals.filter((t) => t.running && t.tab_id).slice(0, 12);
    const reads = await Promise.allSettled(running.map((t) => call("terminal.screen.read", { terminal: t.id })));
    const hits = [];
    let denied = null;
    reads.forEach((r, i) => {
      const term = running[i];
      if (r.status === "rejected") {
        denied ??= r.reason;
        return;
      }
      let found = 0;
      r.value.text.split(`
`).forEach((line, row) => {
        if (found >= 3)
          return;
        const range = matcher.find(line);
        if (!range)
          return;
        found++;
        const ws = at.workspaceOfTab(term.tab_id);
        hits.push({ ...base, id: `terminalScreen:${term.id}:${row}`, source: "terminals", kind: "terminalText", title: term.title, location: at.workspaceName(ws), symbol: "text.magnifyingglass", preview: snippet(line, range), quality: 50, updatedAtMs: null, workspaceId: ws, screenOnly: true, target: { op: "tab.focus", params: ws ? { tab: term.tab_id, workspace: ws } : { tab: term.tab_id } } });
      });
    });
    if (denied && !hits.length && reads.every((r) => r.status === "rejected"))
      return unavailable("terminals", "terminal.screen.read", denied);
    return { hits, truncated: false, unavailable: { source: "terminals", op: "terminal.search", code: "operation.unsupported" } };
  }
  async function history(input) {
    if (input.scope === "workspace")
      return { hits: [], truncated: false, unavailable: null };
    const q = input.matcher.query;
    try {
      const r = await input.call("browser.history.search", { query: q.text, regex: q.regex, limit: input.limit, search_id: input.searchId });
      const hits = r.entries.map((e) => {
        const m = input.matcher.name(e.title) ?? input.matcher.name(e.url);
        return { ...base, id: `history:${e.url}`, source: "browser", kind: "history", title: e.title || e.url, location: hostOf(e.url), symbol: "clock", titleRange: m && input.matcher.name(e.title) ? m.range : null, preview: null, quality: Math.max(40, Math.round((m?.quality ?? 50) * 0.9)), updatedAtMs: e.last_visit_ms, workspaceId: null, target: { op: "action.run", params: { id: "openBrowser", args: { url: e.url } } } };
      });
      return { hits, truncated: r.truncated, unavailable: null };
    } catch (e) {
      return unavailable("browser", "browser.history.search", e);
    }
  }
  async function files(input) {
    const roots = input.at.folders(input.scope === "workspace" ? input.at.currentWorkspace : null);
    if (!roots.length)
      return { hits: [], truncated: false, unavailable: { source: "files", op: "fs.search", code: "no.roots" } };
    const q = input.matcher.query;
    try {
      const r = await input.call("fs.search", { roots, query: q.text, mode: "both", regex: q.regex, case_sensitive: q.caseSensitive, limit: input.limit, search_id: input.searchId });
      const hits = r.matches.map((m) => {
        const name = m.relative.split("/").pop() || m.relative;
        const isName = m.kind === "name";
        const nameRange = isName ? input.matcher.name(name) : null;
        return {
          ...base,
          id: isName ? `file:${m.path}` : `fileContent:${m.path}:${m.line ?? 0}`,
          source: "files",
          kind: isName ? "file" : "fileContent",
          title: name,
          location: isName ? m.relative : `${m.relative}:${m.line ?? 1}`,
          symbol: isName ? "doc" : "doc.text.magnifyingglass",
          titleRange: nameRange?.range ?? null,
          preview: isName || m.line_text === undefined ? null : snippet(m.line_text, { start: m.match_start, length: m.match_length }),
          quality: isName ? nameRange?.quality ?? 60 : 45,
          updatedAtMs: m.modified_ms,
          workspaceId: null,
          target: { op: "action.run", params: { id: "file.open", args: m.line ? { path: m.path, line: m.line, column: m.column ?? 1 } : { path: m.path } } }
        };
      });
      return { hits, truncated: r.truncated, unavailable: null };
    } catch (e) {
      return unavailable("files", "fs.search", e);
    }
  }
  async function apps(input, selfId) {
    if (input.scope === "workspace")
      return { hits: [], truncated: false, unavailable: null };
    try {
      const r = await input.call("search.providers.query", { query: input.matcher.query.raw.trim(), limit_per_provider: Math.min(input.limit, 8), search_id: input.searchId });
      const hits = [];
      let truncated = false;
      for (const p of r.providers) {
        const appId = p.provider.split("#")[0];
        if (appId === selfId || p.error)
          continue;
        truncated ||= p.truncated;
        for (const item of p.items) {
          const m = input.matcher.name(item.title);
          hits.push({
            ...base,
            id: `app:${p.provider}:${item.id}`,
            source: "apps",
            kind: "appItem",
            title: item.title,
            location: [p.title, item.subtitle].filter(Boolean).join(" · "),
            symbol: item.symbol ?? "square.grid.2x2",
            titleRange: m?.range ?? null,
            preview: item.line_text !== undefined && item.match_start !== undefined ? snippet(item.line_text, { start: item.match_start, length: item.match_length ?? 0 }) : null,
            quality: m?.quality ?? 50,
            updatedAtMs: item.updated_at_ms ?? null,
            workspaceId: null,
            target: { op: "action.run", params: { id: `app.${appId}#${item.open.command}`, args: item.open.args ?? {} } }
          });
        }
      }
      return { hits, truncated, unavailable: null };
    } catch (e) {
      return unavailable("apps", "search.providers.query", e);
    }
  }
  var emptyResponse = (query, scope) => ({ query, scope, groups: [], ranked: [], top: null, unavailable: [], truncated: false, pending: [], currentWorkspace: null });
  async function runSearch(req, call, onPartial) {
    const q = req.query;
    if (!q.text)
      return emptyResponse(q.raw, req.scope);
    if (q.error)
      return { ...emptyResponse(q.raw, req.scope), error: q.error, unavailable: req.sources.map((source) => ({ source, op: "", code: "query.invalid" })) };
    const matcher = compile(q);
    let snapshot = null;
    const unavailable = [];
    try {
      snapshot = await call("session.snapshot", {});
    } catch (e) {
      const code = e && typeof e === "object" && "code" in e ? String(e.code) : "operation.failed";
      for (const source of req.sources)
        if (source === "workspaces")
          unavailable.push({ source, op: "session.snapshot", code });
    }
    const snap = snapshot ?? { workspaces: [], screens: [], panes: [], tabs: [], terminals: [], browsers: [] };
    const at = places(snap);
    const ctx = { nowMs: req.nowMs, scope: req.scope, currentWorkspace: at.currentWorkspace, opened: req.opened };
    const inScope = (h) => req.scope === "all" || h.workspaceId === at.currentWorkspace || h.source === "files";
    const local = searchSnapshot(snap, matcher, req.sources, at).filter(inScope);
    const input = { call, matcher, scope: req.scope, at, terminals: snap.terminals, limit: req.limit, searchId: req.searchId };
    const jobs = [];
    if (req.sources.includes("terminals"))
      jobs.push(["terminals", () => terminalText({ ...input, searchId: `${req.searchId}:terminals` })]);
    if (req.sources.includes("browser"))
      jobs.push(["browser", () => history({ ...input, searchId: `${req.searchId}:history` })]);
    if (req.sources.includes("apps"))
      jobs.push(["apps", () => apps({ ...input, searchId: `${req.searchId}:apps` }, req.selfId)]);
    if (req.sources.includes("files"))
      jobs.push(["files", () => files({ ...input, searchId: `${req.searchId}:files` })]);
    const done = new Map;
    const compose = () => {
      const lists = [local, ...[...done.values()].map((r) => r.hits.filter(inScope))];
      const ranked = rank(lists, ctx);
      const truncatedSources = new Set([...done].filter(([, r]) => r.truncated).map(([s]) => s));
      const groups = group(ranked, groupLimit(req.density, req.sources.length), truncatedSources);
      const missing = [...unavailable, ...[...done.values()].flatMap((r) => r.unavailable ? [r.unavailable] : [])];
      return {
        query: q.raw,
        scope: req.scope,
        groups,
        ranked,
        top: activeHit(ranked, null),
        unavailable: missing,
        truncated: groups.some((g) => g.truncated),
        pending: jobs.map(([s]) => s).filter((s) => !done.has(s)),
        currentWorkspace: at.currentWorkspace
      };
    };
    if (jobs.length)
      onPartial?.(compose());
    await Promise.all(jobs.map(async ([source, job]) => {
      try {
        done.set(source, await job());
      } catch (e) {
        done.set(source, { hits: [], truncated: false, unavailable: { source, op: "", code: String(e?.code ?? "operation.failed") } });
      }
      if (done.size < jobs.length)
        onPartial?.(compose());
    }));
    return compose();
  }
  var MAX_RECENT = 8;
  var MAX_OPENED = 100;
  function pushRecent(list, query) {
    const q = query.trim();
    if (!q)
      return [...list];
    return [q, ...list.filter((x) => x !== q)].slice(0, MAX_RECENT);
  }
  function markOpened(opened, id, nowMs) {
    const entries = Object.entries({ ...opened, [id]: nowMs }).sort((a, b) => b[1] - a[1]);
    return Object.fromEntries(entries.slice(0, MAX_OPENED));
  }
  var VARIANTS = ["grouped", "preview", "palette"];
  var DEFAULTS = { variant: "grouped", defaultScope: "all", rememberRecent: true, sources: [...SOURCES] };
  var isVariant = (v) => typeof v === "string" && VARIANTS.includes(v);
  function readSettings(raw) {
    const sources = Array.isArray(raw.sources) ? SOURCES.filter((s) => raw.sources.includes(s)) : DEFAULTS.sources;
    return {
      variant: isVariant(raw.variant) ? raw.variant : DEFAULTS.variant,
      defaultScope: raw.defaultScope === "workspace" ? "workspace" : "all",
      rememberRecent: raw.rememberRecent !== false,
      sources: sources.filter(isSourceId)
    };
  }
  var settings = () => readSettings(cmux.app.settings());
  var nextVariant = (v) => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length];
  var [recentSig, setRecent] = signal([]);
  var [openedSig, setOpened] = signal({});
  var [variantSig, setVariant] = signal(null);
  var loaded = null;
  var recent = recentSig;
  var opened = openedSig;
  async function read(key, fallback) {
    try {
      return await cmux.storage.get(key) ?? fallback;
    } catch {
      return fallback;
    }
  }
  var write = (key, value) => cmux.storage.set(key, value).catch(() => {
    return;
  });
  function loadMemory() {
    loaded ??= (async () => {
      const [r, o, v] = await Promise.all([read("recent", []), read("opened", {}), read("variant", null)]);
      setRecent(Array.isArray(r) ? r.filter((x) => typeof x === "string") : []);
      setOpened(o && typeof o === "object" && !Array.isArray(o) ? Object.fromEntries(Object.entries(o).filter(([, v]) => typeof v === "number")) : {});
      setVariant(typeof v === "string" ? v : null);
    })();
    return loaded;
  }
  function rememberSearch(query, enabled) {
    if (!enabled)
      return;
    const next = pushRecent(recentSig(), query);
    setRecent(next);
    write("recent", next);
  }
  function rememberOpened(id, nowMs) {
    const next = markOpened(openedSig(), id, nowMs);
    setOpened(next);
    write("opened", next);
  }
  function clearMemory() {
    setRecent([]);
    setOpened({});
    return Promise.all([cmux.storage.delete("recent"), cmux.storage.delete("opened")]).catch(() => {
      return;
    });
  }
  function storeVariant(variant) {
    setVariant(variant);
    write("variant", variant);
  }
  var currentVariant = () => {
    const o = variantSig();
    return isVariant(o) ? o : settings().variant;
  };
  function toAgentResult(r, limit) {
    return {
      query: r.query,
      scope: r.scope,
      results: r.ranked.slice(0, limit).map((h) => ({
        id: h.id,
        source: h.source,
        kind: h.kind,
        title: h.title,
        location: h.location,
        preview: h.preview ? joinSegments(h.preview) : null,
        match: h.preview ? h.preview.match : h.titleRange ? h.title.slice(h.titleRange.start, h.titleRange.start + h.titleRange.length) : null,
        score: h.score,
        updated_at_ms: h.updatedAtMs,
        workspace: h.workspaceId,
        open: h.target
      })),
      truncated: r.truncated || r.ranked.length > limit,
      unavailable: r.unavailable.map((u) => ({ source: u.source, op: u.op, code: u.code }))
    };
  }
  async function openHit(hit) {
    const t = hit.target;
    switch (t.op) {
      case "workspace.focus":
        await cmux.workspace.focus(t.params);
        return;
      case "tab.focus":
        await cmux.tab.focus(t.params);
        if (t.reveal) {
          await cmux.call("terminal.viewport.reveal", { terminal: t.reveal.terminal, row: t.reveal.row }).catch(() => {
            return;
          });
        }
        return;
      case "action.run":
        await cmux.actions.run(t.params.id, t.params.args);
        return;
    }
  }
  var DEBOUNCE_MS = 150;
  var INVALIDATING = ["workspace.changed", "tab.changed", "terminal.changed", "browser.changed"];
  var surfaces = 0;
  function createController(density, ctx = {}) {
    const surfaceId = `${ctx.contribution ?? "search"}:${++surfaces}`;
    const [query, setQuery] = signal("");
    const [filter, setFilterSig] = signal(null);
    const [scopeOverride, setScopeOverride] = signal(null);
    const [regex, setRegex] = signal(false);
    const [response, setResponse] = signal(emptyResponse("", "all"));
    const [loading, setLoading] = signal(false);
    const [selectedId, setSelectedId] = signal(null);
    const scope = () => scopeOverride() ?? settings().defaultScope;
    let generation = 0;
    let timer = null;
    let lastRun = "";
    loadMemory();
    const key = () => `${query()}\x00${filter()}\x00${scope()}\x00${regex()}`;
    const run = async () => {
      if (timer !== null)
        cmux.timer.clear(timer);
      timer = null;
      const gen = ++generation;
      lastRun = key();
      const parsed = parseQuery(query(), { regex: regex() });
      const effectiveScope = parsed.scope ?? scope();
      if (!parsed.text) {
        setResponse(emptyResponse(parsed.raw, effectiveScope));
        setLoading(false);
        return;
      }
      setLoading(true);
      const accept = (r) => {
        if (gen !== generation)
          return;
        setResponse(r);
        const sel = selectedId();
        if (sel && !r.ranked.some((h) => h.id === sel))
          setSelectedId(null);
      };
      try {
        const final = await runSearch({
          query: parsed,
          sources: effectiveSources(parsed, filter(), settings().sources),
          scope: effectiveScope,
          density,
          limit: 50,
          searchId: surfaceId,
          opened: opened(),
          selfId: cmux.app.id,
          nowMs: Date.now()
        }, (op, params) => cmux.call(op, params), accept);
        accept(final);
      } finally {
        if (gen === generation)
          setLoading(false);
      }
    };
    const schedule = (ms = DEBOUNCE_MS) => {
      if (timer !== null)
        cmux.timer.clear(timer);
      timer = cmux.timer.after(ms, () => void run());
    };
    for (const stream of INVALIDATING)
      cmux.events.on(stream, () => query().trim() && !loading() ? schedule(300) : undefined);
    const open = (hit) => {
      rememberSearch(query(), settings().rememberRecent);
      rememberOpened(hit.id, Date.now());
      openHit(hit).catch((e) => cmux.log("open failed", String(e)));
    };
    return {
      query,
      filter,
      scope,
      effectiveScope: () => parseQuery(query()).scope ?? scope(),
      regex,
      response,
      loading,
      selectedId,
      active: () => activeHit(response().ranked, selectedId()),
      edit(text) {
        setQuery(text);
        setSelectedId(null);
        schedule();
      },
      submit(text) {
        setQuery(text);
        if (key() !== lastRun || loading())
          return void run();
        const hit = activeHit(response().ranked, selectedId());
        if (hit)
          open(hit);
      },
      cancel() {
        setQuery("");
        setSelectedId(null);
        run();
      },
      setFilter(source) {
        setFilterSig(source && isSourceId(source) ? source : null);
        run();
      },
      toggleScope() {
        setScopeOverride(scope() === "all" ? "workspace" : "all");
        run();
      },
      toggleRegex() {
        setRegex(!regex());
        run();
      },
      select(hit) {
        setSelectedId(hit.id);
      },
      open,
      useRecent(q) {
        setQuery(q);
        run();
      }
    };
  }
  function sourceTitle(source) {
    switch (source) {
      case "workspaces":
        return t("source.workspaces", "Workspaces");
      case "terminals":
        return t("source.terminals", "Terminals");
      case "browser":
        return t("source.browser", "Browser");
      case "apps":
        return t("source.apps", "Apps");
      case "files":
        return t("source.files", "Files");
    }
  }
  function SearchField(c, long = false) {
    return TextField(c.query, {
      placeholder: long ? t("field.placeholder.long", "Search workspaces, terminals, pages and files") : t("field.placeholder", "Search"),
      autofocus: long,
      onEdit: (text) => c.edit(text),
      onSubmit: (text) => c.submit(text),
      onCancel: () => c.cancel()
    });
  }
  function Highlighted(segments, options = {}) {
    const style = (v) => {
      let out = v.lineLimit(1);
      if (options.font)
        out = out.font(options.font);
      if (options.monospaced)
        out = out.monospaced();
      return out;
    };
    const plain = (v) => options.secondary ? style(v).secondary() : style(v);
    return HStack({ spacing: 0 }, [
      plain(Text(() => segments().before)).truncation("head"),
      style(Text(() => segments().match)).weight("semibold").color("accent").fixedSize("horizontal"),
      plain(Text(() => segments().after)).truncation("tail").layoutPriority(1)
    ]);
  }
  var titleSegments = (hit) => nameSegments(hit.title, hit.titleRange);
  var previewText = (s) => s ? s.before + s.match + s.after : "";
  var rowSubtitle = (hit) => previewText(hit.preview) || hit.location;
  function Chip(label, selected, onTap, help) {
    const v = Text(label).font("caption").lineLimit(1).fixedSize("horizontal").color(() => selected() ? "primary" : "secondary").paddingHorizontal(7).paddingVertical(3).background(() => selected() ? "selected" : null).hoverBackground("hover").cornerRadius(5).cursor("pointer").onTap(onTap);
    return help ? v.help(help) : v;
  }
  function ScopeChip(c) {
    return Chip(() => c.effectiveScope() === "workspace" ? t("scope.workspace", "This Workspace") : t("scope.all", "Everywhere"), () => c.effectiveScope() === "workspace", () => c.toggleScope());
  }
  function SourceChips(c) {
    return HStack({ spacing: 2 }, [
      Chip(() => t("filter.all", "All"), () => c.filter() === null, () => c.setFilter(null)),
      ...SOURCES.map((s) => Chip(() => sourceTitle(s), () => c.filter() === s, () => c.setFilter(s)))
    ]);
  }
  function RegexChip(c) {
    return Chip(() => t("regex.toggle", ".*"), c.regex, () => c.toggleRegex(), t("regex.help", "Regular expression")).monospaced();
  }
  function RecentSearches(c) {
    return VStack({ spacing: 2 }, [
      () => recent().length ? Text(t("recent.title", "Recent")).font("caption").secondary().paddingHorizontal(8).paddingVertical(2) : null,
      ForEach({ items: recent, key: (q) => q }, (q) => Row({ title: () => q(), symbol: "clock.arrow.circlepath" }).onTap(() => c.useRecent(q())).contextMenu([Button(t("recent.clear", "Clear Recent Searches"), () => clearMemory())]))
    ]);
  }
  function missingCopy(u) {
    const source = sourceTitle(u.source);
    if (u.code === "scope.missing")
      return t("missing.scope", "{source}: access not granted", { source });
    if (u.code === "no.roots")
      return t("missing.files.noRoots", "No folder to search (folders come from terminal working directories)");
    if (u.code !== "operation.unsupported")
      return t("missing.generic", "{source}: cannot search ({code})", { source, code: u.code });
    switch (u.source) {
      case "terminals":
        return t("missing.terminals", "Terminal history needs terminal.search (searched visible screens only)");
      case "browser":
        return t("missing.browser", "Browsing history needs browser.history.search");
      case "files":
        return t("missing.files", "File search needs fs.search");
      case "apps":
        return t("missing.apps", "Other apps' items need search.providers.query");
      case "workspaces":
        return t("missing.workspaces", "Name search needs session.snapshot");
    }
  }
  function MissingFooter(c) {
    return ForEach({ items: () => c.response().unavailable.filter((u) => u.code !== "query.invalid"), key: (u) => `${u.source}:${u.code}` }, (u) => HStack({ spacing: 4 }, [Icon("info.circle").font("caption2").secondary(), Text(() => missingCopy(u())).font("caption2").secondary().lineLimit(2)]).paddingHorizontal(8));
  }
  function Status(c) {
    const r = c.response();
    if (!c.query().trim())
      return recent().length ? null : EmptyState({ title: t("empty.title", "Search Everything"), message: t("empty.message", "t: terminals, f: files, b: browser, w: workspaces, a: apps. /regex/ works too."), symbol: "magnifyingglass" });
    if (r.unavailable.some((u) => u.code === "query.invalid"))
      return EmptyState({ title: t("invalid.title", "Invalid regular expression"), message: r.error ?? "", symbol: "exclamationmark.triangle" });
    if (c.loading() && !r.ranked.length)
      return Text(t("searching", "Searching…")).font("caption").secondary().paddingHorizontal(8);
    if (!c.loading() && !r.ranked.length && r.query === c.query()) {
      return EmptyState({ title: t("none.title", "No Matches"), message: r.scope === "workspace" ? t("none.here", "Nothing here. Try in:all.") : t("none.message", "Nothing matches “{query}”", { query: c.query().trim() }), symbol: "magnifyingglass" });
    }
    return null;
  }
  function moreLabel(shown, total, truncated) {
    return total > shown ? t("more", "{count} more", { count: total - shown }) : truncated ? t("more.unknown", "More results") : "";
  }
  function lines(c) {
    const out = [];
    for (const g of c.response().groups) {
      out.push({ key: `h:${g.source}`, header: { source: g.source, total: g.total } });
      for (const hit of g.hits)
        out.push({ key: hit.id, hit });
      const label = c.filter() === g.source ? "" : moreLabel(g.hits.length, g.total, g.truncated);
      if (label)
        out.push({ key: `m:${g.source}`, more: { source: g.source, label } });
    }
    return out;
  }
  function GroupedView(c) {
    const rows = () => lines(c);
    return VStack({ spacing: 4 }, [
      HStack({ spacing: 6 }, [Icon("magnifyingglass").secondary(), SearchField(c), ScopeChip(c)]).paddingHorizontal(8),
      () => Status(c),
      () => c.query().trim() ? null : RecentSearches(c),
      ForEach({ items: rows, key: (r) => r.key }, (r) => {
        const line = r();
        if (line.header) {
          return HStack({ spacing: 6 }, [Text(() => sourceTitle(r().header.source)).font("caption").secondary(), Spacer(), Text(() => String(r().header.total)).font("caption2").secondary()]).paddingHorizontal(8).paddingVertical(2);
        }
        if (line.more) {
          return Text(() => r().more.label).font("caption").secondary().paddingHorizontal(8).cursor("pointer").onTap(() => c.setFilter(r().more.source));
        }
        return Row({
          title: () => r().hit.title,
          subtitle: () => rowSubtitle(r().hit),
          symbol: () => r().hit.symbol,
          selected: () => c.active()?.id === r().hit.id
        }).help(() => r().hit.location).onTap(() => c.open(r().hit)).contextMenu(() => [Button(t("open", "Open"), () => c.open(r().hit))]);
      }),
      MissingFooter(c)
    ]);
  }
  var mainSegments = (hit) => hit.preview ?? titleSegments(hit);
  var sideText = (hit) => hit.preview ? hit.title : hit.location || sourceTitle(hit.source);
  function PaletteView(c, density) {
    const cap = density === "compact" ? 12 : 30;
    const items = () => c.response().ranked.slice(0, cap);
    return VStack({ spacing: 2 }, [
      HStack({ spacing: 6 }, [Icon("magnifyingglass").secondary(), SearchField(c, density === "full")]).paddingHorizontal(8).paddingVertical(4),
      Divider(),
      () => Status(c),
      () => c.query().trim() ? null : RecentSearches(c),
      ForEach({ items, key: (h) => h.id }, (h) => HStack({ spacing: 8 }, [
        Icon(() => h().symbol).secondary().frame({ width: 16 }),
        Highlighted(() => mainSegments(h()), { monospaced: !!h().preview && h().kind !== "appItem" }).layoutPriority(1),
        Text(() => sideText(h())).font("caption").color("tertiary").lineLimit(1).truncation("middle").frame({ maxWidth: 110 })
      ]).paddingHorizontal(8).paddingVertical(5).background(() => c.active()?.id === h().id ? "selected" : null).hoverBackground("hover").cornerRadius(6).help(() => h().location).onTap(() => c.open(h()))),
      MissingFooter(c),
      () => c.response().ranked.length ? Text(t("hint.palette", "↩ Open  ⎋ Clear")).font("caption2").color("tertiary").paddingHorizontal(8).paddingVertical(4) : null
    ]);
  }
  function PreviewPanel(c) {
    return () => {
      const hit = c.active();
      if (!c.query().trim())
        return null;
      if (!hit)
        return Text(t("preview.none", "Select a result to preview it here")).font("caption").secondary().padding(8);
      return PreviewOf(c, hit);
    };
  }
  function PreviewOf(c, hit) {
    const mono = hit.kind === "terminalText" || hit.kind === "fileContent";
    return VStack({ spacing: 6 }, [
      HStack({ spacing: 6 }, [Icon(hit.symbol).secondary(), Highlighted(() => titleSegments(hit), { font: "headline" })]),
      hit.location ? Text(hit.location).font("caption").secondary().lineLimit(2).truncation("middle") : null,
      hit.preview ? Highlighted(() => hit.preview, { monospaced: mono, font: "callout" }).padding(8).background("hover").cornerRadius(6) : null,
      hit.screenOnly ? Text(t("screenOnly", "Visible screen only")).font("caption2").secondary() : null,
      HStack([Spacer(), Button(t("open", "Open"), () => c.open(hit))])
    ]).padding(8);
  }
  function PreviewView(c, density) {
    const rows = () => lines(c);
    const list = VStack({ spacing: 4 }, [
      () => Status(c),
      () => c.query().trim() ? null : RecentSearches(c),
      ForEach({ items: rows, key: (r) => r.key }, (r) => {
        const line = r();
        if (line.header)
          return Text(() => sourceTitle(r().header.source)).font("caption").secondary().paddingHorizontal(8).paddingVertical(2);
        if (line.more)
          return Text(() => r().more.label).font("caption").secondary().paddingHorizontal(8).cursor("pointer").onTap(() => c.setFilter(r().more.source));
        return Row({ title: () => r().hit.title, subtitle: () => r().hit.location, symbol: () => r().hit.symbol, selected: () => c.active()?.id === r().hit.id }).onTap(() => {
          const hit = r().hit;
          if (c.selectedId() === hit.id)
            c.open(hit);
          else
            c.select(hit);
        });
      }),
      MissingFooter(c),
      density === "full" ? Spacer() : null
    ]);
    return VStack({ spacing: 6 }, [
      SearchField(c, true).paddingHorizontal(6),
      SourceChips(c).paddingHorizontal(4),
      HStack({ spacing: 2 }, [RegexChip(c), ScopeChip(c), Spacer()]).paddingHorizontal(4),
      Divider(),
      density === "full" ? HStack({ spacing: 0 }, [list.frame({ minWidth: 220, maxWidth: 340 }), Divider(), VStack([PreviewPanel(c), Spacer()]).frame({ maxWidth: "infinity" })]) : VStack({ spacing: 6 }, [list, Divider(), PreviewPanel(c)])
    ]);
  }
  var hostLocale = (ctx) => ctx.locale ?? globalThis.navigator?.language ?? "en";
  function render(ctx, density) {
    setLocale(hostLocale(ctx));
    const c = createController(density, ctx);
    return VStack({ spacing: 0 }, [
      () => {
        switch (currentVariant()) {
          case "preview":
            return PreviewView(c, density);
          case "palette":
            return PaletteView(c, density);
          default:
            return GroupedView(c);
        }
      }
    ]);
  }
  function renderSection(ctx = {}) {
    return render(ctx, "compact");
  }
  function renderPane(ctx = {}) {
    return render(ctx, "full");
  }
  async function search(args = {}) {
    await loadMemory();
    const query = parseQuery(String(args.query ?? ""), { regex: args.regex === true });
    const wanted = Array.isArray(args.sources) ? args.sources.filter(isSourceId) : null;
    const sources = effectiveSources(query, null, settings().sources).filter((s) => !wanted || wanted.includes(s));
    const limit = Math.max(1, Math.min(200, Math.floor(Number(args.limit ?? 20)) || 20));
    const scope = query.scope ?? args.scope ?? settings().defaultScope;
    const response = await runSearch({ query, sources, scope, density: "full", limit, searchId: "command", opened: opened(), selfId: cmux.app.id, nowMs: Date.now() }, (op, params) => cmux.call(op, params));
    return toAgentResult(response, limit);
  }
  async function cycleVariant() {
    await loadMemory();
    const next = nextVariant(currentVariant());
    storeVariant(next);
    return { variant: next };
  }
  async function clearRecent() {
    await clearMemory();
    return { cleared: true };
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
