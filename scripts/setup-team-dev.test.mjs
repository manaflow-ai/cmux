// Run with: node --test scripts/setup-team-dev.test.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const script = fileURLToPath(new URL("./setup-team-dev.sh", import.meta.url));
const loader = fileURLToPath(new URL("./lib/dev-secrets.sh", import.meta.url));
const devProject = "454ecd03-1db2-4050-845e-4ce5b0cd9895";
const productionProject = "9790718f-14cd-4f7e-824d-eaf527a82b82";
const personal = "CMUX_DOGFOOD_STACK_EMAIL=person@example.com\nCMUX_DOGFOOD_STACK_PASSWORD=old-fixture-password\n";
const agent = "CMUX_UITEST_STACK_EMAIL=agent@example.com\nCMUX_UITEST_STACK_PASSWORD=agent-fixture-password\n";
const original = `# Keep both profiles and unrelated configuration.\n${personal}${agent}EXTRA_CONFIG=retained\n`;
const production = "CMUX_DOGFOOD_STACK_EMAIL=production@example.com\nCMUX_DOGFOOD_STACK_PASSWORD=production-fixture-password\n";

function fixture(t, { dev, prod, responses = [] } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-setup-profiles-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const secrets = path.join(root, ".secrets");
  fs.mkdirSync(secrets, { mode: 0o700 });
  const devFile = path.join(secrets, "cmuxterm-dev.env");
  const prodFile = path.join(secrets, "cmux-beta-production.env");
  if (dev !== undefined) fs.writeFileSync(devFile, dev, { mode: 0o600 });
  if (prod !== undefined) fs.writeFileSync(prodFile, prod, { mode: 0o600 });
  const bin = path.join(root, "bin");
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(root, "responses.json"), JSON.stringify(responses));
  // Every sign-in request is intercepted. These are fixture accounts only.
  fs.writeFileSync(path.join(bin, "curl"), `#!${process.execPath}\n` + String.raw`
const fs = require("node:fs");
const path = require("node:path");
const root = process.env.HOME;
const args = process.argv.slice(2);
const headers = args.flatMap((arg, i) => arg === "-H" ? [args[i + 1]] : []);
const request = { headers, body: JSON.parse(fs.readFileSync(0, "utf8")) };
fs.appendFileSync(path.join(root, "requests.jsonl"), JSON.stringify(request) + "\n");
const responseFile = path.join(root, "responses.json");
const responses = JSON.parse(fs.readFileSync(responseFile, "utf8"));
const response = responses.shift() ?? { body: { access_token: "fixture-token" } };
fs.writeFileSync(responseFile, JSON.stringify(responses));
if (response.status) process.exit(response.status);
process.stdout.write(JSON.stringify(response.body));
`, { mode: 0o700 });
  const env = { HOME: root, PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin` };
  return {
    root, devFile, prodFile,
    run(input = "", args = []) {
      const result = spawnSync("/bin/bash", [script, ...args], {
        encoding: "utf8", input, env, timeout: 10_000,
      });
      assert.equal(result.error, undefined);
      assert.doesNotMatch(result.stdout + result.stderr, /fixture-password|fixture-token/);
      return result;
    },
    requests() {
      const file = path.join(root, "requests.jsonl");
      return fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim().split("\n").map(JSON.parse) : [];
    },
    value(file, key) {
      const result = spawnSync("/bin/bash", ["-c", 'source "$1"; cmux_dev_secrets__read_key "$2" "$3"', "read-fixture", loader, file, key], {
        encoding: "utf8", env,
      });
      assert.equal(result.status, 0, result.stderr);
      return result.stdout;
    },
    load(args = []) {
      return spawnSync("/bin/bash", ["-c", 'source "$1"; shift; cmux_dev_secrets_load "$@"', "load-fixture", loader, ...args], {
        encoding: "utf8", env,
      });
    },
  };
}

function successful(result) {
  assert.equal(result.status, 0, result.stderr);
}

function requestProjects(f) {
  return f.requests().map(({ headers }) => headers.find((header) => header.startsWith("x-stack-project-id:"))?.split(": ")[1]);
}

test("fresh setup separately verifies and stores both development profiles", (t) => {
  const f = fixture(t);
  successful(f.run("person@example.com\npersonal-fixture-password\nagent@example.com\nagent-fixture-password\nn\n"));
  assert.deepEqual(f.requests().map(({ body }) => body.email), ["person@example.com", "agent@example.com"]);
  assert.deepEqual(requestProjects(f), [devProject, devProject]);
  assert.equal(f.value(f.devFile, "CMUX_DOGFOOD_STACK_PASSWORD"), "personal-fixture-password");
  assert.equal(f.value(f.devFile, "CMUX_UITEST_STACK_PASSWORD"), "agent-fixture-password");
  assert.equal(fs.statSync(f.devFile).mode & 0o777, 0o600);
  assert.equal(fs.existsSync(f.prodFile), false);
});

test("a configured personal account does not skip missing agent onboarding", (t) => {
  const f = fixture(t, { dev: personal });
  successful(f.run("agent@example.com\nagent-fixture-password\nn\n"));
  assert.equal(f.value(f.devFile, "CMUX_DOGFOOD_STACK_PASSWORD"), "old-fixture-password");
  assert.equal(f.value(f.devFile, "CMUX_UITEST_STACK_PASSWORD"), "agent-fixture-password");
  assert.equal(f.requests().length, 1);
});

test("an incomplete profile is replaced as a pair without borrowing the other identity", (t) => {
  const f = fixture(t, { dev: `CMUX_DOGFOOD_STACK_EMAIL=partial@example.com\n${agent}` });
  successful(f.run("person@example.com\nnew-fixture-password\n"));
  assert.equal(f.value(f.devFile, "CMUX_DOGFOOD_STACK_EMAIL"), "person@example.com");
  assert.equal(f.value(f.devFile, "CMUX_DOGFOOD_STACK_PASSWORD"), "new-fixture-password");
  assert.equal(f.value(f.devFile, "CMUX_UITEST_STACK_PASSWORD"), "agent-fixture-password");
  assert.equal(f.requests().length, 1);
});

test("production opt-in verifies the production project and keeps its file separate", (t) => {
  const f = fixture(t, { dev: original });
  const result = f.run("yes\nproduction@example.com\nproduction-fixture-password\n");
  successful(result);
  assert.match(result.stdout, /optional.*production|production.*optional/i);
  assert.match(result.stdout, /verify.*production/i);
  assert.deepEqual(requestProjects(f), [productionProject]);
  assert.ok(f.requests()[0].headers.includes("x-stack-publishable-client-key: pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr"));
  assert.equal(f.value(f.prodFile, "CMUX_DOGFOOD_STACK_PASSWORD"), "production-fixture-password");
  assert.equal(fs.statSync(f.prodFile).mode & 0o777, 0o600);
  assert.equal(fs.readFileSync(f.devFile, "utf8"), original);
});

test("production decline, empty input, and EOF leave development setup successful", async (t) => {
  for (const input of ["n\n", "\n", "", "yes\n"]) {
    await t.test(JSON.stringify(input), (t) => {
      const f = fixture(t, { dev: original });
      successful(f.run(input));
      assert.equal(fs.existsSync(f.prodFile), false);
      assert.equal(fs.readFileSync(f.devFile, "utf8"), original);
      assert.equal(f.requests().length, 0);
    });
  }
});

test("reruns preserve all complete profiles without requesting credentials", (t) => {
  const f = fixture(t, { dev: original, prod: production });
  successful(f.run());
  assert.equal(fs.readFileSync(f.devFile, "utf8"), original);
  assert.equal(fs.readFileSync(f.prodFile, "utf8"), production);
  assert.equal(f.requests().length, 0);
});

test("refresh verifies a replacement and preserves the agent profile", (t) => {
  const f = fixture(t, { dev: original });
  successful(f.run("person@example.com\nnew-fixture-password\n", ["--refresh"]));
  assert.deepEqual(f.requests()[0].body, { email: "person@example.com", password: "new-fixture-password" });
  assert.equal(f.value(f.devFile, "CMUX_DOGFOOD_STACK_PASSWORD"), "new-fixture-password");
  assert.equal(f.value(f.devFile, "CMUX_UITEST_STACK_PASSWORD"), "agent-fixture-password");
  assert.match(fs.readFileSync(f.devFile, "utf8"), /EXTRA_CONFIG=retained/);
});

test("agent refresh changes only the development test profile", (t) => {
  const f = fixture(t, { dev: original, prod: production });
  successful(f.run("new-agent@example.com\nnew-fixture-password\n", ["--refresh-agent"]));
  assert.equal(f.value(f.devFile, "CMUX_DOGFOOD_STACK_PASSWORD"), "old-fixture-password");
  assert.equal(f.value(f.devFile, "CMUX_UITEST_STACK_EMAIL"), "new-agent@example.com");
  assert.equal(f.value(f.devFile, "CMUX_UITEST_STACK_PASSWORD"), "new-fixture-password");
  assert.equal(fs.readFileSync(f.prodFile, "utf8"), production);
  assert.deepEqual(requestProjects(f), [devProject]);
});

test("production refresh changes only the explicitly selected production profile", (t) => {
  const f = fixture(t, { dev: original, prod: production });
  successful(f.run("new-production@example.com\nnew-fixture-password\n", ["--refresh-production"]));
  assert.equal(fs.readFileSync(f.devFile, "utf8"), original);
  assert.equal(f.value(f.prodFile, "CMUX_DOGFOOD_STACK_EMAIL"), "new-production@example.com");
  assert.equal(f.value(f.prodFile, "CMUX_DOGFOOD_STACK_PASSWORD"), "new-fixture-password");
  assert.deepEqual(requestProjects(f), [productionProject]);
});

for (const [name, response] of [
  ["rejected", { body: { code: "EMAIL_PASSWORD_MISMATCH" } }],
  ["unavailable", { status: 7 }],
  ["empty token", { body: { access_token: "" } }],
]) {
  test(`${name} verification preserves existing profiles`, (t) => {
    const f = fixture(t, { dev: original, prod: production, responses: [response] });
    assert.notEqual(f.run("person@example.com\nnew-fixture-password\n", ["--refresh"]).status, 0);
    assert.equal(fs.readFileSync(f.devFile, "utf8"), original);
    assert.equal(fs.readFileSync(f.prodFile, "utf8"), production);
  });
}

test("unavailable verification never saves unverified new credentials", (t) => {
  const f = fixture(t, { responses: [{ status: 7 }] });
  assert.notEqual(f.run("person@example.com\nnew-fixture-password\n").status, 0);
  assert.equal(fs.existsSync(f.devFile), false);
});

test("a failed production login leaves development credentials available", (t) => {
  const f = fixture(t, { dev: original, responses: [{ body: { code: "EMAIL_PASSWORD_MISMATCH" } }] });
  assert.notEqual(f.run("y\nproduction@example.com\nproduction-fixture-password\n").status, 0);
  assert.equal(fs.existsSync(f.prodFile), false);
  assert.equal(fs.readFileSync(f.devFile, "utf8"), original);
});

test("failed agent setup retains the already verified personal profile for a rerun", (t) => {
  const f = fixture(t, { responses: [{ body: { access_token: "fixture-token" } }, { status: 7 }] });
  assert.notEqual(f.run("person@example.com\nnew-fixture-password\nagent@example.com\nagent-fixture-password\n").status, 0);
  assert.equal(f.value(f.devFile, "CMUX_DOGFOOD_STACK_PASSWORD"), "new-fixture-password");
  assert.equal(f.value(f.devFile, "CMUX_UITEST_STACK_PASSWORD"), "");
  successful(f.run("agent@example.com\nagent-fixture-password\nn\n"));
  assert.equal(f.value(f.devFile, "CMUX_UITEST_STACK_PASSWORD"), "agent-fixture-password");
});

test("special password characters survive both verification and the credential loader", (t) => {
  const f = fixture(t, { dev: agent });
  const password = '  "literal\\fixture-password\t$()`"  ';
  successful(f.run(`person@example.com\n${password}\nn\n`));
  assert.equal(f.requests()[0].body.password, password);
  assert.equal(f.value(f.devFile, "CMUX_DOGFOOD_STACK_PASSWORD"), password);
});

test("refresh replaces whitespace-formatted profile keys without leaving a stale first match", (t) => {
  const f = fixture(t, { dev: `  CMUX_DOGFOOD_STACK_EMAIL = person@example.com\n CMUX_DOGFOOD_STACK_PASSWORD = old-fixture-password\n${agent}` });
  successful(f.run("person@example.com\nnew-fixture-password\n", ["--refresh"]));
  assert.equal(f.value(f.devFile, "CMUX_DOGFOOD_STACK_PASSWORD"), "new-fixture-password");
});

test("default credential loading never discovers production, but an explicit file can", (t) => {
  const f = fixture(t, { prod: production });
  assert.notEqual(f.load().status, 0);
  successful(f.load(["--profile", "personal", "--credentials-file", f.prodFile]));
});

test("unsafe credentials paths are rejected before any authentication request", (t) => {
  const f = fixture(t, { dev: original });
  fs.renameSync(f.devFile, `${f.devFile}.original`);
  fs.symlinkSync(`${f.devFile}.original`, f.devFile);
  assert.notEqual(f.run("person@example.com\nnew-fixture-password\n", ["--refresh"]).status, 0);
  assert.equal(f.requests().length, 0);
  assert.equal(fs.readFileSync(`${f.devFile}.original`, "utf8"), original);
});
