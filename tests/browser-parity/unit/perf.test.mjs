// Performance guards on the stress pages (fixtures/stress) through the dev
// driver. They compare the runtime with itself (scaling ratios, bounded
// output) rather than with wall-clock limits, so a slower machine does not
// fail them; the absolute limits are generous backstops.
// tests/browser-parity/perf/bench.mjs has the numbers.
//
//   node --test tests/browser-parity/unit/
import test from "node:test";
import assert from "node:assert/strict";
import { runDevRepl } from "../lib/dev-driver.mjs";
import { startFixtureServers } from "../lib/fixture-server.mjs";

const servers = await startFixtureServers();
test.after(() => servers.close());
const { primary, peer } = servers.origins;
const stress = (kind, n, extra = "") => `${primary}/stress/stress.html?kind=${kind}&n=${n}${extra}`;
const run = async (code) => {
  const out = await runDevRepl(code);
  const line = out.split("\n").find((l) => l.startsWith("@@"));
  assert.ok(line, out.slice(0, 2000));
  return JSON.parse(line.slice(2));
};

test("perf: page traversal time grows linearly with the page", async () => {
  const r = await run(`const t = {};
for (const n of [10000, 40000]) {
  await page.goto(${JSON.stringify(stress("cards", "N"))}.replace("n=N", "n=" + n));
  await snapshot();
  const runs = [];
  for (let i = 0; i < 3; i++) runs.push((await snapshot())._timing.agentMs);
  t[n] = Math.min(...runs);
}
console.log("@@" + JSON.stringify(t));`);
  const ratio = r[40000] / Math.max(1, r[10000]);
  // Linear is 4; the quadratic label lookup this guards against was 14+.
  assert.ok(ratio < 7, `4x the elements took ${ratio.toFixed(1)}x the time (${JSON.stringify(r)})`);
  assert.ok(r[40000] < 5000, `40k elements took ${r[40000]}ms`);
});

test("perf: a 5,000-item page prints within the budget and keeps the whole tree", async () => {
  const r = await run(`await page.goto(${JSON.stringify(stress("list", 5000))});
const s = await snapshot();
console.log("@@" + JSON.stringify({ printed: String(s).length, tree: s.tree.length, items: (s.tree.match(/link "Item \\d+"/g) || []).length, note: String(s).split("\\n").pop() }));`);
  assert.ok(r.printed <= 20000 + 200, `printed ${r.printed} characters`);
  assert.equal(r.items, 5000);
  assert.match(r.note, /^# condensed to/);
});

test("perf: snapshots across two large pages in one session stay fast", async () => {
  // The previous tree is a different page: a full-rewrite diff of ~50k lines.
  const r = await run(`const t0 = Date.now();
await page.goto(${JSON.stringify(stress("list", 20000))});
await snapshot();
await page.goto(${JSON.stringify(stress("table", 8000))});
const s = await snapshot();
const printed = String(s);
console.log("@@" + JSON.stringify({ ms: Date.now() - t0, printed: printed.length, diffMs: s._timing.diffMs }));`);
  assert.ok(r.diffMs < 3000, `the diff took ${r.diffMs}ms`);
  assert.ok(r.printed <= 20000 + 200, `printed ${r.printed} characters`);
});

test("perf: 300 frames, a third cross-origin and a third nested, snapshot in bounded time", async () => {
  const r = await run(`await page.goto(${JSON.stringify(stress("iframes", 300, `&peer=${encodeURIComponent(peer)}`))});
await page.waitForTimeout(1000);
await snapshot();
const t = Date.now();
const s = await snapshot();
console.log("@@" + JSON.stringify({ ms: Date.now() - t, frames: s._timing.frames, buttons: (s.tree.match(/button "(Frame|Inner) /g) || []).length }));`);
  assert.equal(r.frames, 1 + 300 + 100);
  assert.equal(r.buttons, 300 + 100);
  // Frames are read concurrently: well under one sequential round trip each.
  assert.ok(r.ms < 4000, `took ${r.ms}ms for ${r.frames} frames`);
});

test("perf: a 2 MB text node and a 5,000-option select print within the budget", async () => {
  const r = await run(`const out = {};
await page.goto(${JSON.stringify(stress("text", 2000000))});
out.text = String(await snapshot()).length;
await page.goto(${JSON.stringify(stress("select", 5000))});
const s = await snapshot();
out.select = String(s).length;
out.selectLine = s.tree.split("\\n").find((l) => l.includes('combobox "Pick"'));
console.log("@@" + JSON.stringify(out));`);
  assert.ok(r.text <= 20000 + 200, `text page printed ${r.text}`);
  assert.ok(r.select <= 20000 + 200, `select page printed ${r.select}`);
  assert.match(r.selectLine, /\[options: Option 0, .*\+4990 more\]/);
});
