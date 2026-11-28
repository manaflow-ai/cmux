import { describe, expect, test } from "bun:test";
import { devboxDaemonUnit } from "../scripts/devbox-image-common";
import { metadataGuardRules, metadataGuardUnit, METADATA_GUARD_FILE } from "../services/vms/images/metadataGuard";

// cx-5hr2 ported to the devbox image (the image the manifest serves): the
// daemon's browser host is isolated and the metadata guard is shared.
describe("devbox image metadata guard", () => {
  test("the devbox daemon unit isolates the browser host and keeps its contract", () => {
    const unit = devboxDaemonUnit();
    expect(unit).toContain("Environment=CMUX_BROWSER_HOST_EGRESS=isolated\n");
    expect(unit.indexOf("CMUX_BROWSER_HOST_EGRESS")).toBeLessThan(unit.indexOf("ExecStart="));
    // The old supervisor's argv and environment stay (docs/cloud-guest-upgrades.md).
    expect(unit).toContain("Environment=CMUX_TUI_REMOTE_WS_BIND=[::]:1337\n");
    expect(unit).toContain("Environment=CMUX_TUI_HOST_SCOPES=systemd\n");
    expect(unit).toContain("ExecStart=/usr/local/bin/cmux-devbox-boot\n");
    expect(unit).toContain("User=root\n");
  });

  test("the shared guard blocks every metadata address for non-root and loads at boot", () => {
    const rules = metadataGuardRules();
    for (const address of ["169.254.169.254", "fd00:ec2::254", "100.100.100.200", "168.63.129.16"]) {
      expect(rules).toContain(address);
    }
    expect(rules).toContain("meta skuid != 0 counter reject");
    expect(metadataGuardUnit()).toContain(`ExecStart=/usr/sbin/nft -f ${METADATA_GUARD_FILE}\n`);
  });
});
