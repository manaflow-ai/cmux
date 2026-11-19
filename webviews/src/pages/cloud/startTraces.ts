// Cloud start timings (DEV and NIGHTLY): the platform's start traces as the Cloud app server answers
// them, verbatim (cmux-platform `GET /v1/cloud/start-traces` and `/v1/cloud/start-traces/{trace}`),
// and the pure model the waterfall draws. The server serves the two ops only in DEV and NIGHTLY
// builds; a release build answers them unsupported and the page shows no entry (startTraceStore.ts).

/** The hops of one Cloud start, in the order a start runs them (the contract's fixed names). */
export const START_HOPS = [
  "click",
  "api",
  "placement",
  "provider_create",
  "restore",
  "boot",
  "network",
  "agent_auth",
  "first_token",
] as const;

export type StartHop = (typeof START_HOPS)[number];

export type SpanSource = "app" | "cli" | "platform" | "machine";

/** One measured piece of a hop. `attrs` holds fixed codes and numbers only (`path`, `outcome`, `part`). */
export interface StartSpan {
  hop: string;
  start_ms: number;
  end_ms: number;
  source: SpanSource | string;
  attrs?: Record<string, string | number>;
}

/** `cmux.cloud.start_trace.get {trace}`: one start, spans sorted by `start_ms`. */
export interface StartTrace {
  trace: string;
  machine: string | null;
  started_at: number;
  total_ms: number;
  path: string | null;
  spans: StartSpan[];
}

export interface StartTraceSummary {
  trace: string;
  machine: string | null;
  started_at: number;
  total_ms: number;
  path: string | null;
  hops_seen: string[];
}

export interface HopStats {
  n: number;
  p50_ms: number | null;
  p95_ms: number | null;
}

/** `cmux.cloud.start_trace.list {since_ms?, limit?}`: the window's newest starts and each hop's percentiles. */
export interface StartTraceList {
  window_ms: number;
  since_ms: number;
  traces: StartTraceSummary[];
  hops: Partial<Record<string, HopStats>>;
}

/** One drawn piece of a hop: its offset from the start and its length, in ms. */
export interface HopSegment {
  offset: number;
  length: number;
  source: string;
  part?: string;
}

/** One waterfall row. `duration` is the contract's hop duration (the sum the platform computes), null
 * when the start had no such hop (a spare claim has no restore). */
export interface HopRow {
  hop: StartHop;
  segments: HopSegment[];
  /** Offset of the hop's first counted segment, ms from the start. */
  offset: number | null;
  duration: number | null;
  stats: HopStats | null;
  /** This start's hop took longer than the last day's p95 (with enough samples to say so). */
  slow: boolean;
}

export interface Waterfall {
  rows: HopRow[];
  /** A client timed the click; else the axis starts at the server's receipt of the create. */
  clicked: boolean;
  /** The axis length in ms: the start's total, or its last span's end when that is later. */
  span: number;
}

/** Fewer samples than this and p95 says nothing; no row is marked slow. */
export const MIN_SAMPLES_FOR_SLOW = 5;

const CLIENT_SOURCES = ["machine", "cli", "app"];

/** The spans a hop's duration counts (contract): the platform's win over a client's for the same hop,
 * except network, where the server's and one client's are added. Of the clients, the machine's win
 * over the CLI's, and the CLI's over the app's: one client measures a given start. */
export function countedSpans(hop: string, spans: readonly StartSpan[]): StartSpan[] {
  const own = spans.filter((span) => span.hop === hop && span.end_ms >= span.start_ms);
  const platform = own.filter((span) => span.source === "platform");
  const clientSource = CLIENT_SOURCES.find((source) => own.some((span) => span.source === source));
  const client = clientSource ? own.filter((span) => span.source === clientSource) : [];
  if (hop === "network") return [...platform, ...client];
  return platform.length > 0 ? platform : client;
}

export function waterfall(trace: StartTrace, hops: StartTraceList["hops"] = {}): Waterfall {
  // Offsets count from the earliest of the start and its spans, so no bar starts left of the axis.
  const origin = Math.min(
    ...[trace.started_at, ...trace.spans.map((span) => span.start_ms)].filter((at) => Number.isFinite(at)),
  );
  let end = trace.total_ms;
  // The app's create is not timed on the client yet: a start begins at the server's receipt of the
  // create, and `click` is a row only when a client (the CLI, a journey) posted a span for it.
  const shown = START_HOPS.filter((hop) => hop !== "click" || trace.spans.some((span) => span.hop === "click"));
  const rows = shown.map((hop): HopRow => {
    const counted = countedSpans(hop, trace.spans).sort((a, b) => a.start_ms - b.start_ms);
    const segments = counted.map((span) => {
      const part = span.attrs?.part;
      return {
        offset: Math.max(0, span.start_ms - origin),
        length: span.end_ms - span.start_ms,
        source: String(span.source),
        ...(typeof part === "string" ? { part } : {}),
      };
    });
    for (const segment of segments) end = Math.max(end, segment.offset + segment.length);
    const duration = segments.length > 0 ? segments.reduce((sum, segment) => sum + segment.length, 0) : null;
    const stats = hops[hop] ?? null;
    const slow =
      duration !== null &&
      !!stats &&
      stats.n >= MIN_SAMPLES_FOR_SLOW &&
      stats.p95_ms !== null &&
      duration > stats.p95_ms;
    return { hop, segments, offset: segments[0]?.offset ?? null, duration, stats, slow };
  });
  return { rows, clicked: shown.includes("click"), span: Math.max(1, end) };
}

/** Round axis ticks for an axis of `span` ms: 1, 2 or 5 times a power of ten, about `count` of them. */
export function axisTicks(span: number, count = 4): number[] {
  if (!(span > 0)) return [0];
  const raw = span / count;
  const power = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 5, 10].map((m) => m * power).find((m) => m >= raw) ?? 10 * power;
  const ticks: number[] = [];
  for (let at = 0; at <= span + 1e-9; at += step) ticks.push(Math.round(at));
  return ticks;
}

/** A trace id the contract allows (`^[A-Za-z0-9_-]{8,80}$`); anything else is never sent. */
export function isTraceId(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{8,80}$/.test(value);
}

/** A duration as people read it: whole ms under a second, else seconds with one decimal under a
 * minute. Localized through Intl's unit formats, so no unit string ships in the catalog. */
export function formatDuration(ms: number | null | undefined, locale?: string): string {
  if (ms === null || ms === undefined || !Number.isFinite(ms)) return "–";
  if (ms < 1000)
    return new Intl.NumberFormat(locale, { style: "unit", unit: "millisecond", unitDisplay: "narrow" }).format(
      Math.round(ms),
    );
  if (ms < 60_000)
    return new Intl.NumberFormat(locale, {
      style: "unit",
      unit: "second",
      unitDisplay: "narrow",
      maximumFractionDigits: ms < 10_000 ? 2 : 1,
    }).format(ms / 1000);
  return new Intl.NumberFormat(locale, {
    style: "unit",
    unit: "minute",
    unitDisplay: "narrow",
    maximumFractionDigits: 1,
  }).format(ms / 60_000);
}
