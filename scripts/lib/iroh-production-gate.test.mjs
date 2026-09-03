import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
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

function writeGateAppPlist(
  appPath,
  entries,
  environmentEntries = {},
  platform = "ios",
) {
  const contents = platform === "macOS" ? path.join(appPath, "Contents") : appPath;
  mkdirSync(contents, { recursive: true });
  const values = Object.entries(entries)
    .map(([key, value]) => `<key>${key}</key><string>${value}</string>`)
    .join("");
  const environmentValues = Object.entries(environmentEntries)
    .map(([key, value]) => `<key>${key}</key><string>${value}</string>`)
    .join("");
  const environment = environmentValues
    ? `<key>LSEnvironment</key><dict>${environmentValues}</dict>`
    : "";
  writeFileSync(
    path.join(contents, "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>${values}${environment}</dict></plist>
`,
  );
}

test("release gate rejects Mac and iOS artifacts configured for different authorities", (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const macApp = path.join(directory, "cmux DEV gate.app");
  const iosApp = path.join(directory, "cmux.app");
  const expected = "https://gate.example";
  const presence = "https://presence.example";

  writeGateAppPlist(macApp, {}, {
    CMUX_API_BASE_URL: "https://stale.example",
    CMUX_IROH_BROKER_BASE_URL: "https://stale.example",
  }, "macOS");
  writeGateAppPlist(iosApp, {
    CMUXApiBaseURL: expected,
    CMUXIrohBrokerBaseURL: expected,
    CMUXPresenceBaseURL: presence,
  });

  const mismatch = run("bash", [
    "scripts/lib/verify-iroh-release-gate-builds.sh",
    "--mac-app", macApp,
    "--ios-app", iosApp,
    "--backend-base-url", expected,
    "--presence-base-url", presence,
  ]);
  assert.notEqual(mismatch.status, 0);
  assert.match(mismatch.stderr, /Mac app.*requested backend/u);
  assert.match(mismatch.stderr, /rebuild without --skip-build/u);

  writeGateAppPlist(macApp, {}, {
    CMUX_API_BASE_URL: expected,
    CMUX_IROH_BROKER_BASE_URL: expected,
  }, "macOS");
  const presenceMismatch = run("bash", [
    "scripts/lib/verify-iroh-release-gate-builds.sh",
    "--mac-app", macApp,
    "--ios-app", iosApp,
    "--backend-base-url", expected,
    "--presence-base-url", presence,
  ]);
  assert.notEqual(presenceMismatch.status, 0);
  assert.match(presenceMismatch.stderr, /Mac app presence.*requested backend/u);

  writeGateAppPlist(macApp, {}, {
    CMUX_API_BASE_URL: expected,
    CMUX_IROH_BROKER_BASE_URL: expected,
    CMUX_PRESENCE_BASE_URL: presence,
  }, "macOS");
  const matched = run("bash", [
    "scripts/lib/verify-iroh-release-gate-builds.sh",
    "--mac-app", macApp,
    "--ios-app", iosApp,
    "--backend-base-url", expected,
    "--presence-base-url", presence,
  ]);
  assert.equal(matched.status, 0, matched.stderr);
});

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

test("release gate iOS build is isolated from the configured default iPhone", () => {
  const result = run("bash", ["-c", [
    "set -euo pipefail",
    "source scripts/lib/iroh-release-gate-targets.sh",
    "iroh_release_gate_set_ios_reload_args prodgate 'cmux Iroh gate prodgate' SIMULATOR-ID 1",
    "printf '<%s>\\n' \"${IROH_RELEASE_GATE_IOS_RELOAD_ARGS[@]}\"",
  ].join("; ")]);

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, [
    "<--tag>",
    "<prodgate>",
    "<--simulator>",
    "<cmux Iroh gate prodgate>",
    "<--simulator-id>",
    "<SIMULATOR-ID>",
    "<--simulator-only>",
    "<--prod-auth>",
    "<--no-launch>",
    "",
  ].join("\n"));
});

test("iOS release artifact gate rejects staged runtime origins", (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const app = path.join(directory, "cmux.app");
  const args = ["scripts/lib/verify-ios-release-origins.sh", "--app", app];

  writeGateAppPlist(app, {
    CFBundleIdentifier: "dev.cmux.app.internal",
    CMUXAuthEnvironment: "production",
    CMUXApiBaseURL: "https://cmux.com",
    CMUXIrohBrokerBaseURL: "https://cmux.com",
    CMUXPresenceBaseURL: "https://presence.cmux.dev",
    CMUXDevTag: "",
  });
  const valid = run("bash", args);
  assert.equal(valid.status, 0, valid.stderr);

  writeGateAppPlist(app, {
    CFBundleIdentifier: "dev.cmux.app.internal",
    CMUXAuthEnvironment: "production",
    CMUXApiBaseURL: "https://cmux.com",
    CMUXIrohBrokerBaseURL: "https://cmux-staging.vercel.app",
    CMUXPresenceBaseURL: "https://presence.cmux.dev",
    CMUXDevTag: "internal",
  });
  const invalid = run("bash", args);
  assert.notEqual(invalid.status, 0);
  assert.match(invalid.stderr, /CMUXIrohBrokerBaseURL/u);
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
  const reportOutput = path.join(directory, "release-gate-report.json");
  writeFileSync(reportOutput, '{"passed":true,"stale":true}\n', { mode: 0o600 });

  const result = run("bash", [
    "scripts/run-iroh-release-gate.sh",
    "--mode", "automatic",
    "--tag", "prodtmp",
    "--production",
    "--stack-env-file", stackEnvironment,
    "--report-output", reportOutput,
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
  assert.equal(existsSync(reportOutput), false);
});

test("production release gate removes disposable tagged Iroh endpoint state", (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));

  const fakeBin = path.join(directory, "bin");
  mkdirSync(fakeBin, { mode: 0o700 });
  const fakeBun = path.join(fakeBin, "bun");
  writeFileSync(fakeBun, "#!/usr/bin/env bash\nexit 73\n", { mode: 0o755 });
  chmodSync(fakeBun, 0o755);

  const stackEnvironment = path.join(directory, "stack.env");
  writeFileSync(stackEnvironment, "unused=true\n", { mode: 0o600 });
  chmodSync(stackEnvironment, 0o600);

  const bundleID = "com.cmuxterm.app.debug.prodstate";
  const endpointState = path.join(
    directory,
    "Library",
    "Application Support",
    "cmux",
    "iroh-debug",
    bundleID,
  );
  mkdirSync(endpointState, { recursive: true, mode: 0o700 });
  writeFileSync(path.join(endpointState, "endpoint.key"), "disposable\n", {
    mode: 0o600,
  });

  const result = run("bash", [
    "scripts/run-iroh-release-gate.sh",
    "--mode", "automatic",
    "--tag", "prodstate",
    "--production",
    "--stack-env-file", stackEnvironment,
  ], {
    HOME: directory,
    PATH: `${fakeBin}:${process.env.PATH}`,
    TMPDIR: `${directory}/`,
  });

  assert.equal(result.status, 73, result.stderr);
  assert.equal(existsSync(endpointState), false);
});

test("Mac reload documents production auth without accepting secret values", () => {
  const result = run("bash", ["scripts/reload.sh", "--help"]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /--prod-auth/u);
  assert.match(result.stdout, /--credentials-file <path>/u);
  assert.match(result.stdout, /credential values never enter argv/u);
});
