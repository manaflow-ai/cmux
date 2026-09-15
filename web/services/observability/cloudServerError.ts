import { randomUUID } from "node:crypto";
import { after } from "next/server";
import type { VmRequestContext } from "../vms/requestContext";
import type { VmErrorResponseInput } from "../vms/routeHelpers";
import { cloudOperations, type CloudTelemetryClient, type CloudTelemetrySpan } from "./cloudTelemetryContract";
import { acceptCloudTelemetry } from "./cloudTelemetryRepository";
import { drainCloudDiagnostics } from "./cloudTelemetryDelivery";

/** Error logs use the original server span reference; do not export a duplicate server span. */
export function retainCloudServerError(input: VmErrorResponseInput, context: VmRequestContext | undefined): void {
  if (!context?.userId || !context.traceId || !context.spanId) return;
  const now = Date.now();
  const rawChannel = context.client.channel;
  const channel = rawChannel === "nightly" ? "nightly" : rawChannel === "stable" || rawChannel === "production" ? "production" : rawChannel === "dev" ? "dev" : "unknown";
  const client: CloudTelemetryClient = {
    channel, version: safeVersion(context.client.version),
    build: context.client.build?.match(/^[0-9]{1,20}$/)?.[0] ?? "0",
    revision: context.client.revision ?? "unknown", osVersion: "0", architecture: "unknown",
  };
  const operation = cloudOperations.includes(context.operation as CloudTelemetrySpan["operation"])
    ? context.operation as CloudTelemetrySpan["operation"] : "unknown";
  const span: CloudTelemetrySpan = {
    eventId: randomUUID(), operationId: context.operationId ?? randomUUID(),
    traceId: context.traceId, spanId: context.spanId, operation, phase: "request",
    outcome: input.status === 504 ? "timeout" : "failure",
    startedAtMs: now - Math.max(0, Math.round(performance.now() - context.startedAtMs)), endedAtMs: now,
    attempt: 0, failure: input.status >= 500 ? "server" : "response", httpStatus: input.status,
  };
  const userId = context.userId;
  const code = /^[a-z][a-z0-9_]{0,119}$/.test(input.error) ? input.error : "unknown";
  try {
    after(async () => {
      try {
        await acceptCloudTelemetry(userId, { version: 1, client, spans: [span] }, code);
        await drainCloudDiagnostics();
      } catch {
        console.error("cmux.cloud.error_retention_failed", { code, trace_id: span.traceId });
      }
    });
  } catch {
    // Outside a web request, the caller's existing error sink remains responsible.
  }
}

function safeVersion(value: string | undefined): string {
  return value?.match(/^[0-9][0-9A-Za-z.+-]{0,39}$/)?.[0] ?? "0.0.0";
}
