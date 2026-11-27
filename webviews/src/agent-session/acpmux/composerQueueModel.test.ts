import { describe, expect, test } from "bun:test";
import { heldReason } from "./composerQueueModel";

describe("heldReason", () => {
  test("a held prompt waits on the person (trust) or on nothing they can do (wait)", () => {
    expect(heldReason({ held: true })).toBe("trust");
    expect(heldReason({ held: true, waking: true })).toBe("wait");
  });
  test("a prompt that is not held has no reason", () => {
    expect(heldReason({})).toBeUndefined();
    expect(heldReason({ waking: true })).toBeUndefined();
  });
});

import { uniqueById } from "./composerQueueModel";

describe("uniqueById", () => {
  test("a prompt listed twice draws once, at its first place", () => {
    const list = [{ id: "a" }, { id: "b" }, { id: "a" }, { id: "c" }, { id: "b" }];
    expect(uniqueById(list).map((entry) => entry.id)).toEqual(["a", "b", "c"]);
  });
});
