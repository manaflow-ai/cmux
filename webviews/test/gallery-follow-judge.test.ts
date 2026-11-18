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
