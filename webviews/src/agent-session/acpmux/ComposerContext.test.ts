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
  test("the tail is the name's last word when it reads whole (3 to 10 characters)", () => {
    expect(splitForMiddleTruncation("cmux-cgc-location-strip")).toEqual(["cmux-cgc-location-", "strip"]);
    expect(splitForMiddleTruncation("atlas-web-checkout-service")).toEqual(["atlas-web-checkout-", "service"]);
    expect(splitForMiddleTruncation("my_project.backend")).toEqual(["my_project.", "backend"]);
    expect(splitForMiddleTruncation("v2 rewrite")).toEqual(["v2 ", "rewrite"]);
  });
  test("a last word too short or too long falls back to a third of the name, 3 to 6 characters", () => {
    expect(splitForMiddleTruncation("abcdefghijklmn")).toEqual(["abcdefghij", "klmn"]);
    expect(splitForMiddleTruncation("atlas-web-x")).toEqual(["atlas-we", "b-x"]);
    expect(splitForMiddleTruncation("app-infrastructureservice")).toEqual(["app-infrastructures", "ervice"]);
    expect(splitForMiddleTruncation("-leadingdash")).toEqual(["-leading", "dash"]);
  });
  test("characters outside the BMP are never cut in half", () => {
    const [head, tail] = splitForMiddleTruncation("proj-🚀🚀🚀");
    expect(head + tail).toBe("proj-🚀🚀🚀");
    expect(tail).toBe("🚀🚀🚀");
  });
});
