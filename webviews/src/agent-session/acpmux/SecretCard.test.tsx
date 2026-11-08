// The secret card empties its field as it sends, but a send that fails puts the typed secret back
// (and marks the field), so the person does not retype it; a send that went leaves it empty.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SecretCard } from "./SecretCard";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
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
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function provide(onAnswer: (value?: string) => Promise<unknown>) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<SecretCard ask={{ secretId: "s-1", name: "TOKEN" } as never} agent="Claude" onAnswer={onAnswer} />);
  });
  const field = container.querySelector<HTMLInputElement>("input")!;
  await act(async () => {
    const set = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
    set.call(field, "hunter2");
    field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await act(async () => {
    container
      .querySelector("form")!
      .dispatchEvent(new dom!.window.Event("submit", { bubbles: true, cancelable: true }));
  });
  await act(async () => {});
  return field;
}

test("a secret that could not be sent stays in the field and marks it", async () => {
  const sent: (string | undefined)[] = [];
  const field = await provide(async (value) => {
    sent.push(value);
    throw new Error("native.not_connected");
  });
  expect(sent).toEqual(["hunter2"]);
  expect(field.value).toBe("hunter2");
  expect(field.getAttribute("aria-invalid")).toBe("true");
});

test("a secret that went leaves the field empty", async () => {
  const field = await provide(async () => undefined);
  expect(field.value).toBe("");
  expect(field.getAttribute("aria-invalid")).toBe("false");
});
