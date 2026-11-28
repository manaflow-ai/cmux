// Find in Chat gives focus back: closing the bar returns the reader to where they were (cx-bopcl
// POLISH pass on today's landings).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useEffect } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><button id=opener>Composer</button><div id=root></div>", {
    pretendToBeVisual: true,
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  dom.window.close();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
});

test("Escape closes Find and puts focus back where it was", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatFindBar } = await import("../src/agent-session/acpmux/conversation/ChatFindBar");
  const { useChatFind } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const { user } = await import("../src/gallery/fixtures/acpmux");
  const rows = [user("retry retry", 1)];
  const opener = dom.window.document.getElementById("opener")!;
  opener.focus();
  function Find() {
    const find = useChatFind(rows);
    const { show } = find;
    useEffect(() => show("retry"), [show]);
    return find.open ? <ChatFindBar find={find} /> : null;
  }
  const root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () => root.render(<Find />));
  const input = dom.window.document.querySelector<HTMLInputElement>(".acpmux-find input")!;
  expect(dom.window.document.activeElement).toBe(input);
  act(() => {
    input.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Escape" }));
  });
  expect(dom.window.document.querySelector(".acpmux-find")).toBeNull();
  expect(dom.window.document.activeElement).toBe(opener);
  act(() => root.unmount());
});
