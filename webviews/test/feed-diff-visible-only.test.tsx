// The Inbox detail's diff draws what is visible (the visible-only rule): a diff of 1,000 or 10,000
// lines mounts the same lines and DOM nodes, a one-line scroll draws only the line it brings in, and
// the detail drawing again for the same diff (its item updated) draws no line. Before, every line
// was a mounted row keyed by its index (`maxLines` is unset in the detail). A copy across lines
// that are not mounted still copies them, read from the diff.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { FeedAttachment } from "../src/pages/feed/types";
import { settleReact } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";
import { installVirtualSizes } from "./support/virtualSizes";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "Event",
  "MouseEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

/** The detail pane is 420 px tall; a diff line is 14 px. */
const PANE = 420;
const LINE = 14;
const sizes = (element: HTMLElement) =>
  element.classList.contains("feed-detail-scroll") ? PANE : element.classList.contains("feed-diff-line") ? LINE : 0;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/feed/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  // The page's stylesheet is not loaded: the detail scrolls as styles.css says.
  const style = dom.window.document.createElement("style");
  style.textContent = ".feed-detail-scroll { overflow-y: auto; } .feed-diff { overflow: hidden; }";
  dom.window.document.head.append(style);
  installVirtualSizes(dom.window, sizes);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { DiffPreview } = await import("../src/pages/feed/parts");

const diffLines = (n: number) =>
  Array.from({ length: n }, (_, index) =>
    index % 40 === 0 ? `@@ -${index},4 +${index},4 @@` : `${index % 3 === 0 ? "+" : " "}line ${index}`,
  );

async function mount(n: number) {
  const attachment: FeedAttachment = {
    id: "a",
    name: "change.diff",
    mime: "text/x-diff",
    size: 0,
    text: diffLines(n).join("\n"),
  };
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  // The detail draws again with a copy of its item (another update), the same diff text.
  const draw = (tick: number) =>
    root!.render(
      <div className="feed-detail-scroll" data-tick={tick}>
        <DiffPreview attachment={{ ...attachment }} />
      </div>,
    );
  await act(async () => draw(0));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return { pane: host.querySelector<HTMLElement>(".feed-detail-scroll")!, draw };
}

const lines = () => host.querySelectorAll(".feed-diff-line");
// The nearest component above each line's node: the line itself once memoized, the preview before.
const renders = mountedRowRenders(lines);

async function measure(n: number) {
  const { pane, draw } = await mount(n);
  const box = host.querySelector<HTMLElement>(".feed-diff-lines")!;
  const mounted = { lines: lines().length, nodes: box.querySelectorAll("*").length };

  const rects = { calls: 0 };
  const original = dom.window.Element.prototype.getBoundingClientRect;
  dom.window.Element.prototype.getBoundingClientRect = function (this: Element) {
    rects.calls++;
    return original.call(this);
  };
  renders.mark();
  await act(async () => {
    pane.scrollTop += LINE;
    pane.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const scroll = { renders: renders.since(), rects: rects.calls };
  dom.window.Element.prototype.getBoundingClientRect = original;

  renders.mark();
  await act(async () => draw(1));
  const redraw = renders.since();
  return { n, mounted, scroll, redraw };
}

test("a diff of 1,000 and 10,000 lines mounts the same lines, and one event draws only the lines it changed", async () => {
  const small = await measure(1_000);
  act(() => root?.unmount());
  const large = await measure(10_000);
  console.log(JSON.stringify({ small, large }));

  // Rule 1: the pane's lines (420 / 14) and about one viewport each side, not the diff.
  for (const run of [small, large]) {
    expect(run.mounted.lines).toBeGreaterThan(20);
    expect(run.mounted.lines).toBeLessThanOrEqual(95);
  }
  expect(Math.abs(large.mounted.lines - small.mounted.lines)).toBeLessThanOrEqual(small.mounted.lines * 0.1);
  expect(Math.abs(large.mounted.nodes - small.mounted.nodes)).toBeLessThanOrEqual(small.mounted.nodes * 0.1);

  for (const run of [small, large]) {
    // Rule 2: a one-line scroll draws only the line it brings in; the same diff again draws none.
    expect(run.scroll.renders).toBeLessThanOrEqual(2);
    expect(run.redraw).toBe(0);
  }
  // Rule 3: a scroll reads no row's layout, at any length.
  expect(large.scroll.rects).toBe(small.scroll.rects);
});

test("a copy across lines that are not mounted copies them from the diff", async () => {
  await mount(1_000);
  const rows = [...lines()] as HTMLElement[];
  expect(Number(rows.at(-1)!.dataset.index)).toBeLessThan(999);
  // From "-0,4" on the first line to the very end of the diff.
  const range = dom.window.document.createRange();
  range.setStart(rows[0]!.firstChild!, 4);
  range.setEndAfter(host.querySelector(".feed-diff-lines")!);
  const selection = dom.window.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
  let copied = "";
  const event = new dom.window.Event("copy", { bubbles: true, cancelable: true }) as Event & {
    clipboardData: { setData(type: string, text: string): void };
  };
  event.clipboardData = { setData: (_type, text) => (copied = text) };
  dom.window.document.dispatchEvent(event);
  expect(event.defaultPrevented).toBe(true);
  expect(copied).toBe(diffLines(1_000).join("\n").slice(4));

  // A selection inside the mounted lines is the browser's to copy, as before.
  range.setStart(rows[1]!.firstChild!, 0);
  range.setEnd(rows[3]!.firstChild!, 4);
  const inside = new dom.window.Event("copy", { bubbles: true, cancelable: true });
  dom.window.document.dispatchEvent(inside);
  expect(inside.defaultPrevented).toBe(false);
});

test("the line a selection starts on stays mounted while the pane scrolls far past it", async () => {
  const { pane } = await mount(1_000);
  const anchor = [...lines()][3] as HTMLElement;
  await act(async () => anchor.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true })));
  await act(async () => {
    pane.scrollTop += LINE * 400;
    pane.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(anchor.isConnected).toBe(true);
  expect(Number((lines()[1] as HTMLElement).dataset.index)).toBeGreaterThan(300);
});

test("a row's preview still shows its first lines and an ellipsis", async () => {
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  const text = diffLines(20).join("\n");
  await act(async () =>
    root!.render(
      <DiffPreview attachment={{ id: "a", name: "x.diff", mime: "text/x-diff", size: 0, text }} maxLines={6} />,
    ),
  );
  expect([...lines()].map((line) => line.textContent)).toEqual([...diffLines(6), "…"]);
});
