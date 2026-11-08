// The bookmarks bar rendered in a DOM: only the items that fit are in the document (a bar of five
// thousand links renders a handful), the chevron and Other Bookmarks show when they should, a click
// opens with the native bar's dispositions, a folder asks for its menu under itself, and the
// host hears one layout report per change.
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

const words = { barTitle: "Bookmarks Bar", more: "More Bookmarks", emptyHint: "Drag a link here" };
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

async function render(items: Bookmark[], width: number, hasOther = false) {
  const events: string[] = [];
  const layouts: unknown[] = [];
  const host = dom.window.document.getElementById("root")!;
  const root: Root = createRoot(host);
  await act(async () => {
    root.render(
      <BookmarksBar
        snapshot={{
          loaded: true,
          profile: "default",
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
      />,
    );
  });
  return { host, root, events, layouts };
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
