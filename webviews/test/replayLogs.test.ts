// The replay bench's logs line up with acpmux's: seq 1, 2, 3... per session, and its pure judging.
import { describe, expect, test } from "bun:test";
import { checkSeq, longLog, mockLogs, parseLog, recordedLog, rowsIn, slope, toRecord } from "../bench/replayLogs";
import { judge, movedPx } from "../bench/transcript-replay.bench";

describe("replay logs", () => {
  test("every log is keyed by seq from 1, one session, time never going back", () => {
    const logs = [longLog({ turns: 40 }), recordedLog(), ...mockLogs(Date.UTC(2026, 10, 3))];
    expect(logs.length).toBeGreaterThan(3);
    for (const log of logs) {
      expect(() => checkSeq(log)).not.toThrow();
      expect(log.events.length).toBeGreaterThan(0);
    }
  });

  test("checkSeq names the record that breaks the keys", () => {
    const events = [toRecord("s", 1, 10, { mux: "turn_started" }), toRecord("s", 3, 11, { mux: "turn_result" })];
    expect(() => checkSeq({ name: "gap", sessionId: "s", events })).toThrow("gap: record 1 has seq 3, expected 2");
  });

  test("the long log's bursts are seq ranges of each kind, rows growing", () => {
    const log = longLog({
      turns: 300,
      checkpoints: [2, 150, 299],
      tokenCount: 10,
      outputUpdates: 5,
      thoughtCount: 6,
      toolCalls: 3,
    });
    const tokens = log.bursts.filter((burst) => burst.kind === "token");
    expect(tokens.map((burst) => burst.toSeq - burst.fromSeq + 1)).toEqual([10, 10, 10]);
    expect(tokens[0]!.rows).toBeLessThan(tokens[1]!.rows);
    expect(tokens[2]!.rows).toBeGreaterThan(1000);
    const sized = (kind: string) =>
      log.bursts.filter((burst) => burst.kind === kind).map((burst) => burst.toSeq - burst.fromSeq + 1);
    expect(sized("thought")).toEqual([6, 6, 6]);
    // Each read is a call that starts and one that ends.
    expect(sized("tool_call")).toEqual([6, 6, 6]);
    const kinds: Record<string, string[]> = {
      token: ["agent_message_chunk"],
      thought: ["agent_thought_chunk"],
      tool_output: ["tool_call_update"],
      tool_call: ["tool_call", "tool_call_update"],
    };
    for (const burst of log.bursts) {
      const events = log.events.slice(burst.fromSeq - 1, burst.toSeq);
      for (const event of events) expect(kinds[burst.kind]).toContain(event.kind);
      if (burst.kind === "tool_call")
        expect(events.map((event) => event.kind)).toEqual(events.map((_, at) => kinds.tool_call![at % 2]!));
    }
  });

  test("a recorded daemon log reads as JSON lines or an events page, in seq order", () => {
    const events = [toRecord("d", 2, 20, { mux: "turn_started" }), toRecord("d", 1, 10, { mux: "user_message" })];
    for (const text of [events.map((event) => JSON.stringify(event)).join("\n"), JSON.stringify({ events })]) {
      const log = parseLog("daemon.jsonl", text);
      expect(log.sessionId).toBe("d");
      expect(log.events.map((event) => event.seq)).toEqual([1, 2]);
      expect(() => checkSeq(log)).not.toThrow();
    }
  });

  test("rows count prompts, calls and runs of reply chunks", () => {
    const events = [
      toRecord("s", 1, 0, { mux: "user_message", msg: { text: "hi" } }),
      toRecord("s", 2, 0, { update: { sessionUpdate: "agent_message_chunk" } }),
      toRecord("s", 3, 0, { update: { sessionUpdate: "agent_message_chunk" } }),
      toRecord("s", 4, 0, { update: { sessionUpdate: "tool_call" } }),
      toRecord("s", 5, 0, { update: { sessionUpdate: "tool_call_update" } }),
      toRecord("s", 6, 0, { update: { sessionUpdate: "agent_message_chunk" } }),
    ];
    expect(rowsIn(events)).toBe(4);
  });

  test("slope reads growth per x", () => {
    expect(
      slope([
        { x: 0, y: 1 },
        { x: 1, y: 3 },
        { x: 2, y: 5 },
      ]),
    ).toBe(2);
    expect(slope([{ x: 1, y: 1 }])).toBe(0);
  });
});

describe("judging a replay", () => {
  test("a row that moves after the first frame is measured; one that leaves counts the view", () => {
    const frames = [[{ id: "a", y: 10, height: 20 }], [{ id: "a", y: 13, height: 20 }], []];
    expect(movedPx(frames, 700)).toEqual({ px: 700, row: "a" });
    expect(movedPx(frames.slice(0, 2), 700)).toEqual({ px: 3, row: "a" });
  });

  test("a budget broken prints why; held budgets print nothing", () => {
    const live = {
      log: "long",
      cls: 0,
      longTasks: 0,
      longestTaskMs: 20,
      heapMb: 10,
      idleMsPerS: 0.2,
      seconds: 1,
      shiftNotes: [],
      bursts: [
        { kind: "token", rows: 0, msPerRecord: 1 },
        { kind: "token", rows: 2000, msPerRecord: 3 },
      ],
    };
    const { rows, misses } = judge([{ log: "mock:a", cls: 0, moved: 0, movedRow: "none", shiftNotes: [] }], [live]);
    expect(rows.find((row) => row.name === "transcript_replay.long.token_slope_ms_per_krow")?.p95).toBe(1);
    expect(misses).toHaveLength(2);
    expect(misses[0]).toContain("BUDGET MISS transcript_replay.long.token_slope_ms_per_krow = 1");
    expect(misses[0]).toContain("O(rows) work per update");
    // 3 ms at 2,000 rows against 1 ms at none: past the growth check's factor.
    expect(misses[1]).toContain("BUDGET MISS token growth = 3x (budget 1.5x)");
  });
});
