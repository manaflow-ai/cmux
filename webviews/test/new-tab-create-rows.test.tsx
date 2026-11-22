import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { EMPTY_OMNIBAR, omnibarContext, type OmnibarAction } from "../src/agent-session/acpmux/omnibar";
import { screenRows } from "../src/agent-session/acpmux/newtab/screenModel";
import { setHarnessSymbolHost } from "../src/agent-session/shared/harnessIcons";
import { teardownDom } from "./support/domTeardown";

test("every suggestion order finds create commands only when the query matches", () => {
  for (const order of ["intent", "chat", "minimal"] as const) {
    const context = { omnibar: EMPTY_OMNIBAR, order, create: ["terminal", "browser", "chat"] as const };
    for (const text of ["", "ff", "reddit.com"])
      expect(screenRows(text, context).filter((row) => row.type === "create")).toEqual([]);
    expect(
      screenRows("new", context)
        .filter((row) => row.type === "create")
        .map((row) => row.kind),
    ).toEqual(["terminal", "browser", "chat"]);
    expect(
      screenRows("term", context)
        .filter((row) => row.type === "create")
        .map((row) => row.kind),
    ).toEqual(["terminal"]);
  }
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
  "MutationObserver",
  "getSelection",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
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
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

const noop = () => {};

async function render(calls: unknown[][], harness = "claude", actions: OmnibarAction[] = []) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        template="minimal"
        snapshot={noChat()}
        omnibar={omnibarContext({ ...EMPTY_OMNIBAR, workspaces: [{ id: "ws", name: "ff-scratch" }], actions })}
        lastAgent={harness}
        onAsk={(...args) => calls.push(["ask", ...args])}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
        onAction={(id) => calls.push(["action", id])}
        onCreate={(kind) => calls.push(["create", kind])}
      />,
    ),
  );
}

async function type(text: string) {
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const handle = field.acpmuxMarkdownField!;
  await act(async () => {
    handle.focus();
    handle.type(text);
  });
  expect(handle.value()).toBe(text);
  return field.querySelector<HTMLElement>("[contenteditable]")!;
}

const rows = () => [...window.document.querySelectorAll<HTMLElement>('.nt-popover [role="option"]')];
const label = (row: HTMLElement) => row.querySelector(".nt-row-title")?.textContent ?? "";
const creates = () => rows().filter((row) => row.dataset.type === "create");
const key = (field: Element, name: string) =>
  act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
  });

test("Minimal keeps the home clear and shows create rows for a matching search", async () => {
  await render([]);
  expect(host.querySelector(".nt-create")).toBeNull();
  expect(creates()).toEqual([]);
  await type("ff");
  // Return asks the chip's agent with no row of its own (David Beyer 2026-11-20).
  expect(rows().map(label)).toEqual(["ff-scratch", "Search the web for ff"]);
  expect(rows().some((row) => row.dataset.type === "create")).toBe(false);
  await render([]);
  await type("new");
  expect(creates().map(label)).toEqual(["New terminal", "New browser tab", "New chat"]);
  expect(creates().every((row) => row.closest('[role="listbox"]'))).toBe(true);
});

test("create suggestion rows run the terminal, browser and empty chat actions", async () => {
  for (const kind of ["terminal", "browser", "chat"]) {
    const calls: unknown[][] = [];
    await render(calls);
    await type("new");
    const title = kind === "browser" ? "New browser tab" : `New ${kind}`;
    const row = creates().find((row) => label(row) === title)!;
    await act(async () => row.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true })));
    expect(calls[0]?.slice(0, 3)).toEqual(kind === "chat" ? ["ask", "claude", ""] : ["create", kind]);
  }
});

test("arrows visit suggestions and Return runs the highlighted row", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("ff");
  await key(field, "ArrowDown");
  await key(field, "ArrowDown");
  expect(label(rows().find((row) => row.getAttribute("aria-selected") === "true")!)).toBe("Search the web for ff");
  // Down on the last row wraps to the prompt, which has no row: nothing is lit and Return asks.
  await key(field, "ArrowDown");
  expect(rows().some((row) => row.getAttribute("aria-selected") === "true")).toBe(false);
  await key(field, "Enter");
  expect(calls[0]?.slice(0, 3)).toEqual(["ask", "claude", "ff"]);
});

test("Ask rows show each harness mark without action or Return hints", async () => {
  for (const harness of ["claude", "codex"]) {
    await render([], harness);
    // An address leads with Open, so Ask is a drawn row under it (a prompt's own Ask has no row).
    await type("localhost:3000");
    const ask = rows().find((row) => row.dataset.type === "ask")!;
    expect(ask.querySelector(".agent-mark")?.getAttribute("data-agent")).toBe(
      harness === "codex" ? "openai" : "claude",
    );
    expect(ask.querySelector(".ui-key-hint, .nt-row-action")).toBeNull();
  }
});

test("command rows show catalog icons and live shortcut keycaps", async () => {
  const calls: unknown[][] = [];
  const actions = [
    { id: "terminal", title: "Show terminal", keywords: ["show"], symbol: "terminal", keycaps: ["⌃", "`"] },
    { id: "browser", title: "Show browser", keywords: ["show"], symbol: "globe", keycaps: ["⌥", "B"] },
    { id: "sidebar", title: "Show sidebar", keywords: ["show"], symbol: "sidebar.left" },
  ];
  await render(calls, "claude", actions);
  const field = await type("show");
  const commands = rows().filter((row) => row.dataset.type === "action");
  expect(commands.map((row) => row.querySelector("[data-icon]")?.getAttribute("data-icon"))).toEqual([
    "terminal",
    "browser",
    "tunable.sidebar",
  ]);
  expect(
    commands.map((row) => [...row.querySelectorAll(".nt-row-shortcut .ui-key-hint-key")].map((cap) => cap.textContent)),
  ).toEqual([["⌃", "`"], ["⌥", "B"], []]);
  expect(commands.every((row) => row.getAttribute("aria-selected") === "false")).toBe(true);
  expect(document.querySelector(".nt-section, .nt-popover .nt-row-action")).toBeNull();
  await key(field, "ArrowDown");
  await key(field, "Enter");
  expect(calls).toEqual([["action", "terminal"]]);
  await render([], "claude", [{ ...actions[0]!, keycaps: ["⇧", "⌘", "J"] }]);
  await type("show");
  expect(
    [
      ...rows()
        .find((row) => row.dataset.type === "action")!
        .querySelectorAll(".nt-row-shortcut .ui-key-hint-key"),
    ].map((cap) => cap.textContent),
  ).toEqual(["⇧", "⌘", "J"]);
});

test("commands use the host's symbol image when the cmux pack has no icon for the symbol", async () => {
  const asked: string[] = [];
  const src = "data:image/png;base64,iVBORw0KGgo=";
  const release = setHarnessSymbolHost(async (name) => {
    asked.push(name);
    return src;
  });
  try {
    await render([], "claude", [{ id: "custom", title: "Custom command", keywords: [], symbol: "tortoise" }]);
    await type("custom");
    const command = rows().find((row) => row.dataset.type === "action")!;
    expect(asked).toEqual(["tortoise"]);
    const symbol = command.querySelector<HTMLElement>("[data-symbol=tortoise]")!;
    expect(symbol.style.maskImage).toContain(src);
  } finally {
    release();
  }
});
