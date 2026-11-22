// The parity runner's own browser host for host-* backends: started on a
// private socket, stopped by its exact PID at the end, also when the run
// fails, so no `cmux-browser-host serve` outlives a parity run.
//
//   node --test tests/browser-parity/unit/parity-host.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startOwnHost, withOwnHost } from "../lib/parity-host.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
// A stand-in for `cmux-browser-host serve --socket S`: listens on S, stays.
const fake = { cmd: process.execPath, args: [path.join(here, "fixtures", "fake-host.mjs")] };

const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

test("the host listens on a private socket and stops by its PID", async () => {
  const host = await startOwnHost(fake);
  assert.ok(alive(host.pid), "the host runs");
  assert.ok(fs.existsSync(host.socket), "the socket exists");
  assert.equal((fs.statSync(path.dirname(host.socket)).mode & 0o777).toString(8), "700");
  await host.stop();
  assert.ok(!alive(host.pid), "the host stopped");
  assert.ok(!fs.existsSync(path.dirname(host.socket)), "its directory is removed");
});

test("a failing run still stops the host", async () => {
  let pid = null;
  await assert.rejects(
    withOwnHost(fake, async (host) => {
      pid = host.pid;
      throw new Error("scenario crashed");
    }),
    /scenario crashed/,
  );
  assert.ok(pid && !alive(pid), "the host stopped after the failure");
});
