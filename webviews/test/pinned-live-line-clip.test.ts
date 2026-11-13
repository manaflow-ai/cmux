// l10n-allow-file: test fixture labels, not shipped UI.
import { expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { JSDOM } from "jsdom";
import { drawPinned, pinLiveLine } from "../src/agent-session/acpmux/conversation/pinnedLiveLine";

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
    effect: { getKeyframes: () => [{ translate: "0 16px" }, { translate: "0 0" }] },
  }) as unknown as Animation;
  Object.defineProperty(slide, "playState", { get: () => state });
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
    drawPinned(thread, 0);
    expect(reply!.style.clipPath).toBe("inset(-4096px -4096px 16px -4096px)");
    reply!.style.translate = "0 0";
    state = event === "finish" ? "finished" : "idle";
    slide.dispatchEvent(new Event(event));
    expect(reply!.style.clipPath).toBe("");
  } finally {
    pinLiveLine(thread, false);
    await settleReact();
    if (previous) Object.defineProperty(globalThis, "HTMLElement", previous);
    else Reflect.deleteProperty(globalThis, "HTMLElement");
    dom.window.close();
  }
});
