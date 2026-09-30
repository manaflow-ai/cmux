import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const reload = readFileSync(new URL("../scripts/reload.sh", import.meta.url), "utf8");
const simulatorBuild = reload.match(/^reload_simulator\(\) \{[\s\S]*?^\}/m)?.[0];
const destination = reload.match(/^DESTINATION="platform=iOS Simulator,[\s\S]*?(?=^MOBILE_DEV_LAUNCH=)/m)?.[0];
assert.ok(simulatorBuild, "reload_simulator function is present");
assert.ok(destination, "simulator destination selection is present");

function build(compilerStatus = 0) {
  const derived = mkdtempSync(join(tmpdir(), "cmux-simulator-build-test-"));
  try {
    mkdirSync(join(derived, "Build/Products/Debug-iphonesimulator/cmux.app"), { recursive: true });
    return spawnSync("bash", ["-c", `
      set -euo pipefail
      xcodebuild() { printf 'ARG=%s\\n' "$@"; return "$COMPILER_STATUS"; }
      xcrun() { echo 'unexpected simulator operation' >&2; exit 99; }
      for variable in TAG SIMULATOR_NAME WORKSPACE SCHEME BUNDLE_ID DISPLAY_NAME GIT_SHA \
          CMUX_IOS_AUTH_ENV_VALUE CMUX_IOS_SIMULATOR_API_BASE_URL_VALUE \
          CMUX_IOS_IROH_BROKER_BASE_URL_VALUE CMUX_IROH_V2_ENVIRONMENT_VALUE \
          CMUX_IROH_V2_BASE_URL_VALUE; do
        printf -v "$variable" '%s' test
      done
      BUILD_ONLY=1
      SIMULATOR_ID=
      XCODEBUILD_PARALLEL_ARGS=()
      IROH_RELAY_POLICY_BUILD_ARGS=()
      SWIFT_WORKAROUND_ARGS=()
      eval "$DESTINATION_SOURCE"
      eval "$BUILD_SOURCE"
      reload_simulator
    `], {
      encoding: "utf8",
      env: { ...process.env, DERIVED_DATA: derived, COMPILER_STATUS: String(compilerStatus),
        DESTINATION_SOURCE: destination, BUILD_SOURCE: simulatorBuild },
    });
  } finally {
    rmSync(derived, { recursive: true, force: true });
  }
}

test("build-only compiles an arm64 simulator app without touching a simulator", () => {
  const result = build();
  assert.equal(result.status, 0, result.stderr);
  const args = result.stdout.split("\n").filter(line => line.startsWith("ARG=")).map(line => line.slice(4));
  assert.equal(args[args.indexOf("-destination") + 1], "generic/platform=iOS Simulator");
  assert.deepEqual(args.filter(arg => arg.startsWith("ARCHS=")), ["ARCHS=arm64"]);
  assert.ok(args.includes("ONLY_ACTIVE_ARCH=YES"));
  assert.equal(args.at(-1), "build");
  assert.match(result.stdout, /==> build only: .*\/cmux\.app/);
});

test("build-only propagates a compiler failure even with an older app present", () => {
  const result = build(42);
  assert.equal(result.status, 42, result.stderr);
  assert.doesNotMatch(result.stdout, /==> build only:/);
});
