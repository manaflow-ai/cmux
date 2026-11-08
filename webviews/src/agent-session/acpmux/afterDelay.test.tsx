import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useAfterDelay } from "./afterDelay";

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
  jest.useRealTimers();
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

function Probe({ active, ms }: { active: boolean; ms: number }) {
  return <span>{useAfterDelay(active, ms) ? "shown" : "hidden"}</span>;
}

const wait = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));

async function render(container: HTMLElement, active: boolean, ms: number) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<Probe active={active} ms={ms} />);
  });
}

test("shows only once active has held for the delay, and hides at once when it ends", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await render(container, true, 40);
  expect(container.textContent).toBe("hidden");
  await wait(39);
  expect(container.textContent).toBe("hidden");
  await wait(1);
  expect(container.textContent).toBe("shown");
  await render(container, false, 40);
  expect(container.textContent).toBe("hidden");
});

test("a break restarts the wait: a stretch shorter than the delay never shows", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await render(container, true, 60);
  await wait(30);
  await render(container, false, 60);
  await render(container, true, 60);
  await wait(59);
  expect(container.textContent).toBe("hidden");
  await wait(1);
  expect(container.textContent).toBe("shown");
});

test("a delay of 0 shows at once, and inactive never shows", async () => {
  jest.useFakeTimers();
  const container = installDom();
  await render(container, true, 0);
  expect(container.textContent).toBe("shown");
  await render(container, false, 0);
  expect(container.textContent).toBe("hidden");
});
