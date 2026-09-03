import { reportError } from "../observability/report";

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
  | "upstream_transport";

const SENSITIVE_CONTEXT_KEY = /account.?id|authorization|body|content|cookie|credential|email|header|key|prompt|response|secret|session|team.?id|token/i;

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
 */
export function reportCoderouterFailure(
  failure: CodeRouterFailure,
  error: unknown,
  context: Readonly<Record<string, string | number | boolean>> = {},
): void {
  const errorType = error instanceof Error ? error.name : typeof error;
  addCoderouterBreadcrumb(
    "error",
    `coderouter.${failure}`,
    { failure, errorType, ...context },
    "error",
  );
  reportError(new Error(`coderouter.${failure}`), {
    service: "coderouter",
    failure,
    errorType,
    ...context,
  });
}
