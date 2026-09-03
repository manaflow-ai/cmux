import { randomUUID } from "node:crypto";
import { after } from "next/server";
import { trace, type Span } from "@opentelemetry/api";

import { POSTHOG_HOST, POSTHOG_PROJECT_KEY } from "../analytics/iosEventPolicy";
import { reportError } from "../observability/report";
import { setSpanAttributes, spanTraceIds } from "../telemetry";
import { currentVmRequestContext, type VmRequestContext } from "./requestContext";
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
 * Log, Sentry and request-context leg of the VM error choke point. Called
 * from `vmErrorResponse` for EVERY error response:
 *
 * - annotates the active span so the full operator context reaches Axiom;
 * - records the error on the request context so the response finalizer can
 *   ship it to PostHog with the user, client, duration and trace ids;
 * - reports to Sentry. Operator faults are `error` level, user faults are
 *   `warning`, both fingerprinted by code and provider so one condition is
 *   one issue. Every event carries the trace id as a tag and trace context.
 */
export function reportVmErrorResponse(input: VmErrorResponseInput): void {
  const activeSpan = trace.getActiveSpan();
  if (activeSpan) annotateVmErrorSpan(activeSpan, input);
  const context = currentVmRequestContext();
  if (context) context.lastError = input;
  const diagnostics = input.diagnostics ?? {};
  const provider = stringOrUndefined(diagnostics.provider);
  const operatorFault = isOperatorFaultVmError(input);
  reportError(
    new Error(`cloud VM ${input.error}: ${input.message}`),
    {
      subsystem: "cloud_vm_api",
      code: input.error,
      status: input.status,
      phase: input.phase ?? "unknown",
      operator_fault: operatorFault,
      reason: input.reason ?? input.message,
      operation: context?.operation,
      route: context?.route,
      user_id: context?.userId,
      client: context?.client,
      vercel_request_id: context?.vercelRequestId,
      ...(input.details ?? {}),
      ...diagnostics,
    },
    {
      fingerprint: ["cmux-vm-error", input.error, provider ?? "unknown"],
      level: operatorFault ? "error" : "warning",
      tags: {
        "vm.error_code": input.error,
        "vm.phase": input.phase ?? "unknown",
        "vm.status": input.status,
        "vm.operator_fault": operatorFault,
        "vm.operation": context?.operation,
        "vm.provider": provider,
        "client.name": context?.client.name,
        "client.version": context?.client.version,
        "client.channel": context?.client.channel,
        user_id: context?.userId,
      },
    },
  );
}

/**
 * Operations a client polls on a timer. Their successes stay out of PostHog
 * (Axiom keeps 100% of them); their failures are captured like any other.
 */
const POLLED_VM_OPERATIONS: ReadonlySet<string> = new Set([
  "list",
  "status",
  "stats",
  "list_sessions",
  "get_tunnel",
]);

/** PostHog event carrying one Cloud VM API request outcome with latency. */
export const VM_REQUEST_POSTHOG_EVENT = "cloud_vm_request";

type PostHogProperties = Record<string, string | number | boolean>;

function vmAnalyticsEnabled(env: Record<string, string | undefined>): boolean {
  return env.VERCEL_ENV === "production" || env.CMUX_VM_ANALYTICS_FORCE === "1";
}

function requestTelemetryProperties(
  context: VmRequestContext,
  ids: { traceId?: string; spanId?: string } | undefined,
): PostHogProperties {
  const properties: PostHogProperties = {
    operation: context.operation,
    route: context.route,
    method: context.method,
  };
  const optional: Record<string, string | undefined> = {
    trace_id: ids?.traceId ?? context.traceId,
    span_id: ids?.spanId ?? context.spanId,
    client_trace_id: context.client.traceId,
    client_request_id: context.client.requestId,
    vercel_request_id: context.vercelRequestId,
    client_name: context.client.name,
    client_version: context.client.version,
    client_build: context.client.build,
    client_channel: context.client.channel,
  };
  for (const [key, value] of Object.entries(optional)) {
    if (value) properties[key] = value;
  }
  return properties;
}

/**
 * Per-request outcome choke point, run as the response finalizer of every
 * Cloud VM route (`withAuthedVmApiRoute`). Three legs:
 *
 * - Span (Axiom): success flag, wall-clock duration, error code, user id.
 * - PostHog `cloud_vm_request`: every failure, plus successes of the
 *   operations a user waits on (create, attach, base open, ...) with their
 *   duration. Polled reads succeed silently.
 * - PostHog `$exception` (Error Tracking): every failure, fingerprinted by
 *   error code, with the scrubbed reason, phase and the same ids.
 *
 * Every event carries the server trace id, so a PostHog row, a Sentry issue
 * and an Axiom trace of one failure share one key. Reads only the status
 * and the `x-cmux-vm-error` header, never the body stream.
 */
export function captureVmRequestOutcome(
  input: {
    readonly context: VmRequestContext;
    readonly response: Response;
    readonly span?: Span;
    readonly durationMs: number;
  },
  options: {
    readonly fetch?: typeof fetch;
    readonly env?: Record<string, string | undefined>;
  } = {},
): void {
  const { context, response } = input;
  const status = response.status;
  const success = status < 400;
  const code = response.headers.get(VM_ERROR_CODE_HEADER) ?? undefined;
  const span = input.span ?? trace.getActiveSpan();
  const ids = spanTraceIds(span) ?? (context.traceId ? { traceId: context.traceId, spanId: context.spanId ?? "" } : undefined);
  const durationMs = Math.round(input.durationMs * 100) / 100;
  if (span) {
    setSpanAttributes(span, {
      "cmux.vm.request_success": success,
      "cmux.vm.request_duration_ms": durationMs,
      "cmux.vm.request_error_code": code,
      "cmux.user_id": context.userId,
      "cmux.client.name": context.client.name,
      "cmux.client.version": context.client.version,
      "cmux.client.build": context.client.build,
      "cmux.client.channel": context.client.channel,
      "cmux.client.request_id": context.client.requestId,
      "cmux.client.trace_id": context.client.traceId,
      "cmux.vercel.request_id": context.vercelRequestId,
    });
  }
  if (success && POLLED_VM_OPERATIONS.has(context.operation)) return;
  const env = options.env ?? process.env;
  if (!vmAnalyticsEnabled(env)) return;
  const distinctId = context.userId ?? "cmux-vm-anonymous";
  const lastError = context.lastError;
  const errorCode = code ?? lastError?.error;
  const operatorFault = success ? false : isOperatorFaultVmError({ error: errorCode ?? "", status });
  const base = requestTelemetryProperties(context, ids);
  const requestProperties: PostHogProperties = {
    ...base,
    success,
    status,
    duration_ms: durationMs,
    operator_fault: operatorFault,
    schema_version: 1,
    $insert_id: randomUUID(),
    $geoip_disable: true,
  };
  if (errorCode) requestProperties.error_code = errorCode;
  if (lastError?.phase) requestProperties.error_phase = lastError.phase;
  if (lastError?.retryable !== undefined) requestProperties.retryable = lastError.retryable;
  const provider = stringOrUndefined(lastError?.diagnostics?.provider);
  if (provider) requestProperties.provider = provider;
  const timestamp = new Date().toISOString();
  const batch: Array<{ event: string; properties: PostHogProperties }> = [
    { event: VM_REQUEST_POSTHOG_EVENT, properties: requestProperties },
  ];
  if (!success) {
    const reason = scrubForAnalytics(lastError?.reason ?? lastError?.message ?? `HTTP ${status}`);
    batch.push({
      event: "$exception",
      properties: {
        ...base,
        status,
        duration_ms: durationMs,
        operator_fault: operatorFault,
        error_code: errorCode ?? `http_${status}`,
        error_phase: lastError?.phase ?? "unknown",
        $exception_level: operatorFault ? "error" : "warning",
        $exception_fingerprint: `cmux-vm-error:${errorCode ?? `http_${status}`}`,
        $exception_list: JSON.stringify([
          {
            type: errorCode ?? `http_${status}`,
            value: reason,
            mechanism: { handled: true, type: "cmux_vm_api", synthetic: true },
          },
        ]),
        schema_version: 1,
        $insert_id: randomUUID(),
        $geoip_disable: true,
      },
    });
  }
  const body = JSON.stringify({
    api_key: POSTHOG_PROJECT_KEY,
    batch: batch.map((entry) => ({
      event: entry.event,
      distinct_id: distinctId,
      properties: entry.properties,
      timestamp,
    })),
  });
  const fetchImpl = options.fetch ?? fetch;
  const task = fetchImpl(`${POSTHOG_HOST}/batch/`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
    signal: AbortSignal.timeout(2_000),
  }).then(() => undefined).catch(() => undefined);
  try {
    after(() => task);
  } catch {
    void task;
  }
}

const ANALYTICS_SENSITIVE_TEXT = /(srt_[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{8,}|Bearer\s+\S+|eyJ[A-Za-z0-9_-]{10,}|crt_[A-Za-z0-9_-]{16,})/g;

function scrubForAnalytics(text: string): string {
  return text.replace(ANALYTICS_SENSITIVE_TEXT, "[redacted]").slice(0, 500);
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
  if (!vmAnalyticsEnabled(env)) return;
  const context = currentVmRequestContext();
  const ids = spanTraceIds(span);
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
  // Schema 2 additive fields: the same lookup keys `cloud_vm_request` carries,
  // so the alerting event can be joined to its trace without a second query.
  const traceId = ids?.traceId ?? context?.traceId;
  if (traceId) properties.trace_id = traceId;
  if (context) {
    properties.duration_ms = Math.round((performance.now() - context.startedAtMs) * 100) / 100;
    if (context.lastError?.phase) properties.error_phase = context.lastError.phase;
    if (context.client.name) properties.client_name = context.client.name;
    if (context.client.version) properties.client_version = context.client.version;
    if (context.client.channel) properties.client_channel = context.client.channel;
    if (context.client.requestId) properties.client_request_id = context.client.requestId;
  }
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
