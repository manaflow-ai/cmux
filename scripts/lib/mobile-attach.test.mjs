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

function resolveIOSIrohBrokerBaseURL(extraEnv = {}) {
  const source = fs.readFileSync(path.join(repoRoot, "ios/scripts/reload.sh"), "utf8");
  const resolver = extractShellFunction(source, "cmux_ios_resolve_iroh_broker_base_url");
  return run(
    "bash",
    ["-c", `${resolver}; cmux_ios_resolve_iroh_broker_base_url`, "ios-origin-test"],
    {
      CMUX_IOS_IROH_BROKER_BASE_URL: "",
      CMUX_IROH_BROKER_BASE_URL: "",
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

async function ensureMacAfterRelaunch() {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-mobile-ready-test-"));
  const socketPath = path.join(tempRoot, "mobile.sock");
  const appPath = path.join(tempRoot, "cmux DEV ready.app");
  const callCounterPath = path.join(tempRoot, "call-count");
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
          '  if [[ "$count" -ge 2 ]]; then printf "cmux-ios-dev://attach?v=2&kind=iroh"; return 0; fi',
          '  return 1',
          '}',
          'pkill() { return 0; }',
          'open() { return 0; }',
          'sleep() { return 0; }',
          'CMUX_ATTACH_ALLOW_RELAUNCH=1 cmux_attach_ensure_mac "ready" "$2" physical_device',
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

test("iOS physical-device Debug builds default both services to staging", () => {
  const api = resolveIOSAPIBaseURL("physical_device", { CMUX_PORT: "4123" });
  const broker = resolveIOSIrohBrokerBaseURL();

  assert.equal(api.status, 0, api.stderr);
  assert.equal(api.stdout, "https://cmux-staging.vercel.app");
  assert.equal(broker.status, 0, broker.stderr);
  assert.equal(broker.stdout, "https://cmux-staging.vercel.app");
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

  const broker = resolveIOSIrohBrokerBaseURL({
    CMUX_IOS_IROH_BROKER_BASE_URL: "https://relay.dev.example",
    CMUX_IROH_BROKER_BASE_URL: "https://ignored.example",
  });
  assert.equal(broker.status, 0, broker.stderr);
  assert.equal(broker.stdout, "https://relay.dev.example");
});

test("iOS production-auth builds keep production service origins", () => {
  for (const target of ["simulator", "physical_device"]) {
    const api = resolveIOSAPIBaseURL(target, { PROD_AUTH: "1", CMUX_PORT: "4123" });
    assert.equal(api.status, 0, api.stderr);
    assert.equal(api.stdout, "https://cmux.com");
  }

  const broker = resolveIOSIrohBrokerBaseURL({ PROD_AUTH: "1" });
  assert.equal(broker.status, 0, broker.stderr);
  assert.equal(broker.stdout, "https://cmux.com");
});

test("tagged reloads share a dedicated Iroh broker", () => {
  const macReload = fs.readFileSync(path.join(repoRoot, "scripts/reload.sh"), "utf8");
  const iosReload = fs.readFileSync(path.join(repoRoot, "ios/scripts/reload.sh"), "utf8");

  assert.match(macReload, /CMUX_IROH_BROKER_BASE_URL_VALUE=.*cmux-staging\.vercel\.app/);
  assert.match(macReload, /CMUX_IROH_BROKER_BASE_URL="\$CMUX_IROH_BROKER_BASE_URL_VALUE"/);
  assert.match(iosReload, /CMUX_IOS_IROH_BROKER_BASE_URL_VALUE=.*cmux_ios_resolve_iroh_broker_base_url/);
  assert.match(iosReload, /CMUX_IROH_BROKER_BASE_URL="\$CMUX_IOS_IROH_BROKER_BASE_URL_VALUE"/);
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
  assert.match(
    workflow,
    /iroh_broker_base_url="\$\{CMUX_IOS_IROH_BROKER_BASE_URL:-\$\{CMUX_IROH_BROKER_BASE_URL:-https:\/\/cmux-staging\.vercel\.app\}\}"/,
  );
  assert.match(workflow, /CMUX_API_BASE_URL="\$api_base_url"/);
  assert.match(workflow, /CMUX_IROH_BROKER_BASE_URL="\$iroh_broker_base_url"/);
});

test("physical-device mint rejects a ticket with only plaintext Tailscale routes", async () => {
  const result = await mintAttachURL(
    "physical_device",
    [attachPayload("tailscale"), attachPayload("tailscale")],
    2,
  );
  assert.equal(result.status, 2);
  assert.equal(result.stdout, "");
  assert.equal(result.callCount, 2);
});

test("physical-device mint waits for asynchronous Iroh publication", async () => {
  const payload = attachPayload("iroh");
  const result = await mintAttachURL(
    "physical_device",
    [attachPayload("tailscale"), payload],
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

test("physical-device mint accepts an encrypted Iroh route", async () => {
  const payload = attachPayload("iroh");
  const result = await mintAttachURL("physical_device", payload);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
});

test("QR fallback waits for the exact tagged Mac's authenticated Iroh route", () => {
  const result = runQRGenerator([
    attachPayload("tailscale"),
    attachPayload("iroh"),
  ]);

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.callCount, 2);
  assert.deepEqual(
    result.params.map((params) => params.route_kind),
    ["iroh", "iroh"],
  );
  assert.deepEqual(
    result.filteredPayload.ticket.routes.map((route) => route.kind),
    ["iroh"],
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

test("Mac readiness is revalidated after a tagged relaunch", async () => {
  const result = await ensureMacAfterRelaunch();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.callCount, 2);
});

test("release gate grants asynchronous Iroh publication a bounded startup window", () => {
  const launcher = fs.readFileSync(
    path.join(repoRoot, "scripts/mobile-dev-launch.sh"),
    "utf8",
  );
  const gate = fs.readFileSync(
    path.join(repoRoot, "scripts/run-iroh-release-gate.sh"),
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
  assert.match(
    gate,
    /CMUX_ATTACH_MINT_MAX_ATTEMPTS=600 \\[\s\S]{0,320}\.\/scripts\/mobile-dev-launch\.sh/,
  );
  assert.match(
    gate,
    /CMUX_ATTACH_MINT_MAX_ATTEMPTS=600 \\[\s\S]{0,120}cmux_attach_ensure_mac/,
  );
});

test("release gate assigns each mode to its transport proof", () => {
  const cases = [
    ["automatic", "app-rpc"],
    ["relay-only", "app-rpc"],
    ["relay-expiry", "app-rpc"],
    ["direct-only", "simulator-direct-transport"],
    ["private-path", "host-private-path-transport"],
  ];

  for (const [mode, expectedPlan] of cases) {
    const result = run("bash", [
      "scripts/run-iroh-release-gate.sh",
      "--mode",
      mode,
      "--tag",
      `plan-${mode}`,
      "--print-plan",
    ]);
    assert.equal(result.status, 0, `${mode}: ${result.stderr}`);
    assert.equal(result.stdout.trim(), expectedPlan);
  }
});

test("private-path plan ignores the unrelated staging base URL", () => {
  const result = run("bash", [
    "scripts/run-iroh-release-gate.sh",
    "--mode",
    "private-path",
    "--tag",
    "plan-private",
    "--staging-base-url",
    "not-a-network-url",
    "--print-plan",
  ]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), "host-private-path-transport");
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

test("local iOS reload never hides a requested setup failure with a plain launch", () => {
  const iosReload = fs.readFileSync(path.join(repoRoot, "ios/scripts/reload.sh"), "utf8");

  assert.doesNotMatch(iosReload, /signed launch failed; launching plain/);
  assert.match(
    iosReload,
    /elif ! auto_setup_launch simulator \"\$SIM_ID\"; then[\s\S]{0,240}return 1/,
  );
  assert.match(
    iosReload,
    /elif ! auto_setup_launch device \"\$selected_device_install_id\"; then[\s\S]{0,640}return 1/,
  );
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
