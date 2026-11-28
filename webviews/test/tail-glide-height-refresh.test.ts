// CMUX-896: a row's DOM height can settle before its virtual placement changes. An active
// clip must refresh on that pass, even when every supplied row top stays unchanged.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { Window } from "happy-dom";
import { createTailGlide, type PlacedRows } from "../src/agent-session/acpmux/conversation/tailGlide";

class FakeAnimation extends EventTarget {
  playState: "running" | "paused" | "finished" | "idle" = "running";
  currentTime: number | null = 0;
  constructor(readonly keyframes: Keyframe[]) {
    super();
  }
  pause() {
    this.playState = "paused";
  }
  play() {
    this.playState = "running";
  }
  cancel() {
    if (this.playState === "idle") return;
    this.playState = "idle";
    this.dispatchEvent(new Event("cancel"));
  }
  finish() {
    this.playState = "finished";
    this.dispatchEvent(new Event("finish"));
  }
}

const dom = new Window();
const names = ["Element", "HTMLElement"] as const;
const saved = names.map((name) => [name, Object.getOwnPropertyDescriptor(globalThis, name)] as const);
beforeAll(() => {
  for (const name of names)
    Object.defineProperty(globalThis, name, {
      value: dom[name],
      configurable: true,
      writable: true,
    });
});
afterAll(() => {
  for (const [name, descriptor] of saved)
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else delete (globalThis as Record<string, unknown>)[name];
});

type Row = HTMLElement & { animations: FakeAnimation[] };
const active = (animation: FakeAnimation) => animation.playState === "running" || animation.playState === "paused";
const translate = (row: Row) =>
  String(
    row.animations.findLast((animation) => active(animation) && "translate" in animation.keyframes[0]!)?.keyframes[0]!
      .translate ?? "none",
  );
const drawnTop = (row: Row) => row.offsetTop + (Number.parseFloat(translate(row).split(" ")[1] ?? "0") || 0);
const clipBottom = (row: Row) => {
  const clip = row.animations.findLast((animation) => active(animation) && "clipPath" in animation.keyframes[0]!);
  return Number.parseFloat(String(clip?.keyframes[0]!.clipPath ?? "inset(0px 0px 0px 0px)").split(" ")[2]!);
};
const view = {
  getComputedStyle: (row: Row) => ({
    getPropertyValue: () => "",
    translate: row.animations ? translate(row) : "none",
  }),
};
const doc = { defaultView: view };
function row(id: string, top: number, height: number): Row {
  const node = {
    dataset: { rowId: id },
    offsetTop: top,
    offsetHeight: height,
    ownerDocument: doc,
    isConnected: true,
    animations: [] as FakeAnimation[],
    querySelector: () => null,
    animate(keyframes: Keyframe[]) {
      const animation = new FakeAnimation(keyframes);
      node.animations.push(animation);
      return animation as unknown as Animation;
    },
  };
  Object.setPrototypeOf(node, dom.HTMLElement.prototype);
  return node as unknown as Row;
}

function started(lowerWas = 60, upperHeight = 80) {
  const anchor = row("anchor", 0, 20);
  const upper = row("upper", 20, 40);
  const lower = row("lower", lowerWas, 30);
  const rows = [anchor, upper, lower];
  const thread = {
    ownerDocument: doc,
    animate: () => undefined,
    closest: () => null,
  } as unknown as HTMLElement;
  const placed = (tops: number[], heights: number[]): PlacedRows => ({
    idAt: (index) => rows[index]?.dataset.rowId,
    indexOf: (id) => rows.findIndex((node) => node.dataset.rowId === id),
    topAt: (index) => tops[index] ?? 0,
    heightAt: (index) => heights[index] ?? 0,
    rowAt: (index) => rows[index],
    mounted: [{ first: 0, last: rows.length }],
  });
  const glide = createTailGlide();
  const place = (layout: PlacedRows) => glide.place(thread, true, "anchor", true, undefined, undefined, layout);
  place(placed([0, 20, lowerWas], [20, 40, 30]));
  (upper as { offsetHeight: number }).offsetHeight = upperHeight;
  (lower as { offsetTop: number }).offsetTop = 120;
  const layout = placed([0, 20, 120], [20, upperHeight, 30]);
  place(layout);
  return { upper, lower, rows, glide, layout, place };
}

for (const stage of [
  {
    name: "refreshes an existing clip",
    lowerWas: 60,
    upperHeight: 80,
    grownHeight: 100,
    initialClip: 40,
  },
  {
    name: "adds a clip after an initially clear row grows",
    lowerWas: 80,
    upperHeight: 40,
    grownHeight: 80,
    initialClip: 0,
  },
]) {
  test(`a height-only pass ${stage.name} and releases clipping on completion`, () => {
    const { upper, lower, rows, glide, layout, place } = started(stage.lowerWas, stage.upperHeight);
    try {
      expect(clipBottom(upper)).toBe(stage.initialClip);
      expect(drawnTop(lower)).toBe(stage.lowerWas);

      // The DOM grows while the virtualizer still supplies exactly the same placement.
      (upper as { offsetHeight: number }).offsetHeight = stage.grownHeight;
      place(layout);
      const visibleBottom = drawnTop(upper) + upper.offsetHeight - clipBottom(upper);
      const lowerTop = drawnTop(lower);
      console.log(
        `tail-glide-height-refresh ${JSON.stringify({ case: stage.name, visibleBottom, lowerTop, overlap: visibleBottom - lowerTop, clip: clipBottom(upper) })}`,
      );
      expect(visibleBottom).toBeLessThanOrEqual(lowerTop);

      // Browser animations on this clock finish together, including the independent clip.
      const playing = rows.flatMap((node) => node.animations.filter(active));
      for (const animation of playing) if (active(animation)) animation.finish();
      expect(clipBottom(upper)).toBe(0);
      expect(rows.flatMap((node) => node.animations.filter(active))).toHaveLength(0);
      expect(glide.moving()).toBe(false);
      expect(upper.offsetTop + upper.offsetHeight).toBeLessThanOrEqual(lower.offsetTop);
    } finally {
      glide.stop();
    }
  });
}

test("a pass with unchanged placement and DOM geometry preserves active animation identities", () => {
  const { rows, glide, layout, place } = started();
  try {
    const animations = rows.flatMap((node) => node.animations.filter(active));
    expect(animations).toHaveLength(2);
    for (const animation of animations) animation.currentTime = 23;
    place(layout);
    const after = rows.flatMap((node) => node.animations.filter(active));
    expect(after).toHaveLength(animations.length);
    for (let index = 0; index < animations.length; index++) {
      expect(after[index]).toBe(animations[index]);
      expect(after[index]!.currentTime).toBe(23);
    }
  } finally {
    glide.stop();
  }
});
