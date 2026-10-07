import { Effect } from "effect";
import { readBoundedJsonObject } from "../apns/routePolicy";
import { CLOUD_TELEMETRY_MAX_BYTES, parseCloudTelemetryBatch, type CloudTelemetryBatch } from "./cloudTelemetryContract";
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
    if (!body.ok) return response(body.error === "request_too_large" ? 413 : 400, body.error);
    const batch = parseCloudTelemetryBatch(body.value, dependencies.now());
    if (!batch) return response(400, "invalid_diagnostics");
    yield* store(user.id, batch, dependencies);
    // Sampled-out spans are acknowledged too: the client must not retry or re-queue them.
    return new Response(JSON.stringify({ accepted: batch.spans.length, eventIds: batch.spans.map((span) => span.eventId) }), {
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
