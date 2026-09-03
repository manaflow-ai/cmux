import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import type { VMVolume, VMVolumeInventory } from "../services/vms/drivers";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import {
  VmRepository,
  type CloudVmRow,
  type VmRepositoryShape,
} from "../services/vms/repository";
import { reapVmResources, type VmReaperOptions } from "../services/vms/reaper";

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
    markBaseCreateFailed: () => Effect.die("unexpected lifecycle write"),
    activeLimitCandidates: () => Effect.succeed([]),
    reservePausedResume: () => Effect.die("unused"),
    reconciliationCandidates: () => Effect.succeed([]),
    markProviderObservedStatus: () => Effect.die("unexpected lifecycle write"),
    setDisplayName: () => Effect.die("unexpected lifecycle write"),
    markCreateRunning: () => Effect.die("unused"),
    markCreateFailed: () => Effect.die("unexpected lifecycle write"),
    hasOwnedSnapshot: () => Effect.succeed(false),
    findUserVm: () => Effect.succeed(null),
    markDestroyed: () => Effect.die("unexpected lifecycle write"),
    recordLease: () => Effect.die("unexpected lifecycle write"),
    accountDeletionIdentityLeases: () => Effect.succeed([]),
    listVmSessions: () => Effect.succeed([]),
    upsertVmSession: () => Effect.die("unused"),
    activeIdentityLeases: () => Effect.succeed([]),
    markLeasesRevoked: () => Effect.die("unexpected lifecycle write"),
    recentReaperReportKeys: () => Effect.succeed([]),
    recordUsageEvent: () => Effect.void,
    recordUsageEvents: () => Effect.void,
  } as unknown as VmRepositoryShape;
}

function repository(overrides: Partial<VmRepositoryShape> = {}): VmRepositoryShape {
  return { ...baseRepository(), ...overrides };
}

function oldVolume(
  name: string,
  overrides: Partial<VMVolume> = {},
): VMVolume {
  return {
    name,
    createdAt: NOW.getTime() - 3 * 60 * 60 * 1000,
    attachedTo: null,
    attachmentState: "unattached",
    ...overrides,
  };
}

function vmRow(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "00000000-0000-4000-8000-000000000001",
    userId: "user-reaper",
    billingTeamId: "team-reaper",
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: "stale-sandbox",
    displayName: null,
    imageId: "cmux-devbox:devbox-20260828b",
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

function runReaper(
  repo: VmRepositoryShape,
  provider: VmProviderGatewayShape,
  options: VmReaperOptions = {},
) {
  return Effect.runPromise(
    // No shipped driver exposes a volume inventory, so the scan is inert unless
    // a provider is named; these tests drive it against the stub gateway.
    reapVmResources({ now: NOW, volumeProvider: "freestyle", ...options }).pipe(
      Effect.provide(workflowLayer(repo, provider)),
    ),
  );
}

describe("Cloud VM reaper report", () => {
  test("the volume scan is inert when no registered driver exposes a volume inventory", async () => {
    // Persistent home volumes were a single-provider feature and no shipped
    // driver implements listVolumes today. The reaper must not scan a
    // hardcoded provider; it reports partial coverage and touches nothing.
    const usage: Array<Record<string, unknown>> = [];
    const listVolumeCalls: string[] = [];
    const repo = repository({
      stuckProvisioningCandidates: () => Effect.succeed([]),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    });
    const provider = {
      ...baseProvider(),
      listVolumes: (providerId: string) => Effect.sync(() => {
        listVolumeCalls.push(providerId);
        return [];
      }),
    } as unknown as VmProviderGatewayShape;

    const result = await Effect.runPromise(
      reapVmResources({ now: NOW }).pipe(Effect.provide(workflowLayer(repo, provider))),
    );

    expect(listVolumeCalls).toEqual([]);
    expect(result.orphanVolumes.scanned).toBe(0);
    expect(result.orphanVolumes.candidates).toBe(0);
    expect(result.orphanVolumes.coveragePartial).toBe(true);
    expect(usage).toEqual([]);
  });

  test("reports only known orphan candidates and never deletes or writes VM rows", async () => {
    const usage: Array<Record<string, unknown>> = [];
    const deleted: string[] = [];
    const liveLookups: string[][] = [];
    const repo = repository({
      listLiveHomeVolumeNames: ({ volumeNames }) => Effect.sync(() => {
        liveLookups.push([...volumeNames]);
        return [];
      }),
      stuckProvisioningCandidates: () => Effect.succeed([]),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    });
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([
        oldVolume("cmux-home-abcdef123456-noble-wren"),
        oldVolume("cmux-home-abcdef123456-bold-fox", { attachedTo: "sandbox:bold-fox", attachmentState: "attached" }),
        oldVolume("cmux-home-abcdef123456"),
        oldVolume("shared-volume"),
      ]),
      deleteHomeVolume: (_provider: "freestyle", name: string) => Effect.sync(() => deleted.push(name)),
    } as unknown as VmProviderGatewayShape;

    const result = await runReaper(repo, provider, {
      // A legacy array is still accepted, but it must be marked partial.
      volumeLimit: 10,
      volumeScanLimit: 10,
    });

    expect(result.reportOnly).toBe(true);
    expect(result.deleted).toBe(0);
    expect(result.orphanVolumes.candidates).toBe(1);
    expect(result.orphanVolumes.reported).toBe(1);
    expect(result.orphanVolumes.deleted).toBe(0);
    expect(result.orphanVolumes.coveragePartial).toBe(true);
    expect(liveLookups).toEqual([["cmux-home-abcdef123456-noble-wren"]]);
    expect(deleted).toEqual([]);
    expect(usage).toHaveLength(1);
    expect(usage[0]).toMatchObject({
      eventType: "vm.reaper.orphan_volume",
      metadata: {
        volumeName: "cmux-home-abcdef123456-noble-wren",
        attachmentState: "unattached",
        liveReference: false,
      },
    });
  });

  test("reports unknown attachment separately and never treats it as free", async () => {
    const usage: Array<Record<string, unknown>> = [];
    const liveLookups: string[][] = [];
    const repo = repository({
      listLiveHomeVolumeNames: ({ volumeNames }) => Effect.sync(() => {
        liveLookups.push([...volumeNames]);
        return [];
      }),
      stuckProvisioningCandidates: () => Effect.succeed([]),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    });
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([
        { name: "cmux-home-abcdef123456-unknown-state", createdAt: 1 },
        oldVolume("cmux-home-abcdef123456-explicit-free"),
      ]),
    } as unknown as VmProviderGatewayShape;

    const result = await runReaper(repo, provider, { volumeScanLimit: 10 });

    expect(result.orphanVolumes.unknownAttachment).toBe(1);
    expect(result.orphanVolumes.candidates).toBe(1);
    expect(result.orphanVolumes.reported).toBe(2);
    expect(liveLookups).toEqual([["cmux-home-abcdef123456-explicit-free"]]);
    expect(usage).toContainEqual(expect.objectContaining({
      eventType: "vm.reaper.orphan_volume_unknown_attachment",
      metadata: expect.objectContaining({
        volumeName: "cmux-home-abcdef123456-unknown-state",
        attachmentState: "unknown",
        attachment: "unknown",
      }),
    }));
    expect(usage).not.toContainEqual(expect.objectContaining({
      eventType: "vm.reaper.orphan_volume",
      metadata: expect.objectContaining({ volumeName: "cmux-home-abcdef123456-unknown-state" }),
    }));
  });

  test("reports stale provisioning rows without provider reads or repository status writes", async () => {
    const usage: Array<Record<string, unknown>> = [];
    const row = vmRow({
      providerVmId: null,
      createdAt: new Date(NOW.getTime() - 8 * 60 * 60 * 1000),
      updatedAt: new Date(NOW.getTime() - 2 * 60 * 60 * 1000),
    });
    let statusReads = 0;
    const repo = repository({
      stuckProvisioningCandidates: () => Effect.succeed([row]),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    });
    const provider = {
      ...baseProvider(),
      getStatus: () => Effect.sync(() => {
        statusReads += 1;
        return "running" as const;
      }),
      listVolumes: () => Effect.succeed([]),
    } as unknown as VmProviderGatewayShape;

    const result = await runReaper(repo, provider);

    expect(result.stuckProvisioning.candidates).toBe(1);
    expect(result.stuckProvisioning.reported).toBe(1);
    expect(result.stuckProvisioning.failed).toBe(0);
    expect(result.stuckProvisioning.destroyed).toBe(0);
    expect(statusReads).toBe(0);
    expect(usage).toContainEqual(expect.objectContaining({
      eventType: "vm.reaper.stuck_provisioning",
      vmId: row.id,
      metadata: expect.objectContaining({ reason: "age_over_threshold", ageMinutes: 120 }),
    }));
  });

  test("excludes recent reports before applying each report limit", async () => {
    const usage: Array<Record<string, unknown>> = [];
    const firstVolumeName = "cmux-home-aaaaaaaaaaaa-first-volume";
    const laterVolumeName = "cmux-home-bbbbbbbbbbbb-later-volume";
    const firstRow = vmRow({
      id: "00000000-0000-4000-8000-000000000011",
      createdAt: new Date(NOW.getTime() - 6 * 60 * 60 * 1000),
      updatedAt: new Date(NOW.getTime() - 4 * 60 * 60 * 1000),
    });
    const laterRow = vmRow({
      id: "00000000-0000-4000-8000-000000000012",
      createdAt: new Date(NOW.getTime() - 5 * 60 * 60 * 1000),
      updatedAt: new Date(NOW.getTime() - 3 * 60 * 60 * 1000),
    });
    const recentLookups: Array<{ eventType: string; keys: string[]; since: Date }> = [];
    const repo = repository({
      listLiveHomeVolumeNames: () => Effect.succeed([]),
      stuckProvisioningCandidates: () => Effect.succeed([firstRow, laterRow]),
      recentReaperReportKeys: (input) => Effect.sync(() => {
        recentLookups.push({ ...input, keys: [...input.keys] });
        return input.eventType === "vm.reaper.orphan_volume"
          ? [firstVolumeName]
          : [firstRow.id];
      }),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    });
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([
        oldVolume(firstVolumeName, { createdAt: NOW.getTime() - 4 * 60 * 60 * 1000 }),
        oldVolume(laterVolumeName, { createdAt: NOW.getTime() - 3 * 60 * 60 * 1000 }),
      ]),
    } as unknown as VmProviderGatewayShape;

    const result = await runReaper(repo, provider, {
      volumeLimit: 1,
      volumeScanLimit: 2,
      provisioningLimit: 1,
    });

    expect(result.orphanVolumes.candidates).toBe(1);
    expect(result.orphanVolumes.reported).toBe(1);
    expect(result.orphanVolumes.skipped).toBe(1);
    expect(result.stuckProvisioning.candidates).toBe(1);
    expect(result.stuckProvisioning.reported).toBe(1);
    expect(result.stuckProvisioning.skipped).toBe(1);
    expect(recentLookups).toHaveLength(2);
    expect(usage).toContainEqual(expect.objectContaining({
      eventType: "vm.reaper.orphan_volume",
      metadata: expect.objectContaining({ volumeName: laterVolumeName }),
    }));
    expect(usage).not.toContainEqual(expect.objectContaining({
      eventType: "vm.reaper.orphan_volume",
      metadata: expect.objectContaining({ volumeName: firstVolumeName }),
    }));
    expect(usage).toContainEqual(expect.objectContaining({
      eventType: "vm.reaper.stuck_provisioning",
      vmId: laterRow.id,
    }));
    expect(usage).not.toContainEqual(expect.objectContaining({
      eventType: "vm.reaper.stuck_provisioning",
      vmId: firstRow.id,
    }));
  });

  test("skips orphan volumes that are younger than the grace period or have unknown age", async () => {
    const usage: Array<Record<string, unknown>> = [];
    const repo = repository({
      listLiveHomeVolumeNames: () => Effect.succeed([]),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    });
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([
        oldVolume("cmux-home-cccccccccccc-young", {
          createdAt: new Date(NOW.getTime() - 30 * 60 * 1000),
        } as unknown as Partial<VMVolume>),
        oldVolume("cmux-home-dddddddddddd-unknown", {
          createdAt: "not-a-date",
        } as unknown as Partial<VMVolume>),
      ]),
    } as unknown as VmProviderGatewayShape;

    const result = await runReaper(repo, provider, { volumeScanLimit: 10 });

    expect(result.orphanVolumes.candidates).toBe(0);
    expect(result.orphanVolumes.reported).toBe(0);
    expect(result.orphanVolumes.skipped).toBe(2);
    expect(usage).toHaveLength(0);
  });

  test("does not report a provisioning row with a fresh updatedAt", async () => {
    const usage: Array<Record<string, unknown>> = [];
    const row = vmRow({
      createdAt: new Date(NOW.getTime() - 8 * 60 * 60 * 1000),
      updatedAt: new Date(NOW.getTime() - 5 * 60 * 1000),
    });
    const repo = repository({
      stuckProvisioningCandidates: () => Effect.succeed([row]),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    });
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([]),
    } as unknown as VmProviderGatewayShape;

    const result = await runReaper(repo, provider);

    expect(result.stuckProvisioning.candidates).toBe(0);
    expect(result.stuckProvisioning.reported).toBe(0);
    expect(usage).not.toContainEqual(expect.objectContaining({
      eventType: "vm.reaper.stuck_provisioning",
      vmId: row.id,
    }));
  });

  test("checks live references in bounded batches and excludes referenced volumes", async () => {
    const usage: Array<Record<string, unknown>> = [];
    const lookupBatches: string[][] = [];
    const liveName = "cmux-home-aaaaaaaaaaaa-noble-wren";
    const orphanName = "cmux-home-bbbbbbbbbbbb-noble-wren";
    const repo = repository({
      listLiveHomeVolumeNames: ({ volumeNames }) => Effect.sync(() => {
        lookupBatches.push([...volumeNames]);
        return volumeNames.filter((name) => name === liveName);
      }),
      stuckProvisioningCandidates: () => Effect.succeed([]),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    });
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([
        oldVolume(liveName),
        oldVolume(orphanName),
      ]),
    } as unknown as VmProviderGatewayShape;

    const result = await runReaper(repo, provider, { volumeLimit: 1, volumeScanLimit: 2 });

    expect(lookupBatches).toEqual([[liveName, orphanName]]);
    expect(result.orphanVolumes.candidates).toBe(1);
    expect(result.orphanVolumes.reported).toBe(1);
    expect(usage[0]).toMatchObject({ metadata: { volumeName: orphanName } });
  });

  test("follows provider cursors to avoid starving a batch and records scan coverage", async () => {
    const usage: Array<Record<string, unknown>> = [];
    const calls: Array<{ limit: number; cursor?: string }> = [];
    const firstPage: VMVolume[] = [
      oldVolume("cmux-home-aaaaaaaaaaaa-attached", { attachedTo: "sandbox:a", attachmentState: "attached" }),
      oldVolume("not-a-machine-volume"),
    ];
    const secondPage: VMVolume[] = [oldVolume("cmux-home-bbbbbbbbbbbb-orphan")];
    const repo = repository({
      listLiveHomeVolumeNames: () => Effect.succeed([]),
      stuckProvisioningCandidates: () => Effect.succeed([]),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    });
    const provider = {
      ...baseProvider(),
      listVolumes: (_provider: "freestyle", options: { limit: number; cursor?: string }): Effect.Effect<VMVolumeInventory> => Effect.sync(() => {
        calls.push({ limit: options.limit, ...(options.cursor ? { cursor: options.cursor } : {}) });
        return options.cursor
          ? { volumes: secondPage, nextCursor: null }
          : { volumes: firstPage, nextCursor: "page-2" };
      }),
    } as unknown as VmProviderGatewayShape;

    const result = await runReaper(repo, provider, { volumeLimit: 1, volumeScanLimit: 3 });

    expect(calls).toEqual([
      { limit: 3 },
      { limit: 1, cursor: "page-2" },
    ]);
    expect(result.orphanVolumes.scanned).toBe(3);
    expect(result.orphanVolumes.candidates).toBe(1);
    expect(result.orphanVolumes.coveragePartial).toBe(false);
    expect(usage).toContainEqual(expect.objectContaining({
      eventType: "vm.reaper.orphan_volume",
      metadata: expect.objectContaining({ volumeName: "cmux-home-bbbbbbbbbbbb-orphan" }),
    }));
  });

  test("caps a legacy non-paginated inventory and marks coverage partial", async () => {
    const usage: Array<Record<string, unknown>> = [];
    const scannedNames: string[][] = [];
    const volumes = Array.from({ length: 20 }, (_, index) => oldVolume(
      `cmux-home-${index.toString(16).padStart(12, "0")}-noble-wren`,
    ));
    const repo = repository({
      listLiveHomeVolumeNames: ({ volumeNames }) => Effect.sync(() => {
        scannedNames.push([...volumeNames]);
        return [];
      }),
      stuckProvisioningCandidates: () => Effect.succeed([]),
      recordUsageEvent: (event) => Effect.sync(() => usage.push(event as Record<string, unknown>)),
    });
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed(volumes),
    } as unknown as VmProviderGatewayShape;

    const result = await runReaper(repo, provider, {
      volumeLimit: 2,
      volumeScanLimit: 3,
    });

    expect(result.orphanVolumes.scanned).toBe(3);
    expect(result.orphanVolumes.candidates).toBe(2);
    expect(result.orphanVolumes.reported).toBe(2);
    expect(result.orphanVolumes.coveragePartial).toBe(true);
    expect(scannedNames.flat().length).toBe(3);
    expect(usage).toHaveLength(2);
  });
});
