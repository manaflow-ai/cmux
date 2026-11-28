import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import test from "node:test";

const launcher = readFileSync(new URL("../../scripts/mobile-dev-launch.sh", import.meta.url), "utf8");
const start = launcher.indexOf('if [[ "$TARGET" == "simulator" ]]');
const simulatorBranch = launcher.slice(start, launcher.indexOf("\nelse\n", start)) + "\nfi\n";

test("cached simulator relaunch cannot inject a password or pairing URL", () => {
  const result = spawnSync("bash", ["-c", `
    set -euo pipefail
    ONBOARDING_MARKER="$(mktemp)"
    xcrun() {
      if [[ "$2" == spawn ]]; then
        [[ "$4" == defaults && "$5" == write ]] || exit 42
        printf '%s' "$8" > "$ONBOARDING_MARKER"
      fi
      if [[ "$2" == launch ]]; then
        printf '%s\\n' "onboarding=$(cat "$ONBOARDING_MARKER")" \
          "email=$SIMCTL_CHILD_CMUX_UITEST_STACK_EMAIL" \
          "password=$SIMCTL_CHILD_CMUX_UITEST_STACK_PASSWORD" \
          "attach=$SIMCTL_CHILD_CMUX_DOGFOOD_ATTACH_URL" \
          "test_attach=\${SIMCTL_CHILD_CMUX_UITEST_ATTACH_URL:-}" \
          "replace=$SIMCTL_CHILD_CMUX_DEV_AUTH_REPLACE_SESSION" \
          "device=$SIMCTL_CHILD_CMUX_SIMULATOR_DEVICE_ID"
      fi
    }
    cmux_attach_dogfood_client_id() { echo test-client; }
    cmux_attach_seed_simulator_device_id() { echo retained-device; }
    TARGET=simulator; SIMULATOR_ID=owned-simulator; BUNDLE_ID=dev.cmux.ios.gate
    DETACH=1; RESTORE_PAIRING=1; IROH_RELEASE_GATE_MODE=relayOnly
    CMUX_UITEST_STACK_EMAIL=unexpected-email
    CMUX_UITEST_STACK_PASSWORD=unexpected-password
    ATTACH_URL=unexpected-pairing-url
    SIMCTL_CHILD_CMUX_UITEST_ATTACH_URL=ambient-pairing-url
    eval "$SIMULATOR_BRANCH"
  `], { encoding: "utf8", env: { ...process.env, SIMULATOR_BRANCH: simulatorBranch,
    CMUX_IROH_SOAK_PROFILE: "", CMUX_DEV_AUTH_REPLACE_SESSION: "1" } });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "onboarding=complete\nemail=\npassword=\nattach=\ntest_attach=\nreplace=0\ndevice=retained-device\n");
});

test("cached launch is restricted to a simulator release gate", () => {
  const result = spawnSync("bash", [new URL("../../scripts/mobile-dev-launch.sh", import.meta.url).pathname,
    "--tag", "cacheg", "--restore-pairing", "--device"], { encoding: "utf8" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /restore-pairing requires a simulator release gate/);
});
