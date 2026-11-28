// l10n-allow-file: test fixture labels, not shipped UI.
// A streamed token runs one placement pass (VirtualTranscript's notePinPass effect): it takes the pin
// (`pinLiveLine`), starts its tail glides, then draws the pin once (`refreshPinned`). Each draw reads
// every animation in the thread (`getAnimations({subtree: true})`), which grows with the rows a chat of
// short turns mounts: drawn in `pinLiveLine` too, a god chat's token read it twice (0.24 ms a token,
// the small chat none; bench/transcript-replay.bench.ts PAIRED=1 PROFILE_LINES=1). What the pin draws
// must not change: the line held back by the thread's offset, the row over it clipped there.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";
import { notePinPass, pinLiveLine, refreshPinned } from "../src/agent-session/acpmux/conversation/pinnedLiveLine";

test("a placement pass reads the thread's animations once and draws the pin as before", async () => {
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
  let reads = 0;
  thread.getAnimations = () => {
    reads += 1;
    return [];
  };
  // The chase draws the thread 20px back from its layout.
  thread.style.translate = "0 20px";
  const pass = () => {
    notePinPass(thread);
    pinLiveLine(thread, true);
    // (the pass's tail glides start here)
    refreshPinned(thread);
  };
  try {
    pass();
    expect(reads).toBe(1);
    for (let token = 0; token < 5; token += 1) pass();
    expect(reads).toBe(6);
    // Taken while the thread was drawn back, the line rides with it: nothing is held back yet.
    expect(line!.style.translate).toBe("");
    // The reply grows a line and the chase draws the thread further back: the line holds still (held
    // back by the 30px past its cap) and the row over it is clipped where the line's drawn top passes.
    thread.style.translate = "0 50px";
    pass();
    expect(reads).toBe(7);
    expect(line!.style.translate).toBe("0 -30px");
    expect(reply!.style.clipPath).toBe("inset(-4096px -4096px 30px -4096px)");
  } finally {
    pinLiveLine(thread, false);
    await settleReact();
    if (previous) Object.defineProperty(globalThis, "HTMLElement", previous);
    else Reflect.deleteProperty(globalThis, "HTMLElement");
    dom.window.close();
  }
});
