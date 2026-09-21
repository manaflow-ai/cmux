import { describe, expect, test } from "bun:test";
import { createAttachBlock } from "../services/vms/attachContract";
import { freestyleCmuxRemoteRoute } from "../services/vms/drivers/freestyle";
import {
  GUEST_TOOLS_BAKED_EPOCH,
  TRUSTED_CARRIER_EPOCH,
  imageEpochAtLeast,
  listVmImageKindDefaults,
  listVmImageManifestEntries,
  vmImageEntryEpoch,
  type VmImageManifestEntry,
} from "../services/vms/images/resolver";

// The create response tells the app where to dial before any attach call:
// the machine's private address and the attach block (transport, route,
// carrier trust, daemon build, guest-tools state) are derived from the row
// and the checked-in manifest alone, never from a provider round trip.

function manifestEntry(overrides: Partial<VmImageManifestEntry> = {}): VmImageManifestEntry {
  return {
    provider: "freestyle",
    version: "freestyle-cmux-devbox-test",
    imageId: "sh-0000000000000000000000000000test",
    envVar: "FREESTYLE_SANDBOX_SNAPSHOT",
    kind: "desktop",
    cmuxdRemoteCommit: "none-cmux-tui",
    builtAt: "2026-09-10T00:00:00.000Z",
    builderScriptVersion: "0".repeat(64),
    validationStatus: "passed",
    epoch: "2026-09-10-r2",
    cmuxTuiCommit: "f3b652d8dc0000000000000000000000000000ab",
    cmuxTuiSha256: "1".repeat(64),
    ...overrides,
  };
}

describe("image epochs", () => {
  test("imageEpochAtLeast orders by date, then by numeric revision", () => {
    expect(imageEpochAtLeast("2026-09-10-r2", "2026-09-10-r1")).toBe(true);
    expect(imageEpochAtLeast("2026-09-10-r1", "2026-09-10-r1")).toBe(true);
    expect(imageEpochAtLeast("2026-09-10-r1", "2026-09-10-r2")).toBe(false);
    // r10 is newer than r9: the revision is a number, not a string.
    expect(imageEpochAtLeast("2026-09-10-r10", "2026-09-10-r9")).toBe(true);
    expect(imageEpochAtLeast("2026-09-11-r1", "2026-09-10-r9")).toBe(true);
    expect(imageEpochAtLeast("2026-09-09-r9", "2026-09-10-r1")).toBe(false);
    // An unknown or malformed epoch never satisfies a floor.
    expect(imageEpochAtLeast(undefined, "2026-09-10-r1")).toBe(false);
    expect(imageEpochAtLeast(null, "2026-09-10-r1")).toBe(false);
    expect(imageEpochAtLeast("devbox-2026", "2026-09-10-r1")).toBe(false);
    expect(imageEpochAtLeast("2026-09-10-r1", "not-an-epoch")).toBe(false);
  });

  test("vmImageEntryEpoch reads the field, then the notes prefix every bake writes", () => {
    expect(vmImageEntryEpoch(manifestEntry({ epoch: "2026-09-10-r2" }))).toBe("2026-09-10-r2");
    expect(vmImageEntryEpoch(manifestEntry({ epoch: undefined, notes: "cmux devbox epoch 2026-09-01-r3 Devbox on Freestyle." }))).toBe("2026-09-01-r3");
    expect(vmImageEntryEpoch(manifestEntry({ epoch: undefined, notes: "no epoch here" }))).toBeUndefined();
    expect(vmImageEntryEpoch(manifestEntry({ epoch: undefined, notes: undefined }))).toBeUndefined();
  });

  test("the promoted defaults read as guest-tools baked and older rows do not", () => {
    // The gate flipped with the promotion of the 2026-09-21-r1 bake: every
    // current default carries the guest tools, so the drivers install nothing
    // at create on it, while the older rows keep the install and heal paths.
    expect(GUEST_TOOLS_BAKED_EPOCH).toBe("2026-09-21-r1");
    for (const kind of ["desktop", "base"] as const) {
      const defaults = listVmImageKindDefaults("freestyle", kind);
      expect(defaults.length).toBeGreaterThan(0);
      for (const entry of defaults) {
        expect(imageEpochAtLeast(vmImageEntryEpoch(entry), GUEST_TOOLS_BAKED_EPOCH)).toBe(true);
      }
    }
    const entries = listVmImageManifestEntries();
    expect(entries.some((entry) => !imageEpochAtLeast(vmImageEntryEpoch(entry), GUEST_TOOLS_BAKED_EPOCH))).toBe(true);
  });

  test("every manifest default serves a trusted-carrier daemon", () => {
    expect(TRUSTED_CARRIER_EPOCH).toBe("2026-09-10-r1");
    for (const kind of ["desktop", "base"] as const) {
      const defaults = listVmImageKindDefaults("freestyle", kind);
      expect(defaults.length).toBeGreaterThan(0);
      for (const entry of defaults) {
        expect(imageEpochAtLeast(vmImageEntryEpoch(entry), TRUSTED_CARRIER_EPOCH)).toBe(true);
        expect(entry.cmuxTuiCommit).toMatch(/^[0-9a-f]{40}$/);
      }
    }
  });
});

describe("createAttachBlock", () => {
  test("dials the IPv4 address first and brackets IPv6, exactly like the driver", () => {
    const entry = manifestEntry();
    const dual = createAttachBlock({
      entry: { addressIpv4: "10.16.0.7", addressIpv6: "fd00:4::7", imageEpoch: null },
      manifestEntry: entry,
    });
    expect(dual).toEqual({
      transport: "cmux-remote",
      route: "ws://10.16.0.7:1337/v1/link",
      session: "cloud",
      trustedCarrier: true,
      daemonBuild: { commit: entry.cmuxTuiCommit ?? null, remoteProtocol: null, version: null },
      guestToolsBaked: false,
      readiness: "dial",
    });
    expect(dual?.route).toBe(freestyleCmuxRemoteRoute({ vpcs: [{ ipv4: "10.16.0.7", ipv6: "fd00:4::7" }] }, "vm-test"));

    const v6 = createAttachBlock({
      entry: { addressIpv4: null, addressIpv6: "fd00:4::7", imageEpoch: null },
      manifestEntry: entry,
    });
    expect(v6?.route).toBe("ws://[fd00:4::7]:1337/v1/link");
    expect(v6?.route).toBe(freestyleCmuxRemoteRoute({ vpcs: [{ ipv6: "fd00:4::7" }] }, "vm-test"));
  });

  test("is absent without a private address or a manifest entry", () => {
    expect(createAttachBlock({
      entry: { addressIpv4: null, addressIpv6: null, imageEpoch: "2026-09-10-r2" },
      manifestEntry: manifestEntry(),
    })).toBeNull();
    expect(createAttachBlock({
      entry: { addressIpv4: "10.16.0.7", addressIpv6: null, imageEpoch: "2026-09-10-r2" },
      manifestEntry: null,
    })).toBeNull();
  });

  test("carrier trust and guest-tools state follow the epoch; the row's stamped epoch wins", () => {
    const old = createAttachBlock({
      entry: { addressIpv4: "10.16.0.7", addressIpv6: null, imageEpoch: null },
      manifestEntry: manifestEntry({ epoch: undefined, notes: "cmux devbox epoch 2026-09-01-r3", cmuxTuiCommit: undefined }),
    });
    expect(old).toMatchObject({ trustedCarrier: false, guestToolsBaked: false, daemonBuild: { commit: null } });

    const baked = createAttachBlock({
      entry: { addressIpv4: "10.16.0.7", addressIpv6: null, imageEpoch: GUEST_TOOLS_BAKED_EPOCH },
      // The manifest lookup says older, but the row was stamped at create.
      manifestEntry: manifestEntry({ epoch: "2026-09-10-r2" }),
    });
    expect(baked).toMatchObject({ trustedCarrier: true, guestToolsBaked: true, readiness: "dial" });
  });
});
