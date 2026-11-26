// One trace per user action (actionTrace.ts): nothing goes out until acpmux says it writes a trace,
// a send's steps carry one trace id from the Enter on, and the request carries it as a traceparent.
import { describe, expect, test } from "bun:test";
import { ActionTrace, LOCAL_ROUND_TRIP_FLOOR_US, traceparentOf } from "./actionTrace";

type Call = { method: string; params: any };

function harness(enabled: boolean | "error") {
  const calls: Call[] = [];
  const trace = new ActionTrace();
  trace.pid = 42;
  trace.connect(async (method, params) => {
    calls.push({ method, params });
    if (method === "_acpmux/trace/status") {
      if (enabled === "error") throw new Error("Method not found");
      return { enabled, now_us: 0 };
    }
    return { recorded: (params.spans as unknown[]).length, enabled };
  });
  return { trace, calls };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("action trace", () => {
  test("a traceparent is W3C shaped and carries the trace id acpmux reads", () => {
    const id = "0123456789abcdef0123456789abcdef";
    expect(traceparentOf(id)).toMatch(/^00-0123456789abcdef0123456789abcdef-[0-9a-f]{16}-01$/);
  });

  test("a send's steps share one trace id, the one its request carries, with their floors", async () => {
    const { trace, calls } = harness(true);
    const traceparent = trace.beginSend("p1", "chat-1");
    expect(traceparent).toBeDefined();
    const traceId = traceparent!.split("-")[1];
    expect(trace.sendTraceparent("p1")!.split("-")[1]).toBe(traceId);
    trace.sendRequested("p1");
    trace.sendAccepted("p1");
    await settle();
    await settle();
    const spans = calls.filter((c) => c.method === "_acpmux/trace/spans").flatMap((c) => c.params.spans);
    expect(calls.filter((c) => c.method === "_acpmux/trace/spans")[0]!.params).toMatchObject({
      process: "webview",
      pid: 42,
    });
    const names = spans.map((s: any) => s.name);
    expect(names).toContain("send.enter_to_request");
    expect(names).toContain("send.enter_to_accepted");
    for (const span of spans) {
      expect(span.trace_id).toBe(traceId);
      expect(span.args).toEqual({ chat: "chat-1" });
      expect(span.ts_us).toBeGreaterThan(1_000_000_000_000_000);
    }
    expect(spans.find((s: any) => s.name === "send.enter_to_accepted").floor_us).toBe(LOCAL_ROUND_TRIP_FLOOR_US);
  });

  test("an acpmux that writes no trace gets no spans and the page stops minting ids", async () => {
    const { trace, calls } = harness(false);
    trace.beginSend("p1");
    trace.sendRequested("p1");
    await settle();
    await settle();
    expect(calls.map((c) => c.method)).toEqual(["_acpmux/trace/status"]);
    expect(trace.active).toBe(false);
    expect(trace.beginSend("p2")).toBeUndefined();
  });

  test("an acpmux without the method reads as off", async () => {
    const { trace, calls } = harness("error");
    trace.beginSend("p1");
    trace.sendRequested("p1");
    await settle();
    await settle();
    expect(calls.map((c) => c.method)).toEqual(["_acpmux/trace/status"]);
    expect(trace.active).toBe(false);
  });

  test("a chat switch traces only the newest selection", async () => {
    const { trace, calls } = harness(true);
    const first = trace.beginSwitch("a");
    const second = trace.beginSwitch("b", "a");
    trace.switchAttached(first);
    trace.step(second, "select_to_attach", LOCAL_ROUND_TRIP_FLOOR_US);
    await settle();
    await settle();
    const spans = calls.filter((c) => c.method === "_acpmux/trace/spans").flatMap((c) => c.params.spans);
    expect(spans.map((s: any) => s.args.chat)).toEqual(["b"]);
    expect(spans[0].trace_id).toBe(second!.traceId);
  });
});
