// A clip on the row above a glide ends with that glide. The tail glide clips a reply at the drawn top
// of the live line gliding down under it (tailGlide.ts), so no row draws over the next while a reply
// streams (Leo, 2026-11-11: "esp when it's lagging, there's a breif moment where ther'es overlapping
// text between the sent out text (from you) and the subequent tool calls/thinking"). When the reader
// scrolls up, both hold; a glide that leaves the view is dropped (`dropUnseen`). Its clip used to stay
// on the reply, still in view, so the reply's last lines were hidden over nothing once the live line
// had landed (review of cmux#41034: a held 44 px clip). Fake rows and animations: no browser needed.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Window } from "happy-dom";
import { createTailGlide } from "../src/agent-session/acpmux/conversation/tailGlide";

/// Events a browser dispatches later: the Web Animations API queues `cancel` and `finish` to the next
/// frame's update, never inside `cancel()`. Off, they dispatch at once (the tests below that need no
/// frame); `frame()` dispatches what waits.
let deferEvents = false;
const queued: (() => void)[] = [];
function frame() {
  for (const send of queued.splice(0)) send();
}

class FakeAnimation extends EventTarget {
  playState: "running" | "paused" | "finished" | "idle" = "running";
  currentTime: number | null = 0;
  constructor(
    readonly effect: { target: HTMLElement },
    readonly keyframes: Keyframe[],
  ) {
    super();
  }
  pause() {
    if (this.playState === "running") this.playState = "paused";
  }
  play() {
    if (this.playState === "paused") this.playState = "running";
  }
  cancel() {
    if (this.playState === "idle") return;
    this.playState = "idle";
    if (deferEvents) queued.push(() => this.dispatchEvent(new Event("cancel")));
    else this.dispatchEvent(new Event("cancel"));
  }
}

// Rows are elements, as the app's are (a check on the row's kind sees one); their layout is set here.
const dom = new Window();
// Bun names an Element of its own, which happy-dom's elements are not: the row's kind checks see
// happy-dom's while this file runs, and the globals come back after it.
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

const style = { getPropertyValue: () => "", translate: "none" };
const view = { getComputedStyle: () => style };
const doc = { defaultView: view };

type Row = HTMLElement & { animations: FakeAnimation[]; box: { top: number; bottom: number } };

function row(id: string, top: number, height: number): Row {
  const node = {
    dataset: { rowId: id },
    offsetTop: top,
    offsetHeight: height,
    ownerDocument: doc,
    animations: [] as FakeAnimation[],
    box: { top, bottom: top + height },
    querySelector: () => null,
    getBoundingClientRect() {
      return node.box as DOMRect;
    },
    animate(keyframes: Keyframe[]) {
      const animation = new FakeAnimation({ target: node as unknown as HTMLElement }, keyframes);
      node.animations.push(animation);
      return animation as unknown as Animation;
    },
  };
  Object.setPrototypeOf(node, dom.HTMLElement.prototype);
  return node as unknown as Row;
}

function thread(rows: Row[]): HTMLElement {
  return {
    ownerDocument: doc,
    animate: () => undefined,
    closest: () => null,
    querySelectorAll: () => rows,
  } as unknown as HTMLElement;
}

/// The reply grows by a line of 40 px; the live line under it glides down from where it was drawn,
/// and the reply is clipped where the live line is drawn. Then the reader takes the view.
function grownAndHeld() {
  const anchor = row("a", 0, 20);
  const reply = row("r", 20, 40);
  const live = row("l", 60, 30);
  const rows = [anchor, reply, live];
  const glide = createTailGlide();
  glide.place(thread(rows), true, "a");
  (reply as { offsetHeight: number }).offsetHeight = 80;
  (live as { offsetTop: number }).offsetTop = 100;
  glide.place(thread(rows), true, "a");
  const clip = reply.animations.find((animation) => "clipPath" in animation.keyframes[0]!);
  const slide = live.animations.find((animation) => "translate" in animation.keyframes[0]!);
  glide.hold();
  return { glide, reply, live, clip: clip!, slide: slide! };
}

describe("tail glide clip release", () => {
  test("a reply's clip ends when the glide under it is dropped out of view", () => {
    const { glide, reply, live, clip, slide } = grownAndHeld();
    expect(clip.keyframes[0]).toEqual({ clipPath: "inset(-4096px -4096px 40px -4096px)" });
    expect(clip.playState).toBe("paused");
    // The reader scrolled so the live line lies below the view and the reply still shows.
    reply.box = { top: 20, bottom: 100 };
    live.box = { top: 100, bottom: 130 };
    glide.dropUnseen({ top: 0, bottom: 90 } as DOMRect);
    expect(slide.playState).toBe("idle");
    expect(clip.playState).toBe("idle");
    expect(glide.moving()).toBe(false);
  });

  test("a reply's clip holds while the glide under it is still in view", () => {
    const { glide, reply, live, clip, slide } = grownAndHeld();
    reply.box = { top: 20, bottom: 100 };
    live.box = { top: 60, bottom: 90 };
    glide.dropUnseen({ top: 0, bottom: 200 } as DOMRect);
    expect(slide.playState).toBe("paused");
    expect(clip.playState).toBe("paused");
    glide.resume();
    expect(clip.playState).toBe("running");
  });

  test("a clipped row out of view never drops its clip while the glide it guards still shows", () => {
    const { glide, reply, live, clip, slide } = grownAndHeld();
    reply.box = { top: -100, bottom: -20 };
    live.box = { top: 0, bottom: 30 };
    glide.dropUnseen({ top: 0, bottom: 200 } as DOMRect);
    expect(slide.playState).toBe("paused");
    expect(clip.playState).toBe("paused");
  });

  test("a pass that moves the rows again keeps the new clip when the old glide's cancel event comes a frame later", () => {
    // The reply grows a line and the live line glides under it; before it lands the reply grows
    // again. The pass cancels the old glide and clip and starts both again from where they are
    // drawn; the old glide's `cancel` event comes in the next frame, as a browser sends it. It used
    // to cancel the new clip with it (both kept by the live line's row), and the reply drew over the
    // live line for the whole new glide (agent-pane-stream-row-overlap: 149 px under lag).
    deferEvents = true;
    try {
      const anchor = row("a", 0, 20);
      const reply = row("r", 20, 40);
      const live = row("l", 60, 30);
      const rows = [anchor, reply, live];
      const glide = createTailGlide();
      glide.place(thread(rows), true, "a");
      (reply as { offsetHeight: number }).offsetHeight = 80;
      (live as { offsetTop: number }).offsetTop = 100;
      glide.place(thread(rows), true, "a");
      const first = reply.animations.find((animation) => "clipPath" in animation.keyframes[0]!)!;
      (reply as { offsetHeight: number }).offsetHeight = 120;
      (live as { offsetTop: number }).offsetTop = 140;
      glide.place(thread(rows), true, "a");
      frame();
      const clips = reply.animations.filter((animation) => "clipPath" in animation.keyframes[0]!);
      const slides = live.animations.filter((animation) => "translate" in animation.keyframes[0]!);
      expect(first.playState).toBe("idle");
      expect(clips).toHaveLength(2);
      expect(slides).toHaveLength(2);
      expect(slides[1]!.playState).toBe("running");
      // The new clip covers the line the live line starts drawn over (these fake rows draw no
      // translate, so the old glide's remaining part reads as none).
      expect(clips[1]!.keyframes[0]).toEqual({ clipPath: "inset(-4096px -4096px 40px -4096px)" });
      expect(clips[1]!.playState).toBe("running");
      // It still ends with the glide it guards.
      glide.hold();
      reply.box = { top: 20, bottom: 140 };
      live.box = { top: 140, bottom: 170 };
      glide.dropUnseen({ top: 0, bottom: 130 } as DOMRect);
      expect(clips[1]!.playState).toBe("idle");
      frame();
      expect(glide.moving()).toBe(false);
    } finally {
      deferEvents = false;
      frame();
    }
  });
  /// The reply grows by 40 px over two live rows that both glide down: the nearer needs 40 px of clip,
  /// the farther (30 px further down) 10 px. Then the reader takes the view.
  function grownOverTwo() {
    const anchor = row("a", 0, 20);
    const reply = row("r", 20, 40);
    const near = row("n", 60, 30);
    const far = row("f", 90, 30);
    const rows = [anchor, reply, near, far];
    const glide = createTailGlide();
    glide.place(thread(rows), true, "a");
    (reply as { offsetHeight: number }).offsetHeight = 80;
    (near as { offsetTop: number }).offsetTop = 100;
    (far as { offsetTop: number }).offsetTop = 130;
    glide.place(thread(rows), true, "a");
    glide.hold();
    const clips = () => reply.animations.filter((animation) => "clipPath" in animation.keyframes[0]!);
    return { glide, reply, near, far, clips };
  }

  test("a clip shared by two glides stays while the nearer still glides and the farther is dropped", () => {
    const { glide, reply, near, far, clips } = grownOverTwo();
    const [clip] = clips();
    expect(clip!.keyframes[0]).toEqual({ clipPath: "inset(-4096px -4096px 40px -4096px)" });
    reply.box = { top: 20, bottom: 100 };
    near.box = { top: 100, bottom: 130 };
    far.box = { top: 130, bottom: 160 };
    glide.dropUnseen({ top: 0, bottom: 125 } as DOMRect);
    expect(far.animations[0]!.playState).toBe("idle");
    expect(near.animations[0]!.playState).toBe("paused");
    // Still 40 px over the nearer row, held where it was.
    expect(
      clips()
        .filter((each) => each.playState === "paused")
        .map((each) => each.keyframes[0]),
    ).toEqual([{ clipPath: "inset(-4096px -4096px 40px -4096px)" }]);
  });

  test("a clip goes on at the depth the rows left need when the row that set it is dropped", () => {
    const { glide, reply, near, far, clips } = grownOverTwo();
    const [clip] = clips();
    clip!.currentTime = 30;
    reply.box = { top: -120, bottom: -40 };
    near.box = { top: -40, bottom: -10 };
    far.box = { top: 0, bottom: 30 };
    glide.dropUnseen({ top: 0, bottom: 200 } as DOMRect);
    expect(near.animations[0]!.playState).toBe("idle");
    expect(far.animations[0]!.playState).toBe("paused");
    expect(clip!.playState).toBe("idle");
    const left = clips().filter((each) => each.playState !== "idle");
    expect(left.map((each) => [each.keyframes[0], each.playState, each.currentTime])).toEqual([
      [{ clipPath: "inset(-4096px -4096px 10px -4096px)" }, "paused", 30],
    ]);
  });
});
