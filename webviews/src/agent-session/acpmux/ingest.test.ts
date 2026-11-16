import { expect, test } from "bun:test";
import type { EventRecord } from "./direct";
import { coalesceStream, isStreamFrame } from "./ingest";

const update = (seq: number, body: Record<string, unknown>, meta?: Record<string, unknown>) =>
  ({
    sessionId: "s",
    seq,
    at: 1000 + seq,
    dir: "in",
    kind: String(body.sessionUpdate),
    msg: { method: "session/update", params: { update: body, ...(meta ? { _meta: meta } : {}) } },
  }) as EventRecord;
const say = (seq: number, text: string, messageId = "m") =>
  update(seq, { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } });
const out = (seq: number, text: string, toolCallId = "t1") =>
  update(seq, { sessionUpdate: "tool_call_update", toolCallId, content: [{ type: "text", text }] });

test("isStreamFrame reads the top-level method only", () => {
  expect(isStreamFrame('{"jsonrpc":"2.0","method":"session/update","params":{}}')).toBe(true);
  expect(isStreamFrame('{"method": "_acpmux/event","params":{"seq":1}}')).toBe(true);
  expect(isStreamFrame('{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{}}')).toBe(false);
  expect(isStreamFrame('{"jsonrpc":"2.0","id":4,"result":{"events":[{"method":"session/update"}]}}')).toBe(false);
  expect(isStreamFrame('{"jsonrpc":"2.0","id":4,"result":{"method":"session/update"}}')).toBe(false);
  expect(isStreamFrame('{"x":"\\"method\\":\\"session/update\\"","method":"other"}')).toBe(false);
  expect(isStreamFrame("not json")).toBe(false);
});

test("a run of one reply's chunks folds as its first chunk and one joined chunk, every record held", () => {
  const records = [say(1, "a"), say(2, "b"), say(3, "c"), say(4, "d")];
  const steps = coalesceStream(records);
  expect(steps.length).toBe(2);
  expect(steps[0]!.reduce).toBe(records[0]!);
  expect(steps[1]!.hold).toEqual(records.slice(1));
  expect(steps[1]!.reduce.seq).toBe(4);
  expect(steps[1]!.reduce.msg.params.update.content).toEqual({ type: "text", text: "bcd" });
  expect(steps.flatMap((step) => step.hold).map((record) => record.seq)).toEqual([1, 2, 3, 4]);
});

test("runs never cross messages, kinds or calls, and order holds", () => {
  const records = [
    say(1, "a"),
    say(2, "b", "other"),
    out(3, "x"),
    out(4, "y", "t2"),
    out(5, "z", "t2"),
    out(6, "w", "t2"),
  ];
  const steps = coalesceStream(records);
  expect(steps.map((step) => step.reduce.seq)).toEqual([1, 2, 3, 4, 6]);
  expect(steps.flatMap((step) => step.hold).map((record) => record.seq)).toEqual([1, 2, 3, 4, 5, 6]);
});

test("a chunk with anything but text (a status, an image, a phase change) is folded alone", () => {
  const image = update(2, {
    sessionUpdate: "agent_message_chunk",
    messageId: "m",
    content: { type: "image", data: "" },
  });
  const status = update(5, {
    sessionUpdate: "tool_call_update",
    toolCallId: "t1",
    status: "completed",
    content: [{ type: "text", text: "q" }],
  });
  const records = [say(1, "a"), image, say(3, "b"), out(4, "x"), status, out(6, "y")];
  expect(coalesceStream(records).length).toBe(6);
});

test("records whose segment differs never join; their seq and time stamps do not split a run", () => {
  const records = [
    update(
      1,
      { sessionUpdate: "agent_message_chunk", messageId: "m", content: { type: "text", text: "a" } },
      { acpmux: { segment: "1", seq: 1, at: 1 } },
    ),
    update(
      2,
      { sessionUpdate: "agent_message_chunk", messageId: "m", content: { type: "text", text: "b" } },
      { acpmux: { segment: "1", seq: 2, at: 2 } },
    ),
    update(
      3,
      { sessionUpdate: "agent_message_chunk", messageId: "m", content: { type: "text", text: "c" } },
      { acpmux: { segment: "1", seq: 3, at: 3 } },
    ),
    update(
      4,
      { sessionUpdate: "agent_message_chunk", messageId: "m", content: { type: "text", text: "d" } },
      { acpmux: { segment: "2", seq: 4, at: 4 } },
    ),
  ];
  const steps = coalesceStream(records);
  expect(steps.map((step) => step.hold.map((record) => record.seq))).toEqual([[1], [2, 3], [4]]);
});
