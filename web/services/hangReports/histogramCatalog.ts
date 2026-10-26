/**
 * The field histogram catalog a schema 3 hang report may name, mirrored from
 * the cmux NEXT client's `HistogramID` (CmuxNextMetrics/HistogramID.swift and
 * HistogramID+Dimensions.swift, frozen by chrome-parity task
 * p09-observability-000). A name never changes meaning once shipped, so this
 * list only grows: a client with a newer catalog sends names this server does
 * not know yet, and ingest drops and counts those instead of refusing the
 * report (Chrome's UMA server also ignores histograms it has no description
 * for; tools/metrics/histograms/README.md).
 *
 * Bucket math is the client's (Histogram.swift, and cmux-tui's
 * `LogLinearHistogram::bucket_index`): values 0 to 3 take buckets 0 to 3, then
 * a value whose highest bit is `o` takes `o * 4` plus its next two bits, so
 * buckets 4 to 7 are never used. Each layout ends with an overflow bucket.
 */

/** The catalog this server knows. A report's `catalog_version` may be newer. */
export const HISTOGRAM_CATALOG_VERSION = 1;

/** The shape every cmux histogram name and stability key has. */
export const FIELD_NAME_PATTERN = /^[a-z0-9_.]{1,64}$/;

export type HistogramLayout =
  | { readonly kind: "logLinear"; readonly maximum: number }
  | { readonly kind: "linear"; readonly maximum: number }
  | { readonly kind: "enumeration"; readonly valueCount: number }
  /** Chromium's own buckets: a bucket pair's first number is the bucket's minimum sample. */
  | { readonly kind: "chromium" };

export type HistogramUnit = "us" | "ms" | "kib" | "percent" | "count" | "enumeration" | "chromium";

export type HistogramDefinition = {
  readonly name: string;
  readonly unit: HistogramUnit;
  readonly layout: HistogramLayout;
};

const KEY_TARGETS = ["view", "terminal"] as const;
const ECHO_ROUTES = ["local", "bridge", "cloud"] as const;
const INPUT_KINDS = ["mouse_down", "mouse_up", "drag", "scroll", "ime_commit", "paste"] as const;
const CONGESTION_KINDS = ["exec", "queue"] as const;
const STARTUP_STAGES = ["launch", "steady"] as const;
const HANG_LANES = [
  "main", "daemon_reader", "daemon_writer", "terminal_output", "local_pty", "background_work", "control",
  "diagnostics", "remote_view", "mobile", "acpmux_pane", "acpmux_status", "agent_activity",
  "browser_host_provider", "cef_children", "ghostty_renderer", "chromium_io", "chromium_host_main", "other",
] as const;
const ENTRYPOINTS = ["key", "pointer", "unattributed", "cli", "mcp", "script", "remote", "page"] as const;
const COMMANDS = ["cmd_t", "cmd_n", "cmd_w"] as const;
const FRAME_SEQUENCES = ["motion", "scroll", "resize", "drag", "remote_stream"] as const;
const LAUNCH_TEMPERATURES = ["warm", "lukewarm", "cold"] as const;
const WAKEUP_SOURCES = ["app_main", "app_total", "daemon"] as const;
/** `HistogramID.ProcessKind`, also the `child_exit` kinds of `stability{}`. */
export const PROCESS_KINDS = [
  "app", "daemon", "host", "holder", "acpmux", "agent_host", "app_host", "browser_host", "chromium_host",
  "renderer", "gpu", "utility", "webkit",
] as const;
/** `HistogramID.MethodClass`, also the `daemon_unresponsive` classes of `stability{}`. */
export const METHOD_CLASSES = ["topology", "terminal_io", "create", "query", "browser", "agent", "cloud", "other"] as const;
const PAGES = [
  "home", "history", "apps", "settings", "cloud", "agent", "keybindings", "diff", "markdown", "passwords",
  "editor", "changelog", "icon_picker", "chief_inspector", "debug_settings", "home_channels", "other",
] as const;
/** `HistogramID.UncleanExit`, in value order. */
export const UNCLEAN_EXITS = ["crash", "system_shutdown", "killed", "fatal_hang"] as const;
/** `HistogramID.ChildExit`, in value order. */
export const CHILD_EXITS = ["clean", "signal", "panic", "oom"] as const;
const CHROMIUM_HISTOGRAMS = [
  "EventLatency.KeyPressed.TotalLatency",
  "EventLatency.MousePressed.TotalLatency",
  "Graphics.Smoothness.PercentDroppedFrames3.AllSequences",
  "Memory.Renderer.PrivateMemoryFootprint",
  "Memory.Gpu.PrivateMemoryFootprint",
  "Stability.Counts2",
  "PageLoad.PaintTiming.NavigationToFirstContentfulPaint",
] as const;

const LAYOUT_BY_UNIT: Record<Exclude<HistogramUnit, "enumeration">, HistogramLayout> = {
  us: { kind: "logLinear", maximum: 60_000_000 },
  ms: { kind: "logLinear", maximum: 3_600_000 },
  kib: { kind: "logLinear", maximum: 256 * 1024 * 1024 },
  count: { kind: "logLinear", maximum: 1_000_000 },
  percent: { kind: "linear", maximum: 100 },
  chromium: { kind: "chromium" },
};

function family(prefix: string, values: readonly string[], unit: HistogramUnit, suffix = ""): HistogramDefinition[] {
  return values.map((value) => definition(`${prefix}${value}${suffix}`, unit));
}

function definition(name: string, unit: HistogramUnit, layout?: HistogramLayout): HistogramDefinition {
  if (layout) return { name, unit, layout };
  if (unit === "enumeration") throw new Error(`enumeration histogram ${name} needs its value count`);
  return { name, unit, layout: LAYOUT_BY_UNIT[unit] };
}

function enumeration(name: string, valueCount: number): HistogramDefinition {
  return definition(name, "enumeration", { kind: "enumeration", valueCount });
}

function catalogDefinitions(): HistogramDefinition[] {
  return [
    ...family("key.frame.", KEY_TARGETS, "us"),
    ...family("key.echo_frame.", ECHO_ROUTES, "us"),
    ...family("input.frame.", INPUT_KINDS, "us"),
    definition("resize.frame", "us"),
    ...family("smoothness.dropped_pct.", FRAME_SEQUENCES, "percent"),
    definition("frame.interval", "us"),
    definition("main.turn", "us"),
    definition("main.queue_delay", "us"),
    ...CONGESTION_KINDS.flatMap((kind) => family(`main.congestion.${kind}.`, STARTUP_STAGES, "ms")),
    definition("hang.over250.per_hour", "count"),
    ...family("hang.thread_hung.", HANG_LANES, "count"),
    ...family("action.commit.", ENTRYPOINTS, "us"),
    ...family("action.", COMMANDS, "us"),
    ...family("action.missed_frames.", COMMANDS, "count"),
    ...family("launch.first_frame.", LAUNCH_TEMPERATURES, "ms"),
    definition("launch.pageins", "count"),
    ...family("idle.wakeups.", WAKEUP_SOURCES, "count"),
    ...family("memory.", PROCESS_KINDS, "kib", "_kib"),
    definition("memory.total_kib", "kib"),
    definition("memory.hidden_workspace_kib", "kib"),
    ...family("cpu.", PROCESS_KINDS, "percent", "_pct"),
    definition("disk.idle_write_kib_per_min", "kib"),
    definition("cef.pump", "us"),
    enumeration("cef.helper_exit", 256),
    definition("renderer.unresponsive_ms", "ms"),
    ...family("webview.inp.", PAGES, "ms"),
    ...family("webview.loaf_ms.", PAGES, "ms"),
    ...family("webview.js_errors.", PAGES, "count"),
    ...family("chromium.", CHROMIUM_HISTOGRAMS, "chromium"),
    ...family("daemon.request.", METHOD_CLASSES, "us"),
    definition("daemon.dispatch.queue_us", "us"),
    ...family("automation.request.", METHOD_CLASSES, "us"),
    definition("automation.main_queue_us", "us"),
    definition("automation.blocked_person", "us"),
    definition("runtime.busy_ms", "ms"),
    definition("remote.input_to_present", "us"),
    definition("stability.launch", "count"),
    definition("stability.active_seconds", "count"),
    enumeration("stability.unclean_exit", UNCLEAN_EXITS.length),
    ...PROCESS_KINDS.map((kind) => enumeration(`stability.child_exit.${kind}`, CHILD_EXITS.length)),
    enumeration("daemon.unresponsive", METHOD_CLASSES.length),
    definition("blocking.violations", "count"),
  ];
}

const CATALOG: ReadonlyMap<string, HistogramDefinition> = new Map(
  catalogDefinitions().map((entry) => [entry.name, entry]),
);

/** Every histogram of catalog version ``HISTOGRAM_CATALOG_VERSION``. */
export function histogramCatalog(): ReadonlyMap<string, HistogramDefinition> {
  return CATALOG;
}

/** The catalog entry of `name`, or null for a name this server does not know. */
export function histogramDefinition(name: string): HistogramDefinition | null {
  return CATALOG.get(name) ?? null;
}

/**
 * Whether `name` may appear on the wire at all: a cmux name, or one of the
 * known Chromium names (whose UMA spelling has capitals). Anything else is a
 * bad shape, never stored or counted.
 */
export function isWellFormedHistogramName(name: string): boolean {
  return FIELD_NAME_PATTERN.test(name) || CATALOG.get(name)?.layout.kind === "chromium";
}

/** The bucket a log-linear value falls in (Histogram.swift `logLinearIndex`). */
export function logLinearIndex(value: number): number {
  if (value < 4) return Math.max(0, Math.floor(value));
  const octave = Math.floor(Math.log2(value));
  // Two exact powers of two around a float rounding edge: trust the integer.
  const exactOctave = 2 ** (octave + 1) <= value ? octave + 1 : 2 ** octave > value ? octave - 1 : octave;
  const sub = Math.floor(value / 2 ** (exactOctave - 2)) % 4;
  return exactOctave * 4 + sub;
}

function logLinearLowerBound(index: number): number {
  if (index < 4) return index;
  const octave = Math.floor(index / 4);
  return 2 ** octave + (index % 4) * 2 ** (octave - 2);
}

function logLinearUpperBound(index: number): number {
  if (index < 4) return index;
  const octave = Math.floor(index / 4);
  return (2 ** octave - 1) + ((index % 4) + 1) * 2 ** (octave - 2);
}

/** Buckets in a layout, its overflow bucket included; null for Chromium's own buckets. */
export function bucketCount(layout: HistogramLayout): number | null {
  switch (layout.kind) {
    case "logLinear": return logLinearIndex(layout.maximum) + 2;
    case "linear": return layout.maximum + 2;
    case "enumeration": return layout.valueCount + 1;
    case "chromium": return null;
  }
}

/** The samples a bucket holds; `high` is null for the overflow bucket. */
export type BucketRange = { readonly low: number; readonly high: number | null };

/**
 * The samples bucket `index` holds, or null when no sample can take it
 * (outside the layout, or log-linear buckets 4 to 7). For Chromium's layout
 * the index is the bucket's minimum sample and the upper end is unknown.
 */
export function bucketRange(layout: HistogramLayout, index: number): BucketRange | null {
  if (!Number.isInteger(index) || index < 0) return null;
  if (layout.kind === "chromium") return { low: index, high: null };
  const count = bucketCount(layout) ?? 0;
  if (index >= count) return null;
  if (index === count - 1) return { low: overflowLow(layout), high: null };
  if (layout.kind !== "logLinear") return { low: index, high: index };
  if (index >= 4 && index < 8) return null;
  return { low: logLinearLowerBound(index), high: Math.min(logLinearUpperBound(index), layout.maximum) };
}

function overflowLow(layout: Exclude<HistogramLayout, { kind: "chromium" }>): number {
  return layout.kind === "enumeration" ? layout.valueCount : layout.maximum + 1;
}

/** Whether `index` is a bucket a sample of `layout` can take. */
export function isValidBucket(layout: HistogramLayout, index: number): boolean {
  return bucketRange(layout, index) !== null;
}

/**
 * The `stability{}` keys this server knows (chrome-parity task
 * p09-observability-109): counts since the last report, flat so an unknown
 * key is dropped the same way an unknown histogram name is.
 */
const STABILITY_KEYS: ReadonlySet<string> = new Set([
  "launch",
  "active_seconds",
  ...UNCLEAN_EXITS.map((exit) => `unclean_exit.${exit}`),
  ...PROCESS_KINDS.flatMap((kind) => CHILD_EXITS.map((exit) => `child_exit.${kind}.${exit}`)),
  ...METHOD_CLASSES.map((methodClass) => `daemon_unresponsive.${methodClass}`),
]);

/** Whether `key` is a `stability{}` key this server knows. */
export function isKnownStabilityKey(key: string): boolean {
  return STABILITY_KEYS.has(key);
}
