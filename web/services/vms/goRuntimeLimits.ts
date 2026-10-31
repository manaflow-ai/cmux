import { and, asc, inArray, or, sql, eq } from "drizzle-orm";
import * as Effect from "effect/Effect";
import { cloudDb } from "../../db/client";
import { cloudVms } from "../../db/schema";
import { GO_UNLIMITED_RUNTIME_METADATA_KEY } from "./goUsage";
import { GO_PAUSE_INTENT_KEY, pauseBudgetVm } from "./goPause";
import { VmDatabaseError } from "./errors";
import { getPlanBudgetUsage, planBudgetsEnforced, type PlanBudgetUsage } from "./planUsage";
import { VmProviderGateway } from "./providerGateway";
import { VmRepository, type CloudVmRow } from "./repository";

/**
 * The minute job stops compute only after a durable runtime total reaches its
 * cap, when Pro and Max budgets are enabled. Plus has no hour cap; clear
 * legacy provider caps and stale pause intents once per machine.
 */
export function enforceGoRuntimeLimits() {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const rows = yield* Effect.tryPromise({
      try: () => cloudDb().select().from(cloudVms).where(and(
        inArray(cloudVms.billingPlanId, planBudgetsEnforced() ? ["go", "pro", "max"] : ["go"]),
        or(eq(cloudVms.status, "running"), sql`${cloudVms.providerMetadata}->'cmuxGoPauseIntent' is not null and ${cloudVms.providerMetadata}->'cmuxGoPauseIntent' <> 'null'::jsonb`),
      )).orderBy(asc(cloudVms.updatedAt)),
      catch: (cause) => new VmDatabaseError({ operation: "go_runtime_candidates", cause }),
    });
    const budgets = new Map<string, Promise<PlanBudgetUsage | null>>();
    const budgetFor = (userId: string) => {
      let usage = budgets.get(userId);
      if (!usage) {
        usage = getPlanBudgetUsage(userId);
        budgets.set(userId, usage);
      }
      return usage;
    };
    const clearIntent = (vm: CloudVmRow) => repo.mergeProviderMetadata
      ? repo.mergeProviderMetadata({ id: vm.id, patch: { [GO_PAUSE_INTENT_KEY]: null } })
      : Effect.void;
    const outcomes = yield* Effect.forEach(rows, (vm) => Effect.gen(function* () {
      if (!vm.providerVmId) return "skipped" as const;
      const pending = vm.providerMetadata[GO_PAUSE_INTENT_KEY] != null;
      if (vm.billingPlanId !== "go") {
        const budget = yield* Effect.tryPromise({
          try: () => budgetFor(vm.userId),
          catch: (cause) => new VmDatabaseError({ operation: "plan_budget_usage", cause }),
        });
        if (!budget) {
          if (pending) yield* clearIntent(vm);
          return "skipped" as const;
        }
        if (!pending && budget.remainingComputeSeconds > 0) return "skipped" as const;
        yield* pauseBudgetVm(repo, providers, vm, vm.providerVmId, budget.usedComputeSeconds);
        return "paused" as const;
      }
      if (vm.providerMetadata[GO_UNLIMITED_RUNTIME_METADATA_KEY] === true && !pending) return "skipped" as const;
      if (!providers.setRuntimeBudget || !repo.mergeProviderMetadata) {
        return yield* Effect.fail(new VmDatabaseError({ operation: "clear_starter_runtime_cap", cause: "Runtime cap cleanup is unavailable" }));
      }
      yield* providers.setRuntimeBudget(vm.provider, vm.providerVmId, null);
      yield* repo.mergeProviderMetadata({ id: vm.id, patch: {
        [GO_PAUSE_INTENT_KEY]: null, [GO_UNLIMITED_RUNTIME_METADATA_KEY]: true,
      } });
      return "skipped" as const;
    }).pipe(Effect.catchAll((error) => Effect.sync(() => {
      console.error("[VM] runtime allowance enforcement failed", { vmId: vm.id, error });
      return "error" as const;
    }))), { concurrency: 5 });
    return { checked: rows.length, paused: outcomes.filter((x) => x === "paused").length,
      errors: outcomes.filter((x) => x === "error").length };
  });
}
