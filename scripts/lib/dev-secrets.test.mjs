// Run with: node --test scripts/lib/dev-secrets.test.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const script = path.join(repoRoot, "scripts/lib/dev-secrets.sh");

function runLoad({ home, env = {}, agent = false }) {
  const command = [
    "set -euo pipefail",
    'source "$1"',
    `cmux_dev_secrets_load${agent ? " --agent" : ""} >/dev/null`,
    'printf "%s\\n%s\\n" "${CMUX_UITEST_STACK_EMAIL:-}" "${CMUX_UITEST_STACK_PASSWORD:-}"',
  ].join("; ");

  return spawnSync("bash", ["-c", command, "dev-secrets-test", script], {
    cwd: repoRoot,
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: home,
      ...env,
    },
  });
}

function makeHome(structure) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-dev-secrets-test-"));
  fs.mkdirSync(path.join(home, ".secrets"), { recursive: true });
  if (structure[".secrets/cmuxterm-dev.env"] != null) {
    fs.writeFileSync(
      path.join(home, ".secrets/cmuxterm-dev.env"),
      structure[".secrets/cmuxterm-dev.env"],
    );
  }
  if (structure[".secrets/cmux.env"] != null) {
    fs.writeFileSync(
      path.join(home, ".secrets/cmux.env"),
      structure[".secrets/cmux.env"],
    );
  }
  return home;
}

function resolvePair(result) {
  assert.equal(result.status, 0, result.stderr);
  const [email, password] = result.stdout.trimEnd().split("\n");
  return { email, password };
}

test("file-backed dogfood creds win over ambient dogfood env", () => {
  const home = makeHome({
    ".secrets/cmuxterm-dev.env": [
      "CMUX_DOGFOOD_STACK_EMAIL=file@manaflow.ai",
      "CMUX_DOGFOOD_STACK_PASSWORD=file-pw",
    ].join("\n"),
  });

  const result = runLoad({
    home,
    env: {
      CMUX_DOGFOOD_STACK_EMAIL: "env@manaflow.ai",
      CMUX_DOGFOOD_STACK_PASSWORD: "env-pw",
    },
  });
  assert.deepEqual(resolvePair(result), {
    email: "file@manaflow.ai",
    password: "file-pw",
  });
});

test("file-backed uitest creds win over ambient uitest env", () => {
  const home = makeHome({
    ".secrets/cmuxterm-dev.env": [
      "CMUX_UITEST_STACK_EMAIL=file@manaflow.ai",
      "CMUX_UITEST_STACK_PASSWORD=file-pw",
    ].join("\n"),
  });

  const result = runLoad({
    home,
    env: {
      CMUX_UITEST_STACK_EMAIL: "env@manaflow.ai",
      CMUX_UITEST_STACK_PASSWORD: "env-pw",
    },
    agent: true,
  });
  assert.deepEqual(resolvePair(result), {
    email: "file@manaflow.ai",
    password: "file-pw",
  });
});

test("ambient env still works when no secret files exist", () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-dev-secrets-test-"));

  const result = runLoad({
    home,
    env: {
      CMUX_DOGFOOD_STACK_EMAIL: "env@manaflow.ai",
      CMUX_DOGFOOD_STACK_PASSWORD: "env-pw",
    },
  });
  assert.deepEqual(resolvePair(result), {
    email: "env@manaflow.ai",
    password: "env-pw",
  });
});
