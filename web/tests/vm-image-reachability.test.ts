import { describe, expect, test } from "bun:test";
import { reachabilityKey } from "../scripts/check-devbox-image-reachable";

describe("devbox reachability run key", () => {
  const defaults = [
    { version: "base-sm", imageId: "sh-aaa" },
    { version: "base-md", imageId: "sh-bbb" },
  ];

  test("the same images and client repeat a key, so CI can skip the run", () => {
    expect(reachabilityKey(defaults, "client-1")).toBe(reachabilityKey(defaults, "client-1"));
  });

  test("order of the defaults does not change the key", () => {
    expect(reachabilityKey([...defaults].reverse(), "client-1")).toBe(reachabilityKey(defaults, "client-1"));
  });

  test("a promoted image is a new pair to test", () => {
    const promoted = [{ version: "base-sm", imageId: "sh-ccc" }, defaults[1]!];
    expect(reachabilityKey(promoted, "client-1")).not.toBe(reachabilityKey(defaults, "client-1"));
  });

  test("a new cmux-tui release is a new pair to test", () => {
    // This is the case with no commit behind it: files.cmux.com moves and the
    // manifest does not, which is exactly what the daily run is for.
    expect(reachabilityKey(defaults, "client-2")).not.toBe(reachabilityKey(defaults, "client-1"));
  });
});
