import { describe, expect, test } from "bun:test";
import { floorOnce, floorRoute, modelFloor, p50, snappyParts, snappyReport, snappyRun, SNAPPY_PARTS, stepParts } from "./cloud-start-trace.ts";

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
