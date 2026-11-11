// The unread marker's state (conversation/unreadState.ts), Jump up (jumpUp.ts) and the overlay
// zones (overlayLayout.ts): design/transcript-overlays.md.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { beforeEach, expect, test } from "bun:test";
import {
  bannerShown,
  hideUnreadBanner,
  markUnreadRead,
  noteUnreadMounted,
  noteUnreadSide,
  readUnread,
  resetUnreadForTest,
  sinceDone,
  unreadPending,
  unreadRead,
} from "./conversation/unreadState";
import {
  jumpUpShown,
  jumpUpTarget,
  newerMark,
  placeOffScreen,
  placeOffView,
  pressJumpUp,
  type ManualMark,
} from "./jumpUp";
import { TRANSCRIPT_OVERLAYS, ZONE_KIND, topZoneOffset } from "./overlayLayout";

beforeEach(() => resetUnreadForTest());

test("the banner shows while the line is off screen and not reached, and goes once it was seen", () => {
  noteUnreadMounted("s:41");
  expect(bannerShown("s:41", readUnread(), "expanded")).toBe(true);
  expect(bannerShown("s:41", readUnread(), "collapsed")).toBe(true);
  expect(bannerShown("s:41", readUnread(), "off")).toBe(false);
  noteUnreadSide("s:41", "in");
  expect(bannerShown("s:41", readUnread(), "expanded")).toBe(false);
  // Scrolled away again, it stays away for this mark.
  noteUnreadSide("s:41", "below");
  expect(bannerShown("s:41", readUnread(), "expanded")).toBe(false);
});

test("Mark read fades the line and hides the banner until the next return", () => {
  noteUnreadMounted("s:41");
  markUnreadRead("s:41");
  expect(unreadRead("s:41", readUnread())).toBe(true);
  expect(bannerShown("s:41", readUnread(), "expanded")).toBe(false);
  // The next return is a new mark: shown again, unread.
  noteUnreadMounted("s:57");
  expect(bannerShown("s:57", readUnread(), "expanded")).toBe(true);
  expect(unreadRead("s:57", readUnread())).toBe(false);
});

test("hiding the banner keeps the line; Jump and the latest message end it (#40065)", () => {
  noteUnreadMounted("s:41");
  hideUnreadBanner("s:41");
  expect(bannerShown("s:41", readUnread(), "expanded")).toBe(false);
  expect(unreadRead("s:41", readUnread())).toBe(false);
  resetUnreadForTest();
  noteUnreadMounted("s:41");
  noteUnreadSide("s:41", "below");
  sinceDone("s:41");
  expect(bannerShown("s:41", readUnread(), "expanded")).toBe(false);
  expect(readUnread()?.side).toBe("above");
  // Reaching the latest message by hand reads a line that was seen; one never seen stays unread.
  expect(unreadRead("s:41", readUnread())).toBe(false);
  noteUnreadSide("s:41", "in");
  sinceDone("s:41", true);
  expect(unreadRead("s:41", readUnread())).toBe(true);
  expect(unreadPending("s:41", readUnread())).toBe(false);
});

const mark = (rowId: string, at: number, why: ManualMark["why"]): ManualMark => ({
  place: { rowId, offset: 0 },
  at,
  why,
});

test("Jump up goes to the unread line first, else the newer of the last prompt and the last stop", () => {
  expect(jumpUpTarget("sinceDivider", mark("p", 5, "sent"), mark("r", 9, "stopped"))?.rowId).toBe("sinceDivider");
  expect(jumpUpTarget(undefined, mark("p", 5, "sent"), mark("r", 9, "stopped"))?.rowId).toBe("r");
  expect(jumpUpTarget(undefined, mark("p", 12, "sent"), mark("r", 9, "stopped"))?.rowId).toBe("p");
  expect(jumpUpTarget(undefined, undefined, undefined)).toBeUndefined();
  expect(newerMark(undefined, mark("r", 1, "stopped"))?.place.rowId).toBe("r");
});

test("Jump up shows only while its place is off screen, and while it holds a way back", () => {
  expect(placeOffScreen(100, 0, 400)).toBe(false);
  expect(placeOffScreen(500, 0, 400)).toBe(true);
  expect(placeOffScreen(100, 200, 400)).toBe(true);
  // The header covers the view's top: a place under it is off screen.
  expect(placeOffScreen(210, 200, 400, 24)).toBe(true);
  expect(placeOffScreen(undefined, 0, 400)).toBe(false);
  expect(jumpUpShown(false, undefined)).toBe(false);
  expect(jumpUpShown(true, undefined)).toBe(true);
  expect(jumpUpShown(false, { top: 900, atLatest: true })).toBe(true);
});

test("Jump up reads a place where its row draws: a prompt in sight at the chat's top is on screen", () => {
  // gallery agent-pane.transcript#codex-turn-raw-commands: the first prompt's layout top is 0, the view
  // 10 px down; the row draws 16 px lower (THREAD_TOP), its bubble whole under the header.
  const view = { shownTop: 10, height: 532, threadTop: 16, topInset: 0, dockSpace: 96 };
  expect(placeOffView(0, view)).toBe(false);
  // Scrolled past it, it is off screen.
  expect(placeOffView(0, { ...view, shownTop: 40 })).toBe(true);
  // Under the dock it is out of sight too.
  expect(placeOffView(420, view)).toBe(false);
  expect(placeOffView(440, view)).toBe(true);
  expect(placeOffView(undefined, view)).toBe(false);
});

test("a second press goes back to where the view was", () => {
  const first = pressJumpUp(undefined, { top: 900, atLatest: true });
  expect(first).toEqual({ kind: "go", back: { top: 900, atLatest: true } });
  const second = pressJumpUp(first.back, { top: 120, atLatest: false });
  expect(second).toEqual({ kind: "back", back: { top: 900, atLatest: true } });
});

test("every overlay has one zone; a shared zone is one stack, and each sheet draws it there", () => {
  const overlays = Object.values(TRANSCRIPT_OVERLAYS);
  for (const overlay of overlays) expect(ZONE_KIND[overlay.zone]).toBeDefined();
  const byZone = new Map<string, number[]>();
  for (const overlay of overlays) {
    const stack = byZone.get(overlay.zone) ?? [];
    stack.push("stack" in overlay ? overlay.stack : -1);
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
  // What is new arrives in a dynamic zone; what stays put lives in a stable one.
  expect(ZONE_KIND[TRANSCRIPT_OVERLAYS.unreadBanner.zone]).toBe("dynamic");
  expect(ZONE_KIND[TRANSCRIPT_OVERLAYS.jumpUp.zone]).toBe("dynamic");
  expect(ZONE_KIND[TRANSCRIPT_OVERLAYS.sessionInfo.zone]).toBe("stable");
  // The sheets agree: the banner's zone starts on the column's start inset, Jump up stands one
  // control and one gap above Jump to latest, which is centered on the composer's line.
  const unreadCss = readFileSync(join(import.meta.dir, "conversation/unread.css"), "utf8");
  expect(unreadCss).toMatch(/\.acpmux-over-top\s*\{[^}]*justify-content:\s*flex-start/);
  expect(unreadCss).toMatch(/\.acpmux-over-top\s*\{[^}]*padding-inline:\s*var\(--cv-inset/);
  const pairCss = readFileSync(join(import.meta.dir, "jumpPair.css"), "utf8");
  expect(pairCss).toMatch(/\.acpmux-jump-up\s*\{[^}]*var\(--ds-control-primary\)\s*\+\s*var\(--ds-space-2\)/);
  const conversationCss = readFileSync(join(import.meta.dir, "conversation/conversation.css"), "utf8");
  expect(conversationCss).toMatch(/\.acpmux-jump-latest\s*\{[^}]*height:\s*32px/);
  expect(conversationCss).not.toMatch(/\.cv-since\s*\{/);
});

test("the top zone starts under the clear line, the tab row and a pinned pill", () => {
  expect(topZoneOffset({ clearTop: 40 })).toBe(40);
  expect(topZoneOffset({ clearTop: 40, floor: 52 })).toBe(52);
  expect(topZoneOffset({ clearTop: 40, pinnedBottom: 72 })).toBe(72);
});
