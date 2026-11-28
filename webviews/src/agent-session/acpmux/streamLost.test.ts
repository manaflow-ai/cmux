// acpmux names, on each event-stream record, the record its stream sent before it (`prev`, server
// `Conn::stream_prev`). A page that holds less lost records on the way and reads them from its cursor
// (`streamGap`), rather than drawing a hole until a reload (cmuxterm-hq#27887).
import { expect, test } from "bun:test";
import { streamLost } from "./direct";

test("a prev past what the page holds and heard is a hole", () => {
  expect(streamLost(12, 10, 10)).toBe(true);
  expect(streamLost(12, 10, 11)).toBe(true);
});

test("a prev the page holds, or heard while it held the record back, is no hole", () => {
  expect(streamLost(10, 10, 10)).toBe(false);
  expect(streamLost(9, 10, 10)).toBe(false);
  expect(streamLost(12, 10, 12)).toBe(false);
});

test("no prev, a new stream, or no page yet is no hole", () => {
  expect(streamLost(undefined, 10, 10)).toBe(false);
  expect(streamLost(0, 10, 10)).toBe(false);
  expect(streamLost("12", 10, 10)).toBe(false);
  expect(streamLost(12, 0, 0)).toBe(false);
});
