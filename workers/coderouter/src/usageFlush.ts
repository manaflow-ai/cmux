import type { EndpointClass, UsageIngest } from "./types";

export interface UsageBufferRow {
  event_id: unknown;
  key_id: unknown;
  credential_id: unknown;
  family: unknown;
  endpoint_class: unknown;
  model: unknown;
  credential_class: unknown;
  status: unknown;
  input_tokens: unknown;
  output_tokens: unknown;
  cache_read_tokens: unknown;
  cache_write_tokens: unknown;
  estimated: unknown;
  cost_micros: unknown;
  latency_ms: unknown;
  ts: unknown;
}

export interface StatusUpdateRow {
  credential_id: unknown;
  status: unknown;
}

export function buildUsageIngest(
  poolId: string,
  rows: UsageBufferRow[],
  statusRows: StatusUpdateRow[],
): { body: UsageIngest; flushedEstimateMicros: number } {
  const events = rows.map((row) => ({
    eventId: String(row.event_id),
    keyId: nullableString(row.key_id) ?? undefined,
    credentialId: nullableString(row.credential_id) ?? undefined,
    family: String(row.family),
    endpointClass: row.endpoint_class as EndpointClass,
    model: nullableString(row.model) ?? undefined,
    credentialClass: row.credential_class as UsageIngest["events"][number]["credentialClass"],
    status: Number(row.status),
    inputTokens: Number(row.input_tokens),
    outputTokens: Number(row.output_tokens),
    cacheReadTokens: Number(row.cache_read_tokens),
    cacheWriteTokens: Number(row.cache_write_tokens),
    estimated: Number(row.estimated) === 1,
    costMicros: row.cost_micros === null || row.cost_micros === undefined ? null : Number(row.cost_micros),
    latencyMs: row.latency_ms === null || row.latency_ms === undefined ? undefined : Number(row.latency_ms),
    ts: Number(row.ts),
  }));
  const statusUpdates = statusRows
    .map((row) => ({
      credentialId: String(row.credential_id),
      status: row.status === "active" ? ("active" as const) : ("needs_reauth" as const),
    }))
    .filter((row) => row.credentialId.length > 0);
  return {
    body: {
      poolId,
      events,
      ...(statusUpdates.length > 0 ? { statusUpdates } : {}),
    },
    flushedEstimateMicros: events.reduce(
      (sum, event) => sum + (event.credentialClass === "managed" ? (event.costMicros ?? 0) : 0),
      0,
    ),
  };
}

export function subtractFlushedEstimateMicros(current: number, flushed: number): number {
  return Math.max(0, current - flushed);
}

function nullableString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}
