/**
 * The field-histogram catalog the server keeps from schema 3 hang reports.
 *
 * It mirrors the Swift catalog `HistogramID` (CmuxNextMetrics/HistogramID.swift
 * and HistogramID+Dimensions.swift on feat-cmux-next): every name, unit and
 * bucket layout. Chrome's model: tools/metrics/histograms/*.xml is the
 * catalog the UMA server reads; a client name the server does not know is
 * not stored (components/metrics/metrics_log.cc sends hashes, and the
 * dashboard shows only names in histograms.xml).
 *
 * A name the server does not know is dropped and counted, never stored, so
 * a newer Nightly with a new histogram is not refused. Bump
 * ``HISTOGRAM_CATALOG_VERSION`` with every catalog change; each stored
 * report keeps the server's version next to the client's `catalogVersion`.
 */

/** The server catalog's version, stored with every schema 3 report. */
export const HISTOGRAM_CATALOG_VERSION = 1;

/** A histogram's unit, spelled as the Swift `HistogramID.Unit` case. */
export const HISTOGRAM_UNITS = [
  "microseconds",
  "milliseconds",
  "kibibytes",
  "percent",
  "count",
  "enumeration",
  "chromium",
] as const;
export type HistogramUnit = (typeof HISTOGRAM_UNITS)[number];

/** How samples map to bucket indexes (Swift `HistogramID.Layout`). */
export type HistogramLayout =
  | { readonly kind: "logLinear"; readonly maximum: number }
  | { readonly kind: "linear"; readonly maximum: number }
  | { readonly kind: "enumeration"; readonly valueCount: number }
  | { readonly kind: "chromium" };

export type CatalogEntry = { readonly unit: HistogramUnit; readonly layout: HistogramLayout };

/** Sub-buckets per power of two of a log-linear layout. */
export const LOG_LINEAR_SUB_BUCKETS = 4;

const KEY_TARGETS = ["view", "terminal"];
const ECHO_ROUTES = ["local", "bridge", "cloud"];
const INPUT_KINDS = ["mouse_down", "mouse_up", "drag", "scroll", "ime_commit", "paste"];
const CONGESTION_KINDS = ["exec", "queue"];
const STARTUP_STAGES = ["launch", "steady"];
const HANG_LANES = [
  "main", "daemon_reader", "daemon_writer", "terminal_output", "local_pty", "background_work", "control",
  "diagnostics", "remote_view", "mobile", "acpmux_pane", "acpmux_status", "agent_activity",
  "browser_host_provider", "cef_children", "ghostty_renderer", "chromium_io", "chromium_host_main", "other",
];
const ENTRYPOINTS = ["key", "pointer", "unattributed", "cli", "mcp", "script", "remote", "page"];
const COMMANDS = ["cmd_t", "cmd_n", "cmd_w"];
const FRAME_SEQUENCES = ["motion", "scroll", "resize", "drag", "remote_stream"];
const LAUNCH_TEMPERATURES = ["warm", "lukewarm", "cold"];
const WAKEUP_SOURCES = ["app_main", "app_total", "daemon"];
/** The process kinds of the memory, CPU and child-exit families, and of a black-box event. */
export const PROCESS_KINDS = [
  "app", "daemon", "host", "holder", "acpmux", "agent_host", "app_host", "browser_host", "chromium_host",
  "renderer", "gpu", "utility", "webkit",
] as const;
const METHOD_CLASSES = ["topology", "terminal_io", "create", "query", "browser", "agent", "cloud", "other"];
const PAGES = [
  "home", "history", "apps", "settings", "cloud", "agent", "keybindings", "diff", "markdown", "passwords",
  "editor", "changelog", "icon_picker", "chief_inspector", "debug_settings", "home_channels", "other",
];
const UNCLEAN_EXITS = ["crash", "system_shutdown", "killed", "fatal_hang"];
const CHILD_EXITS = ["clean", "signal", "panic", "oom"];
const CHROMIUM = [
  "EventLatency.KeyPressed.TotalLatency",
  "EventLatency.MousePressed.TotalLatency",
  "Graphics.Smoothness.PercentDroppedFrames3.AllSequences",
  "Memory.Renderer.PrivateMemoryFootprint",
  "Memory.Gpu.PrivateMemoryFootprint",
  "Stability.Counts2",
  "PageLoad.PaintTiming.NavigationToFirstContentfulPaint",
];

const DEFAULT_LAYOUT: Record<HistogramUnit, HistogramLayout> = {
  microseconds: { kind: "logLinear", maximum: 60_000_000 },
  milliseconds: { kind: "logLinear", maximum: 3_600_000 },
  kibibytes: { kind: "logLinear", maximum: 256 * 1024 * 1024 },
  count: { kind: "logLinear", maximum: 1_000_000 },
  percent: { kind: "linear", maximum: 100 },
  enumeration: { kind: "enumeration", valueCount: 1 },
  chromium: { kind: "chromium" },
};

function buildCatalog(): ReadonlyMap<string, CatalogEntry> {
  const catalog = new Map<string, CatalogEntry>();
  const add = (names: readonly string[], unit: HistogramUnit, layout: HistogramLayout = DEFAULT_LAYOUT[unit]) => {
    for (const name of names) catalog.set(name, { unit, layout });
  };
  const family = (prefix: string, values: readonly string[], suffix = "") => values.map((value) => `${prefix}${value}${suffix}`);

  add(family("key.frame.", KEY_TARGETS), "microseconds");
  add(family("key.echo_frame.", ECHO_ROUTES), "microseconds");
  add(family("input.frame.", INPUT_KINDS), "microseconds");
  add(["resize.frame", "frame.interval", "main.turn", "main.queue_delay"], "microseconds");
  add(family("smoothness.dropped_pct.", FRAME_SEQUENCES), "percent");
  add(CONGESTION_KINDS.flatMap((kind) => family(`main.congestion.${kind}.`, STARTUP_STAGES)), "milliseconds");
  add(["hang.over250.per_hour"], "count");
  add(family("hang.thread_hung.", HANG_LANES), "count");
  add(family("action.commit.", ENTRYPOINTS), "microseconds");
  add(family("action.", COMMANDS), "microseconds");
  add(family("action.missed_frames.", COMMANDS), "count");
  add(family("launch.first_frame.", LAUNCH_TEMPERATURES), "milliseconds");
  add(["launch.pageins"], "count");
  add(family("idle.wakeups.", WAKEUP_SOURCES), "count");
  add(family("memory.", PROCESS_KINDS, "_kib"), "kibibytes");
  add(["memory.total_kib", "memory.hidden_workspace_kib", "disk.idle_write_kib_per_min"], "kibibytes");
  add(family("cpu.", PROCESS_KINDS, "_pct"), "percent");
  add(["cef.pump"], "microseconds");
  add(["cef.helper_exit"], "enumeration", { kind: "enumeration", valueCount: 256 });
  add(["renderer.unresponsive_ms"], "milliseconds");
  add(family("webview.inp.", PAGES), "milliseconds");
  add(family("webview.loaf_ms.", PAGES), "milliseconds");
  add(family("webview.js_errors.", PAGES), "count");
  add(family("chromium.", CHROMIUM), "chromium");
  add(family("daemon.request.", METHOD_CLASSES), "microseconds");
  add(["daemon.dispatch.queue_us"], "microseconds");
  add(family("automation.request.", METHOD_CLASSES), "microseconds");
  add(["automation.main_queue_us", "automation.blocked_person", "remote.input_to_present"], "microseconds");
  add(["runtime.busy_ms"], "milliseconds");
  add(["stability.launch", "stability.active_seconds", "blocking.violations"], "count");
  add(["stability.unclean_exit"], "enumeration", { kind: "enumeration", valueCount: UNCLEAN_EXITS.length });
  add(family("stability.child_exit.", PROCESS_KINDS), "enumeration", { kind: "enumeration", valueCount: CHILD_EXITS.length });
  add(["daemon.unresponsive"], "enumeration", { kind: "enumeration", valueCount: METHOD_CLASSES.length });
  return catalog;
}

/** Every histogram name the server stores, with its unit and layout. */
export const HISTOGRAM_CATALOG: ReadonlyMap<string, CatalogEntry> = buildCatalog();

/**
 * Every key `stability{}` may carry (task 109's counters): the launch and
 * active-time counts, then one key per value of each enumerated count.
 */
export const STABILITY_KEYS: ReadonlySet<string> = new Set([
  "stability.launch",
  "stability.active_seconds",
  ...UNCLEAN_EXITS.map((exit) => `stability.unclean_exit.${exit}`),
  ...PROCESS_KINDS.flatMap((kind) => CHILD_EXITS.map((exit) => `stability.child_exit.${kind}.${exit}`)),
  ...METHOD_CLASSES.map((methodClass) => `daemon.unresponsive.${methodClass}`),
]);

/**
 * The highest bucket index of a layout (its overflow bucket), or null for
 * Chromium's own buckets, whose count the server does not know.
 *
 * Log-linear: bucket 0 holds values below 1, then 4 buckets per power of
 * two from 1 up to the first power of two at or above the maximum, then
 * the overflow bucket. Linear and enumeration: one bucket per value, then
 * the overflow bucket.
 */
export function maxBucketIndex(layout: HistogramLayout): number | null {
  switch (layout.kind) {
    case "logLinear": return 1 + LOG_LINEAR_SUB_BUCKETS * Math.ceil(Math.log2(layout.maximum));
    case "linear": return layout.maximum + 1;
    case "enumeration": return layout.valueCount;
    case "chromium": return null;
  }
}

/** A bucket's value range `[low, high)`; `high` is Infinity for the overflow bucket. Null for Chromium buckets. */
export function bucketRange(layout: HistogramLayout, index: number): { readonly low: number; readonly high: number } | null {
  const last = maxBucketIndex(layout);
  if (last === null || index < 0 || index > last) return null;
  if (layout.kind !== "logLinear") return index === last ? { low: index, high: Infinity } : { low: index, high: index + 1 };
  if (index === 0) return { low: 0, high: 1 };
  if (index === last) return { low: 2 ** ((last - 1) / LOG_LINEAR_SUB_BUCKETS), high: Infinity };
  const octave = Math.floor((index - 1) / LOG_LINEAR_SUB_BUCKETS);
  const step = (index - 1) % LOG_LINEAR_SUB_BUCKETS;
  const base = 2 ** octave;
  return {
    low: base * (1 + step / LOG_LINEAR_SUB_BUCKETS),
    high: base * (1 + (step + 1) / LOG_LINEAR_SUB_BUCKETS),
  };
}
