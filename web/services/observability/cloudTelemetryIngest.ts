import { trace } from "@opentelemetry/api";
import { Effect } from "effect";
import { readBoundedJsonObject } from "../apns/routePolicy";
import { CLOUD_TELEMETRY_MAX_BYTES, parseCloudTelemetryUpload, type CloudTelemetryBatch, type CloudTelemetryUpload } from "./cloudTelemetryContract";
import { sampleCloudTelemetryBatch } from "./cloudTelemetrySampling";

export type CloudTelemetryIngestDependencies = {
  readonly authenticate: (request: Request) => Promise<{ readonly id: string } | null>;
  readonly checkIngress: (request: Request) => Promise<boolean>;
  /** Stores the sampled spans. `sampleWeights` lists spans that stand for more than one submitted span. */
  readonly accept: (userId: string, batch: CloudTelemetryBatch, sampleWeights: ReadonlyMap<string, number>) => Promise<number>;
  readonly scheduleDrain: () => void;
  readonly now: () => number;
};

export class CloudTelemetryLimitError extends Error {}
export class CloudTelemetryConflictError extends Error {}

/** The HTTP adapter runs one Effect program; delivery is owned by the durable outbox. */
export function makeCloudTelemetryHandler(dependencies: CloudTelemetryIngestDependencies) {
  return (request: Request): Promise<Response> => Effect.runPromise(
    ingest(request, dependencies).pipe(Effect.catchAll((error) => Effect.succeed(errorResponse(error)))),
  );
}

function ingest(request: Request, dependencies: CloudTelemetryIngestDependencies) {
  return Effect.gen(function* () {
    const allowed = yield* Effect.tryPromise(() => dependencies.checkIngress(request));
    if (!allowed) return response(429, "rate_limited");
    const encoding = request.headers.get("content-encoding");
    if (encoding && encoding !== "identity") return response(415, "unsupported_encoding");
    if (request.headers.get("content-type")?.split(";")[0]?.trim() !== "application/json") return response(415, "unsupported_content_type");
    const user = yield* Effect.tryPromise(() => dependencies.authenticate(request));
    if (!user) return response(401, "unauthorized");
    const body = yield* Effect.tryPromise(() => readBoundedJsonObject(request, CLOUD_TELEMETRY_MAX_BYTES));
    if (!body.ok) {
      recordUploadOutcome({ submitted: 0, accepted: 0, rejected: 0, coerced: 0, refusal: body.error });
      return response(body.error === "request_too_large" ? 413 : 400, body.error);
    }
    const parsed = parseCloudTelemetryUpload(body.value, dependencies.now());
    if (!parsed.ok) {
      recordUploadOutcome({ submitted: parsed.submitted, accepted: 0, rejected: parsed.submitted, coerced: 0, refusal: parsed.reason });
      return response(400, "invalid_diagnostics");
    }
    const { upload } = parsed;
    yield* store(user.id, upload.batch, dependencies);
    recordUploadOutcome(uploadCounts(upload));
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
    // A failed scheduling call must not revoke a durable receipt. The cron drain remains responsible.
    yield* Effect.sync(() => dependencies.scheduleDrain()).pipe(Effect.catchAllDefect(() => Effect.void));
  });
}

type UploadOutcome = {
  readonly submitted: number; readonly accepted: number; readonly rejected: number; readonly coerced: number;
  readonly refusal?: string; readonly rejectedReasons?: string;
};

function uploadCounts(upload: CloudTelemetryUpload): UploadOutcome {
  return {
    submitted: upload.eventIds.length, accepted: upload.batch.spans.length,
    rejected: upload.rejected.length, coerced: upload.coerced,
    ...(upload.rejected.length > 0 ? { rejectedReasons: [...new Set(upload.rejected.map((span) => span.reason))].sort().join(",") } : {}),
  };
}

/** Counts on the route span, so Axiom shows partial acceptance and refusal causes. Codes only, never submitted text. */
function recordUploadOutcome(outcome: UploadOutcome): void {
  trace.getActiveSpan()?.setAttributes({
    "cmux.telemetry.submitted_spans": outcome.submitted,
    "cmux.telemetry.accepted_spans": outcome.accepted,
    "cmux.telemetry.rejected_spans": outcome.rejected,
    "cmux.telemetry.coerced_spans": outcome.coerced,
    ...(outcome.refusal ? { "cmux.telemetry.refusal": outcome.refusal } : {}),
    ...(outcome.rejectedReasons ? { "cmux.telemetry.rejected_reasons": outcome.rejectedReasons } : {}),
  });
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
