/** Native Cloud diagnostics accept codes and measurements, never arbitrary attributes. */
export const CLOUD_TELEMETRY_MAX_BYTES = 64 * 1024;
export const CLOUD_TELEMETRY_MAX_SPANS = 100;
export const CLOUD_TELEMETRY_MAX_AGE_MS = 24 * 60 * 60 * 1000;

export const cloudOperations = [
  "create", "open", "list", "status", "stats", "rename", "delete", "pause", "resume", "restart",
  "snapshot", "fork", "restore", "resize", "exec", "port", "publication", "domain",
  "base", "session", "workspace", "terminal", "file", "environment", "tunnel",
  "connect", "refresh", "notification", "agent", "network", "agent_updates", "unknown",
] as const;
/** Raw values that shipped Mac builds send for a catalog operation. */
const cloudOperationAliases: Readonly<Record<string, typeof cloudOperations[number]>> = { agentUpdates: "agent_updates" };
export const cloudPhases = [
  "operation", "authentication", "request", "retry_wait", "provider", "database",
  "tunnel", "route", "process", "connect", "snapshot", "materialize", "ready",
  "recovery", "file", "environment", "port", "notification", "cleanup", "export",
] as const;
export const cloudFailures = [
  "authentication", "session_refresh", "permission", "plan", "rate_limit", "conflict",
  "network", "timeout", "server", "response", "unsupported", "process", "protocol",
  "not_found", "placement", "resource_limit", "storage", "cancelled", "unknown",
] as const;
export const cloudChannels = ["dev", "nightly", "production", "rc", "unknown"] as const;
export const stackAuthEvents = ["stack_rate_limited", "stack_rate_limit_recovered"] as const;
export const stackAuthPhases = ["sign_in_completion", "token_refresh", "session_check", "other"] as const;
export const stackAuthBodyKinds = ["json", "html", "other"] as const;

/**
 * A sign-in service rate-limit record. Exported as the span `cmux.auth.<event>`.
 * The endpoint is a path with ids replaced by `ID`: no query, token or address.
 */
export type CloudTelemetryAuth = {
  readonly event: typeof stackAuthEvents[number];
  readonly phase: typeof stackAuthPhases[number];
  readonly retryAfterS?: number;
  readonly backoffS?: number;
  readonly bodyKind?: typeof stackAuthBodyKinds[number];
  readonly endpoint?: string;
  readonly limitedForS?: number;
};

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
  readonly auth?: CloudTelemetryAuth;
};
export type CloudTelemetryClient = {
  readonly channel: typeof cloudChannels[number];
  readonly tag?: string;
  readonly version: string;
  readonly build: string;
  readonly revision: string;
  readonly osVersion: string;
  readonly architecture: "arm64" | "x86_64" | "unknown";
  /** Random per-install id, exported as `service.instance.id`. Identifies no user. */
  readonly instanceId?: string;
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
  "outcome", "startedAtMs", "endedAtMs", "attempt", "failure", "httpStatus", "errorNumber", "droppedCount", "sourceFile", "sourceLine", "auth",
]);
const clientKeys = new Set(["channel", "tag", "version", "build", "revision", "osVersion", "architecture", "instanceId"]);
const authKeys = new Set(["event", "phase", "retryAfterS", "backoffS", "bodyKind", "endpoint", "limitedForS"]);
const MAX_LIMITED_FOR_S = 30 * 86400;

/** Why one submitted span was not stored. Coarse categories, never submitted text. */
export type CloudTelemetrySpanRejection = "fields" | "identity" | "timing" | "catalog" | "measurement" | "auth";
/** Why a whole upload was refused. The client drops a refused upload without retrying it. */
export type CloudTelemetryUploadRejection = "envelope" | "client" | "span_count" | "event_id" | "duplicate_event" | "no_valid_span";

export type CloudTelemetryUpload = {
  /** The spans that passed the contract, in submitted order. Never empty. */
  readonly batch: CloudTelemetryBatch;
  /** Spans that failed the contract. Their ids are acknowledged so a client never resends them. */
  readonly rejected: readonly { readonly eventId: string; readonly reason: CloudTelemetrySpanRejection }[];
  /** Spans whose unrecognized operation or failure code was stored as `unknown`. */
  readonly coerced: number;
  /** Every submitted event id, in submitted order: the receipt the client matches. */
  readonly eventIds: readonly string[];
};

/**
 * Validates an upload span by span. One span that a newer or older client
 * build encodes differently costs only that span: an unrecognized operation
 * or failure code becomes `unknown`, and any other contract violation drops
 * the span. The upload is refused only when its envelope is invalid, an
 * event id cannot be acknowledged, or no span is valid.
 *
 * Storage hashes the normalized span. A retry of a span coerced to `unknown`
 * conflicts (409) only when a deployment adds that value to the catalog
 * between the first attempt and a retry, and the first receipt was lost.
 */
export function parseCloudTelemetryUpload(
  value: unknown, now = Date.now(),
): { readonly ok: true; readonly upload: CloudTelemetryUpload } | { readonly ok: false; readonly reason: CloudTelemetryUploadRejection; readonly submitted: number } {
  const submitted = record(value) && Array.isArray(value.spans) ? value.spans.length : 0;
  if (!record(value) || !onlyKeys(value, new Set(["version", "client", "spans"])) || value.version !== 1) return refused("envelope", submitted);
  if (!validClient(value.client)) return refused("client", submitted);
  if (!Array.isArray(value.spans) || submitted === 0 || submitted > CLOUD_TELEMETRY_MAX_SPANS) return refused("span_count", submitted);
  const submittedSpans: { readonly raw: Record<string, unknown>; readonly eventId: string }[] = [];
  for (const raw of value.spans as unknown[]) {
    if (!record(raw) || typeof raw.eventId !== "string" || !uuid.test(raw.eventId)) return refused("event_id", submitted);
    submittedSpans.push({ raw, eventId: raw.eventId });
  }
  const eventIds = submittedSpans.map((span) => span.eventId);
  if (new Set(eventIds).size !== submitted) return refused("duplicate_event", submitted);
  const spans: CloudTelemetrySpan[] = [];
  const rejected: { eventId: string; reason: CloudTelemetrySpanRejection }[] = [];
  let coerced = 0;
  for (const { raw, eventId } of submittedSpans) {
    const normalized = normalizeCatalogCodes(raw);
    const reason = spanRejection(normalized.span, now);
    if (reason) rejected.push({ eventId, reason });
    else { spans.push(normalized.span as CloudTelemetrySpan); if (normalized.coerced) coerced++; }
  }
  if (spans.length === 0) return refused("no_valid_span", submitted);
  return { ok: true, upload: { batch: { version: 1, client: value.client, spans }, rejected, coerced, eventIds } };
}

/** The spans of an upload that pass the contract, or `null` when the upload is refused. */
export function parseCloudTelemetryBatch(value: unknown, now = Date.now()): CloudTelemetryBatch | null {
  const parsed = parseCloudTelemetryUpload(value, now);
  return parsed.ok ? parsed.upload.batch : null;
}

function refused(reason: CloudTelemetryUploadRejection, submitted: number) { return { ok: false as const, reason, submitted }; }

/** A code-shaped value outside the catalog, such as a case added by a newer build. Free text is not code-shaped. */
const catalogCode = /^[a-z][A-Za-z0-9_]{0,39}$/;
function normalizeCatalogCodes(span: Record<string, unknown>): { span: Record<string, unknown>; coerced: boolean } {
  let coerced = false;
  const normalized = { ...span };
  const alias = typeof span.operation === "string" && Object.hasOwn(cloudOperationAliases, span.operation)
    ? cloudOperationAliases[span.operation] : undefined;
  if (alias) normalized.operation = alias;
  else if (!member(span.operation, cloudOperations) && textMatches(span.operation, catalogCode)) { normalized.operation = "unknown"; coerced = true; }
  if (span.failure !== undefined && !member(span.failure, cloudFailures) && textMatches(span.failure, catalogCode)) { normalized.failure = "unknown"; coerced = true; }
  return { span: normalized, coerced };
}

function validClient(value: unknown): value is CloudTelemetryClient {
  if (!record(value) || !onlyKeys(value, clientKeys)) return false;
  return member(value.channel, cloudChannels)
    && (value.tag === undefined || textMatches(value.tag, /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/))
    && textMatches(value.version, /^[0-9][0-9A-Za-z.+-]{0,39}$/)
    && textMatches(value.build, /^[0-9]{1,20}$/)
    && textMatches(value.revision, /^(?:[0-9a-f]{7,64}|unknown)$/)
    && textMatches(value.osVersion, /^[0-9.]{1,30}$/)
    && member(value.architecture, ["arm64", "x86_64", "unknown"])
    && (value.instanceId === undefined || textMatches(value.instanceId, uuid));
}

function spanRejection(value: Record<string, unknown>, now: number): CloudTelemetrySpanRejection | null {
  if (!onlyKeys(value, spanKeys)) return "fields";
  if (!validSpanIdentity(value)) return "identity";
  if (!validSpanTiming(value, now)) return "timing";
  if (!member(value.operation, cloudOperations) || !member(value.phase, cloudPhases)
    || !member(value.outcome, ["success", "failure", "timeout", "cancelled"])
    || !optionalMember(value.failure, cloudFailures)) return "catalog";
  if (!validSpanMeasurements(value)) return "measurement";
  if (value.auth !== undefined && !validAuth(value.auth, value.httpStatus)) return "auth";
  return null;
}

function validSpanMeasurements(value: Record<string, unknown>): boolean {
  return integer(value.attempt, 0, 10000)
    && optionalInteger(value.httpStatus, 100, 599)
    && optionalInteger(value.errorNumber, -2147483648, 2147483647)
    && optionalInteger(value.droppedCount, 0, 1000000)
    && (value.sourceFile === undefined || textMatches(value.sourceFile, /^[A-Za-z][A-Za-z0-9+_-]{0,119}\.swift$/))
    && optionalInteger(value.sourceLine, 1, 100000);
}

/** A rate-limited record carries the 429 evidence; a recovered record carries its duration. */
function validAuth(value: unknown, httpStatus: unknown): value is CloudTelemetryAuth {
  if (!record(value) || !onlyKeys(value, authKeys)) return false;
  if (!member(value.event, stackAuthEvents) || !member(value.phase, stackAuthPhases)) return false;
  if (!optionalInteger(value.retryAfterS, 0, 86400) || !optionalInteger(value.backoffS, 0, 86400)) return false;
  if (!optionalMember(value.bodyKind, stackAuthBodyKinds) || !optionalInteger(value.limitedForS, 0, MAX_LIMITED_FOR_S)) return false;
  // A path only: segments of plain characters, never a query, fragment or address.
  if (value.endpoint !== undefined && !textMatches(value.endpoint, /^\/[A-Za-z0-9._~/-]{0,199}$/)) return false;
  if (value.event === "stack_rate_limited") {
    return httpStatus === 429 && value.backoffS !== undefined && value.bodyKind !== undefined && value.endpoint !== undefined;
  }
  return value.limitedForS !== undefined;
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
