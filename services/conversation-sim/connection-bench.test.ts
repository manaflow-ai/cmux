import { describe, expect, test } from "bun:test";
import { percentile, summarize } from "./connection-bench";

describe("connection bench summary", () => {
  test("uses stable p50 and p95 values and checks every goal", () => {
    expect(percentile([8, 2, 5, 3], 0.5)).toBe(3);
    const result = summarize(
      { drops: 3, reconnectGoalMs: 100 },
      {
        dropsObserved: 3,
        reconnectLatencyMs: [40, 80, 60],
        laggedReconnects: 0,
        replayedEvents: 3,
        duplicateEvents: 0,
        idempotentSend: true,
        historyRecovered: true,
      },
    );
    expect(result.reconnectLatencyP50Ms).toBe(60);
    expect(result.reconnectLatencyP95Ms).toBe(80);
    expect(result.goals.reconnectWithinGoal.pass).toBe(true);
    expect(result.goals.replayWithoutLag.pass).toBe(true);
    expect(result.goals.idempotentSend.pass).toBe(true);
    expect(result.goals.historyRead.pass).toBe(true);
    expect(result.pass).toBe(true);
  });

  test("fails when a drop is missed or replay lags", () => {
    const result = summarize(
      { drops: 2, reconnectGoalMs: 10 },
      {
        dropsObserved: 1,
        reconnectLatencyMs: [30],
        laggedReconnects: 1,
        replayedEvents: 0,
        duplicateEvents: 0,
        idempotentSend: false,
        historyRecovered: false,
      },
    );
    expect(result.pass).toBe(false);
    expect(result.goals.reconnectWithinGoal.pass).toBe(false);
    expect(result.goals.replayWithoutLag.pass).toBe(false);
    expect(result.goals.idempotentSend.pass).toBe(false);
  });
});
