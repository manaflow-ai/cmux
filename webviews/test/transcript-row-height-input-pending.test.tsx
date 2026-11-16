// "typing under load is not good enough" (Leo): a row that changes size in a followed view is placed
// by a synchronous render inside the row ResizeObserver's callback, so a streamed line paints in the
// frame that delivered it. While a key or pointer event waits (Chromium's `isInputPending`), that
// synchronous render holds the typed character behind it: the frame's own commit places the row
// instead, by the next frame. With no input waiting the placement stays synchronous, as before.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { installJsdomScroller } from "./support/jsdomScroller";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
dom.window.document.documentElement.dataset.agentMotion = "off";

/// Every ResizeObserver the transcript makes, with what it observes: the test delivers its entries.
type Observed = { callback: (entries: ResizeObserverEntry[]) => void; targets: Set<Element> };
const observers: Observed[] = [];
class RecordingResizeObserver {
  private readonly observed: Observed;
  constructor(callback: (entries: ResizeObserverEntry[]) => void) {
    this.observed = { callback, targets: new Set() };
    observers.push(this.observed);
  }
  observe(target: Element) {
    this.observed.targets.add(target);
  }
  unobserve(target: Element) {
    this.observed.targets.delete(target);
  }
  disconnect() {
    this.observed.targets.clear();
  }
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
  ResizeObserver: RecordingResizeObserver,
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// Chromium's input-pending signal, set by the test.
let pending = false;
Object.defineProperty(dom.window.navigator, "scheduling", {
  configurable: true,
  value: { isInputPending: () => pending },
});

// jsdom has no layout: a row the test sizes lays out at that height; every other box is not laid out
// (no client rects), so it keeps its estimate.
const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => VIEWPORT);
const sized = new WeakMap<Element, number>();
const rect = (height: number) =>
  ({ top: 0, bottom: height, left: 0, right: 760, width: 760, height, x: 0, y: 0, toJSON() {} }) as DOMRect;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  return rect(sized.get(this) ?? 0);
};
dom.window.HTMLElement.prototype.getClientRects = function (this: HTMLElement) {
  const height = sized.get(this);
  return (height === undefined ? [] : [rect(height)]) as unknown as DOMRectList;
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const turns = Array.from({ length: 3 }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
const spacerHeight = () =>
  dom.window.document.querySelector<HTMLElement>(".acpmux-scroll > .acpmux-spacer")!.style.height;

/// Mounts a followed transcript, grows the last answer to `height` and delivers its observer entry.
/// Returns the spacer's height before, right after the delivery (in the callback's task) and a frame later.
async function growLastAnswer(inputPending: boolean, height: number) {
  observers.length = 0;
  pending = false;
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript rows={turnView(turns, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
    await act(nextFrame);
    const answer = dom.window.document.querySelector<HTMLElement>('.acpmux-row[data-row-id="t2-answer"]')!;
    expect(answer).not.toBeNull();
    const rowObserver = observers.find((observer) => observer.targets.has(answer));
    expect(rowObserver).toBeDefined();
    const before = spacerHeight();
    let delivered = "";
    await act(async () => {
      sized.set(answer, height);
      pending = inputPending;
      rowObserver!.callback([{ target: answer } as unknown as ResizeObserverEntry]);
      // What a synchronous render committed in the observer's own task.
      delivered = spacerHeight();
      pending = false;
      await nextFrame();
    });
    return { before, delivered, after: spacerHeight() };
  } finally {
    await act(async () => root.unmount());
    pending = false;
  }
}

test("with no input waiting, a followed row's new height commits in the observer's task", async () => {
  const { before, delivered, after } = await growLastAnswer(false, 900);
  expect(delivered).not.toBe(before);
  expect(after).toBe(delivered);
});

test("with input waiting, a followed row's new height waits for the frame's commit, then lands", async () => {
  const { before, delivered, after } = await growLastAnswer(true, 900);
  // No synchronous render in the observer's task: the typed key goes first.
  expect(delivered).toBe(before);
  // The frame's commit places it.
  expect(after).not.toBe(before);
  // The same place a synchronous placement gives.
  const synchronous = await growLastAnswer(false, 900);
  expect(after).toBe(synchronous.after);
});

// One placement per frame (chat-render-pipeline R5): the observer's callback places the rows once,
// with one synchronous render and one read of what it placed. A row whose height moves again under
// that placement (its text rewraps) used to be flushed and read up to three times in the one task,
// a forced layout each; its next height now goes in the next commit.
test("a followed row whose height moves under its placement is placed once in the observer's task", async () => {
  observers.length = 0;
  pending = false;
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript rows={turnView(turns, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
    await act(nextFrame);
    const answer = dom.window.document.querySelector<HTMLElement>('.acpmux-row[data-row-id="t2-answer"]')!;
    const rowObserver = observers.find((observer) => observer.targets.has(answer));
    expect(rowObserver).toBeDefined();
    const spacer = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll > .acpmux-spacer")!;
    // Every height the spacer is given in the callback's task: one per synchronous placement.
    const placed: string[] = [];
    let counting = false;
    const style = spacer.style;
    const proto = Object.getPrototypeOf(style) as object;
    const descriptor =
      Object.getOwnPropertyDescriptor(proto, "height") ??
      Object.getOwnPropertyDescriptor(Object.getPrototypeOf(proto) as object, "height")!;
    Object.defineProperty(style, "height", {
      configurable: true,
      get() {
        return descriptor.get!.call(style);
      },
      set(value: string) {
        if (counting && value !== descriptor.get!.call(style)) placed.push(value);
        descriptor.set!.call(style, value);
      },
    });
    let height = 900;
    await act(async () => {
      // Each read of the row finds it taller: every placement rewraps it again.
      Object.defineProperty(answer, "getBoundingClientRect", {
        configurable: true,
        value: () => rect((height += 24)),
      });
      sized.set(answer, height);
      counting = true;
      rowObserver!.callback([{ target: answer } as unknown as ResizeObserverEntry]);
      counting = false;
      await nextFrame();
    });
    expect(placed.length).toBe(1);
    // The height read after that placement still lands, in the next commit.
    expect(spacerHeight()).not.toBe(placed[0]);
    delete (style as unknown as Record<string, unknown>).height;
  } finally {
    await act(async () => root.unmount());
    pending = false;
  }
});
