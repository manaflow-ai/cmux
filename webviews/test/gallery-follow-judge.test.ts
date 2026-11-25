import { expect, test } from "bun:test";
import { FOLLOW_REVERSED, judgeFollowFrames, sharedFollow } from "../src/gallery/followJudge";
import type { BoxFrame, BoxSample } from "../src/gallery/shift";

const row = (name: string, y: number, extra: Partial<BoxSample> = {}): BoxSample => ({
  box: { x: 0, y, width: 800, height: 40 },
  label: `article.acpmux-row[row ${name}]`,
  row: true,
  ...extra,
});
const composer = (y: number): BoxSample => ({
  box: { x: 0, y, width: 800, height: 80 },
  label: "div.acpmux-composer-box",
  composer: true,
});
const frames = (...list: [number, BoxSample][][]): BoxFrame[] => list.map((entries) => new Map(entries));

test("a follow every row shares, with the composer still, is no stray move", () => {
  const judged = judgeFollowFrames(
    frames(
      [
        [1, row("a", 100)],
        [2, row("b", 200)],
        [9, composer(520)],
      ],
      [
        [1, row("a", 60)],
        [2, row("b", 160)],
        [9, composer(520)],
      ],
      [
        [1, row("a", 20)],
        [2, row("b", 120)],
        [9, composer(520)],
      ],
      [
        [1, row("a", 20)],
        [2, row("b", 120)],
        [9, composer(520)],
      ],
    ),
  );
  expect(judged).toEqual({ movingFrames: 2, followFrames: 2, strayFrames: 0, stray: [], worst: 0 });
});

test("two rows that move by different amounts in one frame are a stray move, named with frame and px", () => {
  const judged = judgeFollowFrames(
    frames(
      [
        [1, row("a", 100)],
        [2, row("b", 200)],
        [3, row("c", 300)],
      ],
      [
        [1, row("a", 60)],
        [2, row("b", 160)],
        [3, row("c", 268)],
      ],
    ),
  );
  expect(judged.strayFrames).toBe(1);
  expect(judged.stray).toEqual([{ label: "article.acpmux-row[row c]", frame: 1, dx: 0, dy: -32, follow: -40 }]);
  expect(judged.worst).toBe(8);
});

test("a row that grows moves the rows past it by its growth: the rows stay packed, no stray move", () => {
  // A reply's new line over a bottom-pinned live line: the rows above rise, the line holds.
  const streamed = judgeFollowFrames(
    frames(
      [
        [1, row("user", 100)],
        [2, row("reply", 200)],
        [3, row("thinking-live", 300)],
      ],
      [
        [1, row("user", 77)],
        [2, row("reply", 177, { box: { x: 0, y: 177, width: 800, height: 63 } })],
        [3, row("thinking-live", 300)],
      ],
    ),
  );
  expect(streamed).toMatchObject({ movingFrames: 1, followFrames: 1, strayFrames: 0, stray: [] });
  // A call opened in place: the rows under it go down by its height, the rows over it hold.
  const opened = judgeFollowFrames(
    frames(
      [
        [1, row("call", 100)],
        [2, row("answer", 200)],
        [3, row("thinking-live", 300)],
      ],
      [
        [1, row("call", 100, { box: { x: 0, y: 100, width: 800, height: 287 } })],
        [2, row("answer", 447)],
        [3, row("thinking-live", 547)],
      ],
    ),
  );
  expect(opened).toMatchObject({ followFrames: 1, strayFrames: 0, stray: [] });
  // The same call as the click's target: not judged itself, still the row its push is measured from.
  const clicked = judgeFollowFrames(
    frames(
      [
        [0, row("user", 20)],
        [1, row("call", 100, { targeted: true })],
        [2, row("answer", 200)],
      ],
      [
        [0, row("user", 20)],
        [1, row("call", 100, { targeted: true, box: { x: 0, y: 100, width: 800, height: 287 } })],
        [2, row("answer", 447)],
      ],
    ),
  );
  expect(clicked).toMatchObject({ strayFrames: 0, stray: [] });
});

test("a reply's line landing in the live line's room, then the follow, is no stray move", () => {
  // streaming-text#codex, painted: the reply grows 23 px over the quiet live line's room, then the
  // rows rise by that line a frame later and the line holds; their gap is back at its rest.
  const reply = (y: number, height: number) => row("reply", y, { box: { x: 0, y, width: 800, height } });
  const judged = judgeFollowFrames(
    frames(
      [
        [1, row("user", 296)],
        [2, reply(371, 23)],
        [3, row("thinking-live", 402)],
      ],
      [
        [1, row("user", 296)],
        [2, reply(371, 46)],
        [3, row("thinking-live", 402)],
      ],
      [
        [1, row("user", 273)],
        [2, reply(348, 46)],
        [3, row("thinking-live", 402)],
      ],
    ),
  );
  expect(judged).toMatchObject({ strayFrames: 0, stray: [] });
  // The same gap opened past its rest is a stray move: the line dropped away from the reply.
  const dropped = judgeFollowFrames(
    frames(
      [
        [1, row("user", 296)],
        [2, reply(371, 23)],
        [3, row("thinking-live", 402)],
      ],
      [
        [1, row("user", 273)],
        [2, reply(348, 23)],
        [3, row("thinking-live", 402)],
      ],
    ),
  );
  expect(dropped.stray).toEqual([
    { label: "article.acpmux-row[row thinking-live]", frame: 1, dx: 0, dy: 0, follow: -23 },
  ]);
});

test("a row arriving over the live line moves the rows over it, not the line: no stray move", () => {
  const judged = judgeFollowFrames(
    frames(
      [
        [1, row("user", 220)],
        [3, row("thinking-live", 362)],
      ],
      [
        [1, row("user", 181)],
        [2, row("answer", 300)],
        [3, row("thinking-live", 362)],
      ],
    ),
  );
  expect(judged).toMatchObject({ movingFrames: 1, strayFrames: 0, stray: [] });
});

test("a row that jumps away from its packed neighbour with nothing grown is a stray move", () => {
  const judged = judgeFollowFrames(
    frames(
      [
        [1, row("call", 100)],
        [2, row("answer", 200)],
        [3, row("thinking-live", 300)],
      ],
      [
        [1, row("call", 100)],
        [2, row("answer", 200)],
        [3, row("thinking-live", 547)],
      ],
    ),
  );
  expect(judged.stray).toEqual([
    { label: "article.acpmux-row[row thinking-live]", frame: 1, dx: 0, dy: 247, follow: 0 },
  ]);
});

test("a settle after the follow stopped is a stray move: the rows move again, by a follow of their own", () => {
  // A glide lands, the rows hold, then one row under the place moves 8 px while the rest hold.
  const judged = judgeFollowFrames(
    frames(
      [
        [1, row("a", 100)],
        [2, row("b", 200)],
        [3, row("c", 300)],
      ],
      [
        [1, row("a", 100)],
        [2, row("b", 200)],
        [3, row("c", 300)],
      ],
      [
        [1, row("a", 100)],
        [2, row("b", 208)],
        [3, row("c", 300)],
      ],
    ),
  );
  expect(judged.stray).toEqual([{ label: "article.acpmux-row[row b]", frame: 2, dx: 0, dy: 8, follow: 0 }]);
});

test("the composer moving is a stray move even when it moves by the follow", () => {
  const judged = judgeFollowFrames(
    frames(
      [
        [1, row("a", 100)],
        [9, composer(520)],
      ],
      [
        [1, row("a", 80)],
        [9, composer(500)],
      ],
    ),
  );
  expect(judged.stray.map((move) => move.label)).toEqual(["div.acpmux-composer-box"]);
});

test("a composer that shrinks over its held bottom edge (a sent draft) does not move", () => {
  const shrunk: BoxSample = { ...composer(565), box: { x: 0, y: 565, width: 800, height: 35 } };
  const judged = judgeFollowFrames(
    frames(
      [
        [1, row("a", 100)],
        [9, composer(520)],
      ],
      [
        [1, row("a", 60)],
        [9, shrunk],
      ],
    ),
  );
  expect(judged.strayFrames).toBe(0);
});

test("rows that rise and drop back the next frame bounced, though they moved together", () => {
  // A send: the rows rise by the prompt, and a frame late drop by the composer's lift.
  const judged = judgeFollowFrames(
    frames(
      [
        [1, row("a", 300)],
        [2, row("b", 400)],
      ],
      [
        [1, row("a", 125)],
        [2, row("b", 225)],
      ],
      [
        [1, row("a", 171)],
        [2, row("b", 271)],
      ],
    ),
  );
  expect(judged.stray).toEqual([{ label: FOLLOW_REVERSED, frame: 2, dx: 0, dy: 46, follow: -175 }]);
  // A follow that keeps rising, frame after frame, is the follow.
  const rising = judgeFollowFrames(
    frames([[1, row("a", 300)]], [[1, row("a", 280)]], [[1, row("a", 280)]], [[1, row("a", 250)]]),
  );
  expect(rising.strayFrames).toBe(0);
});

test("a sideways move is a stray move", () => {
  const judged = judgeFollowFrames(
    frames([[1, row("a", 100)]], [[1, { ...row("a", 100), box: { x: 12, y: 100, width: 800, height: 40 } }]]),
  );
  expect(judged.stray).toEqual([{ label: "article.acpmux-row[row a]", frame: 1, dx: 12, dy: 0, follow: 0 }]);
});

test("another tracked box moves by the follow or not at all", () => {
  const option = (y: number): BoxSample => ({ box: { x: 0, y, width: 200, height: 20 }, label: "button[option]" });
  const steady = judgeFollowFrames(
    frames(
      [
        [1, row("a", 100)],
        [5, option(110)],
        [6, option(500)],
      ],
      [
        [1, row("a", 70)],
        [5, option(80)],
        [6, option(500)],
      ],
    ),
  );
  expect(steady.strayFrames).toBe(0);
  const off = judgeFollowFrames(
    frames(
      [
        [1, row("a", 100)],
        [5, option(110)],
      ],
      [
        [1, row("a", 70)],
        [5, option(95)],
      ],
    ),
  );
  expect(off.stray.map((move) => move.label)).toEqual(["button[option]"]);
});

test("new, animating and targeted boxes, and a resize's first move, are not judged", () => {
  const judged = judgeFollowFrames(
    frames(
      [
        [1, row("a", 100)],
        [2, row("b", 200, { animating: true })],
        [3, row("c", 300, { targeted: true })],
      ],
      [
        [1, row("a", 100)],
        [2, row("b", 240, { animating: true })],
        [3, row("c", 330, { targeted: true })],
        [4, row("d", 400)],
      ],
    ),
  );
  expect(judged.movingFrames).toBe(0);
  const resized = frames(
    [
      [1, row("a", 100)],
      [2, row("b", 300)],
    ],
    [
      [1, row("a", 140)],
      [2, row("b", 300)],
    ],
    [
      [1, row("a", 150)],
      [2, row("b", 300)],
    ],
  );
  expect(judgeFollowFrames(resized, { firstMoveFree: true }).stray).toEqual([
    { label: "article.acpmux-row[row a]", frame: 2, dx: 0, dy: 10, follow: 0 },
  ]);
});

test("the shared follow is the dy most rows moved by, the smaller on a tie", () => {
  expect(sharedFollow([-40, -40.2, -32])).toBeCloseTo(-40, 0);
  expect(sharedFollow([-40, 0])).toBe(0);
  expect(sharedFollow([])).toBe(0);
});

// Painted frames, probed in Chromium at 760 px (y and height of each row; the `shown` box is the
// part that paints).
const tall = (name: string, y: number, height: number, extra: Partial<BoxSample> = {}): BoxSample =>
  row(name, y, { box: { x: 0, y, width: 800, height }, ...extra });

test("rows the turn's end fold slides to close the work's gap are its motion; a row that jumps is not", () => {
  // tool-toggle-motion#settle, painted frames 218 to 223: the work row between the reply and the
  // next answer goes, its copy fades in place, and the answer under it slides up over the copy on
  // the fold's own script animation (turnEndFold.ts): 295, 280.9, 273.1, 269.1. Nothing else moves.
  const fold = (folding: boolean) =>
    frames(
      ...[
        [-10.5, 23.5, 295],
        [-10.3, 23.7, 280.9],
        [-10.1, 23.9, 273.1],
        [-10.1, 23.9, 269.1],
      ].map(([header, reply, answer]): [number, BoxSample][] => [
        [1, tall("worked-live-user", header!, 34)],
        [2, tall("live-answer", reply!, 216.8)],
        [3, tall("live-answer-2", answer!, 1830.5, folding ? { folding: true } : {})],
      ]),
    );
  expect(judgeFollowFrames(fold(true))).toMatchObject({ strayFrames: 0, stray: [], worst: 0 });
  // The same slide with no fold playing it: the answer jumped up from the reply, 14 px a frame.
  const jumped = judgeFollowFrames(fold(false));
  expect(jumped.strayFrames).toBe(3);
  expect(jumped.stray[0]).toEqual({
    label: "article.acpmux-row[row live-answer-2]",
    frame: 1,
    dx: 0,
    dy: -14.1,
    follow: 0.2,
  });
  expect(jumped.worst).toBeCloseTo(14.3, 1);
});

/** send-stream-motion#tools-turn (follow-motion spring), painted frames 14 to 18 of the stream step:
 *  the chase raises the rows by 10.6, 8.6, 5.6 then 2.1 px; the pinned live line holds at 362.5; the
 *  reply over it is clipped at the line's drawn top (20, 10, then 1 px of its bottom), then let go
 *  while the chase brings it the last 7.7 px home over the line. */
const pinnedFrames = (options: { pinned: boolean; clipped: boolean; line?: number[] }) =>
  frames(
    ...[
      [176, 232, 284, 358.7, 20],
      [165.3, 221.3, 273.3, 348.1, 10],
      [156.7, 212.7, 264.7, 339.5, 1],
      [151.1, 207.1, 259.1, 333.9, 0],
      [149, 205, 257, 331.8, 0],
    ].map(([end, date, user, reply, cut], index): [number, BoxSample][] => [
      [6, tall("h6-end", end!, 32)],
      [9, tall("date-live-user", date!, 20)],
      [10, tall("live-user", user!, 42.8)],
      [
        12,
        tall(
          "live-answer",
          reply!,
          22.8,
          options.clipped && cut! > 0 ? { shown: { x: 0, y: reply!, width: 800, height: 22.8 - cut! } } : {},
        ),
      ],
      [11, tall("thinking-live", options.line?.[index] ?? 362.5, 32, options.pinned ? { pinned: true } : {})],
    ]),
  );

test("the pinned live line holds while the chase brings the reply home over it: no stray move", () => {
  expect(judgeFollowFrames(pinnedFrames({ pinned: true, clipped: true }))).toMatchObject({
    followFrames: 4,
    strayFrames: 0,
    stray: [],
  });
  // Taken while the chase was drawn away, it rides with the thread part of the way home.
  const riding = judgeFollowFrames(pinnedFrames({ pinned: true, clipped: true, line: [362.5, 360, 358, 356, 355] }));
  expect(riding.strayFrames).toBe(0);
});

test("a live line that holds while the rows rise strays when not pinned, or drops while pinned", () => {
  // No pin and no clip: the reply's box slides under the still line, which drops away from it.
  const loose = judgeFollowFrames(pinnedFrames({ pinned: false, clipped: false }));
  expect(loose.stray.map(({ label, frame, dy, follow }) => [label, frame, dy, follow])).toEqual([
    ["article.acpmux-row[row thinking-live]", 1, 0, -10.6],
    ["article.acpmux-row[row thinking-live]", 2, 0, -8.6],
    ["article.acpmux-row[row thinking-live]", 3, 0, -5.6],
    ["article.acpmux-row[row thinking-live]", 4, 0, -2.1],
  ]);
  // Pinned, but bobbing down on a glide of its own while the rows rise (the bob pinning removed).
  const bob = judgeFollowFrames(pinnedFrames({ pinned: true, clipped: true, line: [362.5, 366, 369, 369, 369] }));
  expect(bob.stray.map(({ label, frame, dy }) => [label, frame, dy])).toEqual([
    ["article.acpmux-row[row thinking-live]", 1, 3.5],
    ["article.acpmux-row[row thinking-live]", 2, 3],
  ]);
});

test("gaps are between painted edges: a row shown from under a clip moves the row under it by what shows", () => {
  // chat-motion-pass#mid-turn-send-before, painted frames 69 to 72 of the turn: the Working line
  // comes in over the reply, shown from under a clip that opens (10.8, 21.4, 29.3, 33.2 of its 34 px)
  // while the rows rise; the reply rides its painted bottom.
  const turn = (clipped: boolean) =>
    frames(
      ...[
        [60.6, 135.3, 10.8, 146.2, 194],
        [54.1, 128.9, 21.4, 150.3, 216.8],
        [32, 106.7, 29.3, 136, 216.8],
        [29, 103.8, 33.2, 137, 216.8],
      ].map(([user, working, shows, reply, height]): [number, BoxSample][] => [
        [9, tall("live-user", user!, 42.8)],
        [
          12,
          tall(
            "working-live-user",
            working!,
            34,
            clipped ? { shown: { x: 0, y: working!, width: 800, height: shows! } } : {},
          ),
        ],
        [11, tall("live-answer", reply!, height!)],
        [10, tall("thinking-live", 362.5, 32, { pinned: true })],
      ]),
    );
  expect(judgeFollowFrames(turn(true)).stray).toEqual([]);
  // Judged by its whole box, the Working line lies over the reply, which reads as jumping from it.
  expect(judgeFollowFrames(turn(false)).stray.map(({ label }) => label)).toContain(
    "article.acpmux-row[row live-answer]",
  );
});

/** A box in the model picker's scroller (`port`: its top and height), cut by it as Chromium paints it. */
const inPort = (label: string, y: number, height: number, port: [number, number], within?: number): BoxSample => {
  const top = Math.max(y, port[0]);
  const bottom = Math.min(y + height, port[0] + port[1]);
  return {
    box: { x: 200, y, width: 300, height },
    label,
    port: { x: 200, y: port[0], width: 300, height: port[1] },
    ...((top > y || bottom < y + height) && {
      shown: { x: 200, y: top, width: 300, height: Math.max(0, bottom - top) },
    }),
    ...(within !== undefined && { within }),
  };
};
const listbox = (y: number, height: number, port: [number, number]) =>
  inPort("div.acpmux-mp-models[listbox]", y, height, port);
const option = (y: number, port: [number, number]) => inPort("button.acpmux-mp-row[option]", y, 28, port, 10);

test("a popup that grows up from its held bottom edge, and the options in it, do not move", () => {
  // composer#model-menu-keyboard, painted frames 2048 to 2050: More models opens the picker's fold;
  // the popup grows from 220 to 354 px over its chip, its bottom held at 362, and its scroller from
  // 192 px at 170 to 326 px at 36. The listbox in it goes from 140 px at 170 (the scroller's room
  // under it empty) to 420 px at 36, cut at 362: its painted top rose 134 px and its bottom fell 52,
  // so neither of its own edges held; it kept its place in the scroller, whose bottom held. The
  // options rise with the listbox's top; the new ones arrive under them.
  const before: [number, number] = [170, 192];
  const after: [number, number] = [36, 326];
  const opened = judgeFollowFrames(
    frames(
      [
        [9, composer(368)],
        [10, listbox(170, 140, before)],
        [11, option(170, before)],
        [12, option(198, before)],
        [13, option(226, before)],
        [14, option(254, before)],
      ],
      [
        [9, composer(368)],
        [10, listbox(36, 420, after)],
        [11, option(36, after)],
        [12, option(64, after)],
        [13, option(92, after)],
        [14, option(120, after)],
        [15, option(148, after)],
        [16, option(176, after)],
      ],
    ),
  );
  expect(opened).toMatchObject({ movingFrames: 1, strayFrames: 0, stray: [] });
  // Arrow Down past the last row in view (painted frames 2064 to 2066), then past the last row to
  // the first (2068 to 2070): the list scrolls under the scroller, 28 px down then 66 back up; the
  // listbox's painted box holds and the options keep their places in it.
  const scrolled = judgeFollowFrames(
    frames(
      ...[26, -2, -30, 36].map((top): [number, BoxSample][] => [
        [10, listbox(top, 420, after)],
        [15, option(top + 112, after)],
        [16, option(top + 140, after)],
      ]),
    ),
  );
  expect(scrolled).toMatchObject({ movingFrames: 3, strayFrames: 0 });
});

test("a popup that jumps without resizing is a stray move, as is an option that jumps in its list", () => {
  // The scroller goes with the popup: the listbox keeps its place in it, but the scroller moved.
  const jumped = judgeFollowFrames(
    frames(
      [
        [10, listbox(170, 140, [170, 192])],
        [11, option(170, [170, 192])],
        [12, option(198, [170, 192])],
      ],
      [
        [10, listbox(36, 140, [36, 192])],
        [11, option(36, [36, 192])],
        [12, option(64, [36, 192])],
      ],
    ),
  );
  // The popup is named; its options went with it.
  expect(jumped.stray).toEqual([{ label: "div.acpmux-mp-models[listbox]", frame: 1, dx: 0, dy: -134, follow: 0 }]);
  expect(jumped.worst).toBe(134);
  // A listbox that grows with neither edge held, in a scroller that holds, moved off its place.
  const grown = judgeFollowFrames(frames([[10, listbox(170, 140, [0, 600])]], [[10, listbox(150, 200, [0, 600])]]));
  expect(grown.stray).toEqual([{ label: "div.acpmux-mp-models[listbox]", frame: 1, dx: 0, dy: -20, follow: 0 }]);
  // A scroller that grows with neither edge held moved its listbox too.
  const both = judgeFollowFrames(frames([[10, listbox(170, 140, [170, 192])]], [[10, listbox(150, 140, [150, 250])]]));
  expect(both.worst).toBe(20);
  const inList = judgeFollowFrames(
    frames(
      [
        [10, listbox(170, 140, [170, 192])],
        [11, option(170, [170, 192])],
        [12, option(198, [170, 192])],
      ],
      [
        [10, listbox(170, 140, [170, 192])],
        [11, option(170, [170, 192])],
        [12, option(210, [170, 192])],
      ],
    ),
  );
  expect(inList.stray).toEqual([{ label: "button.acpmux-mp-row[option]", frame: 1, dx: 0, dy: 12, follow: 0 }]);
});

test("the frame the pin lets go, and a call opened over the pinned line, are no stray move", () => {
  // send-stream-motion#steer-mid-stream (spring), painted frames 53 to 55: the rows rise 35.5 px as
  // the reply grows by a line and its clip goes; the line was pinned and holds; the gap between them
  // opens back to its rest under the reply (the clip had closed it to the line's top).
  const letGo = judgeFollowFrames(
    frames(
      [
        [10, tall("live-user", 126.2, 42.8)],
        [12, tall("live-answer", 201, 171.3, { shown: { x: 0, y: 201, width: 800, height: 161.3 } })],
        [11, tall("thinking-live", 362.5, 32, { pinned: true })],
      ],
      [
        [10, tall("live-user", 121.2, 42.8)],
        [12, tall("live-answer", 196, 171.3, { shown: { x: 0, y: 196, width: 800, height: 166.3 } })],
        [11, tall("thinking-live", 362.5, 32, { pinned: true })],
      ],
      [
        [10, tall("live-user", 85.8, 42.8)],
        [12, tall("live-answer", 160.5, 194)],
        [11, tall("thinking-live", 362.5, 32)],
      ],
    ),
  );
  expect(letGo).toMatchObject({ strayFrames: 0, stray: [] });
  // tool-toggle-motion: a call opened over the pinned line pushes it down by what opened.
  const pushed = judgeFollowFrames(
    frames(
      [
        [1, tall("call", 100, 22)],
        [2, tall("thinking-live", 130, 32, { pinned: true })],
      ],
      [
        [1, tall("call", 100, 172)],
        [2, tall("thinking-live", 280, 32, { pinned: true })],
      ],
    ),
  );
  expect(pushed.strayFrames).toBe(0);
  // Pushed down with nothing opened over it, it strays.
  const dropped = judgeFollowFrames(
    frames(
      [
        [1, tall("call", 100, 22)],
        [2, tall("thinking-live", 130, 32, { pinned: true })],
      ],
      [
        [1, tall("call", 100, 22)],
        [2, tall("thinking-live", 280, 32, { pinned: true })],
      ],
    ),
  );
  expect(dropped.stray).toEqual([
    { label: "article.acpmux-row[row thinking-live]", frame: 1, dx: 0, dy: 150, follow: 0 },
  ]);
});

test("rows the turn's end fold slides still turn the follow round: a bounce through a fold is a bounce", () => {
  // The rows rise by the follow, then the fold drops them back the next frame.
  const judged = judgeFollowFrames(
    frames(
      [
        [1, row("a", 300)],
        [2, row("b", 400)],
      ],
      [
        [1, row("a", 260)],
        [2, row("b", 360)],
      ],
      [
        [1, row("a", 290, { folding: true })],
        [2, row("b", 390, { folding: true })],
      ],
    ),
  );
  expect(judged.stray).toEqual([{ label: FOLLOW_REVERSED, frame: 2, dx: 0, dy: 30, follow: -40 }]);
});

test("a box whose clip takes all of it paints nothing and is not judged", () => {
  const judged = judgeFollowFrames(
    frames(
      [[1, tall("a", 100, 40, { shown: { x: 0, y: 100, width: 800, height: 0 } })]],
      [[1, tall("a", 160, 40, { shown: { x: 0, y: 160, width: 800, height: 0 } })]],
    ),
  );
  expect(judged.movingFrames).toBe(0);
});
