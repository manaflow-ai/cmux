import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChatHeaderInlineStatus, ChatHeaderStatus } from "./ChatHeaderStatus";
import { settleReact } from "../../../../test/support/domTeardown";

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
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("the tab-row warning is an accessory so compressed panes budget it without moving tools", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () =>
    root!.render(<ChatHeaderInlineStatus status="Disconnected" detail="The connection was lost" />),
  );
  const warning = container.querySelector<HTMLOutputElement>("output.acpmux-status--inline");
  expect(warning).not.toBeNull();
  expect(warning!.hasAttribute("data-tab-row-accessory")).toBe(true);
});

test("the regular header status does not join the tab-row accessory budget", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(<ChatHeaderStatus status="Disconnected" detail="The connection was lost" />));
  expect(container.querySelector("[data-tab-row-accessory]")).toBeNull();
});
