// What the runtime keeps of page-driven events (downloads, blocked
// navigations) is bounded: a page can start them without end, and the
// session keeps them for its life (r21 runtime findings 1 and 2).
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createNodeHost, createDevRepl } from "../lib/dev-driver.mjs";
import { makeTestDir, removeTestDir } from "../lib/test-dirs.mjs";

// A REPL session over a driver that answers every call and lets the test
// send events.
async function withFakeDriver(fn) {
  const dir = makeTestDir("cmux-repl-retention-");
  const lines = [];
  const host = createNodeHost({ workDir: dir, sessionId: `retention-${process.pid}`, print: (level, text) => lines.push(text) });
  const handlers = new Map();
  const driver = {
    name: "fake",
    async call(method) {
      if (method === "tabs.list") return [{ targetId: "t1", url: "https://example.com/", title: "t" }];
      return null;
    },
    on: (event, handler) => handlers.set(event, handler),
    capabilities: () => [],
    detach() {},
    setDomainPolicy() {},
  };
  const repl = createDevRepl({ host, driver });
  const emit = (event, payload) => {
    const handler = handlers.get(event) || handlers.get("*");
    assert.ok(handler, `the runtime listens for ${event}`);
    handler(payload);
  };
  // What the cell passed to out(value), through a file in the session's
  // directory (a print is cut at 20,000 characters).
  const read = async (code) => {
    const file = path.join(dir, "result.json");
    fs.rmSync(file, { force: true });
    const r = await repl.evaluate(`const out = (v) => fs.writeFileSync("result.json", JSON.stringify(v));\n${code}`);
    assert.equal(r.ok, true, `${r.error}\n${lines.slice(-5).join("\n")}`);
    return JSON.parse(fs.readFileSync(file, "utf8"));
  };
  try {
    await fn({ emit, read });
  } finally {
    repl.dispose();
    removeTestDir(dir);
    removeTestDir(host.tmpdir);
  }
}

test("downloads: finished records past the cap are dropped oldest first, and a dropped download reads as gone", async () => {
  await withFakeDriver(async ({ emit, read }) => {
    emit("tab.created", { targetId: "t1", url: "https://example.com/" });
    await read(`globalThis.p = await tabs.use("t1"); globalThis.seen = []; p.on("download", (d) => seen.push(d)); out(seen.length);`);
    const started = (i) => emit("download.started", { targetId: "t1", downloadId: `d${i}`, url: `https://example.com/f${i}`, suggestedFilename: `f${i}` });
    const finished = (i) => emit("download.finished", { targetId: "t1", downloadId: `d${i}`, path: `/x/f${i}` });
    // 3,000 downloads that finish, then 1,500 that never do.
    for (let i = 0; i < 3000; i++) {
      started(i);
      finished(i);
    }
    for (let i = 3000; i < 4500; i++) started(i);
    // A late finish for a dropped download changes nothing.
    finished(0);
    finished(3000);
    const r = await read(`
      const list = session.downloads();
      // A download still running has not settled after many turns of the
      // microtask queue; a finished or dropped one has.
      const turns = async () => { for (let i = 0; i < 20; i++) await null; return "pending"; };
      const settled = await Promise.all([seen[0], seen[3000], seen[4499]].map((d) => Promise.race([d.failure(), turns()])));
      out({ count: list.length, ids: list.map((d) => d.id), urls: list.map((d) => d.url), states: list.map((d) => d.state), kept: p._downloads ? p._downloads.size : 0, settled });
    `);
    assert.ok(r.count <= 1000, `session.downloads() keeps ${r.count} records`);
    assert.ok(r.kept <= 1000, `the page keeps ${r.kept} download records`);
    // Every record is its own download, never another's.
    r.ids.forEach((id, k) => assert.equal(r.urls[k], `https://example.com/f${id.slice(1)}`));
    assert.equal(new Set(r.ids).size, r.ids.length);
    // Unfinished ones outlive finished ones; the newest are kept.
    assert.ok(r.ids.includes("d4499"), "the newest download was dropped");
    assert.ok(!r.ids.includes("d0"), "a late finish brought back a dropped download");
    assert.equal(r.states[r.ids.indexOf("d4499")], "started");
    // seen[0] finished before it was dropped; the oldest unfinished one
    // past the page's cap settles as gone instead of never.
    assert.equal(r.settled[0], null);
    assert.match(String(r.settled[1]), /gone/);
    assert.equal(r.settled[2], "pending");
  });
});
