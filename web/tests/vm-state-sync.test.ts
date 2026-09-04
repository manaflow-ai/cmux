import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import type { VMInventory } from "../services/vms/drivers";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { VmProviderOperationError } from "../services/vms/errors";
import {
  getVm,
  reconcileVmProviderStatuses,
  renameVm,
} from "../services/vms/workflows";

const NOW = new Date("2026-09-04T00:00:00.000Z");

function vmRow(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "00000000-0000-4000-8000-00000000sync",
    userId: "user-sync",
    billingTeamId: "team-sync",
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: "provider-vm-sync",
    displayName: null,
    slug: "bright-blue-otter",
    imageId: "snapshot-sync",
    imageVersion: null,
    status: "running",
    idempotencyKey: null,
    createdAt: NOW,
    updatedAt: NOW,
    providerStatusObservedAt: null,
    providerStatusCheckedAt: null,
    providerStatusProbeToken: null,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    ...overrides,
  };
}

function layer(repo: VmRepositoryShape, provider: VmProviderGatewayShape) {
  return Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, provider),
  );
}

function baseRepo(vm: CloudVmRow): VmRepositoryShape {
  return {
    listUserVms: () => Effect.succeed([]),
    findUserVm: () => Effect.succeed(vm),
    setDisplayName: () => Effect.succeed(true),
    claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
    markBillingGrantApplied: () => Effect.void,
    deleteBillingGrant: () => Effect.void,
    beginCreate: () => Effect.die("unused"),
    beginBaseOpen: () => Effect.die("unused"),
    beginBaseReset: () => Effect.die("unused"),
    markBaseCreateRunning: () => Effect.die("unused"),
    markBaseCreateFailed: () => Effect.die("unused"),
    activeLimitCandidates: () => Effect.succeed([]),
    reservePausedResume: () => Effect.succeed(null),
    reconciliationCandidates: () => Effect.succeed([]),
    markProviderObservedStatus: () => Effect.succeed(true),
    markCreateRunning: () => Effect.die("unused"),
    markCreateFailed: () => Effect.die("unused"),
    hasOwnedSnapshot: () => Effect.succeed(false),
    markDestroyed: () => Effect.void,
    recordLease: () => Effect.void,
    accountDeletionIdentityLeases: () => Effect.succeed([]),
    listVmSessions: () => Effect.succeed([]),
    upsertVmSession: () => Effect.die("unused"),
    activeIdentityLeases: () => Effect.succeed([]),
    markLeasesRevoked: () => Effect.void,
    recentReaperReportKeys: () => Effect.succeed([]),
    recordUsageEvent: () => Effect.void,
    recordUsageEvents: () => Effect.void,
  } as unknown as VmRepositoryShape;
}

function providerBase(): VmProviderGatewayShape {
  return {
    create: () => Effect.die("unused"),
    destroy: () => Effect.void,
    exec: () => Effect.die("unused"),
    openAttach: () => Effect.die("unused"),
    openSSH: () => Effect.die("unused"),
    revokeSSHIdentity: () => Effect.void,
  } as unknown as VmProviderGatewayShape;
}

describe("Cloud VM provider state synchronization", () => {
  test("records an unchanged provider observation and fences its response", async () => {
    const vm = vmRow();
    const observations: Array<Record<string, unknown>> = [];
    let statusCalls = 0;
    const repo = {
      ...baseRepo(vm),
      claimProviderStatusProbe: ({ token }: { token: string }) => Effect.succeed(token.length > 0),
      releaseProviderStatusProbe: () => Effect.void,
      markProviderObservedStatus: (observation: Record<string, unknown>) =>
        Effect.sync(() => {
          observations.push(observation);
          return true;
        }),
    } as unknown as VmRepositoryShape;
    const provider = {
      ...providerBase(),
      getStatus: () => Effect.sync(() => {
        statusCalls += 1;
        return "running" as const;
      }),
    } as VmProviderGatewayShape;

    const result = await Effect.runPromise(
      getVm({ userId: vm.userId, teamIds: [vm.billingTeamId!], providerVmId: vm.providerVmId! })
        .pipe(Effect.provide(layer(repo, provider))),
    );

    expect(result.status).toBe("running");
    expect(statusCalls).toBe(1);
    expect(observations).toHaveLength(1);
    expect(observations[0]?.status).toBe("running");
    expect(typeof observations[0]?.probeToken).toBe("string");
    expect(observations[0]?.observedAt).toBeInstanceOf(Date);
  });

  test("does not call the provider when another probe owns the fence", async () => {
    const vm = vmRow();
    let statusCalls = 0;
    const repo = {
      ...baseRepo(vm),
      claimProviderStatusProbe: () => Effect.succeed(false),
    } as unknown as VmRepositoryShape;
    const provider = {
      ...providerBase(),
      getStatus: () => Effect.sync(() => {
        statusCalls += 1;
        return "paused" as const;
      }),
    } as VmProviderGatewayShape;

    const result = await Effect.runPromise(
      getVm({ userId: vm.userId, teamIds: [vm.billingTeamId!], providerVmId: vm.providerVmId! })
        .pipe(Effect.provide(layer(repo, provider))),
    );

    expect(result.status).toBe("running");
    expect(statusCalls).toBe(0);
  });

  test("rejects a slower provider response after a newer probe claims the row", async () => {
    const vm = vmRow({ status: "paused" });
    let currentVm = vm;
    const observations: Array<{ status?: string; probeToken?: string; observedAt?: Date }> = [];
    let activeToken: string | null = null;
    let statusCalls = 0;
    let firstStarted!: () => void;
    let releaseFirst!: () => void;
    const firstStartedPromise = new Promise<void>((resolve) => { firstStarted = resolve; });
    const firstReleasePromise = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const repo = {
      ...baseRepo(vm),
      findUserVm: () => Effect.succeed(currentVm),
      claimProviderStatusProbe: ({ token }: { token: string }) => Effect.sync(() => {
        activeToken = token;
        return true;
      }),
      releaseProviderStatusProbe: () => Effect.void,
      markProviderObservedStatus: (observation: { status?: string; probeToken?: string; observedAt?: Date }) =>
        Effect.sync(() => {
          if (observation.probeToken !== activeToken) return false;
          observations.push(observation);
          currentVm = {
            ...currentVm,
            status: observation.status as CloudVmRow["status"],
            providerStatusObservedAt: observation.observedAt as Date,
            providerStatusCheckedAt: observation.observedAt as Date,
          };
          return true;
        }),
    } as unknown as VmRepositoryShape;
    const provider = {
      ...providerBase(),
      getStatus: () => Effect.promise(async () => {
        statusCalls += 1;
        if (statusCalls === 1) {
          firstStarted();
          await firstReleasePromise;
          return "paused" as const;
        }
        return "running" as const;
      }),
    } as VmProviderGatewayShape;
    const input = { userId: vm.userId, teamIds: [vm.billingTeamId!], providerVmId: vm.providerVmId! };

    const first = Effect.runPromise(getVm(input).pipe(Effect.provide(layer(repo, provider))));
    await firstStartedPromise;
    const second = await Effect.runPromise(getVm(input).pipe(Effect.provide(layer(repo, provider))));
    releaseFirst();
    const firstResult = await first;

    expect(statusCalls).toBe(2);
    expect(second.status).toBe("running");
    expect(firstResult.status).toBe("running");
    expect(observations).toHaveLength(1);
    expect(observations[0]?.status).toBe("running");
  });

  test("persists the database rename and attempts the provider cosmetic sync", async () => {
    const vm = vmRow();
    const databaseNames: (string | null)[] = [];
    const providerNames: (string | null)[] = [];
    const repo = {
      ...baseRepo(vm),
      setDisplayName: ({ displayName }: { displayName: string | null }) =>
        Effect.sync(() => {
          databaseNames.push(displayName);
          return true;
        }),
    } as unknown as VmRepositoryShape;
    const provider = {
      ...providerBase(),
      updateDisplayName: (_provider: "freestyle", _id: string, displayName: string | null) =>
        Effect.sync(() => {
          providerNames.push(displayName);
        }),
    } as VmProviderGatewayShape;

    const result = await Effect.runPromise(
      renameVm({
        userId: vm.userId,
        teamIds: [vm.billingTeamId!],
        providerVmId: vm.providerVmId!,
        displayName: "My build box",
      }).pipe(Effect.provide(layer(repo, provider))),
    );

    expect(result.displayName).toBe("My build box");
    expect(databaseNames).toEqual(["My build box"]);
    expect(providerNames).toEqual(["My build box"]);
  });

  test("restores the stable slug on the provider when the human label is cleared", async () => {
    const vm = vmRow({ displayName: "Old label" });
    const providerNames: (string | null)[] = [];
    const repo = {
      ...baseRepo(vm),
      setDisplayName: () => Effect.succeed(true),
    } as unknown as VmRepositoryShape;
    const provider = {
      ...providerBase(),
      updateDisplayName: (_provider: "freestyle", _id: string, displayName: string | null) =>
        Effect.sync(() => {
          providerNames.push(displayName);
        }),
    } as VmProviderGatewayShape;

    await Effect.runPromise(
      renameVm({
        userId: vm.userId,
        teamIds: [vm.billingTeamId!],
        providerVmId: vm.providerVmId!,
        displayName: null,
      }).pipe(Effect.provide(layer(repo, provider))),
    );

    expect(providerNames).toEqual([vm.slug]);
  });

  test("repairs a provider label drift with bounded retries", async () => {
    const vm = vmRow({ displayName: "My build box" });
    let updateCalls = 0;
    const repo = {
      ...baseRepo(vm),
      listProviderVmReferences: () => Effect.succeed({
        rows: [{
          provider: "freestyle",
          providerVmId: vm.providerVmId!,
          displayName: vm.displayName,
          slug: vm.slug,
        }],
        complete: true,
      }),
    } as unknown as VmRepositoryShape;
    const provider = {
      ...providerBase(),
      listVms: () => Effect.succeed({
        vms: [{
          providerVmId: vm.providerVmId!,
          status: "running" as const,
          slug: vm.slug,
          displayName: "Old label",
          createdAt: NOW.getTime(),
        }],
        totalCount: 1,
        complete: true,
        nextOffset: null,
      } satisfies VMInventory),
      updateDisplayName: () => Effect.suspend(() => {
        updateCalls += 1;
        return updateCalls < 3
          ? Effect.fail(new VmProviderOperationError({
            provider: "freestyle",
            operation: "updateDisplayName",
            cause: new Error("temporary provider outage"),
          }))
          : Effect.void;
      }),
    } as VmProviderGatewayShape;

    const result = await Effect.runPromise(
      reconcileVmProviderStatuses().pipe(Effect.provide(layer(repo, provider))),
    );

    expect(updateCalls).toBe(3);
    expect(result.inventory?.[0]?.displayNameDriftProviderVmIds).toBeUndefined();
  });

  test("reports provider and database inventory drift without mutating either side", async () => {
    const vm = vmRow();
    const inventory: VMInventory = {
      vms: [
        { providerVmId: "provider-vm-sync", status: "running", slug: vm.slug, displayName: vm.slug, createdAt: NOW.getTime() },
        { providerVmId: "provider-vm-orphan", status: "paused", slug: "orphan-slug", displayName: null, createdAt: NOW.getTime() },
      ],
      totalCount: 2,
      complete: true,
      nextOffset: null,
    };
    const repo = {
      ...baseRepo(vm),
      listProviderVmReferences: () => Effect.succeed({
        rows: [
          { provider: "freestyle", providerVmId: vm.providerVmId!, displayName: null, slug: vm.slug },
          { provider: "freestyle", providerVmId: "provider-vm-missing", displayName: null, slug: "missing-slug" },
        ],
        complete: true,
      }),
    } as unknown as VmRepositoryShape;
    const provider = {
      ...providerBase(),
      listVms: () => Effect.succeed(inventory),
    } as VmProviderGatewayShape;

    const result = await Effect.runPromise(
      reconcileVmProviderStatuses().pipe(Effect.provide(layer(repo, provider))),
    );

    expect(result.inventory).toEqual([{
      provider: "freestyle",
      scanned: 2,
      unknownProviderVmIds: ["provider-vm-orphan"],
      missingProviderVmIds: ["provider-vm-missing"],
      providerComplete: true,
      databaseComplete: true,
    }]);
  });

  test("does not report missing rows from a partial provider page", async () => {
    const vm = vmRow();
    const repo = {
      ...baseRepo(vm),
      listProviderVmReferences: () => Effect.succeed({
        rows: [{ provider: "freestyle", providerVmId: "provider-vm-missing", displayName: null, slug: "missing-slug" }],
        complete: true,
      }),
    } as unknown as VmRepositoryShape;
    const provider = {
      ...providerBase(),
      listVms: () => Effect.succeed({
        vms: [{ providerVmId: "provider-vm-page", status: "running", slug: null, displayName: null, createdAt: null }],
        totalCount: 2,
        complete: false,
        nextOffset: 1,
      } satisfies VMInventory),
    } as VmProviderGatewayShape;

    const result = await Effect.runPromise(
      reconcileVmProviderStatuses({ limit: 1 }).pipe(Effect.provide(layer(repo, provider))),
    );

    expect(result.inventory?.[0]?.missingProviderVmIds).toEqual([]);
    expect(result.inventory?.[0]?.providerComplete).toBe(false);
  });
});
