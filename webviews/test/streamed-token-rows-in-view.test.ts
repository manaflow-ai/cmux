// A streamed token costs the same however many rows are in view (Leo, 2026-11-12, on long chats:
// "no perceivable difference", "infinite everything feels like nothing"; 2026-11-04: "never ...
// acceptable ... linear time growth degradation"). A chat of short turns mounts about 60 rows where a
// chat of long ones mounts 31 (bench/transcript-replay.bench.ts, FIXTURE=god against --turns 600), and
// each streamed thought token cost it more: every placement pass read every mounted row's box twice
// for the tail glide (tailGlide.ts: each row's top, then each row's bottom from the view's top on) and
// three times more for the pinned live line (pinnedLiveLine.ts: each row over it within a viewport).
// Here the same pass runs over 30 and over 60 rows and counts the layout reads: the glide reads its
// rows' places from the transcript's placement and the page only for the rows that move, and the pin
// reads only the rows its held place reaches, so both counts are equal. Fake rows: no browser needed.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Window } from "happy-dom";
import { drawPinned, pinLiveLine } from "../src/agent-session/acpmux/conversation/pinnedLiveLine";
import { createTailGlide, type PlacedRows } from "../src/agent-session/acpmux/conversation/tailGlide";
import { LIVE_THINKING } from "../src/agent-session/acpmux/conversation/turns";

const dom = new Window();
const saved = ["Element", "HTMLElement"].map(
  (name) => [name, Object.getOwnPropertyDescriptor(globalThis, name)] as const,
);
beforeAll(() => {
  for (const name of ["Element", "HTMLElement"] as const)
    Object.defineProperty(globalThis, name, { value: dom[name], configurable: true, writable: true });
});
afterAll(() => {
  for (const [name, descriptor] of saved)
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else delete (globalThis as Record<string, unknown>)[name];
});

/// Layout reads from script (offsetTop, offsetHeight), each of which lays the page out again after a write.
let reads = 0;
const computed = { getPropertyValue: () => "", translate: "none" };
const view = { innerHeight: 4000, getComputedStyle: () => computed };
const doc = { defaultView: view };

type Row = HTMLElement & { animations: Animation[]; place: { top: number; height: number } };

function styleOf(): CSSStyleDeclaration {
  const values: Record<string, string> = {};
  return new Proxy(values, {
    get: (target, key) =>
      key === "removeProperty"
        ? (name: string) => delete target[name === "clip-path" ? "clipPath" : name]
        : (target[key as string] ?? ""),
    set: (target, key, value) => {
      target[key as string] = String(value);
      return true;
    },
  }) as unknown as CSSStyleDeclaration;
}

function makeRow(id: string, top: number, height: number): Row {
  const node = {
    dataset: { rowId: id },
    place: { top, height },
    ownerDocument: doc,
    style: styleOf(),
    classList: { contains: (name: string) => name === "acpmux-row" },
    previousElementSibling: null as Row | null,
    animations: [] as Animation[],
    isConnected: true,
    querySelector: () => null,
    getAnimations: () => [],
    animate(keyframes: Keyframe[]) {
      const animation = Object.assign(new EventTarget(), {
        keyframes,
        playState: "running",
        effect: { target: node, getKeyframes: () => keyframes },
        cancel() {},
        pause() {},
        play() {},
      }) as unknown as Animation;
      node.animations.push(animation);
      return animation;
    },
  };
  Object.defineProperty(node, "offsetTop", {
    get: () => {
      reads += 1;
      return node.place.top;
    },
  });
  Object.defineProperty(node, "offsetHeight", {
    get: () => {
      reads += 1;
      return node.place.height;
    },
  });
  Object.setPrototypeOf(node, dom.HTMLElement.prototype);
  return node as unknown as Row;
}

const ROW = 20;

/// `count` rows of 20 px, the reply second to last and the live line last, as a followed chat of short
/// turns lays them out, all of them in view.
function chat(count: number) {
  const rows: Row[] = [];
  for (let index = 0; index < count; index++) {
    const id = index === count - 1 ? LIVE_THINKING : index === count - 2 ? "reply" : `row-${index}`;
    const row = makeRow(id, index * ROW, ROW);
    row.previousElementSibling = rows.at(-1) ?? null;
    rows.push(row);
  }
  const attrs = new Set<string>();
  const thread = {
    ownerDocument: doc,
    style: styleOf(),
    animate: () => undefined,
    closest: () => null,
    getAnimations: () => [],
    setAttribute: (name: string) => attrs.add(name),
    removeAttribute: (name: string) => attrs.delete(name),
    hasAttribute: (name: string) => attrs.has(name),
    querySelectorAll: () => rows,
    querySelector: (selector: string) => rows.find((row) => selector.includes(`"${row.dataset.rowId}"`)) ?? null,
  } as unknown as HTMLElement;
  /// The transcript's placement of the rows now, as VirtualTranscript passes it: read from no row.
  const placed = (): PlacedRows => {
    const at = rows.map((row) => ({ ...row.place }));
    return {
      idAt: (index) => rows[index]?.dataset.rowId,
      indexOf: (id) => rows.findIndex((row) => row.dataset.rowId === id),
      topAt: (index) => at[index]?.top ?? 0,
      heightAt: (index) => at[index]?.height ?? 0,
      mounted: [{ first: 0, last: rows.length }],
    };
  };
  const reply = rows.at(-2)!;
  const live = rows.at(-1)!;
  /// The reply grows by a line: the live line under it moves down by it.
  const grow = (by: number) => {
    reply.place.height += by;
    live.place.top += by;
  };
  return { rows, thread, placed, reply, live, grow };
}

function counted(run: () => void): number {
  reads = 0;
  run();
  return reads;
}

describe("a streamed token's layout reads do not follow the rows in view", () => {
  test("the tail glide: a pass that moves nothing, and one where the reply grows", () => {
    const passes = [30, 60].map((count) => {
      const { thread, placed, grow, reply, live, rows } = chat(count);
      const glide = createTailGlide();
      glide.place(thread, true, rows[0]!.dataset.rowId, true, undefined, undefined, placed());
      // A thought token: the live line's words change, no row moves.
      const still = counted(() =>
        glide.place(thread, true, rows[0]!.dataset.rowId, true, undefined, undefined, placed()),
      );
      grow(ROW);
      const moved = counted(() =>
        glide.place(thread, true, rows[0]!.dataset.rowId, true, undefined, undefined, placed()),
      );
      // The live line glides down from where it was drawn, and the reply is clipped over it meanwhile.
      const slide = live.animations.find(
        (each) => "translate" in (each as unknown as { keyframes: Keyframe[] }).keyframes[0]!,
      );
      const clip = reply.animations.find(
        (each) => "clipPath" in (each as unknown as { keyframes: Keyframe[] }).keyframes[0]!,
      );
      expect((slide as unknown as { keyframes: Keyframe[] } | undefined)?.keyframes[0]).toEqual({
        translate: `0 -${ROW}px`,
      });
      expect((clip as unknown as { keyframes: Keyframe[] } | undefined)?.keyframes[0]).toEqual({
        clipPath: `inset(-4096px -4096px ${ROW}px -4096px)`,
      });
      glide.stop();
      return { count, still, moved };
    });
    console.log(`PER-UPDATE tail glide reads ${JSON.stringify(passes)}`);
    expect(passes[1]!.still).toBe(passes[0]!.still);
    expect(passes[1]!.moved).toBe(passes[0]!.moved);
  });

  test("the pinned live line: a pass that pins it, and a chase frame that holds it back", () => {
    const passes = [30, 60].map((count) => {
      const { thread, reply } = chat(count);
      const pin = counted(() => pinLiveLine(thread, true));
      // The chase draws the thread back by half a line: the live line holds still, and the reply over it
      // is clipped where it would pass the line's top.
      const frame = counted(() => drawPinned(thread, ROW / 2));
      expect(reply.style.clipPath).toBe(`inset(-4096px -4096px ${ROW / 2}px -4096px)`);
      pinLiveLine(thread, false);
      return { count, pin, frame };
    });
    console.log(`PER-UPDATE pinned line reads ${JSON.stringify(passes)}`);
    expect(passes[1]!.pin).toBe(passes[0]!.pin);
    expect(passes[1]!.frame).toBe(passes[0]!.frame);
  });
});
