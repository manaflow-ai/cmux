import { describe, expect, test } from "bun:test";
import { AcpWireLog, MAX_ENTRIES, MAX_PAYLOAD_CHARS, MAX_TEXT_CHARS, redactEndpoint } from "./wire";

function log() {
  let now = 1_000;
  let clock = 0;
  const wire = new AcpWireLog(
    () => now,
    () => clock,
  );
  return {
    wire,
    advance(ms: number) {
      now += ms;
      clock += ms;
    },
  };
}

describe("ACP wire log", () => {
  test("a reply carries its request's method and latency", () => {
    const { wire, advance } = log();
    wire.sent(JSON.stringify({ jsonrpc: "2.0", id: 7, method: "session/prompt", params: {} }), "session/prompt", 7);
    advance(42.5);
    wire.received(JSON.stringify({ jsonrpc: "2.0", id: 7, result: { stopReason: "end_turn" } }));
    const [request, reply] = wire.entries();
    expect(request).toMatchObject({ dir: "out", kind: "request", method: "session/prompt", id: 7, at: 1_000 });
    expect(reply).toMatchObject({
      dir: "in",
      kind: "response",
      method: "session/prompt",
      id: 7,
      latencyMs: 42.5,
      at: 1_042.5,
    });
    expect(wire.stats()).toMatchObject({ requests: 1, errors: 0, inFlight: 0, latencyP50Ms: 42.5, latencyMaxMs: 42.5 });
  });

  test("errors, notifications and unparsable messages are told apart", () => {
    const { wire } = log();
    wire.sent("{}", "_acpmux/attach", 1);
    wire.received(JSON.stringify({ id: 1, error: { message: "no such session" } }));
    wire.received(JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: {} }));
    wire.received("not json");
    wire.sent("{}", "session/cancel");
    expect(wire.entries().map((entry) => entry.kind)).toEqual([
      "request",
      "error",
      "notification",
      "invalid",
      "notification",
    ]);
    expect(wire.stats()).toMatchObject({ errors: 1, lastError: "_acpmux/attach: no such session" });
  });

  test("a close abandons the requests still out and counts reconnects", () => {
    const { wire } = log();
    wire.sent("{}", "_acpmux/events", 3);
    wire.lifecycle("close", { code: 1006 });
    wire.lifecycle("reconnect scheduled", { delayMs: 250 });
    wire.lifecycle("connected");
    const events = wire
      .entries()
      .filter((entry) => entry.kind === "lifecycle")
      .map((entry) => entry.event);
    expect(events).toEqual(["abandoned", "close", "reconnect scheduled", "connected"]);
    expect(wire.stats()).toMatchObject({ inFlight: 0, closes: 1, reconnects: 1, connects: 1 });
  });

  test("the log keeps the newest entries within its bounds", () => {
    const { wire } = log();
    for (let index = 0; index < MAX_ENTRIES + 10; index += 1) wire.lifecycle("tick");
    expect(wire.entries().length).toBe(MAX_ENTRIES);
    expect(wire.entries()[0]!.seq).toBe(11);
    expect(wire.stats().dropped).toBe(10);

    const big = "x".repeat(MAX_PAYLOAD_CHARS * 2);
    wire.received(big);
    const last = wire.entries().at(-1)!;
    expect(last.size).toBe(big.length);
    expect(last.text!.length).toBe(MAX_PAYLOAD_CHARS);
    expect(last.truncated).toBe(true);

    for (let index = 0; index < MAX_TEXT_CHARS / MAX_PAYLOAD_CHARS + 5; index += 1) wire.received(big);
    const held = wire.entries().reduce((total, entry) => total + (entry.text?.length ?? 0), 0);
    expect(held).toBeLessThanOrEqual(MAX_TEXT_CHARS);
  });

  test("an export is JSON Lines with a header, and endpoints lose their token", () => {
    const { wire } = log();
    wire.lifecycle("connecting", { endpoint: redactEndpoint("ws://127.0.0.1:4100/acp?token=secret&x=1") });
    const lines = wire
      .exportJsonl({ sessionId: "a" })
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    expect(lines[0]).toMatchObject({ type: "acp-wire-log", sessionId: "a", stats: { entries: 1 } });
    expect(lines[1].detail.endpoint).toBe("ws://127.0.0.1:4100/acp?x=1");
    expect(JSON.stringify(lines)).not.toContain("secret");
  });
});
