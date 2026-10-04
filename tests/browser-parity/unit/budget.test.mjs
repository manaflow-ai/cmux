// Large output: the printed snapshot fits a budget (repeated siblings
// collapse, the outline and on-screen controls stay, every cut says how to
// get the rest), the diff stays fast on huge trees, and a REPL call that
// prints more than its cap spills the whole output to a file.
//
//   node --test tests/browser-parity/unit/
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { loadRuntime, createNodeHost } from "../lib/dev-driver.mjs";
import { makeTestDir, removeTestDir, removeTestDirIfEmpty } from "../lib/test-dirs.mjs";

const ns = loadRuntime();
const { shape, render, diffLines, condense, Snapshot, PRINT_BUDGET } = ns.snapshot;

const item = (i, extra = {}) => ({ role: "listitem", children: [{ role: "link", name: `Item ${i}`, ref: `e${i + 2}`, act: 1, ...extra }, `word ${i}`] });
const bigList = (n, pinned = -1) => [{ role: "navigation", name: "Items", ref: "e1", children: [{ role: "list", children: Array.from({ length: n }, (_, i) => item(i, i === pinned ? { vp: 1 } : {})) }] }];
const text = (lines) => lines.join("\n");

test("budget: the default print budget is 20,000 characters", () => {
  assert.equal(PRINT_BUDGET, 20000);
});

test("budget: a tree within the budget prints unchanged", () => {
  const nodes = shape(bigList(5), {});
  assert.deepEqual(condense(nodes, 20000, {}), render(nodes, {}));
});

test("budget: repeated siblings collapse to a counted line that says how to see them", () => {
  const nodes = shape(bigList(5000, 2500), {});
  const lines = condense(nodes, 4000, {});
  const out = text(lines);
  assert.ok(out.length <= 4000, `printed ${out.length} characters`);
  assert.match(out, /link "Item 0" \[ref=e2\]/);
  assert.match(out, /link "Item 2" \[ref=e4\]/);
  // The on-screen item stays where it is.
  assert.match(out, /link "Item 2500" \[ref=e2502\]/);
  const collapsed = lines.filter((l) => /^\s*- … [\d,]+ more listitem/.test(l));
  assert.ok(collapsed.length >= 1, out);
  // Counted items plus printed items account for all 5000.
  const shown = lines.filter((l) => /link "Item \d+"/.test(l)).length;
  const hidden = collapsed.reduce((a, l) => a + Number(/… ([\d,]+) more/.exec(l)[1].replace(/,/g, "")), 0);
  assert.equal(shown + hidden, 5000);
  // The scope to expand is named, and the closing note says how to get everything.
  assert.match(out, /more listitem \([\d,]+ refs\): snapshot\("e1"\)/);
  assert.match(lines[lines.length - 1], /\{ maxChars: Infinity \}\) or \.tree everything/);
  assert.match(lines[lines.length - 1], /^# condensed to [\d,]+ of [\d,]+ characters/);
});

test("budget: over budget, the outline (headings, landmarks) and on-screen controls stay", () => {
  const sections = Array.from({ length: 40 }, (_, s) => ({
    role: "region",
    name: `Section ${s}`,
    ref: `e${1000 + s}`,
    children: [{ role: "heading", name: `Heading ${s}`, level: 2 }, ...Array.from({ length: 30 }, (_, t) => `Paragraph ${s}.${t} with some words that fill the line.`),
      { role: "button", name: `Act ${s}`, ref: `e${2000 + s}`, act: 1, ...(s === 33 ? { vp: 1 } : {}) }],
  }));
  const nodes = shape([{ role: "main", children: sections }], {});
  const lines = condense(nodes, 12000, {});
  const out = text(lines);
  assert.ok(out.length <= 12000, `printed ${out.length} characters`);
  for (let s = 0; s < 40; s++) assert.match(out, new RegExp(`heading "Heading ${s}"`), `heading ${s} kept`);
  assert.match(out, /button "Act 33" \[ref=e2033\]/);
  assert.match(out, /Paragraph 0\.0 /, "the top of the page prints in full");
  // A cut inside a region with a ref names that ref.
  assert.match(out, /- … \d+ more lines? \(\d+ refs?\): snapshot\("e10\d\d"/);
});

test("budget: a node too large to print alone is cut with a note, never silently", () => {
  const nodes = shape([{ role: "paragraph", children: ["x".repeat(50000)] }, { role: "button", name: "After", ref: "e1", act: 1 }], {});
  const out = text(condense(nodes, 3000, {}));
  assert.ok(out.length <= 3000, `printed ${out.length} characters`);
  assert.match(out, /button "After" \[ref=e1\]/);
  assert.match(out, /# condensed to/);
});

test("snapshot: printing uses the budget; .tree and .diff stay complete", () => {
  const nodes = shape(bigList(3000), {});
  const body = render(nodes, {});
  const header = ["title: T", "url: http://h/"];
  const s = new Snapshot({ header, body, nodes, maxChars: 6000 });
  assert.ok(String(s).length <= 6000 + 40, `printed ${String(s).length}`);
  assert.ok(String(s).startsWith("title: T\nurl: http://h/\n"));
  assert.equal(s.tree, [...header, ...body].join("\n"));
  const all = new Snapshot({ header, body, nodes, maxChars: Infinity });
  assert.equal(String(all), s.tree);
  // A diff larger than the budget prints the condensed tree instead.
  const next = new Snapshot({ header, body: body.map((l) => l.replace("word", "term")), nodes, previous: body, maxChars: 6000 });
  assert.ok(String(next).length <= 6000 + 40);
  assert.doesNotMatch(String(next), /# changes since/);
});

test("diff: stays near-linear on huge trees", () => {
  const n = 100000;
  const a = Array.from({ length: n }, (_, i) => `  - link "Item ${i}" [ref=e${i}]`);
  const b = a.slice();
  b[50000] = '  - link "Item 50000 (changed)" [ref=e50000]';
  let t = Date.now();
  const one = diffLines(a, b);
  assert.deepEqual(one, ['~   - link "Item 50000 (changed)" [ref=e50000]']);
  assert.ok(Date.now() - t < 2000, `one change took ${Date.now() - t}ms`);
  // Everything changed: no quadratic blow-up in time or memory.
  const c = Array.from({ length: 50000 }, (_, i) => `- text: "other ${i}"`);
  t = Date.now();
  const all = diffLines(a.slice(0, 50000), c);
  assert.equal(all.filter((l) => l.startsWith("+ ")).length, 50000);
  assert.equal(all.filter((l) => l.startsWith("- ")).length, 50000);
  assert.ok(Date.now() - t < 3000, `a full rewrite took ${Date.now() - t}ms`);
  // Moves and interleaved edits still produce a minimal-looking diff.
  const d = a.slice(0, 2000);
  const e = d.slice();
  e.splice(10, 0, '  - text: "inserted"');
  e.splice(1500, 1);
  assert.deepEqual(diffLines(d, e), ['+   - text: "inserted"', '-   - link "Item 1499" [ref=e1499]']);
});

test("repl output: a call over its cap prints the head and spills everything to a file", async () => {
  const workDir = makeTestDir("cap-");
  const printed = [];
  const host = createNodeHost({ workDir, sessionId: `cap-${process.pid}`, print: (level, t) => printed.push(t) });
  const gate = ns.replHost.createOutputGate(host, { maxOutput: 5000 });
  const line = (i) => `line ${i} ` + "y".repeat(90);
  for (let i = 0; i < 100; i++) gate.print("log", line(i));
  gate.finish();
  const shown = printed.join("\n");
  assert.ok(shown.length <= 5000 + 400, `printed ${shown.length}`);
  assert.match(shown, /^line 0 /);
  const note = /# output truncated: [\d,]+ of [\d,]+ characters shown; full output: (\S+)/.exec(shown);
  assert.ok(note, shown.slice(-600));
  const file = fs.readFileSync(note[1], "utf8");
  assert.equal(file, Array.from({ length: 100 }, (_, i) => line(i)).join("\n") + "\n");
  // The end of the output shows too.
  assert.match(shown, /line 99 /);
  // One line longer than the cap prints its start.
  printed.length = 0;
  const long = ns.replHost.createOutputGate(host, { maxOutput: 5000 });
  long.print("log", "z".repeat(60000));
  long.finish();
  assert.match(printed[0], /^z{3000,4000}…$/);
  assert.match(printed.at(-1), /# output truncated: [\d,]+ of 60,001 characters shown/);
  // No cap: everything prints.
  printed.length = 0;
  const open = ns.replHost.createOutputGate(host, { maxOutput: 0 });
  for (let i = 0; i < 100; i++) open.print("log", line(i));
  open.finish();
  assert.equal(printed.length, 100);
  removeTestDir(workDir);
});

test("repl output: no limit (0) still spills past a hard ceiling instead of printing everything", () => {
  const workDir = makeTestDir("cap-");
  let printedChars = 0;
  const notes = [];
  const host = createNodeHost({
    workDir,
    sessionId: `hard-${process.pid}`,
    print: (level, t) => {
      printedChars += t.length + 1;
      if (t.startsWith("# output")) notes.push(t);
    },
  });
  const line = "w".repeat(9999);
  for (const maxOutput of [0, Infinity, 1e12]) {
    printedChars = 0;
    notes.length = 0;
    const gate = ns.replHost.createOutputGate(host, { maxOutput });
    for (let i = 0; i < 600; i++) gate.print("log", line);
    gate.finish();
    // 6,000,000 characters printed; at most the ceiling (4,000,000) reaches the caller.
    assert.ok(printedChars <= 4_000_000 + 1000, `maxOutput ${maxOutput}: printed ${printedChars}`);
    const full = /full output: (\S+)$/.exec(notes.at(-1) || "");
    assert.ok(full, `maxOutput ${maxOutput}: ${notes.join(" | ")}`);
    assert.equal(fs.statSync(full[1]).size, 600 * 10000);
  }
  removeTestDir(workDir);
});

test("repl output: the runtime's own error reports go through the call's output gate", async () => {
  const workDir = makeTestDir("cap-");
  let printedChars = 0;
  const notes = [];
  const host = createNodeHost({
    workDir,
    sessionId: `report-${process.pid}`,
    print: (level, t) => {
      printedChars += t.length + 1;
      if (t.startsWith("# output")) notes.push(t);
    },
  });
  const driver = { call: async () => null, on: () => () => {}, capabilities: () => [] };
  const repl = ns.replHost.createBrowserRepl({ host, driver });
  // The gate is the call's from the moment evaluate() starts; an event
  // listener's error reported meanwhile is output of that call.
  const running = repl.evaluate("await 0", { maxOutput: 5000 });
  repl.session.reportError("e".repeat(50000));
  const r = await running;
  assert.ok(r.ok, r.error);
  assert.ok(printedChars <= 5000 + 400, `printed ${printedChars} characters past a 5,000 cap`);
  assert.ok(notes.some((t) => /full output: \S+/.test(t)), notes.join(" | "));
  removeTestDir(workDir);
});

test("frames: a frame that never answers is left out and marked, and the rest of the page reads", async () => {
  const host = { setTimeout: (fn, ms) => setTimeout(fn, ms), clearTimeout: (t) => clearTimeout(t) };
  const hung = { p: "f1", _detached: false, _agent: () => new Promise(() => {}) };
  const ok = { p: "f2", _detached: false, _agent: async () => ({ nodes: [{ role: "button", name: "Inside", ref: "e1", act: 1 }], max: 1 }) };
  const main = {
    p: "",
    _agent: async () => ({ nodes: [{ role: "iframe", name: "Hung", ref: "e1", frame: "h1" }, { role: "iframe", name: "Fine", ref: "e2", frame: "h2" }], max: 2 }),
    _contentFrame: async (handle) => (handle === "h1" ? hung : ok),
  };
  const page = { _session: { host }, _refMaxFor: () => 0, _noteRefMax() {}, _noteRefDocs() {}, _prefixFor: (f) => f.p };
  const t = Date.now();
  const nodes = await ns.snapshot.frameNodes(page, main, null, { _frameTimeout: 200 }, true);
  assert.ok(Date.now() - t < 2000);
  assert.deepEqual(render(shape(nodes, {}), {}), [
    '- iframe "Hung" [ref=e1] [not read: timed out]',
    '- iframe "Fine" [ref=e2]:',
    '  - button "Inside" [ref=f2e1]',
  ]);
});

test("frames: a frame the domain policy blocks is left out and marked", async () => {
  // The driver refuses to read a frame that shows a blocked page (code
  // "blocked"); the snapshot says why the iframe is empty.
  const host = { setTimeout: (fn, ms) => setTimeout(fn, ms), clearTimeout: (t) => clearTimeout(t) };
  const refusal = Object.assign(new Error("Frame 7 shows https://blocked.example, which the domain policy blocks"), { code: "blocked" });
  const blocked = { p: "f1", _detached: false, _agent: async () => { throw refusal; } };
  const ok = { p: "f2", _detached: false, _agent: async () => ({ nodes: [{ role: "button", name: "Inside", ref: "e1", act: 1 }], max: 1 }) };
  const main = {
    p: "",
    _agent: async () => ({ nodes: [{ role: "iframe", name: "Ad", ref: "e1", frame: "h1" }, { role: "iframe", name: "Fine", ref: "e2", frame: "h2" }], max: 2 }),
    _contentFrame: async (handle) => (handle === "h1" ? blocked : ok),
  };
  const page = { _session: { host }, _refMaxFor: () => 0, _noteRefMax() {}, _noteRefDocs() {}, _prefixFor: (f) => f.p };
  const nodes = await ns.snapshot.frameNodes(page, main, null, {}, true);
  assert.deepEqual(render(shape(nodes, {}), {}), [
    '- iframe "Ad" [ref=e1] [not read: blocked by the domain policy]',
    '- iframe "Fine" [ref=e2]:',
    '  - button "Inside" [ref=f2e1]',
  ]);
});
