// Jump up (jumpControl.ts) glides to the first row the reader has not seen, on Jump to latest's ride,
// instead of cutting there in one frame (Leo, 2026-11-11: "This kind of thing needs to happen a h*ll of a lot more
// gracefully than whatever's going on here."). A long way skips at once to one viewport from the
// place and eases the rest; the way back glides too. With nothing unseen there is no up arrow: not on
// an open (a restart, a reconnect), nor after a press of Jump to latest (Leo, 2026-11-12: "after
// clicking the jump to bottom button, this appears... maybe a bit extra?").
import { afterAll, expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
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

const row = (id: string, kind: string, seq: number, text?: string): AcpmuxRow => ({
  id,
  kind,
  seq,
  text,
  version: 1,
  at: 1,
});
// One prompt the reader saw (their cursor), then a long reply they did not: its first row is many
// viewports up.
const rows: AcpmuxRow[] = [
  row("prompt", "user", 1, "Look into the failing build."),
  ...Array.from({ length: 80 }, (_, index) =>
    row(`answer-${index}`, "assistant", index + 2, `Step ${index}.\n\nWith a second paragraph so the row has height.`),
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

test("Jump up glides to the place and back, never cutting a viewport or more in one frame", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const expanded = new Set<string>();
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, expanded)}
          readThrough={1}
          jumpButton
          onToggleActivity={() => {}}
          expanded={expanded}
        />,
      ),
    );
    await act(async () => nextFrame());
    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const end = scrollerEnd(scroller);
    expect(end).toBeGreaterThan(VIEWPORT * 4);
    expect(scroller.scrollTop).toBe(end);
    const up = dom.window.document.querySelector<HTMLButtonElement>(".acpmux-jump-up")!;
    expect(up.hasAttribute("data-shown")).toBe(true);
    expect(up.getAttribute("data-jump")).toBe("up");

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
    // There the first unseen row is in view: the same control is Jump to latest now.
    expect(up.getAttribute("data-jump")).toBe("latest");

    // A second press goes back to the latest message, also on a glide.
    await act(async () => up.click());
    const backFrames = [scroller.scrollTop, ...(await frames(scroller))];
    expect(backFrames.at(-1)).toBe(scrollerEnd(scroller));
    expect(new Set(backFrames).size).toBeGreaterThan(4);
  } finally {
    await act(async () => root.unmount());
  }
});

/// Renders the chat as it opens, its cursor at `readThrough`.
async function open(readThrough: number) {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const expanded = new Set<string>();
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(rows, expanded)}
        readThrough={readThrough}
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
    jump: doc.querySelector<HTMLButtonElement>(".acpmux-jump-latest")!,
  };
}

/// Moves the view to `top` as the page does (no input held): a reconnect's, a reveal's or Find's move.
async function moveTo(scroller: HTMLElement, top: number) {
  await act(async () => {
    scroller.scrollTop = top;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
  });
  await act(async () => nextFrame());
}

const LAST = rows.at(-1)!.seq!;

test("a restart or reconnect with nothing new, and the page's own moves, bring no up arrow", async () => {
  // The chat reopens with the cursor at its last row (what an attach answers after a restart).
  const { root, scroller, jump } = await open(LAST);
  try {
    expect(scroller.scrollTop).toBe(scrollerEnd(scroller));
    expect(jump.hasAttribute("data-shown")).toBe(false);
    // The page moves the view far up and back (a reveal, Find): Jump to latest while away, never up.
    await moveTo(scroller, 0);
    expect(jump.hasAttribute("data-shown")).toBe(true);
    expect(jump.getAttribute("data-jump")).toBe("latest");
    await moveTo(scroller, VIEWPORT * 2);
    expect(jump.getAttribute("data-jump")).toBe("latest");
  } finally {
    await act(async () => root.unmount());
  }
});

test("after a press of Jump to latest no up arrow comes, and none going back up a little", async () => {
  const { root, scroller, jump } = await open(LAST);
  try {
    await moveTo(scroller, 0);
    expect(jump.getAttribute("data-jump")).toBe("latest");
    // Only ever one disc.
    expect(dom.window.document.querySelectorAll(".acpmux-jump-latest").length).toBe(1);
    await act(async () => jump.click());
    // The ride to the latest message, its scroll events as the browser sends them: never up on the way.
    for (let i = 0; i < 120 && scroller.scrollTop !== scrollerEnd(scroller); i++) {
      await act(async () => {
        await nextFrame();
        scroller.dispatchEvent(new dom.window.Event("scroll"));
      });
      expect(jump.getAttribute("data-jump")).not.toBe("up");
    }
    expect(scroller.scrollTop).toBe(scrollerEnd(scroller));
    await act(async () => nextFrame());
    expect(jump.hasAttribute("data-shown")).toBe(false);
    // Back up a little: nothing unseen above, so it is Jump to latest again, not up.
    await moveTo(scroller, scrollerEnd(scroller) - VIEWPORT / 2);
    expect(jump.hasAttribute("data-shown")).toBe(true);
    expect(jump.getAttribute("data-jump")).toBe("latest");
  } finally {
    await act(async () => root.unmount());
  }
});
