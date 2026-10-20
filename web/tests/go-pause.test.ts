import { expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import { GO_PAUSE_INTENT_KEY, pauseGoVm } from "../services/vms/goPause";
import { VmDatabaseError, VmProviderOperationError } from "../services/vms/errors";
import type { CloudVmRow, VmRepositoryShape } from "../services/vms/repository";
import type { VmProviderGatewayShape } from "../services/vms/providerGateway";

function setup() {
  const calls: string[] = [];
  const metadata: Record<string, unknown> = {};
  const vm = { id: "vm-1", providerVmId: "provider-1", userId: "u", billingTeamId: "u", billingPlanId: "go",
    provider: "freestyle", imageId: "small", status: "paused", providerMetadata: metadata } as CloudVmRow;
  let failStatus = false;
  const repo = {
    mergeProviderMetadata: ({ patch }: { patch: Record<string, unknown> }) => Effect.sync(() => {
      Object.assign(metadata, patch); calls.push(patch[GO_PAUSE_INTENT_KEY] ? "intent" : "clear");
    }),
    markProviderObservedStatus: () => {
      calls.push("status");
      return failStatus ? Effect.fail(new VmDatabaseError({ operation: "pause", cause: "offline" })) : Effect.succeed(true);
    },
    recordUsageEvent: () => Effect.sync(() => { calls.push("event"); }),
  } as unknown as VmRepositoryShape;
  const providers = {
    setRuntimeBudget: () => Effect.sync(() => { calls.push("budget"); }),
    pause: () => Effect.sync(() => { calls.push("pause"); }),
  } as unknown as VmProviderGatewayShape;
  return { vm, repo, providers, calls, metadata, failStatus: (value: boolean) => { failStatus = value; } };
}

test("persists intent before pausing a provider even when the row already says paused", async () => {
  const s = setup();
  await Effect.runPromise(pauseGoVm(s.repo, s.providers, s.vm, "provider-1"));
  expect(s.calls).toEqual(["intent", "budget", "pause", "status", "clear", "event"]);
  expect(s.metadata[GO_PAUSE_INTENT_KEY]).toBeNull();
});

test("failed database finalization keeps a retryable pause intent", async () => {
  const s = setup(); s.failStatus(true);
  await Effect.runPromiseExit(pauseGoVm(s.repo, s.providers, s.vm, "provider-1"));
  expect(s.metadata[GO_PAUSE_INTENT_KEY]).toBeTruthy();
  expect(s.calls).not.toContain("clear");
  s.failStatus(false);
  await Effect.runPromise(pauseGoVm(s.repo, s.providers, s.vm, "provider-1"));
  expect(s.metadata[GO_PAUSE_INTENT_KEY]).toBeNull();
  expect(s.calls.filter((x) => x === "event")).toHaveLength(1);
});

test("a failed provider pause never closes the database interval", async () => {
  const s = setup();
  const failingProvider = { ...s.providers, pause: () => Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "pause", cause: "offline" })) };
  await Effect.runPromiseExit(pauseGoVm(s.repo, failingProvider, s.vm, "provider-1"));
  expect(s.metadata[GO_PAUSE_INTENT_KEY]).toBeTruthy();
  expect(s.calls).not.toContain("status");
});
