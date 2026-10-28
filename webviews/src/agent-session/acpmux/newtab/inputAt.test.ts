import { expect, test } from "bun:test";
import { inputAt, jumpParams } from "./inputAt";

test("an input's time is the page's time origin plus the event's own time stamp", () => {
  expect(inputAt({ timeStamp: 250.5 }, 1_700_000_000_000)).toBe(1_700_000_000_250.5);
});

test("a jump carries the input that picked it, and none without one", () => {
  expect(jumpParams("tab", "t1", 1_700_000_000_250)).toEqual({ target: "tab", id: "t1", inputAt: 1_700_000_000_250 });
  expect(jumpParams("workspace", "w1")).toEqual({ target: "workspace", id: "w1" });
});
