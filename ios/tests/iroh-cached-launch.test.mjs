import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const launcherPath = new URL("../../scripts/mobile-dev-launch.sh", import.meta.url).pathname;
const launcher = readFileSync(launcherPath, "utf8");
const start = launcher.indexOf('\nif [[ "$TARGET" == "simulator" ]]') + 1;
const simulatorBranch = launcher.slice(start, launcher.indexOf("\nelse\n", start)) + "\nfi\n";

test("simulator launch signs in but cannot inject a pairing URL", () => {
  const result = spawnSync("bash", ["-c", `
    set -euo pipefail
    xcrun() {
      if [[ "$2" == launch ]]; then
        printf '%s\\n' "argv=$*" \
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
    CMUX_UITEST_STACK_EMAIL=agent@example.com
    CMUX_UITEST_STACK_PASSWORD=agent-password
    ATTACH_URL=unexpected-pairing-url
    SIMCTL_CHILD_CMUX_UITEST_ATTACH_URL=ambient-pairing-url
    SIMCTL_CHILD_CMUX_DOGFOOD_ATTACH_URL=ambient-dogfood-url
    eval "$SIMULATOR_BRANCH"
  `], { encoding: "utf8", env: { ...process.env, SIMULATOR_BRANCH: simulatorBranch,
    CMUX_DEV_AUTH_REPLACE_SESSION: "1" } });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, [
    "argv=simctl launch owned-simulator dev.cmux.ios.gate",
    "email=agent@example.com",
    "password=agent-password",
    "attach=",
    "test_attach=",
    "replace=1",
    "device=retained-device",
    "",
  ].join("\n"));
});

for (const args of [
  ["--restore-pairing"],
  ["--restore-pairing", "--device"],
  ["--iroh-release-gate", "relayOnly", "--simulator", "iPhone 17"],
]) {
  test(`${args.join(" ")} is refused before credentials or a target`, () => {
    const home = mkdtempSync(path.join(tmpdir(), "cmux-refused-launch-"));
    try {
      const result = spawnSync("bash", [launcherPath, "--tag", "cacheg", ...args], {
        encoding: "utf8",
        // An empty HOME has no credential file and no xcrun log, so any work
        // past the refusal would fail with a different message.
        env: { ...process.env, HOME: home, PATH: "/usr/bin:/bin" },
      });
      assert.equal(result.status, 2, result.stderr);
      assert.match(result.stderr, new RegExp(`${args[0]} has no target`));
      assert.match(result.stderr, /no longer runs the iroh phone listener \(mobile\.attach_ticket\.create \/ mobile\.rpc\.ready\)/);
      assert.equal(result.stdout, "");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
}
