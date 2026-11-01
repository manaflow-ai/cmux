import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { PromptContentPart } from "../model";
import { InlinePromptContent } from "./InlinePromptContent";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function render(parts: PromptContentPart[]): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const host = dom.window.document.getElementById("root")!;
  act(() => {
    root = createRoot(host);
    root.render(
      <InlinePromptContent
        rowId="inline-row"
        parts={parts}
        show={(text) => text}
        renderImage={(image) => <span data-kind="image">{image.id}</span>}
      />,
    );
  });
  return host;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("renders image, text, image, text in one inline content run", () => {
  const host = render([
    { kind: "image", id: "first", mimeType: "image/png" },
    { kind: "text", text: "caption one" },
    { kind: "image", id: "second", mimeType: "image/png" },
    { kind: "text", text: "caption two" },
  ]);
  const children = [...host.querySelectorAll<HTMLElement>("[data-inline-content] > *")].map((child) =>
    child.querySelector('[data-kind="image"]') ? "image" : `text:${child.textContent}`,
  );
  expect(children).toEqual(["image", "text:caption one", "image", "text:caption two"]);
});
