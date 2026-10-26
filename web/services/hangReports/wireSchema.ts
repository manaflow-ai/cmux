import * as Either from "effect/Either";
import * as Schema from "effect/Schema";

import { FIELD_NAME_PATTERN, isWellFormedHistogramName } from "./histogramCatalog";

/**
 * Wire format schemas 2 and 3 of an opt-in cmux NEXT hang report. The bounds
 * and patterns mirror the client's allow-list builder (hang-reports-DESIGN.md
 * section 4). Schema 2 has schema 1's fields; it marks a client with the
 * review 1 and 2 privacy fixes (Data-volume and `..` image paths are "other",
 * no redirects, per-Mac consent). Schema 1 is refused (400, which the client
 * treats as final and drops from its outbox), so reports an older Nightly
 * queued under the old image rules are never stored. Schema 3 adds the field
 * data (``HangReportSchema3``). The Swift client encodes with JSONEncoder, which omits nil
 * optionals, so every nullable field accepts the key absent or `null`, and
 * every array and `metrics` may be absent (read as empty).
 */

export const HANG_REPORT_MAX_BYTES = 64 * 1024;
export const MAX_HANGS = 20;
export const MAX_CPU_EXCEPTIONS = 5;
export const MAX_FRAMES = 64;
export const MAX_BUCKETS = 32;
export const MAX_INTERVALS = 64;
/** Field histograms per launch (the current one, and each section). */
export const MAX_HISTOGRAMS = 32;
/** Non-empty `[index, count]` pairs per field histogram. */
export const MAX_HISTOGRAM_BUCKETS = 24;
export const MAX_STABILITY_KEYS = 128;
export const MAX_BLACKBOX_EVENTS = 512;
/** Earlier launches folded into one report, each with its own profile. */
export const MAX_SECTIONS = 8;
/** Launch histograms per milestone: one per `LaunchTemperature`. */
export const MAX_LAUNCH_HISTOGRAMS = 4;
/** Completion reason counts: one per `LaunchCompletionReason`. */
export const MAX_LAUNCH_REASONS = 6;

const MAX_DURATION_MS = 86_400_000;
const MAX_OFFSET = 2 ** 40;
const MAX_COUNT = 1_000_000_000;
const MAX_MS_PER_S = 1000;
const MAX_CATALOG_VERSION = 65_535;
/** The client's `HangReport.maxActiveSeconds`: 31 days. */
const MAX_ACTIVE_SECONDS = 31 * 86_400;
/** Chromium's `HistogramBase::Sample` is an int32; a cmux bucket index is far below it. */
const MAX_BUCKET_KEY = 2 ** 31 - 1;

export const UUID_PATTERN = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
export const IMAGE_NAME_PATTERN = /^[A-Za-z0-9 ._+()-]{1,64}$/;
export const OTHER_IMAGE = "other";
const DAY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
// The Swift client sends `^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$` (or "0") for the
// app version, app build and macOS version. The version also accepts the
// release pipeline's "0.70.0-nightly.<run>" form, and the build a long numeric
// run id ("2123456789012"), in case the client forwards them unchanged.
const CLIENT_VERSION = String.raw`[0-9]{1,6}(?:\.[0-9]{1,6}){0,3}`;
const APP_VERSION_PATTERN = new RegExp(`^(?:${CLIENT_VERSION}|\\d{1,6}(?:\\.\\d{1,6}){0,2}-[a-z]{1,16}(?:\\.\\d{1,20})?)$`);
const APP_BUILD_PATTERN = new RegExp(`^(?:${CLIENT_VERSION}|\\d{1,20}(?:\\.\\d{1,6}){0,2})$`);
const OS_VERSION_PATTERN = new RegExp(`^${CLIENT_VERSION}$`);
// Closed sets, exactly what the client's HardwareClass can send: a free-text
// chip (a name, a host) or an odd memory size is refused, never stored.
const CHIP_PATTERN = /^(?:Apple M[0-9]{1,2}(?: (?:Pro|Max|Ultra))?|Intel|other)$/;
export const MEMORY_SIZES_GB = [4, 8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 256, 512] as const;
const INTERVAL_NAME_PATTERN = /^[a-z0-9_.-]{1,48}$/;

const COUNT_BUCKETS = ["0", "1", "2-5", "6-10", "11-30", "31-100", "101+"] as const;
const CHANNELS = ["nightly", "dev", "rc", "release"] as const;
// The PL-arch signpost catalog raw values.
const INTERVAL_CATEGORIES = ["action", "motion", "key", "switch", "create", "cef", "launch"] as const;
// Schema 3 adds the main-thread turn and input-queueing histograms (`main.turn`, `main.input_queueing`).
const INTERVAL_CATEGORIES_V3 = [...INTERVAL_CATEGORIES, "main"] as const;
// The client's `LaunchTemperature` and `LaunchCompletionReason` (CmuxNextHangReports).
const LAUNCH_TEMPERATURES = ["cold", "lukewarm", "warm", "undetermined"] as const;
const LAUNCH_COMPLETION_REASONS = [
  "visiblePaneLoadedIdle", "visiblePaneTimedOut", "noVisiblePane", "noWindow", "daemonUnavailable", "failsafe",
] as const;
// The trace ring roles' file stems (CmuxNextTrace TraceRing.Role.fileStem; trace.md "Record").
export const BLACKBOX_PROCESSES = ["app", "daemon", "holder", "terminal-host", "acpmux", "chromium-host", "cli"] as const;
// Chrome's JSON trace phases (base/trace_event/common/trace_event_common.h), as the ring stores them.
export const BLACKBOX_PHASES = ["B", "E", "I", "b", "e", "s", "f", "C"] as const;

const boundedInt = (max: number) => Schema.Number.pipe(Schema.int(), Schema.between(0, max));
const msPerS = Schema.Number.pipe(Schema.finite(), Schema.between(0, MAX_MS_PER_S));
const optionalNullable = <S extends Schema.Schema.Any>(schema: S) =>
  Schema.optionalWith(Schema.NullOr(schema), { exact: true });
const optionalArray = <A, I>(schema: Schema.Schema<A, I>, max: number) =>
  Schema.optionalWith(Schema.Array(schema).pipe(Schema.maxItems(max)), {
    exact: true,
    default: (): ReadonlyArray<A> => [],
  });

const Uuid = Schema.String.pipe(Schema.pattern(UUID_PATTERN));
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

const Hang = Schema.Struct({
  source: Schema.Literal("metrickit", "watchdog"),
  kind: Schema.Literal("hang", "stall"),
  durationMs: boundedInt(MAX_DURATION_MS),
  cpuMs: optionalNullable(boundedInt(MAX_DURATION_MS)),
  frames: Frames,
});

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

// MARK: schema 3 field data

/**
 * One field histogram since the last report: a catalog name and its non-empty
 * buckets as `[index, count]` pairs, ascending by index (the client's delta
 * shadow sends each sample once). For a `chromium.*` histogram the first
 * number is the bucket's minimum sample, since Chromium's bucket ranges are
 * its own (base/metrics/sample_vector.h `SampleCountIterator::Get`).
 */
const Histogram = Schema.Struct({
  name: Schema.String.pipe(Schema.filter(isWellFormedHistogramName, { message: () => "not a histogram name" })),
  buckets: Schema.Array(Schema.Tuple(boundedInt(MAX_BUCKET_KEY), boundedInt(MAX_COUNT))).pipe(
    Schema.maxItems(MAX_HISTOGRAM_BUCKETS),
    Schema.filter(isStrictlyAscending, { message: () => "bucket indexes not strictly ascending" }),
  ),
});

const Histograms = Schema.Array(Histogram).pipe(
  Schema.maxItems(MAX_HISTOGRAMS),
  Schema.filter((histograms) => isUnique(histograms.map((histogram) => histogram.name)), {
    message: () => "a histogram name appears twice",
  }),
);

/**
 * Stability counts since the last report (task p09-observability-109), flat:
 * `launch`, `active_seconds`, `unclean_exit.<exit>`,
 * `child_exit.<process kind>.<exit>` and `daemon_unresponsive.<class>`.
 */
const Stability = Schema.Record({
  key: Schema.String.pipe(Schema.pattern(FIELD_NAME_PATTERN)),
  value: boundedInt(MAX_COUNT),
}).pipe(Schema.filter((stability) => Object.keys(stability).length <= MAX_STABILITY_KEYS, {
  message: () => "too many stability keys",
}));

const fieldDataFields = {
  histograms: Schema.optionalWith(Histograms, { exact: true, default: (): ReadonlyArray<HangReportHistogram> => [] }),
  stability: optionalNullable(Stability),
};

/**
 * One black-box ring record (the client's `TraceBlackBoxUpload`): trace
 * clock nanoseconds since the report's oldest event, the ring's process, a
 * catalog signpost name, the phase and the two numeric arguments, each at
 * most 2^53 - 1 so JSON keeps them exact.
 */
const BlackboxEvent = Schema.Struct({
  t_ns: boundedInt(Number.MAX_SAFE_INTEGER),
  process: Schema.Literal(...BLACKBOX_PROCESSES),
  name: Schema.String.pipe(Schema.pattern(FIELD_NAME_PATTERN)),
  phase: Schema.Literal(...BLACKBOX_PHASES),
  arg0: boundedInt(Number.MAX_SAFE_INTEGER),
  arg1: boundedInt(Number.MAX_SAFE_INTEGER),
});

/** An earlier launch's field data, with that launch's profile (task p09-observability-053). */
const LaunchSection = Schema.Struct({
  profile: Schema.Struct({ app: AppVersion, os: OsVersion }),
  ...fieldDataFields,
});

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
  day: Schema.String.pipe(Schema.pattern(DAY_PATTERN), Schema.filter(isCalendarDay, { message: () => "not a calendar day" })),
  app: AppVersion,
  os: OsVersion,
  hardware: Schema.Struct({
    arch: Schema.Literal("arm64", "x86_64", "other"),
    chip: Schema.String.pipe(Schema.pattern(CHIP_PATTERN)),
    cores: Schema.Number.pipe(Schema.int(), Schema.between(1, 1024)),
    memoryGB: Schema.Literal(...MEMORY_SIZES_GB),
  }),
  counts: Schema.Struct({
    windows: CountBucket,
    workspaces: CountBucket,
    panes: CountBucket,
    tabs: CountBucket,
  }),
  hangs: optionalArray(Hang, MAX_HANGS),
  cpuExceptions: optionalArray(CpuException, MAX_CPU_EXCEPTIONS),
  stallHistogram: optionalArray(Bucket, MAX_BUCKETS),
  metrics: Schema.optionalWith(Metrics, { exact: true }),
};

/** Schema 2 of the hang report body. Decode with ``decodeHangReport``. */
export const HangReportSchema2 = Schema.Struct({
  schema: Schema.Literal(2),
  ...reportFields,
  intervals: optionalArray(intervalSchema(INTERVAL_CATEGORIES), MAX_INTERVALS),
});

/**
 * Schema 3 of the hang report body (chrome-parity tasks p09-observability-063
 * and 064; plans/cmux-next/chrome-parity/p09-observability.md section 3D,
 * "Upload"): schema 2, the `main` interval category, and
 * - `catalog_version`: the client's histogram catalog version;
 * - `active_seconds`: the person's active time since the last report;
 * - `launches`: the launch milestone histograms;
 * - `histograms[]` and `stability{}`: the current launch's field data;
 * - `blackbox[]`: the merged ring tails at a hang;
 * - `sections[]`: each earlier launch's field data with its own profile.
 *
 * The client writes at most 48 KiB; the server keeps its 64 KiB cap. A
 * well-formed histogram name or stability key the server's catalog does not
 * know is dropped and counted at ingest (``normalizeFieldData``), not
 * refused; any other bad shape is a 400.
 */
export const HangReportSchema3 = Schema.Struct({
  schema: Schema.Literal(3),
  ...reportFields,
  intervals: optionalArray(intervalSchema(INTERVAL_CATEGORIES_V3), MAX_INTERVALS),
  catalog_version: Schema.Number.pipe(Schema.int(), Schema.between(1, MAX_CATALOG_VERSION)),
  active_seconds: optionalNullable(boundedInt(MAX_ACTIVE_SECONDS)),
  launches: optionalNullable(Launches),
  ...fieldDataFields,
  blackbox: optionalArray(BlackboxEvent, MAX_BLACKBOX_EVENTS),
  sections: optionalArray(LaunchSection, MAX_SECTIONS),
});

export type HangReportV2 = Schema.Schema.Type<typeof HangReportSchema2>;
export type HangReportV3 = Schema.Schema.Type<typeof HangReportSchema3>;
/** A decoded, bounded schema 2 or 3 report. Absent arrays decode as empty. */
export type HangReport = HangReportV2 | HangReportV3;
export type HangReportFrame = Schema.Schema.Type<typeof Frame>;
export type HangReportBucket = Schema.Schema.Type<typeof Bucket>;
export type HangReportHistogram = Schema.Schema.Type<typeof Histogram>;
export type HangReportStability = Schema.Schema.Type<typeof Stability>;
export type HangReportBlackboxEvent = Schema.Schema.Type<typeof BlackboxEvent>;
export type HangReportLaunchSection = Schema.Schema.Type<typeof LaunchSection>;

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

function isUnique(values: ReadonlyArray<string>): boolean {
  return new Set(values).size === values.length;
}

function isStrictlyAscending(pairs: ReadonlyArray<readonly [number, number]>): boolean {
  return pairs.every((pair, index) => index === 0 || (pairs[index - 1]?.[0] ?? -1) < pair[0]);
}

function isCalendarDay(day: string): boolean {
  const parsed = new Date(`${day}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === day;
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
