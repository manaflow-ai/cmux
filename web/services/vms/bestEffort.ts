import { metrics, trace } from "@opentelemetry/api";
import * as Effect from "effect/Effect";
import { reportError } from "../observability/report";

/**
 * Context attached to a best-effort failure report. Ids only — never tokens,
 * lease material, provider credentials, or request bodies.
 */
export type BestEffortContext = Record<string, string | number | boolean | null | undefined>;

const bestEffortFailureCounter = metrics.getMeter("cmux-vm").createCounter(
  "cmux.vm.best_effort_failure",
  {
    description:
      "Best-effort VM workflow side effects (refunds, usage events, rollbacks) that failed without failing the parent workflow",
  },
);

/**
 * Wraps a best-effort side effect (billing refund, usage event, rollback,
 * provider cleanup). The failure still never propagates to the parent
 * workflow, but it is no longer silent: it is logged with a scrubbed
 * summary, counted on the OTel meter, attached to the active span, and
 * captured to Sentry with the operation label and context.
 */
export function bestEffort(operation: string, context: BestEffortContext = {}) {
  return <A, E, R>(effect: Effect.Effect<A, E, R>): Effect.Effect<void, never, R> =>
    effect.pipe(
      Effect.asVoid,
      Effect.catchAll((error) =>
        Effect.sync(() => {
          reportBestEffortFailure(operation, error, context);
        })
      ),
    );
}

/** Reporting must never change the caller's control flow. */
export function reportBestEffortFailure(
  operation: string,
  error: unknown,
  context: BestEffortContext = {},
): void {
  try {
    bestEffortFailureCounter.add(1, { "cmux.vm.best_effort.operation": operation });
    const span = trace.getActiveSpan();
    if (span) {
      span.addEvent("cmux.vm.best_effort_failure", {
        "cmux.vm.best_effort.operation": operation,
        "cmux.error_message": error instanceof Error ? error.message : String(error),
      });
    }
  } catch {
    // Telemetry must never throw into workflow code.
  }
  reportError(error, {
    subsystem: "vm-cloud",
    bestEffortOperation: operation,
    ...context,
  });
}
