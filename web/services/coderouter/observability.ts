import { reportError } from "../observability/report";

type CodeRouterFailure =
  | "credential_decrypt"
  | "provider_usage"
  | "provider_refresh"
  | "provider_rate_limit"
  | "legacy_cleanup"
  | "rds";

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
  reportError(new Error(`coderouter.${failure}`), {
    service: "coderouter",
    failure,
    errorType,
    ...context,
  });
}
