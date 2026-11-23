// Capturing a chat on another host (src/agent-session/acpmux/sim/README.md "Capture from another host"): the
// lines `acpmux session tail --json` and `acpmux session history --json` print, read into the records and
// turns the local capture uses. Fixture text only; no acpmux runs.
//
// Leo, 2026-11-22: "you guys need to be able to rapidly pull up and develop against these scenarios".
import { describe, expect, test } from "bun:test";
import {
  REMOTE_SESSION,
  findReportTurn,
  parseHistory,
  parseTail,
  pickRange,
  readAfterSeq,
} from "../src/agent-session/acpmux/sim/capture";
import { sanitizeRecords } from "../src/agent-session/acpmux/sim/sanitize";

const ID = "01a1f7a7-0000-7000-8000-000000000001";
const T0 = Date.parse("2026-11-23T06:13:42Z");
const line = (seq: number, at: number, kind: string, msg: unknown = {}, dir = "mux") =>
  JSON.stringify({ at, cursor: `peer-a/${ID}:${seq}`, dir, kind, msg, seq, sessionId: ID });

const TAIL = [
  line(10, T0, "user_message", { text: "go", _meta: { origin: { actor: "person" } } }),
  line(11, T0 + 5, "turn_started", { turnId: "t1" }),
  line(12, T0 + 60_000, "agent_message_chunk", { content: { text: "working" } }, "in"),
  // A record from a tail that printed no sessionId: it takes the cursor's.
  JSON.stringify({ at: T0 + 400_000, cursor: `peer-a/${ID}:13`, dir: "mux", kind: "status", msg: {}, seq: 13 }),
  line(14, T0 + 500_000, "turn_end"),
  '{"at":1,"cursor":"peer-a/x:15","dir":"mux","ki', // a torn last line of a stopped tail
].join("\n");

describe("parseTail", () => {
  test("the tail's lines as the records a session folder holds, cursor dropped", () => {
    const records = parseTail(TAIL);
    expect(records.map((record) => record.seq)).toEqual([10, 11, 12, 13, 14]);
    expect(records.every((record) => !("cursor" in record))).toBe(true);
    expect(records.every((record) => record.sessionId === ID)).toBe(true);
    expect(records[2]).toEqual({
      at: T0 + 60_000,
      dir: "in",
      kind: "agent_message_chunk",
      msg: { content: { text: "working" } },
      seq: 12,
      sessionId: ID,
    });
  });
  test("blank, broken and shapeless lines are skipped", () => {
    expect(parseTail('\n\nnot json\n{"seq":1}\n{"seq":"2","kind":"x","at":3}\n')).toEqual([]);
  });
  test("feeds the local capture path unchanged: range, lead-in, sanitize", () => {
    const records = parseTail(TAIL);
    const range = pickRange(records, T0 + 30_000, T0 + 450_000)!;
    expect([range.fromSeq, range.toSeq, range.leadIn, range.inWindow]).toEqual([11, 13, 1, 2]);
    const clean = sanitizeRecords(records, { from: range.fromSeq, to: range.toSeq });
    expect(clean.map((record) => record.kind)).toEqual(["turn_started", "agent_message_chunk", "status"]);
    expect(JSON.stringify(clean)).not.toContain(ID);
    expect(JSON.stringify(clean)).not.toContain("peer-a");
  });
});

const HISTORY = JSON.stringify({
  peer: "peer-a",
  sessionId: ID,
  turns: [
    { seq: 28, startedAt: T0 - 3_600_000, endedAt: T0 - 3_000_000, prompt: "Fix the sidebar motion…" },
    { seq: 9001, startedAt: T0 - 600_000, endedAt: T0 - 500_000, prompt: "[inbox] New messages" },
    { seq: 10, startedAt: T0, endedAt: T0 + 500_000, prompt: "why did it collapse again" },
    { startedAt: T0 + 1, prompt: "no seq" },
  ],
});

describe("parseHistory / readAfterSeq / findReportTurn", () => {
  test("turns oldest first, ones with no seq left out", () => {
    expect(parseHistory(HISTORY).map((turn) => turn.seq)).toEqual([10, 28, 9001]);
    expect(() => parseHistory('{"error":"no_session"}')).toThrow();
  });
  test("reads from the prompt of the turn running when the window opens", () => {
    const turns = parseHistory(
      JSON.stringify({
        turns: [
          { seq: 28, startedAt: T0 - 3_600_000 },
          { seq: 14341, startedAt: T0 },
          { seq: 15000, startedAt: T0 + 3_600_000 },
        ],
      }),
    );
    expect(readAfterSeq(turns, T0 + 6 * 60_000)).toBe(14340);
    expect(readAfterSeq(turns, T0)).toBe(14340);
    expect(readAfterSeq(turns, T0 - 1)).toBe(27);
    expect(readAfterSeq(turns, T0 - 7_200_000)).toBe(0);
  });
  test("a report prompt by its start, case and spacing ignored", () => {
    const turns = parseHistory(HISTORY);
    expect(findReportTurn(turns, "WHY did  it")?.seq).toBe(10);
    expect(findReportTurn(turns, "sidebar motion")?.seq).toBe(28);
    expect(findReportTurn(turns, "nothing like this")).toBeUndefined();
  });
});

test("HOST/NAME reads as a chat on a peer; a path or a bare name does not", () => {
  expect(REMOTE_SESSION.test("peer-a/some-chat")).toBe(true);
  expect(REMOTE_SESSION.test("peer-a/01a1f7a7-0000-7000-8000-000000000001")).toBe(true);
  expect(REMOTE_SESSION.test("/tmp/x/events")).toBe(false);
  expect(REMOTE_SESSION.test("~/x")).toBe(false);
  expect(REMOTE_SESSION.test("some-chat")).toBe(false);
  expect(REMOTE_SESSION.test("test/fixtures/chat-sim/a.ndjson")).toBe(false);
});
