import assert from "node:assert/strict";
import {
  chmodSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const repositoryRoot = path.resolve(import.meta.dir, "../..");

function fixtureDirectory() {
  const directory = mkdtempSync(path.join(os.tmpdir(), "cmux-prod-gate-test-"));
  chmodSync(directory, 0o700);
  return directory;
}

function run(command, args, environment = {}) {
  return spawnSync(command, args, {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: { ...process.env, ...environment },
  });
}

test("explicit credentials file is exclusive and accepts either supported key pair", (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const credentialsFile = path.join(directory, "credentials.env");
  writeFileSync(credentialsFile, [
    "CMUX_UITEST_STACK_EMAIL=temporary@example.com",
    "CMUX_UITEST_STACK_PASSWORD=temporary-password",
    "",
  ].join("\n"), { mode: 0o600 });
  chmodSync(credentialsFile, 0o600);

  const result = run("bash", ["-c", [
    "source scripts/lib/dev-secrets.sh",
    "cmux_dev_secrets_load --credentials-file \"$CREDENTIALS_FILE\"",
    "! env | grep -Eq '^CMUX_(DOGFOOD|UITEST)_STACK_(EMAIL|PASSWORD)='",
    "printf '%s\\n%s\\n' \"$CMUX_UITEST_STACK_EMAIL\" \"$CMUX_UITEST_STACK_PASSWORD\"",
  ].join("; ")], {
    CREDENTIALS_FILE: credentialsFile,
    CMUX_DOGFOOD_STACK_EMAIL: "ambient@example.com",
    CMUX_DOGFOOD_STACK_PASSWORD: "ambient-password",
  });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, [
    "==> dev sign-in account: [redacted]",
    "temporary@example.com",
    "temporary-password",
    "",
  ].join("\n"));
  assert.doesNotMatch(result.stderr, /temporary@example|temporary-password|ambient@example|ambient-password/u);
});

test("explicit credentials file rejects permissive modes and symlinks", (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const credentialsFile = path.join(directory, "credentials.env");
  writeFileSync(credentialsFile, "CMUX_UITEST_STACK_EMAIL=x\nCMUX_UITEST_STACK_PASSWORD=y\n", {
    mode: 0o640,
  });
  chmodSync(credentialsFile, 0o640);
  const symlink = path.join(directory, "credentials-link.env");
  symlinkSync(credentialsFile, symlink);

  for (const candidate of [credentialsFile, symlink]) {
    const result = run("bash", ["-c", [
      "source scripts/lib/dev-secrets.sh",
      "cmux_dev_secrets_load --credentials-file \"$CREDENTIALS_FILE\"",
    ].join("; ")], { CREDENTIALS_FILE: candidate });
    assert.equal(result.status, 2);
    assert.doesNotMatch(result.stderr, /temporary-password|ambient-password/u);
  }
});

test("production release-gate flags fail before creating runtime state", () => {
  const conflictingBase = run("bash", [
    "scripts/run-iroh-release-gate.sh",
    "--mode", "automatic",
    "--tag", "prodtest",
    "--production",
    "--staging-base-url", "https://example.com",
  ]);
  assert.equal(conflictingBase.status, 2);
  assert.match(conflictingBase.stderr, /cannot be combined/u);

  const reusedBuild = run("bash", [
    "scripts/run-iroh-release-gate.sh",
    "--mode", "automatic",
    "--tag", "prodtest",
    "--production",
    "--skip-build",
  ]);
  assert.equal(reusedBuild.status, 2);
  assert.match(reusedBuild.stderr, /cannot reuse a build/u);

  const productionEnvironmentWithoutProduction = run("bash", [
    "scripts/run-iroh-release-gate.sh",
    "--mode", "automatic",
    "--tag", "prodtest",
    "--stack-env-file", "/private/tmp/unused.env",
  ]);
  assert.equal(productionEnvironmentWithoutProduction.status, 2);
  assert.match(productionEnvironmentWithoutProduction.stderr, /requires --production/u);
});

test("production release gate gives its account helper a normalized protected state directory", (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));

  const fakeBin = path.join(directory, "bin");
  mkdirSync(fakeBin, { mode: 0o700 });
  const captureFile = path.join(directory, "captured-state.txt");
  const fakeBun = path.join(fakeBin, "bun");
  writeFileSync(fakeBun, `#!/usr/bin/env bash
set -euo pipefail
state_file=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--state-file" ]]; then
    state_file="\${2:-}"
    break
  fi
  shift
done
[[ -n "$state_file" ]]
state_directory="$(dirname "$state_file")"
if [[ "$(uname)" == "Darwin" ]]; then
  mode="$(stat -f '%Lp' "$state_directory")"
else
  mode="$(stat -c '%a' "$state_directory")"
fi
printf '%s\n%s\n' "$state_file" "$mode" > "$CMUX_TEST_CAPTURE_FILE"
exit 73
`, { mode: 0o755 });
  chmodSync(fakeBun, 0o755);

  const stackEnvironment = path.join(directory, "stack.env");
  writeFileSync(stackEnvironment, "unused=true\n", { mode: 0o600 });
  chmodSync(stackEnvironment, 0o600);

  const result = run("bash", [
    "scripts/run-iroh-release-gate.sh",
    "--mode", "automatic",
    "--tag", "prodtmp",
    "--production",
    "--stack-env-file", stackEnvironment,
  ], {
    CMUX_TEST_CAPTURE_FILE: captureFile,
    PATH: `${fakeBin}:${process.env.PATH}`,
    TMPDIR: `${directory}/`,
  });

  assert.equal(result.status, 73, result.stderr);
  const [stateFile, mode] = readFileSync(captureFile, "utf8").trimEnd().split("\n");
  assert.equal(stateFile, path.resolve(stateFile));
  assert.equal(path.dirname(stateFile).startsWith(`${directory}/`), true);
  assert.equal(mode, "700");
});

test("Mac reload documents production auth without accepting secret values", () => {
  const result = run("bash", ["scripts/reload.sh", "--help"]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /--prod-auth/u);
  assert.match(result.stdout, /--credentials-file <path>/u);
  assert.match(result.stdout, /credential values never enter argv/u);
});
