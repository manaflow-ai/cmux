// The settled view an attach answers with (acpmux `settled-attach-v1`, cmuxterm-hq#9655 stage 1).
import { describe, expect, test } from "bun:test";
import { settledAppend, settledView } from "./direct";

const record = (seq: number) => ({ sessionId: "s", seq, at: 0, dir: "in", kind: "agent_message_chunk", msg: {} });

describe("settledView", () => {
  test("a plain attach reply names none", () => {
    expect(settledView({ events: [] })).toBeUndefined();
    expect(settledView({ settled: null })).toBeUndefined();
    expect(settledView({ settled: { schema: 1 } })).toBeUndefined();
  });
  test("a settled reply names its frame end and its fork points", () => {
    expect(settledView({ settled: { schema: 1, lastSeq: 40, forkSeqs: [12, 40, "x"] } })).toEqual({
      lastSeq: 40,
      forkSeqs: [12, 40],
    });
    expect(settledView({ settled: { schema: 1, lastSeq: 40 } })).toEqual({ lastSeq: 40, forkSeqs: [] });
  });
});

describe("settledAppend", () => {
  const view = { lastSeq: 30, forkSeqs: [] };
  test("a page that meets the drawn rows adds only what comes after them, in order", () => {
    const page = [record(32), record(20), record(31), record(25)];
    expect(settledAppend(page, 30, view)?.map((event) => event.seq)).toEqual([31, 32]);
  });
  test("a page that starts right after the drawn rows meets them", () => {
    expect(settledAppend([record(31), record(32)], 30, view)?.map((event) => event.seq)).toEqual([31, 32]);
  });
  test("a page past a gap, nothing drawn, or no view: the page is laid in as before", () => {
    expect(settledAppend([record(40)], 30, view)).toBeUndefined();
    expect(settledAppend([record(1)], 0, view)).toBeUndefined();
    expect(settledAppend([record(31)], 30, undefined)).toBeUndefined();
    expect(settledAppend([], 30, view)).toBeUndefined();
  });
});
