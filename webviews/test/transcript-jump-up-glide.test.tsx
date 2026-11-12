// Jump up (jumpUp.ts) glides to where the reader left off, on Jump to latest's ride, instead of cutting
// there in one frame (Leo, 2026-11-11: "This kind of thing needs to happen a h*ll of a lot more
// gracefully than whatever's going on here."). A long way skips at once to one viewport from the
// place and eases the rest; the way back glides too. The place is set by idle detection (Leo,
// 2026-11-12: "at least one full screen of idleness"), kept per chat across reloads, and Jump up
// never shows with Jump to latest nor right after a press of it.
import { afterAll, expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { keepIdle, loadIdle } from "../src/agent-session/acpmux/jumpUp";
import { installJsdomScroller, scrollerEnd } from "./support/jsdomScroller";

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
  localStorage: dom.window.localStorage,
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
  // A frame's time on the clock the code reads (`performance.now()`, Bun's), as in a browser, where
  // both are the page's. jsdom's own frame time counts from when this window was made, so it ran
  // behind Bun's by however long the imports above took: a ride (scrollMotion.ts) held its start
  // until jsdom's clock caught up, and on a loaded worker that outlasted the frames this test waits
  // (the glide "landed" where it skipped to).
  requestAnimationFrame: (callback: FrameRequestCallback) =>
    dom.window.requestAnimationFrame(() => callback(performance.now())),
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
  await settleReact();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
// One prompt, then a long reply: the prompt (where the reader left off) is many viewports up.
const rows: AcpmuxRow[] = [
  row("prompt", "user", "Look into the failing build."),
  ...Array.from({ length: 80 }, (_, index) =>
    row(`answer-${index}`, "assistant", `Step ${index}.\n\nWith a second paragraph so the row has height.`),
  ),
];
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

/// Each frame's offset until, once it has moved, it holds still for a few frames (or 120 frames run
/// out): an eased start can hold a whole pixel for its first frames.
async function frames(scroller: HTMLElement): Promise<number[]> {
  const seen = [scroller.scrollTop];
  let still = 0;
  for (let i = 0; i < 120 && still < 6; i++) {
    await act(async () => nextFrame());
    const moved = seen.some((top) => top !== seen[0]) || scroller.scrollTop !== seen[0];
    still = moved && scroller.scrollTop === seen.at(-1) ? still + 1 : 0;
    seen.push(scroller.scrollTop);
  }
  return seen;
}

const SESSION = "chat-jump-up";
/// Renders the chat as it opens, with what it kept of the reader's idle stretch.
async function open(kept: Parameters<typeof keepIdle>[2]) {
  dom.window.localStorage.clear();
  keepIdle(dom.window.localStorage, SESSION, kept);
  const root = createRoot(dom.window.document.getElementById("root")!);
  const expanded = new Set<string>();
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(rows, expanded)}
        sessionId={SESSION}
        jumpButton
        onToggleActivity={() => {}}
        expanded={expanded}
      />,
    ),
  );
  await act(async () => nextFrame());
  const doc = dom.window.document;
  return {
    root,
    scroller: doc.querySelector<HTMLElement>(".acpmux-scroll")!,
    up: doc.querySelector<HTMLButtonElement>(".acpmux-jump-up")!,
    latest: doc.querySelector<HTMLButtonElement>(".acpmux-jump-latest:not(.acpmux-jump-up)")!,
  };
}

test("with nothing kept and nothing new since the chat opened, Jump up stays away", async () => {
  const { root, up } = await open({});
  try {
    expect(up.hasAttribute("data-shown")).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Jump up glides to the place and back, never cutting a viewport or more in one frame", async () => {
  // The reader went idle at their prompt and a screen of reply came in since: the kept mark.
  const { root, scroller, up, latest } = await open({
    mark: { place: { rowId: "prompt", offset: 0 }, at: 1, why: "idle" },
  });
  try {
    const end = scrollerEnd(scroller);
    expect(end).toBeGreaterThan(VIEWPORT * 4);
    expect(scroller.scrollTop).toBe(end);
    expect(up.hasAttribute("data-shown")).toBe(true);
    expect(latest.hasAttribute("data-shown")).toBe(false);

    await act(async () => up.click());
    // The press skips the far middle at once, to one viewport from the place: not there yet.
    const skipped = scroller.scrollTop;
    expect(skipped).toBeLessThan(end);
    const upFrames = await frames(scroller);
    const landed = upFrames.at(-1)!;
    expect(landed).toBeLessThan(skipped);
    expect(skipped - landed).toBeLessThanOrEqual(VIEWPORT + 1);
    // Eased over several frames, never back down, each one less than a viewport.
    expect(new Set(upFrames).size).toBeGreaterThan(4);
    for (let i = 1; i < upFrames.length; i++) {
      expect(upFrames[i]!).toBeLessThanOrEqual(upFrames[i - 1]!);
      expect(upFrames[i - 1]! - upFrames[i]!).toBeLessThan(VIEWPORT);
    }
    // The glide's own steps are not the reader's stop: the way back is still held. Up there Jump to
    // latest shows, so Jump up steps aside: never the two stacked (Leo, 2026-11-12: "a bit extra").
    expect(up.hasAttribute("data-back")).toBe(true);
    expect(latest.hasAttribute("data-shown")).toBe(true);
    expect(up.hasAttribute("data-shown")).toBe(false);

    // Esc goes back to the latest message, also on a glide.
    await act(async () => {
      dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape" }));
    });
    const backFrames = [scroller.scrollTop, ...(await frames(scroller))];
    expect(backFrames.at(-1)).toBe(scrollerEnd(scroller));
    expect(new Set(backFrames).size).toBeGreaterThan(4);
    // The way back is the press's return, not the reader's act: the mark stays, and Jump up with it.
    expect(up.hasAttribute("data-shown")).toBe(true);
  } finally {
    await act(async () => root.unmount());
  }
});

test("pressing Jump to latest is the reader's act: Jump up does not come up at the bottom after it", async () => {
  const { root, scroller, up, latest } = await open({
    mark: { place: { rowId: "prompt", offset: 0 }, at: 1, why: "idle" },
  });
  try {
    // Scrolled up to the top: only Jump to latest shows.
    await act(async () => {
      scroller.scrollTop = 0;
      scroller.dispatchEvent(new dom.window.Event("scroll"));
    });
    await act(async () => nextFrame());
    expect(latest.hasAttribute("data-shown")).toBe(true);
    expect(up.hasAttribute("data-shown")).toBe(false);
    await act(async () => latest.click());
    // The ride to the latest message, its scroll events as the browser sends them.
    for (let i = 0; i < 120 && scroller.scrollTop !== scrollerEnd(scroller); i++)
      await act(async () => {
        await nextFrame();
        scroller.dispatchEvent(new dom.window.Event("scroll"));
      });
    expect(up.hasAttribute("data-shown")).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
  // The press let go of the mark: what the chat keeps for its next load has none.
  expect(loadIdle(dom.window.localStorage, SESSION).mark).toBeUndefined();
});

test("a press on text while scrolled up is no hand scroll: a row moving the view under it keeps the mark", async () => {
  const kept = { mark: { place: { rowId: "prompt", offset: 0 }, at: 1, why: "idle" as const } };
  for (const input of ["press", "wheel"] as const) {
    const { root, scroller } = await open(kept);
    try {
      // Up in the reply, put there by no input of the reader's.
      await act(async () => {
        scroller.scrollTop = VIEWPORT * 2;
        scroller.dispatchEvent(new dom.window.Event("scroll"));
      });
      await act(async () => nextFrame());
      const text = dom.window.document.querySelector<HTMLElement>(".acpmux-row")!;
      await act(async () => {
        if (input === "press") {
          // A click to select: pressed and released in place.
          text.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true, clientX: 200, clientY: 300 }));
          dom.window.document.dispatchEvent(
            new dom.window.MouseEvent("pointerup", { bubbles: true, clientX: 200, clientY: 300 }),
          );
        } else text.dispatchEvent(new dom.window.WheelEvent("wheel", { bubbles: true, deltaY: -40 }));
        // The view moves inside that input's hold: a row settling for the press, the wheel's own step.
        scroller.scrollTop = VIEWPORT * 2 - 40;
        scroller.dispatchEvent(new dom.window.Event("scroll"));
      });
      await act(async () => nextFrame());
    } finally {
      await act(async () => root.unmount());
    }
    // What the chat keeps for its next load: the press kept the mark, the wheel let it go.
    const mark = loadIdle(dom.window.localStorage, SESSION).mark;
    if (input === "press") expect(mark?.place.rowId).toBe("prompt");
    else expect(mark).toBeUndefined();
  }
});
