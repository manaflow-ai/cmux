// Run with: node --test scripts/lib/mobile-attach.test.mjs
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import { fileURLToPath } from "node:url";
import path from "node:path";
import test from "node:test";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const validator = path.join(repoRoot, "scripts/lib/mobile-attach.sh");
const reservedMessage = "reserved for the stable app instance";

function run(command, args, extraEnv = {}) {
  return spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    env: { ...process.env, ...extraEnv },
  });
}

function validate(tag) {
  return run("bash", [
    "-c",
    'source "$1"; cmux_attach_validate_dev_tag "$2"',
    "mobile-attach-test",
    validator,
    tag,
  ]);
}

function resolveDevAPIBaseURL(fallback, override = "") {
  return run("bash", [
    "-c",
    'source "$1"; CMUX_DEV_API_BASE_URL="$3" cmux_attach_resolve_dev_api_base_url "$2"',
    "mobile-attach-test",
    validator,
    fallback,
    override,
  ]);
}

async function mintAttachURL(target, payload, maxAttempts = 1) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-mobile-attach-test-"));
  const scriptsDir = path.join(tempRoot, "scripts");
  const socketPath = path.join(tempRoot, "mobile.sock");
  const payloadDirectory = path.join(tempRoot, "payloads");
  const callCounterPath = path.join(tempRoot, "call-count");
  fs.mkdirSync(scriptsDir);
  fs.mkdirSync(payloadDirectory);
  const payloads = Array.isArray(payload) ? payload : [payload];
  payloads.forEach((value, index) => {
    fs.writeFileSync(
      path.join(payloadDirectory, `${index + 1}`),
      value == null ? "" : JSON.stringify(value),
    );
  });
  const fakeCLI = path.join(scriptsDir, "cmux-debug-cli.sh");
  fs.writeFileSync(
    fakeCLI,
    [
      "#!/usr/bin/env bash",
      'count="$(cat "$CMUX_TEST_CALL_COUNTER" 2>/dev/null || printf 0)"',
      'count="$((count + 1))"',
      'printf "%s" "$count" > "$CMUX_TEST_CALL_COUNTER"',
      'payload="$CMUX_TEST_PAYLOAD_DIRECTORY/$count"',
      '[[ -f "$payload" ]] && cat "$payload"',
      "",
    ].join("\n"),
  );
  fs.chmodSync(fakeCLI, 0o755);

  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });

  try {
    const result = spawnSync(
      "bash",
      [
        "-c",
        [
          'source "$1"',
          'cmux_attach_socket_path() { printf "%s" "$CMUX_TEST_SOCKET"; }',
          'cmux_attach_mint_url "test" 60 "$2" "$3" "$4"',
        ].join("; "),
        "mobile-attach-test",
        validator,
        tempRoot,
        target,
        String(maxAttempts),
      ],
      {
        cwd: repoRoot,
        encoding: "utf8",
        env: {
          ...process.env,
          CMUX_TEST_CALL_COUNTER: callCounterPath,
          CMUX_TEST_PAYLOAD_DIRECTORY: payloadDirectory,
          CMUX_TEST_SOCKET: socketPath,
        },
      },
    );
    result.callCount = fs.existsSync(callCounterPath)
      ? Number.parseInt(fs.readFileSync(callCounterPath, "utf8"), 10)
      : 0;
    return result;
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

function attachPayload(kind) {
  return {
    attach_url: `cmux-ios-dev://attach?v=2&kind=${kind}`,
    ticket: {
      routes: [{ id: kind, kind }],
    },
  };
}

test("shared dev-tag validator rejects every spelling that sanitizes to default", () => {
  for (const tag of ["default", "DEFAULT", "...Default..."]) {
    const result = validate(tag);
    assert.notEqual(result.status, 0, `${tag} unexpectedly passed`);
    assert.match(result.stderr, new RegExp(reservedMessage));
  }
});

test("shared dev-tag validator permits non-sentinel tags", () => {
  for (const tag of ["future-one", "default-2", "de fault"]) {
    const result = validate(tag);
    assert.equal(result.status, 0, `${tag}: ${result.stderr}`);
  }
});

test("shared dev API origin defaults to the tagged local server", () => {
  const result = resolveDevAPIBaseURL("http://localhost:4123");
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "http://localhost:4123");
});

test("shared dev API origin accepts an explicit trusted backend", () => {
  const result = resolveDevAPIBaseURL(
    "http://localhost:4123",
    "https://cmux-staging.vercel.app",
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "https://cmux-staging.vercel.app");
});

test("macOS and iOS reloads share the dev API backend override", () => {
  const macReload = fs.readFileSync(path.join(repoRoot, "scripts/reload.sh"), "utf8");
  const iosReload = fs.readFileSync(path.join(repoRoot, "ios/scripts/reload.sh"), "utf8");

  assert.match(macReload, /CMUX_DEV_API_BASE_URL_VALUE=.*cmux_attach_resolve_dev_api_base_url/);
  assert.match(macReload, /CMUX_API_BASE_URL="\$CMUX_DEV_API_BASE_URL_VALUE"/);
  assert.match(iosReload, /CMUX_IOS_API_BASE_URL_VALUE=.*CMUX_DEV_API_BASE_URL/);
});

test("physical-device mint rejects a ticket with only plaintext Tailscale routes", async () => {
  const result = await mintAttachURL(
    "physical_device",
    attachPayload("tailscale"),
    20,
  );
  assert.equal(result.status, 2);
  assert.equal(result.stdout, "");
  assert.equal(result.callCount, 1);
});

test("physical-device mint accepts an encrypted Iroh route", async () => {
  const payload = attachPayload("iroh");
  const result = await mintAttachURL("physical_device", payload);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
});

test("simulator mint retains its loopback ticket behavior", async () => {
  const payload = attachPayload("debug_loopback");
  const result = await mintAttachURL("simulator_injection", payload);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
});

test("physical-device mint retries transient empty responses", async () => {
  const payload = attachPayload("iroh");
  const result = await mintAttachURL(
    "physical_device",
    [null, payload],
    20,
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
  assert.equal(result.callCount, 2);
});

test("mobile launch accepts an explicit no-attach override", () => {
  const result = run("bash", [
    "scripts/mobile-dev-launch.sh",
    "--no-attach",
    "--help",
  ]);
  assert.equal(result.status, 0, result.stderr);
  assert.doesNotMatch(result.stderr, /unknown arg/);
});

test("physical-device attach reports a missing tagged Mac before blaming Iroh", () => {
  const tag = `missing-mac-${process.pid}`;
  const result = run(
    "bash",
    [
      "scripts/mobile-dev-launch.sh",
      "--tag",
      tag,
      "--device",
      "--device-id",
      "not-used",
      "--attach",
      "--agent",
    ],
    {
      CMUX_UITEST_STACK_EMAIL: "agent@example.com",
      CMUX_UITEST_STACK_PASSWORD: "test-password",
    },
  );

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /tagged Mac.*not running|debug socket.*not ready/i);
  assert.match(result.stderr, /--ensure-mac/);
  assert.doesNotMatch(result.stderr, /must advertise an encrypted Iroh route/i);
  assert.doesNotMatch(result.stderr, /--no-attach/);
});

for (const entrypoint of [
  { script: "scripts/reload.sh", args: ["--tag", "...DEFAULT..."] },
  { script: "ios/scripts/reload.sh", args: ["--tag", "...DEFAULT...", "--no-launch"] },
  { script: "scripts/mobile-dev-launch.sh", args: ["--tag", "...DEFAULT...", "--detach"] },
  { script: "scripts/dev-setup.sh", args: ["--tag", "...DEFAULT...", "--surface", "ios"] },
]) {
  test(`${entrypoint.script} rejects the reserved tag before doing work`, () => {
    const result = run("bash", [entrypoint.script, ...entrypoint.args]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, new RegExp(reservedMessage));
    assert.doesNotMatch(`${result.stdout}\n${result.stderr}`, /xcodebuild|launching|building/i);
  });
}
