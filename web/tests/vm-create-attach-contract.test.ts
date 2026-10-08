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
  test("returns a trusted dial route with IPv4 preferred over IPv6", () => {
    expect(createAttachBlock({ entry: entry(), manifestEntry })).toEqual({
      transport: "cmux-remote",
      route: "ws://10.0.0.42:1337/v1/link",
      session: "cloud",
      trustedCarrier: true,
      daemonBuild: { commit: "daemon-commit", remoteProtocol: null, version: null },
      guestToolsBaked: true,
      readiness: "dial",
    });
  });

  test("uses IPv6 when the provider only allocated IPv6", () => {
    expect(createAttachBlock({ entry: entry({ addressIpv4: null }), manifestEntry })?.route)
      .toBe("ws://[fd00::42]:1337/v1/link");
  });

  test("feature detects old or public rows and falls back to attach endpoint", () => {
    expect(createAttachBlock({ entry: entry({ addressIpv4: null, addressIpv6: null }), manifestEntry })).toBeNull();
    expect(createAttachBlock({ entry: entry(), manifestEntry: null })).toBeNull();
  });
});
