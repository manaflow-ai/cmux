// "N new messages" (Leo, 2026-11-15: "we needto properly do somthing like this in the gui somehow",
// of the terminal chat's rule): the count after the line, its fade once seen, and the line a scroll up
// places (conversation/unreadState.ts, direct.ts `placeScrolledSince`; design/transcript-overlays.md).
import { afterEach, beforeEach, expect, test } from "bun:test";
import {
  SINCE_COUNT_CAP,
  countNewMessages,
  noteUnreadCount,
  noteUnreadMounted,
  noteUnreadSide,
  readUnread,
  resetUnreadForTest,
  SINCE_FADE_MS,
  setSinceTimersForTest,
  unreadRead,
} from "./conversation/unreadState";
import { SINCE_DIVIDER } from "./model";

/// The fade's timers, fired by hand: what each was armed for, and whether it is still armed.
let armed: { fn: () => void; ms: number; live: boolean }[] = [];
beforeEach(() => {
  armed = [];
  setSinceTimersForTest({
    set: (fn, ms) => {
      const timer = { fn, ms, live: true };
      armed.push(timer);
      return timer;
    },
    clear: (timer) => void ((timer as { live: boolean }).live = false),
  });
  resetUnreadForTest();
});
afterEach(() => setSinceTimersForTest());
const fire = () => {
  for (const timer of armed.splice(0)) if (timer.live) timer.fn();
};

const rows = (...kinds: string[]) =>
  kinds.map((kind, index) => ({ id: kind === SINCE_DIVIDER ? kind : `r${index}`, kind }));

test("the count is the replies, tool runs and messages after the line; status rows never count", () => {
  expect(
    countNewMessages(
      rows("user", "assistant", SINCE_DIVIDER, "activity", "assistant", "turnSummary", "notice", "user", "recap"),
      SINCE_DIVIDER,
    ),
  ).toBe(4);
  // Straight after the person's own message, nothing new yet.
  expect(countNewMessages(rows("user", SINCE_DIVIDER), SINCE_DIVIDER)).toBe(0);
  // No line in the rows: no count.
  expect(countNewMessages(rows("user", "assistant"), SINCE_DIVIDER)).toBeUndefined();
});

test("counting stops past the cap, however many rows came", () => {
  const many = rows(SINCE_DIVIDER, ...Array.from({ length: 5_000 }, () => "assistant"));
  expect(countNewMessages(many, SINCE_DIVIDER)).toBe(SINCE_COUNT_CAP + 1);
  // A day of status rows after the line reads a bounded stretch too, not every row.
  const quiet = rows(SINCE_DIVIDER, "assistant", ...Array.from({ length: 20_000 }, () => "notice"));
  expect(countNewMessages(quiet, SINCE_DIVIDER)).toBe(SINCE_COUNT_CAP + 1);
  expect(countNewMessages(rows(SINCE_DIVIDER, "assistant", "notice", "notice"), SINCE_DIVIDER)).toBe(1);
});

test("the count follows new rows while the line is unread and freezes once it is read", () => {
  noteUnreadMounted("s:7");
  noteUnreadCount("s:7", 3);
  expect(readUnread()?.count).toBe(3);
  noteUnreadCount("s:7", 157);
  expect(readUnread()?.count).toBe(157);
  // Seen, then scrolled past: read at once, and the fading label keeps its words.
  noteUnreadSide("s:7", "in");
  noteUnreadSide("s:7", "above");
  expect(unreadRead("s:7", readUnread())).toBe(true);
  noteUnreadCount("s:7", 158);
  expect(readUnread()?.count).toBe(157);
});

test("a line on screen fades a moment later; one never seen stays", () => {
  noteUnreadMounted("s:7");
  noteUnreadSide("s:7", "below");
  expect(armed).toHaveLength(0);
  noteUnreadSide("s:7", "in");
  // On and off screen while it waits: one timer, not one per crossing.
  noteUnreadSide("s:7", "below");
  noteUnreadSide("s:7", "in");
  expect(armed.map((timer) => timer.ms)).toEqual([SINCE_FADE_MS]);
  expect(unreadRead("s:7", readUnread())).toBe(false);
  fire();
  expect(unreadRead("s:7", readUnread())).toBe(true);
});

test("a later mark starts its own fade; the old mark's timer never reads the new line", () => {
  noteUnreadMounted("s:7");
  noteUnreadSide("s:7", "in");
  noteUnreadMounted("s:9");
  noteUnreadSide("s:9", "below");
  fire();
  expect(readUnread()?.mark).toBe("s:9");
  expect(unreadRead("s:9", readUnread())).toBe(false);
});
