// New side chat and `/side` on a chat whose folder is on another machine (a Cloud or SSH chat):
// that machine opens the side chat in the chat's folder there (`sideChatOnMachine`), as this
// Mac's acpmux does for a local chat ("whatever works on a local chat should work on a Cloud
// chat", cmuxterm-hq#7856).
import { expect, test } from "bun:test";
import { sideChatPlace, sideChatRefusal, sideChatRow } from "../src/agent-session/acpmux/header/sideChatRow";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const finished = [{ kind: "turnSummary", seq: 4 }];
const snapshot = (over: Partial<AcpmuxSnapshot>): AcpmuxSnapshot =>
  ({ connection: "connected", isWorking: false, rows: finished, ...over }) as unknown as AcpmuxSnapshot;

test("a chat on another machine forks there when its machine opens side chats", () => {
  expect(sideChatPlace({ quick: false, localCwd: "/Users/me/api", onMachine: undefined })).toBe("local");
  expect(sideChatPlace({ quick: false, localCwd: undefined, onMachine: true })).toBe("machine");
  // A Cloud chat's summary names its folder there without a host: its machine still forks it.
  expect(sideChatPlace({ quick: false, localCwd: "/root/api", onMachine: true })).toBe("machine");
  // A machine whose cmux predates side chats there offers none, as before.
  expect(sideChatPlace({ quick: false, localCwd: undefined, onMachine: undefined })).toBeUndefined();
  // Quick Chat's panel has no split beside it.
  expect(sideChatPlace({ quick: true, localCwd: "/Users/me/api", onMachine: true })).toBeUndefined();
});

test("a Cloud chat's side chat needs its machine connected and a turn to copy", () => {
  // The page's own fork stays off on a Cloud chat (`canFork` unset); its machine forks instead.
  expect(sideChatRefusal(snapshot({ sideChatOnMachine: true }), "machine")).toBeUndefined();
  expect(sideChatRefusal(snapshot({ sideChatOnMachine: true, isWorking: true, rows: [] }), "machine")).toBeUndefined();
  expect(sideChatRefusal(snapshot({ sideChatOnMachine: true, rows: [] }), "machine")).toBe("nothingYet");
  expect(sideChatRefusal(snapshot({ connection: "disconnected" }), "machine")).toBe("unavailable");
  expect(sideChatRefusal(snapshot({ connection: "connecting (2)" }), "machine")).toBe("unavailable");
  expect(sideChatRefusal(snapshot({}), undefined)).toBe("unavailable");
  // A local chat keeps the fork's own rule: no `canFork`, no side chat.
  expect(sideChatRefusal(snapshot({}), "local")).toBe("unavailable");
  expect(sideChatRefusal(snapshot({ canFork: true }), "local")).toBeUndefined();
});

test("the chat menu offers New side chat on a Cloud chat", () => {
  const opened: number[] = [];
  const row = sideChatRow({ canFork: true, throughSeq: 4, place: "machine" }, (seq) => opened.push(seq));
  expect(row?.key).toBe("sideChat");
  if (row && "onSelect" in row) row.onSelect?.();
  expect(opened).toEqual([4]);
  expect(sideChatRow({ canFork: true, throughSeq: 4, place: undefined }, () => {})).toBeUndefined();
});
