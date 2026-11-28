// The settled-page bench's stand-in acpmux stamps reply segments as acpmux does (bench/replySegments.ts), so a
// running reply longer than a page keeps one row as its older pages come in. Unstamped, chat_switch.stream counted
// a 47 px shift in every round past the 400-record page that no acpmux the pane talks to makes.
import { describe, expect, test } from "bun:test";
import { segmenter, type SegmentedEvent } from "../bench/replySegments";
import { replySegment, type EventRecord } from "../src/agent-session/acpmux/direct/records";

const chunk = (text: string): SegmentedEvent => ({
  dir: "in",
  kind: "agent_message_chunk",
  msg: {
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  },
});
const toolCall = (): SegmentedEvent => ({
  dir: "in",
  kind: "tool_call",
  msg: { method: "session/update", params: { sessionId: "agent-1", update: { sessionUpdate: "tool_call" } } },
});
const usage = (): SegmentedEvent => ({
  dir: "in",
  kind: "usage_update",
  msg: { method: "session/update", params: { sessionId: "agent-1", update: { sessionUpdate: "usage_update" } } },
});
const prompt = (): SegmentedEvent => ({ dir: "mux", kind: "user_message", msg: { text: "Question" } });
const segmentOf = (event: SegmentedEvent) => replySegment({ seq: 1, at: 0, ...event } as EventRecord);

describe("bench reply segments", () => {
  test("every chunk of one reply carries the segment the pane names its row by", () => {
    const stamp = segmenter();
    const events = [prompt(), chunk("The checks "), usage(), chunk("are green.")];
    for (const event of events) stamp(event);
    const [first, second] = [segmentOf(events[1]!), segmentOf(events[3]!)];
    expect(first).toBeString();
    expect(second).toBe(first!);
  });

  test("a tool call cuts the reply and a new turn starts again", () => {
    const stamp = segmenter();
    const events = [prompt(), chunk("Before "), toolCall(), chunk("after."), prompt(), chunk("Next turn.")];
    for (const event of events) stamp(event);
    const segments = [segmentOf(events[1]!), segmentOf(events[3]!), segmentOf(events[5]!)];
    expect(new Set(segments).size).toBe(3);
  });

  test("records that are not reply chunks carry no segment", () => {
    const stamp = segmenter();
    const events = [prompt(), toolCall(), usage()];
    for (const event of events) stamp(event);
    expect(events.map(segmentOf)).toEqual([undefined, undefined, undefined]);
  });
});
