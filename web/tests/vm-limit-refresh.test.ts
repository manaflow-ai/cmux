import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmLimitExceededError, VmSharedResourceLimitExceededError } from "../services/vms/errors";
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

  test("repairs scoped legacy resource claims before retrying a shared-pool create", async () => {
    const requested = row({
      id: "00000000-0000-4000-8000-000000000109",
      status: "provisioning",
      providerVmId: null,
    });
    const legacy = row({
      id: "00000000-0000-4000-8000-000000000110",
      status: "running",
      providerVmId: "provider-vm-legacy-resource-repair",
      providerMetadata: {},
    });
    const staleValid = row({
      id: "00000000-0000-4000-8000-000000000111",
      status: "running",
      providerVmId: "provider-vm-stale-valid-resource",
      providerMetadata: {
        cmuxResourceReservation: { vcpus: 1, memoryMb: 4096, diskMb: 32768 },
      },
    });
    let beginCalls = 0;
    let candidateInput: { userId?: string; billingTeamId?: string | null; limit: number } | undefined;
    let statsCalls = 0;
    let statusCalls = 0;
    const reservations: unknown[] = [];
    const repo = {
      beginCreate: () => {
        beginCalls += 1;
        return beginCalls === 1
          ? Effect.fail(new VmSharedResourceLimitExceededError({
            kind: "shared_resources",
            billingTeamId: requested.billingTeamId!,
            phase: "create",
            resource: "diskMb",
            used: 200 * 1024,
            requested: 32 * 1024,
            limit: 200 * 1024,
          }))
          : Effect.succeed({ inserted: true, vm: requested });
      },
      legacyResourceReservationCandidates: (input: typeof candidateInput) => Effect.sync(() => {
        candidateInput = input;
        return [legacy];
      }),
      activeLimitCandidates: () => Effect.succeed([staleValid]),
      markProviderObservedStatus: () => Effect.sync(() => {
        statusCalls += 1;
        return true;
      }),
      setResourceReservation: (input: unknown) => Effect.sync(() => {
        reservations.push(input);
        return true;
      }),
      claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" as const }),
      markBillingGrantApplied: () => Effect.void,
      deleteBillingGrant: () => Effect.void,
      markCreateRunning: () => Effect.succeed({
        ...requested,
        status: "running" as const,
        providerVmId: "provider-vm-new-after-repair",
      }),
      markCreateFailed: () => Effect.void,
      recordUsageEvent: () => Effect.void,
      recordUsageEvents: () => Effect.void,
      findNetwork: () => Effect.succeed(null),
      upsertNetwork: () => Effect.succeed({
        id: "network-row",
        userId: requested.userId,
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
        providerVmId: "provider-vm-new-after-repair",
        status: "running" as const,
        image: "snapshot-test",
        createdAt: FIXTURE_NOW.getTime(),
      }),
      destroy: () => Effect.void,
      getStats: (_provider: string, providerVmId: string) => {
        expect(providerVmId).toBe(legacy.providerVmId);
        statsCalls += 1;
        return Effect.succeed({
          state: "awake" as const,
          sampledAt: FIXTURE_NOW.getTime(),
          cpus: 2,
          memoryTotalMb: 8192,
          diskTotalMb: 65536,
        });
      },
      getStatus: (_provider: string, providerVmId: string) => {
        expect(providerVmId).toBe(staleValid.providerVmId);
        return Effect.succeed("destroyed" as const);
      },
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
        // A large team allowance must not turn the request-path repair into
        // one provider call per VM. The remaining rows stay for the cron pass.
        maxActiveVms: 5000,
        provider: "freestyle",
        image: "snapshot-test",
      }).pipe(Effect.provide(Layer.mergeAll(
        Layer.succeed(VmRepository, repo),
        Layer.succeed(VmProviderGateway, providers),
        Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
      ))),
    );

    expect(beginCalls).toBe(2);
    expect(candidateInput).toEqual({
      userId: requested.userId,
      billingTeamId: requested.billingTeamId,
      limit: 5,
    });
    expect(statsCalls).toBe(1);
    expect(statusCalls).toBe(1);
    expect(reservations).toEqual([{
      id: legacy.id,
      reservation: { vcpus: 2, memoryMb: 8192, diskMb: 65536 },
    }]);
  });

  test("returns an impossible shared-pool request without a provider refresh", async () => {
    let beginCalls = 0;
    let statusCalls = 0;
    let candidateCalls = 0;
    const requested = row({ status: "provisioning", providerVmId: null });
    const repo = {
      beginCreate: () => {
        beginCalls += 1;
        return Effect.fail(new VmSharedResourceLimitExceededError({
          kind: "shared_resources",
          billingTeamId: requested.billingTeamId!,
          phase: "create",
          resource: "memoryMb",
          used: 0,
          requested: 24 * 1024,
          limit: 20 * 1024,
        }));
      },
      activeLimitCandidates: () => Effect.sync(() => {
        statusCalls += 1;
        return [];
      }),
      legacyResourceReservationCandidates: () => Effect.sync(() => {
        candidateCalls += 1;
        return [];
      }),
    } as unknown as VmRepositoryShape;
    const providers = {
      getStatus: () => Effect.sync(() => {
        statusCalls += 1;
        return "running" as const;
      }),
      getStats: () => Effect.sync(() => {
        statusCalls += 1;
        return { state: "awake" as const, sampledAt: FIXTURE_NOW.getTime(), diskTotalMb: 65536 };
      }),
    } as unknown as VmProviderGatewayShape;

    const result = await Effect.runPromise(
      createVm({
        userId: requested.userId,
        billingCustomerType: "team",
        billingTeamId: requested.billingTeamId!,
        billingPlanId: "pro",
        maxActiveVms: 50,
        provider: "freestyle",
        image: "snapshot-test",
      }).pipe(
        Effect.provide(Layer.mergeAll(
          Layer.succeed(VmRepository, repo),
          Layer.succeed(VmProviderGateway, providers),
          Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
        )),
        Effect.flip,
      ),
    );

    expect(result).toMatchObject({
      _tag: "VmSharedResourceLimitExceededError",
      requested: 24 * 1024,
      limit: 20 * 1024,
    });
    expect(beginCalls).toBe(1);
    expect(statusCalls).toBe(0);
    expect(candidateCalls).toBe(0);
  });
});

describe("background resource reconciliation", () => {
  test("uses a global bounded batch instead of a request owner scope", async () => {
    const legacy = row({
      id: "00000000-0000-4000-8000-000000000106",
      status: "running",
      providerVmId: "provider-vm-background-legacy",
      providerMetadata: {},
    });
    let candidateInput: { userId?: string; billingTeamId?: string | null; limit: number } | undefined;
    const reservations: Array<{ id: string; reservation: { vcpus: number; memoryMb: number; diskMb: number } }> = [];
    const repo = {
      legacyResourceReservationCandidates: (input: typeof candidateInput) =>
        Effect.sync(() => {
          candidateInput = input;
          return [legacy];
        }),
      setResourceReservation: (input: typeof reservations[number]) =>
        Effect.sync(() => {
          reservations.push(input);
          return true;
        }),
      reconciliationCandidates: () => Effect.succeed([]),
    } as unknown as VmRepositoryShape;
    const provider = {
      getStatus: () => Effect.succeed("running" as const),
      getStats: () => Effect.succeed({
        state: "awake" as const,
        sampledAt: FIXTURE_NOW.getTime(),
        diskTotalMb: 65536,
      }),
    } as unknown as VmProviderGatewayShape;

    await Effect.runPromise(
      reconcileVmProviderStatuses().pipe(
        Effect.provide(Layer.mergeAll(
          Layer.succeed(VmRepository, repo),
          Layer.succeed(VmProviderGateway, provider),
        )),
      ),
    );

    expect(candidateInput).toEqual({ limit: 50 });
    expect(reservations).toEqual([{
      id: legacy.id,
      reservation: { vcpus: 5, memoryMb: 20 * 1024, diskMb: 65536 },
    }]);
  });

  test("rotates past legacy providers that fail instead of starving newer rows", async () => {
    const failed = Array.from({ length: 50 }, (_, index) => row({
      id: `legacy-failed-${index}`,
      providerVmId: `provider-vm-failed-${index}`,
      status: "running",
      providerMetadata: {},
    }));
    const newer = row({
      id: "legacy-newer",
      providerVmId: "provider-vm-newer",
      status: "running",
      providerMetadata: {},
    });
    const deferred: string[] = [];
    const reservations: string[] = [];
    let candidateCalls = 0;
    const repo = {
      legacyResourceReservationCandidates: () => Effect.sync(() => {
        candidateCalls += 1;
        return [...failed, newer].filter((candidate) => !deferred.includes(candidate.id)).slice(0, 50);
      }),
      deferResourceReservation: (input: { id: string }) => Effect.sync(() => {
        deferred.push(input.id);
      }),
      setResourceReservation: (input: { id: string }) => Effect.sync(() => {
        reservations.push(input.id);
        return true;
      }),
      reconciliationCandidates: () => Effect.succeed([]),
    } as unknown as VmRepositoryShape;
    const provider = {
      getStats: (_provider: string, providerVmId: string) => failed.some(
        (candidate) => candidate.providerVmId === providerVmId,
      )
        ? Effect.fail(new Error("provider unavailable"))
        : Effect.succeed({
          state: "awake" as const,
          sampledAt: FIXTURE_NOW.getTime(),
          cpus: 5,
          memoryTotalMb: 20 * 1024,
          diskTotalMb: 32768,
        }),
      getStatus: () => Effect.succeed("running" as const),
    } as unknown as VmProviderGatewayShape;
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, provider),
    );

    await Effect.runPromise(reconcileVmProviderStatuses().pipe(Effect.provide(layer)));
    await Effect.runPromise(reconcileVmProviderStatuses().pipe(Effect.provide(layer)));

    expect(candidateCalls).toBe(2);
    expect(deferred).toHaveLength(50);
    expect(reservations).toEqual([newer.id]);
  });

  test("times out a hung legacy provider stats read and defers the row", async () => {
    const legacy = row({
      id: "legacy-hung",
      providerVmId: "provider-vm-hung",
      status: "running",
      providerMetadata: {},
    });
    const deferred: string[] = [];
    const repo = {
      legacyResourceReservationCandidates: () => Effect.succeed([legacy]),
      deferResourceReservation: (input: { id: string }) => Effect.sync(() => {
        deferred.push(input.id);
      }),
      setResourceReservation: () => Effect.succeed(true),
      reconciliationCandidates: () => Effect.succeed([]),
    } as unknown as VmRepositoryShape;
    const provider = {
      getStats: () => Effect.never,
      getStatus: () => Effect.succeed("running" as const),
    } as unknown as VmProviderGatewayShape;

    await Effect.runPromise(
      reconcileVmProviderStatuses().pipe(
        Effect.provide(Layer.mergeAll(
          Layer.succeed(VmRepository, repo),
          Layer.succeed(VmProviderGateway, provider),
        )),
      ),
    );

    expect(deferred).toEqual([legacy.id]);
  });
});
