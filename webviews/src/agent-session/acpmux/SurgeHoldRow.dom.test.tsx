// l10n-allow-file: test fixtures.
// The held surge's one row (SurgeHoldRow.tsx): counts in place, a panel that lists and searches the
// held threads, need-you first, and no row at all once nothing is held.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { SurgeHold } from "./conversation/surgeHold";
import { settleReact } from "../../../test/support/domTeardown";
import { importWithDom } from "../../../test/support/importWithDom";

// Loaded with a document in place (import-order-lint.test.ts): the DOM below installs per test.
const { SurgeHoldRow } = await importWithDom(() => import("./SurgeHoldRow"));

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
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
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
    });
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

const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

const LISTING = {
  threads: [
    {
      threadId: "topic:runner",
      label: "runner-capacity",
      from: ["runner-watch"],
      count: 9,
      newestAt: 300,
      newestPreview: "Queued jobs on fleet-linux",
      class: "fyi",
      surgeHeld: true,
    },
    {
      threadId: "pr:48120",
      label: "#48120",
      from: ["lane-7"],
      count: 1,
      newestAt: 100,
      newestPreview: "Can you lift the freeze?",
      class: "blocker",
      surgeHeld: true,
    },
  ],
};

async function render(surge: SurgeHold | undefined, list = async () => LISTING) {
  const container = installDom();
  const calls = { list: 0 };
  const listThreads = () => {
    calls.list += 1;
    return list();
  };
  const draw = (next: SurgeHold | undefined) =>
    act(async () => {
      root ??= createRoot(container);
      root.render(
        <SurgeHoldRow
          surge={next}
          sessionId="s1"
          listThreads={listThreads}
          readThread={async () => []}
          onOpenSender={() => undefined}
        />,
      );
    });
  await draw(surge);
  return { container, calls, draw };
}

const click = (element: Element | null | undefined) =>
  act(async () => {
    element!.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });

const threadIds = (container: HTMLElement) =>
  [...container.querySelectorAll(".acpmux-surge-threads .cv-inbox")].map((node) => node.textContent ?? "");

test("nothing held draws no row, and reads nothing", async () => {
  const { container, calls, draw } = await render(undefined);
  expect(container.querySelector(".acpmux-surge")).toBeNull();
  await draw({ held: 0, needYou: 0, seq: 3 });
  expect(container.querySelector(".acpmux-surge")).toBeNull();
  expect(calls.list).toBe(0);
});

test("one row whose counts update in place as snapshots come", async () => {
  const { container, draw } = await render({ held: 12, needYou: 0, seq: 1 });
  expect(container.querySelectorAll(".acpmux-surge").length).toBe(1);
  expect(container.querySelector(".acpmux-surge-count")?.textContent).toContain("12");
  expect(container.querySelector("button.acpmux-surge-need")).toBeNull();
  await draw({ held: 37, needYou: 2, seq: 2 });
  expect(container.querySelectorAll(".acpmux-surge").length).toBe(1);
  expect(container.querySelector(".acpmux-surge-count")?.textContent).toContain("37");
  expect(container.querySelector("button.acpmux-surge-need")?.textContent).toContain("2");
  await draw({ held: 0, needYou: 0, seq: 3 });
  expect(container.querySelector(".acpmux-surge")).toBeNull();
});

test("opening lists the held threads once, need-you first; search and the need-you filter narrow them", async () => {
  const { container, calls } = await render({ held: 10, needYou: 1, seq: 1 });
  await click(container.querySelector(".acpmux-surge-toggle"));
  await settle();
  expect(calls.list).toBe(1);
  expect(container.querySelector(".acpmux-surge-toggle")?.getAttribute("aria-expanded")).toBe("true");
  let lines = threadIds(container);
  expect(lines.length).toBe(2);
  expect(lines[0]).toContain("lane-7");
  const input = container.querySelector<HTMLInputElement>(".acpmux-surge-search input")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, "fleet");
    input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  lines = threadIds(container);
  expect(lines.length).toBe(1);
  expect(lines[0]).toContain("runner-watch");
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, "");
    input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  const [, needOnly] = container.querySelectorAll(".acpmux-surge-filters button");
  await click(needOnly);
  lines = threadIds(container);
  expect(lines.length).toBe(1);
  expect(lines[0]).toContain("lane-7");
  expect(calls.list).toBe(1);
});

test("the need-you pill opens the panel on those alone", async () => {
  const { container } = await render({ held: 10, needYou: 1, seq: 1 });
  await click(container.querySelector("button.acpmux-surge-need"));
  await settle();
  const lines = threadIds(container);
  expect(lines.length).toBe(1);
  expect(lines[0]).toContain("lane-7");
});

test("a failed listing says so with Try again, which reads again", async () => {
  let fail = true;
  const { container, calls } = await render({ held: 4, needYou: 0, seq: 1 }, async () => {
    if (fail) throw new Error("offline");
    return LISTING;
  });
  await click(container.querySelector(".acpmux-surge-toggle"));
  await settle();
  expect(container.querySelector('.acpmux-surge-failed[role="alert"]')).not.toBeNull();
  // The failure keeps acpmux's own words, not a bare Try again.
  expect(container.querySelector(".acpmux-surge-failed-reason")?.textContent).toContain("offline");
  fail = false;
  await click(container.querySelector(".acpmux-surge-retry"));
  await settle();
  expect(calls.list).toBe(2);
  expect(threadIds(container).length).toBe(2);
});
