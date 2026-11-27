// A chat's open reads older history only after its newest rows have painted. The older page's fold is one long
// commit (about 150 ms on a god chat), and asked from the open's first commit it landed before the newest message's
// frame in 4 of 7 opens: the god chat's attach p50 was 352 ms against the small chat's 222 (goal chat-attach-p95;
// Leo, 2026-11-12: a god chat shows "no perceivable difference", within 1.2x). Rows too short to reach the view's
// top still ask at once, so no blank band waits a frame.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
// Each element's ResizeObserver callback, which the test fires as a redrawn row would.
const frames = new Map<number, FrameRequestCallback>();
let frameId = 0;
async function paintFrame() {
  const due = [...frames.values()];
  frames.clear();
  for (const callback of due) callback(performance.now());
  // A task queued from a frame callback runs after the frame paints.
  await new Promise((resolve) => setTimeout(resolve, 0));
}
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
  // Frames run when the test says, so "before the frame paints" is a step it takes.
  requestAnimationFrame: (callback: FrameRequestCallback) => {
    frames.set(++frameId, callback);
    return frameId;
  },
  cancelAnimationFrame: (id: number) => frames.delete(id),
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
// jsdom has no layout, so the rows' drawn height is the test's: taller than the view, or not.
let drawnRows = 0;
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollHeight", { configurable: true, get: () => drawnRows });
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
  await settleReact();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
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

async function open(turns: number, sessionId: string, height: number) {
  drawnRows = height;
  const history = Array.from({ length: turns }, (_, index) => turn(index + 1)).flat();
  const root = createRoot(dom.window.document.getElementById("root")!);
  let asks = 0;
  const onLoadOlder = () => {
    asks += 1;
    return new Promise<void>(() => {});
  };
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(history, new Set(), { working: false, now: at })}
        onToggleActivity={() => {}}
        expanded={new Set()}
        canLoadOlder
        onLoadOlder={onLoadOlder}
        sessionId={sessionId}
      />,
    ),
  );
  return { asks: () => asks, root };
}

test("an open whose rows fill the view asks for older history after its first frame, not in its commit", async () => {
  // Eight turns: taller than the view, shorter than the six viewports read ahead.
  const chat = await open(8, "s-fill", VIEWPORT * 3);
  try {
    expect(chat.asks()).toBe(0);
    await act(async () => paintFrame());
    expect(chat.asks()).toBe(1);
  } finally {
    await act(async () => chat.root.unmount());
  }
});

test("an open whose rows do not reach the view's top asks at once", async () => {
  const chat = await open(1, "s-short", VIEWPORT / 2);
  try {
    expect(chat.asks()).toBe(1);
    await act(async () => paintFrame());
    expect(chat.asks()).toBe(1);
  } finally {
    await act(async () => chat.root.unmount());
  }
});
