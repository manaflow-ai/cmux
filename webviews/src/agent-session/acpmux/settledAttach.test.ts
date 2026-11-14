// The settled view an attach answers with (acpmux `settled-attach-v1`, cmuxterm-hq#9655 stage 1).
import { describe, expect, test } from "bun:test";
import { settledAppend, settledAttachFailed, settledView } from "./direct";

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
    expect(settledAppend(page, 30, 30, view)?.map((event) => event.seq)).toEqual([31, 32]);
  });
  test("a page that starts right after the drawn rows meets them", () => {
    expect(settledAppend([record(31), record(32)], 30, 30, view)?.map((event) => event.seq)).toEqual([31, 32]);
  });
  test("a page past a gap, nothing drawn, or no view: the page is laid in as before", () => {
    expect(settledAppend([record(40)], 30, 30, view)).toBeUndefined();
    expect(settledAppend([record(1)], 0, 0, view)).toBeUndefined();
    expect(settledAppend([record(31)], 30, 30, undefined)).toBeUndefined();
    expect(settledAppend([], 30, 30, view)).toBeUndefined();
  });
  // A cold open after a restart of a chat whose turn still streams: live records land while the
  // attach is out, past the rows drawn before it. Measured from them, the page records between the
  // rows and the live turn would be left out (a hole), or, with nothing drawn, the whole page.
  test("a live record applied past the drawn rows while the attach was out: the page is merged", () => {
    const page = [record(28), record(29), record(30), record(31), record(32), record(33)];
    // A kept tail through 30, live records 40.. already applied.
    expect(settledAppend(page, 30, 40, view)).toBeUndefined();
    // No kept tail: only live records are held.
    expect(settledAppend(page, 0, 40, view)).toBeUndefined();
  });
  test("a page with nothing past the drawn rows is no match: the page is merged", () => {
    expect(settledAppend([record(29), record(30)], 30, 30, view)).toBeUndefined();
  });
  test("drawn rows not held any more: the page is merged", () => {
    expect(settledAppend([record(31)], 30, 0, view)).toBeUndefined();
  });
  test("a copy that covers past its newest record: the page goes on from the copy's end", () => {
    expect(settledAppend([record(31), record(32)], 30, 27, view)?.map((event) => event.seq)).toEqual([31, 32]);
  });
});

describe("settledAttachFailed", () => {
  test("a failure that names the settled view is retried plain", () => {
    expect(settledAttachFailed(new Error("settled view unreadable"))).toBe(true);
    expect(settledAttachFailed({ message: "attach failed", code: "settled.unreadable" })).toBe(true);
    expect(settledAttachFailed({ message: "attach failed", reason: "settled_view_corrupt" })).toBe(true);
    expect(settledAttachFailed({ message: "attach failed", reason: "settled view corrupt" })).toBe(true);
  });
  // A host whose params rule does not know `settled` refuses the whole attach as malformed
  // (cmux#42185): the chat must still open from the plain attach.
  test("a host that refuses the settled ask as malformed is retried plain", () => {
    expect(settledAttachFailed({ message: "Refused by the cmux host", code: "transport.intent_invalid" })).toBe(true);
  });
  test("any other failure is not", () => {
    expect(settledAttachFailed(new Error("session not found"))).toBe(false);
    expect(settledAttachFailed(undefined)).toBe(false);
    expect(settledAttachFailed("settled")).toBe(false);
  });
});
