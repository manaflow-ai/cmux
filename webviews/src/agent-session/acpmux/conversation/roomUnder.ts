// The room under the transcript's last row: one number, one owner (transcript-motion-model.md, model
// rule 9 and step 8: "One room number for the space under the last row, animated on the list's
// clock"). VirtualTranscript's placement pass gives this its inputs once a pass and draws what it
// returns; nothing else adds room under the rows.
//
// The terms it combines, each the bottom stack's part (composer card, tray, notices) or the list's:
// - `trayHold`: what the reader opened or folded in the running tray, which lies over the rows' foot;
// - `cardHold`: the overlay composer's growth where the view follows but cannot lift;
// - `noticeHold`: a host line or notice that came taller than the rest gap, or left;
// - `lifted`: the composer's growth the rows are drawn up by instead of given room;
// - `heldRoom`: the room held while the reader is scrolled up, or kept for one they came back to;
// - `floor`: the end a followed view keeps for a sent prompt whose queue card left;
// - `foldRoom`: the end a collapse near the end keeps, so the offset never clamps;
// - `newerRoom`: the room the newer history a reader scrolled far up let go of (newerReserve.ts).
// No room is held for a sent prompt: a send keeps the earlier chat in view above it (issue 51841),
// unless the person turned on `sendTop` (a sent prompt scrolls to the view's top, off by default).
//
// One release rule for the stack's holds (`rowsMoved`): a card, the tray or a notice that changed
// gives its room back, or takes it, in the pass whose rows move anyway (they grew: a reply streaming
// on, a send), so the room changes on the same clock as the rows. Jump to latest and the reader's
// wheel past the end take it at once (VirtualTranscript `takeRoom`, `giveTrayRoom`) by moving the
// bases this reads. Pure: no DOM, no refs, no clock.

/// What a reader who scrolled up and came back down keeps under the last row (VirtualTranscript
/// `heldRoom.reader`). `followed`: the last pass followed the latest row. `left`: the reader's own
/// input let it go since then. `kept`: room kept for the newest prompt they came back to.
/// `kept.end`: where the kept room ends, measured from the top of the prompt it is kept under (`tail`):
/// the rows that come under the prompt fill the room instead of pushing it down.
export type ReaderRoom = {
  followed: boolean;
  left?: true;
  kept?: { room: number; prompt: string | undefined; end: number };
};

/// The room a pass held, and the reader's part of it, as the last pass left it.
export type HeldRoom = { room: number; reader: ReaderRoom };

/// Rows grew by more than this since the last pass: they move anyway, and the stack's holds go.
export const ROWS_MOVED_PX = 0.5;

/// The heights the room under the last row last took for each part of the stack (what each hold is
/// measured from). Written back from `RoomUnder.next` after each commit.
export type RoomBases = {
  /// The tray's height the room was last given.
  tray: number;
  /// The reader opened or folded something in the tray and the room has not taken it yet.
  trayToggled: boolean;
  /// The overlay composer card's height the room last took.
  card: number;
  /// The composer card's height the room was last made for while lifting (the card's rest).
  cardRest: number;
  /// The notices' height the room last took.
  notice: number;
};

export type RoomUnderInput = {
  following: boolean;
  sessionSwitched: boolean;
  /// The chat opened at its latest row (VirtualTranscript `didOpenAtLatest`) as of the last pass.
  openedAtLatest: boolean;
  /// The composer dock is the overlay arm (composer/dockMotion.experiment.ts).
  overlayDock: boolean;
  /// The bottom stack's height over the view's foot (0: docked in flow).
  dockSpace: number;
  /// The stack's room under the last row with the rest gap (model.ts `restRoom`).
  dockRoom: number;
  dockTray: number;
  dockCard: number;
  dockNotice: number;
  /// The rest gap's extra over the stack (VirtualTranscript `restExtra`).
  restExtra: number;
  /// The room the saved copy's bottom stack took that the live one still lacks (VirtualTranscript
  /// `copyDock`), 0 once acpmux's state is here: held as room so the swap moves no row. A gap, never a cover.
  copyDock?: number;
  /// The last row is the running turn's live line.
  lineLast: boolean;
  /// The rows' own growth since the last pass (room taken or given above them is none).
  rowsGrew: number;
  /// The rows' laid-out height (with the room above them for older history).
  rowsHeight: number;
  /// What lies over the rows in the content: the thread's top padding, the top inset, the tail gap.
  over: number;
  /// The scroller's height.
  height: number;
  /// The content end held for a sent prompt (`floorEnd`), 0 for none.
  floor: number;
  /// The lift the last pass drew.
  liftedBefore: number;
  /// The scroller's follow deadband.
  deadband: number;
  held: HeldRoom;
  /// The newest prompt's row id while following (`kept` is for its turn).
  prompt: string | undefined;
  /// The rows' height from the newest prompt's top to the rows' end (`roomUnderRows`' `tail`); read
  /// only while room is held or kept. Absent: the kept room stays a fixed height.
  promptTail?: () => number;
  /// The room that puts the newest prompt, one this view sent, at the view's top while the view follows
  /// (Settings `agentPane.display.sendScrollsToTop`, off by default). Absent: none. Read only while following.
  sendTop?: () => number;
  /// The content end a collapse keeps (foldAnchor.ts `foldRoomFor`), 0 for none.
  foldRoom: number;
  /// The room under the rows for newer history let go of (conversation/newerReserve.ts), 0 for none.
  newerRoom?: number;
  /// A scrollbar drag's held height, which wins while it holds.
  dragged?: number;
  bases: RoomBases;
};

export type RoomUnder = {
  /// The one number: the room under the last row this pass.
  room: number;
  /// The content's total height: the rows and the room, or what a held end (floor, fold) or a
  /// scrollbar drag keeps.
  total: number;
  /// The content's end with the rows and their room, as the view would hold it with nothing held.
  rowsEnd: number;
  /// The rows' end with the room (`total` before the floor and fold).
  rowsHeight: number;
  /// The content's end with all of the stack's height as room, unlifted.
  atDock: number;
  /// The composer growth drawn as lift instead of room, and where the rows draw against where they
  /// lay out (negative: drawn up).
  lifted: number;
  lift: number;
  /// Whether the view lifts with the card this pass.
  lifting: boolean;
  trayHold: number;
  cardHold: number;
  noticeHold: number;
  /// The rows moved this pass: what the stack held is given back (`rowsMoved`).
  released: boolean;
  /// The room kept for the reader who came back down (`ReaderRoom.kept`).
  kept: ReaderRoom["kept"];
  /// What the next pass reads: the room held (with the composer growth, which is room again once
  /// the view stops following) and the bases each hold is measured from.
  next: { heldRoom: number; bases: Omit<RoomBases, "cardRest" | "trayToggled">; trayTaken: boolean };
};

/// The one release rule: rows that grew in a pass after the chat opened at its latest row, in the
/// chat it drew last. A hold the stack keeps lets go in that pass, as the rows move.
export function rowsMoved(input: Pick<RoomUnderInput, "openedAtLatest" | "sessionSwitched" | "rowsGrew">): boolean {
  return input.openedAtLatest && !input.sessionSwitched && input.rowsGrew > ROWS_MOVED_PX;
}

/// The room under the last row this pass, and what of it is kept for the reader (`heldRoom.reader`):
/// followed, the stack's room (`followedRoom`), or more where the reader came back down to room held
/// while they were scrolled up; scrolled up, the room held.
/// The kept room is space the rows already had, so the turn's rows fill it as they come: its end stays
/// where it was drawn (`end`, from the prompt's top) and each row that arrives takes its height out of
/// it, so nothing the reader sees moves, and once the rows reach the stack's room it is gone. Kept as a
/// fixed height, it stayed under the live line for the rest of the turn while every row arrived above
/// it (Leo, 2026-11-22: "for some reason there's also a ton of space at the bottom? idk if it was
/// accounting maybe for tool calls in a long steered with attachment situation").
/// `tail`: the rows' height from the newest prompt's top (the whole content without one) to the rows' end.
export function roomUnderRows(
  { room: held, reader }: HeldRoom,
  pass: {
    following: boolean;
    sessionSwitched: boolean;
    followedRoom: number;
    prompt: string | undefined;
    /// Read only while room is held or kept.
    tail?: () => number;
  },
): { room: number; kept: ReaderRoom["kept"] } {
  if (pass.sessionSwitched) return { room: pass.followedRoom, kept: undefined };
  if (!pass.following) return { room: held, kept: undefined };
  const fresh = !reader.followed && reader.left === true && held > pass.followedRoom + 0.5;
  const carried = reader.followed && reader.kept !== undefined && reader.kept.prompt === pass.prompt;
  if (!fresh && !carried) return { room: pass.followedRoom, kept: undefined };
  const tail = pass.tail ? pass.tail() : 0;
  const end = fresh ? tail + held : reader.kept!.end;
  const left = Number.isFinite(end - tail) ? end - tail : 0;
  // Filled down to the stack's room: nothing is kept any longer.
  // No room kept: the stack's room as it is, below zero too (what an opened tray lies over, `trayHold`).
  if (left <= pass.followedRoom + 0.5) return { room: pass.followedRoom, kept: undefined };
  return { room: left, kept: { room: left, prompt: pass.prompt, end } };
}

/// The end a followed view keeps for a sent prompt whose queue card left (`floor`), 0 for none.
/// `kept`: the hold still applies (following, kept for a prompt or a working reply, same width and
/// chat). `queueEnd`: the last pass's end over the new view when a queue card left and the view's
/// foot dropped. The rows that got shorter under it bring the end up with them (`rowsBefore` against
/// `rows`): the room held is the stack's, never the rows'.
export function floorEnd(input: {
  kept: boolean;
  height: number;
  rowsBefore: number;
  rows: number;
  queueEnd?: number;
}): number {
  if (!input.kept) return 0;
  const shrank = Math.max(0, input.rowsBefore - input.rows);
  const end = input.queueEnd === undefined ? input.height : Math.max(input.height, input.queueEnd);
  return end - shrank;
}

export function roomUnder(input: RoomUnderInput): RoomUnder {
  const { following, sessionSwitched, openedAtLatest, dockSpace, dockTray, dockCard, dockNotice, bases } = input;
  const released = rowsMoved(input);
  // The composer card's growth since the view began following, drawn as lift.
  const lifting =
    following && !sessionSwitched && openedAtLatest && dockSpace > 0 && dockCard > 0 && bases.cardRest > 0;
  const grown = lifting ? Math.min(dockSpace, dockCard - bases.cardRest) : 0;
  // The tray: what the reader opened or folded lies over the rows' foot until the rows move.
  const heldBase =
    sessionSwitched || !following || dockSpace <= 0 || !bases.trayToggled
      ? dockTray
      : released
        ? dockTray - Math.min(0, dockTray - bases.tray + input.rowsGrew)
        : bases.tray;
  // Never over the running turn's live line: at most half its rest gap. And never under the rows: a
  // fold of a list the room had already taken (opened from the tucked tab, or taken by the wheel or the
  // rows' growth) gives that room back as it closes, so the rows come down on the fold's own frames
  // and rest on the folded hat. Held, it left the list's height as blank room under the last row
  // until the rows grew again, the transcript's end gone from view over the hat's one line (Leo,
  // ask-31a1e4b192, 2026-11-27: "this isn't great").
  const trayBase = Math.min(dockTray, input.lineLast ? Math.max(heldBase, dockTray - input.restExtra / 2) : heldBase);
  const trayHold = Math.min(dockSpace, dockTray - trayBase);
  // The overlay card's growth where the view follows but cannot lift, until the rows move.
  const cardHolds =
    !lifting && input.overlayDock && following && !sessionSwitched && openedAtLatest && dockSpace > 0 && bases.card > 0;
  const cardHold =
    cardHolds && !released ? Math.max(0, Math.min(dockSpace - Math.max(0, trayHold), dockCard - bases.card)) : 0;
  // A notice that came taller lies over the newest row's foot within what the stack leaves; one that
  // went leaves its room (a negative hold) until the rows move. Another chat starts from none taken.
  const noticeHeldAt = sessionSwitched ? 0 : bases.notice;
  const noticeHold =
    dockSpace <= 0 || !following
      ? 0
      : dockNotice >= noticeHeldAt
        ? Math.min(dockNotice - noticeHeldAt, Math.max(0, dockSpace - Math.max(0, trayHold) - cardHold))
        : released
          ? 0
          : dockNotice - noticeHeldAt;
  const copyHold =
    (input.copyDock ?? 0) > 0 && dockSpace > 0 && following
      ? Math.max(0, (input.copyDock ?? 0) - (dockSpace - noticeHold))
      : 0;
  const holds = trayHold + cardHold + noticeHold - copyHold;
  const rowsAtDock = input.rowsHeight + input.over + input.dockRoom - holds;
  const atDock = Math.max(input.floor, rowsAtDock);
  // A card that grew is drawn up by at most what the offset can take back; while a floor reaches past
  // the rows it already covers the card, and the lift stays as it was.
  const floorHolds = input.floor > rowsAtDock;
  const lifted =
    grown > 0
      ? Math.max(
          0,
          Math.min(
            grown,
            Math.round(atDock - input.height - input.deadband - 1),
            floorHolds ? input.liftedBefore : grown,
          ),
        )
      : grown;
  const followedRoom = input.dockRoom - lifted - holds;
  const rowsRoom = roomUnderRows(input.held, {
    following,
    sessionSwitched,
    followedRoom,
    prompt: input.prompt,
    tail: input.promptTail,
  });
  // A sent prompt at the view's top (opt-in): room enough under the rows that the followed view's top is
  // the prompt's, and the reply fills it as it comes; once the reply is taller, the stack's room as before.
  const sendTop = following && !sessionSwitched && input.sendTop ? input.sendTop() : 0;
  const room = Math.max(rowsRoom.room, Number.isFinite(sendTop) ? sendTop : 0);
  const kept = rowsRoom.kept;
  const rowsHeight = input.rowsHeight + input.over + room + (input.newerRoom ?? 0);
  const rowsEnd = Math.max(input.floor - lifted, rowsHeight);
  const keptEnd = sessionSwitched ? 0 : input.foldRoom;
  const total = input.dragged ?? Math.max(rowsEnd, keptEnd);
  // Where the rows draw against where they lay out: the followed offset of this layout against the
  // one the unlifted layout would hold. Negative draws them up, positive down. A lift only ever moves
  // the rows with the card's change (up for a card that grew, down for one that shrank): any other
  // height in this layout, as the room a send keeps under its prompt (`sendTop`), is not the card's.
  // The send from a raised composer (a six-line draft) read that room as lift in the commit before the
  // card's emptied height was measured, and drew every row 12 px low for one frame before they jumped
  // up (Leo, 2026-11-11: "when there's a composer thing raised then it gets sent ... if you look at the
  // tnimation for when things get sent: it's not good"; agent-pane-send-raised).
  const offsetLift = lifted ? Math.round(Math.max(0, total - input.height) - Math.max(0, atDock - input.height)) : 0;
  const lift = lifted > 0 ? Math.min(0, offsetLift) : Math.max(0, offsetLift);
  return {
    room,
    total,
    rowsEnd,
    rowsHeight,
    atDock,
    lifted,
    lift,
    lifting,
    trayHold,
    cardHold,
    noticeHold,
    released,
    kept,
    next: {
      // A hold for a line that went is room the rows still have: it stays once scrolled up.
      heldRoom: room + lifted + cardHold + Math.max(0, noticeHold),
      bases: { tray: trayBase, card: dockCard - cardHold, notice: dockNotice - noticeHold },
      // The tray's toggle is spent: the room holds none of it, and the rows moved or the view let go.
      trayTaken: Math.abs(trayHold) <= 0.5 && (released || !following || sessionSwitched),
    },
  };
}
