import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import type { ProviderId, VMVolume } from "../services/vms/drivers";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import {
  VmRepository,
  type CloudVmRow,
  type VmRepositoryShape,
} from "../services/vms/repository";
import { VmProviderOperationError } from "../services/vms/errors";
import { reapVmResources } from "../services/vms/workflows";
import type { VmReaperOptions } from "../services/vms/reaper";

const NOW = new Date("2026-08-31T20:00:00.000Z");

function workflowLayer(repo: VmRepositoryShape, provider: VmProviderGatewayShape) {
  return Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, provider),
  );
}

function baseProvider(): VmProviderGatewayShape {
  return {
    create: () => Effect.die("unused"),
    destroy: () => Effect.void,
    exec: () => Effect.die("unused"),
    openAttach: () => Effect.die("unused"),
    openSSH: () => Effect.die("unused"),
    revokeSSHIdentity: () => Effect.void,
  } as unknown as VmProviderGatewayShape;
}

function baseRepository(): VmRepositoryShape {
  return {
    listUserVms: () => Effect.succeed([]),
    claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
    markBillingGrantApplied: () => Effect.void,
    deleteBillingGrant: () => Effect.void,
    beginCreate: () => Effect.die("unused"),
    beginBaseOpen: () => Effect.die("unused"),
    beginBaseReset: () => Effect.die("unused"),
    markBaseCreateRunning: () => Effect.die("unused"),
    markBaseCreateFailed: () => Effect.void,
    activeLimitCandidates: () => Effect.succeed([]),
    reservePausedResume: () => Effect.die("unused"),
    reconciliationCandidates: () => Effect.succeed([]),
    markProviderObservedStatus: () => Effect.succeed(true),
    setDisplayName: () => Effect.succeed(true),
    markCreateRunning: () => Effect.die("unused"),
    markCreateFailed: () => Effect.void,
    hasOwnedSnapshot: () => Effect.succeed(false),
    findUserVm: () => Effect.succeed(null),
    markDestroyed: () => Effect.void,
    recordLease: () => Effect.void,
    accountDeletionIdentityLeases: () => Effect.succeed([]),
    listVmSessions: () => Effect.succeed([]),
    upsertVmSession: () => Effect.die("unused"),
    activeIdentityLeases: () => Effect.succeed([]),
    markLeasesRevoked: () => Effect.void,
    recordUsageEvent: () => Effect.void,
    recordUsageEvents: () => Effect.void,
  } as unknown as VmRepositoryShape;
}

function repository(overrides: Partial<VmRepositoryShape> = {}): VmRepositoryShape {
  return { ...baseRepository(), ...overrides };
}

type ReaperObservation = {
  readonly volumeName: string;
  readonly firstObservedAt: Date;
};

type ReaperRepositoryExtensions = {
  readonly listOrphanVolumeObservations: (input: {
    readonly provider: ProviderId;
    readonly volumeNames: readonly string[];
  }) => Effect.Effect<readonly ReaperObservation[], never>;
  readonly recordOrphanVolumeObservation: (input: {
    readonly provider: ProviderId;
    readonly volumeName: string;
    readonly observedAt: Date;
  }) => Effect.Effect<void, never>;
};

function withObservations(
  repo: VmRepositoryShape,
  observations: Map<string, Date> = new Map(),
): VmRepositoryShape {
  const extended = repo as VmRepositoryShape & ReaperRepositoryExtensions;
  extended.listOrphanVolumeObservations = ({ volumeNames }) => Effect.succeed(
    volumeNames.flatMap((volumeName) => {
      const firstObservedAt = observations.get(volumeName);
      return firstObservedAt ? [{ volumeName, firstObservedAt }] : [];
    }),
  );
  extended.recordOrphanVolumeObservation = ({ volumeName, observedAt }) => Effect.sync(() => {
    if (!observations.has(volumeName)) observations.set(volumeName, observedAt);
  });
  return extended;
}

function oldVolume(name: string, ageMs = 3 * 60 * 60 * 1000): VMVolume {
  return {
    name,
    createdAt: NOW.getTime() - ageMs,
    attachedTo: null,
  };
}

function vmRow(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "00000000-0000-4000-8000-000000000001",
    userId: "user-reaper",
    billingTeamId: "team-reaper",
    billingPlanId: "pro",
    provider: "blaxel",
    providerVmId: "noble-wren",
    displayName: null,
    imageId: "blaxel/base-image:latest",
    imageVersion: null,
    status: "provisioning",
    idempotencyKey: "reaper-key",
    createdAt: new Date(NOW.getTime() - 2 * 60 * 60 * 1000),
    updatedAt: new Date(NOW.getTime() - 2 * 60 * 60 * 1000),
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    ...overrides,
  };
}

function missingProviderError(vmId: string): VmProviderOperationError {
  return new VmProviderOperationError({
    provider: "blaxel",
    operation: "getStatus",
    cause: new Error(`sandbox ${vmId} -> 404 not found`),
  });
}

describe("Cloud VM reaper", () => {
  test("filters shared/user volumes and reports an unattached machine volume without deleting", async () => {
    const deleted: string[] = [];
    const usage: Array<Record<string, unknown>> = [];
    const observations = new Map<string, Date>();
    const volumes: VMVolume[] = [
      { name: "cmux-home-abcdef123456", createdAt: 1, attachedTo: null },
      { name: "cmux-home-abcdef123456-noble-wren", createdAt: 2, attachedTo: null },
      { name: "cmux-home-abcdef123456-bold-fox", createdAt: 3, attachedTo: "sandbox:bold-fox" },
      { name: "user-home-noble-wren", createdAt: 4, attachedTo: null },
    ];
    const repo = withObservations(repository({
      listLiveHomeVolumeNames: () => Effect.succeed([]),
      stuckProvisioningCandidates: () => Effect.succeed([]),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    }), observations);
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed(volumes),
      deleteHomeVolume: (_provider: ProviderId, name: string) => Effect.sync(() => deleted.push(name)),
    };

    const result = await Effect.runPromise(
      reapVmResources({ now: NOW, deleteVolumes: false }).pipe(
        Effect.provide(workflowLayer(repo, provider)),
      ),
    );

    expect(result.reportOnly).toBe(true);
    expect(result.orphanVolumes.candidates).toBe(1);
    expect(result.orphanVolumes.reported).toBe(1);
    expect(result.orphanVolumes.skipped).toBe(1);
    expect(deleted).toEqual([]);
    expect(usage).toHaveLength(1);
    expect(usage[0]).toMatchObject({
      eventType: "vm.reaper.orphan_volume",
      metadata: {
        volumeName: "cmux-home-abcdef123456-noble-wren",
        mode: "report",
      },
    });
  });

  test("deletes only a free machine-owned volume when delete mode is enabled", async () => {
    const deleted: string[] = [];
    const name = "cmux-home-abcdef123456-noble-wren";
    const observations = new Map([[name, new Date(NOW.getTime() - 60 * 60 * 1000)]]);
    const repo = withObservations(repository({
      listLiveHomeVolumeNames: () => Effect.succeed([]),
      stuckProvisioningCandidates: () => Effect.succeed([]),
    }), observations);
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([oldVolume(name)]),
      deleteHomeVolume: (_provider: ProviderId, name: string) => Effect.sync(() => deleted.push(name)),
    };

    const result = await Effect.runPromise(
      reapVmResources({ now: NOW, deleteVolumes: true }).pipe(
        Effect.provide(workflowLayer(repo, provider)),
      ),
    );

    expect(result.reportOnly).toBe(false);
    expect(result.orphanVolumes.deleted).toBe(1);
    expect(deleted).toEqual(["cmux-home-abcdef123456-noble-wren"]);
  });

  test("skips a machine volume referenced by a live VM row", async () => {
    const deleted: string[] = [];
    const repo = withObservations(repository({
      listLiveHomeVolumeNames: () => Effect.succeed(["cmux-home-abcdef123456-noble-wren"]),
      stuckProvisioningCandidates: () => Effect.succeed([]),
    }));
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([
        { name: "cmux-home-abcdef123456-noble-wren", createdAt: 2, attachedTo: null },
      ]),
      deleteHomeVolume: (_provider: ProviderId, name: string) => Effect.sync(() => deleted.push(name)),
    };

    const result = await Effect.runPromise(
      reapVmResources({ now: NOW, deleteVolumes: true }).pipe(
        Effect.provide(workflowLayer(repo, provider)),
      ),
    );

    expect(result.orphanVolumes.deleted).toBe(0);
    expect(result.orphanVolumes.skipped).toBe(1);
    expect(deleted).toEqual([]);
  });

  test("marks a stale provisioning row destroyed when the provider sandbox is gone", async () => {
    const updates: Array<Record<string, unknown>> = [];
    const usage: Array<Record<string, unknown>> = [];
    const row = vmRow({ providerVmId: "stale-sandbox" });
    const repo = withObservations(repository({
      listLiveHomeVolumeNames: () => Effect.succeed([]),
      stuckProvisioningCandidates: () => Effect.succeed([row]),
      markProviderObservedStatus: (update) => Effect.sync(() => {
        updates.push(update as Record<string, unknown>);
        return true;
      }),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    }));
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([]),
      getStatus: (_provider: ProviderId, vmId: string) => Effect.fail(missingProviderError(vmId)),
    };

    const result = await Effect.runPromise(
      reapVmResources({ now: NOW, deleteVolumes: false }).pipe(
        Effect.provide(workflowLayer(repo, provider)),
      ),
    );

    expect(result.stuckProvisioning.destroyed).toBe(1);
    expect(result.stuckProvisioning.failed).toBe(0);
    expect(updates).toEqual([
      { id: row.id, providerVmId: "stale-sandbox", status: "destroyed", expectedStatus: "provisioning" },
    ]);
    expect(usage).toContainEqual(expect.objectContaining({
      eventType: "vm.destroyed",
      vmId: row.id,
      metadata: expect.objectContaining({ source: "vm_reaper" }),
    }));
  });

  test("marks a stale provisioning row failed when it never received a provider id", async () => {
    const failures: Array<Record<string, unknown>> = [];
    const usage: Array<Record<string, unknown>> = [];
    const row = vmRow({ providerVmId: null });
    const repo = withObservations(repository({
      listLiveHomeVolumeNames: () => Effect.succeed([]),
      stuckProvisioningCandidates: () => Effect.succeed([row]),
      markProvisioningFailed: (input) => Effect.sync(() => {
        failures.push(input as Record<string, unknown>);
        return true;
      }),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    }));
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([]),
    };

    const result = await Effect.runPromise(
      reapVmResources({ now: NOW, deleteVolumes: false }).pipe(
        Effect.provide(workflowLayer(repo, provider)),
      ),
    );

    expect(result.stuckProvisioning.failed).toBe(1);
    expect(failures[0]).toMatchObject({
      id: row.id,
      code: "provisioning_timeout",
    });
    expect(usage).toContainEqual(expect.objectContaining({
      eventType: "vm.create.failed",
      vmId: row.id,
    }));
  });

  test("does not delete a newly observed volume until it is old and observed by a prior run", async () => {
    const deleted: string[] = [];
    const name = "cmux-home-abcdef123456-new-volume";
    const observations = new Map<string, Date>();
    const volume: VMVolume = {
      name,
      createdAt: NOW.getTime() - 30 * 60 * 1000,
      attachedTo: null,
    };
    const repo = withObservations(repository({
      listLiveHomeVolumeNames: () => Effect.succeed([]),
      isLiveHomeVolumeReferenced: () => Effect.succeed(false),
      stuckProvisioningCandidates: () => Effect.succeed([]),
    }), observations);
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([volume]),
      deleteHomeVolume: (_provider: ProviderId, volumeName: string) =>
        Effect.sync(() => deleted.push(volumeName)),
    };
    const run = (now: Date) => Effect.runPromise(
      reapVmResources({ now, deleteVolumes: true } as VmReaperOptions).pipe(
        Effect.provide(workflowLayer(repo, provider)),
      ),
    );

    const first = await run(NOW);
    expect(first.orphanVolumes.deleted).toBe(0);
    expect(first.orphanVolumes.reported).toBe(1);
    expect(observations.has(name)).toBe(true);

    const tooYoung = await run(new Date(NOW.getTime() + 60 * 60 * 1000));
    expect(tooYoung.orphanVolumes.deleted).toBe(0);

    const oldEnough = await run(new Date(NOW.getTime() + 2 * 60 * 60 * 1000));
    expect(oldEnough.orphanVolumes.deleted).toBe(1);
    expect(deleted).toEqual([name]);
  });

  test("does not overwrite a provisioning row that changed while provider status was read", async () => {
    const updates: Array<Record<string, unknown>> = [];
    const row = vmRow({ providerVmId: "racing-sandbox" });
    const repo = withObservations(repository({
      listLiveHomeVolumeNames: () => Effect.succeed([]),
      stuckProvisioningCandidates: () => Effect.succeed([row]),
      markProviderObservedStatus: (update) => Effect.sync(() => {
        updates.push(update as Record<string, unknown>);
        return false;
      }),
    }));
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([]),
      getStatus: () => Effect.succeed("running" as const),
    };

    const result = await Effect.runPromise(
      reapVmResources({ now: NOW, deleteVolumes: false }).pipe(
        Effect.provide(workflowLayer(repo, provider)),
      ),
    );

    expect(result.stuckProvisioning.recovered).toBe(0);
    expect(result.stuckProvisioning.skipped).toBe(1);
    expect(updates).toEqual([
      {
        id: row.id,
        providerVmId: "racing-sandbox",
        status: "running",
        expectedStatus: "provisioning",
      },
    ]);
  });

  test("finalizes a provider-creating row after the terminal deadline", async () => {
    const failures: Array<Record<string, unknown>> = [];
    const usage: Array<Record<string, unknown>> = [];
    const row = vmRow({
      providerVmId: "creating-too-long",
      createdAt: new Date(NOW.getTime() - 5 * 60 * 60 * 1000),
      updatedAt: new Date(NOW.getTime() - 5 * 60 * 60 * 1000),
    });
    const repo = withObservations(repository({
      listLiveHomeVolumeNames: () => Effect.succeed([]),
      stuckProvisioningCandidates: () => Effect.succeed([row]),
      markProvisioningFailed: (input) => Effect.sync(() => {
        failures.push(input as Record<string, unknown>);
        return true;
      }),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    }));
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([]),
      getStatus: () => Effect.succeed("creating" as const),
    };

    const result = await Effect.runPromise(
      reapVmResources({
        now: NOW,
        deleteVolumes: false,
        stuckProvisioningTerminalAgeMs: 4 * 60 * 60 * 1000,
      } as VmReaperOptions).pipe(
        Effect.provide(workflowLayer(repo, provider)),
      ),
    );

    expect(result.stuckProvisioning.failed).toBe(1);
    expect(result.stuckProvisioning.skipped).toBe(0);
    expect(failures).toContainEqual(expect.objectContaining({
      id: row.id,
      code: "provisioning_timeout",
    }));
    expect(usage).toContainEqual(expect.objectContaining({
      eventType: "vm.reaper.stuck_provisioning_terminal",
      vmId: row.id,
    }));
  });

  test("filters live volumes before the limit and keeps reference lookups bounded", async () => {
    const deleted: string[] = [];
    const seenReferenceBatches: string[][] = [];
    const liveNames = new Set(
      ["aaaaaaaaaaaa", "bbbbbbbbbbbb", "cccccccccccc"].map((digest) =>
        `cmux-home-${digest}-noble-wren`),
    );
    const orphanNames = [
      "cmux-home-dddddddddddd-noble-wren",
      "cmux-home-eeeeeeeeeeee-noble-wren",
    ];
    const volumes = [
      ...Array.from(liveNames, (name) => oldVolume(name)),
      ...orphanNames.map((name) => oldVolume(name)),
    ];
    const observations = new Map(orphanNames.map((name) => [
      name,
      new Date(NOW.getTime() - 60 * 60 * 1000),
    ]));
    const repo = withObservations(repository({
      listLiveHomeVolumeNames: ((input?: { readonly volumeNames?: readonly string[] }) => {
        const names = [...(input?.volumeNames ?? [])];
        seenReferenceBatches.push(names);
        return Effect.succeed(names.filter((name) => liveNames.has(name)));
      }) as VmRepositoryShape["listLiveHomeVolumeNames"],
      isLiveHomeVolumeReferenced: () => Effect.succeed(false),
      stuckProvisioningCandidates: () => Effect.succeed([]),
    }), observations);
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed(volumes),
      deleteHomeVolume: (_provider: ProviderId, name: string) => Effect.sync(() => deleted.push(name)),
    };

    const result = await Effect.runPromise(
      reapVmResources({ now: NOW, deleteVolumes: true, volumeLimit: 2 }).pipe(
        Effect.provide(workflowLayer(repo, provider)),
      ),
    );

    expect(result.orphanVolumes.deleted).toBe(2);
    expect(deleted).toEqual(orphanNames);
    expect(seenReferenceBatches.length).toBeGreaterThan(1);
    expect(seenReferenceBatches.every((batch) => batch.length <= 2)).toBe(true);
  });

  test("bounds volume and provisioning batches and processes oldest first", async () => {
    const deleted: string[] = [];
    const statusCalls: string[] = [];
    const volumes: VMVolume[] = Array.from({ length: 105 }, (_, index) => ({
      name: `cmux-home-${index.toString(16).padStart(12, "0")}-noble-wren`,
      createdAt: index + 1,
      attachedTo: null,
    }));
    const rows = Array.from({ length: 105 }, (_, index) => vmRow({
      id: `00000000-0000-4000-8000-${(index + 100).toString(16).padStart(12, "0")}`,
      providerVmId: `stale-${index}`,
      createdAt: new Date(NOW.getTime() - (index + 2) * 60 * 60 * 1000),
      updatedAt: new Date(NOW.getTime() - (index + 2) * 60 * 60 * 1000),
    }));
    const observations = new Map(volumes.map((volume) => [
      volume.name,
      new Date(NOW.getTime() - 60 * 60 * 1000),
    ]));
    const repo = withObservations(repository({
      listLiveHomeVolumeNames: () => Effect.succeed([]),
      stuckProvisioningCandidates: ({ limit }) => Effect.succeed(rows.slice(0, limit)),
      markProviderObservedStatus: ({ providerVmId }) => Effect.sync(() => {
        statusCalls.push(providerVmId);
        return true;
      }),
    }), observations);
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed(volumes),
      deleteHomeVolume: (_provider: ProviderId, name: string) => Effect.sync(() => deleted.push(name)),
      getStatus: () => Effect.succeed("running" as const),
    };

    const result = await Effect.runPromise(
      reapVmResources({ now: NOW, deleteVolumes: true }).pipe(
        Effect.provide(workflowLayer(repo, provider)),
      ),
    );

    expect(result.orphanVolumes.deleted).toBe(100);
    expect(deleted).toHaveLength(100);
    expect(deleted[0]).toBe(volumes[0]?.name);
    expect(result.stuckProvisioning.recovered).toBe(100);
    expect(statusCalls).toHaveLength(100);
    expect(statusCalls[0]).toBe("stale-0");
  });
});
