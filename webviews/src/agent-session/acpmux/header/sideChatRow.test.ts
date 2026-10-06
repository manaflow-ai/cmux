import { expect, test } from "bun:test";
import { sideChatRow } from "./sideChatRow";

test("New side chat forks through the last turn; it needs a turn, a fork and this Mac", () => {
  const opened: number[] = [];
  const row = sideChatRow({ canFork: true, throughSeq: 12, local: true }, (seq) => opened.push(seq));
  expect(row).toMatchObject({ key: "sideChat", label: "New side chat", icon: "agent.chat.new" });
  row?.onSelect?.();
  expect(opened).toEqual([12]);
  expect(sideChatRow({ canFork: true, throughSeq: undefined, local: true }, () => {})).toBeUndefined();
  expect(sideChatRow({ canFork: false, throughSeq: 12, local: true }, () => {})).toBeUndefined();
  expect(sideChatRow({ canFork: true, throughSeq: 12, local: false }, () => {})).toBeUndefined();
});
