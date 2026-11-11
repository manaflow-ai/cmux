// A row the tail glide moves down never draws over the row above it (conversation/tailGlide.ts; Leo,
// 2026-11-11: "esp when it's lagging, there's a breif moment where ther'es overlapping text between
// the sent out text (from you) and the subequent tool calls/thinking"). The reply grows a line while
// the view follows: the live line under it glides down from where it was, and the reply's bottom is
// cut back to the live line's drawn top, uncovered on the same step and curve.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=thread></div>", { pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const saved = ["window", "document", "HTMLElement", "Element"].map((key) => [key, scope[key]] as const);
Object.assign(scope, {
  window: dom.window,
  document: dom.window.document,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
});
(dom.window as unknown as { matchMedia: unknown }).matchMedia = () => ({
  matches: false,
  addEventListener() {},
  removeEventListener() {},
});
afterAll(() => {
  for (const [key, value] of saved) scope[key] = value;
});

const { createTailGlide } = await import("../src/agent-session/acpmux/conversation/tailGlide");

type Played = { node: Element; keyframes: Keyframe[]; options: KeyframeAnimationOptions };
const played: Played[] = [];
/// Each row's layout box, which a test changes between passes.
const boxes = new Map<Element, { top: number; height: number }>();
const proto = dom.window.HTMLElement.prototype as unknown as Record<string, unknown>;
proto.animate = function (this: Element, keyframes: Keyframe[], options: KeyframeAnimationOptions) {
  played.push({ node: this, keyframes, options });
  return { addEventListener() {}, cancel() {}, pause() {}, play() {}, playState: "running" };
};
for (const [name, read] of [
  ["offsetTop", (box: { top: number }) => box.top],
  ["offsetHeight", (box: { height: number }) => box.height],
] as const)
  Object.defineProperty(proto, name, {
    configurable: true,
    get(this: Element) {
      const box = boxes.get(this);
      return box ? read(box) : 0;
    },
  });
proto.getBoundingClientRect = function (this: Element) {
  const top = boxes.get(this)?.top ?? 0;
  return { top, bottom: top, left: 0, right: 0, width: 0, height: 0 };
};

const thread = dom.window.document.getElementById("thread")!;
const row = (id: string, top: number, height: number) => {
  const node = dom.window.document.createElement("div");
  node.className = "acpmux-row";
  node.dataset.rowId = id;
  thread.append(node);
  boxes.set(node, { top, height });
  return node;
};

test("the reply grows a line: the row under it glides down and the reply's bottom is uncovered with it", () => {
  const prompt = row("prompt", 0, 40);
  const reply = row("reply", 40, 100);
  const call = row("call", 140, 28);
  const glide = createTailGlide();
  glide.place(thread, true, "prompt");
  // The reply's next line lands: 20 px taller, the call under it pushed down by as much.
  boxes.set(reply, { top: 40, height: 120 });
  boxes.set(call, { top: 160, height: 28 });
  glide.place(thread, true, "prompt");
  const move = played.find((entry) => entry.node === call)!;
  expect(move.keyframes[0]).toEqual({ translate: "0 -20px" });
  const cut = played.find((entry) => entry.node === reply)!;
  // Cut back by exactly where the call is drawn, ending uncut, on the call's own step and curve.
  expect(cut.keyframes).toEqual([{ clipPath: "inset(-100vh -100vw 20px)" }, { clipPath: "inset(-100vh -100vw 0px)" }]);
  expect(cut.options.duration).toBe(move.options.duration);
  expect(cut.options.easing).toBe(move.options.easing);
  // Nothing above the change is cut.
  expect(played.some((entry) => entry.node === prompt)).toBe(false);
  glide.stop();
  thread.replaceChildren();
  played.length = 0;
});

test("a row gliding up never cuts the row above it", () => {
  row("prompt", 0, 40);
  const reply = row("reply", 40, 120);
  const call = row("call", 160, 28);
  const glide = createTailGlide();
  glide.place(thread, true, "prompt");
  boxes.set(reply, { top: 40, height: 100 });
  boxes.set(call, { top: 140, height: 28 });
  glide.place(thread, true, "prompt");
  expect(played.find((entry) => entry.node === call)!.keyframes[0]).toEqual({ translate: "0 20px" });
  expect(played.some((entry) => entry.node === reply)).toBe(false);
  glide.stop();
  thread.replaceChildren();
  played.length = 0;
});
