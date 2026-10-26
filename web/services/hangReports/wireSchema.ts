import * as Either from "effect/Either";
import * as Schema from "effect/Schema";

import {
  APP_BUILD_PATTERN,
  APP_VERSION_PATTERN,
  CHANNELS,
  Day,
  MAX_COUNT,
  MAX_DURATION_MS,
  OS_VERSION_PATTERN,
  Uuid,
  boundedInt,
  isUnique,
  optionalArray,
  optionalNullable,
} from "./wirePrimitives";
import {
  BlackboxEvent,
  BlockingDetail,
  FieldHistograms,
  InputLatencyEdges,
  InputLatencyRow,
  LaunchSections,
  MAX_BLACKBOX_EVENTS,
  MAX_INPUT_LATENCY_ROWS,
  MainTask,
  ScrollJank,
  Stability,
} from "./wireSchema3";

export { UUID_PATTERN } from "./wirePrimitives";

/**
 * Wire format schemas 2 and 3 of an opt-in cmux NEXT hang report. The bounds
 * and patterns mirror the client's allow-list builder (hang-reports-DESIGN.md
 * section 4). Schema 2 has schema 1's fields; it marks a client with the
 * review 1 and 2 privacy fixes (Data-volume and `..` image paths are "other",
 * no redirects, per-Mac consent). Schema 1 is refused (400, which the client
 * treats as final and drops from its outbox), so reports an older Nightly
 * queued under the old image rules are never stored. Schema 3 adds what the
 * client's `HangReport.WireSchema.v3` carries (``HangReportSchema3``). The
 * Swift client encodes with JSONEncoder, which omits nil optionals, so every
 * nullable field accepts the key absent or `null`, and every array and
 * `metrics` may be absent (read as empty).
 */

export const HANG_REPORT_MAX_BYTES = 64 * 1024;
export const MAX_HANGS = 20;
export const MAX_CPU_EXCEPTIONS = 5;
export const MAX_FRAMES = 64;
export const MAX_BUCKETS = 32;
export const MAX_INTERVALS = 64;
/** Launch histograms per milestone: one per `LaunchTemperature`. */
export const MAX_LAUNCH_HISTOGRAMS = 4;
/** Completion reason counts: one per `LaunchCompletionReason`. */
export const MAX_LAUNCH_REASONS = 6;

const MAX_OFFSET = 2 ** 40;
const MAX_MS_PER_S = 1000;
const MAX_CATALOG_VERSION = 65_535;
/** The client's `HangReport.maxActiveSeconds`: 31 days. */
const MAX_ACTIVE_SECONDS = 31 * 86_400;

export const IMAGE_NAME_PATTERN = /^[A-Za-z0-9 ._+()-]{1,64}$/;
export const OTHER_IMAGE = "other";
// Closed sets, exactly what the client's HardwareClass can send: a free-text
// chip (a name, a host) or an odd memory size is refused, never stored.
const CHIP_PATTERN = /^(?:Apple M[0-9]{1,2}(?: (?:Pro|Max|Ultra))?|Intel|other)$/;
export const MEMORY_SIZES_GB = [4, 8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 256, 512] as const;
const INTERVAL_NAME_PATTERN = /^[a-z0-9_.-]{1,48}$/;

const COUNT_BUCKETS = ["0", "1", "2-5", "6-10", "11-30", "31-100", "101+"] as const;
/** The client's `CoarseCounts.waitLabels`: log2 milliseconds (schema 3's `userBlockingWaitP99Ms`). */
const WAIT_BUCKETS = ["0-1", "1-2", "2-4", "4-8", "8-16", "16-32", "32-64", "64+"] as const;
// The PL-arch signpost catalog raw values.
const INTERVAL_CATEGORIES = ["action", "motion", "key", "switch", "create", "cef", "launch"] as const;
// Schema 3 adds the main-thread turn and input-queueing histograms (`main.turn`, `main.input_queueing`).
const INTERVAL_CATEGORIES_V3 = [...INTERVAL_CATEGORIES, "main"] as const;
// The client's `LaunchTemperature` and `LaunchCompletionReason` (CmuxNextHangReports).
const LAUNCH_TEMPERATURES = ["cold", "lukewarm", "warm", "undetermined"] as const;
const LAUNCH_COMPLETION_REASONS = [
  "visiblePaneLoadedIdle", "visiblePaneTimedOut", "noVisiblePane", "noWindow", "daemonUnavailable", "failsafe",
] as const;

const msPerS = Schema.Number.pipe(Schema.finite(), Schema.between(0, MAX_MS_PER_S));
const CountBucket = Schema.Literal(...COUNT_BUCKETS);

const AppVersion = Schema.Struct({
  version: Schema.String.pipe(Schema.pattern(APP_VERSION_PATTERN)),
  build: Schema.String.pipe(Schema.pattern(APP_BUILD_PATTERN)),
  channel: Schema.Literal(...CHANNELS),
});

const OsVersion = Schema.Struct({ version: Schema.String.pipe(Schema.pattern(OS_VERSION_PATTERN)) });

const Frame = Schema.Struct({
  image: Schema.String.pipe(Schema.pattern(IMAGE_NAME_PATTERN)),
  uuid: optionalNullable(Uuid),
  offset: optionalNullable(boundedInt(MAX_OFFSET)),
}).pipe(Schema.filter((frame) => {
  const located = frame.uuid != null && frame.offset != null;
  const unlocated = frame.uuid == null && frame.offset == null;
  return frame.image === OTHER_IMAGE ? unlocated : located;
}, { message: () => "frame image other carries no uuid or offset; any other image carries both" }));

const Frames = Schema.Array(Frame).pipe(Schema.maxItems(MAX_FRAMES));

const Bucket = Schema.Struct({
  lowMs: boundedInt(MAX_DURATION_MS),
  highMs: boundedInt(MAX_DURATION_MS),
  count: boundedInt(MAX_COUNT),
}).pipe(Schema.filter((bucket) => bucket.lowMs <= bucket.highMs, { message: () => "lowMs above highMs" }));

const hangFields = {
  durationMs: boundedInt(MAX_DURATION_MS),
  cpuMs: optionalNullable(boundedInt(MAX_DURATION_MS)),
  frames: Frames,
};

const Hang = Schema.Struct({
  source: Schema.Literal("metrickit", "watchdog"),
  kind: Schema.Literal("hang", "stall"),
  ...hangFields,
});

/**
 * A schema 3 hang sample (the client's `HangSample`): also the blocking
 * detector's call sites (`source` `detector`, `kind` `blocking`, no duration,
 * a `blocking` object) and a watchdog hang's scheduled `task`. The pairing
 * rules are the client's (HangReportServerRules.swift).
 */
const HangV3 = Schema.Struct({
  source: Schema.Literal("metrickit", "watchdog", "detector"),
  kind: Schema.Literal("hang", "stall", "blocking"),
  ...hangFields,
  blocking: optionalNullable(BlockingDetail),
  task: optionalNullable(MainTask),
}).pipe(Schema.filter(isPairedHang, {
  message: () => "a blocking object goes with a detector sample of no duration; a task with a watchdog hang",
}));

const CpuException = Schema.Struct({
  cpuMs: boundedInt(MAX_DURATION_MS),
  sampledMs: boundedInt(MAX_DURATION_MS),
  frames: Frames,
});

const Metrics = Schema.Struct({
  hangTime: optionalArray(Bucket, MAX_BUCKETS),
  launchFirstDraw: optionalArray(Bucket, MAX_BUCKETS),
  launchResume: optionalArray(Bucket, MAX_BUCKETS),
  launchOptimizedFirstDraw: optionalArray(Bucket, MAX_BUCKETS),
  launchExtended: optionalArray(Bucket, MAX_BUCKETS),
  scrollHitchMsPerS: optionalNullable(msPerS),
  hitchMsPerS: optionalNullable(msPerS),
});

const intervalSchema = <C extends readonly [string, ...string[]]>(categories: C) => Schema.Struct({
  category: Schema.Literal(...categories),
  name: Schema.String.pipe(Schema.pattern(INTERVAL_NAME_PATTERN)),
  count: boundedInt(MAX_COUNT),
  buckets: optionalArray(Bucket, MAX_BUCKETS),
  hitchMsPerS: optionalNullable(msPerS),
});

const countFields = {
  windows: CountBucket,
  workspaces: CountBucket,
  panes: CountBucket,
  tabs: CountBucket,
};

const LaunchHistogram = Schema.Struct({
  temperature: Schema.Literal(...LAUNCH_TEMPERATURES),
  count: boundedInt(MAX_COUNT),
  buckets: Schema.Array(Bucket).pipe(Schema.maxItems(MAX_BUCKETS)),
});

/** One milestone's histograms: at most one per temperature. */
const LaunchHistograms = Schema.Array(LaunchHistogram).pipe(
  Schema.maxItems(MAX_LAUNCH_HISTOGRAMS),
  Schema.filter((histograms) => isUnique(histograms.map((histogram) => histogram.temperature)), {
    message: () => "a temperature appears twice",
  }),
);

const LaunchReasonCounts = Schema.Array(Schema.Struct({
  reason: Schema.Literal(...LAUNCH_COMPLETION_REASONS),
  count: boundedInt(MAX_COUNT),
})).pipe(
  Schema.maxItems(MAX_LAUNCH_REASONS),
  Schema.filter((entries) => isUnique(entries.map((entry) => entry.reason)), {
    message: () => "a completion reason appears twice",
  }),
);

/**
 * The client's `LaunchAggregate` (task p08-startup-115): three milestone
 * histograms by temperature and a count per completion reason. The client
 * always writes the four arrays; an absent one reads as empty.
 */
const Launches = Schema.Struct({
  launchFirstFrame: Schema.optionalWith(LaunchHistograms, { exact: true, default: () => [] }),
  launchStartupComplete: Schema.optionalWith(LaunchHistograms, { exact: true, default: () => [] }),
  launchLiveContent: Schema.optionalWith(LaunchHistograms, { exact: true, default: () => [] }),
  completionReasons: Schema.optionalWith(LaunchReasonCounts, { exact: true, default: () => [] }),
});

// MARK: reports

/** The newest wire schema the server accepts (the Swift client's `HangReport.WireSchema`). */
export const HANG_REPORT_SCHEMA = 3;

const reportFields = {
  reportId: Uuid,
  installId: Uuid,
  day: Day,
  app: AppVersion,
  os: OsVersion,
  hardware: Schema.Struct({
    arch: Schema.Literal("arm64", "x86_64", "other"),
    chip: Schema.String.pipe(Schema.pattern(CHIP_PATTERN)),
    cores: Schema.Number.pipe(Schema.int(), Schema.between(1, 1024)),
    memoryGB: Schema.Literal(...MEMORY_SIZES_GB),
  }),
  cpuExceptions: optionalArray(CpuException, MAX_CPU_EXCEPTIONS),
  stallHistogram: optionalArray(Bucket, MAX_BUCKETS),
  metrics: Schema.optionalWith(Metrics, { exact: true }),
};

/** Schema 2 of the hang report body. Decode with ``decodeHangReport``. */
export const HangReportSchema2 = Schema.Struct({
  schema: Schema.Literal(2),
  ...reportFields,
  counts: Schema.Struct(countFields),
  hangs: optionalArray(Hang, MAX_HANGS),
  intervals: optionalArray(intervalSchema(INTERVAL_CATEGORIES), MAX_INTERVALS),
});

/**
 * Schema 3 of the hang report body: every field the client's
 * `HangReport.WireSchema.v3` writes:
 * - `hangs[]` with detector samples and watchdog task attribution;
 * - `counts.userBlockingWaitP99Ms`, the lanes' user-blocking wait bucket;
 * - `active_seconds` and the `main` interval category;
 * - `launches`, the launch milestone histograms;
 * - `input_latency_bucket_edges_ms`, `input_latency[]` and `scroll_jank`;
 * - `histograms[]`, `stability{}`, `blackbox[]` and `launch_sections[]`, the
 *   field data (chrome-parity p09-observability-063 and 064;
 *   plans/cmux-next/chrome-parity/p09-observability.md section 3D, "Upload");
 * - `catalog_version`, optional: a client histogram catalog version.
 *
 * The client writes at most 48 KiB; the server keeps its 64 KiB cap. A
 * well-formed name or label this server does not know is dropped and counted
 * at ingest (``normalizeFieldData``), not refused; any other bad shape is a 400.
 */
export const HangReportSchema3 = Schema.Struct({
  schema: Schema.Literal(3),
  ...reportFields,
  counts: Schema.Struct({ ...countFields, userBlockingWaitP99Ms: optionalNullable(Schema.Literal(...WAIT_BUCKETS)) }),
  hangs: optionalArray(HangV3, MAX_HANGS),
  intervals: optionalArray(intervalSchema(INTERVAL_CATEGORIES_V3), MAX_INTERVALS),
  catalog_version: optionalNullable(Schema.Number.pipe(Schema.int(), Schema.between(1, MAX_CATALOG_VERSION))),
  active_seconds: optionalNullable(boundedInt(MAX_ACTIVE_SECONDS)),
  launches: optionalNullable(Launches),
  input_latency_bucket_edges_ms: optionalNullable(InputLatencyEdges),
  input_latency: optionalNullable(Schema.Array(InputLatencyRow).pipe(Schema.maxItems(MAX_INPUT_LATENCY_ROWS))),
  scroll_jank: optionalNullable(ScrollJank),
  histograms: Schema.optionalWith(FieldHistograms, { exact: true, default: () => [] }),
  stability: optionalNullable(Stability),
  blackbox: optionalArray(BlackboxEvent, MAX_BLACKBOX_EVENTS),
  launch_sections: Schema.optionalWith(LaunchSections, { exact: true, default: () => [] }),
}).pipe(Schema.filter(hasConsistentInputLatency, {
  message: () => "input latency rows need the bucket edges, one bucket per edge and one over",
}));

export type HangReportV2 = Schema.Schema.Type<typeof HangReportSchema2>;
export type HangReportV3 = Schema.Schema.Type<typeof HangReportSchema3>;
/** A decoded, bounded schema 2 or 3 report. Absent arrays decode as empty. */
export type HangReport = HangReportV2 | HangReportV3;
export type HangReportFrame = Schema.Schema.Type<typeof Frame>;
export type HangReportBucket = Schema.Schema.Type<typeof Bucket>;
export type HangReportHangV3 = Schema.Schema.Type<typeof HangV3>;

const strict = { onExcessProperty: "error", errors: "first" } as const;
const decodeV2 = Schema.decodeUnknownEither(HangReportSchema2, strict);
const decodeV3 = Schema.decodeUnknownEither(HangReportSchema3, strict);

/**
 * Decode an untrusted body strictly by its `schema` number: unknown keys
 * anywhere are rejected. The result carries no detail on failure so no part
 * of the body can be echoed.
 */
export function decodeHangReport(body: unknown): HangReport | null {
  const schema = body !== null && typeof body === "object" ? (body as { readonly schema?: unknown }).schema : undefined;
  const result: Either.Either<HangReport, unknown> = schema === 3 ? decodeV3(body) : decodeV2(body);
  return Either.isRight(result) ? result.right : null;
}

/**
 * The client's pairing (HangReportServerRules.swift): a detector sample is
 * exactly a `blocking` kind, carries the `blocking` object and no duration;
 * only a watchdog hang names its `task`.
 */
function isPairedHang(hang: {
  readonly source: string;
  readonly kind: string;
  readonly durationMs: number;
  readonly blocking?: unknown;
  readonly task?: unknown;
}): boolean {
  const detector = hang.source === "detector";
  if (detector !== (hang.kind === "blocking") || detector !== (hang.blocking != null)) return false;
  if (detector && hang.durationMs !== 0) return false;
  return hang.task == null || (hang.source === "watchdog" && hang.kind === "hang");
}

/** The client writes the edges and the rows together, each row one count per edge plus one over the last. */
function hasConsistentInputLatency(report: {
  readonly input_latency_bucket_edges_ms?: ReadonlyArray<number> | null;
  readonly input_latency?: ReadonlyArray<{ readonly buckets: ReadonlyArray<number> }> | null;
}): boolean {
  const edges = report.input_latency_bucket_edges_ms;
  const rows = report.input_latency;
  if (edges == null || rows == null) return edges == null && rows == null;
  return rows.every((row) => row.buckets.length === edges.length + 1);
}

/** The UTC calendar day of an instant, as `YYYY-MM-DD`. */
export function utcDay(instant: Date): string {
  return instant.toISOString().slice(0, 10);
}

/** Oldest accepted report day, in days before the server's UTC day (the client outbox keeps 14 days). */
export const DAY_WINDOW_PAST = 15;
/** Newest accepted report day, in days after the server's UTC day (client clock ahead of UTC midnight). */
export const DAY_WINDOW_FUTURE = 1;

/** Whether a report day is within server UTC today-15 ... today+1. */
export function dayWithinWindow(day: string, now: Date): boolean {
  const offsetDays = (Date.parse(`${day}T00:00:00Z`) - Date.parse(`${utcDay(now)}T00:00:00Z`)) / 86_400_000;
  return offsetDays >= -DAY_WINDOW_PAST && offsetDays <= DAY_WINDOW_FUTURE;
}
