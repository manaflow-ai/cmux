import * as Effect from "effect/Effect";
import { VmDatabaseError, VmNotFoundError, VmOperationUnsupportedError } from "./errors";
import type { VmProviderGatewayShape } from "./providerGateway";
import type { CloudVmRow, VmRepositoryShape } from "./repository";

export const GO_PAUSE_INTENT_KEY = "cmuxGoPauseIntent";

/** Provider side effects follow durable intent; failed finalization is retried by the minute job. */
export function pauseGoVm(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
  usedSeconds?: number,
) {
  return Effect.gen(function* () {
    if (!providers.pause || !providers.setRuntimeBudget) {
      return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "pause" }));
    }
    const mergeMetadata = repo.mergeProviderMetadata;
    if (!mergeMetadata) return yield* Effect.fail(new VmDatabaseError({ operation: "go_pause_intent", cause: "Durable metadata writes are unavailable" }));
    yield* mergeMetadata({ id: vm.id, patch: {
      [GO_PAUSE_INTENT_KEY]: { requestedAt: new Date().toISOString(), reason: "go_hours_limit" },
    } });
    yield* providers.setRuntimeBudget(vm.provider, providerVmId, 0);
    // The database may already say paused. An idempotent provider pause also
    // stops machines resumed outside the control plane.
    yield* providers.pause(vm.provider, providerVmId);
    const recorded = yield* repo.markProviderObservedStatus({ id: vm.id, providerVmId, status: "paused" });
    if (!recorded) return yield* Effect.fail(new VmNotFoundError({ vmId: providerVmId }));
    yield* mergeMetadata({ id: vm.id, patch: { [GO_PAUSE_INTENT_KEY]: null } });
    yield* repo.recordUsageEvent({ userId: vm.userId, billingTeamId: vm.billingTeamId, billingPlanId: "go",
      vmId: vm.id, eventType: "vm.paused", provider: vm.provider, imageId: vm.imageId,
      metadata: { source: "go_hours_limit", usedSeconds, automated: true },
    }).pipe(Effect.catchAll(() => Effect.void));
  });
}
