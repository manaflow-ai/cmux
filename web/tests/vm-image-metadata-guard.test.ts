import { describe, expect, test } from "bun:test";
import { daemonUnit } from "../scripts/cmux-vm-image/bake";
import {
  METADATA_GUARD_FILE,
  METADATA_GUARD_UNIT,
  METADATA_V4,
  METADATA_V6,
  metadataGuardCheckCommand,
  metadataGuardEnableCommand,
  metadataGuardProblems,
  metadataGuardRules,
  metadataGuardUnit,
} from "../services/vms/images/metadataGuard";

// Bead cx-5hr2: the baked image blocks the metadata service for every
// process but root, and the daemon's browser host is isolated.
describe("cmux VM image metadata guard", () => {
  test("the baked ruleset rejects every metadata address for non-root output and for forwarded traffic", () => {
    const rules = metadataGuardRules();
    for (const address of ["169.254.169.254", "fd00:ec2::254", "100.100.100.200", "168.63.129.16"]) {
      expect(rules).toContain(address);
    }
    expect([...METADATA_V4, ...METADATA_V6]).toHaveLength(4);
    const chain = (name: string) => rules.slice(rules.indexOf(`chain ${name} {`), rules.indexOf("}", rules.indexOf(`chain ${name} {`)));
    const output = chain("output");
    expect(output).toContain("hook output");
    expect(output).toContain("ip daddr @metadata_v4 meta skuid != 0 counter reject");
    expect(output).toContain("ip6 daddr @metadata_v6 meta skuid != 0 counter reject");
    const forward = chain("forward");
    expect(forward).toContain("hook forward");
    expect(forward).toContain("ip daddr @metadata_v4 counter reject");
    expect(forward).not.toContain("skuid");
    // Loading it again replaces the table (the unit and the bake both load it).
    expect(rules.indexOf("delete table inet cmux_metadata_guard")).toBeLessThan(rules.indexOf("chain output"));
  });

  test("the unit loads the ruleset at every boot before the network", () => {
    const unit = metadataGuardUnit();
    expect(unit).toContain(`ExecStart=/usr/sbin/nft -f ${METADATA_GUARD_FILE}\n`);
    expect(unit).toContain("Before=network-pre.target\n");
    expect(unit).toContain("DefaultDependencies=no\n");
    expect(unit).toContain("WantedBy=sysinit.target\n");
    expect(unit).toContain("Type=oneshot\n");
  });

  test("the bake loads it, checks the syntax first, and proves both sides", () => {
    const command = metadataGuardEnableCommand("cmux");
    expect(command.indexOf(`nft -c -f ${METADATA_GUARD_FILE}`)).toBe(0);
    expect(command).toContain(`systemctl enable --quiet ${METADATA_GUARD_UNIT}`);
    expect(command).toContain(metadataGuardCheckCommand("cmux"));
    expect(metadataGuardCheckCommand("cmux")).toContain("runuser -u cmux --");
  });

  test("the check output is read strictly", () => {
    expect(metadataGuardProblems("user_blocked=yes\nroot_reads=yes\n")).toEqual([]);
    expect(metadataGuardProblems("user_blocked=no\nroot_reads=yes\n")).toHaveLength(1);
    expect(metadataGuardProblems("user_blocked=yes\nroot_reads=no\n")[0]).toContain("root no longer reads");
    expect(metadataGuardProblems("")).toHaveLength(2);
  });

  test("the daemon's browser host is isolated in every bake", () => {
    for (const unit of [daemonUnit(), daemonUnit({ CMUX_AGENT_TOOLS_BIN_DIR: "/opt/x" })]) {
      expect(unit).toContain("Environment=CMUX_BROWSER_HOST_EGRESS=isolated\n");
      expect(unit.indexOf("CMUX_BROWSER_HOST_EGRESS")).toBeLessThan(unit.indexOf("ExecStart="));
    }
  });
});
