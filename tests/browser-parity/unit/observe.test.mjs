// Agent reads go through frame.observe (the host's read-only allowlist,
// browser lead contract 2026-10-04), so a lease never counts them as acts:
// snapshot, locator resolution, state checks and reads use frame.observe;
// acts (clicks, fills, focus) stay frame.evaluate. A host without
// frame.observe answers `unsupported` and the runtime falls back to
// frame.evaluate; a refusal (`forbidden`, observe_not_allowed) never falls
// back.
//
//   node --test tests/browser-parity/unit/observe.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { loadRuntime, createDevBrowser, createNodeHost, createHostedRepl } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";
import { makeTestDir, removeTestDir, removeTestDirIfEmpty } from "../lib/test-dirs.mjs";

const ns = loadRuntime();

// One session on the dev driver; `answer(method, params)` may replace the
// driver's reply (return undefined to pass the call on).
async function withSession(answer, fn) {
  const servers = await startFixtureServers();
  const browser = await createDevBrowser();
  const base = browser.driver();
  const calls = [];
  const driver = {
    name: base.name,
    async call(method, params) {
      calls.push({ method, params });
      const replaced = await answer(method, params);
      return replaced === undefined ? base.call(method, params) : replaced;
    },
    on: (event, handler) => base.on(event, handler),
    capabilities: () => (base.capabilities ? base.capabilities() : []),
    detach: () => base.detach(),
  };
  const dir = makeTestDir("observe-");
  const lines = [];
  const host = createNodeHost({ workDir: dir, sessionId: `observe-${process.pid}`, print: (level, text) => lines.push(text) });
  const { repl } = createHostedRepl(ns, { host, driver });
  try {
    await fn({ run: (code) => repl.evaluate(code), calls, lines, primary: servers.origins.primary });
  } finally {
    repl.dispose();
    await base.detach();
    await browser.close();
    await servers.close();
    removeTestDir(dir);
    removeTestDirIfEmpty(host.tmpdir);
  }
}

const agentEvaluates = (calls, method) =>
  calls.filter((c) => c.method === "frame.evaluate" && c.params.world === "agent" && c.params.args && c.params.args[0] === method);

test("agent reads use frame.observe; acts stay frame.evaluate", async () => {
  await withSession(() => undefined, async ({ run, calls, primary }) => {
    const r = await run(`
      await page.goto(${JSON.stringify(primary + "/")});
      await snapshot();
      console.log(await page.locator("#email").isVisible());
      await page.locator("#email").fill("me@x.com");
    `);
    assert.equal(r.ok, true, r.error);
    const observed = calls.filter((c) => c.method === "frame.observe").map((c) => c.params.method);
    assert.ok(observed.includes("snapshot"), JSON.stringify(observed));
    assert.ok(observed.includes("elementState") || observed.includes("checkStates"), JSON.stringify(observed));
    assert.equal(agentEvaluates(calls, "snapshot").length, 0, "snapshot never goes through frame.evaluate");
    assert.ok(agentEvaluates(calls, "fill").length > 0, "fill is an act: frame.evaluate");
    assert.ok(!observed.includes("fill") && !observed.includes("hitTarget"));
  });
});

test("a host without frame.observe gets frame.evaluate once it answers unsupported", async () => {
  const unsupported = (method) => {
    if (method === "frame.observe") throw Object.assign(new Error("Unsupported driver method frame.observe"), { code: "unsupported" });
  };
  await withSession(unsupported, async ({ run, calls, primary }) => {
    const r = await run(`await page.goto(${JSON.stringify(primary + "/")}); console.log(String(await snapshot()).length > 0); await snapshot();`);
    assert.equal(r.ok, true, r.error);
    assert.equal(agentEvaluates(calls, "snapshot").length, 2);
    // The session asks once, then goes straight to frame.evaluate.
    assert.equal(calls.filter((c) => c.method === "frame.observe").length, 1);
  });
});

test("a refused observe never falls back to frame.evaluate", async () => {
  const refused = (method) => {
    if (method === "frame.observe") throw Object.assign(new Error("frame.observe: snapshot is not available"), { code: "forbidden", errorName: "observe_not_allowed" });
  };
  await withSession(refused, async ({ run, calls, primary }) => {
    const r = await run(`await page.goto(${JSON.stringify(primary + "/")}); await snapshot();`);
    assert.equal(r.ok, false);
    assert.match(r.error, /not available/);
    assert.equal(agentEvaluates(calls, "snapshot").length, 0);
  });
});
