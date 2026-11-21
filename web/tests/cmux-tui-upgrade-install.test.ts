import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { runChild } from "./helpers/run-child";

import { cmuxTuiInstallCommand, cmuxTuiServiceInstallCommand } from "../services/vms/drivers/cmuxTuiDaemon";
import { cmuxTuiUpgradeInstallScript } from "../services/vms/drivers/cmuxTuiUpgradeInstall";
import { GUEST_CMUX_SHIM, GUEST_CMUX_SHIM_PATH } from "../services/vms/guestCli";

const SOURCE = {
  url: "https://files.cmux.com/cmux-tui/test/cmux-tui-x86_64-unknown-linux-musl",
  sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  commit: "0123456789abcdef0123456789abcdef01234567",
  builtAt: null, hookUrl: "https://files.cmux.com/cmux-tui/test/cmux-tui-hook-x86_64-unknown-linux-musl", hookSha256: "1".repeat(64),
} as const;
const ADAPTER = "/var/lib/cmux-tui-upgrade/run-test/cmux-cloud-adapter";

// An in-place upgrade replaces the binary; the guest adapter is an image asset. A machine
// that kept its image's adapter misread the new binary's exits (a `process wait` that
// timed out exits 124, which an old adapter took for a failed `agent --wait`), so the
// upgrade installs this build's adapter with the binary.
describe("in-place cmux-tui upgrade", () => {
  test("installs this build's guest adapter with the binary", () => {
    const script = cmuxTuiUpgradeInstallScript(SOURCE, ADAPTER);
    expect(script.startsWith("set -e\n")).toBe(true);
    const binary = script.indexOf(cmuxTuiInstallCommand(SOURCE));
    const adapter = script.indexOf(`mv -f ${GUEST_CMUX_SHIM_PATH}.upgrade ${GUEST_CMUX_SHIM_PATH}`);
    expect(binary).toBeGreaterThan(0);
    expect(adapter).toBeGreaterThan(binary);
    expect(script).toContain(cmuxTuiServiceInstallCommand());
    expect(script).toContain(`install -m 0755 '${ADAPTER}' ${GUEST_CMUX_SHIM_PATH}.upgrade`);
    // The image bake's guest integration steps, so the adapter and the Cloud CLI it calls match.
    expect(script).toContain("/etc/cmux/browser-opener-version");
    expect(script).toContain("cmux-cloud-");
  });

  test("refuses an uploaded adapter that is not this build's before anything changes", async () => {
    const dir = mkdtempSync(join(tmpdir(), "cmux-upgrade-adapter-"));
    try {
      const file = join(dir, "cmux-cloud-adapter");
      const check = cmuxTuiUpgradeInstallScript(SOURCE, file).split("\n")[1];
      expect(check).toContain("sha256sum -c");
      writeFileSync(file, GUEST_CMUX_SHIM);
      expect((await runChild("sh", ["-c", check])).status).toBe(0);
      writeFileSync(file, `${GUEST_CMUX_SHIM}\n# changed`);
      expect((await runChild("sh", ["-c", check])).status).not.toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("the fleet runner uploads the adapter and runs that install script", () => {
    const runner = readFileSync(new URL("../scripts/upgrade-fleet-cmux-tui.ts", import.meta.url), "utf8");
    expect(runner).toContain("fs.writeTextFile(adapterFile, GUEST_CMUX_SHIM");
    expect(runner).toContain("cmuxTuiUpgradeInstallScript(source, adapterFile)");
  });
});
