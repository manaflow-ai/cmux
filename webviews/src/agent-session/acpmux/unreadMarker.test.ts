// The unread marker's state (conversation/unreadState.ts), the one jump control (jumpControl.ts)
// and the overlay zones (overlayLayout.ts): design/transcript-overlays.md.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { beforeEach, expect, test } from "bun:test";
import {
  markUnreadRead,
  noteUnreadMounted,
  noteUnreadSide,
  readUnread,
  resetUnreadForTest,
  sinceDone,
  unreadRead,
} from "./conversation/unreadState";
import { jumpControl, unreadAbove } from "./jumpControl";
import { TRANSCRIPT_OVERLAYS, ZONE_KIND } from "./overlayLayout";

beforeEach(() => resetUnreadForTest());

test("the unread jump stands while the line is above the view and not reached, and goes once it was seen", () => {
  // A chat opens at its latest message: a mark not reported yet is above.
  expect(unreadAbove("s:41", readUnread(), "expanded")).toBe(true);
  noteUnreadMounted("s:41");
  expect(unreadAbove("s:41", readUnread(), "expanded")).toBe(true);
  expect(unreadAbove("s:41", readUnread(), "collapsed")).toBe(true);
  // The unread setting off: never up.
  expect(unreadAbove("s:41", readUnread(), "off")).toBe(false);
  // Scrolled above the line, it is below the view: nothing to go up to.
  noteUnreadSide("s:41", "below");
  expect(unreadAbove("s:41", readUnread(), "expanded")).toBe(false);
  noteUnreadSide("s:41", "in");
  expect(unreadAbove("s:41", readUnread(), "expanded")).toBe(false);
  // Seen once, it stays done for this mark, above the view again or not.
  noteUnreadSide("s:41", "above");
  expect(unreadAbove("s:41", readUnread(), "expanded")).toBe(false);
});

test("Mark read ends the unread jump until the next return", () => {
  noteUnreadMounted("s:41");
  markUnreadRead("s:41");
  expect(unreadRead("s:41", readUnread())).toBe(true);
  expect(unreadAbove("s:41", readUnread(), "expanded")).toBe(false);
  // The next return is a new mark: up again, unread.
  noteUnreadMounted("s:57");
  expect(unreadAbove("s:57", readUnread(), "expanded")).toBe(true);
  expect(unreadRead("s:57", readUnread())).toBe(false);
});

test("a press, or the reader reaching the latest message, ends the unread jump (#40065)", () => {
  noteUnreadMounted("s:41");
  noteUnreadSide("s:41", "below");
  sinceDone("s:41");
  expect(unreadAbove("s:41", readUnread(), "expanded")).toBe(false);
  expect(readUnread()?.side).toBe("above");
  // Reaching the latest message by hand reads a line that was seen; one never seen stays unread.
  expect(unreadRead("s:41", readUnread())).toBe(false);
  noteUnreadSide("s:41", "in");
  sinceDone("s:41", true);
  expect(unreadRead("s:41", readUnread())).toBe(true);
});

const unread = (turns = 9, above = true) => ({
  mark: "s:41",
  turns,
  view: readUnread(),
  mode: "expanded" as const,
  above,
});

test("one control: up to unread turns above, else down to the latest message, else none", () => {
  noteUnreadMounted("s:41");
  // Back in a chat at its latest message, nine turns unread above: up, with the count.
  expect(jumpControl({ unread: unread(), behind: false, asks: 0, asksElsewhere: 0 })).toEqual({
    kind: "unread",
    turns: 9,
  });
  // Scrolled up mid-chat with the line still above: still the one up control, never a second disc.
  expect(jumpControl({ unread: unread(), behind: true, asks: 0, asksElsewhere: 0 }).kind).toBe("unread");
  // Once the line was on screen: the reader's own place is theirs, so only Jump to latest.
  noteUnreadSide("s:41", "in");
  expect(jumpControl({ unread: unread(), behind: true, asks: 0, asksElsewhere: 0 }).kind).toBe("latest");
  expect(jumpControl({ unread: unread(), behind: false, asks: 0, asksElsewhere: 0 }).kind).toBe("hidden");
  // No unread turns: no jump up at all, whatever the reader last sent or where they last stopped.
  expect(jumpControl({ behind: false, asks: 0, asksElsewhere: 0 }).kind).toBe("hidden");
  expect(jumpControl({ behind: true, asks: 0, asksElsewhere: 0 }).kind).toBe("latest");
  expect(jumpControl({ unread: unread(0), behind: false, asks: 0, asksElsewhere: 0 }).kind).toBe("hidden");
  // The line in view or below it by the layout, before its observer reports: never up.
  resetUnreadForTest();
  expect(jumpControl({ unread: unread(9, false), behind: false, asks: 0, asksElsewhere: 0 }).kind).toBe("hidden");
  expect(jumpControl({ unread: unread(9, false), behind: true, asks: 0, asksElsewhere: 0 }).kind).toBe("latest");
});

test("an ask waiting below comes before the unread jump: the control is the Needs you pill", () => {
  noteUnreadMounted("s:41");
  expect(jumpControl({ unread: unread(), behind: true, asks: 1, asksElsewhere: 0 }).kind).toBe("latest");
  expect(jumpControl({ unread: unread(), behind: false, asks: 2, asksElsewhere: 1 }).kind).toBe("latest");
  // An ask here at the latest message, with the reader there: the unread turns above still lead.
  expect(jumpControl({ unread: unread(), behind: false, asks: 1, asksElsewhere: 0 }).kind).toBe("unread");
});

test("every overlay has one zone; a shared zone is one stack, and each sheet draws it there", () => {
  const overlays = Object.values(TRANSCRIPT_OVERLAYS);
  for (const overlay of overlays) expect(ZONE_KIND[overlay.zone]).toBeDefined();
  const byZone = new Map<string, number[]>();
  for (const overlay of overlays) {
    const stack = byZone.get(overlay.zone) ?? [];
    stack.push("stack" in overlay ? (overlay.stack as number) : -1);
    byZone.set(overlay.zone, stack);
  }
  for (const [zone, stack] of byZone) {
    if (stack.length === 1) continue;
    // Shared: every one has a place in the stack, and no two the same place.
    expect(
      stack.every((place) => place >= 0),
      zone,
    ).toBe(true);
    expect(new Set(stack).size, zone).toBe(stack.length);
  }
  // Where to go next is a dynamic zone; what stays put lives in a stable one.
  expect(ZONE_KIND[TRANSCRIPT_OVERLAYS.jumpControl.zone]).toBe("dynamic");
  expect(ZONE_KIND[TRANSCRIPT_OVERLAYS.sessionInfo.zone]).toBe("stable");
  // One control in the bottom-center zone: nothing else lists it.
  expect(overlays.filter((overlay) => overlay.zone === "bottom-center")).toHaveLength(1);
  // The sheets agree: one 32 px disc on the composer's line; the unread state turns its arrow and
  // adds a count, and stacks nothing above it.
  const conversationCss = readFileSync(join(import.meta.dir, "conversation/conversation.css"), "utf8");
  expect(conversationCss).toMatch(/\.acpmux-jump-latest\s*\{[^}]*height:\s*32px/);
  expect(conversationCss).not.toMatch(/\.cv-since\s*\{/);
  const controlCss = readFileSync(join(import.meta.dir, "jumpControl.css"), "utf8");
  expect(controlCss).toMatch(/\[data-jump="unread"\]\s*\.acpmux-jump-latest__arrow\s*\{[^}]*rotate\(180deg\)/);
  expect(controlCss).not.toMatch(/bottom:/);
});
