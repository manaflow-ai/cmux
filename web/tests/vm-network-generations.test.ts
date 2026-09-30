import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { closeCloudDbForTests } from "../db/client";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import {
  ProviderNetworkAddressExhaustedError,
  type EnsureProviderNetworkOptions,
  type ProviderNetwork,
  type ProviderTunnel,
} from "../services/vms/drivers/types";
import { VmProviderOperationError } from "../services/vms/errors";
import {
  deletePrivateNetworkingForAccountDeletion,
  enrollVmTunnel,
  networkSlugForUser,
  successorNetworkCidr,
  successorNetworkSlug,
  userNetworkCidr,
} from "../services/vms/privateNetwork";
import { isProviderNetworkAddressExhausted } from "../services/vms/providerErrors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import {
  VmRepository,
  vmRepositoryLiveShape,
  type CloudVmNetworkRow,
  type CloudVmRetiredNetworkRow,
  type CloudVmRow,
  type VmRepositoryShape,
} from "../services/vms/repository";
import { createVm } from "../services/vms/workflows";

// Freestyle does not release a deleted tunnel's IPv4 reservation, so a full
// network can stay full whatever the control plane deletes. The owner then
// moves to a successor network: new machines go there, old machines stay
// where they are, and every tunnel attaches every generation.

const USER = "user-gen";
const CLIENT_KEY = Buffer.alloc(32, 1).toString("base64");
const OLD_NETWORK = "vpc-gen-1";
const NEW_NETWORK = "vpc-gen-2";
const OLD_CIDR = "10.16.162.0/24";

function exhausted(networkId: string, operation = "create") {
  return new VmProviderOperationError({
    provider: "freestyle",
    operation,
    cause: new ProviderNetworkAddressExhaustedError("freestyle", networkId, new Error("no free addresses")),
  });
}

function ipv4Range(cidr: string): [number, number] {
  const [address, prefix] = cidr.split("/");
  const base = address!.split(".").reduce((value, octet) => value * 256 + Number(octet), 0);
  return [base, base + 2 ** (32 - Number(prefix)) - 1];
}

function overlaps(a: string, b: string): boolean {
  const [a0, a1] = ipv4Range(a);
  const [b0, b1] = ipv4Range(b);
  return a0 <= b1 && b0 <= a1;
}

type World = {
  current: CloudVmNetworkRow;
  retired: CloudVmRetiredNetworkRow[];
  full: Set<string>;
  ensured: EnsureProviderNetworkOptions[];
  createdIn: string[];
  tunnelsCreatedIn: string[];
  attached: string[];
  detached: string[];
  deletedNetworks: string[];
  failures: string[];
};

function networkRow(providerNetworkId: string, slug: string, cidr: string | null): CloudVmNetworkRow {
  const now = new Date();
  return {
    id: "00000000-0000-4000-8000-00000000c10d",
    userId: USER,
    provider: "freestyle",
    providerNetworkId,
    slug,
    cidr,
    cidrV6: null,
    createdAt: now,
    updatedAt: now,
  };
}

function newWorld(): World {
  return {
    current: networkRow(OLD_NETWORK, networkSlugForUser(USER), OLD_CIDR),
    retired: [],
    full: new Set([OLD_NETWORK]),
    ensured: [],
    createdIn: [],
    tunnelsCreatedIn: [],
    attached: [],
    detached: [],
    deletedNetworks: [],
    failures: [],
  };
}

function providerTunnel(networkIds: readonly string[]): ProviderTunnel {
  return {
    id: "tun-gen",
    clientConfig: "[Interface]\nPrivateKey =\n",
    clientPublicKey: CLIENT_KEY,
    serverPublicKey: "server",
    endpointHost: "vpn.test",
    endpointPort: 51820,
    routes: ["10.0.0.0/8"],
    addressV4: "10.1.1.2",
    addressV6: null,
    attachments: networkIds.map((networkId) => ({ networkId, addressV4: "10.1.1.2", addressV6: null })),
  };
}

function gateway(world: World, options: { readonly existingTunnelNetworks?: readonly string[] } = {}): VmProviderGatewayShape {
  return {
    supportsPrivateNetworking: () => true,
    ensureNetwork: (_provider: string, request: EnsureProviderNetworkOptions) => Effect.sync(() => {
      world.ensured.push(request);
      const network: ProviderNetwork = { id: NEW_NETWORK, slug: request.slug, cidr: request.cidr ?? "10.16.200.0/24", cidrV6: "fd00:2::/64" };
      return network;
    }),
    create: (_provider: string, request: { network?: { id: string } }) => Effect.suspend(() => {
      const networkId = request.network!.id;
      world.createdIn.push(networkId);
      if (world.full.has(networkId)) return Effect.fail(exhausted(networkId));
      return Effect.succeed({
        provider: "freestyle" as const,
        providerVmId: `vm-in-${networkId}`,
        status: "running" as const,
        image: "snapshot-test",
        createdAt: Date.now(),
        providerMetadata: { networkId },
      });
    }),
    destroy: () => Effect.void,
    createTunnel: (_provider: string, request: { networkId: string }) => Effect.suspend(() => {
      world.tunnelsCreatedIn.push(request.networkId);
      if (world.full.has(request.networkId)) return Effect.fail(exhausted(request.networkId, "createTunnel"));
      return Effect.succeed({ tunnel: providerTunnel([request.networkId]), created: true, rotated: false });
    }),
    getTunnel: (_provider: string, _tunnelId: string, networkId: string) =>
      Effect.succeed(options.existingTunnelNetworks ? providerTunnel([...new Set([networkId, ...options.existingTunnelNetworks])]) : null),
    rotateTunnelKey: () => Effect.die("unused"),
    deleteTunnel: () => Effect.void,
    getNetwork: () => Effect.succeed(null),
    deleteNetwork: (_provider: string, networkId: string) => Effect.sync(() => { world.deletedNetworks.push(networkId); }),
    attachTunnelNetwork: (_provider: string, _tunnelId: string, networkId: string) => Effect.suspend(() => {
      world.attached.push(networkId);
      if (world.full.has(networkId)) return Effect.fail(exhausted(networkId, "attachTunnelNetwork"));
      return Effect.succeed({ networkId, addressV4: "10.9.9.9", addressV6: null });
    }),
    detachTunnelNetwork: (_provider: string, _tunnelId: string, networkId: string) => Effect.sync(() => { world.detached.push(networkId); }),
    listNetworkTunnels: () => Effect.succeed([]),
    listTunnels: () => Effect.succeed([]),
  } as unknown as VmProviderGatewayShape;
}

function vmRow(): CloudVmRow {
  const now = new Date();
  return {
    id: "00000000-0000-4000-8000-00000000f012",
    userId: USER,
    billingTeamId: USER,
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: null,
    displayName: null,
    slug: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status: "provisioning",
    idempotencyKey: null,
    createdAt: now,
    updatedAt: now,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    ownerTeamId: USER,
    coderouterPoolId: null,
  };
}

function repo(world: World, tunnelRow: boolean = false): VmRepositoryShape {
  const vm = vmRow();
  const now = new Date();
  const grant = {
    id: "00000000-0000-4000-8000-0000000000c1", userId: USER, deviceId: "mac-1", reportedName: "Mac", displayName: null,
    modelIdentifier: null, osVersion: null, architecture: null, cmuxVersion: null, cmuxBuild: null, cmuxChannel: null,
    createdAt: now, updatedAt: now, lastControlPlaneAt: now, mutationLeaseId: null, mutationLeaseExpiresAt: null, revokedAt: null,
  };
  const tunnel = {
    id: "00000000-0000-4000-8000-0000000000bb", userId: USER, networkId: world.current.id, accessGrantId: grant.id,
    provider: "freestyle", providerTunnelId: "tun-gen", deviceFingerprint: "device-1", tunnelPurpose: "terminal",
    deviceName: null, clientPublicKey: CLIENT_KEY, addressV4: null, addressV6: null,
    createdAt: now, updatedAt: now, lastConfigIssuedAt: now, revokedAt: null,
  };
  return {
    beginCreate: () => Effect.succeed({ inserted: true, vm }),
    claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
    recordUsageEvent: () => Effect.void,
    recordUsageEvents: () => Effect.void,
    markCreateFailed: (input: { code: string }) => Effect.sync(() => { world.failures.push(input.code); return true; }),
    markCreateRunning: (update: { providerVmId: string; image: string; providerMetadata?: Record<string, unknown> }) =>
      Effect.succeed({ ...vm, status: "running", providerVmId: update.providerVmId, imageId: update.image, providerMetadata: update.providerMetadata ?? {} }),
    activeLimitCandidates: () => Effect.succeed([]),
    findNetwork: () => Effect.sync(() => world.current),
    upsertNetwork: () => Effect.die("the owner network already exists"),
    deleteNetwork: () => Effect.void,
    listRetiredNetworks: () => Effect.sync(() => [...world.retired]),
    deleteRetiredNetwork: (id: string) => Effect.sync(() => { world.retired = world.retired.filter((row) => row.id !== id); }),
    rotateNetwork: (input: { fromProviderNetworkId: string; to: { providerNetworkId: string; slug: string; cidr: string | null; cidrV6: string | null } }) => Effect.sync(() => {
      if (world.current.providerNetworkId !== input.fromProviderNetworkId) return world.current;
      world.retired.push({
        id: randomUUID(),
        userId: USER,
        provider: "freestyle",
        providerNetworkId: world.current.providerNetworkId,
        slug: world.current.slug,
        cidr: world.current.cidr,
        cidrV6: world.current.cidrV6,
        createdAt: world.current.createdAt,
        retiredAt: new Date(),
      });
      world.current = { ...world.current, ...input.to, updatedAt: new Date() };
      return world.current;
    }),
    findTunnelsByProviderTunnelIds: () => Effect.succeed([]),
    findAccessGrant: () => Effect.succeed(grant),
    findBlockingRevokedAccessGrant: () => Effect.succeed(null),
    listUserAccessGrants: () => Effect.succeed([grant]),
    upsertAccessGrant: () => Effect.succeed(grant),
    upsertAccessGrantSession: () => Effect.void,
    listAccessGrantSessionIds: () => Effect.succeed([]),
    renameAccessGrant: () => Effect.succeed(grant),
    listAccessGrantTunnels: () => Effect.succeed([]),
    claimAccessGrantMutation: () => Effect.succeed(true),
    releaseAccessGrantMutation: () => Effect.void,
    revokeAccessGrant: () => Effect.succeed(true),
    findTunnel: () => Effect.succeed(tunnelRow ? tunnel : null),
    listUserTunnels: () => Effect.succeed([]),
    insertTunnel: (input: Record<string, unknown>) => Effect.succeed({ ...tunnel, ...input }),
    updateTunnel: () => Effect.succeed(tunnel),
    revokeTunnel: () => Effect.succeed(true),
  } as unknown as VmRepositoryShape;
}

function layer(world: World, options: { readonly tunnelRow?: boolean; readonly existingTunnelNetworks?: readonly string[] } = {}) {
  return Layer.mergeAll(
    Layer.succeed(VmRepository, repo(world, options.tunnelRow)),
    Layer.succeed(VmProviderGateway, gateway(world, options)),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
}

const createInput = {
  userId: USER,
  billingCustomerType: "user" as const,
  billingTeamId: USER,
  billingPlanId: "pro",
  maxActiveVms: null,
  provider: "freestyle" as const,
  image: "snapshot-test",
};

describe("successor network naming and range", () => {
  test("generation slugs extend the owner's slug and stay valid provider slugs", () => {
    expect(successorNetworkSlug(USER, 2, {})).toBe(`${networkSlugForUser(USER, {})}-g2`);
    const namespaced = successorNetworkSlug(USER, 99, { CMUX_VM_NETWORK_NAMESPACE: "dev-0123456789ab" });
    expect(namespaced.length).toBeLessThanOrEqual(63);
    expect(() => successorNetworkSlug(USER, 1, {})).toThrow();
    expect(() => successorNetworkSlug(USER, 100, {})).toThrow();
  });

  test("a successor range never overlaps a range the owner's tunnels already route", () => {
    const first = userNetworkCidr(USER);
    const second = successorNetworkCidr(USER, [OLD_CIDR, first]);
    expect(second.endsWith("/20")).toBe(true);
    expect(overlaps(second, first)).toBe(false);
    expect(overlaps(second, OLD_CIDR)).toBe(false);
    expect(successorNetworkCidr(USER, [OLD_CIDR])).toBe(first);
  });
});

describe("createVm when the owner's network stays full", () => {
  test("moves the owner to a successor network and creates the machine there", async () => {
    const world = newWorld();
    const vm = await Effect.runPromise(createVm(createInput).pipe(Effect.provide(layer(world))));
    expect(vm.providerVmId).toBe(`vm-in-${NEW_NETWORK}`);
    expect(world.createdIn).toEqual([OLD_NETWORK, NEW_NETWORK]);
    expect(world.ensured).toEqual([expect.objectContaining({
      slug: successorNetworkSlug(USER, 2),
      cidr: successorNetworkCidr(USER, [OLD_CIDR]),
    })]);
    expect(world.current.providerNetworkId).toBe(NEW_NETWORK);
    expect(world.retired.map((row) => [row.providerNetworkId, row.cidr])).toEqual([[OLD_NETWORK, OLD_CIDR]]);
    expect(world.failures).toEqual([]);
  });

  test("a full successor is final: one rotation per request, typed failure", async () => {
    const world = newWorld();
    world.full.add(NEW_NETWORK);
    const error = await Effect.runPromise(createVm(createInput).pipe(Effect.flip, Effect.provide(layer(world))));
    expect(isProviderNetworkAddressExhausted(error)).toBe(true);
    expect(world.createdIn).toEqual([OLD_NETWORK, NEW_NETWORK]);
    expect(world.ensured).toHaveLength(1);
  });

  test("a rotation another request already made is reused, not repeated", async () => {
    const world = newWorld();
    const successor = networkRow(NEW_NETWORK, successorNetworkSlug(USER, 2), successorNetworkCidr(USER, [OLD_CIDR]));
    const base = repo(world);
    const racing = {
      ...base,
      // Another request rotated between this request's read and its rotation.
      rotateNetwork: () => Effect.sync(() => {
        world.retired.push({ id: randomUUID(), userId: USER, provider: "freestyle", providerNetworkId: OLD_NETWORK, slug: null, cidr: OLD_CIDR, cidrV6: null, createdAt: new Date(), retiredAt: new Date() });
        world.current = successor;
        return successor;
      }),
    } as VmRepositoryShape;
    const vm = await Effect.runPromise(createVm(createInput).pipe(Effect.provide(Layer.mergeAll(
      Layer.succeed(VmRepository, racing),
      Layer.succeed(VmProviderGateway, gateway(world)),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    ))));
    expect(vm.providerVmId).toBe(`vm-in-${NEW_NETWORK}`);
  });
});

describe("tunnels reach every network generation", () => {
  test("enrollment keeps the retired network attached and lists every range", async () => {
    const world = newWorld();
    world.full.clear();
    world.retired.push({ id: randomUUID(), userId: USER, provider: "freestyle", providerNetworkId: OLD_NETWORK, slug: networkSlugForUser(USER), cidr: OLD_CIDR, cidrV6: "fd00:1::/64", createdAt: new Date(), retiredAt: new Date() });
    world.current = networkRow(NEW_NETWORK, successorNetworkSlug(USER, 2), "10.200.16.0/20");
    const tunnel = await Effect.runPromise(enrollVmTunnel({
      userId: USER, provider: "freestyle", deviceId: "mac-1", deviceFingerprint: "device-1", tunnelPurpose: "terminal",
      clientPublicKey: CLIENT_KEY, teamIds: [],
    }).pipe(Effect.provide(layer(world, { tunnelRow: true, existingTunnelNetworks: [] }))));
    expect(world.attached).toEqual([OLD_NETWORK]);
    expect(world.detached).toEqual([]);
    expect(tunnel.network.id).toBe(NEW_NETWORK);
    expect(tunnel.networks.map((network) => [network.id, network.cidr, network.scope])).toEqual([
      [NEW_NETWORK, "10.200.16.0/20", "user"],
      [OLD_NETWORK, OLD_CIDR, "user"],
    ]);
  });

  test("an already attached retired network is neither re-attached nor detached", async () => {
    const world = newWorld();
    world.full.clear();
    world.retired.push({ id: randomUUID(), userId: USER, provider: "freestyle", providerNetworkId: OLD_NETWORK, slug: null, cidr: OLD_CIDR, cidrV6: null, createdAt: new Date(), retiredAt: new Date() });
    world.current = networkRow(NEW_NETWORK, successorNetworkSlug(USER, 2), "10.200.16.0/20");
    await Effect.runPromise(enrollVmTunnel({
      userId: USER, provider: "freestyle", deviceId: "mac-1", deviceFingerprint: "device-1", tunnelPurpose: "terminal",
      clientPublicKey: CLIENT_KEY, teamIds: [],
    }).pipe(Effect.provide(layer(world, { tunnelRow: true, existingTunnelNetworks: [OLD_NETWORK] }))));
    expect(world.attached).toEqual([]);
    expect(world.detached).toEqual([]);
  });

  test("a new computer on a full network enrolls into the successor and skips the full retired one", async () => {
    const world = newWorld();
    const tunnel = await Effect.runPromise(enrollVmTunnel({
      userId: USER, provider: "freestyle", deviceId: "mac-1", deviceFingerprint: "device-1", tunnelPurpose: "terminal",
      clientPublicKey: CLIENT_KEY, teamIds: [],
    }).pipe(Effect.provide(layer(world))));
    expect(world.tunnelsCreatedIn).toEqual([OLD_NETWORK, NEW_NETWORK]);
    expect(tunnel.network.id).toBe(NEW_NETWORK);
    // The retired network has no address left for it; enrollment still succeeds.
    expect(world.attached).toEqual([OLD_NETWORK]);
    expect(tunnel.networks.map((network) => network.id)).toEqual([NEW_NETWORK]);
  });
});

describe("account deletion", () => {
  test("deletes retired networks too", async () => {
    const world = newWorld();
    world.retired.push({ id: randomUUID(), userId: USER, provider: "freestyle", providerNetworkId: "vpc-gen-0", slug: null, cidr: null, cidrV6: null, createdAt: new Date(), retiredAt: new Date() });
    await Effect.runPromise(deletePrivateNetworkingForAccountDeletion(USER).pipe(Effect.provide(layer(world))));
    expect(world.deletedNetworks.sort()).toEqual(["vpc-gen-0", OLD_NETWORK].sort());
    expect(world.retired).toEqual([]);
  });
});

const dbTest = process.env.CMUX_DB_TEST === "1" ? test : test.skip;
let sql: Sql | null = null;
beforeAll(() => {
  if (process.env.CMUX_DB_TEST !== "1") return;
  sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 2 });
});
afterAll(async () => {
  if (!sql) return;
  await closeCloudDbForTests();
  await sql.end();
});

describe("network rotation in Postgres", () => {
  dbTest("retires the current network once and keeps the row id tunnels reference", async () => {
    const userId = `user-rotate-${randomUUID()}`;
    const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);
    try {
      const first = await run(vmRepositoryLiveShape.upsertNetwork!({ userId, provider: "freestyle", providerNetworkId: `vpc-${userId}-1`, slug: "gen-1", cidr: OLD_CIDR, cidrV6: null }));
      const to = { providerNetworkId: `vpc-${userId}-2`, slug: "gen-1-g2", cidr: "10.200.16.0/20", cidrV6: "fd00:2::/64" };
      const [a, b] = await Promise.all([
        run(vmRepositoryLiveShape.rotateNetwork!({ userId, provider: "freestyle", fromProviderNetworkId: first.providerNetworkId, to })),
        run(vmRepositoryLiveShape.rotateNetwork!({ userId, provider: "freestyle", fromProviderNetworkId: first.providerNetworkId, to })),
      ]);
      expect(a.id).toBe(first.id);
      expect(b.id).toBe(first.id);
      expect(a.providerNetworkId).toBe(to.providerNetworkId);
      expect(b.providerNetworkId).toBe(to.providerNetworkId);
      const retired = await run(vmRepositoryLiveShape.listRetiredNetworks!(userId, "freestyle"));
      expect(retired.map((row) => [row.providerNetworkId, row.cidr])).toEqual([[first.providerNetworkId, OLD_CIDR]]);
      // A stale rotation (from the retired id) changes nothing.
      const stale = await run(vmRepositoryLiveShape.rotateNetwork!({ userId, provider: "freestyle", fromProviderNetworkId: first.providerNetworkId, to: { ...to, providerNetworkId: `vpc-${userId}-3` } }));
      expect(stale.providerNetworkId).toBe(to.providerNetworkId);
      await run(vmRepositoryLiveShape.deleteRetiredNetwork!(retired[0]!.id));
      expect(await run(vmRepositoryLiveShape.listRetiredNetworks!(userId, "freestyle"))).toEqual([]);
    } finally {
      await sql!`delete from cloud_vm_retired_networks where user_id = ${userId}`;
      await sql!`delete from cloud_vm_networks where user_id = ${userId}`;
    }
  });
});
