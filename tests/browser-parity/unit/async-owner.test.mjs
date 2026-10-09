// async-owner.js: where an engine's stacks do not name a resumed async
// function's callers (JavaScriptCore before macOS 27), the rewrite carries
// the owning cell through every await, catch, finally, for await and yield,
// and gives it back when the function suspends. V8 records async stacks,
// so the runtime does not rewrite here; these tests run the rewrite itself.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const runtimeDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../Resources/browser-repl");

function load() {
  const context = vm.createContext({});
  for (const name of ["vendor/acorn.js", "async-owner.js"]) {
    vm.runInContext(fs.readFileSync(path.join(runtimeDir, name), "utf8"), context, { filename: name });
  }
  return { context, owner: vm.runInContext("CmuxBrowserRepl.asyncOwner", context) };
}

// Runs `body` (a cell's code, rewritten) as the cell `owner`, with `seen`
// recording the owner at each probe() call.
async function runCell(code, ownerName, extra = {}) {
  const { context, owner } = load();
  const seen = [];
  const probe = (label) => seen.push(`${label}:${owner.tracker.owner() ? owner.tracker.owner().name : "-"}`);
  const source = owner.instrument(code, { cell: true });
  const fn = vm.runInContext(
    `(async function (__cmuxT, __cmuxOwner, probe, extra) { const __cmuxK = __cmuxT.begin(__cmuxOwner); try {\n${source}\n} finally { __cmuxT.leave(__cmuxK); } })`,
    context,
  );
  const done = fn(owner.tracker, { name: ownerName }, probe, extra);
  probe("after-start");
  return { done, seen, owner, source };
}

test("an async function a cell awaits resumes as that cell and gives the owner back when it suspends", async () => {
  const gate = {};
  const gated = new Promise((resolve) => (gate.open = resolve));
  const { done, seen } = await runCell(
    `async function helper() { probe("helper-start"); await extra.gated; probe("helper-resumed"); return 1; }
     probe("body"); await helper(); probe("body-resumed");`,
    "cell1",
    { gated },
  );
  // Between the cell's turns the owner is no cell's.
  assert.deepEqual(seen, ["body:cell1", "helper-start:cell1", "after-start:-"]);
  gate.open();
  await done;
  assert.deepEqual(seen.slice(3), ["helper-resumed:cell1", "body-resumed:cell1"]);
});

test("a rejection resumes catch and finally blocks as the cell; for await steps and yields too", async () => {
  const { done, seen } = await runCell(
    `try { await Promise.reject(new Error("x")); } catch (e) { probe("catch"); } finally { probe("finally"); }
     async function* gen() { yield 1; probe("gen-resumed"); yield 2; }
     outer: for await (const v of gen()) { probe("loop-" + v); if (v === 2) break outer; }
     probe("after-loop");
     for await (const v of [Promise.resolve(3)]) probe("sync-" + v);
     const arrow = async () => (await null, probe("arrow"), { ok: true });
     probe("arrow-result-" + (await arrow()).ok);`,
    "cell2",
  );
  await done;
  assert.deepEqual(seen, [
    "after-start:-",
    "catch:cell2",
    "finally:cell2",
    "loop-1:cell2",
    "gen-resumed:cell2",
    "loop-2:cell2",
    "after-loop:cell2",
    "sync-3:cell2",
    "arrow:cell2",
    "arrow-result-true:cell2",
  ]);
});

test("a function another cell calls belongs to that cell, also after an await", async () => {
  const { context, owner } = load();
  const seen = [];
  const probe = (label) => seen.push(`${label}:${owner.tracker.owner() ? owner.tracker.owner().name : "-"}`);
  const define = vm.runInContext(`(function (__cmuxT, probe) { return ${owner.instrument("async function shared() { await null; probe('shared'); }")}; })`, context);
  const shared = define(owner.tracker, probe);
  const k = owner.tracker.begin({ name: "cell3" });
  const running = shared();
  owner.tracker.leave(k);
  await running;
  assert.deepEqual(seen, ["shared:cell3"]);
});

test("a rewritten function's toString() is its source as written", () => {
  const { context, owner } = load();
  const code = `async function f(a) { "use strict"; try { await a; } catch { } for await (const x of a) { } return await (a); }
const g = async (x) => ({ y: await x });
async function* h() { yield; yield* [1]; }
async function empty() {}`;
  const rewritten = owner.instrument(code);
  assert.notEqual(rewritten, code);
  assert.equal(owner.asWritten(rewritten), code);
  // The rewrite parses.
  vm.runInContext(`(function (__cmuxT) { ${rewritten}\n })`, context);
});
