// l10n-allow-file: test fixture thoughts, not shipped UI.
// A finished thought draws as Claude Desktop and Codex draw it (Leo 2026-10-20): consecutive thoughts
// in one step are one, and a thought with nothing to read (empty, as Claude's omitted or redacted
// thinking arrives, or a short one done in under a second) draws no row, nor does a step that held
// only such thoughts.
import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { QUIET_THOUGHT_CHARS, isQuietThought, mergeThoughts, withoutQuietThoughts } from "./thoughts";

const thought = (text: string, startedAt?: number, endedAt?: number): AcpmuxActivity => ({
  kind: "thought",
  text,
  ...(startedAt !== undefined && { startedAt, endedAt }),
});
const call: AcpmuxActivity = {
  kind: "tool",
  text: "Read",
  tool: { id: "t1", title: "Read", kind: "read", status: "completed" },
};
const step = (id: string, items: AcpmuxActivity[], fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 1,
  kind: "activity",
  items,
  ...fields,
});
const reply: AcpmuxRow = { id: "reply", version: 1, at: 2, kind: "assistant", text: "Done." };
const LONG = "Check how the helper parses errors before changing the retry.";

test("a thought is quiet when empty, blank, or short and quick or undated", () => {
  expect(isQuietThought(thought(""))).toBe(true);
  expect(isQuietThought(thought(" \n\t "))).toBe(true);
  expect(isQuietThought(thought("I am here", 0, 400))).toBe(true);
  expect(isQuietThought(thought("I am here"))).toBe(true);
  // Seconds of thinking, or a line long enough to read, still draw.
  expect(isQuietThought(thought("I am here", 0, 1_000))).toBe(false);
  expect(isQuietThought(thought("x".repeat(QUIET_THOUGHT_CHARS)))).toBe(false);
  expect(isQuietThought(thought(LONG, 0, 0))).toBe(false);
});

test("consecutive thoughts merge a blank line apart, for the sum of their durations", () => {
  expect(mergeThoughts([thought("one ", 1_000, 3_000), thought("two", 10_000, 14_000), call])).toEqual([
    { kind: "thought", text: "one\n\ntwo", startedAt: 1_000, endedAt: 7_000 },
    call,
  ]);
  // Undated thoughts merge undated; a list with no two thoughts side by side is returned as it is.
  expect(mergeThoughts([thought("one"), thought("two")])).toEqual([{ kind: "thought", text: "one\n\ntwo" }]);
  const apart = [thought("one"), call, thought("two")];
  expect(mergeThoughts(apart)).toBe(apart);
});

test("drops quiet thoughts, and a step that held only them, keeping each unchanged row", () => {
  const kept = step("a", [thought(LONG, 0, 5_000), call]);
  const quiet = step("b", [thought("Hmm.", 0, 200)]);
  const mixed = step("c", [thought("", 0, 0), call]);
  const rows = [kept, quiet, mixed, reply];
  const out = withoutQuietThoughts(rows);
  expect(out.map((row) => row.id)).toEqual(["a", "c", "reply"]);
  expect(out[0]).toBe(kept);
  expect(out[1]!.items).toEqual([call]);
  // The changed row draws again: its version is one no row reaches by itself.
  expect(out[1]!.version).not.toBe(mixed.version);
  // The same rows shape to the same objects, so turnViewFrom reuses its turns.
  expect(withoutQuietThoughts(rows)[1]).toBe(out[1]);
  const plain = [kept, reply];
  expect(withoutQuietThoughts(plain)).toBe(plain);
});

test("short quick thoughts side by side are judged merged: together they took over a second", () => {
  const out = withoutQuietThoughts([step("a", [thought("Read the helper", 0, 600), thought("then the loop", 0, 600)])]);
  expect(out[0]!.items).toEqual([
    { kind: "thought", text: "Read the helper\n\nthen the loop", startedAt: 0, endedAt: 1_200 },
  ]);
});

test("keeps a thought that may still stream: the last one of a working chat or a live row", () => {
  const streaming = step("a", [call, thought("Hm", 0, 0)]);
  expect(withoutQuietThoughts([streaming], true)[0]!.items).toEqual(streaming.items);
  expect(withoutQuietThoughts([step("a", [call, thought("Hm", 0, 0)], { live: true }), reply])[0]!.items).toHaveLength(
    2,
  );
  // Once the chat stops, it goes, and the row draws again.
  const done = withoutQuietThoughts([streaming], false);
  expect(done[0]!.items).toEqual([call]);
  expect(done[0]!.version).not.toBe(withoutQuietThoughts([streaming], true)[0]!.version);
});
