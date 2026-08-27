import { randomUUID } from "node:crypto";
import { after } from "next/server";

import { POSTHOG_HOST, POSTHOG_PROJECT_KEY } from "../analytics/iosEventPolicy";
import { reportError } from "../observability/report";
import type { VmErrorResponseInput } from "./routeHelpers";

/**
 * Response header carrying the machine-readable VM error code. Set by
 * `vmErrorResponse` on every error so response finalizers (analytics,
 * timing) can classify an outcome without re-parsing the body.
 */
export const VM_ERROR_CODE_HEADER = "x-cmux-vm-error";

/**
 * Error codes that are the operator's fault, never the caller's: a
 * misconfigured deployment or an unavailable provider. These reach Sentry
 * even when their HTTP status is not a 5xx, because a user cannot fix them
 * by changing the request. User-fault errors (limits, credits, validation)
 * stay out of Sentry; they are product signals, not incidents.
 */
const OPERATOR_FAULT_VM_ERROR_CODES: ReadonlySet<string> = new Set([
  "vm_image_config_error",
  "vm_create_disabled",
  "vm_cloud_service_unavailable",
  "vm_base_create_failed",
  "vm_create_failed",
]);

export function isOperatorFaultVmError(input: {
  readonly error: string;
  readonly status: number;
}): boolean {
  return input.status >= 500 || OPERATOR_FAULT_VM_ERROR_CODES.has(input.error);
}

/**
 * Sentry leg of the VM error choke point. Called from `vmErrorResponse` for
 * every error response; reports only operator-fault errors. The fingerprint
 * is the error code plus provider, so one misconfiguration is one Sentry
 * issue no matter how many users hit it, and a "first seen" alert rule can
 * page without flooding.
 */
export function reportVmErrorResponse(input: VmErrorResponseInput): void {
  if (!isOperatorFaultVmError(input)) return;
  const diagnostics = input.diagnostics ?? {};
  const provider = typeof diagnostics.provider === "string" ? diagnostics.provider : undefined;
  reportError(
    new Error(`cloud VM ${input.error}: ${input.message}`),
    {
      subsystem: "cloud_vm_api",
      code: input.error,
      status: input.status,
      phase: input.phase ?? "unknown",
      reason: input.reason ?? input.message,
      ...(input.details ?? {}),
      ...diagnostics,
    },
    { fingerprint: ["cmux-vm-error", input.error, provider ?? "unknown"] },
  );
}

export type VmProvisionOperation = "create" | "base_open" | "base_reset";

/**
 * PostHog leg: one `cloud_vm_provision` event per provisioning attempt,
 * success or failure, keyed to the requesting user. Feeds the create
 * success-rate insight and its Slack alert. Reads only the response status
 * and the `x-cmux-vm-error` header, so it can run as a response finalizer
 * without touching the body stream.
 */
export function captureVmProvisionOutcome(
  input: {
    readonly userId: string;
    readonly operation: VmProvisionOperation;
    readonly response: Response;
  },
  options: {
    readonly fetch?: typeof fetch;
    readonly env?: Record<string, string | undefined>;
  } = {},
): void {
  const env = options.env ?? process.env;
  if (env.VERCEL_ENV !== "production" && env.CMUX_VM_ANALYTICS_FORCE !== "1") return;
  const status = input.response.status;
  const code = input.response.headers.get(VM_ERROR_CODE_HEADER) ?? undefined;
  const properties: Record<string, string | number | boolean> = {
    operation: input.operation,
    success: status < 400,
    status,
    schema_version: 1,
    $insert_id: randomUUID(),
    $geoip_disable: true,
  };
  if (code) properties.error_code = code;
  const body = JSON.stringify({
    api_key: POSTHOG_PROJECT_KEY,
    event: "cloud_vm_provision",
    distinct_id: input.userId,
    properties,
    timestamp: new Date().toISOString(),
  });
  const fetchImpl = options.fetch ?? fetch;
  const task = fetchImpl(`${POSTHOG_HOST}/capture/`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
    signal: AbortSignal.timeout(2_000),
  }).then(() => undefined).catch(() => undefined);
  try {
    // Callback form keeps the capture inside the request lifecycle; outside a
    // request scope (tests) `after` throws and the fire-and-forget task above
    // still runs.
    after(() => task);
  } catch {
    void task;
  }
}
