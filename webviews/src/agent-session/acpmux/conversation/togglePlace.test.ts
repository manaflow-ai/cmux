import { describe, expect, test } from "bun:test";

import type { AcpmuxRow } from "../model";
import { togglePlace, togglePromptRow } from "./togglePlace";

const row = (id: string, kind: string, text = ""): AcpmuxRow => ({ id, version: 1, at: 0, kind, text });

const rows = [
  row("r0", "status", "Resumed"),
  row("u1", "user", "fix the login bug"),
  row("a1", "assistant", "The bug is in auth.rs."),
  row("t1", "tool", ""),
  row("u2", "user", "now add a test"),
  row("a2", "assistant", "Added."),
  row("u3", "user", "   "),
  row("u4", "user", "fix the login bug"),
  row("a4", "assistant", "Done."),
];

describe("Toggle Terminal and Chat's place (the same turn in the other view)", () => {
  test("names every prompt with words, oldest first", () => {
    expect(togglePlace(rows, null).prompts).toEqual(["fix the login bug", "now add a test", "fix the login bug"]);
  });

  test("the turn in view is the prompt at or above the transcript's resting row", () => {
    expect(togglePlace(rows, { rowId: "u1" }).at).toBe(0);
    expect(togglePlace(rows, { rowId: "t1" }).at).toBe(0);
    expect(togglePlace(rows, { rowId: "a2" }).at).toBe(1);
    // A row with no words of its own is no prompt: its place is the turn before it.
    expect(togglePlace(rows, { rowId: "u3" }).at).toBe(1);
    expect(togglePlace(rows, { rowId: "a4" }).at).toBe(2);
    // The fold's copy of a row is the same row to a reader.
    expect(togglePlace(rows, { rowId: "a2:fold" }).at).toBe(1);
    // Above the first prompt: the first turn.
    expect(togglePlace(rows, { rowId: "r0" }).at).toBe(0);
  });

  test("following the latest message, or resting on a row the chat lacks, is the latest turn", () => {
    expect(togglePlace(rows, null).at).toBeNull();
    expect(togglePlace(rows, undefined).at).toBeNull();
    expect(togglePlace(rows, { rowId: "gone" }).at).toBeNull();
    expect(togglePlace([row("a", "assistant", "hi")], { rowId: "a" })).toEqual({ prompts: [], at: null });
  });

  test("a prompt's index leads back to its row", () => {
    expect(togglePromptRow(rows, 0)).toBe("u1");
    expect(togglePromptRow(rows, 1)).toBe("u2");
    // The repeated words are the later turn's own row.
    expect(togglePromptRow(rows, 2)).toBe("u4");
    expect(togglePromptRow(rows, 3)).toBeUndefined();
  });
});
