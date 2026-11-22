// The prompt rail's two ends follow one rule (model.ts railEdgeFades): an end fades while the chat has
// more past it and has a hard edge once the chat is scrolled all the way to that end (Leo, 2026-11-22:
// "if i scroll up in the scroll rail, the lower end should reflect that i'm not at the very bottom, and
// therefore have the same fade effect as the top does. likewise, when im at the top, it should def
// have the hard edge like when im at the bottom."). The rail mounted in the real transcript, read at
// the top, near it, mid-thread, near the bottom and at the bottom, and a short chat that fits.
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { teardownDom } from "./support/domTeardown";
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };
setDefaultTimeout(60_000);

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
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
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
  // The panes are short, the window is not (the app's transcript sits under a title bar and over a
  // composer): the rail's 70%-of-the-window cap is taller than any pane here, as in the app.
  innerHeight: 900,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window, "innerHeight", { configurable: true, value: 900 });

// jsdom has no layout: a 600 px viewport (the transcript's first height) over a long conversation,
// and a scroll offset the test moves as the reader would.
let viewport = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => viewport });
// Wide enough for the minimap's pane-edge rail in these layout tests.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 1040 });
const offsets = new WeakMap<object, number>();
// Read the pitch the mounted rail gives CSS; jsdom does not lay out its rows.
const railPitch = () =>
  Number.parseFloat(
    dom.window.document
      .querySelector<HTMLElement>(".acpmux-minimap__list")!
      .style.getPropertyValue("--acpmux-minimap-pitch"),
  );
/// The rail's list clamps its offset as a browser does: rows use the mounted pitch, a spacer for rows it does not
/// draw as tall as its style says (tickWindow.ts), the list as tall as the rail.
const listRoom = (node: HTMLElement) =>
  Math.max(
    0,
    [...node.children].reduce(
      (sum, child) =>
        sum +
        (child.querySelector("[data-tick]")
          ? railPitch()
          : Number.parseFloat((child as HTMLElement).style.height) || 0),
      0,
    ) - Number.parseFloat(node.parentElement?.style.height ?? "0"),
  );
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: HTMLElement, value: number) {
    offsets.set(
      this,
      this.classList.contains("acpmux-minimap__list") ? Math.max(0, Math.min(listRoom(this), value)) : value,
    );
  },
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const chat = (count: number) =>
  Array.from({ length: count }, (_, index) => [
    row(`user-${index + 1}`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
    { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
  ]).flat();

const mount = async (count: number, id: string) => {
  const document = dom.window.document;
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(chat(count), new Set())}
        sessionId={id}
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    ),
  );
  const scroller = host.querySelector<HTMLElement>(".acpmux-scroll")!;
  const scrollTo = async (at: number) => {
    scroller.scrollTop = at;
    await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
  };
  const ends = () => {
    const list = host.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    const reach = (edge: string) => Number(list.style.getPropertyValue(`--acpmux-minimap-fade-${edge}-reach`));
    return {
      top: list.hasAttribute("data-fade-top"),
      bottom: list.hasAttribute("data-fade-bottom"),
      topReach: reach("top"),
      bottomReach: reach("bottom"),
    };
  };
  const unmount = async () => {
    await act(async () => root.unmount());
    host.remove();
  };
  return { scroller, scrollTo, ends, end: scroller.scrollTop, unmount };
};

test("each end of a long chat's rail fades while the chat has more past it, hard at the end it is at", async () => {
  viewport = 600;
  const chatView = await mount(70, "ends-long");
  try {
    const { end, scrollTo, ends } = chatView;
    expect(end).toBeGreaterThan(1000);
    // Opened at the bottom: a hard foot, the head fading over the prompts above.
    expect(ends()).toMatchObject({ top: true, bottom: false, topReach: 1 });
    await scrollTo(0);
    expect(ends()).toMatchObject({ top: false, bottom: true, bottomReach: 1 });
    // A few px from the top: the head's fade starts, shallow, and deepens with the scroll.
    await scrollTo(24);
    const near = ends();
    expect(near.top).toBe(true);
    expect(near.topReach).toBeGreaterThan(0);
    expect(near.topReach).toBeLessThan(1);
    await scrollTo(Math.round(end / 2));
    expect(ends()).toMatchObject({ top: true, bottom: true, topReach: 1, bottomReach: 1 });
    // Scrolled up from the bottom with the last prompts still on screen: the foot fades as the head
    // does (the rail's list is at its end, so only the chat says there is more below).
    await scrollTo(end - 300);
    expect(ends()).toMatchObject({ top: true, bottom: true, bottomReach: 1 });
    await scrollTo(end);
    expect(ends()).toMatchObject({ top: true, bottom: false });
    // Back at the top after the bottom: hard again.
    await scrollTo(0);
    expect(ends()).toMatchObject({ top: false, bottom: true });
  } finally {
    await chatView.unmount();
  }
});

test("a short chat's rail, which fits, has hard edges at both ends", async () => {
  viewport = 600;
  const chatView = await mount(4, "ends-short");
  try {
    expect(chatView.ends()).toMatchObject({ top: false, bottom: false });
    await chatView.scrollTo(0);
    expect(chatView.ends()).toMatchObject({ top: false, bottom: false });
  } finally {
    await chatView.unmount();
  }
});
