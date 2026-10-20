// Leo 2026-10-18: Search and Ask switching comes back to the default New Tab screen (reverses R86,
// Lawrence 2026-10-04). A Search | Ask switch sits at the field's right with "Tab to switch"; Tab
// flips it without leaving the field (Shift-Tab still leaves), and the mode decides which row Return takes:
// Ask puts the agent first, Search the web search. An address still opens first in either mode.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import { defaultSelection, screenRows } from "../src/agent-session/acpmux/newtab/screenModel";

const ask = { harness: "claude", agent: "Claude Code" };
const omnibar = { ...EMPTY_OMNIBAR, workspaces: [{ id: "ws", name: "ff-scratch" }] };

test("Search mode puts the web search first for a prompt, and Return takes it", () => {
  const rows = screenRows("ff", { omnibar, ask, mode: "search" });
  expect(rows.map((row) => row.type)).toEqual(["search", "ask", "workspace"]);
  expect(defaultSelection(rows, "search")).toBe(0);
  expect(screenRows("ff", { omnibar, ask }).map((row) => row.type)).toEqual(["ask", "search", "workspace"]);
});

test("an address opens first in either mode", () => {
  expect(screenRows("reddit.com", { omnibar, ask, mode: "search" })[0]?.type).toBe("open");
  expect(screenRows("reddit.com", { omnibar, ask, mode: "ask" })[0]?.type).toBe("open");
});

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

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

async function render(calls: unknown[][]) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        omnibar={omnibar}
        lastAgent="claude"
        onAsk={(...args) => calls.push(["ask", ...args])}
        onOpen={noop}
        onSearch={(text) => calls.push(["search", text])}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  return host.querySelector<HTMLTextAreaElement>(".nt-field")!;
}

async function type(field: HTMLTextAreaElement, text: string) {
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, text);
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
}

const key = (field: HTMLElement, name: string, shiftKey = false) =>
  act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: name, shiftKey, bubbles: true, cancelable: true }));
  });
const selected = () =>
  [...window.document.querySelectorAll<HTMLElement>('[role="option"]')]
    .find((row) => row.getAttribute("aria-selected") === "true")
    ?.querySelector(".nt-row-title")?.textContent;
const pressed = () =>
  [...host.querySelectorAll<HTMLButtonElement>(".nt-mode [data-mode]")]
    .filter((button) => button.getAttribute("aria-pressed") === "true")
    .map((button) => button.dataset.mode);

test("Tab switches to Search without leaving the field, and Return searches", async () => {
  const calls: unknown[][] = [];
  const field = await render(calls);
  field.focus();
  expect(pressed()).toEqual(["ask"]);
  expect(host.querySelector(".nt-mode")?.textContent).toContain("Tab to switch");
  await type(field, "ff");
  expect(selected()).toBe("Ask Claude Code");

  await key(field, "Tab");
  expect(pressed()).toEqual(["search"]);
  expect(window.document.activeElement).toBe(field);
  expect(field.getAttribute("placeholder")).toBe("Search the web or type a URL");
  expect(selected()).toBe("Search the web for ff");
  await key(field, "Enter");
  expect(calls).toEqual([["search", "ff"]]);
});

test("a second Tab and a click on Ask switch back, and Return asks", async () => {
  const calls: unknown[][] = [];
  const field = await render(calls);
  await type(field, "ff");
  await key(field, "Tab");
  await key(field, "Tab");
  expect(pressed()).toEqual(["ask"]);
  await key(field, "Tab");
  await act(async () => host.querySelector<HTMLButtonElement>('.nt-mode [data-mode="ask"]')!.click());
  expect(pressed()).toEqual(["ask"]);
  expect(selected()).toBe("Ask Claude Code");
  await key(field, "Enter");
  expect(calls[0]?.slice(0, 3)).toEqual(["ask", "claude", "ff"]);
});

// Review (PR 21817): Shift-Tab still moves focus, so the keyboard can leave the field; the field
// names the key, and the mode Tab switched to is announced.
test("Shift-Tab leaves the mode alone and is not consumed", async () => {
  const field = await render([]);
  await type(field, "ff");
  const event = new window.KeyboardEvent("keydown", { key: "Tab", shiftKey: true, bubbles: true, cancelable: true });
  await act(async () => void field.dispatchEvent(event));
  expect(event.defaultPrevented).toBe(false);
  expect(pressed()).toEqual(["ask"]);
  expect(window.document.getElementById(field.getAttribute("aria-describedby")!)?.textContent).toBe("Tab to switch");
  await key(field, "Tab");
  expect(host.querySelector(".nt-mode output")?.textContent).toBe("Search");
});

// Review (PR 21817, Greptile): an arrow that lands while a switch is still rendering picks from the
// rows on screen. The pick follows that row when the switch reorders the rows, so Return takes the
// row that was highlighted, not whatever now sits at its index.
test("an arrow pressed before a switch renders keeps its row through the reorder", async () => {
  const calls: unknown[][] = [];
  const field = await render(calls);
  await type(field, "ff");
  expect(selected()).toBe("Ask Claude Code");
  await act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true }));
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
  });
  expect(pressed()).toEqual(["search"]);
  expect(selected()).toBe("Search the web for ff");
  await key(field, "Enter");
  expect(calls).toEqual([["search", "ff"]]);
});

// Review (PR 21817): a Down, then a click on the switch: the highlight is back on the lead row, so
// the next Tab is the switch's again, not a step through the rows.
test("after Down and a click on the switch, Tab switches again", async () => {
  const field = await render([]);
  await type(field, "ff");
  await key(field, "ArrowDown");
  expect(selected()).toBe("Search the web for ff");
  await act(async () => host.querySelector<HTMLButtonElement>('.nt-mode [data-mode="search"]')!.click());
  expect(selected()).toBe("Search the web for ff");
  await key(field, "Tab");
  expect(pressed()).toEqual(["ask"]);
  expect(selected()).toBe("Ask Claude Code");
});
