// CMUX-896: a reply can mount while an earlier footer still glides through its place.
// Unchanged existing placements must still refresh clipping against that new row.
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

for (const stage of [
  { name: "new motion", glide: true, anchor: "anchor" },
  { name: "no new motion", glide: false, anchor: "anchor" },
  { name: "no new anchor", glide: false, anchor: undefined },
  { name: "captured anchor removed", glide: false, anchor: undefined, removeAnchor: true },
])
  test(`a newly mounted reply stays clear of an active retained-row glide (${stage.name})`, () => {
    const anchor = row("anchor", 0, 20);
    const footer = row("worked", 300, 40);
    const reply = row("answer-new", 140, 126);
    const thread = { ownerDocument: doc, animate: () => undefined, closest: () => null } as unknown as HTMLElement;
    const placed = (rows: Row[], tops: number[]): PlacedRows => ({
      idAt: (index) => rows[index]?.dataset.rowId,
      indexOf: (id) => rows.findIndex((node) => node.dataset.rowId === id),
      topAt: (index) => tops[index] ?? 0,
      heightAt: (index) => rows[index]?.offsetHeight ?? 0,
      rowAt: (index) => rows[index],
      mounted: [{ first: 0, last: rows.length }],
    });
    const glide = createTailGlide();
    const place = (layout: PlacedRows) => glide.place(thread, true, "anchor", true, undefined, undefined, layout);
    try {
      place(placed([anchor, footer], [0, 300]));
      (footer as { offsetTop: number }).offsetTop = 100;
      place(placed([anchor, footer], [0, 100]));
      expect(drawnTop(footer)).toBe(300);
      // Sample the glide at the retained footer's observed offset before the assistant mounts.
      const slide = footer.animations.find((animation) => active(animation) && "translate" in animation.keyframes[0]!);
      slide!.keyframes[0]!.translate = "0 76px";
      glide.place(
        thread,
        stage.glide,
        stage.anchor,
        true,
        undefined,
        undefined,
        stage.removeAnchor ? placed([footer, reply], [100, 140]) : placed([anchor, footer, reply], [0, 100, 140]),
      );
      const visibleBottom = drawnTop(footer) + footer.offsetHeight - clipBottom(footer);
      const overlap =
        Math.min(visibleBottom, reply.offsetTop + reply.offsetHeight) - Math.max(drawnTop(footer), reply.offsetTop);
      console.log(
        `tail-glide-arrival-clearance ${JSON.stringify({ visibleBottom, replyTop: reply.offsetTop, overlap, clip: clipBottom(footer) })}`,
      );
      expect(overlap).toBeLessThanOrEqual(0);
      expect(drawnTop(reply)).toBe(reply.offsetTop);
      for (const node of [anchor, footer, reply])
        for (const animation of node.animations.filter(active)) animation.finish();
      expect(clipBottom(footer)).toBe(0);
      expect(glide.moving()).toBe(false);
    } finally {
      glide.stop();
    }
  });
