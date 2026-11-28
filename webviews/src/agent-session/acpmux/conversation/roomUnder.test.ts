import { describe, expect, test } from "bun:test";

import { floorEnd, roomUnder, type RoomUnderInput, roomUnderRows, rowsMoved } from "./roomUnder";

// A followed chat: rows 1000 px under 32 px of padding, a 600 px view, a 200 px stack over its foot
// whose room under the last row (with the rest gap) is 220 px. Nothing held.
const pass = (more: Partial<RoomUnderInput> = {}): RoomUnderInput => ({
  following: true,
  sessionSwitched: false,
  openedAtLatest: true,
  overlayDock: true,
  dockSpace: 200,
  dockRoom: 220,
  dockTray: 0,
  dockCard: 100,
  dockNotice: 0,
  restExtra: 20,
  lineLast: false,
  rowsGrew: 0,
  rowsHeight: 1000,
  over: 32,
  height: 600,
  floor: 0,
  liftedBefore: 0,
  deadband: 2,
  held: { room: 220, reader: { followed: true } },
  prompt: "u1",
  foldRoom: 0,
  bases: { tray: 0, trayToggled: false, card: 100, cardRest: 0, notice: 0 },
  ...more,
});

describe("roomUnder: a sent prompt scrolled to the top (agentPane.display.sendScrollsToTop)", () => {
  test("off (no sendTop): the room is exactly as before", () => {
    expect(roomUnder(pass({ sendTop: undefined }))).toEqual(roomUnder(pass()));
  });

  test("on: room enough that the followed view's top is the prompt's; the reply fills it", () => {
    // The prompt and its reply so far are 100 px; the view is 600: 500 px of room under them.
    const sent = roomUnder(pass({ sendTop: () => 600 - 100 }));
    expect(sent.room).toBe(500);
    // The followed view's top (total - height) is where the prompt starts in the rows.
    expect(sent.total - 600).toBe(1000 + 32 + 500 - 600);
    // The reply grew 300 px: the room gives it back, so the content's end (and the prompt) stay put.
    const grown = roomUnder(pass({ rowsHeight: 1300, sendTop: () => 600 - 400 }));
    expect(grown.room).toBe(220);
    // Taller than the view's room: the stack's room as before, the view follows the reply's end.
    expect(roomUnder(pass({ rowsHeight: 1600, sendTop: () => 600 - 700 })).room).toBe(220);
  });

  test("on: never while scrolled up, or on another chat's first pass", () => {
    expect(roomUnder(pass({ following: false, sendTop: () => 500 })).room).toBe(
      roomUnder(pass({ following: false })).room,
    );
    expect(roomUnder(pass({ sessionSwitched: true, sendTop: () => 500 })).room).toBe(
      roomUnder(pass({ sessionSwitched: true })).room,
    );
  });
});

describe("roomUnder", () => {
  test("nothing held: the room is the stack's, and the content ends under it", () => {
    const under = roomUnder(pass());
    expect(under.room).toBe(220);
    expect(under.total).toBe(1000 + 32 + 220);
    expect(under.trayHold + under.cardHold + under.noticeHold + under.lifted).toBe(0);
    expect(under.next.heldRoom).toBe(220);
  });

  test("trayHold: a tray the reader opened lies over the rows until the rows move", () => {
    const opened = pass({ dockTray: 120, bases: { tray: 40, trayToggled: true, card: 100, cardRest: 0, notice: 0 } });
    const held = roomUnder(opened);
    expect(held.trayHold).toBe(80);
    expect(held.room).toBe(140);
    expect(held.next.bases.tray).toBe(40);
    expect(held.next.trayTaken).toBe(false);
    // The rows grow: the tray's room is taken in the same pass.
    const moved = roomUnder({ ...opened, rowsGrew: 30 });
    expect(moved.released).toBe(true);
    expect(moved.trayHold).toBe(0);
    expect(moved.room).toBe(220);
    expect(moved.next.trayTaken).toBe(true);
  });

  test("trayHold: folding a list the room had taken leaves no blank room under the rows", () => {
    // The room took the open list (120), then the reader folds it to its line (40): nothing is held.
    const folded = roomUnder(
      pass({ dockTray: 40, bases: { tray: 120, trayToggled: true, card: 100, cardRest: 0, notice: 0 } }),
    );
    expect(folded.trayHold).toBe(0);
    expect(folded.room).toBe(220);
    expect(folded.next.bases.tray).toBe(40);
    // A fold of what the reader opened over the rows still gives back only its hold.
    const opened = roomUnder(
      pass({ dockTray: 120, bases: { tray: 40, trayToggled: true, card: 100, cardRest: 0, notice: 0 } }),
    );
    expect(opened.trayHold).toBe(80);
  });

  test("trayHold: never over the running turn's live line past half its rest gap", () => {
    const under = roomUnder(
      pass({
        lineLast: true,
        dockTray: 120,
        bases: { tray: 40, trayToggled: true, card: 100, cardRest: 0, notice: 0 },
      }),
    );
    expect(under.trayHold).toBe(10);
  });

  test("cardHold: the overlay card's growth lies over the rows until the rows move", () => {
    const grew = pass({ dockCard: 140 });
    expect(roomUnder(grew).cardHold).toBe(40);
    expect(roomUnder(grew).room).toBe(180);
    expect(roomUnder(grew).next.bases.card).toBe(100);
    expect(roomUnder({ ...grew, rowsGrew: 5 }).cardHold).toBe(0);
    // The push arm makes room at once.
    expect(roomUnder({ ...grew, overlayDock: false }).cardHold).toBe(0);
  });

  test("noticeHold: a taller notice lies over the rows; one that went keeps its room until the rows move", () => {
    const came = roomUnder(pass({ dockNotice: 30 }));
    expect(came.noticeHold).toBe(30);
    expect(came.room).toBe(190);
    expect(came.next.bases.notice).toBe(0);
    const went = pass({ dockNotice: 0, bases: { tray: 0, trayToggled: false, card: 100, cardRest: 0, notice: 30 } });
    expect(roomUnder(went).noticeHold).toBe(-30);
    expect(roomUnder(went).room).toBe(250);
    // A negative hold is room the rows still have, held once scrolled up.
    expect(roomUnder(went).next.heldRoom).toBe(250);
    expect(roomUnder({ ...went, rowsGrew: 5 }).noticeHold).toBe(0);
    // Another chat starts from none taken.
    expect(roomUnder({ ...went, sessionSwitched: true }).noticeHold).toBe(0);
  });

  test("one release rule: every stack hold goes in the pass whose rows move, and only then", () => {
    const all = pass({
      dockTray: 60,
      dockCard: 120,
      dockNotice: 20,
      bases: { tray: 20, trayToggled: true, card: 100, cardRest: 0, notice: 0 },
    });
    const held = roomUnder(all);
    expect([held.trayHold, held.cardHold, held.noticeHold]).toEqual([40, 20, 20]);
    const moved = roomUnder({ ...all, rowsGrew: 1 });
    expect(moved.trayHold).toBe(0);
    expect(moved.cardHold).toBe(0);
    // A taller notice still lies over the rows (its base moves to it after this pass).
    expect(moved.room).toBe(220 - moved.noticeHold);
    expect(rowsMoved({ openedAtLatest: true, sessionSwitched: false, rowsGrew: 0.5 })).toBe(false);
    expect(rowsMoved({ openedAtLatest: false, sessionSwitched: false, rowsGrew: 10 })).toBe(false);
    expect(rowsMoved({ openedAtLatest: true, sessionSwitched: true, rowsGrew: 10 })).toBe(false);
  });

  test("lifted: a composer that grows while lifting draws the rows up instead of taking room", () => {
    const under = roomUnder(
      pass({ dockCard: 140, bases: { tray: 0, trayToggled: false, card: 100, cardRest: 100, notice: 0 } }),
    );
    expect(under.lifting).toBe(true);
    expect(under.lifted).toBe(40);
    expect(under.cardHold).toBe(0);
    expect(under.room).toBe(180);
    expect(under.lift).toBe(-40);
    // Room again once scrolled up.
    expect(under.next.heldRoom).toBe(220);
  });

  test("heldRoom: scrolled up the room stays what it was; a reader who came back keeps it for the prompt", () => {
    expect(roomUnder(pass({ following: false, held: { room: 300, reader: { followed: false } } })).room).toBe(300);
    const back = roomUnder(pass({ held: { room: 300, reader: { followed: false, left: true } } }));
    expect(back.room).toBe(300);
    expect(back.kept).toEqual({ room: 300, prompt: "u1", end: 300 });
    // A new prompt gives the kept room up.
    expect(
      roomUnderRows(
        { room: 300, reader: { followed: true, kept: back.kept } },
        {
          following: true,
          sessionSwitched: false,
          followedRoom: 220,
          prompt: "u2",
        },
      ).room,
    ).toBe(220);
  });

  test("floor: a sent prompt's end holds past the rows, less what the rows shrank", () => {
    expect(floorEnd({ kept: false, height: 1500, rowsBefore: 1000, rows: 1000 })).toBe(0);
    expect(floorEnd({ kept: true, height: 1500, rowsBefore: 1000, rows: 900 })).toBe(1400);
    expect(floorEnd({ kept: true, height: 1500, rowsBefore: 1000, rows: 1000, queueEnd: 1600 })).toBe(1600);
    const under = roomUnder(pass({ floor: 1500 }));
    expect(under.total).toBe(1500);
    expect(under.rowsHeight).toBe(1252);
  });

  test("foldRoom: a collapse near the end keeps the content as tall as the view's end, but not in another chat", () => {
    expect(roomUnder(pass({ foldRoom: 2000 })).total).toBe(2000);
    expect(roomUnder(pass({ foldRoom: 2000 })).rowsEnd).toBe(1252);
    expect(roomUnder(pass({ foldRoom: 2000, sessionSwitched: true })).total).toBe(1252);
  });

  test("newerRoom: newer history's room is under the rows", () => {
    expect(roomUnder(pass({ newerRoom: 300 })).rowsHeight).toBe(1552);
  });

  test("a scrollbar drag's height wins while it holds", () => {
    expect(roomUnder(pass({ dragged: 5000, foldRoom: 2000 })).total).toBe(5000);
  });
});
