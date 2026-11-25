import { describe, expect, test } from "bun:test";
import { clientSpans, hopDurations, readStartTrace, slowestHop, traceMarkdown, type Trace, type TraceList } from "./cloud-start-trace";

const trace: Trace = {
  trace: "jr-abc-create",
  machine: "m1",
  started_at: 1_000,
  total_ms: 30_000,
  path: "create",
  spans: [
    { hop: "api", start_ms: 1_000, end_ms: 1_400, source: "platform" },
    { hop: "placement", start_ms: 1_000, end_ms: 1_100, source: "platform" },
    { hop: "network", start_ms: 1_100, end_ms: 1_300, source: "platform", attrs: { part: "prepare" } },
    { hop: "provider_create", start_ms: 1_100, end_ms: 9_100, source: "platform" },
    { hop: "network", start_ms: 9_100, end_ms: 11_100, source: "platform", attrs: { part: "attach" } },
    { hop: "boot", start_ms: 9_100, end_ms: 15_100, source: "platform" },
    { hop: "agent_auth", start_ms: 16_000, end_ms: 24_000, source: "cli" },
    { hop: "first_token", start_ms: 25_000, end_ms: 31_000, source: "cli" },
  ],
};
const list: TraceList = {
  window_ms: 86_400_000,
  since_ms: 0,
  traces: [],
  hops: { api: { n: 5, p50_ms: 400, p95_ms: 900 }, provider_create: { n: 5, p50_ms: 8_000, p95_ms: 12_000 }, agent_auth: { n: 5, p50_ms: 7_000, p95_ms: 9_000 } },
};

describe("cloud start trace", () => {
  test("client spans come from the journey's marks, epoch from the create's send", () => {
    const spans = clientSpans({ create: 0, login: 15_000, session_ready: 23_000, send: 24_000, first_text: 30_000 }, 1_000);
    expect(spans).toEqual([
      { hop: "agent_auth", start_ms: 16_000, end_ms: 24_000, source: "cli" },
      { hop: "first_token", start_ms: 25_000, end_ms: 31_000, source: "cli" },
    ]);
    expect(clientSpans({ create: 0, login: 15_000 }, 1_000)).toEqual([]);
    expect(clientSpans(undefined, 1_000)).toEqual([]);
  });

  test("a hop sums its parts; the platform's span wins over a client's except for network", () => {
    const withClient: Trace = { ...trace, spans: [...trace.spans, { hop: "api", start_ms: 900, end_ms: 2_000, source: "cli" }, { hop: "network", start_ms: 15_100, end_ms: 15_600, source: "cli" }] };
    const d = hopDurations(withClient);
    expect(d.api).toBe(400);
    expect(d.network).toBe(2_700);
    expect(d.restore).toBeUndefined();
  });

  test("the slowest hop is the largest p50 over the day", () => {
    expect(slowestHop(list)).toEqual({ hop: "provider_create", p50_ms: 8_000, p95_ms: 12_000 });
    expect(slowestHop({ ...list, hops: {} })).toBeNull();
  });

  test("the markdown names each hop's offset, ms and the day's p50/p95", () => {
    const md = traceMarkdown(trace, list);
    expect(md).toContain("| provider_create | 100 | 8000 | 8000 | 12000 | 5 |");
    expect(md).toContain("| first_token | 24000 | 6000 | - | - | 0 |");
    expect(md).not.toContain("| restore |");
  });

  test("a backend without start traces answers missing, not an error", async () => {
    const got = await readStartTrace(async () => ({ status: 404, body: { error: { code: "not_found" } } }), "jr-abc-create", [{ hop: "agent_auth", start_ms: 1, end_ms: 2, source: "cli" }], "m1");
    expect(got).toEqual({ missing: "start traces are not deployed on this backend (404)" });
  });

  test("posts the spans, then reads the trace and the day's list", async () => {
    const calls: string[] = [];
    const got = await readStartTrace(async (method, route) => {
      calls.push(`${method} ${route}`);
      if (method === "POST") return { status: 200, body: { ok: true, kept: 1 } };
      return route.includes("?") ? { status: 200, body: list } : { status: 200, body: trace };
    }, "jr-abc-create", [{ hop: "agent_auth", start_ms: 1, end_ms: 2, source: "cli" }], "m1");
    expect(calls).toEqual(["POST /v1/cloud/start-traces/jr-abc-create/spans", "GET /v1/cloud/start-traces/jr-abc-create", "GET /v1/cloud/start-traces?limit=200"]);
    expect(got).toEqual({ trace, list });
  });
});
