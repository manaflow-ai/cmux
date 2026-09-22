// Run with: node --test scripts/lib/ios-tagged-device-entitlements.test.mjs
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const read = (relativePath) => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");

const reload = read("ios/scripts/reload.sh");
const sharedConfig = read("ios/Config/Shared.xcconfig");
const releaseConfig = read("ios/Config/Release.xcconfig");
const project = read("ios/cmux-ios.xcodeproj/project.pbxproj");
const appEntitlements = read("ios/Config/cmux.entitlements");
const extensionEntitlements = read("ios/Config/NotificationService.entitlements");
const releaseEntitlements = read("ios/Config/cmux-release.entitlements");
const uploadTestFlight = read("ios/scripts/upload-testflight.sh");
const cloudTestFlight = read("ios/scripts/cloud-testflight.sh");

function extractShellFunction(source, name) {
  const start = source.indexOf(`${name}() {`);
  assert.notEqual(start, -1, `missing shell function ${name}`);
  let cursor = start;
  let depth = 0;
  let inHeredoc = false;
  for (const line of source.slice(start).split("\n")) {
    cursor += line.length + 1;
    if (line.endsWith("<<'PY'")) {
      inHeredoc = true;
      continue;
    }
    if (inHeredoc) {
      if (line === "PY") inHeredoc = false;
      continue;
    }
    for (const char of line) {
      if (char === "{") depth += 1;
      if (char === "}") depth -= 1;
    }
    if (depth === 0) return source.slice(start, cursor - 1);
  }
  assert.fail(`unterminated shell function ${name}`);
}

function fallbackAllowed(configuration, signingBackend, allowProvisioningUpdates) {
  const helper = extractShellFunction(
    reload,
    "cmux_ios_tagged_device_app_group_fallback_allowed",
  );
  return spawnSync(
    "bash",
    [
      "-c",
      `${helper}; cmux_ios_tagged_device_app_group_fallback_allowed "$1" "$2" "$3"`,
      "ios-entitlement-test",
      configuration,
      signingBackend,
      allowProvisioningUpdates ? "1" : "0",
    ],
    { cwd: repoRoot, encoding: "utf8" },
  );
}

function detectsAppGroupProfileMismatch(logBody) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-ios-entitlement-log-"));
  const logPath = path.join(tempRoot, "build.log");
  fs.writeFileSync(logPath, logBody);
  try {
    const helper = extractShellFunction(
      reload,
      "cmux_ios_device_build_failed_for_app_group_entitlement",
    );
    return spawnSync(
      "bash",
      [
        "-c",
        `${helper}; cmux_ios_device_build_failed_for_app_group_entitlement "$1"`,
        "ios-entitlement-log-test",
        logPath,
      ],
      { cwd: repoRoot, encoding: "utf8" },
    );
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

function renderFallbackEntitlements() {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-ios-entitlements-"));
  const helper = extractShellFunction(
    reload,
    "cmux_ios_render_tagged_device_no_app_group_entitlements",
  );
  const result = spawnSync(
    "bash",
    [
      "-c",
      `IOS_DIR="$1"; ${helper}; cmux_ios_render_tagged_device_no_app_group_entitlements "$2"`,
      "ios-entitlement-render-test",
      path.join(repoRoot, "ios"),
      tempRoot,
    ],
    { cwd: repoRoot, encoding: "utf8" },
  );
  return { result, tempRoot };
}

function simulatorBuildBlock() {
  const start = reload.indexOf("reload_simulator() {");
  const end = reload.indexOf("\n# Every phone build ships with the same-tag Mac dev build", start);
  assert.notEqual(start, -1, "missing reload_simulator");
  assert.notEqual(end, -1, "missing end of reload_simulator");
  return reload.slice(start, end);
}

test("tagged Debug API-key signing can retry without the App Group", () => {
  const allowed = fallbackAllowed("Debug", "asc-api-key", true);
  assert.equal(allowed.status, 0, allowed.stderr);

  const mismatch = detectsAppGroupProfileMismatch(
    "error: Provisioning profile \"iOS Team Provisioning Profile: dev.cmux.ios.fresh\" " +
      "doesn't match the entitlements file's value for the " +
      "com.apple.security.application-groups entitlement.\n",
  );
  assert.equal(mismatch.status, 0, mismatch.stderr);

  const { result, tempRoot } = renderFallbackEntitlements();
  try {
    assert.equal(result.status, 0, result.stderr);
    const app = fs.readFileSync(path.join(tempRoot, "cmux.entitlements"), "utf8");
    const extension = fs.readFileSync(
      path.join(tempRoot, "NotificationService.entitlements"),
      "utf8",
    );
    assert.doesNotMatch(app, /com\.apple\.security\.application-groups/u);
    assert.doesNotMatch(extension, /com\.apple\.security\.application-groups/u);
    assert.match(app, /<key>aps-environment<\/key>\s*<string>development<\/string>/u);
    assert.match(app, /com\.apple\.developer\.usernotifications\.time-sensitive/u);
    assert.match(app, /keychain-access-groups/u);
    assert.match(extension, /keychain-access-groups/u);
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }

  assert.match(
    reload,
    /run_and_capture "\$build_log" "\$\{build_args\[@\]\}" build/u,
  );
  assert.match(
    reload,
    /CMUX_APP_CODE_SIGN_ENTITLEMENTS=\$fallback_entitlements_dir\/cmux\.entitlements/u,
  );
  assert.match(
    reload,
    /CMUX_NOTIFICATION_SERVICE_CODE_SIGN_ENTITLEMENTS=\$fallback_entitlements_dir\/NotificationService\.entitlements/u,
  );
});

test("App Group fallback is narrow and preserves capable signing paths", () => {
  for (const [configuration, backend, provisioningUpdates] of [
    ["Debug", "xcode-account", true],
    ["Debug", "asc-api-key", false],
    ["Release", "asc-api-key", true],
    ["Profile", "asc-api-key", true],
    ["AppStore", "asc-api-key", true],
  ]) {
    const result = fallbackAllowed(configuration, backend, provisioningUpdates);
    assert.notEqual(
      result.status,
      0,
      `${configuration}/${backend}/${provisioningUpdates} unexpectedly allowed fallback`,
    );
  }

  const unrelated = detectsAppGroupProfileMismatch(
    "error: Provisioning profile has expired.\n",
  );
  assert.notEqual(unrelated.status, 0);

  for (const entitlements of [appEntitlements, extensionEntitlements]) {
    assert.match(entitlements, /com\.apple\.security\.application-groups/u);
    assert.match(entitlements, /group\.dev\.cmux\.ios/u);
  }

  const renderer = extractShellFunction(
    reload,
    "cmux_ios_render_tagged_device_no_app_group_entitlements",
  );
  assert.match(renderer, /Config\/cmux\.entitlements/u);
  assert.match(renderer, /Config\/NotificationService\.entitlements/u);
  assert.doesNotMatch(renderer, /release/i);
  assert.match(renderer, /expected_group = \["group\.dev\.cmux\.ios"\]/u);
});

test("tagged Simulator builds keep the existing full entitlement selection", () => {
  const simulator = simulatorBuildBlock();

  assert.match(
    sharedConfig,
    /CMUX_APP_CODE_SIGN_ENTITLEMENTS = Config\/cmux\.entitlements/u,
  );
  assert.match(
    sharedConfig,
    /CMUX_NOTIFICATION_SERVICE_CODE_SIGN_ENTITLEMENTS = Config\/NotificationService\.entitlements/u,
  );
  assert.match(simulator, /CODE_SIGNING_ALLOWED=NO/u);
  assert.doesNotMatch(simulator, /fallback_entitlements|no-app-group/u);
});

test("Release and TestFlight entitlement behavior stays on the production lane", () => {
  assert.match(
    releaseConfig,
    /CMUX_APP_CODE_SIGN_ENTITLEMENTS = Config\/cmux-release\.entitlements/u,
  );
  assert.match(
    releaseConfig,
    /CODE_SIGN_ENTITLEMENTS = \$\(CMUX_APP_CODE_SIGN_ENTITLEMENTS\)/u,
  );
  assert.match(
    releaseEntitlements,
    /<key>aps-environment<\/key>\s*<string>production<\/string>/u,
  );

  const extensionSelectorMatches = project.match(
    /CODE_SIGN_ENTITLEMENTS = "\$\(CMUX_NOTIFICATION_SERVICE_CODE_SIGN_ENTITLEMENTS\)";/gu,
  ) ?? [];
  assert.equal(extensionSelectorMatches.length, 2);
  assert.match(extensionEntitlements, /group\.dev\.cmux\.ios/u);

  assert.doesNotMatch(releaseConfig, /fallback_entitlements|no-app-group/u);
  assert.doesNotMatch(uploadTestFlight, /fallback_entitlements|no-app-group/u);
  assert.doesNotMatch(cloudTestFlight, /fallback_entitlements|no-app-group/u);

  // The shipping manual re-sign path still seeds from the selected distribution
  // provisioning profile before merging cmux-release.entitlements.
  assert.match(
    uploadTestFlight,
    /plutil -extract Entitlements xml1 -o "\$PROFILE_ENTITLEMENTS"/u,
  );
  assert.match(uploadTestFlight, /Merge \$PROFILE_ENTITLEMENTS/u);
});

test("production configurations cannot enter the tagged Debug fallback", () => {
  const helper = extractShellFunction(
    reload,
    "cmux_ios_tagged_device_app_group_fallback_allowed",
  );
  assert.match(helper, /"\$configuration" == "Debug"/u);
  assert.match(helper, /"\$signing_backend" == "asc-api-key"/u);
  assert.match(helper, /"\$allow_provisioning_updates" == "1"/u);
  assert.match(reload, /local configuration="Debug"/u);

  const fullAttempt = reload.indexOf(
    'run_and_capture "$build_log" "${build_args[@]}" build',
  );
  const renderer = reload.indexOf(
    'cmux_ios_render_tagged_device_no_app_group_entitlements "$fallback_entitlements_dir"',
  );
  const retry = reload.indexOf(
    '"CMUX_APP_CODE_SIGN_ENTITLEMENTS=$fallback_entitlements_dir/cmux.entitlements"',
  );
  assert.ok(fullAttempt >= 0, "full-entitlement device build attempt is missing");
  assert.ok(renderer > fullAttempt, "fallback entitlements must be generated only after full signing fails");
  assert.ok(retry > renderer, "no-App-Group override must appear only on the retry");
});
