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
      // Settled as the reply would be.
      const text = sized.settle(sized.textContent(big));
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

// Item 5: the snapshot walk. A hostile page can hold millions of nodes; the
// walk must not read them all before the output limits apply. `_maxNodes`
// and `_maxSize` lower the budget for the test. (classic runtime.test.mjs)
const lines = (s) => s.tree.split("\n").filter((l) => /button|iframe|^#/.test(l));

test("snapshot: the page walk stops at its node budget with a note, and frames past the budget are not read", async () => {
  await withRepl(async (run) => {
    const r = await run(`
      await page.evaluate(() => {
        document.body.innerHTML = '<iframe title="inner" srcdoc="<button>Inner</button>"></iframe><button>First</button>' + "<p>filler</p>".repeat(2000) + "<button>Last</button>";
      });
      await page.waitForFunction(() => { const d = document.querySelector("iframe").contentDocument; return !!(d && d.querySelector("button")); });
      const keep = ${lines.toString()};
      const whole = await snapshot({ maxChars: Infinity });
      const cut = await snapshot({ maxChars: Infinity, _maxNodes: 500 });
      console.log("@@" + JSON.stringify({ whole: keep(whole), cut: keep(cut) }));
    `);
    const { whole, cut } = r;
    assert.ok(whole.some((l) => /button "Inner"/.test(l)), whole.slice(0, 6).join("\n"));
    assert.ok(whole.some((l) => /button "Last"/.test(l)));
    assert.ok(!whole.some((l) => /too large to read whole/.test(l)), whole.join("\n"));
    assert.ok(cut.some((l) => /button "First"/.test(l)), cut.slice(0, 6).join("\n"));
    assert.ok(!cut.some((l) => /button "Last"/.test(l)), "the walk read past its budget");
    assert.ok(!cut.some((l) => /button "Inner"/.test(l)), "a frame past the budget was read");
    assert.ok(cut.some((l) => /iframe "inner".*\[not read: the snapshot's node budget is used up\]/.test(l)), cut.slice(0, 6).join("\n"));
    assert.match(cut[cut.length - 1], /^# the page is too large to read whole: the snapshot stopped after 500 nodes/);
  });
});

test("snapshot: one huge text or value is cut at the snapshot's size budget with a note, per frame and in total", async () => {
  await withRepl(async (run) => {
    const r = await run(`
      await page.evaluate(() => {
        document.body.innerHTML = '<button>First</button><p id="big"></p><textarea aria-label="Field"></textarea><button>Last</button><iframe title="inner" srcdoc="<button>Inner</button>"></iframe>';
        document.getElementById("big").textContent = "A".repeat(5000000);
        document.querySelector("textarea").value = "V".repeat(5000000);
      });
      await page.waitForFunction(() => { const d = document.querySelector("iframe").contentDocument; return !!(d && d.querySelector("button")); });
      const keep = ${lines.toString()};
      const whole = await snapshot({ maxChars: Infinity });
      const small = await snapshot({ maxChars: Infinity, _maxSize: 3000 });
      console.log("@@" + JSON.stringify({ wholeLength: whole.tree.length, whole: keep(whole), smallLength: small.tree.length, small: keep(small) }));
    `);
    const { wholeLength, whole, smallLength, small } = r;
    assert.ok(wholeLength < 2200000, `a 10,000,000-character page printed a ${wholeLength}-character tree`);
    assert.match(whole[whole.length - 1], /^# the page is too large to read whole: the snapshot stopped after [\d,]+ characters/, whole.join("\n"));
    assert.ok(smallLength < 3600, `the tree is ${smallLength} characters`);
    assert.ok(small.some((l) => /button "First"/.test(l)), small.join("\n"));
    assert.ok(!small.some((l) => /button "Last"|button "Inner"/.test(l)), small.join("\n"));
    assert.match(small[small.length - 1], /^# the page is too large to read whole: the snapshot stopped after 3,000 characters/, small.join("\n"));
  });
});

// The walk is a deferred work stack: a node's children are scheduled before
// any is read. One element with very many children must not schedule them
// all; the walk charges each child where it schedules it. 200,000 children:
// more than the snapshot's 1,000-node budget, and within the 250,000
// elements that frame.observe's sensitive-field scan reads (a page with
// more is refused whole).
test("snapshot: one element with more children than the node budget schedules no more than the budget", async () => {
  await withRepl(async (run) => {
    const r = await run(`
      await page.evaluate(() => {
        const host = document.createElement("div");
        const p = document.createElement("span");
        p.textContent = "x";
        for (let i = 0; i < 200000; i++) host.appendChild(p.cloneNode(true));
        document.body.replaceChildren(host);
      });
      const raw = await page._mainFrame._agent("snapshot", { maxNodes: 1000 });
      console.log("@@" + JSON.stringify({ visited: raw.visited, truncated: raw.truncated, entries: raw.flat.length }));
    `);
    assert.equal(r.truncated, "nodes");
    assert.ok(r.visited <= 1000, `visited ${r.visited}`);
  });
});

// Each frame reads up to its share; a frame's inner frames split what that
// frame left of its own share, so a slow sibling's share cannot also be
// spent by another sibling's inner frames. Here B answers only after A's
// inner frame C was asked, the order that let C take B's share.
// (classic budget.test.mjs)
test("frames: frames read together never pass the snapshot's node and size budget, nested frames included", async () => {
  const asked = [];
  let cAsked;
  const cGate = new Promise((resolve) => (cAsked = resolve));
  const full = (name) => async (method, opts) => {
    asked.push({ name, maxNodes: opts.maxNodes, maxSize: opts.maxSize });
    return { flat: [[0, { role: "button", name, ref: "e1", act: 1 }]], max: 1, visited: opts.maxNodes, size: opts.maxSize };
  };
  const c = { p: "f3", _detached: false, _agent: async (method, opts) => { const r = await full("C")(method, opts); cAsked(); return r; } };
  const a = {
    p: "f1",
    _detached: false,
    _agent: async (method, opts) => {
      asked.push({ name: "A", maxNodes: opts.maxNodes, maxSize: opts.maxSize });
      return { flat: [[0, { role: "iframe", name: "C", ref: "e1", frame: "h3" }]], max: 1, visited: 1, size: 1 };
    },
    _contentFrame: async () => c,
  };
  const b = { p: "f2", _detached: false, _agent: async (method, opts) => { await cGate; return full("B")(method, opts); } };
  const main = {
    p: "",
    _agent: async (method, opts) => {
      asked.push({ name: "main", maxNodes: opts.maxNodes, maxSize: opts.maxSize });
      return { flat: [[0, { role: "iframe", name: "A", ref: "e1", frame: "h1" }], [0, { role: "iframe", name: "B", ref: "e2", frame: "h2" }]], max: 2, visited: 10, size: 10 };
    },
    _contentFrame: async (handle) => (handle === "h1" ? a : b),
  };
  const host = { setTimeout: (fn, ms) => setTimeout(fn, ms), clearTimeout: (t) => clearTimeout(t) };
  const page = { _session: { host }, _batchContentFrames: false, _refMaxFor: () => 0, _noteRefMax() {}, _prefixFor: (f) => f.p };
  await ns.snapshot.frameNodes(page, main, null, { _maxNodes: 100, _maxSize: 1000 }, true);
  const spent = (key, own) => asked.reduce((sum, x) => sum + (own[x.name] !== undefined ? own[x.name] : x[key]), 0);
  // main and A read less than their shares (10 and 1); C and B read all of theirs.
  assert.ok(spent("maxNodes", { main: 10, A: 1 }) <= 100, `nodes read: ${JSON.stringify(asked)}`);
  assert.ok(spent("maxSize", { main: 10, A: 1 }) <= 1000, `characters read: ${JSON.stringify(asked)}`);
  assert.deepEqual(asked.map((x) => x.name).sort(), ["A", "B", "C", "main"]);
});

// Budget items 7 and 9 (classic 7f37c374e9f5, 61b3f78a30d2): the label
// index and a slot's assigned nodes are read within the read's budget,
// never listed whole. The dev driver's agent world is the page world, so a
// list method the page wraps records the largest list a read asks for.
test("locators: past the page-read budget, labels are not read by a whole-document scan", async () => {
  await withRepl(async (run) => {
    const count = await run(`
      await page.evaluate(() => {
        document.body.innerHTML = '<input id="a">' + '<label for="b">x</label>'.repeat(250001) + '<label for="a">Beyond the budget</label><input id="b">';
      });
      console.log("@@" + JSON.stringify(await page.getByRole("textbox", { name: "Beyond the budget" }).count()));
    `);
    assert.equal(count, 0, "a label past the budget was found by a whole-document scan");
  });
});

test("label index: <label>s are read one at a time within the budget, never listed whole (document and shadow root)", async () => {
  await withRepl(async (run) => {
    const listed = await run(`
      await page.evaluate(() => {
        document.body.innerHTML = '<input id="a"><div id="host"></div><div id="hidden" style="display:none"></div>';
        document.getElementById("hidden").innerHTML = '<label for="a">L</label>'.repeat(5000);
        document.getElementById("host").attachShadow({ mode: "open" }).innerHTML = '<input id="b"><div style="display:none">' + '<label for="b">S</label>'.repeat(5000) + '</div>';
        window.__labels = 0;
        for (const proto of [Document.prototype, DocumentFragment.prototype, Element.prototype]) {
          const native = proto.querySelectorAll;
          proto.querySelectorAll = function (selector) {
            const list = native.call(this, selector);
            if (String(selector).trim().toLowerCase() === "label") window.__labels = Math.max(window.__labels, list.length);
            return list;
          };
        }
      });
      await snapshot({ maxChars: Infinity, _maxNodes: 1000 });
      console.log("@@" + JSON.stringify(await page.evaluate(() => window.__labels)));
    `);
    assert.ok(listed <= 1000, `the label index listed ${listed} <label>s at once with a budget of 1,000 nodes`);
    // Below the budget, labels still name their controls in both trees.
    const named = await run(`
      await page.evaluate(() => {
        document.getElementById("hidden").innerHTML = '<label for="a">Doc label</label>';
        document.getElementById("host").shadowRoot.innerHTML = '<input id="b"><label for="b">Shadow label</label>';
      });
      const s = await snapshot({ maxChars: Infinity });
      console.log("@@" + JSON.stringify({ doc: s.tree.includes('textbox "Doc label"'), shadow: s.tree.includes('textbox "Shadow label"') }));
    `);
    assert.deepEqual(named, { doc: true, shadow: true }, "a label below the budget no longer names its control");
  });
});

test("snapshot: a slot's assigned nodes are read one at a time within the walk's budget, never listed whole", async () => {
  await withRepl(async (run) => {
    const listed = await run(`
      await page.evaluate(() => {
        window.__assigned = 0;
        for (const name of ["assignedNodes", "assignedElements"]) {
          const native = HTMLSlotElement.prototype[name];
          HTMLSlotElement.prototype[name] = function (o) { const list = native.call(this, o); window.__assigned = Math.max(window.__assigned, list.length); return list; };
        }
        document.body.innerHTML = '<div id="host"></div>';
        const host = document.getElementById("host");
        host.innerHTML = '<button>b</button>'.repeat(5000);
        host.attachShadow({ mode: "open" }).innerHTML = '<p><slot></slot></p>';
      });
      await snapshot({ maxChars: Infinity, _maxNodes: 1000 });
      console.log("@@" + JSON.stringify(await page.evaluate(() => window.__assigned)));
    `);
    assert.ok(listed <= 1000, `the snapshot listed ${listed} assigned nodes at once with a budget of 1,000 nodes`);
    const named = await run(`
      await page.evaluate(() => {
        document.body.innerHTML = '<div id="h"><button slot="b">Bee one</button><button>Default one</button><button slot="b">Bee two</button><button slot="zz">Unplaced</button></div>';
        document.getElementById("h").attachShadow({ mode: "open" }).innerHTML = '<div role="group" aria-label="A"><slot name="a"><button>Fallback a</button></slot></div><div role="group" aria-label="B"><slot name="b"></slot></div><div role="group" aria-label="D"><slot></slot></div>';
      });
      const s = await snapshot({ maxChars: Infinity });
      console.log("@@" + JSON.stringify(s.tree.split("\\n").map((l) => l.trim()).filter((l) => /^- (group|button)/.test(l)).map((l) => l.replace(/ \\[ref=\\w+\\]/, "").replace(/:$/, ""))));
    `);
    assert.deepEqual(named, ['- group "A"', '- button "Fallback a"', '- group "B"', '- button "Bee one"', '- button "Bee two"', '- group "D"', '- button "Default one"']);
  });
});
