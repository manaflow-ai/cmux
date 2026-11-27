// A REPL session drives the tabs it created and the user's tabs, never a tab
// another live session created (docs/browser-repl/README.md, Sessions and
// tabs). The driver refuses it by creator, naming the owner; tabs.list({ all })
// lists such a tab as the other session's. A tab's clipboard ends with its
// creating session, and network events carry credential headers only to
// the tab's creator. Runs on Playwright WebKit through the dev driver.
//
//   node --test tests/browser-parity/unit/session-isolation.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { createDevBrowser, runDevCells } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";

const text = (s) => [{ type: "text/plain", base64: Buffer.from(s).toString("base64") }];

test("a session cannot drive a tab another live session created", async () => {
  const browser = await createDevBrowser();
  try {
    const a = browser.driver({ sessionId: "a" });
    const b = browser.driver({ sessionId: "b" });
    const { targetId } = await a.call("tabs.open", {});
    await a.call("clipboard.write", { targetId, items: text("a's secret") });

    const row = (await b.call("tabs.list", { all: true })).find((t) => t.targetId === targetId);
    assert.equal(row.ownerSession, "a", "listed as the other session's");
    assert.equal(row.dataStore, undefined, "without its data store");
    for (const [method, params] of [
      ["tab.info", {}],
      ["clipboard.read", {}],
      ["clipboard.write", { items: text("b") }],
      ["frame.evaluate", { source: "() => document.cookie", world: "page" }],
      ["input.key", { type: "press", key: "a" }],
      ["tab.navigate", { url: "about:blank", waitUntil: "commit", timeoutMs: 5000 }],
      ["tab.screenshot", {}],
      ["tabs.close", {}],
      ["tabs.dataStore", {}],
      ["cookies.get", {}],
    ]) {
      await assert.rejects(b.call(method, { targetId, ...params }), (e) => {
        assert.equal(e.code, "denied", `${method}: ${e.message}`);
        assert.match(e.message, /REPL session "a"/, method);
        return true;
      });
    }
    // The creator still drives it, and its clipboard is unchanged.
    assert.deepEqual((await a.call("clipboard.read", { targetId })).items, text("a's secret"));
  } finally {
    await browser.close();
  }
});

test("a kept tab has no clipboard for a later session", async () => {
  const browser = await createDevBrowser();
  try {
    const a = browser.driver({ sessionId: "a" });
    const { targetId } = await a.call("tabs.open", {});
    await a.call("clipboard.write", { targetId, items: text("a's secret") });
    await a.call("tab.keep", { targetId });
    await a.detach();

    // Once its creator ended, the tab is the user's: another session drives it.
    const c = browser.driver({ sessionId: "c" });
    const row = (await c.call("tabs.list", { all: true })).find((t) => t.targetId === targetId);
    assert.equal(row.ownerSession, undefined);
    // The tab is the user's: no session reads or writes a clipboard there,
    // so nothing passes from one session to another through it.
    for (const [method, params] of [["clipboard.read", {}], ["clipboard.write", { items: text("c") }]]) {
      await assert.rejects(c.call(method, { targetId, ...params }), (e) => {
        assert.equal(e.code, "unsupported", `${method}: ${e.message}`);
        assert.match(e.message, /refused in a user's tab/);
        return true;
      });
    }
  } finally {
    await browser.close();
  }
});

test("tabs.use on another live session's tab fails naming that session", async () => {
  const outputs = await runDevCells([
    { session: "a", code: `const t = await tabs.open(); console.log(JSON.stringify(t.id));` },
    {
      session: "b",
      code: `
const rows = await tabs.list({ all: true });
const row = rows.find((r) => r.ownedBy);
console.log(JSON.stringify({ ownedBy: row && row.ownedBy, use: await tabs.use(row.id).then(() => "attached", (e) => e.message) }));`,
    },
  ]);
  for (const [i, o] of outputs.entries()) assert.equal(o.error, null, `cell ${i + 1}: ${o.error}\n${o.output}`);
  const out = JSON.parse(outputs[1].output.trim().split("\n").at(-1));
  assert.equal(out.ownedBy, "a");
  assert.match(out.use, /REPL session "a"/);
});

test("network events show credential headers only to the tab's creator", async () => {
  const servers = await startFixtureServers();
  const { primary } = servers.origins;
  const request = () => `
const probe = page.waitForEvent("request", (r) => r.url().endsWith("/probe"));
await page.evaluate((u) => { fetch(u, { headers: { authorization: "Bearer token", "x-probe": "1" } }).catch(() => null); }, ${JSON.stringify(primary)} + "/probe");
const h = (await probe).headers();
console.log(JSON.stringify({ authorization: h.authorization || null, probe: h["x-probe"] || null }));`;
  try {
    const outputs = await runDevCells([
      // A one-shot run opens a tab and keeps it: the user's tab from then on.
      { code: `const t = await tabs.open(${JSON.stringify(primary)} + "/index.html?user"); await t.keep();` },
      // The creator of a tab sees its credentials.
      { session: "creator", code: `await tabs.open(${JSON.stringify(primary)} + "/index.html?own");${request()}` },
      // Another session driving the user's tab does not.
      { session: "agent", code: `await tabs.use((await tabs.list()).find((t) => t.url.endsWith("?user")).id);${request()}` },
    ]);
    for (const [i, o] of outputs.entries()) assert.equal(o.error, null, `cell ${i + 1}: ${o.error}\n${o.output}`);
    const last = (o) => JSON.parse(o.output.trim().split("\n").at(-1));
    assert.deepEqual(last(outputs[1]), { authorization: "Bearer token", probe: "1" });
    assert.deepEqual(last(outputs[2]), { authorization: null, probe: "1" });
  } finally {
    await servers.close();
  }
});

// In the app two sessions that drive one user's tab each have an agent world
// of their own, so one's code never reaches the other's agent, built-ins or
// DOM wrappers (BrowserReplSessionWorldTests runs that in real WebKit). The
// dev driver has no content worlds: every session's agent lives in the
// page's main world, where a session's patched built-ins (deref, mapGet
// below) do apply. Here the agent's own sealing must hold: its methods, its
// global, the ref engine, the handle resolver the driver uses, and the
// tables that bind refs and handles to elements.
test("another session's code in the agent world cannot redirect a session's refs and actions", async () => {
  const servers = await startFixtureServers();
  const { primary } = servers.origins;
  try {
    const tamper = `() => {
      const K = Symbol.for("cmux.browserRepl.agent");
      const a = globalThis[K];
      const decoy = document.getElementById("decoy");
      const forged = { ...a, snapshot: () => ({ nodes: ["forged"], max: 0 }), queryAll: () => [a.handleFor(decoy)], refState: () => ({ live: true, max: 0 }) };
      const tries = {
        methods: () => { a.snapshot = forged.snapshot; a.queryAll = forged.queryAll; if (a.snapshot !== forged.snapshot) throw 0; },
        redefine: () => Object.defineProperty(globalThis, K, { value: forged }),
        replace: () => { delete globalThis[K]; globalThis[K] = forged; if (globalThis[K] !== forged) throw 0; },
        engine: () => a.injected._engines.set("aria-ref", { queryAll: () => [decoy] }),
        resolver: () => Object.defineProperty(globalThis, "__cmuxPageAgent", { value: { resolveHandle: () => decoy } }),
        deref: () => { WeakRef.prototype.deref = function () { return decoy; }; },
        mapGet: () => { const get = Map.prototype.get; Map.prototype.get = function (k) { const v = get.call(this, k); return v && typeof v.deref === "function" ? new WeakRef(decoy) : v; }; },
      };
      const out = {};
      for (const [k, f] of Object.entries(tries)) { try { f(); out[k] = "applied"; } catch (e) { out[k] = "refused"; } }
      return out;
    }`;
    const outputs = await runDevCells([
      { code: `const t = await tabs.open(${JSON.stringify(primary)} + "/index.html?user"); await t.keep();` },
      {
        session: "a",
        code: `await tabs.use((await tabs.list()).find((t) => t.url.endsWith("?user")).id);
await page.evaluate(() => { document.body.innerHTML = '<button id="real" onclick="window.clicked = this.id">Real</button><button id="decoy" onclick="window.clicked = this.id">Decoy</button>'; });
globalThis.realRef = /button "Real" \\[ref=(e\\d+)\\]/.exec((await snapshot()).tree)[1];
console.log(realRef);`,
      },
      {
        session: "b",
        code: `await tabs.use((await tabs.list()).find((t) => t.url.endsWith("?user")).id);
console.log(JSON.stringify(await page._mainFrame._call("agent", ${JSON.stringify(tamper)}, [])));`,
      },
      {
        session: "a",
        code: `const tree = (await snapshot()).tree;
await page.ref(realRef).click();
console.log(JSON.stringify({ real: /button "Real"/.test(tree), forged: /forged/.test(tree), id: await page.ref(realRef).evaluate((el) => el.id), clicked: await page.evaluate(() => window.clicked) }));`,
      },
    ]);
    for (const [i, o] of outputs.entries()) assert.equal(o.error, null, `cell ${i + 1}: ${o.error}\n${o.output}`);
    const last = (o) => JSON.parse(o.output.trim().split("\n").at(-1));
    const tried = last(outputs[2]);
    for (const k of ["methods", "redefine", "replace", "engine", "resolver"]) assert.equal(tried[k], "refused", `${k}: ${JSON.stringify(tried)}`);
    assert.deepEqual(last(outputs[3]), { real: true, forged: false, id: "real", clicked: "real" });
  } finally {
    await servers.close();
  }
});
