// cmux browser REPL site tools: the `sites` global
// (plans/cmux-next/browser-repl/site-tools.md). Each file in sites/ registers one tool
// with register(name, factory); createSites builds them for a REPL session.
//
// Rules every tool follows:
// - It runs through the user's signed-in cmux browser session: the REPL
//   `fetch` (cookie-bearing), or a background tab of the same profile where
//   the call runs in the page's own world, same-origin. A token a site keeps
//   in the page stays in the page; no tool returns a credential.
// - Reads run directly. A write that reaches other people returns a draft;
//   only `tool.method(draftId, { confirm: true })` performs it.
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});
  const registry = [];
  const shared = {};

  function register(name, factory, meta = {}) {
    const at = registry.findIndex((r) => r.name === name);
    const entry = { name, factory, summary: meta.summary || "" };
    if (at >= 0) registry[at] = entry;
    else registry.push(entry);
  }

  class SiteError extends Error {
    constructor(code, message) {
      super(message);
      this.name = "SiteError";
      this.code = code;
    }
  }

  // Page-side Markdown for one element (a subset of api.pageMarkdown that
  // takes a root). Kept as source so tools can compose page functions with it.
  const ELEMENT_MARKDOWN = `function elementMarkdown(rootEl) {
    if (!rootEl) return "";
    const skip = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS", "IFRAME", "BUTTON"]);
    const clean = (t) => t.replace(/\\s+/g, " ");
    const hidden = (el) => { const cs = getComputedStyle(el); return cs.display === "none" || cs.visibility === "hidden"; };
    const inline = (node) => {
      if (node.nodeType === 3) return clean(node.textContent);
      if (node.nodeType !== 1 || skip.has(node.tagName) || hidden(node)) return "";
      const inner = [...node.childNodes].map(inline).join("");
      const t = inner.trim();
      if (node.tagName === "A" && node.getAttribute("href")) return t ? "[" + t + "](" + node.href + ")" : "";
      if (node.tagName === "B" || node.tagName === "STRONG") return t ? "**" + t + "**" : "";
      if (node.tagName === "EM" || node.tagName === "I") return t ? "*" + t + "*" : "";
      if (node.tagName === "CODE") return "\`" + inner + "\`";
      if (node.tagName === "IMG") return node.alt ? "![" + node.alt + "](" + node.src + ")" : "";
      if (node.tagName === "BR") return "\\n";
      return inner;
    };
    const out = [];
    const BLOCK = /^(DIV|P|H[1-6]|UL|OL|TABLE|SECTION|ARTICLE|MAIN|NAV|HEADER|FOOTER|ASIDE|FORM|PRE|BLOCKQUOTE|DETAILS|FIELDSET|FIGURE|LI)$/;
    const block = (node, depth) => {
      if (node.nodeType === 3) { const t = clean(node.textContent).trim(); if (t) out.push(t); return; }
      if (node.nodeType !== 1 || skip.has(node.tagName) || hidden(node)) return;
      const tag = node.tagName;
      const m = /^H([1-6])$/.exec(tag);
      if (m) return void out.push("#".repeat(Number(m[1])) + " " + inline(node).trim());
      if (tag === "P") { const t = inline(node).trim(); if (t) out.push(t); return; }
      if (tag === "PRE") return void out.push("\`\`\`\\n" + node.innerText + "\\n\`\`\`");
      if (tag === "UL" || tag === "OL") {
        let n = 0;
        for (const li of node.children) if (li.tagName === "LI") out.push("  ".repeat(depth) + (tag === "OL" ? (++n) + "." : "-") + " " + inline(li).trim());
        return;
      }
      if (tag === "TABLE") {
        const rows = [...node.rows].map((r) => "| " + [...r.cells].map((c) => inline(c).trim().replace(/\\|/g, "\\\\|")).join(" | ") + " |");
        if (rows.length) out.push([rows[0], "| " + [...node.rows[0].cells].map(() => "---").join(" | ") + " |", ...rows.slice(1)].join("\\n"));
        return;
      }
      if (tag === "BLOCKQUOTE") return void out.push("> " + inline(node).trim());
      if (![...node.children].some((c) => BLOCK.test(c.tagName))) { const t = inline(node).trim(); if (t) out.push(t); return; }
      for (const c of node.childNodes) block(c, depth);
    };
    block(rootEl, 0);
    return out.filter(Boolean).join("\\n\\n");
  }`;

  // A page function built from source parts. Its toString() is its source,
  // so page.evaluate runs it in the page's world (under the page's CSP, which
  // does not apply to the evaluation itself).
  function pageFunction(body, ...helpers) {
    // eslint-disable-next-line no-new-func
    return new Function("arg", `${helpers.join("\n")}\nreturn (async () => {\n${body}\n})();`);
  }

  // A JavaScript string literal starting at html[i] (quote included), decoded.
  function stringLiteral(html, i) {
    const quote = html[i];
    let out = "";
    for (let j = i + 1; j < html.length; j++) {
      const c = html[j];
      if (c === quote) return out;
      if (c !== "\\") {
        out += c;
        continue;
      }
      const n = html[++j];
      if (n === "x") (out += String.fromCharCode(parseInt(html.substr(j + 1, 2), 16))), (j += 2);
      else if (n === "u") (out += String.fromCharCode(parseInt(html.substr(j + 1, 4), 16))), (j += 4);
      else out += { n: "\n", r: "\r", t: "\t", b: "\b", f: "\f", v: "\v", 0: "\0" }[n] !== undefined ? { n: "\n", r: "\r", t: "\t", b: "\b", f: "\f", v: "\v", 0: "\0" }[n] : n;
    }
    return null;
  }

  // The value of `name = {...}`, `name({...})` or `name = '<escaped JSON>'`
  // (YouTube's mobile pages) embedded in an HTML page, as JSON.
  function embeddedJSON(html, marker) {
    let at = html.indexOf(marker);
    while (at >= 0) {
      const lead = /^\s*(['"])/.exec(html.slice(at + marker.length, at + marker.length + 8));
      if (lead) {
        const text = stringLiteral(html, at + marker.length + lead[0].length - 1);
        try {
          return JSON.parse(text);
        } catch {}
        at = html.indexOf(marker, at + marker.length);
        continue;
      }
      const start = html.indexOf("{", at + marker.length);
      if (start < 0) return null;
      let depth = 0;
      let inString = false;
      for (let i = start; i < html.length; i++) {
        const c = html[i];
        if (inString) {
          if (c === "\\") i++;
          else if (c === '"') inString = false;
          continue;
        }
        if (c === '"') inString = true;
        else if (c === "{") depth++;
        else if (c === "}" && --depth === 0) {
          try {
            return JSON.parse(html.slice(start, i + 1));
          } catch {
            break;
          }
        }
      }
      at = html.indexOf(marker, at + marker.length);
    }
    return null;
  }

  const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", "#39": "'" };
  function decodeEntities(s) {
    return String(s).replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (m, e) => {
      if (e[0] === "#") return String.fromCodePoint(e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10));
      return ENTITIES[e.toLowerCase()] !== undefined ? ENTITIES[e.toLowerCase()] : m;
    });
  }

  // RFC 4180 CSV to rows of strings.
  function parseCSV(text, sep = ",") {
    const rows = [];
    let row = [];
    let field = "";
    let quoted = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (quoted) {
        if (c === '"' && text[i + 1] === '"') {
          field += '"';
          i++;
        } else if (c === '"') quoted = false;
        else field += c;
      } else if (c === '"' && field === "") quoted = true;
      else if (c === sep) {
        row.push(field);
        field = "";
      } else if (c === "\n" || c === "\r") {
        if (c === "\r" && text[i + 1] === "\n") i++;
        row.push(field);
        rows.push(row);
        row = [];
        field = "";
      } else field += c;
    }
    if (field !== "" || row.length) {
      row.push(field);
      rows.push(row);
    }
    return rows;
  }

  // "B2:D10" -> { c0, r0, c1, r1 } (0-based, inclusive); open ends allowed ("A:C", "3:9").
  function parseA1Range(range) {
    const m = /^([A-Z]*)(\d*)(?::([A-Z]*)(\d*))?$/i.exec(String(range).trim());
    if (!m) throw new SiteError("invalid", `range: expected A1 notation such as "A1:C10", got ${JSON.stringify(range)}`);
    const col = (s) => (s ? [...s.toUpperCase()].reduce((n, ch) => n * 26 + ch.charCodeAt(0) - 64, 0) - 1 : null);
    const row = (s) => (s ? Number(s) - 1 : null);
    const c0 = col(m[1]);
    const r0 = row(m[2]);
    const two = m[3] !== undefined || m[4] !== undefined;
    return { c0: c0 === null ? 0 : c0, r0: r0 === null ? 0 : r0, c1: two ? col(m[3]) : c0, r1: two ? row(m[4]) : r0 };
  }

  const DRAFT_TTL_MS = 30 * 60 * 1000;

  // A private deep copy of plain data, so a write keeps no object its caller
  // can still change. Each own enumerable property is read once (a getter or
  // Proxy cannot answer differently later); arrays and plain objects from
  // any realm are copied, a Date becomes a new Date, an object with toJSON
  // (URL) its JSON value. Functions, symbols, cycles and other objects are
  // refused.
  function copyInput(value, name = "input", seen = []) {
    if (typeof value === "function" || typeof value === "symbol") throw new SiteError("invalid", `${name}: expected plain data, got a ${typeof value}`);
    if (value === null || typeof value !== "object") return value;
    const tag = Object.prototype.toString.call(value);
    if (tag === "[object Date]") return new Date(value.getTime());
    if (seen.includes(value)) throw new SiteError("invalid", `${name}: expected plain data, got a cycle`);
    if (Array.isArray(value)) {
      const out = [];
      const n = value.length;
      seen.push(value);
      for (let i = 0; i < n; i++) out.push(copyInput(value[i], `${name}[${i}]`, seen));
      seen.pop();
      return out;
    }
    const proto = Object.getPrototypeOf(value);
    if (tag !== "[object Object]" || (proto !== null && Object.getPrototypeOf(proto) !== null)) {
      if (typeof value.toJSON === "function") return copyInput(value.toJSON(), name, seen);
      throw new SiteError("invalid", `${name}: expected plain data, got ${tag}`);
    }
    const out = {};
    seen.push(value);
    for (const key of Object.keys(value)) out[key] = copyInput(value[key], `${name}.${key}`, seen);
    seen.pop();
    return out;
  }

  function deepFreeze(value) {
    if (value && typeof value === "object" && !Object.isFrozen(value)) {
      Object.freeze(value);
      for (const key of Object.keys(value)) deepFreeze(value[key]);
    }
    return value;
  }

  // Drafts live in the REPL session that made them, so a draft can be
  // confirmed only by the session the user saw it in (use --session NAME).
  // A draft's record (status, expiry, preview) stays here; the agent gets
  // frozen views of it. The preview is a frozen JSON copy whose canonical
  // text is kept: confirming runs the draft with that same preview, after
  // checking the text still matches, so the action is the one shown.
  function createDrafts(host) {
    const drafts = new Map();
    let n = 0;
    const now = () => (host.now ? host.now() : Date.now());
    const rand = () => Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, "0");
    const view = (e) =>
      Object.freeze({
        id: e.id,
        site: e.site,
        action: e.action,
        status: e.status,
        summary: e.summary,
        category: e.category,
        preview: e.preview,
        expiresAt: new Date(e.expiresAt).toISOString(),
        confirm: `await sites.${e.site}.${e.action}(${JSON.stringify(e.id)}, { confirm: true })`,
      });
    return {
      create({ site, action, category, summary, preview, run }) {
        let canonical;
        try {
          canonical = JSON.stringify(preview === undefined ? null : preview);
        } catch (e) {
          throw new SiteError("invalid", `sites.${site}.${action}: the draft preview is not JSON data (${(e && e.message) || e})`);
        }
        const id = `draft-${++n}-${rand()}`;
        const entry = { id, site, action, status: "draft", summary: String(summary), category: String(category), preview: deepFreeze(JSON.parse(canonical)), canonical, expiresAt: now() + DRAFT_TTL_MS, run };
        drafts.set(id, entry);
        return view(entry);
      },
      async run(id, site, action) {
        const entry = drafts.get(id);
        if (!entry) throw new SiteError("draft_not_found", `sites.${site}.${action}: no draft ${JSON.stringify(id)} in this REPL session. Drafts live in the session that made them; run both calls in one named session (cmux browser repl --session NAME).`);
        if (entry.site !== site || entry.action !== action) throw new SiteError("draft_mismatch", `sites.${site}.${action}: draft ${id} is a sites.${entry.site}.${entry.action} draft`);
        if (entry.status !== "draft") throw new SiteError("draft_used", `sites.${site}.${action}: draft ${id} is ${entry.status}; make a new draft`);
        if (now() > entry.expiresAt) {
          entry.status = "expired";
          throw new SiteError("draft_expired", `sites.${site}.${action}: draft ${id} expired; make a new draft and show it to the user again`);
        }
        if (JSON.stringify(entry.preview) !== entry.canonical) {
          entry.status = "failed";
          throw new SiteError("draft_changed", `sites.${site}.${action}: draft ${id} no longer matches its preview; nothing was sent. Make a new draft and show it to the user again`);
        }
        entry.status = "sending";
        try {
          const result = await entry.run(entry.preview);
          entry.status = "sent";
          return result;
        } catch (e) {
          // A failed send may have reached the site; never retry it blindly.
          entry.status = "failed";
          throw e;
        }
      },
      list: () => [...drafts.values()].map(view),
      get: (id) => (drafts.has(id) ? view(drafts.get(id)) : null),
      discard(id) {
        const entry = drafts.get(id);
        if (entry && entry.status === "draft") entry.status = "discarded";
        return !!entry;
      },
    };
  }

  function createSites(ctx) {
    const { session, host, fs, path } = ctx;
    const drafts = createDrafts(host);
    let files = 0;

    const tool = {
      SiteError,
      shared,
      ELEMENT_MARKDOWN,
      pageFunction,
      embeddedJSON,
      decodeEntities,
      parseCSV,
      parseA1Range,
      URL: ctx.URL,
      Buffer: ctx.Buffer,
      fs,
      path,
      host,
      session,
      fetch: ctx.fetch,
      currentPage: ctx.currentPage,
      snapshot: ctx.snapshot,
      sleep: (ms) => session.sleep(ms),
      now: () => session.now(),
      fail(code, message) {
        throw new SiteError(code, message);
      },
      // A file path for tool output: options.path, else the session's temp directory.
      outputPath(options, ext, base = "site") {
        if (options && options.path) return path.resolve(String(options.path));
        const dir = path.join(host.tmpdir, "cmux-browser-repl", String(host.sessionId || "session").replace(/[^\w.-]/g, "_"));
        fs.mkdirSync(dir, { recursive: true });
        const safe = String(base).replace(/[^\w.-]+/g, "_").slice(0, 80) || "site";
        return path.join(dir, `${safe}-${++files}${ext}`);
      },
      outputDir(options, base) {
        const dir = options && options.dir ? path.resolve(String(options.dir)) : path.join(host.tmpdir, "cmux-browser-repl", String(host.sessionId || "session").replace(/[^\w.-]/g, "_"), `${base}-${++files}`);
        fs.mkdirSync(dir, { recursive: true });
        return dir;
      },
      // GET through the signed-in session (cookie-bearing REPL fetch);
      // throws on HTTP errors with the tool's name.
      async get(name, url, init = {}) {
        const r = await ctx.fetch(url, init);
        if (!r.ok) throw new SiteError(r.status === 401 || r.status === 403 ? "not_signed_in" : "http", `${name}: HTTP ${r.status} for ${url}`);
        return r;
      },
      // Runs fn(page) in a background tab loaded at url, then closes the tab.
      // The current tab does not change.
      async withTab(url, fn, options = {}) {
        const page = await session.newPage(undefined, { background: true });
        try {
          await page.goto(url, { waitUntil: options.waitUntil || "load", timeout: options.timeout || 45000 });
          return await fn(page);
        } finally {
          await page.close().catch(() => {});
        }
      },
      // Runs page function fn(arg) in the world of a background tab at
      // origin + path (default /robots.txt, a same-origin document with no
      // scripts): same-origin fetches there send the site's cookies, and
      // whatever the function reads from the page stays there unless it
      // returns it. Functions must return only non-secret data.
      async inOrigin(origin, fn, arg, options = {}) {
        return tool.withOrigin(origin, (run) => run(fn, arg), options);
      },
      // Like inOrigin for several calls on one tab: body(run) where
      // run(fn, arg) evaluates in the page.
      async withOrigin(origin, body, options = {}) {
        return tool.withTab(origin.replace(/\/$/, "") + (options.path || "/robots.txt"), (page) => body((fn, arg) => page.evaluate(fn, arg)), options);
      },
      // Waits in `page` until fn(arg) returns a truthy value; returns it.
      // With { signIn: [patterns], name }, a tab that reaches a sign-in page
      // at any point (sites also redirect from script) fails as not_signed_in.
      async waitIn(page, fn, arg, { timeout = 20000, what = "the page", signIn, name = "sites" } = {}) {
        const deadline = session.now() + timeout;
        for (;;) {
          if (signIn) tool.assertSignedIn(name, page, signIn);
          let v = null;
          try {
            v = await page.evaluate(fn, arg);
          } catch (e) {
            // A navigation replaced the document; try again on the new one.
            if (!/stale|navigat|context|detached|destroyed/i.test(String(e && e.message))) throw e;
          }
          if (v) return v;
          if (session.now() >= deadline) {
            if (signIn) tool.assertSignedIn(name, page, signIn);
            throw new SiteError("timeout", `${name}: timed out after ${timeout}ms waiting for ${what} (${page.url()})`);
          }
          await session.sleep(150);
        }
      },
      // Throws not_signed_in when a tab landed on a sign-in page.
      assertSignedIn(name, page, patterns) {
        const url = page.url();
        if (patterns.some((p) => p.test(url))) throw new SiteError("not_signed_in", `${name}: the cmux browser is not signed in (landed on ${url.split("?")[0]}). Open the site with tabs.open(url) and ask the user to sign in, or use sites.browserAuth.request().`);
      },
      // A private deep copy of plain data (see copyInput).
      copyInput,
      // A write that reaches other people: the first call returns a draft; a
      // second call with the draft id and { confirm: true } performs it.
      // make() receives a private copy of input, so what it captures for
      // run() cannot be changed by the caller afterwards; run() receives the
      // frozen preview.
      write(site, action, input, options, make) {
        const isDraftId = typeof input === "string" && /^draft-\d+-[0-9a-f]+$/.test(input);
        if (isDraftId) {
          if (!options || options.confirm !== true) throw new SiteError("confirm_required", `sites.${site}.${action}: pass { confirm: true } to perform draft ${input}, after the user has seen its preview`);
          return drafts.run(input, site, action);
        }
        if (options && options.confirm) throw new SiteError("draft_required", `sites.${site}.${action}: { confirm: true } takes a draft id. Call sites.${site}.${action}(input) first, show the returned draft to the user, then confirm it.`);
        const spec = make(copyInput(input, `sites.${site}.${action}`));
        return drafts.create({ site, action, category: spec.category, summary: spec.summary, preview: spec.preview, run: spec.run });
      },
    };

    const sites = {};
    const failed = {};
    for (const { name, factory } of registry) {
      try {
        sites[name] = factory(tool);
      } catch (e) {
        failed[name] = String((e && e.message) || e);
      }
    }
    Object.defineProperties(sites, {
      drafts: {
        value: { list: () => drafts.list(), get: (id) => drafts.get(id), discard: (id) => drafts.discard(id) },
        enumerable: false,
      },
      // One line per tool; sites.help(name) for its methods.
      list: {
        value: () => registry.map((r) => ({ name: r.name, summary: r.summary, ...(failed[r.name] ? { error: failed[r.name] } : {}) })),
        enumerable: false,
      },
      help: {
        value: (name) => {
          const t = name ? sites[name] : null;
          if (name && !t) throw new SiteError("invalid", `sites.help: no tool ${JSON.stringify(name)}; see sites.list()`);
          if (t) return Object.keys(t).filter((k) => typeof t[k] === "function").map((k) => `sites.${name}.${k}`).join("\n");
          return registry.map((r) => `sites.${r.name}: ${r.summary}`).join("\n");
        },
        enumerable: false,
      },
    });
    return sites;
  }

  ns.sites = { register, createSites, shared, SiteError, copyInput, embeddedJSON, decodeEntities, parseCSV, parseA1Range, pageFunction, ELEMENT_MARKDOWN };
})(typeof globalThis !== "undefined" ? globalThis : this);
