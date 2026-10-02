// Runs the browser REPL (cmux-tui/crates/cmux-browser-host/js, `sites` included) on the
// Playwright WebKit dev driver with every https request for a mock host
// answered by mock-sites.mjs: page loads and in-page fetches through
// Playwright routing, the REPL's native fetch through the same handler.
// Real sites are never contacted.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadRuntime, createDevBrowser, createNodeHost, createHostedRepl } from "../lib/dev-driver.mjs";
import { answer, createState, COOKIES, MOCK_HOSTS } from "./mock-sites.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const authFillSource = () => fs.readFileSync(path.join(here, "../../../cmux-tui/crates/cmux-browser-host/js/sites/auth-fill.js"), "utf8");

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
// the way the app's credential sheet would.
export async function createSitesEnv({ signedIn = true, authResponder } = {}) {
  const ns = loadRuntime();
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
  const workDir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cmux-sites-")));
  const sessions = new Map();

  // The REPL's native fetch: mock hosts only, redirects followed, cookies as sent by the runtime.
  async function mockFetch(url, init = {}) {
    let href = url;
    let method = init.method || "GET";
    let body = init.body === undefined ? "" : Buffer.from(init.body, "base64").toString("utf8");
    const headers = Object.fromEntries(Object.entries(init.headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
    for (let hop = 0; hop < 10; hop++) {
      if (!isMock(href)) throw new Error(`test fetch refused a non-mock URL: ${href}`);
      const cookies = await context.cookies([href]);
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
    driver.call = async (method, params) => {
      if (method !== "auth.request") return call(method, params);
      auth.push(params);
      if (!authResponder) return call(method, params);
      return authResponder(params, { call, context });
    };
    const repl = createHostedRepl(ns, { host, driver }).repl;
    const s = {
      repl,
      auth,
      lines,
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
    workDir,
    context: () => context,
    async close() {
      for (const s of sessions.values()) await s.close().catch(() => {});
      await browser.close();
      fs.rmSync(workDir, { recursive: true, force: true });
    },
  };
}

// Fills credential fields the way the app does after the user presses Fill:
// sites/auth-fill.js in the frame that holds them (the dev driver's agent
// world is the page world).
export function fillLike(values) {
  return async (params, { call }) => {
    const source = `async (__fields, __values) => { ${authFillSource()} }`;
    const raw = await call("frame.evaluate", { targetId: params.targetId, frameId: params.frameId, world: "page", source, args: [params.fields.map((f) => ({ id: f.id, marker: f.marker })), values], awaitPromise: true });
    return raw;
  };
}
