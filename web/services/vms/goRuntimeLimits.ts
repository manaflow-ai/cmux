import { and, asc, eq, or, sql } from "drizzle-orm";
import * as Effect from "effect/Effect";
import { cloudDb } from "../../db/client";
import { cloudVms } from "../../db/schema";
import { getGoVmUsage } from "./goUsage";
import { GO_PAUSE_INTENT_KEY, pauseGoVm } from "./goPause";
import { VmDatabaseError } from "./errors";
import { VmProviderGateway } from "./providerGateway";
import { VmRepository } from "./repository";

/** The minute job stops compute only after a durable runtime total reaches its cap. */
export function enforceGoRuntimeLimits() {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const rows = yield* Effect.tryPromise({
      try: () => cloudDb().select().from(cloudVms).where(and(
        eq(cloudVms.billingPlanId, "go"), or(eq(cloudVms.status, "running"), sql`${cloudVms.providerMetadata}->'cmuxGoPauseIntent' is not null and ${cloudVms.providerMetadata}->'cmuxGoPauseIntent' <> 'null'::jsonb`),
      )).orderBy(asc(cloudVms.updatedAt)),
      catch: (cause) => new VmDatabaseError({ operation: "go_runtime_candidates", cause }),
    });
    const outcomes = yield* Effect.forEach(rows, (vm) => Effect.gen(function* () {
      if (!vm.providerVmId) return "skipped" as const;
      const usage = yield* Effect.tryPromise({
        try: () => getGoVmUsage(vm.userId),
        catch: (cause) => new VmDatabaseError({ operation: "go_runtime_usage", cause }),
      });
      const pending = vm.providerMetadata[GO_PAUSE_INTENT_KEY] != null;
      if (!usage) {
        if (pending && repo.mergeProviderMetadata) yield* repo.mergeProviderMetadata({ id: vm.id, patch: { [GO_PAUSE_INTENT_KEY]: null } });
        return "skipped" as const;
      }
      if (!pending && usage.remainingSeconds > 0) return "skipped" as const;
      yield* pauseGoVm(repo, providers, vm, vm.providerVmId, usage?.usedSeconds);
      return "paused" as const;
    }).pipe(Effect.catchAll((error) => Effect.sync(() => {
      console.error("[VM] Go runtime enforcement failed", { vmId: vm.id, error });
      return "error" as const;
    }))), { concurrency: 5 });
    return { checked: rows.length, paused: outcomes.filter((x) => x === "paused").length,
      errors: outcomes.filter((x) => x === "error").length };
  });
}
