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

function removeStaleSocket(socketPath) {
  return run(
    "bash",
    [
      "-c",
      [
        'source "$1"',
        'cmux_attach_socket_path() { printf "%s" "$CMUX_TEST_SOCKET"; }',
        'cmux_attach_remove_stale_socket "release-gate"',
      ].join("; "),
      "mobile-attach-test",
      validator,
    ],
    { CMUX_TEST_SOCKET: socketPath },
  );
}

function waitForUsableSession(
  status = 0,
  baseline = "100",
  timeout = "15",
  event = '{"seq":101,"name":"mobile.rpc.ready","payload":{"connection_id":"connection-a","client_id":"phone-a","transport":"tailscale","stream_id":"events"}}',
  expectedClientID = "phone-a",
) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-mobile-admission-test-"));
  const argsPath = path.join(tempRoot, "args");

  try {
    const result = run(
      "bash",
      [
        "-c",
        [
          'source "$1"',
          'cmux_attach_events() {',
          '  shift 2',
          '  printf "%s\\n" "$*" > "$CMUX_TEST_ARGS"',
          '  [[ "$CMUX_TEST_STATUS" == "0" ]] && printf "%s\\n" "$CMUX_TEST_EVENT"',
          '  return "$CMUX_TEST_STATUS"',
          '}',
          'cmux_attach_wait_for_usable_session "ready" "$2" "$3" "$4" "$5"',
        ].join("\n"),
        "mobile-admission-test",
        validator,
        repoRoot,
        baseline,
        timeout,
        expectedClientID,
      ],
      {
        CMUX_TEST_ARGS: argsPath,
        CMUX_TEST_EVENT: event,
        CMUX_TEST_STATUS: String(status),
      },
    );
    result.eventArgs = fs.existsSync(argsPath) ? fs.readFileSync(argsPath, "utf8").trim() : "";
    return result;
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

function writeReadinessReceipt(eventJSON) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-mobile-receipt-test-"));
  const receiptPath = path.join(tempRoot, "receipt.json");
  const result = run(
    "bash",
    [
      "-c",
      [
        'source "$1"',
        'cmux_attach_write_readiness_receipt "$2" "$3" iosrdy dev.cmux.ios.iosrdy physical_device phone-a iosrdy /tmp/cmux-debug-iosrdy.sock 8421 1 "$4"',
      ].join("\n"),
      "mobile-readiness-receipt-test",
      validator,
      receiptPath,
      "0123456789abcdef0123456789abcdef01234567",
      eventJSON,
    ],
  );
  result.receipt = fs.existsSync(receiptPath)
    ? JSON.parse(fs.readFileSync(receiptPath, "utf8"))
    : null;
  result.directoryMode = fs.statSync(tempRoot).mode & 0o777;
  result.receiptMode = fs.existsSync(receiptPath)
    ? fs.statSync(receiptPath).mode & 0o777
    : null;
  fs.rmSync(tempRoot, { recursive: true, force: true });
  return result;
}

function readinessCursor(snapshot) {
  return run(
    "bash",
    [
      "-c",
      [
        'source "$1"',
        'cmux_attach_events() { printf "%s\\n" "$CMUX_TEST_SNAPSHOT"; }',
        'cmux_attach_readiness_cursor "ready" "$2"',
      ].join("\n"),
      "mobile-admission-cursor-test",
      validator,
      repoRoot,
    ],
    { CMUX_TEST_SNAPSHOT: snapshot },
  );
}

function monotonicMilliseconds() {
  return run("bash", [
    "-c",
    'source "$1"; cmux_attach_monotonic_milliseconds',
    "mobile-monotonic-clock-test",
    validator,
  ]);
}

function extractShellFunction(source, name) {
  const start = source.indexOf(`${name}() {`);
  assert.notEqual(start, -1, `missing shell function ${name}`);
  const end = source.indexOf("\n}", start);
  assert.notEqual(end, -1, `unterminated shell function ${name}`);
  return source.slice(start, end + 2);
}

function resolveIOSAPIBaseURL(target, extraEnv = {}) {
  const source = fs.readFileSync(path.join(repoRoot, "ios/scripts/reload.sh"), "utf8");
  const resolver = extractShellFunction(source, "cmux_ios_resolve_api_base_url");
  return run(
    "bash",
    ["-c", `${resolver}; cmux_ios_resolve_api_base_url "$1"`, "ios-origin-test", target],
    {
      CMUX_IOS_API_BASE_URL: "",
      CMUX_DEV_API_BASE_URL: "",
      CMUX_VM_API_BASE_URL: "",
      CMUX_PORT: "",
      PROD_AUTH: "0",
      ...extraEnv,
    },
  );
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
    const response = value?.cliResponse;
    fs.writeFileSync(
      path.join(payloadDirectory, `${index + 1}.stdout`),
      response ? (response.stdout ?? "") : (value == null ? "" : JSON.stringify(value)),
    );
    fs.writeFileSync(
      path.join(payloadDirectory, `${index + 1}.stderr`),
      response?.stderr ?? "",
    );
    fs.writeFileSync(
      path.join(payloadDirectory, `${index + 1}.status`),
      String(response?.status ?? 0),
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
      '[[ -f "$payload.stdout" ]] && cat "$payload.stdout"',
      '[[ -f "$payload.stderr" ]] && cat "$payload.stderr" >&2',
      'status="$(cat "$payload.status" 2>/dev/null || printf 0)"',
      'exit "$status"',
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

async function ensureMacAfterRelaunch({ forceRelaunch = false, readyAtCall = 2 } = {}) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-mobile-ready-test-"));
  const socketPath = path.join(tempRoot, "mobile.sock");
  const appPath = path.join(tempRoot, "cmux DEV ready.app");
  const callCounterPath = path.join(tempRoot, "call-count");
  const pkillArgsPath = path.join(tempRoot, "pkill-args");
  fs.mkdirSync(appPath);

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
          'cmux_attach_enable_pairing_host() { :; }',
          'cmux_attach_socket_path() { printf "%s" "$CMUX_TEST_SOCKET"; }',
          'cmux_attach_mac_app_path() { printf "%s" "$CMUX_TEST_APP"; }',
          'cmux_attach__slug() { printf "ready"; }',
          'cmux_attach_mint_url() {',
          '  count="$(cat "$CMUX_TEST_CALL_COUNTER" 2>/dev/null || printf 0)"',
          '  count="$((count + 1))"',
          '  printf "%s" "$count" > "$CMUX_TEST_CALL_COUNTER"',
          '  if [[ "$count" -ge "$CMUX_TEST_READY_AT_CALL" ]]; then printf "cmux-ios-dev://attach?v=2&kind=tailscale"; return 0; fi',
          '  return 1',
          '}',
          'cmux_attach_terminate_bundle_app() { printf "%s\\n" "$*" > "$CMUX_TEST_PKILL_ARGS"; return 0; }',
          'cmux_attach_launch_bundle_app() { return 0; }',
          'sleep() { return 0; }',
          'cmux_attach_ensure_mac "ready" "$2" physical_device "$CMUX_TEST_FORCE_RELAUNCH"',
        ].join("\n"),
        "mobile-attach-test",
        validator,
        tempRoot,
      ],
      {
        cwd: repoRoot,
        encoding: "utf8",
        env: {
          ...process.env,
          CMUX_TEST_APP: appPath,
          CMUX_TEST_CALL_COUNTER: callCounterPath,
          CMUX_TEST_FORCE_RELAUNCH: forceRelaunch ? "1" : "0",
          CMUX_TEST_PKILL_ARGS: pkillArgsPath,
          CMUX_TEST_READY_AT_CALL: String(readyAtCall),
          CMUX_TEST_SOCKET: socketPath,
        },
      },
    );
    result.callCount = fs.existsSync(callCounterPath)
      ? Number.parseInt(fs.readFileSync(callCounterPath, "utf8"), 10)
      : 0;
    result.pkillArgs = fs.existsSync(pkillArgsPath)
      ? fs.readFileSync(pkillArgsPath, "utf8").trim()
      : "";
    return result;
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

function attachPayload(kind) {
  return {
    attach_url: `cmux-ios-dev://attach?v=2&kind=${kind}`,
    routes: [{ id: kind, kind }],
    ticket: {
      routes: [{ id: kind, kind }],
    },
  };
}

function runQRGenerator(payloads) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-mobile-qr-test-"));
  const scriptsDir = path.join(tempRoot, "scripts");
  const libDir = path.join(scriptsDir, "lib");
  const payloadDirectory = path.join(tempRoot, "payloads");
  const callCounterPath = path.join(tempRoot, "call-count");
  const paramsLogPath = path.join(tempRoot, "params.log");
  const outputDirectory = path.join(tempRoot, "out");
  fs.mkdirSync(libDir, { recursive: true });
  fs.mkdirSync(payloadDirectory);
  fs.copyFileSync(
    path.join(repoRoot, "scripts/mobile-attach-qr.sh"),
    path.join(scriptsDir, "mobile-attach-qr.sh"),
  );
  payloads.forEach((payload, index) => {
    fs.writeFileSync(
      path.join(payloadDirectory, `${index + 1}`),
      JSON.stringify(payload),
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
      'printf "%s\\n" "${@: -1}" >> "$CMUX_TEST_PARAMS_LOG"',
      'payload="$CMUX_TEST_PAYLOAD_DIRECTORY/$count"',
      '[[ -f "$payload" ]] && cat "$payload"',
      "",
    ].join("\n"),
  );
  fs.chmodSync(fakeCLI, 0o755);

  const result = run(
    "bash",
    [
      path.join(scriptsDir, "mobile-attach-qr.sh"),
      "--tag",
      "lane-a",
      "--out-dir",
      outputDirectory,
    ],
    {
      CMUX_ATTACH_QR_MAX_ATTEMPTS: String(payloads.length),
      CMUX_ATTACH_QR_POLL_INTERVAL_SECONDS: "0",
      CMUX_TEST_CALL_COUNTER: callCounterPath,
      CMUX_TEST_PARAMS_LOG: paramsLogPath,
      CMUX_TEST_PAYLOAD_DIRECTORY: payloadDirectory,
    },
  );
  result.callCount = fs.existsSync(callCounterPath)
    ? Number.parseInt(fs.readFileSync(callCounterPath, "utf8"), 10)
    : 0;
  result.params = fs.existsSync(paramsLogPath)
    ? fs.readFileSync(paramsLogPath, "utf8").trim().split("\n").map(JSON.parse)
    : [];
  result.filteredPayload = fs.existsSync(path.join(outputDirectory, "attach-ticket.filtered.json"))
    ? JSON.parse(fs.readFileSync(path.join(outputDirectory, "attach-ticket.filtered.json"), "utf8"))
    : null;
  fs.rmSync(tempRoot, { recursive: true, force: true });
  return result;
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

test("tagged stale-socket cleanup removes only the exact Unix socket", async () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-stale-socket-test-"));
  const socketPath = path.join(tempRoot, "release-gate.sock");
  const neighborPath = path.join(tempRoot, "neighbor.sock");
  fs.writeFileSync(neighborPath, "keep");
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });

  try {
    const result = removeStaleSocket(socketPath);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(socketPath), false);
    assert.equal(fs.readFileSync(neighborPath, "utf8"), "keep");
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("tagged stale-socket cleanup refuses a non-socket path", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-stale-socket-test-"));
  const socketPath = path.join(tempRoot, "release-gate.sock");
  fs.writeFileSync(socketPath, "keep");

  try {
    const result = removeStaleSocket(socketPath);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /refusing to remove non-socket/);
    assert.equal(fs.readFileSync(socketPath, "utf8"), "keep");
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("dogfood readiness captures the Mac event sequence before launch", () => {
  const result = readinessCursor(
    '{"type":"ack","resume":{"latest_seq":842,"next_seq":843}}',
  );

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "842");
});

test("dogfood readiness clock is stable across helper processes", () => {
  const first = monotonicMilliseconds();
  const second = monotonicMilliseconds();

  assert.equal(first.status, 0, first.stderr);
  assert.equal(second.status, 0, second.stderr);
  const firstMilliseconds = Number.parseInt(first.stdout.trim(), 10);
  const secondMilliseconds = Number.parseInt(second.stdout.trim(), 10);
  assert.ok(Number.isSafeInteger(firstMilliseconds));
  assert.ok(Number.isSafeInteger(secondMilliseconds));
  assert.ok(
    secondMilliseconds >= firstMilliseconds,
    `expected monotonic clock, got ${firstMilliseconds} -> ${secondMilliseconds}`,
  );
});

test("dogfood readiness blocks on the post-launch usable RPC event", () => {
  const result = waitForUsableSession(0, "842", "15");

  assert.equal(result.status, 0, result.stderr);
  assert.equal(
    result.eventArgs,
    "--after 842 --name mobile.rpc.ready --limit 1 --timeout 15 --no-ack --no-heartbeat",
  );
  assert.match(result.stdout, /"name":"mobile\.rpc\.ready"/);
});

test("dogfood readiness rejects an event from another client", () => {
  const result = waitForUsableSession(
    0,
    "842",
    "1",
    '{"seq":843,"name":"mobile.rpc.ready","payload":{"client_id":"other-phone"}}',
    "phone-a",
  );

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /did not establish a usable RPC session/i);
});

test("dogfood readiness fails when a usable RPC session misses its deadline", () => {
  const result = waitForUsableSession(1);

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /did not establish a usable RPC session.*readiness deadline/i);
});

test("dogfood readiness writes a secret-free identity and latency receipt", () => {
  const result = writeReadinessReceipt(
    '{"name":"mobile.rpc.ready","payload":{"connection_id":"connection-a","client_id":"phone-a","workspace_count":2,"stream_id":"events","transport":"tailscale","access_token":"must-not-appear"}}',
  );

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.receipt, {
    schema: "cmux-ios-dogfood-readiness-v1",
    git_sha: "0123456789abcdef0123456789abcdef01234567",
    tag: "iosrdy",
    bundle_id: "dev.cmux.ios.iosrdy",
    target: "physical_device",
    target_id: "phone-a",
    mac_tag: "iosrdy",
    socket_path: "/tmp/cmux-debug-iosrdy.sock",
    readiness_latency_ms: 8421,
    attempt_count: 1,
    connection_id: "connection-a",
    client_id: "phone-a",
    workspace_count: 2,
    stream_id: "events",
    transport: "tailscale",
  });
  assert.equal(result.directoryMode, 0o700);
  assert.equal(result.receiptMode, 0o600);
  assert.doesNotMatch(JSON.stringify(result.receipt), /must-not-appear|access_token/);
});

test("macOS and iOS reloads share the dev API backend override", () => {
  const macReload = fs.readFileSync(path.join(repoRoot, "scripts/reload.sh"), "utf8");
  const iosReload = fs.readFileSync(path.join(repoRoot, "ios/scripts/reload.sh"), "utf8");

  assert.match(macReload, /CMUX_DEV_API_BASE_URL_VALUE=.*cmux_attach_resolve_dev_api_base_url/);
  assert.match(macReload, /CMUX_API_BASE_URL="\$CMUX_DEV_API_BASE_URL_VALUE"/);
  assert.match(iosReload, /explicit_base_url=.*CMUX_DEV_API_BASE_URL/);
});

test("iOS Simulator defaults to its tagged localhost API", () => {
  const result = resolveIOSAPIBaseURL("simulator", { CMUX_PORT: "4123" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "http://localhost:4123");
});

test("iOS physical-device Debug builds default to the staging API", () => {
  const api = resolveIOSAPIBaseURL("physical_device", { CMUX_PORT: "4123" });

  assert.equal(api.status, 0, api.stderr);
  assert.equal(api.stdout, "https://cmux-staging.vercel.app");
});

test("iOS service origin overrides win for every Debug target", () => {
  for (const target of ["simulator", "physical_device"]) {
    const api = resolveIOSAPIBaseURL(target, {
      CMUX_IOS_API_BASE_URL: "https://api.dev.example",
      CMUX_DEV_API_BASE_URL: "https://ignored.example",
      CMUX_PORT: "4123",
    });
    assert.equal(api.status, 0, api.stderr);
    assert.equal(api.stdout, "https://api.dev.example");
  }
});

test("iOS production-auth builds keep production service origins", () => {
  for (const target of ["simulator", "physical_device"]) {
    const api = resolveIOSAPIBaseURL(target, { PROD_AUTH: "1", CMUX_PORT: "4123" });
    assert.equal(api.status, 0, api.stderr);
    assert.equal(api.stdout, "https://cmux.com");
  }
});

test("cloud physical-device archives bake staging origins with override escape hatches", () => {
  const workflow = fs.readFileSync(
    path.join(repoRoot, ".github/workflows/reload-build.yml"),
    "utf8",
  );

  assert.match(
    workflow,
    /api_base_url="\$\{CMUX_IOS_API_BASE_URL:-\$\{CMUX_DEV_API_BASE_URL:-https:\/\/cmux-staging\.vercel\.app\}\}"/,
  );
  assert.match(workflow, /CMUX_API_BASE_URL="\$api_base_url"/);
});

test("physical-device mint rejects a ticket with only loopback routes", async () => {
  const result = await mintAttachURL(
    "physical_device",
    [attachPayload("loopback"), attachPayload("loopback")],
    2,
  );
  assert.equal(result.status, 2);
  assert.equal(result.stdout, "");
  assert.equal(result.callCount, 2);
});

test("physical-device mint waits for asynchronous Tailscale publication", async () => {
  const payload = attachPayload("tailscale");
  const result = await mintAttachURL(
    "physical_device",
    [attachPayload("loopback"), payload],
    2,
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
  assert.equal(result.callCount, 2);
});

test("physical-device mint reports a redacted route-readiness timeout", async () => {
  const result = await mintAttachURL(
    "physical_device",
    {
      cliResponse: {
        status: 1,
        stderr: "unavailable: Mobile host routes are not available yet secret-token-value",
      },
    },
  );
  assert.equal(result.status, 1);
  assert.match(result.stderr, /attach readiness exhausted: host_routes_unavailable/);
  assert.doesNotMatch(result.stderr, /secret-token-value/);
});

test("physical-device mint distinguishes malformed successful output", async () => {
  const result = await mintAttachURL(
    "physical_device",
    { cliResponse: { status: 0, stdout: "not-json secret-payload-value" } },
  );
  assert.equal(result.status, 1);
  assert.match(result.stderr, /attach readiness exhausted: malformed_response/);
  assert.doesNotMatch(result.stderr, /secret-payload-value/);
});

test("physical-device mint accepts a Tailscale route", async () => {
  const payload = attachPayload("tailscale");
  const result = await mintAttachURL("physical_device", payload);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
});

test("QR fallback waits for the exact tagged Mac's authenticated Tailscale route", () => {
  const result = runQRGenerator([
    attachPayload("loopback"),
    attachPayload("tailscale"),
  ]);

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.callCount, 2);
  assert.deepEqual(
    result.params.map((params) => params.route_kind),
    ["tailscale", "tailscale"],
  );
  assert.deepEqual(
    result.filteredPayload.ticket.routes.map((route) => route.kind),
    ["tailscale"],
  );
});

test("QR server pins its launch tags and allocates an isolated port", () => {
  const server = fs.readFileSync(
    path.join(repoRoot, "scripts/mobile-attach-qr-server.sh"),
    "utf8",
  );

  assert.doesNotMatch(server, /cmux-mobile-attach-qr-tags\.json|refresh_tags|TAG_MARKER_PATH/);
  assert.match(server, /PORT="\$\{PORT:-0\}"/);
  assert.match(server, /httpd\.server_address\[1\]/);
});

test("simulator mint retains its loopback ticket behavior", async () => {
  const payload = attachPayload("debug_loopback");
  const result = await mintAttachURL("simulator_injection", payload);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
});

test("physical-device mint retries transient empty responses", async () => {
  const payload = attachPayload("tailscale");
  const result = await mintAttachURL(
    "physical_device",
    [null, payload],
    20,
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
  assert.equal(result.callCount, 2);
});

test("ensure-mac self-heals an unarmed running exact-tag app", async () => {
  const result = await ensureMacAfterRelaunch();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.callCount, 2);
  assert.match(
    result.pkillArgs,
    /^com\.cmuxterm\.app\.debug\.ready .* 5$/,
  );
});

test("ensure-mac rotates an armed exact-tag app before using explicit credentials", async () => {
  const result = await ensureMacAfterRelaunch({ forceRelaunch: true, readyAtCall: 1 });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.callCount, 1);
  assert.match(
    result.pkillArgs,
    /^com\.cmuxterm\.app\.debug\.ready .* 5$/,
  );
});

test("mobile launch grants asynchronous route publication a bounded startup window", () => {
  const launcher = fs.readFileSync(
    path.join(repoRoot, "scripts/mobile-dev-launch.sh"),
    "utf8",
  );

  assert.match(
    launcher,
    /ATTACH_MINT_MAX_ATTEMPTS="\$\{CMUX_ATTACH_MINT_MAX_ATTEMPTS:-20\}"/,
  );
  assert.match(
    launcher,
    /cmux_attach_mint_url[^\n]+"\$ATTACH_TARGET" "\$ATTACH_MINT_MAX_ATTEMPTS"/,
  );
});

test("simulator launch seeds a deterministic durable device id before app launch", () => {
  const launcher = fs.readFileSync(
    path.join(repoRoot, "scripts/mobile-dev-launch.sh"),
    "utf8",
  );
  const simulatorBranch = launcher.slice(
    launcher.indexOf('if [[ "$TARGET" == "simulator" ]]'),
    launcher.indexOf("\nelse\n", launcher.indexOf('if [[ "$TARGET" == "simulator" ]]')),
  );
  const seed = simulatorBranch.indexOf(
    'cmux_attach_seed_simulator_device_id "$SIM_UDID" "$BUNDLE_ID"',
  );
  const seedEnvironment = simulatorBranch.indexOf(
    'SIMCTL_CHILD_CMUX_SIMULATOR_DEVICE_ID="$SIMULATOR_DEVICE_ID"',
  );
  const terminate = simulatorBranch.indexOf('xcrun simctl terminate');
  const launch = simulatorBranch.indexOf('xcrun simctl "${launch_args[@]}"');

  assert.notEqual(terminate, -1, "existing simulator app must terminate before seeding");
  assert.notEqual(seed, -1, "simulator launch must seed the durable identity mirror");
  assert.notEqual(
    seedEnvironment,
    -1,
    "simulator launch must pass the durable seed into the sandboxed app process",
  );
  assert.notEqual(launch, -1, "simulator launch command is missing");
  assert.ok(terminate < seed, "existing app must terminate before its durable identity is seeded");
  assert.ok(
    seed < seedEnvironment,
    "the seed must be resolved before the simulator child environment uses it",
  );
  assert.ok(seed < launch, "durable identity must be seeded before the app starts");
  assert.ok(
    seedEnvironment < launch,
    "the sandboxed app must receive its durable identity before launch",
  );
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

test("ensure-mac fails closed before a simulator can launch unpaired", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-ensure-mac-test-"));
  const binDir = path.join(tempRoot, "bin");
  const xcrunLog = path.join(tempRoot, "xcrun.log");
  fs.mkdirSync(binDir);
  fs.mkdirSync(path.join(tempRoot, ".secrets"));
  fs.writeFileSync(
    path.join(tempRoot, ".secrets/cmuxterm-dev.env"),
    "CMUX_UITEST_STACK_EMAIL=agent@example.com\nCMUX_UITEST_STACK_PASSWORD=test-password\n",
    { mode: 0o600 },
  );
  fs.writeFileSync(
    path.join(binDir, "defaults"),
    "#!/bin/bash\nexit 0\n",
    { mode: 0o755 },
  );
  fs.writeFileSync(
    path.join(binDir, "xcrun"),
    [
      "#!/bin/bash",
      'if [[ "$*" == "simctl list devices booted" ]]; then',
      '  printf "iPhone 17 (AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA) (Booted)\\n"',
      "  exit 0",
      "fi",
      'printf "%s\\n" "$*" >> "$CMUX_TEST_XCRUN_LOG"',
      "exit 0",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );

  try {
    const result = run(
      "bash",
      [
        "scripts/mobile-dev-launch.sh",
        "--tag",
        `ensure-missing-${process.pid}`,
        "--simulator",
        "iPhone 17",
        "--ensure-mac",
        "--detach",
        "--agent",
      ],
      {
        HOME: tempRoot,
        PATH: `${binDir}:${process.env.PATH}`,
        CMUX_TEST_XCRUN_LOG: xcrunLog,
      },
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /could not prepare tagged Mac.*auto-pair/i);
    const calls = fs.existsSync(xcrunLog) ? fs.readFileSync(xcrunLog, "utf8") : "";
    assert.doesNotMatch(calls, /simctl launch/);
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("local iOS reload never hides a requested setup failure with a plain launch", () => {
  const iosReload = fs.readFileSync(path.join(repoRoot, "ios/scripts/reload.sh"), "utf8");

  assert.doesNotMatch(iosReload, /signed launch failed; launching plain/);
  assert.match(
    iosReload,
    /elif ! auto_setup_launch simulator \"\$SIM_ID\"; then[\s\S]{0,240}return 1/,
  );
  assert.match(
    iosReload,
    /auto_setup_launch device \"\$selected_device_install_id\"[\s\S]{0,2200}return 1/,
  );
});

test("iOS reload builds and installs on an exact isolated simulator id", () => {
  const iosReload = fs.readFileSync(path.join(repoRoot, "ios/scripts/reload.sh"), "utf8");

  assert.match(iosReload, /--simulator-id\)/);
  assert.match(
    iosReload,
    /DESTINATION="platform=iOS Simulator,id=\$SIMULATOR_ID"/,
  );
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
