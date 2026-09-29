// `dev` browser driver: implements docs/browser-repl/driver-protocol.md on
// Playwright WebKit so the engine-neutral runtime in Resources/browser-repl can
// be developed and checked without an app build.
//
// Playwright cannot choose a content world on WebKit, so the "agent" world is
// the main world and the page agent lives under a non-enumerable symbol.
// Input goes through page.mouse / page.keyboard, which WebKit delivers as
// trusted events.
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import crypto from "node:crypto";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
export const runtimeDir = path.join(repoRoot, "Resources/browser-repl");

const AGENT_KEY = 'Symbol.for("cmux.browserRepl.agent")';
const NEEDS_AGENT = "__cmuxNeedsAgent__";
const ERROR_KEY = "__cmuxError__";

function loadPlaywright() {
  process.env.PLAYWRIGHT_BROWSERS_PATH ??= path.join(process.env.HOME, ".cache/cmux-parity-browsers");
  const dirs = [process.env.PARITY_PLAYWRIGHT_DIR, "/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules"].filter(Boolean);
  for (const d of dirs) {
    try {
      return require(path.join(d, "playwright"));
    } catch {}
  }
  return require("playwright");
}

// Builds the install script from the recipe in page-agent.js.
export function agentInstallSource() {
  const injected = fs.readFileSync(path.join(runtimeDir, "vendor/playwright-injected.js"), "utf8");
  const agent = fs.readFileSync(path.join(runtimeDir, "page-agent.js"), "utf8");
  return `(() => {\nconst module = {};\n${injected}\n;const __cmuxInjectedScriptFactory = module.exports.InjectedScript;\n${agent}\n})()`;
}

class DriverError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const hexId = () => crypto.randomBytes(16).toString("hex").toUpperCase();

function pngSize(buf) {
  if (buf.length > 24 && buf.toString("ascii", 1, 4) === "PNG") return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
  return { width: 0, height: 0 };
}

// Playwright WebKit cannot print. A one-page PDF that carries the page text
// keeps page.pdf() usable in dev runs; the app driver uses WKWebView.createPDF.
function textPdf(text) {
  const lines = text.split("\n").map((l) => l.trim()).filter(Boolean).slice(0, 60);
  const esc = (s) => s.replace(/[\\()]/g, (c) => "\\" + c).replace(/[^\x20-\x7e]/g, "?");
  const stream = ["BT", "/F1 11 Tf", "50 800 Td", "14 TL", ...lines.map((l) => `(${esc(l)}) '`), "ET"].join("\n");
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    `<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}\nendstream`,
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  ];
  let out = "%PDF-1.4\n";
  const offsets = [];
  objects.forEach((o, i) => {
    offsets.push(Buffer.byteLength(out));
    out += `${i + 1} 0 obj\n${o}\nendobj\n`;
  });
  const xref = Buffer.byteLength(out);
  out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n` + offsets.map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("");
  out += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(out);
}

export async function createDevDriver({ headless = true, viewport = { width: 1280, height: 800 } } = {}) {
  const { webkit } = loadPlaywright();
  const installSource = agentInstallSource();
  const browser = await webkit.launch({ headless });
  const context = await browser.newContext({ viewport, acceptDownloads: true });
  const listeners = new Map();
  const tabs = new Map(); // targetId -> tab record
  const tabOf = new WeakMap(); // page -> tab record
  const dialogs = new Map();
  const choosers = new Map();
  const downloads = new Map();
  let activeTarget = null;
  let nextId = 1;
  const modifiersDown = new Set();

  const emit = (event, payload) => {
    for (const h of listeners.get(event) ?? []) {
      try {
        h(payload);
      } catch (e) {
        console.error(`driver listener for ${event} failed:`, e);
      }
    }
  };

  function frameId(tab, frame) {
    let id = tab.frameIds.get(frame);
    if (!id) {
      id = frame === tab.page.mainFrame() ? `${tab.targetId}:main` : `${tab.targetId}:f${nextId++}`;
      tab.frameIds.set(frame, id);
      tab.frames.set(id, frame);
    }
    return id;
  }

  function register(page) {
    if (tabOf.has(page)) return tabOf.get(page);
    const tab = { targetId: hexId(), page, frameIds: new WeakMap(), frames: new Map(), clipboard: [], openerTargetId: undefined, openDialogs: 0, title: "", loadState: "commit" };
    tabs.set(tab.targetId, tab);
    tabOf.set(page, tab);
    frameId(tab, page.mainFrame());
    const targetId = tab.targetId;
    page.on("console", (m) => emit("console", { targetId, type: m.type(), text: m.text(), location: m.location() }));
    page.on("pageerror", (e) => {
      // WebKit reports unhandled rejections as "Error: <message>"; Chromium
      // and the protocol carry the bare message.
      let message = e.message;
      if (e.name === "Unhandled Promise Rejection") message = message.replace(/^[A-Za-z]*Error: /, "");
      emit("pageerror", { targetId, message, stack: e.stack ?? "" });
    });
    page.on("dialog", (d) => {
      const dialogId = `d${nextId++}`;
      dialogs.set(dialogId, d);
      tab.openDialogs++;
      emit("dialog.opened", { targetId, dialogId, type: d.type(), message: d.message(), defaultValue: d.defaultValue() });
    });
    page.on("filechooser", async (c) => {
      const chooserId = `c${nextId++}`;
      choosers.set(chooserId, c);
      const frame = c.element().ownerFrame ? await c.element().ownerFrame() : page.mainFrame();
      await ensureAgent(frame);
      const element = await c.element().evaluate((el, key) => globalThis[Symbol.for(key)].handleFor(el), "cmux.browserRepl.agent");
      emit("filechooser.opened", { targetId, chooserId, frameId: frameId(tab, frame), element, multiple: c.isMultiple() });
    });
    page.on("download", (d) => {
      const downloadId = `dl${nextId++}`;
      downloads.set(downloadId, d);
      emit("download.started", { targetId, downloadId, url: d.url(), suggestedFilename: d.suggestedFilename() });
      d.path().then(
        (p) => emit("download.finished", { targetId, downloadId, path: p }),
        (e) => emit("download.finished", { targetId, downloadId, error: String(e.message) }),
      );
    });
    const net = (event) => (r) => {
      const req = r.request ? r.request() : r;
      emit(event, {
        targetId,
        requestId: req._guid ?? req.url(),
        url: req.url(),
        method: req.method(),
        resourceType: req.resourceType(),
        status: r.status ? r.status() : undefined,
        headers: r.headers ? r.headers() : undefined,
      });
    };
    page.on("request", net("request"));
    page.on("response", net("response"));
    page.on("requestfailed", net("requestfailed"));
    page.on("requestfinished", net("requestfinished"));
    page.on("domcontentloaded", () => emit("tab.loadState", { targetId, state: "domcontentloaded" }));
    page.on("load", () => emit("tab.loadState", { targetId, state: "load" }));
    page.on("framenavigated", (f) => emit("tab.navigated", { targetId, frameId: frameId(tab, f), url: f.url() }));
    page.on("close", () => {
      tabs.delete(targetId);
      if (activeTarget === targetId) activeTarget = [...tabs.keys()].at(-1) ?? null;
      emit("tab.closed", { targetId });
    });
    return tab;
  }

  context.on("page", async (page) => {
    const tab = register(page);
    const opener = await page.opener().catch(() => null);
    if (opener && tabOf.has(opener)) tab.openerTargetId = tabOf.get(opener).targetId;
    if (tab.openerTargetId) activeTarget = tab.targetId;
    emit("tab.created", { targetId: tab.targetId, openerTargetId: tab.openerTargetId, url: page.url() });
  });

  function tabFor(targetId) {
    const tab = tabs.get(targetId);
    if (!tab) throw new DriverError("closed", `Tab ${targetId} is closed`);
    return tab;
  }
  function frameFor(targetId, id) {
    const tab = tabFor(targetId);
    if (!id) return tab.page.mainFrame();
    const frame = tab.frames.get(id);
    if (!frame || frame.isDetached()) throw new DriverError("stale", `Frame ${id} is detached`);
    return frame;
  }

  async function ensureAgent(frame) {
    const has = await frame.evaluate(`!!globalThis[${AGENT_KEY}]`);
    if (!has) await frame.evaluate(installSource);
  }

  async function evaluate(frame, { world = "page", source, args = [], handles = [], timeoutMs }) {
    const needsAgent = world === "agent" || handles.length > 0;
    const expr = `(async () => {
      const __agent = globalThis[${AGENT_KEY}];
      if (${needsAgent} && !__agent) return { ${NEEDS_AGENT}: true };
      try {
        const __handles = ${JSON.stringify(handles)}.map((h) => __agent.element(h));
        return await (${source})(...__handles, ...${JSON.stringify(args)});
      } catch (e) {
        return { ${ERROR_KEY}: { code: (e && e.code) || "evaluation", message: String(e && e.message !== undefined ? e.message : e), name: e && e.name } };
      }
    })()`;
    const run = async () => {
      let result = await frame.evaluate(expr);
      if (result && result[NEEDS_AGENT]) {
        await frame.evaluate(installSource);
        result = await frame.evaluate(expr);
      }
      if (result && result[ERROR_KEY]) {
        const e = new DriverError(result[ERROR_KEY].code, result[ERROR_KEY].message);
        e.errorName = result[ERROR_KEY].name;
        throw e;
      }
      return result;
    };
    try {
      if (!timeoutMs) return await run();
      let timer;
      return await Promise.race([
        run(),
        new Promise((_, reject) => (timer = setTimeout(() => reject(new DriverError("timeout", `Evaluation timed out after ${timeoutMs}ms`)), timeoutMs))),
      ]).finally(() => clearTimeout(timer));
    } catch (e) {
      if (e instanceof DriverError) throw e;
      if (/Execution context was destroyed|Frame was detached|navigat/i.test(e.message)) throw new DriverError("stale", e.message);
      if (/closed/i.test(e.message)) throw new DriverError("closed", e.message);
      throw new DriverError("evaluation", e.message);
    }
  }

  async function withModifiers(page, modifiers = [], fn) {
    const pressed = [];
    for (const m of modifiers) {
      if (!modifiersDown.has(m)) {
        await page.keyboard.down(m);
        pressed.push(m);
      }
    }
    try {
      return await fn();
    } finally {
      for (const m of pressed.reverse()) await page.keyboard.up(m);
    }
  }

  const MODIFIER_KEYS = new Set(["Alt", "Control", "Meta", "Shift"]);

  async function keyEvent(page, { type, key, code, text }) {
    const names = [key, code].filter(Boolean);
    for (const name of names) {
      try {
        if (type === "down") await page.keyboard.down(name);
        else await page.keyboard.up(name);
        if (MODIFIER_KEYS.has(key)) type === "down" ? modifiersDown.add(key) : modifiersDown.delete(key);
        return;
      } catch (e) {
        if (!/Unknown key/.test(e.message)) throw e;
      }
    }
    if (type === "down" && text) await page.keyboard.insertText(text);
  }

  const methods = {
    "tabs.list": async () =>
      Promise.all([...tabs.values()].map(async (t) => ({
        targetId: t.targetId,
        title: await t.page.title().catch(() => ""),
        url: t.page.url(),
        active: t.targetId === activeTarget,
        windowId: 1,
        ...(t.openerTargetId ? { openerTargetId: t.openerTargetId } : {}),
      }))),
    "tabs.open": async ({ url, background }) => {
      const page = await context.newPage();
      const tab = register(page);
      if (!background) activeTarget = tab.targetId;
      if (url) await page.goto(url, { waitUntil: "commit" });
      return { targetId: tab.targetId };
    },
    "tabs.close": async ({ targetId, runBeforeUnload }) => {
      await tabFor(targetId).page.close({ runBeforeUnload: !!runBeforeUnload });
    },
    "tabs.activate": async ({ targetId }) => {
      await tabFor(targetId).page.bringToFront();
      activeTarget = targetId;
    },
    "tab.navigate": async ({ targetId, url, waitUntil = "load", timeoutMs }) => {
      const page = tabFor(targetId).page;
      try {
        const r = await page.goto(url, { waitUntil, timeout: timeoutMs ?? 30000 });
        return { url: page.url(), status: r ? r.status() : undefined };
      } catch (e) {
        if (/Timeout/.test(e.message)) throw new DriverError("timeout", e.message.split("\n")[0]);
        throw new DriverError("invalid", e.message.split("\n")[0]);
      }
    },
    "tab.history": async ({ targetId, delta, waitUntil = "load", timeoutMs }) => {
      const page = tabFor(targetId).page;
      const before = page.url();
      const opts = { waitUntil, timeout: timeoutMs ?? 30000 };
      const r = delta < 0 ? await page.goBack(opts) : await page.goForward(opts);
      if (!r && page.url() === before) return null;
      return { url: page.url() };
    },
    "tab.reload": async ({ targetId, waitUntil = "load", timeoutMs }) => {
      await tabFor(targetId).page.reload({ waitUntil, timeout: timeoutMs ?? 30000 });
    },
    "tab.info": async ({ targetId }) => {
      const tab = tabFor(targetId);
      const page = tab.page;
      // Page script is blocked while a JavaScript dialog is open, so report
      // the last known title and load state instead of evaluating.
      if (!tab.openDialogs) {
        const readyState = await page.mainFrame().evaluate("document.readyState").catch(() => "loading");
        tab.loadState = readyState === "complete" ? "load" : readyState === "interactive" ? "domcontentloaded" : "commit";
        tab.title = await page.title().catch(() => tab.title);
      }
      return { url: page.url(), title: tab.title, loadState: tab.loadState, viewport: page.viewportSize() ?? viewport, deviceScaleFactor: 1 };
    },
    "tab.setViewport": async ({ targetId, width, height, reset }) => {
      await tabFor(targetId).page.setViewportSize(reset ? viewport : { width, height });
    },
    "tab.bringToFront": async ({ targetId }) => {
      await tabFor(targetId).page.bringToFront();
    },
    "frames.list": async ({ targetId }) => {
      const tab = tabFor(targetId);
      const main = tab.page.mainFrame();
      const origin = (u) => {
        try {
          return new URL(u).origin;
        } catch {
          return u;
        }
      };
      const out = [];
      const queue = [main];
      while (queue.length) {
        const f = queue.shift();
        if (f.isDetached()) continue;
        out.push({
          frameId: frameId(tab, f),
          parentFrameId: f.parentFrame() ? frameId(tab, f.parentFrame()) : null,
          url: f.url(),
          name: f.name(),
          crossOrigin: origin(f.url()) !== origin(main.url()),
        });
        queue.push(...f.childFrames());
      }
      return out;
    },
    "frame.evaluate": async ({ targetId, frameId: id, ...rest }) => evaluate(frameFor(targetId, id), rest),
    "frame.ownerBox": async ({ targetId, frameId: id }) => {
      const frame = frameFor(targetId, id);
      const owner = await frame.frameElement();
      return owner.evaluate((el) => {
        const r = el.getBoundingClientRect();
        const cs = getComputedStyle(el);
        const px = (v) => parseFloat(v) || 0;
        return {
          x: r.left + el.clientLeft + px(cs.paddingLeft),
          y: r.top + el.clientTop + px(cs.paddingTop),
          width: el.clientWidth - px(cs.paddingLeft) - px(cs.paddingRight),
          height: el.clientHeight - px(cs.paddingTop) - px(cs.paddingBottom),
        };
      });
    },
    // Proposed protocol addition: child frame of an <iframe> handle.
    "frame.contentFrame": async ({ targetId, frameId: id, element }) => {
      const tab = tabFor(targetId);
      const frame = frameFor(targetId, id);
      await ensureAgent(frame);
      const handle = await frame.evaluateHandle(([key, h]) => globalThis[Symbol.for(key)].element(h), ["cmux.browserRepl.agent", element]);
      const el = handle.asElement();
      const child = el ? await el.contentFrame() : null;
      await handle.dispose();
      return child ? { frameId: frameId(tab, child) } : null;
    },
    "input.mouse": async ({ targetId, type, x, y, button = "left", clickCount = 1, modifiers, deltaX = 0, deltaY = 0 }) => {
      const page = tabFor(targetId).page;
      await withModifiers(page, modifiers, async () => {
        if (type === "move") await page.mouse.move(x, y);
        else if (type === "down") await page.mouse.down({ button, clickCount });
        else if (type === "up") await page.mouse.up({ button, clickCount });
        else if (type === "wheel") {
          if (x !== undefined) await page.mouse.move(x, y);
          await page.mouse.wheel(deltaX, deltaY);
        } else throw new DriverError("invalid", `Unknown mouse event ${type}`);
      });
    },
    "input.key": async ({ targetId, ...event }) => keyEvent(tabFor(targetId).page, event),
    "input.insertText": async ({ targetId, text }) => tabFor(targetId).page.keyboard.insertText(text),
    "input.drag": async ({ targetId, path: points, button = "left", modifiers }) => {
      const page = tabFor(targetId).page;
      await withModifiers(page, modifiers, async () => {
        await page.mouse.move(points[0].x, points[0].y);
        await page.mouse.down({ button });
        for (const p of points.slice(1)) await page.mouse.move(p.x, p.y, { steps: 5 });
        await page.mouse.up({ button });
      });
    },
    "input.setFiles": async ({ targetId, frameId: id, element, files }) => {
      const frame = frameFor(targetId, id);
      const handle = await frame.evaluateHandle(([key, h]) => globalThis[Symbol.for(key)].element(h), ["cmux.browserRepl.agent", element]);
      try {
        await handle.asElement().setInputFiles(files.map((f) => ({ name: f.name, mimeType: f.mimeType, buffer: Buffer.from(f.base64, "base64") })));
      } finally {
        await handle.dispose();
      }
    },
    "filechooser.respond": async ({ chooserId, files, cancel }) => {
      const chooser = choosers.get(chooserId);
      choosers.delete(chooserId);
      if (!chooser) throw new DriverError("not_found", `File chooser ${chooserId} is gone`);
      if (cancel) return;
      await chooser.setFiles(files.map((f) => ({ name: f.name, mimeType: f.mimeType, buffer: Buffer.from(f.base64, "base64") })));
    },
    "dialog.respond": async ({ targetId, dialogId, accept, promptText }) => {
      const d = dialogs.get(dialogId);
      dialogs.delete(dialogId);
      if (!d) throw new DriverError("not_found", `Dialog ${dialogId} is gone`);
      if (tabs.has(targetId)) tabs.get(targetId).openDialogs--;
      if (accept) await d.accept(promptText);
      else await d.dismiss();
    },
    "download.path": async ({ downloadId }) => {
      const d = downloads.get(downloadId);
      if (!d) throw new DriverError("not_found", `Download ${downloadId} is gone`);
      return { path: await d.path() };
    },
    "tab.screenshot": async ({ targetId, clip, fullPage, format = "png", quality }) => {
      const type = format === "jpeg" ? "jpeg" : "png";
      const buf = await tabFor(targetId).page.screenshot({ clip, fullPage, type, quality: type === "jpeg" ? quality : undefined });
      return { base64: buf.toString("base64"), ...pngSize(buf) };
    },
    "tab.pdf": async ({ targetId }) => {
      const text = await tabFor(targetId).page.evaluate(() => document.body ? document.body.innerText : "");
      return { base64: textPdf(text).toString("base64") };
    },
    "cookies.get": async ({ urls } = {}) => context.cookies(urls),
    "cookies.set": async ({ cookies }) => context.addCookies(cookies),
    "cookies.clear": async () => context.clearCookies(),
    "clipboard.read": async ({ targetId }) => ({ items: tabFor(targetId).clipboard }),
    "clipboard.write": async ({ targetId, items }) => {
      tabFor(targetId).clipboard = items;
    },
  };

  return {
    name: "dev",
    async call(method, params = {}) {
      const fn = methods[method];
      if (!fn) throw new DriverError("unsupported", `Unsupported driver method ${method}`);
      return fn(params);
    },
    on(event, handler) {
      if (!listeners.has(event)) listeners.set(event, new Set());
      listeners.get(event).add(handler);
      return () => listeners.get(event).delete(handler);
    },
    capabilities: () => [],
    async close() {
      await browser.close().catch(() => {});
    },
  };
}

// Loads the runtime scripts into this Node process the way the app loads them
// into JavaScriptCore: as plain scripts that attach to globalThis.CmuxBrowserRepl.
export function loadRuntime() {
  if (globalThis.CmuxBrowserRepl?.replHost) return globalThis.CmuxBrowserRepl;
  const files = [
    "vendor/acorn.js",
    "vendor/playwright-locator-utils.js",
    "runtime-core.js",
    "dialect-aside.js",
    "dialect-chatgpt.js",
    "repl-host.js",
  ];
  for (const f of files) {
    const file = path.join(runtimeDir, f);
    vm.runInThisContext(fs.readFileSync(file, "utf8"), { filename: file });
  }
  return globalThis.CmuxBrowserRepl;
}

// Host capabilities the app provides natively. fs is confined to `workDir`
// by the dialect; the host only performs the operation.
export function createNodeHost({ workDir, log = (line) => process.stdout.write(line + "\n") }) {
  return {
    workDir,
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (t) => clearTimeout(t),
    now: () => Date.now(),
    console: { log },
    display: (value) => log(typeof value === "string" ? value : JSON.stringify(value)),
    // The ChatGPT reference REPL is Node, so dev runs allow Node modules.
    importModule: (specifier) => import(specifier),
    async fetch(url, init = {}) {
      const res = await fetch(url, { method: init.method, headers: init.headers, body: init.body === undefined ? undefined : Buffer.from(init.body, "base64") });
      const body = Buffer.from(await res.arrayBuffer());
      return { status: res.status, statusText: res.statusText, url: res.url, headers: Object.fromEntries(res.headers), base64: body.toString("base64") };
    },
    fs: {
      async readFile(p) {
        return (await fs.promises.readFile(p)).toString("base64");
      },
      async writeFile(p, base64) {
        await fs.promises.writeFile(p, Buffer.from(base64, "base64"));
      },
      async appendFile(p, base64) {
        await fs.promises.appendFile(p, Buffer.from(base64, "base64"));
      },
      async mkdir(p, recursive) {
        await fs.promises.mkdir(p, { recursive: !!recursive });
      },
      async readdir(p) {
        return fs.promises.readdir(p);
      },
      async stat(p) {
        const s = await fs.promises.stat(p);
        return { size: s.size, isFile: s.isFile(), isDirectory: s.isDirectory(), mtimeMs: s.mtimeMs };
      },
      async rm(p, recursive) {
        await fs.promises.rm(p, { recursive: !!recursive, force: true });
      },
      async exists(p) {
        return fs.existsSync(p);
      },
      realpath: (p) => (fs.existsSync(p) ? fs.realpathSync(p) : p),
    },
  };
}

// Runs one REPL cell against a fresh browser, the way `cmux browser repl
// --eval` runs a one-shot session. Returns the printed output.
export async function runDevRepl(code, { workDir } = {}) {
  const ns = loadRuntime();
  const os = await import("node:os");
  const dir = workDir ?? fs.mkdtempSync(path.join(os.tmpdir(), "cmux-repl-"));
  const lines = [];
  const host = createNodeHost({ workDir: fs.realpathSync(dir), log: (line) => lines.push(line) });
  host.console.error = (line) => lines.push(line);
  const driver = await createDevDriver();
  try {
    const repl = ns.replHost.createBrowserRepl({ host, driver, workDir: host.workDir });
    const r = await repl.evaluate(code);
    if (!r.ok) lines.push(`Uncaught ${r.error}`);
    repl.dispose();
  } finally {
    await driver.close();
    if (!workDir) fs.rmSync(dir, { recursive: true, force: true });
  }
  return lines.join("\n");
}
