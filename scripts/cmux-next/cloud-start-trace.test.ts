import { describe, expect, test } from "bun:test";
import { floorOnce, floorRoute, mintSendTrace, modelFloor, readSendTrace, sendTraceRows, sendTraceTable, p50, snappyParts, snappyReport, snappyRun, SNAPPY_PARTS, stepParts } from "./cloud-start-trace.ts";

const marks = { create: 0, created: 2658, running: 2701, login: 3082, login_ready: 3082, session_start: 6320, session_ready: 10089, send: 10092, sent: 10558, first_text: 14000 };

describe("snappy-bench/v1 cloud leg", () => {
  test("the parts are consecutive and add up to create to first text", () => {
    const parts = snappyParts(marks);
    expect(Object.keys(parts)).toEqual(SNAPPY_PARTS.map(([n]) => n));
    expect(Object.values(parts).reduce((a, b) => a + b, 0)).toBe(marks.first_text);
    expect(parts.harness_spawn).toBe(3769);
  });

  test("a mark not reached leaves its part out, never a negative", () => {
    const parts = snappyParts({ create: 0, created: 500, running: 400 });
    expect(parts).toEqual({ claim: 500 });
  });

  test("reads a journey's steps, and an hq row's select_to_first_text_ms when its marks stop at sent", () => {
    const fromSteps = snappyRun({ steps: [{ step: "reply", fields: { create_marks_ms: marks } }], run: "https://github.com/o/r/actions/runs/1" });
    expect(fromSteps?.send_first_token_ms).toBe(14000);
    expect(fromSteps?.run).toBe("https://github.com/o/r/actions/runs/1");
    const { first_text: _, ...noFirst } = marks;
    const hq = snappyRun({ create_marks_ms: noFirst, select_to_first_text_ms: 40000, launch_to_signed_in_ms: 8246, run: "not a url" });
    expect(hq?.parts.first_token).toBe(40000 - 10558);
    expect(hq?.sign_in_ms).toBe(8246);
    expect(hq?.run).toBeUndefined();
    expect(snappyRun({ outcome: "fail" })).toBeNull();
  });

  test("an hq row's CLI step list splits the start-session into the same parts", () => {
    const stages = { steps: [{ step: "cloud list-machines", ms: 6 }, { step: "cloud start-session", ms: 27228, parts: [{ step: "machine", ms: 7282 }, { step: "connect", ms: 10826 }, { step: "copy", ms: 0 }, { step: "approvals", ms: 2509 }, { step: "anchor", ms: 1703 }, { step: "start", ms: 3501 }] }, { step: "link send", ms: 956 }, { step: "link observe", ms: 3598 }] };
    expect(stepParts(stages)).toEqual({ claim: 7282, connect: 10826, login: 0, acpmux_connect: 4212, harness_spawn: 3501, request_sent: 956, first_token: 3598 });
    const run = snappyRun({ stages_ms: stages, select_to_first_text_ms: 31798 });
    expect(run?.send_first_token_ms).toBe(31798);
    expect(run?.parts.connect).toBe(10826);
  });

  test("the report has the schema's fields, the p50s and the slowest part", () => {
    const runs = [snappyRun({ create_marks_ms: marks })!, snappyRun({ create_marks_ms: { ...marks, first_text: 50000 } })!, snappyRun({ create_marks_ms: { ...marks, first_text: 20000 } })!];
    const r = snappyReport(runs, { ms: 900, runs: [1000, 900, 800], via: "oauth" }, { sha: "abc", host: "h", at: new Date(0) });
    expect(r.schema).toBe("snappy-bench/v1");
    expect([r.platform, r.surface, r.mode, r.duress]).toEqual(["mac", "cloud", "active", "none"]);
    expect(r.rows.send_first_token_ms).toEqual([14000, 50000, 20000]);
    expect(r.rows.send_first_token_p50_ms).toBe(20000);
    expect(r.rows.model_floor_ttft_ms).toBe(900);
    expect(r.rows.slowest_part).toBe("first_token");
    expect(p50([3, 1, 2, 4])).toBe(3);
  });

  test("guest-timed parts and the probe route's share sit beside the parts", () => {
    const runs = [5000, 7000, 6000].map((g, i) => snappyRun({ steps: [{ step: "reply", fields: { create_marks_ms: marks, guest_ms: { first_token: g, harness_spawn: 400 + i } } }] })!);
    const r = snappyReport(runs, null, { at: new Date(0) });
    expect(r.rows.guest_parts).toEqual({ first_token: 6000, harness_spawn: 401 });
    expect(r.rows.exec_route_ms?.first_token).toBe(runs[0].parts.first_token - 6000);
    expect(snappyReport([snappyRun({ create_marks_ms: marks })!], null).rows).not.toHaveProperty("guest_parts");
  });

  test("the floor picks its route from the environment and never puts a token in its answer", async () => {
    expect(floorRoute({})).toBeNull();
    expect(floorRoute({ ANTHROPIC_API_KEY: "k" })?.via).toBe("api-key");
    expect(floorRoute({ ANTHROPIC_AUTH_TOKEN: "t", ANTHROPIC_BASE_URL: "http://g/" })?.url).toBe("http://g/v1/messages");
    const oauth = floorRoute({ CLAUDE_CODE_OAUTH_TOKEN: "secret-token" })!;
    expect(oauth.via).toBe("oauth");
    let clock = 0;
    const sse = new TextEncoder().encode('event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}\n\n');
    let body = "";
    const ok = async (_u: string, init: { body: string }) => { body = init.body; clock = 420; return new Response(new ReadableStream({ start(c) { c.enqueue(sse); c.close(); } })); };
    expect(await floorOnce(oauth, "claude-opus-5-5", "hi", ok as any, () => clock)).toEqual({ ms: 420 });
    expect(JSON.parse(body).system).toContain("Claude Code");
    const denied = await modelFloor({ CLAUDE_CODE_OAUTH_TOKEN: "secret-token" }, "m", "hi", (async () => new Response("secret-token", { status: 401 })) as any);
    expect(denied).toEqual({ ms: null, runs: [], via: "oauth", missing: "HTTP 401" });
  });
});

describe("send trace (one journey send as one W3C trace)", () => {
  test("mints 32 lowercase hex, carried as traceparent and x-cmux-start-trace", () => {
    const t = mintSendTrace();
    expect(t.id).toMatch(/^[0-9a-f]{32}$/);
    expect(t.headers.traceparent).toMatch(new RegExp(`^00-${t.id}-[0-9a-f]{16}-01$`));
    expect(t.headers["x-cmux-start-trace"]).toBe(t.id);
    expect(mintSendTrace().id).not.toBe(t.id);
  });

  test("an all-zero draw is drawn again", () => {
    let n = 0;
    const t = mintSendTrace((k: number) => new Uint8Array(k).fill(n++ === 0 ? 0 : 0xab));
    expect(t.id).toBe("ab".repeat(16));
  });

  test("rows from the array and the object forms, in trace order, hop ms floor_ms", () => {
    const events = [
      { name: "process_name", ph: "M", args: { name: "cmux-platform" } },
      { name: "first_token", ph: "X", ts: 9_000_000, dur: 1_234_400, args: { trace_id: "x", hop: "first_token", floor_ms: 30 } },
      { name: "api", ph: "X", ts: 1_000_000, dur: 45_000, args: { trace_id: "x", hop: "api", floor_ms: 30 } },
      { name: "boot", ph: "X", ts: 2_000_000, dur: 700_000, args: { hop: "boot" } },
    ];
    const rows = sendTraceRows(events);
    expect(rows).toEqual([{ hop: "api", ms: 45, floor_ms: 30 }, { hop: "boot", ms: 700, floor_ms: null }, { hop: "first_token", ms: 1234, floor_ms: 30 }]);
    expect(sendTraceRows({ traceEvents: events })).toEqual(rows);
    expect(sendTraceRows({ error: "x" })).toEqual([]);
    const table = sendTraceTable(rows).split("\n");
    expect(table[0]).toMatch(/^hop\s+ms\s+floor_ms$/);
    expect(table[2]).toMatch(/^boot\s+700\s+-$/);
  });

  test("a 404 or a thrown read is missing, never an error", async () => {
    expect(await readSendTrace(async () => ({ status: 404, body: { error: { code: "not_found" } } }), "a".repeat(32))).toEqual({ missing: expect.stringContaining("HTTP 404") });
    expect(await readSendTrace(async () => { throw new Error("offline"); }, "a".repeat(32))).toEqual({ missing: "offline" });
    let route = "";
    expect(await readSendTrace(async (_m: string, r: string) => ((route = r), { status: 200, body: [] }), "ab".repeat(16))).toEqual({ body: [] });
    expect(route).toBe(`/v1/cloud/start-traces/${"ab".repeat(16)}/chrome`);
  });
});
