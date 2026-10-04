// Oracle backend: runs scenarios on real Playwright (headless Google Chrome,
// throwaway profile) with a thin shim of the cmux REPL globals, so behavior
// values (page effects, event trust, Playwright return values) come from
// Playwright itself. The shim reuses the REPL's cell rewriting so top-level
// bindings persist across cells of a named session.
//
// snapshot() returns Playwright's AI snapshot so scenarios can pick refs with
// the same regular expressions; its text is never compared (snapshot text is
// cmux-owned). APIs with no Playwright counterpart (elementAt, clipboard)
// throw here; scenarios that need them are marked `oracle: skip`.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { loadRuntime, loadPlaywright } from "./dev-driver.mjs";

const REF = /^(f\d+)?e\d+$/;

export async function runOracleCells(cells) {
  const ns = loadRuntime();
  const { chromium } = loadPlaywright();
  const work = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "parity-oracle-")));
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const context = await browser.newContext({ acceptDownloads: true, viewport: { width: 1280, height: 800 } });
  const ids = new WeakMap();
  let nextId = 1;
  const idOf = (p) => {
    if (!ids.has(p)) ids.set(p, String(nextId++).padStart(32, "0"));
    return ids.get(p);
  };
  const kept = new WeakSet();

  // Adds the cmux Page members to a Playwright page.
  const prepare = (p) => {
    if (p.__cmux) return p;
    p.__cmux = true;
    idOf(p);
    const locator = p.locator.bind(p);
    p.locator = (sel, o) => locator(typeof sel === "string" && REF.test(sel.trim()) ? `aria-ref=${sel.trim()}` : sel, o);
    p.ref = (ref) => p.locator(ref);
    Object.defineProperty(p, "id", { get: () => idOf(p) });
    let dialog = null;
    let chooser = null;
    p.on("dialog", (d) => {
      if (p.listenerCount("dialog") === 1) dialog = d;
    });
    p.on("filechooser", (c) => {
      if (p.listenerCount("filechooser") === 1) chooser = c;
    });
    p.dialog = () => {
      if (!dialog) return null;
      const d = dialog;
      const done = () => (dialog = null);
      return {
        type: d.type(),
        message: d.message(),
        defaultValue: d.defaultValue(),
        accept: (t) => (done(), d.accept(t)),
        dismiss: () => (done(), d.dismiss()),
      };
    };
    p.fileChooser = () => {
      if (!chooser) return null;
      const c = chooser;
      return {
        multiple: c.isMultiple(),
        setFiles: (f) => ((chooser = null), c.setFiles(f)),
        cancel: async () => {
          chooser = null;
        },
      };
    };
    const consoleMessages = p.consoleMessages.bind(p);
    p.consoleMessages = async (o = {}) => {
      let list = await consoleMessages();
      if (o.level) {
        const levels = [].concat(o.level).map((l) => (l === "warn" ? "warning" : l));
        list = list.filter((m) => levels.includes(m.type()));
      }
      if (o.filter !== undefined) list = list.filter((m) => (o.filter instanceof RegExp ? o.filter.test(m.text()) : m.text().includes(String(o.filter))));
      if (o.limit) list = list.slice(-o.limit);
      return list;
    };
    p.errors = () => p.pageErrors();
    p.keep = async () => kept.add(p);
    return p;
  };
  context.on("page", prepare);

  function createSession() {
    const s = { print: () => {}, current: null, opened: new Set() };
    const print = (level, text) => s.print(level, text);
    const inspect = ns.api.inspect;
    const show = (v) => {
      if (v === undefined) return;
      print("log", v && v.__image ? `[Image ${v.width}x${v.height} ${v.type}]` : inspect(v));
    };
    const newPage = async () => {
      const p = prepare(await context.newPage());
      s.opened.add(p);
      return p;
    };
    const pageById = async (id) => {
      if (id && typeof id === "object") return id;
      const p = context.pages().find((x) => idOf(x) === String(id));
      if (!p) throw new Error(`No open tab with id ${JSON.stringify(String(id))}; see tabs.list()`);
      return p;
    };
    const image = (buffer) => {
      const size = ns.api.imageSize(buffer);
      return { __image: true, buffer, type: size.type, width: size.width, height: size.height, base64: buffer.toString("base64") };
    };
    const snapshotOf = async (target) => {
      const page = target && typeof target === "object" && target.mainFrame ? target : s.current;
      const r = await page._snapshotForAI({ track: "oracle" });
      const tree = typeof r === "string" ? r : r.full;
      return { tree, diff: typeof r === "string" ? tree : r.incremental ?? tree, usesDiff: false, toString: () => tree };
    };
    const globals = {
      tabs: {
        list: async () => Promise.all(context.pages().map(async (p) => ({ id: idOf(p), title: await p.title(), url: p.url(), active: p === s.current, current: p === s.current, state: "live" }))),
        async open(url, o = {}) {
          const p = await newPage();
          if (url) await p.goto(url);
          if (!o.background) s.current = p;
          return p;
        },
        current: () => s.current,
        use: async (t) => (s.current = await pageById(t)),
        get: (id) => pageById(id),
      },
      snapshot: (target) => snapshotOf(target),
      async screenshot(target, o) {
        if (target && typeof target === "object" && !target.mainFrame && !target.click) (o = target), (target = undefined);
        o = o || {};
        const shot = { type: o.type, fullPage: o.fullPage };
        const buf = typeof target === "string" ? await s.current.locator(target).screenshot(shot) : target && target.click ? await target.screenshot(shot) : await s.current.screenshot(shot);
        if (o.path) fs.writeFileSync(o.path, buf);
        return image(buf);
      },
      fetch: async (url, init = {}) => {
        const r = await context.request.fetch(new URL(url, s.current && /^http/.test(s.current.url()) ? s.current.url() : undefined).href, { method: init.method, headers: init.headers, data: init.body });
        const headers = r.headers();
        return {
          ok: r.ok(),
          status: r.status(),
          url: r.url(),
          headers: { get: (k) => headers[String(k).toLowerCase()] ?? null, has: (k) => String(k).toLowerCase() in headers },
          json: () => r.json(),
          text: () => r.text(),
        };
      },
      fs,
      path,
      os,
      Buffer,
      require: (name) => ({ fs, path, os, "fs/promises": fs.promises, buffer: { Buffer } })[String(name).replace(/^node:/, "")],
      sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
      display: (v) => show(v),
      session: { name: async () => {}, keep: (p) => kept.add(p || s.current) },
      console: Object.fromEntries(["log", "info", "warn", "error", "debug"].map((m) => [m, (...a) => print(m, a.map((x) => inspect(x)).join(" "))])),
      setTimeout,
      clearTimeout,
      __cmuxImport: async (spec) => {
        const mod = await import(String(spec).startsWith("node:") ? spec : `node:${spec}`);
        return mod;
      },
    };
    Object.defineProperty(globals, "page", { get: () => s.current, set: (v) => (s.current = v), enumerable: true, configurable: true });
    s.repl = ns.replHost.createReplSession({ host: { now: Date.now }, globals: [globals] });
    s.show = show;
    s.newPage = newPage;
    return s;
  }

  const named = new Map();
  const outputs = [];
  const prevCwd = process.cwd();
  process.chdir(work);
  try {
    for (const cell of cells) {
      const lines = [];
      let s = cell.session ? named.get(cell.session) : null;
      if (!s) {
        s = createSession();
        if (cell.session) named.set(cell.session, s);
      }
      s.print = (level, text) => lines.push(text);
      if (!s.current || s.current.isClosed()) s.current = await s.newPage();
      const r = await s.repl.evaluate(cell.code);
      if (r.ok) s.show(r.value);
      if (!cell.session) {
        for (const p of s.opened) if (!kept.has(p)) await p.close().catch(() => {});
      }
      outputs.push({ output: lines.join("\n"), error: r.ok ? null : r.error });
    }
  } finally {
    process.chdir(prevCwd);
    await browser.close();
    fs.rmSync(work, { recursive: true, force: true });
  }
  return outputs;
}
