// Page reads that marshal page-controlled values to the session are bounded
// before they leave the page (docs/browser-repl/README.md, Large output): a
// hostile page can hold millions of nodes or one text of megabytes, and
// every read below runs on the page's main thread and crosses to the
// session before any output limit applies. Each read stops at the same
// page-read budget as a snapshot (250,000 nodes, 2,000,000 characters,
// 8 s) and says it was cut. Runs on Playwright WebKit through the dev
// driver; the driver log records what each agent-world read returned.
//
//   node --test tests/browser-parity/unit/page-read-budget.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { createDevBrowser, createNodeHost, createDevRepl } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";
import { makeTestDir, removeTestDir } from "../lib/test-dirs.mjs";

const READ_SIZE = 2000000;

// A REPL on the dev driver whose driver calls are logged: for each
// agent-world frame.evaluate, the length of its JSON result; for each
// frame.contentFrames, how many elements it asked about.
async function withLoggedRepl(fn) {
  const dir = makeTestDir("cmux-repl-read-budget-");
  const browser = await createDevBrowser();
  const base = browser.driver();
  const log = [];
  const driver = new Proxy(base, {
    get(target, key) {
      if (key === "call") {
        return async (method, params = {}) => {
          const result = await target.call(method, params);
          if (method === "frame.evaluate" && params.world === "agent") log.push({ method, size: JSON.stringify(result === undefined ? null : result).length });
          if (method === "frame.contentFrames") log.push({ method, elements: (params.elements || []).length });
          return result;
        };
      }
      const value = target[key];
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  const lines = [];
  const host = createNodeHost({ workDir: dir, sessionId: `read-budget-${process.pid}`, print: (level, text) => lines.push(text) });
  const repl = createDevRepl({ host, driver });
  const run = async (code) => {
    const start = lines.length;
    log.length = 0;
    const r = await repl.evaluate(code);
    const output = lines.slice(start).join("\n");
    assert.equal(r.ok, true, `${r.error}\n${output.slice(0, 2000)}`);
    return { output, log: log.slice(), value: (output.split("\n").find((l) => l.startsWith("@@")) || "").slice(2) };
  };
  try {
    await fn(run);
  } finally {
    repl.dispose();
    await browser.close();
    removeTestDir(dir);
    removeTestDir(host.tmpdir);
  }
}

const largestRead = (log) => Math.max(0, ...log.filter((e) => e.method === "frame.evaluate").map((e) => e.size));

test("markdown: an oversized page stops at the page-read budget with a note, and asks about at most the frames it reads", async () => {
  const servers = await startFixtureServers();
  try {
    await withLoggedRepl(async (run) => {
      await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});
        await page.evaluate(() => {
          document.body.innerHTML = '<h1>Top</h1><p id="big"></p><p>Last</p>';
          document.getElementById("big").textContent = "A".repeat(5000000);
        });`);
      const big = await run(`const md = await page.markdown(); console.log("@@" + JSON.stringify({ length: md.length, top: md.includes("# Top"), tail: md.slice(-400) }));`);
      const r = JSON.parse(big.value);
      assert.ok(r.top, "the page's start is kept");
      assert.ok(r.length < READ_SIZE + 100000, `a 5,000,000-character page gave ${r.length} characters of Markdown`);
      assert.match(r.tail, /<!-- the page is too large to read whole: Markdown stopped after 2,000,000 characters/);
      assert.ok(largestRead(big.log) < READ_SIZE + 100000, `the page agent returned ${largestRead(big.log)} characters at once`);

      await run(`await page.evaluate(() => { document.body.innerHTML = "<h1>Frames</h1>" + "<iframe></iframe>".repeat(300); });`);
      const frames = await run(`const fmd = await page.markdown(); console.log("@@" + JSON.stringify({ tail: fmd.slice(-400) }));`);
      const asked = frames.log.filter((e) => e.method === "frame.contentFrames").reduce((n, e) => n + e.elements, 0);
      assert.ok(asked <= 100, `markdown asked the driver about ${asked} frames`);
      assert.match(JSON.parse(frames.value).tail, /<!-- the page is too large to read whole: Markdown stopped after 100 frames/);
    });
  } finally {
    await servers.close();
  }
});

test("snapshot: DOM read beside the walk (visible-box checks, aria-owns, labels) counts against the walk's node budget", async () => {
  // `_maxNodes` lowers the budget for the test; each page holds far more
  // nodes than it outside the part the walk visits.
  const servers = await startFixtureServers();
  try {
    await withLoggedRepl(async (run) => {
      await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});`);
      const pages = {
        box: `document.body.innerHTML = '<button>First</button><a id="zero" href="#" style="display:block;width:0;height:0"></a>'; const z = document.getElementById("zero"); for (let i = 0; i < 5000; i++) z.appendChild(document.createElement("span"));`,
        owns: `document.body.innerHTML = '<button>First</button><div role="listbox" aria-label="L"></div><div id="x">x</div>'; document.querySelector("[role=listbox]").setAttribute("aria-owns", "x ".repeat(100000));`,
        labels: `document.body.innerHTML = '<input id="a"><div id="hidden" style="display:none"></div>'; document.getElementById("hidden").innerHTML = '<label for="a">L</label>'.repeat(5000);`,
      };
      for (const [name, setup] of Object.entries(pages)) {
        const r = await run(`await page.evaluate(() => { ${setup} }); const s = await snapshot({ maxChars: Infinity, _maxNodes: 1000 }); console.log("@@" + JSON.stringify(s.tree.split("\\n").slice(-1)[0]));`);
        assert.match(JSON.parse(r.value), /^# the page is too large to read whole: the snapshot stopped after 1,000 nodes/, `${name}: the snapshot read past its budget without saying so`);
      }
    });
  } finally {
    await servers.close();
  }
});
