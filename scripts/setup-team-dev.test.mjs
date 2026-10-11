// Run with: node --test scripts/setup-team-dev.test.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const script = fileURLToPath(new URL("./setup-team-dev.sh", import.meta.url));
const original = [
  "# Keep both profiles and unrelated configuration.",
  "CMUX_DOGFOOD_STACK_EMAIL=person@example.com",
  "CMUX_DOGFOOD_STACK_PASSWORD=old-fixture-password",
  "CMUX_UITEST_STACK_EMAIL=agent@example.com",
  "CMUX_UITEST_STACK_PASSWORD=agent-fixture-password",
  "EXTRA_CONFIG=retained",
  "",
].join("\n");

function refresh(t, response, curlStatus = 0) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-setup-refresh-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const secrets = path.join(home, ".secrets");
  fs.mkdirSync(secrets, { mode: 0o700 });
  const credentials = path.join(secrets, "cmuxterm-dev.env");
  fs.writeFileSync(credentials, original, { mode: 0o600 });
  const bin = path.join(home, "bin");
  fs.mkdirSync(bin);
  // No real network or credentials: consume the request and return a fixture.
  fs.writeFileSync(path.join(bin, "curl"), [
    "#!/bin/bash",
    'cat > "$HOME/request.json"',
    ...(curlStatus === 0 ? [`printf '%s' '${JSON.stringify(response)}'`] : []),
    `exit ${curlStatus}`,
  ].join("\n"), { mode: 0o700 });
  const result = spawnSync("/bin/bash", [script, "--refresh"], {
    encoding: "utf8",
    input: "person@example.com\nnew-fixture-password\n",
    env: { HOME: home, PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin` },
    timeout: 10_000,
  });
  assert.equal(result.error, undefined);
  assert.doesNotMatch(result.stdout + result.stderr, /new-fixture-password|agent-fixture-password/);
  return { result, credentials, home };
}

test("refresh verifies a replacement and preserves the agent profile", (t) => {
  const { result, credentials, home } = refresh(t, { access_token: "fixture-token" });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(home, "request.json"), "utf8")), {
    email: "person@example.com", password: "new-fixture-password",
  });
  const updated = fs.readFileSync(credentials, "utf8");
  assert.match(updated, /CMUX_DOGFOOD_STACK_PASSWORD=new-fixture-password/);
  assert.doesNotMatch(updated, /old-fixture-password/);
  assert.match(updated, /CMUX_UITEST_STACK_PASSWORD=agent-fixture-password/);
  assert.match(updated, /EXTRA_CONFIG=retained/);
  assert.equal(fs.statSync(credentials).mode & 0o777, 0o600);
});

test("rejected replacement leaves both profiles unchanged", (t) => {
  const { result, credentials } = refresh(t, { code: "EMAIL_PASSWORD_MISMATCH" });
  assert.notEqual(result.status, 0);
  assert.equal(fs.readFileSync(credentials, "utf8"), original);
});

test("unavailable sign-in service leaves both profiles unchanged", (t) => {
  const { result, credentials } = refresh(t, {}, 7);
  assert.notEqual(result.status, 0);
  assert.equal(fs.readFileSync(credentials, "utf8"), original);
});
