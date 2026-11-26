import { expect, test } from "bun:test";
import { adaptRow } from "./adapter";
import { heightKey } from "./heights";
import type { ChatRow } from "./wire";

const adapted = (text: string, edition?: number) => {
  const row: ChatRow = { id: 7, rev: 1, kind: "text", at: 1, open: false, est: 1, body: { text } };
  return adaptRow({ id: row.id, rev: row.rev, row }, new Map(), { sessionId: "chat" }, 1, edition)[0]!;
};

test("replacement text with the same id, revision and length gets a distinct measurement key", () => {
  const old = adapted("abcde", 1);
  const replacement = adapted("a\nb\nc", 2);
  const before = heightKey([{ ...old }], 0, "chat", "layout", 800)!;
  const after = heightKey([{ ...replacement }], 0, "chat", "layout", 800)!;
  expect(before).toBeDefined();
  expect(after).toBeDefined();
  expect(before.signature).toBe(after.signature);
  expect(before).not.toEqual(after);
  expect(before.edition).toBe(1);
  expect(after.edition).toBe(2);
});

test("rows without a known edition cannot read or write native measurements", () => {
  expect(heightKey([adapted("text")], 0, "chat", "layout", 800)).toBeUndefined();
});
