// Older history pages in once per loaded page while the reader is near the top. Streaming
// commits, resizes and follow-scroll re-render the transcript many times a second; none of them
// may ask for the same page again (#21369, silently undone by a stale-base squash in #21194).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
// Each element's ResizeObserver callback, which the test fires as a redrawn row would.
const observers = new Map<Element, (entries: { target: Element }[]) => void>();
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
  ResizeObserver: class {
    constructor(private readonly callback: (entries: { target: Element }[]) => void) {}
    observe(target: Element) {
      observers.set(target, this.callback);
    }
    unobserve(target: Element) {
      observers.delete(target);
    }
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
const offsets = new WeakMap<object, number>();
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: object, value: number) {
    offsets.set(this, value);
  },
});
// jsdom has no layout: each row draws at a height of its own, which a redraw can change.
const drawnHeights = new Map<string, number>();
const drawnHeight = (id: string) => drawnHeights.get(id) ?? 40 + (id.length % 7) * 9;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const height = this.dataset.rowId ? drawnHeight(this.dataset.rowId) : 0;
  return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: height, width: 0, height, toJSON() {} } as DOMRect;
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const turn = (index: number) => [
  row(`t${index}-user`, "user", { text: `Question ${index}` }),
  row(`t${index}-answer`, "assistant", { text: `Answer ${index}.` }),
  row(`t${index}-end`, "turnSummary", { status: "completed", durationMs: 1_000 }),
];

test("a streaming reply near the top asks for the older page once, and the next page once more", async () => {
  let history = Array.from({ length: 3 }, (_, index) => turn(index + 10)).flat();
  let reply = row("live-answer", "assistant", { text: "First words", streaming: true });
  const root = createRoot(dom.window.document.getElementById("root")!);
  let asked = 0;
  // Never settles, like a page still in flight: only the transcript's own bookkeeping can dedupe.
  const onLoadOlder = () => {
    asked += 1;
    return new Promise<void>(() => {});
  };
  const draw = async () =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView([...history, reply], new Set(), { working: true, now: at })}
          working
          onToggleActivity={() => {}}
          expanded={new Set()}
          canLoadOlder
          onLoadOlder={onLoadOlder}
          sessionId="s1"
        />,
      ),
    );
  try {
    await draw();
    expect(asked).toBe(1);
    for (let step = 1; step <= 6; step += 1) {
      reply = { ...reply, version: reply.version + 1, text: `${reply.text} more ${step}.` };
      await draw();
    }
    expect(asked).toBe(1);
    // The page lands above the first row: the reader is still near the top, so the next page is asked for.
    history = [...turn(9), ...history];
    await draw();
    expect(asked).toBe(2);
  } finally {
    await act(async () => root.unmount());
  }
});

test.each([
  [true, false],
  [false, false],
  [true, true],
])("a thumb drag keeps its range through pages, seeded=%s, switching=%s", async (seeded, switching) => {
  let history = Array.from({ length: 20 }, (_, index) => turn(index + 30)).flat();
  const originalSession = `thumb-history-${seeded}-${switching}`;
  let session = originalSession;
  const root = createRoot(dom.window.document.getElementById("root")!);
  let asked = 0;
  const load = () => {
    asked += 1;
    return new Promise<void>(() => {});
  };
  const draw = () =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={history}
          onToggleActivity={() => {}}
          expanded={new Set()}
          canLoadOlder
          promptCount={seeded ? 50 : undefined}
          onLoadOlder={load}
          sessionId={session}
        />,
      ),
    );
  try {
    await draw();
    const node = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const spacer = () => node.querySelector<HTMLElement>(".acpmux-spacer")!;
    const total = () => Number.parseFloat(spacer().style.height);
    Object.defineProperties(node, {
      offsetWidth: { value: 772, configurable: true },
      scrollHeight: { get: total, configurable: true },
    });
    node.getBoundingClientRect = () =>
      ({ left: 0, top: 0, width: 772, height: VIEWPORT, right: 772, bottom: VIEWPORT }) as DOMRect;
    const event = (type: string, y: number, buttons = 1) => {
      const input = new dom.window.MouseEvent(type, { bubbles: true, clientX: 768, clientY: y, buttons });
      Object.defineProperty(input, "pointerType", { value: "mouse" });
      return input;
    };
    const height = total();
    const room = Number(spacer().dataset.olderRoom);
    if (seeded) expect(room).toBeGreaterThan(0);
    await act(async () => node.dispatchEvent(event("pointerdown", 400)));
    const draggedTo = Math.max(0, room - 20);
    await act(async () => {
      dom.window.document.dispatchEvent(event("pointermove", 300));
      node.scrollTop = draggedTo;
      node.dispatchEvent(new dom.window.Event("scroll", { bubbles: true }));
    });
    expect(node.scrollTop).toBe(draggedTo);
    expect(total()).toBeCloseTo(height, 3);
    expect(asked).toBeGreaterThan(0);

    history = [...Array.from({ length: 5 }, (_, index) => turn(index + 25)).flat(), ...history];
    await draw();
    expect(node.scrollTop).toBe(draggedTo);
    expect(total()).toBeCloseTo(height, 3);
    // A much taller earlier turn can exceed the reserved estimate entirely.
    const tall = turn(24).map((entry) =>
      entry.kind === "assistant" ? { ...entry, text: "Earlier detail.\n".repeat(1000) } : entry,
    );
    for (const entry of tall) drawnHeights.set(entry.id, 12000);
    history = [...tall, ...history];
    await draw();
    expect(total()).toBeCloseTo(height, 3);
    expect(node.scrollTop).toBe(draggedTo);
    if (switching) {
      session = `${originalSession}-other`;
      await draw();
    }
    await act(async () => dom.window.document.dispatchEvent(event("pointerup", 300, 0)));
    session = originalSession;
    await draw();
    expect(total()).toBeGreaterThan(height);
  } finally {
    await act(async () => root.unmount());
  }
});
