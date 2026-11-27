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

test("a token that leaves the line in place keeps its pin; a move or a new row over it takes it again", async () => {
  const dom = new JSDOM(
    "<!doctype html><main><article>Reply</article><article data-row-id=thinking-live>Thinking</article></main>",
  );
  const previous = Object.getOwnPropertyDescriptor(globalThis, "HTMLElement");
  globalThis.HTMLElement = dom.window.HTMLElement;
  const thread = dom.window.document.querySelector<HTMLElement>("main")!;
  const [reply, line] = [...thread.children] as HTMLElement[];
  const tops = new Map<Element, number>([
    [reply!, 0],
    [line!, 100],
  ]);
  const heights = new Map<Element, number>([
    [reply!, 100],
    [line!, 40],
  ]);
  const withBox = (node: HTMLElement) => {
    node.className = "acpmux-row";
    Object.defineProperty(node, "offsetTop", { get: () => tops.get(node) ?? 0 });
    Object.defineProperty(node, "offsetHeight", { get: () => heights.get(node) ?? 0 });
    node.getAnimations = () => [];
  };
  withBox(reply!);
  withBox(line!);
  thread.getAnimations = () => [];
  let queries = 0;
  const query = thread.querySelector.bind(thread);
  thread.querySelector = ((selector: string) => ((queries += 1), query(selector))) as typeof thread.querySelector;
  // The line's translate written each pass: a pass that keeps the pin writes none.
  let writes = 0;
  const style = line!.style;
  const remove = style.removeProperty.bind(style);
  style.removeProperty = (name: string) => ((writes += 1), remove(name));
  const pass = () => {
    notePinPass(thread);
    pinLiveLine(thread, true);
  };
  try {
    pass();
    expect(queries).toBe(1);
    const taken = writes;
    for (let token = 0; token < 5; token += 1) pass();
    expect([queries, writes]).toEqual([1, taken]);
    // The reply grows a line: the line moves down and is taken again (its rows read anew).
    heights.set(reply!, 120);
    tops.set(line!, 120);
    pass();
    expect(writes).toBeGreaterThan(taken);
    // A row mounts over the line in its place: taken again.
    const after = writes;
    const tool = dom.window.document.createElement("article");
    tops.set(tool, 100);
    heights.set(tool, 20);
    withBox(tool);
    tops.set(reply!, 0);
    heights.set(reply!, 100);
    line!.before(tool);
    pass();
    expect(writes).toBeGreaterThan(after);
    // The line remounts as another element: found by its query.
    const remount = line!.cloneNode(true) as HTMLElement;
    withBox(remount);
    tops.set(remount, 120);
    line!.replaceWith(remount);
    pass();
    expect(queries).toBe(2);
  } finally {
    pinLiveLine(thread, false);
    await settleReact();
    if (previous) Object.defineProperty(globalThis, "HTMLElement", previous);
    else Reflect.deleteProperty(globalThis, "HTMLElement");
    dom.window.close();
  }
});
