import { createHmac } from "node:crypto";
import type { CloudTelemetrySpan } from "./cloudTelemetryContract";
import type { StoredCloudDiagnostic } from "./cloudTelemetryRepository";

export type CloudAxiomConfiguration = {
  readonly origin: string;
  readonly token: string;
  readonly identityKey: string;
  readonly tracesDataset: string;
  readonly errorsDataset: string;
  readonly environment: string;
  readonly revision: string;
};

export function cloudAxiomConfiguration(env = process.env): CloudAxiomConfiguration | null {
  const token = env.CMUX_CLOUD_AXIOM_TOKEN?.trim();
  const identityKey = env.CMUX_CLOUD_TELEMETRY_ID_KEY?.trim();
  if (!token || !identityKey || identityKey.length < 32) return null;
  const origin = trustedAxiomOrigin(env.CMUX_CLOUD_AXIOM_ORIGIN);
  if (!origin) return null;
  const production = env.VERCEL_ENV === "production";
  return {
    origin, token, identityKey,
    tracesDataset: production ? "cmux-prod-otel-traces" : "cmux-preview-otel-traces",
    errorsDataset: production ? "cmux-cloud-errors-prod" : "cmux-cloud-errors-preview",
    environment: production ? "production" : env.VERCEL_ENV === "preview" ? "preview" : "development",
    revision: env.VERCEL_GIT_COMMIT_SHA?.match(/^[0-9a-f]{7,64}$/)?.[0] ?? "unknown",
  };
}

export async function exportCloudDiagnostics(
  rows: readonly StoredCloudDiagnostic[], configuration: CloudAxiomConfiguration, doFetch: typeof fetch = fetch,
): Promise<void> {
  if (rows.length === 0) return;
  const resourceSpans = rows.filter((row) => row.payload.source !== "server").map((row) => ({
    resource: { attributes: otlpAttributes(resourceAttributes(row, configuration)) },
    scopeSpans: [{ scope: { name: "cmux-cloud-native", version: "1" }, spans: [cloudSpanToOtlp(row.payload.span)] }],
  }));
  const errors = rows.filter((row) => ["failure", "timeout"].includes(row.payload.span.outcome)).map((row) => ({
    _time: new Date(row.payload.span.endedAtMs).toISOString(),
    client_channel: row.payload.client.channel,
    client_version: row.payload.client.version,
    client_build: row.payload.client.build,
    client_revision: row.payload.client.revision,
    backend_environment: configuration.environment,
    backend_revision: configuration.revision,
    account_key: createHmac("sha256", configuration.identityKey).update(row.userId).digest("hex"),
    source: row.payload.source ?? "client",
    event_id: row.eventId, operation_id: row.payload.span.operationId,
    trace_id: row.payload.span.traceId, span_id: row.payload.span.spanId,
    parent_span_id: row.payload.span.parentSpanId,
    operation: row.payload.span.operation, phase: row.payload.span.phase,
    outcome: row.payload.span.outcome, failure: row.payload.span.failure,
    error_number: row.payload.span.errorNumber, http_status: row.payload.span.httpStatus,
    duration_ms: row.payload.span.endedAtMs - row.payload.span.startedAtMs,
    attempt: row.payload.span.attempt,
    source_file: row.payload.span.sourceFile, source_line: row.payload.span.sourceLine,
    error_code: row.payload.serverErrorCode,
  }));
  // Independent destinations run together; failure leaves the durable lease retryable.
  // An ambiguous network acknowledgement can repeat a span. Queries deduplicate event_id.
  await Promise.all([
    ...(resourceSpans.length ? [send("/v1/traces", { resourceSpans }, configuration.tracesDataset)] : []),
    ...(errors.length ? [send(`/v1/ingest/${configuration.errorsDataset}`, errors)] : []),
  ]);

  async function send(path: string, body: unknown, dataset?: string): Promise<void> {
    const result = await doFetch(`${configuration.origin}${path}`, {
      method: "POST", redirect: "error", signal: AbortSignal.timeout(10_000),
      headers: {
        authorization: `Bearer ${configuration.token}`, "content-type": "application/json",
        ...(dataset ? { "x-axiom-dataset": dataset } : {}),
      },
      body: JSON.stringify(body),
    });
    if (!result.ok) throw new Error(`cloud_diagnostic_export_http_${result.status}`);
    const text = await result.text();
    if (!text) return;
    const receipt = JSON.parse(text) as { failed?: number; partialSuccess?: { rejectedSpans?: string | number } };
    if (Number(receipt.failed ?? 0) > 0 || Number(receipt.partialSuccess?.rejectedSpans ?? 0) > 0) {
      throw new Error("cloud_diagnostic_export_partial_failure");
    }
  }
}

function resourceAttributes(row: StoredCloudDiagnostic, configuration: CloudAxiomConfiguration) {
  const client = row.payload.client;
  return {
    "service.name": row.payload.source === "server" ? "cmux-web" : "cmux-mac", "service.version": row.payload.source === "server" ? configuration.revision : client.version,
    "cmux.client.version": client.version,
    "deployment.environment.name": configuration.environment,
    "cmux.backend.revision": configuration.revision,
    "cmux.client.channel": client.channel, "cmux.client.build": client.build,
    "cmux.client.revision": client.revision,
    "os.version": row.payload.source === "server" ? undefined : client.osVersion,
    "host.arch": row.payload.source === "server" ? undefined : client.architecture,
    "cmux.account_key": createHmac("sha256", configuration.identityKey).update(row.userId).digest("hex"),
    "cmux.observation.source": row.payload.source ?? "client",
  };
}

/** Preserve the originating span, including time and parent, through the HTTP gateway. */
export function cloudSpanToOtlp(span: CloudTelemetrySpan) {
  const attributes = {
    "cmux.subsystem": "vm-cloud", "cmux.observation.source": "client",
    "cmux.event_id": span.eventId, "cmux.operation_id": span.operationId,
    "cmux.cloud.operation": span.operation, "cmux.cloud.phase": span.phase,
    "cmux.cloud.outcome": span.outcome, "cmux.cloud.attempt": span.attempt,
    "error.type": span.failure, "http.response.status_code": span.httpStatus,
    "cmux.error_number": span.errorNumber, "cmux.telemetry.dropped_count": span.droppedCount,
    "code.file.name": span.sourceFile, "code.line.number": span.sourceLine,
  };
  return {
    traceId: span.traceId, spanId: span.spanId,
    ...(span.parentSpanId ? { parentSpanId: span.parentSpanId } : {}),
    name: `cmux.cloud.${span.operation}.${span.phase}`,
    kind: span.phase === "request" ? 3 : 1,
    startTimeUnixNano: (BigInt(span.startedAtMs) * BigInt(1_000_000)).toString(),
    endTimeUnixNano: (BigInt(span.endedAtMs) * BigInt(1_000_000)).toString(),
    attributes: otlpAttributes(attributes),
    status: { code: span.outcome === "failure" || span.outcome === "timeout" ? 2 : 1 },
  };
}

export function otlpAttributes(values: Record<string, string | number | undefined>) {
  return Object.entries(values).flatMap(([key, value]) => value === undefined ? [] : [{
    key, value: typeof value === "number" ? { intValue: String(value) } : { stringValue: value },
  }]);
}

function trustedAxiomOrigin(value: string | undefined): string | null {
  try {
    const url = new URL(value ?? "https://us-east-1.aws.edge.axiom.co");
    if (url.protocol !== "https:" || !url.hostname.endsWith(".axiom.co") || url.username || url.password || url.port) return null;
    return url.origin;
  } catch { return null; }
}
