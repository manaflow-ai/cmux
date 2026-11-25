import { describe, expect, test } from "bun:test";
import { createAttachBlock, type VmAttachEntry } from "../services/vms/attachContract";
import type { VmImageManifestEntry } from "../services/vms/images/resolver";

const manifestEntry: VmImageManifestEntry = {
  provider: "freestyle",
  version: "snapshot-v2",
  imageId: "devbox-md",
  envVar: "CMUX_VM_IMAGE",
  kind: "desktop",
  defaultForKind: true,
  size: { name: "md", cpu: 4, memoryMb: 8192, storageMb: 32768 },
  cmuxdRemoteCommit: "daemon-commit",
  builtAt: "2026-10-01T00:00:00Z",
  builderScriptVersion: "test",
  validationStatus: "passed",
};

function entry(overrides: Partial<VmAttachEntry> = {}): VmAttachEntry {
  return {
    addressIpv4: "10.0.0.42",
    addressIpv6: "fd00::42",
    cmuxTuiContract: "snapshot-v2",
    providerVmId: "vm-test",
    ...overrides,
  };
}

describe("create attach contract", () => {
  test("a client-grant image always requires the attach endpoint, independent of the backend flag", () => {
    const previous = process.env.CMUX_CLOUD_REQUIRE_CLIENT_GRANT;
    delete process.env.CMUX_CLOUD_REQUIRE_CLIENT_GRANT;
    try {
      expect(createAttachBlock({
        entry: entry(),
        manifestEntry: { ...manifestEntry, cmuxRemoteAuth: "client-grant" },
      })).toBeNull();
      expect(createAttachBlock({
        entry: entry(),
        manifestEntry: { ...manifestEntry, cmuxRemoteAuth: "trusted-carrier" },
      })?.trustedCarrier).toBe(true);
    } finally {
      if (previous === undefined) delete process.env.CMUX_CLOUD_REQUIRE_CLIENT_GRANT;
      else process.env.CMUX_CLOUD_REQUIRE_CLIENT_GRANT = previous;
    }
  });

  test("feature detects old or public rows and falls back to attach endpoint", () => {
    expect(createAttachBlock({ entry: entry({ addressIpv4: null, addressIpv6: null }), manifestEntry })).toBeNull();
    expect(createAttachBlock({ entry: entry(), manifestEntry: null })).toBeNull();
  });
});
