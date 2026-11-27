// "typing under load is not good enough" (Leo): a row that changes size in a followed view is placed
// by a synchronous render inside the row ResizeObserver's callback, so a streamed line paints in the
// frame that delivered it. While a key or pointer event waits (Chromium's `isInputPending`), that
// synchronous render holds the typed character behind it: the frame's own commit places the row
// instead, by the next frame. With no input waiting the placement stays synchronous, as before.
import { afterAll, expect, test } from "bun:test";
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

const { act, startTransition, Suspense } = await import("react");
const { flushSync } = await import("react-dom");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

test("urgent append keeps committed height after suspended height correction", async () => {
  const row = (id: string, kind: string, text: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
  const initial = [row("a", "assistant", "Earlier assistant reply."), row("b", "user", "Follow up")];
  const appended = [...initial, row("c", "assistant", "New reply")];
  const never = new Promise<never>(() => {});
  let suspended = 0;
  function Suspends({ on }: { on: boolean }) {
    if (on) {
      suspended++;
      throw never;
    }
    return null;
  }
  const expanded = new Set<string>();
  const toggle = () => {};
  function View({ rows, suspend = false }: { rows: AcpmuxRow[]; suspend?: boolean }) {
    return (
      <Suspense fallback="loading">
        <VirtualTranscript sessionId="abandoned-height" rows={rows} onToggleActivity={toggle} expanded={expanded} />
        <Suspends on={suspend} />
      </Suspense>
    );
  }
  const node = (id: string) => dom.window.document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${id}"]`)!;
  const top = (id: string) => parseFloat(node(id).style.top) + (parseFloat(node(id).style.marginTop) || 0);
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () => root.render(<View rows={initial} />));
    await act(() => new Promise<void>((r) => dom.window.requestAnimationFrame(() => r())));
    const a = node("a");
    const observer = observers.find((o) => o.targets.has(a))!;
    expect(observer).toBeDefined();
    sized.set(a, 150);
    act(() => observer.callback([{ target: a } as unknown as ResizeObserverEntry]));
    const initialTop = top("b");
    expect(initialTop).toBeGreaterThanOrEqual(150);
    pending = true;
    act(() =>
      startTransition(() => {
        sized.set(a, 100);
        observer.callback([{ target: a } as unknown as ResizeObserverEntry]);
        root.render(<View rows={initial} suspend />);
      }),
    );
    expect(suspended).toBeGreaterThan(0);
    expect(top("b")).toBe(initialTop);
    // Layout was restored before the urgent append. No new observer entry has arrived yet.
    sized.set(a, 150);
    act(() => {
      flushSync(() => root.render(<View rows={appended} />));
      console.log("full-transcript-abandoned", JSON.stringify({ initialTop, appendedTop: top("b"), suspended }));
      expect(top("b")).toBe(initialTop);
    });
  } finally {
    pending = false;
    await act(async () => root.unmount());
  }
});
