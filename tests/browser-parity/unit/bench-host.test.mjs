// The bench's host-headless backend runs every `cmux-browser-host eval` on
// a host of its own (a private socket) and stops that host by its exact PID
// when the bench ends. Before, the first eval started a detached `serve` on
// the default socket that outlived the bench.
//
//   node --test tests/browser-parity/unit/bench-host.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { hostHeadlessBackend } from "../perf/bench.mjs";
import { makeTestDir, removeTestDir } from "../lib/test-dirs.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));

const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

test("the bench's host-headless backend runs on a host of its own and stops it", async () => {
  const dir = makeTestDir("bench-host-");
  const log = path.join(dir, "log");
  const saved = { bin: process.env.PARITY_HOST_BIN, log: process.env.FAKE_HOST_LOG };
  process.env.PARITY_HOST_BIN = path.join(here, "fixtures", "fake-host-cli.mjs");
  process.env.FAKE_HOST_LOG = log;
  try {
    const backend = await hostHeadlessBackend();
    await backend.overhead();
    await backend.close();
    const rows = fs.readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l));
    const serves = rows.filter((r) => r.serve);
    assert.equal(serves.length, 1, `one host for the bench: ${JSON.stringify(rows)}`);
    const calls = rows.filter((r) => r.cmd);
    assert.ok(calls.length > 0);
    assert.ok(calls.every((r) => r.socket === serves[0].socket), `every call uses that host: ${JSON.stringify(calls)}`);
    assert.ok(!alive(serves[0].serve), "the host stopped with the bench");
  } finally {
    for (const [key, value] of [["PARITY_HOST_BIN", saved.bin], ["FAKE_HOST_LOG", saved.log]]) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    removeTestDir(dir);
  }
});
