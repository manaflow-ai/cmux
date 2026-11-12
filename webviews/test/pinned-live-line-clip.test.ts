// l10n-allow-file: test fixture labels, not shipped UI.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { drawPinned, pinLiveLine } from "../src/agent-session/acpmux/conversation/pinnedLiveLine";

test("the pinned line clips a reply's gliding position, not just its layout bottom", () => {
  const dom = new JSDOM(
    "<!doctype html><main><article>Reply</article><article data-row-id=thinking-live>Thinking</article></main>",
  );
  const previous = globalThis.HTMLElement;
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
  const slide = {
    playState: "running",
    effect: { getKeyframes: () => [{ translate: "0 16px" }, { translate: "0 0" }] },
  } as unknown as Animation;
  reply!.getAnimations = () => [slide];
  reply!.style.translate = "0 0";
  try {
    pinLiveLine(thread, true);
    reply!.style.translate = "0 16px";
    drawPinned(thread, 0);
    expect(reply!.style.clipPath).toBe("inset(-4096px -4096px 16px -4096px)");
    drawPinned(thread, 20);
    // The line starts 20px over the layout boundary; the reply is another 16px below its place.
    expect(reply!.style.clipPath).toBe("inset(-4096px -4096px 36px -4096px)");
    reply!.style.translate = "0 0";
    drawPinned(thread, 0);
    expect(reply!.style.clipPath).toBe("");
  } finally {
    pinLiveLine(thread, false);
    globalThis.HTMLElement = previous;
    dom.window.close();
  }
});
