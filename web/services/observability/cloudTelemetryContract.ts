/** Native Cloud diagnostics accept codes and measurements, never arbitrary attributes. */
export const CLOUD_TELEMETRY_MAX_BYTES = 64 * 1024;
export const CLOUD_TELEMETRY_MAX_SPANS = 100;
export const CLOUD_TELEMETRY_MAX_AGE_MS = 24 * 60 * 60 * 1000;

export const cloudOperations = [
  "create", "open", "list", "status", "stats", "rename", "delete", "pause", "resume",
  "snapshot", "fork", "restore", "resize", "exec", "port", "publication", "domain",
  "base", "session", "workspace", "terminal", "file", "environment", "tunnel",
  "connect", "refresh", "notification", "agent", "unknown",
] as const;
export const cloudPhases = [
  "operation", "authentication", "request", "retry_wait", "provider", "database",
  "tunnel", "route", "process", "connect", "snapshot", "materialize", "ready",
  "recovery", "file", "environment", "port", "notification", "cleanup", "export",
] as const;
export const cloudFailures = [
  "authentication", "session_refresh", "permission", "plan", "rate_limit", "conflict",
  "network", "timeout", "server", "response", "unsupported", "process", "protocol",
  "not_found", "resource_limit", "storage", "cancelled", "unknown",
] as const;

export type CloudTelemetrySpan = {
  readonly eventId: string;
  readonly operationId: string;
  readonly traceId: string;
  readonly spanId: string;
  readonly parentSpanId?: string;
  readonly operation: typeof cloudOperations[number];
  readonly phase: typeof cloudPhases[number];
  readonly outcome: "success" | "failure" | "timeout" | "cancelled";
  readonly startedAtMs: number;
  readonly endedAtMs: number;
  readonly attempt: number;
  readonly failure?: typeof cloudFailures[number];
  readonly httpStatus?: number;
  readonly errorNumber?: number;
  readonly droppedCount?: number;
  readonly sourceFile?: string;
  readonly sourceLine?: number;
};
export type CloudTelemetryClient = {
  readonly channel: "dev" | "nightly" | "production" | "unknown";
  readonly version: string;
  readonly build: string;
  readonly revision: string;
  readonly osVersion: string;
  readonly architecture: "arm64" | "x86_64" | "unknown";
};
export type CloudTelemetryBatch = {
  readonly version: 1;
  readonly client: CloudTelemetryClient;
  readonly spans: readonly CloudTelemetrySpan[];
};

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const traceId = /^(?!0{32}$)[0-9a-f]{32}$/;
const spanId = /^(?!0{16}$)[0-9a-f]{16}$/;
const spanKeys = new Set([
  "eventId", "operationId", "traceId", "spanId", "parentSpanId", "operation", "phase",
  "outcome", "startedAtMs", "endedAtMs", "attempt", "failure", "httpStatus", "errorNumber", "droppedCount", "sourceFile", "sourceLine",
]);
const clientKeys = new Set(["channel", "version", "build", "revision", "osVersion", "architecture"]);

export function parseCloudTelemetryBatch(value: unknown, now = Date.now()): CloudTelemetryBatch | null {
  if (!record(value) || !onlyKeys(value, new Set(["version", "client", "spans"])) || value.version !== 1) return null;
  if (!validClient(value.client)) return null;
  if (!Array.isArray(value.spans) || value.spans.length === 0 || value.spans.length > CLOUD_TELEMETRY_MAX_SPANS) return null;
  if (!value.spans.every((span) => validSpan(span, now))) return null;
  const ids = new Set(value.spans.map((span) => span.eventId));
  if (ids.size !== value.spans.length) return null;
  return value as CloudTelemetryBatch;
}

function validClient(value: unknown): value is CloudTelemetryClient {
  if (!record(value) || !onlyKeys(value, clientKeys)) return false;
  return member(value.channel, ["dev", "nightly", "production", "unknown"])
    && textMatches(value.version, /^[0-9][0-9A-Za-z.+-]{0,39}$/)
    && textMatches(value.build, /^[0-9]{1,20}$/)
    && textMatches(value.revision, /^(?:[0-9a-f]{7,64}|unknown)$/)
    && textMatches(value.osVersion, /^[0-9.]{1,30}$/)
    && member(value.architecture, ["arm64", "x86_64", "unknown"]);
}

function validSpan(value: unknown, now: number): value is CloudTelemetrySpan {
  if (!record(value) || !onlyKeys(value, spanKeys)) return false;
  if (!validSpanIdentity(value) || !validSpanTiming(value, now)) return false;
  return member(value.operation, cloudOperations) && member(value.phase, cloudPhases)
    && member(value.outcome, ["success", "failure", "timeout", "cancelled"])
    && optionalMember(value.failure, cloudFailures)
    && integer(value.attempt, 0, 10000)
    && optionalInteger(value.httpStatus, 100, 599)
    && optionalInteger(value.errorNumber, -2147483648, 2147483647)
    && optionalInteger(value.droppedCount, 0, 1000000)
    && (value.sourceFile === undefined || textMatches(value.sourceFile, /^[A-Za-z][A-Za-z0-9+_-]{0,119}\.swift$/))
    && optionalInteger(value.sourceLine, 1, 100000);
}

function validSpanIdentity(value: Record<string, unknown>): boolean {
  return textMatches(value.eventId, uuid) && textMatches(value.operationId, uuid)
    && textMatches(value.traceId, traceId) && textMatches(value.spanId, spanId)
    && (value.parentSpanId === undefined || (textMatches(value.parentSpanId, spanId) && value.parentSpanId !== value.spanId));
}
function validSpanTiming(value: Record<string, unknown>, now: number): boolean {
  return integer(value.startedAtMs, now - CLOUD_TELEMETRY_MAX_AGE_MS, now + 300_000)
    && integer(value.endedAtMs, Number(value.startedAtMs), now + 300_000)
    && Number(value.endedAtMs) - Number(value.startedAtMs) <= 60 * 60 * 1000;
}
function record(value: unknown): value is Record<string, unknown> { return !!value && typeof value === "object" && !Array.isArray(value); }
function onlyKeys(value: Record<string, unknown>, keys: ReadonlySet<string>): boolean { return Object.keys(value).every((key) => keys.has(key)); }
function member(value: unknown, values: readonly string[]): boolean { return typeof value === "string" && values.includes(value); }
function optionalMember(value: unknown, values: readonly string[]): boolean { return value === undefined || member(value, values); }
function textMatches(value: unknown, pattern: RegExp): boolean { return typeof value === "string" && pattern.test(value); }
function integer(value: unknown, min: number, max: number): boolean { return typeof value === "number" && Number.isSafeInteger(value) && value >= min && value <= max; }
function optionalInteger(value: unknown, min: number, max: number): boolean { return value === undefined || integer(value, min, max); }
