// Run with: node --test scripts/lib/mobile-attach.test.mjs
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
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
  const productionGuard = extractShellFunction(source, "cmux_ios_require_production_origin");
  const resolver = extractShellFunction(source, "cmux_ios_resolve_api_base_url");
  return run(
    "bash",
    ["-c", `${productionGuard}; ${resolver}; cmux_ios_resolve_api_base_url "$1"`, "ios-origin-test", target],
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
  const productionGuard = extractShellFunction(source, "cmux_ios_require_production_origin");
  const resolver = extractShellFunction(source, "cmux_ios_resolve_iroh_broker_base_url");
  return run(
    "bash",
    ["-c", `${productionGuard}; ${resolver}; cmux_ios_resolve_iroh_broker_base_url`, "ios-origin-test"],
    {
      CMUX_IOS_IROH_BROKER_BASE_URL: "",
      CMUX_IROH_BROKER_BASE_URL: "",
      PROD_AUTH: "0",
      ...extraEnv,
    },
  );
}

test("shared dev-tag validator rejects every spelling that sanitizes to default", () => {
  for (const tag of ["default", "DEFAULT", "...Default..."]) {
    const result = validate(tag);
    assert.notEqual(result.status, 0, `${tag} unexpectedly passed`);
    assert.match(result.stderr, new RegExp(reservedMessage));
  }
});

test("shared dev-tag validator permits non-sentinel tags", () => {
  for (const tag of ["future-one", "default-2", "de-fault"]) {
    const result = validate(tag);
    assert.equal(result.status, 0, `${tag}: ${result.stderr}`);
  }
});

test("shared dev-tag validator refuses every spelling but the slug, so no two tags share a build space", () => {
  for (const [tag, slug] of [["de fault", "de-fault"], ["foo_bar", "foo-bar"], ["Foo-Bar", "foo-bar"], ["foo--bar", "foo-bar"]]) {
    const result = validate(tag);
    assert.notEqual(result.status, 0, `${tag} unexpectedly passed`);
    assert.match(result.stderr, new RegExp(`is not a canonical tag.*--tag ${slug}`));
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

test("macOS and iOS reloads share the dev API backend override", () => {
  const macReload = fs.readFileSync(path.join(repoRoot, "scripts/reload.sh"), "utf8");
  const iosReload = fs.readFileSync(path.join(repoRoot, "ios/scripts/reload.sh"), "utf8");

  assert.match(macReload, /CMUX_DEV_API_BASE_URL_VALUE=.*cmux_attach_resolve_dev_api_base_url/);
  assert.match(macReload, /CMUX_API_BASE_URL="\$CMUX_DEV_API_BASE_URL_VALUE"/);
  assert.match(iosReload, /explicit_base_url=.*CMUX_DEV_API_BASE_URL/);
});

test("tagged macOS launches require a personal credential file by default", () => {
  const macReload = fs.readFileSync(path.join(repoRoot, "scripts/reload.sh"), "utf8");

  assert.match(macReload, /tagged launches require authenticated dev credentials/u);
  assert.match(macReload, /cmuxterm-dev\.env.*cmux\.env/su);
  assert.match(macReload, /AUTH_PROFILE="personal"/u);
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

test("iOS production-auth rejects staging origin overrides", () => {
  const api = resolveIOSAPIBaseURL("physical_device", {
    PROD_AUTH: "1",
    CMUX_DEV_API_BASE_URL: "https://cmux-staging.vercel.app",
  });
  assert.notEqual(api.status, 0);
  assert.match(api.stderr, /--prod-auth cannot use the API origin/u);

  const broker = resolveIOSIrohBrokerBaseURL({
    PROD_AUTH: "1",
    CMUX_IROH_BROKER_BASE_URL: "https://cmux-staging.vercel.app",
  });
  assert.notEqual(broker.status, 0);
  assert.match(broker.stderr, /--prod-auth cannot use the Iroh broker origin/u);
});

test("the iOS reload keeps its Iroh broker; the Mac reload injects no Iroh config", () => {
  const macReload = fs.readFileSync(path.join(repoRoot, "scripts/reload.sh"), "utf8");
  const iosReload = fs.readFileSync(path.join(repoRoot, "ios/scripts/reload.sh"), "utf8");

  // The cmux-next Mac app no longer runs the iroh phone listener, the only
  // reader of the broker and v2 control-plane settings on the Mac.
  assert.doesNotMatch(macReload, /CMUX_IROH_(BROKER_BASE_URL|V2_[A-Z_]+)/);
  const macInfo = fs.readFileSync(path.join(repoRoot, "Resources/Info.plist"), "utf8");
  assert.doesNotMatch(macInfo, /CMUX_IROH_V2_/);
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

test("simulator launch seeds a deterministic durable device id before app launch", () => {
  const launcher = fs.readFileSync(
    path.join(repoRoot, "scripts/mobile-dev-launch.sh"),
    "utf8",
  );
  const branchStart = launcher.indexOf('\nif [[ "$TARGET" == "simulator" ]]');
  const simulatorBranch = launcher.slice(
    branchStart,
    launcher.indexOf("\nelse\n", branchStart),
  );
  const seed = simulatorBranch.indexOf(
    'cmux_attach_seed_simulator_device_id "$SIM_UDID" "$BUNDLE_ID"',
  );
  const seedEnvironment = simulatorBranch.indexOf(
    'SIMCTL_CHILD_CMUX_SIMULATOR_DEVICE_ID="$SIMULATOR_DEVICE_ID"',
  );
  const terminate = simulatorBranch.indexOf('xcrun simctl terminate');
  const launch = simulatorBranch.indexOf('xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"');

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

test("release gate keeps its transport proofs and refuses the Mac app-rpc modes", () => {
  for (const [mode, expectedPlan] of [
    ["direct-only", "simulator-direct-transport"],
    ["private-path", "host-private-path-transport"],
  ]) {
    const result = run("bash", [
      "scripts/run-iroh-release-gate.sh", "--mode", mode, "--tag", `plan-${mode}`, "--print-plan",
    ]);
    assert.equal(result.status, 0, `${mode}: ${result.stderr}`);
    assert.equal(result.stdout.trim(), expectedPlan);
  }
  for (const mode of ["automatic", "relay-only", "relay-expiry"]) {
    const result = run("bash", [
      "scripts/run-iroh-release-gate.sh", "--mode", mode, "--tag", `plan-${mode}`, "--print-plan",
    ]);
    assert.equal(result.status, 2, `${mode}: ${result.stderr}`);
    assert.match(result.stderr, /no longer runs the iroh phone listener/);
    assert.equal(result.stdout, "");
  }
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

test("a simulator app without the app-receipt contract is refused before launch", () => {
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

    // No installed app means no CMUXDogfoodReadiness, which used to fall back
    // to mac-rpc. That needs the Mac's iroh listener, which is gone.
    assert.equal(result.status, 2, result.stderr);
    assert.match(result.stderr, /no longer runs the iroh phone listener/);
    assert.match(result.stderr, /--readiness app-receipt/);
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

test("the Iroh release gate launch is refused before any Mac or simulator work", () => {
  const tag = `missing-mac-${process.pid}`;
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-missing-mac-test-"));
  fs.mkdirSync(path.join(tempRoot, ".secrets"));
  fs.writeFileSync(
    path.join(tempRoot, ".secrets/cmuxterm-dev.env"),
    "CMUX_UITEST_STACK_EMAIL=agent@example.com\nCMUX_UITEST_STACK_PASSWORD=test-password\n",
    { mode: 0o600 },
  );
  const result = run("bash", [
    "scripts/mobile-dev-launch.sh",
    "--tag",
    tag,
    "--simulator",
    "iPhone 17",
    "--attach",
    "--agent",
    "--detach",
    "--iroh-release-gate",
    "automatic",
  ], { HOME: tempRoot });
  fs.rmSync(tempRoot, { recursive: true, force: true });

  assert.equal(result.status, 2, result.stderr);
  assert.match(result.stderr, /--iroh-release-gate has no target/);
  assert.match(result.stderr, /mobile\.attach_ticket\.create \/ mobile\.rpc\.ready/);
  assert.equal(result.stdout, "");
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

// dev-setup.sh with fake reload scripts and launcher: the Mac pairing host is
// gone, so dev-setup must not write its default, and the iOS launch must use
// the app-receipt gate (a physical device exposes no Info.plist, so `auto`
// without CMUX_INSTALLED_APP_PATH would exit 2).
function runDevSetupWithFakes(args) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-dev-setup-test-"));
  const home = path.join(root, "home");
  const bin = path.join(root, "bin");
  const calls = path.join(root, "calls.log");
  fs.mkdirSync(path.join(root, "scripts/lib"), { recursive: true });
  fs.mkdirSync(path.join(root, "ios/scripts"), { recursive: true });
  fs.mkdirSync(path.join(home, ".secrets"), { recursive: true });
  fs.mkdirSync(bin);
  for (const file of ["scripts/dev-setup.sh", "scripts/lib/mobile-attach.sh", "scripts/lib/dev-secrets.sh"]) {
    fs.copyFileSync(path.join(repoRoot, file), path.join(root, file));
  }
  const recorder = (name) => `#!/bin/bash\nprintf '%s %s\\n' "${name}" "$*" >> "$CMUX_TEST_CALLS"\nexit 0\n`;
  fs.writeFileSync(path.join(root, "scripts/reload.sh"), recorder("mac-reload"), { mode: 0o755 });
  fs.writeFileSync(path.join(root, "ios/scripts/reload.sh"), recorder("ios-reload"), { mode: 0o755 });
  fs.writeFileSync(path.join(root, "scripts/mobile-dev-launch.sh"), recorder("mobile-dev-launch"), { mode: 0o755 });
  fs.writeFileSync(path.join(bin, "defaults"), recorder("defaults"), { mode: 0o755 });
  fs.writeFileSync(
    path.join(home, ".secrets/cmuxterm-dev.env"),
    "CMUX_DOGFOOD_STACK_EMAIL=person@example.com\nCMUX_DOGFOOD_STACK_PASSWORD=test-password\n",
    { mode: 0o600 },
  );
  try {
    const result = spawnSync("bash", [path.join(root, "scripts/dev-setup.sh"), ...args], {
      cwd: root,
      encoding: "utf8",
      env: { ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}`, CMUX_TEST_CALLS: calls },
    });
    return { ...result, calls: fs.existsSync(calls) ? fs.readFileSync(calls, "utf8") : "" };
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

for (const target of [["--device"], ["--simulator", "iPhone 17"]]) {
  test(`dev-setup ${target[0]} launches with the app-receipt gate and no Mac pairing host`, () => {
    const result = runDevSetupWithFakes(["--tag", "devsetuptest", ...target]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.calls, /^mac-reload --tag devsetuptest --launch/m);
    assert.doesNotMatch(result.calls, /^defaults /m, "the removed pairing host's default must not be written");
    assert.doesNotMatch(`${result.stdout}${result.stderr}`, /pairing host|auto-pair/i);
    const launch = result.calls.split("\n").find((line) => line.startsWith("mobile-dev-launch "));
    assert.ok(launch, result.calls);
    assert.match(launch, / --readiness app-receipt( |$)/);
    assert.doesNotMatch(launch, / --attach( |$)| --ensure-mac( |$)/);
  });
}
