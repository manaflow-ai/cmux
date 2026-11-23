// The heading outline rail (OutlineRail.tsx, outline.ts): a dash per heading, none for a file with
// fewer than two; pointing at it or a click opens the contents, a heading there scrolls through the
// router's `#heading` path; the current section follows the scroll.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import type { HeadingTarget } from "./links";
import { activeHeading, Outline } from "./outline";
import { OutlineRail } from "./OutlineRail";
import { L } from "./strings";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
// Frames are queued and run by frame(), so a test paints the next frame without waiting on the clock.
const frames = new Map<number, () => void>();
let lastFrame = 0;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  requestAnimationFrame: (run: () => void) => {
    frames.set(++lastFrame, run);
    return lastFrame;
  },
  cancelAnimationFrame: (id: number) => frames.delete(id),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
const { createRoot } = await import("react-dom/client");
const strings = createStrings(table);
const frame = async () => {
  const due = [...frames.values()];
  frames.clear();
  for (const run of due) run();
};

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope: globals });
});

const heading = (text: string, level: number, pos: number): HeadingTarget => ({
  slug: text.toLowerCase().replace(/ /g, "-"),
  text,
  level,
  pos,
});

const HEADINGS = [
  heading("Plan", 1, 0),
  heading("Goals", 2, 10),
  heading("Staff week", 3, 20),
  heading("Risks", 2, 30),
];

test("the current heading is the last one at or above the line", () => {
  const tops = [0, 300, 700, 1200];
  expect(activeHeading(4, (index) => tops[index]!, -10)).toBe(-1);
  expect(activeHeading(4, (index) => tops[index]!, 0)).toBe(0);
  expect(activeHeading(4, (index) => tops[index]!, 650)).toBe(1);
  expect(activeHeading(4, (index) => tops[index]!, 5000)).toBe(3);
});

async function mount(headings: readonly HeadingTarget[]) {
  const went: string[] = [];
  const scroller = document.createElement("main");
  document.body.append(scroller);
  // jsdom lays nothing out: the pane scrolls by a plain property, 2000px of document in 400px.
  Object.defineProperty(scroller, "scrollTop", { value: 0, writable: true });
  Object.defineProperty(scroller, "clientHeight", { value: 400 });
  Object.defineProperty(scroller, "scrollHeight", { value: 2000 });
  // Each heading's element sits 100px under the one before it; the pane's top is at 0.
  const tops = new Map(headings.map((item, index) => [item.pos, index * 100]));
  const element = (pos: number) => {
    const node = document.createElement("h2");
    node.getBoundingClientRect = () => ({ top: (tops.get(pos) ?? 0) - scroller.scrollTop }) as DOMRect;
    return node;
  };
  const outline = new Outline({ element, scroller: () => scroller, go: (slug) => went.push(slug) });
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  await act(async () => {
    root.render(<OutlineRail outline={outline} strings={strings} />);
    outline.setHeadings(headings);
    await frame();
  });
  const unmount = async () => {
    await act(async () => root.unmount());
    host.remove();
    scroller.remove();
  };
  return { host, outline, scroller, went, unmount };
}

test("fewer than two headings: no rail", async () => {
  const { host, unmount } = await mount([heading("Only", 1, 0)]);
  expect(host.querySelector(".md-outline")).toBeNull();
  await unmount();
});

test("a dash per heading, deeper levels further in, the current section marked", async () => {
  const { host, unmount } = await mount(HEADINGS);
  const dashes = [...host.querySelectorAll<HTMLElement>(".md-outline-dash")];
  expect(dashes.map((dash) => dash.dataset.depth)).toEqual(["0", "1", "2", "1"]);
  expect(dashes.findIndex((dash) => dash.dataset.active !== undefined)).toBe(0);
  expect(host.querySelector(".md-outline")?.getAttribute("aria-label")).toBe(strings.t(L.outlineLabel));
  await unmount();
});

test("the current section follows the scroll", async () => {
  const { host, scroller, unmount } = await mount(HEADINGS);
  await act(async () => {
    scroller.scrollTop = 150;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    await frame();
  });
  const dashes = [...host.querySelectorAll<HTMLElement>(".md-outline-dash")];
  expect(dashes.findIndex((dash) => dash.dataset.active !== undefined)).toBe(1);
  await unmount();
});

test("a click opens the contents; a heading there scrolls to it and closes them", async () => {
  const { host, went, unmount } = await mount(HEADINGS);
  const rail = host.querySelector<HTMLButtonElement>(".md-outline-rail")!;
  expect(host.querySelector(".md-outline-panel")).toBeNull();
  await act(async () => rail.click());
  const items = [...host.querySelectorAll<HTMLButtonElement>(".md-outline-item")];
  expect(items.map((item) => item.textContent)).toEqual(["Plan", "Goals", "Staff week", "Risks"]);
  expect(rail.getAttribute("aria-expanded")).toBe("true");
  await act(async () => items[3]!.click());
  expect(went).toEqual(["risks"]);
  expect(host.querySelector(".md-outline-panel")).toBeNull();
  await unmount();
});

test("pointing opens the contents and leaving closes them; a pinned panel stays", async () => {
  const { host, unmount } = await mount(HEADINGS);
  const nav = host.querySelector<HTMLElement>(".md-outline")!;
  const rail = host.querySelector<HTMLButtonElement>(".md-outline-rail")!;
  // React makes pointerenter and pointerleave from pointerover and pointerout and their related target.
  const enter = () =>
    rail.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true, relatedTarget: document.body }));
  const leave = () =>
    nav.dispatchEvent(new dom.window.MouseEvent("pointerout", { bubbles: true, relatedTarget: document.body }));
  await act(async () => enter());
  expect(host.querySelector(".md-outline-panel")).not.toBeNull();
  await act(async () => leave());
  expect(host.querySelector(".md-outline-panel")).toBeNull();
  await act(async () => rail.click());
  await act(async () => leave());
  expect(host.querySelector(".md-outline-panel")).not.toBeNull();
  await unmount();
});
