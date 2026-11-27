import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
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
    "==> dev sign-in profile: agent ([redacted])",
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

test("production release gate is refused before creating runtime state", (t) => {
  // The production gate paired the iOS app with the tagged Mac app's iroh
  // phone listener, which the cmux-next Mac app removed. It must stop before
  // creating a temporary account, building, or touching endpoint state.
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const fakeBin = path.join(directory, "bin");
  mkdirSync(fakeBin, { mode: 0o700 });
  const bunCalls = path.join(directory, "bun-calls");
  writeFileSync(path.join(fakeBin, "bun"), `#!/usr/bin/env bash\necho "$*" >> "${bunCalls}"\nexit 73\n`, { mode: 0o755 });
  const stackEnvironment = path.join(directory, "stack.env");
  writeFileSync(stackEnvironment, "unused=true\n", { mode: 0o600 });
  const reportOutput = path.join(directory, "release-gate-report.json");
  writeFileSync(reportOutput, '{"passed":true,"stale":true}\n', { mode: 0o600 });

  for (const mode of ["automatic", "relay-only", "relay-expiry"]) {
    const result = run("bash", [
      "scripts/run-iroh-release-gate.sh",
      "--mode", mode,
      "--tag", "prodtmp",
      "--production",
      "--stack-env-file", stackEnvironment,
      "--report-output", reportOutput,
    ], { HOME: directory, PATH: `${fakeBin}:${process.env.PATH}`, TMPDIR: `${directory}/` });
    assert.equal(result.status, 2, result.stderr);
    assert.match(result.stderr, /no longer runs the iroh phone listener/u);
  }
  assert.equal(existsSync(bunCalls), false);
});

test("Mac reload documents production auth without accepting secret values", () => {
  const result = run("bash", ["scripts/reload.sh", "--help"]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /--prod-auth/u);
  assert.match(result.stdout, /--credentials-file <path>/u);
  assert.match(result.stdout, /credential values never enter argv/u);
});

