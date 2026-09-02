import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  enrollVmTunnel,
  isWireGuardPublicKey,
  networkSlugForUser,
  readVmTunnel,
  resolveOwnerNetwork,
  revokeVmTunnel,
  tunnelSlugForDevice,
} from "../services/vms/privateNetwork";
import {
  VmPrivateNetworkUnavailableError,
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
    provider: "freestyle",
    providerTunnelId: "tun-test-1",
    deviceFingerprint: "device-1",
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

type GatewayCalls = {
  ensureNetwork: number;
  createTunnel: CreateProviderTunnelOptions[];
  rotateTunnelKey: string[];
  deleteTunnel: string[];
};

function testGateway(options: {
  calls?: GatewayCalls;
  getTunnel?: ProviderTunnel | null;
  supports?: boolean;
} = {}): VmProviderGatewayShape {
  const calls = options.calls;
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
        return NETWORK;
      }),
    deleteNetwork: () => Effect.void,
    createTunnel: (_provider, createOptions) =>
      Effect.sync(() => {
        calls?.createTunnel.push(createOptions);
        return providerTunnel({ clientPublicKey: createOptions.clientPublicKey });
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
  revoked: string[];
};

function testRepo(options: {
  calls?: RepoCalls;
  network?: CloudVmNetworkRow | null;
  tunnel?: CloudVmTunnelRow | null;
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
    findTunnel: () => Effect.succeed(options.tunnel ?? null),
    listUserTunnels: () => Effect.succeed(options.tunnel ? [options.tunnel] : []),
    insertTunnel: (input) =>
      Effect.sync(() => {
        if (calls) calls.inserts += 1;
        return tunnelRow({
          providerTunnelId: input.providerTunnelId,
          deviceFingerprint: input.deviceFingerprint,
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
  return { ensureNetwork: 0, createTunnel: [], rotateTunnelKey: [], deleteTunnel: [] };
}

function newRepoCalls(): RepoCalls {
  return { upserts: 0, inserts: 0, updates: 0, revoked: [] };
}

describe("WireGuard public key validation", () => {
  test("accepts a base64 32-byte key and rejects everything else", () => {
    expect(isWireGuardPublicKey(CLIENT_KEY)).toBe(true);
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

  test("reuses the recorded network without a provider call", async () => {
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

  test("returns null (does not fail) when the provider has no private networking", async () => {
    const network = await Effect.runPromise(
      resolveOwnerNetwork({ userId: "user-1", provider: "freestyle" }).pipe(
        Effect.provide(layerFor(testRepo(), testGateway({ supports: false }))),
      ),
    );
    expect(network).toBeNull();
  });

  test("returns null when the rollback flag disables private networking", async () => {
    const prior = process.env.CMUX_VM_PRIVATE_NETWORK_ENABLED;
    process.env.CMUX_VM_PRIVATE_NETWORK_ENABLED = "0";
    try {
      const network = await Effect.runPromise(
        resolveOwnerNetwork({ userId: "user-1", provider: "freestyle" }).pipe(
          Effect.provide(layerFor(testRepo(), testGateway())),
        ),
      );
      expect(network).toBeNull();
    } finally {
      if (prior === undefined) delete process.env.CMUX_VM_PRIVATE_NETWORK_ENABLED;
      else process.env.CMUX_VM_PRIVATE_NETWORK_ENABLED = prior;
    }
  });
});

describe("enrollVmTunnel", () => {
  test("first enrollment creates a provider tunnel keyed to the device", async () => {
    const gatewayCalls = newGatewayCalls();
    const repoCalls = newRepoCalls();
    const tunnel = await Effect.runPromise(
      enrollVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceFingerprint: "device-1",
        deviceName: "Test Mac",
        clientPublicKey: CLIENT_KEY,
      }).pipe(
        Effect.provide(layerFor(testRepo({ calls: repoCalls }), testGateway({ calls: gatewayCalls }))),
      ),
    );
    expect(tunnel.created).toBe(true);
    expect(tunnel.rotated).toBe(false);
    expect(tunnel.clientPublicKey).toBe(CLIENT_KEY);
    expect(gatewayCalls.createTunnel).toHaveLength(1);
    expect(gatewayCalls.createTunnel[0]?.networkId).toBe(NETWORK.id);
    expect(repoCalls.inserts).toBe(1);
  });

  test("re-enrolling with the same key is idempotent: no create, no rotate", async () => {
    const gatewayCalls = newGatewayCalls();
    const repoCalls = newRepoCalls();
    const tunnel = await Effect.runPromise(
      enrollVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceFingerprint: "device-1",
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
        deviceFingerprint: "device-1",
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
        deviceFingerprint: "device-1",
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
        deviceFingerprint: "device-1",
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
  test("read fails typed for a device that never enrolled", async () => {
    const error = await Effect.runPromise(
      readVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceFingerprint: "device-unknown",
      }).pipe(
        Effect.provide(layerFor(testRepo({ network: networkRow() }), testGateway())),
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
  });

  test("revoking a device that never enrolled is a no-op, not an error", async () => {
    const result = await Effect.runPromise(
      revokeVmTunnel({
        userId: "user-1",
        provider: "freestyle",
        deviceFingerprint: "device-unknown",
      }).pipe(Effect.provide(layerFor(testRepo(), testGateway()))),
    );
    expect(result.revoked).toBe(false);
  });
});
