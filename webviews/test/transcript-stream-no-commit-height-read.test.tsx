// "the dream is infinite chats of infinite length with flat or no growth in cpu/memory" (Leo): a
// streamed token reads no row's height in its commit. That read (drawnHeightOf after React's DOM
// writes) forced a layout per token, the top one in a long chat's profile. A token that resized the
// reply is reported by the row's ResizeObserver from the browser's own layout pass; one that did not
// keeps the height already placed. The placed heights are the same as when the commit read them.
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

// jsdom has no layout: a row the test sizes lays out at that height; every other box is not laid out
// (no client rects), so it keeps its estimate. Each read of the streamed reply's box is counted while
// a commit runs (`inCommit`). The follow chase's read of the row above it is another pass's (chaseFollow).
const VIEWPORT = 600;
const TURNS = 40;
const LAST = `t${TURNS - 1}-answer`;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => VIEWPORT);
const sized = new WeakMap<Element, number>();
let inCommit = false;
let commitReads = 0;
const countRead = (element: HTMLElement) => {
  if (inCommit && element.dataset.rowId === LAST) commitReads += 1;
};
const rect = (height: number) =>
  ({ top: 0, bottom: height, left: 0, right: 760, width: 760, height, x: 0, y: 0, toJSON() {} }) as DOMRect;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  countRead(this);
  return rect(sized.get(this) ?? 0);
};
dom.window.HTMLElement.prototype.getClientRects = function (this: HTMLElement) {
  countRead(this);
  const height = sized.get(this);
  return (height === undefined ? [] : [rect(height)]) as unknown as DOMRectList;
};
Object.defineProperty(dom.window.HTMLElement.prototype, "offsetHeight", {
  configurable: true,
  get(this: HTMLElement) {
    countRead(this);
    return sized.get(this) ?? 0;
  },
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const TOKENS = 30;
const row = (id: string, kind: string, text?: string, version = 1): AcpmuxRow => ({ id, kind, text, version, at: 1 });
/// A long chat whose last reply has streamed `tokens` tokens.
const transcript = (tokens: number): AcpmuxRow[] =>
  Array.from({ length: TURNS }, (_, index) => {
    const last = index === TURNS - 1;
    return [
      row(`t${index}-user`, "user", `Question ${index}`),
      last
        ? row(LAST, "assistant", `Answer ${index}.${" word".repeat(tokens)}`, 1 + tokens)
        : row(`t${index}-answer`, "assistant", `Answer ${index}.`),
      ...(last ? [] : [{ ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 }]),
    ];
  }).flat();
/// The reply's drawn height after `tokens` tokens: a new line every third token.
const heightAt = (tokens: number) => 200 + 20 * Math.floor(tokens / 3);
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
const spacerHeight = () =>
  parseFloat(dom.window.document.querySelector<HTMLElement>(".acpmux-scroll > .acpmux-spacer")!.style.height);
const answerNode = () => dom.window.document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${LAST}"]`)!;

test("streamed tokens read no row height in their commit, and place the reply as a read would", async () => {
  observers.length = 0;
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (tokens: number) =>
    root.render(
      <VirtualTranscript
        rows={turnView(transcript(tokens), new Set())}
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    );
  /// Delivers the reply's observer entry, as the browser does after a layout that resized it.
  const deliver = async () => {
    const answer = answerNode();
    const rowObserver = observers.find((observer) => observer.targets.has(answer));
    expect(rowObserver).toBeDefined();
    await act(async () => rowObserver!.callback([{ target: answer } as unknown as ResizeObserverEntry]));
  };
  try {
    await act(async () => render(0));
    await act(nextFrame);
    const answer = answerNode();
    expect(answer).not.toBeNull();
    sized.set(answer, heightAt(0));
    await deliver();
    const start = spacerHeight();
    const reads: number[] = [];
    const placed: number[] = [];
    for (let token = 1; token <= TOKENS; token += 1) {
      // The DOM the token commits lays out at its new height.
      const resized = heightAt(token) !== heightAt(token - 1);
      sized.set(answerNode(), heightAt(token));
      commitReads = 0;
      inCommit = true;
      try {
        await act(async () => render(token));
      } finally {
        inCommit = false;
      }
      reads.push(commitReads);
      expect(answerNode()).toBe(answer);
      // The browser's layout after the commit: the observer reports only a size that changed.
      if (resized) await deliver();
      await act(nextFrame);
      placed.push(spacerHeight() - start);
    }
    console.log(`stream commit row height reads: ${JSON.stringify({ tokens: TOKENS, reads })}`);
    // Each token is placed at the height it drew: the reply's growth, exactly.
    expect(placed).toEqual(Array.from({ length: TOKENS }, (_, index) => heightAt(index + 1) - heightAt(0)));
    // No height read in any token's commit.
    expect(reads).toEqual(Array.from({ length: TOKENS }, () => 0));
  } finally {
    await act(async () => root.unmount());
  }
});
