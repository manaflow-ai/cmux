// Session rows keep their 30px geometry while a latest-reply preview floats in the shared popup
// layer. The same card is available to pointer hover and keyboard focus, and missing previews stay
// absent.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const saved: (readonly [string, boolean, unknown])[] = [];
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
  const { window } = dom;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  const replacements: Record<string, unknown> = {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    MutationObserver: window.MutationObserver,
    ResizeObserver: window.ResizeObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.getOwnPropertyNames(window))
    if (
      /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
      !(key in scope)
    )
      replacements[key] = (window as unknown as Record<string, unknown>)[key];
  saved.push(...Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const));
  Object.assign(scope, replacements);
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const chat = (sessionId: string, preview?: string) => ({
  sessionId,
  title: "Fix the checkout",
  harness: "codex",
  cwd: "/Users/you/src/cmux",
  branch: "feat/checkout",
  status: "running",
  indicator: "working" as const,
  host: "This Mac",
  hostKind: "local" as const,
  preview,
  updatedAt: 1,
});

async function sidebar(preview?: string, enabled = true, count = 1, onSelect = (_id: string) => {}) {
  const { createRoot } = await import("react-dom/client");
  const { SessionSidebar } = await import("../src/agent-session/acpmux/SessionSidebar");
  root ??= createRoot(host);
  const sessions = Array.from({ length: count }, (_, index) => chat(`session-${index}`, preview));
  await act(async () => root!.render(<SessionSidebar sessions={sessions} preview={enabled} onSelect={onSelect} />));
  return host.querySelector<HTMLElement>(".acpmux-session-row")!;
}

const wait = (ms: number) => act(async () => void (await new Promise((resolve) => setTimeout(resolve, ms))));

test("session preview appears after hover and includes status and placement", async () => {
  const row = await sidebar("The payment form needs a final pass.");
  await act(async () => {
    row.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true }));
  });
  await wait(1_050);
  const card = document.querySelector<HTMLElement>(".acpmux-session-preview");
  expect(card?.textContent).toContain("The payment form needs a final pass.");
  expect(card?.textContent).toContain("Working");
  expect(card?.textContent).toContain("Branch feat/checkout");
  await act(async () => {
    row.dispatchEvent(new window.MouseEvent("pointerout", { bubbles: true, relatedTarget: document.body }));
  });
  expect(document.querySelector(".acpmux-session-preview") === null).toBe(true);
});

test("session preview appears immediately on focus and stays absent without preview text", async () => {
  const row = await sidebar("A focused latest reply.");
  await act(async () => row.focus());
  expect(document.querySelector<HTMLElement>(".acpmux-session-preview")?.textContent).toContain(
    "A focused latest reply.",
  );

  await sidebar();
  expect(document.querySelector(".acpmux-session-preview") === null).toBe(true);
});

test("turning preview features off removes the focused card and prevents hover cards", async () => {
  const row = await sidebar("A reply behind the preview setting.");
  await act(async () => row.focus());
  expect(document.querySelector(".acpmux-session-preview")?.textContent).toContain(
    "A reply behind the preview setting.",
  );

  const disabledRow = await sidebar("A reply behind the preview setting.", false);
  expect(document.querySelector(".acpmux-session-preview") === null).toBe(true);
  await act(async () => {
    disabledRow.blur();
    disabledRow.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true }));
  });
  await wait(1_050);
  expect(document.querySelector(".acpmux-session-preview") === null).toBe(true);
  await act(async () => disabledRow.focus());
  expect(document.querySelector(".acpmux-session-preview") === null).toBe(true);
});

test("Escape dismisses the focused preview", async () => {
  const row = await sidebar("A reply that can be dismissed.");
  await act(async () => row.focus());
  expect(document.querySelector(".acpmux-session-preview") !== null).toBe(true);
  await act(async () => row.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
  expect(document.querySelector(".acpmux-session-preview") === null).toBe(true);
});

test("session rows retain ArrowDown, End and Home navigation", async () => {
  const selected: string[] = [];
  const row = await sidebar(undefined, true, 3, (id) => selected.push(id));
  await act(async () => row.focus());
  for (const [key, expected] of [
    ["ArrowDown", "session-1"],
    ["End", "session-2"],
    ["Home", "session-0"],
  ]) {
    await act(async () =>
      document.activeElement?.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true })),
    );
    expect(document.activeElement?.getAttribute("data-session-id")).toBe(expected);
  }
  expect(selected).toEqual(["session-1", "session-2", "session-0"]);
});
