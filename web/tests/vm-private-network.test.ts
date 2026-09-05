import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  enrollVmTunnel,
  isWireGuardPublicKey,
  networkSlugForUser,
  readVmTunnel,
  resolveOwnerNetwork,
  revokeVmAccessGrant,
  revokeVmTunnel,
  tunnelSlugForDevice,
} from "../services/vms/privateNetwork";
import {
  VmAccessGrantMutationBusyError,
  VmAccessGrantRevokedError,
  VmPrivateNetworkUnavailableError,
  VmProviderOperationError,
  VmTunnelNotFoundError,
} from "../services/vms/errors";
import type {
  CreateProviderTunnelOptions,
  ProviderNetwork,
  ProviderTunnel,
} from "../services/vms/drivers";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import {
  VmRepository,
  type CloudVmAccessGrantRow,
  type CloudVmNetworkRow,
  type CloudVmTunnelRow,
  type VmRepositoryShape,
} from "../services/vms/repository";

// A valid base64 32-byte key (all zero bytes) for shape-level tests.
const CLIENT_KEY = Buffer.alloc(32, 1).toString("base64");
const OTHER_KEY = Buffer.alloc(32, 2).toString("base64");

const NETWORK: ProviderNetwork = {
  id: "vpc-test-1",
  slug: "cmux-net-abc",
  cidr: "10.40.0.0/24",
  cidrV6: "fd00:40::/64",
};

function providerTunnel(overrides: Partial<ProviderTunnel> = {}): ProviderTunnel {
  return {
    id: "tun-test-1",
    clientConfig: "[Interface]\nPrivateKey =\n[Peer]\n",
    clientPublicKey: CLIENT_KEY,
    serverPublicKey: "server-key",
    endpointHost: "vpn.freestyle.sh",
    endpointPort: 51820,
    routes: ["10.0.0.0/8", "fd00::/8"],
    addressV4: "10.40.0.2",
    addressV6: "fd00:40::2",
    ...overrides,
  };
}

function networkRow(overrides: Partial<CloudVmNetworkRow> = {}): CloudVmNetworkRow {
  return {
    id: "00000000-0000-4000-8000-0000000000aa",
    userId: "user-1",
    provider: "freestyle",
    providerNetworkId: NETWORK.id,
    slug: NETWORK.slug,
    cidr: NETWORK.cidr,
    cidrV6: NETWORK.cidrV6,
    createdAt: new Date(),
    updatedAt: new Date(),
    ...overrides,
  };
}

function tunnelRow(overrides: Partial<CloudVmTunnelRow> = {}): CloudVmTunnelRow {
  return {
    id: "00000000-0000-4000-8000-0000000000bb",
    userId: "user-1",
    networkId: "00000000-0000-4000-8000-0000000000aa",
    accessGrantId: "00000000-0000-4000-8000-0000000000c1",
    provider: "freestyle",
    providerTunnelId: "tun-test-1",
    deviceFingerprint: "device-1",
    tunnelPurpose: "browser",
    deviceName: "Test Mac",
    clientPublicKey: CLIENT_KEY,
    addressV4: "10.40.0.2",
    addressV6: "fd00:40::2",
    createdAt: new Date(),
    updatedAt: new Date(),
    lastConfigIssuedAt: new Date(),
    revokedAt: null,
    ...overrides,
  };
}

function accessGrantRow(overrides: Partial<CloudVmAccessGrantRow> = {}): CloudVmAccessGrantRow {
  return {
    id: "00000000-0000-4000-8000-0000000000c1",
    userId: "user-1",
    deviceId: "mac-stable-1",
    reportedName: "Test Mac",
    displayName: null,
    modelIdentifier: "Mac15,6",
    osVersion: "26.0",
    architecture: "arm64",
    cmuxVersion: "0.65.0",
    cmuxBuild: "103",
    cmuxChannel: "nightly",
    createdAt: new Date(),
    updatedAt: new Date(),
    lastControlPlaneAt: new Date(),
    mutationLeaseId: null,
    mutationLeaseExpiresAt: null,
    revokedAt: null,
    ...overrides,
  };
}

type GatewayCalls = {
  ensureNetwork: number;
  getNetwork: number;
  createTunnel: CreateProviderTunnelOptions[];
  rotateTunnelKey: string[];
  deleteTunnel: string[];
};

function testGateway(options: {
  calls?: GatewayCalls;
  getTunnel?: ProviderTunnel | null;
  network?: ProviderNetwork;
  supports?: boolean;
} = {}): VmProviderGatewayShape {
  const calls = options.calls;
  const network = options.network ?? NETWORK;
  return {
    create: () => Effect.die("unused"),
    destroy: () => Effect.void,
    exec: () => Effect.die("unused"),
    openAttach: () => Effect.die("unused"),
    openSSH: () => Effect.die("unused"),
    revokeSSHIdentity: () => Effect.void,
    supportsPrivateNetworking: () => options.supports ?? true,
    ensureNetwork: () =>
      Effect.sync(() => {
        if (calls) calls.ensureNetwork += 1;
        return network;
      }),
    getNetwork: (_provider, networkId) =>
      Effect.sync(() => {
        if (calls) calls.getNetwork += 1;
        return network.id === networkId ? network : null;
      }),
    deleteNetwork: () => Effect.void,
    createTunnel: (_provider, createOptions) =>
      Effect.sync(() => {
        calls?.createTunnel.push(createOptions);
        return {
          tunnel: providerTunnel({ clientPublicKey: createOptions.clientPublicKey }),
          created: true,
          rotated: false,
        };
      }),
    getTunnel: () => Effect.succeed(options.getTunnel === undefined ? providerTunnel() : options.getTunnel),
    rotateTunnelKey: (_provider, tunnelId, clientPublicKey) =>
      Effect.sync(() => {
        calls?.rotateTunnelKey.push(clientPublicKey);
        return providerTunnel({ clientPublicKey });
      }),
    deleteTunnel: (_provider, tunnelId) =>
      Effect.sync(() => {
        calls?.deleteTunnel.push(tunnelId);
      }),
  };
}

type RepoCalls = {
  upserts: number;
  inserts: number;
  updates: number;
  lockAcquires: number;
  lockReleases: number;
  lockRenews: number;
  revoked: string[];
};

function testRepo(options: {
  calls?: RepoCalls;
  network?: CloudVmNetworkRow | null;
  tunnel?: CloudVmTunnelRow | null;
  lockAcquired?: boolean;
  lockRenewed?: boolean;
} = {}): VmRepositoryShape {
  const calls = options.calls;
  const base: Partial<VmRepositoryShape> = {
    findNetwork: () => Effect.succeed(options.network ?? null),
    upsertNetwork: (input) =>
      Effect.sync(() => {
        if (calls) calls.upserts += 1;
        return networkRow({
          userId: input.userId,
          providerNetworkId: input.providerNetworkId,
        });
      }),
    deleteNetwork: () => Effect.void,
    findAccessGrant: () => Effect.succeed(accessGrantRow()),
    findBlockingRevokedAccessGrant: () => Effect.succeed(null),
    listUserAccessGrants: () => Effect.succeed([accessGrantRow()]),
    upsertAccessGrant: () => Effect.succeed(accessGrantRow()),
    upsertAccessGrantSession: () => Effect.void,
    listAccessGrantSessionIds: () => Effect.succeed(["session-1"]),
    renameAccessGrant: () => Effect.succeed(accessGrantRow()),
    listAccessGrantTunnels: () => Effect.succeed(options.tunnel ? [options.tunnel] : []),
    claimAccessGrantMutation: () => Effect.succeed(true),
    releaseAccessGrantMutation: () => Effect.void,
    revokeAccessGrant: () => Effect.succeed(true),
    findTunnel: () => Effect.succeed(options.tunnel ?? null),
    listUserTunnels: () => Effect.succeed(options.tunnel ? [options.tunnel] : []),
    insertTunnel: (input) =>
      Effect.sync(() => {
        if (calls) calls.inserts += 1;
        return tunnelRow({
          providerTunnelId: input.providerTunnelId,
          accessGrantId: input.accessGrantId,
          deviceFingerprint: input.deviceFingerprint,
          tunnelPurpose: input.tunnelPurpose,
          clientPublicKey: input.clientPublicKey,
        });
      }),
    updateTunnel: (input) =>
      Effect.sync(() => {
        if (calls) calls.updates += 1;
        return tunnelRow({
          ...(input.clientPublicKey ? { clientPublicKey: input.clientPublicKey } : {}),
        });
      }),
    revokeTunnel: (id) =>
      Effect.sync(() => {
        calls?.revoked.push(id);
        return true;
      }),
    acquireTunnelEnrollmentLock: () => Effect.sync(() => {
        if (calls) calls.lockAcquires += 1;
        return options.lockAcquired ?? true;
      }),
    releaseTunnelEnrollmentLock: () =>
      Effect.sync(() => {
        if (calls) calls.lockReleases += 1;
      }),
    renewTunnelEnrollmentLock: () =>
      Effect.sync(() => {
        if (calls) calls.lockRenews += 1;
        return options.lockRenewed ?? true;
      }),
  };
  return base as VmRepositoryShape;
}

function layerFor(repo: VmRepositoryShape, gateway: VmProviderGatewayShape) {
  return Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, gateway),
  );
}

function newGatewayCalls(): GatewayCalls {
  return { ensureNetwork: 0, getNetwork: 0, createTunnel: [], rotateTunnelKey: [], deleteTunnel: [] };
}

function newRepoCalls(): RepoCalls {
  return {
    upserts: 0,
    inserts: 0,
    updates: 0,
    lockAcquires: 0,
    lockReleases: 0,
    lockRenews: 0,
    revoked: [],
  };
}

describe("WireGuard public key validation", () => {
  test("accepts a base64 32-byte key and rejects everything else", () => {
    expect(isWireGuardPublicKey(CLIENT_KEY)).toBe(true);
    // RFC 4648 Base64 allows digits in the final sextet. This is a real
    // CryptoKit-generated public key from the Nightly dogfood Mac.
    expect(isWireGuardPublicKey("/LP04D7GGKWfqnFrgW+y1f0UvH2OyvSccKvHGQnkR08=")).toBe(true);
    expect(isWireGuardPublicKey(`  ${CLIENT_KEY}  `)).toBe(true);
    expect(isWireGuardPublicKey("")).toBe(false);
    expect(isWireGuardPublicKey("not-a-key")).toBe(false);
    // 31 bytes: right shape class, wrong length.
    expect(isWireGuardPublicKey(Buffer.alloc(31, 1).toString("base64"))).toBe(false);
    // A private key would be the same shape; the regex can't tell, but a
    // URL/path can never pass.
    expect(isWireGuardPublicKey("https://example.com/AAAA")).toBe(false);
    expect(isWireGuardPublicKey(42)).toBe(false);
  });
});

describe("account slugs", () => {
  test("are stable, hashed, and do not embed the raw user id", () => {
    const slug = networkSlugForUser("user-abcdef");
    expect(slug).toBe(networkSlugForUser("user-abcdef"));
    expect(slug.startsWith("cmux-net-")).toBe(true);
    expect(slug).not.toContain("user-abcdef");
    const device = tunnelSlugForDevice("user-abcdef", "device-1");
    expect(device).toBe(tunnelSlugForDevice("user-abcdef", "device-1"));
    expect(device).not.toBe(tunnelSlugForDevice("user-abcdef", "device-2"));
    expect(device).not.toContain("user-abcdef");
  });
});

describe("resolveOwnerNetwork", () => {
  test("provisions on first use and records the provider network", async () => {
    const gatewayCalls = newGatewayCalls();
    const repoCalls = newRepoCalls();
    const network = await Effect.runPromise(
      resolveOwnerNetwork({ userId: "user-1", provider: "freestyle" }).pipe(
        Effect.provide(layerFor(testRepo({ calls: repoCalls }), testGateway({ calls: gatewayCalls }))),
      ),
    );
    expect(network?.providerNetworkId).toBe(NETWORK.id);
    expect(gatewayCalls.ensureNetwork).toBe(1);
    expect(repoCalls.upserts).toBe(1);
  });

  test("reuses the recorded network without a provider read", async () => {
    const gatewayCalls = newGatewayCalls();
    const network = await Effect.runPromise(
      resolveOwnerNetwork({ userId: "user-1", provider: "freestyle" }).pipe(
        Effect.provide(layerFor(
          testRepo({ network: networkRow() }),
          testGateway({ calls: gatewayCalls }),
        )),
      ),
    );
    expect(network?.providerNetworkId).toBe(NETWORK.id);
    expect(gatewayCalls.ensureNetwork).toBe(0);
  });

  test("keeps the recorded network id as the control-plane authority", async () => {
    const gatewayCalls = newGatewayCalls();
    const repoCalls = newRepoCalls();
    const recreated: ProviderNetwork = {
      ...NETWORK,
      id: "vpc-recreated-2",
      slug: networkSlugForUser("user-1"),
    };
    const network = await Effect.runPromise(
      resolveOwnerNetwork({ userId: "user-1", provider: "freestyle" }).pipe(
        Effect.provide(layerFor(
          testRepo({ calls: repoCalls, network: networkRow({ providerNetworkId: "vpc-deleted-1" }) }),
          testGateway({ calls: gatewayCalls, network: recreated }),
        )),
      ),
    );
    expect(network?.providerNetworkId).toBe("vpc-deleted-1");
    expect(gatewayCalls.ensureNetwork).toBe(0);
    expect(repoCalls.upserts).toBe(0);
  });

  test("fails closed when the provider has no private networking", async () => {
    const error = await Effect.runPromise(
      resolveOwnerNetwork({ userId: "user-1", provider: "freestyle" }).pipe(
        Effect.provide(layerFor(testRepo(), testGateway({ supports: false }))),
        Effect.flip,
      ),
    );
    expect(error).toBeInstanceOf(VmPrivateNetworkUnavailableError);
  });

  test("fails closed when the private-network kill switch is off", async () => {
    const prior = process.env.CMUX_VM_PRIVATE_NETWORK_ENABLED;
    process.env.CMUX_VM_PRIVATE_NETWORK_ENABLED = "0";
    try {
      const error = await Effect.runPromise(
        resolveOwnerNetwork({ userId: "user-1", provider: "freestyle" }).pipe(
          Effect.provide(layerFor(testRepo(), testGateway())),
          Effect.flip,
        ),
      );
      expect(error).toBeInstanceOf(VmPrivateNetworkUnavailableError);
    } finally {
      if (prior === undefined) delete process.env.CMUX_VM_PRIVATE_NETWORK_ENABLED;
      else process.env.CMUX_VM_PRIVATE_NETWORK_ENABLED = prior;
    }
  });
});

describe("enrollVmTunnel", () => {
  test("fails closed when another provider mutation owns the Mac", async () => {
    const gatewayCalls = newGatewayCalls();
    const repo = {
      ...testRepo({ network: networkRow() }),
      claimAccessGrantMutation: () => Effect.succeed(false),
    } as VmRepositoryShape;

    const error = await Effect.runPromise(
      enrollVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceId: "mac-stable-1",
        deviceFingerprint: "device-1",
        tunnelPurpose: "terminal",
        clientPublicKey: CLIENT_KEY,
      }).pipe(
        Effect.provide(layerFor(repo, testGateway({ calls: gatewayCalls }))),
        Effect.flip,
      ),
    );

    expect(error).toBeInstanceOf(VmAccessGrantMutationBusyError);
    expect(gatewayCalls.createTunnel).toHaveLength(0);
  });

  test("releases the Mac mutation lease when provider enrollment fails", async () => {
    const events: string[] = [];
    const repo = {
      ...testRepo({ network: networkRow() }),
      claimAccessGrantMutation: () => Effect.sync(() => {
        events.push("claim");
        return true;
      }),
      releaseAccessGrantMutation: () => Effect.sync(() => {
        events.push("release");
      }),
    } as VmRepositoryShape;
    const gateway = {
      ...testGateway(),
      createTunnel: () => Effect.sync(() => {
        events.push("provider-create");
        throw new VmProviderOperationError({
          provider: "freestyle",
          operation: "createTunnel",
          cause: new Error("provider unavailable"),
        });
      }),
    } as VmProviderGatewayShape;

    await expect(Effect.runPromise(
      enrollVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceId: "mac-stable-1",
        deviceFingerprint: "device-1",
        tunnelPurpose: "terminal",
        clientPublicKey: CLIENT_KEY,
      }).pipe(Effect.provide(layerFor(repo, gateway))),
    )).rejects.toBeDefined();

    expect(events).toEqual(["claim", "provider-create", "release"]);
  });

  test("holds the physical Mac mutation lease through provider enrollment", async () => {
    const events: string[] = [];
    const repo = {
      ...testRepo(),
      claimAccessGrantMutation: () => Effect.sync(() => {
        events.push("claim");
        return true;
      }),
      releaseAccessGrantMutation: () => Effect.sync(() => {
        events.push("release");
      }),
    } as VmRepositoryShape;
    const gateway = {
      ...testGateway(),
      createTunnel: (_provider: string, options: CreateProviderTunnelOptions) =>
        Effect.sync(() => {
          events.push("provider-create");
          return { tunnel: providerTunnel({ clientPublicKey: options.clientPublicKey }), created: true, rotated: false };
        }),
    } as VmProviderGatewayShape;

    await Effect.runPromise(
      enrollVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceId: "mac-stable-1",
        deviceFingerprint: "device-1",
        tunnelPurpose: "terminal",
        stackSessionId: "session-1",
        sessionIssuedAt: new Date("2026-09-03T12:00:00Z"),
        clientPublicKey: CLIENT_KEY,
      }).pipe(Effect.provide(layerFor(repo, gateway))),
    );

    expect(events).toEqual(["claim", "provider-create", "release"]);
  });

  test("first enrollment creates a provider tunnel keyed to the device", async () => {
    const gatewayCalls = newGatewayCalls();
    const repoCalls = newRepoCalls();
    const issuedAt = new Date("2026-09-03T12:00:00Z");
    const recordedSessions: Array<{ stackSessionId: string; sessionIssuedAt: Date }> = [];
    const repo = {
      ...testRepo({ calls: repoCalls }),
      upsertAccessGrantSession: (input: { stackSessionId: string; sessionIssuedAt: Date }) =>
        Effect.sync(() => {
          recordedSessions.push({
            stackSessionId: input.stackSessionId,
            sessionIssuedAt: input.sessionIssuedAt,
          });
        }),
    } as VmRepositoryShape;
    const tunnel = await Effect.runPromise(
      enrollVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceId: "mac-stable-1",
        deviceFingerprint: "device-1",
        tunnelPurpose: "browser",
        deviceName: "Test Mac",
        stackSessionId: "session-stable",
        sessionIssuedAt: issuedAt,
        clientPublicKey: CLIENT_KEY,
      }).pipe(
        Effect.provide(layerFor(repo, testGateway({ calls: gatewayCalls }))),
      ),
    );
    expect(tunnel.created).toBe(true);
    expect(tunnel.rotated).toBe(false);
    expect(tunnel.clientPublicKey).toBe(CLIENT_KEY);
    expect(gatewayCalls.createTunnel).toHaveLength(1);
    expect(gatewayCalls.createTunnel[0]?.networkId).toBe(NETWORK.id);
    expect(repoCalls.inserts).toBe(1);
    expect(recordedSessions).toEqual([{
      stackSessionId: "session-stable",
      sessionIssuedAt: issuedAt,
    }]);
  });

  test("a login issued before physical Mac revoke cannot create its first tunnel later", async () => {
    const gatewayCalls = newGatewayCalls();
    const repo = {
      ...testRepo(),
      findBlockingRevokedAccessGrant: () => Effect.succeed(accessGrantRow({
        revokedAt: new Date("2026-09-03T13:00:00Z"),
      })),
    } as VmRepositoryShape;
    const error = await Effect.runPromise(
      enrollVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceId: "mac-stable-1",
        deviceFingerprint: "nightly-first-use",
        tunnelPurpose: "terminal",
        stackSessionId: "session-nightly-never-enrolled",
        sessionIssuedAt: new Date("2026-09-03T12:00:00Z"),
        clientPublicKey: CLIENT_KEY,
      }).pipe(
        Effect.provide(layerFor(repo, testGateway({ calls: gatewayCalls }))),
        Effect.flip,
      ),
    );
    expect(error).toBeInstanceOf(VmAccessGrantRevokedError);
    expect(gatewayCalls.createTunnel).toHaveLength(0);
  });

  test("re-enrolling with the same key is idempotent: no create, no rotate", async () => {
    const gatewayCalls = newGatewayCalls();
    const repoCalls = newRepoCalls();
    const tunnel = await Effect.runPromise(
      enrollVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceId: "mac-stable-1",
        deviceFingerprint: "device-1",
        tunnelPurpose: "browser",
        clientPublicKey: CLIENT_KEY,
      }).pipe(
        Effect.provide(layerFor(
          testRepo({ calls: repoCalls, network: networkRow(), tunnel: tunnelRow() }),
          testGateway({ calls: gatewayCalls }),
        )),
      ),
    );
    expect(tunnel.created).toBe(false);
    expect(tunnel.rotated).toBe(false);
    expect(gatewayCalls.createTunnel).toHaveLength(0);
    expect(gatewayCalls.rotateTunnelKey).toHaveLength(0);
    expect(repoCalls.updates).toBe(1); // config re-issue timestamp
  });

  test("a different key rotates the existing tunnel in place, keeping its address", async () => {
    const gatewayCalls = newGatewayCalls();
    const tunnel = await Effect.runPromise(
      enrollVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceId: "mac-stable-1",
        deviceFingerprint: "device-1",
        tunnelPurpose: "browser",
        clientPublicKey: OTHER_KEY,
      }).pipe(
        Effect.provide(layerFor(
          testRepo({ network: networkRow(), tunnel: tunnelRow() }),
          testGateway({ calls: gatewayCalls }),
        )),
      ),
    );
    expect(tunnel.rotated).toBe(true);
    expect(tunnel.created).toBe(false);
    expect(gatewayCalls.rotateTunnelKey).toEqual([OTHER_KEY]);
    expect(gatewayCalls.createTunnel).toHaveLength(0);
  });

  test("a control-plane row whose provider tunnel is gone re-enrolls fresh", async () => {
    const gatewayCalls = newGatewayCalls();
    const repoCalls = newRepoCalls();
    const tunnel = await Effect.runPromise(
      enrollVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceId: "mac-stable-1",
        deviceFingerprint: "device-1",
        tunnelPurpose: "browser",
        clientPublicKey: CLIENT_KEY,
      }).pipe(
        Effect.provide(layerFor(
          testRepo({ calls: repoCalls, network: networkRow(), tunnel: tunnelRow() }),
          testGateway({ calls: gatewayCalls, getTunnel: null }),
        )),
      ),
    );
    expect(tunnel.created).toBe(true);
    expect(repoCalls.revoked).toHaveLength(1);
    expect(gatewayCalls.createTunnel).toHaveLength(1);
  });

  test("fails typed when the provider has no private networking", async () => {
    const error = await Effect.runPromise(
      enrollVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceId: "mac-stable-1",
        deviceFingerprint: "device-1",
        tunnelPurpose: "browser",
        clientPublicKey: CLIENT_KEY,
      }).pipe(
        Effect.provide(layerFor(testRepo(), testGateway({ supports: false }))),
        Effect.flip,
      ),
    );
    expect(error).toBeInstanceOf(VmPrivateNetworkUnavailableError);
  });
});

describe("readVmTunnel / revokeVmTunnel", () => {
  test("fails closed when rollback leaves only a stale network row", async () => {
    const prior = process.env.CMUX_VM_PRIVATE_NETWORK_ENABLED;
    process.env.CMUX_VM_PRIVATE_NETWORK_ENABLED = "0";
    try {
      const error = await Effect.runPromise(
        readVmTunnel({
          userId: "user-1",
          provider: "freestyle",
          deviceFingerprint: "device-1",
          tunnelPurpose: "terminal",
        }).pipe(
          Effect.provide(layerFor(
            testRepo({ network: networkRow(), tunnel: tunnelRow() }),
            testGateway({ network: { ...NETWORK, id: "vpc-recreated" } }),
          )),
          Effect.flip,
        ),
      );
      expect(error).toBeInstanceOf(VmPrivateNetworkUnavailableError);
    } finally {
      if (prior === undefined) delete process.env.CMUX_VM_PRIVATE_NETWORK_ENABLED;
      else process.env.CMUX_VM_PRIVATE_NETWORK_ENABLED = prior;
    }
  });

  test("read fails typed for a device that never enrolled", async () => {
    const gatewayCalls = newGatewayCalls();
    const error = await Effect.runPromise(
      readVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceFingerprint: "device-unknown",
        tunnelPurpose: "browser",
      }).pipe(
        Effect.provide(layerFor(testRepo({ network: networkRow() }), testGateway({ calls: gatewayCalls }))),
        Effect.flip,
      ),
    );
    expect(error).toBeInstanceOf(VmTunnelNotFoundError);
    expect(gatewayCalls.getNetwork).toBe(0);
    expect(gatewayCalls.ensureNetwork).toBe(0);
  });

  test("reports a missing device as not found without a mutation lock", async () => {
    const error = await Effect.runPromise(
      readVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceFingerprint: "device-unknown",
        tunnelPurpose: "terminal",
      }).pipe(
        Effect.provide(layerFor(
          testRepo(),
          testGateway(),
        )),
        Effect.flip,
      ),
    );
    expect(error).toBeInstanceOf(VmTunnelNotFoundError);
  });

  test("revoke deletes the provider tunnel before marking the row revoked", async () => {
    const gatewayCalls = newGatewayCalls();
    const repoCalls = newRepoCalls();
    const result = await Effect.runPromise(
      revokeVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceFingerprint: "device-1",
        tunnelPurpose: "browser",
      }).pipe(
        Effect.provide(layerFor(
          testRepo({ calls: repoCalls, tunnel: tunnelRow() }),
          testGateway({ calls: gatewayCalls }),
        )),
      ),
    );
    expect(result.revoked).toBe(true);
    expect(gatewayCalls.deleteTunnel).toEqual(["tun-test-1"]);
    expect(repoCalls.revoked).toHaveLength(1);
    expect(repoCalls.lockAcquires).toBe(0);
    expect(repoCalls.lockReleases).toBe(0);
    expect(repoCalls.lockRenews).toBe(0);
  });

  test("revoking a device that never enrolled is a no-op, not an error", async () => {
    const result = await Effect.runPromise(
      revokeVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceFingerprint: "device-unknown",
        tunnelPurpose: "browser",
      }).pipe(Effect.provide(layerFor(testRepo(), testGateway()))),
    );
    expect(result.revoked).toBe(false);
  });

  test("serializes a missing-device read and releases the lease", async () => {
    const repoCalls = newRepoCalls();
    const error = await Effect.runPromise(
      readVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceFingerprint: "device-unknown",
        tunnelPurpose: "terminal",
      }).pipe(
        Effect.provide(layerFor(
          testRepo({ calls: repoCalls, network: networkRow() }),
          testGateway(),
        )),
        Effect.flip,
      ),
    );
    expect(error).toBeInstanceOf(VmTunnelNotFoundError);
    expect(repoCalls.lockAcquires).toBe(0);
    expect(repoCalls.lockReleases).toBe(0);
  });
});

describe("Cloud VM access grant revocation", () => {
  test("holds the physical Mac mutation lease through provider deletion", async () => {
    const events: string[] = [];
    const row = tunnelRow();
    const repo = {
      ...testRepo({ tunnel: row }),
      claimAccessGrantMutation: () => Effect.sync(() => {
        events.push("claim");
        return true;
      }),
      releaseAccessGrantMutation: () => Effect.sync(() => {
        events.push("release");
      }),
      revokeTunnel: () => Effect.sync(() => {
        events.push("row-revoke");
        return true;
      }),
      revokeAccessGrant: () => Effect.sync(() => {
        events.push("grant-revoke");
        return true;
      }),
    } as VmRepositoryShape;
    const gateway = {
      ...testGateway(),
      deleteTunnel: () => Effect.sync(() => {
        events.push("provider-delete");
      }),
    } as VmProviderGatewayShape;

    await Effect.runPromise(
      revokeVmAccessGrant({
        userId: "user-1",
        accessGrantId: accessGrantRow().id,
      }).pipe(Effect.provide(layerFor(repo, gateway))),
    );

    expect(events).toEqual([
      "claim",
      "provider-delete",
      "row-revoke",
      "grant-revoke",
      "release",
    ]);
  });

  test("revokes every tunnel role for one Mac", async () => {
    const deleted: string[] = [];
    const revoked: string[] = [];
    const rows = [
      tunnelRow({
        id: "00000000-0000-4000-8000-0000000000b1",
        providerTunnelId: "tun-userspace",
        tunnelPurpose: "terminal",
      }),
      tunnelRow({
        id: "00000000-0000-4000-8000-0000000000b2",
        providerTunnelId: "tun-vpn",
        tunnelPurpose: "browser",
      }),
    ];
    const repo = {
      ...testRepo(),
      findAccessGrant: () => Effect.succeed({
        id: "00000000-0000-4000-8000-0000000000c1",
        userId: "user-1",
        deviceId: "mac-stable-1",
        reportedName: "Lawrence’s MacBook Pro",
        displayName: null,
        modelIdentifier: "Mac15,6",
        osVersion: "26.0",
        architecture: "arm64",
        cmuxVersion: "0.65.0",
        cmuxBuild: "103",
        cmuxChannel: "nightly",
        createdAt: new Date(),
        updatedAt: new Date(),
        lastControlPlaneAt: new Date(),
        mutationLeaseId: null,
        mutationLeaseExpiresAt: null,
        revokedAt: null,
      }),
      listAccessGrantTunnels: () => Effect.succeed(rows),
      listAccessGrantSessionIds: () => Effect.succeed(["session-stable", "session-nightly"]),
      revokeTunnel: (id: string) => Effect.sync(() => {
        revoked.push(id);
        return true;
      }),
      revokeAccessGrant: () => Effect.succeed(true),
    } as VmRepositoryShape;
    const gateway = {
      ...testGateway(),
      deleteTunnel: (_provider: string, tunnelId: string) => Effect.sync(() => {
        deleted.push(tunnelId);
      }),
    } as VmProviderGatewayShape;

    const result = await Effect.runPromise(
      revokeVmAccessGrant({
        userId: "user-1",
        accessGrantId: "00000000-0000-4000-8000-0000000000c1",
      }).pipe(Effect.provide(layerFor(repo, gateway))),
    );

    expect(result.revoked).toBe(true);
    expect(result.stackSessionIds).toEqual(["session-stable", "session-nightly"]);
    expect(deleted).toEqual(["tun-userspace", "tun-vpn"]);
    expect(revoked).toEqual(rows.map((row) => row.id));
  });
});
