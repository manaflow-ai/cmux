// followGlide.ts: a followed reply's new line eases in within the live line's room, and nothing
// else glides. The live browser behaviour is in test/streaming-text-frames.test.ts.
import { expect, test } from "bun:test";
import type { AcpmuxRow, ConversationLayout } from "../model";
import { createFollowGlide, followRoom } from "./followGlide";

const layout = (heights: number[]): ConversationLayout => {
  const tops = new Float64Array(heights.length);
  let top = 0;
  heights.forEach((height, index) => {
    tops[index] = top;
    top += height;
  });
  return { tops, heights: Float64Array.from(heights), totalHeight: top };
};
const reply: AcpmuxRow = { id: "a", kind: "assistant", version: 3, at: 1, text: "Hello", streaming: true };
const line = (extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: "thinking-live",
  kind: "thinking",
  version: 1,
  at: 1,
  below: true,
  quietKey: "a:3",
  ...extra,
});

test("the room is the quiet live line under the reply, and nothing else", () => {
  expect(followRoom([reply, line()], layout([80, 40]))).toBe(40);
  // A line naming a call is shown, not waiting: the reply's text may not land on it.
  expect(followRoom([reply, line({ quietKey: undefined, doing: "Read file" })], layout([80, 40]))).toBe(0);
  // A line drawn above the turn's rows, or no line at all.
  expect(followRoom([reply, line({ below: undefined })], layout([80, 40]))).toBe(0);
  expect(followRoom([reply], layout([80]))).toBe(0);
});

/// A thread whose `animate` records each glide; `progress` is what the glide in flight reports.
function thread(motion: { reduce?: boolean; off?: boolean; token?: string } = {}) {
  const glides: { keyframes: Keyframe[]; options: KeyframeAnimationOptions; cancelled: boolean }[] = [];
  let progress = 0;
  const view = {
    matchMedia: () => ({ matches: motion.reduce === true }),
    getComputedStyle: () => ({ getPropertyValue: () => motion.token ?? "" }),
  };
  const node = {
    ownerDocument: { defaultView: view, documentElement: { dataset: motion.off ? { agentMotion: "off" } : {} } },
    closest: () => null,
    animate(keyframes: Keyframe[], options: KeyframeAnimationOptions) {
      const glide = { keyframes, options, cancelled: false };
      glides.push(glide);
      return {
        effect: { getComputedTiming: () => ({ progress }) },
        cancel: () => (glide.cancelled = true),
        onfinish: null,
      } as unknown as Animation;
    },
  } as unknown as HTMLElement;
  return { node, glides, at: (value: number) => (progress = value) };
}

test("a rise eases from where the reader saw the rows, at most the room, on the standard step", () => {
  const glide = createFollowGlide();
  const { node, glides, at } = thread();
  expect(glide.rise(node, 22.75, 40)).toBe(22.75);
  expect(glides[0]!.keyframes).toEqual([{ translate: "0 22.75px" }, { translate: "0 0" }]);
  expect(glides[0]!.options.duration).toBe(180);
  // Halfway through, the next line starts from what is still drawn back plus its own rise, capped.
  at(0.5);
  expect(glide.outstanding()).toBeCloseTo(11.375);
  expect(glide.rise(node, 22.75, 40)).toBeCloseTo(34.125);
  expect(glides[0]!.cancelled).toBe(true);
  at(0);
  expect(glide.rise(node, 22.75, 40)).toBe(40);
  glide.stop();
  expect(glides.at(-1)!.cancelled).toBe(true);
  expect(glide.outstanding()).toBe(0);
});

test("nothing glides for a fall, without room, or with motion off", () => {
  for (const motion of [{ reduce: true }, { off: true }, { token: "0ms" }]) {
    const { node, glides } = thread(motion);
    expect(createFollowGlide().rise(node, 22.75, 40)).toBe(0);
    expect(glides).toHaveLength(0);
  }
  const { node, glides } = thread();
  const glide = createFollowGlide();
  expect(glide.rise(node, -22.75, 40)).toBe(0);
  expect(glide.rise(node, 22.75, 0)).toBe(0);
  expect(glide.rise(null, 22.75, 40)).toBe(0);
  expect(glides).toHaveLength(0);
});

test("a glide stops once the room it lands in is smaller than what it still holds back", () => {
  const glide = createFollowGlide();
  const { node, glides, at } = thread();
  glide.rise(node, 22.75, 40);
  at(0.5);
  // Still room for the 11.4 px it holds back: it plays on.
  glide.fit(40);
  glide.fit(12);
  expect(glides[0]!.cancelled).toBe(false);
  // The live line came into view (a call started): no room under the reply, so the rows rest now.
  glide.fit(0);
  expect(glides[0]!.cancelled).toBe(true);
  expect(glide.outstanding()).toBe(0);
  glide.fit(0);
});
