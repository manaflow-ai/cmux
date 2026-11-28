// l10n-allow-file: test fixture labels, not shipped UI.
import { expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { JSDOM } from "jsdom";
import { importWithDom } from "./support/importWithDom";

const { drawPinned, pinLiveLine, refreshPinned } = await importWithDom(
  () => import("../src/agent-session/acpmux/conversation/pinnedLiveLine"),
);

test.each(["finish", "cancel"])("the pinned line clips a gliding reply and clears the clip on %s", async (event) => {
  const dom = new JSDOM(
    "<!doctype html><main><article>Reply</article><article data-row-id=thinking-live>Thinking</article></main>",
  );
  const previous = Object.getOwnPropertyDescriptor(globalThis, "HTMLElement");
  globalThis.HTMLElement = dom.window.HTMLElement;
  const thread = dom.window.document.querySelector<HTMLElement>("main")!;
  const [reply, line] = [...thread.children] as HTMLElement[];
  for (const [node, top] of [
    [reply!, 0],
    [line!, 100],
  ] as const) {
    node.className = "acpmux-row";
    Object.defineProperty(node, "offsetTop", { value: top });
    Object.defineProperty(node, "offsetHeight", { value: 100 });
    node.getAnimations = () => [];
  }
  let state = "running";
  const slide = Object.assign(new EventTarget(), {
    effect: { target: reply, getKeyframes: () => [{ translate: "0 16px" }, { translate: "0 0" }] },
  }) as unknown as Animation;
  Object.defineProperty(slide, "playState", { get: () => state });
  // The rows' animations come from one read of the thread's (each row's own read is a style check).
  let rowReads = 0;
  reply!.getAnimations = () => {
    rowReads += 1;
    return [slide];
  };
  thread.getAnimations = () => [slide];
  reply!.style.translate = "0 0";
  try {
    pinLiveLine(thread, true);
    reply!.style.translate = "0 16px";
    drawPinned(thread, 0);
    expect(reply!.style.clipPath).toBe("inset(-4096px -4096px 16px -4096px)");
    drawPinned(thread, 20);
    // The line starts 20px over the layout boundary; the reply is another 16px below its place.
    expect(reply!.style.clipPath).toBe("inset(-4096px -4096px 36px -4096px)");
    drawPinned(thread, 0);
    expect(reply!.style.clipPath).toBe("inset(-4096px -4096px 16px -4096px)");
    reply!.style.translate = "0 0";
    state = event === "finish" ? "finished" : "idle";
    slide.dispatchEvent(new Event(event));
    expect(reply!.style.clipPath).toBe("");
    expect(rowReads).toBe(0);
  } finally {
    pinLiveLine(thread, false);
    await settleReact();
    if (previous) Object.defineProperty(globalThis, "HTMLElement", previous);
    else Reflect.deleteProperty(globalThis, "HTMLElement");
    dom.window.close();
  }
});

for (const scenario of ["reply grows", "live top moves", "previously clear reply grows", "held reply grows"] as const) {
  test(`a pin refresh measures current clearance when ${scenario}`, async () => {
    const dom = new JSDOM(
      "<!doctype html><main><article>Reply</article><article data-row-id=thinking-live>Thinking</article></main>",
    );
    const previous = Object.getOwnPropertyDescriptor(globalThis, "HTMLElement");
    globalThis.HTMLElement = dom.window.HTMLElement;
    const thread = dom.window.document.querySelector<HTMLElement>("main")!;
    const [reply, line] = [...thread.children] as HTMLElement[];
    let height = scenario === "previously clear reply grows" ? 20 : 58;
    let top = 3593;
    let reads = 0;
    for (const node of [reply!, line!]) {
      node.className = "acpmux-row";
      Object.defineProperty(node, "offsetTop", {
        get: () => {
          reads++;
          return node === reply ? 3527 : top;
        },
      });
      Object.defineProperty(node, "offsetHeight", {
        get: () => {
          reads++;
          return node === reply ? height : 32;
        },
      });
      node.getAnimations = () => [];
    }
    thread.getAnimations = () => [];
    // A long mounted history must not turn this growth refresh into a transcript-wide read.
    for (let index = 0; index < 60; index++) {
      const older = dom.window.document.createElement("article");
      older.className = "acpmux-row";
      Object.defineProperty(older, "offsetTop", {
        get: () => {
          reads++;
          return index * 30;
        },
      });
      Object.defineProperty(older, "offsetHeight", {
        get: () => {
          reads++;
          return 30;
        },
      });
      reply!.before(older);
    }
    try {
      pinLiveLine(thread, true);
      thread.style.translate = "0 28.283092px";
      drawPinned(thread, 28.283092);
      expect(reply!.style.clipPath).toBe(
        scenario === "previously clear reply grows" ? "" : "inset(-4096px -4096px 21px -4096px)",
      );
      if (scenario === "held reply grows") {
        pinLiveLine(thread, false, true);
        // A held pin must keep its last draw even if another owner moves the thread.
        thread.style.translate = "0 80px";
      }
      if (scenario === "live top moves") top -= 35;
      else height = 93;
      reads = 0;
      refreshPinned(thread, true);
      expect(reply!.style.clipPath).toBe("inset(-4096px -4096px 56px -4096px)");
      expect(line!.style.translate).toBe("0 -28.283092px");
      expect(reads).toBeLessThanOrEqual(5);
      // The chase still uses the refreshed cache: no row measurements every animation frame.
      reads = 0;
      drawPinned(thread, scenario === "held reply grows" ? 80 : 28.283092);
      expect(reads).toBe(0);
      expect(line!.style.translate).toBe("0 -28.283092px");
      // Moving the line beyond the reply releases the old clip, including a held pin's clip.
      top = 3793;
      refreshPinned(thread, true);
      expect(reply!.style.clipPath).toBe("");
      expect(line!.style.translate).toBe("0 -28.283092px");
      pinLiveLine(thread, false);
      reads = 0;
      refreshPinned(thread, true);
      expect(reads).toBe(0);
    } finally {
      pinLiveLine(thread, false);
      await settleReact();
      if (previous) Object.defineProperty(globalThis, "HTMLElement", previous);
      else Reflect.deleteProperty(globalThis, "HTMLElement");
      dom.window.close();
    }
  });
}
