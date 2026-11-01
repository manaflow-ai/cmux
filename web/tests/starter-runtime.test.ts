import { describe, expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import type { CloudVmRow, VmRepositoryShape } from "../services/vms/repository";
import type { VmProviderGatewayShape } from "../services/vms/providerGateway";

let rows: CloudVmRow[] = [];
const realDb = { ...await import("../db/client") };
mock.module("../db/client", () => ({ ...realDb, cloudDb: () => ({
  select: () => ({ from: () => ({ where: () => ({ orderBy: async () => rows }) }) }),
}) }));
const { enforceGoRuntimeLimits } = await import("../services/vms/goRuntimeLimits");
const { VmRepository } = await import("../services/vms/repository");
const { VmProviderGateway } = await import("../services/vms/providerGateway");
const { GO_UNLIMITED_RUNTIME_METADATA_KEY } = await import("../services/vms/goUsage");

async function reconcile(metadata: Record<string, unknown>) {
  const caps: (number | null)[] = [];
  const patches: Record<string, unknown>[] = [];
  let pauses = 0;
  rows = [{ id: "starter-row", userId: "starter-user", billingPlanId: "go", provider: "freestyle",
    providerVmId: "starter-vm", status: "running", providerMetadata: metadata } as CloudVmRow];
  const repo = {
    mergeProviderMetadata: ({ patch }: { patch: Record<string, unknown> }) => Effect.sync(() => { patches.push(patch); }),
  } as unknown as VmRepositoryShape;
  const providers = {
    setRuntimeBudget: (_provider: string, _id: string, seconds: number | null) => Effect.sync(() => { caps.push(seconds); }),
    pause: () => Effect.sync(() => { pauses++; }),
  } as unknown as VmProviderGatewayShape;
  const result = await Effect.runPromise(enforceGoRuntimeLimits().pipe(Effect.provide(Layer.merge(
    Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, providers),
  ))));
  return { result, caps, patches, pauses };
}

describe("Plus runtime cleanup", () => {
  test("clears a legacy provider cap and pending pause without pausing the VM", async () => {
    const { result, caps, patches, pauses } = await reconcile({ cmuxGoPauseIntent: { reason: "go_hours_limit" } });
    expect(result).toEqual({ checked: 1, paused: 0, errors: 0 });
    expect(caps).toEqual([null]);
    expect(patches).toEqual([{ cmuxGoPauseIntent: null, [GO_UNLIMITED_RUNTIME_METADATA_KEY]: true }]);
    expect(pauses).toBe(0);
  });

  test("leaves an already unlimited machine running without more provider calls", async () => {
    const { result, caps, patches, pauses } = await reconcile({ [GO_UNLIMITED_RUNTIME_METADATA_KEY]: true });
    expect(result).toEqual({ checked: 1, paused: 0, errors: 0 });
    expect(caps).toEqual([]);
    expect(patches).toEqual([]);
    expect(pauses).toBe(0);
  });
});
