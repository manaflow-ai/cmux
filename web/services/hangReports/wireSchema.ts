import * as Either from "effect/Either";
import * as Schema from "effect/Schema";

/**
 * Wire format schema 1 of an opt-in cmux NEXT hang report. The bounds and
 * patterns mirror the client's allow-list builder (hang-reports-DESIGN.md
 * section 4). The Swift client encodes with JSONEncoder, which omits nil
 * optionals, so every nullable field accepts the key absent or `null`, and
 * every array and `metrics` may be absent (read as empty).
 */

export const HANG_REPORT_MAX_BYTES = 64 * 1024;
export const MAX_HANGS = 20;
export const MAX_CPU_EXCEPTIONS = 5;
export const MAX_FRAMES = 64;
export const MAX_BUCKETS = 32;
export const MAX_INTERVALS = 64;

const MAX_DURATION_MS = 86_400_000;
const MAX_OFFSET = 2 ** 40;
const MAX_COUNT = 1_000_000_000;
const MAX_MS_PER_S = 1000;

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
const CHIP_PATTERN = /^[A-Za-z0-9 ()._+-]{1,48}$/;
const INTERVAL_NAME_PATTERN = /^[a-z0-9_.-]{1,48}$/;

const COUNT_BUCKETS = ["0", "1", "2-5", "6-10", "11-30", "31-100", "101+"] as const;
const CHANNELS = ["nightly", "dev", "rc", "release"] as const;
// The PL-arch signpost catalog raw values.
const INTERVAL_CATEGORIES = ["action", "motion", "key", "switch", "create", "cef", "launch"] as const;

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

const Interval = Schema.Struct({
  category: Schema.Literal(...INTERVAL_CATEGORIES),
  name: Schema.String.pipe(Schema.pattern(INTERVAL_NAME_PATTERN)),
  count: boundedInt(MAX_COUNT),
  buckets: optionalArray(Bucket, MAX_BUCKETS),
  hitchMsPerS: optionalNullable(msPerS),
});

/** Schema 1 of the hang report body. Decode with ``decodeHangReport``. */
export const HangReportSchema = Schema.Struct({
  schema: Schema.Literal(1),
  reportId: Uuid,
  installId: Uuid,
  day: Schema.String.pipe(Schema.pattern(DAY_PATTERN), Schema.filter(isCalendarDay, { message: () => "not a calendar day" })),
  app: Schema.Struct({
    version: Schema.String.pipe(Schema.pattern(APP_VERSION_PATTERN)),
    build: Schema.String.pipe(Schema.pattern(APP_BUILD_PATTERN)),
    channel: Schema.Literal(...CHANNELS),
  }),
  os: Schema.Struct({ version: Schema.String.pipe(Schema.pattern(OS_VERSION_PATTERN)) }),
  hardware: Schema.Struct({
    arch: Schema.Literal("arm64", "x86_64", "other"),
    chip: Schema.String.pipe(Schema.pattern(CHIP_PATTERN)),
    cores: Schema.Number.pipe(Schema.int(), Schema.between(1, 1024)),
    memoryGB: Schema.Number.pipe(Schema.int(), Schema.between(1, 16_384)),
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
  intervals: optionalArray(Interval, MAX_INTERVALS),
});

/** A decoded, bounded schema 1 report. Absent arrays decode as empty. */
export type HangReport = Schema.Schema.Type<typeof HangReportSchema>;
export type HangReportFrame = Schema.Schema.Type<typeof Frame>;
export type HangReportBucket = Schema.Schema.Type<typeof Bucket>;

const decode = Schema.decodeUnknownEither(HangReportSchema, { onExcessProperty: "error", errors: "first" });

/**
 * Decode an untrusted body strictly: unknown keys anywhere are rejected. The
 * result carries no detail on failure so no part of the body can be echoed.
 */
export function decodeHangReport(body: unknown): HangReport | null {
  const result = decode(body);
  return Either.isRight(result) ? result.right : null;
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
