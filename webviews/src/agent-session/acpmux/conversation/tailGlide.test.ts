// tailGlide.ts: the live line, the thread's last row, holds where it was drawn against what the follow
// chase moved the rows by at once in a pass (`jumped`), so it never rises into the rest gap under the
// bottom stack. The live browser behaviour is in test/agent-pane-composer-rest-gap.test.ts.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { foldMotion } from "./fold";
import { createTailGlide } from "./tailGlide";
import { LIVE_THINKING } from "./turns";

const motion = { ...foldMotion };
beforeAll(() => {
  foldMotion.duration = () => 180;
  foldMotion.reducedMotion = () => false;
});
afterAll(() => Object.assign(foldMotion, motion));

type Played = { id: string; keyframes: Keyframe[] };

/// A thread of rows laid out top to bottom at `heights`, each `animate` call recorded.
function fixture(ids: string[], heights: number[]) {
  const played: Played[] = [];
  const view = { getComputedStyle: () => ({ getPropertyValue: () => "", translate: "none" }) };
  const doc = { defaultView: view };
  const animation = () => {
    const self = {
      playState: "running",
      currentTime: 0,
      cancel: () => (self.playState = "idle"),
      pause: () => (self.playState = "paused"),
      play: () => (self.playState = "running"),
      addEventListener: () => {},
    };
    return self;
  };
  const rows = ids.map((id) => {
    const row = {
      dataset: { rowId: id },
      offsetTop: 0,
      offsetHeight: 0,
      offsetParent: null,
      isConnected: true,
      ownerDocument: doc,
      querySelector: () => null,
      getBoundingClientRect: () => ({ top: row.offsetTop, bottom: row.offsetTop + row.offsetHeight }),
      animate: (keyframes: Keyframe[]) => {
        played.push({ id, keyframes });
        return animation();
      },
    };
    return row;
  });
  const lay = (next: number[]) => {
    let top = 0;
    rows.forEach((row, index) => {
      row.offsetTop = top;
      row.offsetHeight = next[index]!;
      top += next[index]!;
    });
  };
  lay(heights);
  const thread = {
    ownerDocument: doc,
    animate: () => animation(),
    closest: () => null,
    querySelectorAll: () => rows,
  } as unknown as HTMLElement;
  return { thread, played, lay };
}

const startOf = (played: Played[], id: string) => {
  const glide = played.find((each) => each.id === id && each.keyframes[0]?.translate !== undefined);
  return glide ? Number.parseFloat(String(glide.keyframes[0]!.translate).split(" ")[1]) : undefined;
};

test("a reply's growth glides the live line from where it was drawn, against the anchor", () => {
  const { thread, played, lay } = fixture(["anchor", "reply", LIVE_THINKING], [100, 44, 40]);
  const glide = createTailGlide();
  glide.place(thread, true, "anchor");
  lay([100, 66, 40]);
  glide.place(thread, true, "anchor");
  expect(startOf(played, LIVE_THINKING)).toBe(-22);
});

test("what the chase moved at once in the pass leaves the live line where it was drawn", () => {
  const { thread, played, lay } = fixture(["anchor", "reply", LIVE_THINKING], [100, 44, 40]);
  const glide = createTailGlide();
  glide.place(thread, true, "anchor");
  lay([100, 66, 40]);
  // The chase drew back 19 of the line's 22 px and moved 3 px at once: the rows rose 3 px.
  glide.jumped(-3);
  glide.place(thread, true, "anchor");
  expect(startOf(played, LIVE_THINKING)).toBe(-19);
  // The reply is clipped where the line is drawn over it, on the same clock.
  const clip = played.find((each) => each.id === "reply" && each.keyframes[0]?.clipPath !== undefined);
  expect(String(clip?.keyframes[0]?.clipPath)).toContain(" 19px ");
});

test("the jump is spent by the pass that takes it, and a last row that is not the live line moves with the rows", () => {
  const { thread, played, lay } = fixture(["anchor", "reply", LIVE_THINKING], [100, 44, 40]);
  const glide = createTailGlide();
  glide.place(thread, true, "anchor");
  lay([100, 66, 40]);
  glide.jumped(-3);
  // A pass that glides nothing (the view moved at once) still spends it.
  glide.place(thread, false, "anchor");
  lay([100, 88, 40]);
  glide.place(thread, true, "anchor");
  expect(startOf(played, LIVE_THINKING)).toBe(-22);

  const other = fixture(["anchor", "reply", "footer"], [100, 44, 24]);
  const glide2 = createTailGlide();
  glide2.place(other.thread, true, "anchor");
  other.lay([100, 66, 24]);
  glide2.jumped(-3);
  glide2.place(other.thread, true, "anchor");
  expect(startOf(other.played, "footer")).toBe(-22);
});
