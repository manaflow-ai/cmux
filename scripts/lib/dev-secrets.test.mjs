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

function runLoad({
  home,
  env = {},
  agent = false,
  profile,
  expectedAccount,
  credentialsFile,
}) {
  const loaderArguments = [];
  if (agent) loaderArguments.push("--agent");
  if (profile) loaderArguments.push("--profile", profile);
  if (expectedAccount) loaderArguments.push("--expected-account", expectedAccount);
  if (credentialsFile) loaderArguments.push("--credentials-file", credentialsFile);
  const command = [
    "set -euo pipefail",
    'source "$1"',
    "shift",
    'cmux_dev_secrets_load "$@" >/dev/null',
    'printf "%s\\n%s\\n%s\\n%s\\n" "${CMUX_UITEST_STACK_EMAIL:-}" "${CMUX_UITEST_STACK_PASSWORD:-}" "${CMUX_DEV_AUTH_PROFILE:-}" "${CMUX_DEV_AUTH_ACCOUNT:-}"',
  ].join("; ");

  return spawnSync("bash", ["-c", command, "dev-secrets-test", script, ...loaderArguments], {
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

function resolveCredential(result) {
  assert.equal(result.status, 0, result.stderr);
  const [email, password, profile, account] = result.stdout.trimEnd().split("\n");
  return { email, password, profile, account };
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

test("personal profile never falls back to shared agent credentials", () => {
  const home = makeHome({
    ".secrets/cmuxterm-dev.env": [
      "CMUX_UITEST_STACK_EMAIL=agent@manaflow.ai",
      "CMUX_UITEST_STACK_PASSWORD=agent-pw",
    ].join("\n"),
    ".secrets/cmux.env": [
      "CMUX_UITEST_STACK_EMAIL=other-agent@manaflow.ai",
      "CMUX_UITEST_STACK_PASSWORD=other-agent-pw",
    ].join("\n"),
  });

  const result = runLoad({ home, profile: "personal" });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /personal.*CMUX_DOGFOOD_STACK_EMAIL.*CMUX_DOGFOOD_STACK_PASSWORD/is);
});

test("agent profile selects only the shared agent pair", () => {
  const home = makeHome({
    ".secrets/cmuxterm-dev.env": [
      "CMUX_DOGFOOD_STACK_EMAIL=person@manaflow.ai",
      "CMUX_DOGFOOD_STACK_PASSWORD=person-pw",
      "CMUX_UITEST_STACK_EMAIL=agent@manaflow.ai",
      "CMUX_UITEST_STACK_PASSWORD=agent-pw",
    ].join("\n"),
  });

  const result = runLoad({ home, profile: "agent" });

  assert.deepEqual(resolveCredential(result), {
    email: "agent@manaflow.ai",
    password: "agent-pw",
    profile: "agent",
    account: "agent@manaflow.ai",
  });
});

test("agent profile still discovers the legacy cmux.env pair", () => {
  const home = makeHome({
    ".secrets/cmux.env": [
      "CMUX_UITEST_STACK_EMAIL=legacy-agent@manaflow.ai",
      "CMUX_UITEST_STACK_PASSWORD=legacy-agent-pw",
    ].join("\n"),
  });

  const result = runLoad({ home, profile: "agent" });

  assert.deepEqual(resolveCredential(result), {
    email: "legacy-agent@manaflow.ai",
    password: "legacy-agent-pw",
    profile: "agent",
    account: "legacy-agent@manaflow.ai",
  });
});

test("expected account mismatch fails before credentials are exported", () => {
  const home = makeHome({
    ".secrets/cmuxterm-dev.env": [
      "CMUX_DOGFOOD_STACK_EMAIL=person@manaflow.ai",
      "CMUX_DOGFOOD_STACK_PASSWORD=person-pw",
    ].join("\n"),
  });

  const result = runLoad({
    home,
    profile: "personal",
    expectedAccount: "other@manaflow.ai",
  });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /expected.*other@manaflow\.ai.*resolved.*person@manaflow\.ai/is);
});
