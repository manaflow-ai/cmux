// Run with: node --test scripts/setup-team-dev.test.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { EventEmitter, once } from "node:events";
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

function fixture(t, { dev, prod, legacyProd, responses = [] } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-setup-profiles-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const secrets = path.join(root, ".secrets");
  fs.mkdirSync(secrets, { mode: 0o700 });
  const devFile = path.join(secrets, "cmuxterm-dev.env");
  const prodFile = path.join(secrets, "cmuxterm-prod.env");
  const legacyProdFile = path.join(secrets, "cmux-beta-production.env");
  if (dev !== undefined) fs.writeFileSync(devFile, dev, { mode: 0o600 });
  if (prod !== undefined) fs.writeFileSync(prodFile, prod, { mode: 0o600 });
  if (legacyProd !== undefined) fs.writeFileSync(legacyProdFile, legacyProd, { mode: 0o600 });
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
    root, devFile, prodFile, legacyProdFile, env, bin,
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
  assert.equal(fs.existsSync(f.legacyProdFile), false);
  assert.equal(fs.readFileSync(f.devFile, "utf8"), original);
});

test("setup adopts a complete legacy production file without prompting or changing the original", (t) => {
  const f = fixture(t, { dev: original, legacyProd: production });
  successful(f.run());
  assert.equal(fs.readFileSync(f.prodFile, "utf8"), production);
  assert.equal(fs.statSync(f.prodFile).mode & 0o777, 0o600);
  assert.equal(fs.readFileSync(f.legacyProdFile, "utf8"), production);
  assert.equal(f.requests().length, 0);
  successful(f.load(["--profile", "personal", "--credentials-file", f.legacyProdFile]));
});

test("an existing canonical production profile takes precedence over legacy credentials", (t) => {
  const legacyProd = production.replace("production@example.com", "legacy@example.com");
  const f = fixture(t, { dev: original, prod: production, legacyProd });
  successful(f.run());
  assert.equal(fs.readFileSync(f.prodFile, "utf8"), production);
  assert.equal(fs.readFileSync(f.legacyProdFile, "utf8"), legacyProd);
  assert.equal(f.requests().length, 0);
});

test("legacy adoption never overwrites a partial canonical profile or combines partial pairs", async (t) => {
  for (const [prod, legacyProd] of [
    ["CMUX_DOGFOOD_STACK_EMAIL=partial@example.com\n", production],
    ["CMUX_DOGFOOD_STACK_EMAIL=partial@example.com\n", "CMUX_DOGFOOD_STACK_PASSWORD=legacy-fixture-password\n"],
    [undefined, "CMUX_DOGFOOD_STACK_EMAIL=partial@example.com\n"],
  ]) {
    await t.test(JSON.stringify({ prod, legacyProd }), (t) => {
      const f = fixture(t, { dev: original, prod, legacyProd });
      successful(f.run());
      if (prod === undefined) assert.equal(fs.existsSync(f.prodFile), false);
      else assert.equal(fs.readFileSync(f.prodFile, "utf8"), prod);
      assert.equal(fs.readFileSync(f.legacyProdFile, "utf8"), legacyProd);
      assert.equal(f.requests().length, 0);
    });
  }
});

test("production refresh updates the adopted profile and preserves explicit legacy callers", (t) => {
  const f = fixture(t, { dev: original, legacyProd: production });
  successful(f.run("new-production@example.com\nnew-fixture-password\n", ["--refresh-production"]));
  assert.equal(f.value(f.prodFile, "CMUX_DOGFOOD_STACK_EMAIL"), "new-production@example.com");
  assert.equal(fs.readFileSync(f.legacyProdFile, "utf8"), production);
  assert.deepEqual(requestProjects(f), [productionProject]);
});

test("legacy adoption refuses unsafe permissions and symbolic links", async (t) => {
  for (const kind of ["permissions", "symlink"]) {
    await t.test(kind, (t) => {
      const f = fixture(t, { dev: original, legacyProd: production });
      if (kind === "permissions") fs.chmodSync(f.legacyProdFile, 0o644);
      else {
        fs.renameSync(f.legacyProdFile, `${f.legacyProdFile}.original`);
        fs.symlinkSync(`${f.legacyProdFile}.original`, f.legacyProdFile);
      }
      assert.notEqual(f.run().status, 0);
      assert.equal(fs.existsSync(f.prodFile), false);
      assert.equal(fs.readFileSync(f.legacyProdFile, "utf8"), production);
      assert.equal(f.requests().length, 0);
    });
  }
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

test("concurrent personal and agent refreshes preserve both successful updates", { timeout: 15_000 }, async (t) => {
  const f = fixture(t, { dev: original, prod: production });
  const events = new EventEmitter();
  const sockets = new Set();
  const children = [];
  const server = net.createServer((socket) => {
    sockets.add(socket);
    let message = "";
    socket.on("data", (data) => {
      message += data;
      if (message.includes("\n")) events.emit(message.trim(), socket);
    });
    socket.on("close", () => sockets.delete(socket));
  });
  t.after(() => {
    for (const child of children) {
      if (child.exitCode !== null || child.signalCode !== null) continue;
      try { process.kill(-child.pid, "SIGKILL"); } catch (error) {
        if (error.code !== "ESRCH") throw error;
      }
    }
    for (const socket of sockets) socket.destroy();
    server.close();
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");

  // Pause the first atomic replacement, then let the other process either
  // reach its own replacement (the bug) or wait for the transaction lock.
  // Both shell and Python filesystem boundaries use the same event protocol.
  fs.writeFileSync(path.join(f.bin, "mv"), `#!${process.execPath}\n` + String.raw`
const net = require("node:net");
const { spawnSync } = require("node:child_process");
const socket = net.connect(Number(process.env.FIXTURE_PORT), "127.0.0.1", () => {
  socket.write(process.env.FIXTURE_ROLE + ":replace\n");
});
socket.once("data", () => {
  process.exit(spawnSync("/bin/mv", process.argv.slice(2)).status ?? 1);
});
`, { mode: 0o700 });
  fs.writeFileSync(path.join(f.bin, "sitecustomize.py"), String.raw`
import fcntl, os, socket
def signal(event, wait=False):
    with socket.create_connection(("127.0.0.1", int(os.environ["FIXTURE_PORT"])), timeout=10) as connection:
        connection.sendall((os.environ["FIXTURE_ROLE"] + ":" + event + "\n").encode())
        if wait:
            connection.recv(1)
replace, flock = os.replace, fcntl.flock
def intercepted_replace(*args, **kwargs):
    signal("replace", wait=True)
    return replace(*args, **kwargs)
def intercepted_flock(*args, **kwargs):
    signal("lock")
    return flock(*args, **kwargs)
os.replace, fcntl.flock = intercepted_replace, intercepted_flock
`);
  function start(role, flag, email) {
    const child = spawn("/bin/bash", [script, flag], {
      detached: true,
      env: { ...f.env, PYTHONPATH: f.bin, FIXTURE_PORT: String(server.address().port), FIXTURE_ROLE: role },
    });
    children.push(child);
    let output = "";
    child.stdout.on("data", (data) => { output += data; });
    child.stderr.on("data", (data) => { output += data; });
    const done = once(child, "close").then(([status]) => {
      assert.equal(status, 0, output);
      assert.doesNotMatch(output, /fixture-password|fixture-token/);
    });
    child.stdin.end(`${email}\n${role}-new-fixture-password\n`);
    return done;
  }
  const personalReplace = once(events, "personal:replace");
  const personalDone = start("personal", "--refresh", "new-person@example.com");
  const [personalSocket] = await personalReplace;
  const agentLock = once(events, "agent:lock").then(() => "locked");
  const agentReplace = once(events, "agent:replace");
  const agentDone = start("agent", "--refresh-agent", "new-agent@example.com");
  if (await Promise.race([agentLock, agentReplace.then(() => "replacing")]) === "replacing") {
    const [agentSocket] = await agentReplace;
    agentSocket.end("continue");
    await agentDone;
    personalSocket.end("continue");
  } else {
    personalSocket.end("continue");
    const [agentSocket] = await agentReplace;
    agentSocket.end("continue");
  }
  await Promise.all([personalDone, agentDone]);
  assert.equal(f.value(f.devFile, "CMUX_DOGFOOD_STACK_PASSWORD"), "personal-new-fixture-password");
  assert.equal(f.value(f.devFile, "CMUX_UITEST_STACK_PASSWORD"), "agent-new-fixture-password");
  assert.match(fs.readFileSync(f.devFile, "utf8"), /EXTRA_CONFIG=retained/);
  assert.equal(fs.statSync(f.devFile).mode & 0o777, 0o600);
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
