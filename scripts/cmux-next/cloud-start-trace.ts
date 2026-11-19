/**
 * The Cloud start waterfall from the journey's side (Leo, 2026-11-19: "the developer debug thing to be able to
 * visualize the sort of breakdown of the timings for the, like the cloud startups among all areas").
 *
 * The platform keeps one trace per create (cmux-platform /v1/cloud/start-traces), keyed by the create op's
 * idempotency key when the create names no `trace`, and records its own hops (api, placement, provider_create,
 * restore, boot, network). It has no mark for the agent's start or its first token, so the client posts those
 * (source "cli"): agent_auth [login, session_ready] and first_token [send, first_text], from the journey's own
 * FirstTextTiming marks (ms from the create call, `createSentAt` epoch). Then it reads the trace back and the last
 * day's per-hop p50/p95, for the summary. Fixed names and numbers only.
 */

export const HOPS = ["click", "api", "placement", "provider_create", "restore", "boot", "network", "agent_auth", "first_token"] as const;
export type Hop = (typeof HOPS)[number];
export type Span = { hop: Hop; start_ms: number; end_ms: number; source: "app" | "cli" | "platform" | "machine"; attrs?: Record<string, string | number> };
export type HopStat = { n: number; p50_ms: number | null; p95_ms: number | null };
export type TraceList = { window_ms: number; since_ms: number; traces: { trace: string; machine: string | null; started_at: number; total_ms: number; path: string | null; hops_seen: string[] }[]; hops: Partial<Record<Hop, HopStat>> };
export type Trace = { trace: string; machine: string | null; started_at: number; total_ms: number; path: string | null; spans: Span[] };

type Raw = (method: string, route: string, body?: unknown, timeoutMs?: number) => Promise<{ status: number; body: any }>;

/** The client hops the journey measured, as epoch spans; a hop whose two marks were not both reached is left out. */
export function clientSpans(marks: Record<string, number> | undefined, createSentAt: number | null): Span[] {
  if (!marks || createSentAt === null) return [];
  const span = (hop: Hop, from: string, to: string): Span[] => {
    const a = marks[from];
    const b = marks[to];
    return a === undefined || b === undefined || b < a ? [] : [{ hop, start_ms: createSentAt + a, end_ms: createSentAt + b, source: "cli" }];
  };
  return [...span("agent_auth", "login", "session_ready"), ...span("first_token", "send", "first_text")];
}

/** Each hop's ms in one trace: the sum of its winning source's spans (platform wins; network adds server and client). */
export function hopDurations(trace: Trace): Partial<Record<Hop, number>> {
  const out: Partial<Record<Hop, number>> = {};
  for (const hop of HOPS) {
    const spans = trace.spans.filter((s) => s.hop === hop);
    if (!spans.length) continue;
    const platform = spans.filter((s) => s.source === "platform");
    const kept = hop === "network" || !platform.length ? spans : platform;
    out[hop] = kept.reduce((n, s) => n + (s.end_ms - s.start_ms), 0);
  }
  return out;
}

/** One trace as a markdown table: each hop's offset from the trace start, its ms, and the last day's p50/p95. */
export function traceMarkdown(trace: Trace, list: TraceList | null): string {
  const durations = hopDurations(trace);
  const t0 = Math.min(trace.started_at, ...trace.spans.map((s) => s.start_ms));
  const rows = HOPS.filter((h) => durations[h] !== undefined || list?.hops[h]).map((h) => {
    const first = trace.spans.filter((s) => s.hop === h).map((s) => s.start_ms);
    const stat = list?.hops[h];
    return `| ${h} | ${first.length ? Math.min(...first) - t0 : "-"} | ${durations[h] ?? "-"} | ${stat?.p50_ms ?? "-"} | ${stat?.p95_ms ?? "-"} | ${stat?.n ?? 0} |`;
  });
  return [`## Cloud start trace \`${trace.trace}\` (${trace.path ?? "?"}, ${trace.total_ms} ms)`, "", "| hop | at ms | ms | p50 24 h | p95 24 h | n |", "|:--|--:|--:|--:|--:|--:|", ...rows, ""].join("\n");
}

/** The slowest hop by the last day's p50, with its p50 and p95. */
export function slowestHop(list: TraceList): { hop: Hop; p50_ms: number; p95_ms: number | null } | null {
  let best: { hop: Hop; p50_ms: number; p95_ms: number | null } | null = null;
  for (const hop of HOPS) {
    const s = list.hops[hop];
    if (s?.p50_ms != null && (!best || s.p50_ms > best.p50_ms)) best = { hop, p50_ms: s.p50_ms, p95_ms: s.p95_ms };
  }
  return best;
}

/**
 * Post the client spans to trace `id`, then read the trace and the last day's list. Null with the reason when the
 * backend has no start traces yet (404 on the list) or the trace is unknown.
 */
export async function readStartTrace(raw: Raw, id: string, spans: Span[], machine: string | null): Promise<{ trace: Trace; list: TraceList | null } | { missing: string }> {
  const route = `/v1/cloud/start-traces/${encodeURIComponent(id)}`;
  if (spans.length) {
    const r = await raw("POST", `${route}/spans`, { spans, ...(machine ? { machine } : {}) }, 15_000);
    if (r.status === 404 && r.body?.error?.code !== "cloud.start_trace.not_found") return { missing: "start traces are not deployed on this backend (404)" };
    if (r.status >= 300 && r.status !== 404) return { missing: `posting spans: HTTP ${r.status} ${String(r.body?.error?.code ?? "")}` };
  }
  const t = await raw("GET", route, undefined, 15_000);
  if (t.status !== 200) return { missing: `trace read: HTTP ${t.status} ${String(t.body?.error?.code ?? "")}` };
  const l = await raw("GET", "/v1/cloud/start-traces?limit=200", undefined, 15_000);
  return { trace: t.body as Trace, list: l.status === 200 ? (l.body as TraceList) : null };
}
