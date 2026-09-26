import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { createVm, enrollVmTunnel } from "../services/vms/workflows";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import type { ProviderTunnel } from "../services/vms/drivers";

const CLIENT_KEY = Buffer.alloc(32, 1).toString("base64");
const teamNetwork = {
  id: "00000000-0000-4000-8000-000000000001",
  teamId: "team-1",
  provider: "freestyle" as const,
  providerNetworkId: "vpc-team",
  slug: "cmux-team-net-test",
  cidr: "10.20.0.0/24",
  cidrV6: "fd20::/64",
  createdByUserId: "user-1",
  createdAt: new Date(),
  updatedAt: new Date(),
};
const personalNetwork = {
  id: "00000000-0000-4000-8000-000000000002",
  userId: "user-1",
  provider: "freestyle" as const,
  providerNetworkId: "vpc-personal",
  slug: "cmux-net-personal",
  cidr: "10.30.0.0/24",
  cidrV6: "fd30::/64",
  createdAt: new Date(),
  updatedAt: new Date(),
};

function providerTunnel(overrides: Partial<ProviderTunnel> = {}): ProviderTunnel {
  return {
    id: "tun-1",
    clientConfig: "[Interface]\nPrivateKey =\n[Peer]\n",
    clientPublicKey: CLIENT_KEY,
    serverPublicKey: "server",
    endpointHost: "vpn.test",
    endpointPort: 51820,
    routes: [],
    addressV4: "10.30.0.2",
    addressV6: null,
    attachments: [{ networkId: personalNetwork.providerNetworkId, addressV4: "10.30.0.2", addressV6: null }],
    ...overrides,
  };
}

function baseGateway(calls: { readonly creates: Array<Record<string, unknown>>; readonly attaches: string[] }): VmProviderGatewayShape {
  return {
    create: (_provider, options) => Effect.sync(() => {
      calls.creates.push(options as unknown as Record<string, unknown>);
      return { provider: "freestyle", providerVmId: "provider-vm-1", status: "running", image: options.image, createdAt: Date.now() };
    }),
    destroy: () => Effect.void,
    exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
    openAttach: () => Effect.die("unused"),
    openSSH: () => Effect.die("unused"),
    revokeSSHIdentity: () => Effect.void,
    supportsPrivateNetworking: () => true,
    ensureNetwork: (_provider, options) => Effect.succeed({ id: options.slug.includes("team") ? "vpc-team" : personalNetwork.providerNetworkId, slug: options.slug, cidr: options.slug.includes("team") ? teamNetwork.cidr : personalNetwork.cidr, cidrV6: options.slug.includes("team") ? teamNetwork.cidrV6 : personalNetwork.cidrV6 }),
    createTunnel: () => Effect.succeed({ tunnel: providerTunnel(), created: true, rotated: false }),
    getTunnel: () => Effect.succeed(providerTunnel()),
    rotateTunnelKey: () => Effect.succeed(providerTunnel()),
    deleteTunnel: () => Effect.void,
    attachTunnelNetwork: (_provider, _tunnelId, networkId) => Effect.sync(() => {
      calls.attaches.push(networkId);
      return { networkId, addressV4: "10.20.0.2", addressV6: null };
    }),
    detachTunnelNetwork: () => Effect.void,
  };
}

function enrollmentRepo(calls: { inserts: number; attaches: string[] }): VmRepositoryShape {
  const tunnelRow = {
    id: "00000000-0000-4000-8000-000000000003",
    userId: "user-1",
    networkId: personalNetwork.id,
    accessGrantId: "00000000-0000-4000-8000-000000000004",
    provider: "freestyle" as const,
    providerTunnelId: "tun-1",
    deviceFingerprint: "device-1",
    tunnelPurpose: "browser" as const,
    deviceName: "Test Mac",
    clientPublicKey: CLIENT_KEY,
    addressV4: "10.30.0.2",
    addressV6: null,
    createdAt: new Date(),
    updatedAt: new Date(),
    lastConfigIssuedAt: new Date(),
    revokedAt: null,
  };
  return {
    findNetwork: () => Effect.succeed(personalNetwork),
    upsertNetwork: () => Effect.succeed(personalNetwork),
    findTeamNetwork: () => Effect.succeed(teamNetwork),
    upsertTeamNetwork: () => Effect.succeed(teamNetwork),
    listTeamNetworks: () => Effect.succeed([teamNetwork]),
    listTunnelTeamNetworks: () => Effect.succeed([]),
    insertTunnelTeamNetwork: (input: { tunnelId: string; teamNetworkId: string; addressV4?: string | null; addressV6?: string | null }) => Effect.sync(() => { calls.inserts += 1; return { ...input, attachedAt: new Date() } as never; }),
    deleteTunnelTeamNetwork: () => Effect.void,
    findAccessGrant: () => Effect.succeed({ id: tunnelRow.accessGrantId, userId: "user-1", deviceId: "device-1", reportedName: "Test Mac", displayName: null, modelIdentifier: null, osVersion: null, architecture: null, cmuxVersion: null, cmuxBuild: null, cmuxChannel: null, createdAt: new Date(), updatedAt: new Date(), lastControlPlaneAt: new Date(), mutationLeaseId: null, mutationLeaseExpiresAt: null, revokedAt: null }),
    findBlockingRevokedAccessGrant: () => Effect.succeed(null),
    upsertAccessGrant: () => Effect.succeed({ id: tunnelRow.accessGrantId, userId: "user-1", deviceId: "device-1", reportedName: "Test Mac", displayName: null, modelIdentifier: null, osVersion: null, architecture: null, cmuxVersion: null, cmuxBuild: null, cmuxChannel: null, createdAt: new Date(), updatedAt: new Date(), lastControlPlaneAt: new Date(), mutationLeaseId: null, mutationLeaseExpiresAt: null, revokedAt: null }),
    upsertAccessGrantSession: () => Effect.void,
    claimAccessGrantMutation: () => Effect.succeed(true),
    releaseAccessGrantMutation: () => Effect.void,
    findTunnel: () => Effect.succeed(null),
    insertTunnel: () => Effect.succeed(tunnelRow),
    updateTunnel: () => Effect.succeed(tunnelRow),
    revokeTunnel: () => Effect.succeed(true),
    listUserTunnels: () => Effect.succeed([tunnelRow]),
    listAccessGrantTunnels: () => Effect.succeed([tunnelRow]),
    listAccessGrantSessionIds: () => Effect.succeed([]),
    renameAccessGrant: () => Effect.succeed(null),
    listUserAccessGrants: () => Effect.succeed([]),
    revokeAccessGrant: () => Effect.succeed(true),
  } as unknown as VmRepositoryShape;
}

function createRepo(team: typeof teamNetwork | null = teamNetwork): VmRepositoryShape {
  const vm: CloudVmRow = {
    id: "00000000-0000-4000-8000-000000000010",
    userId: "user-1",
    ownerTeamId: "team-1",
    coderouterPoolId: null,
    billingTeamId: "team-1",
    billingPlanId: "free",
    provider: "freestyle",
    providerVmId: null,
    displayName: null,
    slug: "test-vm",
    imageId: "image",
    imageVersion: null,
    status: "provisioning",
    idempotencyKey: null,
    createdAt: new Date(),
    updatedAt: new Date(),
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
  };
  return {
    beginCreate: () => Effect.succeed({ inserted: true, vm }),
    markCreateRunning: (input: { providerVmId: string; providerMetadata?: Record<string, unknown> }) => Effect.succeed({ ...vm, status: "running", providerVmId: input.providerVmId, providerMetadata: input.providerMetadata ?? {} }),
    markCreateFailed: () => Effect.void,
    recordUsageEvents: () => Effect.void,
    recordUsageEvent: () => Effect.void,
    findNetwork: () => Effect.succeed(personalNetwork),
    upsertNetwork: () => Effect.succeed(personalNetwork),
    findTeamNetwork: () => Effect.succeed(team),
    upsertTeamNetwork: () => Effect.succeed(team ?? teamNetwork),
    listTeamNetworks: () => Effect.succeed(team ? [team] : []),
    listTunnelTeamNetworks: () => Effect.succeed([]),
    insertTunnelTeamNetwork: () => Effect.succeed({} as never),
    deleteTunnelTeamNetwork: () => Effect.void,
  } as unknown as VmRepositoryShape;
}

describe("team private network regression", () => {
  test("enrollment attaches once and returns home then team networks", async () => {
    const calls = { inserts: 0, attaches: [] as string[] };
    const gateway = baseGateway({ creates: [], attaches: calls.attaches });
    const result = await Effect.runPromise(enrollVmTunnel({ userId: "user-1", provider: "freestyle", deviceId: "device-1", deviceFingerprint: "device-1", tunnelPurpose: "browser", clientPublicKey: CLIENT_KEY, teamIds: ["team-1"] }).pipe(Effect.provide(Layer.mergeAll(Layer.succeed(VmRepository, enrollmentRepo(calls)), Layer.succeed(VmProviderGateway, gateway)))));
    expect(calls.attaches).toEqual([teamNetwork.providerNetworkId]);
    expect(calls.inserts).toBe(1);
    expect(result.networks[0]?.scope).toBe("user");
    expect(result.networks[1]).toMatchObject({ scope: "team", cidr: teamNetwork.cidr });
  });

  test("create uses team ingress only for capable multi-member teams", async () => {
    const creates: Array<Record<string, unknown>> = [];
    const calls = { creates, attaches: [] as string[] };
    const gateway = baseGateway(calls);
    const teamDirectory = { listMemberIds: async () => ["user-1", "user-2"] };
    const input = { userId: "user-1", billingCustomerType: "team" as const, billingTeamId: "team-1", billingPlanId: "free", maxActiveVms: 2, provider: "freestyle" as const, image: "image" };
    const run = (extra: Record<string, unknown> = {}, teamRow: typeof teamNetwork | null = null) => Effect.runPromise(createVm({ ...input, ...extra } as never).pipe(Effect.provide(Layer.mergeAll(Layer.succeed(VmRepository, createRepo(teamRow)), Layer.succeed(VmProviderGateway, gateway), Layer.succeed(VmBillingGateway, noOpVmBillingGateway())))));
    await run({ teamDirectory }, teamNetwork);
    expect(creates[0]?.network).toEqual({ id: "vpc-team", memberIngress: true });
    creates.length = 0;
    await run();
    expect(creates[0]?.network).toEqual({ id: personalNetwork.providerNetworkId, memberIngress: false });
    creates.length = 0;
    await run({ teamDirectory: { listMemberIds: async () => ["user-1"] } });
    expect(creates[0]?.network).toEqual({ id: personalNetwork.providerNetworkId, memberIngress: false });
  });
});
