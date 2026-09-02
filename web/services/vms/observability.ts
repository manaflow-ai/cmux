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

/**
 * 5xx codes that are expected product limitations, not incidents. The status
 * stays >= 500 for HTTP honesty (501 Not Implemented), but a provider that
 * simply lacks a capability is neither the caller's nor the operator's fault
 * and must not page anyone.
 */
const EXPECTED_5XX_VM_ERROR_CODES: ReadonlySet<string> = new Set([
  "vm_operation_unsupported",
]);

export function isOperatorFaultVmError(input: {
  readonly error: string;
  readonly status: number;
}): boolean {
  if (EXPECTED_5XX_VM_ERROR_CODES.has(input.error)) return false;
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

export type VmProvisionOperation = "create" | "fork" | "restore" | "base_open" | "base_reset";

/** Stable PostHog event name for one bounded VM reaper invocation. */
export const VM_REAPER_POSTHOG_EVENT = "cloud_vm_reaper_run";
export const VM_REAPER_POSTHOG_DISTINCT_ID = "cmux-vm-reaper";

export type VmReaperSummaryTelemetry = {
  readonly reportOnly: boolean;
  readonly candidates: number;
  readonly reported: number;
  readonly deleted: number;
  readonly skipped: number;
  readonly errors: number;
  readonly orphanVolumes: {
    readonly candidates: number;
    readonly deleted: number;
    readonly reported: number;
    readonly unknownAttachment: number;
    readonly unknownReference: number;
    readonly scanned: number;
    readonly providerPages: number;
    readonly coveragePartial: boolean;
    readonly skipped: number;
    readonly errors: number;
  };
  readonly stuckProvisioning: {
    readonly candidates: number;
    readonly reported: number;
    readonly recovered: number;
    readonly failed: number;
    readonly destroyed: number;
    readonly skipped: number;
    readonly errors: number;
  };
};

type VmReaperTelemetryOptions = {
  readonly env?: Record<string, string | undefined>;
  readonly fetch?: typeof fetch;
  readonly now?: Date;
};

const VM_REAPER_CAPTURE_TIMEOUT_MS = 2_000;

/**
 * Deliver one aggregate reaper outcome to PostHog.
 *
 * The event is production-only by default. A force flag is useful for a
 * staging smoke test. Delivery is best effort and bounded so telemetry can
 * never turn a successful report run into a failed cron request.
 */
export async function captureVmReaperSummary(
  summary: VmReaperSummaryTelemetry,
  options: VmReaperTelemetryOptions = {},
): Promise<void> {
  const env = options.env ?? process.env;
  const enabled = env.VERCEL_ENV === "production" ||
    env.CMUX_VM_REAPER_ANALYTICS_FORCE === "1" ||
    env.CMUX_VM_ANALYTICS_FORCE === "1";
  if (!enabled) return;

  const properties: Record<string, string | number | boolean> = {
    report_only: true,
    candidates: boundedTelemetryCount(summary.candidates),
    reported: boundedTelemetryCount(summary.reported),
    deleted: boundedTelemetryCount(summary.deleted),
    skipped: boundedTelemetryCount(summary.skipped),
    errors: boundedTelemetryCount(summary.errors),
    orphan_volume_candidates: boundedTelemetryCount(summary.orphanVolumes.candidates),
    orphan_volume_deleted: boundedTelemetryCount(summary.orphanVolumes.deleted),
    orphan_volume_reported: boundedTelemetryCount(summary.orphanVolumes.reported),
    orphan_volume_unknown_attachment: boundedTelemetryCount(summary.orphanVolumes.unknownAttachment),
    orphan_volume_unknown_reference: boundedTelemetryCount(summary.orphanVolumes.unknownReference),
    orphan_volume_scanned: boundedTelemetryCount(summary.orphanVolumes.scanned),
    orphan_volume_provider_pages: boundedTelemetryCount(summary.orphanVolumes.providerPages),
    orphan_volume_coverage_partial: summary.orphanVolumes.coveragePartial,
    orphan_volume_skipped: boundedTelemetryCount(summary.orphanVolumes.skipped),
    orphan_volume_errors: boundedTelemetryCount(summary.orphanVolumes.errors),
    stuck_provisioning_candidates: boundedTelemetryCount(summary.stuckProvisioning.candidates),
    stuck_provisioning_reported: boundedTelemetryCount(summary.stuckProvisioning.reported),
    stuck_provisioning_recovered: boundedTelemetryCount(summary.stuckProvisioning.recovered),
    stuck_provisioning_failed: boundedTelemetryCount(summary.stuckProvisioning.failed),
    stuck_provisioning_destroyed: boundedTelemetryCount(summary.stuckProvisioning.destroyed),
    stuck_provisioning_skipped: boundedTelemetryCount(summary.stuckProvisioning.skipped),
    stuck_provisioning_errors: boundedTelemetryCount(summary.stuckProvisioning.errors),
    schema_version: 2,
    $insert_id: randomUUID(),
    $geoip_disable: true,
    $process_person_profile: false,
  };
  const now = options.now ?? new Date();
  const body = JSON.stringify({
    api_key: POSTHOG_PROJECT_KEY,
    event: VM_REAPER_POSTHOG_EVENT,
    distinct_id: VM_REAPER_POSTHOG_DISTINCT_ID,
    properties,
    timestamp: now.toISOString(),
  });
  const fetchImpl = options.fetch ?? fetch;
  const task = postVmReaperTelemetry(body, fetchImpl);
  try {
    // Keep the capture alive after a Vercel response. In tests and scripts there
    // is no Next request scope, so the task is still awaited below.
    after(() => task);
  } catch {
    // No request scope. The caller still awaits the bounded task.
  }
  await task;
}

async function postVmReaperTelemetry(body: string, fetchImpl: typeof fetch): Promise<void> {
  try {
    const response = await fetchImpl(`${POSTHOG_HOST}/capture/`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
      signal: AbortSignal.timeout(VM_REAPER_CAPTURE_TIMEOUT_MS),
    });
    if (!response.ok) {
      console.error("[VM] reaper summary telemetry rejected", { status: response.status });
    }
  } catch (error) {
    console.error("[VM] reaper summary telemetry failed", safeTelemetryError(error));
  }
}

function boundedTelemetryCount(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(1_000_000_000, Math.trunc(value)));
}

function safeTelemetryError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  return message.replace(/Bearer\s+\S+/gi, "Bearer [redacted]").slice(0, 300);
}

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
