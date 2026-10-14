// The location strip cuts a folder's name in the middle (design panel, compact composer: "atla…"
// told the reader nothing): splitForMiddleTruncation keeps the name's end whole, and leaves a short
// name alone.
import { describe, expect, test } from "bun:test";
import { splitForMiddleTruncation } from "./ComposerContext";

describe("splitForMiddleTruncation", () => {
  test("a short name is not split", () => {
    expect(splitForMiddleTruncation("relay")).toEqual(["relay", ""]);
    expect(splitForMiddleTruncation("cmuxer")).toEqual(["cmuxer", ""]);
  });
  test("at 7 characters the tail is 3, the least that still reads", () => {
    expect(splitForMiddleTruncation("dotfile")).toEqual(["dotf", "ile"]);
    expect(splitForMiddleTruncation("atlas-web")).toEqual(["atlas-", "web"]);
  });
  test("a long name keeps a third of itself, at most 6 characters", () => {
    expect(splitForMiddleTruncation("cmux-cgc-location-strip")).toEqual(["cmux-cgc-location", "-strip"]);
    expect(splitForMiddleTruncation("abcdefghijklmn")).toEqual(["abcdefghij", "klmn"]);
  });
  test("characters outside the BMP are never cut in half", () => {
    const [head, tail] = splitForMiddleTruncation("proj-🚀🚀🚀");
    expect(head + tail).toBe("proj-🚀🚀🚀");
    expect(tail).toBe("🚀🚀🚀");
  });
});
