// Unit tests for the shared Freestyle dev key helper.
//   node --test scripts/lib/freestyle-dev-key.test.mjs

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { devKeyEnvFile, freestyleDevKey, parseFreestyleApiKey } from "./freestyle-dev-key.mjs";

const KEY = "fs_test_0123456789abcdefghijklmnopqrstuvwxyz";
const helper = fileURLToPath(new URL("./freestyle-dev-key.mjs", import.meta.url));

const envFile = (text) => {
  const dir = mkdtempSync(join(tmpdir(), "freestyle-dev-key-"));
  const file = join(dir, "cmux.env");
  writeFileSync(file, text, { mode: 0o600 });
  return file;
};

test("reads FREESTYLE_API_KEY from an env file, with export and quotes, ignoring other lines", () => {
  assert.equal(parseFreestyleApiKey(`# comment\nOTHER=secret\nFREESTYLE_API_KEY=${KEY}\n`), KEY);
  assert.equal(parseFreestyleApiKey(`export FREESTYLE_API_KEY="${KEY}"\n`), KEY);
  assert.equal(parseFreestyleApiKey(`FREESTYLE_API_KEY='${KEY}'\n`), KEY);
});

test("does not take a longer name that ends in FREESTYLE_API_KEY, and the last assignment wins", () => {
  assert.equal(parseFreestyleApiKey(`MY_FREESTYLE_API_KEY=wrong\nFREESTYLE_API_KEY=old\nFREESTYLE_API_KEY=${KEY}\n`), KEY);
});

test("fails on a missing or empty key without echoing the file", () => {
  assert.throws(() => parseFreestyleApiKey("OTHER=top-secret-value\n"), (error) => !String(error).includes("top-secret-value"));
  assert.throws(() => parseFreestyleApiKey("FREESTYLE_API_KEY=\n"), /empty/);
});

test("defaults to ~/.secrets/cmux.env and honours CMUX_FREESTYLE_DEV_ENV_FILE", () => {
  assert.equal(devKeyEnvFile({ HOME: "/home/x" }), "/home/x/.secrets/cmux.env");
  assert.equal(devKeyEnvFile({ HOME: "/home/x", CMUX_FREESTYLE_DEV_ENV_FILE: "/tmp/k.env" }), "/tmp/k.env");
  assert.equal(freestyleDevKey({ file: envFile(`FREESTYLE_API_KEY=${KEY}\n`) }), KEY);
});

test("the CLI writes only the key, no newline, to a pipe", () => {
  const file = envFile(`OTHER=x\nFREESTYLE_API_KEY=${KEY}\n`);
  const run = spawnSync(process.execPath, [helper], { env: { ...process.env, CMUX_FREESTYLE_DEV_ENV_FILE: file }, encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(run.stdout, KEY);
});

test("the CLI fails with a message, not a key, when the file has none", () => {
  const file = envFile("OTHER=x\n");
  const run = spawnSync(process.execPath, [helper], { env: { ...process.env, CMUX_FREESTYLE_DEV_ENV_FILE: file }, encoding: "utf8" });
  assert.notEqual(run.status, 0);
  assert.equal(run.stdout, "");
  assert.match(run.stderr, /FREESTYLE_API_KEY/);
});
