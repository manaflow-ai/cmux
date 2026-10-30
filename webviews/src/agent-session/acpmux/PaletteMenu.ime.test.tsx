import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PaletteMenu, paletteSections } from "./PaletteMenu";
import { translate, type Translate } from "./i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  container = dom.window.document.querySelector("main")!;
  root = createRoot(container);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

test("composition Enter does not dispatch or close, then plain Enter does", async () => {
  let picks = 0;
  await act(async () =>
    root!.render(
      <PaletteMenu
        label="Add"
        button={<span>+</span>}
        sections={[
          {
            title: "Tools",
            choices: [{ id: "tool", name: "Tool", description: "Run tool" }],
            onPick: () => {
              picks += 1;
            },
          },
        ]}
      />,
    ),
  );
  const trigger = container.querySelector<HTMLButtonElement>(".acpmux-picker-button")!;
  await act(async () => trigger.click());
  const input = container.querySelector<HTMLInputElement>("input[role=combobox]")!;
  const composing = new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, isComposing: true });
  Object.defineProperty(composing, "keyCode", { value: 229 });
  await act(async () => input.dispatchEvent(composing));
  expect(picks).toBe(0);
  expect(trigger.getAttribute("aria-expanded")).toBe("true");
  await act(async () => input.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
  expect(picks).toBe(1);
  expect(trigger.getAttribute("aria-expanded")).toBe("false");
});

test("Home and End edit the search input; only the listbox navigates first and last", async () => {
  await act(async () =>
    root!.render(
      <PaletteMenu
        label="Add"
        button="+"
        sections={[
          {
            title: "Tools",
            choices: [
              { id: "first", name: "First" },
              { id: "last", name: "Last" },
            ],
          },
        ]}
      />,
    ),
  );
  await act(async () => container.querySelector<HTMLButtonElement>("button")!.click());
  const input = container.querySelector<HTMLInputElement>("input")!;
  const first = input.getAttribute("aria-activedescendant");
  for (const key of ["Home", "End"])
    for (const shiftKey of [false, true]) {
      const event = new dom!.window.KeyboardEvent("keydown", { key, shiftKey, bubbles: true, cancelable: true });
      await act(async () => input.dispatchEvent(event));
      expect(event.defaultPrevented).toBe(false);
      expect(input.getAttribute("aria-activedescendant")).toBe(first);
    }
  const list = container.querySelector<HTMLElement>("[role=listbox]")!;
  await act(async () => list.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "End", bubbles: true })));
  expect(input.getAttribute("aria-activedescendant")).not.toBe(first);
  await act(async () => list.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Home", bubbles: true })));
  expect(input.getAttribute("aria-activedescendant")).toBe(first);
});

test("a rejected host action keeps the palette open and reports its source error", async () => {
  const failed = Promise.reject(new Error("Browser unavailable"));
  void failed.catch(() => {});
  const calls: string[] = [];
  const sections = paletteSections(
    (id) => {
      calls.push(id);
      return failed;
    },
    translate,
    [
      {
        id: "browser",
        section: "tools",
        name: "Browser",
        description: "Open a browser",
        icon: "browser",
        keywords: [],
        action: { kind: "command", id: "openBrowser" },
      },
    ],
  );
  await act(async () => root!.render(<PaletteMenu label="Add" button="+" sections={sections} />));
  const trigger = container.querySelector<HTMLButtonElement>("button")!;
  await act(async () => trigger.click());
  await act(async () =>
    container
      .querySelector<HTMLInputElement>("input")!
      .dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
  );
  expect(calls).toEqual(["openBrowser"]);
  expect(trigger.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector("[role=alert]")?.textContent).toContain("Browser unavailable");
});

test("palette sections and search use actual Japanese translations", async () => {
  const t: Translate = (key, values) => translate(key, values, "ja");
  const sections = paletteSections(
    () => {},
    t,
    ["tools", "apps", "sessions", "tabs"].map((section) => ({
      id: section,
      section: section as "tools" | "apps" | "sessions" | "tabs",
      name: section,
      description: section,
      icon: "terminal",
      keywords: [],
      action: { kind: "command" as const, id: section },
    })),
  );
  expect(sections.map((section) => section.title)).toEqual(["ツール", "アプリ", "セッション", "開いているタブ"]);
});

for (const button of [1, 2]) {
  test(`mouse button ${button} cannot open or dispatch the palette`, async () => {
    let picks = 0;
    await act(async () =>
      root!.render(
        <PaletteMenu
          label="Add"
          button="+"
          sections={[
            {
              title: "Tools",
              choices: [{ id: "tool", name: "Tool" }],
              onPick: () => {
                picks += 1;
              },
            },
          ]}
        />,
      ),
    );
    const trigger = container.querySelector<HTMLButtonElement>("button")!;
    const press = new dom!.window.MouseEvent("pointerdown", { bubbles: true, button });
    Object.defineProperty(press, "pointerType", { value: "mouse" });
    await act(async () => trigger.dispatchEvent(press));
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    await act(async () => trigger.click());
    await act(async () =>
      container
        .querySelector('[role="option"]')!
        .dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true, button })),
    );
    expect(picks).toBe(0);
    expect(trigger.getAttribute("aria-expanded")).toBe("true");
    await act(async () =>
      container
        .querySelector('[role="option"]')!
        .dispatchEvent(new dom!.window.MouseEvent("mousedown", { bubbles: true, button: 0 })),
    );
    expect(picks).toBe(1);
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
  });
}
