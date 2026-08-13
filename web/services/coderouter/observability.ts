import {
  isSensitiveObservabilityKey,
  reportError,
} from "../observability/report";

type CodeRouterFailure =
  | "credential_decrypt"
  | "provider_usage"
  | "provider_refresh"
  | "provider_rate_limit"
  | "legacy_cleanup"
  | "rds"
  | "analytics_delivery"
  | "analytics_query"
  | "configuration"
  | "upstream_transport";

export function addCoderouterBreadcrumb(
  category: string,
  message: string,
  data: Readonly<Record<string, string | number | boolean>> = {},
  level: "debug" | "info" | "warning" | "error" = "info",
): void {
  const safeData = Object.fromEntries(
    Object.entries(data).filter(([key]) => !isSensitiveObservabilityKey(key)),
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
 */
export function reportCoderouterFailure(
  failure: CodeRouterFailure,
  error: unknown,
  context: Readonly<Record<string, string | number | boolean>> = {},
): void {
  const errorType = error instanceof Error ? error.name : typeof error;
  const safeContext = Object.fromEntries(
    Object.entries(context).filter(([key]) => !isSensitiveObservabilityKey(key)),
  );
  addCoderouterBreadcrumb(
    "error",
    `coderouter.${failure}`,
    { failure, errorType, ...safeContext },
    "error",
  );
  reportError(new Error(`coderouter.${failure}`), {
    service: "coderouter",
    failure,
    errorType,
    ...safeContext,
  });
}
