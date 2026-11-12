// The scroll area's keyboard focus and its Corner. Base UI makes an overflowing viewport a Tab stop; the page
// ring (desktop.css) is an outline outside it that the root's `overflow: hidden` clips, so the viewport draws
// the shared ring inset, keyboard-gated like every `:focus-visible`. A viewport with a role or its own
// `data-focus-ring` keeps that rule instead. With both bars, Base UI's Corner fills the square they share.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ScrollArea } from "./ScrollArea";
import { settleReact } from "../../test/support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | null = null;
let root: Root | null = null;

/** Every box is 100 px; content is 400 px tall, and 400 px wide when `wide`. */
async function mount(options: { horizontal?: boolean; wide?: boolean; viewportProps?: Record<string, string> } = {}) {
  dom = new JSDOM('<!doctype html><html><body><main id="root"></main></body></html>', { url: "http://localhost/" });
  const win = dom.window;
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    getComputedStyle: win.getComputedStyle.bind(win),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const box = (value: number) => ({ configurable: true, get: () => value });
  Object.defineProperties(win.HTMLElement.prototype, {
    clientHeight: box(100),
    clientWidth: box(100),
    scrollHeight: box(400),
    scrollWidth: box(options.wide ? 400 : 100),
    offsetWidth: box(6),
    offsetHeight: box(6),
  });
  root = createRoot(win.document.getElementById("root")!);
  act(() =>
    root!.render(
      <ScrollArea horizontal={options.horizontal} viewportProps={options.viewportProps}>
        <p>Rows</p>
      </ScrollArea>,
    ),
  );
  // Base UI measures the viewport in a microtask after layout, and again after the hidden state it set
  // re-renders the bars; a few turns let both land.
  for (let turn = 0; turn < 4; turn++)
    await act(async () => {
      await new Promise((done) => setTimeout(done, 0));
    });
  const viewport = win.document.querySelector<HTMLElement>("#root > div > div")!;
  return { viewport, document: win.document };
}

afterEach(async () => {
  if (root) act(() => root!.unmount());
  root = null;
  await settleReact();
  dom?.window.close();
  dom = null;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("an overflowing viewport is a Tab stop that draws the shared ring inset", async () => {
  const { viewport } = await mount();
  expect(viewport.tabIndex).toBe(0);
  // Keyboard-only (`:focus-visible`, which the build gates), skipping a viewport with a role or its own
  // data-focus-ring; the shared width and colour, inset by that width so the root's overflow clip cannot hide it.
  const gate = "[&:focus-visible:not([role],[data-focus-ring])]:";
  const classes = viewport.className.split(/\s+/);
  for (const part of [
    "outline-solid!",
    "outline-[length:var(--cmux-focus-ring-width,1.5px)]!",
    "outline-[color:var(--cmux-focus-ring-color,currentColor)]!",
    "outline-offset-[calc(-1*var(--cmux-focus-ring-width,1.5px))]!",
  ])
    expect(classes).toContain(gate + part);
});

test("a viewport that keeps a role or its own ring rule still carries the caller's props", async () => {
  const { viewport } = await mount({ viewportProps: { role: "listbox", "aria-label": "Rows" } });
  expect(viewport.getAttribute("role")).toBe("listbox");
  expect(viewport.getAttribute("aria-label")).toBe("Rows");
});

test("both bars showing draw Base UI's Corner where they meet", async () => {
  const { document } = await mount({ horizontal: true, wide: true });
  const corner = document.querySelector<HTMLElement>(".cmux-scrollbar-corner");
  expect(corner).not.toBeNull();
  expect(corner!.getAttribute("aria-hidden")).toBe("true");
});

test("one bar draws no Corner", async () => {
  expect((await mount({ horizontal: true })).document.querySelector(".cmux-scrollbar-corner")).toBeNull();
});

test("a vertical-only scroller draws no Corner", async () => {
  expect((await mount({ wide: true })).document.querySelector(".cmux-scrollbar-corner")).toBeNull();
});
