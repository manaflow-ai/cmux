// CMUX-896: a streamed commit can leave virtual tops unchanged while a mounted row grows.
// Exercise the real transcript fast path with an active glide; do not deliver its ResizeObserver.
// l10n-allow-file: test transcript text.
import { afterAll, expect, spyOn, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { installJsdomScroller } from "./support/jsdomScroller";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
dom.window.document.documentElement.dataset.agentMotion = "off";

// No observer entry is delivered: the commit must repair clearance before observation.
class SilentResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}

const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: SilentResizeObserver,
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a row the test sizes lays out at that height; every other box is not laid out
// (no client rects), so it keeps its estimate.
const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => VIEWPORT);
const sized = new WeakMap<Element, number>();
const rect = (height: number) =>
  ({ top: 0, bottom: height, left: 0, right: 760, width: 760, height, x: 0, y: 0, toJSON() {} }) as DOMRect;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  if (this.classList.contains("acpmux-scroll")) return rect(VIEWPORT);
  const box = fakeGeometry.get(this);
  if (box) return { ...rect(box.height), top: box.top, bottom: box.top + box.height };
  return rect(sized.get(this) ?? 0);
};
dom.window.HTMLElement.prototype.getClientRects = function (this: HTMLElement) {
  const height = sized.get(this);
  return (height === undefined ? [] : [rect(height)]) as unknown as DOMRectList;
};

const tailModule = await import("../src/agent-session/acpmux/conversation/tailGlide");
const realCreate = tailModule.createTailGlide;
const glides: ReturnType<typeof realCreate>[] = [];
const factory = spyOn(tailModule, "createTailGlide").mockImplementation(() => {
  const glide = realCreate();
  glides.push(glide);
  return glide;
});
const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
const { acpmuxPerf } = await import("../src/agent-session/acpmux/perf");
const { openSettled } = await import("./support/openSettled");

afterAll(async () => {
  factory.mockRestore();
  await teardownDom(saved, { window: dom.window, scope });
});

class FakeAnimation extends EventTarget {
  playState: "running" | "paused" | "finished" | "idle" = "running";
  currentTime = 0;
  constructor(
    readonly effect: { target: HTMLElement },
    readonly keyframes: Keyframe[],
  ) {
    super();
  }
  cancel() {
    this.playState = "idle";
    this.dispatchEvent(new Event("cancel"));
  }
  pause() {
    this.playState = "paused";
  }
  play() {
    this.playState = "running";
  }
}
const animations = new WeakMap<HTMLElement, FakeAnimation[]>();
const active = (node: HTMLElement) =>
  (animations.get(node) ?? []).filter((one) => one.playState !== "idle" && one.playState !== "finished");
const fakeGeometry = new WeakMap<HTMLElement, { top: number; height: number }>();
Object.defineProperty(dom.window.HTMLElement.prototype, "offsetTop", {
  configurable: true,
  get(this: HTMLElement) {
    return fakeGeometry.get(this)?.top ?? 0;
  },
});
Object.defineProperty(dom.window.HTMLElement.prototype, "offsetHeight", {
  configurable: true,
  get(this: HTMLElement) {
    return fakeGeometry.get(this)?.height ?? 0;
  },
});
dom.window.HTMLElement.prototype.animate = function (this: HTMLElement, frames: Keyframe[] | PropertyIndexedKeyframes) {
  const animation = new FakeAnimation({ target: this }, frames as Keyframe[]);
  animations.set(this, [...(animations.get(this) ?? []), animation]);
  return animation as unknown as Animation;
};
const getStyle = dom.window.getComputedStyle.bind(dom.window);
dom.window.getComputedStyle = ((node: HTMLElement) => {
  const style = getStyle(node);
  const slide = active(node).find((one) => "translate" in one.keyframes[0]!);
  if (slide) Object.defineProperty(style, "translate", { value: slide.keyframes[0]!.translate });
  return style;
}) as typeof dom.window.getComputedStyle;
const clip = (node: HTMLElement) => {
  const animation = active(node)
    .filter((one) => "clipPath" in one.keyframes[0]!)
    .at(-1);
  return animation ? Number.parseFloat(String(animation.keyframes[0]!.clipPath).split(" ")[2]!) : 0;
};

const row = (id: string, kind: string, text: string, version = 1): AcpmuxRow => ({ id, kind, text, version, at: 1 });
const history = Array.from({ length: 40 }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.`),
]).flat();

test("an unchanged-placement transcript commit refreshes active clearance before ResizeObserver delivery", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (version: number) => {
    const rows = [...history.slice(0, -1), row("t39-answer", "assistant", "Answer 39.", version)];
    root.render(
      <VirtualTranscript rows={turnView(rows, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
    );
  };
  let marker: ReturnType<typeof spyOn> | undefined;
  try {
    await act(async () => render(1));
    await openSettled(dom.window);
    const nodes = ["t38-answer", "t39-user", "t39-answer"].map((id) =>
      dom.window.document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${id}"]`)!,
    );
    for (const node of nodes) expect(node).not.toBeNull();
    const [anchor, upper, lower] = nodes as [HTMLElement, HTMLElement, HTMLElement];
    const thread = upper.parentElement!;
    const glide = glides.at(-1)!;
    expect(glide).toBeDefined();
    delete dom.window.document.documentElement.dataset.agentMotion;
    fakeGeometry.set(anchor, { top: 0, height: 20 });
    fakeGeometry.set(upper, { top: 20, height: 40 });
    fakeGeometry.set(lower, { top: 60, height: 30 });
    const placed = (tops: number[]) => ({
      idAt: (index: number) => nodes[index]?.dataset.rowId,
      indexOf: (id: string) => nodes.findIndex((node) => node.dataset.rowId === id),
      topAt: (index: number) => tops[index] ?? 0,
      heightAt: (index: number) => [20, 80, 30][index] ?? 0,
      rowAt: (index: number) => nodes[index],
      mounted: [{ first: 0, last: 3 }],
    });
    glide.place(thread, true, anchor.dataset.rowId, true, undefined, undefined, placed([0, 20, 60]));
    fakeGeometry.set(upper, { top: 20, height: 80 });
    fakeGeometry.set(lower, { top: 120, height: 30 });
    glide.place(thread, true, anchor.dataset.rowId, true, undefined, undefined, placed([0, 20, 120]));
    expect(clip(upper)).toBe(40);
    expect(glide.moving()).toBe(true);
    fakeGeometry.set(upper, { top: 20, height: 100 });
    acpmuxPerf.enabled = true;
    acpmuxPerf.resetRenders();
    type Clearance = { visibleBottom: number; lowerTop: number; clip: number; moving: boolean };
    const skippedClearance: Clearance[] = [];
    const realRender = acpmuxPerf.render.bind(acpmuxPerf);
    marker = spyOn(acpmuxPerf, "render").mockImplementation((name: string) => {
      realRender(name);
      if (name !== "transcript:anchor-skipped") return;
      const lowerSlide = active(lower).find((one) => "translate" in one.keyframes[0]!);
      const lowerTop =
        lower.offsetTop + Number.parseFloat(String(lowerSlide?.keyframes[0]!.translate ?? "0 0").split(" ")[1]!);
      skippedClearance.push({
        visibleBottom: upper.offsetTop + upper.offsetHeight - clip(upper),
        lowerTop,
        clip: clip(upper),
        moving: glide.moving(),
      });
    });
    // Observe at the skipped-layout marker: a later placement can otherwise hide one bad frame.
    // No observer entry and no virtual geometry update. The same text has a new stream version.
    await act(async () => render(2));
    expect(skippedClearance.length).toBeGreaterThan(0);
    for (const frame of skippedClearance) {
      expect(frame.lowerTop).toBe(60);
      expect(frame.clip).toBe(60);
      expect(frame.moving).toBe(true);
      expect(frame.visibleBottom).toBeLessThanOrEqual(frame.lowerTop);
    }
    glide.stop();
  } finally {
    marker?.mockRestore();
    acpmuxPerf.enabled = false;
    await act(async () => root.unmount());
  }
});
