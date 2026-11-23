// l10n-allow-file: test fixture summaries, not shipped UI.
// The summary line's × (https://github.com/manaflow-ai/cmux/issues/51749): a click hides both copies
// of that chat's line (beside the name and in the tab row) at once, and remembers it on this device.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import { ChatSummaryLine } from "./ChatSummaryLine";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("the × hides both copies of the chat's summary line and remembers it", () => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "https://cmux.test/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
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
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  const summary = { text: "The download fix is merged.", next: "Tell the user" };
  act(() =>
    root!.render(
      <>
        <ChatSummaryLine summary={summary} chat="chat-click" />
        <ChatSummaryLine summary={summary} chat="chat-click" inline />
        <ChatSummaryLine summary={summary} chat="chat-kept" />
      </>,
    ),
  );
  expect(container.querySelectorAll("[data-chat-summary]").length).toBe(3);
  const close = container.querySelector<HTMLButtonElement>(".acpmux-chat-summary__close")!;
  act(() => close.click());
  const left = [...container.querySelectorAll("[data-chat-summary]")];
  expect(left.length).toBe(1);
  expect(dom.window.localStorage.getItem("cmux.agentPane.summaryDismissed")).toBe('["chat-click"]');
});
