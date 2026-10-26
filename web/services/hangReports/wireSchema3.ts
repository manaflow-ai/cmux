import * as Schema from "effect/Schema";

import { FIELD_NAME_PATTERN, isWellFormedHistogramName } from "./histogramCatalog";
import {
  APP_BUILD_PATTERN,
  APP_VERSION_PATTERN,
  CHANNELS,
  Day,
  MAX_DURATION_MS,
  OS_VERSION_PATTERN,
  Uuid,
  boundedInt,
  isStrictlyAscending,
  isUnique,
  optionalNullable,
  u64,
} from "./wirePrimitives";

/**
 * The shapes only schema 3 carries, each as the Swift client encodes it
 * (CmuxNextHangReports: HangReport+FieldData.swift, HangReport+InputLatency.swift,
 * HangSample.swift). Closed-set labels the client may grow (blocking kinds,
 * input labels, black-box processes) decode with a bounded pattern; ingest
 * drops and counts a value this server does not know (``normalizeFieldData``)
 * instead of refusing the report, as Chrome's UMA server ignores what it has
 * no description for (tools/metrics/histograms/README.md).
 */

/** Field histograms per launch (the current one, and each section). */
export const MAX_HISTOGRAMS = 32;
/** Non-empty `[index, count]` pairs per field histogram. */
export const MAX_HISTOGRAM_BUCKETS = 24;
/** Count leaves in one `stability{}` object. */
export const MAX_STABILITY_LEAVES = 128;
export const MAX_BLACKBOX_EVENTS = 512;
/** Earlier launches folded into one report (the client sends at most one). */
export const MAX_SECTIONS = 8;
/** The client's `HangReport.maxInputLatencyRows`. */
export const MAX_INPUT_LATENCY_ROWS = 64;
/** Input latency bucket edges (the client sends 13). */
export const MAX_INPUT_LATENCY_EDGES = 32;
/** Scroll jank histograms (the client knows 6). */
export const MAX_SCROLL_JANK_HISTOGRAMS = 16;
/** Chrome's percentages stop at 100, missed vsyncs at `kVsyncCountsMax` (50). */
const MAX_SCROLL_JANK_VALUE = 100;
/** Chromium's `HistogramBase::Sample` is an int32; a cmux bucket index is far below it. */
const MAX_BUCKET_KEY = 2 ** 31 - 1;
/** The client's `HangReportBuilder.maxRefreshHz`. */
const MAX_REFRESH_HZ = 1000;

// The client's `HangReportBuilder+FieldData.isEventName` and `HangReport.blackBoxProcess` shapes.
const EVENT_NAME_PATTERN = /^[A-Za-z0-9._-]{1,64}$/;
const PROCESS_PATTERN = /^[a-z_]{1,32}$/;
const PHASE_PATTERN = /^[A-Za-z]$/;
const UNIT_PATTERN = /^[a-z]{1,16}$/;
// Swift case names (`keyPress`, `estimatedVsync`) and raw values (`file-io`, `cpu-lane`).
const CASE_NAME_PATTERN = /^[A-Za-z][A-Za-z0-9]{0,31}$/;
const RAW_LABEL_PATTERN = /^[a-z][a-z0-9-]{0,31}$/;
// `HangReportBuilder.safeTask`: a code-defined identifier, or `other`.
const TASK_OWNER_PATTERN = /^[A-Za-z][A-Za-z0-9._-]{0,63}$/;
const CHROME_HISTOGRAM_PATTERN = /^[A-Za-z0-9_.]{1,64}$/;

// MARK: field histograms and stability (p09-observability-063)

/**
 * One catalog histogram's samples since the last report (the client's
 * `HangReport.FieldHistogram`): its unit and layout ceiling, the non-empty
 * buckets as `[index, count]` pairs ascending by index, their count and sum.
 */
export const FieldHistogram = Schema.Struct({
  name: Schema.String.pipe(Schema.filter(isWellFormedHistogramName, { message: () => "not a histogram name" })),
  unit: Schema.String.pipe(Schema.pattern(UNIT_PATTERN)),
  buckets: Schema.Array(Schema.Tuple(boundedInt(MAX_BUCKET_KEY), u64)).pipe(
    Schema.maxItems(MAX_HISTOGRAM_BUCKETS),
    Schema.filter((pairs) => isStrictlyAscending(pairs.map(([index]) => index)), {
      message: () => "bucket indexes not strictly ascending",
    }),
  ),
  count: u64,
  sum: u64,
  max: u64,
});

export const FieldHistograms = Schema.Array(FieldHistogram).pipe(
  Schema.maxItems(MAX_HISTOGRAMS),
  Schema.filter((histograms) => isUnique(histograms.map((histogram) => histogram.name)), {
    message: () => "a histogram name appears twice",
  }),
);

const StabilityName = Schema.String.pipe(Schema.pattern(FIELD_NAME_PATTERN));
const CountMap = Schema.Record({ key: StabilityName, value: u64 });
const NestedCountMap = Schema.Record({ key: StabilityName, value: CountMap });

/**
 * `stability{}` (the client's `HangReport.Stability`): `launch` and
 * `active_seconds` counts, `unclean_exit{exit}`, `child_exit{kind{exit}}` and
 * `daemon_unresponsive{class}`. Decoded generically so a key this server does
 * not know is dropped and counted, not refused.
 */
export const Stability = Schema.Record({
  key: StabilityName,
  value: Schema.Union(u64, CountMap, NestedCountMap),
}).pipe(Schema.filter((stability) => stabilityLeaves(stability) <= MAX_STABILITY_LEAVES, {
  message: () => "too many stability counts",
}));

/** The counts in a `stability{}` value: 1 for a count, the leaves of a map. */
export function stabilityLeaves(value: unknown): number {
  if (typeof value === "number") return 1;
  if (value === null || typeof value !== "object") return 0;
  return Object.values(value).reduce((total: number, item) => total + stabilityLeaves(item), 0);
}

/**
 * One black-box ring record (the client's `HangReport.BlackBoxEvent`):
 * microseconds after the list's first event, the ring's process, the trace
 * name, Chrome's one-letter phase, and the arguments (absent when 0). An
 * argument is a full `UInt64` (an async slice id is about 7.2e18).
 */
export const BlackboxEvent = Schema.Struct({
  t_us: u64,
  process: Schema.String.pipe(Schema.pattern(PROCESS_PATTERN)),
  name: Schema.String.pipe(Schema.pattern(EVENT_NAME_PATTERN)),
  phase: Schema.String.pipe(Schema.pattern(PHASE_PATTERN)),
  arg0: optionalNullable(u64),
  arg1: optionalNullable(u64),
});

/** An earlier launch's field data under its own profile (the client's `HangReport.LaunchSection`). */
export const LaunchSection = Schema.Struct({
  /** A digest of the source launch's id: the merge script counts a section sent twice once. */
  id: Uuid,
  profile: Schema.Struct({
    version: Schema.String.pipe(Schema.pattern(APP_VERSION_PATTERN)),
    build: Schema.String.pipe(Schema.pattern(APP_BUILD_PATTERN)),
    channel: Schema.Literal(...CHANNELS),
    os: Schema.String.pipe(Schema.pattern(OS_VERSION_PATTERN)),
    build_day: Day,
  }),
  histograms: Schema.optionalWith(FieldHistograms, { exact: true, default: () => [] }),
  stability: optionalNullable(Stability),
});

export const LaunchSections = Schema.Array(LaunchSection).pipe(
  Schema.maxItems(MAX_SECTIONS),
  Schema.filter((sections) => isUnique(sections.map((section) => section.id.toLowerCase())), {
    message: () => "a section id appears twice",
  }),
);

// MARK: input latency (p04-input-010)

const milliseconds = Schema.Number.pipe(Schema.finite(), Schema.between(0, MAX_DURATION_MS));

/** `input_latency_bucket_edges_ms`: each bucket's upper edge, ascending. */
export const InputLatencyEdges = Schema.Array(milliseconds).pipe(
  Schema.minItems(1),
  Schema.maxItems(MAX_INPUT_LATENCY_EDGES),
  Schema.filter(isStrictlyAscending, { message: () => "bucket edges not strictly ascending" }),
);

/** One `input_latency[]` row (the client's `HangReport.InputLatencyRow`). */
export const InputLatencyRow = Schema.Struct({
  kind: Schema.String.pipe(Schema.pattern(CASE_NAME_PATTERN)),
  target: Schema.String.pipe(Schema.pattern(CASE_NAME_PATTERN)),
  entrypoint: Schema.String.pipe(Schema.pattern(CASE_NAME_PATTERN)),
  presentation_source: Schema.String.pipe(Schema.pattern(CASE_NAME_PATTERN)),
  display: Schema.Struct({ refresh_hz: boundedInt(MAX_REFRESH_HZ), vrr: Schema.Boolean }),
  count: u64,
  buckets: Schema.Array(u64).pipe(Schema.maxItems(MAX_INPUT_LATENCY_EDGES + 1)),
  max_ms: milliseconds,
});

const ScrollJankHistogram = Schema.Struct({
  name: Schema.String.pipe(Schema.pattern(CHROME_HISTOGRAM_PATTERN)),
  samples: Schema.Array(Schema.Struct({ value: boundedInt(MAX_SCROLL_JANK_VALUE), count: u64 })).pipe(
    Schema.maxItems(MAX_SCROLL_JANK_VALUE + 1),
    Schema.filter((samples) => isStrictlyAscending(samples.map((sample) => sample.value)), {
      message: () => "scroll jank values not strictly ascending",
    }),
  ),
});

/** `scroll_jank` (the client's `HangReport.ScrollJank`): Chrome's scroll jank counts. */
export const ScrollJank = Schema.Struct({
  presented_frames: u64,
  delayed_frames: u64,
  skipped_frames: u64,
  histograms: Schema.Array(ScrollJankHistogram).pipe(
    Schema.maxItems(MAX_SCROLL_JANK_HISTOGRAMS),
    Schema.filter((histograms) => isUnique(histograms.map((histogram) => histogram.name)), {
      message: () => "a scroll jank histogram appears twice",
    }),
  ),
});

// MARK: hang samples (blocking detector, task attribution)

/** `hangs[].blocking` of a detector sample: what the call waited on and where it ran. */
export const BlockingDetail = Schema.Struct({
  kind: Schema.String.pipe(Schema.pattern(RAW_LABEL_PATTERN)),
  context: Schema.String.pipe(Schema.pattern(RAW_LABEL_PATTERN)),
});

/** `hangs[].task` of a watchdog hang (p06-scheduler-203): the scheduled task's owner and class. */
export const MainTask = Schema.Struct({
  owner: Schema.String.pipe(Schema.pattern(TASK_OWNER_PATTERN)),
  class: Schema.String.pipe(Schema.pattern(CASE_NAME_PATTERN)),
});

// MARK: the client's closed sets

/** `TraceRuntime.Role` through `HangReport.blackBoxProcess`. */
export const BLACKBOX_PROCESSES: ReadonlySet<string> = new Set([
  "app", "daemon", "holder", "terminal_host", "acpmux", "chromium_host", "cli",
]);
/** `TraceRuntime.Phase`: Chrome's JSON trace phases (base/trace_event/common/trace_event_common.h). */
export const BLACKBOX_PHASES: ReadonlySet<string> = new Set(["B", "E", "I", "b", "e", "s", "f", "C"]);
/** `BlockingKind` raw values (CmuxNextCompat/Threading/BlockingKind.swift). */
export const BLOCKING_KINDS: ReadonlySet<string> = new Set([
  "file-io", "socket-read", "socket-write", "sync-wait", "ipc-reply", "process-wait", "process-spawn", "lock-wait",
  "system-call", "sleep", "wrong-lane", "cpu-intensive", "fs-metadata", "sqlite", "process-reap", "system-query",
  "priority-inversion", "ffi",
]);
/** `BlockingContext` raw values (CmuxNextCompat/Threading/BlockingContext.swift). */
export const BLOCKING_CONTEXTS: ReadonlySet<string> = new Set(["main", "pool", "lane", "dedicated", "cpu-lane", "lane-sync"]);
/** `MainWorkClass` descriptions and `HangSample.MainTask.unattributed`. */
export const TASK_CLASSES: ReadonlySet<string> = new Set([
  "input", "frame", "userBlocking", "visible", "automation", "background", "idle", "unattributed",
]);
/** The case names of CmuxNextInputCore's `InputEventKind`, `InputTarget`, `InputEntrypoint`, `InputPresentationSource`. */
export const INPUT_LABELS = {
  kind: new Set([
    "keyPress", "keyRelease", "flags", "mousePress", "mouseRelease", "pointerMove", "drag", "scrollBegin",
    "scrollFirstUpdate", "scrollUpdate", "scrollMomentum", "scrollEnd", "magnify",
  ]),
  target: new Set(["terminal", "textView", "chromiumPage", "webkitPage", "agentPane", "layout", "sidebar", "palette", "other"]),
  entrypoint: new Set(["person", "automation"]),
  presentation_source: new Set([
    "estimatedVsync", "metalPresented", "hostFeedback", "pageEstimated", "extrapolatedVsync", "nominalRefresh",
  ]),
} as const satisfies Record<string, ReadonlySet<string>>;
/** `ScrollJankHistograms.Name` (cc/metrics/scroll_jank_dropped_frame_tracker.cc). */
export const SCROLL_JANK_NAMES: ReadonlySet<string> = new Set([
  "Event.ScrollJank.DelayedFramesPercentage.FixedWindow",
  "Event.ScrollJank.MissedVsyncsSum.FixedWindow",
  "Event.ScrollJank.MissedVsyncsMax.FixedWindow",
  "Event.ScrollJank.DelayedFramesPercentage.PerScroll",
  "Event.ScrollJank.MissedVsyncsSum.PerScroll",
  "Event.ScrollJank.MissedVsyncsMax.PerScroll",
]);

export type HangReportFieldHistogram = Schema.Schema.Type<typeof FieldHistogram>;
export type HangReportStability = Schema.Schema.Type<typeof Stability>;
export type HangReportBlackboxEvent = Schema.Schema.Type<typeof BlackboxEvent>;
export type HangReportLaunchSection = Schema.Schema.Type<typeof LaunchSection>;
export type HangReportInputLatencyRow = Schema.Schema.Type<typeof InputLatencyRow>;
export type HangReportScrollJank = Schema.Schema.Type<typeof ScrollJank>;
