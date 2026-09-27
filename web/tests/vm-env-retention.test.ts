import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import type { CloudVmEnvLayerRow, VmRepositoryShape } from "../services/vms/repository";
import { VmRepository } from "../services/vms/repository";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { cleanupEnvLayers } from "../services/vms/workflows";
import { recordEnvLayer } from "../services/vms/workflows";

const layer: CloudVmEnvLayerRow = {
  id: "00000000-0000-0000-0000-000000000001",
  userId: "user-retention",
  billingTeamId: "team-retention",
  provider: "freestyle",
  baseImageId: "image-retention",
  chainHash: "chain-retention",
  stepIndex: 0,
  stepName: "install",
  specDigest: "spec-retention",
  snapshotId: "snapshot-retention",
  createdAt: new Date("2026-01-01T00:00:00.000Z"),
  lastUsedAt: new Date("2026-01-01T00:00:00.000Z"),
  invalidatedAt: null,
};

describe("Cloud VM env-layer retention", () => {
  test("deletes the provider snapshot before invalidating its row", async () => {
    const order: string[] = [];
    const repo: Partial<VmRepositoryShape> = {
      listEnvLayerRetentionCandidates: () => Effect.succeed([{ ...layer, deletionRequested: false }]),
      recordUsageEvent: (input) => {
        order.push(input.eventType);
        return Effect.void;
      },
      invalidateEnvLayer: () => {
        order.push("row.invalidated");
        return Effect.succeed(true);
      },
    };
    const provider: Partial<VmProviderGatewayShape> = {
      deleteSnapshotById: (_provider, snapshotId) => {
        order.push(`provider.delete:${snapshotId}`);
        return Effect.void;
      },
    };
    const services = Layer.mergeAll(
      Layer.succeed(VmRepository, repo as VmRepositoryShape),
      Layer.succeed(VmProviderGateway, provider as VmProviderGatewayShape),
    );

    const result = await Effect.runPromise(cleanupEnvLayers({ now: new Date("2026-02-01T00:00:00.000Z") }).pipe(Effect.provide(services)));

    expect(result.deleted).toBe(1);
    expect(order).toEqual([
      "vm.env.layer.delete_requested",
      "provider.delete:snapshot-retention",
      "vm.env.layer.deleted",
      "row.invalidated",
    ]);
  });

  test("does not orphan a concurrently produced duplicate snapshot", async () => {
    const order: string[] = [];
    const repo: Partial<VmRepositoryShape> = {
      hasOwnedSnapshot: () => Effect.succeed(true),
      insertEnvLayer: () => Effect.succeed(layer),
      recordUsageEvent: (input) => {
        order.push(input.eventType);
        return Effect.void;
      },
    };
    const provider: Partial<VmProviderGatewayShape> = {
      deleteSnapshotById: (_provider, snapshotId) => {
        order.push(`provider.delete:${snapshotId}`);
        return Effect.void;
      },
    };
    const services = Layer.mergeAll(
      Layer.succeed(VmRepository, repo as VmRepositoryShape),
      Layer.succeed(VmProviderGateway, provider as VmProviderGatewayShape),
    );

    await Effect.runPromise(recordEnvLayer({
      userId: layer.userId,
      billingTeamId: layer.billingTeamId,
      provider: layer.provider,
      baseImageId: layer.baseImageId,
      chainHash: layer.chainHash,
      stepIndex: layer.stepIndex,
      stepName: layer.stepName,
      specDigest: layer.specDigest,
      snapshotId: "snapshot-loser",
    }).pipe(Effect.provide(services)));

    expect(order).toEqual([
      "vm.env.layer.delete_requested",
      "provider.delete:snapshot-loser",
      "vm.env.layer.deleted",
      "vm.env.layer.registered",
    ]);
  });
});
