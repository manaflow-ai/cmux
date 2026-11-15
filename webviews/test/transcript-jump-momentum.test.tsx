// Jump to latest during a trackpad fling's momentum lands at the latest message and stays there
// (Leo 2026-11-12: "if you already have momentum scrolling up, like it doesn't fully jump to the
// bottom. It, like, just maintains momentum"). WebKit keeps sending the fling's momentum as wheel
// events after the jump writes the offset, and moves the view by each: here a wheel event and the
// offset it moves, a frame apart, decaying, as the fling up the chat goes on through the click.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { installJsdomScroller, scrollerEnd } from "./support/jsdomScroller";
import { teardownDom } from "./support/domTeardown";

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
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => VIEWPORT);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const turns = Array.from({ length: 30 }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

/// The wheel's own clock, as the platform stamps its events: a frame apart, however long the page
/// took to handle the last one (a slow runner's render is no pause in the fling).
let stamp = 0;
/// One frame of a trackpad scroll: the wheel event over a row, then the browser's own move of the
/// offset by its delta and the scroll event it fires.
const wheelFrame = async (scroller: HTMLElement, deltaY: number) => {
  await act(async () => {
    const over = scroller.querySelector(".acpmux-row") ?? scroller;
    const event = new dom.window.WheelEvent("wheel", { deltaY, bubbles: true, cancelable: false });
    stamp += 16;
    Object.defineProperty(event, "timeStamp", { value: stamp });
    over.dispatchEvent(event);
    scroller.scrollTop += deltaY;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    await nextFrame();
  });
};

/// A fling up: 30 frames of momentum decaying from 60 px a frame.
const fling = Array.from({ length: 30 }, (_, frame) => -Math.max(1, Math.round(60 * 0.9 ** frame)));

for (const motion of ["off", "on"] as const) {
  test(`Jump to latest mid-fling (motion ${motion}) ends the momentum at the latest message, still following`, async () => {
    if (motion === "off") dom.window.document.documentElement.dataset.agentMotion = "off";
    else delete dom.window.document.documentElement.dataset.agentMotion;
    const root = createRoot(dom.window.document.getElementById("root")!);
    const rows = turnView(turns, new Set());
    const following: boolean[] = [];
    try {
      await act(async () =>
        root.render(
          <VirtualTranscript
            rows={rows}
            jumpButton
            onToggleActivity={() => {}}
            expanded={new Set()}
            onFollowingChange={(next) => following.push(next)}
          />,
        ),
      );
      const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const latest = scrollerEnd(scroller);
      expect(scroller.scrollTop).toBe(latest);
      const button = () =>
        dom.window.document.querySelector<HTMLButtonElement>(".acpmux-jump-latest:not(.acpmux-jump-up)")!;

      // The reader flings up the chat; a few frames in, they press Jump to latest.
      for (const delta of fling.slice(0, 8)) await wheelFrame(scroller, delta);
      expect(scroller.scrollTop).toBeLessThan(latest - VIEWPORT / 2);
      expect(following.at(-1)).toBe(false);
      await act(async () => button().click());
      // The rest of the fling's momentum keeps arriving.
      for (const delta of fling.slice(8)) await wheelFrame(scroller, delta);
      // The jump's own glide (motion on) runs out; nothing more arrives.
      for (let frame = 0; frame < 60; frame += 1) await act(nextFrame);

      expect(scroller.scrollTop).toBe(latest);
      expect(following.at(-1)).toBe(true);
      expect(button().dataset.shown).toBeUndefined();

      // The reader's next gesture, after a pause, is theirs: it scrolls up and lets go of the latest row.
      // The pause is on the wheel's clock: 150 ms with no event, past MOMENTUM_GAP_MS.
      stamp += 150;
      for (const delta of [-4, -12, -30]) await wheelFrame(scroller, delta);
      expect(scroller.scrollTop).toBe(latest - 46);
      expect(following.at(-1)).toBe(false);
    } finally {
      await act(async () => root.unmount());
    }
  });
}
