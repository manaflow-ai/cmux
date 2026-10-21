import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useEffect } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(() => {
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

async function mount() {
  const { createRoot } = await import("react-dom/client");
  const { ChatFindBar } = await import("../src/agent-session/acpmux/conversation/ChatFindBar");
  const { useChatFind } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const { user } = await import("../src/gallery/fixtures/acpmux");
  const rows = [user("retry retry retry", 1)];
  function Find() {
    const find = useChatFind(rows);
    const { show } = find;
    useEffect(() => show("retry"), [show]);
    return find.open ? <ChatFindBar find={find} /> : null;
  }
  root = createRoot(host);
  await act(async () => root!.render(<Find />));
  expect(host.querySelector(".acpmux-find .find-pill__count")?.textContent).toBe("1 of 3");
  return host.querySelector<HTMLInputElement>("input")!;
}

const commands = [
  { name: "Enter", key: "Enter", count: "2 of 3" },
  { name: "Shift-Enter", key: "Enter", shiftKey: true, count: "3 of 3" },
  { name: "Cmd-G", key: "g", metaKey: true, count: "2 of 3" },
  { name: "Shift-Cmd-G", key: "g", metaKey: true, shiftKey: true, count: "3 of 3" },
  { name: "Escape", key: "Escape", count: null },
];

for (const composition of [{ isComposing: true }, { keyCode: 229 }]) {
  for (const { name, count, ...key } of commands) {
    test(`${name} preserves Find during ${"isComposing" in composition ? "composition" : "WebKit composition commit"}`, async () => {
      const input = await mount();
      const composing = new dom.window.KeyboardEvent("keydown", {
        bubbles: true,
        cancelable: true,
        ...key,
        ...composition,
      });
      act(() => {
        input.dispatchEvent(composing);
      });
      expect(composing.defaultPrevented).toBe(false);
      expect(host.querySelector(".acpmux-find .find-pill__count")?.textContent).toBe("1 of 3");
      expect(dom.window.document.activeElement).toBe(input);

      // After composition, the same key still performs its normal Find action.
      const regular = new dom.window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...key });
      act(() => {
        input.dispatchEvent(regular);
      });
      expect(regular.defaultPrevented).toBe(true);
      if (count) expect(host.querySelector(".acpmux-find .find-pill__count")?.textContent).toBe(count);
      else expect(host.querySelector(".acpmux-find")).toBeNull();
    });
  }
}
