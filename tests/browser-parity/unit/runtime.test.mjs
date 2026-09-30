// Focused tests for the browser REPL runtime: snapshot shaping, rendering,
// diff and the diff-or-tree print choice, key parsing, the top-level rewrite,
// printing, the fs sandbox, and ref identity and auto-print on Playwright
// WebKit through the dev driver.
//
//   node --test tests/browser-parity/unit/
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { loadRuntime, runDevRepl, createFsOp } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";

const ns = loadRuntime();
const { shape, interactiveOnly, render, diffLines, Snapshot } = ns.snapshot;
const { describeKey, splitKeyCombo, MiniURL } = ns.core;
const { rewriteTopLevel, createReplSession } = ns.replHost;
const { inspect } = ns.api;

const tree = (nodes, options = {}) => render(options.interactive ? interactiveOnly(shape(nodes, options)) : shape(nodes, options), options);

test("render: states print in a fixed order, then url, placeholder and value", () => {
  const nodes = [
    { role: "heading", name: "Sign up", level: 1, children: ["Sign up"] },
    { role: "textbox", name: "Email", ref: "e3", placeholder: "you@x.com", value: "me@x.com", required: true, invalid: true, readonly: true, focused: true },
    { role: "checkbox", name: "Terms", ref: "e4", checked: "mixed", disabled: true },
    { role: "button", name: "Menu", ref: "e5", expanded: false, pressed: true, children: ["Menu"] },
    { role: "link", name: "Home", ref: "e6", url: "/aria.html", children: ["Home"] },
    { role: "generic", name: "Log", ref: "e7", scrollable: 1, hidden: 1, children: ["one", "two"] },
  ];
  const lines = tree(nodes, { urls: true });
  assert.deepEqual(lines, [
    '- heading "Sign up" [level=1]',
    '- textbox "Email" [ref=e3] [required] [invalid] [readonly] [focused] [placeholder="you@x.com"]: "me@x.com"',
    '- checkbox "Terms" [ref=e4] [checked=mixed] [disabled]',
    '- button "Menu" [ref=e5] [expanded=false] [pressed]',
    '- link "Home" [ref=e6] [url=/aria.html]',
    '- generic "Log" [ref=e7] [hidden] [scrollable]:',
    '  - text: "one"',
    '  - text: "two"',
  ]);
  // Link URLs print only on request.
  assert.equal(tree(nodes)[4], '- link "Home" [ref=e6]');
});

test("shape: text-only rows print as one line with | between cells", () => {
  // Rows and cells carry no content names (page-agent names them only from an author label).
  const row = (cells) => ({ role: "row", children: cells.map((c) => ({ role: "cell", children: [c] })) });
  const lines = tree([{ role: "table", name: "Scores", children: ["Scores", row(["Name", "Score"]), row(["Ada", { role: "button", name: "Edit", ref: "e9", children: ["Edit"] }])] }]);
  assert.deepEqual(lines, [
    '- table "Scores":',
    '  - row: "Name | Score"',
    "  - row:",
    '    - cell: "Ada"',
    '    - button "Edit" [ref=e9]',
  ]);
});

test("shape: structure with nothing in it, or around one element, is not printed", () => {
  assert.deepEqual(tree([{ role: "list", children: [] }, { role: "listitem" }, { role: "separator" }]), ["- separator"]);
  assert.deepEqual(tree([{ role: "list", children: [{ role: "listitem", children: [{ role: "link", name: "A", ref: "e1", children: ["A"] }] }, { role: "listitem", children: ["Plain"] }] }]),
    ["- list:", '  - link "A" [ref=e1]', '  - listitem: "Plain"']);
  assert.deepEqual(tree([{ role: "navigation", children: [{ role: "navigation", children: [{ role: "link", name: "A", ref: "e1", children: ["A"] }] }] }]),
    ["- navigation:", '  - link "A" [ref=e1]']);
});

test("shape: long names print as content, and printed names are capped", () => {
  const long = "word ".repeat(50).trim();
  assert.deepEqual(tree([{ role: "link", name: long, ref: "e1", children: [long] }]), [`- link [ref=e1]: ${JSON.stringify(long)}`]);
  const mid = "x".repeat(150);
  assert.deepEqual(tree([{ role: "link", name: mid, ref: "e2", children: [mid] }]), [`- link ${JSON.stringify(mid)} [ref=e2]`]);
  assert.deepEqual(tree([{ role: "img", name: mid }]), [`- img ${JSON.stringify("x".repeat(99) + "…")}`]);
  // A lone text the name already says is dropped; zero-width spaces do not count.
  assert.deepEqual(tree([{ role: "link", name: "docs, (Directory)", ref: "e3", children: ["docs"] }]), ['- link "docs, (Directory)" [ref=e3]']);
  assert.deepEqual(tree([{ role: "link", name: "Blog (external)", ref: "e4", children: ["Blog \u200b(external)"] }]), ['- link "Blog (external)" [ref=e4]']);
});

test("shape: a name that repeats the children keeps one copy", () => {
  assert.deepEqual(tree([{ role: "group", name: "Size", children: ["Size", { role: "radio", name: "S", ref: "e1" }] }]), ['- group "Size":', '  - radio "S" [ref=e1]']);
  assert.deepEqual(tree([{ role: "link", name: "Read more", ref: "e2", children: [{ role: "heading", name: "Read", level: 3, children: ["Read"] }, "more"] }]), ['- link "Read more" [ref=e2]']);
});

test("shape: combobox options print only on request or when expanded", () => {
  const nodes = [{ role: "combobox", name: "Plan", ref: "e1", value: "Pro", options: [{ name: "Free" }, { name: "Pro", selected: true }] }];
  assert.deepEqual(tree(nodes), ['- combobox "Plan" [ref=e1]: "Pro"']);
  assert.deepEqual(tree(nodes, { options: true }), ['- combobox "Plan" [ref=e1]: "Pro"', '  - option "Free"', '  - option "Pro" [selected]']);
  assert.equal(tree([{ ...nodes[0], expanded: true }]).length, 3);
});

test("interactive: controls and their named ancestors; unnamed controls keep their text", () => {
  const nodes = [
    { role: "main", children: [{ role: "heading", name: "Title", level: 1 }, "Intro text", { role: "navigation", name: "Main", ref: "e1", children: [{ role: "link", name: "Home", ref: "e2", act: 1 }] }] },
    { role: "generic", ref: "e3", act: 1, children: ["Clickable div"] },
    { role: "table", name: "Scores", children: [{ role: "row", children: [{ role: "cell", name: "Ada" }] }] },
  ];
  assert.deepEqual(tree(nodes, { interactive: true }), ['- navigation "Main" [ref=e1]:', '  - link "Home" [ref=e2]', '- generic [ref=e3]: "Clickable div"']);
});

test("diff: changes carry their unchanged ancestors as context", () => {
  const before = ["- main:", "  - list:", '    - listitem: "One"', '  - button "Save" [ref=e1]'];
  const after = ["- main:", "  - list:", '    - listitem: "One"', '    - listitem: "Two"', '  - button "Save" [ref=e1] [disabled]'];
  assert.deepEqual(diffLines(before, after), [
    "  - main:",
    "    - list:",
    '+     - listitem: "Two"',
    '-   - button "Save" [ref=e1]',
    '+   - button "Save" [ref=e1] [disabled]',
  ]);
  assert.deepEqual(diffLines(before, before), []);
  assert.deepEqual(diffLines([], ["- a"]), ["+ - a"]);
});

test("print choice: the diff prints when it is at least 30% shorter than the tree", () => {
  const body = Array.from({ length: 20 }, (_, i) => `- button "B${i}" [ref=e${i + 1}]`);
  const header = ["title: T", "url: http://h/"];
  const changed = body.map((l, i) => (i === 7 ? l + " [focused]" : l));
  const small = new Snapshot({ header, body: changed, previous: body });
  assert.equal(small.usesDiff, true);
  assert.equal(String(small), small.diff);
  assert.match(small.diff, /^title: T\nurl: http:\/\/h\/\n# changes since the previous snapshot/);
  const rewritten = new Snapshot({ header, body: body.map((l) => l.replace("B", "C")), previous: body });
  assert.equal(rewritten.usesDiff, false);
  assert.equal(String(rewritten), rewritten.tree);
  const first = new Snapshot({ header, body });
  assert.equal(first.usesDiff, false);
  assert.match(first.diff, /# no previous snapshot/);
  const same = new Snapshot({ header, body, previous: body });
  assert.equal(String(same), "title: T\nurl: http://h/\n# no changes since the previous snapshot");
  const cut = new Snapshot({ header, body, maxChars: 60 });
  assert.match(cut.tree, /# truncated: \d+ of \d+ characters shown/);
});

test("keys: combos split on + with a trailing plus key", () => {
  assert.deepEqual(splitKeyCombo("Meta+a"), ["Meta", "a"]);
  assert.deepEqual(splitKeyCombo("Shift+KeyC"), ["Shift", "KeyC"]);
  assert.deepEqual(splitKeyCombo("Control++"), ["Control", "+"]);
  assert.deepEqual(splitKeyCombo("+"), ["+"]);
});

test("keys: Shift maps codes to shifted keys; Meta suppresses text", () => {
  assert.deepEqual(describeKey("KeyC", new Set(["Shift"])), { key: "C", code: "KeyC", keyCode: 67, text: "C", location: 0 });
  assert.equal(describeKey("KeyC", new Set()).key, "c");
  assert.equal(describeKey("Digit1", new Set(["Shift"])).key, "!");
  assert.equal(describeKey("a", new Set(["Meta"])).text, "");
  assert.equal(describeKey("Enter", new Set()).text, "\r");
  assert.equal(describeKey("Shift", new Set()).code, "ShiftLeft");
  assert.equal(describeKey("é", new Set()).text, "é");
  assert.throws(() => describeKey("NotAKey", new Set()), /Unknown key/);
});

test("rewrite: top-level declarations become scope assignments; the last expression is the result", () => {
  const r = rewriteTopLevel("const a = 1, { b, c: [d] } = o;\nlet e;\nfunction f() { return a; }\nclass G {}\na + 1");
  assert.deepEqual(r.names.sort(), ["G", "a", "b", "d", "e", "f"]);
  assert.match(r.source, /^f = function f\(\) \{ return a; \};/);
  assert.match(r.source, /void \(a = 1\); void \(\(\{ b, c: \[d\] \} = o\)\);/);
  assert.match(r.source, /__cmuxLast = \(a \+ 1\);$/);
  assert.deepEqual(rewriteTopLevel("for (const x of y) { const z = x; }").names, []);
  assert.match(rewriteTopLevel('await import("node:fs")').source, /__cmuxImport\("node:fs"\)/);
});

test("rewrite: bindings persist across cells, including closures", async () => {
  const host = { setTimeout, clearTimeout, now: Date.now };
  const repl = createReplSession({ host, globals: [] });
  assert.equal((await repl.evaluate("const n = 2; function twice() { return n * 2; }")).ok, true);
  assert.equal((await repl.evaluate("let m = await Promise.resolve(n + 1); twice() + m")).value, 7);
  assert.equal((await repl.evaluate("n = 5; twice()")).value, 10);
  assert.equal((await repl.evaluate("Promise.resolve(3)")).value, 3);
  const err = await repl.evaluate("throw new TypeError('boom')");
  assert.equal(err.ok, false);
  assert.equal(err.error, "TypeError: boom");
});

test("inspect: Node-like formatting; strings print raw at the top level", () => {
  assert.equal(inspect("plain"), "plain");
  assert.equal(inspect({ a: 1, b: ["s", null], c: { d: true } }), "{ a: 1, b: [ 's', null ], c: { d: true } }");
  assert.equal(inspect(new Map([["k", 1]])), "Map(1) { 'k' => 1 }");
  assert.equal(inspect([]), "[]");
  assert.equal(inspect(ns.core.Buffer.from("hi")), "<Buffer 68 69>");
  assert.equal(inspect(Promise.resolve(1)), "Promise { <pending> }");
  const long = inspect({ alpha: "a".repeat(30), beta: "b".repeat(30), gamma: "c".repeat(30) });
  assert.match(long, /^\{\n  alpha: 'a+',\n  beta: 'b+',\n  gamma: 'c+'\n\}$/);
});

test("url: the JavaScriptCore fallback matches WHATWG URL for common cases", () => {
  for (const [input, base] of [
    ["http://Example.COM:80/a/./b/../c?x=1#h", undefined],
    ["https://h:443", undefined],
    ["../x?y", "http://h/a/b/c"],
    ["//other/p", "https://h/"],
    ["?q", "http://h/p?old"],
    ["about:blank", undefined],
  ]) {
    assert.equal(new MiniURL(input, base).href, new URL(input, base).href, input);
  }
});

test("fs sandbox: the session directory and the temp directory only", () => {
  const work = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cmux-repl-unit-")));
  try {
    const op = createFsOp({ workDir: work, tmpdir: os.tmpdir() });
    op("writeFile", { path: path.join(work, "a.txt"), base64: Buffer.from("x").toString("base64") });
    assert.equal(Buffer.from(op("readFile", { path: path.join(work, "a.txt") }), "base64").toString(), "x");
    assert.throws(() => op("readFile", { path: "/etc/hosts" }), (e) => e.code === "EACCES");
    assert.throws(() => op("writeFile", { path: path.join(work, "../../outside.txt"), base64: "" }), (e) => e.code === "EACCES" || e.code === undefined);
    assert.throws(() => op("rm", { path: work, recursive: true }), (e) => e.code === "EACCES");
    fs.symlinkSync("/etc", path.join(work, "link"));
    assert.throws(() => op("readFile", { path: path.join(work, "link/hosts") }), (e) => e.code === "EACCES");
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

test("refs: bound to DOM nodes; survive renames; never reused; removed refs fail fast", async () => {
  const server = await startFixtureServers();
  try {
    const out = await runDevRepl(`
      await page.goto(${JSON.stringify(server.origins.primary + "/")});
      await page.evaluate(() => { document.body.innerHTML = '<button id=a>Alpha</button><button id=b>Beta</button>'; });
      const s1 = await snapshot({ interactive: true });
      await page.evaluate(() => { document.getElementById("b").textContent = "Beta2"; document.getElementById("a").remove(); document.body.insertAdjacentHTML("beforeend", "<button>Gamma</button>"); });
      const s2 = await snapshot({ interactive: true });
      console.log("S1", JSON.stringify(s1.tree.split("\\n").slice(2)));
      console.log("S2", JSON.stringify(s2.tree.split("\\n").slice(2)));
      const started = Date.now();
      try { await page.locator("e1").click(); } catch (e) { console.log("STALE", e.message, Date.now() - started < 5000); }
      try { await page.locator("e9").click(); } catch (e) { console.log("UNKNOWN", e.message); }
    `);
    const line = (tag) => JSON.parse(out.split("\n").find((l) => l.startsWith(tag + " ")).slice(tag.length + 1));
    assert.deepEqual(line("S1"), ['- button "Alpha" [ref=e1]', '- button "Beta" [ref=e2]']);
    assert.deepEqual(line("S2"), ['- button "Beta2" [ref=e2]', '- button "Gamma" [ref=e3]']);
    assert.match(out, /STALE ref e1 is stale: the element was removed; take a new snapshot true/);
    assert.match(out, /UNKNOWN ref e9 does not exist; take a new snapshot/);
  } finally {
    await server.close();
  }
});

test("auto-print: the last value prints, promises are awaited, undefined prints nothing", async () => {
  assert.equal(await runDevRepl("1 + 1"), "2");
  assert.equal(await runDevRepl("Promise.resolve({ a: [1] })"), "{ a: [ 1 ] }");
  assert.equal(await runDevRepl("const x = 1;"), "");
  assert.equal(await runDevRepl("undefined"), "");
  assert.equal(await runDevRepl("console.log('a'); 'b'"), "a\nb");
});
