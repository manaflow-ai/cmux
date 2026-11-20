import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

// A concurrency re-pause can still zero a provider cap. Plus must clear
// that cap before giving a machine back to a resume that won the race.
const { VmBillingGateway, noOpVmBillingGateway } = await import("../services/vms/billingGateway");
const { VmProviderOperationError } = await import("../services/vms/errors");
const { VmProviderGateway } = await import("../services/vms/providerGateway");
const { VmRepository } = await import("../services/vms/repository");
const { reconcileVmProviderStatuses } = await import("../services/vms/workflows");
type CloudVmRow = import("../services/vms/repository").CloudVmRow;
type VmRepositoryShape = import("../services/vms/repository").VmRepositoryShape;
type VmProviderGatewayShape = import("../services/vms/providerGateway").VmProviderGatewayShape;

const PROVIDER_VM_ID = "provider-vm-go-woken";

function goRow(status: CloudVmRow["status"]): CloudVmRow {
  const now = new Date();
  return {
    id: "00000000-0000-4000-8000-00000000a60e",
    userId: "user-go-wake",
    billingTeamId: null,
    billingPlanId: "go",
    provider: "freestyle",
    providerVmId: PROVIDER_VM_ID,
    displayName: null,
    slug: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status,
    idempotencyKey: null,
    createdAt: now,
    updatedAt: now,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    networkPolicy: null,
    networkPolicyStatus: null,
    agentUpdates: null,
    ownerTeamId: "user-go-wake",
    coderouterPoolId: null,
  };
}

/** A woken Go machine whose re-pause loses to a resume that lands meanwhile. */
async function runLostRace(options: { readonly budgetFails?: boolean } = {}) {
  const budgets: (number | null)[] = [];
  const resumes: string[] = [];
  const rereads = [goRow("paused"), goRow("running")];
  const repo: Partial<VmRepositoryShape> = {
    reconciliationCandidates: () => Effect.succeed([goRow("paused")]),
    findUserVm: () => Effect.succeed(rereads.length > 1 ? rereads.shift()! : rereads[0]!),
    claimUnexpectedWakeRepause: () => Effect.succeed(true),
    markProviderObservedStatus: () => Effect.succeed(true),
    recordUsageEvent: () => Effect.void,
  };
  const providers: Partial<VmProviderGatewayShape> = {
    getStatus: () => Effect.succeed("running"),
    pause: () => Effect.void,
    setRuntimeBudget: (_provider, vmId, seconds) => Effect.sync(() => {
      budgets.push(seconds);
    }).pipe(Effect.andThen(options.budgetFails && seconds !== 0
      ? Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: `setRuntimeBudget(${vmId})`, cause: new Error("refused") }))
      : Effect.void)),
    resume: (_provider, vmId) => Effect.sync(() => {
      resumes.push(vmId);
      return { provider: "freestyle" as const, providerVmId: vmId, status: "running" as const, image: "snapshot-test", createdAt: Date.now() };
    }),
  };
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo as VmRepositoryShape),
    Layer.succeed(VmProviderGateway, providers as VmProviderGatewayShape),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  await Effect.runPromise(reconcileVmProviderStatuses({ unexpectedWakeConfirmMs: 0 }).pipe(Effect.provide(layer)));
  return { budgets, resumes };
}

describe("giving a Plus machine back after a lost re-pause race", () => {
  test("clears the runtime cap before resuming", async () => {
    const { budgets, resumes } = await runLostRace();
    expect(budgets).toEqual([0, null]);
    expect(resumes).toEqual([PROVIDER_VM_ID]);
  });

  test("still resumes when clearing the cap fails", async () => {
    const { budgets, resumes } = await runLostRace({ budgetFails: true });
    expect(budgets).toEqual([0, null]);
    expect(resumes).toEqual([PROVIDER_VM_ID]);
  });
});
