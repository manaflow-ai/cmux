import { AsyncLocalStorage } from "node:async_hooks";
import { reportError } from "../observability/report";
// Namespace import: test suites replace `./analytics` with partial mocks, and a
// missing named export must degrade to "no PostHog leg", not a link error.
import * as analytics from "./analytics";
import { errorSummary, exceptionEvent } from "./exceptionEvent";

type CodeRouterFailure =
  | "credential_decrypt"
  | "provider_usage"
  | "provider_refresh"
  | "provider_rate_limit"
  | "legacy_cleanup"
  | "rds"
  | "analytics_delivery"
  | "analytics_query"
  | "usage_ledger"
  | "upstream_transport"
  | "route_crash"
  | "health_check"
  | "alerts";

export type CoderouterFailureOptions = {
  /** Set false when the active request finalizer emits the trace-linked exception. */
  readonly emitPostHogException?: boolean;
};

/**
 * Failures a deploy or an operator caused. PostHog files these as `error`
 * issues; everything else (provider transport, rate limits) is `warning`.
 */
const OPERATOR_FAULT_FAILURES: ReadonlySet<CodeRouterFailure> = new Set([
  "credential_decrypt",
  "rds",
  "analytics_delivery",
  "analytics_query",
  "usage_ledger",
  "route_crash",
  "health_check",
  "alerts",
]);

const SENSITIVE_CONTEXT_KEY = /account.?id|authorization|body|content|cookie|credential|email|header|key|prompt|response|secret|session|team.?id|token/i;
// A route finalizer emits one trace-linked exception after the handler returns.
// Keep step failures out of Error Tracking while that route scope is active;
// cron and other background callers still emit their standalone exception.
const routeFailureScope = new AsyncLocalStorage<boolean>();

export function runWithCoderouterFailureScope<T>(fn: () => T): T {
  return routeFailureScope.run(true, fn);
}

export function addCoderouterBreadcrumb(
  category: string,
  message: string,
  data: Readonly<Record<string, string | number | boolean>> = {},
  level: "debug" | "info" | "warning" | "error" = "info",
): void {
  const safeData = Object.fromEntries(
    Object.entries(data).filter(([key]) => !SENSITIVE_CONTEXT_KEY.test(key)),
  );
  void import("@sentry/nextjs")
    .then((Sentry) => {
      Sentry.addBreadcrumb({
        category: `coderouter.${category}`,
        message,
        level,
        data: safeData,
      });
    })
    .catch(() => {
      // Observability must never alter product control flow.
    });
}

/**
 * Emit an alertable error without ever forwarding a provider error message,
 * response body, credential, tenant ID, or account ID to logs/Sentry.
 *
 * Two sinks. Sentry (legacy, kept for existing alert rules) receives a
 * synthetic `coderouter.<failure>` error with the context as tags. PostHog
 * Error Tracking, the primary sink, receives an `$exception` carrying a safe
 * error class and repository-only stack frames, grouped by failure kind and
 * provider. The original error is never sent to Sentry. Events are joined
 * to the ClickHouse route row by the ledger request id when a route is active.
 */
export function reportCoderouterFailure(
  failure: CodeRouterFailure,
  error: unknown,
  context: Readonly<Record<string, string | number | boolean>> = {},
  options: CoderouterFailureOptions = {},
): void {
  const errorType = error instanceof Error ? error.name : typeof error;
  const safeContext = sanitizeCoderouterFailureContext(context);
  addCoderouterBreadcrumb(
    "error",
    `coderouter.${failure}`,
    { failure, errorType, ...safeContext },
    "error",
  );
  // Keep Sentry's exception message synthetic. Provider and infrastructure
  // errors can contain credentials or connection strings.
  reportError(new Error(`coderouter.${failure}`), {
    service: "coderouter",
    failure,
    errorType,
    ...safeContext,
  });
  const provider = typeof context.provider === "string" ? context.provider : "unknown";
  const requestId = typeof context.request_id === "string" ? context.request_id : undefined;
  if (
    options.emitPostHogException !== false &&
    routeFailureScope.getStore() !== true &&
    failure !== "analytics_delivery"
  ) {
    analytics.captureCoderouterRawBatch?.([
      exceptionEvent({
        type: `coderouter.${failure}`,
        value: errorSummary(error),
        fingerprint: `coderouter.${failure}:${provider}`,
        level: OPERATOR_FAULT_FAILURES.has(failure) ? "error" : "warning",
        error,
        properties: {
          coderouter_failure: failure,
          coderouter_error_type: errorType,
          ...(requestId ? { coderouter_request_id: requestId } : {}),
          ...safeContext,
        },
      }),
    ]);
  }
}

export function sanitizeCoderouterFailureContext(
  context: Readonly<Record<string, string | number | boolean>>,
): Record<string, string | number | boolean> {
  return Object.fromEntries(
    Object.entries(context).filter(([key]) => !SENSITIVE_CONTEXT_KEY.test(key) || key === "request_id"),
  );
}
