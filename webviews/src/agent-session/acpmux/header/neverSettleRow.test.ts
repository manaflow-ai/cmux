import { expect, test } from "bun:test";
import { neverSettleRow } from "./archiveRow";

const t = (key: string) => key;
const chat = { sessionId: "a", archived: false, local: true };

test("no Never Settle row while every Settle Chats setting is off (the default)", () => {
  expect(neverSettleRow(chat, { sessionId: "a", never: false, on: false }, () => undefined, t)).toBeUndefined();
  expect(neverSettleRow(chat, undefined, () => undefined, t)).toBeUndefined();
});

test("Never Settle while a setting is on; Allow Settling on a chat set to never, even with them off", () => {
  const picked: boolean[] = [];
  const row = neverSettleRow(chat, { sessionId: "a", never: false, on: true }, (never) => picked.push(never), t);
  expect(row?.label).toBe("settle.never");
  row?.onSelect?.();
  const back = neverSettleRow(chat, { sessionId: "a", never: true, on: false }, (never) => picked.push(never), t);
  expect(back?.label).toBe("settle.allow");
  back?.onSelect?.();
  expect(picked).toEqual([true, false]);
});

test("no row for another chat's answer, an archived chat or a chat on another computer", () => {
  const on = { sessionId: "a", never: false, on: true };
  expect(neverSettleRow({ ...chat, sessionId: "b" }, on, () => undefined, t)).toBeUndefined();
  expect(neverSettleRow({ ...chat, archived: true }, on, () => undefined, t)).toBeUndefined();
  expect(neverSettleRow({ ...chat, local: false }, on, () => undefined, t)).toBeUndefined();
});
