import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmLimitExceededError } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { createVm, reconcileVmProviderStatuses } from "../services/vms/workflows";

type ObservedStatusUpdate = Parameters<VmRepositoryShape["markProviderObservedStatus"]>[0];
const FIXTURE_NOW = new Date("2026-01-01T00:00:00.000Z");

function row(overrides: Partial<CloudVmRow>): CloudVmRow {
  return {
    id: "00000000-0000-4000-8000-000000000101",
    userId: "user-limit-refresh",
    billingTeamId: "team-limit-refresh",
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: null,
    displayName: null,
    slug: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status: "provisioning",
    idempotencyKey: "limit-refresh",
    createdAt: FIXTURE_NOW,
    updatedAt: FIXTURE_NOW,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    ...overrides,
  };
}

// Regression: refreshActiveLimitProviderStatuses returned early for every
// non-Freestyle machine, so a stale `running` row on another provider blocked
// creates until the 10-minute cron even though that provider has a
// status read. The lazy refresh on limit-exceeded must reconcile every
// provider the gateway can report on, exactly like the cron path.
describe("lazy active-limit provider refresh", () => {
  test("does not fan out legacy provider reads on a successful create", async () => {
    const requested = row({ status: "provisioning", providerVmId: null });
    const running = row({ status: "running", providerVmId: "provider-vm-new" });
    let legacyCandidateCalls = 0;
    let statsCalls = 0;
    let beginReservation: unknown;
    const repo = {
      beginCreate: (input: { resourceReservation?: unknown }) => {
        beginReservation = input.resourceReservation;
        return Effect.succeed({ inserted: true, vm: requested });
      },
      legacyResourceReservationCandidates: () => Effect.sync(() => {
        legacyCandidateCalls += 1;
        return [];
      }),
      claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" as const }),
      markBillingGrantApplied: () => Effect.void,
      deleteBillingGrant: () => Effect.void,
      markCreateRunning: () => Effect.succeed(running),
      markCreateFailed: () => Effect.void,
      recordUsageEvent: () => Effect.void,
      recordUsageEvents: () => Effect.void,
      findNetwork: () => Effect.succeed(null),
      upsertNetwork: () => Effect.succeed({
        id: "network-row",
        userId: "user-limit-refresh",
        provider: "freestyle" as const,
        providerNetworkId: "network-1",
        slug: "cmux-net",
        cidr: "10.0.0.0/24",
        cidrV6: "fd00::/64",
        createdAt: FIXTURE_NOW,
        updatedAt: FIXTURE_NOW,
      }),
    } as unknown as VmRepositoryShape;
    const providers = {
      create: () => Effect.succeed({
        provider: "freestyle" as const,
        providerVmId: "provider-vm-new",
        status: "running" as const,
        image: "snapshot-test",
        createdAt: FIXTURE_NOW.getTime(),
      }),
      destroy: () => Effect.void,
      getStats: () => Effect.sync(() => {
        statsCalls += 1;
        return { state: "awake" as const, sampledAt: FIXTURE_NOW.getTime(), diskTotalMb: 65536 };
      }),
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      supportsPrivateNetworking: () => true,
      ensureNetwork: () => Effect.succeed({ id: "network-1", slug: "cmux-net", cidr: "10.0.0.0/24", cidrV6: "fd00::/64" }),
    } as unknown as VmProviderGatewayShape;
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, providers),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    );

    await Effect.runPromise(
      createVm({
        userId: requested.userId,
        billingCustomerType: "team",
        billingTeamId: requested.billingTeamId!,
        billingPlanId: "pro",
        maxActiveVms: 50,
        provider: "freestyle",
        image: "snapshot-test",
        imageSize: { name: "xl", cpu: 16, memoryMb: 32768, storageMb: 131072 },
      }).pipe(Effect.provide(layer)),
    );
    expect(legacyCandidateCalls).toBe(0);
    expect(statsCalls).toBe(0);
    expect(beginReservation).toEqual({ vcpus: 16, memoryMb: 32768, diskMb: 131072 });
  });

  test("keeps the baked image disk in a memory-sized paid reservation", async () => {
    const requested = row({
      id: "00000000-0000-4000-8000-000000000107",
      status: "provisioning",
      providerVmId: null,
    });
    const running = row({
      id: "00000000-0000-4000-8000-000000000108",
      status: "running",
      providerVmId: "provider-vm-memory-image",
    });
    let beginReservation: unknown;
    const repo = {
      beginCreate: (input: { resourceReservation?: unknown }) => {
        beginReservation = input.resourceReservation;
        return Effect.succeed({ inserted: true, vm: requested });
      },
      claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" as const }),
      markBillingGrantApplied: () => Effect.void,
      deleteBillingGrant: () => Effect.void,
      markCreateRunning: () => Effect.succeed(running),
      markCreateFailed: () => Effect.void,
      recordUsageEvent: () => Effect.void,
      recordUsageEvents: () => Effect.void,
      findNetwork: () => Effect.succeed(null),
      upsertNetwork: () => Effect.succeed({
        id: "network-row",
        userId: "user-limit-refresh",
        provider: "freestyle" as const,
        providerNetworkId: "network-1",
        slug: "cmux-net",
        cidr: "10.0.0.0/24",
        cidrV6: "fd00::/64",
        createdAt: FIXTURE_NOW,
        updatedAt: FIXTURE_NOW,
      }),
    } as unknown as VmRepositoryShape;
    const provider = {
      create: () => Effect.succeed({
        provider: "freestyle" as const,
        providerVmId: running.providerVmId!,
        status: "running" as const,
        image: "snapshot-test",
        createdAt: FIXTURE_NOW.getTime(),
      }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      supportsPrivateNetworking: () => true,
      ensureNetwork: () => Effect.succeed({ id: "network-1", slug: "cmux-net", cidr: "10.0.0.0/24", cidrV6: "fd00::/64" }),
    } as unknown as VmProviderGatewayShape;

    await Effect.runPromise(
      createVm({
        userId: requested.userId,
        billingCustomerType: "team",
        billingTeamId: requested.billingTeamId!,
        billingPlanId: "pro",
        maxActiveVms: 50,
        provider: "freestyle",
        image: "snapshot-test",
        memoryMb: 16 * 1024,
        imageSize: { name: "xl", cpu: 16, memoryMb: 32 * 1024, storageMb: 128 * 1024 },
      }).pipe(Effect.provide(Layer.mergeAll(
        Layer.succeed(VmRepository, repo),
        Layer.succeed(VmProviderGateway, provider),
        Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
      ))),
    );

    expect(beginReservation).toEqual({
      vcpus: 4,
      memoryMb: 16 * 1024,
      diskMb: 128 * 1024,
    });
  });

  test("refreshes stale rows for every provider with a status read, not just freestyle", async () => {
    const requested = row({ status: "provisioning", providerVmId: null });
    const running = row({
      id: "00000000-0000-4000-8000-000000000102",
      status: "running",
      providerVmId: "provider-vm-limit-refresh-new",
    });
    const staleE2b = row({
      id: "00000000-0000-4000-8000-000000000103",
      provider: "freestyle",
      providerVmId: "provider-vm-stale",
      status: "running",
    });
    const staleFreestyle = row({
      id: "00000000-0000-4000-8000-000000000104",
      provider: "freestyle",
      providerVmId: "provider-vm-stale-freestyle",
      status: "running",
    });
    const extraCandidates = Array.from({ length: 205 }, (_, index) => row({
      id: `extra-${index}`,
      providerVmId: `provider-vm-extra-${index}`,
      status: "running",
    }));

    let beginCreateCalls = 0;
    let candidateLimit: number | undefined;
    const observed: ObservedStatusUpdate[] = [];
    const statusCalls: Array<[string, string]> = [];

    const repo = {
      beginCreate: () => {
        beginCreateCalls += 1;
        return beginCreateCalls === 1
          ? Effect.fail(new VmLimitExceededError({
            kind: "active_vms",
            billingTeamId: "team-limit-refresh",
            limit: 5,
          }))
          : Effect.succeed({ inserted: true, vm: requested });
      },
      activeLimitCandidates: (input: { limit: number }) => {
        candidateLimit = input.limit;
        // Deliberately return more rows than the requested limit. The workflow
        // keeps its own cap so alternate repository implementations cannot make
        // the synchronous retry unbounded.
        return Effect.succeed([staleE2b, staleFreestyle, ...extraCandidates]);
      },
      markProviderObservedStatus: (update: ObservedStatusUpdate) => {
        observed.push(update);
        return Effect.succeed(true);
      },
      claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" as const }),
      markBillingGrantApplied: () => Effect.void,
      deleteBillingGrant: () => Effect.void,
      markCreateRunning: () => Effect.succeed(running),
      markCreateFailed: () => Effect.void,
      recordUsageEvent: () => Effect.void,
      recordUsageEvents: () => Effect.void,
      findNetwork: () => Effect.succeed(null),
      upsertNetwork: (network: Parameters<NonNullable<VmRepositoryShape["upsertNetwork"]>>[0]) => Effect.succeed({
        id: "00000000-0000-4000-8000-00000000c10d",
        userId: network.userId,
        provider: network.provider,
        providerNetworkId: network.providerNetworkId,
        slug: network.slug ?? null,
        cidr: network.cidr ?? null,
        cidrV6: network.cidrV6 ?? null,
        createdAt: FIXTURE_NOW,
        updatedAt: FIXTURE_NOW,
      }),
    } as unknown as VmRepositoryShape;

    const providers = {
      create: () => Effect.succeed({
        provider: "freestyle" as const,
        providerVmId: "provider-vm-limit-refresh-new",
        status: "running" as const,
        image: "snapshot-test",
        createdAt: FIXTURE_NOW.getTime(),
      }),
      destroy: () => Effect.void,
      getStatus: (provider: string, vmId: string) => {
        statusCalls.push([provider, vmId]);
        return Effect.succeed("destroyed" as const);
      },
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      supportsPrivateNetworking: () => true,
      ensureNetwork: (_provider: string, options: { slug: string }) => Effect.succeed({
        id: `network-${options.slug}`,
        slug: options.slug,
        cidr: "10.40.0.0/24",
        cidrV6: "fd00:40::/64",
      }),
    } as unknown as VmProviderGatewayShape;

    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, providers),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    );

    const created = await Effect.runPromise(
      createVm({
        userId: "user-limit-refresh",
        billingCustomerType: "team",
        billingTeamId: "team-limit-refresh",
        billingPlanId: "pro",
        maxActiveVms: 5,
        provider: "freestyle",
        image: "snapshot-test",
      }).pipe(Effect.provide(layer)),
    );

    expect(created.providerVmId).toBe("provider-vm-limit-refresh-new");
    expect(beginCreateCalls).toBe(2);
    expect(candidateLimit).toBe(200);
    expect(statusCalls).toHaveLength(200);
    // The refresh must probe BOTH stale rows; before the fix it skipped non-freestyle.
    expect(statusCalls).toContainEqual(["freestyle", "provider-vm-stale"]);
    expect(statusCalls).toContainEqual(["freestyle", "provider-vm-stale-freestyle"]);
    // And must durably record what the provider said so the recount can pass.
    const observedIds = observed.map((u) => u.providerVmId).sort();
    expect(observedIds).toContain("provider-vm-stale");
    expect(observedIds).toContain("provider-vm-stale-freestyle");
    expect(observedIds).toHaveLength(200);
    expect(new Set(observed.map((u) => u.status))).toEqual(new Set(["destroyed"]));
  });

});
