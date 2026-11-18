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

test("a copy across lines that are not mounted keeps the spaces the selection starts and ends with", async () => {
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  const text = diffLines(1_000).join("\n");
  await act(async () =>
    root!.render(
      <div className="feed-detail-scroll">
        <DiffPreview attachment={{ id: "a", name: "my change.diff", mime: "text/x-diff", size: 0, text }} />
        <p id="after">Reply below</p>
      </div>,
    ),
  );
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(Number((lines()[lines().length - 1] as HTMLElement).dataset.index)).toBeLessThan(999);
  const name = [...host.querySelector(".feed-diff-name")!.childNodes].find((node) => node.nodeType === 3)!;
  expect(name.textContent).toBe("my change.diff");
  // From " change.diff" (the attachment's name, above the lines) to "Reply " (below them): the range
  // reads both ends' spaces, and the copy keeps them.
  const range = dom.window.document.createRange();
  range.setStart(name, "my".length);
  range.setEnd(host.querySelector("#after")!.firstChild!, "Reply ".length);
  const selection = dom.window.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
  let copied = "";
  const event = new dom.window.Event("copy", { bubbles: true, cancelable: true }) as Event & {
    clipboardData: { setData(type: string, text: string): void };
  };
  event.clipboardData = { setData: (_type, data) => (copied = data) };
  dom.window.document.dispatchEvent(event);
  expect(event.defaultPrevented).toBe(true);
  expect(copied).toBe([" change.diff", text, "Reply "].join("\n"));
});

test("select-all copies the whole diff, its end in the block below the window, and mounts no more lines", async () => {
  const { pane } = await mount(10_000);
  const box = host.querySelector<HTMLElement>(".feed-diff-lines")!;
  const whole = diffLines(10_000).join("\n");
  const copy = () => {
    let copied = "";
    const event = new dom.window.Event("copy", { bubbles: true, cancelable: true }) as Event & {
      clipboardData: { setData(type: string, text: string): void };
    };
    event.clipboardData = { setData: (_type, text) => (copied = text) };
    dom.window.document.dispatchEvent(event);
    return { copied, taken: event.defaultPrevented };
  };
  // Chromium and WebKit end select-all at the block standing in for the lines below the window, at
  // its offset 0: from the first line (or the block above the window) to there.
  for (const scrolled of [0, LINE * 5_000]) {
    await act(async () => {
      pane.scrollTop = scrolled;
      pane.dispatchEvent(new dom.window.Event("scroll"));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    const mounted = lines().length;
    const first = box.firstElementChild as HTMLElement;
    const below = box.lastElementChild as HTMLElement;
    expect(below.dataset.gap).toBeDefined();
    const range = dom.window.document.createRange();
    range.setStart(first.dataset.gap === undefined ? first.firstChild! : first, 0);
    range.setEnd(below, 0);
    const selection = dom.window.getSelection()!;
    selection.removeAllRanges();
    selection.addRange(range);
    const { copied, taken } = copy();
    expect(taken).toBe(true);
    expect(copied).toBe(whole);
    expect(lines().length).toBe(mounted);

    // A scroll after select-all keeps the block below the window the same element, so the
    // selection's end stays in it (a new one would leave the end at the last mounted line).
    await act(async () => {
      pane.scrollTop += LINE * 200;
      pane.dispatchEvent(new dom.window.Event("scroll"));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(below.isConnected).toBe(true);
    expect(copy().copied).toBe(whole);
  }

  // Scrolled to the last line: the block below has no height left, and stays, holding the end.
  const below = box.lastElementChild as HTMLElement;
  await act(async () => {
    pane.scrollTop = LINE * 10_000;
    pane.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(host.querySelector('.feed-diff-line[data-index="9999"]')).not.toBeNull();
  expect(below.isConnected).toBe(true);
  expect(copy().copied).toBe(whole);
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

test("a selection made with the keyboard keeps its lines mounted while the pane scrolls far past them, and copies whole", async () => {
  const { pane } = await mount(1_000);
  const row = (index: number) => host.querySelector<HTMLElement>(`.feed-diff-line[data-index="${index}"]`);
  const start = row(3)!;
  const end = row(8)!;
  // No pointer: a selection from "ne 3" on line 3 to " li" on line 8, as Shift and the arrows (or
  // find, or a script) make one. The browser says so with a selectionchange (jsdom too, a task later).
  await act(async () => {
    dom.window.getSelection()!.setBaseAndExtent(start.firstChild!, 2, end.firstChild!, 3);
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  await act(async () => {
    pane.scrollTop += LINE * 400;
    pane.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(row(5)).toBeNull();
  expect(Number((lines()[2] as HTMLElement).dataset.index)).toBeGreaterThan(300);
  expect(start.isConnected).toBe(true);
  expect(end.isConnected).toBe(true);
  const selection = dom.window.getSelection()!;
  expect(selection.anchorNode).toBe(start.firstChild);
  expect(selection.focusNode).toBe(end.firstChild);

  let copied = "";
  const event = new dom.window.Event("copy", { bubbles: true, cancelable: true }) as Event & {
    clipboardData: { setData(type: string, text: string): void };
  };
  event.clipboardData = { setData: (_type, text) => (copied = text) };
  dom.window.document.dispatchEvent(event);
  expect(event.defaultPrevented).toBe(true);
  const shown = diffLines(9).slice(3);
  expect(copied).toBe([shown[0]!.slice(2), ...shown.slice(1, -1), shown.at(-1)!.slice(0, 3)].join("\n"));
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

// A press pins its line until the selection says where it is. Each press used to add its line to
// the pinned ones for good: where a press leaves no selection end in the lines, no selection change
// came to clear them, so every line pressed stayed mounted. (In Chromium a click on a line leaves a
// caret there, whose selection change clears them: feed-diff-stale-pins-browser.test.ts.)
const scrollTo = async (pane: HTMLElement, top: number) =>
  act(async () => {
    pane.scrollTop = top * LINE;
    pane.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
const lineAt = (index: number) => host.querySelector<HTMLElement>(`.feed-diff-line[data-index="${index}"]`);
/** A press and release on a line; `caret` puts the caret where it pressed, as a click in the lines does. */
async function click(index: number, { caret = false, shift = false, char = 2 } = {}) {
  const row = lineAt(index)!;
  await act(async () => {
    row.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true, shiftKey: shift }));
    const selection = dom.window.getSelection()!;
    if (shift) selection.extend(row.firstChild!, char);
    else if (caret) selection.setBaseAndExtent(row.firstChild!, char, row.firstChild!, char);
    // The browser says so with a selectionchange, a task later (jsdom too).
    await new Promise((resolve) => setTimeout(resolve, 0));
    row.dispatchEvent(new dom.window.MouseEvent("pointerup", { bubbles: true, shiftKey: shift }));
  });
}
/** The mounted lines outside the window around the line at the pane's top (one viewport, 30 lines, each side). */
const outsideWindow = (top: number) =>
  [...lines()].map((row) => Number((row as HTMLElement).dataset.index)).filter((at) => at < top - 30 || at > top + 60);
function copySelection() {
  let text = "";
  const event = new dom.window.Event("copy", { bubbles: true, cancelable: true }) as Event & {
    clipboardData: { setData(type: string, text: string): void };
  };
  event.clipboardData = { setData: (_type, data) => (text = data) };
  dom.window.document.dispatchEvent(event);
  return { text, taken: event.defaultPrevented };
}

for (const caret of [false, true])
  test(`50 presses on lines far apart that ${caret ? "put the caret" : "select nothing"} leave mounted only the window${caret ? " and the caret's line" : ""}`, async () => {
    const { pane } = await mount(10_000);
    await scrollTo(pane, 9_600);
    const window = lines().length;
    dom.window.getSelection()!.removeAllRanges();
    const pressed: number[] = [];
    for (let at = 0; at < 50; at++) {
      const index = at * 190 + 5;
      await scrollTo(pane, index - 2);
      await click(index, { caret });
      pressed.push(index);
    }
    await scrollTo(pane, 9_600);
    const extra = outsideWindow(9_600);
    console.log(JSON.stringify({ caret, window, mounted: lines().length, extra: extra.length }));
    expect(extra).toEqual(caret ? [pressed.at(-1)!] : []);
    expect(lines().length).toBeLessThanOrEqual(window + (caret ? 1 : 0));
    if (!caret) return;

    // A Shift-click far above extends from the caret, whose line stayed mounted, and copies what it covers.
    const anchor = lineAt(9_315)!;
    await scrollTo(pane, 0);
    expect(anchor.isConnected).toBe(true);
    await click(20, { shift: true, char: 3 });
    const selection = dom.window.getSelection()!;
    expect(selection.anchorNode).toBe(anchor.firstChild!);
    expect(selection.anchorOffset).toBe(2);
    expect(selection.focusNode).toBe(lineAt(20)!.firstChild!);
    expect(outsideWindow(0)).toEqual([9_315]);
    const all = diffLines(10_000);
    const expected = [all[20]!.slice(3), ...all.slice(21, 9_315), all[9_315]!.slice(0, 2)].join("\n");
    expect(copySelection()).toEqual({ text: expected, taken: true });
    // Scrolled far from both ends: both stay mounted, and only they.
    await scrollTo(pane, 5_000);
    expect(outsideWindow(5_000)).toEqual([20, 9_315]);
    expect(copySelection()).toEqual({ text: expected, taken: true });
  });
