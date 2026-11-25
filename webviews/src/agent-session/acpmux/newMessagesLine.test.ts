// "N new messages" (Leo, 2026-11-15: "we needto properly do somthing like this in the gui somehow",
// of the terminal chat's rule): the count under the line, what it counts, its bound, and that it
// freezes once the line is read (conversation/sinceNews.ts `sinceCount`, conversation/unreadState.ts
// `noteUnreadCount`; design/transcript-overlays.md).
import { beforeEach, expect, test } from "bun:test";
import { SINCE_COUNT_CAP, SinceTurnHold, runningTurnFrom, sinceCount, sinceNews } from "./conversation/sinceNews";
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

// Leo, 2026-11-25: "i think the new messages thing may be redundant if there is an unfinished turn.
// like dont mark it as new if it's still going". A running turn's own rows are held back from the
// line (sinceNews.ts `SinceTurnHold`); its end lets them go only when the reader was scrolled away.
const summary = () => row("turnSummary");
const fromAgent = (text: string) => row("user", { text, incoming: { kind: "message" } as AcpmuxRow["incoming"] });

test("a streaming turn is not marked new: no news, no count under the line", () => {
  const hold = new SinceTurnHold();
  const rows = [
    reply("Earlier."),
    summary(),
    line(),
    row("user", { text: "go" }),
    reply("Working on it"),
    reply("More"),
  ];
  const held = hold.spans(rows, 2, "s:7", true, false);
  expect(sinceNews(rows, 2, held)).toBe(false);
  expect(sinceCount(rows, 2, undefined, held)).toBe(0);
  // Scrolled up or not, still going is not new.
  expect(sinceNews(rows, 2, hold.spans(rows, 2, "s:7", true, true))).toBe(false);
});

test("another agent's message mid-turn still counts", () => {
  const hold = new SinceTurnHold();
  const rows = [
    line(),
    row("user", { text: "go" }),
    reply("Working"),
    fromAgent("Heads up from lane B"),
    reply("More"),
  ];
  const held = hold.spans(rows, 0, "s:7", true, false);
  expect(sinceNews(rows, 0, held)).toBe(true);
  expect(sinceCount(rows, 0, undefined, held)).toBe(1);
});

test("a turn that finishes while the reader is scrolled up is marked new", () => {
  const hold = new SinceTurnHold();
  const rows = [line(), row("user", { text: "go" }), reply("Working"), reply("Done.")];
  hold.spans(rows, 0, "s:7", true, false);
  const ended = [...rows, summary()];
  const held = hold.spans(ended, 0, "s:7", false, false);
  expect(held).toHaveLength(0);
  expect(sinceNews(ended, 0, held)).toBe(true);
  expect(sinceCount(ended, 0, undefined, held)).toBe(2);
});

test("a turn that finishes while the reader is at the bottom is not marked new", () => {
  const hold = new SinceTurnHold();
  const rows = [line(), row("user", { text: "go" }), reply("Working"), reply("Done.")];
  hold.spans(rows, 0, "s:7", true, true);
  const ended = [...rows, summary()];
  const held = hold.spans(ended, 0, "s:7", false, true);
  expect(sinceNews(ended, 0, held)).toBe(false);
  expect(sinceCount(ended, 0, undefined, held)).toBe(0);
  // It stays read; a later turn finished while scrolled away is new on its own.
  const next = [...ended, row("user", { text: "next" }), reply("Next one.")];
  hold.spans(next, 0, "s:7", true, false);
  const nextEnded = [...next, summary()];
  const later = hold.spans(nextEnded, 0, "s:7", false, false);
  expect(sinceCount(nextEnded, 0, undefined, later)).toBe(1);
  // A new mark forgets what the old one held.
  expect(hold.spans(nextEnded, 0, "s:9", false, false)).toHaveLength(0);
});

// Leo, 2026-11-25: "idk why it even happened in the first place for new to appear at the bottom".
test("news that comes in while the reader is at the latest row is read: no line, no count", () => {
  const hold = new SinceTurnHold();
  const rows = [reply("Earlier."), summary(), line()];
  expect(hold.spans(rows, 2, "s:7", false, true)).toHaveLength(0);
  // Another agent writes, then a turn runs and ends, all with the reader pinned to the tail.
  const message = [...rows, fromAgent("Heads up from lane B")];
  expect(sinceNews(message, 2, hold.spans(message, 2, "s:7", false, true))).toBe(false);
  const turn = [...message, row("user", { text: "go" }), reply("Working"), fromAgent("Another one")];
  const mid = hold.spans(turn, 2, "s:7", true, true);
  expect(sinceNews(turn, 2, mid)).toBe(false);
  const ended = [...turn, reply("Done."), summary()];
  const held = hold.spans(ended, 2, "s:7", false, true);
  expect(sinceNews(ended, 2, held)).toBe(false);
  expect(sinceCount(ended, 2, undefined, held)).toBe(0);
  // Scrolled away, what comes in next is new, and only that.
  const away = [...ended, fromAgent("While you were up there")];
  const later = hold.spans(away, 2, "s:7", false, false);
  expect(sinceCount(away, 2, undefined, later)).toBe(1);
});

test("what was under the line when it was placed stays news when more comes in at the bottom", () => {
  const hold = new SinceTurnHold();
  const rows = [line(), fromAgent("Missed while away"), reply("Also missed")];
  hold.spans(rows, 0, "s:7", false, true);
  const more = [...rows, fromAgent("Seen as it came")];
  const held = hold.spans(more, 0, "s:7", false, true);
  expect(sinceCount(more, 0, undefined, held)).toBe(2);
});

test("the running turn starts after the last turn's end, never above the line", () => {
  expect(runningTurnFrom([reply(), summary(), line(), reply()], 2)).toBe(3);
  expect(runningTurnFrom([line(), reply(), summary(), row("user"), reply()], 0)).toBe(3);
  expect(runningTurnFrom([line(), reply(), reply()], 0)).toBe(1);
});
