import { expect, test } from "bun:test";
import { archiveRow } from "./archiveRow";

test("Archive tags the chat, Unarchive takes the tag off; only a chat on this Mac offers either", () => {
  const calls: unknown[] = [];
  const archive = (archived: boolean) => calls.push(archived);
  const row = archiveRow({ sessionId: "s", archived: false, local: true }, archive);
  expect(row).toMatchObject({ key: "archive", label: "Archive", icon: "inbox" });
  row?.onSelect?.();
  const undo = archiveRow({ sessionId: "s", archived: true, local: true }, archive);
  expect(undo).toMatchObject({ key: "archive", label: "Unarchive" });
  undo?.onSelect?.();
  expect(calls).toEqual([true, false]);
  expect(archiveRow({ sessionId: undefined, archived: false, local: true }, archive)).toBeUndefined();
  expect(archiveRow({ sessionId: "s", archived: false, local: false }, archive)).toBeUndefined();
});
