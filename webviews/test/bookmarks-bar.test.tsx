// The bookmarks bar rendered in a DOM: only the items that fit are in the document (a bar of five
// thousand links renders a handful), the chevron and Other Bookmarks show when they should, a click
// opens with the native bar's dispositions, a folder asks for its menu under itself, and the
// host hears one layout report per change, the profile's own included.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { Bookmark } from "../src/pages/bookmarks/types";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MouseEvent",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
});

afterAll(() => {
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { BookmarksBar } = await import("../src/browser-chrome/bookmarks-bar/BookmarksBar");

const words = {
  barTitle: "Bookmarks Bar",
  more: "More Bookmarks",
  emptyHint: "Drag a link here",
};
const link = (index: number, kind: Bookmark["kind"] = "url"): Bookmark => ({
  id: `bm_${index}`,
  browser_profile_id: "default",
  parent: "bar",
  kind,
  index,
  title: `Item ${index}`,
  url: kind === "url" ? `https://item-${index}.example/` : undefined,
  created_ms: 0,
});

async function render(items: Bookmark[], width: number | undefined, hasOther = false, profile = "default") {
  const events: string[] = [];
  const layouts: unknown[] = [];
  const host = dom.window.document.getElementById("root")!;
  const root: Root = createRoot(host);
  const draw = (items: Bookmark[], profile: string) =>
    act(async () => {
      root.render(element(items, profile));
    });
  const element = (items: Bookmark[], profile: string) => (
    <BookmarksBar
      snapshot={{
        loaded: true,
        profile,
        otherTitle: "Other Bookmarks",
        revision: 1,
        items,
        hasOther,
        icons: {},
      }}
      words={words}
      width={width}
      measure={(text) => text.length * 6}
      onOpen={(node, disposition) => events.push(`open ${node.id} ${disposition}`)}
      onFolder={(node, anchor) => events.push(`folder ${node.id} ${typeof anchor.height}`)}
      onOverflow={(shown) => events.push(`overflow ${shown}`)}
      onOther={() => events.push("other")}
      onContextMenu={(id) => events.push(`menu ${id}`)}
      onMove={() => undefined}
      onDrop={() => undefined}
      onIcons={(nodes) => events.push(`icons ${nodes.length}`)}
      onLayout={(laidOut) => layouts.push(laidOut)}
    />
  );
  await draw(items, profile);
  return { host, root, events, layouts, draw };
}

test("a bar of five thousand links renders only what fits, the rest behind the chevron", async () => {
  const items = Array.from({ length: 5_000 }, (_, index) => link(index));
  const { host, root, events, layouts } = await render(items, 640);
  const rendered = host.querySelectorAll(".bb-item:not(.bb-chevron)");
  expect(rendered.length).toBeGreaterThan(0);
  expect(rendered.length).toBeLessThan(12);
  expect(host.querySelector(".bb-chevron")).not.toBeNull();
  expect(events.filter((event) => event.startsWith("icons"))).toEqual([`icons ${rendered.length}`]);
  expect(layouts).toHaveLength(1);
  expect((layouts[0] as { overflow: string[] }).overflow).toHaveLength(5_000 - rendered.length);
  await act(async () => (host.querySelector(".bb-chevron") as HTMLElement).click());
  expect(events).toContain(`overflow ${rendered.length}`);
  act(() => root.unmount());
});

test("clicks open as the native bar's; a folder asks for its menu; the empty bar shows the hint", async () => {
  const { host, root, events } = await render([link(0), link(1, "folder")], 640, true);
  const [first, folder] = Array.from(host.querySelectorAll<HTMLElement>(".bb-item:not(.bb-other)"));
  await act(async () => first!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, metaKey: true })));
  await act(async () => folder!.click());
  await act(async () => (host.querySelector(".bb-other") as HTMLElement).click());
  expect(events).toContain("open bm_0 backgroundTab");
  expect(events).toContain("folder bm_1 number");
  expect(events).toContain("other");
  expect(host.querySelector(".bb-chevron")).toBeNull();
  act(() => root.unmount());
  const empty = await render([], 640, true);
  expect(empty.host.querySelector(".bb-empty")?.textContent).toBe("Drag a link here");
  act(() => empty.root.unmount());
});

test("a page lent to another profile's bar reports again when both bars are empty", async () => {
  const { root, layouts, draw } = await render([], 640, false, "work");
  expect(layouts).toEqual([{ profile: "work", visible: [], overflow: [] }]);
  await draw([], "work");
  expect(layouts).toHaveLength(1);
  await draw([], "personal");
  expect(layouts).toEqual([
    { profile: "work", visible: [], overflow: [] },
    { profile: "personal", visible: [], overflow: [] },
  ]);
  act(() => root.unmount());
});

test("a middle click on a folder opens its menu; on a link it opens a background tab", async () => {
  const { host, root, events } = await render([link(0), link(1, "folder")], 640);
  const [first, folder] = Array.from(host.querySelectorAll<HTMLElement>(".bb-item"));
  const middle = () => new dom.window.MouseEvent("auxclick", { bubbles: true, button: 1 });
  await act(async () => folder!.dispatchEvent(middle()));
  await act(async () => first!.dispatchEvent(middle()));
  expect(events).toContain("folder bm_1 number");
  expect(events).toContain("open bm_0 backgroundTab");
  act(() => root.unmount());
});

test("with no width given, the bar lays out from its own box: nothing past it or under Other Bookmarks", async () => {
  const proto = dom.window.HTMLElement.prototype;
  const original = proto.getBoundingClientRect;
  proto.getBoundingClientRect = function (this: HTMLElement) {
    const width = this.classList.contains("bb-bar") ? 360 : 0;
    return { x: 0, y: 0, left: 0, top: 0, right: width, bottom: 28, width, height: 28, toJSON: () => ({}) };
  };
  try {
    const items = Array.from({ length: 40 }, (_, index) => link(index));
    const { host, root, layouts } = await render(items, undefined, true);
    const other = host.querySelector<HTMLElement>(".bb-other")!;
    const otherLeft = 360 - Number.parseFloat(other.style.right) - Number.parseFloat(other.style.width);
    const ends = Array.from(host.querySelectorAll<HTMLElement>(".bb-item:not(.bb-other)")).map(
      (item) => Number.parseFloat(item.style.left) + Number.parseFloat(item.style.width),
    );
    expect(ends.length).toBeGreaterThan(1);
    expect(Math.max(...ends)).toBeLessThanOrEqual(otherLeft);
    expect((layouts.at(-1) as { overflow: string[] }).overflow.length).toBeGreaterThan(0);
    act(() => root.unmount());
  } finally {
    proto.getBoundingClientRect = original;
  }
});

test("a middle press opens once on its release, with or without an auxclick after it", async () => {
  const { host, root, events } = await render([link(0), link(1, "folder")], 640);
  const [first, folder] = Array.from(host.querySelectorAll<HTMLElement>(".bb-item"));
  const fire = (target: HTMLElement, type: string) =>
    act(async () => void target.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, button: 1 })));
  const opens = () => events.filter((event) => event === "open bm_0 backgroundTab").length;

  // Current WebKit: pointer and mouse events, then auxclick.
  for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "auxclick"]) await fire(first!, type);
  expect(opens()).toBe(1);
  // Older WebKit: no auxclick, and the pointer events may be missing too.
  for (const type of ["mousedown", "mouseup"]) await fire(first!, type);
  expect(opens()).toBe(2);
  // A release with no press on the item (dragged in from elsewhere) opens nothing.
  await fire(first!, "mouseup");
  expect(opens()).toBe(2);
  // A folder's middle press opens its menu once.
  for (const type of ["pointerdown", "pointerup", "mouseup", "auxclick"]) await fire(folder!, type);
  expect(events.filter((event) => event === "folder bm_1 number")).toHaveLength(1);
  act(() => root.unmount());
});
