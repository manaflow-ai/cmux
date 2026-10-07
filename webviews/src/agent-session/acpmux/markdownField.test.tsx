import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"];
const saved = Object.fromEntries(keys.map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  getSelection: dom.window.getSelection.bind(dom.window),
  MutationObserver: dom.window.MutationObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement, createRef } = await import("react");
const { createRoot } = await import("react-dom/client");
const { MarkdownField } = await import("./MarkdownField");
type Handle = import("./MarkdownField").MarkdownFieldHandle;

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 20)));

test("the field takes markdown in, reports edits out, and reaches the composer's keys first", async () => {
  const changes: [string, number][] = [];
  const keysSeen: string[] = [];
  const ref = createRef<Handle>();
  const root = createRoot(document.getElementById("root")!);
  const render = (value: string) =>
    act(async () =>
      root.render(
        createElement(MarkdownField, {
          ref,
          value,
          placeholder: "Ask anything",
          attributes: { role: "combobox", "aria-label": "Prompt", "aria-expanded": "false" },
          onChange: (markdown: string, caret: number) => changes.push([markdown, caret]),
          onKeyDown: (event: KeyboardEvent) => {
            keysSeen.push(event.key);
            if (event.key === "Enter") event.preventDefault();
          },
        }),
      ),
    );
  await render("Make it **bold**");
  await settle();
  const editable = document.querySelector<HTMLElement>(".acpmux-md")!;
  expect(editable.querySelector("strong")?.textContent).toBe("bold");
  expect(editable.getAttribute("role")).toBe("combobox");
  expect(document.querySelector<HTMLElement>(".acpmux-md-placeholder")!.hidden).toBe(true);
  expect(ref.current!.value()).toBe("Make it **bold**");
  // A value from outside replaces the document; the field does not echo it back.
  await render("");
  await settle();
  expect(editable.textContent).toBe("");
  expect(document.querySelector<HTMLElement>(".acpmux-md-placeholder")!.hidden).toBe(false);
  expect(changes).toEqual([]);
  // Keys go to the composer before the editor.
  await act(async () => {
    editable.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  expect(keysSeen).toEqual(["Enter"]);
  await act(async () => root.unmount());
});
