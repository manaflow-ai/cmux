// Fork feedback: a slow host must acknowledge the click immediately, ignore duplicates, and leave a
// terminal error in the action row when the host refuses the request (HQ #3324).
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import { ForkButton } from "./MessageActions";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

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

async function render(node: ReactNode): Promise<HTMLElement> {
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
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

test("fork feedback is immediate and duplicate clicks are ignored", async () => {
  let resolve: (value: string) => void = () => undefined;
  let calls = 0;
  const container = await render(
    <ForkButton
      onFork={() => {
        calls += 1;
        return new Promise<string>((done) => (resolve = done));
      }}
    />,
  );
  const button = container.querySelector<HTMLButtonElement>("button")!;
  await act(async () => button.click());
  expect(calls).toBe(1);
  expect(button.disabled).toBe(true);
  expect(button.getAttribute("aria-busy")).toBe("true");
  await act(async () => button.click());
  expect(calls).toBe(1);
  await act(async () => resolve("session-1"));
  expect(button.disabled).toBe(false);
  expect(button.getAttribute("aria-busy")).toBe("false");
  expect(button.dataset.forkState).toBe("idle");
});

test("fork refusal leaves a localized terminal error", async () => {
  const container = await render(<ForkButton onFork={() => Promise.resolve(undefined)} />);
  const button = container.querySelector<HTMLButtonElement>("button")!;
  await act(async () => button.click());
  expect(button.disabled).toBe(false);
  expect(button.dataset.forkState).toBe("error");
  expect(button.title).toBe(translate("notice.forkFailed"));
  expect(container.querySelector('[role="status"]')?.textContent).toBe(translate("notice.forkFailed"));
});
