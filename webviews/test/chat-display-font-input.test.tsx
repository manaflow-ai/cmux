import { afterAll, beforeAll, expect, test } from "bun:test";
import { act } from "react";
import { JSDOM } from "jsdom";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = dom.window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  dom.window.close();
});

test("a custom code font keeps the typed space until it is committed", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatDisplayRows } = await import("../src/agent-session/acpmux/ChatDisplaySettings");
  const { CHAT_DISPLAY, chatDisplayValues, setChatDisplay } = await import("../src/agent-session/acpmux/chatDisplay");
  setChatDisplay({});
  root = createRoot(host);
  await act(async () => root!.render(<ChatDisplayRows />));

  const input = host.querySelector<HTMLInputElement>('.acpmux-display-row input[type="text"]')!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(input), "value")!.set!;
  await act(async () => {
    setValue.call(input, "JetBrains ");
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  expect(input.value).toBe("JetBrains ");

  await act(async () => input.dispatchEvent(new dom.window.FocusEvent("blur", { bubbles: true })));
  expect(chatDisplayValues()[CHAT_DISPLAY.codeFamily.key]).toBe("JetBrains");
});
