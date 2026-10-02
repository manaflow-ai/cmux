// `dev` browser driver: implements docs/browser-repl/driver-protocol.md on
// Playwright WebKit so the engine-neutral runtime in Resources/browser-repl can
// be developed and checked without an app build.
//
// Playwright cannot choose a content world on WebKit, so the "agent" world is
// the main world and the page agent lives under a non-enumerable symbol.
// Input goes through page.mouse / page.keyboard, which WebKit delivers as
// trusted events.
//
// One browser serves several REPL sessions, as one cmux window does: each
// session gets its own driver, and a session's detach closes the tabs it
// opened unless they were kept (tab.keep), like the app's one-shot runs.
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import crypto from "node:crypto";
import os from "node:os";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
export const runtimeDir = path.join(repoRoot, "Resources/browser-repl");

const AGENT_KEY = 'Symbol.for("cmux.browserRepl.agent")';
const NEEDS_AGENT = "__cmuxNeedsAgent__";
const ERROR_KEY = "__cmuxError__";
const JSON_KEY = "__cmuxJson__";

export function loadPlaywright() {
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

// `setupContext(context)` runs once on the Playwright context before any tab
// opens (site-tool tests route real hostnames to local mock sites with it).
export async function createDevBrowser({ headless = true, viewport = { width: 1280, height: 800 }, setupContext } = {}) {
  const { webkit } = loadPlaywright();
  const installSource = agentInstallSource();
  const browser = await webkit.launch({ headless });
  const context = await browser.newContext({ viewport, acceptDownloads: true });
  if (setupContext) await setupContext(context);
  // The app's agent world sees closed shadow roots (WebKit's
  // allowAccessToClosedShadowRoots world option). Playwright cannot configure
  // a world, and this driver's agent shares the main world, so closed roots
  // are exposed through `shadowRoot` in the main world. Pages here therefore
  // see their own closed roots too; no fixture depends on the difference.
  await context.addInitScript(() => {
    const attach = Element.prototype.attachShadow;
    const getter = Object.getOwnPropertyDescriptor(Element.prototype, "shadowRoot").get;
    const closed = new WeakMap();
    Element.prototype.attachShadow = function (init) {
      const root = attach.call(this, init);
      if (init && init.mode === "closed") closed.set(this, root);
      return root;
    };
    Object.defineProperty(Element.prototype, "shadowRoot", {
      configurable: true,
      enumerable: true,
      get() {
        return getter.call(this) || closed.get(this) || null;
      },
    });
  });
  const drivers = new Set();
  const tabs = new Map();
  // Visits most recent first, one row per URL.
  const history = [];
  const recordVisit = (url, title) => {
    const at = history.findIndex((h) => h.url === url);
    if (at >= 0) history.splice(at, 1);
    history.unshift({ url, title: title || "", dateVisited: Date.now() });
  }; // targetId -> tab record
  const tabOf = new WeakMap(); // page -> tab record
  const dialogs = new Map();
  const choosers = new Map();
  const downloads = new Map();
  let activeTarget = null;
  let nextId = 1;
  const modifiersDown = new Set();

  const emit = (event, payload) => {
    for (const d of drivers) {
      for (const h of d.listeners.get(event) ?? []) {
        try {
          h(payload);
        } catch (e) {
          console.error(`driver listener for ${event} failed:`, e);
        }
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
    page.on("load", () => {
      emit("tab.loadState", { targetId, state: "load" });
      // Browser history, as cmux records it: http(s) main-frame loads.
      const url = page.url();
      if (/^https?:/.test(url)) page.title().then((title) => recordVisit(url, title), () => recordVisit(url, ""));
    });
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
        const __result = await (${source})(...__handles, ...${JSON.stringify(args)});
        // Agent results cross as JSON text, as in the app's driver: one
        // string instead of Playwright's per-value serialization.
        return ${world === "agent"} ? { ${JSON_KEY}: __result === undefined ? "null" : JSON.stringify(__result) } : __result;
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
      if (result && typeof result[JSON_KEY] === "string") return JSON.parse(result[JSON_KEY]);
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

  // Meta+C, Meta+X and Meta+V use the tab's virtual clipboard, as the app
  // driver does; the system pasteboard is never touched.
  async function clipboardShortcut(tab, key) {
    const page = tab.page;
    if (key === "v") {
      // The app runs WebKit's Paste against the tab's clipboard, so the page
      // gets a paste event with clipboardData. Playwright WebKit's own paste
      // reads the system clipboard, so this double dispatches the event (not
      // trusted) in the focused frame and inserts the text unless cancelled.
      const item = tab.clipboard.find((i) => i.type === "text/plain");
      const text = item ? Buffer.from(item.base64, "base64").toString("utf8") : "";
      const entries = tab.clipboard.filter((i) => /^[\w.+-]+\/[\w.+-]+$/.test(i.type)).map((i) => [i.type, Buffer.from(i.base64, "base64").toString("utf8")]);
      let frame = page.mainFrame();
      for (const f of page.frames()) {
        if (await f.evaluate(() => document.hasFocus() && !(document.activeElement instanceof HTMLIFrameElement)).catch(() => false)) frame = f;
      }
      const cancelled = await frame.evaluate((entries) => {
        const data = new DataTransfer();
        for (const [type, value] of entries) data.setData(type, value);
        let el = document.activeElement || document.body;
        while (el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        return !el.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true, composed: true }));
      }, entries);
      if (!cancelled && text) await page.keyboard.insertText(text);
      return;
    }
    const selection = await page.evaluate(() => {
      const el = document.activeElement;
      if (el && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) && el.selectionStart !== null) {
        return el.value.slice(el.selectionStart, el.selectionEnd);
      }
      return String(getSelection() || "");
    });
    tab.clipboard = [{ type: "text/plain", base64: Buffer.from(selection).toString("base64") }];
    // The app sends Cocoa's delete: action; execCommand is its page-side twin.
    if (key === "x" && selection) await page.evaluate(() => document.execCommand("delete"));
  }

  async function keyEvent(tab, { type, key, code, text, modifiers = [] }) {
    const page = tab.page;
    const lower = String(key).toLowerCase();
    if ((modifiers.includes("Meta") || modifiersDown.has("Meta")) && ["c", "x", "v"].includes(lower)) {
      if (type === "down") await clipboardShortcut(tab, lower);
      return;
    }
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

  // WebKit content-blocker rules applied with request routing: the last
  // matching block or ignore-previous-rules rule decides. Main-frame
  // documents are not routed, as in the app.
  const RESOURCE_TYPES = { image: "image", stylesheet: "style-sheet", script: "script", font: "font", media: "media", fetch: "fetch", xhr: "fetch", websocket: "websocket", ping: "ping", other: "other" };
  let contentRules = [];
  let routed = false;
  async function setContentRules(rules) {
    contentRules = rules.map((r) => ({ re: new RegExp(r.trigger["url-filter"], "i"), types: r.trigger["resource-type"] || null, child: (r.trigger["load-context"] || []).includes("child-frame"), type: r.action.type }));
    if (routed || !contentRules.length) return;
    routed = true;
    await context.route("**/*", (route, request) => {
      const isDocument = request.resourceType() === "document";
      if (isDocument && request.frame().parentFrame() === null) return route.fallback();
      const type = isDocument ? "document" : RESOURCE_TYPES[request.resourceType()] || "other";
      let blocked = false;
      for (const r of contentRules) {
        if (!r.re.test(request.url())) continue;
        if (r.types && !r.types.includes(type)) continue;
        if (isDocument && !r.child) continue;
        blocked = r.type === "block";
      }
      return blocked ? route.abort("blockedbyclient") : route.fallback();
    });
  }

  const methods = {
    "history.search": async ({ queries = [], from, to, limit = 100 }) => {
      const qs = queries.map((q) => String(q).toLowerCase());
      return history
        .filter((h) => (from === undefined || h.dateVisited >= from) && (to === undefined || h.dateVisited <= to))
        .filter((h) => !qs.length || qs.some((q) => h.url.toLowerCase().includes(q) || h.title.toLowerCase().includes(q)))
        .slice(0, limit);
    },
    "tabs.list": async () =>
      Promise.all([...tabs.values()].map(async (t) => ({
        targetId: t.targetId,
        title: await t.page.title().catch(() => ""),
        url: t.page.url(),
        active: t.targetId === activeTarget,
        windowId: 1,
        ...(t.openerTargetId ? { openerTargetId: t.openerTargetId } : {}),
      }))),
    "tabs.open": async ({ url, background }, driver) => {
      const page = await context.newPage();
      const tab = register(page);
      tab.blankStart = !url;
      driver.opened.add(tab.targetId);
      if (!background) activeTarget = tab.targetId;
      if (url) await page.goto(url, { waitUntil: "commit" });
      return { targetId: tab.targetId };
    },
    "tab.keep": async ({ targetId }, driver) => {
      tabFor(targetId);
      driver.opened.delete(targetId);
    },
    "session.name": async ({ name }, driver) => {
      driver.sessionName = String(name);
    },
    // Browser-context options. Playwright fixes the user agent and proxy at
    // context creation, so those are unsupported here; headers apply to every
    // request (the app adds them to main-frame navigations only).
    "session.configure": async (params) => {
      if ((params.userAgent !== undefined && params.userAgent !== null) || (params.proxy !== undefined && params.proxy !== null)) {
        throw new DriverError("unsupported", "the dev driver cannot change the user agent or proxy of a running context");
      }
      if (params.extraHTTPHeaders !== undefined) await context.setExtraHTTPHeaders(params.extraHTTPHeaders || {});
      if (params.permissions !== undefined) {
        await context.clearPermissions();
        if ((params.permissions || []).length) await context.grantPermissions(params.permissions);
      }
      if (params.contentRules !== undefined) await setContentRules(params.contentRules || []);
      return { proxy: false };
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
      // The blank page a new tab starts on is not a history entry to go back
      // to (Chrome drops it on the first navigation), as the app's driver.
      const tab = tabFor(targetId);
      if (delta < 0 && tab.blankStart && !tab.wentBack && (await page.evaluate("history.length").catch(() => 0)) === 2) return null;
      if (delta < 0) tab.wentBack = true;
      const opts = { waitUntil, timeout: timeoutMs ?? 30000 };
      const r = delta < 0 ? await page.goBack(opts) : await page.goForward(opts);
      if (!r && page.url() === before) return null;
      return { url: page.url() };
    },
    "tab.reload": async ({ targetId, waitUntil = "load", timeoutMs }) => {
      const r = await tabFor(targetId).page.reload({ waitUntil, timeout: timeoutMs ?? 30000 });
      return r ? { status: r.status() } : null;
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
    "frame.contentFrames": async ({ targetId, frameId: id, elements = [] }) => {
      return Promise.all(elements.map((element) => methods["frame.contentFrame"]({ targetId, frameId: id, element }).catch(() => null)));
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
    "input.key": async ({ targetId, ...event }) => {
      await keyEvent(tabFor(targetId), event);
      // As the app's driver: Command+B/I/U format an editable selection.
      const mods = event.modifiers || [];
      const cmd = { KeyB: "bold", KeyI: "italic", KeyU: "underline" }[event.code];
      if (event.type === "down" && cmd && mods.length === 1 && mods[0] === "Meta") {
        await tabFor(targetId).page.evaluate((c) => {
          const el = document.activeElement;
          if (document.designMode === "on" || (el && el.isContentEditable)) document.execCommand(c);
        }, cmd);
      }
    },
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

  function createDriver() {
    const driver = {
      name: "dev",
      listeners: new Map(),
      opened: new Set(),
      sessionName: null,
      async call(method, params = {}) {
        const fn = methods[method];
        if (!fn) throw new DriverError("unsupported", `Unsupported driver method ${method}`);
        return fn(params, driver);
      },
      on(event, handler) {
        if (!driver.listeners.has(event)) driver.listeners.set(event, new Set());
        driver.listeners.get(event).add(handler);
        return () => driver.listeners.get(event).delete(handler);
      },
      capabilities: () => [],
      // Ends the session: tabs it opened close unless kept.
      async detach() {
        drivers.delete(driver);
        for (const targetId of driver.opened) {
          const tab = tabs.get(targetId);
          if (tab) await tab.page.close().catch(() => {});
        }
        driver.opened.clear();
      },
    };
    drivers.add(driver);
    return driver;
  }

  return {
    driver: createDriver,
    async close() {
      await browser.close().catch(() => {});
    },
  };
}

// A single-session driver on its own browser, closed with the driver.
export async function createDevDriver(options) {
  const browser = await createDevBrowser(options);
  const driver = browser.driver();
  driver.close = () => browser.close();
  return driver;
}

// Loads the runtime scripts into this Node process the way the app loads them
// into JavaScriptCore: the `repl` list of manifest.json, as plain scripts that
// attach to globalThis.CmuxBrowserRepl.
export function loadRuntime() {
  if (globalThis.CmuxBrowserRepl?.replHost) return globalThis.CmuxBrowserRepl;
  const manifest = JSON.parse(fs.readFileSync(path.join(runtimeDir, "manifest.json"), "utf8"));
  for (const f of manifest.repl) {
    const file = path.join(runtimeDir, f);
    vm.runInThisContext(fs.readFileSync(file, "utf8"), { filename: file });
  }
  return globalThis.CmuxBrowserRepl;
}

function fsError(code, message) {
  const e = new Error(message);
  e.code = code;
  return e;
}

// The app's fs sandbox, in Node: paths must resolve inside the session
// directory or the temporary directory; downloads the driver reported are
// readable too (BrowserReplFileSandbox.swift).
export function createFsOp({ workDir, tmpdir, readable = new Set() }) {
  // Mirrors BrowserReplFileSystem: reading or writing through a path checks
  // where its links point; rm, rename and lstat act on a link itself and
  // check only its parent directories.
  const roots = [fs.realpathSync(workDir), fs.realpathSync(tmpdir)];
  const lexists = (p) => {
    try {
      fs.lstatSync(p);
      return true;
    } catch {
      return false;
    }
  };
  const canonical = (p) => {
    let head = path.resolve(p);
    const tail = [];
    while (!fs.existsSync(head) && head !== "/") {
      // A dangling link: writing through it would create its target,
      // which may be anywhere. No canonical path.
      if (lexists(head)) return null;
      tail.unshift(path.basename(head));
      head = path.dirname(head);
    }
    return path.join(fs.realpathSync(head), ...tail);
  };
  const entry = (p) => {
    const full = path.resolve(p);
    if (full === "/") return full;
    const parent = canonical(path.dirname(full));
    return parent === null ? null : path.join(parent, path.basename(full));
  };
  const inside = (p) => p !== null && roots.some((r) => p === r || p.startsWith(r + "/"));
  const check = (raw, write, followLastLink = true) => {
    if (typeof raw !== "string") throw fsError("EINVAL", "EINVAL: missing path");
    const full = path.resolve(workDir, raw);
    const followed = canonical(full);
    const candidates = followLastLink ? [followed] : [entry(full), ...(roots.includes(followed) ? [followed] : [])];
    for (const p of candidates) {
      if (inside(p) || (p !== null && !write && readable.has(p))) return p;
    }
    throw fsError("EACCES", `EACCES: permission denied, '${raw}' is outside the REPL's directories`);
  };
  const type = (p) => {
    const st = fs.lstatSync(p);
    return st.isSymbolicLink() ? "symlink" : st.isFile() ? "file" : st.isDirectory() ? "directory" : "other";
  };
  const statOf = (p, st) => ({ size: st.size, type: type(p), mtimeMs: st.mtimeMs, birthtimeMs: st.birthtimeMs });
  const ops = {
    resolve: (a) => check(a.path, false),
    exists: (a) => {
      try {
        return fs.existsSync(check(a.path, false));
      } catch {
        return false;
      }
    },
    readFile: (a) => fs.readFileSync(check(a.path, false)).toString("base64"),
    writeFile: (a) => {
      const p = check(a.path, true);
      const data = Buffer.from(a.base64 || "", "base64");
      if (a.append) fs.appendFileSync(p, data);
      else fs.writeFileSync(p, data);
      return null;
    },
    mkdir: (a) => {
      fs.mkdirSync(check(a.path, true), { recursive: !!a.recursive });
      return null;
    },
    readdir: (a) => {
      const p = check(a.path, false);
      return fs.readdirSync(p).sort().map((name) => ({ name, type: type(path.join(p, name)) }));
    },
    stat: (a) => {
      const p = check(a.path, false);
      return statOf(p, fs.statSync(p));
    },
    lstat: (a) => {
      const p = check(a.path, false, false);
      return statOf(p, fs.lstatSync(p));
    },
    rm: (a) => {
      const p = check(a.path, true, false);
      if (roots.includes(p)) throw fsError("EACCES", "EACCES: refusing to remove the REPL working directory");
      // fs.rmSync acts on a link itself (lstat), never on what it points to.
      fs.rmSync(p, { recursive: !!a.recursive, force: !!a.force });
      return null;
    },
    rename: (a) => {
      fs.renameSync(check(a.from, true, false), check(a.to, true, false));
      return null;
    },
    copyFile: (a) => {
      const from = check(a.from, false);
      const to = check(a.to, true);
      // Copy next to the destination, then swap it in, so a failed copy
      // leaves an existing destination untouched.
      const staging = path.join(path.dirname(to), `.${path.basename(to)}.cmux-copy-${crypto.randomUUID()}`);
      try {
        fs.copyFileSync(from, staging);
        fs.renameSync(staging, to);
      } catch (e) {
        fs.rmSync(staging, { force: true });
        throw e;
      }
      return null;
    },
  };
  return (op, args) => {
    const fn = ops[op];
    if (!fn) throw fsError("EINVAL", `EINVAL: unknown fs operation ${op}`);
    try {
      return fn(args || {});
    } catch (e) {
      if (e.code) throw fsError(e.code, e.message);
      throw e;
    }
  };
}

// Host capabilities the app provides natively (driver-protocol.md, "Native
// host contract").
export function createNodeHost({ workDir, sessionId = "dev", print, readable = new Set() }) {
  const tmpdir = fs.realpathSync(os.tmpdir());
  return {
    workDir,
    sessionId,
    tmpdir,
    homedir: os.homedir(),
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (t) => clearTimeout(t),
    now: () => Date.now(),
    print,
    console: { error: (text) => print("error", text) },
    readResource: (relativePath) => {
      const file = path.join(runtimeDir, relativePath);
      return file.startsWith(runtimeDir + "/") && fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
    },
    fsOp: createFsOp({ workDir, tmpdir, readable }),
    async fetch(url, init = {}) {
      const res = await fetch(url, { method: init.method, headers: init.headers, body: init.body === undefined ? undefined : Buffer.from(init.body, "base64") });
      const body = Buffer.from(await res.arrayBuffer());
      return { status: res.status, statusText: res.statusText, url: res.url, headers: Object.fromEntries(res.headers), base64: body.toString("base64"), redirected: res.redirected };
    },
  };
}

// Runs REPL cells the way `cmux browser repl` runs calls: every cell is a
// one-shot session unless it names a session, and one-shot sessions close
// the tabs they opened unless kept. Returns each cell's printed output and
// uncaught error.
export async function runDevCells(cells, { workDir } = {}) {
  const ns = loadRuntime();
  const dir = fs.realpathSync(workDir ?? fs.mkdtempSync(path.join(os.tmpdir(), "cmux-repl-")));
  const browser = await createDevBrowser();
  const named = new Map();
  const readable = new Set();
  const outputs = [];
  try {
    for (const cell of cells) {
      const lines = [];
      const print = (level, text) => lines.push(text);
      let entry = cell.session ? named.get(cell.session) : null;
      if (!entry) {
        const driver = browser.driver();
        driver.on("download.finished", (p) => p.path && readable.add(fs.realpathSync(p.path)));
        let current = print;
        const host = createNodeHost({ workDir: dir, sessionId: cell.session || `oneshot-${outputs.length + 1}`, print: (l, t) => current(l, t), readable });
        entry = { driver, repl: ns.replHost.createBrowserRepl({ host, driver }), setPrint: (p) => (current = p) };
        if (cell.session) named.set(cell.session, entry);
      }
      entry.setPrint(print);
      const r = await entry.repl.evaluate(cell.code);

      if (!cell.session) {
        entry.repl.dispose();
        await entry.driver.detach();
      }
      outputs.push({ output: lines.join("\n"), error: r.ok ? null : r.error });
    }
  } finally {
    await browser.close();
    if (!workDir) fs.rmSync(dir, { recursive: true, force: true });
  }
  return outputs;
}

export async function runDevRepl(code, options) {
  const [r] = await runDevCells([{ code }], options);
  return r.error ? `${r.output}\nUncaught ${r.error}`.replace(/^\n/, "") : r.output;
}
