// l10n-allow-file: the transcript fixture text is test data, not shipped UI.
// Ordering map O16, O17 (design/chat-animation-ordering-map.md), with the real VirtualTranscript under
// jsdom's scroller model (virtualized: a 600 px view over 60 rows). Leo, 2026-11-21: "some animations
// i think are still a bit... off. like, you finish some sort of tool call, things happen, things fold,
// stuff comes in at different times", and "i srolled up and then bac k down and it replayed an
// animation".
// - O16 rows that arrive while the reader is scrolled far up are not mounted: no entrance plays then
// - O17 they mount when the reader comes back: after the arrival-to-mount bound they draw in place;
//   soon after their arrival (the control) they still enter
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ENTRANCE_MOUNT_MS } from "../src/agent-session/acpmux/conversation/pendingEntrances";
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
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => 600);

// The pending entrances read `performance.now()`; the test moves that clock instead of waiting.
const realNow = performance.now.bind(performance);
let skew = 0;
performance.now = () => realNow() + skew;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { releaseReaderScroll } = await import("../src/agent-session/acpmux/summary/heldWhileScrolling");

afterAll(async () => {
  performance.now = realNow;
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: string, text: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 }) as AcpmuxRow;
const arrival = (id: string, kind: string, text: string): AcpmuxRow => ({ ...row(id, kind, text), at: Date.now() });
const history = () =>
  Array.from({ length: 60 }, (_, index) =>
    index % 2
      ? row(`reply-${index}`, "assistant", `Reply ${index}\n\nwith a second paragraph`)
      : row(`prompt-${index}`, "user", `Prompt ${index}`),
  );
const Row = ({ row: item }: { row: AcpmuxRow }) => <div>{item.text}</div>;
const registry = { user: Row, assistant: Row } as never;

/// Mounts the chat at its latest row, scrolls the reader to the top, lets three rows arrive, and
/// scrolls back to the latest after `awayMs`. Returns the entrance classes the arrived rows mount with.
async function scrollBack(awayMs: number) {
  skew = 0;
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const scroller = () => host.querySelector<HTMLElement>(".acpmux-scroll")!;
  const render = (rows: AcpmuxRow[]) =>
    act(async () => {
      root.render(
        <VirtualTranscript
          rows={rows}
          registry={registry}
          sessionId={`order-o16-${awayMs}`}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  const mounted = (id: string) => host.querySelector(`[data-row-id="${id}"]`) !== null;
  const jump = async (top: number, key: string, landed: () => boolean) => {
    await act(
      async () => void scroller().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key, bubbles: true })),
    );
    scroller().scrollTop = top;
    await act(async () => void scroller().dispatchEvent(new dom.window.Event("scroll")));
    releaseReaderScroll();
    // The virtual window follows the scroll on the page's next frames: run frames until it holds the
    // rows at the new position (at most 30, half a second of them).
    for (let frame = 0; frame < 30 && !landed(); frame++)
      await act(async () => void (await new Promise((resolve) => dom.window.requestAnimationFrame(resolve))));
  };
  try {
    const rows = history();
    await render(rows);
    await jump(0, "Home", () => mounted("prompt-0") && !mounted("reply-59"));
    expect(host.querySelector('[data-row-id="reply-59"]')).toBeNull();
    const added = [
      arrival("late-1", "user", "Late prompt"),
      arrival("late-2", "assistant", "Late reply"),
      arrival("late-3", "assistant", "Another"),
    ];
    await render([...rows, ...added]);
    // Not mounted: the reader is a long way from them (O16).
    for (const item of added) expect(host.querySelector(`[data-row-id="${item.id}"]`)).toBeNull();
    skew = awayMs;
    await jump(scrollerEnd(scroller()), "End", () => added.every((item) => mounted(item.id)));
    return added.map((item) => {
      const node = host.querySelector<HTMLElement>(`[data-row-id="${item.id}"]`);
      return {
        id: item.id,
        mounted: node !== null,
        entering: node ? /--(message-)?enter/.test(node.className) : false,
      };
    });
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
}

test("O16/O17 control: rows that mount soon after they arrived still enter", async () => {
  const seen = await scrollBack(0);
  expect(seen.every((entry) => entry.mounted)).toBe(true);
  expect(seen.some((entry) => entry.entering)).toBe(true);
});

test("O16/O17: rows that arrived while the reader was far up draw in place when they scroll back to them", async () => {
  const seen = await scrollBack(ENTRANCE_MOUNT_MS + 1000);
  expect(seen.every((entry) => entry.mounted)).toBe(true);
  expect(seen.filter((entry) => entry.entering)).toEqual([]);
});
