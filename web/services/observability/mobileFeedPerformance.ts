import { z } from "zod";

import { withSpan } from "../telemetry";

// v1 upper bounds in milliseconds; the last bucket includes overflow above 60s.
export const FEED_TIMING_BUCKETS_MS = [8, 12, 17, 25, 34, 50, 100, 250, 1_000, 60_000] as const;
const count = z.number().int().min(0).max(1_000_000);
const duration = z.number().int().min(0).max(60_000);
const machineString = z.string().max(120).regex(/^[A-Za-z0-9._-]+$/);
const histogram = z.string().max(128).transform((value, context) => {
  try { return JSON.parse(value) as unknown; } catch {
    context.addIssue({ code: "custom", message: "Invalid histogram" });
    return z.NEVER;
  }
}).pipe(z.array(count).length(FEED_TIMING_BUCKETS_MS.length));

const metadata = {
  platform: z.literal("ios").optional(),
  client_channel: z.enum(["dev", "nightly", "production", "unknown"]).optional(),
  app_version: machineString.optional(),
  build_number: machineString.optional(),
  bundle_identifier: machineString.optional(),
  os_version: machineString.optional(),
  device_model: z.string().max(120).regex(/^[A-Za-z0-9._ -]+$/).optional(),
  build_sha: z.string().regex(/^[a-f0-9]{40}$/).optional(),
  is_simulator: z.boolean(),
  schema_version: z.literal(1),
  window_id: z.string().uuid(),
  item_count: z.number().int().min(0).max(10_000),
  callback_count: count,
  callback_gap_max_ms: duration,
};

const windowProperties = z.object({
  ...metadata,
  window_ms: duration,
  scroll_observed_ms: z.number().int().min(0).max(0xffff_ffff),
  callback_gap_histogram: histogram,
  callback_budget_histogram: histogram,
  gaps_over_50ms: count,
  gaps_over_100ms: count,
  updates_while_scrolling: count,
  fetch_histogram: histogram,
  fetch_max_ms: duration,
  decode_histogram: histogram,
  decode_max_ms: duration,
  apply_histogram: histogram,
  apply_max_ms: duration,
  projection_histogram: histogram,
  projection_max_ms: duration,
}).strict().refine((properties) => {
  const sum = (values: number[]) => values.reduce((a, b) => a + b, 0);
  return sum(properties.callback_gap_histogram) === properties.callback_count
    && sum(properties.callback_budget_histogram) === properties.callback_count
    && sum(properties.callback_gap_histogram.slice(6)) === properties.gaps_over_50ms
    && sum(properties.callback_gap_histogram.slice(7)) === properties.gaps_over_100ms
    && properties.updates_while_scrolling <= sum(properties.apply_histogram);
});

const anomalyProperties = z.object({
  ...metadata,
  callback_gap_max_ms: duration.min(101),
  callback_count: count.min(1),
  sentry_event_id: z.string().regex(/^[a-f0-9]{32}$/).optional(),
}).strict();

const timestamp = z.string().datetime({ offset: false });
const eventSchema = z.discriminatedUnion("event", [
  z.object({ event: z.literal("ios_feed_performance_window"), timestamp, properties: windowProperties }).strict(),
  z.object({ event: z.literal("ios_feed_scroll_anomaly"), timestamp, properties: anomalyProperties }).strict(),
]);

export type MobileFeedPerformanceEvent = z.infer<typeof eventSchema> & { readonly feedEvent: true };

/** Rejects unknown fields rather than allowing Feed text, prompts, URLs, or row IDs through. */
export function parseMobileFeedPerformanceEvent(candidate: unknown): MobileFeedPerformanceEvent | null {
  const result = eventSchema.safeParse(candidate);
  return result.success ? { ...result.data, feedEvent: true } : null;
}

/** Numeric distributions are span attributes; ingestion span duration is not scroll latency. */
export function mobileFeedPerformanceAttributes(userId: string, observation: MobileFeedPerformanceEvent) {
  const attributes: Record<string, string | number | boolean> = {
    "cmux.subsystem": "mobile-feed",
    "cmux.runtime": "ios",
    "cmux.user_id": userId,
    "cmux.observation.source": "client",
    "cmux.mobile.event": observation.event,
    "cmux.mobile.occurred_at": observation.timestamp,
    "cmux.mobile.feed.measurement": "display_link_callback_gap",
  };
  for (const [key, value] of Object.entries(observation.properties)) {
    if (value !== undefined) {
      attributes[`cmux.mobile.feed.${key}`] = Array.isArray(value) ? JSON.stringify(value) : value;
    }
  }
  return attributes;
}

/** Uses the existing server-owned Axiom credentials and authenticated user attribution. */
export function emitMobileFeedPerformance(userId: string, observation: MobileFeedPerformanceEvent): Promise<void> {
  const name = observation.event === "ios_feed_performance_window"
    ? "cmux.mobile.feed.performance" : "cmux.mobile.feed.scroll_anomaly";
  return withSpan("cmux-mobile-feed", name, mobileFeedPerformanceAttributes(userId, observation), async () => {});
}
