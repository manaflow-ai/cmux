import type { CloudTelemetryBatch, CloudTelemetrySpan } from "./cloudTelemetryContract";
import { DEFAULT_BASE_SAMPLE_RATIO } from "./sampler";

/**
 * The Mac app polls these operations on timers. Their successful spans were
 * about 88% of all stored diagnostics in production (2026-10-06) and carry
 * little information each, so ingest keeps only a deterministic sample of them.
 */
const POLLED_OPERATIONS: ReadonlySet<CloudTelemetrySpan["operation"]> = new Set(["list", "status", "stats", "refresh"]);

/**
 * One kept poll span stands for this many submitted ones: the app-wide 2% head
 * sampling convention. The trace predicate matches the Mac uploader, which
 * already keeps successful poll detail spans only when the last four hex digits
 * of the trace ID are divisible by 50. Using the same predicate keeps a sampled
 * trace whole and drops an unsampled trace whole, including for old clients.
 */
export const CLOUD_POLL_SAMPLE_WEIGHT = Math.round(1 / DEFAULT_BASE_SAMPLE_RATIO);

export type SampledCloudTelemetryBatch = {
  /** Spans to store. Empty when every span was sampled out. */
  readonly spans: readonly CloudTelemetrySpan[];
  /** Event IDs whose kept span represents more than one submitted span. Absent means weight 1. */
  readonly sampleWeights: ReadonlyMap<string, number>;
};

/**
 * Keep every non-success span, every non-poll span, and every span of a trace
 * that has a non-success span in this batch. Successful poll spans of other
 * traces are kept with weight `CLOUD_POLL_SAMPLE_WEIGHT` when their trace is
 * sampled, and otherwise dropped. Development builds keep everything.
 *
 * Contract: the decision holds no state across batches. Whether a trace is kept is a
 * deterministic hash of its trace ID, shared with the Mac uploader, and every
 * non-success span is always kept. A sampled-in trace is therefore always whole. The
 * only loss is successful siblings of a sampled-out trace that were sent in an earlier
 * batch than that trace's failure; the failure itself and any siblings in its batch remain.
 */
export function sampleCloudTelemetryBatch(batch: CloudTelemetryBatch): SampledCloudTelemetryBatch {
  const sampleWeights = new Map<string, number>();
  if (batch.client.channel === "dev") return { spans: batch.spans, sampleWeights };
  const eventfulTraces = new Set(batch.spans.filter((span) => span.outcome !== "success").map((span) => span.traceId));
  const spans = batch.spans.filter((span) => {
    if (span.outcome !== "success" || !POLLED_OPERATIONS.has(span.operation) || eventfulTraces.has(span.traceId)) return true;
    if (!isSampledCloudPollTrace(span.traceId)) return false;
    sampleWeights.set(span.eventId, CLOUD_POLL_SAMPLE_WEIGHT);
    return true;
  });
  return { spans, sampleWeights };
}

/** Same predicate as `CloudTelemetryUploader.enqueue` in the Mac app. */
export function isSampledCloudPollTrace(traceId: string): boolean {
  return Number.parseInt(traceId.slice(-4), 16) % CLOUD_POLL_SAMPLE_WEIGHT === 0;
}
