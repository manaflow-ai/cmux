// Back returns to where the person was (swipeNavigation/restore.ts): the scroll + selection snapshot a
// page notes when it leaves a history entry and restores in one frame when Back shows the entry
// again, without re-rendering anything.
import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { SnapshotStore, restorePage, snapshotPage } from "../src/swipeNavigation/restore";

const dom = new JSDOM("<!doctype html><body></body>", { url: "http://localhost/", pretendToBeVisual: true });
const doc = dom.window.document;
const scope = globalThis as Record<string, unknown>;
const saved = { Node: scope.Node, Element: scope.Element, HTMLElement: scope.HTMLElement };
Object.assign(scope, { Node: dom.window.Node, Element: dom.window.Element, HTMLElement: dom.window.HTMLElement });
afterAll(() => Object.assign(scope, saved));
// jsdom keeps no scroll offsets: store them per element, as an engine would.
for (const name of ["scrollTop", "scrollLeft"] as const) {
  const offsets = new WeakMap<Element, number>();
  Object.defineProperty(dom.window.Element.prototype, name, {
    configurable: true,
    get(this: Element) {
      return offsets.get(this) ?? 0;
    },
    set(this: Element, value: number) {
      offsets.set(this, value);
    },
  });
}

function page(html: string): void {
  doc.body.innerHTML = html;
  doc.getSelection()?.removeAllRanges();
}

const at = (id: string) => doc.getElementById(id);

describe("scroll and selection snapshot", () => {
  const body = `<div id=list data-scroll-key="list"><p id=para>first line of text</p></div>
    <div><div class=code><pre id=code>a long code line</pre></div></div>`;

  test("restores nested horizontal and vertical scroll and the selection in one pass", () => {
    page(body);
    const list = at("list")!;
    const code = at("code")!.parentElement!;
    list.scrollTop = 240;
    code.scrollLeft = 96;
    const text = at("para")!.firstChild!;
    const selection = doc.getSelection()!;
    selection.setBaseAndExtent(text, 6, text, 10);
    const snap = snapshotPage(doc, [list, code]);
    // Leaving the entry: everything resets (the new route rendered over it, then Back re-rendered it).
    list.scrollTop = 0;
    code.scrollLeft = 0;
    selection.removeAllRanges();
    restorePage(doc, snap);
    expect(list.scrollTop).toBe(240);
    expect(code.scrollLeft).toBe(96);
    expect(selection.toString()).toBe("line");
  });

  test("finds a re-created element by its stable key, not object identity", () => {
    page(body);
    at("list")!.scrollTop = 120;
    const snap = snapshotPage(doc, [at("list")!]);
    page(body);
    restorePage(doc, snap);
    expect(at("list")!.scrollTop).toBe(120);
  });

  test("an element that is gone is skipped, the rest still restores", () => {
    page(body);
    at("list")!.scrollTop = 50;
    const code = at("code")!.parentElement!;
    code.scrollLeft = 30;
    const snap = snapshotPage(doc, [at("list")!, code]);
    page(`<div id=list data-scroll-key="list"></div>`);
    expect(() => restorePage(doc, snap)).not.toThrow();
    expect(at("list")!.scrollTop).toBe(50);
  });

  test("the store keeps one snapshot per entry and only the newest entries", () => {
    const store = new SnapshotStore(3);
    for (const key of ["a", "b", "c", "d"]) store.set(key, { scroll: [], selection: null });
    expect(store.get("a")).toBeUndefined();
    expect(store.get("d")).toBeDefined();
    store.get("b");
    store.set("e", { scroll: [], selection: null });
    expect(store.get("b")).toBeDefined();
    expect(store.get("c")).toBeUndefined();
  });
});
