// A Cloud start's spinner shows only past 300 ms of a real wait (Leo, 2026-11-25, "just go"):
// shorter waits draw nothing, and the empty box holds the spinner's size so nothing moves.
import { afterAll, afterEach, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});
afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

async function draw(delayMs?: number) {
  const { createRoot } = await import("react-dom/client");
  const { DelayedSpinner } = await import("../src/agent-session/acpmux/conversation/DelayedSpinner");
  root = createRoot(host);
  await act(async () => root!.render(<DelayedSpinner size={14} {...(delayMs === undefined ? {} : { delayMs })} />));
}

test("no spinner before 300 ms, one after", async () => {
  jest.useFakeTimers();
  try {
    await draw();
    expect(host.querySelector(".cv-spinner")).toBeNull();
    const box = host.querySelector<HTMLElement>("[data-spinner-wait]")!;
    expect(box.style.width).toBe("14px");
    act(() => jest.advanceTimersByTime(290));
    expect(host.querySelector(".cv-spinner")).toBeNull();
    act(() => jest.advanceTimersByTime(20));
    expect(host.querySelector(".cv-spinner")).not.toBeNull();
  } finally {
    jest.useRealTimers();
  }
});

test("delay 0 (the kill switch) draws the spinner at once", async () => {
  await draw(0);
  expect(host.querySelector(".cv-spinner")).not.toBeNull();
});
