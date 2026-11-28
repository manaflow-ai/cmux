// A channel message's actions (Leo dogfood 2026-10-13: hover buttons everywhere). A right-click on the
// message offers them all: the reactions, Reply in Thread, Copy, and Edit and Delete on my own message.
// The hover card shows one button, More; the `hover-actions` experiment's "all" arm keeps the quick
// reactions, Add reaction, Reply in thread and More.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { MessageRow } from "../src/pages/home-channels/MessageRow";
import table from "../src/pages/home-channels/generated/strings.json";
import { createStrings } from "../src/pages/shared/i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "MouseEvent",
    "KeyboardEvent",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(container: HTMLElement) {
  const message = {
    id: "m1",
    conversation: "c1",
    seq: 1,
    author: "me",
    createdAt: 0,
    retracted: false,
    parts: [{ type: "text", text: "Ship it", mentions: [] }],
    reactions: [],
  };
  await act(async () => {
    root = createRoot(container);
    root.render(
      <MessageRow
        message={message as never}
        head
        people={new Map()}
        me="me"
        strings={strings}
        timeFormat={new Intl.DateTimeFormat("en", { timeStyle: "short" })}
        editing={false}
        onOpenThread={() => {}}
        onReact={() => {}}
        onEditStart={() => {}}
        onEdit={async () => true}
        onRetract={() => {}}
      />,
    );
  });
}

const strings = createStrings(table, ["en"]);
const card = (container: HTMLElement) =>
  [...container.querySelectorAll(".hc-msg-actions button")].map((button) => button.getAttribute("aria-label"));

test("the all arm's hover card keeps its reactions, Reply and More", async () => {
  const container = installDom();
  (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "hover-actions": "all" };
  try {
    await render(container);
  } finally {
    delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
  }
  expect(card(container)).toEqual([
    strings.format("action.reactWith", "✅"),
    strings.format("action.reactWith", "👀"),
    strings.format("action.reactWith", "🙌"),
    strings.t("action.react"),
    strings.t("action.reply"),
    strings.t("action.more"),
  ]);
});

test("a message shows More alone on hover, and a right-click offers every action", async () => {
  const container = installDom();
  await render(container);
  expect(card(container)).toEqual([strings.t("message.actions")]);

  const text = [...container.querySelectorAll<HTMLElement>("p, span, div")].find(
    (node) => node.textContent === "Ship it",
  )!;
  await act(async () =>
    text.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 })),
  );
  const items = [...document.querySelectorAll('[role="menu"] [role="menuitem"]')].map((item) => item.textContent);
  expect(items).toEqual([
    strings.format("action.reactWith", "✅"),
    strings.format("action.reactWith", "👀"),
    strings.format("action.reactWith", "🙌"),
    `${strings.t("action.react")}…`,
    strings.t("action.reply"),
    strings.t("action.copy"),
    strings.t("action.edit"),
    strings.t("action.delete"),
  ]);
});
