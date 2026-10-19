import { describe, expect, test } from "bun:test";

import { parseMobileNetworkOutcome } from "../services/observability/mobileNetworkOutcome";

/**
 * A replay that never settles leaves a surface blank with only a cursor. The
 * client reports it as a non-terminal `stalled` phase; these lock the contract
 * that carries that row through to Axiom.
 */
describe("terminal replay stall telemetry", () => {
  const stall = (properties: Record<string, unknown> = {}) => ({
    event: "ios_connectivity_latency",
    timestamp: "2026-09-23T19:05:25.000Z",
    properties: {
      runtime_role: "mobileClient",
      phase: "terminal_trace",
      outcome: "stalled",
      duration_ms: 30_000,
      user_usable: false,
      trace_id: "00000000000b1a4f",
      operation: "replay",
      terminal_phase: "stalled",
      replay_trigger: "outputReset",
      surface_blank: true,
      barrier_active: true,
      replay_attempt: 1,
      app_foreground: true,
      ...properties,
    },
  });

  test("accepts a stalled replay with its blank-surface context", () => {
    const parsed = parseMobileNetworkOutcome(stall());
    expect(parsed).not.toBeNull();
    expect(parsed?.outcome).toBe("stalled");
    expect(parsed?.terminalPhase).toBe("stalled");
    expect(parsed?.replayTrigger).toBe("outputReset");
    expect(parsed?.surfaceBlank).toBe(true);
    expect(parsed?.barrierActive).toBe(true);
    expect(parsed?.replayAttempt).toBe(1);
  });

  test("keeps surface_blank false distinguishable from an absent value", () => {
    const painted = parseMobileNetworkOutcome(stall({ surface_blank: false }));
    expect(painted?.surfaceBlank).toBe(false);
    const absent = parseMobileNetworkOutcome(
      stall({ surface_blank: undefined, barrier_active: undefined }),
    );
    expect(absent).not.toBeNull();
    expect(absent?.surfaceBlank).toBeUndefined();
  });

  test("carries whether the stall was on screen or across suspension", () => {
    expect(parseMobileNetworkOutcome(stall())?.appForeground).toBe(true);
    expect(parseMobileNetworkOutcome(stall({ app_foreground: false }))?.appForeground).toBe(false);
    expect(parseMobileNetworkOutcome(stall({ app_foreground: "yes" }))).toBeNull();
  });

  test("rejects a non-boolean blank flag and an unknown trigger", () => {
    expect(parseMobileNetworkOutcome(stall({ surface_blank: "yes" }))).toBeNull();
    expect(parseMobileNetworkOutcome(stall({ replay_trigger: "madeUp" }))).toBeNull();
  });

  test("accepts the host capture split on a settled replay", () => {
    const parsed = parseMobileNetworkOutcome(
      stall({ outcome: "success", terminal_phase: "hostCaptureFinished" }),
    );
    expect(parsed?.terminalPhase).toBe("hostCaptureFinished");
  });

  test("still requires trace id and operation on every terminal trace", () => {
    expect(parseMobileNetworkOutcome(stall({ trace_id: undefined }))).toBeNull();
    expect(parseMobileNetworkOutcome(stall({ operation: undefined }))).toBeNull();
  });
});
