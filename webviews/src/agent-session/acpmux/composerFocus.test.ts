import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { focusedArea, routesToComposer } from "./composerFocus";

const dom = new JSDOM(
  `<!doctype html><body>
    <button id="row">Session</button>
    <input id="search" />
    <div role="menu"><button id="item">Model</button></div>
    <div class="acpmux-composer-box"><div id="field" contenteditable="true"></div></div>
  </body>`,
  { pretendToBeVisual: true, virtualConsole: new VirtualConsole() },
);
const document = dom.window.document;
const element = (id: string) => document.getElementById(id)!;
afterAll(() => dom.window.close());

const key = (value: string, extra: Partial<Parameters<typeof routesToComposer>[0]> = {}) => ({
  key: value,
  metaKey: false,
  ctrlKey: false,
  altKey: false,
  isComposing: false,
  defaultPrevented: false,
  ...extra,
});

describe("composer focus", () => {
  test("a printed key outside any text field goes to the composer", () => {
    expect(routesToComposer(key("h"), element("row"))).toBe(true);
    expect(routesToComposer(key("H"), document.body)).toBe(true);
    expect(routesToComposer(key("h"), null)).toBe(true);
  });

  test("text fields, menus, chords, named keys and claimed keys stay where they are", () => {
    expect(routesToComposer(key("h"), element("search"))).toBe(false);
    expect(routesToComposer(key("h"), element("field"))).toBe(false);
    expect(routesToComposer(key("h"), element("item"))).toBe(false);
    expect(routesToComposer(key("k", { metaKey: true }), document.body)).toBe(false);
    expect(routesToComposer(key("c", { ctrlKey: true }), document.body)).toBe(false);
    expect(routesToComposer(key("Enter"), document.body)).toBe(false);
    expect(routesToComposer(key("ArrowDown"), document.body)).toBe(false);
    expect(routesToComposer(key("y", { defaultPrevented: true }), element("row"))).toBe(false);
    expect(routesToComposer(key("a", { isComposing: true }), document.body)).toBe(false);
  });

  test("space on a button presses it instead of typing", () => {
    expect(routesToComposer(key(" "), element("row"))).toBe(false);
    expect(routesToComposer(key(" "), document.body)).toBe(true);
  });

  test("the focused area reads composer, none, or the element", () => {
    expect(focusedArea(element("field"))).toBe("composer");
    expect(focusedArea(document.body)).toBe("none");
    expect(focusedArea(null)).toBe("none");
    expect(focusedArea(element("row"))).toBe("button#row");
  });
});
