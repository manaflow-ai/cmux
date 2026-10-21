// Leo 2026-10-18 (photo, "ff" typed in New Tab): the suggestions offered "Ask Claude Code", the web
// search and the workspaces, but New terminal, New browser tab and New chat only as buttons under
// the field, hidden behind the open list. Now the list ends with the same three create actions
// (cx-ag5.7), so they are always one Down or one click away while the list shows.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../src/agent-session/acpmux/omnibar";
import { MAX_SUGGESTIONS, screenRows, type ScreenRow } from "../src/agent-session/acpmux/newtab/screenModel";

const ask = { harness: "claude", agent: "Claude Code", model: "Claude Opus 5.5" };
const create = ["terminal", "browser", "chat"] as const;
const context = (fields: Partial<OmnibarContext> = {}) => ({
  omnibar: { ...EMPTY_OMNIBAR, ...fields },
  ask,
  create,
});
const kinds = (rows: ScreenRow[]) => rows.map((row) => (row.type === "create" ? `create:${row.kind}` : row.type));

test("a prompt's rows end with the three create actions", () => {
  const rows = screenRows("ff", context({ workspaces: [{ id: "ws", name: "ff-scratch" }] }));
  expect(kinds(rows)).toEqual(["search", "ask", "workspace", "create:terminal", "create:browser", "create:chat"]);
});

test("an address keeps its top hit, the web search and Ask, then the create actions", () => {
  const rows = screenRows("reddit.com", context());
  expect(kinds(rows).slice(-5)).toEqual(["search", "ask", "create:terminal", "create:browser", "create:chat"]);
  expect(rows[0]?.type).toBe("open");
});

test("a full list still ends with the create actions", () => {
  const many = context({
    history: Array.from({ length: 30 }, (_, index) => ({
      url: `https://red${index}.example.com/`,
      title: `Red ${index}`,
    })),
  });
  const rows = screenRows("red", many);
  expect(rows.length).toBe(MAX_SUGGESTIONS + create.length);
  expect(kinds(rows).slice(-5)).toEqual(["search", "ask", "create:terminal", "create:browser", "create:chat"]);
});

test("an empty field and shell mode still show no rows", () => {
  expect(screenRows("", context())).toEqual([]);
  expect(screenRows("!ls", context())).toEqual([]);
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
        omnibar={{ ...EMPTY_OMNIBAR, workspaces: [{ id: "ws", name: "ff-scratch" }] }}
        lastAgent="claude"
        onAsk={(...args) => calls.push(["ask", ...args])}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
        onCreate={(kind) => calls.push(["create", kind])}
      />,
    ),
  );
}

async function type(text: string) {
  const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, text);
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  return field;
}

const rows = () => [...window.document.querySelectorAll<HTMLElement>('[role="option"]')];
const label = (row: HTMLElement) => row.querySelector(".nt-row-title")?.textContent ?? "";

test('typing "ff" lists the web search, Ask, the workspace and the three create actions', async () => {
  await render([]);
  await type("ff");
  expect(rows().map(label)).toEqual([
    "Search the web for ff",
    "Ask Claude Code",
    "ff-scratch",
    "New terminal",
    "New browser tab",
    "New chat",
  ]);
});

test("a create row opens what its button opens", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  await type("ff");
  const terminal = rows().find((row) => label(row) === "New terminal")!;
  await act(async () => terminal.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0 })));
  expect(calls).toEqual([["create", "terminal"]]);

  calls.length = 0;
  await render(calls);
  await type("ff");
  // Up from the top row wraps to the last one, New chat, which Return takes.
  const field2 = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
  await act(async () => field2.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true })));
  const selected = rows().find((row) => row.getAttribute("aria-selected") === "true")!;
  expect(label(selected)).toBe("New chat");
  await act(async () => field2.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
  expect(calls).toEqual([["ask", "claude", "ff", undefined, "claude-opus-5-5"]]);
});
