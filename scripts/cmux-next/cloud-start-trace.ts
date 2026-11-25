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

/*
 * snappy-bench/v1, the cloud leg: send to first token on a fresh Cloud chat, cut into its parts, beside the model's
 * own floor (Leo, 2026-11-25: "austin started a cloud chat on current main ... he apparently got like 40+ seconds
 * from sending message to first token"). On a fresh chat the person's send is the create (Enter on "new chat in
 * Cloud"), so send_first_token_ms is create to first text on the journey's FirstTextTiming clock. The same marks
 * are the cmuxterm-hq app probe rows' `create_marks_ms`, so one projection reads both:
 *
 *   bun scripts/cmux-next/cloud-start-trace.ts snappy --row ROW.json [--row ...] [--floor] [--model M] [--out F]
 *
 * ROW.json is a journey probe.json, a journey.json, or an hq probe result row (or a JSON list of them). --floor times
 * the same model and prompt straight through the Messages API (no cmux in the path) FLOOR_RUNS times: ANTHROPIC_API_KEY
 * to api.anthropic.com, else ANTHROPIC_AUTH_TOKEN at ANTHROPIC_BASE_URL (the gateway a Cloud chat's sr2 route uses),
 * else CLAUDE_CODE_OAUTH_TOKEN. The report's last line on stdout is the JSON; no token, URL or id is ever in it.
 */

/** Each part: [name, from mark, to mark]. Consecutive, so the parts a run reached add up to its send_first_token_ms. */
export const SNAPPY_PARTS = [
  ["claim", "create", "created"], // the create or spare claim answered
  ["machine_start", "created", "running"], // the machine booted or resumed
  ["connect", "running", "login"], // reached over its link, config pushed
  ["login", "login", "login_ready"], // the Claude login copied and checked
  ["acpmux_connect", "login_ready", "session_start"], // acpmux reachable, approvals, the session asked for
  ["harness_spawn", "session_start", "session_ready"], // the harness (Claude Code) spawned and ready
  ["prompt_queue", "session_ready", "send"], // the prompt waiting on the session
  ["request_sent", "send", "sent"], // the prompt handed to the harness
  ["first_token", "sent", "first_text"], // the model request to the first text back
] as const;
export const FLOOR_RUNS = 3;

export function snappyParts(marks: Record<string, number> | undefined): Record<string, number> {
  const out: Record<string, number> = {};
  if (!marks) return out;
  for (const [name, a, b] of SNAPPY_PARTS) {
    if (marks[a] !== undefined && marks[b] !== undefined && marks[b] >= marks[a]) out[name] = marks[b] - marks[a];
  }
  return out;
}

export function p50(values: number[]): number | null {
  const v = values.filter((n) => Number.isFinite(n)).sort((x, y) => x - y);
  if (!v.length) return null;
  const m = Math.floor(v.length / 2);
  return v.length % 2 ? v[m] : Math.round((v[m - 1] + v[m]) / 2);
}

/** The CLI's own step list (`cloud start-chat --json` stages_ms, kept on hq app probe rows) as the same parts. */
const STEP_PARTS: Record<string, string> = { machine: "claim", connect: "connect", copy: "login", approvals: "acpmux_connect", anchor: "acpmux_connect", start: "harness_spawn", "link send": "request_sent", "link observe": "first_token" };
export function stepParts(stages: any): Record<string, number> {
  const out: Record<string, number> = {};
  for (const step of Array.isArray(stages?.steps) ? stages.steps : []) {
    const inner = step?.step === "cloud start-session" && Array.isArray(step?.parts) ? step.parts : [step];
    for (const s of inner) {
      const name = STEP_PARTS[s?.step];
      if (name && typeof s.ms === "number") out[name] = (out[name] ?? 0) + s.ms;
    }
  }
  return out;
}

/** One run's numbers from a journey probe.json / journey.json or an hq probe row: null when it has no times. */
export function snappyRun(row: any): { send_first_token_ms: number | null; parts: Record<string, number>; sign_in_ms?: number; run?: string } | null {
  const marks: Record<string, number> | undefined = row?.create_marks_ms
    ?? [...(Array.isArray(row?.steps) ? row.steps : [])].reverse().find((s: any) => s?.fields?.create_marks_ms)?.fields?.create_marks_ms;
  const fromSteps = stepParts(row?.stages_ms);
  if ((!marks || typeof marks !== "object") && !Object.keys(fromSteps).length) return null;
  const first = typeof marks?.first_text === "number" ? marks.first_text
    : typeof row?.select_to_first_text_ms === "number" ? row.select_to_first_text_ms : null;
  // The CLI's step list when the row has one (it splits the start-session the marks see as one span), else the marks.
  const parts = Object.keys(fromSteps).length ? fromSteps : snappyParts(marks);
  if (!marks) return { send_first_token_ms: first, parts, ...(typeof row?.launch_to_signed_in_ms === "number" ? { sign_in_ms: row.launch_to_signed_in_ms } : {}), ...(typeof row?.run === "string" && /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/actions\/runs\/\d+$/.test(row.run) ? { run: row.run } : {}) };
  // An hq row's reply time when its marks stop at `sent` (the app reads the reply, not a first-text mark).
  if (parts.first_token === undefined && first !== null && marks?.sent !== undefined && first >= marks.sent) parts.first_token = first - marks.sent;
  return {
    send_first_token_ms: first,
    parts,
    ...(typeof row?.launch_to_signed_in_ms === "number" ? { sign_in_ms: row.launch_to_signed_in_ms } : {}),
    ...(typeof row?.run === "string" && /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/actions\/runs\/\d+$/.test(row.run) ? { run: row.run } : {}),
  };
}

type Fetch = (url: string, init: { method: string; headers: Record<string, string>; body: string; signal?: AbortSignal }) => Promise<Response>;

/** Where the floor's request goes and how it signs in, from the environment; null when nothing is set. */
export function floorRoute(env: Record<string, string | undefined>): { url: string; headers: Record<string, string>; via: string } | null {
  const base = { "content-type": "application/json", "anthropic-version": "2023-06-01" };
  const custom: Record<string, string> = {};
  for (const line of (env.ANTHROPIC_CUSTOM_HEADERS ?? "").split("\n")) {
    const i = line.indexOf(":");
    if (i > 0) custom[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  if (env.ANTHROPIC_API_KEY) return { url: "https://api.anthropic.com/v1/messages", headers: { ...base, "x-api-key": env.ANTHROPIC_API_KEY }, via: "api-key" };
  if (env.ANTHROPIC_AUTH_TOKEN && env.ANTHROPIC_BASE_URL) {
    return { url: `${env.ANTHROPIC_BASE_URL.replace(/\/+$/, "")}/v1/messages`, headers: { ...base, ...custom, authorization: `Bearer ${env.ANTHROPIC_AUTH_TOKEN}` }, via: "gateway" };
  }
  if (env.CLAUDE_CODE_OAUTH_TOKEN) {
    return { url: "https://api.anthropic.com/v1/messages", headers: { ...base, authorization: `Bearer ${env.CLAUDE_CODE_OAUTH_TOKEN}`, "anthropic-beta": "oauth-2025-04-20" }, via: "oauth" };
  }
  return null;
}

/** One streamed request's time to its first text delta, or the reason (a status code, never a body or a token). */
export async function floorOnce(route: { url: string; headers: Record<string, string> }, model: string, prompt: string, fetcher: Fetch = fetch as unknown as Fetch, clock = () => performance.now()): Promise<{ ms: number } | { missing: string }> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), 60_000);
  const t0 = clock();
  try {
    // A Claude Code login answers only a request that says it is Claude Code, as the harness's own does.
    const system = route.headers["anthropic-beta"]?.includes("oauth") ? { system: "You are Claude Code, Anthropic's official CLI for Claude." } : {};
    const res = await fetcher(route.url, { method: "POST", headers: route.headers, signal: abort.signal, body: JSON.stringify({ model, max_tokens: 64, stream: true, ...system, messages: [{ role: "user", content: prompt }] }) });
    if (!res.ok || !res.body) return { missing: `HTTP ${res.status}` };
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return { missing: "the stream ended with no text" };
      buf += dec.decode(value, { stream: true });
      if (/"type"\s*:\s*"text_delta"/.test(buf)) {
        const ms = Math.round(clock() - t0);
        abort.abort();
        return { ms };
      }
      if (buf.length > 1 << 20) buf = buf.slice(-4096);
    }
  } catch (e) {
    return { missing: abort.signal.aborted ? "no first text in 60 s" : `request failed: ${(e as Error)?.name ?? "error"}` };
  } finally {
    clearTimeout(timer);
  }
}

/** The model's floor: the p50 of FLOOR_RUNS straight calls (the first warms DNS and TLS as a chat's would be). */
export async function modelFloor(env: Record<string, string | undefined>, model: string, prompt: string, fetcher?: Fetch): Promise<{ ms: number | null; runs: number[]; via: string | null; missing?: string }> {
  const route = floorRoute(env);
  if (!route) return { ms: null, runs: [], via: null, missing: "no ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN with ANTHROPIC_BASE_URL, or CLAUDE_CODE_OAUTH_TOKEN" };
  const runs: number[] = [];
  let missing: string | undefined;
  for (let i = 0; i < FLOOR_RUNS; i++) {
    const r = await floorOnce(route, model, prompt, fetcher);
    if ("ms" in r) runs.push(r.ms);
    else missing = r.missing;
  }
  return { ms: p50(runs), runs, via: route.via, ...(runs.length ? {} : { missing }) };
}

export type SnappyReport = {
  schema: "snappy-bench/v1"; at: string; sha: string | null; host: string; platform: string; surface: "cloud"; mode: "active"; duress: string;
  rows: { send_first_token_ms: (number | null)[]; send_first_token_p50_ms: number | null; model_floor_ttft_ms: number | null; parts: Record<string, number>; runs?: unknown[]; model?: string; floor?: unknown; slowest_part?: string | null };
  run_url: string | null;
};

/** The report: per-run send to first token, its p50, the floor, and each part's p50 across the runs. */
export function snappyReport(runs: NonNullable<ReturnType<typeof snappyRun>>[], floor: { ms: number | null; runs?: number[]; via?: string | null; missing?: string } | null, o: { sha?: string | null; host?: string; platform?: string; duress?: string; model?: string; runUrl?: string | null; at?: Date } = {}): SnappyReport {
  const parts: Record<string, number> = {};
  for (const [name] of SNAPPY_PARTS) {
    const v = p50(runs.map((r) => r.parts[name]).filter((n): n is number => typeof n === "number"));
    if (v !== null) parts[name] = v;
  }
  const signIn = p50(runs.map((r) => r.sign_in_ms).filter((n): n is number => typeof n === "number"));
  if (signIn !== null) parts.sign_in = signIn; // before the send (app launch to signed in), not inside send_first_token_ms
  const slowest = Object.entries(parts).filter(([k]) => k !== "sign_in").sort((a, b) => b[1] - a[1])[0]?.[0] ?? null;
  const send = runs.map((r) => r.send_first_token_ms);
  return {
    schema: "snappy-bench/v1",
    at: (o.at ?? new Date()).toISOString(),
    sha: o.sha ?? null,
    host: o.host ?? "unknown",
    platform: o.platform ?? "mac",
    surface: "cloud",
    mode: "active",
    duress: o.duress ?? "none",
    rows: {
      send_first_token_ms: send,
      send_first_token_p50_ms: p50(send.filter((n): n is number => n !== null)),
      model_floor_ttft_ms: floor?.ms ?? null,
      parts,
      slowest_part: slowest,
      ...(o.model ? { model: o.model } : {}),
      ...(floor ? { floor: { runs: floor.runs ?? [], via: floor.via ?? null, ...(floor.missing ? { missing: floor.missing } : {}) } } : {}),
      runs: runs.map((r) => ({ send_first_token_ms: r.send_first_token_ms, parts: r.parts, ...(r.run ? { run: r.run } : {}) })),
    },
    run_url: o.runUrl ?? runs.find((r) => r.run)?.run ?? null,
  };
}

async function snappyMain(argv: string[]): Promise<number> {
  const { readFileSync, writeFileSync } = await import("node:fs");
  const { hostname } = await import("node:os");
  const rows: any[] = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] !== "--row") continue;
    const text = readFileSync(argv[++i], "utf8").trim();
    const parsed = text.startsWith("[") ? JSON.parse(text) : text.split("\n").filter(Boolean).map((l) => JSON.parse(l));
    rows.push(...(Array.isArray(parsed) ? parsed : [parsed]));
  }
  const val = (f: string) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : undefined; };
  const model = val("--model") ?? "claude-opus-5-5";
  const prompt = val("--prompt") ?? "Reply with exactly: ok";
  const runs = rows.map(snappyRun).filter((r): r is NonNullable<typeof r> => r !== null);
  const floor = argv.includes("--floor") ? await modelFloor(process.env, model, prompt) : null;
  const report = snappyReport(runs, floor, { sha: val("--sha") ?? null, host: val("--host") ?? hostname(), platform: val("--platform") ?? "mac", duress: val("--duress") ?? "none", model, runUrl: val("--run-url") ?? null });
  const line = JSON.stringify(report);
  const out = val("--out");
  if (out) writeFileSync(out, `${line}\n`);
  console.log(line);
  return runs.length ? 0 : 1;
}

if (import.meta.main && process.argv[2] === "snappy") process.exit(await snappyMain(process.argv.slice(3)));
