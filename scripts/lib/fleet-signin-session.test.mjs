// Run with: node --test scripts/lib/fleet-signin-session.test.mjs
//
// scripts/lib/fleet-signin-session.sh reads the session a fleet step receives from its submitter
// ($CMUX_CI_SIGNIN_FILE) and hands it to one `simctl launch` only. Linux-runnable: a stand-in `xcrun`
// records what the launch got.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const library = path.join(repoRoot, "scripts/lib/fleet-signin-session.sh");
const TOKEN = "TEST-ONLY-step-session-refresh-token-0123456789";

function fixture({ mode = 0o600, session } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleet-signin-"));
  const bin = path.join(dir, "bin");
  fs.mkdirSync(bin);
  // The stand-in xcrun writes which SIMCTL_CHILD_ variables a launch got, and whether the token was among them.
  fs.writeFileSync(path.join(bin, "xcrun"), `#!/bin/bash
{ echo "argv: $*"; env | grep '^SIMCTL_CHILD_' | sed 's/=.*//' | sort
  [[ "$SIMCTL_CHILD_CMUX_MOBILE_STACK_REFRESH_TOKEN" == "${TOKEN}" ]] && echo "token reached the launch"; } >> "${dir}/launches"
exit 0
`, { mode: 0o755 });
  const file = path.join(dir, "session.json");
  fs.writeFileSync(file, JSON.stringify(session ?? {
    profile: "agent", email: "agent@example.com", project: "454ecd03-1db2-4050-845e-4ce5b0cd9895", refresh_token: TOKEN,
  }));
  fs.chmodSync(file, mode);
  return { dir, bin, file };
}

function run(body, { bin, file, env = {} }) {
  const result = spawnSync("bash", ["-c", `set -euo pipefail\nsource "$1"\n${body}`, "test", library], {
    encoding: "utf8",
    env: { PATH: `${bin}:/usr/bin:/bin`, HOME: os.tmpdir(), ...(file ? { CMUX_CI_SIGNIN_FILE: file } : {}), ...env },
  });
  return result;
}

test("the session reaches one simctl launch and nothing else", () => {
  const f = fixture();
  const r = run(`
cmux_fleet_signin_load
echo "account=$CMUX_FLEET_SIGNIN_EMAIL"
cmux_fleet_signin_simctl --set "${f.dir}/sims" launch UDID-1 dev.cmux.mobile.tag
env > "${f.dir}/child-env"
xcrun simctl launch UDID-1 dev.cmux.mobile.tag
cmux_fleet_signin_forget
cmux_fleet_signin_simctl launch UDID-1 dev.cmux.mobile.tag || echo "no session after forget"
`, f);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /account=agent@example\.com/);
  assert.match(r.stdout, /no session after forget/);
  const launches = fs.readFileSync(path.join(f.dir, "launches"), "utf8");
  assert.equal(launches.match(/token reached the launch/g)?.length, 1, launches);
  assert.match(launches, /argv: simctl --set \S+\/sims launch UDID-1 dev\.cmux\.mobile\.tag\nSIMCTL_CHILD_CMUX_MOBILE_STACK_REFRESH_TOKEN\ntoken reached/);
  assert.doesNotMatch(fs.readFileSync(path.join(f.dir, "child-env"), "utf8"), new RegExp(TOKEN), "a child of the script inherits the token");
  assert.doesNotMatch(r.stdout + r.stderr, new RegExp(TOKEN));
});

test("a step sent without --sign-in, or a file anyone else can read, is refused without its value", () => {
  for (const [what, opts, reason] of [
    ["no file named", { file: undefined }, /cmux-ci run --sign-in agent/],
    ["a missing file", { file: "/nonexistent/session.json" }, /not a regular file/],
    ["a group- or world-readable file", { mode: 0o644 }, /mode 0600/],
    ["another profile", { session: { profile: "personal", email: "me@example.com", project: "p", refresh_token: TOKEN } }, /not an agent session/],
    ["no refresh token", { session: { profile: "agent", email: "agent@example.com", project: "p" } }, /not an agent session/],
  ]) {
    const f = fixture(opts);
    const file = "file" in opts ? opts.file : f.file;
    const r = run(`cmux_fleet_signin_load || { echo "refused: $CMUX_FLEET_SIGNIN_ERROR"; exit 7; }`, { bin: f.bin, file });
    assert.equal(r.status, 7, `${what}: ${r.stdout}${r.stderr}`);
    assert.match(r.stdout, reason, what);
    assert.doesNotMatch(r.stdout + r.stderr, new RegExp(TOKEN), what);
  }
});
