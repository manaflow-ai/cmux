import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmLimitExceededError } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { createVm } from "../services/vms/workflows";

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
});
