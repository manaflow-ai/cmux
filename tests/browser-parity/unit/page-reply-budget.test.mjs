// Every reply the page agent's world sends to the session goes through one
// reply budget (page-agent.js `reply`, applied by runtime-core.js
// Frame._call to every agent-world call and by the host's frame.observe
// script to every read), and a reply past it fails with the page-read cut
// note (core.readCutNote). The test lists the agent's exports at run time:
// an export without a case below fails, and every export, called with the
// reply budget lowered to 0, must come back cut. Ported from classic
// tests/browser-parity/unit/page-reply-budget.test.mjs. Runs on Playwright
// WebKit through the dev driver and the reference host.
//
//   node --test tests/browser-parity/unit/page-reply-budget.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { loadRuntime, createDevBrowser, createNodeHost, createHostedRepl } from "../lib/dev-driver.mjs";

const ns = loadRuntime();
const createDevRepl = ({ host, driver }) => createHostedRepl(ns, { host, driver }).repl;
import { startFixtureServers } from "../lib/fixture-server.mjs";
import { makeTestDir, removeTestDir } from "../lib/test-dirs.mjs";

// How to call each export from the session: `agent` lists `_agent` arguments
// ("$t", "$u", "$input", "$select", "$frame" are handles of the fixture's
// elements); `world` is a page function run in the agent's world with the
// handles it names as its first arguments, for exports that take or return
// what only that world holds (elements, functions).
const CALLS = {
  ping: { agent: [] },
  handleFor: { world: "(el) => A.handleFor(el)", handles: ["$t"] },
  element: { agent: ["$t"] },
  snapshot: { agent: [{}] },
  stats: { agent: [] },
  refState: { agent: ["e1", 0] },
  refForHandle: { agent: ["$t", 0] },
  elementAt: { agent: [5, 5, 0] },
  splitFrames: { agent: ["div"] },
  queryAll: { agent: ["div"] },
  describe: { agent: ["$t"] },
  strictError: { agent: ["div", ["$t", "$u"]] },
  checkStates: { agent: ["$t", ["visible"]] },
  elementState: { agent: ["$t", "visible"] },
  scrollIntoViewIfNeeded: { agent: ["$t"] },
  rect: { agent: ["$t"] },
  clickPoint: { agent: ["$t"] },
  hitTarget: { agent: ["$t", { x: 1, y: 1 }, "button-link"] },
  emulateClickFocus: { agent: ["$input"] },
  activeHandle: { agent: [] },
  chooserHandle: { agent: [] },
  fill: { agent: ["$input", "x"] },
  selectText: { agent: ["$input"] },
  focus: { agent: ["$input"] },
  blur: { agent: ["$input"] },
  selectOptions: { agent: ["$select", [{ value: "a" }]] },
  dispatchEvent: { agent: ["$t", "click", {}] },
  retarget: { agent: ["$t", "follow-label"] },
  read: { agent: ["$t", "tagName"] },
  iframeHandles: { agent: [] },
  contentBox: { agent: ["$frame"] },
  annotate: { agent: [[["e1", "1"]]] },
  clearAnnotations: { agent: [] },
  budget: { world: "() => A.budget({})" },
  reply: { world: "() => A.reply('a reply', 0)" },
  adoptClosedRoot: { world: "(el) => A.adoptClosedRoot(el, null)", handles: ["$t"] },
};

test("every page agent export replies through the reply budget, and a reply past it is cut with the page-read note", async () => {
  const servers = await startFixtureServers();
  const dir = makeTestDir("cmux-repl-reply-budget-");
  const browser = await createDevBrowser();
  const lines = [];
  const host = createNodeHost({ workDir: dir, sessionId: `reply-budget-${process.pid}`, print: (level, text) => lines.push(text) });
  const repl = createDevRepl({ host, driver: browser.driver() });
  try {
    const r = await repl.evaluate(`
      const CALLS = ${JSON.stringify(CALLS)};
      await page.goto(${JSON.stringify(servers.origins.primary + "/")});
      await page.evaluate(() => {
        document.body.innerHTML = '<div id="t">t</div><div id="u">u</div><input id="i"><select id="s"><option value="a">a</option></select><iframe id="f"></iframe>';
      });
      const frame = page._mainFrame;
      const AGENT = 'globalThis[Symbol.for("cmux.browserRepl.agent")]';
      const names = await frame._call("agent", "() => { const A = " + AGENT + "; return Object.keys(A).filter((k) => typeof A[k] === 'function'); }", []);
      const handles = {};
      for (const [name, selector] of [["$t", "#t"], ["$u", "#u"], ["$input", "#i"], ["$select", "#s"], ["$frame", "#f"]]) {
        handles[name] = (await frame._agent("queryAll", selector))[0];
      }
      const resolve = (v) => typeof v === "string" && v in handles ? handles[v] : Array.isArray(v) ? v.map(resolve) : v;
      const outcomes = {};
      page._session._replyLimit = 0;
      try {
        for (const name of names) {
          const c = CALLS[name];
          if (!c) { outcomes[name] = "no case"; continue; }
          const call = c.world
            ? frame._call("agent", "(...a) => { const A = " + AGENT + "; return (" + c.world + ")(...a); }", [], (c.handles || []).map(resolve), name)
            : frame._call("agent", "(m, ...a) => " + AGENT + "[m](...a)", [name, ...resolve(c.agent)], [], name);
          outcomes[name] = await call.then((v) => "replied " + JSON.stringify(v), (e) => String(e.message || e));
        }
      } finally {
        page._session._replyLimit = undefined;
      }
      const pong = await frame._agent("ping");
      console.log("@@" + JSON.stringify({ names, outcomes, pong }));
    `);
    const output = lines.join("\n");
    assert.equal(r.ok, true, `${r.error}\n${output.slice(0, 2000)}`);
    const { names, outcomes, pong } = JSON.parse((lines.find((l) => l.startsWith("@@")) || "@@{}").slice(2));
    assert.ok(names.length >= Object.keys(CALLS).length, `the agent lists ${names.length} exports`);
    const missing = names.filter((n) => outcomes[n] === "no case");
    assert.deepEqual(missing, [], `exports without a case in CALLS (add one): ${missing.join(", ")}`);
    for (const name of names) {
      assert.match(outcomes[name], new RegExp(`the page is too large to read whole: ${name} stopped after 0 characters`), `${name}: ${String(outcomes[name]).slice(0, 300)}`);
    }
    assert.equal(pong, "pong", "the default budget lets a small reply through");
  } finally {
    repl.dispose();
    await browser.close();
    await servers.close();
    removeTestDir(dir);
    removeTestDir(host.tmpdir);
  }
});

// A REPL on the dev driver, on the fixture page, for one test.
async function withRepl(fn) {
  const servers = await startFixtureServers();
  const dir = makeTestDir("cmux-repl-reply-budget-");
  const browser = await createDevBrowser();
  const lines = [];
  const host = createNodeHost({ workDir: dir, sessionId: `reply-budget-${process.pid}`, print: (level, text) => lines.push(text) });
  const repl = createDevRepl({ host, driver: browser.driver() });
  const run = async (code) => {
    const start = lines.length;
    const r = await repl.evaluate(code);
    const output = lines.slice(start).join("\n");
    assert.equal(r.ok, true, `${r.error}\n${output.slice(0, 2000)}`);
    return JSON.parse((output.split("\n").find((l) => l.startsWith("@@")) || "@@null").slice(2));
  };
  try {
    await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});`);
    await fn(run);
  } finally {
    repl.dispose();
    await browser.close();
    await servers.close();
    removeTestDir(dir);
    removeTestDir(host.tmpdir);
  }
}

test("an agent reply past the default reply budget (10,000,000 characters) is cut with the page-read note", async () => {
  await withRepl(async (run) => {
    const r = await run(`
      await page.evaluate(() => { document.body.innerHTML = '<p id="big"></p>'; document.getElementById("big").textContent = "A".repeat(12000000); });
      const [h] = await page._mainFrame._agent("queryAll", "#big");
      const got = await page._mainFrame._agent("read", h, "textContent").then((v) => "replied " + v.length, (e) => String(e.message));
      console.log("@@" + JSON.stringify(got));
    `);
    assert.match(r, /the page is too large to read whole: read stopped after 10,000,000 characters/, String(r).slice(0, 300));
  });
});

test("queryAll makes and returns at most the page-read node budget of handles, and says it was cut", async () => {
  await withRepl(async (run) => {
    const r = await run(`
      await page.evaluate(() => { document.body.innerHTML = "<div></div>".repeat(300000); });
      const got = await page.locator("div").count().then((n) => "counted " + n, (e) => String(e.message));
      const kept = await page._mainFrame._call("agent", "() => " + 'globalThis[Symbol.for("cmux.browserRepl.agent")]' + ".stats().handles", []);
      console.log("@@" + JSON.stringify({ got, kept }));
    `);
    assert.match(r.got, /the page is too large to read whole: queryAll stopped after 250,000 nodes/, r.got.slice(0, 300));
    assert.ok(r.kept <= 250001, `the page agent made ${r.kept} handles`);
  });
});

// The page agent marks where it cut a page string with a marker that sealing
// settles (page-agent.js settleCuts). Page text cannot forge that marker: a
// page string that holds U+FDD0 (or any other character) reaches the session
// whole, with the text before it kept.
test("page text holding U+FDD0 is not taken for a cut marker", async () => {
  await withRepl(async (run) => {
    const r = await run(`
      const text = "head-" + "A".repeat(300) + "\\ufdd0" + "tail";
      await page.evaluate((text) => {
        document.body.innerHTML = '<button id="b"></button><input id="i"><p id="p"></p>';
        document.getElementById("b").textContent = text;
        document.getElementById("i").value = text;
        document.getElementById("p").textContent = text;
      }, text);
      const out = {};
      out.text = text;
      out.content = await page.locator("#p").textContent();
      out.value = await page.locator("#i").inputValue();
      out.tree = (await snapshot()).tree;
      console.log("@@" + JSON.stringify(out));
    `);
    assert.equal(r.content, r.text, "textContent keeps the text before U+FDD0");
    assert.equal(r.value, r.text, "inputValue keeps the text before U+FDD0");
    assert.ok(r.tree.includes("head-AAAA"), `the snapshot keeps the text before U+FDD0:\n${r.tree.slice(0, 600)}`);
  });
});
