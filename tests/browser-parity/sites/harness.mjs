// Runs the browser REPL (Resources/browser-repl, `sites` included) on the
// Playwright WebKit dev driver with every https request for a mock host
// answered by mock-sites.mjs: page loads and in-page fetches through
// Playwright routing, the REPL's native fetch through the same handler.
// Real sites are never contacted.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadRuntime, createDevBrowser, createNodeHost, createDevRepl } from "../lib/dev-driver.mjs";
import { answer, createState, COOKIES, MOCK_HOSTS } from "./mock-sites.mjs";
import { makeTestDir, removeTestDir, removeTestDirIfEmpty } from "../lib/test-dirs.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const authFillSource = () => fs.readFileSync(path.join(here, "../../../Resources/browser-repl/sites/auth-fill.js"), "utf8");

const isMock = (href) => {
  try {
    const u = new URL(href);
    return u.protocol === "https:" && MOCK_HOSTS.includes(u.hostname);
  } catch {
    return false;
  }
};

// Options: signedIn (default true) adds the site session cookies;
// authResponder(params, page) answers the native "auth.request" driver call
// the way the app's credential sheet would; gmailReplies (default false)
// turns on confirmed Gmail replies, which are off in source until their
// live check passes (sites/gmail.js), for tests of the reply path.
export async function createSitesEnv({ signedIn = true, authResponder, gmailReplies = false } = {}) {
  const ns = loadRuntime();
  const setGmailReplies = (on) => (ns.sites.shared.gmailReplies = { verified: !!on });
  setGmailReplies(gmailReplies);
  const state = createState();
  let context;
  const browser = await createDevBrowser({
    setupContext: async (ctx) => {
      context = ctx;
      await ctx.route((url) => isMock(url.href), async (route) => {
        const req = route.request();
        const headers = await req.allHeaders();
        // WebKit routing sees the request before cookies attach; attach the
        // profile's cookies for the URL as the browser would.
        if (!headers.cookie) headers.cookie = (await ctx.cookies([req.url()])).map((c) => `${c.name}=${c.value}`).join("; ");
        const r = answer(state, { method: req.method(), url: req.url(), headers, body: req.postDataBuffer() ? req.postDataBuffer().toString("utf8") : "" });
        // Playwright cannot fulfill a 3xx; a page load follows it from script instead.
        if (r.status >= 300 && r.status < 400 && r.headers.location) {
          await route.fulfill({ status: 200, headers: { "content-type": "text/html" }, body: `<!doctype html><script>location.replace(${JSON.stringify(new URL(r.headers.location, req.url()).href)})</script>` });
          return;
        }
        await route.fulfill({ status: r.status, headers: r.headers, body: Buffer.isBuffer(r.body) ? r.body : Buffer.from(String(r.body)) });
      });
      await ctx.route((url) => url.protocol === "https:" && !isMock(url.href), (route) => route.abort("blockedbyclient"));
      if (signedIn) await ctx.addCookies(COOKIES);
      // Linear's web client keeps the signed-in user in localStorage.
      const seed = await ctx.newPage();
      await seed.goto("https://linear.app/__seed");
      await seed.close();
    },
  });
  const workDir = makeTestDir("cmux-sites-");
  const sessions = new Map();

  // The REPL's native fetch: mock hosts only, redirects followed, the
  // profile's cookies per hop as BrowserReplFetcher sends them (`credentials`
  // include: every URL, same-origin: URLs on `origin`, omit: none).
  async function mockFetch(url, init = {}) {
    const credentials = init.credentials || "include";
    const sendsCookies = (href) => credentials === "include" || (credentials === "same-origin" && init.origin === new URL(href).origin);
    let href = url;
    let method = init.method || "GET";
    let body = init.body === undefined ? "" : Buffer.from(init.body, "base64").toString("utf8");
    const headers = Object.fromEntries(Object.entries(init.headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
    for (let hop = 0; hop < 10; hop++) {
      if (!isMock(href)) throw new Error(`test fetch refused a non-mock URL: ${href}`);
      const cookies = sendsCookies(href) ? await context.cookies([href]) : [];
      const h = { ...headers, cookie: cookies.map((c) => `${c.name}=${c.value}`).join("; ") };
      const r = answer(state, { method, url: href, headers: h, body });
      if ([301, 302, 303, 307, 308].includes(r.status) && r.headers.location) {
        href = new URL(r.headers.location, href).href;
        if (r.status !== 307 && r.status !== 308) (method = "GET"), (body = "");
        continue;
      }
      const bytes = Buffer.isBuffer(r.body) ? r.body : Buffer.from(String(r.body));
      return { status: r.status, statusText: "", url: href, headers: r.headers, base64: bytes.toString("base64"), redirected: hop > 0 };
    }
    throw new Error("too many redirects");
  }

  function session(name = "test") {
    if (sessions.has(name)) return sessions.get(name);
    const driver = browser.driver();
    const lines = [];
    const host = createNodeHost({ workDir, sessionId: name, print: (level, text) => lines.push(text) });
    host.fetch = mockFetch;
    host.fetchHandlesCookies = true;
    const call = driver.call.bind(driver);
    const auth = [];
    // s.intercept(fn): fn(method, params, call) sees every driver call
    // first and answers it when it returns something other than undefined
    // (a test standing in for a page that controls what its own world
    // returns, or that changes itself between two calls).
    let intercept = null;
    driver.call = async (method, params) => {
      if (intercept) {
        const r = await intercept(method, params, call);
        if (r !== undefined) return r;
      }
      if (method !== "auth.request") return call(method, params);
      auth.push(params);
      if (!authResponder) return call(method, params);
      return authResponder(params, { call, context });
    };
    const repl = createDevRepl({ host, driver });
    const s = {
      repl,
      auth,
      lines,
      intercept(fn) {
        intercept = fn || null;
      },
      // Evaluates code; returns { output, error, scope }.
      async run(code) {
        lines.length = 0;
        const r = await repl.evaluate(code, { maxOutput: 0 });
        return { output: lines.join("\n"), error: r.ok ? null : r.error, scope: repl.scope };
      },
      // Evaluates `expr` and returns its value (JSON round trip), throwing on error.
      async value(expr) {
        const r = await s.run(`const __v = await (async () => (${expr}))();`);
        if (r.error) throw new Error(r.error);
        return JSON.parse(JSON.stringify(repl.scope.__v === undefined ? null : repl.scope.__v));
      },
      // Evaluates `expr`, which must return a draft, confirms it and
      // returns the confirmed result (JSON round trip).
      async confirmed(expr) {
        return s.value(`(async () => { const __d = await (${expr}); if (!__d || __d.status !== "draft") throw new Error("expected a draft, got " + JSON.stringify(__d)); return sites[__d.site][__d.action](__d.id, { confirm: true }); })()`);
      },
      async error(expr) {
        const r = await s.run(`await (async () => (${expr}))();`);
        return r.error;
      },
    };
    s.close = async () => {
      repl.dispose();
      await driver.detach();
    };
    sessions.set(name, s);
    return s;
  }

  return {
    state,
    session,
    setGmailReplies,
    workDir,
    context: () => context,
    async close() {
      for (const s of sessions.values()) await s.close().catch(() => {});
      await browser.close();
      removeTestDir(workDir);
    },
  };
}

// Fills credential fields the way the app does: sites/auth-fill.js in the
// frame that holds them (the dev driver's agent world is the page world),
// once when the sheet is requested (phase "bind": it takes the marked
// elements and their document), then after the user presses Fill (phase
// "fill"), with the origin the sheet named as __origin. `origin` stands in
// for a frame that navigated elsewhere while the sheet was open;
// `meanwhile({ params, call })` runs while the sheet is up (another
// session or the page changing the page); `onBound(answer)` sees the bind
// phase's answer (its credential kinds label the app's sheet).
export function fillLike(values, { origin, meanwhile, onBound } = {}) {
  return async (params, { call }) => {
    const source = `async (__phase, __binding, __fields, __values, __origin) => { ${authFillSource()} }`;
    const fields = params.fields.map((f) => ({ id: f.id, type: f.type, marker: f.marker }));
    const binding = `binding-${Math.random().toString(36).slice(2)}`;
    const run = (phase, vals, from) => call("frame.evaluate", { targetId: params.targetId, frameId: params.frameId, world: "page", source, args: [phase, binding, fields, vals, from], awaitPromise: true });
    const bound = await run("bind", {}, params.origin);
    if (onBound) onBound(bound);
    if (bound && bound.status && bound.status !== "bound" && bound.status !== "filled") return bound;
    if (meanwhile) await meanwhile({ params, call });
    return run("fill", values, origin ?? params.origin);
  };
}
