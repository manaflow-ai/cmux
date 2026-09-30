import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { FreestyleApiError, type Freestyle } from "freestyle";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import {
  ProviderNetworkAddressExhaustedError,
  ProviderTunnelNetworkOverlapError,
  type ProviderNetworkTunnel,
  type ProviderTunnel,
} from "../services/vms/drivers/types";
import { VmProviderOperationError } from "../services/vms/errors";
import {
  FOREIGN_TUNNEL_MIN_AGE_MS,
  MAX_RECLAIM_ACTIONS,
  planNetworkReclaim,
  reclaimNetworkAddresses,
  reconcileRevokedProviderTunnels,
} from "../services/vms/networkCapacity";
import { enrollVmTunnel } from "../services/vms/privateNetwork";
import { isProviderNetworkAddressExhausted } from "../services/vms/providerErrors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import {
  PROVIDER_NETWORK_FULL_FAILURE_CODE,
  VmRepository,
  type CloudVmRow,
  type VmRepositoryShape,
} from "../services/vms/repository";
import { respondVmWorkflowError } from "../services/vms/routeHelpers";
import { createVm } from "../services/vms/workflows";

// The outage this file pins: Freestyle refused a VM create with
// `409 CONFLICT: vpc … has no free addresses in 10.16.162.0/24`, the route
// answered a retryable 502, and the client retried every 5 s forever while
// 150 WireGuard tunnels leaked by dev stacks held the addresses.

// Workflow paths read the wall clock, so fixtures are relative to it.
const NOW = Date.now();
const DAY = 24 * 60 * 60 * 1000;
const FULL_NETWORK = "vpc-full";
const EXHAUSTED_MESSAGE = `conflict: vpc ${FULL_NETWORK} has no free addresses in 10.16.162.0/24`;
const CLIENT_KEY = Buffer.alloc(32, 1).toString("base64");

function exhaustedApiError() {
  return new FreestyleApiError(409, { code: "CONFLICT", message: EXHAUSTED_MESSAGE });
}

function exhaustedProviderFailure(operation = "create") {
  return new VmProviderOperationError({
    provider: "freestyle",
    operation,
    cause: new ProviderNetworkAddressExhaustedError("freestyle", FULL_NETWORK, exhaustedApiError()),
  });
}

function networkTunnel(id: string, ageMs: number): ProviderNetworkTunnel {
  const at = NOW - ageMs;
  return { id, slug: null, createdAt: at, updatedAt: at, networkIds: [FULL_NETWORK] };
}

async function bodyOf(response: Response | null) {
  expect(response).not.toBeNull();
  return { status: response!.status, body: await response!.json() as Record<string, unknown> };
}

describe("Freestyle address exhaustion is a typed network failure", () => {
  test("a VM create into a full network rejects with the typed error", async () => {
    const provider = new FreestyleProvider({
      client: () => ({ vms: { create: async () => { throw exhaustedApiError(); } } } as unknown as Freestyle),
    });
    const error = await provider.create({ image: "snapshot-1", network: { id: FULL_NETWORK, memberIngress: false } })
      .catch((err: unknown) => err);
    expect(error).toBeInstanceOf(ProviderNetworkAddressExhaustedError);
    expect((error as ProviderNetworkAddressExhaustedError).networkId).toBe(FULL_NETWORK);
    expect(isProviderNetworkAddressExhausted(new VmProviderOperationError({ provider: "freestyle", operation: "create", cause: error }))).toBe(true);
  });

  test("a tunnel create into a full network is not mistaken for a recoverable slug conflict", async () => {
    let listed = 0;
    const provider = new FreestyleProvider({
      client: () => ({
        tunnels: {
          create: async () => { throw exhaustedApiError(); },
          list: async () => { listed += 1; return { tunnels: [], totalCount: 0 }; },
        },
      } as unknown as Freestyle),
    });
    const error = await provider.privateNetworking!.createTunnel({
      slug: "cmux-wg-1",
      clientPublicKey: CLIENT_KEY,
      networkId: FULL_NETWORK,
    }).catch((err: unknown) => err);
    expect(error).toBeInstanceOf(ProviderNetworkAddressExhaustedError);
    expect(listed).toBe(0);
  });

  test("attaching a tunnel to a full network is exhaustion, not an overlap", async () => {
    const provider = new FreestyleProvider({
      client: () => ({ tunnels: { attachVpc: async () => { throw exhaustedApiError(); } } } as unknown as Freestyle),
    });
    const error = await provider.privateNetworking!.attachTunnelNetwork!("tun-1", FULL_NETWORK).catch((err: unknown) => err);
    expect(error).toBeInstanceOf(ProviderNetworkAddressExhaustedError);
    expect(error).not.toBeInstanceOf(ProviderTunnelNetworkOverlapError);
  });

  test("re-attaching a known tunnel to a full network is exhaustion", async () => {
    const provider = new FreestyleProvider({
      client: () => ({
        tunnels: {
          get: async () => ({ id: "tun-1", tunnelId: "tun-1", attachments: [], clientPublicKey: CLIENT_KEY }),
          attachVpc: async () => { throw exhaustedApiError(); },
        },
      } as unknown as Freestyle),
    });
    const error = await provider.privateNetworking!.getTunnel("tun-1", FULL_NETWORK).catch((err: unknown) => err);
    expect(error).toBeInstanceOf(ProviderNetworkAddressExhaustedError);
  });

  test("a slug conflict is still an ordinary conflict", async () => {
    const provider = new FreestyleProvider({
      client: () => ({ vms: { create: async () => { throw new FreestyleApiError(409, { code: "CONFLICT", message: "slug already exists" }); } } } as unknown as Freestyle),
    });
    const error = await provider.create({ image: "snapshot-1", network: { id: FULL_NETWORK, memberIngress: false } })
      .catch((err: unknown) => err);
    expect(error).not.toBeInstanceOf(ProviderNetworkAddressExhaustedError);
  });

  test("tunnels attached to a network carry the provider's timestamps", async () => {
    const provider = new FreestyleProvider({
      client: () => ({
        vpc: {
          ref: () => ({
            tunnels: {
              list: async () => ({
                tunnels: [{
                  id: "row-1",
                  tunnelId: "tun-1",
                  slug: "cmux-wg-1",
                  createdAt: "2026-09-01T00:00:00Z",
                  updatedAt: "2026-09-02T00:00:00Z",
                  attachments: [{ vpcId: FULL_NETWORK }],
                }],
                totalCount: 1,
              }),
            },
          }),
        },
      } as unknown as Freestyle),
    });
    await expect(provider.privateNetworking!.listNetworkTunnels!(FULL_NETWORK)).resolves.toEqual([{
      id: "tun-1",
      slug: "cmux-wg-1",
      createdAt: Date.parse("2026-09-01T00:00:00Z"),
      updatedAt: Date.parse("2026-09-02T00:00:00Z"),
      networkIds: [FULL_NETWORK],
    }]);
  });
});

describe("vm_network_full response", () => {
  test("is a non-retryable 409 with an action, not a retryable 502", async () => {
    const { status, body } = await bodyOf(await respondVmWorkflowError(exhaustedProviderFailure(), { locale: "en" }));
    expect(status).toBe(409);
    expect(body.error).toBe("vm_network_full");
    expect(body.retryable).toBe(false);
    expect(body.retryAfterSeconds).toBeUndefined();
    expect(String(body.message)).not.toMatch(/retrying|temporarily unavailable|timed out/i);
    expect(String(body.action)).toContain("cmux vm rm");
  });

  test("is localized", async () => {
    const en = await bodyOf(await respondVmWorkflowError(exhaustedProviderFailure(), { locale: "en" }));
    const ja = await bodyOf(await respondVmWorkflowError(exhaustedProviderFailure(), { locale: "ja" }));
    expect(ja.body.error).toBe("vm_network_full");
    expect(ja.body.message).not.toBe(en.body.message);
  });

  test("tunnel enrollment into a full network answers the same code", async () => {
    const { status, body } = await bodyOf(await respondVmWorkflowError(exhaustedProviderFailure("createTunnel"), { locale: "en" }));
    expect(status).toBe(409);
    expect(body.error).toBe("vm_network_full");
  });

  test("other provider failures keep the retryable outage answer", async () => {
    const other = new VmProviderOperationError({ provider: "freestyle", operation: "create", cause: new Error("boom") });
    const { status, body } = await bodyOf(await respondVmWorkflowError(other, { locale: "en" }));
    expect(status).toBe(502);
    expect(body.error).toBe("vm_cloud_service_unavailable");
  });
});

describe("reclaim policy", () => {
  test("reclaims revoked rows first, then foreign tunnels oldest first, and never an active row or a young tunnel", () => {
    const actions = planNetworkReclaim({
      now: NOW,
      tunnels: [
        networkTunnel("tun-active-ancient", 400 * DAY),
        networkTunnel("tun-foreign-young", FOREIGN_TUNNEL_MIN_AGE_MS - 60_000),
        networkTunnel("tun-foreign-mid", 10 * DAY),
        networkTunnel("tun-revoked", 1_000),
        networkTunnel("tun-foreign-old", 30 * DAY),
      ],
      rows: [
        { providerTunnelId: "tun-active-ancient", revokedAt: null },
        { providerTunnelId: "tun-revoked", revokedAt: new Date(NOW - 1_000) },
      ],
    });
    expect(actions).toEqual([
      { kind: "delete", tunnelId: "tun-revoked", reason: "revoked_row" },
      { kind: "detach", tunnelId: "tun-foreign-old", reason: "foreign_tunnel" },
      { kind: "detach", tunnelId: "tun-foreign-mid", reason: "foreign_tunnel" },
    ]);
  });

  test("a tunnel with both a revoked and an active row is kept", () => {
    const actions = planNetworkReclaim({
      now: NOW,
      tunnels: [networkTunnel("tun-shared", 90 * DAY)],
      rows: [
        { providerTunnelId: "tun-shared", revokedAt: new Date(NOW - DAY) },
        { providerTunnelId: "tun-shared", revokedAt: null },
      ],
    });
    expect(actions).toEqual([]);
  });

  test("is bounded per request", () => {
    const tunnels = Array.from({ length: MAX_RECLAIM_ACTIONS + 10 }, (_, index) => networkTunnel(`tun-${index}`, (index + 2) * DAY));
    expect(planNetworkReclaim({ now: NOW, tunnels, rows: [] })).toHaveLength(MAX_RECLAIM_ACTIONS);
  });
});

type ReclaimCalls = { deleted: string[]; detached: string[]; created: number; createdTunnels: number; failures: string[] };

function newCalls(): ReclaimCalls {
  return { deleted: [], detached: [], created: 0, createdTunnels: 0, failures: [] };
}

function reclaimGateway(calls: ReclaimCalls, options: {
  readonly tunnels?: readonly ProviderNetworkTunnel[];
  readonly createFailures?: number;
  readonly tunnelCreateFailures?: number;
  readonly failDetach?: string;
  readonly accountTunnels?: readonly ProviderNetworkTunnel[];
} = {}): VmProviderGatewayShape {
  let createFailures = options.createFailures ?? 0;
  let tunnelCreateFailures = options.tunnelCreateFailures ?? 0;
  const tunnel: ProviderTunnel = {
    id: "tun-new",
    clientConfig: "[Interface]\nPrivateKey =\n",
    clientPublicKey: CLIENT_KEY,
    serverPublicKey: "server",
    endpointHost: "vpn.test",
    endpointPort: 51820,
    routes: ["10.0.0.0/8"],
    addressV4: "10.16.162.9",
    addressV6: null,
  };
  return {
    create: () => Effect.suspend(() => {
      calls.created += 1;
      if (createFailures > 0) {
        createFailures -= 1;
        return Effect.fail(exhaustedProviderFailure());
      }
      return Effect.succeed({
        provider: "freestyle" as const,
        providerVmId: "provider-vm-1",
        status: "running" as const,
        image: "snapshot-test",
        createdAt: NOW,
      });
    }),
    destroy: () => Effect.void,
    supportsPrivateNetworking: () => true,
    ensureNetwork: () => Effect.die("the owner network already exists"),
    createTunnel: () => Effect.suspend(() => {
      calls.createdTunnels += 1;
      if (tunnelCreateFailures > 0) {
        tunnelCreateFailures -= 1;
        return Effect.fail(exhaustedProviderFailure("createTunnel"));
      }
      return Effect.succeed({ tunnel, created: true, rotated: false });
    }),
    getTunnel: () => Effect.succeed(null),
    rotateTunnelKey: () => Effect.die("unused"),
    deleteTunnel: (_provider: string, tunnelId: string) => Effect.sync(() => { calls.deleted.push(tunnelId); }),
    detachTunnelNetwork: (_provider: string, tunnelId: string, networkId: string) => {
      if (tunnelId === options.failDetach) {
        calls.failures.push(tunnelId);
        return Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "detachTunnelNetwork", cause: new Error("down") }));
      }
      return Effect.sync(() => { calls.detached.push(`${tunnelId}@${networkId}`); });
    },
    listNetworkTunnels: () => Effect.succeed([...(options.tunnels ?? [])]),
    listTunnels: () => Effect.succeed([...(options.accountTunnels ?? [])]),
  } as unknown as VmProviderGatewayShape;
}

function reclaimRepo(rows: ReadonlyArray<{ providerTunnelId: string; revokedAt: Date | null }>, extra: Partial<VmRepositoryShape> = {}) {
  return {
    findTunnelsByProviderTunnelIds: (_provider: string, ids: readonly string[]) =>
      Effect.succeed(rows.filter((row) => ids.includes(row.providerTunnelId)).map((row) => ({ ...row, userId: "user-1" }))),
    ...extra,
  } as unknown as VmRepositoryShape;
}

function layer(repo: VmRepositoryShape, providers: VmProviderGatewayShape) {
  return Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
}

const POLICY_TUNNELS = [
  networkTunnel("tun-active", 200 * DAY),
  networkTunnel("tun-revoked", 3 * DAY),
  networkTunnel("tun-foreign", 20 * DAY),
  networkTunnel("tun-foreign-young", 60_000),
];
const POLICY_ROWS = [
  { providerTunnelId: "tun-active", revokedAt: null },
  { providerTunnelId: "tun-revoked", revokedAt: new Date(NOW - DAY) },
];

describe("reclaimNetworkAddresses", () => {
  test("deletes revoked tunnels, detaches old foreign ones from the full network only, and counts partial failures", async () => {
    const calls = newCalls();
    const result = await Effect.runPromise(
      reclaimNetworkAddresses({ provider: "freestyle", networkId: FULL_NETWORK, now: NOW }).pipe(
        Effect.provide(layer(reclaimRepo(POLICY_ROWS), reclaimGateway(calls, {
          tunnels: [...POLICY_TUNNELS, networkTunnel("tun-foreign-broken", 21 * DAY)],
          failDetach: "tun-foreign-broken",
        }))),
      ),
    );
    expect(calls.deleted).toEqual(["tun-revoked"]);
    expect(calls.detached).toEqual([`tun-foreign@${FULL_NETWORK}`]);
    expect(result).toEqual({ planned: 3, freed: 2, failed: 1 });
  });

  test("a provider listing failure frees nothing and does not throw", async () => {
    const calls = newCalls();
    const gateway = {
      ...reclaimGateway(calls),
      listNetworkTunnels: () => Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "listNetworkTunnels", cause: new Error("down") })),
    } as VmProviderGatewayShape;
    const result = await Effect.runPromise(
      reclaimNetworkAddresses({ provider: "freestyle", networkId: FULL_NETWORK, now: NOW }).pipe(
        Effect.provide(layer(reclaimRepo([]), gateway)),
      ),
    );
    expect(result).toEqual({ planned: 0, freed: 0, failed: 0 });
  });
});

function createRow(): CloudVmRow {
  const now = new Date(NOW);
  return {
    id: "00000000-0000-4000-8000-00000000f011",
    userId: "user-1",
    billingTeamId: "team-1",
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
    ownerTeamId: "team-1",
    coderouterPoolId: null,
  };
}

function createRepo(failures: string[]): VmRepositoryShape {
  const vm = createRow();
  const now = new Date(NOW);
  return reclaimRepo(POLICY_ROWS, {
    beginCreate: () => Effect.succeed({ inserted: true, vm }),
    claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
    recordUsageEvent: () => Effect.void,
    recordUsageEvents: () => Effect.void,
    markCreateFailed: (input: { code: string }) => Effect.sync(() => { failures.push(input.code); return true; }),
    markCreateRunning: (update: { providerVmId: string; image: string }) =>
      Effect.succeed({ ...vm, status: "running", providerVmId: update.providerVmId, imageId: update.image }),
    activeLimitCandidates: () => Effect.succeed([]),
    findNetwork: () => Effect.succeed({
      id: "00000000-0000-4000-8000-00000000c10d",
      userId: vm.userId,
      provider: "freestyle",
      providerNetworkId: FULL_NETWORK,
      slug: "cmux-net-full",
      cidr: "10.16.162.0/24",
      cidrV6: null,
      createdAt: now,
      updatedAt: now,
    }),
    upsertNetwork: () => Effect.die("the owner network already exists"),
  } as unknown as Partial<VmRepositoryShape>);
}

const createInput = {
  userId: "user-1",
  billingCustomerType: "team" as const,
  billingTeamId: "team-1",
  billingPlanId: "pro",
  maxActiveVms: null,
  provider: "freestyle" as const,
  image: "snapshot-test",
};

describe("createVm into a full network", () => {
  test("reclaims provably stale addresses and retries the create once", async () => {
    const calls = newCalls();
    const failures: string[] = [];
    const vm = await Effect.runPromise(createVm(createInput).pipe(
      Effect.provide(layer(createRepo(failures), reclaimGateway(calls, { tunnels: POLICY_TUNNELS, createFailures: 1 }))),
    ));
    expect(vm.providerVmId).toBe("provider-vm-1");
    expect(calls.created).toBe(2);
    expect(calls.deleted).toEqual(["tun-revoked"]);
    expect(calls.detached).toEqual([`tun-foreign@${FULL_NETWORK}`]);
    expect(failures).toEqual([]);
  });

  test("fails typed without a second create when nothing is provably stale", async () => {
    const calls = newCalls();
    const failures: string[] = [];
    const error = await Effect.runPromise(createVm(createInput).pipe(
      Effect.flip,
      Effect.provide(layer(createRepo(failures), reclaimGateway(calls, { tunnels: [networkTunnel("tun-active", 200 * DAY)], createFailures: 5 }))),
    ));
    expect(isProviderNetworkAddressExhausted(error)).toBe(true);
    expect(calls.created).toBe(1);
    expect(calls.deleted).toEqual([]);
    expect(calls.detached).toEqual([]);
    expect(failures).toEqual([PROVIDER_NETWORK_FULL_FAILURE_CODE]);
  });

  test("a second exhaustion after a reclaim is not retried again", async () => {
    const calls = newCalls();
    const failures: string[] = [];
    const error = await Effect.runPromise(createVm(createInput).pipe(
      Effect.flip,
      Effect.provide(layer(createRepo(failures), reclaimGateway(calls, { tunnels: POLICY_TUNNELS, createFailures: 5 }))),
    ));
    expect(isProviderNetworkAddressExhausted(error)).toBe(true);
    expect(calls.created).toBe(2);
    expect(failures).toEqual([PROVIDER_NETWORK_FULL_FAILURE_CODE]);
  });
});

describe("enrollVmTunnel into a full network", () => {
  test("reclaims and retries the tunnel create once", async () => {
    const calls = newCalls();
    const now = new Date(NOW);
    const grant = {
      id: "00000000-0000-4000-8000-0000000000c1",
      userId: "user-1",
      deviceId: "mac-1",
      reportedName: "Mac",
      displayName: null,
      modelIdentifier: null,
      osVersion: null,
      architecture: null,
      cmuxVersion: null,
      cmuxBuild: null,
      cmuxChannel: null,
      createdAt: now,
      updatedAt: now,
      lastControlPlaneAt: now,
      mutationLeaseId: null,
      mutationLeaseExpiresAt: null,
      revokedAt: null,
    };
    const repo = reclaimRepo(POLICY_ROWS, {
      findNetwork: () => Effect.succeed({
        id: "00000000-0000-4000-8000-00000000c10d",
        userId: "user-1",
        provider: "freestyle",
        providerNetworkId: FULL_NETWORK,
        slug: "cmux-net-full",
        cidr: "10.16.162.0/24",
        cidrV6: null,
        createdAt: now,
        updatedAt: now,
      }),
      upsertNetwork: () => Effect.die("unused"),
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
      findTunnel: () => Effect.succeed(null),
      listUserTunnels: () => Effect.succeed([]),
      insertTunnel: (input: { providerTunnelId: string; accessGrantId: string; deviceFingerprint: string; tunnelPurpose: "terminal" | "browser"; clientPublicKey: string }) => Effect.succeed({
        id: "00000000-0000-4000-8000-0000000000bb",
        userId: "user-1",
        networkId: "00000000-0000-4000-8000-00000000c10d",
        provider: "freestyle",
        deviceName: null,
        addressV4: null,
        addressV6: null,
        createdAt: now,
        updatedAt: now,
        lastConfigIssuedAt: now,
        revokedAt: null,
        ...input,
      }),
      updateTunnel: () => Effect.die("unused"),
      revokeTunnel: () => Effect.succeed(true),
    } as unknown as Partial<VmRepositoryShape>);
    const tunnel = await Effect.runPromise(enrollVmTunnel({
      userId: "user-1",
      provider: "freestyle",
      deviceId: "mac-1",
      deviceFingerprint: "device-1",
      tunnelPurpose: "terminal",
      clientPublicKey: CLIENT_KEY,
    }).pipe(Effect.provide(layer(repo, reclaimGateway(calls, { tunnels: POLICY_TUNNELS, tunnelCreateFailures: 1 })))));
    expect(tunnel.tunnelId).toBe("tun-new");
    expect(calls.createdTunnels).toBe(2);
    expect(calls.deleted).toEqual(["tun-revoked"]);
  });
});

describe("reconcileRevokedProviderTunnels", () => {
  test("deletes provider tunnels whose only row is revoked and leaves active and unknown tunnels alone", async () => {
    const calls = newCalls();
    const result = await Effect.runPromise(reconcileRevokedProviderTunnels({ provider: "freestyle" }).pipe(
      Effect.provide(layer(reclaimRepo(POLICY_ROWS), reclaimGateway(calls, { accountTunnels: POLICY_TUNNELS }))),
    ));
    expect(calls.deleted).toEqual(["tun-revoked"]);
    expect(calls.detached).toEqual([]);
    expect(result).toEqual({ checked: POLICY_TUNNELS.length, deleted: 1, failed: 0 });
  });

  test("is bounded per run", async () => {
    const calls = newCalls();
    const tunnels = Array.from({ length: 5 }, (_, index) => networkTunnel(`tun-r${index}`, DAY));
    const rows = tunnels.map((tunnel) => ({ providerTunnelId: tunnel.id, revokedAt: new Date(NOW - DAY) }));
    const result = await Effect.runPromise(reconcileRevokedProviderTunnels({ provider: "freestyle", limit: 2 }).pipe(
      Effect.provide(layer(reclaimRepo(rows), reclaimGateway(calls, { accountTunnels: tunnels }))),
    ));
    expect(calls.deleted).toHaveLength(2);
    expect(result.deleted).toBe(2);
  });
});
