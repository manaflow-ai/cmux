// CMUX-896: a ResizeObserver callback can synchronously catch up a DIFFERENT streaming row.
// Same-depth rows cannot report their new size again before this frame paints. Placement must
// include the reply changed by catch-up even though it was absent from the original entries.
// l10n-allow-file: test transcript text.
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

// jsdom has no layout: explicit row heights model a new line only after its text commits.
// Unsized rows keep their estimates.
const VIEWPORT = 600;
const TURNS = 40;
const LAST = `t${TURNS - 1}-answer`;
const OBSERVED = `t${TURNS - 1}-user`;
const WRAPPED = "new streamed line";
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", {
  configurable: true,
  get: () => 760,
});
installJsdomScroller(dom.window as never, () => VIEWPORT);
const sized = new WeakMap<Element, number>();
const heightOf = (node: HTMLElement): number | undefined => {
  const base = sized.get(node);
  return base === undefined
    ? undefined
    : base + (node.dataset.rowId === LAST && node.textContent?.includes(WRAPPED) ? 40 : 0);
};
const rect = (height: number) =>
  ({
    top: 0,
    bottom: height,
    left: 0,
    right: 760,
    width: 760,
    height,
    x: 0,
    y: 0,
    toJSON() {},
  }) as DOMRect;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  return rect(heightOf(this) ?? 0);
};
dom.window.HTMLElement.prototype.getClientRects = function (this: HTMLElement) {
  const height = heightOf(this);
  return (height === undefined ? [] : [rect(height)]) as unknown as DOMRectList;
};
Object.defineProperty(dom.window.HTMLElement.prototype, "offsetHeight", {
  configurable: true,
  get(this: HTMLElement) {
    return heightOf(this) ?? 0;
  },
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
const { streamingRow } = await import("../src/agent-session/acpmux/streamingRow");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: string, text?: string, version = 1): AcpmuxRow => ({
  id,
  kind,
  text,
  version,
  at: 1,
});
const transcript: AcpmuxRow[] = Array.from({ length: TURNS }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  {
    ...row(`t${index}-answer`, "assistant", `Answer ${index}.`),
    ...(index === TURNS - 1 ? { streaming: true } : {}),
  },
  ...(index === TURNS - 1 ? [] : [{ ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 }]),
]).flat();
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
const spacerHeight = () =>
  parseFloat(dom.window.document.querySelector<HTMLElement>(".acpmux-scroll > .acpmux-spacer")!.style.height);
const nodeFor = (id: string) => dom.window.document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${id}"]`)!;

test("observer catch-up places a different streamed reply before returning, without its own observer entry", async () => {
  observers.length = 0;
  const root = createRoot(dom.window.document.getElementById("root")!);
  const expanded = new Set<string>();
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(transcript, expanded, { working: true })}
          streams
          expanded={expanded}
          onToggleActivity={() => {}}
        />,
      ),
    );
    await act(nextFrame);
    const observed = nodeFor(OBSERVED);
    const answer = nodeFor(LAST);
    expect(observed).not.toBeNull();
    expect(answer).not.toBeNull();
    sized.set(observed, 100);
    sized.set(answer, 200);
    const observer = observers.find((one) => one.targets.has(answer) && one.targets.has(observed));
    expect(observer).toBeDefined();
    const entries = (nodes: HTMLElement[]) => nodes.map((target) => ({ target }) as unknown as ResizeObserverEntry);
    await act(async () => observer!.callback(entries([observed, answer])));
    const start = spacerHeight();
    const lower = dom.window.document.querySelector<HTMLElement>(".acpmux-thinking.acpmux-row--below")!;
    expect(lower).not.toBeNull();
    const lowerStart = Number.parseFloat(lower.style.top);
    let lowerAtReturn = 0;
    const drawn = transcript.find((one) => one.id === LAST)!;
    let placedAtReturn = 0;
    await act(async () => {
      // Publish a pending transition, then deliver another row's resize in the same browser task.
      // The reply still has its old DOM until the observer's flushSync calls catchUpLive.
      streamingRow.set(
        {
          ...drawn,
          text: `${drawn.text} The ${WRAPPED} wraps the reply.`,
          version: drawn.version + 1,
        },
        drawn,
      );
      expect(answer.textContent).not.toContain(WRAPPED);
      sized.set(observed, 120);
      observer!.callback(entries([observed]));
      expect(answer.textContent).toContain(WRAPPED);
      placedAtReturn = spacerHeight() - start;
      lowerAtReturn = Number.parseFloat(lower.style.top) - lowerStart;
    });
    // Both heights must be placed before callback return: 20px for its entry, 40px for catch-up.
    // Waiting for act or another observer would hide the one-frame stale placement.
    expect(placedAtReturn).toBe(60);
    expect(lowerAtReturn).toBe(60);
    expect(nodeFor(LAST)).toBe(answer);
  } finally {
    await act(async () => {
      root.unmount();
      streamingRow.clear();
    });
  }
});
