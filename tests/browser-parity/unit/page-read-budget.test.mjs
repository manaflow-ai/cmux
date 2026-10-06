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

// The label index charges the read's budget for every <label> it reads.
// Once that budget is spent, a control's labels must not come from
// WebKit's own getter, which scans the whole document for each control: a
// page of many labels and controls would make every name a full scan. A
// locator query past it names controls without those labels.
test("locators: past the page-read budget, labels are not read by a whole-document scan", async () => {
  const servers = await startFixtureServers();
  try {
    await withLoggedRepl(async (run) => {
      await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});`);
      const setup = `document.body.innerHTML = '<input id="a">' + '<label for="b">x</label>'.repeat(250001) + '<label for="a">Beyond the budget</label><input id="b">';`;
      const r = await run(`await page.evaluate(() => { ${setup} }); console.log("@@" + JSON.stringify(await page.getByRole("textbox", { name: "Beyond the budget" }).count()));`);
      assert.equal(r.value, "0", "a label past the budget was found by a whole-document scan");
    });
  } finally {
    await servers.close();
  }
});

test("composer text: a composer past the page-read budget is refused before its text leaves the page", async () => {
  const servers = await startFixtureServers();
  try {
    await withLoggedRepl(async (run) => {
      await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});
        await page.evaluate(() => {
          document.body.innerHTML = '<div id="c" contenteditable="true"></div><textarea id="t"></textarea>';
          document.getElementById("c").textContent = "A".repeat(5000000);
          document.getElementById("t").value = "B".repeat(5000000);
        });`);
      for (const sel of ["#c", "#t"]) {
        const r = await run(`let err = null; try { await page.locator(${JSON.stringify(sel)})._read("composerText", null, {}, "composer text"); } catch (e) { err = String(e.message); } console.log("@@" + JSON.stringify(err));`);
        assert.match(JSON.parse(r.value) || "", /more than 2,000,000 characters/, `${sel}: the composer text was read whole`);
        assert.ok(largestRead(r.log) < 100000, `${sel}: the page agent returned ${largestRead(r.log)} characters`);
      }
    });
  } finally {
    await servers.close();
  }
});

test("dropdownOptions and extract: page-controlled lists stop at the page-read budget with a note", async () => {
  const servers = await startFixtureServers();
  try {
    await withLoggedRepl(async (run) => {
      await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});
        await page.evaluate(() => {
          document.body.innerHTML = '<select id="s"></select><div id="items"></div><div id="bigs"></div>';
          const s = document.getElementById("s");
          for (let i = 0; i < 3; i++) s.appendChild(new Option(String(i).repeat(1000000), "v" + i));
          const items = document.getElementById("items");
          for (let i = 0; i < 20000; i++) items.appendChild(document.createElement("span")).className = "item";
          const bigs = document.getElementById("bigs");
          for (let i = 0; i < 5; i++) bigs.appendChild(document.createElement("p")).textContent = "C".repeat(1000000);
        });`);
      const drop = await run(`const o = await page.dropdownOptions("#s"); console.log("@@" + JSON.stringify(o.reduce((n, x) => n + x.label.length, 0)));`);
      assert.ok(Number(drop.value) <= READ_SIZE + 10, `dropdownOptions returned ${drop.value} characters of labels`);
      assert.ok(largestRead(drop.log) < READ_SIZE + 100000, `the page agent returned ${largestRead(drop.log)} characters`);
      assert.match(drop.output, /# page\.dropdownOptions: the page is too large to read whole: it stopped after 2,000,000 characters/);

      const handles = await run(`const before = (await page.mainFrame()._agent("stats")).handles; await page.extract([".item"], { limit: 5 }); console.log("@@" + ((await page.mainFrame()._agent("stats")).handles - before));`);
      assert.ok(Number(handles.value) < 100, `extract kept ${handles.value} element handles for a list limited to 5`);

      const text = await run(`const e = await page.extract(["#bigs p"]); console.log("@@" + JSON.stringify(e.reduce((n, x) => n + (x ? x.length : 0), 0)));`);
      assert.ok(Number(text.value) <= READ_SIZE + 10, `extract returned ${text.value} characters`);
      assert.ok(largestRead(text.log) < READ_SIZE + 100000, `the page agent returned ${largestRead(text.log)} characters`);
      assert.match(text.output, /# page\.extract: the page is too large to read whole: it stopped after 2,000,000 characters/);
    });
  } finally {
    await servers.close();
  }
});

test("tabs.content: each URL and the whole call stop at the page-read budget, and a cut row says so", async () => {
  const big = "<!doctype html><title>Big</title><p>" + "A".repeat(5000000) + "</p>";
  const server = http.createServer((req, res) => {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    res.end(big);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  try {
    await withLoggedRepl(async (run) => {
      for (const format of ["text", "html", "markdown", "snapshot"]) {
        const r = await run(`const rows = await tabs.content([${JSON.stringify(url + "/a")}, ${JSON.stringify(url + "/b")}, ${JSON.stringify(url + "/c")}], { format: ${JSON.stringify(format)} });
          console.log("@@" + JSON.stringify(rows.map((x) => ({ length: x.content ? x.content.length : 0, truncated: x.truncated || null, error: x.error || null }))));`);
        const rows = JSON.parse(r.value);
        const total = rows.reduce((n, x) => n + x.length, 0);
        assert.ok(total <= READ_SIZE + 1000, `${format}: three 5,000,000-character pages gave ${total} characters`);
        for (const row of rows) assert.match(row.truncated || "", /the page is too large to read whole/, `${format}: ${JSON.stringify(row)}`);
        assert.ok(largestRead(r.log) < READ_SIZE + 100000, `${format}: the page agent returned ${largestRead(r.log)} characters at once`);
      }
    });
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test("locator reads, allTextContents and page.content: an oversized element stops at the page-read budget with a note", async () => {
  const servers = await startFixtureServers();
  try {
    await withLoggedRepl(async (run) => {
      await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});
        await page.evaluate(() => {
          document.body.innerHTML = '<div id="big"><p class="p"></p><p class="p"></p></div><textarea id="field"></textarea><div id="wide"></div><p id="small">Small <b>text</b></p>';
          for (const p of document.querySelectorAll(".p")) p.textContent = "A".repeat(3000000);
          document.getElementById("field").value = "B".repeat(5000000);
          document.getElementById("big").setAttribute("data-x", "C".repeat(5000000));
          const wide = document.getElementById("wide");
          for (let i = 0; i < 300000; i++) wide.appendChild(document.createElement("i"));
        });`);
      const reads = {
        textContent: 'page.locator("#big").textContent()',
        innerText: 'page.locator("#big").innerText()',
        innerHTML: 'page.locator("#big").innerHTML()',
        getAttribute: 'page.locator("#big").getAttribute("data-x")',
        inputValue: 'page.locator("#field").inputValue()',
        allTextContents: 'page.locator(".p").allTextContents().then((a) => a.join(""))',
        allInnerTexts: 'page.locator(".p").allInnerTexts().then((a) => a.join(""))',
        content: "page.content()",
        wideHTML: 'page.locator("#wide").innerHTML()',
      };
      for (const [name, expr] of Object.entries(reads)) {
        const r = await run(`const v = await ${expr}; console.log("@@" + JSON.stringify(v.length));`);
        assert.ok(Number(r.value) <= READ_SIZE + 10, `${name}: returned ${r.value} characters`);
        assert.ok(largestRead(r.log) < READ_SIZE + 100000, `${name}: the page agent returned ${largestRead(r.log)} characters at once`);
        assert.match(r.output, /# (locator|page)\.\w+: the page is too large to read whole: it stopped after (2,000,000 characters|250,000 nodes)/, `${name}: no note`);
      }
      // A read within the budget is the getter's own string, with no note.
      const small = await run(`console.log("@@" + JSON.stringify([await page.locator("#small").textContent(), await page.locator("#small").innerText(), await page.locator("#small").innerHTML()]));`);
      assert.deepEqual(JSON.parse(small.value), ["Small text", "Small text", "Small <b>text</b>"]);
      assert.doesNotMatch(small.output, /too large/);
    });
  } finally {
    await servers.close();
  }
});

// The text and HTML formats read the page node by node under the budget,
// never through a getter that walks the whole DOM first: a page of more
// nodes than the budget (each tiny, so the string itself would fit) is cut
// at the node budget.
test("tabs.content: text and HTML stop at the node budget, not after serializing the whole DOM", async () => {
  const page = "<!doctype html><title>Many</title><body>" + "<i>x</i>".repeat(270000) + "</body>";
  const server = http.createServer((req, res) => {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    res.end(page);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;
  try {
    await withLoggedRepl(async (run) => {
      for (const format of ["text", "html"]) {
        const r = await run(`const [row] = await tabs.content(${JSON.stringify(url)}, { format: ${JSON.stringify(format)} }); console.log("@@" + JSON.stringify({ length: row.content.length, truncated: row.truncated || null }));`);
        const row = JSON.parse(r.value);
        assert.match(row.truncated || "", /stopped after 250,000 nodes/, `${format}: ${JSON.stringify(row)}`);
      }
    });
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

// A name reads text the walk may never visit (a hidden aria-labelledby
// target, a hidden label) and the name computation reads it whole and
// recursively: those reads count against the snapshot's node budget, and
// nesting deeper than the stack cannot fail the snapshot.
test("snapshot: names and values read within the budget, and deep nesting is cut with a ref instead of failing", async () => {
  const servers = await startFixtureServers();
  try {
    await withLoggedRepl(async (run) => {
      await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});`);
      const pages = {
        labelledby: `document.body.innerHTML = '<button aria-labelledby="h">B</button><div id="h" style="display:none"></div>'; const h = document.getElementById("h"); for (let i = 0; i < 5000; i++) h.appendChild(document.createElement("span")).textContent = "w";`,
        label: `document.body.innerHTML = '<input id="a"><label for="a" style="display:none" id="l"></label>'; const l = document.getElementById("l"); for (let i = 0; i < 5000; i++) l.appendChild(document.createElement("span")).textContent = "w";`,
      };
      for (const [name, setup] of Object.entries(pages)) {
        const r = await run(`await page.evaluate(() => { ${setup} }); const s = await snapshot({ maxChars: Infinity, _maxNodes: 1000 }); console.log("@@" + JSON.stringify(s.tree.split("\\n").slice(-1)[0]));`);
        assert.match(JSON.parse(r.value), /^# the page is too large to read whole: the snapshot stopped after 1,000 nodes/, `${name}: the name read past the snapshot's budget without saying so`);
      }
      // Buttons nested 20,000 deep (each one's name is its content), and
      // elements nested as deep read with showHidden (the walk itself).
      for (const [tags, opts] of [[["div", "button"], {}], [["div", "span"], { showHidden: true }]]) {
        const deep = await run(`await page.evaluate((tags) => {
            document.body.innerHTML = '<button>First</button><div id="root"></div><button>Last</button>';
            let e = document.getElementById("root");
            for (let i = 0; i < 20000; i++) e = e.appendChild(document.createElement(tags[i % 2]));
            e.textContent = "deepest";
          }, ${JSON.stringify(tags)});
          let out;
          try { out = String(await snapshot({ maxChars: Infinity, ...${JSON.stringify(opts)} })); } catch (e) { out = "error: " + e.message; }
          console.log("@@" + JSON.stringify({ error: /^error:/.test(out) ? out.slice(0, 300) : null, last: /button "Last"/.test(out), cut: /\\[ref=e\\d+\\] \\[not read: nested deeper than 1000 elements; snapshot this ref to read it\\]/.test(out) }));`);
        const r = JSON.parse(deep.value);
        assert.equal(r.error, null, tags.join());
        assert.ok(r.last, `${tags}: the snapshot lost the page after the nested part`);
        if (opts.showHidden) assert.ok(r.cut, `${tags}: no note where the nesting was cut`);
      }
    });
  } finally {
    await servers.close();
  }
});

test("page.searchText: the text it scans and the contexts it returns stop at the page-read budget with a note", async () => {
  const servers = await startFixtureServers();
  try {
    await withLoggedRepl(async (run) => {
      await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});
        await page.evaluate(() => {
          document.body.innerHTML = '<p id="a"></p><p id="b"></p><p>needle at the end</p>';
          document.getElementById("a").textContent = "A".repeat(3000000);
          document.getElementById("b").textContent = "B".repeat(3000000);
        });`);
      const r = await run(`const s = await page.searchText("A", { context: 100000000, limit: 5 }); console.log("@@" + JSON.stringify({ total: s.total, longest: Math.max(...s.matches.map((m) => m.context.length)), chars: s.matches.reduce((n, m) => n + m.context.length + m.match.length, 0) }));`);
      const v = JSON.parse(r.value);
      assert.ok(v.longest <= 2010, `a context ran ${v.longest} characters`);
      assert.ok(largestRead(r.log) < 100000, `the page agent returned ${largestRead(r.log)} characters`);
      const end = await run(`const e = await page.searchText("needle"); console.log("@@" + JSON.stringify(e.total));`);
      assert.equal(end.value, "0", "text past the budget was scanned");
      assert.match(end.output, /# page\.searchText: the page is too large to read whole: it stopped after 2,000,000 characters/);
      const regex = await run(`const g = await page.searchText("A+", { regex: true, limit: 2 }); console.log("@@" + JSON.stringify(Math.max(...g.matches.map((m) => m.match.length))));`);
      assert.ok(Number(regex.value) <= 1010, `a match ran ${regex.value} characters`);
    });
  } finally {
    await servers.close();
  }
});

test("session.storageState: localStorage is read within the page-read budget, and past it the call fails with the note", async () => {
  const servers = await startFixtureServers();
  try {
    await withLoggedRepl(async (run) => {
      // 2,300,000 characters of one origin's localStorage, within WebKit's
      // 5 MB quota and past the page-read budget's 2,000,000 characters.
      await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});
        await page.evaluate(() => { localStorage.clear(); localStorage.setItem("big", "A".repeat(2300000)); localStorage.setItem("small", "s"); });`);
      const r = await run(`const out = await session.storageState().then((s) => "saved " + JSON.stringify(s).length, (e) => e.message); console.log("@@" + JSON.stringify(out));`);
      const out = JSON.parse(r.value);
      assert.match(out, /^session\.storageState: the page is too large to read whole: localStorage stopped after 2,000,000 characters/, out.slice(0, 300));
      assert.ok(largestRead(r.log) < READ_SIZE + 100000, `the page agent returned ${largestRead(r.log)} characters at once`);
      // A state within the budget is still read whole.
      await run(`await page.evaluate(() => { localStorage.clear(); localStorage.setItem("k", "v"); });`);
      const small = await run(`const st = await session.storageState(); console.log("@@" + JSON.stringify(st.origins));`);
      assert.deepEqual(JSON.parse(small.value), [{ origin: servers.origins.primary, localStorage: [{ name: "k", value: "v" }] }]);
    });
  } finally {
    await servers.close();
  }
});

test("page.exportContent: the default Markdown export stops at the page-read budget with a note", async () => {
  const servers = await startFixtureServers();
  try {
    await withLoggedRepl(async (run) => {
      await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});
        await page.evaluate(() => {
          document.title = "Export lab";
          document.body.innerHTML = '<h1>Top</h1><p id="big"></p><p>Last</p>';
          document.getElementById("big").textContent = "A".repeat(5000000);
        });`);
      const r = await run(`const file = await page.exportContent(); const md = fs.readFileSync(file, "utf8"); console.log("@@" + JSON.stringify({ length: md.length, head: md.slice(0, 200), tail: md.slice(-400) }));`);
      const md = JSON.parse(r.value);
      assert.ok(md.length < READ_SIZE + 100000, `a 5,000,000-character page exported ${md.length} characters`);
      assert.match(md.head, /^# Export lab\n\n<http:\/\/[^>]+>\n\n# Top/);
      assert.match(md.tail, /<!-- the page is too large to read whole: Markdown stopped after 2,000,000 characters/);
    });
  } finally {
    await servers.close();
  }
});

// Secrets are masked natively, after a reply leaves the page, by matching
// whole values: a read cut at the budget inside a value (a typed secret in
// a field or an editor, its text split across nodes) would hand on the
// value's unmasked prefix. A cut read must end before any value it could
// have split, whatever the page put in front of it.
test("a read cut at the page-read budget never ends inside a value the session masks", async () => {
  const servers = await startFixtureServers();
  const SECRET = "Zq9Wv7Kj";
  try {
    await withLoggedRepl(async (run) => {
      await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});
        await page.evaluate(({ size, secret }) => {
          document.body.innerHTML = '<h1>Top</h1><textarea id="field"></textarea><p id="split"></p>';
          // The cut falls three characters into the secret.
          document.getElementById("field").value = "x".repeat(size - 3) + secret + "y".repeat(10);
          // Text nodes: the first ends in the secret's start, the cut falls in the second.
          const p = document.getElementById("split");
          p.appendChild(document.createTextNode("x".repeat(size - 3) + secret.slice(0, 3)));
          p.appendChild(document.createTextNode(secret.slice(3) + "y".repeat(10)));
        }, { size: ${READ_SIZE}, secret: ${JSON.stringify(SECRET)} });`);
      const reads = {
        inputValue: 'page.locator("#field").inputValue()',
        textContent: 'page.locator("#split").textContent()',
        innerText: 'page.locator("#split").innerText()',
        innerHTML: 'page.locator("#split").innerHTML()',
        markdown: "page.markdown()",
      };
      for (const [name, expr] of Object.entries(reads)) {
        const r = await run(`const v = await ${expr}; console.log("@@" + JSON.stringify({ leaked: v.includes(${JSON.stringify(SECRET.slice(0, 1))}) }));`);
        const v = JSON.parse(r.value);
        assert.equal(v.leaked, false, `${name}: the cut read ends inside the secret`);
      }
    });
  } finally {
    await servers.close();
  }
});

// A link's URL is shortened for the snapshot (an off-site link's host
// summary, a cross-origin URL). Shortening before the reply leaves the page
// would cut a secret in the URL before native masking sees it whole, and
// hand on its prefix; it happens after masking instead.
test("snapshot: a shortened link URL never shows a prefix of a value the session masks", async () => {
  const servers = await startFixtureServers();
  const SECRET = "Zq9Wv7KjQ3xP8mLt";
  try {
    await withLoggedRepl(async (run) => {
      await run(`secrets.set("k", ${JSON.stringify(SECRET)}, { domains: ["localhost"] });
        await page.goto(${JSON.stringify(servers.origins.primary + "/")});
        await page.evaluate((secret) => {
          // The off-site summary ("host/first-segment") is cut at 48
          // characters, 7 into the secret; the cross-origin URL at 300, 8
          // into it.
          const summary = "https://e.example/" + "a".repeat(30) + secret + "/more";
          const long = "https://evil.example/" + "a".repeat(270) + secret + "b".repeat(50);
          document.body.innerHTML = '<a id="s">Summary</a> <a id="l">Long</a>';
          document.getElementById("s").href = summary;
          document.getElementById("l").href = long;
        }, ${JSON.stringify(SECRET)});`);
      for (const opts of [{}, { urls: true }]) {
        const r = await run(`const s = await snapshot(${JSON.stringify(opts)}); console.log("@@" + JSON.stringify(String(s.tree || s)));`);
        const tree = JSON.parse(r.value);
        assert.match(tree, /\[url=e\.example\/a/, `the link URLs are not in the snapshot: ${tree}`);
        assert.equal(tree.includes(SECRET.slice(0, 4)), false, `${JSON.stringify(opts)}: the snapshot shows the secret's prefix: ${tree}`);
      }
    });
  } finally {
    await servers.close();
  }
});
