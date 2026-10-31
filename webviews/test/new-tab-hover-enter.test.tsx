// Leo 2026-10-31: "and i cant even press enter on that hello anymore it doesnt send it to claude".
// With "hello" typed and the suggestions open, the pointer resting on a row (New browser tab) took
// Return from the prompt. The pointer only lights a row now: Return asks the agent unless the arrow
// keys moved the selection since the last edit, and typing again hands Return back to the prompt.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>").window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
const omnibar = { ...EMPTY_OMNIBAR, workspaces: [{ id: "ws", name: "hello-scratch" }] };

async function screen(calls: unknown[][]) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        omnibar={omnibar}
        lastAgent="claude"
        onAsk={(...args) => calls.push(["ask", ...args])}
        onOpen={(...args) => calls.push(["open", ...args])}
        onSearch={(...args) => calls.push(["search", ...args])}
        onShell={noop}
        onJump={(...args) => calls.push(["jump", ...args])}
        onOpenSession={noop}
        onShowAll={noop}
        onCreate={(kind) => calls.push(["create", kind])}
      />,
    ),
  );
  return host.querySelector<HTMLTextAreaElement>(".nt-field")!;
}

async function type(field: HTMLTextAreaElement | HTMLInputElement, text: string) {
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, text);
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
}

const press = (field: HTMLElement, key: string) =>
  act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  });

const hover = (row: HTMLElement) =>
  act(async () => {
    for (const type of ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove"])
      row.dispatchEvent(new window.MouseEvent(type, { bubbles: true }));
  });

const options = () => [...window.document.querySelectorAll<HTMLElement>('[role="option"]')];
const title = (row: HTMLElement) => row.querySelector(".nt-row-title")?.textContent ?? "";
const option = (name: string) => options().find((row) => title(row) === name)!;
const selectedTitle = () => title(options().find((row) => row.getAttribute("aria-selected") === "true")!);

test('"hello" with the pointer on New browser tab: Return asks Claude Code', async () => {
  const calls: unknown[][] = [];
  const field = await screen(calls);
  await type(field, "hello");
  expect(selectedTitle()).toBe("Ask Claude Code");
  await hover(option("New browser tab"));
  // The pointer never moves the selection: Ask keeps it (and its Return glyph).
  expect(selectedTitle()).toBe("Ask Claude Code");
  await hover(option("hello-scratch"));
  expect(selectedTitle()).toBe("Ask Claude Code");
  await press(field, "Enter");
  expect(calls).toEqual([["ask", "claude", "hello", undefined, "claude-opus-5-5"]]);
});

test("Down picks the next row and Return runs it; typing again hands Return back to Ask", async () => {
  const calls: unknown[][] = [];
  const field = await screen(calls);
  await type(field, "hello");
  await press(field, "ArrowDown");
  expect(selectedTitle()).toBe("hello-scratch");
  await press(field, "Enter");
  expect(calls).toEqual([["jump", "workspace", "ws"]]);

  calls.length = 0;
  act(() => root?.unmount());
  const again = await screen(calls);
  await type(again, "hello");
  await press(again, "ArrowDown");
  expect(selectedTitle()).toBe("hello-scratch");
  await type(again, "hello there");
  expect(selectedTitle()).toBe("Ask Claude Code");
  await press(again, "Enter");
  expect(calls).toEqual([["ask", "claude", "hello there", undefined, "claude-opus-5-5"]]);
});

test("a click on a row still runs that row", async () => {
  const calls: unknown[][] = [];
  const field = await screen(calls);
  await type(field, "hello");
  const browser = option("New browser tab");
  await hover(browser);
  await act(async () => browser.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0 })));
  expect(calls).toEqual([["create", "browser"]]);
});

test("classic New Tab: the pointer on a row leaves Return with the prompt", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  const submitted: unknown[][] = [];
  const jumped: unknown[][] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabPage
        snapshot={noChat()}
        lastAgent="claude"
        omnibar={omnibar}
        onSubmit={(...args) => {
          submitted.push(args);
        }}
        onJump={(...args) => jumped.push(args)}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const field = host.querySelector<HTMLInputElement>("input:not([type=file])")!;
  await act(async () => field.focus());
  await type(field, "hello");
  const rows = [...window.document.querySelectorAll<HTMLElement>(".acpmux-omni-row")];
  const other = rows.find((row) => row.getAttribute("aria-selected") !== "true");
  expect(other).toBeDefined();
  await hover(other!);
  expect(other!.getAttribute("aria-selected")).not.toBe("true");
  await act(async () =>
    host.querySelector("form")!.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true })),
  );
  expect(jumped).toEqual([]);
  expect(submitted.map((call) => call.slice(0, 2))).toEqual([["agent", "hello"]]);
});
