// Run with: node --test scripts/lib/ios-tagged-device-entitlements.test.mjs
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
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
const debugAppNoGroup = read("ios/Config/cmux-debug-no-app-group.entitlements");
const debugExtensionNoGroup = read("ios/Config/NotificationService-debug-no-app-group.entitlements");
const releaseEntitlements = read("ios/Config/cmux-release.entitlements");
const uploadTestFlight = read("ios/scripts/upload-testflight.sh");
const cloudTestFlight = read("ios/scripts/cloud-testflight.sh");

function extractShellFunction(source, name) {
  const start = source.indexOf(`${name}() {`);
  assert.notEqual(start, -1, `missing shell function ${name}`);
  const end = source.indexOf("\n}", start);
  assert.notEqual(end, -1, `unterminated shell function ${name}`);
  return source.slice(start, end + 2);
}

function taggedDeviceEntitlementMode(configuration, signingBackend, allowProvisioningUpdates) {
  const resolver = extractShellFunction(reload, "cmux_ios_tagged_device_entitlement_mode");
  return spawnSync(
    "bash",
    [
      "-c",
      `${resolver}; cmux_ios_tagged_device_entitlement_mode "$1" "$2" "$3"`,
      "ios-entitlement-test",
      configuration,
      signingBackend,
      allowProvisioningUpdates ? "1" : "0",
    ],
    { cwd: repoRoot, encoding: "utf8" },
  );
}

function simulatorBuildBlock() {
  const start = reload.indexOf("reload_simulator() {");
  const end = reload.indexOf("\n# Every phone build ships with the same-tag Mac dev build", start);
  assert.notEqual(start, -1, "missing reload_simulator");
  assert.notEqual(end, -1, "missing end of reload_simulator");
  return reload.slice(start, end);
}

test("tagged Debug device API-key signing omits only the unsupported App Group", () => {
  const mode = taggedDeviceEntitlementMode("Debug", "asc-api-key", true);
  assert.equal(mode.status, 0, mode.stderr);
  assert.equal(mode.stdout, "no-app-group");

  assert.doesNotMatch(debugAppNoGroup, /com\.apple\.security\.application-groups/u);
  assert.doesNotMatch(debugExtensionNoGroup, /com\.apple\.security\.application-groups/u);
  assert.match(debugAppNoGroup, /<key>aps-environment<\/key>\s*<string>development<\/string>/u);
  assert.match(debugAppNoGroup, /com\.apple\.developer\.usernotifications\.time-sensitive/u);
  assert.match(debugAppNoGroup, /keychain-access-groups/u);
  assert.match(debugExtensionNoGroup, /keychain-access-groups/u);

  assert.match(
    reload,
    /CMUX_APP_CODE_SIGN_ENTITLEMENTS=Config\/cmux-debug-no-app-group\.entitlements/u,
  );
  assert.match(
    reload,
    /CMUX_NOTIFICATION_SERVICE_CODE_SIGN_ENTITLEMENTS=Config\/NotificationService-debug-no-app-group\.entitlements/u,
  );
});

test("Debug device signing keeps the App Group when the signing path can grant it", () => {
  const localAccount = taggedDeviceEntitlementMode("Debug", "xcode-account", true);
  assert.equal(localAccount.status, 0, localAccount.stderr);
  assert.equal(localAccount.stdout, "default");

  const preprovisionedAPIKey = taggedDeviceEntitlementMode("Debug", "asc-api-key", false);
  assert.equal(preprovisionedAPIKey.status, 0, preprovisionedAPIKey.stderr);
  assert.equal(preprovisionedAPIKey.stdout, "default");

  for (const entitlements of [appEntitlements, extensionEntitlements]) {
    assert.match(entitlements, /com\.apple\.security\.application-groups/u);
    assert.match(entitlements, /group\.dev\.cmux\.ios/u);
  }
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
  assert.doesNotMatch(simulator, /no-app-group|CMUX_APP_CODE_SIGN_ENTITLEMENTS/u);
});

test("Release and TestFlight paths cannot select the Debug no-App-Group entitlements", () => {
  const releaseMode = taggedDeviceEntitlementMode("Release", "asc-api-key", true);
  assert.equal(releaseMode.status, 0, releaseMode.stderr);
  assert.equal(releaseMode.stdout, "default");

  assert.match(
    releaseConfig,
    /CMUX_APP_CODE_SIGN_ENTITLEMENTS = Config\/cmux-release\.entitlements/u,
  );
  assert.match(
    releaseConfig,
    /CODE_SIGN_ENTITLEMENTS = \$\(CMUX_APP_CODE_SIGN_ENTITLEMENTS\)/u,
  );
  assert.match(releaseEntitlements, /<key>aps-environment<\/key>\s*<string>production<\/string>/u);
  assert.doesNotMatch(releaseConfig, /no-app-group/u);
  assert.doesNotMatch(uploadTestFlight, /debug-no-app-group/u);
  assert.doesNotMatch(cloudTestFlight, /debug-no-app-group/u);

  const extensionSelectorMatches = project.match(
    /CODE_SIGN_ENTITLEMENTS = "\$\(CMUX_NOTIFICATION_SERVICE_CODE_SIGN_ENTITLEMENTS\)";/gu,
  ) ?? [];
  assert.equal(extensionSelectorMatches.length, 2);
  assert.match(extensionEntitlements, /group\.dev\.cmux\.ios/u);

  // The shipping re-sign path continues to seed entitlements from the selected
  // distribution provisioning profile before merging cmux-release.entitlements.
  assert.match(uploadTestFlight, /plutil -extract Entitlements xml1 -o "\$PROFILE_ENTITLEMENTS"/u);
  assert.match(uploadTestFlight, /Merge \$PROFILE_ENTITLEMENTS/u);
});

test("the tagged-device exception is explicitly fenced to Debug provisioning updates", () => {
  for (const configuration of ["Release", "Profile", "AppStore"]) {
    const result = taggedDeviceEntitlementMode(configuration, "asc-api-key", true);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "default", configuration);
  }

  assert.match(reload, /local configuration="Debug"/u);
  assert.match(
    reload,
    /cmux_ios_tagged_device_entitlement_mode \\\n    "\$configuration" "\$DEVICE_SIGNING_BACKEND" "\$ALLOW_PROVISIONING_UPDATES"/u,
  );
});
