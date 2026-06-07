import { describe, expect, test } from "bun:test";
import { normalizeDraftInput } from "../services/typefully/workflows";

describe("Typefully draft workflow helpers", () => {
  test("normalizes empty draft input into a persisted shape", () => {
    expect(normalizeDraftInput({ title: "   ", thread: [] })).toEqual({
      title: "Untitled draft",
      thread: [""],
    });
  });

  test("keeps the first empty post and drops later empty posts", () => {
    expect(normalizeDraftInput({
      title: " Launch notes ",
      thread: ["", "  ", "Ship it\n\n"],
    })).toEqual({
      title: "Launch notes",
      thread: ["", "Ship it"],
    });
  });

  test("caps drafts to the persisted limits", () => {
    const normalized = normalizeDraftInput({
      title: "x".repeat(240),
      thread: Array.from({ length: 60 }, (_, index) => `post ${index}`),
    });
    expect(normalized.title).toHaveLength(180);
    expect(normalized.thread).toHaveLength(50);
  });
});
