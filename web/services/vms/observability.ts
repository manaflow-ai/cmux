import { randomUUID } from "node:crypto";
import { after } from "next/server";
import { trace, type Span } from "@opentelemetry/api";

import { POSTHOG_HOST, POSTHOG_PROJECT_KEY } from "../analytics/iosEventPolicy";
import { reportError } from "../observability/report";
import { setSpanAttributes } from "../telemetry";
import type { VmErrorResponseInput } from "./routeHelpers";

/**
 * Response header carrying the machine-readable VM error code. Set by
 * `vmErrorResponse` on every error so response finalizers (analytics,
 * timing) can classify an outcome without re-parsing the body.
 */
export const VM_ERROR_CODE_HEADER = "x-cmux-vm-error";

/**
 * Error codes that are the operator's fault, never the caller's: a
 * misconfigured deployment or an unavailable provider. A user cannot fix
 * these by changing the request. User-fault errors (limits, credits,
 * validation) are product signals, not incidents; alerting should filter
 * on the `cmux.vm.error_operator_fault` span attribute or the PostHog
 * `operator_fault` property.
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
 * Span leg of the VM error choke point: every VM error annotates the active
 * request span with the machine-readable code and the operator-context that
 * must never reach the response body (provider, image, env var name,
 * reason). Axiom is the operator-facing sink for these details; the caller
 * only ever sees the scrubbed payload from `vmErrorResponse`.
 */
export function annotateVmErrorSpan(span: Span, input: VmErrorResponseInput): void {
  const diagnostics = input.diagnostics ?? {};
  setSpanAttributes(span, {
    "cmux.vm.error_code": input.error,
    "cmux.vm.error_status": input.status,
    "cmux.vm.error_phase": input.phase ?? "unknown",
    "cmux.vm.error_operator_fault": isOperatorFaultVmError(input),
    "cmux.vm.error_reason": input.reason ?? input.message,
    "cmux.vm.error_provider": stringOrUndefined(diagnostics.provider),
    "cmux.vm.error_image": stringOrUndefined(diagnostics.image),
    "cmux.vm.error_env_var": stringOrUndefined(diagnostics.envVar),
  });
}

/**
 * Log leg of the VM error choke point. Called from `vmErrorResponse` for
 * every error response; emits a scrubbed structured log line for
 * operator-fault errors (Vercel runtime logs) and annotates the active
 * span so the full error context reaches Axiom. The Sentry delivery inside
 * `reportError` is intentionally inert for this app: `instrumentation.ts`
 * filters the shared Sentry project to coderouter events only.
 */
export function reportVmErrorResponse(input: VmErrorResponseInput): void {
  const activeSpan = trace.getActiveSpan();
  if (activeSpan) annotateVmErrorSpan(activeSpan, input);
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
 * Provisioning outcome choke point, run as a response finalizer. Two legs:
 *
 * - Span (Axiom): every attempt, success or failure, annotates the route
 *   span with the operation, outcome, and error code. Success-rate and
 *   latency questions are answered from Axiom traces.
 * - PostHog: failures only. `cloud_vm_provision` is the error signal that
 *   feeds the provisioning-failures insight and its alert; successes stay
 *   out of PostHog by design (2026-08-27 telemetry split).
 *
 * Reads only the response status and the `x-cmux-vm-error` header, so it
 * never touches the body stream.
 */
export function captureVmProvisionOutcome(
  input: {
    readonly userId: string;
    readonly operation: VmProvisionOperation;
    readonly response: Response;
    readonly span?: Span;
  },
  options: {
    readonly fetch?: typeof fetch;
    readonly env?: Record<string, string | undefined>;
  } = {},
): void {
  const status = input.response.status;
  const success = status < 400;
  const code = input.response.headers.get(VM_ERROR_CODE_HEADER) ?? undefined;
  const span = input.span ?? trace.getActiveSpan();
  if (span) {
    setSpanAttributes(span, {
      "cmux.vm.provision_operation": input.operation,
      "cmux.vm.provision_success": success,
      "cmux.vm.provision_error_code": code,
    });
  }
  if (success) return;
  const env = options.env ?? process.env;
  if (env.VERCEL_ENV !== "production" && env.CMUX_VM_ANALYTICS_FORCE !== "1") return;
  const properties: Record<string, string | number | boolean> = {
    operation: input.operation,
    success,
    status,
    // A missing code on a 5xx (a response that bypassed vmErrorResponse) is
    // still an operator fault; isOperatorFaultVmError treats every 5xx as one.
    operator_fault: isOperatorFaultVmError({ error: code ?? "", status }),
    schema_version: 2,
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

function stringOrUndefined(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
