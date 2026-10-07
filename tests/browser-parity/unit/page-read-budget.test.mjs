// Page reads that marshal page-controlled values to the session are bounded
// before they leave the page (classic Resources/browser-repl page-agent.js,
// the page-read budget): a hostile page can hold millions of nodes or one
// text of megabytes, and every read runs on the page's main thread and
// crosses to the session before any output limit applies. Each read stops at
// the same page-read budget (250,000 nodes, 2,000,000 characters, 8 s) and
// says it was cut. Where the agent cuts a page string it leaves a per-world
// cut marker; sealing the reply drops the text just before it, so a cut never
// ends inside a value the session masks. Ported from classic
// tests/browser-parity/unit/page-read-budget.test.mjs and
// page-reply-budget.test.mjs as the budget port lands. Runs on Playwright
// WebKit through the dev driver and the reference host.
//
//   node --test tests/browser-parity/unit/page-read-budget.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { loadRuntime, createDevBrowser, createNodeHost, createHostedRepl } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";
import { makeTestDir, removeTestDir } from "../lib/test-dirs.mjs";

const ns = loadRuntime();
const AGENT = 'globalThis[Symbol.for("cmux.browserRepl.agent")]';

// A REPL on the dev driver, on the fixture page, for one test. `run` returns
// the JSON a cell prints after "@@".
async function withRepl(fn) {
  const servers = await startFixtureServers();
  const dir = makeTestDir("cmux-repl-read-budget-");
  const browser = await createDevBrowser();
  const lines = [];
  const host = createNodeHost({ workDir: dir, sessionId: `read-budget-${process.pid}`, print: (level, text) => lines.push(text) });
  const repl = createHostedRepl(ns, { host, driver: browser.driver() }).repl;
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

// A page function run in the agent world, as agent-tools.js runs its reads.
const inAgent = (body) => `await page._mainFrame._call("agent", ${JSON.stringify(`() => { const A = ${AGENT}; ${body} }`)}, [])`;

test("A.budget: nodes, characters and the clock are charged; a caller can lower a bound, never raise it", async () => {
  await withRepl(async (run) => {
    const r = await run(`console.log("@@" + JSON.stringify(${inAgent(`
      const out = {};
      const nodes = A.budget({ maxNodes: 3 });
      out.spent = [nodes.spend(2), nodes.spend(2)];
      out.nodes = nodes.report();
      const size = A.budget({ maxSize: 10 });
      out.fits = size.fit("abcd");
      out.cut = size.fit("efghijklmnop");
      out.after = size.fit("q");
      out.size = size.report();
      const head = A.budget({ maxSize: 4 });
      out.head = head.head("0123456789");
      out.headLeft = head.sizeLeft;
      out.headTruncated = head.truncated;
      out.raised = A.budget({ maxNodes: 1e12, maxSize: 1e12 }).report();
      return out;`)}));`);
    assert.deepEqual(r.spent, [true, false], "the second spend passes the node budget");
    assert.deepEqual(r.nodes, { visited: 2, size: 0, maxNodes: 3, maxSize: 2000000, truncated: "nodes" });
    assert.equal(r.fits, "abcd");
    // A string cut at the budget ends in the cut marker, which sealing the
    // reply settles to "…" with the text before it dropped.
    assert.equal(r.cut, "…");
    assert.equal(r.after, "…", "an empty budget keeps nothing");
    assert.deepEqual(r.size, { visited: 0, size: 10, maxNodes: 250000, maxSize: 10, truncated: "size" });
    // head cuts before the caller normalizes; it does not charge.
    assert.equal(r.head, "…");
    assert.equal(r.headLeft, 4);
    assert.equal(r.headTruncated, "size");
    assert.equal(r.raised.maxNodes, 250000);
    assert.equal(r.raised.maxSize, 2000000);
  });
});

// The snapshot caps one name at 2,000 characters before it crosses to the
// session (a safety cap; the host decides how much to print). Secrets are
// masked after the reply leaves the page, by matching whole values: a name
// cut inside a secret would hand on its unmasked prefix.
test("snapshot: a name cut at the agent's cap never ends inside a value the session masks", async () => {
  const SECRET = "Zq9Wv7Kj";
  await withRepl(async (run) => {
    const r = await run(`
      secrets.set("k", ${JSON.stringify(SECRET)}, { domains: ["localhost", "127.0.0.1"] });
      await page.evaluate((secret) => {
        document.body.innerHTML = '<button id="b"></button><a id="a" href="/x"></a>';
        // The cap falls three characters into the secret.
        document.getElementById("b").textContent = "x".repeat(1996) + secret + "y".repeat(10);
        document.getElementById("a").setAttribute("aria-label", "x".repeat(1996) + secret + "y".repeat(10));
      }, ${JSON.stringify(SECRET)});
      const raw = await page._mainFrame._agent("snapshot", {});
      console.log("@@" + JSON.stringify({ raw: JSON.stringify(raw) }));
    `);
    assert.equal(r.raw.includes(SECRET.slice(0, 3)), false, `the agent reply holds the secret's prefix: …${r.raw.slice(r.raw.indexOf(SECRET.slice(0, 3)) - 20, r.raw.indexOf(SECRET.slice(0, 3)) + 20)}…`);
    assert.match(r.raw, /"name":"…"/, "the cut name settles to the cut note");
  });
});

// The page agent marks where it cut a page string with a marker that sealing
// settles. Page text cannot forge that marker: a page string that holds
// U+FDD0 (or any other character) reaches the session whole, with the text
// before it kept. (classic page-reply-budget.test.mjs)
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

// The bounded DOM readers (classic measureTree, boundedTextContent,
// boundedInnerText, boundedHTML): a getter builds its whole string before
// anything can cut it, so each reader first counts what the getter would
// read and, past the budget, builds the string node by node and stops there.
test("A.budget readers: textContent, innerText and HTML read whole within the budget, and stop at it past the budget", async () => {
  await withRepl(async (run) => {
    const r = await run(`console.log("@@" + JSON.stringify(${inAgent(`
      const out = {};
      document.body.innerHTML = '<div id="d"><p>alpha</p><p>beta <b>gamma</b> &amp; "q"</p><!--c--><br><span style="display:none">x</span></div>' +
        '<div id="big"></div><div id="deep"></div>';
      const d = document.getElementById("d");
      const whole = A.budget({});
      out.whole = [whole.textContent(d) === d.textContent, whole.innerText(d) === d.innerText, whole.innerHTML(d) === d.innerHTML, whole.outerHTML(d) === d.outerHTML];
      out.wholeCut = whole.truncated || null;
      const big = document.getElementById("big");
      for (let i = 0; i < 2000; i++) { const p = document.createElement("p"); p.textContent = "w".repeat(49) + " "; big.appendChild(p); }
      // 100,000 characters of text; a 60,000-character budget keeps what is
      // left after the cut margin (53,248 characters) is dropped.
      const sized = A.budget({ maxSize: 60000 });
      const text = sized.textContent(big);
      out.sizedLength = text.length;
      out.sizedEnd = text.slice(-1);
      out.sizedCut = sized.truncated;
      for (const [name, read] of [["textContent", "textContent"], ["innerText", "innerText"], ["innerHTML", "innerHTML"], ["outerHTML", "outerHTML"]]) {
        const b = A.budget({ maxNodes: 50 });
        b[read](big);
        out[name] = { cut: b.truncated, visited: b.report().visited };
      }
      const deep = document.getElementById("deep");
      let cur = deep;
      for (let i = 0; i < 20000; i++) { const c = document.createElement("i"); cur.appendChild(c); cur = c; }
      cur.textContent = "bottom";
      const nodes = A.budget({ maxNodes: 30000 });
      out.deepHTML = nodes.innerHTML(deep).length;
      out.deepCut = nodes.truncated || null;
      const small = A.budget({ maxNodes: 100 });
      out.deepText = small.textContent(deep);
      out.deepTextCut = small.truncated;
      return out;`)}));`);
    assert.deepEqual(r.whole, [true, true, true, true], "a read within the budget is the getter's exact string");
    assert.equal(r.wholeCut, null);
    assert.equal(r.sizedLength, 60000 - 53248 + 1);
    assert.equal(r.sizedEnd, "…");
    assert.equal(r.sizedCut, "size");
    for (const name of ["textContent", "innerText", "innerHTML", "outerHTML"]) {
      assert.equal(r[name].cut, "nodes", `${name} stops at the node budget`);
      assert.ok(r[name].visited <= 50, `${name} visited ${r[name].visited} nodes`);
    }
    assert.equal(r.deepHTML, 20000 * 7 + 6, "20,000 nested elements read without overflowing the stack");
    assert.equal(r.deepCut, null);
    assert.equal(r.deepText, "", "past the node budget the text read stops");
    assert.equal(r.deepTextCut, "nodes");
  });
});
