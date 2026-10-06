// r22 runtime: page-controlled strings are charged and cut before they are
// normalized or parsed (docs/browser-repl/README.md, Large output). A cap
// on the returned value is not enough: a DOM getter (innerText,
// textContent, an option's label), a whitespace replace or a CSS content
// parse over a page string of megabytes runs whole on the page's main
// thread before any cap applies.
//
// The dev driver's agent world is the page world, so getters,
// String.prototype.replace and RegExp.prototype.exec the page wraps record
// the longest string they handed out or worked on (in the app the agent
// world is the session's own; this only observes what the reads ask for).
//
//   node --test tests/browser-parity/unit/page-read-sources.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { createDevBrowser, createNodeHost, createDevRepl } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";
import { makeTestDir, removeTestDir } from "../lib/test-dirs.mjs";

const BIG = 3000000;
const READ_SIZE = 2000000;

async function withRepl(fn) {
  const servers = await startFixtureServers();
  const dir = makeTestDir("cmux-repl-read-sources-");
  const browser = await createDevBrowser();
  const lines = [];
  const host = createNodeHost({ workDir: dir, sessionId: `read-sources-${process.pid}`, print: (level, text) => lines.push(text) });
  const repl = createDevRepl({ host, driver: browser.driver() });
  const run = async (code) => {
    const start = lines.length;
    const r = await repl.evaluate(code);
    const output = lines.slice(start).join("\n");
    assert.equal(r.ok, true, `${r.error}\n${output.slice(0, 2000)}`);
    return { output, value: (output.split("\n").find((l) => l.startsWith("@@")) || "").slice(2) };
  };
  try {
    await run(`await page.goto(${JSON.stringify(servers.origins.primary + "/")});`);
    await fn(run);
  } finally {
    repl.dispose();
    await browser.close();
    removeTestDir(dir);
    removeTestDir(host.tmpdir);
    await servers.close();
  }
}

// Sets the page up with `setup` (a function body; `BIG` is in scope), then
// wraps the getters, String.prototype.replace and RegExp.prototype.exec
// (also what a regular expression method runs) so each records the
// longest string it returned or worked on in window.__longest.
const prepare = (setup) => `await page.evaluate((BIG) => {
  ${setup}
  window.__longest = {};
  const rec = (key, s) => { if (typeof s === "string") window.__longest[key] = Math.max(window.__longest[key] || 0, s.length); };
  const wrap = (proto, key) => {
    const d = Object.getOwnPropertyDescriptor(proto, key);
    Object.defineProperty(proto, key, { ...d, get() { const v = d.get.call(this); rec(key, v); return v; } });
  };
  wrap(Node.prototype, "textContent");
  wrap(HTMLElement.prototype, "innerText");
  wrap(HTMLOptionElement.prototype, "label");
  wrap(HTMLOptionElement.prototype, "text");
  const replace = String.prototype.replace;
  String.prototype.replace = function (...args) { rec("replace", String(this)); return replace.apply(this, args); };
  const exec = RegExp.prototype.exec;
  RegExp.prototype.exec = function (input) { rec("exec", String(input)); return exec.call(this, input); };
}, ${BIG});`;
const longest = `(await page.evaluate(() => window.__longest))`;

test("accessible names: elementAt and snapshot names never run the name computation over a page string past the name bounds", async () => {
  await withRepl(async (run) => {
    const cases = {
      // The element's own content.
      content: `document.body.innerHTML = '<button id="t" style="position:fixed;left:0;top:0;width:200px;height:40px"></button>'; document.getElementById("t").textContent = "A".repeat(BIG);`,
      // A role-less editable element named by aria-labelledby.
      labelledby: `document.body.innerHTML = '<div id="t" contenteditable="true" aria-labelledby="h" style="position:fixed;left:0;top:0;width:200px;height:40px"></div><div id="h" style="display:none"></div>'; document.getElementById("h").textContent = "A".repeat(BIG);`,
    };
    for (const [name, setup] of Object.entries(cases)) {
      const r = await run(`${prepare(setup)}
        const at = await page.elementAt(20, 20);
        console.log("@@" + JSON.stringify({ longest: ${longest}, name: at && at.name ? at.name.length : 0 }));`);
      const v = JSON.parse(r.value);
      assert.ok((v.longest.textContent || 0) <= 100000, `${name}: elementAt read a ${v.longest.textContent}-character textContent for a name`);
      assert.ok(v.name <= 2001, `${name}: elementAt returned a ${v.name}-character name`);
    }
    // Generated content (::before) is a name source the vendor computation
    // reads and parses whole, so it counts toward the name bounds (20,000
    // characters); past them the name is read from the element's text.
    const pseudo = await run(`${prepare(`document.body.innerHTML = '<style id="s"></style><button id="t" style="position:fixed;left:0;top:0;width:200px;height:40px">Go</button>'; document.getElementById("s").textContent = '#t::before { content: "' + "A".repeat(30000) + '"; }';`)}
      const at = await page.elementAt(20, 20);
      const snap = String(await snapshot({ maxChars: Infinity }));
      const named = /- button "([^"]*)"/.exec(snap);
      console.log("@@" + JSON.stringify({ at: at.name.slice(0, 200), snap: named ? named[1].slice(0, 200) : null }));`);
    const p = JSON.parse(pseudo.value);
    // The vendor name ("A" x 30,000 + "Go") is cut whole ("…").
    assert.equal(p.at, "Go", "elementAt computed the name over 30,000 characters of generated content");
    assert.equal(p.snap, "Go", "the snapshot computed the name over 30,000 characters of generated content");
  });
});

test("agent-tools reads: extract, dropdownOptions, searchText and markdown main detection cut page text before they normalize it", async () => {
  await withRepl(async (run) => {
    const extract = await run(`${prepare(`document.body.innerHTML = '<p id="big"></p>'; document.getElementById("big").textContent = "A ".repeat(BIG / 2);`)}
      await page.extract({ t: "#big" });
      console.log("@@" + JSON.stringify(${longest}));`);
    const e = JSON.parse(extract.value);
    assert.ok((e.innerText || 0) <= READ_SIZE, `extract read a ${e.innerText}-character innerText`);
    assert.ok((e.replace || 0) <= READ_SIZE + 100, `extract normalized a ${e.replace}-character string`);

    const drop = await run(`${prepare(`document.body.innerHTML = '<div role="listbox" id="lb"><div role="option" id="o"></div></div>'; document.getElementById("o").textContent = "A ".repeat(BIG / 2);`)}
      await page.dropdownOptions("#lb");
      console.log("@@" + JSON.stringify(${longest}));`);
    const d = JSON.parse(drop.value);
    assert.ok((d.innerText || 0) <= READ_SIZE, `dropdownOptions read a ${d.innerText}-character innerText`);
    assert.ok((d.replace || 0) <= READ_SIZE + 100, `dropdownOptions normalized a ${d.replace}-character string`);

    const search = await run(`${prepare(`document.body.innerHTML = '<p id="big"></p>'; document.getElementById("big").textContent = "A ".repeat(BIG);`)}
      await page.searchText("A", { limit: 1 });
      console.log("@@" + JSON.stringify(${longest}));`);
    const s = JSON.parse(search.value);
    assert.ok((s.replace || 0) <= READ_SIZE + 100, `searchText normalized a ${s.replace}-character text node`);

    // Where checkVisibility is missing, <main> detection fell back to the
    // whole innerText of each candidate.
    const main = await run(`${prepare(`document.body.innerHTML = '<main id="m"></main>'; document.getElementById("m").textContent = "A ".repeat(BIG / 2); delete Element.prototype.checkVisibility;`)}
      await page.markdown({ main: true });
      console.log("@@" + JSON.stringify(${longest}));`);
    const m = JSON.parse(main.value);
    assert.ok((m.innerText || 0) <= READ_SIZE, `markdown main detection read a ${m.innerText}-character innerText`);
  });
});
