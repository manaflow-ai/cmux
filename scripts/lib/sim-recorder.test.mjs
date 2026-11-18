// Run with: node --test scripts/lib/sim-recorder.test.mjs
//
// scripts/lib/sim-recorder.sh records a simulator's screen in the background and finishes the file on
// SIGINT. The handoff step's recorder never got that SIGINT (the background job was a shell running a
// `simctl` function, and a non-interactive shell's background jobs ignore SIGINT), so `wait` blocked
// until the step's lease ran out: steps 09bc28d701780bcefcc1c9bc and 05134d4e25a61d5f1df3bc13 hung
// after "simulator restored". Linux-runnable: a stand-in `xcrun` records until SIGINT and finishes
// the file then.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const library = path.join(repoRoot, "scripts/lib/sim-recorder.sh");

function fixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sim-recorder-"));
  const bin = path.join(dir, "bin");
  fs.mkdirSync(bin);
  // Like `simctl io recordVideo`: runs until SIGINT, then writes the file's end and exits 0. Without
  // a SIGINT it gives up after 20 s and exits 3, so a recorder that never got one fails the test.
  fs.writeFileSync(path.join(bin, "xcrun"), `#!/usr/bin/env python3
import signal, sys, time
out = sys.argv[sys.argv.index("--force") + 1]
open("${dir}/argv", "w").write(" ".join(sys.argv[1:]))
def finish(*_):
    open(out, "w").write("finished on SIGINT")
    sys.exit(0)
signal.signal(signal.SIGINT, finish)
open("${dir}/started", "w").write("")
time.sleep(20)
sys.exit(3)
`, { mode: 0o755 });
  return { dir, env: { ...process.env, PATH: `${bin}:${process.env.PATH}` } };
}

function run(dir, env, setArg) {
  const script = `
source "${library}"
sim_recorder_start UDID-1 "${dir}/recording.mp4" "${dir}/recording.log" ${setArg}
until [[ -e "${dir}/started" ]]; do read -r -t 0.05 <> <(:) || true; done
t0=$SECONDS
sim_recorder_stop
echo "stopped after $((SECONDS - t0)) s"
`;
  return spawnSync("bash", ["-c", script], { env, encoding: "utf8", timeout: 30_000 });
}

test("stopping the recorder delivers SIGINT to recordVideo and finishes the file at once", () => {
  const { dir, env } = fixture();
  const r = run(dir, env, `"${dir}/set"`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /stopped after [0-2] s/, "the recorder did not get the SIGINT: stop waited for it to give up");
  assert.equal(fs.readFileSync(path.join(dir, "recording.mp4"), "utf8"), "finished on SIGINT");
  assert.equal(fs.readFileSync(path.join(dir, "argv"), "utf8"),
    `simctl --set ${dir}/set io UDID-1 recordVideo --codec h264 --force ${dir}/recording.mp4`);
});

test("without a device set it records on the default set", () => {
  const { dir, env } = fixture();
  const r = run(dir, env, "");
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /stopped after [0-2] s/);
  assert.equal(fs.readFileSync(path.join(dir, "argv"), "utf8"),
    `simctl io UDID-1 recordVideo --codec h264 --force ${dir}/recording.mp4`);
});

test("stopping when nothing records does nothing", () => {
  const r = spawnSync("bash", ["-c", `source "${library}"; sim_recorder_stop; echo ok`], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), "ok");
});
