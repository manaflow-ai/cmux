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
  assert.match(out, /snapshot\("e1", \{ maxChars: Infinity \}\)/);
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
  const lines = condense(nodes, 5000, {});
  const out = text(lines);
  assert.ok(out.length <= 5000, `printed ${out.length} characters`);
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
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "cap-"));
  const printed = [];
  const host = createNodeHost({ workDir, sessionId: `cap-${process.pid}`, print: (level, t) => printed.push(t) });
  const gate = ns.replHost.createOutputGate(host, { maxOutput: 5000 });
  const line = (i) => `line ${i} ` + "y".repeat(990);
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
  // No cap: everything prints.
  printed.length = 0;
  const open = ns.replHost.createOutputGate(host, { maxOutput: 0 });
  for (let i = 0; i < 100; i++) open.print("log", line(i));
  open.finish();
  assert.equal(printed.length, 100);
  fs.rmSync(workDir, { recursive: true, force: true });
});
