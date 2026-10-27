// A cmux page's field data (p09-observability-114): what the shared theme bootstrap
// (WebTheme.bootstrapScript, CmuxNextDesign/Windows/WebTheme.swift) posts to the host, which records it
// into the webview.inp.<page>, webview.loaf_ms.<page> and webview.js_errors.<page> histograms
// (CmuxNextPages PagePerfReport.swift, which reads it with the same rules as parsePerfReport).
// The page names nothing: the host takes the page from the view that got the message, so a report
// with any other key (a URL, a page name) is refused.

/** The `window.webkit.messageHandlers` name of the reports (`WebTheme.perfHandlerName`). */
export const PERF_REPORT_HANDLER = "cmuxPagePerf";

/** The most interactions or long frames the page holds before it reports (`WebTheme.perfReportCapacity`). */
export const PERF_REPORT_CAPACITY = 32;

/** The most samples the host takes in one list (`PagePerfReport.maximumSamples`). */
export const PERF_REPORT_MAXIMUM_SAMPLES = 2 * PERF_REPORT_CAPACITY;

/** An interaction this long or longer makes the page report at once (web vitals' poor INP). */
export const PERF_SLOW_INTERACTION_MS = 200;

/** The Event Timing threshold the page observes with (the smallest the API takes). */
export const PERF_EVENT_THRESHOLD_MS = 16;

/** The longest duration the host takes, in ms (the ms histograms' top bucket). */
const MAXIMUM_MS = 3_600_000;

/** The most script errors one report may count. */
const MAXIMUM_ERRORS = 1_000_000;

/** One report: durations in ms, and the script errors since the page's last report. */
export interface PerfReport {
  readonly v: 1;
  /** Each interaction's longest Event Timing entry. */
  readonly inp: readonly number[];
  /** Each long animation frame, or long task where the engine has no long-animation-frame entries. */
  readonly loaf: readonly number[];
  /** Script errors and unhandled rejections. */
  readonly errors: number;
}

const KEYS = new Set(["v", "inp", "loaf", "errors"]);

function durations(value: unknown): number[] | null {
  if (!Array.isArray(value) || value.length > PERF_REPORT_MAXIMUM_SAMPLES) return null;
  const out: number[] = [];
  for (const item of value) {
    if (typeof item !== "number" || !Number.isFinite(item) || item < 0 || item > MAXIMUM_MS) return null;
    out.push(Math.round(item));
  }
  return out;
}

/** The report `body` is, or null for any other shape, version, key or out-of-range number. */
export function parsePerfReport(body: unknown): PerfReport | null {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return null;
  const object = body as Record<string, unknown>;
  if (Object.keys(object).some((key) => !KEYS.has(key)) || object.v !== 1) return null;
  const inp = durations(object.inp);
  const loaf = durations(object.loaf);
  const errors = object.errors;
  if (!inp || !loaf || typeof errors !== "number" || !Number.isInteger(errors)) return null;
  if (errors < 0 || errors > MAXIMUM_ERRORS) return null;
  return { v: 1, inp, loaf, errors };
}
