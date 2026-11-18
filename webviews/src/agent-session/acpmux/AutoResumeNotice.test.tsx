// The automatic retry line (AutoResumeNotice.tsx): it says the daemon waits to retry, never that a
// turn already resumed (a fixed condition is no notice).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { NoticeSlot } from "./NoticeSlot";
import { AutoResumeNotice } from "./AutoResumeNotice";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
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

async function render(container: HTMLElement, state: Parameters<typeof AutoResumeNotice>[0]["state"]) {
  root ??= createRoot(container);
  await act(async () => {
    root!.render(
      <NoticeSlot>
        <AutoResumeNotice state={state} />
      </NoticeSlot>,
    );
  });
}

test("the retry line shows while the daemon waits to retry, and nothing once the turn resumed", async () => {
  const container = installDom();
  await render(container, { retry: { attempt: 2, of: 4, reason: "transport" }, attempt: 1 });
  expect(container.querySelector('[data-auto-resume="waiting"]')).not.toBeNull();
  // The retry ran and the turn went on: the condition is fixed, so the pane says nothing about it.
  await render(container, { attempt: 2 });
  expect(container.querySelector("[data-auto-resume]")).toBeNull();
  expect(container.textContent).toBe("");
});
