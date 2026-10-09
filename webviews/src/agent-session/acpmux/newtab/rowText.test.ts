import { expect, test } from "bun:test";
import { compactUrl, matchRanges } from "./rowText";

test("matchRanges finds every query word, case-insensitive, merged and in order", () => {
  expect(matchRanges("Release notes", "rel")).toEqual([[0, 3]]);
  expect(matchRanges("release build", "BUILD rel")).toEqual([
    [0, 3],
    [8, 13],
  ]);
  expect(matchRanges("aaa", "aa a")).toEqual([[0, 3]]);
  expect(matchRanges("Release", "")).toEqual([]);
  expect(matchRanges("Release", "zz")).toEqual([]);
});

test("compactUrl drops the scheme and www, and keeps the host and the last segment when long", () => {
  expect(compactUrl("https://www.cmux.dev/docs")).toBe("cmux.dev/docs");
  expect(compactUrl("https://github.com/manaflow-ai/cmux/pull/18729/files?diff=split", 40)).toBe(
    "github.com/…/files?diff=split",
  );
  const long = compactUrl("https://example.com/" + "a".repeat(80), 30);
  expect(long.length).toBeLessThanOrEqual(30);
  expect(long.startsWith("example.com/")).toBe(true);
});
