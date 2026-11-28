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
    row.animations
      .slice()
      .reverse()
      .find((animation) => active(animation) && "translate" in animation.keyframes[0]!)?.keyframes[0]!.translate ??
      "none",
  );
const drawnTop = (row: Row) => row.offsetTop + (Number.parseFloat(translate(row).split(" ")[1] ?? "0") || 0);
const clipBottom = (row: Row) => {
  const clip = row.animations
    .slice()
    .reverse()
    .find((animation) => active(animation) && "clipPath" in animation.keyframes[0]!);
  return Number.parseFloat(String(clip?.keyframes[0]!.clipPath ?? "inset(0px 0px 0px 0px)").split(" ")[2]!);
};
const view = {
  requestAnimationFrame: (callback: FrameRequestCallback) => {
    frameCallbacks.push(callback);
    return frameCallbacks.length;
  },
  getComputedStyle: (row: Row) => ({
    getPropertyValue: () => "",
    translate: row.animations ? translate(row) : "none",
  }),
};
const frameCallbacks: FrameRequestCallback[] = [];
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
    getBoundingClientRect: () => ({
      top: drawnTop(node as unknown as Row),
      bottom: drawnTop(node as unknown as Row) + node.offsetHeight,
    }),
    animate(keyframes: Keyframe[]) {
      const animation = new FakeAnimation(keyframes);
      node.animations.push(animation);
      return animation as unknown as Animation;
    },
  };
  Object.setPrototypeOf(node, dom.HTMLElement.prototype);
  return node as unknown as Row;
}

function started(lowerWas = 60, upperHeight = 80, readView?: () => DOMRect | undefined) {
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
  const place = (layout: PlacedRows) =>
    glide.place(thread, true, "anchor", true, undefined, undefined, layout, readView);
  place(placed([0, 20, lowerWas], [20, 40, 30]));
  (upper as { offsetHeight: number }).offsetHeight = upperHeight;
  (lower as { offsetTop: number }).offsetTop = 120;
  const layout = placed([0, 20, 120], [20, upperHeight, 30]);
  place(layout);
  return { upper, lower, rows, glide, layout, place, thread };
}

test("growth after placement is clipped before the glide's first painted frame", () => {
  frameCallbacks.length = 0;
  const { upper, lower, rows, glide } = started(60, 72, () => ({ top: 0, bottom: 500 }) as DOMRect);
  try {
    expect(clipBottom(upper)).toBe(32);
    // A later layout in this rendering step grows the row after placement read its box.
    // No virtual placement or explicit refresh comes before the queued first-frame callback.
    (upper as { offsetHeight: number }).offsetHeight = 96;
    const pending = frameCallbacks.splice(0);
    expect(pending).toHaveLength(1);
    for (const callback of pending) callback(16);
    expect(clipBottom(upper)).toBe(56);
    expect(drawnTop(upper) + upper.offsetHeight - clipBottom(upper)).toBeLessThanOrEqual(drawnTop(lower));
    const animations = rows.flatMap((node) => node.animations.filter(active));
    const next = frameCallbacks.splice(0);
    expect(next).toHaveLength(1);
    for (const callback of next) callback(32);
    const after = rows.flatMap((node) => node.animations.filter(active));
    expect(after).toHaveLength(animations.length);
    for (let index = 0; index < animations.length; index++) expect(after[index]).toBe(animations[index]);
    expect(frameCallbacks).toHaveLength(0);
  } finally {
    glide.stop();
    frameCallbacks.length = 0;
  }
});

for (const mode of ["refresh", "held refresh", "pass without glide", "pass without anchor"] as const) {
  test(`DOM-only growth updates active clearance during ${mode}`, () => {
    const { upper, lower, rows, glide, layout, thread } = started();
    try {
      if (mode === "held refresh") glide.hold();
      (upper as { offsetHeight: number }).offsetHeight = 100;
      if (mode === "refresh" || mode === "held refresh") glide.refresh(thread);
      else glide.place(thread, mode !== "pass without glide", undefined, true, undefined, undefined, layout);
      expect(drawnTop(upper) + upper.offsetHeight - clipBottom(upper)).toBeLessThanOrEqual(drawnTop(lower));
      if (mode === "held refresh") {
        const animations = rows.flatMap((node) => node.animations.filter(active));
        expect(animations.length).toBeGreaterThan(0);
        expect(animations.every((animation) => animation.playState === "paused")).toBe(true);
      }
      glide.stop();
      glide.refresh(thread);
      expect(rows.flatMap((node) => node.animations.filter(active))).toHaveLength(0);
    } finally {
      glide.stop();
    }
  });
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

test("a reader-held glide keeps clearance when tracking stops", () => {
  const { upper, lower, rows, glide, layout, thread } = started();
  try {
    glide.hold();
    const held = rows.flatMap((node) => node.animations.filter(active));
    for (const animation of held) animation.currentTime = 23;
    glide.place(thread, false, undefined, false, undefined, undefined, layout);
    const unchanged = rows.flatMap((node) => node.animations.filter(active));
    expect(unchanged).toHaveLength(held.length);
    for (let index = 0; index < held.length; index++) expect(unchanged[index]).toBe(held[index]);
    for (const animation of held) expect(animation.currentTime).toBe(23);

    (upper as { offsetHeight: number }).offsetHeight = 100;
    glide.refresh(thread);
    expect(drawnTop(upper) + upper.offsetHeight - clipBottom(upper)).toBeLessThanOrEqual(drawnTop(lower));
    expect(
      rows.flatMap((node) => node.animations.filter(active)).every((animation) => animation.playState === "paused"),
    ).toBe(true);

    (upper as { offsetHeight: number }).offsetHeight = 112;
    (lower as { offsetTop: number }).offsetTop = 140;
    glide.place(thread, false, undefined, false, undefined, undefined, {
      ...layout,
      topAt: (index) => (index === 2 ? 140 : layout.topAt(index)),
    });
    // Tracking is off: the new placement cannot add a movement delta to the held glide.
    expect(drawnTop(lower)).toBe(80);
    expect(drawnTop(upper) + upper.offsetHeight - clipBottom(upper)).toBeLessThanOrEqual(drawnTop(lower));
    expect(
      rows.flatMap((node) => node.animations.filter(active)).every((animation) => animation.playState === "paused"),
    ).toBe(true);
    // An internal refresh passes track=true but must not consume the resume baseline.
    glide.refresh(thread);
    glide.resume();
    (lower as { offsetTop: number }).offsetTop = 160;
    glide.place(thread, true, "anchor", true, undefined, undefined, {
      ...layout,
      topAt: (index) => (index === 2 ? 160 : layout.topAt(index)),
    });
    expect(drawnTop(lower)).toBe(100);
    expect(
      rows.flatMap((node) => node.animations.filter(active)).every((animation) => animation.playState === "running"),
    ).toBe(true);
  } finally {
    glide.stop();
  }
});

test("an idle untracked pass reads no row geometry and starts no motion", () => {
  const { rows, glide, layout, thread } = started();
  glide.stop();
  let reads = 0;
  for (const node of rows) {
    const top = node.offsetTop;
    const height = node.offsetHeight;
    Object.defineProperty(node, "offsetTop", {
      get: () => {
        reads++;
        return top;
      },
    });
    Object.defineProperty(node, "offsetHeight", {
      get: () => {
        reads++;
        return height;
      },
    });
  }
  glide.place(thread, false, undefined, false, undefined, undefined, layout);
  glide.refresh(thread);
  expect(reads).toBe(0);
  expect(rows.flatMap((node) => node.animations.filter(active))).toHaveLength(0);
});
