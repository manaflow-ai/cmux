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

test("a kept tab's clipboard is empty for a later session", async () => {
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
    assert.deepEqual((await c.call("clipboard.read", { targetId })).items, []);
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
