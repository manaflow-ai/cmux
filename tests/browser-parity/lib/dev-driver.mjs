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
import { createBoundary } from "./native-boundary.mjs";
import { siteOf } from "./public-suffix.mjs";
import { makeTestDir, removeTestDir, removeTestDirIfEmpty } from "./test-dirs.mjs";

const require = createRequire(import.meta.url);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
export const runtimeDir = path.join(repoRoot, "Resources/browser-repl");

const AGENT_KEY = 'Symbol.for("cmux.browserRepl.agent")';
const NEEDS_AGENT = "__cmuxNeedsAgent__";
const ERROR_KEY = "__cmuxError__";
const JSON_KEY = "__cmuxJson__";

export function loadPlaywright() {
  process.env.PLAYWRIGHT_BROWSERS_PATH ??= path.join(process.env.HOME, ".cache/cmux-parity-browsers");
  // A node_modules directory with playwright: PARITY_PLAYWRIGHT_DIR, else the
  // copy bundled with reference B's runtime (lib/references.mjs), else the
  // usual resolution from here.
  const runtime = process.env.PARITY_REFERENCE_B_RUNTIME || process.env.CUA_REFERENCE_RUNTIME;
  const dirs = [process.env.PARITY_PLAYWRIGHT_DIR, runtime && path.join(runtime, "lib/node_modules")].filter(Boolean);
  for (const d of dirs) {
    try {
      return require(path.join(d, "playwright"));
    } catch {}
  }
  try {
    return require("playwright");
  } catch (e) {
    throw new Error(`playwright not found: set PARITY_PLAYWRIGHT_DIR to a node_modules directory that holds it (${e.message.split("\n")[0]})`);
  }
}

// Builds the install script from the recipe in page-agent.js.
export function agentInstallSource() {
  const injected = fs.readFileSync(path.join(runtimeDir, "vendor/playwright-injected.js"), "utf8");
  const agent = fs.readFileSync(path.join(runtimeDir, "page-agent.js"), "utf8");
  return `(() => {\nconst module = {};\n${injected}\n;const __cmuxInjectedScriptFactory = module.exports.InjectedScript;\n${agent}\n})()`;
}

// The app's page clipboard guard (BrowserReplPageClipboard): in a tab a
// session created, the page's Clipboard API and execCommand("copy" | "cut")
// write the tab's clipboard, never the system's. The app also switches
// WebKit's asynchronous Clipboard API off; Playwright cannot, so here the
// same page-clipboard.js replaces it in every document the page loads.
export function pageClipboardInitScript() {
  const shim = fs.readFileSync(path.join(runtimeDir, "page-clipboard.js"), "utf8");
  return `(${shim})(((post) => (message) => post ? post(message) : Promise.reject(new Error("the tab's clipboard is unavailable")))(globalThis.__cmuxReplClipboard));`;
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
// The id `tabs.list` and `tabs.dataStore` report for the context's one store.
const DATA_STORE = "default";

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

  const emitTo = (d, event, payload) => {
    for (const h of d.listeners.get(event) ?? []) {
      try {
        h(payload);
      } catch (e) {
        console.error(`driver listener for ${event} failed:`, e);
      }
    }
  };
  const emit = (event, payload) => {
    for (const d of drivers) emitTo(d, event, payload);
  };
  // The headers a session other than the tab's creator gets
  // (Dictionary.removingBrowserReplCredentialHeaders in the app).
  const CREDENTIAL_HEADERS = new Set(["cookie", "set-cookie", "set-cookie2", "authorization", "proxy-authorization", "x-api-key", "x-auth-token", "x-csrf-token", "x-xsrf-token"]);
  const withoutCredentials = (headers) => Object.fromEntries(Object.entries(headers).filter(([k]) => !CREDENTIAL_HEADERS.has(k.toLowerCase())));
  // A tab another live session created: `driver` may not drive it.
  const ownClipboard = (tab, driver) => {
    if (tab.creator === driver && drivers.has(driver)) return tab;
    throw new DriverError("unsupported", "page.clipboard is refused in a user's tab (one no attached session opened): a tab's clipboard belongs to the session that opened the tab, and other sessions may drive a user's tab. Open the page with tabs.open() to use it");
  };
  const ownerRefusing = (tab, driver) => (tab.creator && tab.creator !== driver && drivers.has(tab.creator) ? tab.creator : null);

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
    const tab = { targetId: hexId(), page, frameIds: new WeakMap(), frames: new Map(), clipboard: [], clipboardCommand: null, openerTargetId: undefined, openDialogs: 0, title: "", loadState: "commit", creator: null, handled: new Map(), inputDrivers: [], heldKeys: new Map(), heldButtons: new Map(), requestRecipients: new Map() };
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
      // A user's tab keeps its own UI for dialogs no session handles; this
      // driver stands in for the user: it lets the page leave on
      // beforeunload, as cmux does with no session, and dismisses the rest.
      if (!routesToSessions(tab, "dialog")) {
        (d.type() === "beforeunload" ? d.accept() : d.dismiss()).catch(() => {});
        return;
      }
      const dialogId = `d${nextId++}`;
      // As in the app: a dialog during Copy, Cut or Paste is dismissed at
      // once, so it cannot hold the command, and reported.
      if (tab.clipboardCommand) {
        d.dismiss().catch(() => {});
        emit("dialog.opened", { targetId, dialogId, type: d.type(), message: d.message(), defaultValue: d.defaultValue(), dismissedDuring: tab.clipboardCommand });
        return;
      }
      dialogs.set(dialogId, d);
      tab.openDialogs++;
      emit("dialog.opened", { targetId, dialogId, type: d.type(), message: d.message(), defaultValue: d.defaultValue() });
    });
    page.on("filechooser", async (c) => {
      // The user's own file panel: nobody answers it here.
      if (!routesToSessions(tab, "filechooser")) return;
      const chooserId = `c${nextId++}`;
      choosers.set(chooserId, c);
      const frame = c.element().ownerFrame ? await c.element().ownerFrame() : page.mainFrame();
      await ensureAgent(frame);
      const element = await c.element().evaluate((el, key) => globalThis[Symbol.for(key)].handleFor(el), "cmux.browserRepl.agent");
      emit("filechooser.opened", { targetId, chooserId, frameId: frameId(tab, frame), element, multiple: c.isMultiple() });
    });
    page.on("download", (d) => {
      // The user's download: it is not reported to the sessions.
      if (!routesToSessions(tab, "download")) return;
      const downloadId = `dl${nextId++}`;
      downloads.set(downloadId, d);
      emit("download.started", { targetId, downloadId, url: d.url(), suggestedFilename: d.suggestedFilename() });
      d.path().then(
        (p) => emit("download.finished", { targetId, downloadId, path: p }),
        (e) => emit("download.finished", { targetId, downloadId, error: String(e.message) }),
      );
    });
    // As in the app (BrowserReplTabOwnership.networkRecipients): a network
    // event goes to the tab's live creator, the sessions with a network
    // listener on the tab and the session whose action started the
    // request; only the creator gets credential headers.
    const net = (event) => (r) => {
      const req = r.request ? r.request() : r;
      const requestId = req._guid ?? req.url();
      const live = (d) => drivers.has(d);
      const recipients = new Set([...tab.handled].filter(([d, events]) => live(d) && events.has("network")).map(([d]) => d));
      if (tab.creator && live(tab.creator)) recipients.add(tab.creator);
      if (event === "request") {
        for (const d of tab.inputDrivers) if (live(d)) recipients.add(d);
        tab.requestRecipients.set(requestId, new Set(recipients));
      } else {
        for (const d of tab.requestRecipients.get(requestId) ?? []) if (live(d)) recipients.add(d);
        if (event !== "response") tab.requestRecipients.delete(requestId);
      }
      const headers = r.headers ? r.headers() : undefined;
      for (const d of recipients) {
        emitTo(d, event, {
          targetId,
          requestId,
          url: req.url(),
          method: req.method(),
          resourceType: req.resourceType(),
          status: r.status ? r.status() : undefined,
          headers: headers && d !== tab.creator ? withoutCredentials(headers) : headers,
        });
      }
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

  // Session behaviors apply to tabs a session opened (and their popups)
  // while it is attached; in any other tab only the events a session
  // registered a handler for (tab.handleEvents) reach the sessions.
  async function guardPageClipboard(tab) {
    if (tab.pageClipboardGuarded) return;
    tab.pageClipboardGuarded = true;
    await tab.page.exposeBinding("__cmuxReplClipboard", (_source, message) => {
      const items = message && Array.isArray(message.items) ? message.items : null;
      if (!items || items.some((i) => !i || typeof i.type !== "string" || typeof i.base64 !== "string")) {
        throw new Error("the clipboard write is not a list of typed items within the size limit");
      }
      // Only while the creating session holds the tab.
      if (!(tab.creator && drivers.has(tab.creator))) throw new Error("the tab's clipboard is unavailable");
      tab.clipboard = items.map((i) => ({ type: i.type, base64: i.base64 }));
    });
    await tab.page.addInitScript({ content: pageClipboardInitScript() });
  }

  function routesToSessions(tab, event) {
    if (tab.creator && drivers.has(tab.creator)) return true;
    for (const [driver, events] of tab.handled) if (drivers.has(driver) && events.has(event)) return true;
    // As in the app: a dialog or file chooser the page opens while it
    // handles a session's input or navigation goes to that session.
    if (event !== "download" && tab.inputDrivers.some((driver) => drivers.has(driver))) return true;
    return false;
  }

  context.on("page", async (page) => {
    const tab = register(page);
    const opener = await page.opener().catch(() => null);
    if (opener && tabOf.has(opener)) {
      tab.openerTargetId = tabOf.get(opener).targetId;
      tab.creator ??= tabOf.get(opener).creator;
      if (tab.creator) await guardPageClipboard(tab).catch(() => {});
    }
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

  // The checks of an input.mouse press's `expect`, all at once, in each
  // frame's agent: `{ frameId, handle, x, y, owners: [{ frameId, handle,
  // x, y }] }`, innermost first, ending at the press point.
  async function checkPress(targetId, expect, x, y) {
    const refused = (why) => new DriverError("stale", `no press was sent: ${why} when the press was about to be sent (the page changed under the pointer)`);
    const levels = [{ frameId: expect.frameId, handle: expect.handle, x: expect.x, y: expect.y, from: null }];
    for (const o of expect.owners || []) {
      const below = levels[levels.length - 1];
      levels.push({ frameId: o.frameId, handle: o.handle, x: o.x, y: o.y, from: { x: below.x, y: below.y } });
    }
    const last = levels[levels.length - 1];
    if (typeof expect.handle !== "string" || last.x !== x || last.y !== y) throw new DriverError("invalid", "input.mouse: expect does not end at the press point");
    const frames = levels.map((l) => {
      try {
        return frameFor(targetId, l.frameId);
      } catch {
        throw refused(`frame ${l.frameId} was detached`);
      }
    });
    for (let i = 0; i + 1 < frames.length; i++) {
      if (frames[i].parentFrame() !== frames[i + 1]) throw refused(`frame ${levels[i].frameId} is not in frame ${levels[i + 1].frameId}`);
    }
    if (frames[frames.length - 1].parentFrame()) throw refused("the press names no frame up to the main frame");
    const source = "(h, at, from) => { const a = globalThis[Symbol.for('cmux.browserRepl.agent')]; return a && typeof a.pressCheck === 'function' ? a.pressCheck(h, at, from) : 'the frame shows another document'; }";
    const results = await Promise.all(levels.map((l, i) =>
      evaluate(frames[i], { world: "agent", source, args: [l.handle, { x: l.x, y: l.y }, l.from] }).catch((e) => String(e.message || e))));
    const why = results.find((r) => r !== null);
    if (why !== undefined) throw refused(why);
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
  // driver does; no pasteboard is ever touched. Like the app, this
  // dispatches the copy, cut or paste event (not trusted) with a
  // DataTransfer in the focused frame and does the default action there
  // unless the page cancels it. They run only in tabs a session created.
  async function clipboardShortcut(tab, key) {
    const type = { c: "copy", x: "cut", v: "paste" }[key];
    const name = { copy: "Copy", cut: "Cut", paste: "Paste" }[type];
    if (!(tab.creator && drivers.has(tab.creator))) {
      throw new DriverError(
        "unsupported",
        `${name} is refused in a user's tab (one no attached session opened): the clipboard there is the system's, which agent input never reaches. Open the page with tabs.open() to use the tab's own clipboard`,
      );
    }
    await runClipboardShortcut(tab, type);
  }

  async function runClipboardShortcut(tab, type) {
    const page = tab.page;
    let frame = page.mainFrame();
    for (const f of page.frames()) {
      if (await f.evaluate(() => document.hasFocus() && !(document.activeElement instanceof HTMLIFrameElement)).catch(() => false)) frame = f;
    }
    tab.clipboardCommand = type;
    try {
      if (type === "paste") {
        const item = tab.clipboard.find((i) => i.type === "text/plain");
        const text = item ? Buffer.from(item.base64, "base64").toString("utf8") : "";
        const entries = tab.clipboard.filter((i) => /^[\w.+-]+\/[\w.+-]+$/.test(i.type)).map((i) => [i.type, Buffer.from(i.base64, "base64").toString("utf8")]);
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
      // Copy and Cut fire only when something is selected; without a
      // cancelled event they take the selection as it is after the handlers.
      const result = await frame.evaluate((type) => {
        let el = document.activeElement || document.body;
        while (el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        const field = (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) && el.selectionStart !== null;
        const selected = () => (field ? el.value.slice(el.selectionStart, el.selectionEnd) : String(getSelection() || ""));
        if (!selected()) return { selection: "", items: null };
        const data = new DataTransfer();
        const cancelled = !el.dispatchEvent(new ClipboardEvent(type, { clipboardData: data, bubbles: true, cancelable: true, composed: true }));
        return { selection: selected(), items: cancelled ? [...data.types].map((t) => [t, data.getData(t)]) : null };
      }, type);
      tab.clipboard = result.items
        ? result.items.map(([t, value]) => ({ type: t, base64: Buffer.from(value).toString("base64") }))
        : [{ type: "text/plain", base64: Buffer.from(result.selection).toString("base64") }];
      if (type === "cut" && !result.items && result.selection) await frame.evaluate(() => document.execCommand("delete"));
    } finally {
      tab.clipboardCommand = null;
    }
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
  // A main-frame navigation of a tab a session opened, to a URL that
  // session's domain policy blocks, is cancelled and reported, as the app's
  // navigation delegate does.
  function cancelsNavigation(request) {
    const tab = tabOf.get(request.frame().page());
    if (!tab) return false;
    for (const d of drivers) {
      if (!d.blockReason || !d.opened.has(tab.targetId)) continue;
      const reason = d.blockReason(request.url());
      if (!reason) continue;
      for (const h of d.listeners.get("navigation.blocked") ?? []) h({ targetId: tab.targetId, url: request.url(), reason });
      return true;
    }
    return false;
  }
  async function setContentRules(rules) {
    contentRules = rules.map((r) => ({ re: new RegExp(r.trigger["url-filter"], "i"), types: r.trigger["resource-type"] || null, child: (r.trigger["load-context"] || []).includes("child-frame"), type: r.action.type }));
    if (routed || !contentRules.length) return;
    routed = true;
    await context.route("**/*", (route, request) => {
      const isDocument = request.resourceType() === "document";
      if (isDocument && request.frame().parentFrame() === null) return cancelsNavigation(request) ? route.abort("blockedbyclient") : route.fallback();
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
    "tabs.list": async (_params, driver) =>
      Promise.all([...tabs.values()].map(async (t) => {
        const owner = ownerRefusing(t, driver);
        return {
          targetId: t.targetId,
          title: await t.page.title().catch(() => ""),
          url: t.page.url(),
          active: t.targetId === activeTarget,
          windowId: 1,
          // Another live session's tab: its owner, never its data store.
          ...(owner ? { ownerSession: owner.sessionId } : { dataStore: DATA_STORE }),
          ...(t.openerTargetId ? { openerTargetId: t.openerTargetId } : {}),
        };
      })),
    // One Playwright context, so one data store for every tab.
    "tabs.dataStore": async ({ targetId } = {}) => {
      if (targetId !== undefined) tabFor(targetId);
      return { dataStore: DATA_STORE };
    },
    "tabs.open": async ({ url, background, dataStore }, driver) => {
      if (dataStore !== undefined && dataStore !== DATA_STORE) throw new DriverError("invalid", `tabs.open: no open tab uses data store ${JSON.stringify(dataStore)}`);
      const page = await context.newPage();
      const tab = register(page);
      tab.blankStart = !url;
      tab.creator = driver;
      await guardPageClipboard(tab);
      driver.opened.add(tab.targetId);
      if (!background) activeTarget = tab.targetId;
      if (url) await page.goto(url, { waitUntil: "commit" });
      return { targetId: tab.targetId };
    },
    "tab.handleEvents": async ({ targetId, events }, driver) => {
      const known = ["dialog", "filechooser", "download", "network"];
      if (!Array.isArray(events) || events.some((e) => !known.includes(e))) {
        throw new DriverError("invalid", `tab.handleEvents: events must be an array of ${known.join(", ")}`);
      }
      tabFor(targetId).handled.set(driver, new Set(events));
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
    "input.mouse": async ({ targetId, type, x, y, button = "left", clickCount = 1, modifiers, deltaX = 0, deltaY = 0, expect }, driver) => {
      const tab = tabFor(targetId);
      const page = tab.page;
      // As the app's driver: a press that names its target is sent only
      // while the target, and each parent frame's <iframe>, is still at
      // the point (BrowserReplPressTarget).
      if (type === "down" && expect) await checkPress(targetId, expect, x, y);
      if (type === "down") tab.heldButtons.set(button, driver);
      if (type === "up") tab.heldButtons.delete(button);
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
    "input.key": async ({ targetId, ...event }, driver) => {
      const tab = tabFor(targetId);
      const held = event.code || event.key;
      if (event.type === "down") tab.heldKeys.set(held, { key: event.key, code: event.code, driver });
      else tab.heldKeys.delete(held);
      await keyEvent(tab, event);
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
    "input.insertText": async ({ targetId, text, secretName, secretDomains }, driver) => {
      const tab = tabFor(targetId);
      if (secretName) {
        // As BrowserReplSecretTarget.tabRefusal: only the typing session's own tab.
        if (!(tab.creator === driver && drivers.has(driver))) {
          throw new DriverError("invalid", `secret ${JSON.stringify(secretName)} is typed only into a tab this session opened (tabs.open), where its domain policy keeps the page from sending it elsewhere; this tab is ${tab.creator && drivers.has(tab.creator) ? "another session's" : "the user's"}`);
        }
        // As the app's driver: the frame that has focus must be on one of
        // the secret's domains, by its own origin.
        let focused = tab.page.mainFrame();
        for (const f of tab.page.frames()) {
          const own = await f.evaluate(() => document.hasFocus() && !!document.activeElement && !/^(IFRAME|FRAME)$/.test(document.activeElement.tagName)).catch(() => false);
          if (own) focused = f;
        }
        const origin = new URL(focused.url()).origin;
        const T = loadRuntime().agentTools;
        if (!secretDomains.some((d) => T.urlMatches(origin + "/", d, true))) {
          throw new DriverError("invalid", `secret ${JSON.stringify(secretName)} may not be typed into ${origin}; its domains are ${secretDomains.map((d) => d.raw).join(", ")}`);
        }
      }
      await tab.page.keyboard.insertText(text);
    },
    // As the app's driver: `expect` binds the press to the source and
    // `dropExpect` the release to the target (input.mouse's check); a
    // target that changed gets no drop (the release goes back to the press
    // point, where the drag started).
    "input.drag": async ({ targetId, path: points, button = "left", modifiers, expect, dropExpect }) => {
      const page = tabFor(targetId).page;
      const first = points[0];
      const last = points[points.length - 1];
      await withModifiers(page, modifiers, async () => {
        await page.mouse.move(first.x, first.y);
        if (expect) await checkPress(targetId, expect, first.x, first.y);
        await page.mouse.down({ button });
        for (const p of points.slice(1)) await page.mouse.move(p.x, p.y, { steps: 5 });
        if (dropExpect) {
          try {
            await checkPress(targetId, dropExpect, last.x, last.y);
          } catch (e) {
            await page.mouse.move(first.x, first.y, { steps: 5 });
            await page.mouse.up({ button });
            if (e instanceof DriverError && e.code === "stale") {
              throw new DriverError("stale", e.message.replace(/^no press was sent: /, "no drop was made: ").replace("when the press was about to be sent", "when the drop was about to be made"));
            }
            throw e;
          }
        }
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
    "tab.screenshot": async ({ targetId, clip, fullPage, format = "png", quality, secretMasks }) => {
      const type = format === "jpeg" ? "jpeg" : "png";
      const page = tabFor(targetId).page;
      return withSecretMasks(page, secretMasks, async () => {
        const buf = await page.screenshot({ clip, fullPage, type, quality: type === "jpeg" ? quality : undefined });
        return { base64: buf.toString("base64"), ...pngSize(buf) };
      });
    },
    "tab.pdf": async ({ targetId, secretMasks }) => {
      const page = tabFor(targetId).page;
      return withSecretMasks(page, secretMasks, async () => {
        const text = await page.evaluate(() => document.body ? document.body.innerText : "");
        return { base64: textPdf(text).toString("base64") };
      });
    },
    // The session's domain policy covers cookies as in the app: blocked
    // URLs are refused and blocked sites' cookies are never listed, set or
    // cleared (driver.cookieBlockReason, from the native-boundary emulation).
    "cookies.get": async ({ urls } = {}, driver) => {
      for (const url of urls || []) {
        const reason = driver.blockReason && driver.blockReason(url);
        if (reason) throw new DriverError("blocked", `cookies.get: ${url} is blocked: ${reason}`);
      }
      // Matched as the app's driver does (cookieMatchesURL), not by
      // Playwright's URL filter, which sends Secure cookies over http only
      // to localhost.
      const all = await context.cookies();
      const matched = urls && urls.length ? all.filter((c) => urls.some((u) => cookieMatchesURL(c, u))) : all;
      return matched.filter((c) => !(driver.cookieBlockReason && driver.cookieBlockReason(c.domain)));
    },
    "cookies.set": async ({ cookies }, driver) => {
      for (const c of cookies || []) {
        const reason = driver.blockReason && c.url ? driver.blockReason(c.url) : null;
        if (reason) throw new DriverError("blocked", `cookies.set: ${c.url} is blocked: ${reason}`);
        const domain = c.domain || (c.url ? new URL(c.url).hostname : "");
        const check = driver.cookieSetBlockReason || driver.cookieBlockReason;
        const cookieReason = check && check(domain);
        if (cookieReason) throw new DriverError("blocked", `cookies.set: a cookie on ${domain} is blocked: ${cookieReason}`);
      }
      return context.addCookies(cookies);
    },
    // Scoped as in the app, where tabs use the user's profile: the driver
    // clears the site (registrable domain) of the target tab, else the
    // active tab, whatever site the caller names, narrowed by exact name,
    // domain and path. A tab with no site and { all: true } are refused.
    "cookies.clear": async ({ targetId, all, name, domain, path } = {}, driver) => {
      if (all) throw new DriverError("invalid", "cookies.clear: { all: true } would clear every site in the user's browser profile, which a session may not do; clear the current tab's site instead (a private tab's store, or one from session.configure({ proxy }), may be cleared whole)");
      if (domain && driver.cookieBlockReason && driver.cookieBlockReason(domain)) throw new DriverError("blocked", `cookies.clear: ${domain} is blocked: ${driver.cookieBlockReason(domain)}`);
      const tab = targetId ? tabFor(targetId) : tabs.get(activeTarget);
      const url = tab ? tab.page.url() : "";
      const site = /^https?:/i.test(url) ? siteOf(new URL(url).hostname) : null;
      if (!site) throw new DriverError("invalid", `cookies.clear: the tab (${url || "none"}) has no site to scope to; open the site first`);
      for (const c of await context.cookies()) {
        const host = String(c.domain).toLowerCase().replace(/^\.+/, "");
        if (host !== site && !host.endsWith("." + site)) continue;
        if (driver.cookieBlockReason && driver.cookieBlockReason(c.domain)) continue;
        if ((name && c.name !== name) || (domain && c.domain !== domain) || (path && c.path !== path)) continue;
        await context.clearCookies({ name: c.name, domain: c.domain, path: c.path });
      }
    },
    // As in the app (BrowserReplTabClipboard): the tab's clipboard is its
    // live creator's alone; a user's tab has none for sessions.
    "clipboard.read": async ({ targetId }, driver) => ({ items: ownClipboard(tabFor(targetId), driver).clipboard }),
    "clipboard.write": async ({ targetId, items }, driver) => {
      ownClipboard(tabFor(targetId), driver).clipboard = items;
    },
  };

  // Captures hide secrets as the app's driver does (BrowserReplCaptureMask):
  // in frames whose origin is on a secret's domains (the only frames it can
  // be typed into), fields and text holding its value render as password
  // dots for the length of the capture. Other frames never receive a value.
  // Each capture restores only the elements it masked, so one capture ending
  // does not unmask another's. It fails closed: the capture is refused
  // (`invalid`) when the mask step fails in one of those frames, or when a
  // scan after the capture finds a value rendered unmasked. Playwright
  // evaluates in the page's world, so closed shadow roots, which the app's
  // mask world sees, are not reached here.
  async function withSecretMasks(page, masks, capture) {
    if (!masks || !masks.length) return capture();
    const T = loadRuntime().agentTools;
    const token = crypto.randomUUID();
    const targets = () =>
      page
        .frames()
        .map((f) => {
          let origin = "";
          try {
            origin = new URL(f.url()).origin;
          } catch {}
          return { f, origin, values: masks.filter((m) => m.domains.some((d) => T.urlMatches(origin + "/", d, true))).map((m) => m.value) };
        })
        .filter((t) => t.values.length);
    const MASK = ([values, mode, token]) => {
      const key = Symbol.for("cmux.dev.secretMask");
      const state = (globalThis[key] ||= { counts: new Map(), captures: new Map() });
      const prop = "-webkit-text-security";
      if (mode === "off") {
        const masked = state.captures.get(token) || [];
        state.captures.delete(token);
        for (const el of masked) {
          const entry = state.counts.get(el);
          if (!entry || --entry.count > 0) continue;
          state.counts.delete(el);
          if (entry.value) el.style.setProperty(prop, entry.value, entry.priority);
          else el.style.removeProperty(prop);
        }
        return 0;
      }
      const hits = new Set();
      const has = (t) => typeof t === "string" && values.some((v) => t.includes(v));
      const visit = (root) => {
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
        for (let n = walker.currentNode; n; n = walker.nextNode()) {
          if (n.nodeType === 3) {
            if (n.parentElement && has(n.data)) hits.add(n.parentElement);
            continue;
          }
          if ((n instanceof HTMLInputElement && n.type !== "password") || n instanceof HTMLTextAreaElement) {
            if (has(n.value)) hits.add(n);
          }
          if (n.shadowRoot) visit(n.shadowRoot);
        }
      };
      visit(document.documentElement || document);
      if (mode === "on") {
        const styled = (el) => {
          for (let n = el; n; n = n.parentElement || (n.parentNode && n.parentNode.host) || null) {
            if (n.style instanceof CSSStyleDeclaration) return n;
          }
          return null;
        };
        const masked = state.captures.get(token) || new Set();
        state.captures.set(token, masked);
        for (const hit of hits) {
          const el = styled(hit);
          if (!el || masked.has(el)) continue;
          masked.add(el);
          const entry = state.counts.get(el);
          if (entry) entry.count++;
          else {
            state.counts.set(el, { count: 1, value: el.style.getPropertyValue(prop), priority: el.style.getPropertyPriority(prop) });
            el.style.setProperty(prop, "disc", "important");
          }
        }
      }
      let unmasked = 0;
      for (const el of hits) if (getComputedStyle(el).getPropertyValue(prop) === "none") unmasked++;
      return unmasked;
    };
    const refused = (message) => new DriverError("invalid", `the capture was refused: ${message}; try again`);
    const step = async ({ f, origin, values }, mode) => {
      let unmasked;
      try {
        unmasked = await f.evaluate(MASK, [values, mode, token]);
      } catch (e) {
        throw refused(`secrets could not be masked in ${origin} (${e.message})`);
      }
      if (unmasked !== 0) throw refused(mode === "verify" ? `the page in ${origin} showed a secret unmasked while it was taken` : `a secret in ${origin} could not be masked`);
    };
    const masked = [];
    try {
      for (const t of targets()) {
        masked.push(t);
        await step(t, "on");
      }
      const value = await capture();
      for (const t of targets()) await step(t, "verify");
      return value;
    } finally {
      for (const { f } of masked) await f.evaluate(MASK, [[], "off", token]).catch(() => {});
    }
  }

  // Reads and input on a tab whose page the session's policy blocks are
  // refused, as the app's driver does.
  // Of the cookie calls only cookies.clear takes its scope from the page.
  const GUARDED = /^(frame\.evaluate|input\.|tab\.screenshot|tab\.pdf|clipboard\.|filechooser\.respond|cookies\.clear$)/;
  // The session's own input, script and navigations (WebKitBrowserReplDriver.isActionOnPage).
  const ACTIONS = /^(input\.|frame\.evaluate$|tab\.navigate$|tab\.reload$|tab\.history$)/;
  const NAVIGATIONS = /^tab\.(navigate|reload|history)$/;

  function createDriver({ sessionId = `dev-${nextId++}` } = {}) {
    const driver = {
      name: "dev",
      sessionId,
      listeners: new Map(),
      opened: new Set(),
      sessionName: null,
      blockReason: null,
      cookieBlockReason: null,
      policyFailure: null,
      // Called by the native-boundary emulation, never by the runtime. As
      // WebKit does, rules with a non-ASCII url-filter do not compile; then
      // every call fails until a policy that compiles replaces them.
      async setDomainPolicy(policy, blockReason, cookieBlockReason, cookieSetBlockReason) {
        driver.cookieSetBlockReason = policy.allowed || policy.prohibited.length || policy.blockIPs ? cookieSetBlockReason || null : null;
        const rules = loadRuntime().agentTools.policyContentRules(policy);
        const bad = rules.find((r) => /[^\x00-\x7f]/.test(r.trigger["url-filter"]));
        if (bad) {
          driver.policyFailure = new DriverError("invalid", `the domain policy could not be applied: WebKit refused its content rules (contentRules: Only ASCII characters are supported in pattern ${bad.trigger["url-filter"]}); set a policy that compiles (session.allowedDomains, session.prohibitedDomains, session.blockIPAddresses), or reset the session if the policy is locked`);
          return;
        }
        driver.policyFailure = null;
        const active = !!(policy.allowed || policy.prohibited.length || policy.blockIPs);
        driver.blockReason = active ? blockReason : null;
        driver.cookieBlockReason = active ? cookieBlockReason || null : null;
        await setContentRules(rules);
      },
      async call(method, params = {}) {
        const fn = methods[method];
        if (!fn) throw new DriverError("unsupported", `Unsupported driver method ${method}`);
        if (driver.policyFailure) throw driver.policyFailure;
        // As the app's driver: a tab another live session created is that
        // session's alone.
        const owned = params.targetId && tabs.get(params.targetId);
        const owner = owned && ownerRefusing(owned, driver);
        if (owner) {
          throw new DriverError("denied", `the tab ${params.targetId} belongs to the REPL session "${owner.sessionId}", which is still running; a session drives only the tabs it opened and the user's tabs (tabs.list({ all: true }) shows each tab's owner)`);
        }
        if (driver.blockReason && params.targetId && GUARDED.test(method) && tabs.has(params.targetId)) {
          const url = tabs.get(params.targetId).page.url();
          const reason = driver.blockReason(url);
          if (reason) throw new DriverError("blocked", `the tab shows ${url}, which the domain policy blocks: ${reason}`);
        }
        const tab = params.targetId && tabs.get(params.targetId);
        // The runtime's own agent-world reads are not the session's action.
        if (!tab || !ACTIONS.test(method) || (method === "frame.evaluate" && params.world !== "page")) return fn(params, driver);
        tab.inputDrivers.push(driver);
        let ended = false;
        const end = () => {
          if (ended) return;
          ended = true;
          tab.inputDrivers.splice(tab.inputDrivers.lastIndexOf(driver), 1);
        };
        // As in the app, a navigation is the session's action until it
        // commits; a dialog while the new page loads is not.
        const navigation = NAVIGATIONS.test(method);
        const onCommit = (frame) => { if (frame === tab.page.mainFrame()) end(); };
        if (navigation) tab.page.on("framenavigated", onCommit);
        // As in the app, a page script holds the window for at most a second.
        const bound = method === "frame.evaluate" ? setTimeout(end, 1000) : null;
        try {
          const result = await fn(params, driver);
          // Like the app's round trip after input: what the page opened while
          // it handled the input (a file chooser) is reported before the
          // input counts as done.
          if (method === "input.mouse" || method === "input.key") await tab.page.evaluate(() => 0).catch(() => {});
          return result;
        } finally {
          if (navigation) tab.page.off("framenavigated", onCommit);
          if (bound) clearTimeout(bound);
          end();
        }
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
        for (const tab of tabs.values()) {
          tab.handled.delete(driver);
          // What the creating session put in the tab's clipboard ends with it.
          if (tab.creator === driver) tab.clipboard = [];
          // Keys and buttons this session left pressed are released, last
          // pressed first, so the page sees keyup and mouseup.
          for (const [held, k] of [...tab.heldKeys].reverse()) {
            if (k.driver !== driver) continue;
            tab.heldKeys.delete(held);
            await keyEvent(tab, { type: "up", key: k.key, code: k.code }).catch(() => {});
          }
          for (const [button, owner] of [...tab.heldButtons].reverse()) {
            if (owner !== driver) continue;
            tab.heldButtons.delete(button);
            await tab.page.mouse.up({ button }).catch(() => {});
          }
        }
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

// Session temporary directories this process made (createNodeHost). A test
// that does not remove its own leaves it until the process exits, when they
// go; only directories made here are ever removed (test-dirs.mjs).
const hostTemporaryDirectories = new Set();
process.on("exit", () => {
  for (const dir of hostTemporaryDirectories) {
    try {
      removeTestDir(dir);
    } catch {}
  }
});

// Whether a cookie goes with a request to `url`, as the app's
// HTTPCookie.browserReplMatches: a host-only cookie (no leading dot) to its
// exact host, a Domain cookie to the domain and its subdomains (never an IP
// address by suffix), RFC 6265 path-match, and a Secure cookie only over
// https or to a loopback host (localhost and its subdomains, [::1], an
// address in 127.0.0.0/8).
export function cookieMatchesURL(cookie, url) {
  let u;
  try {
    u = new URL(url);
  } catch {
    return false;
  }
  const host = u.hostname.toLowerCase();
  const domain = String(cookie.domain || "").toLowerCase();
  const isIP = /^\[.*\]$/.test(host) || /^\d+\.\d+\.\d+\.\d+$/.test(host);
  if (domain.startsWith(".")) {
    const bare = domain.slice(1);
    if (host !== bare && (isIP || !host.endsWith("." + bare))) return false;
  } else if (host !== domain) return false;
  const cookiePath = cookie.path || "/";
  const sent = u.pathname || "/";
  if (!sent.startsWith(cookiePath)) return false;
  if (sent.length !== cookiePath.length && !cookiePath.endsWith("/") && sent[cookiePath.length] !== "/") return false;
  return !cookie.secure || u.protocol === "https:" || isLoopbackHost(host);
}

function isLoopbackHost(host) {
  if (host === "localhost" || host.endsWith(".localhost") || host === "[::1]") return true;
  const parts = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  return !!parts && parts[1] === "127" && parts.slice(2).every((p) => Number(p) <= 255);
}

// Host capabilities the app provides natively (driver-protocol.md, "Native
// host contract").
export function createNodeHost({ workDir, sessionId = "dev", print, readable = new Set() }) {
  // As the app: the session's own private temporary directory,
  // <tmp>/cmux-browser-repl/<session>-<random>-tmp, mode 0700.
  const safeID = String(sessionId).slice(0, 64).replace(/[^A-Za-z0-9_-]/g, "_");
  const tmpdir = makeTestDir(`${safeID}-`, { parent: path.join(os.tmpdir(), "cmux-browser-repl"), mode: 0o700 });
  hostTemporaryDirectories.add(tmpdir);
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
    // As the app's fetcher: every redirect hop is checked against the
    // domain policy (init.blockReason, from the native-boundary emulation)
    // and a body over 64 MiB fails.
    async fetch(url, init = {}) {
      let current = url;
      let method = init.method;
      let body = init.body === undefined ? undefined : Buffer.from(init.body, "base64");
      let res;
      for (let hop = 0; ; hop++) {
        res = await fetch(current, { method, headers: init.headers, body, redirect: "manual" });
        const location = res.status >= 300 && res.status < 400 && res.headers.get("location");
        if (!location || hop >= 20) break;
        const next = new URL(location, current).href;
        const reason = init.blockReason && init.blockReason(next);
        if (reason) throw Object.assign(new Error(`fetch: redirect to ${next} is blocked: ${reason}`), { code: "blocked" });
        if (res.status === 303 || ((res.status === 301 || res.status === 302) && method === "POST")) {
          method = "GET";
          body = undefined;
        }
        current = next;
      }
      const limit = init.maxBodyBytes || 64 * 1024 * 1024;
      if (Number(res.headers.get("content-length")) > limit) throw new Error(`fetch: the response body is larger than ${limit >> 20} MiB; download it in a tab (page.waitForEvent("download")) instead`);
      const bytes = Buffer.from(await res.arrayBuffer());
      if (bytes.length > limit) throw new Error(`fetch: the response body is larger than ${limit >> 20} MiB; download it in a tab (page.waitForEvent("download")) instead`);
      return { status: res.status, statusText: res.statusText, url: current, headers: Object.fromEntries(res.headers), base64: bytes.toString("base64"), redirected: current !== url };
    },
  };
}

// A REPL session on the dev backend, with the native session's guards
// (secrets, domain policy, redaction) emulated around the host and driver,
// as the app's BrowserReplSession puts them around its JavaScriptCore
// context. Use it wherever the app would run a session.
export function createDevRepl({ host, driver }) {
  const ns = loadRuntime();
  const boundary = createBoundary(ns.agentTools, { now: () => (host.now ? host.now() : Date.now()) });
  const repl = ns.replHost.createBrowserRepl({ host: boundary.wrapHost(host), driver: boundary.wrapDriver(driver) });
  return {
    ...repl,
    boundary,
    async evaluate(code, options) {
      const r = await repl.evaluate(code, options);
      if (!r.ok) {
        r.error = boundary.redact(r.error);
        if (r.exception instanceof Error) {
          try {
            r.exception.message = boundary.redact(r.exception.message);
          } catch {}
        }
      }
      return r;
    },
  };
}

// Runs REPL cells the way `cmux browser repl` runs calls: every cell is a
// one-shot session unless it names a session, and one-shot sessions close
// the tabs they opened unless kept. Returns each cell's printed output and
// uncaught error.
export async function runDevCells(cells, { workDir } = {}) {
  const ns = loadRuntime();
  const dir = fs.realpathSync(workDir ?? makeTestDir("cmux-repl-"));
  const browser = await createDevBrowser();
  const named = new Map();
  const readable = new Set();
  const outputs = [];
  const hosts = [];
  try {
    for (const cell of cells) {
      const lines = [];
      const print = (level, text) => lines.push(text);
      let entry = cell.session ? named.get(cell.session) : null;
      if (!entry) {
        const driver = browser.driver({ sessionId: cell.session || `oneshot-${outputs.length + 1}` });
        driver.on("download.finished", (p) => p.path && readable.add(fs.realpathSync(p.path)));
        let current = print;
        const host = createNodeHost({ workDir: dir, sessionId: cell.session || `oneshot-${outputs.length + 1}`, print: (l, t) => current(l, t), readable });
        hosts.push(host);
        entry = { driver, repl: createDevRepl({ host, driver }), setPrint: (p) => (current = p) };
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
    if (!workDir) removeTestDir(dir);
    // As the app at session close: a session's temporary directory goes
    // only when nothing is left in it.
    for (const host of hosts) removeTestDirIfEmpty(host.tmpdir);
  }
  return outputs;
}

export async function runDevRepl(code, options) {
  const [r] = await runDevCells([{ code }], options);
  return r.error ? `${r.output}\nUncaught ${r.error}`.replace(/^\n/, "") : r.output;
}
