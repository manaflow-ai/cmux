// Capturing a reported breakage as a chat-sim fixture (src/agent-session/acpmux/sim/README.md "Capture a
// reported breakage"): his clock times read as he writes them, the report prompt found, and the records
// kept reaching back to the running turn's start.
//
// Leo, 2026-11-22: "you guys need to be able to rapidly pull up and develop against these scenarios".
import { describe, expect, test } from "bun:test";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { findReport, parseClock, parseWindow, pickRange, readOffsets } from "../src/agent-session/acpmux/sim/capture";
import { sanitizeRecords } from "../src/agent-session/acpmux/sim/sanitize";

const near = Date.parse("2026-11-23T01:00:00Z"); // 5:00PM Nov 22 on his clock
const iso = (ms: number | undefined) => (ms === undefined ? undefined : new Date(ms).toISOString());

describe("parseClock / parseWindow", () => {
  test("his clock, as he writes it", () => {
    expect(iso(parseClock("2:05PM NOV 22", { near }))).toBe("2026-11-22T22:05:00.000Z");
    expect(iso(parseClock("2:05 pm", { near }))).toBe("2026-11-22T22:05:00.000Z");
    expect(iso(parseClock("14:05", { near }))).toBe("2026-11-22T22:05:00.000Z");
    expect(iso(parseClock("22:05Z", { near }))).toBe("2026-11-23T22:05:00.000Z");
    expect(iso(parseClock("2026-11-22T22:05:00Z", { near }))).toBe("2026-11-22T22:05:00.000Z");
    expect(parseClock("soon", { near })).toBeUndefined();
  });
  test("windows", () => {
    expect(parseWindow("2:05PM NOV 22 TO 2:11PM", { near })?.map(iso)).toEqual([
      "2026-11-22T22:05:00.000Z",
      "2026-11-22T22:11:00.000Z",
    ]);
    expect(parseWindow("22:05Z-22:11Z", { near })?.map(iso)).toEqual([
      "2026-11-23T22:05:00.000Z",
      "2026-11-23T22:11:00.000Z",
    ]);
    expect(parseWindow("2026-11-22T10:08:00Z to 2026-11-22T10:18:00Z", { near })?.map(iso)).toEqual([
      "2026-11-22T10:08:00.000Z",
      "2026-11-22T10:18:00.000Z",
    ]);
    expect(parseWindow("11:50PM nov 22 to 12:10AM", { near })?.map(iso)).toEqual([
      "2026-11-23T07:50:00.000Z",
      "2026-11-23T08:10:00.000Z",
    ]);
    expect(parseWindow("2:11PM nov 22", { near, minutes: 6 })?.map(iso)).toEqual([
      "2026-11-22T22:05:00.000Z",
      "2026-11-22T22:11:00.000Z",
    ]);
  });
});

let seq = 0;
const record = (at: number, kind: string, msg: unknown = {}): EventRecord =>
  ({ sessionId: "s", seq: ++seq, at, dir: "mux", kind, msg }) as EventRecord;
const prompt = (at: number, text: string) =>
  record(at, "user_message", { text, _meta: { origin: { actor: "person" } } });

describe("findReport / pickRange / readOffsets", () => {
  seq = 0;
  const records = [
    prompt(1_000, "first ask"),
    record(1_100, "turn_started"),
    record(1_200, "turn_result"),
    prompt(2_000, "do the thing"),
    record(2_100, "turn_started"),
    record(2_500, "agent_message_chunk"),
    record(3_000, "agent_message_chunk"),
    prompt(3_500, "WHY did it  collapse"),
    record(3_600, "user_message", { text: "why did it collapse", _meta: { origin: { actor: "agent" } } }),
  ];
  test("the person's last prompt holding the text, spacing and case ignored", () => {
    expect(findReport(records, "why did it collapse")?.at).toBe(3_500);
    expect(findReport(records, "")?.at).toBe(3_500);
    expect(findReport(records, "nope")).toBeUndefined();
  });
  test("reaches back to the running turn's start", () => {
    const range = pickRange(records, 2_400, 3_500)!;
    expect([range.fromSeq, range.toSeq, range.leadIn, range.inWindow]).toEqual([5, 8, 1, 3]);
    expect(pickRange(records, 2_400, 3_500, "none")!.fromSeq).toBe(6);
    // A window opening after a turn ended does not reach back into it.
    expect(pickRange(records, 1_300, 2_000)!.fromSeq).toBe(4);
    expect(pickRange(records, 9_000, 9_500)).toBeUndefined();
  });
  test("reads as the live pane read", () => {
    expect(readOffsets(100).map((read) => read.from)).toEqual([0]);
    expect(readOffsets(1_000).map((read) => read.from)).toEqual([0, 600]);
    expect(readOffsets(2_000).map((read) => read.from)).toEqual([0, 1_600, 1_000]);
  });
});

test("an id holding a path keeps none of its words", () => {
  const [clean] = sanitizeRecords([
    record(1, "codex.hook/started", { run: { id: "/home/someone/.codex/hooks.json:exec-12ab" }, callId: "call_9x" }),
  ]) as unknown as { msg: { run: { id: string }; callId: string } }[];
  expect(clean!.msg.run.id).not.toContain("home");
  expect(clean!.msg.run.id).not.toContain("hooks");
  expect(clean!.msg.callId.startsWith("call_")).toBe(true);
});
