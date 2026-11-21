// l10n-allow-file: test fixture output, not shipped UI.
// A long block inside a transcript row (a finished command's output, a call's output, a read past
// the highlight limits) scrolls in its own eight-line box, and mounts only the lines in that box's
// view plus one box past each edge (lineWindow.ts). The count is the same for 1,000 lines and for
// 10,000; a scroll step swaps at most one chunk and leaves every other mounted line's node alone; the
// line at the box's top edge stays the line the reader scrolled to; a held selection keeps its lines
// mounted; Find's reveal draws the block whole, as before. jsdom has no layout, so a small fake lays
// out each box's children top to bottom: lines LINE px tall, spacers their own height.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { teardownDom } from "./support/domTeardown";
import { ShellBlock } from "../src/agent-session/acpmux/conversation/ShellBlock";
import { ToolOutput } from "../src/agent-session/acpmux/conversation/ToolOutputBody";
import { FileResultCard } from "../src/agent-session/acpmux/conversation/FileResultCard";
import { PREVIEW_LINES } from "../src/agent-session/acpmux/conversation/blockPartsModel";

const LINE = 18;
const BOX = PREVIEW_LINES * LINE;
/// The contract, from the box alone (not lineWindow.ts's constants, so the file runs against a tree
/// without it): its viewport's lines, one box past each edge, rounded out to a box of lines each way.
const WINDOW_CHUNK = PREVIEW_LINES;
const MOUNTED_MAX = 3 * PREVIEW_LINES + 2 * WINDOW_CHUNK;
const LINE_SELECTOR = ".cv-line, .cv-code-plain__line";

let dom: JSDOM;
let root: Root;
let restore: () => Promise<void>;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "cmux-page://cmux.agent/", pretendToBeVisual: true });
  const window = dom.window;
  const scope = globalThis as Record<string, unknown>;
  const keys = ["window", "document", "navigator", "HTMLElement", "Node", "getSelection", "IS_REACT_ACT_ENVIRONMENT"];
  const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Node: window.Node,
    getSelection: window.getSelection.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  installLayout(window);
  root = createRoot(window.document.getElementById("root")!);
  restore = () => teardownDom(saved, { window });
});

afterEach(async () => {
  act(() => root.unmount());
  await restore();
});

const isBox = (node: Element) => node.matches("[data-preview]");
const isLine = (node: Element) => node.matches(LINE_SELECTOR);

/// Lays every element out in one column: a box is BOX tall at the top of the page and scrolls; a
/// line is LINE tall; a spacer its style's height; anything else the sum of its children.
function installLayout(window: JSDOM["window"]) {
  const proto = window.HTMLElement.prototype;
  const scrolls = new WeakMap<Element, number>();
  const height = (node: Element): number => {
    if (node.classList.contains("cv-line-spacer")) return parseFloat((node as HTMLElement).style.height) || 0;
    if (isLine(node)) return LINE;
    let sum = 0;
    for (const child of node.children) sum += height(child);
    return sum;
  };
  const contentHeight = (box: Element) => [...box.children].reduce((sum, child) => sum + height(child), 0);
  const top = (node: Element): number => {
    if (isBox(node)) return 0;
    const parent = node.parentElement;
    if (!parent) return 0;
    let at = isBox(parent) ? -(scrolls.get(parent) ?? 0) : top(parent);
    for (let sibling = parent.firstElementChild; sibling && sibling !== node; sibling = sibling.nextElementSibling)
      at += height(sibling);
    return at;
  };
  proto.getBoundingClientRect = function (this: Element) {
    const y = top(this);
    const h = isBox(this) ? BOX : height(this);
    return { top: y, bottom: y + h, height: h, left: 0, right: 600, width: 600, x: 0, y, toJSON() {} } as DOMRect;
  };
  Object.defineProperty(proto, "clientHeight", {
    configurable: true,
    get(this: Element) {
      return isBox(this) ? BOX : height(this);
    },
  });
  Object.defineProperty(proto, "scrollHeight", {
    configurable: true,
    get(this: Element) {
      return isBox(this) ? contentHeight(this) : height(this);
    },
  });
  Object.defineProperty(proto, "scrollTop", {
    configurable: true,
    get(this: Element) {
      return scrolls.get(this) ?? 0;
    },
    set(this: Element, value: number) {
      const max = Math.max(0, contentHeight(this) - BOX);
      scrolls.set(this, Math.min(max, Math.max(0, value)));
    },
  });
}

const text = (lines: number) => Array.from({ length: lines }, (_, index) => `line ${index}`).join("\n");
const box = () => document.querySelector<HTMLElement>("[data-preview]")!;
const mounted = () => [...box().querySelectorAll<HTMLElement>(LINE_SELECTOR)];
/// The source line at the box's top edge, read off the fake layout.
const lineAtTop = () =>
  mounted()
    .find((line) => line.getBoundingClientRect().bottom > 0)!
    .textContent!.replace(/\n$/, "");

function scrollTo(y: number) {
  act(() => {
    box().scrollTop = y;
    box().dispatchEvent(new window.Event("scroll"));
  });
}

function draw(node: React.ReactNode) {
  act(() => root.render(node));
}

const shell = (lines: number, reveal = 0) => <ShellBlock command="seq" output={`${text(lines)}\n`} reveal={reveal} />;
const read = (lines: number) => (
  <FileResultCard
    id="read"
    reveal={0}
    card={{ kind: "read", read: { path: "/tmp/big.txt", start: 1, end: lines, code: text(lines) } }}
  />
);
const showAll = () =>
  act(() => document.querySelector<HTMLButtonElement>(".cv-output-more button, button.cv-output-more")?.click());

for (const [name, view, whole] of [
  ["a finished Shell block", shell, false],
  ["a finished Shell block after Show all", shell, true],
  ["a call's output", (lines: number) => <ToolOutput result={{ text: text(lines), lang: "text" }} />, false],
  ["a read past the highlight limits", read, false],
] as const) {
  test(`${name} mounts the same lines at 1,000 and 10,000, no more than its box's view and overscan`, () => {
    const counts: number[] = [];
    const nodes: number[] = [];
    for (const lines of [1_000, 10_000]) {
      // A read is drawn plain only past the highlight limit (highlightLimits.ts): read 3,000 and 10,000.
      draw(view(name.startsWith("a read") ? Math.max(lines, 3_000) : lines));
      if (whole) showAll();
      counts.push(mounted().length);
      nodes.push(document.getElementById("root")!.querySelectorAll("*").length);
      draw(null);
    }
    expect(counts[0]).toBeLessThanOrEqual(MOUNTED_MAX);
    expect(counts[1]).toBeLessThanOrEqual(MOUNTED_MAX);
    expect(Math.abs(counts[1]! - counts[0]!)).toBeLessThanOrEqual(counts[0]! * 0.1);
    expect(Math.abs(nodes[1]! - nodes[0]!)).toBeLessThanOrEqual(nodes[0]! * 0.1);
  });
}

test("a scroll step swaps at most one chunk, keeps every other line's node, and holds the line at the top", () => {
  draw(shell(10_000));
  showAll();
  const steps = [3 * LINE, 40 * LINE, 41 * LINE, 500 * LINE, 499 * LINE, 9_000 * LINE];
  for (const y of steps) {
    const before = new Set(mounted());
    scrollTo(y);
    const after = mounted();
    expect(after.length).toBeLessThanOrEqual(MOUNTED_MAX);
    expect(lineAtTop()).toBe(`line ${y / LINE}`);
    // A one-line step: no more than a chunk comes in, and every line that stays is the same node.
    if (Math.abs(y - steps[steps.indexOf(y) - 1]!) === LINE) {
      expect(after.filter((line) => !before.has(line)).length).toBeLessThanOrEqual(WINDOW_CHUNK);
      const stayed = [...before].filter((line) => after.includes(line));
      expect(stayed.length).toBeGreaterThanOrEqual(after.length - WINDOW_CHUNK);
    }
  }
  // The box's content keeps its full height: the spacers stand for every line not drawn.
  expect(box().scrollHeight).toBe(10_001 * LINE);
});

test("the read's gutter numbers the lines drawn beside them", () => {
  draw(read(10_000));
  scrollTo(5_000 * LINE);
  const gutter = document.querySelector<HTMLElement>(".cv-filepeek__gutter")!;
  const numbers = gutter.textContent!.split("\n");
  const lines = mounted();
  expect(numbers.length).toBe(lines.length);
  expect(lines[0]!.textContent).toBe(`line ${Number(numbers[0]) - 1}`);
  expect(gutter.style.paddingTop).toBe(`${(Number(numbers[0]) - 1) * LINE}px`);
});

test("a held selection keeps the lines between its ends mounted while the box scrolls away", () => {
  draw(shell(10_000));
  showAll();
  const first = mounted()[2]!;
  const selection = document.getSelection()!;
  act(() => {
    const range = document.createRange();
    range.setStart(first.firstChild!, 0);
    range.setEnd(mounted()[5]!.firstChild!, 2);
    selection.removeAllRanges();
    selection.addRange(range);
    document.dispatchEvent(new window.Event("selectionchange"));
  });
  scrollTo(200 * LINE);
  expect(first.isConnected).toBe(true);
  act(() => {
    selection.extend(mounted().at(-1)!.firstChild!, 1);
    document.dispatchEvent(new window.Event("selectionchange"));
  });
  const shown = mounted().map((line) => Number(line.textContent!.replace("line ", "")));
  // Every line from the selection's start to the window is drawn: the page's copy reads them all.
  expect(shown.slice(0, shown.indexOf(200) + 1)).toEqual(Array.from({ length: shown.indexOf(200) + 1 }, (_, i) => i));
  act(() => {
    selection.removeAllRanges();
    document.dispatchEvent(new window.Event("selectionchange"));
  });
  expect(mounted().length).toBeLessThanOrEqual(MOUNTED_MAX);
});

test("Find's reveal draws the block whole, as before", () => {
  draw(shell(1_000, 1));
  expect(mounted().length).toBe(1_001);
});

test("a screen reader meets one region named with the true line count, its lines placed in the whole", () => {
  // A finished Shell block shows its last 400 lines (toolOutputModel.ts): its first is line 9,600.
  for (const [view, name, total, firstLine] of [
    [shell(10_000), "Shell, 400 lines", 400, 9_600],
    [read(10_000), "big.txt, 10,000 lines", 10_000, 0],
  ] as const) {
    draw(view);
    expect(box().getAttribute("aria-label")).toBe(name);
    expect(box().getAttribute("tabindex")).toBe("0");
    scrollTo(200 * LINE);
    const lines = mounted().filter((line) => line.hasAttribute("role"));
    expect(lines[0]!.parentElement!.getAttribute("role")).toBe("list");
    // Every mounted line is an item at its place in the whole block, in order.
    expect(lines.map((line) => line.getAttribute("role"))).toEqual(lines.map(() => "listitem"));
    expect(lines.map((line) => line.getAttribute("aria-setsize"))).toEqual(lines.map(() => String(total)));
    const places = lines.map((line) => Number(line.getAttribute("aria-posinset")));
    expect(places).toEqual(places.map((_, index) => places[0]! + index));
    expect(lines[0]!.textContent!.startsWith(`line ${firstLine + places[0]! - 1}`)).toBe(true);
    // Scrolling on mounts the next lines, numbered on from these.
    scrollTo(208 * LINE);
    expect(Number(mounted().at(-1)!.getAttribute("aria-posinset"))).toBeGreaterThan(places.at(-1)!);
    draw(null);
  }
  // Drawn whole (Find's reveal), it is the plain block it was: no region, no list.
  draw(shell(1_000, 1));
  expect(box().hasAttribute("role")).toBe(false);
  expect(mounted()[0]!.hasAttribute("role")).toBe(false);
});
