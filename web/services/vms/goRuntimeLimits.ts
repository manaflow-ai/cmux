import { and, asc, eq } from "drizzle-orm";
import * as Effect from "effect/Effect";
import { cloudDb } from "../../db/client";
import { cloudVms } from "../../db/schema";
import { getGoVmUsage } from "./goUsage";
import { VmDatabaseError, VmOperationUnsupportedError } from "./errors";
import { VmProviderGateway } from "./providerGateway";
import { VmRepository } from "./repository";

/** The minute job stops compute only after a durable runtime total reaches its cap. */
export function enforceGoRuntimeLimits() {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const rows = yield* Effect.tryPromise({
      try: () => cloudDb().select().from(cloudVms).where(and(
        eq(cloudVms.billingPlanId, "go"), eq(cloudVms.status, "running"),
      )).orderBy(asc(cloudVms.updatedAt)),
      catch: (cause) => new VmDatabaseError({ operation: "go_runtime_candidates", cause }),
    });
    const outcomes = yield* Effect.forEach(rows, (vm) => Effect.gen(function* () {
      if (!vm.providerVmId) return "skipped" as const;
      const usage = yield* Effect.tryPromise({
        try: () => getGoVmUsage(vm.userId),
        catch: (cause) => new VmDatabaseError({ operation: "go_runtime_usage", cause }),
      });
      // A paid upgrade removes the Go runtime cap.
      if (!usage || usage.remainingSeconds > 0) return "skipped" as const;
      if (!providers.pause) return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "pause" }));
      yield* providers.pause(vm.provider, vm.providerVmId);
      // Never mark a machine paused when the provider pause failed. The next
      // job retries it and the meter continues to count its actual state.
      yield* repo.markProviderObservedStatus({ id: vm.id, providerVmId: vm.providerVmId, status: "paused" });
      yield* repo.recordUsageEvent({ userId: vm.userId, billingTeamId: vm.billingTeamId, billingPlanId: "go",
        vmId: vm.id, eventType: "vm.paused", provider: vm.provider, imageId: vm.imageId,
        metadata: { source: "go_hours_limit", usedSeconds: usage.usedSeconds, automated: true },
      }).pipe(Effect.catchAll(() => Effect.void));
      return "paused" as const;
    }).pipe(Effect.catchAll((error) => Effect.sync(() => {
      console.error("[VM] Go runtime enforcement failed", { vmId: vm.id, error });
      return "error" as const;
    }))), { concurrency: 5 });
    return { checked: rows.length, paused: outcomes.filter((x) => x === "paused").length,
      errors: outcomes.filter((x) => x === "error").length };
  });
}
