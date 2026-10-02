// The browser host boundary (plans/cmux-next/browser-host.md, section 4): the
// domain policy, the secret vault and output masking run in the host, below
// the agent's JS context. Agent code that skips the runtime's API (calls the
// driver directly) still meets the policy; a secret the user gives the host
// never enters the agent context; secret-bearing driver calls carry handles
// that only the host resolves.
//
// The host here is the Node reference host (lib/reference-host.mjs), which
// wraps the dev driver and the native host exactly where the Rust
// `cmux browser host` sits. The Rust host must pass the same checks.
//
//   node --test tests/browser-parity/unit/host-boundary.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { loadRuntime, createDevBrowser, createNodeHost, createHostedRepl } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";

const ns = loadRuntime();

async function withHosted(fn) {
  const servers = await startFixtureServers();
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cmux-repl-hb-")));
  const sessionId = `hb-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
  const browser = await createDevBrowser();
  const lines = [];
  const host = createNodeHost({ workDir: dir, sessionId, print: (level, text) => lines.push(text) });
  const hosted = createHostedRepl(ns, { host, driver: browser.driver() });
  const run = async (code) => {
    const start = lines.length;
    const r = await hosted.repl.evaluate(code);
    return { output: lines.slice(start).join("\n"), error: r.ok ? null : r.error };
  };
  try {
    await fn({ run, hosted, origins: servers.origins });
  } finally {
    hosted.repl.dispose();
    await browser.close();
    await servers.close();
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(path.join(fs.realpathSync(os.tmpdir()), "cmux-browser-repl", sessionId), { recursive: true, force: true });
  }
}

// Every string reachable from the agent's globals, own properties included.
const REACHABLE = `(() => {
  const seen = new Set();
  const strings = [];
  const walk = (o, depth) => {
    if (o === null || (typeof o !== "object" && typeof o !== "function") || seen.has(o) || depth > 7) return;
    seen.add(o);
    for (const k of Reflect.ownKeys(o)) {
      let v;
      try { v = Object.getOwnPropertyDescriptor(o, k).value; } catch { continue; }
      if (typeof v === "string") strings.push(v);
      else walk(v, depth + 1);
    }
  };
  for (const root of [globalThis, session, page, secrets, tabs]) walk(root, 0);
  return strings;
})()`;

test("a secret the user loads into the host never enters the agent context, yet types", async () => {
  const KEY = "Zq7-user-only-VALUE-31";
  await withHosted(async ({ run, hosted, origins }) => {
    hosted.loadUserSecret("apikey", KEY, { domains: ["localhost"] });
    let r = await run(`secrets.list()`);
    assert.equal(r.error, null);
    assert.match(r.output, /apikey/);
    r = await run(`
      await page.goto("${origins.primary}/agent-tools.html");
      await page.fill("#apikey", secret("apikey"));
      const typed = await page.evaluate(() => document.getElementById("apikey").value);
      const leaked = ${REACHABLE}.filter((s) => s.includes(${JSON.stringify(KEY.slice(0, 12))}));
      [typed, leaked.length]
    `);
    assert.equal(r.error, null);
    assert.match(r.output, /<secret:apikey>/);
    assert.match(r.output, /, 0 \]$/);
    assert.ok(!r.output.includes(KEY));
    assert.equal(await hosted.pageValue("#apikey"), KEY);
    assert.ok(hosted.vmDriverCalls().every((c) => !JSON.stringify(c).includes(KEY)), "a driver call from the agent context carried the value");
  });
});

test("the domain policy holds when agent code calls the driver directly", async () => {
  await withHosted(async ({ run, hosted, origins }) => {
    hosted.setBasePolicy({ allowed: ["http://localhost"], lock: true });
    let r = await run(`await page.goto("${origins.primary}/index.html"); page.url()`);
    assert.equal(r.error, null);
    r = await run(`await page._session.driver.call("tab.navigate", { targetId: page._targetId, url: "${origins.peer}/aria.html", waitUntil: "load", timeoutMs: 10000 })`);
    assert.match(r.error, /is blocked: not in session\.allowedDomains \(http:\/\/localhost\)/);
    r = await run(`await page._session.driver.call("tabs.open", { url: "${origins.peer}/aria.html", background: true })`);
    assert.match(r.error, /is blocked/);
    // The agent may narrow but never widen or unlock the user's policy.
    r = await run(`session.allowedDomains(null)`);
    assert.match(r.error, /locked/);
    // Subresource rules come from the host; the agent cannot clear them.
    const before = hosted.contentRules().length;
    assert.ok(before > 0);
    r = await run(`await page._session.driver.call("session.configure", { contentRules: [] })`);
    assert.equal(hosted.contentRules().length, before);
  });
});

test("the agent narrows the policy through the host; skipping the runtime does not skip it", async () => {
  await withHosted(async ({ run, origins }) => {
    let r = await run(`session.allowedDomains(["http://localhost"]); await page.goto("${origins.primary}/index.html"); page.url()`);
    assert.equal(r.error, null);
    r = await run(`await page._session.driver.call("tab.navigate", { targetId: page._targetId, url: "${origins.peer}/aria.html", waitUntil: "load", timeoutMs: 10000 })`);
    assert.match(r.error, /is blocked/);
    r = await run(`session.allowedDomains(null); await page.goto("${origins.peer}/aria.html"); page.url()`);
    assert.equal(r.error, null);
  });
});

test("secrets from agent code are agent-known; secret input reaches the driver as a handle", async () => {
  const PW = "agent known pw 9";
  await withHosted(async ({ run, hosted, origins }) => {
    const r = await run(`
      secrets.set("pw", ${JSON.stringify(PW)}, { domains: ["localhost"] });
      await page.goto("${origins.primary}/agent-tools.html");
      await page.locator("#pass").pressSequentially(secret("pw"));
      secrets.list()
    `);
    assert.equal(r.error, null);
    assert.match(r.output, /agentKnown: true/);
    assert.equal(await hosted.pageValue("#pass"), PW);
    const inputs = hosted.vmDriverCalls().filter((c) => c.method.startsWith("input.") || c.method === "frame.evaluate");
    assert.ok(inputs.some((c) => JSON.stringify(c.params).includes('{"__secret":"pw"}')), "no driver call carried the handle");
    assert.ok(inputs.every((c) => !JSON.stringify(c.params).includes(PW)), "a driver call from the agent context carried the value");
  });
});

test("a session with the raw CDP grant cannot type secrets", async () => {
  await withHosted(async ({ run, hosted, origins }) => {
    hosted.loadUserSecret("apikey", "cdp-grant-value-5", { domains: ["localhost"] });
    hosted.grantRawCdp();
    const r = await run(`await page.goto("${origins.primary}/agent-tools.html"); await page.fill("#apikey", secret("apikey"))`);
    assert.match(r.error, /locator\.fill: secret "apikey" cannot be typed in a session with raw CDP access/);
    assert.equal(await hosted.pageValue("#apikey"), "");
  });
});

// Review findings (2026-10-02): agent code can run any source in the agent
// world, so host-side page code must not run there or trust what it reports.
const AGENT = 'globalThis[Symbol.for("cmux.browserRepl.agent")]';
const agentEval = (source) => `await page._session.driver.call("frame.evaluate", { targetId: page._targetId, world: "agent", source: ${JSON.stringify(source)}, args: [], awaitPromise: true })`;

test("a patched page agent cannot capture a user secret through capture masking or fill", async () => {
  const KEY = "Zq7-patched-agent-VALUE-8";
  await withHosted(async ({ run, hosted, origins }) => {
    hosted.loadUserSecret("apikey", KEY, { domains: ["localhost"] });
    const r = await run(`
      await page.goto("${origins.primary}/agent-tools.html");
      ${agentEval(`() => { const a = ${AGENT}; a.maskSecrets = (v) => { globalThis.__x1 = btoa(JSON.stringify(v)); return 0; }; a.fill = (h, v) => { globalThis.__x2 = btoa(String(v)); return "done"; }; return true; }`)};
      await page.fill("#apikey", secret("apikey"));
      await page.screenshot();
      ${agentEval(`() => [globalThis.__x1 || "", globalThis.__x2 || ""]`)}
    `);
    assert.equal(r.error, null);
    for (const b64 of r.output.match(/'([A-Za-z0-9+/=]*)'/g) || []) {
      assert.ok(!Buffer.from(b64.slice(1, -1), "base64").toString("utf8").includes(KEY), "the patched agent got the value");
    }
    assert.equal(await hosted.pageValue("#apikey"), KEY);
  });
});

test("a spoofed focus report cannot send a user secret to another origin", async () => {
  const KEY = "Zq7-spoofed-focus-VALUE-4";
  await withHosted(async ({ run, hosted, origins }) => {
    hosted.loadUserSecret("apikey", KEY, { domains: ["localhost"] });
    const r = await run(`
      await page.goto("${origins.peer}/agent-tools.html");
      ${agentEval(`() => { const a = ${AGENT}; a.focusInfo = () => ({ url: "http://localhost/", activeIsFrame: false, activeEditable: true, hasFocus: true }); return true; }`)};
      await page.locator("#apikey").click();
      await page._session.driver.call("input.insertText", { targetId: page._targetId, text: secret("apikey") })
    `);
    assert.match(r.error || "", /may not be typed into http:\/\/127\.0\.0\.1/);
    assert.equal(await hosted.pageValue("#apikey"), "");
  });
});

test("the agent's allow list narrows the user's subresource rules; it never replaces them", async () => {
  await withHosted(async ({ run, hosted, origins }) => {
    await hosted.setBasePolicy({ allowed: ["http://localhost"] });
    const peerHost = new URL(origins.peer).host;
    let r = await run(`session.allowedDomains(["http://${peerHost}", "http://localhost"]); session.allowedDomains()`);
    assert.equal(r.error, null);
    assert.doesNotMatch(r.output, /127\.0\.0\.1/);
    r = await run(`
      await page.goto("${origins.primary}/agent-tools.html");
      await page.evaluate(async (peer) => {
        const load = (src) => new Promise((ok) => { const s = document.createElement("script"); s.onload = () => ok("loaded"); s.onerror = () => ok("blocked"); s.src = src; document.head.append(s); });
        return [await load("/log.js?own"), await load(peer + "/log.js?peer")];
      }, "${origins.peer}")
    `);
    assert.equal(r.error, null);
    assert.match(r.output, /'loaded', 'blocked'/);
  });
});

test("the host's objects expose no raw driver or host, and the host world is the host's", async () => {
  await withHosted(async ({ run, origins }) => {
    let r = await run(`[Object.getPrototypeOf(page._session.driver), Object.getPrototypeOf(page._session.host)]`);
    assert.equal(r.error, null);
    assert.match(r.output, /\[ null, null \]/);
    r = await run(`await page.goto("${origins.primary}/index.html"); await page._session.driver.call("frame.evaluate", { targetId: page._targetId, world: "host", source: "() => 1", args: [], awaitPromise: true })`);
    assert.match(r.error || "", /host world/);
  });
});

test("a proxy cannot be set while a domain policy is active", async () => {
  await withHosted(async ({ run, hosted }) => {
    await hosted.setBasePolicy({ allowed: ["http://localhost"] });
    const r = await run(`await page._session.driver.call("session.configure", { proxy: { server: "http://evil.example:8080" } })`);
    assert.match(r.error || "", /proxy cannot be set while a domain policy is active/);
  });
});
