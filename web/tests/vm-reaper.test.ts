import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import type { VMVolume } from "../services/vms/drivers";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import {
  VmRepository,
  type CloudVmRow,
  type VmRepositoryShape,
} from "../services/vms/repository";
import { VmProviderOperationError } from "../services/vms/errors";
import { reapVmResources } from "../services/vms/workflows";

const NOW = new Date("2026-08-31T20:00:00.000Z");

function providerLayer(provider: VmProviderGatewayShape) {
  return Layer.succeed(VmProviderGateway, provider);
}

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
    const volumes: VMVolume[] = [
      { name: "cmux-home-abcdef123456", createdAt: 1, attachedTo: null },
      { name: "cmux-home-abcdef123456-noble-wren", createdAt: 2, attachedTo: null },
      { name: "cmux-home-abcdef123456-bold-fox", createdAt: 3, attachedTo: "sandbox:bold-fox" },
      { name: "user-home-noble-wren", createdAt: 4, attachedTo: null },
    ];
    const repo = baseRepository();
    repo.listLiveHomeVolumeNames = () => Effect.succeed([]);
    repo.stuckProvisioningCandidates = () => Effect.succeed([]);
    repo.recordUsageEvent = (event) => Effect.sync(() => usage.push(event as Record<string, unknown>));
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed(volumes),
      deleteHomeVolume: (_provider, name) => Effect.sync(() => deleted.push(name)),
    };

    const result = await Effect.runPromise(
      reapVmResources({ now: NOW, deleteVolumes: false }).pipe(
        Effect.provide(workflowLayer(repo, provider)),
      ),
    );

    expect(result.reportOnly).toBe(true);
    expect(result.orphanVolumes.candidates).toBe(2);
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
    const repo = baseRepository();
    repo.listLiveHomeVolumeNames = () => Effect.succeed([]);
    repo.stuckProvisioningCandidates = () => Effect.succeed([]);
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([
        { name: "cmux-home-abcdef123456-noble-wren", createdAt: 2, attachedTo: null },
      ]),
      deleteHomeVolume: (_provider, name) => Effect.sync(() => deleted.push(name)),
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
    const repo = baseRepository();
    repo.listLiveHomeVolumeNames = () => Effect.succeed(["cmux-home-abcdef123456-noble-wren"]);
    repo.stuckProvisioningCandidates = () => Effect.succeed([]);
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([
        { name: "cmux-home-abcdef123456-noble-wren", createdAt: 2, attachedTo: null },
      ]),
      deleteHomeVolume: (_provider, name) => Effect.sync(() => deleted.push(name)),
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
    const repo = baseRepository();
    repo.listLiveHomeVolumeNames = () => Effect.succeed([]);
    repo.stuckProvisioningCandidates = () => Effect.succeed([row]);
    repo.markProviderObservedStatus = (update) => Effect.sync(() => {
      updates.push(update as Record<string, unknown>);
      return true;
    });
    repo.recordUsageEvent = (event) => Effect.sync(() => usage.push(event as Record<string, unknown>));
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed([]),
      getStatus: (_provider, vmId) => Effect.fail(missingProviderError(vmId)),
    };

    const result = await Effect.runPromise(
      reapVmResources({ now: NOW, deleteVolumes: false }).pipe(
        Effect.provide(workflowLayer(repo, provider)),
      ),
    );

    expect(result.stuckProvisioning.destroyed).toBe(1);
    expect(result.stuckProvisioning.failed).toBe(0);
    expect(updates).toEqual([
      { id: row.id, providerVmId: "stale-sandbox", status: "destroyed" },
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
    const repo = baseRepository();
    repo.listLiveHomeVolumeNames = () => Effect.succeed([]);
    repo.stuckProvisioningCandidates = () => Effect.succeed([row]);
    repo.markProvisioningFailed = (input) => Effect.sync(() => {
      failures.push(input as Record<string, unknown>);
      return true;
    });
    repo.recordUsageEvent = (event) => Effect.sync(() => usage.push(event as Record<string, unknown>));
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
    const repo = baseRepository();
    repo.listLiveHomeVolumeNames = () => Effect.succeed([]);
    repo.stuckProvisioningCandidates = ({ limit }) => Effect.succeed(rows.slice(0, limit));
    repo.markProviderObservedStatus = ({ providerVmId }) => Effect.sync(() => {
      statusCalls.push(providerVmId);
      return true;
    });
    const provider = {
      ...baseProvider(),
      listVolumes: () => Effect.succeed(volumes),
      deleteHomeVolume: (_provider, name) => Effect.sync(() => deleted.push(name)),
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
