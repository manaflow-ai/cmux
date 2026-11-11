// The reader's fold (turnFold.ts): a copy of a row the close hid draws only outside the rows sliding
// over its place (`coverClip`), and keeps doing so when a later pass places those rows somewhere else
// (review of #41337: the reply retargeted from 100 to 80 px, its copy's clip still where it had been
// headed). Rows are happy-dom elements with their heights set here; animations are recorded.
import { expect, test } from "bun:test";
import { Window } from "happy-dom";
import { playTurnFold, type PlacedRows, type TurnFold } from "./turnFold";

type Played = { node: Element; keyframes: Keyframe[]; options: KeyframeAnimationOptions; cancelled: boolean };

function setup() {
  const dom = new Window();
  const document = dom.document;
  const played: Played[] = [];
  const proto = dom.HTMLElement.prototype as unknown as Record<string, unknown>;
  Object.defineProperty(proto, "offsetHeight", {
    configurable: true,
    get(this: Element) {
      return Number(this.getAttribute("data-h") ?? 0);
    },
  });
  proto.animate = function (this: Element, keyframes: Keyframe[], options: KeyframeAnimationOptions) {
    const entry: Played = { node: this, keyframes, options, cancelled: false };
    played.push(entry);
    return { cancel: () => (entry.cancelled = true), finish() {}, onfinish: null, oncancel: null };
  };
  const thread = document.createElement("div");
  document.body.appendChild(thread);
  const row = (id: string, index: number, height: number) => {
    const node = document.createElement("div");
    node.className = "acpmux-row";
    node.setAttribute("data-row-id", id);
    node.setAttribute("aria-posinset", String(index + 1));
    node.setAttribute("data-h", String(height));
    node.textContent = id;
    thread.appendChild(node);
    return node as unknown as HTMLElement;
  };
  return { thread: thread as unknown as HTMLElement, played, row };
}

const placedOf = (rows: [string, number][]): PlacedRows => ({
  count: rows.length,
  idAt: (index) => rows[index]?.[0],
  tops: rows.map(([, top]) => top),
});

/// The bottom inset of a clip-path keyframe.
const bottomOf = (frame: Keyframe) => Number(/inset\(\S+ \S+ (\S+)px/.exec(String(frame.clipPath))?.[1]);

test("a copy's clip follows the rows over it when a later pass places them somewhere else", () => {
  const { thread, played, row } = setup();
  // The toggled line at 0, a call (60 px tall) at 60, the reply at 120.
  row("line", 0, 60);
  const call = row("call", 1, 60);
  const reply = row("reply", 2, 40);
  const start = 1000;
  const fold: TurnFold = {
    id: "line",
    at: 0,
    opening: false,
    ms: 200,
    start,
    until: start + 300,
    startRows: placedOf([
      ["line", 0],
      ["call", 60],
      ["reply", 120],
    ]),
    startAt: 0,
    moving: new Map([
      [call, { id: "call", top: 60, delta: 0, reveal: false, animations: [] }],
      [reply, { id: "reply", top: 120, delta: 0, reveal: false, animations: [] }],
    ]),
    copies: new Map(),
    animations: new Set(),
  };
  const ghosts = new Set<HTMLElement>();
  // The close hides the call: the reply slides from 120 up to 100 over the call's copy (60 to 120).
  call.remove();
  reply.setAttribute("aria-posinset", "2");
  expect(
    playTurnFold(
      fold,
      thread,
      placedOf([
        ["line", 0],
        ["reply", 100],
      ]),
      undefined,
      ghosts,
      start,
    ),
  ).toBe(true);
  const [ghost] = [...ghosts];
  expect(ghost).toBeDefined();
  const clips = () => played.filter((entry) => entry.node === (ghost as unknown) && "clipPath" in entry.keyframes[0]!);
  expect(clips()).toHaveLength(1);
  expect(clips()[0]!.keyframes.map(bottomOf)).toEqual([0, 20]);
  // A pass part way through places the reply higher, at 80 (a row above it went): its move retargets,
  // and the copy's clip goes with it, on the same clock (part way, as the reply's own move).
  expect(
    playTurnFold(
      fold,
      thread,
      placedOf([
        ["line", 0],
        ["reply", 80],
      ]),
      undefined,
      ghosts,
      start + 50,
    ),
  ).toBe(true);
  expect(clips()).toHaveLength(2);
  const [old, now] = clips();
  expect(old!.cancelled).toBe(true);
  expect(now!.cancelled).toBe(false);
  expect(now!.keyframes.map(bottomOf)).toEqual([0, 40]);
  const replyMove = played.filter((entry) => entry.node === (reply as unknown) && !entry.cancelled).at(-1)!;
  expect(replyMove.keyframes[0]!.translate).toBe("0 40px");
  expect(now!.options.delay).toBe(replyMove.options.delay);
  expect(now!.options.delay).toBe(-50);
  expect(now!.options.easing).toBe(replyMove.options.easing);
  expect(now!.options.duration).toBe(200);
  // A pass that moves nothing plays nothing again.
  playTurnFold(
    fold,
    thread,
    placedOf([
      ["line", 0],
      ["reply", 80],
    ]),
    undefined,
    ghosts,
    start + 60,
  );
  expect(clips()).toHaveLength(2);
});

test("a copy stays clipped under a row that left mid-fold and slides over it as a copy", () => {
  const { thread, played, row } = setup();
  row("line", 0, 60);
  const call = row("call", 1, 60);
  const reply = row("reply", 2, 40);
  const start = 1000;
  const fold: TurnFold = {
    id: "line",
    at: 0,
    opening: false,
    ms: 200,
    start,
    until: start + 300,
    startRows: placedOf([
      ["line", 0],
      ["call", 60],
      ["reply", 120],
    ]),
    startAt: 0,
    moving: new Map([
      [call, { id: "call", top: 60, delta: 0, reveal: false, animations: [] }],
      [reply, { id: "reply", top: 120, delta: 0, reveal: false, animations: [] }],
    ]),
    copies: new Map(),
    animations: new Set(),
  };
  const ghosts = new Set<HTMLElement>();
  // The close hides the call: the reply slides from 120 up to 100 over the call's copy.
  call.remove();
  reply.setAttribute("aria-posinset", "2");
  playTurnFold(
    fold,
    thread,
    placedOf([
      ["line", 0],
      ["reply", 100],
    ]),
    undefined,
    ghosts,
    start,
  );
  const [callCopy] = [...ghosts];
  const clipsOf = (node: unknown) => played.filter((entry) => entry.node === node && "clipPath" in entry.keyframes[0]!);
  expect(clipsOf(callCopy).map((entry) => entry.keyframes.map(bottomOf))).toEqual([[0, 20]]);
  // Part way, the reply leaves too (its row goes): it becomes a copy that goes on sliding from 120 to
  // 100, on the fold's clock, over the call's copy. The call's copy keeps its clip until it has passed.
  reply.remove();
  playTurnFold(fold, thread, placedOf([["line", 0]]), undefined, ghosts, start + 50);
  const replyCopy = [...ghosts].find((ghost) => ghost !== callCopy)!;
  expect(replyCopy).toBeDefined();
  const replyMove = played.find((entry) => entry.node === (replyCopy as unknown))!;
  expect(replyMove.keyframes[0]!.translate).toBe("0 20px");
  expect(replyMove.keyframes.at(-1)!.translate).toBe("0 0px");
  const callClips = clipsOf(callCopy);
  expect(callClips).toHaveLength(1);
  expect(callClips[0]!.cancelled).toBe(false);
  expect(callClips[0]!.keyframes.map(bottomOf)).toEqual([0, 20]);
  // The reply's copy draws over the call's: nothing clips it.
  expect(clipsOf(replyCopy)).toHaveLength(0);
});
