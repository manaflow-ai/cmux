// The New Tab dropdown lists the Commands palette's actions from a catalog the host builds once per binding
// change (no availability, so a Cmd-T builds nothing). A query's matches ask the host whether they run now
// (`newTab.actionStates`). The rows of a query draw once that answer is in, in one draw with their final state:
// never a row drawn and then greyed or removed, never a row the host says cannot run, and Return pressed before
// the answer runs nothing until it is in (lead 2026-10-31, conditions for the New Tab palette redesign).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import type { ActionStates } from "../src/agent-session/acpmux/newtab/screenModel";

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
    // The suggestions' Popover (Base UI and Floating UI) reads these.
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
const actions = [
  { id: "newWindow", title: "New Window", detail: "Windows", keywords: [] },
  { id: "newWorkspace", title: "New Workspace", detail: "Workspaces", keywords: [] },
];

/// A host whose answers the test releases by hand.
function slowHost() {
  const asked: string[][] = [];
  const pending: ((states: ActionStates) => void)[] = [];
  const load = (ids: readonly string[]) => {
    asked.push([...ids]);
    return new Promise<ActionStates>((resolve) => pending.push(resolve));
  };
  return { asked, load, answer: (states: ActionStates) => pending.shift()?.(states) };
}

async function render(load: (ids: readonly string[]) => Promise<ActionStates>, ran: string[], asks: string[] = []) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        omnibar={{ ...EMPTY_OMNIBAR, actions }}
        loadActionStates={load}
        onAction={(id) => ran.push(id)}
        onAsk={(_harness, text) => asks.push(text)}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
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
  field.focus();
  field.setSelectionRange(field.value.length, field.value.length);
  return field;
}

const titles = () =>
  [...window.document.querySelectorAll<HTMLElement>('[role="option"]')].map(
    (option) => option.querySelector(".nt-row-title")?.textContent ?? "",
  );

test("a query's rows draw once its action states are in, and never a row that cannot run", async () => {
  const ran: string[] = [];
  const slow = slowHost();
  await render(slow.load, ran);
  await type("new w");
  // The host is asked for this query's candidates, and nothing of the query is drawn before the answer.
  expect(slow.asked.at(-1)).toEqual(["newWindow", "newWorkspace"]);
  expect(titles()).toEqual([]);
  await act(async () => {
    slow.answer({
      newWindow: { enabled: false, title: "New Window" },
      newWorkspace: { enabled: true, title: "New Workspace" },
    });
  });
  // One draw with the answer: the row that runs, not the one that cannot.
  expect(titles()).toContain("New Workspace");
  expect(titles()).not.toContain("New Window");
});

test("the previous query's rows stay drawn until the next query's states are in", async () => {
  const ran: string[] = [];
  const slow = slowHost();
  await render(slow.load, ran);
  await type("new w");
  await act(async () => {
    slow.answer({
      newWindow: { enabled: true, title: "New Window" },
      newWorkspace: { enabled: true, title: "New Workspace" },
    });
  });
  const before = titles();
  expect(before).toContain("New Window");
  await type("new wo");
  // Asked again for the new query; the rows drawn are still the previous query's, unchanged.
  expect(slow.asked.length).toBe(2);
  expect(titles()).toEqual(before);
  await act(async () => {
    slow.answer({ newWorkspace: { enabled: true, title: "New Workspace" } });
  });
  expect(titles()).toContain("New Workspace");
  expect(titles()).not.toContain("New Window");
});

test("a toggle's row shows the host's title for it", async () => {
  const ran: string[] = [];
  const slow = slowHost();
  await render(slow.load, ran);
  await type("new win");
  await act(async () => {
    slow.answer({ newWindow: { enabled: true, title: "New Window Here" } });
  });
  expect(titles()).toContain("New Window Here");
});

test("Return pressed before the states are in waits for them, then runs the query's top row", async () => {
  const ran: string[] = [];
  const asks: string[] = [];
  const slow = slowHost();
  await render(slow.load, ran, asks);
  const field = await type("new w");
  await act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  // Nothing ran on rows that were not drawn yet.
  expect(asks).toEqual([]);
  expect(ran).toEqual([]);
  await act(async () => {
    slow.answer({
      newWindow: { enabled: true, title: "New Window" },
      newWorkspace: { enabled: true, title: "New Workspace" },
    });
  });
  // With the states in, the Return runs what it would have run with the rows drawn: the Ask row, the top one.
  expect(asks).toEqual(["new w"]);
  expect(ran).toEqual([]);
});
