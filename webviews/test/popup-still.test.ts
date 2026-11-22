// popupMoves (test/support/popupStill.ts): what it names and what it lets pass, on hand-made frames.
import { describe, expect, test } from "bun:test";
import { POPUP_INPUT_MS } from "../src/ui/popupSettle";
import { popupBoxMoves, popupMoves, type PopupFrame, type PopupRow, type PopupShot } from "./support/popupStill";

const FRAME_MS = 1000 / 60;

function shot(width: number, height = 200, rows: PopupRow[] = [], place = { left: 10, top: 40 }): PopupShot {
  return { id: ".acpmux-folder-popover@0", name: ".acpmux-folder-popover", box: { ...place, width, height }, rows };
}

/** One frame per shot, 60 per second. */
function frames(...shots: PopupShot[]): PopupFrame[] {
  return shots.map((popup, index) => ({ index, t: index * FRAME_MS, popups: [popup] }));
}

const row = (key: string, left = 16, height = 28, lead = 22, trail = 300): PopupRow => ({
  key,
  left,
  height,
  lead,
  trail,
});

describe("popupMoves", () => {
  test("a popup that holds still passes", () => {
    expect(popupMoves(frames(shot(315), shot(315), shot(315), shot(315)))).toEqual([]);
  });

  test("names a popup that grows wider with no input", () => {
    const moves = popupMoves(frames(shot(315), shot(315), shot(315), shot(530), shot(530)));
    expect(moves).toEqual(["popup .acpmux-folder-popover grew 315 -> 530 px wide at frame 3 (t=50 ms) with no input"]);
  });

  test("names a popup that shrinks, in width and height", () => {
    const moves = popupMoves(frames(shot(530, 400), shot(530, 400), shot(530, 400), shot(315, 200)));
    expect(moves).toEqual([
      "popup .acpmux-folder-popover shrank 530 -> 315 px wide at frame 3 (t=50 ms) with no input",
      "popup .acpmux-folder-popover shrank 400 -> 200 px tall at frame 3 (t=50 ms) with no input",
    ]);
  });

  test("names a popup that moves", () => {
    const moves = popupMoves(frames(shot(315), shot(315), shot(315), shot(315, 200, [], { left: 10, top: 12 })));
    expect(moves).toEqual([
      "popup .acpmux-folder-popover moved from (10, 40) to (10, 12) at frame 3 (t=50 ms) with no input",
    ]);
  });

  test("names a row that shifts sideways, grows taller, or whose slots move", () => {
    const still = [row("atlas-web"), row("cmux")];
    const shifted = [row("atlas-web", 16, 28, 40, 300), row("cmux", 24, 34, 30, 280)];
    const moves = popupMoves(
      frames(shot(315, 200, still), shot(315, 200, still), shot(315, 200, still), shot(315, 200, shifted)),
    );
    expect(moves).toEqual([
      'popup .acpmux-folder-popover row "atlas-web" leading slot moved 22 -> 40 px at frame 3 (t=50 ms) with no input',
      'popup .acpmux-folder-popover row "cmux" moved sideways 16 -> 24 px at frame 3 (t=50 ms) with no input',
      'popup .acpmux-folder-popover row "cmux" grew 28 -> 34 px tall at frame 3 (t=50 ms) with no input',
      'popup .acpmux-folder-popover row "cmux" leading slot moved 22 -> 30 px at frame 3 (t=50 ms) with no input',
      'popup .acpmux-folder-popover row "cmux" trailing slot moved 300 -> 280 px at frame 3 (t=50 ms) with no input',
    ]);
    expect(popupBoxMoves(moves)).toEqual([]);
  });

  test("names words that a late icon pushes sideways", () => {
    const before = [{ ...row("Rename"), text: 22 }];
    const after = [{ ...row("Rename"), text: 42 }];
    expect(
      popupMoves(frames(shot(315, 200, before), shot(315, 200, before), shot(315, 200, before), shot(315, 200, after))),
    ).toEqual([
      'popup .acpmux-folder-popover row "Rename" words moved sideways 22 -> 42 px at frame 3 (t=50 ms) with no input',
    ]);
  });

  test("rows that arrive or leave late are not moves", () => {
    const before = [row("atlas-web")];
    const after = [row("atlas-web"), row("cmux"), row("notes")];
    expect(
      popupMoves(frames(shot(315, 200, before), shot(315, 200, before), shot(315, 200, after), shot(315, 200, before))),
    ).toEqual([]);
  });

  test("the first two frames are the settle window", () => {
    expect(popupMoves(frames(shot(200, 100), shot(315, 200), shot(315, 200), shot(315, 200)))).toEqual([]);
    // From the third frame on, a change is named.
    expect(popupMoves(frames(shot(200), shot(315), shot(315), shot(320)))).toHaveLength(1);
    // A wider window is the caller's to ask for.
    expect(popupMoves(frames(shot(200), shot(315), shot(315), shot(320)), { allowFirstFrames: 4 })).toEqual([]);
  });

  test("a change within POPUP_INPUT_MS after input is allowed, and one after it is not", () => {
    const shots = frames(shot(315), shot(315), shot(315), shot(400), shot(400));
    const late = { index: 5, t: 30 + POPUP_INPUT_MS + 50, popups: [shot(500)] };
    const moves = popupMoves({ frames: [...shots, late], inputs: [30] });
    expect(moves).toEqual([
      `popup .acpmux-folder-popover grew 400 -> 500 px wide at frame 5 (t=${Math.round(late.t)} ms) with no input`,
    ]);
  });

  test("the input that opened the popup excuses nothing", () => {
    // The press that opens it comes before it is drawn: it is given to no popup.
    const shots = frames(shot(315), shot(315), shot(315), shot(530));
    const grew = ["popup .acpmux-folder-popover grew 315 -> 530 px wide at frame 3 (t=50 ms) with no input"];
    expect(popupMoves({ frames: shots, inputs: [{ at: -20, popups: [] }] })).toEqual(grew);
    expect(popupMoves({ frames: shots, inputs: [{ at: 6, popups: [] }] })).toEqual(grew);
    // A press in the popup, or a key while it is open, is input to it.
    expect(popupMoves({ frames: shots, inputs: [{ at: 20, popups: [".acpmux-folder-popover@0"] }] })).toEqual([]);
  });

  test("input to one popup does not excuse another", () => {
    const other: PopupShot = { ...shot(180), id: ".ui-menu@1", name: ".ui-menu" };
    const wider = { ...other, box: { ...other.box, width: 240 } };
    const list: PopupFrame[] = [
      { index: 0, t: 0, popups: [shot(315)] },
      { index: 1, t: 40, popups: [shot(315), other] },
      { index: 2, t: 56, popups: [shot(315), other] },
      { index: 3, t: 72, popups: [shot(315), other] },
      { index: 4, t: 90, popups: [shot(315), wider] },
    ];
    expect(popupMoves({ frames: list, inputs: [{ at: 30, popups: [".acpmux-folder-popover@0"] }] })).toEqual([
      "popup .ui-menu grew 180 -> 240 px wide at frame 4 (t=90 ms) with no input",
    ]);
  });

  test("changes below stillPx are rounding", () => {
    expect(popupMoves(frames(shot(315), shot(315), shot(315), shot(315.4)))).toEqual([]);
    expect(popupMoves(frames(shot(315), shot(315), shot(315), shot(315.4)), { stillPx: 0.1 })).toHaveLength(1);
  });

  test("each popup is judged on its own frames", () => {
    const other: PopupShot = { ...shot(180), id: ".ui-menu@1", name: ".ui-menu" };
    const list: PopupFrame[] = [
      { index: 0, t: 0, popups: [shot(315)] },
      { index: 1, t: 16, popups: [shot(315)] },
      { index: 2, t: 33, popups: [shot(315), other] },
      // The submenu's own second frame: still its settle window.
      { index: 3, t: 50, popups: [shot(315), { ...other, box: { ...other.box, width: 220 } }] },
      { index: 4, t: 66, popups: [shot(315), { ...other, box: { ...other.box, width: 240 } }] },
    ];
    expect(popupMoves(list)).toEqual(["popup .ui-menu grew 220 -> 240 px wide at frame 4 (t=66 ms) with no input"]);
  });
});
