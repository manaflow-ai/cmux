import { SpanKind, trace, type Attributes } from "@opentelemetry/api";
import { Effect } from "effect";
import { readBoundedJsonObject } from "../apns/routePolicy";
import { CLOUD_TELEMETRY_MAX_BYTES, parseCloudTelemetryUpload, type CloudTelemetryBatch, type CloudTelemetryUpload } from "./cloudTelemetryContract";
import { cloudTelemetryAccountKey } from "./cloudTelemetryExport";
import { sampleCloudTelemetryBatch } from "./cloudTelemetrySampling";

export type CloudTelemetryIngestDependencies = {
  readonly authenticate: (request: Request) => Promise<{ readonly id: string } | null>;
  /**
   * The pre-authentication gate. `true` admits the request; `false` or a refusal
   * naming the firewall rule answers 429 with refusal `ingress_rate_limited`.
   */
  readonly checkIngress: (request: Request) => Promise<boolean | CloudTelemetryIngressRefusal>;
  /** Stores the sampled spans. `sampleWeights` lists spans that stand for more than one submitted span. */
  readonly accept: (userId: string, batch: CloudTelemetryBatch, sampleWeights: ReadonlyMap<string, number>) => Promise<number>;
  readonly scheduleDrain: () => void;
  readonly now: () => number;
};

export type CloudTelemetryIngressRefusal = { readonly rateLimitRule: string };

/** The account's byte budget refused the batch. `storedSpans` were kept anyway, from the reserve or earlier receipts. */
export class CloudTelemetryLimitError extends Error {
  constructor(readonly storedSpans = 0) { super("cloud_diagnostics_byte_budget"); }
}
export class CloudTelemetryConflictError extends Error {}

/** The HTTP adapter runs one Effect program; delivery is owned by the durable outbox. */
export function makeCloudTelemetryHandler(dependencies: CloudTelemetryIngestDependencies) {
  return (request: Request): Promise<Response> => Effect.runPromise(
    ingest(request, dependencies).pipe(Effect.catchAll((error) => Effect.succeed(errorResponse(error)))),
  );
}

function ingest(request: Request, dependencies: CloudTelemetryIngestDependencies) {
  return Effect.gen(function* () {
    // Identity labels gathered as the request is understood; refusals carry what is known so far.
    const labels: Record<string, string> = {};
    const ingress = yield* Effect.tryPromise(() => dependencies.checkIngress(request));
    if (ingress !== true) {
      if (ingress) labels["cmux.telemetry.rate_limit_rule"] = ingress.rateLimitRule;
      // Before authentication and parsing, so only the cause and the rule are known.
      return refuse(429, "rate_limited", { submitted: 0, accepted: 0, rejected: 0, coerced: 0, refusal: "ingress_rate_limited" }, labels, dependencies.now());
    }
    const encoding = request.headers.get("content-encoding");
    if (encoding && encoding !== "identity") return response(415, "unsupported_encoding");
    if (request.headers.get("content-type")?.split(";")[0]?.trim() !== "application/json") return response(415, "unsupported_content_type");
    const user = yield* Effect.tryPromise(() => dependencies.authenticate(request));
    if (!user) return response(401, "unauthorized");
    const accountKey = cloudTelemetryAccountKeyFromEnvironment(user.id);
    if (accountKey) labels["cmux.account_key"] = accountKey;
    const body = yield* Effect.tryPromise(() => readBoundedJsonObject(request, CLOUD_TELEMETRY_MAX_BYTES));
    if (!body.ok) {
      return refuse(body.error === "request_too_large" ? 413 : 400, body.error, { submitted: 0, accepted: 0, rejected: 0, coerced: 0, refusal: body.error }, labels, dependencies.now());
    }
    const parsed = parseCloudTelemetryUpload(body.value, dependencies.now());
    if (!parsed.ok) {
      return refuse(400, "invalid_diagnostics", { submitted: parsed.submitted, accepted: 0, rejected: parsed.submitted, coerced: 0, refusal: parsed.reason }, labels, dependencies.now());
    }
    const { upload } = parsed;
    if (upload.batch.client.instanceId) labels["cmux.client.instance_id"] = upload.batch.client.instanceId;
    yield* store(user.id, upload.batch, dependencies).pipe(
      Effect.tapError((error) => Effect.sync(() => {
        const stored = error instanceof CloudTelemetryLimitError ? error.storedSpans : 0;
        // Evidence kept from a refused batch is durable now; deliver it without waiting for the cron.
        if (stored > 0) scheduleDrainSafely(dependencies);
        // Budget, conflict and storage refusals follow authentication and client backoff, so each is recorded.
        recordRefusal(storeRefusalStatus(error), {
          ...uploadCounts(upload), accepted: 0, refusal: storeRefusal(error), ...(stored > 0 ? { stored } : {}),
        }, labels);
      })),
    );
    recordUploadOutcome(uploadCounts(upload), labels);
    // Sampled-out and rejected spans are acknowledged too: the client must not retry or re-queue them.
    return new Response(JSON.stringify({
      accepted: upload.batch.spans.length,
      rejected: upload.rejected.length,
      eventIds: upload.eventIds,
      rejectedEventIds: upload.rejected.map((span) => span.eventId),
    }), {
      status: 202, headers: { "content-type": "application/json", "cache-control": "no-store" },
    });
  });
}

function store(userId: string, batch: CloudTelemetryBatch, dependencies: CloudTelemetryIngestDependencies) {
  return Effect.gen(function* () {
    const sampled = sampleCloudTelemetryBatch(batch);
    // A batch of routine successful polls needs no transaction, quota charge or drain.
    if (sampled.spans.length === 0) return;
    yield* Effect.tryPromise({
      try: () => dependencies.accept(userId, { ...batch, spans: sampled.spans }, sampled.sampleWeights), catch: (error) => error,
    });
    yield* Effect.sync(() => scheduleDrainSafely(dependencies));
  });
}

/** A failed scheduling call must not revoke a durable receipt. The cron drain remains responsible. */
function scheduleDrainSafely(dependencies: CloudTelemetryIngestDependencies): void {
  try { dependencies.scheduleDrain(); } catch { /* the cron drain delivers it */ }
}

type UploadOutcome = {
  readonly submitted: number; readonly accepted: number; readonly rejected: number; readonly coerced: number;
  readonly refusal?: string; readonly rejectedReasons?: string;
  /** Spans of a refused batch that are stored anyway (reserve evidence or earlier receipts of a retry). */
  readonly stored?: number;
};

function uploadCounts(upload: CloudTelemetryUpload): UploadOutcome {
  return {
    submitted: upload.eventIds.length, accepted: upload.batch.spans.length,
    rejected: upload.rejected.length, coerced: upload.coerced,
    ...(upload.rejected.length > 0 ? { rejectedReasons: [...new Set(upload.rejected.map((span) => span.reason))].sort().join(",") } : {}),
  };
}

function outcomeAttributes(outcome: UploadOutcome, labels: Readonly<Record<string, string>>): Attributes {
  return {
    ...labels,
    "cmux.telemetry.submitted_spans": outcome.submitted,
    "cmux.telemetry.accepted_spans": outcome.accepted,
    "cmux.telemetry.rejected_spans": outcome.rejected,
    "cmux.telemetry.coerced_spans": outcome.coerced,
    ...(outcome.refusal ? { "cmux.telemetry.refusal": outcome.refusal } : {}),
    ...(outcome.rejectedReasons ? { "cmux.telemetry.rejected_reasons": outcome.rejectedReasons } : {}),
    ...(outcome.stored ? { "cmux.telemetry.stored_spans": outcome.stored } : {}),
  };
}

/** Counts on the route span, so Axiom shows partial acceptance and refusal causes. Codes only, never submitted text. */
function recordUploadOutcome(outcome: UploadOutcome, labels: Readonly<Record<string, string>>): void {
  trace.getActiveSpan()?.setAttributes(outcomeAttributes(outcome, labels));
}

/**
 * The route span is head-sampled with the app-wide 2% ratio, so a refusal also
 * leaves its own always-kept span: refused uploads are countable in Axiom by
 * cause, firewall rule, account and install. `cmux.telemetry.refusal_count` is
 * the number of refusals the span stands for.
 */
function recordRefusal(status: number, outcome: UploadOutcome, labels: Readonly<Record<string, string>>, refusalCount = 1): void {
  recordUploadOutcome(outcome, labels);
  trace.getTracer("cmux.cloud-diagnostics").startSpan(CLOUD_TELEMETRY_REFUSAL_SPAN, {
    root: true, kind: SpanKind.INTERNAL,
    attributes: {
      ...outcomeAttributes(outcome, labels), "cmux.priority": true, "http.response.status_code": status,
      "cmux.telemetry.refusal_count": refusalCount,
    },
  }).end();
}

/**
 * Refusals a caller can repeat without backing off (a firewall refusal before
 * authentication, a malformed body) are coalesced per cause, rule and account:
 * at most one kept span per key per window on each server instance, carrying the
 * count. A flood the firewall stops therefore cannot become a flood of kept spans.
 * Refusals still pending when an instance stops are not reported.
 */
const REFUSAL_COALESCE_WINDOW_MS = 10_000;
const REFUSAL_COALESCE_MAX_KEYS = 1_000;
const pendingRefusals = new Map<string, { readonly emittedAtMs: number; readonly suppressed: number }>();

function refuse(status: number, error: string, outcome: UploadOutcome, labels: Readonly<Record<string, string>>, nowMs: number): Response {
  const key = [outcome.refusal, labels["cmux.telemetry.rate_limit_rule"], labels["cmux.account_key"]].join("\u0000");
  const pending = pendingRefusals.get(key);
  if (pending && nowMs - pending.emittedAtMs < REFUSAL_COALESCE_WINDOW_MS) {
    pendingRefusals.set(key, { ...pending, suppressed: pending.suppressed + 1 });
    recordUploadOutcome(outcome, labels);
  } else {
    if (!pending && pendingRefusals.size >= REFUSAL_COALESCE_MAX_KEYS) pendingRefusals.clear();
    pendingRefusals.set(key, { emittedAtMs: nowMs, suppressed: 0 });
    recordRefusal(status, outcome, labels, 1 + (pending?.suppressed ?? 0));
  }
  return response(status, error);
}

/** The always-sampled span name for a refused upload. */
export const CLOUD_TELEMETRY_REFUSAL_SPAN = "cmux.cloud_diagnostics.refusal";


function storeRefusalStatus(error: unknown): number {
  if (error instanceof CloudTelemetryLimitError) return 429;
  if (error instanceof CloudTelemetryConflictError) return 409;
  return 503;
}

/** The refusal code of a storage error, matching the status `errorResponse` answers. */
function storeRefusal(error: unknown): string {
  if (error instanceof CloudTelemetryLimitError) return "account_byte_budget";
  if (error instanceof CloudTelemetryConflictError) return "event_conflict";
  return "storage_unavailable";
}

/**
 * The same keyed account hash as exported client diagnostics, so Axiom can join
 * upload outcomes to the accounts that sent them. Without the key the account
 * is left out, never sent raw.
 */
function cloudTelemetryAccountKeyFromEnvironment(userId: string): string | undefined {
  const key = process.env.CMUX_CLOUD_TELEMETRY_ID_KEY?.trim();
  return key && key.length >= 32 ? cloudTelemetryAccountKey(key, userId) : undefined;
}

function errorResponse(error: unknown): Response {
  if (error instanceof CloudTelemetryLimitError) return response(429, "rate_limited");
  if (error instanceof CloudTelemetryConflictError) return response(409, "event_conflict");
  return response(503, "diagnostics_unavailable");
}
function response(status: number, error: string): Response {
  return new Response(JSON.stringify({ error }), {
    status, headers: {
      "content-type": "application/json", "cache-control": "no-store",
      ...(status === 429 || status === 503 ? { "retry-after": "60" } : {}),
    },
  });
}
