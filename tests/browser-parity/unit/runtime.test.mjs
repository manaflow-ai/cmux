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
import { loadRuntime, runDevRepl, createFsOp, createDevBrowser, createDevRepl, createNodeHost } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";
import { makeTestDir, removeTestDir, removeTestDirIfEmpty } from "../lib/test-dirs.mjs";

const ns = loadRuntime();
const { shape, interactiveOnly, render, diffLines, textChanges, Snapshot } = ns.snapshot;
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

test("shape: a closed combobox lists its options inline, capped; one line each on request or when expanded", () => {
  const nodes = [{ role: "combobox", name: "Plan", ref: "e1", value: "Pro", options: [{ name: "Free" }, { name: "Pro", selected: true }] }];
  assert.deepEqual(tree(nodes), ['- combobox "Plan" [ref=e1] [options: Free, Pro]: "Pro"']);
  const many = [{ role: "combobox", name: "Dept", ref: "e2", value: "All", options: Array.from({ length: 13 }, (_, i) => ({ name: `D${i}` })) }];
  assert.deepEqual(tree(many), ['- combobox "Dept" [ref=e2] [options: D0, D1, D2, D3, D4, D5, D6, D7, D8, D9, +3 more]: "All"']);
  assert.deepEqual(tree(nodes, { options: true }), ['- combobox "Plan" [ref=e1]: "Pro"', '  - option "Free"', '  - option "Pro" [selected]']);
  assert.equal(tree([{ ...nodes[0], expanded: true }]).length, 3);
});

test("interactive: controls and their named ancestors; unnamed controls keep their text", () => {
  const nodes = [
    { role: "main", children: [{ role: "heading", name: "Title", level: 1 }, "Intro text", { role: "navigation", name: "Main", ref: "e1", children: [{ role: "link", name: "Home", ref: "e2", act: 1 }] }] },
    { role: "generic", ref: "e3", act: 1, children: ["Clickable div"] },
    { role: "table", name: "Scores", children: [{ role: "row", children: [{ role: "cell", name: "Ada" }] }] },
  ];
  // Headings and landmarks stay as the page outline.
  assert.deepEqual(tree(nodes, { interactive: true }), ['- main:', '  - heading "Title" [level=1]', '  - navigation "Main" [ref=e1]:', '    - link "Home" [ref=e2]', '- generic [ref=e3]: "Clickable div"']);
});

test("shape: punctuation-only text joins the texts around it or is dropped next to elements", () => {
  const link = (n, r) => ({ role: "link", name: n, ref: r, act: 1 });
  assert.deepEqual(tree([link("new", "e1"), "|", link("past", "e2"), "(", link("site.com", "e3"), ")", "10 points by", "|", "ada", "·"]),
    ['- link "new" [ref=e1]', '- link "past" [ref=e2]', '- link "site.com" [ref=e3]', '- text: "10 points by | ada"']);
});

test("shape: a header row says so; a link with no name shows its URL", () => {
  const cell = (role, t) => ({ role, children: [t] });
  assert.deepEqual(tree([{ role: "table", children: [{ role: "row", children: [cell("columnheader", "User"), cell("columnheader", "Action")] }, { role: "row", children: [cell("cell", "Ada"), cell("cell", "Edit")] }] }]),
    ['- table:', '  - row [header]: "User | Action"', '  - row: "Ada | Edit"']);
  assert.deepEqual(tree([{ role: "link", name: "Logo", ref: "e1", url: "/logo", children: [{ role: "img", name: "Logo" }] }, { role: "link", ref: "e2", url: "/home" }, { role: "link", name: "Home", ref: "e3", url: "/home", children: ["Home"] }]),
    ['- link "Logo" [ref=e1] [url=/logo]', '- link [ref=e2] [url=/home]', '- link "Home" [ref=e3]']);
});

test("diff: changes carry their unchanged ancestors as context", () => {
  const before = ["- main:", "  - list:", '    - listitem: "One"', '  - button "Save" [ref=e1]'];
  const after = ["- main:", "  - list:", '    - listitem: "One"', '    - listitem: "Two"', '  - button "Save" [ref=e1] [disabled]'];
  assert.deepEqual(diffLines(before, after), [
    "  - main:",
    "    - list:",
    '+     - listitem: "Two"',
    '~   - button "Save" [ref=e1] [disabled]',
  ]);
  assert.deepEqual(diffLines(before, before), []);
  assert.deepEqual(diffLines([], ["- a"]), ["+ - a"]);
});

test("diff: page text that reads like a ref never pairs with a real ref", () => {
  // The text sits before the button, so a key read from anywhere in a line
  // would pair the text's removal with the button's change and hide it.
  const before = ['- text: "[ref=e1]"', '- button "Save" [ref=e1]'];
  const after = ['- button "Save" [ref=e1] [disabled]'];
  assert.deepEqual(diffLines(before, after), [
    '- - text: "[ref=e1]"',
    '~ - button "Save" [ref=e1] [disabled]',
  ]);
  // A name or value that reads like a ref is page text too.
  assert.deepEqual(diffLines(['- link "x [ref=e2]"', '- link "Go" [ref=e2]'], ['- link "Go" [ref=e2] [focused]']), [
    '- - link "x [ref=e2]"',
    '~ - link "Go" [ref=e2] [focused]',
  ]);
  // Added text that contains a ref marker is still text for an interactive diff.
  const full = ["- main:", '  - textbox "Email" [ref=e1]'];
  const fullAfter = ["- main:", '  - textbox "Email" [ref=e1]', '  - text: "Saved [ref=e9]"'];
  assert.deepEqual(textChanges(diffLines(full, fullAfter)), ["  - main:", '+   - text: "Saved [ref=e9]"']);
});

test("print choice: a small tree prints its diff when shorter; a large one needs 30%", () => {
  const form = ['- heading "Sign up" [level=1]', '- textbox "Email" [ref=e1]', '- textbox "Name" [ref=e2]', '- checkbox "Accept terms" [ref=e3]',
    '- combobox "Plan" [ref=e4] [options: Free, Pro, Team]: "Pro"', '- button "Create account" [ref=e5]', '- text: "Already have an account?"', '- link "Sign in" [ref=e6]'];
  const filled = new Snapshot({ header: ["title: F", "url: http://f/"], body: form.map((l, i) => (i === 1 ? '- textbox "Email" [ref=e1] [focused]: "me@x.com"' : l)), previous: form });
  assert.equal(filled.usesDiff, true);
  const big = Array.from({ length: 120 }, (_, i) => `- button "Button number ${i}" [ref=e${i + 1}]`);
  const most = big.map((l, i) => (i % 10 ? l + " [focused]" : l));
  assert.equal(new Snapshot({ header: [], body: most, previous: big }).usesDiff, false);
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
  // maxChars limits what prints; .tree stays complete.
  const cut = new Snapshot({ header, body, maxChars: 200 });
  assert.match(String(cut), /# truncated: [\d,]+ of [\d,]+ characters shown/);
  assert.ok(String(cut).length <= 200);
  assert.equal(cut.tree, [...header, ...body].join("\n"));
});

test("shape: a control with its own ref keeps its name when its children have refs", () => {
  assert.deepEqual(tree([{ role: "button", name: "Guides", ref: "e1", act: 1, expanded: false, children: [{ role: "link", name: "Guides", ref: "e2", act: 1 }] }]),
    ['- button "Guides" [ref=e1] [expanded=false]:', '  - link "Guides" [ref=e2]']);
  // Without a ref of its own the name still gives way to the children.
  assert.deepEqual(tree([{ role: "heading", name: "Intro", level: 2, children: [{ role: "link", name: "Intro", ref: "e3", act: 1 }] }]),
    ['- heading [level=2]:', '  - link "Intro" [ref=e3]']);
});

test("shape: names and texts compare without case; off-site links say where they go", () => {
  assert.deepEqual(tree([{ role: "link", name: "main content", ref: "e1", children: ["Main content"] }]), ['- link "main content" [ref=e1]']);
  assert.deepEqual(tree([{ role: "link", name: "Docs", ref: "e2", url: "https://example.org/docs/page", offsite: "example.org/docs/…", children: ["Docs"] }]),
    ['- link "Docs" [ref=e2] [url=example.org/docs/…]']);
  assert.deepEqual(tree([{ role: "link", name: "Docs", ref: "e2", url: "https://example.org/docs/page", offsite: "example.org/docs/…", children: ["Docs"] }], { urls: true }),
    ['- link "Docs" [ref=e2] [url=https://example.org/docs/page]']);
});

test("render: an unnamed link's URL is short: host form off-site, capped on-site", () => {
  const long = "/clk/?p=" + "x".repeat(200);
  assert.deepEqual(tree([{ role: "link", ref: "e1", url: "https://ads.example.com" + long, offsite: "ads.example.com/clk/…" }]), ['- link [ref=e1] [url=ads.example.com/clk/…]']);
  assert.deepEqual(tree([{ role: "link", ref: "e2", url: long }]), [`- link [ref=e2] [url=${long.slice(0, 99)}…]`]);
  assert.deepEqual(tree([{ role: "link", ref: "e2", url: long }], { urls: true }), [`- link [ref=e2] [url=${long}]`]);
});

test("diff: an interactive diff carries added or changed text from the full tree", () => {
  const before = ["- main:", '  - textbox "Email" [ref=e1]', '  - text: "Waiting"'];
  const after = ["- main:", '  - textbox "Email" [ref=e1]: "me@x.com"', '  - text: "Submitted me@x.com"'];
  assert.deepEqual(textChanges(diffLines(before, after)), ["  - main:", '+   - text: "Submitted me@x.com"']);
  const s = new Snapshot({ header: [], body: ['- textbox "Email" [ref=e1]: "me@x.com"'], previous: ['- textbox "Email" [ref=e1]'], extraChanges: textChanges(diffLines(before, after)) });
  assert.match(s.diff, /Submitted me@x\.com/);
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

// A promise the test settles, and timers that fire only when the test says,
// so the cells below interleave in one fixed order on any machine.
function deferred() {
  let resolve;
  const promise = new Promise((r) => { resolve = r; });
  return { promise, resolve };
}
function manualTimers() {
  const pending = [];
  return { setTimeout: (fn) => pending.push(fn), fire: () => pending.splice(0).forEach((fn) => fn()) };
}

test("cancel: a cancel for an earlier cell id never ends the cell running now", async () => {
  const host = { setTimeout, clearTimeout, now: Date.now };
  const gate = deferred();
  const repl = createReplSession({ host, globals: [{ gate: gate.promise }] });
  const first = repl.evaluate("await new Promise(() => {})", { id: 1 });
  assert.equal(repl.cancel("timed out", 1), true);
  assert.equal((await first).ok, false);
  // A late cancel for cell 1 arrives while cell 2 runs.
  const second = repl.evaluate("await gate", { id: 2 });
  repl.cancel("timed out", 1);
  gate.resolve(42);
  const r = await second;
  assert.equal(r.ok, true, r.error);
  assert.equal(r.value, 42);
});

test("cancel: output a cancelled cell prints later does not reach the next cell", async () => {
  const printed = [];
  const host = { setTimeout, clearTimeout, now: Date.now };
  const console = { log: (...a) => printed.push(a.join(" ")) };
  const timers = manualTimers();
  const gate = deferred();
  const repl = createReplSession({ host, globals: [{ console, setTimeout: timers.setTimeout, gate: gate.promise }] });
  const hung = repl.evaluate("setTimeout(() => console.log('late from cell 1'), 30); await new Promise(() => {})", { id: 1 });
  repl.cancel("timed out", 1);
  await hung;
  // Cell 1's timer fires while cell 2 runs.
  const running = repl.evaluate("await gate; console.log('cell 2')", { id: 2 });
  timers.fire();
  gate.resolve();
  const next = await running;
  assert.equal(next.ok, true, next.error);
  assert.deepEqual(printed, ["cell 2"]);
});

// A Session over a driver that records calls, with a host whose timers fire
// only when the test says so.
function fakeSession() {
  const timers = [];
  const calls = [];
  const host = {
    setTimeout: (fn) => (timers.push(fn), timers.length),
    clearTimeout: () => {},
    now: Date.now,
    print: () => {},
  };
  const driver = {
    call: async (method, params) => {
      calls.push({ method, params });
      return method === "tab.info" ? { url: "https://example.com/", title: "T", viewport: { width: 1, height: 1 } } : null;
    },
    on: () => () => {},
    capabilities: () => [],
  };
  const session = new ns.core.Session({ driver, host });
  const fire = () => timers.splice(0).forEach((fn) => fn());
  return { session, calls, fire };
}

// How a call stands once the event loop has nothing left to run: the fake
// driver answers at once and the host's timers fire only on fire(), so a
// call still "pending" after the queue drains is waiting on something
// that will never come, with no wall clock involved.
async function settledState(promise) {
  const probe = { state: "pending" };
  promise.then(() => { probe.state = "answered"; }, (e) => { probe.state = "failed: " + e.message; });
  for (let turn = 0; turn < 100 && probe.state === "pending"; turn++) await new Promise((r) => setImmediate(r));
  return probe.state;
}

// A file chooser answer the driver refuses (its frame is blocked or stale
// by now) leaves the chooser open in the page; the session must still be
// able to answer it (cancel), so the runtime keeps it pending until the
// driver confirms an answer. A chooser the driver says is gone is settled.
test("file chooser: a refused answer keeps the chooser answerable; a confirmed one settles it", async () => {
  const listeners = new Map();
  const calls = [];
  let refuse = "blocked";
  const host = { setTimeout: () => 0, clearTimeout: () => {}, now: Date.now, print: () => {} };
  const driver = {
    call: async (method, params) => {
      calls.push({ method, params });
      if (method === "filechooser.respond" && refuse) {
        const e = new Error(`file chooser answer refused (${refuse})`);
        e.code = refuse;
        throw e;
      }
      return null;
    },
    on: (event, handler) => (listeners.set(event, handler), () => {}),
    capabilities: () => [],
  };
  const session = new ns.core.Session({ driver, host });
  const page = session.pageFor("t1");
  listeners.get("filechooser.opened")({ targetId: "t1", chooserId: "c1", frameId: "main", element: "h1", multiple: false });
  const held = page.fileChooser();
  assert.ok(held, "the chooser is pending");
  await assert.rejects(held.setFiles([]), /refused \(blocked\)/);
  assert.ok(page.fileChooser(), "a blocked answer left the chooser pending");
  refuse = "stale";
  await assert.rejects(page.fileChooser().cancel(), /refused \(stale\)/);
  assert.ok(page.fileChooser(), "a stale answer left the chooser pending");
  refuse = null;
  await page.fileChooser().cancel();
  assert.equal(page.fileChooser(), null, "a confirmed answer settles the chooser");
  assert.equal(calls.filter((c) => c.method === "filechooser.respond").length, 3);
  // A chooser the driver no longer has is settled, not offered again.
  listeners.get("filechooser.opened")({ targetId: "t1", chooserId: "c2", frameId: "main", element: "h2", multiple: false });
  refuse = "not_found";
  await assert.rejects(page.fileChooser().cancel(), /not_found/);
  assert.equal(page.fileChooser(), null);
});

// As Playwright's FileChooser.setFiles, the files are read before the
// chooser is answered: a path outside the REPL's directories fails with
// the file error (EACCES, so `denied`) even on an answered chooser, and an
// answered chooser is refused only for files that could be read.
test("file chooser: setFiles reports a file it cannot read before an answered chooser", async () => {
  const listeners = new Map();
  const host = { setTimeout: () => 0, clearTimeout: () => {}, now: Date.now, print: () => {} };
  const driver = { call: async () => null, on: (event, handler) => (listeners.set(event, handler), () => {}), capabilities: () => [] };
  const session = new ns.core.Session({ driver, host });
  session.files = {
    read: async (p) => {
      if (p.startsWith("/nonexistent/")) throw Object.assign(new Error(`EACCES: permission denied, '${p}' is outside the REPL's directories`), { code: "EACCES" });
      return new Uint8Array([104, 105]);
    },
  };
  const page = session.pageFor("t1");
  listeners.get("filechooser.opened")({ targetId: "t1", chooserId: "c1", frameId: "main", element: "h1", multiple: false });
  const chooser = page.fileChooser();
  await chooser.setFiles("/work/a.txt");
  assert.equal(page.fileChooser(), null, "the confirmed answer settled the chooser");
  await assert.rejects(chooser.setFiles("/nonexistent/parity.txt"), (e) => e.code === "EACCES");
  await assert.rejects(chooser.setFiles("/work/a.txt"), /already answered/);
});

// cmux replaces a tab's web view when it unloads a hidden page to save
// memory and later restores it: the new page has new frame ids. Seen live: a
// call after a forced unload addressed the old main frame and timed out with
// "Frame ... is detached" instead of running on the restored page.
test("tab.replaced: calls stop naming the frames of the web view cmux replaced", async () => {
  const listeners = new Map();
  const calls = [];
  const host = { setTimeout: () => 0, clearTimeout: () => {}, now: Date.now, print: () => {} };
  const driver = {
    call: async (method, params) => {
      calls.push({ method, params });
      if (method === "tab.info") return { url: "https://example.com/", title: "T", viewport: { width: 1, height: 1 } };
      if (method === "frame.evaluate") return 2;
      return null;
    },
    on: (event, handler) => (listeners.set(event, handler), () => {}),
    capabilities: () => [],
  };
  const session = new ns.core.Session({ driver, host });
  const page = session.pageFor("t1");
  page._mainFrame._id = "old-main";
  const child = page._frameFor("old-child", page._mainFrame);
  listeners.get("tab.replaced")({ targetId: "t1" });
  assert.equal(child._detached, true);
  assert.equal(await page.evaluate(() => 1 + 1), 2, "the page is not treated as crashed");
  const evaluation = calls.find((c) => c.method === "frame.evaluate");
  assert.notEqual(evaluation.params.frameId, "old-main");
});

test("handled events: a tab update that never settles holds later calls at most until the bound", async () => {
  const { session, calls, fire } = fakeSession();
  const page = session.pageFor("t1");
  page._handledSync = new Promise(() => {});
  const first = session.call("tab.info", { targetId: "t1" });
  await new Promise((r) => setImmediate(r));
  fire();
  assert.equal(await settledState(first), "answered");
  // The tab is not locked: the next call goes straight through.
  assert.equal(await settledState(session.call("tab.info", { targetId: "t1" })), "answered");
  assert.equal(calls.filter((c) => c.method === "tab.info").length, 2);
});

test("handled events: after a dropped update removing the last listener, the empty set is sent again", async () => {
  const { session, calls, fire } = fakeSession();
  const page = session.pageFor("t1");
  const handler = () => {};
  page.on("dialog", handler);
  await page._handledSync;
  // The update that removes the listener is lost (its job never runs).
  page._handledSync = new Promise(() => {});
  page.off("dialog", handler);
  const call = session.call("tab.info", { targetId: "t1" });
  await new Promise((r) => setImmediate(r));
  fire();
  assert.equal(await settledState(call), "answered");
  const updates = calls.filter((c) => c.method === "tab.handleEvents").map((c) => c.params.events);
  assert.deepEqual(updates.at(-1), [], JSON.stringify(updates));
});

test("cancel: a function a cancelled cell defined still prints when a later cell calls it", async () => {
  const printed = [];
  const host = { setTimeout, clearTimeout, now: Date.now };
  const console = { log: (...a) => printed.push(a.join(" ")) };
  const timers = manualTimers();
  const gate = deferred();
  const repl = createReplSession({ host, globals: [{ console, setTimeout: timers.setTimeout, gate: gate.promise }] });
  const hung = repl.evaluate("function hello() { console.log('hello'); } setTimeout(() => console.log('late from cell 1'), 30); await new Promise(() => {})", { id: 1 });
  repl.cancel("timed out", 1);
  await hung;
  // Cell 1's timer fires while cell 2 runs.
  const running = repl.evaluate("hello(); await gate; console.log('cell 2')", { id: 2 });
  timers.fire();
  gate.resolve();
  const next = await running;
  assert.equal(next.ok, true, next.error);
  assert.deepEqual(printed, ["hello", "cell 2"]);
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
  const work = makeTestDir("cmux-repl-unit-");
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
    removeTestDir(work);
  }
});

test("fs sandbox: rm, rename and lstat act on a link itself; copy and rename keep the destination on failure", () => {
  const base = makeTestDir("cmux-repl-unit-");
  const work = path.join(base, "work");
  const outside = path.join(base, "outside");
  fs.mkdirSync(work);
  fs.mkdirSync(outside);
  fs.mkdirSync(path.join(base, "tmp"));
  const secret = path.join(outside, "secret.txt");
  fs.writeFileSync(secret, "secret");
  const at = (name) => path.join(work, name);
  const text = (p) => fs.readFileSync(p, "utf8");
  try {
    const op = createFsOp({ workDir: work, tmpdir: path.join(base, "tmp") });
    const nodeFs = ns.api.createFs({ fsOp: op }, ns.api.createPath(() => work));

    fs.symlinkSync(secret, at("out-link"));
    assert.equal(op("lstat", { path: "out-link" }).type, "symlink");
    assert.equal(nodeFs.lstatSync("out-link").isSymbolicLink(), true);
    assert.throws(() => op("readFile", { path: "out-link" }), (e) => e.code === "EACCES");
    assert.throws(() => op("writeFile", { path: "out-link", base64: "" }), (e) => e.code === "EACCES");
    op("rename", { from: "out-link", to: "moved-link" });
    assert.equal(fs.readlinkSync(at("moved-link")), secret);
    op("rm", { path: "moved-link" });
    assert.equal(fs.existsSync(at("moved-link")), false);
    assert.equal(text(secret), "secret");

    fs.mkdirSync(at("data"));
    fs.writeFileSync(at("data/keep.txt"), "keep");
    fs.symlinkSync(at("data"), at("alias"));
    op("rm", { path: "alias", recursive: true });
    assert.equal(text(at("data/keep.txt")), "keep");

    fs.symlinkSync(path.join(outside, "missing.txt"), at("dangling"));
    assert.throws(() => op("writeFile", { path: "dangling", base64: "" }), (e) => e.code === "EACCES");
    op("rm", { path: "dangling" });
    assert.equal(fs.existsSync(path.join(outside, "missing.txt")), false);

    fs.writeFileSync(at("dest.txt"), "old");
    assert.throws(() => op("rename", { from: "missing.txt", to: "dest.txt" }), (e) => e.code === "ENOENT");
    fs.writeFileSync(at("unreadable.txt"), "new");
    fs.chmodSync(at("unreadable.txt"), 0o000);
    assert.throws(() => op("copyFile", { from: "unreadable.txt", to: "dest.txt" }), (e) => e.code === "EACCES");
    fs.chmodSync(at("unreadable.txt"), 0o644);
    assert.equal(text(at("dest.txt")), "old");
    assert.deepEqual(fs.readdirSync(work).sort(), ["data", "dest.txt", "unreadable.txt"]);
    op("copyFile", { from: "unreadable.txt", to: "dest.txt" });
    assert.equal(text(at("dest.txt")), "new");
  } finally {
    removeTestDir(base);
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

test("export: Google Workspace export URLs and YouTube transcripts", () => {
  const { googleExportURL, youtubeVideoId, transcriptText } = ns.api;
  assert.equal(googleExportURL("https://docs.google.com/document/d/abc_1-2/edit#heading=h", "md").url, "https://docs.google.com/document/d/abc_1-2/export?format=md");
  assert.equal(googleExportURL("https://docs.google.com/spreadsheets/d/S1/edit#gid=42", "csv").url, "https://docs.google.com/spreadsheets/d/S1/export?format=csv&gid=42");
  assert.equal(googleExportURL("https://docs.google.com/presentation/d/P9/edit", "pptx").url, "https://docs.google.com/presentation/d/P9/export/pptx");
  assert.throws(() => googleExportURL("https://docs.google.com/document/d/abc/edit", "xlsx"), /format: expected one of pdf, md/);
  assert.throws(() => googleExportURL("http://127.0.0.1:1/x", "pdf"), /expected a Google Docs, Sheets or Slides tab/);
  assert.throws(() => googleExportURL("https://evil.example/document/d/abc", "pdf"), /expected a Google Docs/);
  assert.equal(youtubeVideoId("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1"), "dQw4w9WgXcQ");
  assert.equal(youtubeVideoId("https://youtube.com/watch?v=x1"), "x1");
  assert.equal(youtubeVideoId("http://www.youtube.com/watch?v=x1"), null);
  assert.equal(youtubeVideoId("https://www.youtube.com/shorts/x1"), null);
  assert.equal(transcriptText({ events: [{ segs: [{ utf8: "Hello " }, { utf8: "world" }] }, { segs: [{ utf8: "\n" }] }, { segs: [{ utf8: "Second  line" }] }] }), "Hello world\nSecond line\n");
  assert.equal(transcriptText({}), "");
});

test("keyboard: ControlOrMeta is Meta on macOS; empty and non-string keys fail", () => {
  assert.equal(describeKey("ControlOrMeta", new Set()).key, "Meta");
  assert.throws(() => describeKey("", new Set()), /expected a non-empty string/);
  assert.throws(() => splitKeyCombo(42), /expected a non-empty string/);
});

test("url: the JavaScriptCore fallback's setters match WHATWG URL", () => {
  for (const [field, value] of [["username", "parity"], ["password", "s3cr t@"], ["hash", "x"], ["pathname", "a/../b"], ["port", "8080"], ["port", "80"], ["hostname", "Example.ORG"], ["host", "example.net:81"]]) {
    const a = new MiniURL("http://127.0.0.1:5000/p?q=1");
    const b = new URL("http://127.0.0.1:5000/p?q=1");
    a[field] = value;
    b[field] = value;
    assert.equal(a.href, b.href, `${field} = ${value}`);
  }
});

test("frames: without the driver's frame identity, an iframe is not matched to a child frame by its box", async () => {
  // A driver without frame.contentFrame cannot say which child frame an
  // <iframe> holds. Two overlapping iframes have the same box, so matching
  // by geometry could act in the wrong frame; the runtime reports none.
  const { Frame } = ns.core;
  const box = { x: 10, y: 10, width: 100, height: 80 };
  const session = {
    call: async (method) => {
      if (method === "frame.contentFrame") throw Object.assign(new Error("Unsupported driver method frame.contentFrame"), { code: "unsupported" });
      if (method === "frame.evaluate" || method === "frame.ownerBox") return box;
      throw new Error(`unexpected ${method}`);
    },
  };
  let all = [];
  const page = { _targetId: "t1", _session: session, _blockedError: () => null, _raceDialog: (p) => p, _refreshFrames: async () => {}, frames: () => all };
  const main = new Frame(page, "", null);
  all = [main, new Frame(page, "1", main), new Frame(page, "2", main)];
  assert.equal(await main._contentFrame("h1"), null);
});

test("frames: a click in a nested frame never lands on another element: a transformed <iframe> is refused, a covering element in the parent intercepts", async () => {
  // The frame's point in the tab is its owner <iframe>'s box plus the point
  // in the frame. A scale (or rotation, zoom) on the <iframe> or an ancestor
  // moves the frame's content away from that sum, and an element of the
  // parent can cover the <iframe>: the trusted click would land there.
  const server = await startFixtureServers();
  try {
    const out = await runDevRepl(`
      const scene = async (frameStyle, extra) => {
        await page.goto(${JSON.stringify(server.origins.primary + "/")});
        await page.evaluate(([frameStyle, extra]) => {
          window.clicked = [];
          document.body.style.margin = "0";
          document.body.innerHTML = extra + '<iframe style="position:absolute;left:0;top:0;width:600px;height:600px;border:0;' + frameStyle + '" srcdoc="<body style=margin:0><button style=position:absolute;left:400px;top:400px;width:100px;height:40px onclick=parent.clicked.push(&quot;target&quot;)>Target</button><button style=position:absolute;left:100px;top:160px;width:100px;height:40px onclick=parent.clicked.push(&quot;other&quot;)>Other</button></body>"></iframe>';
          for (const b of document.querySelectorAll("[data-decoy]")) b.onclick = () => window.clicked.push(b.dataset.decoy);
        }, [frameStyle, extra]);
        await page.waitForFunction(() => { const d = document.querySelector("iframe").contentDocument; return !!(d && d.querySelector("button")); });
        let error = null;
        try {
          await page.frameLocator("iframe").getByRole("button", { name: "Target" }).click({ timeout: 1500 });
        } catch (e) {
          error = String(e.message || e).split("\\n").slice(0, 2).join(" ");
        }
        return { clicked: await page.evaluate(() => window.clicked), error };
      };
      const decoy = (name, left, top) => '<button data-decoy="' + name + '" style="position:absolute;left:' + left + 'px;top:' + top + 'px;width:200px;height:200px;z-index:0">' + name + '</button>';
      const r = {
        scaled: await scene("transform:scale(0.5);transform-origin:0 0", decoy("decoy", 350, 350)),
        rotated: await scene("transform:rotate(180deg)", decoy("decoy", 350, 350)),
        covered: await scene("", '<div data-decoy="overlay" style="position:absolute;left:0;top:0;width:700px;height:700px;z-index:5"></div>'),
        translated: await scene("transform:translate(30px, 20px)", ""),
      };
      console.log("@@" + JSON.stringify(r));
    `);
    const line = out.split("\n").find((l) => l.startsWith("@@"));
    assert.ok(line, out.slice(0, 2000));
    const r = JSON.parse(line.slice(2));
    for (const name of ["scaled", "rotated"]) {
      assert.deepEqual(r[name].clicked, [], `${name}: the click landed on ${JSON.stringify(r[name].clicked)}`);
      assert.match(r[name].error || "", /transform/, `${name}: ${r[name].error}`);
    }
    assert.deepEqual(r.covered.clicked, [], `covered: the click landed on ${JSON.stringify(r.covered.clicked)}`);
    assert.match(r.covered.error || "", /intercepts pointer events/, r.covered.error);
    // A translation keeps the frame's geometry: the click reaches the target.
    assert.deepEqual(r.translated, { clicked: ["target"], error: null });
  } finally {
    await server.close();
  }
});

test("pointer: a page that moves another frame over the target when the click's pointer arrives gets no press in that frame", async () => {
  // The click checks the hit target after the pointer moves there, then
  // moves it once more and presses. A page that puts another frame (or
  // element) over the point on that last move would get the trusted press:
  // the target is checked again right before the press, and the click fails.
  const server = await startFixtureServers();
  try {
    const out = await runDevRepl(`
      await page.goto(${JSON.stringify(server.origins.primary + "/")});
      await page.evaluate(() => {
        window.clicked = [];
        document.body.style.margin = "0";
        document.body.innerHTML = '<button id="t" style="position:absolute;left:100px;top:100px;width:120px;height:40px">Target</button>' +
          '<iframe id="f" style="position:absolute;left:-1000px;top:0;width:400px;height:300px;border:0;z-index:5" srcdoc="<body style=margin:0;height:300px onmousedown=parent.clicked.push(&quot;frame-down&quot;) onclick=parent.clicked.push(&quot;frame-click&quot;)></body>"></iframe>';
        const t = document.getElementById("t");
        t.onclick = () => window.clicked.push("target");
        let moves = 0;
        t.addEventListener("mousemove", () => {
          if (++moves === 2) document.getElementById("f").style.left = "0px";
        });
      });
      await page.waitForFunction(() => { const d = document.getElementById("f").contentDocument; return !!(d && d.body); });
      let error = null;
      try {
        await page.locator("#t").click({ timeout: 1500 });
      } catch (e) {
        error = String(e.message || e).split("\\n")[0];
      }
      console.log("@@" + JSON.stringify({ clicked: await page.evaluate(() => window.clicked), error }));
    `);
    const line = out.split("\n").find((l) => l.startsWith("@@"));
    assert.ok(line, out.slice(0, 2000));
    const r = JSON.parse(line.slice(2));
    assert.deepEqual(r.clicked, [], `the press landed on ${JSON.stringify(r.clicked)}`);
    assert.match(r.error || "", /intercepts pointer events|frame/, r.error);
  } finally {
    await server.close();
  }
});

// Runs `code` in a dev session whose driver calls the page's
// `onPressWindow()` right before it handles each input.mouse down, after
// the runtime's last check: what a page can do in the driver round trip
// between that check and the press.
async function runWithPressWindow(code) {
  const browser = await createDevBrowser();
  const dir = fs.realpathSync(makeTestDir("cmux-repl-"));
  const lines = [];
  let host = null;
  try {
    const raw = browser.driver({ sessionId: "press-window" });
    const driver = Object.create(raw);
    driver.call = async (method, params = {}) => {
      if ((method === "input.mouse" && params.type === "down") || method === "input.drag") {
        await raw.call("frame.evaluate", {
          targetId: params.targetId,
          world: "page",
          source: "() => { if (typeof window.onPressWindow === 'function') window.onPressWindow(); }",
          args: [],
          handles: [],
          awaitPromise: true,
        });
      }
      return raw.call(method, params);
    };
    host = createNodeHost({ workDir: dir, sessionId: "press-window", print: (level, text) => lines.push(text) });
    const repl = createDevRepl({ host, driver });
    const r = await repl.evaluate(code);
    repl.dispose();
    await raw.detach();
    return r.ok ? lines.join("\n") : `${lines.join("\n")}\nUncaught ${r.error}`;
  } finally {
    await browser.close();
    removeTestDir(dir);
    if (host) removeTestDirIfEmpty(host.tmpdir);
  }
}

test("pointer: the driver refuses a click's press when the page changes the point in the round trip after the runtime's last check", async () => {
  // The runtime checks the target and each parent frame's <iframe> right
  // before the press, but the press is another driver call: the page runs
  // between the two. The driver checks again where it sends the press, so
  // a frame moved over the target, or a frame moved away from under the
  // pointer, gets no press.
  const server = await startFixtureServers();
  try {
    const out = await runWithPressWindow(`
      const click = async (locator) => {
        try {
          await locator.click({ timeout: 1500 });
          return null;
        } catch (e) {
          return String(e.message || e).split("\\n")[0];
        }
      };
      await page.goto(${JSON.stringify(server.origins.primary + "/")});
      await page.evaluate(() => {
        window.clicked = [];
        document.body.style.margin = "0";
        document.body.innerHTML = '<button id="t" style="position:absolute;left:100px;top:100px;width:120px;height:40px">Target</button>' +
          '<iframe id="f" style="position:absolute;left:-1000px;top:0;width:400px;height:300px;border:0;z-index:5" srcdoc="<body style=margin:0;height:300px onmousedown=parent.clicked.push(&quot;frame-down&quot;) onclick=parent.clicked.push(&quot;frame-click&quot;)></body>"></iframe>';
        document.getElementById("t").onclick = () => window.clicked.push("target");
        window.onPressWindow = () => { document.getElementById("f").style.left = "0px"; };
      });
      await page.waitForFunction(() => { const d = document.getElementById("f").contentDocument; return !!(d && d.body); });
      const covered = { error: await click(page.locator("#t")), clicked: await page.evaluate(() => window.clicked) };

      await page.evaluate(() => {
        window.clicked = [];
        document.body.innerHTML = '<button data-decoy style="position:absolute;left:300px;top:300px;width:400px;height:400px;z-index:0" onclick="clicked.push(&quot;decoy&quot;)">Decoy</button>' +
          '<iframe id="g" style="position:absolute;left:0;top:0;width:600px;height:600px;border:0;z-index:1" srcdoc="<body style=margin:0><button style=position:absolute;left:400px;top:400px;width:100px;height:40px onclick=parent.clicked.push(&quot;target&quot;)>Target</button></body>"></iframe>';
        window.onPressWindow = () => { document.getElementById("g").style.left = "700px"; };
      });
      await page.waitForFunction(() => { const d = document.getElementById("g").contentDocument; return !!(d && d.querySelector("button")); });
      const moved = { error: await click(page.frameLocator("#g").getByRole("button", { name: "Target" })), clicked: await page.evaluate(() => window.clicked) };

      await page.evaluate(() => {
        window.clicked = [];
        document.getElementById("g").style.left = "0px";
        window.onPressWindow = null;
      });
      const still = { error: await click(page.frameLocator("#g").getByRole("button", { name: "Target" })), clicked: await page.evaluate(() => window.clicked) };
      console.log("@@" + JSON.stringify({ covered, moved, still }));
    `);
    const line = out.split("\n").find((l) => l.startsWith("@@"));
    assert.ok(line, out.slice(0, 2000));
    const r = JSON.parse(line.slice(2));
    assert.deepEqual(r.covered.clicked, [], `covered: the press landed on ${JSON.stringify(r.covered.clicked)}`);
    assert.match(r.covered.error || "", /no press was sent: .*intercepts pointer events/, r.covered.error);
    assert.deepEqual(r.moved.clicked, [], `moved: the press landed on ${JSON.stringify(r.moved.clicked)}`);
    assert.match(r.moved.error || "", /no press was sent: .*(moved|intercepts pointer events)/, r.moved.error);
    // A page that leaves the point alone still gets the click.
    assert.deepEqual(r.still, { error: null, clicked: ["target"] });
  } finally {
    await server.close();
  }
});

test("pointer: a locator drag starts and drops only on the elements the runtime checked, also after the page changes the points", async () => {
  // dragTo is two points, and the page runs between the runtime's checks
  // and the driver's drag, and during the drag itself: it can put another
  // element or another (allowed) frame over the source before the press,
  // or over the target once the drag started. The driver checks the source
  // right before the press and the target right before the release, as it
  // does a click's press, and makes no drop when either changed.
  const server = await startFixtureServers();
  try {
    const out = await runWithPressWindow(`
      const drag = async () => {
        try {
          await page.locator("#s").dragTo(page.locator("#t"), { timeout: 1500 });
          return null;
        } catch (e) {
          return String(e.message || e).split("\\n")[0];
        }
      };
      const setUp = (mode) => page.evaluate((mode) => {
        window.events = [];
        document.body.style.margin = "0";
        const decoy = (left, top) => '<iframe id="d" style="position:absolute;left:' + left + 'px;top:' + top + 'px;width:200px;height:120px;border:0;z-index:5" ' +
          'srcdoc="<body style=margin:0;height:120px ondragover=event.preventDefault() ondrop=event.preventDefault();parent.events.push(&quot;decoy-drop&quot;) onmousedown=parent.events.push(&quot;decoy-down&quot;)></body>"></iframe>';
        document.body.innerHTML =
          '<div id="s" draggable="true" style="position:absolute;left:20px;top:20px;width:100px;height:60px;background:#ccc">source</div>' +
          '<div id="t" style="position:absolute;left:300px;top:300px;width:120px;height:80px;background:#eee">target</div>' +
          decoy(-1000, 0);
        const s = document.getElementById("s");
        const t = document.getElementById("t");
        s.addEventListener("dragstart", (e) => {
          e.dataTransfer.setData("text/plain", "x");
          window.events.push("dragstart");
          if (mode === "drop") { const d = document.getElementById("d"); d.style.left = "250px"; d.style.top = "280px"; }
        });
        t.addEventListener("dragenter", (e) => e.preventDefault());
        t.addEventListener("dragover", (e) => e.preventDefault());
        t.addEventListener("drop", (e) => { e.preventDefault(); window.events.push("target-drop"); });
        window.onPressWindow = mode === "start" ? () => { const d = document.getElementById("d"); d.style.left = "0px"; d.style.top = "0px"; } : null;
      }, mode);
      const ready = () => page.waitForFunction(() => { const d = document.getElementById("d").contentDocument; return !!(d && d.body); });
      const result = {};
      for (const mode of ["start", "drop", "still"]) {
        await setUp(mode);
        await ready();
        const error = await drag();
        result[mode] = { error, events: await page.evaluate(() => window.events) };
      }
      console.log("@@" + JSON.stringify(result));
    `);
    const line = out.split("\n").find((l) => l.startsWith("@@"));
    assert.ok(line, out.slice(0, 2000));
    const r = JSON.parse(line.slice(2));
    assert.ok(!r.start.events.includes("decoy-down") && !r.start.events.includes("decoy-drop"), `start: the drag reached the frame over the source: ${JSON.stringify(r.start)}`);
    assert.match(r.start.error || "", /no press was sent: /, JSON.stringify(r.start));
    assert.ok(!r.drop.events.includes("decoy-drop") && !r.drop.events.includes("target-drop"), `drop: the drop landed on ${JSON.stringify(r.drop.events)}`);
    assert.match(r.drop.error || "", /no drop was made: /, JSON.stringify(r.drop));
    // A page that leaves the points alone still gets the drop.
    assert.deepEqual(r.still, { error: null, events: ["dragstart", "target-drop"] });
  } finally {
    await server.close();
  }
});

test("frames: finding a frame's <iframe> for an action walks at most the node budget of the parent frame", async () => {
  // The parent frame is the page's: it can hold millions of elements, and a
  // walk of all of them before every action in a child frame would let it
  // stall the session. An <iframe> in the light DOM is found through the
  // frame's own place in window.frames; one in a shadow tree past the
  // snapshot's node budget (250000 elements) is not looked for.
  const server = await startFixtureServers();
  try {
    const out = await runDevRepl(`
      await page.goto(${JSON.stringify(server.origins.primary + "/")});
      await page.evaluate(() => {
        window.clicked = [];
        const button = (name) => '<button onclick=parent.clicked.push(&quot;' + name + '&quot;)>' + name + '</button>';
        document.body.innerHTML = '<div style="display:none">' + "<i></i>".repeat(260000) + '</div>' +
          '<iframe name="light" style="position:absolute;left:0;top:0;width:300px;height:100px" srcdoc="' + button("light") + '"></iframe>' +
          '<div id="host" style="position:absolute;left:0;top:200px"></div>';
        document.getElementById("host").attachShadow({ mode: "open" }).innerHTML = '<iframe name="shadow" style="width:300px;height:100px" srcdoc="' + button("shadow") + '"></iframe>';
      });
      await page.waitForFunction(() => {
        const ready = (f) => { const d = f && f.contentDocument; return !!(d && d.querySelector("button")); };
        return ready(document.querySelector("iframe")) && ready(document.getElementById("host").shadowRoot.querySelector("iframe"));
      });
      // An action refreshes the page's frame list.
      await page.mouse.click(1200, 700);
      const result = {};
      for (const name of ["light", "shadow"]) {
        try {
          await page.frame(name).getByRole("button").click({ timeout: 3000 });
          result[name] = "clicked";
        } catch (e) {
          result[name] = String(e.message || e).split("\\n").slice(0, 2).join(" ");
        }
      }
      result.clicked = await page.evaluate(() => window.clicked);
      console.log("@@" + JSON.stringify(result));
    `);
    const line = out.split("\n").find((l) => l.startsWith("@@"));
    assert.ok(line, out.slice(0, 2000));
    const r = JSON.parse(line.slice(2));
    assert.equal(r.light, "clicked", r.light);
    assert.match(r.shadow, /node budget/, `the shadow-tree <iframe> past the budget was looked for: ${r.shadow}`);
    assert.deepEqual(r.clicked, ["light"]);
  } finally {
    await server.close();
  }
});

test("network: requests that never finish are not kept without bound", () => {
  const { session } = fakeSession();
  const page = session.pageFor("t1");
  const seen = [];
  page.on("response", (r) => seen.push(r.request().url()));
  for (let i = 0; i < 5000; i++) page._onNetwork({ requestId: `r${i}`, url: `https://example.com/${i}`, method: "GET" }, "request");
  // A page that opens many long-lived requests (streams, long polls) keeps only the newest.
  assert.ok(page._requests.size <= 1000, `${page._requests.size} requests kept`);
  // The newest still pairs with its response; an evicted one still reports its own.
  page._onNetwork({ requestId: "r4999", url: "https://example.com/4999", status: 200 }, "response");
  page._onNetwork({ requestId: "r0", url: "https://example.com/0", status: 200 }, "response");
  assert.deepEqual(seen, ["https://example.com/4999", "https://example.com/0"]);
});

test("snapshot header: page text reaches the caller without controls or escape sequences, and bounded", () => {
  // A title can carry terminal escapes (here OSC 52, a clipboard write) and C1 controls.
  const title = "Inbox\u001b]52;c;cHduZWQ=\u0007\u001b[2J\u009b31mRed\u0085\u009d0;spoof\u009c" + "t".repeat(5000);
  const s = new Snapshot({ header: [`title: ${title}`, "url: https://example.com/"], body: ['- button "Go" [ref=e1]'] });
  const text = String(s);
  assert.doesNotMatch(text, /[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/);
  const first = text.split("\n")[0];
  assert.ok(first.startsWith("title: InboxRedttt"), JSON.stringify(first.slice(0, 40)));
  assert.ok(first.length <= 600, `title line is ${first.length} characters`);
  assert.match(text, /\nurl: https:\/\/example\.com\/\n- button "Go" \[ref=e1\]$/);
});

test("snapshot: the page walk stops at its node budget with a note, and frames past the budget are not read", async () => {
  // A hostile page can hold millions of nodes; the walk must not read them all
  // before the output limits apply. `_maxNodes` lowers the budget for the test.
  const server = await startFixtureServers();
  try {
    const out = await runDevRepl(`
      await page.goto(${JSON.stringify(server.origins.primary + "/")});
      await page.evaluate(() => {
        document.body.innerHTML = '<iframe title="inner" srcdoc="<button>Inner</button>"></iframe><button>First</button>' + "<p>filler</p>".repeat(2000) + "<button>Last</button>";
      });
      await page.waitForFunction(() => { const d = document.querySelector("iframe").contentDocument; return !!(d && d.querySelector("button")); });
      const whole = await snapshot({ maxChars: Infinity });
      const cut = await snapshot({ maxChars: Infinity, _maxNodes: 500 });
      const keep = (s) => s.tree.split("\\n").filter((l) => /button|iframe|^#/.test(l));
      console.log("@@" + JSON.stringify({ whole: keep(whole), cut: keep(cut) }));
    `);
    const line = out.split("\n").find((l) => l.startsWith("@@"));
    assert.ok(line, out.slice(0, 2000));
    const { whole, cut } = JSON.parse(line.slice(2));
    assert.ok(whole.some((l) => /button "Inner"/.test(l)), whole.slice(0, 6).join("\n"));
    assert.ok(whole.some((l) => /button "Last"/.test(l)));
    assert.ok(cut.some((l) => /button "First"/.test(l)), cut.slice(0, 6).join("\n"));
    assert.ok(!cut.some((l) => /button "Last"/.test(l)), "the walk read past its budget");
    assert.ok(!cut.some((l) => /button "Inner"/.test(l)), "a frame past the budget was read");
    assert.ok(cut.some((l) => /iframe "inner".*\[not read: the snapshot's node budget is used up\]/.test(l)), cut.slice(0, 6).join("\n"));
    assert.match(cut[cut.length - 1], /^# the page is too large to read whole: the snapshot stopped after 500 nodes/);
  } finally {
    await server.close();
  }
});

test("snapshot: one huge text or value is cut at the snapshot's size budget with a note, per frame and in total", async () => {
  // The node budget does not bound one node: a hostile page can put
  // megabytes in one text node or field value, which would cross to the
  // session, be kept as the diff baseline and be diffed. The walk stops at
  // a size budget (characters), per frame and over all frames, and says so.
  // `_maxSize` lowers it for the test.
  const server = await startFixtureServers();
  try {
    const out = await runDevRepl(`
      await page.goto(${JSON.stringify(server.origins.primary + "/")});
      await page.evaluate(() => {
        document.body.innerHTML = '<button>First</button><p id="big"></p><textarea aria-label="Field"></textarea><button>Last</button><iframe title="inner" srcdoc="<button>Inner</button>"></iframe>';
        document.getElementById("big").textContent = "A".repeat(5000000);
        document.querySelector("textarea").value = "V".repeat(5000000);
      });
      await page.waitForFunction(() => { const d = document.querySelector("iframe").contentDocument; return !!(d && d.querySelector("button")); });
      const whole = await snapshot({ maxChars: Infinity });
      const small = await snapshot({ maxChars: Infinity, _maxSize: 3000 });
      const keep = (s) => s.tree.split("\\n").filter((l) => /button|iframe|^#/.test(l));
      console.log("@@" + JSON.stringify({ wholeLength: whole.tree.length, whole: keep(whole), smallLength: small.tree.length, small: keep(small) }));
    `);
    const line = out.split("\n").find((l) => l.startsWith("@@"));
    assert.ok(line, out.slice(0, 2000));
    const { wholeLength, whole, smallLength, small } = JSON.parse(line.slice(2));
    assert.ok(wholeLength < 2200000, `a 10,000,000-character page printed a ${wholeLength}-character tree`);
    assert.match(whole[whole.length - 1], /^# the page is too large to read whole: the snapshot stopped after [\d,]+ characters/, whole.join("\n"));
    assert.ok(smallLength < 3600, `the tree is ${smallLength} characters`);
    assert.ok(small.some((l) => /button "First"/.test(l)), small.join("\n"));
    assert.ok(!small.some((l) => /button "Last"|button "Inner"/.test(l)), small.join("\n"));
    assert.match(small[small.length - 1], /^# the page is too large to read whole: the snapshot stopped after 3,000 characters/, small.join("\n"));
  } finally {
    await server.close();
  }
});

test("snapshot: reading outside the walk (offscreen counts, table shape) stays within the walk's bounds", async () => {
  // Counting the interactive elements outside the viewport, and telling a
  // layout table from a data table, read DOM the walk does not visit. Both
  // read lazily and stop at a bound: the offscreen count reads at most the
  // walk's node budget of elements and then says it is a lower bound, and a
  // table's shape is judged from its first 50 rows (a later row of another
  // length does not make a 60,000-row table a layout table).
  // `_maxNodes` lowers the budget for the test.
  const server = await startFixtureServers();
  try {
    const out = await runDevRepl(`
      await page.goto(${JSON.stringify(server.origins.primary + "/")});
      await page.evaluate(() => {
        document.body.innerHTML = '<button>Seen</button><div id="off" style="position:absolute;top:100000px"></div>';
        const off = document.getElementById("off");
        const b = document.createElement("button");
        b.textContent = "x";
        for (let i = 0; i < 5000; i++) off.appendChild(b.cloneNode(true));
      });
      const offscreen = (await snapshot({ viewport: true, maxChars: Infinity, _maxNodes: 1000 })).tree.split("\\n").filter((l) => /outside the viewport/.test(l));
      await page.evaluate(() => {
        const t = document.createElement("table");
        const tb = t.appendChild(document.createElement("tbody"));
        const row = document.createElement("tr");
        for (let j = 0; j < 3; j++) row.appendChild(document.createElement("td")).textContent = "c" + j;
        for (let i = 0; i < 60000; i++) tb.appendChild(row.cloneNode(true));
        tb.lastChild.appendChild(document.createElement("td")).textContent = "extra";
        document.body.replaceChildren(t);
      });
      const table = (await snapshot({ maxChars: Infinity, _maxNodes: 200 })).tree.split("\\n").slice(2, 6);
      console.log("@@" + JSON.stringify({ offscreen, table }));
    `);
    const line = out.split("\n").find((l) => l.startsWith("@@"));
    assert.ok(line, out.slice(0, 2000));
    const { offscreen, table } = JSON.parse(line.slice(2));
    assert.equal(offscreen.length, 1, JSON.stringify(offscreen));
    const m = /^# at least ([\d,]+) interactive elements outside the viewport are not shown/.exec(offscreen[0]);
    assert.ok(m, offscreen[0]);
    assert.ok(Number(m[1].replace(/,/g, "")) <= 1000, offscreen[0]);
    assert.ok(table.some((l) => /^- table/.test(l)) && table.some((l) => /row: "c0 \| c1 \| c2"/.test(l)), table.join("\n"));
  } finally {
    await server.close();
  }
});

// Page text reaches the caller's terminal. Escape sequences and other C0,
// C1 and DEL controls a page puts in its text, title, option labels, URLs or
// error messages print as visible escapes (`\u001b`), never raw, whichever
// path prints them: console.log, the auto-printed value, a snapshot, page
// tools, or an error. Newlines and tabs stay.
test("printing: control characters from the page never reach the output raw", async () => {
  const servers = await startFixtureServers();
  const { primary } = servers.origins;
  try {
    const hostile = "A\u001b]0;pwned\u0007B\u001b[2JC\u009b31mD\u0090dcs\u009cE\u007fF\rG\u0000H";
    const out = await runDevRepl(`
await page.goto(${JSON.stringify(primary)} + "/index.html?controls");
await page.evaluate((t) => {
  document.title = t;
  document.body.innerHTML = '<p id="p"></p><select aria-label="Pick"><option></option></select><a id="a" href="#">link</a>';
  document.getElementById("p").textContent = t;
  document.querySelector("option").textContent = t;
  document.getElementById("a").href = "https://example.com/" + encodeURIComponent(t) + "#" + t;
}, ${JSON.stringify(hostile)});
console.log(await page.textContent("#p"));
console.log([await page.title()]);
console.log(await snapshot({ urls: true }));
console.log(await page.evaluate(() => ({ text: document.title })));
await page.evaluate((t) => { throw new Error(t); }, ${JSON.stringify(hostile)});`);
    const raw = out.match(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/gu) || [];
    assert.deepEqual(raw, [], `raw controls in output:\n${JSON.stringify(out)}`);
    assert.match(out, /A\\u001b\]0;pwned\\u0007B/, out);
    assert.match(out, /Uncaught .*A\\u001b/, out);
  } finally {
    await servers.close();
  }
});
