import { expect, mock, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
const realDb = { ...await import("../db/client") };
const writes: unknown[] = [];
mock.module("../db/client", () => ({ ...realDb, cloudDb: () => ({ update: () => ({ set: (value: unknown) => ({
  where: async () => { writes.push(value); },
}) }) }) }));
const { resumeVm } = await import("../services/vms/workflows");
const { VmRepository } = await import("../services/vms/repository");
const { VmProviderGateway } = await import("../services/vms/providerGateway");
import type { VmRepositoryShape } from "../services/vms/repository";
import type { VmProviderGatewayShape } from "../services/vms/providerGateway";

test("a paid upgrade cancels a stale Go pause instead of stopping the upgraded VM", async () => {
  const calls: string[] = [];
  const repo = {
    findUserVm: () => Effect.succeed({ id: "row", userId: "u", billingTeamId: "u", billingPlanId: "go", status: "running",
      provider: "freestyle", providerVmId: "vm", providerMetadata: { cmuxGoPauseIntent: { requestedAt: "2026-09-01T00:00:00Z" } } }),
    mergeProviderMetadata: ({ patch }: { patch: Record<string, unknown> }) => Effect.sync(() => { writes.push(patch); }),
    markProviderObservedStatus: () => Effect.succeed(true),
    recordUsageEvent: () => Effect.void,
  } as unknown as VmRepositoryShape;
  const providers = {
    setRuntimeBudget: (_provider: string, _id: string, remaining: number | null) => Effect.sync(() => { calls.push(`budget:${remaining}`); }),
    pause: () => Effect.sync(() => { calls.push("pause"); }),
    resume: () => Effect.sync(() => { calls.push("resume"); throw new Error("already running"); }),
    getStatus: () => Effect.succeed("running"),
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.merge(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, providers));
  await Effect.runPromise(resumeVm({ userId: "u", billingTeamId: "u", providerVmId: "vm", callerPlanId: "pro" }).pipe(Effect.provide(layer)));
  expect(calls).toEqual(["budget:null"]);
  expect(writes).toContainEqual({ billingPlanId: "pro" });
  expect(writes).toContainEqual({ cmuxGoPauseIntent: null });
});
