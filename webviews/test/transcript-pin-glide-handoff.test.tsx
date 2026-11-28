// CMUX-896: only an owned live-line pin can exclude that row from glide clearance.
// A requested pin can be rejected while a translate still plays, or remain held without a request.
// l10n-allow-file: test transcript text.
import { afterAll, expect, mock, test } from "bun:test";
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

// jsdom has no layout: the test delivers explicit heights to trigger real placement passes.
// Unsized rows keep their estimates.
const VIEWPORT = 600;
const TURNS = 40;
const LAST = `t${TURNS - 1}-answer`;

Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", {
  configurable: true,
  get: () => 760,
});
installJsdomScroller(dom.window as never, () => VIEWPORT);
const sized = new WeakMap<Element, number>();
const heightOf = (node: HTMLElement): number | undefined => sized.get(node);
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

let translatingLive = true;
dom.window.HTMLElement.prototype.getAnimations = function (this: HTMLElement) {
  return translatingLive && this.dataset.rowId === "thinking-live"
    ? [
        {
          playState: "running",
          effect: { target: this, getKeyframes: () => [{ translate: "0 -90px" }, { translate: "0 0" }] },
        } as unknown as Animation,
      ]
    : [];
};
const PIN = "../src/agent-session/acpmux/conversation/pinnedLiveLine";
const realPin = { ...(await import(PIN)) } as typeof import("../src/agent-session/acpmux/conversation/pinnedLiveLine");
let request: { pin: boolean; hold: boolean } | undefined;
await mock.module(PIN, () => ({
  ...realPin,
  pinLiveLine: (...args: Parameters<typeof realPin.pinLiveLine>) => {
    request = { pin: args[1], hold: args[2] ?? false };
    return realPin.pinLiveLine(...args);
  },
}));
const GLIDE = "../src/agent-session/acpmux/conversation/tailGlide";
const realGlide = { ...(await import(GLIDE)) } as typeof import("../src/agent-session/acpmux/conversation/tailGlide");
const passes: { requested: boolean; held: boolean; actual: string | undefined; excluded: string | undefined }[] = [];
await mock.module(GLIDE, () => ({
  ...realGlide,
  createTailGlide: (...args: Parameters<typeof realGlide.createTailGlide>) => {
    const glide = realGlide.createTailGlide(...args);
    const place = glide.place;
    glide.place = (...args) => {
      passes.push({
        requested: request?.pin ?? false,
        held: request?.hold ?? false,
        actual: realPin.pinnedLiveRow(args[0])?.dataset.rowId,
        excluded: args[4],
      });
      return place(...args);
    };
    return glide;
  },
}));
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
const nodeFor = (id: string) => dom.window.document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${id}"]`)!;

test("glide excludes only the actual live pin through rejected, acquired, and held handoffs", async () => {
  observers.length = 0;
  passes.length = 0;
  translatingLive = true;
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
    const answer = nodeFor(LAST);
    expect(answer).not.toBeNull();
    const observer = observers.find((one) => one.targets.has(answer));
    expect(observer).toBeDefined();
    const resize = async (height: number) => {
      sized.set(answer, height);
      await act(async () => observer!.callback([{ target: answer } as unknown as ResizeObserverEntry]));
    };
    await resize(200);
    const rejected = passes.filter((pass) => pass.requested && pass.actual === undefined);
    expect(rejected.length).toBeGreaterThan(0);
    expect(rejected.every((pass) => pass.excluded === undefined)).toBe(true);

    translatingLive = false;
    await resize(240);
    const acquired = passes.filter((pass) => pass.requested && pass.actual === "thinking-live");
    expect(acquired.length).toBeGreaterThan(0);
    expect(acquired.every((pass) => pass.excluded === "thinking-live")).toBe(true);

    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    await act(async () => scroller.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: -80, bubbles: true })));
    await resize(280);
    const held = passes.filter((pass) => !pass.requested && pass.held && pass.actual === "thinking-live");
    expect(held.length).toBeGreaterThan(0);
    expect(held.every((pass) => pass.excluded === "thinking-live")).toBe(true);
  } finally {
    await act(async () => {
      root.unmount();
      streamingRow.clear();
    });
  }
});
