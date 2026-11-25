// "N new messages" (Leo, 2026-11-15: "we needto properly do somthing like this in the gui somehow",
// of the terminal chat's rule): the count under the line, what it counts, its bound, and that it
// freezes once the line is read (conversation/sinceNews.ts `sinceCount`, conversation/unreadState.ts
// `noteUnreadCount`; design/transcript-overlays.md).
import { beforeEach, expect, test } from "bun:test";
import { SINCE_COUNT_CAP, sinceCount } from "./conversation/sinceNews";
import {
  dissipateUnread,
  noteUnreadCount,
  noteUnreadMounted,
  noteUnreadSide,
  readUnread,
  resetUnreadForTest,
} from "./conversation/unreadState";
import { MESSAGE_RUN, SINCE_DIVIDER, type AcpmuxRow } from "./model";
import { SUBAGENT_STARTED } from "./subagents/subagentRows";

beforeEach(() => resetUnreadForTest());

let next = 0;
const row = (kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: kind === SINCE_DIVIDER ? SINCE_DIVIDER : `r${next++}`,
  version: 1,
  at: 0,
  kind,
  ...(kind === SINCE_DIVIDER && { since: { key: "s:7", seq: 7, turns: 1 } }),
  ...fields,
});
const reply = (text = "Done.") => row("assistant", { text });
const line = () => row(SINCE_DIVIDER);

test("the count is the news under the line: replies and messages, never status, tool runs or own prompts", () => {
  const rows = [
    row("user", { text: "go" }),
    reply(),
    line(),
    row("activity"),
    reply("Case 1 passes."),
    row(SUBAGENT_STARTED),
    row("turnSummary"),
    row("user", { text: "and the next one" }),
    reply(""),
    row("user", { text: "from another agent", incoming: { kind: "message" } as AcpmuxRow["incoming"] }),
    reply("Case 2 passes."),
  ];
  expect(sinceCount(rows, 2)).toBe(3);
  // A "Received 4 messages" run counts its four.
  expect(sinceCount([line(), row(MESSAGE_RUN, { messageRun: { received: 4 } as AcpmuxRow["messageRun"] })], 0)).toBe(4);
  // Nothing new yet, and an index that is not the line.
  expect(sinceCount([reply(), line()], 1)).toBe(0);
  expect(sinceCount([reply(), line()], 0)).toBeUndefined();
});

test("counting is bounded: past the cap it reads 999+, and a long run of status claims no number", () => {
  const many = [line(), ...Array.from({ length: 5_000 }, () => reply())];
  expect(sinceCount(many, 0)).toBe(SINCE_COUNT_CAP + 1);
  // A day of tool runs after one reply reads a bounded stretch from the end, not every row, and
  // answers no number it did not count (the label reads "New").
  const quiet = [line(), reply(), ...Array.from({ length: 20_000 }, () => row("activity"))];
  expect(sinceCount(quiet, 0)).toBeUndefined();
  expect(sinceCount([line(), reply(), row("activity"), row("activity")], 0)).toBe(1);
});

test("the count follows new rows while the line is unread and freezes once it is read", () => {
  noteUnreadMounted("s:7");
  noteUnreadCount("s:7", 3);
  expect(readUnread()?.count).toBe(3);
  noteUnreadCount("s:7", 157);
  expect(readUnread()?.count).toBe(157);
  // Not counted (past the reach): the last count stands.
  noteUnreadCount("s:7", undefined);
  expect(readUnread()?.count).toBe(157);
  // On screen, then dissipated: the fading label keeps its words.
  noteUnreadSide("s:7", "in");
  dissipateUnread("s:7");
  noteUnreadCount("s:7", 158);
  expect(readUnread()?.count).toBe(157);
});

test("a later mark starts its own count", () => {
  noteUnreadMounted("s:7");
  noteUnreadCount("s:7", 12);
  noteUnreadMounted("s:9");
  expect(readUnread()?.mark).toBe("s:9");
  expect(readUnread()?.count).toBeUndefined();
});
