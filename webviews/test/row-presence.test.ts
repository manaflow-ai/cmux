import { expect, test } from "bun:test";
import { rowPresence } from "../src/agent-session/acpmux/conversation/rowPresence";

const rows = (ids: string[]) => ids.map((id) => ({ id }));

test("finds focused ids in one reverse walk and stops at the live tail", () => {
  let reads = 0;
  const source = rows(["old", "middle", "active", "anchor", "focus"]).map((row) => ({
    get id() {
      reads += 1;
      return row.id;
    },
  }));

  expect(rowPresence(source, "active", "anchor", "focus")).toEqual({ active: true, anchor: true, focus: true });
  expect(reads).toBe(3);
});

test("marks removed focus and selection endpoints missing", () => {
  expect(rowPresence(rows(["one", "two"]), "gone", "one", "missing")).toEqual({
    active: false,
    anchor: true,
    focus: false,
  });
});

test("does not walk when no focused ids need validation", () => {
  let reads = 0;
  const source = rows(["one", "two"]).map((row) => ({
    get id() {
      reads += 1;
      return row.id;
    },
  }));
  expect(rowPresence(source, undefined, undefined, undefined)).toEqual({ active: true, anchor: true, focus: true });
  expect(reads).toBe(0);
});
